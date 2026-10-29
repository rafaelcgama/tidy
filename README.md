# Tidy

Tidy is a Mac app that keeps your Mac clean, safe and fast. It finds the junk you can't easily find yourself, removes apps along with everything they leave behind, checks for anything suspicious, and shows how busy your Mac is.

## How Tidy works

- **You see everything first.** Nothing is removed until you've seen the list of items and their sizes.
- **Everything can be undone.** Whatever Tidy removes goes to its Quarantine for 30 days, where you can put it back. After 30 days it's deleted for good.
- **You decide when.** Tidy never scans, cleans or updates anything on its own, and it never sends notifications.
- **No special access.** Tidy doesn't need Full Disk Access. When something needs administrator rights, macOS asks for your password.

## Install

You need a Mac with macOS 13 or later, and Xcode (free on the App Store) to build the installer.

### 1. Get the code

Open Terminal and run:

```sh
git clone https://github.com/rafaelcgama/clean-my-mac.git
cd clean-my-mac
```

If you already have the folder, go into it with `cd` instead.

### 2. Build the installer (Tidy.dmg)

```sh
scripts/make-app.sh
```

It takes a few minutes. When it's done, it creates `build/Tidy.dmg` and opens it.

### 3. Install

1. In the window that opens, drag **Tidy** onto **Applications**.
2. Eject the Tidy disk (click ⏏ next to it in Finder's sidebar).
3. Open Tidy from Applications, Launchpad or Spotlight.

### Installing on another Mac

Copy `build/Tidy.dmg` to the other Mac and do step 3. The first time you open Tidy there, macOS says it can't check it for malware, because the app isn't signed with a paid Apple Developer ID. Click **Done**, go to System Settings › Privacy & Security, and click **Open Anyway** next to Tidy. You only need to do this once.

### Updating

1. Quit Tidy with ⌘Q. If it's still in the menu bar, click it there and choose **Quit Tidy**.
2. In the project folder, run `git pull` and then `scripts/make-app.sh`.
3. Drag Tidy onto Applications and choose **Replace**.

Your settings and your Quarantine are kept.

### Uninstalling

1. In Tidy's Quarantine, put back anything you want to keep.
2. Quit Tidy and drag it from Applications to the Trash.
3. To remove its data too, delete the folder `~/Library/Application Support/Tidy`.

## The tabs

### Smart Care

One scan that checks for junk and for suspicious startup items and browser settings. The results show:

- **Junk:** how much was found. Click **Review & Clean…** to see the list and clean it, or **Choose Items in System Junk** to pick items yourself.
- **Trash:** **Open Trash** shows the Trash in Finder, where you can empty it.
- **Protection:** whether anything suspicious was found, with a button to Protection.
- **Apps:** a button to the Uninstaller, because deciding which apps to remove is up to you.

It also shows when you last scanned, and a reminder when a scan is due (see Settings).

### System Junk

Finds files that take up space without doing anything useful:

- caches and logs of your apps
- package caches from Homebrew, npm, Yarn, pnpm, pip, Cargo, Go, Gradle, CocoaPods and Conda
- Xcode leftovers: build files, archives, old simulators and device support files
- old "Install macOS" apps
- system caches, system logs and crash reports (these need your password and are never preselected)

Caches used in the last 30 days are listed but not selected, because they keep your apps fast. Tick what you want removed, click **Review & Clean…**, check the list and confirm. Afterwards you can click **Undo** right away.

### Uninstaller

Lists your apps and when you last opened each one. Sort by **Last Opened** to find apps you no longer use. Pick an app to see it together with everything it left on your Mac: settings, caches, saved data, background helpers, and files its installer put elsewhere. Click **Review & Remove…** to remove it all. If the app is running, Tidy asks you to quit it first.

**Leftovers of removed apps** finds data from apps you've already deleted. Nothing there is preselected, so check each item.

### Updater

Click **Check for Updates** to find newer versions of:

- **apps that update themselves** (via Sparkle): **Open App to Update** opens the app so its own updater installs the update
- **Homebrew apps:** **Update** updates them from Tidy
- **App Store apps:** **Open App Store Updates** takes you there

Nothing is installed unless you click.

### Protection

Checks the programs that start with your Mac and your browser settings. It flags, for example:

- programs that aren't signed by a known developer, or were changed after signing
- programs running from hidden or temporary folders
- scripts that download code
- startup items left behind by apps that are gone
- browser settings locked by a profile, a common adware trick

Each finding says why it was flagged. You can **Reveal in Finder** or **Move to Quarantine…**.

Below that are two lists, each with an **Open** button:

- **Apps that can watch you or control your Mac:** the System Settings pages for Camera, Microphone, Screen Recording, Input Monitoring and Accessibility
- **Websites that can watch you:** the page in each of your browsers (Chrome, Firefox, Edge, Brave) that lists the websites allowed to use your camera, microphone, location and more. Safari doesn't let other apps open that page, so Tidy opens Safari and tells you where to look.

### Malware Scan

Checks your files for malware with Apple's own XProtect rules.

- **Quick Scan** checks Downloads, your apps, what starts with your Mac, and the shared and temporary folders.
- **Scan Folders or Files…** checks only what you choose.

Anything found is listed with its location and what it matched. Select it and click **Move to Quarantine…**. You can add your own rule files with **Open Signatures Folder**.

### Performance

- **CPU, RAM and Hard Drive** show live how much is in use. Click CPU or RAM to open Activity Monitor, or Hard Drive to open your home folder in Finder.
- A tip appears when memory or disk space is running low.
- **What starts with your Mac** explains the three lists macOS keeps: Open at Login, Background Activity and Extensions. **Open System Settings…** opens the page where you turn them on or off.
- **Show in Menu Bar** turns the menu bar monitor on or off.

### Quarantine

Lists everything Tidy removed in the last 30 days, one entry per clean.

- **Put Back Selected** returns the ticked items to where they were.
- **Delete Selected…** and **Delete All…** delete for good, after showing the full list and sizes.
- Right-click an entry and choose **Show in Finder** to see its files.

## Menu bar

Tidy shows CPU and memory use in the menu bar. Click it to see disk space, network activity and any due reminder, and to open or quit Tidy. While it's in the menu bar, closing the window keeps Tidy running.

## Settings (⌘,)

- **Reminders:** a reminder when your last Smart Care scan or Quick Scan is older than a week, two weeks, a month or three months. It shows only inside Tidy and in its menu bar.
- **General:** show CPU and memory in the menu bar, and open Tidy at login.
- **Admin Helper:** an optional helper that does administrator tasks without asking for your password each time. It only works in a build signed with a paid Developer ID; the normal build asks for your password instead.

## For developers

```sh
open Package.swift     # Xcode: TidyApp scheme, My Mac, ⌘R runs the app from source
scripts/check.sh       # builds and runs the tests, output in build-log.txt
swift test             # runs the tests
```

- Xcode runs the branch checked out in the folder; the installed app is whatever `scripts/make-app.sh` last built.
- `main` holds released versions (tag `v1.0`). Each change is made on its own `dev/…` branch and merged into `main` once it works.
- `scripts/make-app.sh` explains in its header how to sign with a Developer ID and notarize.
- Code: `Sources/TidyApp` (the app), `Sources/TidyCore` (scanning, cleaning, quarantine, malware scan), `Sources/TidyHelper` (admin helper), `Sources/tidy` (command-line tool), `Sources/CYara` (the YARA malware engine), `Tests/TidyCoreTests` (tests).
- The original spec is in [project-context.md](project-context.md).
