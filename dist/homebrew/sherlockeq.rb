# Homebrew Cask for SherlockEQ.
#
# Lives in a personal tap repo at:
#   github.com/smbrownai/homebrew-sherlockeq/Casks/sherlockeq.rb
#
# Bumping a release:
#   1. dist/release.sh <version>   produces a signed/notarized/stapled dmg
#      and prints the sha256 + the two lines below.
#   2. Copy the printed `version` and `sha256` over the values here.
#   3. Commit and push the tap repo. `brew upgrade --cask sherlockeq`
#      picks it up on the next `brew update`.
#
# Future migration to the official homebrew-cask:
#   - App must be 1.0+ for a stretch, have a real homepage, working
#     livecheck, and not be a beta. The DSL below already passes those.
#   - Submit via `brew bump-cask-pr` once eligible.

cask "sherlockeq" do
  version "0.9.6"
  sha256 "eef672267b8352adea703adb8de1c8c8965dfc7b216e32703edf37b1bede301a"

  url "https://github.com/smbrownai/SherlockEQ/releases/download/v#{version}/SherlockEQ-#{version}.dmg",
      verified: "github.com/smbrownai/SherlockEQ/"
  name "SherlockEQ"
  desc "Audio equalizer for personal listening preferences on macOS"
  homepage "https://snxt.ai"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Cask's :sonoma matches macOS 14.x. The app's runtime check enforces
  # 14.6 specifically (Core Audio Tap engine floor).
  depends_on macos: ">= :sonoma"

  app "SherlockEQ.app"

  # Expose the bundled `sherlockeq` command-line tool on PATH. It lives inside
  # the app (Contents/Helpers/), built + signed + notarized with the bundle by
  # dist/release.sh; Homebrew just symlinks it into its bin. Non-Homebrew users
  # get the same result with `sherlockeq install`.
  binary "#{appdir}/SherlockEQ.app/Contents/Helpers/sherlockeq"

  # `brew uninstall --zap sherlockeq` removes these alongside the .app.
  # Keep this in sync with anything the app writes under ~/Library.
  zap trash: [
    "~/Library/Application Support/SherlockEQ",
    "~/Library/Caches/com.shawnbrown.SherlockEQ",
    "~/Library/HTTPStorages/com.shawnbrown.SherlockEQ",
    "~/Library/Preferences/com.shawnbrown.SherlockEQ.plist",
    "~/Library/Saved Application State/com.shawnbrown.SherlockEQ.savedState",
  ]
end
