import AppKit
import Foundation
import Sparkle

@MainActor
final class UpdaterController: NSObject {
    static let shared = UpdaterController()

    private let standardController: SPUStandardUpdaterController?
    let install: InstallKind

    enum InstallKind: String {
        case developerID      // notarized .dmg dropped into /Applications
        case homebrewCask     // brew upgrade owns updates
        case xcode            // running from DerivedData; do not check
        case unknown
    }

    private override init() {
        let detected = Self.detectInstallKind()
        self.install = detected

        switch detected {
        case .developerID:
            self.standardController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        case .homebrewCask, .xcode, .unknown:
            self.standardController = nil
        }
        super.init()
    }

    var hasUpdater: Bool { standardController != nil }

    var updater: SPUUpdater? { standardController?.updater }

    @objc func checkForUpdates(_ sender: Any?) {
        standardController?.checkForUpdates(sender)
    }

    private static func detectInstallKind() -> InstallKind {
        let resolved = (Bundle.main.bundlePath as NSString).resolvingSymlinksInPath

        if resolved.contains("/Caskroom/")
            || resolved.hasPrefix("/usr/local/Cellar/")
            || resolved.hasPrefix("/opt/homebrew/Cellar/")
        {
            return .homebrewCask
        }

        if resolved.contains("/DerivedData/")
            || resolved.contains("/Xcode/")
        {
            return .xcode
        }

        if resolved.hasPrefix("/Applications/")
            || resolved.hasPrefix(NSHomeDirectory() + "/Applications/")
        {
            return .developerID
        }

        return .unknown
    }
}
