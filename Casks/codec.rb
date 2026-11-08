# Codec's Homebrew cask. The release workflow sets its version and checksum after each release.
#   brew tap srozen/codec https://github.com/srozen/codec
#   brew install --cask srozen/codec/codec
cask "codec" do
  version "0.1.7"
  sha256 "853bbcd4f4d8250a7f9231fc015a68b929235093b124a8be512642bffa796724"

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
end
