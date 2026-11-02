import Testing
import Foundation
import CryptoKit
@testable import CodecCore

/// Installing a release over the running app, with real app bundles signed ad hoc and real disk images.
@Suite("Self update", .serialized)
struct SelfUpdateTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SelfUpdateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A minimal app, signed ad hoc with `identifier`.
    private func makeApp(_ name: String, version: String, identifier: String = "com.srozen.codec", in parent: URL? = nil) throws -> URL {
        let app = (parent ?? folder).appendingPathComponent(name).appendingPathComponent("Codec.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("Codec").path)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
                                   "CFBundleExecutable": "Codec", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identifier, app.path])
        return app
    }

    private func makeImage(of app: URL) throws -> URL {
        let image = folder.appendingPathComponent("\(UUID().uuidString).dmg")
        try run("/usr/bin/hdiutil", ["create", "-quiet", "-fs", "HFS+", "-volname", "Codec", "-srcfolder",
                                     app.deletingLastPathComponent().path, "-format", "UDZO", image.path])
        return image
    }

    private func attachedImages() throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return (info?["images"] as? [[String: Any]] ?? []).compactMap {
            ($0["image-path"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        }
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(tool) \(arguments)")
        return process.terminationStatus
    }

    private func updater(for installed: URL, requirement: String = "identifier \"com.srozen.codec\"") -> SelfUpdate {
        SelfUpdate(installed: installed, requirement: requirement, bundleIdentifier: "com.srozen.codec")
    }

    @Test func readsTheChecksumGitHubListsForAnAsset() throws {
        let json = #"{"tag_name": "v0.2.0", "html_url": "https://github.com/srozen/codec/releases/tag/v0.2.0", "assets": [{"name": "Codec-0.2.0.dmg", "browser_download_url": "https://example.com/Codec-0.2.0.dmg", "digest": "sha256:abc"}, {"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"}]}"#
        let release = try JSONDecoder().decode(Release.self, from: Data(json.utf8))
        #expect(release.diskImageAsset?.digest == "sha256:abc")
        #expect(release.assets[1].digest == nil)
    }

    @Test func checksADownloadAgainstItsChecksum() throws {
        let file = folder.appendingPathComponent("image.dmg")
        try Data("codec".utf8).write(to: file)
        let hex = SHA256.hash(data: Data("codec".utf8)).map { String(format: "%02x", $0) }.joined()
        try SelfUpdate.checkDigest(of: file, against: "sha256:\(hex)")
        try SelfUpdate.checkDigest(of: file, against: "sha256:\(hex.uppercased())")
        // Older releases list none; the app's signature is still checked.
        try SelfUpdate.checkDigest(of: file, against: nil)
        #expect(throws: SelfUpdateError.damaged) { try SelfUpdate.checkDigest(of: file, against: "sha256:\(String(hex.reversed()))") }
    }

    @Test func replacesOnlyWhereItCanWrite() throws {
        let app = try makeApp("writable", version: "0.1.0")
        #expect(SelfUpdate.canReplace(app))
        #expect(!SelfUpdate.canReplace(URL(fileURLWithPath: "/private/var/folders/xy/T/AppTranslocation/1234/d/Codec.app")))
        #expect(!SelfUpdate.canReplace(app.deletingLastPathComponent()))

        let locked = app.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        #expect(!SelfUpdate.canReplace(app))
    }

    @Test func acceptsOnlyCodecSignedAsThisCopyIsAtTheReleasesVersion() throws {
        let installed = try makeApp("installed", version: "0.1.0")
        let update = try makeApp("new", version: "0.2.0")
        try updater(for: installed).check(update, version: AppVersion("0.2.0")!)

        #expect(throws: SelfUpdateError.wrongVersion(found: "0.2.0", expected: "0.3.0")) {
            try updater(for: installed).check(update, version: AppVersion("0.3.0")!)
        }
        // Released copies require Codec's certificate, which an ad hoc signature doesn't have.
        let certificate = #"identifier "com.srozen.codec" and certificate leaf = H"0a8b80f842e2f27937545be26dce5c59ac6df7f9""#
        #expect(throws: SelfUpdateError.self) { try updater(for: installed, requirement: certificate).check(update, version: AppVersion("0.2.0")!) }

        let other = try makeApp("other", version: "0.2.0", identifier: "com.example.other")
        #expect(throws: SelfUpdateError.self) { try updater(for: installed).check(other, version: AppVersion("0.2.0")!) }
        let anyIdentifier = SelfUpdate(installed: installed, requirement: #"identifier "com.example.other""#, bundleIdentifier: "com.srozen.codec")
        #expect(throws: SelfUpdateError.notCodec("Its identifier isn’t com.srozen.codec.")) {
            try anyIdentifier.check(other, version: AppVersion("0.2.0")!)
        }

        // Changed after it was signed.
        let plist = update.appendingPathComponent("Contents/Info.plist")
        var info = try #require(NSDictionary(contentsOf: plist) as? [String: Any])
        info["LSEnvironment"] = ["DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        #expect(throws: SelfUpdateError.self) { try updater(for: installed).check(update, version: AppVersion("0.2.0")!) }
    }

    @Test func stagesTheAppFromADiskImageThenSwapsItIn() throws {
        let installed = try makeApp("installed", version: "0.1.0")
        let image = try makeImage(of: try makeApp("new", version: "0.2.0"))
        let update = updater(for: installed)

        let staged = try update.stage(from: image, version: AppVersion("0.2.0")!)
        #expect(staged.lastPathComponent == "Codec.app")
        #expect(staged.deletingLastPathComponent() != installed.deletingLastPathComponent())
        // The disk image is closed again.
        #expect(!(try attachedImages()).contains(image.resolvingSymlinksInPath().path))

        try update.replace(with: staged)
        let info = try #require(NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist")))
        #expect(info["CFBundleShortVersionString"] as? String == "0.2.0")
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        try update.check(installed, version: AppVersion("0.2.0")!)
    }

    @Test func refusesADiskImageWhoseAppIsntCodec() throws {
        let installed = try makeApp("installed", version: "0.1.0")
        let image = try makeImage(of: try makeApp("new", version: "0.2.0", identifier: "com.example.other"))
        #expect(throws: SelfUpdateError.self) { try updater(for: installed).stage(from: image, version: AppVersion("0.2.0")!) }
        // Nothing is left beside the installed app, and it's untouched.
        let info = try #require(NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist")))
        #expect(info["CFBundleShortVersionString"] as? String == "0.1.0")
    }
}
