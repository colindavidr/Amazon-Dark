/*
 * ADImageKey.m — corner-keyed white-background darkening for product photos.
 * ============================================================================
 * The problem this solves is genuinely different from the rest of the tweak.
 * Everywhere else we intercept a COLOUR DECLARATION and never touch a pixel, which
 * is why images have stayed pristine. But a product shot of a white item on a white
 * studio backdrop is an opaque JPEG: the "white background" is thousands of near-
 * white PIXELS inside the photograph, and a CSS/backgroundColor trick cannot reach
 * them. Darkening them means separating backdrop from product inside a raster image
 * with no alpha channel — segmentation.
 *
 * APPROACH: conservative corner-seeded flood fill (chroma key).
 *   1. Sample the four corners. Product shots are centred, so corners are almost
 *      always pure backdrop. If the corners do NOT agree on a near-white colour,
 *      this is not a white-studio shot — bail, change nothing.
 *   2. Flood fill inward from each corner, converting only pixels within a tight
 *      tolerance of the sampled backdrop colour to the dark theme colour. The fill
 *      stops at the product edge (where colour leaves tolerance), so the product —
 *      including its own white highlights, which are not connected to the border —
 *      is left exactly as photographed.
 *
 * This is deliberately cautious. It darkens obvious white catalogue backdrops and
 * declines everything ambiguous, because a wrong segmentation (holes punched in a
 * white product, or a grey halo) looks worse than an untouched white card. It is
 * gated behind a Setting and off by default.
 *
 * Cost: one pass over the pixels of images we choose to process, on a background
 * queue, cached by the source image so each image is done at most once.
 */

#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import "ADColor.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Returns a darkened copy if `img` is a white-studio-backdrop photo we can safely
/// key, or nil if it is ambiguous / not applicable (caller then leaves it alone).
/// `bgHex` is the dark colour to paint the backdrop (e.g. "#181a1b").
UIImage *ADKeyWhiteBackground(UIImage *img, const char *bgHex);

#ifdef __cplusplus
}
#endif

/// YES if `img` looks like a dark monochrome GLYPH (an icon), not a photograph:
/// small, has an alpha channel, and its opaque pixels are predominantly dark and
/// close to neutral. Such icons are invisible once the surface behind them goes
/// dark, and unlike photos they can be safely recoloured by switching them to
/// template rendering — which preserves the shape exactly and only changes the tint.
BOOL ADIsDarkGlyph(UIImage *img);
