export TARGET := iphone:clang:latest:16.0
export ARCHS = arm64e
export THEOS_PACKAGE_SCHEME = roothide
INSTALL_TARGET_PROCESSES = MobileSafari

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SafariTool

SafariTool_FILES = Tweak.xm
SafariTool_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
SafariTool_FRAMEWORKS = UIKit WebKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += SafariToolPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk
