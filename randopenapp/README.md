# 随机开启app (RandOpenApp)

一个用于 **roothide (Relaxin) rootless 越狱** 的 iOS Tweak：
在设置的时间段内，随机挑选一个时刻自动打开指定的 App，**每天最多一次**。
可在 "设置 → 随机开启app" 中配置目标 App 与时间段。

## 项目结构

```
randopenapp/
├── Makefile                          # Theos 构建脚本
├── control                           # deb 元信息
├── Tweak.xm                          # 入口（注入 SpringBoard 发起调度）
├── ROARandomScheduler.h/.m           # 随机调度引擎
├── ROARootListController.m           # 设置面板控制器（选App）
└── layout/
    ├── Library/MobileSubstrate/DynamicLibraries/
    │   ├── RandOpenApp.dylib         # (编译生成)
    │   └── RandOpenApp.plist         # Filter → 只注 SpringBoard
    ├── Library/PreferenceLoader/Preferences/RandOpenApp.plist   # 设置入口
    └── Library/PreferenceBundles/RandOpenAppSettings.bundle/    # 设置面板
```

## 编译所需环境（Windows 上先搭 Theos）

tweak 只能交叉编译成 iOS 二进制。你电脑上目前没装 Theos。推荐二选一：

### 方式 A：Windows + WSL + Theos（全部免费）
在 WSL(Ubuntu) 里装 Theos，参考官方：
> https://theos.dev/docs/installation-macos  （适用于 Linux 的步骤）

```bash
# 在 WSL 中
git clone --recursive https://github.com/theos/theos.git ~/theos
export THEOS=~/theos
sudo apt install clang ldid dpkg-dev fakeroot
```

### 方式 B：一台 macOS + Theos（有 Mac 的话最省事）
```bash
git clone --recursive https://github.com/theos/theos.git ~/theos
export THEOS=~/theos
brew install ldid xz
```

## 编译

```bash
cd randopenapp
export THEOS=~/theos
export ARCHS="arm64 arm64e"
export THEOS_PACKAGE_SCHEME=roothide
make clean
make package FINALPACKAGE=1
```

产物在 `packages/com.roa.randopenapp_1.0.0_iphoneos-arm64e.deb`

## 安装

把生成的 `.deb` 传到手机（例如通过 Sileo 的文件，或 Filza 直接打开），
或用 VPROP/SSH：
```bash
make install   # 需先 export THEOS_DEVICE_IP=<手机IP>
```
装完在 Sileo 里"重启 SpringBoard"即可生效。

## 使用

1. 打开 **设置**，找到 **随机开启app**
2. 开启"启用随机开启"
3. 点"选择要随机开启的App"，从列表选（或手动填 Bundle ID）
4. 设开始/结束的小时和分钟
5. （可选）开启"仅限工作日"
6. 重启 SpringBoard

## 行为说明

- 到达站点时若当前时间已在时间段内，会随机选一个人"之后1分钟~窗口末尾"的时刻
- 到点后用 `LSApplicationWorkspace` 拉起目标 App
- 每天记一次"已开"标记，第二天自动重置

## 注意事项 / 限制

1. **手机必须一直亮屏或常驻**：iOS 后台会挂起 SpringBoard 前端进程？实际 SpringBoard 常驻，但若屏幕关闭久了，进程仍在。本 Tweak 注入 SpringBoard，可靠性接近系统级。
2. 若目标 App 被系统判定为"不允许后台拉起"，可能受 iOS 限制（一般越狱可绕过）。
3. 改配置后需**重启 SpringBoard** 让插件重新读取。