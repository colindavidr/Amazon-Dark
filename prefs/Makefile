export TARGET = iphone:clang:latest:15.0
export ARCHS  = arm64 arm64e
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ADPrefs

ADPrefs_FILES     = ADRootListController.m
ADPrefs_INSTALL_PATH = /Library/PreferenceBundles
ADPrefs_FRAMEWORKS   = UIKit
ADPrefs_PRIVATE_FRAMEWORKS = Preferences
ADPrefs_CFLAGS       = -fobjc-arc -Wno-error

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/AmazonDark.plist$(ECHO_END)
