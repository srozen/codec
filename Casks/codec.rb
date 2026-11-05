# Codec's Homebrew cask. The release workflow sets its version and checksum after each release.
#   brew tap srozen/codec https://github.com/srozen/codec
#   brew install --cask srozen/codec/codec
cask "codec" do
  version "0.1.6"
  sha256 "69aa084c275d6fdc78ec3a136199f11b77dedae8953736bc01b8c1fb7cd1902e"

  url "https://github.com/srozen/codec/releases/download/v#{version}/Codec-#{version}.dmg"
  name "Codec"
  desc "Native terminal that remembers what you did"
  homepage "https://github.com/srozen/codec"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :tahoe

  app "Codec.app"

  zap trash: [
    "~/.codec",
    "~/Library/Application Support/Codec",
    "~/Library/Preferences/com.srozen.codec.plist",
    "~/Library/Saved Application State/com.srozen.codec.savedState",
  ]

  caveats <<~EOS
    Codec isn't notarized by Apple yet, so macOS stops it the first time you open it, and again
    after each upgrade. Open System Settings > Privacy & Security and choose Open Anyway beside Codec.
  EOS
end
