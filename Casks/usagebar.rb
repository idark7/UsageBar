cask "usagebar" do
  version "3.0.0"
  sha256 ""

  url "https://github.com/idark7/UsageBar/releases/download/v#{version}/UsageBar-#{version}.dmg"
  name "UsageBar"
  desc "Claude Code + Codex usage limits in the menu bar"
  homepage "https://github.com/idark7/UsageBar"

  livecheck do
    url :url
    strategy :github_latest
  end

  app "UsageBar.app"

  # until the app is notarized
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/UsageBar.app"]
  end

  zap trash: [
    "~/Library/Application Support/UsageBar",
    "~/Library/Preferences/com.sudipta.usagebar.plist",
  ]
end
