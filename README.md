# Tidy

Tidy keeps your Mac clean, safe and fast. It finds the junk that's hard to find by hand: what removed apps and old installers leave behind, caches and logs nothing uses anymore, and background helpers nobody needs. It removes apps completely, checks for malware and for anything suspicious that starts on its own, and shows how busy your Mac is. Whatever it removes can be put back for 30 days.

Tidy is a native Mac app for macOS 13 Ventura or later, on Apple silicon and Intel.

## Install

1. Download [**Tidy.dmg**](https://github.com/rafaelcgama/clean-my-mac/releases/latest/download/Tidy.dmg) from the latest [release](https://github.com/rafaelcgama/clean-my-mac/releases).
2. Open it and drag **Tidy** onto **Applications**. Then eject the Tidy disk (⏏ next to it in Finder's sidebar).
3. Open Tidy from Applications.

The first time you open it, macOS says it can't check Tidy for malware, because Tidy isn't signed with a paid Apple Developer ID. Click **Done**, open **System Settings › Privacy & Security**, scroll down, click **Open Anyway** next to the message about Tidy, and confirm with your password. You only do this once.

If you'd rather use Terminal, this downloads and opens the disk image without that warning:

```sh
curl -fL -o ~/Downloads/Tidy.dmg https://github.com/rafaelcgama/clean-my-mac/releases/latest/download/Tidy.dmg && open ~/Downloads/Tidy.dmg
```

### Update

Tidy checks for a new version when it starts, and Smart Care and the menu bar panel say when one is out. To check now, choose **Tidy › Check for Updates…** while Tidy's window is open, or **Check for Updates…** from the ⚙ menu in the menu bar panel. The Software Update window shows what's new. **Install Update** downloads the new Tidy, checks it, replaces the old one and opens it again. Nothing is installed until you click, and your settings and Quarantine are kept.

### Uninstall

1. In Quarantine, put back anything you want to keep.
2. If you installed the admin helper, remove it in **Settings › Admin Helper**.
3. Quit Tidy and drag it from Applications to the Trash.
4. To remove its data too, delete `~/Library/Application Support/Tidy` and, if it exists, `/Library/Application Support/Tidy`.

## How Tidy works

- **You see everything first.** Nothing is removed until you've reviewed the exact items and their sizes.
- **Everything can be undone.** What Tidy removes goes to Quarantine for 30 days, where you can put it back. It's gone for good only after that, or when you delete it from Quarantine yourself.
- **You decide when.** Tidy never scans, cleans or updates on its own, and it never shows notifications. At most it tells you, inside Tidy, that a scan is due or that a new version is out.
- **Speed comes first.** Caches that keep your apps fast stay: only caches nothing has used for 30 days are selected.
- **Safe places only.** Tidy looks only in known junk locations. It never touches `/System`, files macOS protects, Keychains, Mail's files or the Photos library, and it works without Full Disk Access.
- **Your files are yours.** Tidy doesn't hunt for big or duplicate files. From Downloads it only offers to remove old installers, and malware if a scan finds any.

macOS may ask you four things while you use Tidy:

- **Your administrator password**, when Tidy removes something that belongs to the whole Mac, such as system caches or an app's helper in `/Library`. The optional admin helper does that without asking (see Settings).
- **Whether Tidy may look in Downloads**, the first time Smart Care or a malware scan does.
- **Whether Tidy may control Finder**, the first time you click **Open Trash**, so that Finder opens the whole Trash, as the Dock does. If you don't allow it, Tidy opens your Trash folder, which shows only what you deleted on this Mac, not in iCloud Drive or on other disks.
- **Whether Tidy may control Mail**, the first time you click **Mark Junk and Trash as Read**. If you don't allow it, Smart Care says where to turn it on later.

Because Tidy isn't signed with a Developer ID, macOS may ask the last three again after Tidy updates.

## The tabs

Each of the six tabs in the sidebar does one job.

### Smart Care

One scan for junk, login items and browser settings. The report shows:

- **Cleanup:** how much junk is selected for you. **Review & Clean…** lists everything the scan found, by kind. If some leftovers of removed apps aren't selected because Tidy can't be sure about them, the report says how many.
- **Trash:** **Open Trash** opens Finder's Trash, the same one the Dock opens, where you see what's in it and empty it. macOS keeps the Trash private from apps without Full Disk Access.
- **Junk and Trash Mail:** **Mark Junk and Trash as Read** has Mail mark the unread messages in its Junk and Trash as read, in all your accounts, and says how many. Mail does the marking, so they show as read on your other devices too, and Tidy never opens Mail's files. If Mail isn't open, it opens.
- **Protection:** "Nothing suspicious", or how many findings there are, with **Open Protection**.
- **Apps:** which apps to remove is your call, so this points you to the Uninstaller.

The list under **Review & Clean…** works like Quarantine's. Tick items one by one or a whole kind at once, or use **Select All**. **Clean Selected…** and **Clean All…** show exactly what moves, with sizes, before anything does. Right-click an item to reveal it in Finder, and **Report** goes back to the report.

After cleaning, Smart Care shows how much was moved to Quarantine, with **Undo**. Its start screen shows when you last scanned, a reminder when a scan is due, and a new version of Tidy when there is one.

The scan looks for what takes up space without doing anything useful, grouped by kind:

- **Your apps' caches and logs**
- **Package manager caches:** Homebrew, npm, Yarn, pnpm, pip, Cargo, Go, Gradle, CocoaPods, Conda
- **Xcode leftovers:** DerivedData, archives, iOS device support files, simulators and their caches
- **Old macOS installers:** the "Install macOS" apps
- **Installers in Downloads:** .dmg, .pkg and .xip files that have done their job
- **Leftovers of removed apps:** what deleted apps left in your Library and in `/Library` for all users: settings, saved data, window state, web caches, cookies, startup items and the helpers they run, and folders named after the app's maker once none of its apps is left (a "VMware" folder, say)
- **System caches, logs and crash reports**, which need your administrator password

What's selected for you is what's safe to remove:

- caches, Xcode build files and simulator caches nothing has used for 30 days, and your apps' logs
- simulators Xcode can no longer run
- macOS installers for the version you run or an older one, since Apple lets you download them again
- installers in Downloads once they're a week old
- of removed apps' leftovers, only what can't matter: startup items whose program is gone (they start nothing), window state, web caches, cookies and recent-documents lists

Everything else is listed for you to tick, and system junk is never selected for you.

An app counts as installed wherever it is: in Applications, in your own Applications folder, or anywhere else Spotlight finds it, along with the extensions and helpers inside it. Files an app maker's apps share, such as updaters, stay while any app from that maker is installed. What Tidy can't be sure about is listed but not selected, because an app kept somewhere Tidy can't see looks removed. Removed apps' containers are left alone, because macOS asks before an app looks inside another app's container.

### Uninstaller

Removes an app together with everything it put on your Mac:

- its settings, caches, saved data and containers in your Library
- its logs and crash reports
- the login items, background helpers and startup items it installed
- its files in `/Library` for all users
- for apps installed with a .pkg, everything that package installed. Files other apps share are kept.

The list includes iPhone and iPad apps installed on the Mac, and it updates as soon as an app is added to or removed from Applications. Sort the list by **Last Opened** to find apps you no longer use. Pick an app and check what was found: tick items one by one, or use **Select All**. **Remove Selected…** and **Remove All…** show exactly what moves before anything does. A running app has to be quit first (**Quit App**). Background helpers are stopped before they're removed, and started again if you undo.

Smart Care finds what apps you already deleted left behind.

### Updater

**Check for Updates** finds newer versions of your apps:

- **Apps that update themselves (Sparkle):** **Release Notes** shows what's new, and **Open App to Update** opens the app so its own updater installs it. Betas and versions that need a newer macOS are skipped.
- **Homebrew apps:** **Update** updates them from Tidy. If Homebrew can't, Tidy shows why.

The list refreshes after each update. App Store apps are left to the App Store, and nothing is installed unless you click. Tidy updates itself (see [Update](#update)).

### Protection

Everything that could harm your Mac or watch you, on one screen.

**Malware** checks your files against Apple's own malware list: the XProtect rules macOS uses, which Apple keeps up to date. Tidy reads them from your Mac and runs them with the YARA engine.

- **Quick Scan:** Downloads, your apps, what starts at login or boot, and the shared and temporary folders
- **Scan Folders or Files…:** only what you choose

Each threat shows where it is and what it matched. Tick threats or use **Select All** in the bar under the list: **Quarantine Selected…** and **Quarantine All…** move them where they can't run, and you can put them back if it was a mistake. Apple's list is mentioned only if something is wrong with it. Files over 128 MB and files stored only in iCloud aren't read.

For advanced use, put your own YARA rules (`.yar`, `.yara`) and lists of known-bad SHA-256 hashes (`.txt`, `.csv`, `.tsv`, `.sha256`) in `~/Library/Application Support/Tidy/Signatures`. A file that can't be used is named on the screen. To test the scan safely, use the standard EICAR test file, which Tidy recognizes.

**Startup items and browser settings** are checked each time you open Protection, and **Check Again** checks once more. Tidy looks at what starts on its own (launch agents and daemons) and at your browsers' settings, and flags, with the reason:

- programs not signed by a developer Apple knows, or changed after they were signed
- programs that run from hidden, temporary or shared folders
- scripts that download or decode code
- browser settings forced by a profile, such as a locked search engine or extensions installed by policy, a common adware trick

For each finding, **Reveal in Finder** shows it and **Move to Quarantine…** stops it from starting (you can undo that for 30 days). macOS's own items are never touched. Startup items whose program is gone start nothing, so Smart Care lists them with the junk instead.

Below them are two lists of who can watch you, each with an **Open** button:

- **Apps that can watch you or control your Mac:** the System Settings pages for Camera, Microphone, Screen Recording, Input Monitoring and Accessibility, where you see which apps have access and can turn it off
- **Websites that can watch you:** the page in Chrome, Firefox, Edge and Brave, when they're installed, that lists the sites allowed to use your camera, microphone, location, notifications and more

### Performance

Live numbers from macOS:

- **CPU:** how much is in use, out of how many cores. Click it to open Activity Monitor.
- **RAM:** how much is in use, out of your total, counted the way Activity Monitor counts it (16 GB shows as 16 GB). The bar turns orange or red when RAM runs short. Click it to open Activity Monitor's Memory tab.
- **Hard Drive:** how much space is free on your Mac's hard drive. Click it to open your home folder in Finder.

When RAM or hard drive space runs low, a tip says what to do. **What starts with your Mac** explains the three lists macOS keeps of things that start by themselves (Open at Login, Background Activity and Extensions), and **Open System Settings…** opens the page where you turn them off. Tidy has no switches of its own for these, so it never disagrees with macOS. **Show in Menu Bar**, at the top right, turns the menu bar monitor on or off.

### Quarantine

Everything Tidy removed in the last 30 days, one entry per clean, with how many items and how much space:

- **Put Back Selected** returns the ticked entries to where they came from. It never overwrites a file that has reappeared since.
- **Delete Selected…** and **Delete All…** delete for good, after a confirmation that lists every item and its size.
- Right-click an entry and choose **Show in Finder** to see its files.

Entries older than 30 days are deleted for good the next time Tidy starts.

## Menus, menu bar and settings

### Menu bar

Tidy lives in the menu bar, like other menu bar apps: it shows CPU and RAM use there. Click it to see CPU, RAM and Hard Drive with a bar each, any reminder that's due, a new version of Tidy when there is one, **Open Tidy**, **Quit Tidy** and a ⚙ menu with:

- **Settings…** (see below)
- **Check for Updates…** (see [Update](#update))
- **Tidy Help**, which opens this guide
- **About Tidy:** the version and build you have, links to this guide and the release notes, and the licenses of the code Tidy includes

While Tidy's window is open, Tidy is also in the Dock and has its menus at the top of the screen, like any app. Closing the window takes it out of the Dock and keeps it running in the menu bar, and when Tidy opens at login it starts there, with no window.

### Menus

While Tidy's window is open, the **Tidy** menu has **About Tidy**, **Check for Updates…** and **Settings…**, and **Help › Tidy Help** opens this guide. With the menu bar monitor turned off (**Settings › General**), Tidy is an ordinary app: it's in the Dock while it runs, and closing its window quits it.

### Settings

- **Reminders:** off until you turn them on. Tidy reminds you when your last Smart Care scan or malware Quick Scan is older than one week, two weeks, a month or three months. Reminders show only in Smart Care and the menu bar panel, never as notifications.
- **General:** show CPU and RAM in the menu bar (turned off, Tidy is an ordinary app in the Dock), and open Tidy at login.
- **Admin Helper:** optional. Without it, macOS asks for your password each time Tidy needs administrator rights. With it, a small helper does that work without asking, staying within a short list of system folders. It needs a Tidy signed with an Apple Developer ID (see [Build the .dmg yourself](#build-the-dmg-yourself)), so with the normal download macOS asks for your password instead.

### Where Tidy keeps things

- **Quarantine:** `~/Library/Application Support/Tidy/Quarantine`, one folder per clean, each with a `manifest.json` of what came from where. `history.jsonl` in the same folder logs every move, put-back and deletion.
- **What needed administrator rights:** `/Library/Application Support/Tidy/Quarantine`
- **Your own malware rules:** `~/Library/Application Support/Tidy/Signatures`

## Working on Tidy

### Requirements

- macOS 13 Ventura or later
- Xcode, free on the App Store. With only the Command Line Tools, Tidy builds for your Mac's processor only.

### Run from source

```sh
git clone https://github.com/rafaelcgama/clean-my-mac.git
cd clean-my-mac
open Package.swift
```

In Xcode, choose the **TidyApp** scheme and **My Mac**, then press ⌘R. Xcode runs whatever branch is checked out. Runs from Xcode have no app bundle, so they show in the Dock as a plain program (exec) even with the window closed, while the installed Tidy leaves the Dock when its window closes.

### Test

```sh
scripts/check.sh
```

Builds everything and runs every test. The full output is saved in `build-log.txt`. `swift test` runs the tests alone.

### Build the .dmg yourself

```sh
scripts/make-app.sh
```

Don't use `sudo`. In a few minutes the script builds Tidy for Apple silicon and Intel, assembles `build/Tidy.app` (the app, the admin helper, the command-line tool and the icon), signs it ad hoc, makes `build/Tidy.dmg` and opens it. What it prints is also saved in `build/make-app-log.txt`.

Settings for the script, put before the command:

| Setting | What it does |
| --- | --- |
| `DEVELOPER_ID="Developer ID Application: Name (TEAMID)"` | signs with your Apple Developer ID and the hardened runtime, which the admin helper needs |
| `NOTARY_PROFILE=name` | also notarizes the app and the disk image, so they open on any Mac without a warning (needs `DEVELOPER_ID`; create the profile with `xcrun notarytool store-credentials`) |
| `BUNDLE_ID=com.you.tidy` | the app's id (default `com.example.tidy`). Settings and macOS permissions are tied to it. |
| `VERSION=x.y.z` | builds with that version number instead of the one in the `VERSION` file |
| `NO_OPEN=1` | doesn't open the disk image at the end |

### Command-line tool

Included in the app at `Tidy.app/Contents/Helpers/tidy`, or run it with `swift run tidy …`:

| Command | What it does |
| --- | --- |
| `tidy scan` | lists system junk and its size |
| `tidy clean --dry-run` | shows what `tidy clean` would move to Quarantine |
| `tidy clean` | moves the selected junk to Quarantine, after you type yes. What needs administrator rights is skipped. |
| `tidy updates` | lists apps and Homebrew casks with newer versions |
| `tidy stats` | CPU, RAM, hard drive, network and the busiest processes |
| `tidy malware [--quarantine] [path…]` | scans for malware, and with `--quarantine` moves what it finds to Quarantine |
| `tidy quarantine` | lists what's in Quarantine |
| `tidy restore <batch-id>` | puts a quarantined batch back |

### Project layout

| Path | What's there |
| --- | --- |
| `Sources/TidyApp` | the app (SwiftUI), one view per tab |
| `Sources/TidyCore` | all the logic: scanners, cleaning, Quarantine, the allowlist of safe paths, the malware scanner, update checks, system monitoring |
| `Sources/TidyHelper` | the optional admin helper |
| `Sources/tidy` | the command-line tool |
| `Sources/CYara` | libyara 4.5.4, the YARA engine, with its licenses in `NOTICE.md` |
| `Tests/TidyCoreTests` | the tests (XCTest) |
| `Resources` | the icon, `Info.plist`, the app's entitlements and the helper's launchd file |
| `scripts` | `make-app.sh` (app and .dmg), `check.sh` (build and test), `make-icon.py` (icon) |
| `VERSION` | Tidy's version number |
| `.github/workflows/build.yml` | tests and builds every push, and publishes each change to `main` as a release |

### Tech stack

| Part | What's used |
| --- | --- |
| Language | Swift 5.10 or later |
| Interface | SwiftUI, with AppKit where SwiftUI falls short (menu bar, Dock icon, opening apps and Finder) |
| Build | Swift Package Manager (`Package.swift`) and Xcode |
| Malware engine | [libyara](https://github.com/VirusTotal/yara) 4.5.4 (C), included as source, running Apple's XProtect rules |
| System frameworks | ServiceManagement (open at login, the admin helper, System Settings links), XPC (talking to the admin helper), Security (code signatures), CoreServices (when apps were last opened), CryptoKit (SHA-256), Combine |
| macOS tools it runs | `launchctl` (stops and restarts startup items it moves), `pkgutil` (what an installer package put on the Mac), `mdfind` (apps installed outside Applications), `brew` (Homebrew updates), `osascript` (the administrator password prompt, asking Finder to open the Trash and asking Mail to mark junk and trash as read), `hdiutil`, `codesign` and `ditto` (installing an update), `open` |
| Packaging | `codesign` and `hdiutil`, optionally `notarytool` |
| Releases | GitHub Actions |

There are no third-party dependencies besides libyara.

### Branches and releases

`main` holds what's released. Each change is made on its own `dev/…` branch, pushed to GitHub and merged into `main` through a pull request. GitHub Actions tests and builds every push (the disk image is attached to the run), and publishes every merge into `main` as a release with `Tidy.dmg`, which is where Check for Updates… gets new versions. The pull request's title and description become the release notes Tidy shows. `VERSION` sets the version number, so change it in the pull request to give a release a new one. The build number is the UTC date and time of the build, so two builds of one version are told apart.

### Acknowledgements

Tidy's malware scan runs on [YARA](https://virustotal.github.io/yara/) 4.5.4 by The YARA Authors, under the BSD 3-Clause License. One of its modules is under the Apache License 2.0. Both licenses are in `Sources/CYara/NOTICE.md` and ship inside Tidy.app, and About Tidy shows YARA's.
