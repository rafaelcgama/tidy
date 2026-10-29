# Tidy

A native macOS cleaner. The spec is in [project-context.md](project-context.md).

## Install

```sh
scripts/make-app.sh     # builds Tidy.app and Tidy.dmg for Apple silicon and Intel, then opens the disk image
```

In the window that opens, drag Tidy onto Applications. From then on Tidy is a normal app: open it from Applications, Launchpad or Spotlight, no Terminal needed. To update, run the script again and drag the new Tidy over the old one. The disk image stays in `build/Tidy.dmg` if you want to install it on another Mac.

Give Tidy Full Disk Access in System Settings › Privacy & Security › Full Disk Access, so it can see everything in the Trash and in other protected folders. It still never touches Mail, Photos or Keychains.

Set `DEVELOPER_ID` (and `NOTARY_PROFILE`) to sign with your Developer ID and notarize the app and the disk image; the script's header explains the options. A Developer ID build is also what the admin helper needs; without it, macOS asks for an administrator's password whenever Tidy needs one (see Admin rights). `scripts/make-icon.py` redraws the icon.

Building needs macOS 13+ and Xcode (or the Swift 5.10+ toolchain; without Xcode the build is for this Mac's processor only).

## Develop

```sh
open Package.swift      # Xcode: pick the TidyApp scheme and My Mac, then ⌘R runs the app from source
scripts/check.sh        # build + tests, output saved to build-log.txt
scripts/check.sh && scripts/make-app.sh   # tests first, then the app and disk image
swift test              # core logic tests
swift run TidyApp       # the app window, without installing
swift run tidy scan     # list system junk and sizes
swift run tidy clean --dry-run
```

## What works so far

- **Smart Care**: one scan over system junk, package caches, login items and browser settings, with one report before anything changes. Cleans only the preselected junk, after you review it.
- **System Junk**: user caches, logs, Xcode DerivedData/archives, iOS device support files, Trash, plus system caches, system logs, crash reports and archived system logs (these need administrator rights and are never preselected; live logs are left alone). Caches written to in the last 30 days are listed but not preselected: they keep apps fast, and removing them only means rebuilding them. Review every item and its size, then move to quarantine; Undo from the result screen.
- **Uninstaller**: pick an app to remove it with everything it left: its files in ~/Library (Application Support, Caches, Preferences, Containers and group containers, saved state, cookies and web data, logs and crash reports, its recent-documents list, launch agents…) and in /Library for all users (launch daemons, privileged helper tools, preferences, caches). Matches by bundle id, by the app's name (preselected unless the name is two letters or less), by launch jobs that run something inside the app, and by the helpers the app installs (`SMPrivilegedExecutables`) and the tools its jobs run. Its background jobs are stopped as they're removed and started again on Undo. Apps and files that belong to root need administrator rights. The result lists anything that wasn't moved and why. "Leftovers of removed apps" finds data of apps that are gone (never preselected).
- **Clutter**: duplicate files (size → quick hash → full hash → byte-by-byte check; hard links ignored), similar photos (bursts, edited or resized copies, found with a perceptual hash of a small preview; the best one, with the most pixels, is listed first) and large & old files in folders you pick. App data (~/Library, except iCloud Drive and cloud storage) and project dependencies or build output (node_modules, Pods, Rust's target, site-packages and the like) are left out unless you choose those folders, since copies there are normal and removing one breaks what it belongs to. Nothing preselected; you can't remove every copy of a file or every photo of a group. The Photos library is never scanned.
- **Developer**: package caches (Homebrew, npm, Yarn, pnpm, pip, Cargo, Gradle, Go, CocoaPods, Conda) and build output in your projects (node_modules, Rust target, SwiftPM .build). A cache used in the last 30 days isn't preselected, and build output never is.
- **Protection**: heuristics for launch agents/daemons running from temporary or hidden folders, scripts that download or decode code, jobs pointing at deleted programs, and browser settings locked by a policy (a common adware trick). Flagged launch agents and daemons can be moved to quarantine (the ones in /Library need administrator rights; macOS's own are never touched).
- **Malware Scan**: checks files with YARA rules and lists of known-bad SHA-256 hashes. The rules are Apple's own XProtect rules (read from macOS, newest copy; Full Disk Access may be needed), any `.yar`/`.yara` files and hash lists (`.txt`, `.csv`, `.tsv`, `.sha256`) you put in `~/Library/Application Support/Tidy/Signatures`, and a built-in signature for the harmless EICAR test file, so you can try it. Quick Scan covers Downloads, the code inside your apps (executables, helpers, login items, XPC services, loose libraries), what launchd starts and the programs it starts, and the shared and temporary folders; or scan any folders or files. A file in an app flags the whole app, and a launch job that starts a detected program is flagged with it. Everything found starts selected and goes through the review to quarantine, so it's reversible. Rule files with errors are skipped and listed with the reason; files over 128 MB and files only in iCloud aren't read. The engine is libyara 4.5.4, built from source in the package (`Sources/CYara`).
- **Shredder**: drop files or folders, see how many files and bytes that is, type `shred`, and they're overwritten with random data, flushed to the disk and deleted. This is the one thing in Tidy that can't be undone. It refuses what Tidy never touches (Photos libraries and keychains wherever they are, Mail's data, Tidy's own quarantine) and any folder holding one, whole volumes and the home folder, locked files, and files with other hard links; it never follows a symlink or leaves the disk a folder is on. Files only in iCloud are deleted without being downloaded. Each run is logged in `~/Library/Application Support/Tidy/shred-log.jsonl` (paths and sizes, never contents). The screen says plainly that SSDs, iCloud and backups can keep old data, and whether FileVault is on.
- **Space Map**: treemap of any folder; click a folder to go into it, right-click to reveal in Finder. Read-only.
- **Privacy**: browsing and download history, cookies, autofill data and saved tabs for Safari, Chrome, Brave, Edge, Arc, Vivaldi, Chromium, Opera and Firefox (every profile), plus macOS recent items. Nothing preselected; passwords, bookmarks, extensions and settings are never listed, and the allowlist holds only those exact files. A browser has to be quit before its data is moved. Firefox history shares a file with bookmarks, so it's left to Firefox.
- **Performance**: one screen for how busy the Mac is and what starts with it. Three boxes of the same size, read live from macOS: CPU (used, of how many cores), RAM (used, of the RAM macOS reports, counted the way Activity Monitor does, so 16 GB reads 16 GB; the bar turns orange or red under memory pressure) and Hard Drive (free, of the startup disk's size). Click CPU or RAM to open Activity Monitor on that tab (when it isn't already open), or Hard Drive to open your home folder in Finder. Tips show when memory or disk run short when memory or disk run short. Switches for apps that open at login (read and changed through System Events, so macOS asks once; Tidy remembers what it turned off so it can go back on) and background items, the launch agents and daemons apps install (macOS's own aren't listed). Switching one off is launchd's own switch (`launchctl disable`) and stops it now; nothing is moved or deleted, and on turns it back on and starts it. System-wide items ask for an administrator's password. Plus the maintenance tasks Free Up Memory (`purge`), Flush DNS Cache and Reindex Spotlight. Processes aren't listed: Activity Monitor does that.
- **Menu bar monitor**: CPU and memory in the menu bar; click for disk and network. Turn it off in Performance › Show in Menu Bar. While it's on, closing the window keeps Tidy in the menu bar.
- **Cloud**: large files in iCloud Drive, Dropbox, Google Drive, OneDrive and other File Provider folders, with Remove Download (the file stays in the cloud), plus local files that also exist in a cloud folder (never preselected; cloud folders themselves are never touched).
- **Updater**: apps that update with Sparkle are checked against their own feeds (beta channels and versions that need a newer macOS are skipped), Homebrew casks via `brew outdated --cask --greedy`. Casks update from the app with one click; Sparkle apps are opened so their own signed updater installs the update; App Store apps go to the App Store. Nothing installs without you.
- **Reminders**: Tidy never scans or updates anything on its own, and it never sends notifications. In Settings (⌘,) you can ask it to remind you when your last Smart Care scan or malware Quick Scan is older than a week, two weeks, a month or three months. Smart Care and Malware Scan show when you last ran them, and a due reminder shows in Smart Care and in the menu bar panel. Settings also has Open Tidy at login.
- **Quarantine**: every clean of the last 30 days with what it moved; Put Back any of them, or delete one for good now (Delete Now) or all of them (Empty Quarantine), after a confirmation that lists every item and its size.
- **Admin rights**: what needs root (system caches and logs, apps installed for all users, files in /Library, system-wide background items, the maintenance tasks) runs after macOS asks for an administrator's password, each time: Tidy starts its own program as root for that one request (`AdminCommand`), under the same rules as the admin helper. Settings › Admin Helper installs that helper instead, a small launchd daemon, so Tidy doesn't have to ask every time; it needs a Developer ID–signed Tidy.app (see above). See Safety for what either may do.
- **CLI**: `tidy scan`, `tidy clean [--dry-run]`, `tidy duplicates [folder]`, `tidy similar [folder]`, `tidy large [folder]`, `tidy updates`, `tidy stats`, `tidy privacy`, `tidy malware [--quarantine] [path…]`, `tidy shred <path…>`, `tidy quarantine`, `tidy restore <batch-id>`.

## Safety

- Cleaning never deletes. Items are moved to `~/Library/Application Support/Tidy/Quarantine/<batch>/` with a `manifest.json`, and every move, restore, purge and deletion is appended to `history.jsonl` there.
- Undo from the app, or with `tidy restore <batch-id>` (`tidy quarantine` lists batches). Restore never overwrites a file that has reappeared.
- Batches older than 30 days are deleted for good the next time the app or CLI starts; in the system quarantine, the next time Tidy acts as administrator. That, Delete Now and Empty Quarantine in Quarantine (each after a confirmation listing every item and its size), and the Shredder are the only permanent deletes.
- The Shredder is the one exception to quarantine, and only for what you hand it, after you type `shred`. Every run is logged.
- The malware scan only reads. When it finds something, exactly the flagged items are the allowlist for moving them to quarantine.
- Scanners only look inside an allowlist of junk locations; `/System`, Keychains, Mail and the Photos library are always refused.
- The admin helper answers only the Tidy app signed by the same team (both sides check each other's code signature) and has five calls: version, quarantine, restore, delete quarantine batches, and three fixed maintenance commands. It moves only entries directly inside a short list of system folders (`HelperPolicy`), with per-folder name rules (no live logs, nothing named `com.apple.*` in launch folders, only `.app` bundles in /Applications), refuses anything SIP-protected or locked, and never follows a symlink on the way (`SecureFileOps`). What it moves goes to `/Library/Application Support/Tidy/Quarantine`, which it checks only root can change; the same 30-day rule applies, and Put Back works the same. A daemon it moves is stopped first (`launchctl bootout`) and started again when it's put back.
- Without the helper, the same `PrivilegedService` runs inside Tidy started as root by macOS's password prompt (`osascript`'s `do shell script … with administrator privileges`), for one quarantine, restore or delete request, and exits. Only commands Tidy builds itself run that way, every word quoted, and the command line reaches AppleScript as data, never as script text (`AdminPrompt`). Switching background items uses `launchctl disable`/`enable` on the job's label, and only labels made of letters, digits and `._-@+` are passed.

## Layout

- `Sources/TidyCore`: scanners (`Scanner` → `[ScanItem]`), cleaners, the quarantine, the path allowlist, the space-map size tree and treemap layout, the malware scanner (`Malware/`) and the shredder
- `Sources/CYara`: libyara 4.5.4 as released, plus a small C layer for Swift; `NOTICE.md` says where it came from and its licenses
- `Sources/TidyApp`: SwiftUI app
- `Sources/tidy`: command-line tool
- `Sources/TidyHelper`: the privileged helper's XPC listener; what it does is `PrivilegedService` in TidyCore, so it's tested
- `Tests/TidyCoreTests`: XCTest suite
- `Resources`: app icon, Info.plist, the app's entitlements (sending Apple Events, for System Events) and the helper's launchd plist, used by `scripts/make-app.sh`
- `scripts`: `check.sh` (build + test log), `make-app.sh` (Tidy.app and Tidy.dmg), `make-icon.py` (icon)
