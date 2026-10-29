# Tidy

Keeps your Mac neat and fast. Tidy finds the hidden junk you can't easily find yourself (caches, logs, installer and uninstall leftovers, system debris), removes apps with everything they left behind, checks for things that compromise your Mac, and shows how busy the Mac is. Nothing is deleted without showing you exactly what goes and how big it is, and everything it cleans can be put back for 30 days.

Native macOS app, written in Swift and SwiftUI. The original spec is in [project-context.md](project-context.md).

## Install

You need macOS 13 (Ventura) or later, and Xcode (free on the App Store) to build the disk image once.

1. Open Terminal and get the code, or `cd` into the folder you already have:

   ```sh
   git clone https://github.com/rafaelcgama/clean-my-mac.git
   cd clean-my-mac
   ```

2. Build the disk image (no `sudo`; it takes a few minutes):

   ```sh
   scripts/make-app.sh
   ```

   It makes `build/Tidy.dmg` and opens it when it's done.

3. In the window that opens, drag **Tidy** onto **Applications**.
4. Eject the Tidy disk (the ⏏ next to it in Finder's sidebar).
5. Open Tidy from Applications, Launchpad or Spotlight. From now on it's a normal app: no Terminal needed.

On the Mac that built it, Tidy opens straight away. To install it on another Mac, copy `build/Tidy.dmg` there and do steps 3 to 5. Because this build isn't signed with a paid Apple Developer ID, macOS on that Mac will first say it can't check Tidy for malware: click Done, then go to System Settings › Privacy & Security and click **Open Anyway** next to Tidy. You only do that once.

### Update

1. Quit Tidy: ⌘Q, or **Quit Tidy** in its menu bar panel (closing the window leaves it running in the menu bar).
2. In the project folder, get the new code and build again:

   ```sh
   git pull
   scripts/make-app.sh
   ```

3. Drag Tidy onto Applications and choose **Replace**.

Your settings and your quarantine are kept: they live in your Library folder, not in the app.

### Uninstall

1. If you installed the admin helper, remove it first: Tidy › Settings (⌘,) › Admin Helper › **Remove Helper**.
2. If anything is still in Quarantine that you don't want back, delete it there (or put it back).
3. Quit Tidy and drag it from Applications to the Trash.
4. To remove its settings and data too, delete `~/Library/Application Support/Tidy`.

### Permissions

Tidy doesn't need Full Disk Access and never asks for it. It leaves alone what macOS keeps private from apps without it, such as the Trash, Safari's data and other apps' private data, and says so where it matters.

Some cleanup needs administrator rights (system caches and logs, apps installed for all users). For those, macOS asks for your password each time, unless you install the admin helper (see Settings below).

## What's in Tidy

Eight tabs, one job each.

- **Smart Care**: one scan for junk, login items and browser settings, with one report before anything changes. It cleans only the junk it preselects, after you review it. An **Open Trash** button shows the Trash in Finder, where you can empty it.
- **System Junk**: caches, logs, developer leftovers (Xcode build data and old simulators, Homebrew, npm, pip and other package caches) and old "Install macOS" apps. System caches and logs are listed too; they need your password and are never preselected. Caches used in the last 30 days are listed but not preselected, because they keep apps fast. Review every item and its size, then clean; Undo is right there on the result screen.
- **Uninstaller**: remove an app together with everything it left: settings, caches, saved data, background helpers, and what its installer package put elsewhere on the Mac. Each app shows when you last opened it, so unused ones stand out. "Leftovers of removed apps" finds data of apps that are already gone.
- **Updater**: finds newer versions of your apps (apps that update themselves with Sparkle, Homebrew casks, and App Store apps). Nothing installs without you: Homebrew apps update with one click, the others are opened so their own updater, or the App Store, does it.
- **Protection**: looks for suspicious things that start with your Mac (programs running from hidden or temporary folders, unsigned or tampered programs, scripts that download code) and browser settings locked by adware. What it flags can be moved to quarantine. Below that, one list of what can watch you or control your Mac, each with a plain line and an **Open** button: the System Settings pages for Camera, Microphone, Screen Recording, Input Monitoring and Accessibility, and each installed browser's list of websites allowed to use your camera, microphone, location and more.
- **Malware Scan**: checks your files against Apple's own XProtect malware rules, plus any rule files you add. Quick Scan covers Downloads, your apps, what starts with your Mac, and shared and temporary folders; or pick folders yourself. You can try it safely with the standard EICAR test file. Anything found goes to quarantine, so it can be undone.
- **Performance**: CPU, RAM and Hard Drive, read live from your Mac (RAM is counted the way Activity Monitor counts it, so 16 GB reads 16 GB). Click CPU or RAM to open Activity Monitor, or Hard Drive to open your home folder in Finder. A tip shows when memory or disk space runs short. Below that, **What starts with your Mac** explains in plain words the three lists macOS keeps (Open at Login, Background Activity and Extensions) and opens System Settings, where you switch them on or off. Tidy doesn't keep switches of its own, so it can never disagree with macOS.
- **Quarantine**: every clean of the last 30 days and what it moved. Tick cleans and **Put Back Selected** or **Delete Selected**, or **Delete All**. Deleting for good always asks first, with the full list and sizes.

Also:

- **Menu bar**: CPU and memory in the menu bar; click it for disk, network, a due reminder, Open Tidy and Quit Tidy. Turn it off with **Show in Menu Bar** in Performance.
- **Settings** (⌘,): reminders when your last Smart Care scan or malware Quick Scan is older than a week, two weeks, a month or three months (Tidy never scans or updates on its own and never sends notifications; reminders show only inside Tidy and its menu bar panel), Open Tidy at login, and the admin helper.

## Safety

- Cleaning never deletes. Items are moved to `~/Library/Application Support/Tidy/Quarantine/<batch>/` with a `manifest.json`, and every move, restore, purge and deletion is logged in `history.jsonl` there.
- Undo from the app, or with `tidy restore <batch-id>` (`tidy quarantine` lists batches). Putting back never overwrites a file that has reappeared.
- Quarantined batches are deleted for good after 30 days, the next time Tidy starts (the system quarantine, the next time Tidy acts as administrator). That and Delete Selected or Delete All in Quarantine, each after a confirmation listing every item and its size, are the only permanent deletes.
- Scanners only look inside an allowlist of junk locations. `/System`, SIP-protected paths, Keychains, Mail and the Photos library are always refused. The malware scan only reads; only what it flags can be moved to quarantine.
- Admin rights: the admin helper (a small launchd daemon, installed from Settings; it needs a Developer ID–signed Tidy.app) answers only the Tidy app signed by the same team, and both sides check each other's code signature. It has four calls: version, quarantine, restore, and delete quarantine batches. It moves only entries directly inside a short list of system folders (`HelperPolicy`) with per-folder name rules (no live logs, nothing named `com.apple.*` in launch folders, only `.app` bundles in /Applications), refuses anything SIP-protected or locked, and never follows a symlink on the way (`SecureFileOps`). What it moves goes to `/Library/Application Support/Tidy/Quarantine`, which it checks only root can change. A background job it moves is stopped first and started again when it's put back.
- Without the helper, the same `PrivilegedService` runs inside Tidy started as root by macOS's password prompt (`osascript`'s `do shell script … with administrator privileges`), for one request, and exits. Only commands Tidy builds itself run that way, every word quoted, and the command line reaches AppleScript as data, never as script text (`AdminPrompt`).

## For developers

```sh
open Package.swift      # Xcode: pick the TidyApp scheme and My Mac, then ⌘R runs the app from source
scripts/check.sh        # build + tests, output saved to build-log.txt
scripts/check.sh && scripts/make-app.sh   # tests first, then the app and disk image
swift test              # core logic tests
swift run tidy scan     # the command-line tool
```

Xcode runs whatever branch is checked out in the folder; the installed app is whatever `scripts/make-app.sh` last built.

**Command-line tool** (also inside the app at `Tidy.app/Contents/Helpers/tidy`): `tidy scan`, `tidy clean [--dry-run]`, `tidy updates`, `tidy stats`, `tidy malware [--quarantine] [path…]`, `tidy quarantine`, `tidy restore <batch-id>`.

**Malware rules**: Apple's XProtect rules are read from macOS (the newest copy Tidy can read). Put your own `.yar`/`.yara` rule files and SHA-256 hash lists (`.txt`, `.csv`, `.tsv`, `.sha256`) in `~/Library/Application Support/Tidy/Signatures`. Rule files with errors are skipped and listed with the reason; files over 128 MB and files only in iCloud aren't read. The engine is libyara 4.5.4, built from source in the package (`Sources/CYara`).

**Signing**: `scripts/make-app.sh` signs ad hoc, which is enough for your own Macs. Set `DEVELOPER_ID` (and `NOTARY_PROFILE`) to sign with a Developer ID and notarize the app and the disk image; the script's header explains the options. The admin helper needs a Developer ID build. `scripts/make-icon.py` redraws the icon. Without Xcode (Command Line Tools only), the build is for this Mac's processor only.

**Git**: `main` holds released versions (tag `v1.0`); every change is made on its own `dev/<topic>` branch and merged into `main` when it works.

### Layout

- `Sources/TidyCore`: scanners (`Scanner` → `[ScanItem]`), cleaners, the quarantine, the path allowlist and the malware scanner (`Malware/`)
- `Sources/CYara`: libyara 4.5.4 as released, plus a small C layer for Swift; `NOTICE.md` says where it came from and its licenses
- `Sources/TidyApp`: the SwiftUI app
- `Sources/tidy`: the command-line tool
- `Sources/TidyHelper`: the admin helper's XPC listener; what it does is `PrivilegedService` in TidyCore, so it's tested
- `Tests/TidyCoreTests`: XCTest suite
- `Resources`: app icon, Info.plist, entitlements and the helper's launchd plist, used by `scripts/make-app.sh`
- `scripts`: `check.sh` (build + test log), `make-app.sh` (Tidy.app and Tidy.dmg), `make-icon.py` (icon)
