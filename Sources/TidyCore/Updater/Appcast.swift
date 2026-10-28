import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// One release in a Sparkle appcast.
public struct AppcastItem: Equatable, Sendable {
    /// Compared with the app's CFBundleVersion.
    public let version: String
    public let shortVersion: String?
    public let downloadURL: URL?
    public let releaseNotesURL: URL?
    public let minimumSystemVersion: String?
    /// Non-nil for beta or other opt-in channels.
    public let channel: String?

    public var displayVersion: String { shortVersion ?? version }
}

public enum AppcastParser {
    public static func parse(_ data: Data) -> [AppcastItem] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.items
    }

    /// The newest release this Mac can run, from the default channel.
    public static func latest(in items: [AppcastItem], osVersion: String) -> AppcastItem? {
        items
            .filter { $0.channel == nil }
            .filter { $0.minimumSystemVersion.map { !VersionComparator.isNewer($0, than: osVersion) } ?? true }
            .max { VersionComparator.compare($0.version, $1.version) == .orderedAscending }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        private var inItem = false
        private var fields: [String: String] = [:]
        private var enclosure: [String: String] = [:]
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            text = ""
            if elementName == "item" {
                inItem = true
                fields = [:]
                enclosure = [:]
            } else if inItem, elementName == "enclosure" {
                enclosure = attributeDict
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard inItem else { return }
            if elementName == "item" {
                inItem = false
                let version = fields["sparkle:version"] ?? enclosure["sparkle:version"]
                guard let version, !version.isEmpty else { return }
                items.append(AppcastItem(
                    version: version,
                    shortVersion: fields["sparkle:shortVersionString"] ?? enclosure["sparkle:shortVersionString"],
                    downloadURL: enclosure["url"].flatMap(URL.init(string:)),
                    releaseNotesURL: fields["sparkle:releaseNotesLink"].flatMap(URL.init(string:)),
                    minimumSystemVersion: fields["sparkle:minimumSystemVersion"],
                    channel: fields["sparkle:channel"]))
            } else {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { fields[elementName] = value }
            }
            text = ""
        }
    }
}
