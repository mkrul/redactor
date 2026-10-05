import Darwin
import Foundation

enum LoginItem {
    static let label = "com.redactor.agent"

    static func installedExecutable() -> URL? {
        guard Bundle.main.bundleIdentifier == "com.redactor.app" else { return nil }
        guard let executable = Bundle.main.executableURL else { return nil }
        let appPath = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let homeApps = NSHomeDirectory() + "/Applications/"
        if appPath.hasPrefix("/Applications/") || appPath.hasPrefix(homeApps) {
            return executable.resolvingSymlinksInPath()
        }
        return nil
    }

    static func reportedState() -> String {
        let directory = RedactorPaths.launchAgentPlist.deletingLastPathComponent()
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
        if !exists { return "no" }
        if !FileManager.default.isReadableFile(atPath: directory.path) { return "unknown" }
        return FileManager.default.fileExists(atPath: RedactorPaths.launchAgentPlist.path) ? "yes" : "no"
    }

    static func seedPatternsIfInstalled() {
        guard installedExecutable() != nil else { return }
        let destination = RedactorPaths.patternFile
        if FileManager.default.fileExists(atPath: destination.path) { return }
        guard let factory = PatternList.locateFactory(), let data = try? Data(contentsOf: factory) else { return }
        RedactorPaths.ensure(RedactorPaths.supportDirectory)
        try? data.write(to: destination, options: [.atomic])
    }

    static func syncOnLaunch() {
        guard installedExecutable() != nil, wantsOpenAtLogin() else { return }
        if FileManager.default.fileExists(atPath: RedactorPaths.launchAgentPlist.path) { return }
        writePlist()
        runLaunchctl(["enable", target])
    }

    static func enableFromMenu() {
        UserDefaults.standard.set(true, forKey: "openAtLogin")
        guard installedExecutable() != nil else { return }
        writePlist()
        runLaunchctl(["enable", target])
    }

    static func disableFromMenu() {
        UserDefaults.standard.set(false, forKey: "openAtLogin")
        runLaunchctl(["disable", target])
        try? FileManager.default.removeItem(at: RedactorPaths.launchAgentPlist)
    }

    private static var target: String { "gui/\(getuid())/\(label)" }

    private static func wantsOpenAtLogin() -> Bool {
        if UserDefaults.standard.object(forKey: "openAtLogin") == nil { return true }
        return UserDefaults.standard.bool(forKey: "openAtLogin")
    }

    private static func writePlist() {
        guard let executable = installedExecutable() else { return }
        RedactorPaths.ensure(RedactorPaths.logDirectory)
        RedactorPaths.ensure(RedactorPaths.launchAgentPlist.deletingLastPathComponent())
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path, "--launched-at-login"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "AssociatedBundleIdentifiers": "com.redactor.app",
            "StandardOutPath": RedactorPaths.logDirectory.appendingPathComponent("launchd.stdout.log").path,
            "StandardErrorPath": RedactorPaths.logDirectory.appendingPathComponent("launchd.stderr.log").path,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        try? data.write(to: RedactorPaths.launchAgentPlist, options: [.atomic])
    }

    private static func runLaunchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
    }
}
