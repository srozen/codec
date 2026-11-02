import Foundation
import Security

/// A version number as releases are tagged: "1.2.3", "v1.2", "1.3.0-beta.2". Build metadata after a
/// "+" is ignored.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public var components: [Int]
    /// What follows the "-": a prerelease, which comes before the release it leads to.
    public var prerelease: String?

    public init?(_ text: String) {
        var text = Substring(text.trimmingCharacters(in: .whitespaces))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        if let plus = text.firstIndex(of: "+") { text = text[..<plus] }
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        components = numbers.compactMap { $0 }
        prerelease = parts.count > 1 ? String(parts[1]) : nil
        if prerelease?.isEmpty == true { return nil }
    }

    /// The version of the app that's running; nil outside a bundle that has one (tests, `swift run`).
    public static var running: AppVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    }

    public var description: String {
        components.map(String.init).joined(separator: ".") + (prerelease.map { "-" + $0 } ?? "")
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool {
        !(a < b) && !(b < a)
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        // 1.2 and 1.2.0 are the same version.
        for i in 0..<max(a.components.count, b.components.count) {
            let x = i < a.components.count ? a.components[i] : 0
            let y = i < b.components.count ? b.components[i] : 0
            if x != y { return x < y }
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, _): return false
        case (_, nil): return true
        case let (x?, y?): return precedes(x, y)
        }
    }

    /// Semantic versioning's order of prereleases: dot by dot, numbers by value and below words, and
    /// fewer parts first when the rest are equal ("beta" < "beta.2" < "beta.10" < "rc.1").
    private static func precedes(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: "."), y = b.split(separator: ".")
        for (p, q) in zip(x, y) where p != q {
            switch (Int(p), Int(q)) {
            case let (m?, n?): return m < n
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return p < q
            }
        }
        return x.count < y.count
    }
}

/// A published release, as GitHub's releases API describes it.
public struct Release: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public var name: String
        public var url: URL

        public init(name: String, url: URL) {
            self.name = name
            self.url = url
        }

        private enum CodingKeys: String, CodingKey {
            case name, url = "browser_download_url"
        }
    }

    public var tag: String
    public var name: String?
    /// Markdown; empty when the release has none.
    public var notes: String
    /// The release's page on GitHub.
    public var page: URL
    public var assets: [Asset]

    public init(tag: String, name: String? = nil, notes: String = "", page: URL, assets: [Asset] = []) {
        self.tag = tag
        self.name = name
        self.notes = notes
        self.page = page
        self.assets = assets
    }

    private enum CodingKeys: String, CodingKey {
        case tag = "tag_name", name, notes = "body", page = "html_url", assets
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tag = try container.decode(String.self, forKey: .tag)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        page = try container.decode(URL.self, forKey: .page)
        assets = try container.decodeIfPresent([Asset].self, forKey: .assets) ?? []
    }

    public var version: AppVersion? { AppVersion(tag) }

    /// The disk image to download, if the release has one.
    public var diskImage: URL? {
        assets.first { $0.name.lowercased().hasSuffix(".dmg") }?.url
    }
}

/// When to look for a new version, and what counts as one.
public enum UpdatePolicy {
    /// How often Codec looks on its own.
    public static let interval: TimeInterval = 24 * 60 * 60

    /// Whether it's time to look again: never looked, a day has passed, or the clock went back.
    public static func isDue(lastChecked: Date?, now: Date = Date()) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= interval || lastChecked > now
    }

    /// Whether `release` is newer than the version that's running.
    public static func isNewer(_ release: Release, than current: AppVersion) -> Bool {
        guard let version = release.version else { return false }
        return version > current
    }
}

/// Where releases are looked up. The app asks GitHub; tests use a fake.
public protocol ReleaseSource: Sendable {
    /// The newest release that isn't a draft or a prerelease.
    func latest() async throws -> Release
}

public enum UpdateCheckError: LocalizedError, Equatable {
    case noReleases
    case unexpectedResponse(Int)

    public var errorDescription: String? {
        switch self {
        case .noReleases: "No release of Codec has been published yet."
        case .unexpectedResponse(let status): "GitHub answered with an error (\(status)). Try again later."
        }
    }
}

/// Codec's releases on GitHub. Asks for the latest one and nothing else: no cookies, no cache, and
/// nothing about the Mac beyond what any web request carries.
public struct GitHubReleases: ReleaseSource {
    public static let codec = GitHubReleases(repository: "srozen/codec")

    /// "owner/name".
    public var repository: String

    public init(repository: String) {
        self.repository = repository
    }

    public var latestURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    public func latest() async throws -> Release {
        var request = URLRequest(url: latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Codec", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw UpdateCheckError.noReleases }
        guard status == 200 else { throw UpdateCheckError.unexpectedResponse(status) }
        return try JSONDecoder().decode(Release.self, from: data)
    }
}

/// How the running app is signed.
public enum CodeSigning {
    /// Whether it's signed with a Developer ID, as a notarized release is; false when it's signed ad
    /// hoc, so macOS asks before opening each new version that's downloaded.
    public static var runningAppHasTeamIdentifier: Bool {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any] else { return false }
        return information[kSecCodeInfoTeamIdentifier as String] != nil
    }
}

/// Codec installed as a Homebrew cask, which Homebrew upgrades.
public enum Homebrew {
    public static let upgradeCommand = "brew upgrade --cask srozen/codec/codec"

    /// Where Homebrew keeps Codec's cask once it's installed, on Apple silicon and on Intel.
    static let caskrooms = ["/opt/homebrew/Caskroom/codec", "/usr/local/Caskroom/codec"]

    public static func installedCodec(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        caskrooms.contains(where: fileExists)
    }
}
