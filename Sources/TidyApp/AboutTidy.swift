import AppKit
import SwiftUI
import TidyCore

/// About Tidy, in the Tidy and Help menus.
struct AboutTidyButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Tidy") {
            openWindow(id: AboutTidyWindow.id)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// Tidy Help, in the Help menu: Tidy's guide, the README on GitHub.
struct TidyHelpButton: View {
    var body: some View {
        Button("Tidy Help") { NSWorkspace.shared.open(AboutTidyWindow.guide) }
    }
}

/// The About Tidy window: Tidy's name in large type with no icon, the version and build, what it does,
/// links to its guide and release notes, the license of YARA, which Malware Scan runs on, and the copyright.
struct AboutTidyWindow: View {
    static let id = "about"
    static let guide = URL(string: "https://github.com/\(TidyRelease.repository)#readme")!
    static let releaseNotes = URL(string: "https://github.com/\(TidyRelease.repository)/releases")!

    var body: some View {
        VStack(spacing: 6) {
            Text("Tidy")
                .font(.system(size: 30, weight: .bold))
            Text(Self.versionLine)
                .foregroundStyle(.secondary)
            Text("Keeps your Mac clean, safe and fast.")
                .padding(.top, 10)
            HStack(spacing: 8) {
                Button("Tidy Help") { NSWorkspace.shared.open(Self.guide) }
                    .buttonStyle(.link)
                Text("·")
                    .foregroundStyle(.secondary)
                Button("Release Notes") { NSWorkspace.shared.open(Self.releaseNotes) }
                    .buttonStyle(.link)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Acknowledgements")
                        .bold()
                    Group {
                        Text("Malware Scan runs on YARA 4.5.4 by The YARA Authors, under this license:")
                        Text(Self.yaraLicense)
                        Text("YARA's .NET module is under the Apache License 2.0, a copy of which comes with Tidy in Tidy.app/Contents/Resources.")
                    }
                    .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(height: 140)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            .padding(.top, 12)
            if let copyright = Self.copyright {
                Text(copyright)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(width: 360)
    }

    /// "Version 1.1.3 (202610300204)", from Info.plist; run from Xcode, "Version 1.1.3 (development)".
    static var versionLine: String {
        guard let version = info("CFBundleShortVersionString") ?? SourceFolder.version else { return "Development version" }
        return "Version \(version) (\(info("CFBundleVersion") ?? "development"))"
    }

    static var copyright: String? {
        info("NSHumanReadableCopyright") ?? SourceFolder.info("NSHumanReadableCopyright")
    }

    private static func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
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

/// Run from Xcode, Tidy isn't an app bundle yet, so macOS knows no version or copyright for it. Debug
/// builds take them from the project folder instead, from the VERSION and Info.plist the .dmg gets. The
/// app itself, built with make-app.sh, has them in its Info.plist.
enum SourceFolder {
    #if DEBUG
    static let root: URL? = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    #else
    static let root: URL? = nil
    #endif

    static var version: String? {
        root.flatMap { try? String(contentsOf: $0.appendingPathComponent("VERSION"), encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A value from Resources/Info.plist, the template make-app.sh fills in.
    static func info(_ key: String) -> String? {
        guard let root, let data = try? Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        return plist[key] as? String
    }
}
