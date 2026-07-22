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

# NO preference bundle (v5.61.0).
# Five implementations were tried -- the stock Theos compile-time subclass, a
# CBR-style runtime %subclass, a hand-built specifier list, an executable-free
# bundle, and a dladdr-resolved bundle. Every one faulted SIGBUS inside
# Settings at whatever call it reached first (loadSpecifiersFromPlistName,
# groupSpecifierWithName, then pathForResource on a bundle that had already
# resolved OK). Code that has nothing in common cannot be wrong the same way;
# the bundle binary itself is what Settings will not run here. The toggle now
# ships as layout/usr/bin/amazondark -- a shell script, nothing to validate.

after-package::
	@ls -1t packages/*.deb 2>/dev/null | head -1 | xargs -I{} echo "package ready: {}"
