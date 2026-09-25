# Spotlight

A macOS Spotlight-style search clone, built as a way to learn Swift.

Goal: index items (files, notes, whatever) and search them with BM25 ranking.

## Status

- Global hotkey (Cmd+Space) shows a floating, translucent search bar.
- No indexing or search yet.

Note: Cmd+Space is macOS Spotlight's shortcut. Disable it in System Settings >
Keyboard > Keyboard Shortcuts > Spotlight so this app can receive it.

## Commands

Run `make help` to list them:

```
make run       # build and launch (Ctrl-C to quit)
make stop      # quit a running copy
make test      # run unit tests
make clean     # delete build output
```

## Layout

- `Package.swift`: project manifest (name, macOS version, targets)
- `Sources/Spotlight/Spotlight.swift`: app entry point and AppDelegate
- `Sources/Spotlight/HotKey.swift`: global shortcut via Carbon
- `Sources/Spotlight/SearchPanel.swift`: floating window and SwiftUI search field
