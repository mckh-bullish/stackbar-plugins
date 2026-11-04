#!/bin/sh
# Builds prebuilt helpers, so Macs without Xcode or the Command Line Tools can
# run store plugins. macOS only (signing uses CryptoKit). The Helpers workflow
# runs it hourly and after each publish.
#
#   scripts/helpers.sh <site dir> <private key file>
#
# For the StackbarKit of each of the latest Stackbar releases (HELPER_RELEASES,
# default 4), it builds every plugin's current source that has no helper yet.
# Each binary goes up as an asset of the release helpers-<kit digest> in this
# repository. Its signed record goes to <site>/helpers/<kit digest>/, and every
# record of the current kits is listed in <site>/helpers.json, which the app
# reads beside index.json. A record names the exact source and StackbarKit it
# was built from, so the app uses a helper only for that source.
# Needs GH_TOKEN (contents: write).
set -eu
SITE=$1
KEY=$2
cd "$(dirname "$0")/.."

REPO=${GITHUB_REPOSITORY:-navbytes/stackbar-plugins}
RELEASES=${HELPER_RELEASES:-4}
WORK="$(pwd)/.build/helpers"
mkdir -p "$WORK/out" "$SITE/helpers"
: > "$WORK/kits"

swift build -c release --product stackbarctl
CTL="$(swift build -c release --show-bin-path)/stackbarctl"

# Newest first.
TAGS=$(gh api "repos/navbytes/stackbar/releases?per_page=30" --jq '.[] | select(.draft | not) | .tag_name' | head -n "$RELEASES")
[ -n "$TAGS" ] || { echo "no Stackbar releases found"; exit 1; }

for tag in $TAGS; do
    src="$WORK/stackbar-$tag"
    if [ ! -d "$src" ]; then
        git clone -q --depth 1 --branch "$tag" https://github.com/navbytes/stackbar "$src"
    fi
    # The slim package the app embeds (scripts/embed-stackbarkit.sh), so the
    # digest is the one the app computes.
    kit="$WORK/kit-$tag"
    rm -rf "$kit"
    mkdir -p "$kit/Sources"
    cp "$src/Packaging/StackbarKit-Package.swift" "$kit/Package.swift"
    cp -R "$src/Sources/StackbarProtocol" "$src/Sources/StackbarKit" "$kit/Sources/"
    if ! info=$(STACKBAR_PACKAGE="$kit" "$CTL" helper kit); then
        echo "::warning::can't read the StackbarKit of $tag"
        continue
    fi
    digest=${info%% *}
    short=$(printf '%s' "$digest" | cut -c1-16)
    grep -qx "$short" "$WORK/kits" && { echo "$tag: same StackbarKit as a newer release"; continue; }
    echo "$short" >> "$WORK/kits"
    release="helpers-$short"
    echo "== $tag: StackbarKit $short"

    if ! gh release view "$release" -R "$REPO" > /dev/null 2>&1; then
        gh release create "$release" -R "$REPO" --prerelease \
            --title "Prebuilt plugins for StackbarKit $short" \
            --notes "Plugin helpers built against the StackbarKit of Stackbar $tag (digest $digest). Stackbar downloads them through helpers.json; you don't need these files yourself."
    fi
    assets=$(gh release view "$release" -R "$REPO" --json assets --jq '.assets[].name')
    records="$SITE/helpers/$short"
    mkdir -p "$records"

    for source in */*/*.swift; do
        case "$source" in scripts/*|.build/*|Tests/*) continue ;; esac
        sum=$(shasum -a 256 "$source" | cut -c1-12)
        asset="$(basename "$source" .swift)-$sum"
        if [ -f "$records/$asset.json" ] && printf '%s\n' "$assets" | grep -qx "$asset"; then
            continue
        fi
        if ! STACKBAR_PACKAGE="$kit" "$CTL" helper build "$source" --key "$KEY" --cache "$WORK/cache-$short" \
            -o "$WORK/out/$asset" --url "https://github.com/$REPO/releases/download/$release/$asset" > "$WORK/record.json"; then
            # Usually a plugin that needs a newer Stackbar than this release.
            echo "::warning::$source doesn't build against Stackbar $tag; skipped"
            continue
        fi
        gh release upload "$release" "$WORK/out/$asset" -R "$REPO" --clobber
        mv "$WORK/record.json" "$records/$asset.json"
        rm -f "$WORK/out/$asset"
        echo "built: $asset for $tag"
    done
done

# helpers.json: the records of the current kits, oldest release first, so the
# app's pick of a helper for the same protocol takes the newest.
python3 - "$SITE" "$WORK/kits" <<'PY'
import json, os, shutil, sys
site, kits_file = sys.argv[1], sys.argv[2]
kits = [line.strip() for line in open(kits_file) if line.strip()]
root = os.path.join(site, "helpers")
for name in os.listdir(root):
    if name not in kits and os.path.isdir(os.path.join(root, name)):
        shutil.rmtree(os.path.join(root, name))
helpers = []
for kit in reversed(kits):
    folder = os.path.join(root, kit)
    for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        if name.endswith(".json"):
            helpers.append(json.load(open(os.path.join(folder, name))))
with open(os.path.join(site, "helpers.json"), "w") as out:
    # No timestamp: an hourly run with nothing new must change nothing.
    json.dump({"format": 1, "helpers": helpers}, out, indent=2, sort_keys=True)
    out.write("\n")
print(f"helpers.json: {len(helpers)} helpers for {len(kits)} StackbarKits")
PY
