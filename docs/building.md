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

## Release

```bash
./scripts/release.sh
```

`release.sh` builds the app, signs it with your Developer ID Application certificate, has Apple notarize it and makes `build/Foliarium-<version>.dmg`, also signed, notarized and stapled, so it opens on any Mac without a warning. The version comes from `MARKETING_VERSION` in the Xcode project. It needs a notarytool keychain profile called `notary`, which you make once:

```bash
xcrun notarytool store-credentials notary --apple-id <your Apple ID> --team-id C6ZRF9KM22 --password <app-specific password>
```

Set `NOTARY_PROFILE` to use another profile. If Apple rejects the app, the script prints the notary log.

The disk image opens on a window that asks you to drag Foliarium into Applications. `scripts/make-dmg.sh <app> <dmg>` makes it on its own, without signing, handy for trying a new design: it installs [dmgbuild](https://github.com/dmgbuild/dmgbuild) into `build/.dmgbuild-venv` the first time and lays out the window from `scripts/dmg-settings.py`. The window background is `Design/dmg/background.png` and its `@2x`, drawn by `Design/dmg/make-background.py` (it needs Pillow and the Inter font); keep the icon positions in the two files in step.

## App Store edition

The App Store edition is the same code, built in the App Sandbox. There it can only use folders you choose in the rule editor, which it remembers with security-scoped bookmarks, and it has no "Delete files in Trash" action, because a sandboxed app can't read the Trash. A rule whose folder it isn't allowed to use shows "Needs access" until you choose the folder again.

```bash
EDITION=appstore ./scripts/build-app.sh   # a sandboxed build to try locally
./scripts/appstore.sh                     # build/appstore/Foliarium.pkg, signed for the Mac App Store
UPLOAD=1 ./scripts/appstore.sh            # the same, uploaded to App Store Connect
```

`appstore.sh` needs the app's record in App Store Connect and Xcode signed in to the team's Apple account, so it can make the App Store provisioning profile. Each upload needs a higher build number: raise `CURRENT_PROJECT_VERSION` or set `BUILD_NUMBER`. The sandbox settings live in `Config/Foliarium-AppStore.entitlements`.

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
| `Foliarium/FolderAccess.swift` | The App Store edition's sandbox: which folders it may use, and the edition's limits |
| `Config/Foliarium-AppStore.entitlements` | The App Store edition's sandbox entitlements |
| `scripts/` | `build-app.sh`, `install-local.sh`, `release.sh` and `appstore.sh` |
| `docs/` | The guide, this page, and the pictures in the README |
