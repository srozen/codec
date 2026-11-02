import Testing
import Foundation
@testable import CodecCore

@Suite("Updates")
struct UpdatesTests {
    private func version(_ text: String) throws -> AppVersion {
        try #require(AppVersion(text))
    }

    @Test func readsVersionsAsTheyAreTagged() throws {
        #expect(try version("v1.2.3").components == [1, 2, 3])
        #expect(try version("1.2").description == "1.2")
        #expect(try version(" V2.0.0-beta.2 ").description == "2.0.0-beta.2")
        #expect(try version("1.4.0+build.7").description == "1.4.0")
        for bad in ["", "v", "1..2", "1.x", "-1.0", "1.0-", "latest"] {
            #expect(AppVersion(bad) == nil, "\(bad)")
        }
    }

    @Test func ordersVersionsByNumberNotText() throws {
        #expect(try version("0.9.0") < version("0.10.0"))
        #expect(try version("1.2") == version("1.2.0"))
        #expect(try version("1.2.1") > version("1.2"))
        #expect(try !(version("2.0") < version("1.99.99")))
    }

    @Test func putsPrereleasesBeforeTheirRelease() throws {
        let order = try ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.10", "1.0.0-rc.1", "1.0.0", "1.0.1-beta"]
            .map(version)
        for (earlier, later) in zip(order, order.dropFirst()) {
            #expect(earlier < later, "\(earlier) < \(later)")
            #expect(!(later < earlier))
        }
    }

    @Test func decodesGitHubsLatestRelease() throws {
        let json = """
            {"tag_name": "v0.3.0", "name": "Codec 0.3.0", "body": "## What's new\\n- Updates", "draft": false,
             "html_url": "https://github.com/srozen/codec/releases/tag/v0.3.0",
             "assets": [
               {"name": "checksums.txt", "browser_download_url": "https://example.com/checksums.txt"},
               {"name": "Codec-0.3.0.dmg", "browser_download_url": "https://example.com/Codec-0.3.0.dmg"}
             ]}
            """
        let release = try JSONDecoder().decode(Release.self, from: Data(json.utf8))
        #expect(release.version == (try version("0.3.0")))
        #expect(release.notes == "## What's new\n- Updates")
        #expect(release.diskImage == URL(string: "https://example.com/Codec-0.3.0.dmg"))
        #expect(release.page.absoluteString.hasSuffix("/v0.3.0"))
    }

    @Test func decodesAReleaseWithoutNotesOrAssets() throws {
        let json = #"{"tag_name": "v1.0", "name": null, "body": null, "html_url": "https://github.com/srozen/codec/releases/tag/v1.0"}"#
        let release = try JSONDecoder().decode(Release.self, from: Data(json.utf8))
        #expect(release.notes.isEmpty)
        #expect(release.diskImage == nil)
    }

    @Test func offersOnlyNewerReleasesWithAVersion() throws {
        let page = URL(string: "https://github.com/srozen/codec/releases")!
        let current = try version("1.2.0")
        #expect(UpdatePolicy.isNewer(Release(tag: "v1.3.0", page: page), than: current))
        #expect(!UpdatePolicy.isNewer(Release(tag: "v1.2", page: page), than: current))
        #expect(!UpdatePolicy.isNewer(Release(tag: "v1.1.9", page: page), than: current))
        #expect(!UpdatePolicy.isNewer(Release(tag: "nightly", page: page), than: current))
    }

    @Test func checksOnceADay() {
        let now = Date()
        #expect(UpdatePolicy.isDue(lastChecked: nil, now: now))
        #expect(!UpdatePolicy.isDue(lastChecked: now.addingTimeInterval(-3600), now: now))
        #expect(UpdatePolicy.isDue(lastChecked: now.addingTimeInterval(-UpdatePolicy.interval), now: now))
        // The clock went back: the last check is in the future, so look again.
        #expect(UpdatePolicy.isDue(lastChecked: now.addingTimeInterval(3600), now: now))
    }

    @Test func asksGitHubForTheLatestRelease() {
        #expect(GitHubReleases.codec.latestURL.absoluteString == "https://api.github.com/repos/srozen/codec/releases/latest")
    }

    @Test func knowsWhenHomebrewInstalledCodec() {
        #expect(Homebrew.installedCodec { $0 == "/opt/homebrew/Caskroom/codec" })
        #expect(Homebrew.installedCodec { $0 == "/usr/local/Caskroom/codec" })
        #expect(!Homebrew.installedCodec { _ in false })
    }
}
