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
        // nvm 최신 버전 동적 탐색 (하드코딩 제거)
        let nvmVersionsDir = "\(home)/.nvm/versions/node"
        let nvmNodeBin: String
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmVersionsDir),
           let latest = versions.filter({ $0.hasPrefix("v") }).sorted(by: { $0.compare($1, options: .numeric) == .orderedAscending }).last {
            nvmNodeBin = "\(nvmVersionsDir)/\(latest)/bin"
        } else {
            nvmNodeBin = "\(home)/.nvm/versions/node/v22.18.0/bin"  // fallback
        }
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

    // projectDir을 싱글쿼트 안전하게 이스케이프
    private static func shellEscapeArg(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func intentionalStop(projectDir: String) {
        let registryScript = "~/.claude/scripts/session-registry.sh"
        let escaped = shellEscapeArg(projectDir)
        let _ = run("bash \(registryScript) intentional-stop \(escaped)")
    }

    static func intentionalStopAsync(projectDir: String) async {
        let registryScript = "~/.claude/scripts/session-registry.sh"
        let escaped = shellEscapeArg(projectDir)
        await runAsync("bash \(registryScript) intentional-stop \(escaped)")
    }

    /// 세션 완전 삭제: 프로세스 kill + tmux window 제거 + 레지스트리 제거 + state 파일 제거 + smug YAML 제거
    static func purgeSessionAsync(pid: Int, windowName: String, tty: String, projectDir: String) async {
        let ttyBase = (tty as NSString).lastPathComponent

        // 1. intentional-stop 기록 (watchdog 자동 재시작 방지)
        if !projectDir.isEmpty {
            await intentionalStopAsync(projectDir: projectDir)
        }
        // 2. 프로세스 강제 종료 (SIGKILL)
        if pid > 0 {
            await runAsync("kill -9 \(pid) 2>/dev/null; true")
        }
        // 3. tmux window 종료 — 이름 정확 일치 (windowIndex 기반 대안 없으므로 이름 비교 유지)
        if !windowName.isEmpty {
            let escapedName = windowName.replacingOccurrences(of: "'", with: "'\\''")
            let killCmd = """
            tmux list-windows -t claude-work -F '#{window_index} #{window_name}' 2>/dev/null \
            | while IFS=' ' read -r idx name; do \
              [ "$name" = '\(escapedName)' ] && tmux kill-window -t "claude-work:$idx" 2>/dev/null; \
            done; true
            """
            await runAsync(killCmd)
        }
        // 4. active-sessions.json 제거 — 환경변수로 값 전달 (인라인 삽입 제거)
        let pyRemoveSession = """
        TTY_BASE=\(shellEscapeArg(ttyBase)) WIN_NAME=\(shellEscapeArg(windowName)) \
        python3 -c "
        import json, os
        tty = os.environ['TTY_BASE']
        win = os.environ['WIN_NAME']
        path = os.path.expanduser('~/.claude/active-sessions.json')
        try:
            d = json.load(open(path))
            d['sessions'] = [s for s in d.get('sessions', [])
                if s.get('tty') != tty and s.get('project') != win]
            tmp = path + '.tmp'
            json.dump(d, open(tmp, 'w'), indent=2)
            os.replace(tmp, path)
        except: pass
        " 2>/dev/null; true
        """
        await runAsync(pyRemoveSession)
        // 5. smug YAML 블록 제거 — 환경변수 + re.escape (regex 특수문자 안전)
        if !windowName.isEmpty {
            let pyRemoveYml = """
            WIN_NAME=\(shellEscapeArg(windowName)) \
            python3 -c "
            import re, os
            name = os.environ['WIN_NAME']
            path = os.path.expanduser('~/.config/smug/claude-work.yml')
            try:
                content = open(path).read()
                pattern = r'  - name: ' + re.escape(name) + r'\\n(?:(?!  - name:).)*'
                new_content = re.sub(pattern, '', content, flags=re.DOTALL)
                open(path, 'w').write(new_content)
            except: pass
            " 2>/dev/null; true
            """
            await runAsync(pyRemoveYml)
        }
        // 6. tab-color state 파일 제거
        if !ttyBase.isEmpty {
            let safeTty = ttyBase.replacingOccurrences(of: "/", with: "")
                .replacingOccurrences(of: " ", with: "")
            await runAsync("rm -f ~/.claude/tab-color/states/\(safeTty).json 2>/dev/null; true")
        }
    }
}
