/*
 * ADColor.h — Dark Reader's dynamic-theme colour algorithm, ported to C/Obj-C.
 * ============================================================================
 * Ported from Dark Reader (https://github.com/darkreader/darkreader),
 * src/inject/dynamic-theme/modify-colors.ts and src/generators/utils/matrix.ts.
 *
 * Dark Reader is MIT licensed — Copyright (c) Dark Reader Ltd.
 * Full licence text: Resources/DARKREADER-LICENSE.
 *
 * WHY THIS EXISTS
 * ----------------------------------------------------------------------------
 * A colour *inversion* maps every pixel through 1-x. It cannot tell a background
 * from a photograph, so photos come out as negatives and you spend the rest of
 * your life enumerating image classes to un-invert them. That was v3.x.
 *
 * Dark Reader does something categorically different: it never touches pixels at
 * all. It intercepts each *declared colour* and re-maps it in HSL space, pulling
 * lightness toward a dark pole while preserving hue and saturation. Backgrounds,
 * text and borders each get their own curve, because a background wants to become
 * dark while text sitting on it wants to become light.
 *
 * The consequence that matters here: images are never a "colour", so they are
 * never modified. Image safety is structural, not a special case we maintain.
 *
 * This file is the native half of that idea. Tweak.xm feeds it every colour the
 * app assigns to a view, layer, label or border, and swaps in the result.
 */

#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef NS_ENUM(NSInteger, ADColorRole) {
    ADColorRoleBackground = 0,
    ADColorRoleForeground = 1,
    ADColorRoleBorder     = 2,
    /// For drawRect: painting, where we cannot know whether a colour is about to
    /// fill a panel or draw text. Picks the curve from the colour's own lightness:
    /// light fills darken, dark fills lighten. That preserves contrast direction
    /// instead of crushing custom-drawn text into its own background.
    ADColorRoleAuto       = 3,
};

/// Mirrors the subset of Dark Reader's `Theme` we expose in Settings.
typedef struct {
    double brightness;   // 0..150,  default 100
    double contrast;     // 0..150,  default 100
    double grayscale;    // 0..100,  default 0
    double sepia;        // 0..100,  default 0
    double bgR, bgG, bgB; // dark-scheme background pole, 0..255 (default #181a1b)
    double fgR, fgG, fgB; // dark-scheme text pole,       0..255 (default #e8e6e3)
} ADThemeConfig;

/// The live theme. Tweak.xm updates this from prefs; changing it clears the cache.
extern ADThemeConfig ADTheme;
void ADColorSetTheme(ADThemeConfig cfg);

/// Core transform. Components are 0..1. Alpha passes through untouched.
void ADModifyRGB(ADColorRole role,
                 CGFloat r,  CGFloat g,  CGFloat b,
                 CGFloat *outR, CGFloat *outG, CGFloat *outB);

/// UIColor / CGColor convenience wrappers. Both are:
///   - memoised (fixed-size open-addressed cache, no allocation in the hot path)
///   - idempotent (a colour we produced is recognised and returned unchanged, so
///     a view that re-reads and re-assigns its own colour does not drift darker
///     on every layout pass)
/// Returns nil / NULL when the input is nil, patterned, or non-RGB.
UIColor  *ADModifyUIColor(UIColor *c, ADColorRole role);
CGColorRef ADModifyCGColor(CGColorRef c, ADColorRole role) CF_RETURNS_NOT_RETAINED;

/// YES if this exact colour is one we emitted — used to short-circuit re-entry.
BOOL ADIsModifiedUIColor(UIColor *c);

/// Convenience: parse "#rrggbb" into the pole fields of a config.
void ADParseHexInto(const char *hex, double *r, double *g, double *b);

#ifdef __cplusplus
}
#endif
