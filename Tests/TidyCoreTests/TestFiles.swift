import Foundation

extension FileManager {
    /// Sets the modification date of `url` and everything under it to `days` ago, as if nothing had
    /// written to it since.
    func backdate(_ url: URL, days: Int) throws {
        let date = Date().addingTimeInterval(-Double(days) * 86_400)
        var urls = [url]
        if let enumerator = enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let child as URL in enumerator { urls.append(child) }
        }
        for child in urls {
            try setAttributes([.modificationDate: date], ofItemAtPath: child.path)
        }
    }
}
