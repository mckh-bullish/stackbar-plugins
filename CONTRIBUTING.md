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
   Apple's on-device NaturalLanguage and Translation frameworks are the
   exception: they do no I/O of their own. Guard them with
   `#if canImport(...)` so the plugin still builds on Linux.
3. **It asks for as little as it can.** Every capability shows on the install
   sheet. Network hosts are exact (`api.github.com`), not `*.com`. A secret is
   asked for only when it is needed, through `Stackbar.secret`.
4. **It degrades gracefully.** No token, no network, no data: each gets a
   clear row or a `ContentUnavailableView`, never a thrown error the user can't
   act on.
5. **The panel is for doing things.** Preferences set once go on the
   `.settings` surface; quick mid-task controls stay in the panel.
6. **Destructive actions say so** with `role: .critical`, and say what
   they do with `confirm: "remove web"`: Stackbar then asks for a second
   press within 10 seconds, the same way on every surface. Use
   `confirm: .none` when the action needs no question (Undo brings it back,
   or it is the confirm row of a command view the user opened). Don't keep
   your own "press again" state. `scripts/lint.py` checks this.
7. **It renders every surface it declares** and survives the soak in CI.
8. **Its manifest is complete:** an id starting `io.navbytes.stackbar.plugins.`
   (the plugins that moved here from Stackbar keep their old ids; community
   plugins use `io.github.<user>.`, see below),
   a `version` (`x.y.z`), a one-sentence `summary`, `minimumStackbar` (the
   oldest Stackbar it builds against) and `homepage` (its folder on GitHub).
9. **It has a README** saying what it does, what it needs and its settings,
   ending with a `## What's new in <version>` list of bullets for the
   current version. The store shows it on the Update button and the
   plugin's page; older sections can stay below it as history.
10. **Any change raises the version.** Published versions are never rewritten,
    and CI fails a source change without a higher `version`.

## Layout

```
<Category>/<Name>/<Name>.swift    the plugin, the only file that ships
<Category>/<Name>/README.md
Tests/PluginTests/<Name>Tests.swift    optional: the plugin's behaviour, run as a real
                                      process on a simulated Mac (swift test)
```

A plugin's tests live under `Tests/`, never in its folder. A plugin with tests
is listed in `testedPlugins` in `Package.swift`. Tests drive the plugin the
way the host does, so assert what it does (actions, command results, URLs,
keep-awake reasons) rather than the words it shows.

The categories are `System`, `Developer`, `Network`, `Monitoring` and
`Productivity`; the folder is the category the store shows. A new category is
a new entry in `CATEGORIES` in `scripts/lint.py` and `categories` in
`Package.swift`.

## The community lane

Your own plugin can be in the store under your name. It goes in
`Community/<your-github-user>/<Name>/`, with the same two files, and its id is
`io.github.<your-github-user>.<name>` in lowercase:

```
Community/octocat/HackerNews/HackerNews.swift   id: io.github.octocat.hacker-news
Community/octocat/HackerNews/README.md
```

Everything in "The bar" above still holds, except the id prefix. Open a pull
request from your fork; when it is merged the plugin is signed and published
like the others, shows in the store's Community section with "by @octocat" on
its page, and you keep it: a later pull request from you (and only you, or a
maintainer) changes it. A plugin left broken for a release is withdrawn.

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

## Demo loops

A plugin can have a short silent loop on its store page and the site's hero:
an entry in `demos.json`, keyed by plugin id, that scripts one of its
previews with `stackbarctl render` arguments. Each `--event` or `--copy` adds
a frame, `--hold <seconds>` sets how long the last frame shows, and
`--wait <seconds>` adds a frame later (for a clock or countdown).

```json
"io.navbytes.stackbar.plugins.world-clock": {
  "preview": "hero", "surface": "panel",
  "steps": ["--hold", "1.5", "--event", "slider/time-travel=3", "--hold", "2.5"]
}
```

Try it with `stackbarctl render <file> --preview hero --frames demo.png <steps>`
(text frames off macOS). `scripts/check.sh` fails a demo whose action ids
don't exist or whose frames never change. Publishing records it in light and
dark; changing the entry records it again, with no version bump.

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
