# 注意：版本号应与 VERSION 文件保持一致
# 更新步骤：1. 修改 VERSION 文件 2. 构建 DMG 3. 更新此文件的 version 和 sha256
cask "x-nook" do
  version "1.4.5"
  sha256 "b69270a9b38d44e72606db35b1f1b412d0f95a1358173f7df1fa5a52c5e6a4c8"

  url "https://github.com/Meteorkid/XNook/releases/download/v#{version}/XNook-#{version}.dmg",
      verified: "github.com/Meteorkid/XNook/"
  name "X Nook"
  desc "Dynamic Island-style tool center for MacBook"
  homepage "https://github.com/Meteorkid/XNook"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "X Nook.app"

  zap trash: [
    "~/Library/Preferences/com.meteorkid.xnook.plist",
  ]
end
