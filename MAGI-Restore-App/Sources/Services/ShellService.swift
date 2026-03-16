import Foundation

struct ShellService {
    static func run(_ command: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func runAsync(_ command: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: run(command))
            }
        }
    }

    static func kill(pid: Int) {
        let _ = run("kill -TERM \(pid)")
    }

    static func intentionalStop(projectDir: String) {
        let registryScript = "~/.claude/scripts/session-registry.sh"
        let _ = run("bash \(registryScript) intentional-stop '\(projectDir)'")
    }
}
