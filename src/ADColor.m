/*
 * ADColor.m — Dark Reader's dynamic-theme colour algorithm, ported to C/Obj-C.
 * Ported from Dark Reader (MIT, Copyright (c) Dark Reader Ltd.) — see ADColor.h
 * and Resources/DARKREADER-LICENSE.
 */

#import "ADColor.h"
#import <objc/runtime.h>
#import <math.h>
#import <string.h>
#import <stdint.h>
#import <stdio.h>

ADThemeConfig ADTheme = {
    .brightness = 100, .contrast = 100, .grayscale = 0, .sepia = 0,
    .bgR = 24,  .bgG = 26,  .bgB = 27,     // #181a1b — Dark Reader's default background
    .fgR = 232, .fgG = 230, .fgB = 227,    // #e8e6e3 — Dark Reader's default text
};

// ─── small helpers ────────────────────────────────────────────────────────────────
static inline double ADScale(double x, double inLow, double inHigh, double outLow, double outHigh) {
    if (inHigh == inLow) return outLow;
    return (x - inLow) * (outHigh - outLow) / (inHigh - inLow) + outLow;
}
static inline double ADClamp(double x, double lo, double hi) {
    return x < lo ? lo : (x > hi ? hi : x);
}

typedef struct { double h, s, l; } ADHSL;

static ADHSL ADRGBToHSL(double r, double g, double b) {   // inputs 0..1
    double max = fmax(r, fmax(g, b));
    double min = fmin(r, fmin(g, b));
    double c   = max - min;
    double h = 0.0;
    if (c == 0.0)        h = 0.0;
    else if (max == r)   h = 60.0 * fmod(((g - b) / c), 6.0);
    else if (max == g)   h = 60.0 * (((b - r) / c) + 2.0);
    else                 h = 60.0 * (((r - g) / c) + 4.0);
    if (h < 0.0) h += 360.0;
    double l = (max + min) / 2.0;
    double s = (c == 0.0) ? 0.0 : (c / (1.0 - fabs(2.0 * l - 1.0)));
    ADHSL out = { h, ADClamp(s, 0.0, 1.0), l };
    return out;
}

static void ADHSLToRGB(ADHSL hsl, double *r, double *g, double *b) {
    double h = fmod(fmod(hsl.h, 360.0) + 360.0, 360.0);
    double s = ADClamp(hsl.s, 0.0, 1.0);
    double l = ADClamp(hsl.l, 0.0, 1.0);
    double c  = (1.0 - fabs(2.0 * l - 1.0)) * s;
    double x  = c * (1.0 - fabs(fmod(h / 60.0, 2.0) - 1.0));
    double m  = l - c / 2.0;
    double rr = 0, gg = 0, bb = 0;
    if      (h <  60) { rr = c; gg = x; bb = 0; }
    else if (h < 120) { rr = x; gg = c; bb = 0; }
    else if (h < 180) { rr = 0; gg = c; bb = x; }
    else if (h < 240) { rr = 0; gg = x; bb = c; }
    else if (h < 300) { rr = x; gg = 0; bb = c; }
    else              { rr = c; gg = 0; bb = x; }
    *r = rr + m; *g = gg + m; *b = bb + m;
}

// ─── Dark Reader's HSL curves ─────────────────────────────────────────────────────
// Faithful ports of modifyBgHSL / modifyFgHSL / modifyBorderHSL.

static const double AD_MAX_BG_LIGHTNESS = 0.4;
static const double AD_MIN_FG_LIGHTNESS = 0.55;

static ADHSL ADModifyBgHSL(ADHSL in, ADHSL pole) {
    BOOL isDark    = in.l < 0.5;
    BOOL isBlue    = in.h > 200 && in.h < 280;
    BOOL isNeutral = in.s < 0.12 || (in.l > 0.8 && isBlue);

    if (isDark) {
        double lx = ADScale(in.l, 0, 0.5, 0, AD_MAX_BG_LIGHTNESS);
        if (isNeutral) { ADHSL o = { pole.h, pole.s, lx }; return o; }
        ADHSL o = { in.h, in.s, lx }; return o;
    }

    double lx = ADScale(in.l, 0.5, 1, AD_MAX_BG_LIGHTNESS, pole.l);
    if (isNeutral) { ADHSL o = { pole.h, pole.s, lx }; return o; }

    double hx = in.h;
    BOOL isYellow = in.h > 60 && in.h < 180;
    if (isYellow) {
        if (in.h > 120) hx = ADScale(in.h, 120, 180, 135, 180);   // closer to green
        else            hx = ADScale(in.h, 60, 120, 60, 105);
    }
    // Pull down lightness in the muddy low-yellow band.
    if (hx > 40 && hx < 80) lx *= 0.75;

    ADHSL o = { hx, in.s, lx }; return o;
}

static inline double ADModifyBlueFgHue(double hue) { return ADScale(hue, 205, 245, 205, 220); }

static ADHSL ADModifyFgHSL(ADHSL in, ADHSL pole) {
    BOOL isLight   = in.l > 0.5;
    BOOL isNeutral = in.l < 0.2 || in.s < 0.24;
    BOOL isBlue    = !isNeutral && in.h > 205 && in.h < 245;

    if (isLight) {
        double lx = ADScale(in.l, 0.5, 1, AD_MIN_FG_LIGHTNESS, pole.l);
        if (isNeutral) { ADHSL o = { pole.h, pole.s, lx }; return o; }
        double hx = isBlue ? ADModifyBlueFgHue(in.h) : in.h;
        ADHSL o = { hx, in.s, lx }; return o;
    }

    if (isNeutral) {
        double lx = ADScale(in.l, 0, 0.5, pole.l, AD_MIN_FG_LIGHTNESS);
        ADHSL o = { pole.h, pole.s, lx }; return o;
    }

    double hx = in.h, lx;
    if (isBlue) {
        hx = ADModifyBlueFgHue(in.h);
        lx = ADScale(in.l, 0, 0.5, pole.l, fmin(1.0, AD_MIN_FG_LIGHTNESS + 0.05));
    } else {
        lx = ADScale(in.l, 0, 0.5, pole.l, AD_MIN_FG_LIGHTNESS);
    }
    ADHSL o = { hx, in.s, lx }; return o;
}

static ADHSL ADModifyBorderHSL(ADHSL in, ADHSL poleFg, ADHSL poleBg) {
    BOOL isDark    = in.l < 0.5;
    BOOL isNeutral = in.l < 0.2 || in.s < 0.24;
    double hx = in.h, sx = in.s;
    if (isNeutral) {
        if (isDark) { hx = poleFg.h; sx = poleFg.s; }
        else        { hx = poleBg.h; sx = poleBg.s; }
    }
    double lx = ADScale(in.l, 0, 1, 0.5, 0.2);
    ADHSL o = { hx, sx, lx }; return o;
}

// ─── brightness / contrast / grayscale / sepia (5×5 colour matrix) ────────────────
// Dark Reader builds this with mode forced to 0, i.e. WITHOUT the invert term — the
// darkening has already happened in HSL space. This stage is purely the user's
// aesthetic sliders. Keeping the invert out is what stops this from becoming an
// inversion tweak again.

typedef double ADMat[5][5];

static void ADMatIdentity(ADMat m) {
    memset(m, 0, sizeof(ADMat));
    for (int i = 0; i < 5; i++) m[i][i] = 1.0;
}
static void ADMatMul(const ADMat a, const ADMat b, ADMat out) {
    ADMat t; memset(t, 0, sizeof(ADMat));
    for (int i = 0; i < 5; i++)
        for (int j = 0; j < 5; j++) {
            double s = 0;
            for (int k = 0; k < 5; k++) s += a[i][k] * b[k][j];
            t[i][j] = s;
        }
    memcpy(out, t, sizeof(ADMat));
}

static void ADBuildFilterMatrix(ADMat out) {
    ADMat m; ADMatIdentity(m);

    if (ADTheme.sepia != 0) {
        double v = ADTheme.sepia / 100.0, iv = 1.0 - v;
        ADMat s; ADMatIdentity(s);
        s[0][0] = 0.393 + 0.607 * iv; s[0][1] = 0.769 - 0.769 * iv; s[0][2] = 0.189 - 0.189 * iv;
        s[1][0] = 0.349 - 0.349 * iv; s[1][1] = 0.686 + 0.314 * iv; s[1][2] = 0.168 - 0.168 * iv;
        s[2][0] = 0.272 - 0.272 * iv; s[2][1] = 0.534 - 0.534 * iv; s[2][2] = 0.131 + 0.869 * iv;
        ADMatMul(m, s, m);
    }
    if (ADTheme.grayscale != 0) {
        double v = ADTheme.grayscale / 100.0, iv = 1.0 - v;
        ADMat g; ADMatIdentity(g);
        g[0][0] = 0.2126 + 0.7874 * iv; g[0][1] = 0.7152 - 0.7152 * iv; g[0][2] = 0.0722 - 0.0722 * iv;
        g[1][0] = 0.2126 - 0.2126 * iv; g[1][1] = 0.7152 + 0.2848 * iv; g[1][2] = 0.0722 - 0.0722 * iv;
        g[2][0] = 0.2126 - 0.2126 * iv; g[2][1] = 0.7152 - 0.7152 * iv; g[2][2] = 0.0722 + 0.9278 * iv;
        ADMatMul(m, g, m);
    }
    if (ADTheme.contrast != 100) {
        double v = ADTheme.contrast / 100.0, t = (1.0 - v) / 2.0;
        ADMat c; ADMatIdentity(c);
        c[0][0] = v; c[0][4] = t;
        c[1][1] = v; c[1][4] = t;
        c[2][2] = v; c[2][4] = t;
        ADMatMul(m, c, m);
    }
    if (ADTheme.brightness != 100) {
        double v = ADTheme.brightness / 100.0;
        ADMat b; ADMatIdentity(b);
        b[0][0] = v; b[1][1] = v; b[2][2] = v;
        ADMatMul(m, b, m);
    }
    memcpy(out, m, sizeof(ADMat));
}

// Cached matrix; rebuilt only when the theme changes.
static ADMat gFilter;
static BOOL  gFilterBuilt = NO;

static void ADApplyMatrix(double *r, double *g, double *b) {
    if (ADTheme.brightness == 100 && ADTheme.contrast == 100 &&
        ADTheme.grayscale  == 0   && ADTheme.sepia    == 0) return;   // fast path
    if (!gFilterBuilt) { ADBuildFilterMatrix(gFilter); gFilterBuilt = YES; }
    double in[5] = { *r, *g, *b, 1.0, 1.0 };
    double o[3];
    for (int i = 0; i < 3; i++) {
        double s = 0;
        for (int k = 0; k < 5; k++) s += gFilter[i][k] * in[k];
        o[i] = s;
    }
    *r = ADClamp(o[0], 0.0, 1.0);
    *g = ADClamp(o[1], 0.0, 1.0);
    *b = ADClamp(o[2], 0.0, 1.0);
}

// ─── the transform ────────────────────────────────────────────────────────────────
void ADModifyRGB(ADColorRole role,
                 CGFloat r, CGFloat g, CGFloat b,
                 CGFloat *outR, CGFloat *outG, CGFloat *outB) {
    ADHSL in     = ADRGBToHSL(r, g, b);
    ADHSL poleBg = ADRGBToHSL(ADTheme.bgR / 255.0, ADTheme.bgG / 255.0, ADTheme.bgB / 255.0);
    ADHSL poleFg = ADRGBToHSL(ADTheme.fgR / 255.0, ADTheme.fgG / 255.0, ADTheme.fgB / 255.0);

    // Auto: decide by lightness before dispatching.
    if (role == ADColorRoleAuto) {
        ADHSL probe = ADRGBToHSL(r, g, b);
        role = (probe.l < 0.5) ? ADColorRoleForeground : ADColorRoleBackground;
    }

    ADHSL mod;
    switch (role) {
        case ADColorRoleForeground: mod = ADModifyFgHSL(in, poleFg);          break;
        case ADColorRoleBorder:     mod = ADModifyBorderHSL(in, poleFg, poleBg); break;
        case ADColorRoleBackground:
        default:                    mod = ADModifyBgHSL(in, poleBg);          break;
    }

    double rr, gg, bb;
    ADHSLToRGB(mod, &rr, &gg, &bb);
    ADApplyMatrix(&rr, &gg, &bb);
    *outR = (CGFloat)rr; *outG = (CGFloat)gg; *outB = (CGFloat)bb;
}

// ─── memoisation + idempotency ────────────────────────────────────────────────────
// Open-addressed, fixed-size, allocation-free. setBackgroundColor: is called on
// every cell reuse during a fast scroll, so this path must not allocate or lock.

#define AD_CACHE_BITS 13
#define AD_CACHE_SIZE (1u << AD_CACHE_BITS)      // 8192 slots
#define AD_CACHE_MASK (AD_CACHE_SIZE - 1u)

typedef struct { uint32_t key; uint32_t val; uint8_t used; } ADCacheSlot;
static ADCacheSlot gCache[AD_CACHE_SIZE];

// Colours we produced. Recognising our own output is what makes the hooks safe to
// re-enter: a view that reads its backgroundColor and writes it back unchanged
// must not be darkened a second time.
static ADCacheSlot gOutSet[AD_CACHE_SIZE];

static inline uint32_t ADPack(CGFloat r, CGFloat g, CGFloat b, ADColorRole role) {
    uint32_t ri = (uint32_t)ADClamp(round(r * 255.0), 0, 255);
    uint32_t gi = (uint32_t)ADClamp(round(g * 255.0), 0, 255);
    uint32_t bi = (uint32_t)ADClamp(round(b * 255.0), 0, 255);
    return (ri << 24) | (gi << 16) | (bi << 8) | ((uint32_t)role & 0xFF);
}
static inline uint32_t ADHash(uint32_t k) {          // Knuth multiplicative
    return (k * 2654435761u) >> (32 - AD_CACHE_BITS);
}
static BOOL ADCacheGet(ADCacheSlot *tbl, uint32_t key, uint32_t *out) {
    uint32_t i = ADHash(key);
    for (uint32_t p = 0; p < 8; p++) {
        ADCacheSlot *s = &tbl[(i + p) & AD_CACHE_MASK];
        if (!s->used) return NO;
        if (s->key == key) { if (out) *out = s->val; return YES; }
    }
    return NO;
}
static void ADCachePut(ADCacheSlot *tbl, uint32_t key, uint32_t val) {
    uint32_t i = ADHash(key);
    for (uint32_t p = 0; p < 8; p++) {
        ADCacheSlot *s = &tbl[(i + p) & AD_CACHE_MASK];
        if (!s->used || s->key == key) { s->key = key; s->val = val; s->used = 1; return; }
    }
    ADCacheSlot *s = &tbl[i & AD_CACHE_MASK];        // evict on full probe run
    s->key = key; s->val = val; s->used = 1;
}

void ADColorSetTheme(ADThemeConfig cfg) {
    ADTheme = cfg;
    gFilterBuilt = NO;
    memset(gCache,  0, sizeof(gCache));
    memset(gOutSet, 0, sizeof(gOutSet));
}

static BOOL ADRGBAOf(UIColor *c, CGFloat *r, CGFloat *g, CGFloat *b, CGFloat *a) {
    if (!c) return NO;
    if ([c getRed:r green:g blue:b alpha:a]) return YES;
    CGFloat w, wa;
    if ([c getWhite:&w alpha:&wa]) { *r = *g = *b = w; *a = wa; return YES; }
    return NO;
}

static const void *kADModifiedKey = &kADModifiedKey;

BOOL ADIsModifiedUIColor(UIColor *c) {
    if (!c) return NO;
    if (objc_getAssociatedObject(c, kADModifiedKey)) return YES;
    CGFloat r, g, b, a;
    if (!ADRGBAOf(c, &r, &g, &b, &a)) return NO;
    // Role byte is zeroed here: an emitted colour is recognised regardless of which
    // role produced it, which is what we want for re-entry safety.
    return ADCacheGet(gOutSet, ADPack(r, g, b, 0) & 0xFFFFFF00u, NULL);
}

UIColor *ADModifyUIColor(UIColor *c, ADColorRole role) {
    if (!c) return nil;
    CGFloat r, g, b, a;
    if (!ADRGBAOf(c, &r, &g, &b, &a)) return nil;      // pattern / unsupported space
    if (a <= 0.001) return nil;                        // fully transparent: nothing to do
    if (ADIsModifiedUIColor(c)) return nil;            // already ours

    // Resolve Auto up-front so the memo key matches the curve actually used.
    if (role == ADColorRoleAuto) {
        ADHSL probe = ADRGBToHSL(r, g, b);
        role = (probe.l < 0.5) ? ADColorRoleForeground : ADColorRoleBackground;
    }

    // SCRIM GUARD. A partially transparent LIGHT fill can be an overlay sitting on
    // top of imagery — a gradient scrim over a hero shot, a press-state highlight,
    // a fade at the edge of a carousel. Flipping those to a dark fill does not
    // "darken the background", it drops a black veil over the picture.
    //
    // But translucent CHROME (nav bars, search fields, sheet backdrops) lives in the
    // same alpha range and absolutely must darken, so the first version of this guard
    // was far too broad and left the top bar light. Narrowed to the case that
    // actually indicates an image overlay: quite transparent AND near-white.
    if (role == ADColorRoleBackground && a < 0.35){
        CGFloat lum = 0.2126*r + 0.7152*g + 0.0722*b;
        if (lum > 0.80) return nil;
    }

    uint32_t key = ADPack(r, g, b, role);
    uint32_t packed;
    CGFloat nr, ng, nb;
    if (ADCacheGet(gCache, key, &packed)) {
        nr = ((packed >> 24) & 0xFF) / 255.0;
        ng = ((packed >> 16) & 0xFF) / 255.0;
        nb = ((packed >>  8) & 0xFF) / 255.0;
    } else {
        ADModifyRGB(role, r, g, b, &nr, &ng, &nb);
        uint32_t outKey = ADPack(nr, ng, nb, role);
        ADCachePut(gCache,  key, outKey);
        ADCachePut(gOutSet, outKey & 0xFFFFFF00u, 1);
    }

    UIColor *out = [UIColor colorWithRed:nr green:ng blue:nb alpha:a];
    objc_setAssociatedObject(out, kADModifiedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return out;
}

CGColorRef ADModifyCGColor(CGColorRef c, ADColorRole role) {
    if (!c) return NULL;
    size_t n = CGColorGetNumberOfComponents(c);
    const CGFloat *comp = CGColorGetComponents(c);
    if (!comp) return NULL;

    CGFloat r, g, b, a;
    if (n == 4)      { r = comp[0]; g = comp[1]; b = comp[2]; a = comp[3]; }
    else if (n == 2) { r = g = b = comp[0];                    a = comp[1]; }
    else return NULL;

    if (a <= 0.001) return NULL;
    if (ADCacheGet(gOutSet, ADPack(r, g, b, 0) & 0xFFFFFF00u, NULL)) return NULL;

    uint32_t key = ADPack(r, g, b, role);
    uint32_t packed;
    CGFloat nr, ng, nb;
    if (ADCacheGet(gCache, key, &packed)) {
        nr = ((packed >> 24) & 0xFF) / 255.0;
        ng = ((packed >> 16) & 0xFF) / 255.0;
        nb = ((packed >>  8) & 0xFF) / 255.0;
    } else {
        ADModifyRGB(role, r, g, b, &nr, &ng, &nb);
        uint32_t outKey = ADPack(nr, ng, nb, role);
        ADCachePut(gCache,  key, outKey);
        ADCachePut(gOutSet, outKey & 0xFFFFFF00u, 1);
    }
    // Autoreleased via UIColor so callers need not manage lifetime.
    return [UIColor colorWithRed:nr green:ng blue:nb alpha:a].CGColor;
}

void ADParseHexInto(const char *hex, double *r, double *g, double *b) {
    if (!hex) return;
    if (*hex == '#') hex++;
    unsigned int ri = 0, gi = 0, bi = 0;
    if (strlen(hex) >= 6 && sscanf(hex, "%02x%02x%02x", &ri, &gi, &bi) == 3) {
        *r = ri; *g = gi; *b = bi;
    }
}
