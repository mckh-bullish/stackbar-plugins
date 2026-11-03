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

# Each plugin's current version and README, for site.json's "about".
ABOUT=$(mktemp)
trap 'rm -f "$ABOUT"' EXIT

# Every surface in light and dark, for the plugin's page on the Stackbar site.
# Renders are not part of a signed bundle, so a version missing them (one
# published before renders existed) gets them on the next run.
render_shots() {
    out="$SITE/$1/shots/$2/$3"
    [ -d "$out" ] && return 0
    for appearance in light dark; do
        flag=""
        [ "$appearance" = dark ] && flag="--dark"
        # shellcheck disable=SC2086
        "$CTL" render "$4" --png "$out.tmp/$appearance" $flag > /dev/null || echo "warning: could not render $2 $3 $appearance"
    done
    if [ -d "$out.tmp/light" ]; then mv "$out.tmp" "$out"; else rm -rf "$out.tmp"; fi
}

for source in */*/*.swift; do
    case "$source" in scripts/*|.build/*|Tests/*) continue ;; esac
    category=${source%%/*}
    first=$("$CTL" manifest "$source" | head -1)          # "Name 1.2.0 (io.navbytes...)"
    id=$(echo "$first" | sed -n 's/.*(\(.*\))$/\1/p')
    version=$(echo "$first" | sed -n 's/.* \([0-9][0-9.]*\) (.*)$/\1/p')
    [ -n "$id" ] && [ -n "$version" ] || { echo "can't read the manifest of $source: $first"; exit 1; }
    printf '%s\t%s\t%s\n' "$id" "$version" "$(dirname "$source")/README.md" >> "$ABOUT"
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
        render_shots "$category" "$id" "$version" "$source"
        continue
    fi
    "$CTL" sign "$source" --publisher navbytes --key "$KEY" -o "$bundle"
    render_shots "$category" "$id" "$version" "$source"
    shots="$SITE/$category/shots/$id/$version/light"
    for surface in panel menuBar window widget; do
        if [ -f "$shots/$surface.png" ]; then cp "$shots/$surface.png" "$SITE/$category/$id.png"; break; fi
    done
    echo "published: $id $version"
done

"$CTL" index build "$SITE" --name "Stackbar Plugins by navbytes" \
    --homepage https://github.com/navbytes/stackbar-plugins \
    --revoked revoked.json --key "$KEY"
touch "$SITE/.nojekyll"

# site.json: each version's renders, for the site's plugin galleries and the
# app's store, and each plugin's README (description and `- **Label:**` facts,
# split the way the site splits them) for the app's plugin page.
python3 - "$SITE" "$ABOUT" <<'PY'
import json, os, re, sys
site, about_list = sys.argv[1], sys.argv[2]

def parse_readme(markdown):
    lines = markdown.replace("\r\n", "\n").split("\n")
    if lines and lines[0].startswith("# "):
        lines.pop(0)
    facts, rest, i = [], [], 0
    while i < len(lines):
        fact = re.match(r"^- \*\*(.+?):\*\*\s*(.*)$", lines[i])
        if not fact:
            rest.append(lines[i])
            i += 1
            continue
        text = fact.group(2)
        while i + 1 < len(lines) and re.match(r"^\s{2,}\S", lines[i + 1]):
            i += 1
            text += " " + lines[i].strip()
        facts.append({"label": fact.group(1), "text": text})
        i += 1
    return {"description": "\n".join(rest).strip(), "facts": facts}

about = {}
for line in open(about_list):
    plugin, version, readme = line.rstrip("\n").split("\t")
    if os.path.isfile(readme):
        about[plugin] = {"version": version, **parse_readme(open(readme, encoding="utf-8").read())}

plugins = {}
for category in sorted(os.listdir(site)):
    root = os.path.join(site, category, "shots")
    if not os.path.isdir(root):
        continue
    for plugin in sorted(os.listdir(root)):
        for version in sorted(os.listdir(os.path.join(root, plugin))):
            shots = {}
            for appearance in ("light", "dark"):
                folder = os.path.join(root, plugin, version, appearance)
                for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
                    if name.endswith(".png"):
                        shots.setdefault(name[:-4], {})[appearance] = f"{category}/shots/{plugin}/{version}/{appearance}/{name}"
            if shots:
                plugins.setdefault(plugin, {})[version] = shots
with open(os.path.join(site, "site.json"), "w") as out:
    json.dump({"format": 1, "plugins": plugins, "about": about}, out, indent=2, sort_keys=True)
    out.write("\n")
PY

# People who open the store's address get the store's pages.
cat > "$SITE/index.html" <<'HTML'
<!doctype html>
<meta charset="utf-8">
<title>Stackbar Plugins</title>
<link rel="canonical" href="https://stackbar.navbytes.io/plugins/">
<meta http-equiv="refresh" content="0; url=https://stackbar.navbytes.io/plugins/">
<p><a href="https://stackbar.navbytes.io/plugins/">Stackbar Plugins</a></p>
HTML
