include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SafariToolPrefs

SafariToolPrefs_FILES = SafariToolPrefsRootListController.m
SafariToolPrefs_INSTALL_PATH = /Library/PreferenceBundles
SafariToolPrefs_FRAMEWORKS = UIKit
SafariToolPrefs_PRIVATE_FRAMEWORKS = Preferences
SafariToolPrefs_CFLAGS = -fobjc-arc
SafariToolPrefs_LDFLAGS = -F$(THEOS)/sdks/iPhoneOS16.5.sdk/System/Library/PrivateFrameworks

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/SafariToolPrefs.plist$(ECHO_END)
