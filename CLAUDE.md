# Stackbar Plugins — notes for AI sessions

The curated plugin store for Stackbar (navbytes/stackbar). `CONTRIBUTING.md`
is the bar a plugin must clear and `README.md` explains publishing.

- A plugin is `<Category>/<Name>/<Name>.swift` plus a `README.md`. Nothing
  else goes in the folder.
- Any source change raises the manifest `version`. Published versions are
  immutable.
- The Stackbar pin is `stackbarRevision` in `Package.swift`. Set
  `STACKBAR_PATH` to build against a local stackbar checkout.
- Stackbar's own authoring reference: `stackbarctl docs`.

Run this before you call a change done:

```sh
scripts/check.sh
```
