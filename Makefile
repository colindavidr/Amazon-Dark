export TARGET = iphone:clang:latest:15.0
export ARCHS  = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AmazonDark

AmazonDark_FILES   = src/Tweak.xm src/ADColor.m src/ADImageKey.m
AmazonDark_CFLAGS  = -fobjc-arc -fexceptions
AmazonDark_CFLAGS += -Wno-unused-variable -Wno-unused-function
AmazonDark_CFLAGS += -Wno-deprecated-declarations -Wno-error
AmazonDark_FRAMEWORKS = UIKit Foundation WebKit CoreGraphics QuartzCore

# Bundle the official Dark Reader UMD (resources/) alongside the dylib as
# AmazonDark.bundle so the tweak can read darkreader.js at runtime.
AmazonDark_BUNDLE_RESOURCE_DIRS = Resources

# Fail fast on the Logos %orig footgun (it deletes code and still exits 0).
before-all::
	@bash scripts/lint-logos.sh

include $(THEOS_MAKE_PATH)/tweak.mk

# Preference bundle, built the CarBridgeReborn way: declared in THIS makefile
# alongside the tweak (not as a SUBPROJECTS aggregate) with RESOURCE_DIRS, and
# with no private-framework linkage. v5.56.0's executable-free bundle could not
# load at all -- Settings requires an executable -- so the compiled controller
# is back, mirroring the structure that works on this device.
BUNDLE_NAME = ADPrefs
ADPrefs_FILES         = prefs/ADPrefsController.xm
ADPrefs_INSTALL_PATH  = /Library/PreferenceBundles
ADPrefs_FRAMEWORKS    = UIKit Foundation CoreFoundation
ADPrefs_CFLAGS        = -fobjc-arc -Wno-error -Wno-unused-variable -Wno-unused-function
ADPrefs_RESOURCE_DIRS = prefs/Resources

include $(THEOS_MAKE_PATH)/bundle.mk

after-package::
	@ls -1t packages/*.deb 2>/dev/null | head -1 | xargs -I{} echo "package ready: {}"
