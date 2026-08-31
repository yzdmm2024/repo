# Theos Makefile - 随机开启app
# 范式照 SN3extension / KeyboardPlusPro：ARCHS=arm64 arm64e → macOS 原生 clang/ld
# 产出真 FAT arm64e（带合法 LC_DYLD_CHAINED_FIXUPS，roothide/A14 加载器才接受）。
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:14.0:14.5
export THEOS_PACKAGE_SCHEME = rootless
export GO_EASY_ON_ME = 1

include $(THEOS)/makefiles/common.mk

# ===== Tweak（ElleKit / TweakInject 注入）=====
TWEAK_NAME = RandOpenApp
RandOpenApp_FILES = Tweak.xm ROARandomScheduler.m
RandOpenApp_FRAMEWORKS = UIKit Foundation
RandOpenApp_LDFLAGS = -Wl,-undefined,dynamic_lookup
RandOpenApp_CFLAGS = -fobjc-arc -fobjc-exceptions -Wno-deprecated-declarations -Wno-error
include $(THEOS_MAKE_PATH)/tweak.mk

# ===== 设置面板 PreferenceBundle =====
# 编译成 MH_DYLIB（与正常偏好 bundle 一致），由 CI 注入 layout 的 bundle 作为 CFBundleExecutable。
BUNDLE_NAME = RandOpenAppSettings
RandOpenAppSettings_FILES = ROARootListController.m
RandOpenAppSettings_INSTALL_PATH = /Library/PreferenceBundles
RandOpenAppSettings_FRAMEWORKS = UIKit Foundation
RandOpenAppSettings_CFLAGS = -fobjc-arc -fobjc-exceptions
RandOpenAppSettings_LDFLAGS = -Wl,-undefined,dynamic_lookup
include $(THEOS_MAKE_PATH)/bundle.mk