# screenydocs

Standalone Mintlify project for the Screeny iOS app's architecture book. Kept separate from
`../screeny-site` (the marketing site) and from the `screeny` Mintlify deployment already live on
Mintlify's dashboard (that one is an unrelated macOS screenshot MCP server that happens to share the
name — do not connect this folder/repo to that deployment).

GitHub: private repo under `adimakes`, pushed from this folder.

## How it's wired

`architecture/` holds **real, committed copies** of the chapter files that live canonically in the
app repo (`screeny/docs/architecture/`). They are not symlinks — a git-hosted build (Mintlify's
included) only checks out this repo, so a symlink pointing outside it (`../screeny/...`) would be a
dangling reference on the build server. That was tried first and confirmed broken both for `mint
dev`'s directory-symlink resolution and for a git-based deploy.

**Editing a chapter does NOT show up here automatically.** Run `./sync.sh` to pull the latest
content from the app repo, then commit and push:

```bash
./sync.sh
git add -A && git commit -m "sync architecture docs"
git push
```

If a new chapter file is added to `screeny/docs/architecture/`, `sync.sh` copies it in
automatically, but you still need to add it to `docs.json`'s `navigation.pages` list by hand.

```
screenydocs/
├── docs.json          Mintlify nav/theme config
├── index.mdx           landing page
├── sync.sh             pulls fresh chapters from ../screeny/docs/architecture
└── architecture/       real files, committed (rsync'd copies, not symlinks)
    ├── 00-index.md
    ├── 01-apple-api-constraints.md
    └── ...
```

## Local preview

```bash
# mint dev requires an LTS Node (not 25+); node@22 via Homebrew works
cd screenydocs
PATH="/opt/homebrew/opt/node@22/bin:$PATH" mint dev
```

Serves at http://localhost:3000. Run `./sync.sh` first if you've edited chapters in the app repo
since the last sync — the preview reads whatever is currently in `architecture/`, not the app repo
directly.

## Deploying

Create a **new** Mintlify project/deployment (do not reuse the existing `screeny` subdomain) and
connect it to this GitHub repo. Every push to the deploy branch (after running `sync.sh` to pick up
any doc changes) rebuilds the live site.
