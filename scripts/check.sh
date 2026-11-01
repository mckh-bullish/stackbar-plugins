#!/bin/sh
# The gate for a pull request, on Linux or macOS:
#   1. every plugin builds against the pinned StackbarKit (swift build)
#   2. house rules and the README table (scripts/lint.py)
#   3. every plugin renders every surface it declares with stackbarctl
# On macOS it also soaks each plugin for a minute (pass SOAK_MINUTES to change).
#
#   scripts/check.sh [--base <git ref>]   --base also requires version bumps
set -eu
cd "$(dirname "$0")/.."

swift build
python3 scripts/lint.py "$@"

# stackbarctl comes from the same StackbarKit the plugins build against.
swift build -c release --product stackbarctl
CTL="$(swift build -c release --show-bin-path)/stackbarctl"
if [ -n "${STACKBAR_PATH:-}" ]; then
    STACKBAR_PACKAGE="$STACKBAR_PATH"
else
    STACKBAR_PACKAGE="$(pwd)/.build/checkouts/stackbar"
fi
export STACKBAR_PACKAGE

summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
for source in */*/*.swift; do
    case "$source" in scripts/*|.build/*) continue ;; esac
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
    if [ "$(uname)" = Darwin ]; then
        "$CTL" soak "$source" --minutes "${SOAK_MINUTES:-1}" --press
    fi
done
echo "check: ok"
