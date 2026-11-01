#!/bin/sh
# Signs every plugin version not yet published and rebuilds the signed index.
# macOS only (signing uses CryptoKit). The publish workflow runs it on main.
#
#   scripts/publish.sh <site dir> <private key file>
#
# <site dir> is a checkout of the gh-pages branch. Published bundles are never
# rewritten: a version that is already there with different source fails, so
# a change must raise the plugin's version.
set -eu
SITE=$1
KEY=$2
cd "$(dirname "$0")/.."

swift build -c release --product stackbarctl
CTL="$(swift build -c release --show-bin-path)/stackbarctl"
STACKBAR_PACKAGE="${STACKBAR_PATH:-$(pwd)/.build/checkouts/stackbar}"
export STACKBAR_PACKAGE

for source in */*/*.swift; do
    case "$source" in scripts/*|.build/*) continue ;; esac
    category=${source%%/*}
    first=$("$CTL" manifest "$source" | head -1)          # "Name 1.2.0 (io.navbytes...)"
    id=$(echo "$first" | sed -n 's/.*(\(.*\))$/\1/p')
    version=$(echo "$first" | sed -n 's/.* \([0-9][0-9.]*\) (.*)$/\1/p')
    [ -n "$id" ] && [ -n "$version" ] || { echo "can't read the manifest of $source: $first"; exit 1; }
    mkdir -p "$SITE/$category"
    bundle="$SITE/$category/$id-$version.stackbarplugin"
    if [ -f "$bundle" ]; then
        python3 - "$bundle" "$source" <<'PY'
import hashlib, json, sys
bundle, source = sys.argv[1], sys.argv[2]
published = json.load(open(bundle))["sourceDigest"]
current = hashlib.sha256(open(source, "rb").read()).hexdigest()
if published != current:
    sys.exit(f"{source}: version already published with different source; raise its version")
PY
        echo "unchanged: $id $version"
        continue
    fi
    "$CTL" sign "$source" --publisher navbytes --key "$KEY" -o "$bundle"
    shots=$(mktemp -d)
    if "$CTL" render "$source" --surface panel --png "$shots" > /dev/null; then
        first_png=$(ls "$shots"/*.png 2>/dev/null | head -1 || true)
        [ -n "$first_png" ] && cp "$first_png" "$SITE/$category/$id.png"
    fi
    rm -rf "$shots"
    echo "published: $id $version"
done

"$CTL" index build "$SITE" --name "Stackbar Plugins by navbytes" \
    --homepage https://github.com/navbytes/stackbar-plugins \
    --revoked revoked.json --key "$KEY"
touch "$SITE/.nojekyll"
