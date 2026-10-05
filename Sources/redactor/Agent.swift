import AppKit
import CryptoKit
import Darwin
import Foundation
import UserNotifications

final class Agent: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum WatchMode: String {
        case watching
        case paused
        case pausedTemporarily = "paused_temporarily"
    }

    private enum LockResult {
        case acquired
        case busy
        case failed
    }

    private var list = PatternList(
        replacement: "[redacted]",
        minimumValueLength: 4,
        ignoreValues: [],
        parameterNames: [],
        normalizedNames: [],
        tokenPatterns: [],
        sourceURL: RedactorPaths.patternFile
    )
    private var mode = WatchMode.watching
    private var pauseUntil: Date?
    private var lastRemoval = "none"
    private var patternError: String?
    private var patternExists = false
    private var patternMtime: Date?
    private var patternBaselineReady = false
    private var alertUntil: Date?
    private var shownSymbol: String?
    private var askedNotifications = false
    private var debounce: [String: Date] = [:]
    private var lockFD: Int32 = -1
    private var statusItem: NSStatusItem?
    private var modeItem: NSMenuItem?
    private var removalItem: NSMenuItem?
    private var errorItem: NSMenuItem?
    private var pauseItem: NSMenuItem?
    private var loginItem: NSMenuItem?
    private var clipboard: ClipboardWatch?
    private let server = StatusServer()

    func launch() -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        switch acquireLock() {
        case .busy:
            return 0
        case .failed:
            return 1
        case .acquired:
            break
        }
        LoginItem.seedPatternsIfInstalled()
        do {
            let loaded = try PatternList.load(strict: false)
            list = loaded.list
            patternError = loaded.error
        } catch {
            log("pattern file invalid")
            return 1
        }
        notePatternBaseline()
        LoginItem.syncOnLaunch()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = self
        buildMenu()
        clipboard = ClipboardWatch(agent: self)
        clipboard?.start()
        if !server.start(agent: self) {
            log("status socket failed")
            return 1
        }
        log("started")
        app.run()
        return 0
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("quit")
        clipboard?.stop()
        server.stop()
    }

    func currentList() -> PatternList { list }

    var isPaused: Bool { mode != .watching }

    func expirePause() {
        guard mode == .pausedTemporarily, let until = pauseUntil, until <= Date() else { return }
        mode = .watching
        pauseUntil = nil
        log("resumed")
        refreshMenu()
    }

    func handleCommand(_ command: String) -> String {
        expirePause()
        switch command {
        case "PAUSE":
            if mode != .paused {
                mode = .paused
                pauseUntil = nil
                log("paused")
            }
        case "RESUME":
            if mode != .watching {
                mode = .watching
                pauseUntil = nil
                log("resumed")
            }
        default:
            break
        }
        refreshMenu()
        refreshSymbol()
        return statusText()
    }

    func noteRemoval(names: [String], redacted: String) {
        let sentence = "Removed " + names.joined(separator: ", ") + "."
        lastRemoval = sentence
        alertUntil = Date().addingTimeInterval(4)
        shownSymbol = nil
        refreshSymbol()
        let digest = SHA256.hash(data: Data(redacted.utf8)).map { String(format: "%02x", $0) }.joined()
        if shouldEmit(sentence + ":" + digest) {
            log(sentence)
            notify(sentence)
        }
        refreshMenu()
    }

    func noteTooLarge() {
        let sentence = "Clipboard left unchanged because it was too large to scan."
        lastRemoval = sentence
        if shouldEmit(sentence) { log(sentence) }
        refreshMenu()
    }

    private func menuBarImage(named name: String) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: "Redactor") else {
            return nil
        }
        let limit = max(16, NSStatusBar.system.thickness - 4)
        let configuration = NSImage.SymbolConfiguration(pointSize: limit, weight: .medium)
        guard let symbol = base.withSymbolConfiguration(configuration) else { return nil }
        symbol.isTemplate = false
        let symbolSize = symbol.size
        let fitted = min(limit / max(symbolSize.width, 1), limit / max(symbolSize.height, 1), 1)
        let glyph = NSSize(
            width: (symbolSize.width * fitted).rounded(.down),
            height: (symbolSize.height * fitted).rounded(.down)
        )
        let margin: CGFloat = 4
        let image = NSImage(size: NSSize(width: glyph.width + margin, height: glyph.height + margin), flipped: false) { rect in
            let origin = NSPoint(x: (rect.width - glyph.width) / 2, y: (rect.height - glyph.height) / 2)
            symbol.draw(in: NSRect(origin: origin, size: glyph), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        return image
    }

    func refreshSymbol() {
        let name: String
        if let until = alertUntil, until > Date() {
            name = "exclamationmark.shield"
        } else {
            alertUntil = nil
            name = "shield.lefthalf.filled"
        }
        if name == shownSymbol { return }
        guard let button = statusItem?.button else { return }
        shownSymbol = name
        if let image = menuBarImage(named: name) {
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageOnly
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "R"
        }
    }

    func reloadPatternsIfNeeded() {
        let url = RedactorPaths.patternFile
        let exists = FileManager.default.fileExists(atPath: url.path)
        let mtime = modificationDate(url, exists: exists)
        if !patternBaselineReady {
            patternBaselineReady = true
            patternExists = exists
            patternMtime = mtime
            return
        }
        if exists == patternExists && mtime == patternMtime { return }
        patternExists = exists
        patternMtime = mtime
        if !exists {
            if let factory = PatternList.locateFactory(), let loaded = try? PatternList.parse(url: factory) {
                list = loaded
                patternError = nil
            }
            refreshMenu()
            return
        }
        do {
            list = try PatternList.parse(url: url)
            patternError = nil
            log("reloaded patterns")
        } catch {
            patternError = menuError(error)
            log("pattern file invalid")
        }
        refreshMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenu()
        guard !askedNotifications else { return }
        askedNotifications = true
        guard Bundle.main.bundleIdentifier == "com.redactor.app" else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        modeItem = disabledItem("Watching")
        removalItem = disabledItem("Last removal: none")
        errorItem = disabledItem("Pattern file is invalid")
        errorItem?.isHidden = true
        pauseItem = actionItem("Pause", #selector(pauseOrResume))
        let pauseSixty = actionItem("Pause for 60 Seconds", #selector(pauseForSixty))
        let edit = actionItem("Edit Pattern List", #selector(editPatterns))
        loginItem = disabledItem("Open at login: no")
        let enable = actionItem("Enable Open at Login", #selector(enableLogin))
        let disable = actionItem("Disable Open at Login", #selector(disableLogin))
        let quit = actionItem("Quit Redactor", #selector(quit))
        for entry in [modeItem, removalItem, errorItem, pauseItem, pauseSixty, edit, loginItem, enable, disable, quit] {
            if let entry { menu.addItem(entry) }
        }
        item.menu = menu
        statusItem = item
        refreshSymbol()
        refreshMenu()
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    private func refreshMenu() {
        modeItem?.title = modeTitle()
        if lastRemoval == "none" {
            removalItem?.title = "Last removal: none"
        } else {
            removalItem?.title = lastRemoval
        }
        if let patternError {
            errorItem?.title = patternError
            errorItem?.isHidden = false
        } else {
            errorItem?.isHidden = true
        }
        pauseItem?.title = mode == .watching ? "Pause" : "Resume"
        let login = LoginItem.reportedState()
        loginItem?.title = "Open at login: " + login
    }

    private func modeTitle() -> String {
        switch mode {
        case .watching:
            return "Watching"
        case .paused:
            return "Paused"
        case .pausedTemporarily:
            return "Paused for \(pauseSecondsRemaining) seconds"
        }
    }

    private func statusText() -> String {
        let lines = [
            "state: running",
            "mode: \(mode.rawValue)",
            "pause_seconds_remaining: \(pauseSecondsRemaining)",
            "pid: \(getpid())",
            "pattern_file: \(list.sourceURL.path)",
            "parameter_names: \(list.parameterNames.count)",
            "token_shapes: \(list.tokenPatterns.count)",
            "last_removal: \(lastRemoval)",
            "open_at_login: \(LoginItem.reportedState())",
        ]
        return lines.joined(separator: "\n") + "\n\n"
    }

    private var pauseSecondsRemaining: Int {
        guard mode == .pausedTemporarily, let until = pauseUntil else { return 0 }
        return max(0, Int(ceil(until.timeIntervalSinceNow)))
    }

    @objc private func pauseOrResume(_ sender: Any?) {
        if mode == .watching {
            mode = .paused
            pauseUntil = nil
            log("paused")
        } else {
            mode = .watching
            pauseUntil = nil
            log("resumed")
        }
        refreshMenu()
        refreshSymbol()
    }

    @objc private func pauseForSixty(_ sender: Any?) {
        mode = .pausedTemporarily
        pauseUntil = Date().addingTimeInterval(60)
        log("paused for 60 seconds")
        refreshMenu()
        refreshSymbol()
    }

    @objc private func editPatterns(_ sender: Any?) {
        let destination = RedactorPaths.patternFile
        if !FileManager.default.fileExists(atPath: destination.path),
           let factory = PatternList.locateFactory(),
           let data = try? Data(contentsOf: factory) {
            RedactorPaths.ensure(RedactorPaths.supportDirectory)
            try? data.write(to: destination, options: [.atomic])
        }
        NSWorkspace.shared.open(destination)
    }

    @objc private func enableLogin(_ sender: Any?) {
        LoginItem.enableFromMenu()
        refreshMenu()
    }

    @objc private func disableLogin(_ sender: Any?) {
        LoginItem.disableFromMenu()
        refreshMenu()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func notePatternBaseline() {
        let url = RedactorPaths.patternFile
        patternExists = FileManager.default.fileExists(atPath: url.path)
        patternMtime = modificationDate(url, exists: patternExists)
        patternBaselineReady = true
    }

    private func modificationDate(_ url: URL, exists: Bool) -> Date? {
        guard exists else { return nil }
        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func menuError(_ error: Error) -> String {
        let text = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
        if text.count <= 240 { return text }
        return String(text.prefix(240))
    }

    private func shouldEmit(_ key: String) -> Bool {
        let now = Date()
        debounce = debounce.filter { now.timeIntervalSince($0.value) < 10 }
        if let last = debounce[key], now.timeIntervalSince(last) < 10 { return false }
        debounce[key] = now
        return true
    }

    private func notify(_ body: String) {
        guard Bundle.main.bundleIdentifier == "com.redactor.app" else { return }
        let content = UNMutableNotificationContent()
        content.title = "Redactor"
        content.body = body
        content.sound = nil
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func log(_ line: String) {
        RedactorPaths.ensure(RedactorPaths.logDirectory)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = Data((stamp + " " + line + "\n").utf8)
        let url = RedactorPaths.agentLog
        if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: text)
            try? handle.close()
        } else {
            try? text.write(to: url)
        }
    }

    private func acquireLock() -> LockResult {
        RedactorPaths.ensure(RedactorPaths.supportDirectory)
        let fd = open(RedactorPaths.lockFile.path, O_CREAT | O_RDWR, 0o600)
        if fd < 0 { return .failed }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let occupied = errno == EWOULDBLOCK || errno == EAGAIN
            close(fd)
            return occupied ? .busy : .failed
        }
        _ = fchmod(fd, 0o600)
        lockFD = fd
        return .acquired
    }
}
