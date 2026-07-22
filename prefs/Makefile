export TARGET = iphone:clang:latest:15.0
export ARCHS  = arm64 arm64e
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ADPrefs

# CarBridgeReborn pattern: NO Preferences framework linkage. The old
# ADPrefs_PRIVATE_FRAMEWORKS = Preferences is what made the bundle unloadable
# in Settings on this jailbreak (dyld failure = instant Settings crash).
# Everything Preferences-related resolves at runtime inside the .xm.
ADPrefs_FILES     = ADPrefsController.xm
ADPrefs_INSTALL_PATH = /Library/PreferenceBundles
ADPrefs_FRAMEWORKS   = UIKit Foundation CoreFoundation
ADPrefs_CFLAGS       = -fobjc-arc -Wno-error -Wno-unused-variable -Wno-unused-function

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/AmazonDark.plist$(ECHO_END)
