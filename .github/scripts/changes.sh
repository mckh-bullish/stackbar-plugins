#!/bin/sh
# Decides whether a change needs the macOS job, from the changed files on
# stdin (one path per line). Prints `macos=` for $GITHUB_OUTPUT. The Linux job
# always runs: it is cheap, and it lints READMEs too. Anything not listed
# here runs on the Mac, so a new folder is covered until someone decides
# otherwise.
#
#   git diff --name-only A...B | .github/scripts/changes.sh
#   .github/scripts/changes.sh --all
set -eu

macos=false
if [ "${1:-}" = --all ]; then
    macos=true
else
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        case "$path" in
            # Docs and READMEs (the Linux lint checks the plugin table), and
            # what only the publish and canary workflows run.
            *.md|LICENSE|.gitignore|revoked.json \
            |.github/workflows/publish.yml|.github/workflows/canary.yml \
            |scripts/publish.sh|scripts/push-signed.py|scripts/lint.py) ;;
            *) macos=true ;;
        esac
    done
fi
echo "macos=$macos"
