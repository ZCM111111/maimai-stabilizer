# FisheyeGimbal

iPhone 外接鱼眼镜头 → 实时去畸变 + 三轴增稳，做成「纯 IMU 云台」。

手机随便晃，画面始终看向同一个世界方向 —— 效果对标 DJI Pocket 3 的云台锁定模式，
但不靠电机，全靠陀螺仪 + GPU 逐像素重投影。

镜头夹在 **0.5x 超广角**上。

---

## 0. 没有 Mac、没有开发者证书，怎么编译

iOS 编译**必须** macOS + Xcode toolchain，这一步绕不过去。但可以完全在线完成：

```
Windows 写代码 ──push──► 云端 macOS runner 编译出「未签名 ipa」──► Windows 上自己签名装手机
```

**没有开发者证书不影响编译**，只影响最后装到手机上那一步。

### 路线 A：Codemagic（推荐，日志能直接看）

1. 打开 https://codemagic.io ，用 GitHub 登录
2. `Add application` → 选 `ZCM111111/maimai-stabilizer`
3. 构建类型选 `iOS App Store`（或 `Other`），Codemagic 自动读仓库里的 `codemagic.yaml`
4. **什么都不用配** —— 不需要证书、不需要 Apple ID、不需要 App Store Connect Key
5. `Start new build` → 进去看实时完整日志
6. 构建完在 Artifacts 下载 `FisheyeGimbal-unsigned.ipa`

> ⚠️ 免费额度（500 min/月）**主要覆盖 Linux 机器**，而 iOS 构建必须用 macOS 机器。
> 如果网页提示需要付费/试用，说明 macOS 分钟不在免费额度内 —— 直接走路线 B。

### 路线 B：GitHub Actions（公开仓库免费）

推送后自动跑 `.github/workflows/build-ios.yml`。

> **为什么必须用公开仓库**：GitHub macOS runner 是 **10 倍计费倍率**，
> 私有仓库免费额度 2000 min/月 → 实际只有 200 min macOS。
> 公开仓库的 Actions 完全免费。

仓库 → `Actions` → 最新一次 run → 底部 `Artifacts` → 下载 ipa。

---

## 0.1 拿到未签名 ipa 之后怎么装到手机

未签名 ipa **不能直接安装**，必须先签名。三条路：

| 方式 | 成本 | 有效期 | 说明 |
|---|---|---|---|
| **Sideloadly**（Windows 上跑） | 免费 | 7 天 | 填 Apple ID 自动签名装机，到期重跑 |
| **AltStore / AltServer** | 免费 | 7 天 | 装完 AltStore 后手机上自己续签，比 Sideloadly 省事 |
| **Apple 开发者账号** | $99/年 | 1 年 | 拿到正式证书后不用反复重签 |

Windows 上 Sideloadly 流程：

```
装 Sideloadly -> USB 连 iPhone -> 拖入 FisheyeGimbal-unsigned.ipa
-> 填 Apple ID -> Start -> 手机设置里信任开发者证书
```

同一仓库里还带了 `sign-and-install.ps1`（走 AltServer 自动装机）。

**首次安装前必须做**：iPhone → `设置 → 隐私与安全性 → 开发者模式` → 打开 → 重启手机。
不开这个，装完点图标会闪退。

---

## 1. 算法

### 1.1 一个 pass 同时干掉去畸变和晃动手抖

关键：**不做"先变形图像再平移"**（那样边缘会撕裂、视场会不够），
而是对每个输出像素做**反向映射**，直接算出它该从鱼眼原图的哪个像素取色。

```
屏幕像素 (px, py)
  │  ① 输出小孔相机光线
  ▼
dir_view = normalize((px - W/2)/f_out, (py - H/2)/f_out, 1)
  │  ② 世界系 → 相机帧（这就是增稳）
  ▼
dir_sensor = R_comp · dir_view
  │  ③ 投影到锁定朝向构成的平面，得到 (x, y) 与夹角 θ
  ▼
θ = acos(dot(P, f))
  │  ④ 鱼眼投影模型 → 像高
  ▼
r = f_fish · θ                 (等距 equidistant)
r = 2·f_fish·sin(θ/2)          (等立体角 equisolid)
r ← r·(1 + k1·r² + k2·r⁴)      (径向修正，吃掉真实镜头与理想模型的偏差)
  │  ⑤ 落到鱼眼圆里
  ▼
src_pixel = center + (x,y)/|(x,y)| · r  → 双线性采样
```

### 1.2 增稳：四元数低通 + 锁向

```
q_raw(t)      CoreMotion 给的设备姿态（世界系，100 Hz）
q_smooth(t)   四元数低通：q_smooth ← slerp(q_smooth, q_raw, 1 - e^(-dt/τ))
q_lock        锁定朝向（按"回中"那一刻冻结）
R_comp = q_lock⁻¹ ⊗ q_smooth
```

**为什么必须对四元数滤波，不能对欧拉角滤波**：欧拉角在万向节附近会跳变/死锁，
滤波出来就是画面抽搐。四元数 slerp 是旋转空间里的最短弧插值，永远平滑。

**为什么画面看起来"锁死"**：`R_comp` 表达的是「当前相机帧相对锁定朝向的姿态」。
把它乘到出射光线上，等于把画面反向旋转回去 —— 于是不管手机怎么转，
同一个世界方向永远落在屏幕同一个位置。

两种模式：

| 模式 | 行为 | 类比 |
|---|---|---|
| 锁定 (hold) | `q_lock` 完全不动，画面绝对钉死 | Pocket 3 云台锁定 |
| 跟随 (damping) | `q_lock` 以 τ=1.2s 慢慢追向 `q_smooth` | Pocket 3 云台跟随 |

**物理极限**：陀螺仪有零偏（bias），纯 IMU 无绝对参考，
锁定模式下画面会以约 0.1~1°/分钟 的速度缓慢漂移。
真云台靠电机 + 编码器闭环，光靠传感器做不到零漂。点一下"回中"即可修正。

`抵消 Yaw 漂移` 开关：只对跟随模式有意义，把绕竖直轴的累计角度解缠掉，
避免转到 ±180° 时画面突然翻转。

---

## 2. 坐标系（这块最容易搞错，写死了）

手机背部摄像头：

| 物理方向 | 传感器坐标 | 源帧纹理坐标 |
|---|---|---|
| 沿画面宽度向右 | +x | **+u** |
| 沿画面高度向下 | +y | **+v** |
| 光轴，镜头朝外 | +z | **−(u × v)** |

所以源帧坐标系三个基向量：

```
axisU = R_comp · (1,0,0)     纹理 +u
axisV = R_comp · (0,1,0)     纹理 +v
axisW = R_comp · (0,0,1)     纹理 -(u×v)，即光轴朝外
```

行向量构造成的 3×3 矩阵 `[axisU; axisV; axisW]` 恰好是**正交阵**（行列式 = +1），
这是"基底变换"和"坐标系变换"之间那个经典的反转关系，不是笔误。

**屏幕方向**（竖屏/横屏）只影响 `screenUp`，跟设备姿态无关（传感器固定装在机身上）：

| 界面方向 | screenUp |
|---|---|
| 竖屏 | (0, −1) |
| 左横屏 | (1, 0) |
| 右横屏 | (−1, 0) |

---

## 3. 标定流程（这是能不能出效果的关键）

镜头的 `f` 和 `k1/k2` 决定成败。默认值只是数量级，**必须现场拧**。

1. **找一条直线**：门框、桌沿、窗台、瓷砖缝。让它在画面里近乎水平地横穿。
2. **先拧「镜头半视场角」**：画面整体缩放对不对。太小 → 画面被过度拉大；
   太大 → 边缘出现黑色空洞（超出成像圈）。调到刚好填满、只剩一点点黑边。
3. **再拧投影模型**：`equidistant` / `equisolid` 切换看哪个直线更直。
   两个都不够直 → 继续 k1。
4. **拧 k1**：k1 越大，边缘越往外推。直线中间鼓起 → 减小 k1；中间凹陷 → 增大 k1。
5. **拧 k2**：k1 拉不平的残留，用 k2 修。k2 影响的主要是画面最外圈。
6. **拧光心 X/Y**：镜头夹歪了、螺丝偏心，靠这两个把画面中心对正。
   判断标准：画面中心附近的直线应该**同时**是直的，而不是一边直一边弯。
7. **【回中】→ 晃手机**：确认画面不跟着手机走。

**调好了记下来**，换个镜头/重装一次可能就得重调。

### 关于 0.5x 超广角的两个坑

夹在 0.5x 上视野极大，但要盯两件事：

1. **成像圈可能小于传感器**。0.5x 本身已经 120° 了，再叠鱼眼，
   组合视场可能超过 260°，导致成像圈缩在画面中间、四周一圈黑。
   表现：中间是个圆，圆外全黑且转不动。
   → 处理：把「镜头半视场角」调小、或点【回中】后只用小幅晃动。
2. **低光下画质偏软**。0.5x 传感器和单像素面积都比 1x 小得多，
   掰直后要放大插值，会比 1x 更肉、噪点更多。
   如果画质不能接受，就改夹在 1x 上（高级面板里「夹在哪个镜头」切换），重新标定。

---

## 4. 期望效果与限制

**能做到：**
- 鱼眼畸变实时矫正，直线变直（残差取决于标定精度）
- 三轴（偏航/俯仰/横滚）全部补偿。横滚也会被纠平 —— 手机歪着，地平线依然是平的
- 1080p60 在 A12 及以上流畅（iPhone XS/XR 之后全系）

**做不到 / 会看到的：**
- **黑边**：手机转太快或转太大角度时，需要的视场超出镜头能提供的范围 → 黑边。
  这是物理限制。想更抗晃 → 把「输出视场角」调小（画面放大），换取转动余量。
- **缓慢漂移**：见 §1.2，纯 IMU 无解。
- **果冻效应**：CMOS 是逐行曝光的，快速横摇时会有轻微斜切。
  真云台靠机械隔离，纯软件补偿不了这个。
- **音频/录像没做**：现在是纯预览管线。要加录像得再接 AVAssetWriter，
  把 Metal 输出回灌到 pixel buffer（需要 `framebufferOnly = false`）。

**想要更好可以继续做：**
- 用 `AVCaptureDevice.Format.formatDescription` 里的畸变元数据拿实测参数
- 加棋盘格/直线检测做**自动标定**：用 Vision 或 OpenCV 拟合直线，最小二乘解 k1/k2
- 补录像、补陀螺仪时间戳与帧时间戳的插值对齐（现在直接取最新姿态，
  高速晃动时会有 1 帧级的时间错位）

---

## 5. 文件结构

```
FisheyeGimbal/
├── FisheyeGimbal.xcodeproj/
│   └── xcshareddata/xcschemes/FisheyeGimbal.xcscheme   共享 scheme（CI 要用）
├── FisheyeGimbal/
│   ├── App.swift                      入口 + 权限 + 生命周期
│   ├── ContentView.swift              UI + 标定面板 + Metal 视图容器
│   ├── CameraCapture.swift            AVCapture 取原始帧（关掉所有内置修正）
│   ├── MotionTracker.swift            CoreMotion 姿态 + 四元数低通 + 锁向
│   ├── DistortionModel.swift          鱼眼模型定义与预设
│   ├── TunableParams.swift            标定参数（UI 与 renderer 共享）
│   ├── InterfaceOrientationTracker.swift  界面方向
│   ├── FrameRenderer.swift            Metal 管线 + 环形纹理池 + uniform 打包
│   ├── Shaders.metal                  核心 kernel：去畸变 + 增稳
│   └── Info.plist
├── .github/workflows/build-ios.yml    GitHub Actions 免 Mac 编译
├── codemagic.yaml                     Codemagic 免 Mac 编译（日志可在网页看）
├── sign-and-install.ps1               Windows 签名装机（走 AltServer）
└── README.md
```

---

## 6. 真机跑起来之后

1. 第一次启动会要摄像头和运动权限，都给。
2. 顶部胶囊里 `imu ok` 才说明陀螺仪在工作。显示 `imu －` 就是没数据，
   云台功能不会生效（画面还是去畸变的，但不会锁向）。
3. `cam xx fps / render xx fps` 是实时帧率。低于 30 就去高级里降到 30fps。
4. 点【回中】把当前朝向设成锁定方向。之后手机随便晃，画面都朝着这个方向。
5. 先按 §3 把镜头标定好，再测增稳 —— 标定没做好，晃起来你会以为增稳也坏了。

---

## 7. 出问题了按这个顺序查

| 现象 | 原因 | 处理 |
|---|---|---|
| 画面全黑，`cam 0 fps` | 摄像头权限 / 会话没起来 | 看 `camera.lastError` 那条红条 |
| 画面是雪花/错位彩条 | Uniform 布局和 shader 错位 | 检查 `FrameRenderer.init` 里的 assert 有没有炸 |
| `Metal 初始化失败` | shader 编译失败或设备不支持 Metal | 看编译日志里 `Shaders.metal` 的报错 |
| 画面跟着手机一起晃 | IMU 没数据 | 顶部应显示 `imu ok`；否则检查运动权限 |
| 画面锁死但缓慢漂移 | 陀螺仪零偏，物理极限 | 见 §1.2，点【回中】 |
| 边缘一圈黑 | 输出视场角太大，超出成像圈 | 调小「输出视场角」或调大「镜头半视场角」 |
| 直线中间鼓/凹 | 畸变模型或 k1 不对 | 回 §3 第 4 步 |
| 晃快了出现黑色扇形 | 需要的视场超出镜头范围 | 物理限制。调小输出视场角 |
| 装完点图标闪退 | 没开开发者模式 / 证书没信任 | 见 §0.1 |

---

## 8. 代码里埋的几个坑（已处理，别改回去）

1. **Uniform 布局用显式 16 字节槽位**，不用散装 `float` / `float2`。
   Metal 里 `float2` 对齐 8、Swift 里 `SIMD2<Float>` 也对齐 8，
   但两边各自插 padding 就可能错位 → 画面变成雪花。
   `FrameRenderer.init` 里有 `assert` 做布局自检，Debug 编译时会炸给你看。
2. **必须关掉系统内置几何畸变校正**。iPhone 会偷偷把广角畸变掰直，
   我们要的是原始像素，否则标定无从谈起。
3. **关掉 `videoStabilizationMode`**。系统增稳会裁剪 + 平移画面，
   和我们自己的补偿叠加就是双重补偿，画面会飘。
4. **必须用 `AVCaptureSession.Preset.high`**，不要 `.photo` / HDR 预设，
   否则会触发多帧合成，帧率崩、延迟抖。
5. **四元数低通，不是欧拉角低通**。理由见 §1.2。
6. **纹理池环形 + in-flight 标记**。帧率高于处理能力时直接丢帧，
   绝不阻塞摄像头线程（阻塞 = 整条管线延迟越堆越大 = 手感变泥）。
   显示用纹理也要占住槽位直到显示 command buffer 结束，否则会撕裂。
7. **`q` 和 `−q` 是同一个旋转**。所有算角度差的地方都不能直接减分量，
   代码里用姿态矩阵的轴向量投影到水平面算 yaw，绕开双覆盖问题。
8. **`CVPixelBuffer` 拷贝到纹理必须用 `copy(from:to:)` 那个重载**。
   带 `sourceBytesPerRow` 参数的版本是给 `MTLBuffer` 源用的，塞 pixel buffer 会编译不过。
9. **部署目标是 iOS 16**，所以 `.onChange` 用单参闭包版本；
   两个参数的 `onChange(of:initial:_:)` 是 iOS 17 API。
   超广角设备类型是 `.builtInUltraWideCamera`（不是 `...UltraWideAngleCamera`）。
