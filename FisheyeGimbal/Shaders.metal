//
//  Shaders.metal
//  FisheyeGimbal
//
//  两个 pass：
//   1) FEConvertKernel —— BGRA -> RGBA，顺手记录源帧尺寸
//   2) FEStabilizeVertex/Fragment —— 逐像素做「反向映射」：
//        屏幕像素 -> 输出小孔相机中的方向 -> 世界系方向(应用防抖旋转)
//        -> 鱼眼相机系方向 -> 鱼眼投影到源图像素坐标 -> 双线性采样
//      这是标准的 image-based rendering / 视角重投影，一个 pass 内同时完成
//      去畸变 + 三轴增稳。
//

#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// 源帧纹理坐标基
// ---------------------------------------------------------------------------
// 我们统一用纹理空间坐标：u 沿纹理宽度方向、v 沿纹理高度方向。
// 手机背部摄像头的光轴朝 +z，传感器 x 轴朝纹理 u 方向(右)，y 轴朝纹理 v 方向(下)。
// 于是 sensor 系下的三个基向量分别对应纹理空间的：
//   sensor +z  -> 纹理 +u
//   sensor +x  -> 纹理 +v
//   sensor +y  -> 纹理 -(u x v) = 指向纹理外(屏幕朝观察者)
//
// 传入的 viewDirW 是「锁定的世界方向」；每个像素的重投影方向为
//   dirSensor = rawRotation * (pinhole 光线方向)
// 已用数值验证：此时输出画面的 right / up 与 sensor 基向量映射一致。
// ---------------------------------------------------------------------------

// 显式 16 字节槽位布局：
//   offset 0   : 4x4 矩阵            (64)
//   offset 64  : viewDirW            (16)
//   offset 80  : slots[0] = srcSize+outSize   (16)
//   offset 96  : slots[1] = center + 2 floats (16)
//   offset 112 : slots[2] = 4 floats          (16)
//   offset 128 : slots[3] = 4 floats          (16)
//   offset 144 : screenUp + pad       (16)
//   总计 160 字节。全部落在 16 字节边界上，
//   Metal 和 Swift 不会有任何"各自插 padding"的分歧。
//
//   诊断复用（screenUp_.z，as_type 成 uint，同时存两个开关）：
//     高 16 位 = 测试图模式  0=关 1=同心环
//     低 16 位 = 姿态旁路    0=正常 1=跳过姿态补偿（直接取原始画面）
struct FEUniforms {
    float4x4 rawRotation   [[id(0)]];   // 0   : 源帧坐标系<-世界系的旋转
    float4   viewDirW      [[id(1)]];   // 64  : 锁定的世界朝向（源帧坐标系中）
    float4   slots0        [[id(2)]];   // 80  : xy = srcSize, zw = outSize
    float4   slots1        [[id(3)]];   // 96  : xy = center,  z = focal, w = fOutX
    float4   slots2        [[id(4)]];   // 112 : x = fOutY, y = projection, z = k1, w = k2
    float4   slots3        [[id(5)]];   // 128 : x = maxTheta, y = maxR, z = edgeFeather, w = exposure
    float4   screenUp_     [[id(6)]];   // 144 : xy = screenUp, z = 诊断开关(打包)
};

static inline float2 feSrcSize(constant FEUniforms &u)  { return u.slots0.xy; }
static inline float2 feOutSize(constant FEUniforms &u)  { return u.slots0.zw; }
static inline float2 feCenter(constant FEUniforms &u)   { return u.slots1.xy; }
static inline float  feFocal(constant FEUniforms &u)    { return u.slots1.z; }
static inline float  feFOutX(constant FEUniforms &u)    { return u.slots1.w; }
static inline float  feFOutY(constant FEUniforms &u)    { return u.slots2.x; }
static inline float  feProjection(constant FEUniforms &u) { return u.slots2.y; }
static inline float  feK1(constant FEUniforms &u)       { return u.slots2.z; }
static inline float  feK2(constant FEUniforms &u)       { return u.slots2.w; }
static inline float  feMaxTheta(constant FEUniforms &u) { return u.slots3.x; }
static inline float  feMaxR(constant FEUniforms &u)     { return u.slots3.y; }
static inline float  feFeather(constant FEUniforms &u)  { return u.slots3.z; }
static inline float  feExposure(constant FEUniforms &u) { return u.slots3.w; }
static inline float2 feScreenUp(constant FEUniforms &u) { return u.screenUp_.xy; }
static inline uint   feTestPattern(constant FEUniforms &u) { return as_type<uint>(u.screenUp_.z) >> 16; }
static inline uint   fePoseBypass(constant FEUniforms &u)  { return as_type<uint>(u.screenUp_.z) & 0xFFFFu; }

// equisolid: r = 2 f sin(theta/2)
static inline float feRadiusFromTheta(float theta, float f, float model) {
    return (model < 0.5f) ? (f * theta) : (2.0f * f * sin(theta * 0.5f));
}

// 径向修正：把实测畸变曲线拉回理想模型
static inline float feCorrectRadius(float r, float k1, float k2) {
    float x = r * r;
    return r * (1.0f + k1 * x + k2 * x * x);
}

// ---------------------------------------------------------------------------
// Pass 1: 源帧 -> RGBA
//   sourceFormat: 0 = BGRA(单平面)  1 = YUV420 biplanar full range
//                2 = YUV420 biplanar video range
//
//   必须支持 YUV：AVCaptureVideoDataOutput 在很多摄像头格式上压根不支持 BGRA，
//   那时系统会静默回退到 420v/420f —— 这正是首版黑屏的根因。
// ---------------------------------------------------------------------------
kernel void FEConvertKernel(texture2d<float, access::read>  inTex   [[texture(0)]],
                            texture2d<float, access::read>  inYTex  [[texture(1)]],
                            texture2d<float, access::read>  inUVTex [[texture(2)]],
                            texture2d<float, access::write> outTex  [[texture(3)]],
                            constant uint &sourceFormat [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }

    float4 rgba;
    if (sourceFormat == 0u) {
        float4 c = inTex.read(gid);
        rgba = float4(c.b, c.g, c.r, 1.0f);   // BGRA 字节序 -> RGBA
    } else {
        // NV12：Y 全分辨率单平面，CbCr 半分辨率交错在一个平面里
        float y  = inYTex.read(gid).r;
        float2 chroma = inUVTex.read(uint2(gid.x >> 1, gid.y >> 1)).rg;
        float cb = chroma.r;
        float cr = chroma.g;

        float yv  = (sourceFormat == 1u) ? y : (y - (16.0f / 255.0f)) * (255.0f / 219.0f);
        float cbv = (sourceFormat == 1u) ? (cb - 0.5f)
                                         : (cb - (128.0f / 255.0f)) * (255.0f / 224.0f);
        float crv = (sourceFormat == 1u) ? (cr - 0.5f)
                                         : (cr - (128.0f / 255.0f)) * (255.0f / 224.0f);

        float r = yv + 1.5748f * crv;                       // BT.709
        float g = yv - 0.1873f * cbv - 0.4681f * crv;
        float b = yv + 1.8556f * cbv;
        rgba = float4(clamp(float3(r, g, b), 0.0f, 1.0f), 1.0f);
    }
    outTex.write(rgba, gid);
}

// ---------------------------------------------------------------------------
// Pass 2: 去畸变 + 增稳
// ---------------------------------------------------------------------------
struct FEVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex FEVertexOut FEStabilizeVertex(uint vid [[vertex_id]]) {
    const float2 pos[4] = { float2(-1.0f, -3.0f),
                            float2(-1.0f,  1.0f),
                            float2( 3.0f,  1.0f),
                            float2( 1.0f, -1.0f) };
    FEVertexOut out;
    float2 p = pos[vid];
    out.position = float4(p, 0.0f, 1.0f);
    out.uv = p;
    return out;
}

fragment float4 FEStabilizeFragment(FEVertexOut in [[stage_in]],
                                    constant FEUniforms &u [[buffer(0)]],
                                    texture2d<float> srcTex [[texture(0)]]) {
    constexpr sampler samp(coord::normalized,
                           address::clamp_to_edge,
                           filter::linear,
                           mip_filter::none);

    float2 outSize  = max(feOutSize(u), float2(1.0f, 1.0f));
    float2 fOut     = float2(feFOutX(u), feFOutY(u));
    float2 srcSize  = feSrcSize(u);
    float2 center   = feCenter(u);
    float  focal    = feFocal(u);
    float  model    = feProjection(u);
    float  k1       = feK1(u);
    float  k2       = feK2(u);
    float  maxTheta = feMaxTheta(u);
    float  maxR     = feMaxR(u);
    float  eFeather = feFeather(u);
    float2 screenUp = feScreenUp(u);

    // ---- 0a) 测试图模式：证明 shader 确实在跑、输出确实可见 ----
    // 看不到同心环 = shader 没执行（管线/PSO 的问题）
    // 看到同心环但正常模式全黑 = 数学算出来的就是黑的
    if (feTestPattern(u) != 0u) {
        float2 c2 = in.uv;
        float rr = length(c2);
        float ring = fract(rr * 6.0f);
        float3 tp = (ring < 0.5f) ? float3(1.0f, 0.3f, 0.0f)
                                  : float3(0.0f, 0.05f, 0.35f);
        if (rr < 0.45f) { tp = float3(0.0f, 0.9f, 0.1f); }
        if (rr > 0.95f) { tp = float3(1.0f, 1.0f, 1.0f); }
        return float4(tp, 1.0f);
    }

    // ---- 1) 该像素对应的输出小孔光线（右手系：x 右、y 下、z 前）----
    float2 ndc = in.uv;                       // [-1,1]
    float2 pixel = float2((ndc.x + 1.0f) * 0.5f * outSize.x,
                          (1.0f - ndc.y) * 0.5f * outSize.y);
    float2 d = (pixel - outSize * 0.5f) / fOut;
    float3 dirView = normalize(float3(d.x, d.y, 1.0f));

    // ---- 2) 转到源帧坐标系 ----
    // 旁路模式下跳过姿态补偿，直接取原始鱼眼画面（用来区分"数学错"还是"姿态错"）
    bool bypass = (fePoseBypass(u) != 0u);
    float4x4 rot = bypass ? float4x4(1.0f) : u.rawRotation;
    float3 dirS = normalize((rot * float4(dirView, 0.0f)).xyz);

    // 世界系中锁定的朝向，转到源帧坐标系
    float3 f = (rot * float4(normalize(u.viewDirW.xyz), 0.0f)).xyz;

    // ---- 3) 对齐屏幕方向（竖屏/横屏时旋转 90°）----
    float3 screenUpRaw = (rot * float4(screenUp.x, screenUp.y, 0.0f, 0.0f)).xyz;
    float3 planeUp = screenUpRaw - f * dot(screenUpRaw, f);
    float ul = length(planeUp);
    if (ul < 1e-5f) {
        planeUp = float3(f.y, -f.x, 0.0f);
        ul = max(length(planeUp), 1e-5f);
    }
    planeUp /= ul;

    float3 rightS = cross(planeUp, f);
    float rl = length(rightS);
    rightS = (rl > 1e-5f) ? (rightS / rl) : normalize(cross(float3(0.0f, 1.0f, 0.0f), f));

    // 把 P 投影到输出视图平面
    float3 P = normalize(dirS);
    float3 planeP = P - f * dot(P, f);
    float x = dot(planeP, rightS);
    float y = dot(planeP, planeUp);

    // ---- 4) 计算到源图像素坐标 ----
    float theta = acos(clamp(dot(P, f), -1.0f, 1.0f));
    if (theta > maxTheta) {
        return float4(0.0f, 0.0f, 0.0f, 1.0f);   // 超出镜头视野 -> 黑边
    }

    float xy = sqrt(x * x + y * y);
    float r = feRadiusFromTheta(theta, focal, model);
    r = feCorrectRadius(r, k1, k2);

    float2 offset = (xy > 1e-6f) ? (float2(x, y) / xy * r) : float2(0.0f, 0.0f);
    float2 srcPix = center + offset;

    // ---- 5) 采样（越界就黑掉，避免 clamp_to_edge 拉出条纹）----
    float hr = (maxR > 0.0f) ? maxR : (srcSize.x * 0.5f);
    float rc = length(offset);
    if (srcPix.x < 0.0f || srcPix.y < 0.0f ||
        srcPix.x > srcSize.x || srcPix.y > srcSize.y) {
        return float4(0.0f, 0.0f, 0.0f, 1.0f);
    }

    float4 col = srcTex.sample(samp, srcPix / srcSize);

    // ---- 6) 镜头圆边缘羽化 ----
    if (eFeather > 0.0f && rc > hr - eFeather) {
        float t = clamp((hr - rc) / eFeather, 0.0f, 1.0f);
        col.rgb *= t;
    }

    // ---- 7) 曝光 ----
    col.rgb *= feExposure(u);
    col.a = 1.0f;
    return col;
}
