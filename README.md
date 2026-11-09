# ScreenShelf

A tiny macOS menu bar app that holds your screenshots.

Click the icon in the menu bar and a dropdown shows your screenshots in a 4-wide grid, newest first.

- **Click** a thumbnail to copy the image to the clipboard (pastes as an image in apps, as a file in Finder)
- **Right-click** for Copy, Open, Show in Finder or Move to Trash
- **Drag** a thumbnail into any app that accepts files
- **ⓧ** on the top-right corner moves that screenshot to the Trash

The menu bar icon fills in when a new screenshot arrives. The gear menu can make the dropdown pop open after every screenshot.

ScreenShelf reads from wherever macOS saves screenshots (⇧⌘5 → Options → Save to), which is the Desktop by default. It registers itself as a login item on every launch, so it always starts with your Mac.

## Build

Requires macOS 14+ and the Xcode command line tools.

```bash
./build.sh
```

This compiles `ScreenShelf.swift`, signs the app (with your Apple Development identity if you have one, otherwise ad-hoc), installs it to `/Applications` and launches it. Pass `--no-launch` to skip launching.

## Tip

macOS waits about 5 seconds before saving a screenshot while the floating preview is shown. Turn it off in ⇧⌘5 → Options → Show Floating Thumbnail to have screenshots appear on the shelf right away.
