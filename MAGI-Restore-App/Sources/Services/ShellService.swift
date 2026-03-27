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

    // 싱글쿼트 완전 이스케이프 ('...' 래핑 포함) — 모든 호출부에서 공유
    static func shellq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // projectDir을 싱글쿼트 안전하게 이스케이프
    private static func shellEscapeArg(_ s: String) -> String { shellq(s) }

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
        // 3. tmux window 종료 — window-groups.json에서 해당 창이 속한 세션 동적 탐색
        if !windowName.isEmpty {
            let escapedName = windowName.replacingOccurrences(of: "'", with: "'\\''")
            let killCmd = """
            python3 -c "
import json, os, subprocess
win = '\(escapedName)'
try:
    groups = json.load(open(os.path.expanduser('~/.claude/window-groups.json')))
    sessions = [g.get('sessionName','') for g in groups if not g.get('isWaitingList', False) and g.get('sessionName','') and g.get('sessionName','') != '__waiting__']
except:
    sessions = ['claude-work']
if not sessions:
    sessions = ['claude-work']
for sn in sessions:
    r = subprocess.run(['tmux','list-windows','-t',sn,'-F','#{window_index} #{window_name}'], capture_output=True, text=True)
    for line in r.stdout.strip().split('\\n'):
        parts = line.split(' ', 1)
        if len(parts) == 2 and parts[1] == win:
            subprocess.run(['tmux','kill-window','-t',sn + ':' + parts[0]], capture_output=True)
            break
" 2>/dev/null; true
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
                tmp = path + '.tmp'
                open(tmp, 'w').write(new_content)
                os.replace(tmp, path)
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
