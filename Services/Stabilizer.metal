#include <metal_stdlib>
using namespace metal;

// R: 旋转矩阵（虚拟→物理，即旋转虚拟光线到物理鱼眼坐标系）
// cam: (fx, fy, cx, cy) 虚拟相机内参
// fish: (fx, fy, cx, cy) 鱼眼相机内参
kernel void stabilize(texture2d<float, access::sample> inTex [[texture(0)]],
                      texture2d<float, access::write>  outTex [[texture(1)]],
                      constant float3x3& R   [[buffer(0)]],
                      constant float4&   cam [[buffer(1)]],
                      constant float4&   fish [[buffer(2)]],
                      uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    // 1. 输出像素 → 虚拟相机归一化方向
    float fx = cam.x, fy = cam.y, cx = cam.z, cy = cam.w;
    float xn = (float(gid.x) + 0.5 - cx) / fx;
    float yn = (float(gid.y) + 0.5 - cy) / fy;
    float3 ray = normalize(float3(xn, yn, 1.0));

    // 2. 旋转到物理鱼眼坐标系
    float3 rot = R * ray;

    // 3. 方向 → 球坐标
    float theta = acos(clamp(rot.z, -1.0, 1.0));
    float phi   = atan2(rot.y, rot.x);

    // 4. 等距投影: r = f * theta
    float iFx = fish.x, iFy = fish.y, iCx = fish.z, iCy = fish.w;
    float avgF = (iFx + iFy) * 0.5;
    float r_fish = avgF * theta;

    // 5. 鱼眼像素坐标
    float2 src = float2(iCx + r_fish * cos(phi), iCy + r_fish * sin(phi));

    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);
    outTex.write(inTex.sample(s, src), gid);
}
