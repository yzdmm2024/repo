# Theos Makefile - 随机开启app
#
# 使用方法（需要在已配置好 Theos 的 macOS/Linux 编译环境）:
#   export THEOS=~/theos        # 指向你的 Theos 安装目录
#   export THEOS_DEVICE_IP=      # (可选) 自动安装到设备
#   make package                # 生成 .deb
#   make package FINALPACKAGE=1 # 生成发布版 .deb (分包去重)
#
# 说明：本工程按 roothide (Relaxin) rootless 布局编写，
# 使用 arm64e 架构，路径均指向 /var/jb。

export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:14.0
# rootless 越狱路径前缀（roothide / Dopamine 标准值）
export THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

Bundle_LIBRARY_FILES = 

# ===== Tweak =====
TWEAK_NAME = RandOpenApp
RandOpenApp_FILES = Tweak.xm ROARandomScheduler.m
RandOpenApp_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations
RandOpenApp_LDFLAGS =
RandOpenApp_PRIVATE_FRAMEWORKS = SpringBoardServices MobileCoreServices

include $(THEOS_MAKE_PATH)/tweak.mk

# ===== Preference Bundle =====
BUNDLE_NAME = RandOpenAppSettings
RandOpenAppSettings_FILES = ROARootListController.m
RandOpenAppSettings_INSTALL_PATH = /Library/PreferenceBundles
RandOpenAppSettings_PRIVATE_FRAMEWORKS = Preferences
RandOpenAppSettings_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk

# ===== 过滤（只注 SpringBoard）=====
# layout 中已放置 Filter.plist