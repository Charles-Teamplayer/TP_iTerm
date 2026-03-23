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

    /// 세션 완전 삭제: 프로세스 kill + tmux window 제거 + 레지스트리 제거 + state 파일 제거
    static func purgeSessionAsync(pid: Int, windowName: String, tty: String, projectDir: String) async {
        let ttyBase = (tty as NSString).lastPathComponent

        // 1. intentional-stop 기록 (watchdog 자동 재시작 방지)
        if !projectDir.isEmpty {
            await runAsync("bash ~/.claude/scripts/session-registry.sh intentional-stop '\(projectDir)'")
        }
        // 2. 프로세스 강제 종료 (SIGKILL)
        if pid > 0 {
            await runAsync("kill -9 \(pid) 2>/dev/null; true")
        }
        // 3. tmux window 종료 (이름이 같은 모든 중복 윈도우 제거)
        if !windowName.isEmpty {
            let killCmd = "tmux list-windows -t claude-work -F '#{window_index} #{window_name}' 2>/dev/null | awk '{print $2, $1}' | grep -F '\(windowName) ' | awk '{print $2}' | sort -rn | while read idx; do tmux kill-window -t \"claude-work:$idx\" 2>/dev/null; done; true"
            await runAsync(killCmd)
        }
        // 4. active-sessions.json에서 해당 TTY 항목 제거
        if !ttyBase.isEmpty {
            let pyCmd = "python3 -c \"import json,os; path=os.path.expanduser('~/.claude/active-sessions.json'); d=json.load(open(path)); d['sessions']=[s for s in d.get('sessions',[]) if s.get('tty')!='\\(ttyBase)']; f=open(path+'.tmp','w'); json.dump(d,f,indent=2); f.close(); os.replace(path+'.tmp',path)\" 2>/dev/null; true"
            await runAsync(pyCmd)
        }
        // 5. tab-color state 파일 제거
        if !ttyBase.isEmpty {
            await runAsync("rm -f ~/.claude/tab-color/states/\(ttyBase).json 2>/dev/null; true")
        }
    }
}
