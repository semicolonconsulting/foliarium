# Build from source

You need Xcode 16 or later.

```bash
git clone https://github.com/semicolonconsulting/foliarium.git
cd foliarium
./scripts/build-app.sh
./scripts/install-local.sh
```

`build-app.sh` makes `build/Foliarium.app`. It signs the app with your Apple Development certificate when your keychain has one, so macOS keeps the folder permissions you gave it (Desktop, Documents, Downloads) across rebuilds. Otherwise it signs ad-hoc. Set `SIGN_IDENTITY` to choose another identity (`SIGN_IDENTITY=-` for ad-hoc) and `TEAM_ID` for another team. The full build log is in `build/xcodebuild.log`.

`install-local.sh` quits the running copy, copies the app to `/Applications` and opens it. It also unregisters the copy in `build/`, so Open at Login and Spotlight find the installed one.

A copy you build yourself isn't notarized. On another Mac, its first launch is blocked with a message that macOS "could not verify" it. To allow it, open System Settings → Privacy & Security, scroll down to the message about Foliarium and click **Open Anyway**. You only need to do this once.

## Launch arguments

Launch arguments, handy for screenshots and testing:

- `-configPath /path/config.json` uses another settings file. The activity log and watch state are kept next to it.
- `-openSettings general|rules|activity` opens the Settings window on that tab.
- `-openPreview YES` opens the Preview window.
- `-editRule first` opens the editor for the first rule.

```bash
open -n build/Foliarium.app --args -configPath /tmp/ft/config.json -openSettings rules
```

## Source files

| File | What it is |
| --- | --- |
| `Foliarium/AppDelegate.swift` | The menu bar item and its menu: Run Now, Preview, the rule folders, Activity and Settings |
| `Foliarium/AppModel.swift` | The app's state, shared by the menu and the windows, and the activity log |
| `Foliarium/Config.swift` | Rules and settings, saved as JSON, including the upgrade from version 1 settings |
| `Foliarium/Engine.swift` | Decides what happens to each file, and does it: conversions, extension changes, moves and deletes |
| `Foliarium/Processor.swift` | Runs the engine on a background queue for Run Now, Preview, watching and schedules |
| `Foliarium/FolderWatcher.swift` | Watches folders with FSEvents, and picks up changes made while Foliarium wasn't running |
| `Foliarium/Windows.swift` | The Settings and Preview windows |
| `Foliarium/GeneralView.swift` | The General tab |
| `Foliarium/RulesView.swift` | The Rules tab and the rule editor |
| `Foliarium/ActivityView.swift` | The Activity tab and the Preview list |
| `Foliarium/LoginItem.swift` | Open at Login |
| `Config/Info.plist` | The app's Info.plist |
| `scripts/` | `build-app.sh` and `install-local.sh` |
| `docs/` | The guide, this page, and the pictures in the README |
