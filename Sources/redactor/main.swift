import Darwin
import Foundation

private var runningAgent: Agent?

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.isEmpty || arguments == ["--launched-at-login"] {
    let agent = Agent()
    runningAgent = agent
    exit(agent.launch())
}

guard arguments.count == 1 else { usage() }

switch arguments[0] {
case "check":
    runCheck()
case "status":
    StatusClient.run("STATUS")
case "pause":
    StatusClient.run("PAUSE")
case "resume":
    StatusClient.run("RESUME")
default:
    usage()
}

private func usage() -> Never {
    FileHandle.standardError.write(Data("usage: redactor [check|status|pause|resume]\n".utf8))
    exit(2)
}

private func runCheck() -> Never {
    if isatty(STDIN_FILENO) != 0 {
        FileHandle.standardError.write(Data("redactor check: stdin is a terminal\n".utf8))
        exit(2)
    }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else {
        FileHandle.standardOutput.write(data)
        exit(0)
    }
    let loaded: (list: PatternList, error: String?)
    do {
        loaded = try PatternList.load(strict: true)
    } catch {
        FileHandle.standardError.write(Data("pattern file is invalid\n".utf8))
        exit(1)
    }
    if loaded.error != nil {
        FileHandle.standardError.write(Data("pattern file is invalid\n".utf8))
        exit(1)
    }
    let result = SecretRedactor(list: loaded.list).redact(text)
    FileHandle.standardOutput.write(Data(result.text.utf8))
    if !result.names.isEmpty {
        FileHandle.standardError.write(Data((result.names.joined(separator: "\n") + "\n").utf8))
    }
    exit(0)
}
