import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A release of Tidy itself. The GitHub build that runs whenever main changes publishes one: tag
/// `build-<build number>`, title `Tidy <version>`, with Tidy.dmg attached.
public struct TidyRelease: Equatable, Sendable {
    public let version: String
    /// The app's CFBundleVersion: the build's date and time, such as 202610291200, so a newer build
    /// always has a larger number.
    public let build: Int
    public let notes: String
    public let downloadURL: URL
    public let pageURL: URL

    public static let repository = "rafaelcgama/clean-my-mac"
    public static let latestURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    public static let diskImageName = "Tidy.dmg"

    public init(version: String, build: Int, notes: String, downloadURL: URL, pageURL: URL) {
        self.version = version
        self.build = build
        self.notes = notes
        self.downloadURL = downloadURL
        self.pageURL = pageURL
    }

    /// Reads GitHub's reply for the latest release. Nil when it isn't one of Tidy's builds or has no disk image.
    public static func parse(_ json: Data) -> TidyRelease? {
        struct Reply: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let name: String?
            let body: String?
            let html_url: URL
            let assets: [Asset]
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: json),
              reply.tag_name.hasPrefix("build-"),
              let build = Int(reply.tag_name.dropFirst("build-".count)),
              let image = reply.assets.first(where: { $0.name == diskImageName })
        else { return nil }
        let title = reply.name ?? ""
        let version = title.hasPrefix("Tidy ") ? String(title.dropFirst("Tidy ".count)) : title
        return TidyRelease(version: version.isEmpty ? String(build) : version, build: build,
                           notes: reply.body ?? "", downloadURL: image.browser_download_url, pageURL: reply.html_url)
    }

    /// Whether this release is newer than the installed build. A copy run from Xcode has no build
    /// number, so nothing is newer than it.
    public func isNewer(thanBuild installed: Int?) -> Bool {
        guard let installed else { return false }
        return build > installed
    }

    /// The latest release, or nil when there is none yet. Throws when GitHub can't be reached.
    public static func latest(fetch: @Sendable (URL) async throws -> (Data, Int)) async throws -> TidyRelease? {
        let (data, status) = try await fetch(latestURL)
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw CheckFailed(status: status) }
        return parse(data)
    }

    #if os(macOS)
    public static func latest() async throws -> TidyRelease? {
        try await latest { url in
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }
    #endif

    public struct CheckFailed: Error, LocalizedError {
        public let status: Int
        public var errorDescription: String? { "GitHub answered with status \(status). Try again later." }
    }
}
