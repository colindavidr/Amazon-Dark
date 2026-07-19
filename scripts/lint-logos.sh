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

if [ "$fail" -ne 0 ]; then
    cat <<'EOF'

lint-logos: FAILED — Logos will silently delete the trailing code above.

Fix by putting %orig on its own line:

    - (void)viewDidAppear:(BOOL)a {
        %orig;
        ADDarkenSplash(self);
    }

EOF
    exit 1
fi

echo "lint-logos: OK — %orig is always last on its line"
exit 0
