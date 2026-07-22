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

# NO preference-bundle subproject any more (v5.56.0).
# The pane is now a plist-only bundle staged straight from layout/ with NO
# executable. Three separate crash-report-driven attempts at a compiled
# PSListController subclass all took Settings down with them; a bundle that
# contains no code of ours cannot. Settings loads its own PSListController and
# reads our Root.plist -- the toggle writes to the same defaults domain the
# tweak reads, so nothing else changes.

after-package::
	@ls -1t packages/*.deb 2>/dev/null | head -1 | xargs -I{} echo "package ready: {}"
