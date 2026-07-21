# Amazon Dark

True dark mode for the Amazon Shopping iOS app — a real dark theme, not a colour inversion.

Rootless jailbreak (NathanLR / ellekit), arm64 + arm64e, iOS 15+.
Built against Amazon Shopping **27.11.8**.

---

## Why v5 is a rewrite

Every v3.x build applied a `colorInvert` CAFilter to the top-level `UIWindow`, then
tried to *counter-invert* image layers back to normal. That approach fails for a
reason no amount of tuning fixes: an inversion cannot tell a background from a
photograph. Every image class must be enumerated and exempted by hand, the
counter-filters land a layout pass late, and anything missed ships as a negative.
The binary only defines **8** image-view classes, and the tweak was chasing them
one regression at a time.

v5 stops inverting anything.

| Surface | Method | Images |
|---|---|---|
| Web views (Home, Cart, product, search) | Bundled **Dark Reader** engine | Untouched by design |
| Native chrome (tab bar, nav/search bar) | Amazon's **own** native dark theme | Amazon's own assets |
| Native content (cells, sheets, RN views) | **Dark Reader colour algorithm, ported to Obj-C** | Never on the code path |

Images are safe *structurally*, not by exemption. The colour engine intercepts
colour **declarations** — `backgroundColor`, `textColor`, `tintColor`, `borderColor`.
It never touches `layer.contents`, never installs a `CAFilter`, and never sees a
`CGImage`. A photograph is not a colour, so it is never modified. There is no
allowlist left to maintain.

---

## How the colour engine works

`src/ADColor.m` is a port of Dark Reader's dynamic-theme algorithm
(`modify-colors.ts` + `matrix.ts`). Each colour is converted to HSL and re-mapped
along a curve chosen by its role:

- **Backgrounds** fall toward the dark pole (default `#181a1b`), clamped so a light
  surface lands under 40% lightness.
- **Text and tints** rise toward the light pole (default `#e8e6e3`), floored at 55%
  lightness so nothing goes muddy. Blue hues are nudged toward 220° so links stay
  readable.
- **Borders** compress toward the middle so dividers stay visible without glowing.

Hue and saturation survive the transform, so Amazon orange stays orange and link
blue stays blue — they just sit at a lightness that works on a dark surface. The
brightness/contrast/grayscale/sepia sliders are applied afterwards as a 5×5 colour
matrix, deliberately **without** Dark Reader's invert term.

The port is differential-tested against a direct transcription of the upstream
TypeScript: **bit-identical across 2,187 colour/role combinations**.

Tinting is treated as foreground, which is what keeps tab-bar glyphs visible once
the bar behind them goes dark — the exact failure that broke v3.2.1.

---

## Build

CI builds the rootless `.deb` on every push (`.github/workflows/build.yml`) and
attaches it to releases. Locally, with Theos installed:

```bash
make clean
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

The Dark Reader engine is vendored at `Resources/darkreader.js` (MIT) and installed
beside the dylib as `AmazonDark.bundle`. To refresh it:

```bash
npm pack darkreader && tar -xzO -f darkreader-*.tgz package/darkreader.js > Resources/darkreader.js
```

## Install

```bash
ssh root@<device> "rm -f /var/mobile/*.deb"
scp packages/*.deb root@<device>:/var/mobile/
ssh root@<device> "dpkg -i /var/mobile/com.colindavidr.amazondark_*.deb"
```

Then **force-quit and relaunch Amazon**. No respring — the tweak injects per-app.
Injection must be enabled for Amazon in NathanLR's app list, or the dylib never loads.

## Verify

```bash
ssh root@<device> "find /var/mobile/Containers/Data/Application -name 'AmazonDark.log' 2>/dev/null | head -1 | xargs cat"
```

Logging goes to `$TMPDIR` because a sandboxed app cannot write to `/var/mobile`.

## Settings

Settings → AmazonDark: master toggle, per-surface toggles, brightness / contrast /
grayscale / sepia, and hex background/text poles. Set the background pole to
`#000000` for OLED black. Changes apply on next foreground.

If a native screen ever looks wrong, turn off **Recolor native content** — web and
native chrome keep working independently.

---

## Notes

- `Info.plist` of the app hard-pins `UIUserInterfaceStyle = Light`. That is why every
  earlier attempt to force the trait alone kept getting clawed back; the window-level
  override in `ADForceWindowsDarkTrait` is what actually sticks.
- Amazon ships a complete native dark theme gated behind one Weblab
  (`NAVX_DARK_MODE_IOS_1283655`, default treatment `C` = off). v5 flips it client-side
  for the chrome. Server-driven SSNAP content will not return dark colour tokens for
  accounts outside the cohort — which is precisely why the local colour engine exists.
- Zero Obj-C runs in `%ctor` (raw `write()` only); all work is deferred to the main
  queue. Every hook body is wrapped in `@try/@catch`. No auto-`killall` in `postinst`.

## Credits

Colour algorithm ported from [Dark Reader](https://github.com/darkreader/darkreader)
(MIT, © Dark Reader Ltd.) — see `Resources/DARKREADER-LICENSE`.
