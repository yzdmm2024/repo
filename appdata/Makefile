# ============================================================
# AppData — rootless 重编译，容器改用 Fila 打开
# 目标: iOS 15/16 无根越狱 (Dopamine / roothide), arm64 + arm64e
# ============================================================
# 本地:  make package THEOS_PACKAGE_SCHEME=rootless
# CI:    推送到 GitHub 后由 .github/workflows/build.yml 自动编译
# ============================================================

TARGET := iphone:clang:16.6:15.0
ARCHS := arm64 arm64e

TWEAK_NAME := AppData

# tweak 主体：AppData/Classes 下全部 .m + Logos 入口 .xm
# 注意：AppData.mm 是 AppData.xm 的 Logos 预处理产物（#line 指向 .xm），
# 若一并编译会符号重复，因此只编 .xm（Theos 会自动预处理）。
AppData_FILES = $(shell find AppData/Classes -name '*.m') \
                AppData/AppData.xm

# 前缀头里定义了 kSBApplicationShortcutItemType 等宏
AppData_CFLAGS += -fobjc-arc -IAppData -IAppData/Classes
GLOBAL_CFLAGS += -include AppData/AppData-Prefix.pch

AppData_FRAMEWORKS = UIKit Foundation CoreLocation

# 说明：SBIconController / SBFloatingDock* / LSApplicationProxy / IXAppInstallCoordinator
# 等私有类均由 Headers.h 自行声明，并在运行时用 NSClassFromString / dlopen 获取，
# 无需链接私有框架（链接反而会因 SDK 无对应 tbd 而失败）。

# 无根越狱：产物安装到 /var/jb
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET = rootless

include $(THEOS_MAKE_PATH)/tweak.mk

# 资源与注入配置随 layout/ 一起打进 deb（见 layout/var/jb/...）
