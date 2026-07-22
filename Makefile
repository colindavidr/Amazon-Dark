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

# Preference bundle with an INTENTIONALLY EMPTY executable (v5.63.0).
# Settings will not load a bundle that has no executable, but every bundle
# that contained our code faulted SIGBUS inside Settings. dlopen always
# succeeded though -- the ctor logged every time -- so the executable exists
# to satisfy the loader and contains nothing. NSPrincipalClass points at
# Apple's PSListController, which renders Root.plist itself.
BUNDLE_NAME = ADPrefs
ADPrefs_FILES         = prefs/empty.m
ADPrefs_INSTALL_PATH  = /Library/PreferenceBundles
ADPrefs_FRAMEWORKS    = Foundation
ADPrefs_CFLAGS        = -Wno-error
ADPrefs_RESOURCE_DIRS = prefs/Resources

include $(THEOS_MAKE_PATH)/bundle.mk

after-package::
	@ls -1t packages/*.deb 2>/dev/null | head -1 | xargs -I{} echo "package ready: {}"
