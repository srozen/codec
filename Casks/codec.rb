# Codec's Homebrew cask. The release workflow sets its version and checksum after each release.
#   brew tap srozen/codec https://github.com/srozen/codec
#   brew install --cask srozen/codec/codec
cask "codec" do
  version "0.1.3"
  sha256 "079399baeae55b4c4e36afd5720f1f45c4931d2e2f37eca62f6e3e66e991b5e2"

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
