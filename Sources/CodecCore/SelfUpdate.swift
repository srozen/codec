import Foundation
import CryptoKit
import Security

/// What's being done to get a new version ready.
public enum UpdatePreparation: Equatable, Sendable {
    /// How much of the disk image is in, when its size is known.
    case downloading(Double?)
    /// Mounting it, copying the app out and checking it.
    case checking
}

/// Puts a release in place of the running app. The app needs one; tests use a fake.
public protocol UpdateInstalling: Sendable {
    /// Downloads `release`, checks it and copies its app next to the installed one; returns that copy.
    func prepare(_ release: Release, progress: @escaping @Sendable (UpdatePreparation) -> Void) async throws -> URL
    /// Swaps the copy `prepare` returned in for the installed app. Done while quitting.
    func replace(with staged: URL) throws
    /// Opens the installed app once this process has exited.
    func relaunch()
}

public enum SelfUpdateError: LocalizedError, Equatable {
    case noDiskImage
    case download(status: Int)
    case damaged
    case noApp
    case notCodec(String)
    case wrongVersion(found: String, expected: String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .noDiskImage: "The release has no disk image."
        case .download(let status): "GitHub answered with an error (\(status)) when downloading it."
        case .damaged: "The download doesn’t match the checksum GitHub lists for it."
        case .noApp: "The disk image has no app in it."
        case .notCodec(let reason): "The app in the disk image isn’t signed as this copy of Codec is. \(reason)"
        case .wrongVersion(let found, let expected): "The disk image holds Codec \(found), not \(expected)."
        case .failed(let reason): reason
        }
    }
}

/// Installs a release over the copy of Codec that's running. Its disk image is downloaded and checked
/// against the checksum GitHub lists, and the app in it is copied next to this one and checked again:
/// it has to be signed with the same certificate as this copy, with the same identifier, and be the
/// version the release says. Quitting then only has to swap the two.
public struct SelfUpdate: UpdateInstalling {
    /// The app that's replaced.
    public var installed: URL
    /// What the new app's signature has to satisfy: the running app's designated requirement, which
    /// names its certificate.
    public var requirement: String
    public var bundleIdentifier: String

    public init(installed: URL, requirement: String, bundleIdentifier: String) {
        self.installed = installed
        self.requirement = requirement
        self.bundleIdentifier = bundleIdentifier
    }

    /// For the running app; nil when it can't replace itself: signed ad hoc, or somewhere it can't
    /// write.
    public static func forRunningApp(_ bundle: Bundle = .main) -> SelfUpdate? {
        guard let identifier = bundle.bundleIdentifier, let requirement = CodeSigning.runningAppRequirement,
              canReplace(bundle.bundleURL) else { return nil }
        return SelfUpdate(installed: bundle.bundleURL.standardizedFileURL, requirement: requirement, bundleIdentifier: identifier)
    }

    /// Whether a new copy can be swapped in for `app`: not when macOS runs it from where it moved it to
    /// (App Translocation, for an app opened where it was downloaded), from a read-only disk, or from a
    /// folder Codec can't write to.
    public static func canReplace(_ app: URL, fileManager: FileManager = .default) -> Bool {
        let app = app.standardizedFileURL
        guard app.pathExtension == "app", !app.path.contains("/AppTranslocation/") else { return false }
        if (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true { return false }
        return fileManager.isWritableFile(atPath: app.path)
            && fileManager.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    public func prepare(_ release: Release, progress: @escaping @Sendable (UpdatePreparation) -> Void) async throws -> URL {
        guard let asset = release.diskImageAsset else { throw SelfUpdateError.noDiskImage }
        guard let version = release.version else { throw SelfUpdateError.failed("\(release.tag) isn’t a version.") }
        progress(.downloading(nil))
        let image = try await Self.download(asset.url) { progress(.downloading($0)) }
        defer { try? FileManager.default.removeItem(at: image.deletingLastPathComponent()) }
        try Task.checkCancellation()
        progress(.checking)
        try Self.checkDigest(of: image, against: asset.digest)
        return try stage(from: image, version: version)
    }

    /// Copies the app out of the disk image `image`, into a folder on the installed app's volume so
    /// that swapping it in is a rename, and checks it.
    public func stage(from image: URL, version: AppVersion) throws -> URL {
        let volume = try Self.attach(image)
        defer { Self.detach(volume) }
        let contents = try FileManager.default.contentsOfDirectory(at: volume, includingPropertiesForKeys: nil)
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else { throw SelfUpdateError.noApp }
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                 appropriateFor: installed, create: true)
        let staged = folder.appendingPathComponent(installed.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: app, to: staged)
            try check(staged, version: version)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return staged
    }

    /// The signature first: until it's checked, nothing in the bundle can be trusted.
    public func check(_ app: URL, version: AppVersion) throws {
        try checkSignature(of: app)
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw SelfUpdateError.notCodec("Its identifier isn’t \(bundleIdentifier).")
        }
        let found = info["CFBundleShortVersionString"] as? String ?? "?"
        guard AppVersion(found) == version else { throw SelfUpdateError.wrongVersion(found: found, expected: "\(version)") }
    }

    func checkSignature(of app: URL) throws {
        var code: SecStaticCode?
        var required: SecRequirement?
        var errors: Unmanaged<CFError>?
        guard SecRequirementCreateWithString(requirement as CFString, [], &required) == errSecSuccess, let required else {
            throw SelfUpdateError.notCodec("This copy’s signing requirement can’t be read.")
        }
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw SelfUpdateError.notCodec("It isn’t signed.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidityWithErrors(code, flags, required, &errors) == errSecSuccess else {
            let reason = errors?.takeRetainedValue().localizedDescription ?? "Its signature doesn’t match."
            throw SelfUpdateError.notCodec(reason)
        }
    }

    public func replace(with staged: URL) throws {
        _ = try FileManager.default.replaceItemAt(installed, withItemAt: staged)
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
    }

    public func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Waits for this process to be gone, so the new one doesn't start while this one is still saving.
        process.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                             "codec-relaunch", "\(ProcessInfo.processInfo.processIdentifier)", installed.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: - Steps

    /// Downloads `url` into a folder of its own, reporting how much is in.
    static func download(_ url: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("Codec", forHTTPHeaderField: "User-Agent")
        let (file, response) = try await session.download(for: request, delegate: DownloadProgress(progress))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw SelfUpdateError.download(status: status)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codec-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent(url.lastPathComponent.isEmpty ? "Codec.dmg" : url.lastPathComponent)
        try FileManager.default.moveItem(at: file, to: image)
        return image
    }

    /// `digest` as GitHub lists an asset's: "sha256:" and the hex. Releases from before GitHub listed
    /// one have none; the app's signature is checked all the same.
    public static func checkDigest(of file: URL, against digest: String?) throws {
        guard let digest, digest.hasPrefix("sha256:") else { return }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        let hex = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard hex == digest.dropFirst("sha256:".count).lowercased() else { throw SelfUpdateError.damaged }
    }

    /// Mounts `image` read-only, out of sight: not in the Finder, and under a folder of its own.
    static func attach(_ image: URL) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codec-mount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let output = try tool("/usr/bin/hdiutil", ["attach", image.path, "-readonly", "-nobrowse", "-noautoopen",
                                                   "-mountroot", root.path, "-plist"])
        let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any]
        let entities = plist?["system-entities"] as? [[String: Any]] ?? []
        guard let mountPoint = entities.lazy.compactMap({ $0["mount-point"] as? String }).first else {
            try? FileManager.default.removeItem(at: root)
            throw SelfUpdateError.failed("The disk image couldn’t be opened.")
        }
        return URL(fileURLWithPath: mountPoint)
    }

    static func detach(_ volume: URL) {
        _ = try? tool("/usr/bin/hdiutil", ["detach", volume.path, "-force"])
        try? FileManager.default.removeItem(at: volume.deletingLastPathComponent())
    }

    /// Runs a command line tool and returns what it printed; throws with what it said when it fails.
    private static func tool(_ path: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SelfUpdateError.failed("\(URL(fileURLWithPath: path).lastPathComponent) failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return data
    }
}

/// Reports a download's progress from its task's.
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double?) -> Void
    private var observation: NSKeyValueObservation?

    init(_ report: @escaping @Sendable (Double?) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [report] progress, _ in
            report(progress.totalUnitCount > 0 ? progress.fractionCompleted : nil)
        }
    }
}
