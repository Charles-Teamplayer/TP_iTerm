import Foundation
import Combine
import UserNotifications

@MainActor
final class SessionMonitor: ObservableObject {
    @Published var sessions: [ClaudeSession] = []
    @Published var selectedForRestore: Set<String> = []
    @Published var restoreProgress: (current: Int, total: Int)? = nil
    @Published var isBatchRestoring = false
    private var cancelRestoreFlag = false

    private var timer: Timer?
    private var syncTimer: Timer?
    @Published var isRefreshing = false   // 내부 dedup 전용
    @Published var isSyncing = false      // UI 배너 표시 전용 (사용자 액션 시만)
    private let activeSessionsPath = NSHomeDirectory() + "/.claude/active-sessions.json"
    private let statesDir = NSHomeDirectory() + "/.claude/tab-color/states"
    let profileService = ProfileService()
    let windowGroupService = WindowGroupService()

    // FSEvent 감시: tab-color/states 디렉토리 변경 → 즉시 refresh
    private var statesDirSource: DispatchSourceFileSystemObject?
    private var debounceTask: Task<Void, Never>?

    // 자동 재시작 설정 + 상태 추적
    @Published var restoreSettings = RestoreSettings.load()
    private var crashTimestamps: [String: Date] = [:]        // id → crash 발생 시각
    private var restoreAttemptCounts: [String: Int] = [:]    // id → 재시작 시도 횟수
    private var intentionallyStoppedIds: Set<String> = []    // 의도적 중지 추적 (by session ID)
    private var intentionallyStoppedProfiles: Set<String> = [] // 의도적 중지 추적 (by profileName, checkAutoSync 용)

    func start() {
        Task {
            await cleanupStaleLinkedSessions()
            await refresh()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
                await self?.checkAutoRestore()
                await self?.cleanupStaleLinkedSessions()
            }
        }
        setupStateWatcher()
        restartSyncTimer()
    }

    // client 없는 stale linked sessions(-vN) 자동 정리
    func cleanupStaleLinkedSessions() async {
        let raw = await ShellService.runAsync(
            "tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E '.*-v[0-9]+$'"
        )
        for s in raw.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
            let clients = await ShellService.runAsync("tmux list-clients -t '\(shellEscape(s))' 2>/dev/null | wc -l")
            if (Int(clients.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) == 0 {
                await ShellService.runAsync("tmux kill-session -t '\(shellEscape(s))' 2>/dev/null; true")
            }
        }
    }

    func restartSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = nil
        guard restoreSettings.autoSync, restoreSettings.syncIntervalSeconds > 0 else { return }
        let interval = TimeInterval(restoreSettings.syncIntervalSeconds)
        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkAutoSync() }
        }
    }

    private func setupStateWatcher() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: statesDir) {
            try? fm.createDirectory(atPath: statesDir, withIntermediateDirectories: true)
        }
        let fd = open(statesDir, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            self?.scheduleRefresh()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        statesDirSource = source
    }

    // 디바운스: 연속 변경 시 0.3초 후 경량 상태 업데이트 (ps 없이 states 파일만)
    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshStatusOnly()
        }
    }

    // 경량 refresh: states 파일만 읽어 claudeStatus 즉시 업데이트 (< 50ms)
    func refreshStatusOnly() {
        let ttyStatusMap = loadTtyStatusMap()
        sessions = sessions.map { session in
            var s = session
            if s.isRunning {
                let ttyBase = (s.tty as NSString).lastPathComponent
                if let statusType = ttyStatusMap[ttyBase] {
                    s.claudeStatus = ClaudeStatus(rawValue: statusType) ?? .unknown
                }
            }
            return s
        }
    }

    // 미배정 프로필 → 대기 목록 pane 자동 배정 (윈도우에 추가하지 않은 세션은 프로세스 미실행)
    func syncWindowGroupsWithProfiles() {
        windowGroupService.ensureWaitingList()
        let allAssigned = Set(windowGroupService.groups.flatMap { $0.profileNames })
        let unassigned = profileService.profiles.filter { !allAssigned.contains($0.name) }
        guard !unassigned.isEmpty else { return }
        let wl = windowGroupService.waitingList
        for profile in unassigned {
            windowGroupService.moveProfile(profile.name, to: wl)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        syncTimer?.invalidate()
        syncTimer = nil
        statesDirSource?.cancel()
        statesDirSource = nil
        debounceTask?.cancel()
    }

    deinit {
        timer?.invalidate()
    }

    func refresh(showBanner: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        if showBanner {
            isSyncing = true
            await Task.yield()  // SwiftUI 렌더링 틱 양보 (배너 먼저 표시)
        }
        defer {
            isRefreshing = false
            if showBanner { isSyncing = false }
        }

        let tmuxWindows = await loadTmuxWindows()
        let activeSessions = await loadActiveSessions()

        // ps 한 번만 실행해서 전체 claude 프로세스 캐시 (pid,ppid,tty,command 포함)
        let claudeProcessSnapshot = await ShellService.runAsync(
            "ps -o pid,ppid,tty,command -ax 2>/dev/null | grep '[c]laude'"
        )

        var result: [ClaudeSession] = []
        var matchedProjects = Set<String>()

        for tw in tmuxWindows {
            let claudePid = findClaudePidFromSnapshot(claudeProcessSnapshot, panePid: tw.panePid, paneTty: tw.paneTty)
            let isRunning = claudePid != nil

            let activeInfo = activeSessions.first { info in
                info.project == tw.windowName
                || info.dir.hasSuffix("/\(tw.windowName)")
                || tw.windowName.contains(info.project.lowercased())
                || info.project.lowercased().contains(tw.windowName.lowercased())
            }

            if let info = activeInfo {
                matchedProjects.insert(info.project)
            }

            result.append(ClaudeSession(
                id: tw.windowName,
                pid: claudePid ?? tw.panePid,
                tty: tw.paneTty,
                projectName: activeInfo?.project ?? tw.windowName,
                startTime: activeInfo?.started ?? "",
                directory: activeInfo?.dir ?? tw.rootDir,
                windowName: tw.windowName,
                windowIndex: tw.windowIndex,
                isRunning: isRunning,
                tmuxSession: tw.sessionName
            ))
        }

        for info in activeSessions where !matchedProjects.contains(info.project) {
            guard let pid = Int(info.pid) else { continue }
            let alive = await isProcessAlive(pid: pid)
            if alive {
                result.append(ClaudeSession(
                    id: "json-\(info.project)",
                    pid: pid,
                    tty: info.tty,
                    projectName: info.project,
                    startTime: info.started,
                    directory: info.dir,
                    windowName: info.project,
                    windowIndex: -1,
                    isRunning: true
                ))
            }
        }

        // 프로필 병합 — 세션 목록에 없는 프로필은 가상 정지 세션으로 추가
        profileService.load()
        let waitingListNames = Set(windowGroupService.groups
            .filter { $0.isWaitingList }
            .flatMap { $0.profileNames })
        let existingNames = Set(result.map { $0.projectName } + result.map { $0.windowName })
        // 프로필→그룹 세션명 맵 (profile-only 세션의 tmuxSession 주입용)
        var profileToSession: [String: String] = [:]
        for group in windowGroupService.groups where !group.isWaitingList {
            for name in group.profileNames { profileToSession[name] = group.sessionName }
        }
        for profile in profileService.profiles {
            guard !existingNames.contains(profile.name) else { continue }
            let rootPath = profile.root.isEmpty ? "~/claude/\(profile.name)" : profile.root
            let assigned = !waitingListNames.contains(profile.name)
            var session = ClaudeSession(
                id: "profile-\(profile.id)",
                pid: 0,
                tty: "",
                projectName: profile.name,
                startTime: "",
                directory: rootPath,
                windowName: profile.name,
                windowIndex: Int.max,
                isRunning: false,
                profileRoot: rootPath,
                profileDelay: profile.delay,
                isAssigned: assigned
            )
            session.tmuxSession = profileToSession[profile.name] ?? "claude-work"
            result.append(session)
        }

        // tab-color/states 디렉토리에서 TTY별 상태 읽기
        let ttyStatusMap = loadTtyStatusMap()

        // 기존 세션 중 프로필과 이름 매칭되면 profileRoot 주입
        var profileMap: [String: SmugProfile] = [:]
        for p in profileService.profiles { profileMap[p.name] = p }
        let activatedRoots = ActivationService.shared.loadActivated()
        result = result.map { session in
            var s = session
            if s.profileRoot == nil, let p = profileMap[s.projectName] ?? profileMap[s.windowName] {
                s.profileRoot = p.root
                s.profileDelay = p.delay
            }
            // 활성화 플래그 주입
            let root = s.profileRoot ?? s.directory
            s.isActivated = activatedRoots.contains(
                root.hasPrefix("~") ? NSHomeDirectory() + root.dropFirst() : root
            )
            // 실행 중인 세션(tmux 창 존재)은 배정 여부와 무관하게 isAssigned = true
            if !s.id.hasPrefix("profile-") {
                s.isAssigned = true
            }
            // TTY 기반 실시간 상태 주입 (tab-color/states)
            if s.isRunning {
                let ttyBase = (s.tty as NSString).lastPathComponent
                if let statusType = ttyStatusMap[ttyBase] {
                    s.claudeStatus = ClaudeStatus(rawValue: statusType) ?? .unknown
                }
            }
            return s
        }

        var newSessions = result.sorted {
            if $0.windowIndex == $1.windowIndex { return $0.projectName < $1.projectName }
            return $0.windowIndex < $1.windowIndex
        }
        detectChanges(old: sessions, new: &newSessions)
        sessions = newSessions
    }

    // crash 감지 + didCrash 플래그 반영 (의도적 중지는 crash로 처리하지 않음)
    private func detectChanges(old: [ClaudeSession], new: inout [ClaudeSession]) {
        guard !old.isEmpty else { return }
        var oldMap: [String: (running: Bool, crashed: Bool)] = [:]
        for s in old { oldMap[s.id] = (s.isRunning, s.didCrash) }

        for i in new.indices {
            let id = new[i].id
            guard let prev = oldMap[id] else { continue }
            if prev.running && !new[i].isRunning {
                if intentionallyStoppedIds.contains(id) {
                    // 의도적 중지 → crash 아님
                    new[i].didCrash = false
                } else {
                    // 비정상 종료 → crash
                    new[i].didCrash = true
                    if crashTimestamps[id] == nil { crashTimestamps[id] = Date() }
                    NotificationService.shared.notifySessionCrashed(name: new[i].projectName)
                }
            } else if new[i].isRunning {
                // 재실행 → crash 해제
                new[i].didCrash = false
                intentionallyStoppedIds.remove(id)
                crashTimestamps.removeValue(forKey: id)
                restoreAttemptCounts.removeValue(forKey: id)
            } else {
                new[i].didCrash = prev.crashed
            }
        }
    }

    // MARK: - Auto Restore

    func checkAutoRestore() async {
        guard restoreSettings.autoRestore else { return }
        let now = Date()
        let crashed = sessions.filter { $0.didCrash && !intentionallyStoppedIds.contains($0.id) }
        for session in crashed {
            guard let crashTime = crashTimestamps[session.id] else { continue }
            guard now.timeIntervalSince(crashTime) >= Double(restoreSettings.delaySeconds) else { continue }
            let attempts = restoreAttemptCounts[session.id] ?? 0
            guard attempts < restoreSettings.maxAttempts else { continue }
            restoreAttemptCounts[session.id] = attempts + 1
            await restartSession(session)
        }
    }

    // 수동/자동 재시작: 기존 창에 claude 재실행 (창이 없으면 새로 생성)
    func restartSession(_ session: ClaudeSession) async {
        // crash 플래그 즉시 해제 (UI 반응)
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx].didCrash = false
        }
        intentionallyStoppedIds.remove(session.id)
        crashTimestamps.removeValue(forKey: session.id)

        let dir = session.directory.isEmpty ? "~/claude/\(session.windowName)" : session.directory
        let safeDir = dir.hasPrefix("~") ? NSHomeDirectory() + dir.dropFirst() : dir
        let claudeCmd = hasClaudeProject(at: safeDir)
            ? "claude --dangerously-skip-permissions --continue"
            : "claude --dangerously-skip-permissions"
        let winNameForStatus = session.windowName
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "'", with: "'\\''")
        let claudeEntry = "bash ~/.claude/scripts/tab-status.sh starting '\(winNameForStatus)' && unset CLAUDECODE && \(claudeCmd)"

        if session.windowIndex >= 0 && session.windowIndex != Int.max {
            // 창 존재 여부 확인
            let paneCmd = await ShellService.runAsync(
                "tmux list-panes -t '\(session.tmuxSession):\(session.windowIndex)' -F '#{pane_current_command}' 2>/dev/null | head -1"
            )
            if paneCmd.isEmpty {
                // 창이 없어진 경우 → 새로 생성 (-P -F로 실제 index 획득 후 send-keys)
                let escapedName = shellEscape(session.windowName)
                let escapedDir  = shellEscape(safeDir)
                let newIdxRaw = await ShellService.runAsync("tmux new-window -t \(session.tmuxSession) -n '\(escapedName)' -c '\(escapedDir)' -P -F '#{window_index}'")
                let newIdx = newIdxRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                let winTarget = newIdx.isEmpty ? escapedName : newIdx
                await ShellService.runAsync("tmux send-keys -t '\(session.tmuxSession):\(winTarget)' '\(claudeEntry)' Enter 2>/dev/null")
            } else {
                await ShellService.runAsync("tmux send-keys -t '\(session.tmuxSession):\(session.windowIndex)' '\(claudeEntry)' Enter 2>/dev/null")
            }
        } else if let root = session.profileRoot {
            let group = windowGroupService.group(for: session.projectName)
            await launchProfile(name: session.projectName, root: root, delay: 0, sessionName: group.sessionName)
            return
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await refresh(showBanner: true)
    }

    // 강제 복구: 기존 창 완전 kill → 새 창 생성 → claude 실행 (어떤 상태에서도 무조건 새 창)
    func forceResetSession(_ session: ClaudeSession) async {
        // 기존 창 kill
        if session.windowIndex >= 0 && session.windowIndex != Int.max {
            await ShellService.runAsync("tmux kill-window -t '\(session.tmuxSession):\(session.windowIndex)' 2>/dev/null; true")
        }
        // crash 상태 초기화
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx].didCrash = false
        }
        intentionallyStoppedIds.remove(session.id)
        crashTimestamps.removeValue(forKey: session.id)
        restoreAttemptCounts.removeValue(forKey: session.id)

        // 새 창으로 런치
        let root = session.profileRoot ?? session.directory
        let safeRoot = root.hasPrefix("~") ? NSHomeDirectory() + root.dropFirst() : root
        let group = windowGroupService.group(for: session.projectName)
        ActivationService.shared.activate(root: safeRoot)
        await launchProfile(name: session.projectName, root: root, delay: 0, sessionName: group.sessionName)
    }

    // MARK: - Restore

    func restoreSelected() async {
        let toRestore = sessions.filter {
            selectedForRestore.contains($0.id) && !$0.isRunning && $0.isAssigned
        }
        guard !toRestore.isEmpty else { return }

        isRefreshing = true
        isBatchRestoring = true
        cancelRestoreFlag = false
        restoreProgress = (0, toRestore.count)
        defer {
            isRefreshing = false
            isBatchRestoring = false
            restoreProgress = nil
        }

        for (i, session) in toRestore.enumerated() {
            guard !cancelRestoreFlag else { break }
            let delay = session.profileDelay > 0 ? session.profileDelay : 0
            // profile-only 세션(windowIndex=Int.max)은 launchProfile로 위임
            if session.id.hasPrefix("profile-") || session.windowIndex == Int.max,
               let root = session.profileRoot {
                // window-groups에서 이 프로필이 속한 세션 이름 조회 (대기목록 제외)
                let targetSession = windowGroupService.groups
                    .first(where: { !$0.isWaitingList && $0.profileNames.contains(session.projectName) })?
                    .sessionName ?? "claude-work"
                await launchProfile(name: session.projectName, root: root, delay: delay, sessionName: targetSession)
                restoreProgress = (i + 1, toRestore.count)
                continue
            }

            let winName = shellEscape(session.windowName)
            let dir = session.directory.isEmpty ? "~/claude/\(session.windowName)" : session.directory
            let safeDir = dir.hasPrefix("~") ? NSHomeDirectory() + dir.dropFirst() : dir
            let escapedDir = shellEscape(safeDir)
            let claudeCmd = hasClaudeProject(at: safeDir)
                ? "claude --dangerously-skip-permissions --continue"
                : "claude --dangerously-skip-permissions"
            let escapedWindowName = shellEscape(session.windowName)
            let sleepPart = delay > 0 ? "sleep \(delay) && " : ""
            let claudeEntry = "\(sleepPart)bash ~/.claude/scripts/tab-status.sh starting '\(escapedWindowName)' && unset CLAUDECODE && \(claudeCmd)"

            // 창 존재 여부 먼저 확인 — windowIndex 기반 (이모지/특수문자 안전)
            let winIdx = session.windowIndex
            let paneCmd = await ShellService.runAsync(
                "tmux list-panes -t '\(session.tmuxSession):\(winIdx)' -F '#{pane_current_command}' 2>/dev/null | head -1"
            )

            if paneCmd.isEmpty {
                // 창이 사라진 경우 — 새로 생성 (-P -F로 실제 index 획득 후 send-keys)
                let newIdxRaw = await ShellService.runAsync(
                    "tmux new-window -t \(session.tmuxSession) -n '\(winName)' -c '\(escapedDir)' -P -F '#{window_index}'"
                )
                let newIdx2 = newIdxRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                let winTarget2 = newIdx2.isEmpty ? winName : newIdx2
                await ShellService.runAsync(
                    "tmux send-keys -t '\(session.tmuxSession):\(winTarget2)' '\(claudeEntry)' Enter 2>/dev/null"
                )
            } else {
                // 창이 있음 — windowIndex로 targeting (특수문자 무관)
                await ShellService.runAsync(
                    "tmux send-keys -t '\(session.tmuxSession):\(winIdx)' '\(claudeEntry)' Enter 2>/dev/null"
                )
            }

            restoreProgress = (i + 1, toRestore.count)

            // 배치 5개마다 2초 대기 (tmux 부하 분산)
            if (i + 1) % 5 == 0 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        let restoredCount = cancelRestoreFlag
            ? (restoreProgress?.current ?? 0)
            : toRestore.count
        NotificationService.shared.notifyRestoreComplete(count: restoredCount)
        selectedForRestore.removeAll()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await refresh(showBanner: true)
    }

    func purgeSession(_ session: ClaudeSession) async {
        intentionallyStoppedIds.insert(session.id)
        let projectDir = session.directory.isEmpty ? session.projectName : session.directory
        await ShellService.purgeSessionAsync(
            pid: session.pid,
            windowName: session.windowName,
            tty: session.tty,
            projectDir: projectDir
        )
        // window-groups.json과 activated-sessions에서도 제거 (checkAutoSync 재시작 방지)
        let projectName = session.projectName
        for i in windowGroupService.groups.indices {
            windowGroupService.groups[i].profileNames.removeAll { $0 == projectName }
        }
        windowGroupService.save()
        ActivationService.shared.deactivate(root: session.profileRoot ?? session.directory)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await refresh(showBanner: true)
    }

    /// 단일 세션 수동 중지 시 checkAutoSync 재시작 방지 (doStop/doKill 전 호출)
    func markIntentionallyStopped(_ session: ClaudeSession) {
        intentionallyStoppedIds.insert(session.id)
        intentionallyStoppedProfiles.insert(session.projectName)
    }

    func toggleSelection(_ id: String) {
        if selectedForRestore.contains(id) {
            selectedForRestore.remove(id)
        } else {
            selectedForRestore.insert(id)
        }
    }

    // 대기 목록의 모든 tmux 창 닫기 (zsh 포함 전체)
    func killWaitingListWindows() async {
        let waitingNames = Set(windowGroupService.waitingList.profileNames)
        let toKill = sessions.filter {
            !$0.id.hasPrefix("profile-") && $0.windowIndex >= 0 && $0.windowIndex != Int.max
            && waitingNames.contains($0.projectName)
        }
        for session in toKill { intentionallyStoppedIds.insert(session.id) }
        for session in toKill {
            intentionallyStoppedProfiles.insert(session.projectName)  // checkAutoSync 방지
            let dir = session.directory.isEmpty ? session.projectName : session.directory
            await ShellService.intentionalStopAsync(projectDir: dir)
            if session.pid > 0 {
                await ShellService.runAsync("kill -TERM \(session.pid) 2>/dev/null")
            }
            await ShellService.runAsync(
                "tmux kill-window -t '\(session.tmuxSession):\(session.windowIndex)' 2>/dev/null; true"
            )
        }
        if !toKill.isEmpty {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        await refresh(showBanner: true)
    }

    // claude 실행 중 세션 중지 + tmux 창 닫기
    func stopGroup(_ group: WindowPane) async {
        let profileNames = Set(group.profileNames)
        let toStop = sessions.filter { $0.isRunning && !$0.id.hasPrefix("profile-") && profileNames.contains($0.projectName) }
        for session in toStop { intentionallyStoppedIds.insert(session.id) }
        for session in toStop {
            let dir = session.directory.isEmpty ? session.projectName : session.directory
            await ShellService.intentionalStopAsync(projectDir: dir)
            if session.pid > 0 {
                await ShellService.runAsync("kill -TERM \(session.pid) 2>/dev/null")
            }
            if session.windowIndex >= 0 {
                await ShellService.runAsync(
                    "tmux kill-window -t '\(group.sessionName):\(session.windowIndex)' 2>/dev/null; true"
                )
            }
            // checkAutoSync 재시작 방지: 인메모리 셋 + deactivate (watchdog 보호 포함)
            intentionallyStoppedProfiles.insert(session.projectName)
            let root = session.profileRoot ?? session.directory
            ActivationService.shared.deactivate(root: root)
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await refresh(showBanner: true)
    }

    func stopAllRunning() async {
        let toStop = sessions.filter { $0.isRunning && !$0.id.hasPrefix("profile-") }
        for session in toStop { intentionallyStoppedIds.insert(session.id) }
        for session in toStop {
            let dir = session.directory.isEmpty ? session.projectName : session.directory
            await ShellService.intentionalStopAsync(projectDir: dir)
            if session.pid > 0 {
                await ShellService.runAsync("kill -TERM \(session.pid) 2>/dev/null")
            }
            // windowIndex 기반 tmux kill-window (이름 특수문자 무관, json-* 세션 -1 방어)
            if session.windowIndex >= 0 {
                await ShellService.runAsync(
                    "tmux kill-window -t '\(session.tmuxSession):\(session.windowIndex)' 2>/dev/null; true"
                )
            }
            // checkAutoSync 재시작 방지: 인메모리 셋 + deactivate (watchdog 보호 포함)
            intentionallyStoppedProfiles.insert(session.projectName)
            let root = session.profileRoot ?? session.directory
            ActivationService.shared.deactivate(root: root)
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await refresh(showBanner: true)
    }

    // zsh만 있는 유휴 창 전체 닫기 (복원 실패 후 남은 zsh 정리용)
    func purgeIdleZshWindows() async {
        let idleZsh = sessions.filter {
            !$0.isRunning && !$0.id.hasPrefix("profile-") && $0.windowIndex != Int.max
        }
        for session in idleZsh { intentionallyStoppedIds.insert(session.id) }
        for session in idleZsh {
            intentionallyStoppedProfiles.insert(session.projectName)  // BUG#14 fix: checkAutoSync 즉시 재시작 방지
            let winIdx = session.windowIndex
            let paneCmd = await ShellService.runAsync(
                "tmux list-panes -t '\(session.tmuxSession):\(winIdx)' -F '#{pane_current_command}' 2>/dev/null | head -1"
            )
            guard paneCmd == "zsh" || paneCmd == "bash" || paneCmd.isEmpty else {
                continue
            }
            let dir = session.directory.isEmpty ? session.projectName : session.directory
            await ShellService.intentionalStopAsync(projectDir: dir)
            await ShellService.runAsync(
                "tmux kill-window -t '\(session.tmuxSession):\(winIdx)' 2>/dev/null; true"
            )
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await refresh(showBanner: true)
    }

    /// ~/claude/ 디렉토리 기준 smug YAML 동기화
    /// — 디렉토리에 있는데 프로필에 없으면 추가, 디렉토리가 삭제된 프로필은 제거
    @discardableResult
    func syncProfilesWithDirectory(baseDir: String = "~/claude") -> (added: [String], removed: [String]) {
        let safeBase = baseDir.hasPrefix("~") ? NSHomeDirectory() + baseDir.dropFirst() : baseDir
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: safeBase) else { return ([], []) }

        let ignorePatterns = [
            "Claude_code_", "Claude-code_", "Claude-Code-",
            "_아카이빙", "_archived_", "_archive", "archive",
            "claude-squad", "claude_squad", "claude_gpt",
            "teamplean-github-pages", "teamplayer-github-pages",
            "TP_Infra_reduce_Project",
        ]

        let dirs = entries.filter { name in
            !name.hasPrefix(".") && !name.hasPrefix("_") &&
            !ignorePatterns.contains(where: { name.hasPrefix($0) || name.contains($0) }) &&
            (try? fm.attributesOfItem(atPath: safeBase + "/" + name)[.type] as? FileAttributeType) == .typeDirectory
        }

        profileService.load()
        let existingNames = Set(profileService.profiles.map { $0.name })
        let dirSet = Set(dirs)

        // 추가: 디렉토리에는 있는데 프로필에 없는 것
        var added: [String] = []
        for name in dirs.sorted() where !existingNames.contains(name) {
            let profile = SmugProfile(
                id: UUID(),
                name: name,
                root: baseDir + "/" + name,
                delay: 0,
                enabled: true
            )
            profileService.add(profile)
            added.append(name)
        }

        // 제거: 프로필에는 있는데 디렉토리가 없는 것 (순회 전 스냅샷으로 ConcurrentModification 방지)
        var removed: [String] = []
        let toRemove = profileService.profiles.filter { !dirSet.contains($0.name) }
        for profile in toRemove {
            profileService.delete(profile)
            removed.append(profile.name)
        }

        profileService.load()
        return (added, removed)
    }

    func selectAllStopped() {
        selectedForRestore.removeAll()
        for session in sessions where !session.isRunning
            && session.isAssigned
            && !session.id.hasPrefix("profile-")
            && session.windowIndex != Int.max {
            selectedForRestore.insert(session.id)
        }
    }

    func selectAllLaunchable() {
        selectedForRestore.removeAll()
        for session in sessions where !session.isRunning
            && session.isAssigned
            && (session.id.hasPrefix("profile-") || session.windowIndex == Int.max) {
            selectedForRestore.insert(session.id)
        }
    }

    func deselectAll() {
        selectedForRestore.removeAll()
    }

    func cancelRestore() {
        cancelRestoreFlag = true
    }

    func launchProfile(name: String, root: String, delay: Int, sessionName: String = "claude-work", createDir: Bool = false) async {
        let safeSession = sessionName.isEmpty ? "claude-work" : sessionName
        let escapedSafeSession = shellEscape(safeSession)
        // tmux 세션 없으면 자동 생성 (BUG#13: shellEscape 적용)
        let sessionExists = await ShellService.runAsync(
            "tmux has-session -t '\(escapedSafeSession)' 2>/dev/null && echo yes || echo no"
        )
        if sessionExists.trimmingCharacters(in: .whitespacesAndNewlines) == "no" {
            await ShellService.runAsync("tmux new-session -s '\(escapedSafeSession)' -d 2>/dev/null; true")
        }

        let safeRoot = root.hasPrefix("~") ? NSHomeDirectory() + root.dropFirst() : root

        // claude 프로젝트 데이터(.jsonl)가 있을 때만 --continue
        let hasPrior = !createDir && hasClaudeProject(at: safeRoot)
        let claudeCmd = hasPrior
            ? "claude --dangerously-skip-permissions --continue"
            : "claude --dangerously-skip-permissions"

        let escapedName = shellEscape(name)
        let escapedRoot = shellEscape(safeRoot)
        let escapedSession = shellEscape(safeSession)
        let mkdirPart = createDir ? "mkdir -p '\(escapedRoot)' && " : ""
        let sleepPart = delay > 0 ? "sleep \(delay) && " : ""
        let winNameForStatus = name.replacingOccurrences(of: "\"", with: "\\\"")
                                   .replacingOccurrences(of: "'", with: "'\\''")
        // 중복 생성 방지: check+create를 단일 shell 명령으로 atomic하게 처리
        let cmd = """
        if ! tmux list-windows -t '\(escapedSession)' -F '#{window_name}' 2>/dev/null | grep -qxF '\(escapedName)'; then \
          tmux new-window -t '\(escapedSession)' -n '\(escapedName)' -c '\(escapedRoot)' \\; \
          send-keys "\(mkdirPart)\(sleepPart)bash ~/.claude/scripts/tab-status.sh starting '\(winNameForStatus)' && unset CLAUDECODE && \(claudeCmd)" Enter 2>/dev/null; \
        fi; \
        true
        """
        ActivationService.shared.activate(root: safeRoot)
        intentionallyStoppedProfiles.remove(name)  // 수동 시작 → 중지 게이트 해제
        await ShellService.runAsync(cmd)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await refresh(showBanner: true)
    }

    // 자동 동기화: window-groups.json 상태와 tmux 실제 상태를 비교해 최소 변경만 적용
    // - 추가된 탭: launchProfile로 새 tmux 창 생성 (기존 창 무관)
    // - 제거된 탭: 해당 tmux 창만 kill (다른 창 무관)
    // - 순서 변경: reorderTabs로 move-window만 사용 (프로세스 재시작 없음)
    func checkAutoSync() async {
        guard restoreSettings.autoSync else { return }
        // auto-restore.sh가 최근 5분 내 실행된 경우 충돌 방지 (부팅 직후 경쟁 방지)
        let restoreDoneFlag = NSHomeDirectory() + "/.claude/logs/.auto-restore-done"
        if let ts = try? String(contentsOfFile: restoreDoneFlag, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let flagTime = Double(ts), Date().timeIntervalSince1970 - flagTime < 300 {
            return
        }
        windowGroupService.load()
        let activeGroups = windowGroupService.groups.filter { !$0.isWaitingList }
        for group in activeGroups {
            let sname = group.sessionName
            let escaped = shellEscape(sname)

            // tmux 세션 없으면 스킵 (startGroup으로 명시적 시작 필요)
            let exists = await ShellService.runAsync(
                "tmux has-session -t '\(escaped)' 2>/dev/null && echo yes || echo no"
            )
            guard exists.trimmingCharacters(in: .whitespacesAndNewlines) == "yes" else { continue }

            // 현재 tmux 창 목록 (monitor, _init_ 제외)
            let rawWins = await ShellService.runAsync(
                "tmux list-windows -t '\(escaped)' -F '#{window_name}' 2>/dev/null"
            )
            let currentWindows = rawWins.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != "monitor" && $0 != "_init_" }

            let desiredProfiles = group.profileNames
            let currentSet = Set(currentWindows)
            let desiredSet = Set(desiredProfiles)

            // 이미 동일하면 스킵
            if currentWindows == desiredProfiles { continue }

            var anyChange = false

            // 추가: desired에 있는데 tmux에 없는 탭
            let activatedPathList = ActivationService.shared.loadActivated()
            for profileName in desiredProfiles where !currentSet.contains(profileName) {
                // 의도적으로 중지된 세션은 자동 재시작 안 함 (stopGroup/stopAllRunning 후)
                guard !intentionallyStoppedProfiles.contains(profileName) else { continue }
                // ProfileService 우선, 없으면 activated-sessions.json에서 경로 추론
                var rootToUse: String
                if let profile = profileService.profiles.first(where: { $0.name == profileName }) {
                    rootToUse = profile.root
                } else if let activated = activatedPathList.first(where: { $0.hasSuffix("/\(profileName)") }) {
                    rootToUse = activated
                } else {
                    continue
                }
                let safeRoot = rootToUse.hasPrefix("~") ? NSHomeDirectory() + rootToUse.dropFirst() : rootToUse
                let dirOk = await ShellService.runAsync("[ -d '\(shellEscape(safeRoot))' ] && echo yes || echo no")
                guard dirOk.trimmingCharacters(in: .whitespacesAndNewlines) == "yes" else { continue }
                await launchProfile(name: profileName, root: rootToUse, delay: 0, sessionName: sname)
                anyChange = true
            }

            // 제거: tmux에 있는데 desired에 없는 탭 (BUG#12: intentional stop 처리 후 kill)
            for windowName in currentWindows where !desiredSet.contains(windowName) {
                intentionallyStoppedProfiles.insert(windowName)  // crash 감지 방지
                // 실행 중인 세션은 intentional-stop 기록 + graceful TERM
                if let runningSession = sessions.first(where: {
                    $0.projectName == windowName && $0.tmuxSession == sname && $0.isRunning
                }) {
                    intentionallyStoppedIds.insert(runningSession.id)
                    let dir = runningSession.directory.isEmpty ? windowName : runningSession.directory
                    await ShellService.intentionalStopAsync(projectDir: dir)
                    if runningSession.pid > 0 {
                        await ShellService.runAsync("kill -TERM \(runningSession.pid) 2>/dev/null; true")
                    }
                }
                await ShellService.runAsync(
                    "tmux kill-window -t '\(escaped):\(shellEscape(windowName))' 2>/dev/null; true"
                )
                anyChange = true
            }

            // 순서 변경: desired 순서와 다르면 reorderTabs (move-window만 사용, 프로세스 무관)
            let rawWinsAfter = await ShellService.runAsync(
                "tmux list-windows -t '\(escaped)' -F '#{window_name}' 2>/dev/null"
            )
            let windowsAfter = rawWinsAfter.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != "monitor" && $0 != "_init_" }
            if windowsAfter != desiredProfiles {
                await reorderTabs(for: group)
                anyChange = true
            }

            if anyChange {
                await refresh(showBanner: false)
            }
        }
    }

    // 즉시 적용: 배정된 pane의 중단된 세션 모두 시작 + 모든 그룹 탭 순서 재배치
    func applyNow() async {
        selectAllLaunchable()
        await restoreSelected()
        // 모든 활성 그룹 탭 순서 재배치
        for group in windowGroupService.groups where !group.isWaitingList {
            await reorderTabs(for: group)
        }
    }

    // 그룹(창) 전체 시작: tmux 세션 생성 + iTerm 새 창 attach + 프로필 순서대로 열기 + 탭 재배치
    func startGroup(_ group: WindowPane) async {
        guard !group.isWaitingList else { return }
        let sessionName = group.sessionName
        let escapedSession = shellEscape(sessionName)

        // tmux 세션 없으면 _init_ 임시 창으로 생성 (profile → monitor 순서로 맨 뒤 배치)
        let exists = await ShellService.runAsync(
            "tmux has-session -t '\(escapedSession)' 2>/dev/null && echo yes || echo no"
        )
        if exists.trimmingCharacters(in: .whitespacesAndNewlines) == "no" {
            await ShellService.runAsync(
                "tmux new-session -d -s '\(escapedSession)' -n _init_ -c '\(NSHomeDirectory())/claude' 2>/dev/null; true"
            )
        }

        // 꺼진 세션만 기동 (실행 중이면 유지)
        let allProfiles = profileService.profiles
        let runningSessions = Set(sessions.filter { $0.isRunning }.map { $0.projectName })
        for (i, profileName) in group.profileNames.enumerated() {
            guard let profile = allProfiles.first(where: { $0.name == profileName }) else { continue }
            if runningSessions.contains(profileName) { continue }  // 실행 중이면 skip
            await launchProfile(name: profile.name, root: profile.root, delay: i * 2, sessionName: sessionName)
        }

        // BUG#10 fix: linked sessions kill 전에 TTY 수집해야 함
        // linked sessions가 살아있는 동안 closeExistingITermWindows를 먼저 호출
        await closeExistingITermWindows(for: sessionName)

        // 기존 monitor 창 모두 제거 후 맨 마지막에 하나만 재생성 + _init_ 제거
        // 이전 linked view sessions 정리 (중복 방지)
        await ShellService.runAsync("""
            tmux list-windows -t '\(escapedSession)' -F '#{window_id}|#{window_name}' 2>/dev/null \
              | awk -F'|' '$2=="monitor"{print $1}' \
              | xargs -I{} tmux kill-window -t {} 2>/dev/null; \
            tmux kill-window -t '\(escapedSession):_init_' 2>/dev/null; \
            tmux new-window -t '\(escapedSession)' -n monitor -c '\(NSHomeDirectory())/claude' '/bin/bash -c \"while true; do sleep 86400; done\"' 2>/dev/null; \
            tmux set-window-option -t '\(escapedSession):monitor' automatic-rename off 2>/dev/null; \
            tmux move-window -s '\(escapedSession):monitor' -t '\(escapedSession):999' 2>/dev/null; \
            SNAME=\(ShellService.shellq(sessionName)) tmux list-sessions -F '#{session_name}' 2>/dev/null \
              | python3 -c "import sys,os,re; sn=os.environ['SNAME']; [print(l.strip()) for l in sys.stdin if re.fullmatch(re.escape(sn)+r'-v[0-9]+', l.strip())]" \
              | xargs -I{} tmux kill-session -t {} 2>/dev/null; \
            true
            """
        )

        // 탭 순서 재배치 (profileNames 순서, monitor는 999)
        await reorderTabs(for: group)

        // iTerm2 새 창 + 각 tmux 창마다 탭 생성 (CC 모드 대신 개별 attach)
        try? await Task.sleep(nanoseconds: 2_000_000_000)  // 창 생성 대기
        await openITermTabs(for: group)

        await refresh(showBanner: true)
    }

    // 이 tmux 세션에 붙어있는 기존 iTerm2 창 모두 닫기 (TTY 기반 매칭)
    func closeExistingITermWindows(for sessionName: String) async {
        // main session + linked view sessions(-v*)에서 클라이언트 TTY 수집
        let ttysRaw = await ShellService.runAsync("""
            { tmux list-clients -t '\(shellEscape(sessionName))' -F '#{client_tty}' 2>/dev/null; \
              SNAME=\(ShellService.shellq(sessionName)) tmux list-sessions -F '#{session_name}' 2>/dev/null \
                | python3 -c "import sys,os,re; sn=os.environ['SNAME']; [print(l.strip()) for l in sys.stdin if re.fullmatch(re.escape(sn)+r'-v[0-9]+', l.strip())]" \
                | while read s; do tmux list-clients -t "$s" -F '#{client_tty}' 2>/dev/null; done; \
            } | sort -u
            """
        )
        let ttys = ttysRaw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !ttys.isEmpty else { return }

        let ttyList = ttys.map { "\"\($0)\"" }.joined(separator: ", ")
        let script = """
        osascript << '__APPLES__'
        tell application "iTerm2"
            set ttySet to {\(ttyList)}
            set toClose to {}
            repeat with w in every window
                repeat with t in every tab of w
                    try
                        if tty of current session of t is in ttySet then
                            set end of toClose to w
                            exit repeat
                        end if
                    end try
                end repeat
            end repeat
            repeat with w in toClose
                close w
            end repeat
        end tell
        __APPLES__
        """
        await ShellService.runAsync(script)
    }

    // iTerm2 새 창 + tmux 창마다 탭 생성 (CC 모드 대신 개별 attach)
    func openITermTabs(for group: WindowPane) async {
        guard !group.isWaitingList else { return }
        let sname = group.sessionName

        // 현재 tmux windows 목록 조회 (index|name 형식)
        let rawWins = await ShellService.runAsync(
            "tmux list-windows -t '\(shellEscape(sname))' -F '#{window_index}|#{window_name}' 2>/dev/null"
        )
        var winPairs: [(Int, String)] = []
        for line in rawWins.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "|")
            if parts.count == 2, let idx = Int(parts[0]) {
                winPairs.append((idx, parts[1]))
            }
        }
        // monitor 제외한 실제 탭만 생성 (monitor 탭은 사용자에게 불필요)
        let realPairs = winPairs.filter { $0.1 != "monitor" }
        guard !realPairs.isEmpty else { return }

        // AppleScript: linked session 방식 (각 탭이 독립적인 창 추적)
        // tmux attach-session -t session:N 방식은 마지막 N이 session 전체 current window를 덮어씀
        // → {sname}-v{winIdx} linked session 생성으로 각 탭 독립 창 보장
        let firstWinIdx = realPairs[0].0
        let firstLinked = "\(sname)-v\(firstWinIdx)"
        let firstCmd = "/bin/bash -lc 'tmux has-session -t \(firstLinked) 2>/dev/null || tmux new-session -d -s \(firstLinked) -t \(sname) 2>/dev/null; tmux select-window -t \(firstLinked):\(firstWinIdx) 2>/dev/null; tmux attach-session -t \(firstLinked); exec /bin/zsh -l'"
        var lines: [String] = [
            "tell application \"iTerm2\"",
            "    activate",
            "    set newWin to (create window with default profile command \"\(firstCmd)\")",
        ]
        for (winIdx, _) in realPairs.dropFirst() {
            let linkedName = "\(sname)-v\(winIdx)"
            let cmd = "/bin/bash -lc 'tmux has-session -t \(linkedName) 2>/dev/null || tmux new-session -d -s \(linkedName) -t \(sname) 2>/dev/null; tmux select-window -t \(linkedName):\(winIdx) 2>/dev/null; tmux attach-session -t \(linkedName); exec /bin/zsh -l'"
            lines.append("    delay 0.5")
            lines.append("    tell newWin")
            lines.append("        create tab with default profile command \"\(cmd)\"")
            lines.append("    end tell")
        }
        lines.append("end tell")

        let appleScript = lines.joined(separator: "\n")
        let script = "osascript << '__APPLES__'\n\(appleScript)\n__APPLES__"
        await ShellService.runAsync(script)
    }

    // profileNames 순서대로 tmux 탭 재배치 (1부터 시작, monitor는 0 유지)
    func reorderTabs(for group: WindowPane) async {
        guard !group.isWaitingList else { return }
        let sname = group.sessionName
        let order = group.profileNames

        // 현재 창 목록 (이름→인덱스)
        let rawWindows = await ShellService.runAsync(
            "tmux list-windows -t '\(shellEscape(sname))' -F '#{window_index}|#{window_name}' 2>/dev/null"
        )
        var nameToIdx: [String: Int] = [:]
        for line in rawWindows.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "|")
            guard parts.count >= 2, let idx = Int(parts[0]) else { continue }
            nameToIdx[parts[1]] = idx
        }

        // temp 인덱스(500+)로 이동 → 충돌 없이 순서 변경 가능
        let tempBase = 500
        for (i, profile) in order.enumerated() {
            guard let src = nameToIdx[profile] else { continue }
            await ShellService.runAsync(
                "tmux move-window -s '\(shellEscape(sname)):\(src)' -t '\(shellEscape(sname)):\(tempBase + i)' 2>/dev/null; true"
            )
        }

        // 최종 순서로 이동 (1부터 시작)
        for (i, profile) in order.enumerated() {
            let tempIdx = tempBase + i
            let targetIdx = i + 1
            await ShellService.runAsync(
                "tmux move-window -s '\(shellEscape(sname)):\(tempIdx)' -t '\(shellEscape(sname)):\(targetIdx)' 2>/dev/null; true"
            )
            _ = profile
        }

        // monitor는 항상 맨 뒤 (index 999)
        await ShellService.runAsync(
            "tmux move-window -s '\(shellEscape(sname)):monitor' -t '\(shellEscape(sname)):999' 2>/dev/null; true"
        )
    }

    func createSession(name: String, directory: String, sessionName: String? = nil) async {
        let safeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeDir = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeName.isEmpty, !safeDir.isEmpty else { return }

        // 호출자가 sessionName 지정하면 사용, 없으면 첫 번째 active 세션 (없으면 claude-work)
        let targetSession = sessionName ?? windowGroupService.groups
            .first(where: { !$0.isWaitingList })?.sessionName ?? "claude-work"
        let escapedName = shellEscape(safeName)
        let escapedDir = shellEscape(safeDir)
        let escapedSession = shellEscape(targetSession)
        let nameForStatus = safeName.replacingOccurrences(of: "\"", with: "\\\"")
                                     .replacingOccurrences(of: "'", with: "'\\''")
        // 중복 방지: check+create 단일 shell 명령
        let cmd = """
        if ! tmux list-windows -t '\(escapedSession)' -F '#{window_name}' 2>/dev/null | grep -qxF '\(escapedName)'; then \
          tmux new-window -t '\(escapedSession)' -n '\(escapedName)' -c '\(escapedDir)' \\; \
          send-keys "bash ~/.claude/scripts/tab-status.sh starting '\(nameForStatus)' && unset CLAUDECODE && claude --dangerously-skip-permissions" Enter 2>/dev/null; \
        fi; true
        """
        await ShellService.runAsync(cmd)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await refresh(showBanner: true)
    }

    // inner escape only (caller wraps in '...')
    private func shellEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

    // full shell-quote (wraps in '...')
    private func shellq(_ s: String) -> String { ShellService.shellq(s) }

    // MARK: - Data Loading

    private struct TmuxWindow {
        let windowIndex: Int
        let windowName: String
        let panePid: Int
        let paneTty: String
        let rootDir: String
        let sessionName: String
    }

    private struct ActiveSessionInfo {
        let project: String
        let dir: String
        let pid: String
        let tty: String
        let started: String
    }

    private func hasClaudeProject(at path: String) -> Bool {
        // /Users/foo/claude/proj → -Users-foo-claude-proj
        let encoded = path.unicodeScalars.map { c in
            CharacterSet.alphanumerics.contains(c) ? String(c) : "-"
        }.joined()
        let projectDir = NSHomeDirectory() + "/.claude/projects/" + encoded
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: projectDir) else { return false }
        return files.contains { $0.hasSuffix(".jsonl") }
    }

    private func loadTmuxWindows() async -> [TmuxWindow] {
        // window-groups.json에서 active 세션 목록 조회
        let groupsRaw = await ShellService.runAsync("""
            python3 -c "
import json, os
try:
    groups = json.load(open(os.path.expanduser('~/.claude/window-groups.json')))
    for g in groups:
        sn = g.get('sessionName','')
        if not g.get('isWaitingList', False) and sn and sn != '__waiting__':
            print(sn)
except: pass
" 2>/dev/null
""")
        let activeSessions = groupsRaw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let sessions = activeSessions.isEmpty ? ["claude-work"] : activeSessions

        var result: [TmuxWindow] = []
        for sessionName in sessions {
            let escaped = shellEscape(sessionName)
            let output = await ShellService.runAsync(
                "tmux list-windows -t '\(escaped)' -F '#{window_index}\u{01}#{window_name}\u{01}#{pane_pid}\u{01}#{pane_tty}\u{01}#{pane_current_path}' 2>/dev/null"
            )
            guard !output.isEmpty else { continue }
            for line in output.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: "\u{01}")
                guard parts.count >= 4 else { continue }
                guard let idx = Int(parts[0]), let pid = Int(parts[2]) else { continue }
                result.append(TmuxWindow(
                    windowIndex: idx,
                    windowName: parts[1],
                    panePid: pid,
                    paneTty: parts[3],
                    rootDir: parts.count >= 5 ? parts[4] : "",
                    sessionName: sessionName
                ))
            }
        }
        return result
    }

    private func loadActiveSessions() async -> [ActiveSessionInfo] {
        guard let data = FileManager.default.contents(atPath: activeSessionsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = json["sessions"] as? [[String: Any]] else {
            return []
        }
        return sessions.compactMap { s in
            guard let project = s["project"] as? String else { return nil }
            return ActiveSessionInfo(
                project: project,
                dir: (s["dir"] as? String) ?? "",
                pid: (s["pid"] as? String) ?? "",
                tty: (s["tty"] as? String) ?? "??",
                started: (s["started"] as? String) ?? ""
            )
        }
    }

    // ps 스냅샷(pid,ppid,tty,command)에서 Claude PID 탐색 — ps 중복 실행 없음
    // 출력 형식: "  PID  PPID TTY  COMMAND..."
    private func findClaudePidFromSnapshot(_ snapshot: String, panePid: Int, paneTty: String) -> Int? {
        let ttyBase = paneTty.isEmpty ? "" : (paneTty as NSString).lastPathComponent
        for line in snapshot.components(separatedBy: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces)
            guard parts.count >= 3,
                  let pid = Int(parts[0]) else { continue }
            // 방법1: TTY 매칭
            if !ttyBase.isEmpty && parts[2] == ttyBase {
                return pid
            }
            // 방법2: PPID 매칭 (직계 자식)
            if let ppid = Int(parts[1]), ppid == panePid {
                return pid
            }
        }
        return nil
    }

    private func isProcessAlive(pid: Int) async -> Bool {
        let result = await ShellService.runAsync("kill -0 \(pid) 2>/dev/null && echo alive")
        return result == "alive"
    }

    // tab-color/states/*.json → [ttyBase: type] 맵 (동기, 가벼운 파일 읽기)
    private func loadTtyStatusMap() -> [String: String] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: statesDir) else { return [:] }
        var map: [String: String] = [:]
        for file in files where file.hasSuffix(".json") {
            let path = statesDir + "/" + file
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type_ = json["type"] as? String else { continue }
            let ttyBase = file.replacingOccurrences(of: ".json", with: "")  // "ttys007"
            map[ttyBase] = type_
        }
        return map
    }
}
