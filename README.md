# Tidy

Tidy is a native macOS app that keeps a Mac clean, safe and fast. It finds the hidden junk you can't easily find by hand, removes apps together with everything they leave behind, checks for anything suspicious, and shows how busy the Mac is. It's a free, open alternative to apps like CleanMyMac, deliberately kept small.

## What it's about

Over time a Mac collects things nobody asked for: caches that are never used again, logs, leftovers from installers and from apps you removed, old developer files, background helpers that start on their own, and sometimes things that shouldn't be there at all. Most of it is buried in hidden Library folders. Tidy finds it, explains it, and lets you remove it safely.

What Tidy does **not** try to do: manage your own files. Big movies, duplicates and Downloads are yours, and you know where they are.

Tidy follows a few rules everywhere:

- **You see everything first.** Nothing is removed until you've seen the exact list of items and their sizes.
- **Everything can be undone.** Removed items go to Tidy's Quarantine for 30 days, where you can put them back. Only after 30 days, or when you choose to delete them from Quarantine, are they gone for good.
- **You decide when.** Tidy never scans, cleans or updates anything on its own, and it never shows notifications or popups. At most it reminds you, inside the app, that a scan is due.
- **No special access.** Tidy doesn't need Full Disk Access and never asks for it. When a task needs administrator rights (for example, system caches), macOS asks for your password.
- **It never touches** `/System`, SIP-protected files, Keychains, Mail data or the Photos library, and it only looks in a fixed list of known junk locations.

## Tech stack

| Part | What's used |
| --- | --- |
| Language | Swift 5.10+ |
| Interface | SwiftUI, with AppKit where SwiftUI falls short (menu bar, opening apps and Finder) |
| Platform | macOS 13 Ventura or later, Apple silicon and Intel |
| Build | Swift Package Manager (`Package.swift`), Xcode |
| Malware engine | [libyara](https://github.com/VirusTotal/yara) 4.5.4 (C), included as source in `Sources/CYara`, plus Apple's own XProtect rules |
| System frameworks | ServiceManagement (open at login, admin helper, System Settings links), XPC (talking to the admin helper), Security (code signature checks), CoreServices (Spotlight data for "last opened"), CryptoKit (SHA-256 hashes), Combine |
| macOS tools it calls | `launchctl` (stop and restart background jobs it quarantines), `pkgutil` (what an installer package put on the Mac), `brew` (Homebrew updates), `osascript` (the administrator password prompt), `open` |
| Tests | XCTest (`Tests/TidyCoreTests`) |
| Packaging | `codesign`, `hdiutil` (the .dmg), optionally `notarytool` |

There are no third-party dependencies besides libyara.

The package has five parts:

- **TidyApp**: the app you see (SwiftUI)
- **TidyCore**: all the logic: scanners, cleaning, Quarantine, the malware scanner, update checks, system monitoring
- **TidyHelper**: the optional admin helper, a small background service that does administrator tasks
- **tidy**: a command-line version of Tidy
- **CYara**: the YARA malware engine

## Requirements

- A Mac with macOS 13 Ventura or later
- Xcode (free on the App Store), to build the app. The Command Line Tools alone also work, but then the app is built only for your Mac's processor type.
- Git, to download the code (it comes with Xcode)

## Install

### 1. Download the code

Open Terminal and run:

```sh
git clone https://github.com/rafaelcgama/clean-my-mac.git
cd clean-my-mac
```

If you already have the folder, just `cd` into it.

### 2. Create the .dmg

```sh
scripts/make-app.sh
```

Don't use `sudo`. It takes a few minutes. The script:

1. builds Tidy in release mode for Apple silicon and Intel
2. assembles `build/Tidy.app`: the app, the admin helper, the command-line tool and the icon
3. signs it (ad hoc, which is enough to run on your own Mac)
4. creates the disk image `build/Tidy.dmg`, with Tidy and a shortcut to Applications
5. opens the disk image

Everything it prints is also saved in `build/make-app-log.txt`.

### 3. Install from the .dmg

1. In the window that opens, drag **Tidy** onto **Applications**.
2. Eject the Tidy disk (click ⏏ next to it in Finder's sidebar).
3. Open Tidy from Applications, Launchpad or Spotlight.

From now on Tidy is a normal app. You don't need Terminal to use it.

### Installing on another Mac

Copy `build/Tidy.dmg` to the other Mac and do step 3. The first time you open Tidy there, macOS says it can't check it for malware, because the app isn't signed with a paid Apple Developer ID. Click **Done**, then go to System Settings › Privacy & Security and click **Open Anyway** next to Tidy. You only need to do this once.

To make a build that opens anywhere without that step, you need an Apple Developer ID: run the script with `DEVELOPER_ID` and `NOTARY_PROFILE` set. The top of `scripts/make-app.sh` explains how.

### Updating

1. Quit Tidy with ⌘Q. If it's still in the menu bar, click it there and choose **Quit Tidy**.
2. In the project folder, run:

   ```sh
   git pull
   scripts/make-app.sh
   ```

3. Drag Tidy onto Applications and choose **Replace**.

Your settings and Quarantine are kept, because they're stored outside the app.

### Uninstalling

1. If you installed the admin helper, remove it: Settings › Admin Helper › **Remove Helper**.
2. In Quarantine, put back anything you want to keep.
3. Quit Tidy and drag it from Applications to the Trash.
4. To remove its data too, delete the folder `~/Library/Application Support/Tidy`.

## The tabs

Tidy has eight tabs in its sidebar, each doing one job.

### 1. Smart Care

The quick, all-in-one check. Click **Scan** and Tidy looks for junk (everything System Junk covers) and for suspicious startup items and browser settings (everything Protection checks). It shows one report with:

- **Junk:** how much was found and how many items. **Review & Clean…** shows the full list before anything is removed. **Choose Items in System Junk** takes you there to pick items one by one.
- **Trash:** **Open Trash** opens the Trash in Finder, where you see what's in it and empty it.
- **Protection:** "Nothing suspicious" or how many things are worth a look, with **Open Protection**.
- **Apps:** a pointer to the Uninstaller, because deciding which apps to remove needs you.

After cleaning, it shows how much was moved to Quarantine, with **Undo**. The screen also shows when you last scanned, and a reminder when a scan is due, if you turned reminders on in Settings.

### 2. System Junk

Finds files that take up space without doing anything useful, grouped by kind:

- **Your apps' caches and logs**
- **Package manager caches:** Homebrew, npm, Yarn, pnpm, pip, Cargo, Go, Gradle, CocoaPods, Conda
- **Xcode leftovers:** DerivedData (build files), archives, iOS device support files, simulators and their caches
- **Old macOS installers:** "Install macOS" apps
- **System junk:** system caches, system logs, crash reports and archived logs. These need your administrator password and are never selected for you.

What's selected for you is what's safe to remove. Caches used in the last 30 days are listed but not selected, because they keep apps fast. macOS installers for the version you run or an older one are selected, because you can download them again from Apple. Simulators that Xcode can no longer run are selected too.

Tick what you want, click **Review & Clean…**, check the list and sizes, and confirm. The result screen has **Undo**.

### 3. Uninstaller

Removes apps completely. Dragging an app to the Trash leaves its data behind. Tidy finds that data too:

- settings, caches, saved data and containers in your Library folder
- logs and crash reports
- background helpers and login items the app installed
- files in `/Library` for all users (helpers, background services, settings)
- for apps installed with a .pkg installer, the other files that installer put on the Mac. Files shared with other apps are kept.

The list shows when you last opened each app. Sort by **Last Opened** to find apps you no longer use. Pick an app, check what's found, and click **Review & Remove…**. If the app is running, Tidy asks you to quit it first. Background helpers are stopped before they're removed, and started again if you undo.

**Leftovers of removed apps** finds data from apps you've already deleted. Nothing there is selected for you, because some items can look like leftovers when they aren't, so check each one.

### 4. Updater

Click **Check for Updates** to find newer versions of your apps:

- **Apps that update themselves (Sparkle):** Tidy checks each app's own update feed. **Release Notes** shows what's new. **Open App to Update** opens the app so its own updater installs the update. Beta versions, and versions that need a newer macOS, are skipped.
- **Homebrew apps (casks):** **Update** updates them right from Tidy.
- **App Store apps:** **Open App Store Updates** takes you to the App Store.

Nothing is installed unless you click.

### 5. Protection

Checks what starts automatically with your Mac (launch agents and daemons) and your browsers' settings. It flags, with the reason:

- programs not signed by a developer Apple knows, or changed after they were signed
- programs that run from hidden, temporary or shared folders
- scripts that download or decode code
- startup items that point at programs that no longer exist (left over from removed apps)
- browser settings forced by a profile, such as a locked search engine or extensions installed by policy, a common adware trick

For each finding you can **Reveal in Finder** or **Move to Quarantine…** (it then won't start anymore, and you can undo it for 30 days). macOS's own items are never touched.

Below that are two lists of who can watch you, each with an **Open** button:

- **Apps that can watch you or control your Mac:** opens the System Settings pages for Camera, Microphone, Screen Recording, Input Monitoring and Accessibility, where you see which apps have access and can turn it off
- **Websites that can watch you:** opens the page in each installed browser (Chrome, Firefox, Edge, Brave) that lists websites allowed to use your camera, microphone, location, notifications and more. Safari doesn't let other apps open that page, so Tidy opens Safari and tells you where to look (Settings › Websites).

### 6. Malware Scan

Checks files for known malware, using Apple's own XProtect rules (read from your Mac) and the YARA engine.

- **Quick Scan:** checks Downloads, your apps, what starts at login or boot, and the shared and temporary folders.
- **Scan Folders or Files…:** checks only what you choose.

Anything found is listed with its location and what it matched. Select it and click **Move to Quarantine…**. It can't run from there, and you can put it back if it was a mistake.

Advanced: you can add your own YARA rules (`.yar`, `.yara`) and lists of known-bad SHA-256 hashes (`.txt`, `.csv`, `.tsv`, `.sha256`) with **Open Signatures Folder**. To test the scan safely, use the standard EICAR test file, which Tidy recognizes. Files over 128 MB and files stored only in iCloud aren't read.

### 7. Performance

Shows how busy your Mac is right now:

- **CPU:** how much is in use, out of how many cores. Click it to open Activity Monitor.
- **RAM:** how much memory is in use, out of your total. It's counted the way Activity Monitor counts it, so 16 GB shows as 16 GB, and the bar turns orange or red when memory runs short. Click it to open Activity Monitor on the Memory tab.
- **Hard Drive:** how much space is free on your startup disk. Click it to open your home folder in Finder.

All numbers are read live from macOS. When memory or disk space runs low, a tip explains what to do.

**What starts with your Mac** explains the three lists macOS keeps of things that start by themselves: Open at Login (apps that open when you log in), Background Activity (hidden helpers like updaters) and Extensions (add-ons to macOS). **Open System Settings…** opens the page where you turn them on or off. Tidy has no switches of its own for these, so it can never disagree with macOS.

**Show in Menu Bar** (top right) turns the menu bar monitor on or off.

### 8. Quarantine

Lists everything Tidy removed in the last 30 days, one entry per clean, with how many items and how much space.

- **Put Back Selected:** returns the ticked entries to where they came from. It never overwrites a file that has reappeared since.
- **Delete Selected…** and **Delete All…:** delete for good, after a confirmation that lists every item and its size.
- Right-click an entry and choose **Show in Finder** to see its files.

After 30 days, entries are deleted automatically the next time Tidy starts.

## Menu bar

Tidy shows CPU and memory use in the menu bar. Click it to see free disk space, network activity and any due reminder, plus **Open Tidy** and **Quit Tidy**. While the menu bar monitor is on, closing Tidy's window keeps it running there.

## Settings (⌘,)

- **Reminders:** remind you when your last Smart Care scan or malware Quick Scan is older than a week, two weeks, a month or three months. Reminders appear only in Smart Care and in the menu bar panel, never as notifications.
- **General:** show CPU and memory in the menu bar, open Tidy at login.
- **Admin Helper:** optional. Without it, macOS asks for your password each time Tidy needs administrator rights. With it, a small helper does that work without asking. It only works in a build signed with an Apple Developer ID, so with the normal build you'll be asked for your password instead.

## Where Tidy keeps things

- Your Quarantine: `~/Library/Application Support/Tidy/Quarantine`. Each clean is a folder with a `manifest.json` of what came from where.
- A log of every move, put-back and deletion: `history.jsonl` in the same folder.
- Items that needed administrator rights: `/Library/Application Support/Tidy/Quarantine`.
- Your own malware rules: `~/Library/Application Support/Tidy/Signatures`.

## Working on Tidy's code

This part isn't about the app's tabs. It's for changing Tidy itself: running it from source, testing it and the project layout.

### Run from source

```sh
open Package.swift
```

In Xcode, pick the **TidyApp** scheme and **My Mac**, then press ⌘R. Xcode runs whatever branch is checked out in the folder. The installed app is whatever `scripts/make-app.sh` last built.

### Test

```sh
scripts/check.sh     # builds and runs all tests, output saved in build-log.txt
swift test           # runs the tests
```

### Command-line tool

Built with the app and included in it at `Tidy.app/Contents/Helpers/tidy`, or run it with `swift run tidy …`:

| Command | What it does |
| --- | --- |
| `tidy scan` | list system junk and its size |
| `tidy clean --dry-run` | show what would be moved to Quarantine |
| `tidy clean` | move the preselected junk to Quarantine (asks first) |
| `tidy updates` | list apps and Homebrew casks with newer versions |
| `tidy stats` | CPU, memory, disk, network and the busiest processes |
| `tidy malware [--quarantine] [path…]` | scan for malware |
| `tidy quarantine` | list what's in Quarantine |
| `tidy restore <batch-id>` | put a quarantined batch back |

### Project layout

- `Sources/TidyApp`: the SwiftUI app, one view per tab
- `Sources/TidyCore`: scanners, cleaning, Quarantine, the safe-path allowlist, the malware scanner, update checks, system monitoring
- `Sources/TidyHelper`: the admin helper
- `Sources/tidy`: the command-line tool
- `Sources/CYara`: libyara 4.5.4 and its licenses (`NOTICE.md`)
- `Tests/TidyCoreTests`: the tests
- `Resources`: icon, `Info.plist`, entitlements, the helper's launchd file
- `scripts`: `make-app.sh` (app and .dmg), `check.sh` (build and test), `make-icon.py` (icon)

### Branches

`main` holds released versions (tag `v1.0`). Each change is made on its own `dev/…` branch and merged into `main` once it works.
