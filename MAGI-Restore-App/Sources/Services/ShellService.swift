import Foundation

struct ShellService {
    static func run(_ command: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe
        // GUI 앱은 PATH 상속 안 함 → homebrew/tmux/claude/nvm 경로 명시
        var env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()
        let nvmNodeBin = "\(home)/.nvm/versions/node/v22.18.0/bin"
        let extraPaths = "\(nvmNodeBin):/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
        env["PATH"] = extraPaths + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    @discardableResult
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

    static func killAsync(pid: Int) async {
        await runAsync("kill -TERM \(pid)")
    }

    static func intentionalStop(projectDir: String) {
        let registryScript = "~/.claude/scripts/session-registry.sh"
        let _ = run("bash \(registryScript) intentional-stop '\(projectDir)'")
    }

    static func intentionalStopAsync(projectDir: String) async {
        let registryScript = "~/.claude/scripts/session-registry.sh"
        await runAsync("bash \(registryScript) intentional-stop '\(projectDir)'")
    }
}
