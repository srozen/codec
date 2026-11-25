# Codec's Homebrew cask. The release workflow sets its version and checksum after each release.
#   brew tap srozen/codec https://github.com/srozen/codec
#   brew install --cask srozen/codec/codec
cask "codec" do
  version "0.1.8"
  sha256 "b1164422f678f8e83c68d6bd79919555e4fe8813fb5c9e0ae2e498ac72aabb39"

  url "https://codec.srozen.com/releases/Codec-#{version}.dmg"
  name "Codec"
  desc "Native terminal that remembers what you did"
  homepage "https://codec.srozen.com"

  livecheck do
    url "https://codec.srozen.com/releases/latest.json"
    strategy :json do |json|
      json["tag_name"]&.delete_prefix("v")
    end
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
