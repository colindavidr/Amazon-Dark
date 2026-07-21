#!/usr/bin/env bash
#
# lint-logos.sh — catch the Logos %orig footgun before it reaches a build.
#
# THE BUG THIS EXISTS TO PREVENT
# ------------------------------------------------------------------------------
# Logos silently discards any code that follows %orig on the SAME LINE.
#
#     - (void)viewDidAppear:(BOOL)a { %orig; ADDarkenSplash(self); }
#
# preprocesses to a function whose body is just the orig call: the trailing
# statement AND the closing brace are deleted. Logos still exits 0. The damage
# only surfaces later as clang's "function definition is not allowed here" and
# "expected '}'", reported hundreds of lines away at whatever hook happens to
# follow — which sends you debugging the wrong code entirely.
#
# The same applies to the parenthesised form, where Logos does at least error:
#
#     %orig(m); return;      -> "Invalid argument structure in %orig"
#
# Both variants cost this project a CI cycle. The rule that avoids both:
#
#     %orig must be the last thing on its line.
#
# Usage: scripts/lint-logos.sh [files...]   (defaults to src/*.xm)
set -uo pipefail

files=("$@")
if [ ${#files[@]} -eq 0 ]; then
    shopt -s nullglob
    files=(src/*.xm src/*.xmi)
fi
[ ${#files[@]} -eq 0 ] && { echo "lint-logos: no .xm files found"; exit 0; }

fail=0
for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    # Strip // comments, then find %orig followed by a ';' that still has
    # non-whitespace after it on the same line.
    while IFS=: read -r lineno content; do
        [ -z "${lineno:-}" ] && continue
        echo "  $f:$lineno: code follows %orig on the same line"
        echo "      $(echo "$content" | sed 's/^[[:space:]]*//')"
        fail=1
    done < <(
        sed 's://.*::' "$f" \
        | grep -nE '%orig(\([^)]*\))?[[:space:]]*;[[:space:]]*[^[:space:]]' \
        || true
    )

    # Logos's %orig argument tokenizer also chokes on a nested call inside the
    # parens, e.g. %orig(foo(x)) — resolve to a local and pass that instead.
    while IFS=: read -r lineno content; do
        [ -z "${lineno:-}" ] && continue
        echo "  $f:$lineno: %orig has a nested call in its arguments"
        echo "      $(echo "$content" | sed 's/^[[:space:]]*//')"
        fail=1
    done < <(
        sed 's://.*::' "$f" \
        | grep -nE '%orig\([^)]*\([^)]*\)' \
        || true
    )
done


# ── header linkage guard ──────────────────────────────────────────────────────
# Tweak.xm compiles as Objective-C++ while the helper .m files compile as plain
# Objective-C. A declaration that sits OUTSIDE a header's extern "C" block is
# therefore mangled by the C++ side and unmangled by the C side, producing an
# undefined symbol at LINK time. clang -fsyntax-only never links, so this class of
# break passes every syntax check and only fails in CI. Catch it here instead.
for h in src/*.h; do
    [ -f "$h" ] || continue
    grep -q 'extern "C"' "$h" || continue
    # find function declarations that appear after the LAST closing brace of the
    # extern "C" block
    close_line=$(grep -n '^}' "$h" | tail -1 | cut -d: -f1)
    [ -z "$close_line" ] && continue
    stray=$(tail -n "+$((close_line+1))" "$h" | grep -nE '^[A-Za-z_].*\(.*\);' || true)
    if [ -n "$stray" ]; then
        echo "  $h: declaration(s) outside the extern \"C\" block —"
        echo "$stray" | sed 's/^/      /'
        echo "      These will link-fail from Objective-C++. Move them inside the block."
        fail=1
    fi
done


# ── quote-before-comment guard ────────────────────────────────────────────────
# A stray " in front of a // comment turns that comment into an unterminated
# string literal. Two consecutive builds died on exactly this, and it is invisible
# to every other check here: Logos preprocesses it happily, the lint regexes above
# pass, and it only surfaces as a clang "expected ']'" pointing at a bare quote.
# The signature is unambiguous - a string that opens and immediately contains a
# comment marker is never intentional in this codebase.
for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    stray=$(grep -nE '^[[:space:]]*"//' "$f" || true)
    if [ -n "$stray" ]; then
        echo "  $f: stray quote before a // comment (quote-before-comment) —"
        echo "$stray" | sed 's/^/      /'
        echo "      This opens an unterminated string literal. Delete the leading \"."
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    cat <<'EOF'

lint-logos: FAILED — see the specific problems listed above.

  * "code follows %orig on the same line"
      Logos silently DELETES that trailing code and still exits 0. Put %orig on
      its own line:
          - (void)viewDidAppear:(BOOL)a {
              %orig;
              ADDarkenSplash(self);
          }

  * "%orig has a nested call in its arguments"
      Resolve it to a local first, then pass the local to %orig.

  * "declaration(s) outside the extern \"C\" block"
      Tweak.xm builds as Objective-C++ and the helper .m files build as plain
      Objective-C, so a declaration outside the block is name-mangled on one side
      only and fails at LINK time — which no -fsyntax-only check can catch. Move
      the declaration inside the extern "C" block.

EOF
    exit 1
fi

echo "lint-logos: OK"
exit 0
