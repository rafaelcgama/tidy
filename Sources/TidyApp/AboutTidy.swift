import AppKit
import SwiftUI
import TidyCore

/// About Tidy, in the Tidy and Help menus.
struct AboutTidyButton: View {
    var body: some View {
        Button("About Tidy") { AboutTidy.show() }
    }
}

/// Tidy Help, in the Help menu: Tidy's guide, the README on GitHub.
struct TidyHelpButton: View {
    var body: some View {
        Button("Tidy Help") { NSWorkspace.shared.open(AboutTidy.guide) }
    }
}

/// macOS's own About window: Tidy's icon, name, version and build (from Info.plist), what it does,
/// links to its page and release notes, and the license of YARA, which Malware Scan runs on.
enum AboutTidy {
    static let guide = URL(string: "https://github.com/\(TidyRelease.repository)#readme")!
    static let releaseNotes = URL(string: "https://github.com/\(TidyRelease.repository)/releases")!

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        var options: [NSApplication.AboutPanelOptionKey: Any] = [.applicationName: "Tidy", .credits: credits]
        if let version = info("CFBundleShortVersionString") ?? SourceFolder.version {
            options[.applicationVersion] = version
            options[.version] = info("CFBundleVersion") ?? "development"
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    private static func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    static var credits: NSAttributedString {
        let text = NSMutableAttributedString(string: "")
        func add(_ string: String, bold: Bool = false, secondary: Bool = false, link: URL? = nil, centered: Bool = true) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = centered ? .center : .natural
            let size = NSFont.smallSystemFontSize
            var attributes: [NSAttributedString.Key: Any] = [
                .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                .foregroundColor: secondary ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
            if let link { attributes[.link] = link }
            text.append(NSAttributedString(string: string, attributes: attributes))
        }
        add("Keeps your Mac clean, safe and fast.\n\n")
        add("Tidy Help", link: guide)
        add("   ·   ")
        add("Release Notes", link: releaseNotes)
        add("\n\nAcknowledgements\n", bold: true)
        add("Malware Scan runs on YARA 4.5.4 by The YARA Authors, under this license:\n\n", secondary: true)
        add(yaraLicense, secondary: true, centered: false)
        add("\n\nYARA's .NET module is under the Apache License 2.0, a copy of which comes with Tidy in Tidy.app/Contents/Resources.",
            secondary: true, centered: false)
        return text
    }

    /// libyara's BSD 3-Clause License, as in Sources/CYara/NOTICE.md.
    static let yaraLicense = """
        Copyright (c) 2007-2022. The YARA Authors. All Rights Reserved.

        Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

        1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

        2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

        3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

        THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
        """
}

/// Run from Xcode, Tidy isn't an app bundle yet, so macOS knows no icon or version for it: it shows a
/// folder and "TidyApp". Debug builds take both from the project folder instead, the icon and VERSION
/// the .dmg gets. The app itself, built with make-app.sh, has them in Info.plist.
enum SourceFolder {
    #if DEBUG
    static let root: URL? = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    #else
    static let root: URL? = nil
    #endif

    /// Whether Tidy runs from Tidy.app rather than straight from the build folder.
    static var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var icon: NSImage? {
        root.flatMap { NSImage(contentsOf: $0.appendingPathComponent("Resources/AppIcon.iconset/icon_512x512@2x.png")) }
    }

    static var version: String? {
        root.flatMap { try? String(contentsOf: $0.appendingPathComponent("VERSION"), encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
