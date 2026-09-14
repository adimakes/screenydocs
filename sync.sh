#!/usr/bin/env bash
# Pulls the latest architecture chapters from the app repo (screeny/docs/architecture)
# into this repo as real files, ready to commit + push.
#
# New chapter files are copied automatically. If a new chapter appears, also add it
# to docs.json's navigation.pages list — that isn't automatic.
set -euo pipefail
cd "$(dirname "$0")"

SRC="../screeny/docs/architecture/"
DEST="architecture/"

rsync -avL --delete --exclude '_research' "$SRC" "$DEST"

echo
echo "Synced. Review with: git status"
echo "Then: git add -A && git commit -m 'sync architecture docs' && git push"
