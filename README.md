# Spotlight

A Spotlight/Raycast-style launcher for macOS that searches your apps, files and
the text inside them, ranked with BM25. Built as a way to learn Swift from zero.

- Press **Cmd+Space**, type, and press **Return** to open the selected result.
- Results are grouped into **Applications** and **Files & Folders**.
- File contents are indexed too: when a match is inside a file, the matching
  text is shown under it with the matched words in bold.

## Install

1. Download `Spotlight-<version>-macos.zip` from the
   [latest release](https://github.com/ivanleomk/spotlight/releases/latest) and unzip it.
2. Move `Spotlight.app` to `/Applications` and open it.
3. The app is signed but not notarized yet, so macOS blocks it the first time.
   Open **System Settings > Privacy & Security**, scroll down, and click
   **Open Anyway**.
4. Allow access to Documents, Desktop and Downloads when asked; that's what it
   indexes.
5. Free up Cmd+Space: **System Settings > Keyboard > Keyboard Shortcuts >
   Spotlight**, and turn off "Show Spotlight search".

Requires macOS 14 or later, on Apple Silicon or Intel.

## What gets indexed

- **Apps** in `/Applications`, `/System/Applications` (names only).
- **Files and folders** in `~/Documents`, `~/Desktop` and `~/Downloads`.
- **Contents** of text files (Markdown, code, JSON, ...) and PDFs: the first
  10,000 characters of each.
- Skipped: hidden files, `node_modules`, `.build`, `DerivedData`, virtualenvs,
  lockfiles, and the insides of app bundles.

The index lives in `~/Library/Application Support/Spotlight/index.sqlite`
(SQLite FTS5). The first crawl reads everything; later launches only re-read
files whose modification date changed.

## Development

Run `make help` to list the commands:

```
make run       # build and launch (Ctrl-C to quit)
make stop      # quit a running copy
make test      # run unit tests
make app       # build a signed Spotlight.app + zip in dist/ (VERSION=0.1.0)
make clean     # delete build output
```

## Layout

```
Sources/Spotlight/
  App/        SpotlightApp (entry point), AppDelegate (startup), HotKey (Cmd+Space),
              SettingsWindow (the Settings window)
  Search/     SearchEngine (the contract the UI uses), SQLiteSearchEngine (FTS5 index,
              BM25 ranking, snippets), +Schema (tables and upgrades), SearchText
              (query sanitizing, camelCase splitting), SQLite (C API wrapper)
  Indexing/   FileCrawler (walks folders, keeps the index current), ContentExtractor
              (text from files and PDFs), IndexedFolder (what gets crawled)
  Panel/      SearchPanel (floating window), SearchView, ResultRow, PanelStyle
  Settings/   SettingsView (sidebar), GeneralPage, SourcesPage, SettingsComponents
  Shared/     Formatting (labels, ~ paths, bold matches), WindowPlacement (centering)

Tests/SpotlightTests/   one file per area above, plus TestHelpers
```

`scripts/package.sh` builds, signs and zips `Spotlight.app` for a release.
