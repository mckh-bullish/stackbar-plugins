#!/bin/sh
# The gate for a pull request, on Linux or macOS:
#   1. every plugin builds against the pinned StackbarKit (swift build)
#   2. the plugins' own tests (Tests/PluginTests)
#   3. house rules and the README table (scripts/lint.py)
#   4. every plugin renders every surface it declares, and every preview,
#      with stackbarctl, and its demo loop in demos.json records and moves
# On macOS it also soaks each plugin for a minute (pass SOAK_MINUTES to change).
#
#   scripts/check.sh [--base <git ref>]   --base also requires version bumps
set -eu
cd "$(dirname "$0")/.."

swift build
swift test

# stackbarctl comes from the same StackbarKit the plugins build against.
# lint.py reads each manifest through it.
swift build -c release --product stackbarctl
CTL="$(swift build -c release --show-bin-path)/stackbarctl"
if [ -n "${STACKBAR_PATH:-}" ]; then
    STACKBAR_PACKAGE="$STACKBAR_PATH"
else
    STACKBAR_PACKAGE="$(pwd)/.build/checkouts/stackbar"
fi
export STACKBAR_PACKAGE
STACKBARCTL="$CTL" python3 scripts/lint.py "$@"

summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
# Community plugins sit one folder deeper: Community/<user>/<Name>/.
for source in */*/*.swift Community/*/*/*.swift; do
    [ -f "$source" ] || continue
    case "$source" in scripts/*|.build/*|Tests/*) continue ;; esac
    echo "== $source"
    manifest=$("$CTL" manifest "$source")
    echo "$manifest"
    if echo "$manifest" | grep -q '^! '; then
        echo "::error file=$source::the manifest has problems"; exit 1
    fi
    {
        echo "### $(echo "$manifest" | head -1)"
        echo "$manifest" | grep '^- ' || true
        echo
    } >> "$summary"
    for surface in $(echo "$manifest" | sed -n 's/^surfaces: //p' | tr ',' ' '); do
        "$CTL" render "$source" --surface "$surface" > /dev/null
    done
    # Each preview renders, and sets itself up without an error.
    "$CTL" previews "$source" --json | python3 -c 'import json,sys; [print(p["name"], p["surface"]) for p in json.load(sys.stdin)]' |
    while read -r name surface; do
        echo "   preview $name ($surface)"
        if "$CTL" render "$source" --preview "$name" --surface "$surface" --verbose 2>&1 >/dev/null | grep -q "preview $name failed"; then
            echo "::error file=$source::preview $name failed to set up"; exit 1
        fi
    done
    # Its demo loop in demos.json, if it has one, records and moves.
    STACKBARCTL="$CTL" python3 scripts/check_demo.py "$source" "$(echo "$manifest" | head -1 | sed -n 's/.*(\(.*\))$/\1/p')"
    if [ "$(uname)" = Darwin ]; then
        "$CTL" soak "$source" --minutes "${SOAK_MINUTES:-1}" --press
    fi
done
echo "check: ok"
