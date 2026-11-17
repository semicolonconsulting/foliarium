# Foliarium guide

Foliarium is a menu bar app that tidies folders with rules. Each rule says **where** to look (a folder, and optionally every folder inside it), **when** to run (as soon as files are added or changed, on a schedule, or only when you click Run Now), and **what** to do:

- **Move files** that match conditions into a folder, for example "PDFs → Documents/PDFs" or "images named Screenshot* → Pictures/Screenshots".
- **Delete files** that match conditions (they go to the Trash).
- **Change the extension** of files that match conditions, for example `.txt` → `.md`.
- **Convert Finder aliases to symlinks**, like the [alias2symlink](https://github.com/semicolonconsulting/alias2symlink) Quick Action.
- **Convert `.webloc` bookmarks to Windows `.url` files**, like the [webloc2url](https://github.com/semicolonconsulting/webloc2url) Quick Action.
- **Convert `.textClipping` files to `.txt`**.
- **Extract `.zip` archives**.

Every conversion replaces the file: the new file is written first, then the original goes to the Trash. Nothing opens another app.

- [Requirements](#requirements)
- [Install](#install)
- [Usage](#usage)
- [How it works](#how-it-works)
- [Permissions](#permissions)
- [Files](#files)
- [Uninstall](#uninstall)

## Requirements

macOS 14 Sonoma or later.

## Install

1. Download the latest release from [Releases](https://github.com/semicolonconsulting/foliarium/releases) and open it.
2. Drag **Foliarium** onto the **Applications** folder.
3. Open Foliarium from Applications.

To build it yourself instead, see [Build from source](building.md).

## Usage

Foliarium lives in the menu bar. The first time it opens, the Settings window opens on the Rules tab so you can add a rule.

**Rules** lists the rules in three columns: Where, When and What. Click **+** to add a rule, and **Edit…** or double-click to change one. Right-click a rule to duplicate it, move it up or down, or delete it. The **Auto** switch on each row turns that rule on or off. A rule that's on runs by itself as its When says; a rule that's off doesn't run at all, not even with Run Now.

In the rule editor:

- **Where**: the folder, and whether to look in the folders inside it. Hidden files and folders, and the contents of apps and other packages, are skipped.
- **When**: "When files are added or changed" handles files a few seconds after they arrive. Changes made while Foliarium wasn't running are picked up at the next launch. Files already in the folder when watching starts are left for Run Now. "On a schedule" goes through every file in the folder every few minutes or hours, every day at a time, or every week on a day at a time. If the Mac is asleep or Foliarium isn't running at that time, the rule runs once as soon as it can (one catch-up run, not one per missed time). A new schedule starts counting when you save the rule. The When column's tooltip shows the next run. "Only when I click Run Now" waits for Run Now.
- **What**: the action, chosen from a menu. Move, delete and change-extension rules also have conditions (a move rule also has a folder to move files to, and a change-extension rule the new extension). All the conditions you fill in must match:
  - **Kind**: Image, Movie, Audio, PDF, Document, Archive, Disk image or installer, or Application.
  - **Extensions**: for example `pdf, png`.
  - **File name**: text the name contains, or a pattern with `*` and `?` (`Invoice-*.pdf`). `*` matches every file. Case doesn't matter.

  **Rename to** (optional) gives moved files a new name. `*` is the original name, and `YYYY`, `MM` and `DD` are the date of the move, so `YYYYMMDD_*` turns `Picture1.png` into `20261117_Picture1.png`. The extension is kept, and a name that already starts with a date in that shape (`20261105_Scan.png`) keeps its name.

A file is handled by the rules whose folder it's in, from top to bottom. Conversions happen first, then the first move rule that matches the file decides where it goes. Files already inside a move rule's destination folder, when that's inside the rule's own folder, are never moved again, so you can organise them further by hand. A move rule with no conditions does nothing.

**General** sums up the rules, and has **Preview…** (what Run Now would do, without changing anything), **Run Now** (every rule that's turned on, through every file in its folder), the recent activity, and **Open at Login**.

**Activity** lists what was done. Double-click a row to show the file in Finder.

## How it works

Each file goes through three steps, using the rules for its folder:

1. A conversion for its type: `.webloc`, alias, `.textClipping` or `.zip`.
2. A new extension, from the first change-extension rule that matches.
3. The first move or delete rule that matches.

So a `.textClipping` can become `.txt`, then `.md`, and be filed by a move rule, all in one pass. What comes out of a `.zip` is new to the folder: watching handles it a few seconds later, and Run Now on its next run.

- **Alias → symlink**: the symlink is created first under a hidden name. Then the alias goes to the Trash and the symlink takes its name. If anything fails, the alias stays where it was. A broken alias (original item missing) is left alone and reported. Symlinks use absolute paths.
- **Webloc → URL**: writes `Name.url` (`[InternetShortcut]` / `URL=…`, CRLF line endings) next to the `.webloc`, then moves the `.webloc` to the Trash. XML, binary and legacy resource-fork `.webloc` files are supported. An existing `.url` is never overwritten; the new file becomes `Name (1).url`.
- **Clipping → text**: writes the clipping's plain text to `Name.txt` (UTF-8) next to it, then moves the `.textClipping` to the Trash.
- **Extract .zip**: extracts with macOS's `ditto` tool into a hidden folder next to the archive, so a failed extraction leaves nothing behind. A single item then takes its place next to the archive; several go into a folder named after it. The `.zip` goes to the Trash.
- **Change the extension**: renames `notes.txt` to `notes.md` in the same folder. Only the name changes.
- **Move**: if the destination already has a file with that name, the moved file becomes `Name (1).ext`. Nothing is overwritten. If the destination folder is missing, the move fails and is reported.
- **Delete**: moves matching files to the Trash.

Originals go to the Trash (Put Back works), never straight to deletion. In-progress downloads (`.download`, `.crdownload`, `.part`) are skipped. When watching, a file that changed in the last 3 seconds waits until it's been left alone, so files still being copied aren't moved halfway through.

## Permissions

The app isn't sandboxed. macOS asks once if a rule's folder is in Desktop, Documents or Downloads, or on a removable or network volume. No Automation (Finder) permission is needed.

## Files

- Settings: `~/Library/Application Support/Foliarium/config.json`
- Activity log (tab-separated): `~/Library/Logs/Foliarium/activity.log`
- Where watching and schedules left off: `watch-state.json` and `schedule-state.json`, next to the settings

A settings file from version 1 (one folder with on/off switches) is turned into rules for that folder when it's loaded.

Foliarium was called Foldertidy during development. On its first launch it moves `~/Library/Application Support/Foldertidy` and `~/Library/Logs/Foldertidy` to the Foliarium names.

## Uninstall

Turn off **Open at Login** in General if it's on, choose **Quit Foliarium** from its menu bar menu, and move Foliarium from Applications to the Trash. To remove its settings and activity log too, delete `~/Library/Application Support/Foliarium` and `~/Library/Logs/Foliarium`.
