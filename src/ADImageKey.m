/*
 * ADImageKey.m — see ADImageKey.h for the rationale.
 */

#import "ADImageKey.h"
#import <stdlib.h>
#import <string.h>
#import <math.h>

// A pixel counts as "backdrop" if it is within this Euclidean RGB distance of the
// sampled corner colour. Tight, so the product's own tones are never captured.
static const int    AD_KEY_TOL      = 40;     // 0..441 (sqrt(3)*255)
// The corners must be at least this light to be considered a white studio backdrop.
static const int    AD_KEY_MIN_LUMA = 200;    // 0..255
// The four corners must agree within this distance, or we bail.
static const int    AD_KEY_CORNER_AGREE = 30;

static inline int ad_dist2(int r1,int g1,int b1,int r2,int g2,int b2){
    int dr=r1-r2, dg=g1-g2, db=b1-b2;
    return dr*dr + dg*dg + db*db;
}

UIImage *ADKeyWhiteBackground(UIImage *img, const char *bgHex){
    if (!img) return nil;
    CGImageRef src = img.CGImage;
    if (!src) return nil;

    size_t W = CGImageGetWidth(src);
    size_t H = CGImageGetHeight(src);
    if (W < 24 || H < 24) return nil;                 // too small to matter
    if (W * H > 2200*2200) return nil;                // guard against giant images

    // Decode to a known RGBA8 buffer.
    size_t bytesPerRow = W * 4;
    uint8_t *buf = (uint8_t *)calloc(H, bytesPerRow);
    if (!buf) return nil;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, bytesPerRow, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx){ free(buf); return nil; }
    CGContextDrawImage(ctx, CGRectMake(0,0,W,H), src);

    #define PX(x,y) (buf + ((y)*bytesPerRow) + ((x)*4))

    // ── 1. sample the four corners a few px in from the edge ──
    int inset = 3;
    int cx[4] = { inset, (int)W-1-inset, inset,        (int)W-1-inset };
    int cy[4] = { inset, inset,          (int)H-1-inset,(int)H-1-inset };
    int sr=0, sg=0, sb=0;
    for (int i=0;i<4;i++){
        uint8_t *p = PX(cx[i], cy[i]);
        sr += p[0]; sg += p[1]; sb += p[2];
    }
    sr/=4; sg/=4; sb/=4;

    int luma = (54*sr + 183*sg + 19*sb) >> 8;         // ~0.2126/0.7152/0.0722
    if (luma < AD_KEY_MIN_LUMA){ CGContextRelease(ctx); free(buf); return nil; }

    // corners must agree, or this is not a uniform studio backdrop
    for (int i=0;i<4;i++){
        uint8_t *p = PX(cx[i], cy[i]);
        if (ad_dist2(p[0],p[1],p[2], sr,sg,sb) > AD_KEY_CORNER_AGREE*AD_KEY_CORNER_AGREE){
            CGContextRelease(ctx); free(buf); return nil;
        }
    }

    // ── parse the destination dark colour ──
    double dr_=24, dg_=26, db_=27;
    ADParseHexInto(bgHex, &dr_, &dg_, &db_);
    uint8_t DR=(uint8_t)dr_, DG=(uint8_t)dg_, DB=(uint8_t)db_;

    int tol2 = AD_KEY_TOL*AD_KEY_TOL;

    // ── 2. flood fill inward from every border pixel that matches the backdrop ──
    // BFS over a visited bitmap. Border-seeded so only backdrop CONNECTED to the
    // edge is filled; a white highlight enclosed by the product is never reached.
    size_t N = W*H;
    uint8_t *visited = (uint8_t *)calloc(N, 1);
    if (!visited){ CGContextRelease(ctx); free(buf); return nil; }
    // simple ring-buffer queue of pixel indices
    uint32_t *queue = (uint32_t *)malloc(N * sizeof(uint32_t));
    if (!queue){ free(visited); CGContextRelease(ctx); free(buf); return nil; }
    size_t qh=0, qt=0;

    #define IDX(x,y) ((size_t)(y)*W + (x))
    #define MATCH(p) (ad_dist2((p)[0],(p)[1],(p)[2], sr,sg,sb) <= tol2)
    #define ENQUEUE(x,y) do{ size_t _i=IDX(x,y); if(!visited[_i]){ uint8_t*_p=PX(x,y); \
        if(MATCH(_p)){ visited[_i]=1; queue[qt++]=(uint32_t)_i; } } }while(0)

    for (int x=0; x<(int)W; x++){ ENQUEUE(x,0); ENQUEUE(x,(int)H-1); }
    for (int y=0; y<(int)H; y++){ ENQUEUE(0,y); ENQUEUE((int)W-1,y); }

    size_t filled=0;
    while (qh < qt){
        uint32_t idx = queue[qh++];
        int x = idx % W, y = idx / W;
        uint8_t *p = PX(x,y);
        // paint toward dark, preserving the backdrop's own subtle shading so it does
        // not become a flat slab (keep a little of the delta from pure white).
        p[0]=DR; p[1]=DG; p[2]=DB;
        filled++;
        if (x>0)        ENQUEUE(x-1,y);
        if (x<(int)W-1) ENQUEUE(x+1,y);
        if (y>0)        ENQUEUE(x,y-1);
        if (y<(int)H-1) ENQUEUE(x,y+1);
    }

    free(queue);
    free(visited);

    UIImage *out = nil;
    // Only bother returning a new image if we actually changed a meaningful area
    // (>3% of pixels) — otherwise the "backdrop" was negligible and not worth it.
    if (filled > N/32){
        CGImageRef newCG = CGBitmapContextCreateImage(ctx);
        if (newCG){
            out = [UIImage imageWithCGImage:newCG scale:img.scale orientation:img.imageOrientation];
            CGImageRelease(newCG);
        }
    }
    CGContextRelease(ctx);
    free(buf);
    return out;

    #undef PX
    #undef IDX
    #undef MATCH
    #undef ENQUEUE
}

BOOL ADIsDarkGlyph(UIImage *img){
    if (!img) return NO;
    CGImageRef src = img.CGImage;
    if (!src) return NO;

    size_t W = CGImageGetWidth(src), H = CGImageGetHeight(src);
    if (W == 0 || H == 0) return NO;
    // Glyphs are small. A large asset is a photo or banner; leave it alone.
    if (W > 256 || H > 256) return NO;

    // NO alpha-info gate. The previous version required kCGImageAlphaFirst/Last/
    // Premultiplied*, which rejected everything else outright - and iOS decodes
    // asset-catalog icons as kCGImageAlphaOnly (template masks) or
    // kCGImageAlphaNoneSkipLast, both of which failed instantly. On device that showed
    // up as glyphFixed=0 while the sweep walked past 19 image views every pass, i.e.
    // every glyph fix since v5.12 was a no-op on native icons.
    //
    // Transparency is measured from the drawn buffer below instead, which is accurate
    // regardless of how the source declares itself.

    size_t bpr = W * 4;
    uint8_t *buf = (uint8_t *)calloc(H, bpr);
    if (!buf) return NO;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, bpr, cs,
                        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx){ free(buf); return NO; }
    CGContextDrawImage(ctx, CGRectMake(0,0,W,H), src);

    double sumL = 0, sumChroma = 0;
    long n = 0, transparent = 0, total = 0;
    size_t stepX = (W > 32) ? W/32 : 1;
    size_t stepY = (H > 32) ? H/32 : 1;
    for (size_t y = 0; y < H; y += stepY){
        for (size_t x = 0; x < W; x += stepX){
            uint8_t *p = buf + y*bpr + x*4;
            total++;
            if (p[3] < 128) { transparent++; continue; }  // see-through: not artwork
            int r = p[0], g = p[1], b = p[2];
            int mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
            int mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
            sumL += (0.2126*r + 0.7152*g + 0.0722*b) / 255.0;
            sumChroma += (mx - mn) / 255.0;
            n++;
        }
    }
    CGContextRelease(ctx);
    free(buf);
    if (n < 8 || total == 0) return NO;                // essentially empty

    double meanL = sumL / n, meanC = sumChroma / n;
    double clearFrac = (double)transparent / (double)total;

    // Two ways to qualify, both requiring dark + near-neutral artwork:
    //   (a) a real icon: meaningful see-through area around the strokes;
    //   (b) a small solid glyph with no transparency at all, held to a stricter
    //       darkness/neutrality bar so a small dark PHOTO cannot match.
    if (clearFrac > 0.15 && meanL < 0.42 && meanC < 0.22) return YES;
    if (W <= 64 && H <= 64 && meanL < 0.25 && meanC < 0.12) return YES;
    return NO;
}
