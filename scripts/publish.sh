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
# A plugin with previews (sample-data scenes, Stackbar 0.17.0) is rendered as
# its `hero` preview, so the store shows it in use, and each preview is
# rendered too, at previews/<name>/<surface>.png beside a previews.json that
# lists them. Renders are not part of a signed bundle, so a version missing
# them (one published before renders existed) gets them on the next run.
render_shots() {
    out="$SITE/$1/shots/$2/$3"
    [ -d "$out" ] && return 0
    mkdir -p "$out.tmp"
    "$CTL" previews "$4" --json > "$out.tmp/previews.json" 2>/dev/null || echo "[]" > "$out.tmp/previews.json"
    hero=""
    if python3 -c 'import json,sys; sys.exit(0 if any(p["name"] == "hero" for p in json.load(open(sys.argv[1]))) else 1)' "$out.tmp/previews.json"; then
        hero="--preview hero"
    fi
    scenes=$(python3 -c 'import json,sys; [print(p["name"], p["surface"]) for p in json.load(open(sys.argv[1]))]' "$out.tmp/previews.json")
    for appearance in light dark; do
        flag=""
        [ "$appearance" = dark ] && flag="--dark"
        # shellcheck disable=SC2086
        "$CTL" render "$4" --png "$out.tmp/$appearance" $flag $hero > /dev/null || echo "warning: could not render $2 $3 $appearance"
        echo "$scenes" | while read -r name surface; do
            [ -n "$name" ] || continue
            # shellcheck disable=SC2086
            "$CTL" render "$4" --preview "$name" --surface "$surface" --png "$out.tmp/$appearance/previews/$name" $flag > /dev/null \
                || echo "warning: could not render $2 $3 preview $name $appearance"
        done
    done
    if [ -d "$out.tmp/light" ]; then mv "$out.tmp" "$out"; else rm -rf "$out.tmp"; fi
}

# Demo loops (demos.json): a scripted run of one preview recorded as an
# animated PNG with `stackbarctl render --frames`, light and dark, at
# <appearance>/demo/<script hash>/<surface>.png. The hash is of the plugin's
# entry, so changing the script records it again; like the other renders it
# is added to versions published before it existed.
render_demo() {
    spec=$(python3 -c 'import json,sys; d=json.load(open("demos.json")).get(sys.argv[1]); print(json.dumps(d, sort_keys=True) if d else "")' "$2")
    [ -n "$spec" ] || return 0
    hash=$(printf '%s' "$spec" | shasum -a 256 | cut -c1-12)
    base="$SITE/$1/shots/$2/$3"
    for appearance in light dark; do
        out="$base/$appearance/demo/$hash"
        [ -d "$out" ] && continue
        flag=""
        [ "$appearance" = dark ] && flag="--dark"
        python3 - "$spec" "$CTL" "$4" "$out.tmp" $flag <<'PY' || { echo "warning: could not record the $2 $3 demo ($appearance)"; rm -rf "$out.tmp"; continue; }
import json, os, subprocess, sys
spec, ctl, source, out = json.loads(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
os.makedirs(out, exist_ok=True)
surface = spec.get("surface", "panel")
command = [ctl, "render", source, "--preview", spec.get("preview", "hero"), "--surface", surface,
           "--frames", os.path.join(out, f"{surface}.png"), *sys.argv[5:], *spec["steps"]]
subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
PY
        if [ -d "$out.tmp" ]; then mkdir -p "$(dirname "$out")"; mv "$out.tmp" "$out"; fi
    done
}

# Community plugins sit one folder deeper: Community/<user>/<Name>/.
for source in */*/*.swift Community/*/*/*.swift; do
    [ -f "$source" ] || continue
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
        render_demo "$category" "$id" "$version" "$source"
        continue
    fi
    "$CTL" sign "$source" --publisher navbytes --key "$KEY" -o "$bundle"
    render_shots "$category" "$id" "$version" "$source"
    render_demo "$category" "$id" "$version" "$source"
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
# app's store, its previews (name, title, surface and renders, in order), and
# each plugin's README (description, `- **Label:**` facts and
# `## What's new in <version>` notes, split the way the site splits them) for
# the app's plugin page.
python3 - "$SITE" "$ABOUT" <<'PY'
import json, os, re, sys
site, about_list = sys.argv[1], sys.argv[2]

def parse_readme(markdown):
    lines = markdown.replace("\r\n", "\n").split("\n")
    if lines and lines[0].startswith("# "):
        lines.pop(0)
    facts, rest, changes, i = [], [], [], 0
    while i < len(lines):
        # `## Highlights` and `## FAQ` are for the website (navbytes/stackbar
        # site/scripts/store.mjs); keep them out of the app's description.
        if re.match(r"^## (Highlights|FAQ|Questions)\s*$", lines[i]):
            i += 1
            while i < len(lines) and not lines[i].startswith("## "):
                i += 1
            continue
        # `## What's new in 1.2.0` and its bullets: the release notes the
        # store shows on the Update button and the plugin's page.
        heading = re.match(r"^## What's new in (\S+)\s*$", lines[i])
        if heading:
            notes = []
            i += 1
            while i < len(lines) and not lines[i].startswith("#"):
                if lines[i].startswith("- "):
                    notes.append(lines[i][2:].strip())
                elif re.match(r"^\s{2,}\S", lines[i]) and notes:
                    notes[-1] += " " + lines[i].strip()
                i += 1
            changes.append({"version": heading.group(1), "notes": notes})
            continue
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
    return {"description": "\n".join(rest).strip(), "facts": facts, "changes": changes}

about = {}
for line in open(about_list):
    plugin, version, readme = line.rstrip("\n").split("\t")
    if os.path.isfile(readme):
        about[plugin] = {"version": version, **parse_readme(open(readme, encoding="utf-8").read())}

def apng_seconds(path):
    """How long one pass of an animated PNG lasts: the sum of its frame delays."""
    data, at, total = open(path, "rb").read(), 8, 0.0
    while at + 8 <= len(data):
        length = int.from_bytes(data[at:at + 4], "big")
        kind = data[at + 4:at + 8]
        if kind == b"fcTL":
            body = data[at + 8:at + 8 + length]
            num, den = int.from_bytes(body[20:22], "big"), int.from_bytes(body[22:24], "big") or 100
            total += num / den
        at += 12 + length
    return round(total, 2)

def demo_hash(plugin):
    import hashlib
    spec = json.load(open("demos.json")).get(plugin) if os.path.isfile("demos.json") else None
    return hashlib.sha256(json.dumps(spec, sort_keys=True).encode()).hexdigest()[:12] if spec else None

plugins, previews, demos = {}, {}, {}
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
            # Previews in the plugin's order, each with the surface it is about.
            listed = os.path.join(root, plugin, version, "previews.json")
            scenes = []
            for preview in json.load(open(listed)) if os.path.isfile(listed) else []:
                scene = {"name": preview["name"], "title": preview["title"], "surface": preview["surface"]}
                for appearance in ("light", "dark"):
                    relative = f"{appearance}/previews/{preview['name']}/{preview['surface']}.png"
                    if os.path.isfile(os.path.join(root, plugin, version, relative)):
                        scene[appearance] = f"{category}/shots/{plugin}/{version}/{relative}"
                if "light" in scene or "dark" in scene:
                    scenes.append(scene)
            if scenes:
                previews.setdefault(plugin, {})[version] = scenes
            # The demo loop recorded from the plugin's current demos.json entry.
            current = demo_hash(plugin)
            demo = {}
            for appearance in ("light", "dark"):
                folder = os.path.join(root, plugin, version, appearance, "demo", current or "-")
                for name in sorted(os.listdir(folder)) if current and os.path.isdir(folder) else []:
                    if name.endswith(".png"):
                        demo["surface"] = name[:-4]
                        demo[appearance] = f"{category}/shots/{plugin}/{version}/{appearance}/demo/{current}/{name}"
                        demo["seconds"] = apng_seconds(os.path.join(folder, name))
            if "light" in demo or "dark" in demo:
                demos.setdefault(plugin, {})[version] = demo
with open(os.path.join(site, "site.json"), "w") as out:
    json.dump({"format": 1, "plugins": plugins, "previews": previews, "demos": demos, "about": about}, out, indent=2, sort_keys=True)
    out.write("\n")
PY

# People who open the store's address get the store's pages.
cat > "$SITE/index.html" <<'HTML'
<!doctype html>
<meta charset="utf-8">
<title>Stackbar Plugins</title>
<link rel="canonical" href="https://stackbar.app/plugins/">
<meta http-equiv="refresh" content="0; url=https://stackbar.app/plugins/">
<p><a href="https://stackbar.app/plugins/">Stackbar Plugins</a></p>
HTML
