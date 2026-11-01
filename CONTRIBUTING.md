# Contributing

This is a curated store. Everything in it is reviewed, signed by navbytes and
offered to every Stackbar user, so the bar is a plugin you would leave in your
menu bar, not a demo. Small teaching plugins belong in Stackbar's `Examples/`.

## The bar

A plugin is accepted when all of these hold:

1. **It is useful more than once.** Something people keep running.
2. **It is one file that imports StackbarKit and Foundation only.** No
   `URLSession`, `Process` or `FileManager`: plugins run sandboxed and reach
   the network, secrets and the system through `Stackbar.*` host calls.
3. **It asks for as little as it can.** Every capability shows on the install
   sheet. Network hosts are exact (`api.github.com`), not `*.com`. A secret is
   asked for only when it is needed, through `Stackbar.secret`.
4. **It degrades gracefully.** No token, no network, no data: each gets a
   clear row or a `ContentUnavailableView`, never a thrown error the user can't
   act on.
5. **The panel is for doing things.** Preferences set once go on the
   `.settings` surface; quick mid-task controls stay in the panel.
6. **Destructive actions say so** with `role: .critical`.
7. **It renders every surface it declares** and survives the soak in CI.
8. **Its manifest is complete:** an id starting `io.navbytes.stackbar.plugins.`
   (the plugins that moved here from Stackbar keep their old ids),
   a `version` (`x.y.z`), a one-sentence `summary`, `minimumStackbar` (the
   oldest Stackbar it builds against) and `homepage` (its folder on GitHub).
9. **It has a README** saying what it does, what it needs and its settings.
10. **Any change raises the version.** Published versions are never rewritten,
    and CI fails a source change without a higher `version`.

## Layout

```
<Category>/<Name>/<Name>.swift    the plugin, the only file that ships
<Category>/<Name>/README.md
```

The categories are `System`, `Developer`, `Network`, `Monitoring` and
`Productivity`; the folder is the category the store shows. A new category is
a new entry in `CATEGORIES` in `scripts/lint.py` and `categories` in
`Package.swift`.

## The loop

```sh
stackbarctl new Productivity/MyThing/MyThing.swift --name "My Thing" --id io.navbytes.stackbar.plugins.my-thing
stackbarctl render Productivity/MyThing/MyThing.swift --surface panel
stackbarctl render Productivity/MyThing/MyThing.swift --surface panel --event button/Refresh
python3 scripts/lint.py --write-readme    # updates the table in README.md
scripts/check.sh                          # what CI runs
```

To build against a local Stackbar checkout instead of the pinned release, set
`STACKBAR_PATH=/path/to/stackbar`.

## Review

The job summary of each CI run lists what every plugin asks for. That list is
what users approve, so it is the first thing a reviewer reads. Merging to
`main` publishes: CI signs the new version and adds it to the index.

## Withdrawing a version

Add `{"id": "...", "versions": ["1.2.0"], "reason": "..."}` to `revoked.json`
(leave out `versions` to withdraw every version). Stackbar stops offering it
and moves it to the Trash on Macs that installed it.

## Security

Found something wrong with a plugin? Open an issue, or for anything you would
rather not file publicly, email the address on the navbytes GitHub profile.
