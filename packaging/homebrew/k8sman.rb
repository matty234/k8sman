# Homebrew cask template for a personal tap (matty234/homebrew-tap). Copy
# to Casks/k8sman.rb in that repo; see README.md next to this file.
#
#   brew install --cask matty234/tap/k8sman
cask "k8sman" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_FROM_SHA256SUMS"

  url "https://github.com/matty234/k8sman/releases/download/v#{version}/k8sman-#{version}-macos.zip"
  name "k8sman"
  desc "Native Kubernetes IDE"
  homepage "https://github.com/matty234/k8sman"

  # The appcast the app itself uses; `brew livecheck` reads it.
  livecheck do
    url "https://github.com/matty234/k8sman/releases/latest/download/appcast.xml"
    strategy :sparkle, &:short_version
  end

  # The app updates itself with Sparkle, so `brew upgrade` leaves it alone
  # unless run with --greedy.
  auto_updates true
  depends_on macos: :monterey

  app "k8sman.app"

  zap trash: [
    "~/.cache/k8sman",
    "~/.config/k8sman",
    "~/Library/Caches/dev.k8sman.app",
    "~/Library/HTTPStorages/dev.k8sman.app",
    "~/Library/Preferences/dev.k8sman.app.plist",
    "~/Library/Saved Application State/dev.k8sman.app.savedState",
  ]

  caveats <<~EOS
    k8sman is ad-hoc signed, not notarized. On first launch macOS will block
    it: open System Settings → Privacy & Security and click "Open Anyway"
    (or Control-click the app and choose Open).
  EOS
end
