import AppKit
import Foundation

final class ClipboardWatch {
    private weak var agent: Agent?
    private var timer: Timer?
    private var remembered: Int

    init(agent: Agent) {
        self.agent = agent
        remembered = NSPasteboard.general.changeCount
    }

    func start() {
        remembered = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let agent else { return }
        agent.expirePause()
        agent.reloadPatternsIfNeeded()
        agent.refreshSymbol()
        let pasteboard = NSPasteboard.general
        let seen = pasteboard.changeCount
        if agent.isPaused {
            remembered = seen
            return
        }
        if seen == remembered { return }
        inspect(pasteboard, seen: seen, agent: agent)
    }

    private func inspect(_ pasteboard: NSPasteboard, seen: Int, agent: Agent) {
        let source: String
        if let plain = pasteboard.string(forType: .string) {
            source = plain
        } else if let html = pasteboard.string(forType: .html) {
            if html.utf8.count > 1_000_000 {
                agent.noteTooLarge()
                remembered = seen
                return
            }
            source = stripTags(html)
        } else {
            remembered = seen
            return
        }
        if source.utf8.count > 1_000_000 {
            agent.noteTooLarge()
            remembered = seen
            return
        }
        let result = SecretRedactor(list: agent.currentList()).redact(source)
        if result.names.isEmpty {
            remembered = seen
            return
        }
        if pasteboard.changeCount != seen { return }
        guard write(result.text, to: pasteboard) else { return }
        remembered = pasteboard.changeCount
        agent.noteRemoval(names: result.names, redacted: result.text)
    }

    private func write(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    private func stripTags(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]{0,200}>", options: []) else { return html }
        let range = NSRange(html.startIndex..., in: html)
        return regex.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: "")
    }
}
