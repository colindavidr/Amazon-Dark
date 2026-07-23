# SDK PINNED TO 16.5 -- this is the prefs crash, not a logic bug.
# CI warns "object file was built with an incompatible arm64e ABI compiler" on
# every build. Amazon is an arm64 process, so it loads the good slice and works
# fine; Settings is arm64e and loads the broken one, which is why the pane
# faults SIGBUS at a garbage address on its FIRST call into
# Preferences.framework -- loadSpecifiersFromPlistName in v5.58, PSSpecifier
# creation in v5.55. Same symptom, same cause. CarBridgeReborn's prefs bundle
# runs on this device and pins iphone:clang:16.5:17.0; matching it produces a
# correct arm64e slice.
export TARGET = iphone:clang:16.5:17.0
export ARCHS  = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AmazonDark AmazonDarkSB

AmazonDark_FILES   = src/Tweak.xm src/ADColor.m src/ADImageKey.m
AmazonDark_CFLAGS  = -fobjc-arc -fexceptions
AmazonDark_CFLAGS += -Wno-unused-variable -Wno-unused-function
AmazonDark_CFLAGS += -Wno-deprecated-declarations -Wno-error
AmazonDark_FRAMEWORKS = UIKit Foundation WebKit CoreGraphics QuartzCore

# SpringBoard-side dark launch cover (injects ONLY into com.apple.springboard
# via AmazonDarkSB.plist). Defensive: every hook guarded, cover auto-removes.
AmazonDarkSB_FILES      = src/AmazonDarkSB.xm
AmazonDarkSB_CFLAGS     = -fobjc-arc -fexceptions -Wno-unused-variable -Wno-error
AmazonDarkSB_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore

# Bundle the official Dark Reader UMD (resources/) alongside the dylib as
# AmazonDark.bundle so the tweak can read darkreader.js at runtime.
AmazonDark_BUNDLE_RESOURCE_DIRS = Resources

# Fail fast on the Logos %orig footgun (it deletes code and still exits 0).
before-all::
	@bash scripts/lint-logos.sh

include $(THEOS_MAKE_PATH)/tweak.mk

# Preference bundle -- real controller, CBR structure.
# Viable now that CI builds on macOS: the Linux toolchain's arm64e (old ABI,
# capabilities 0x0) was what crashed Settings, not this code.
BUNDLE_NAME = ADPrefs
ADPrefs_FILES         = prefs/ADPrefsController.xm
ADPrefs_INSTALL_PATH  = /Library/PreferenceBundles
ADPrefs_FRAMEWORKS    = UIKit Foundation CoreFoundation
ADPrefs_CFLAGS        = -fobjc-arc -Wno-error -Wno-unused-variable -Wno-unused-function
ADPrefs_RESOURCE_DIRS = prefs/Resources

include $(THEOS_MAKE_PATH)/bundle.mk

after-package::
	@ls -1t packages/*.deb 2>/dev/null | head -1 | xargs -I{} echo "package ready: {}"
