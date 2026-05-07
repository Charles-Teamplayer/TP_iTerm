import SwiftUI

struct MonitoringView: View {
    @ObservedObject var monitor: SessionMonitor
    @StateObject private var codexMonitor = CodexMonitorService()
    @State private var selectedAgentId: String?
    @State private var refreshing = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Active Agents (\(activeAgents.count))")
                        .font(.headline)
                    Spacer()
                    Text("Updated \(codexMonitor.lastUpdate.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button {
                        Task {
                            refreshing = true
                            await codexMonitor.refresh()
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            refreshing = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if refreshing {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.clockwise.circle.fill")
                                    .font(.system(size: 16))
                            }
                            Text(refreshing ? "Refreshing..." : "Refresh")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(refreshing ? 0.3 : 0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(refreshing)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(activeGroupNames, id: \.self) { sessionName in
                            // 그룹 헤더 (1차) — 활성 agent 있는 그룹만
                            Text(displayGroupName(sessionName))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                                .padding(.bottom, 4)

                            // 윈도우(부모) 1차 + sub-agent 2차 (들여쓰기)
                            let agentsInGroup = activeAgentsByGroup[sessionName] ?? []
                            let byWindow = Dictionary(grouping: agentsInGroup, by: { $0.windowName })
                            ForEach(byWindow.keys.sorted(), id: \.self) { winName in
                                let agents = (byWindow[winName] ?? []).sorted { $0.paneIndex < $1.paneIndex }
                                ForEach(agents) { agent in
                                    AgentRow(
                                        agent: agent,
                                        isSelected: selectedAgentId == agent.id,
                                        indentLevel: agent.isParent ? 0 : 1
                                    )
                                    .onTapGesture { selectedAgentId = agent.id }
                                }
                            }
                        }
                        if activeGroupNames.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "moon.zzz")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.secondary)
                                Text("No active agents")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Text("Agents 작업 시작하면 여기 표시됩니다")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        }
                    }
                }
            }
            .frame(width: 380)

            Divider()

            if let agent = codexMonitor.agents.first(where: { $0.id == selectedAgentId }) {
                AgentDetailView(agent: agent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "cursorarrow.click")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Select an agent to see details")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { codexMonitor.start() }
        .onDisappear { codexMonitor.stop() }
    }

    private var groupedAgents: [String: [AgentSession]] {
        Dictionary(grouping: codexMonitor.agents, by: { $0.tmuxSession })
    }

    // FIX-U (2026-05-07): multi-agent로 운영 중인 윈도우만 표시
    // — sub-agent (paneIndex >= 1) 가 1개라도 있는 윈도우만
    // — 그 윈도우의 부모 + 모든 sub-agent 함께 표시
    // — sub-agent 없는 단순 윈도우는 모두 숨김
    private var activeAgents: [AgentSession] {
        // 윈도우 키별로 그룹화
        let byWindow = Dictionary(grouping: codexMonitor.agents, by: {
            "\($0.tmuxSession)|\($0.windowName)"
        })
        // sub-agent가 1개라도 있는 윈도우만 통과
        let multiAgentWindows = byWindow.filter { _, agents in
            agents.contains(where: { !$0.isParent })
        }
        return multiAgentWindows.values.flatMap { $0 }
    }
    private var activeAgentsByGroup: [String: [AgentSession]] {
        Dictionary(grouping: activeAgents, by: { $0.tmuxSession })
    }
    private var activeGroupNames: [String] {
        activeAgentsByGroup.keys.sorted()
    }

    private func displayGroupName(_ sn: String) -> String {
        if let group = monitor.windowGroupService.groups.first(where: { $0.sessionName == sn }) {
            return "\(group.name) (\(sn))"
        }
        return sn
    }
}

private struct AgentRow: View {
    let agent: AgentSession
    let isSelected: Bool
    let indentLevel: Int

    var body: some View {
        HStack(spacing: 8) {
            // FIX-S: sub-agent 들여쓰기 + 트리 라인
            if indentLevel > 0 {
                Spacer().frame(width: CGFloat(indentLevel) * 16)
                Text("└")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Circle().fill(statusColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if agent.isParent {
                        Image(systemName: "person.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.blue)
                    }
                    Text(displayName).font(.system(size: 12, weight: agent.isParent ? .semibold : .regular))
                    Spacer()
                    Text(agent.elapsedFormatted)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(agent.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }

    private var displayName: String {
        // FIX-S: 부모는 윈도우명, sub-agent는 agent-name (없으면 pane 번호)
        if agent.isParent { return agent.windowName }
        if let name = agent.agentName, !name.isEmpty { return name }
        return "pane \(agent.paneIndex)"
    }

    private var statusColor: Color {
        switch agent.status {
        case .running: return .green
        case .idle: return .gray
        case .completed: return .blue
        case .error: return .red
        }
    }
}

private struct AgentDetailView: View {
    let agent: AgentSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Circle().fill(statusColor).frame(width: 12, height: 12)
                    Text(agent.status.rawValue).font(.headline)
                    Spacer()
                }
                GroupBox("Identity") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Session", value: "\(agent.tmuxSession):\(agent.windowIndex).\(agent.paneIndex)")
                        LabeledContent("Pane ID", value: agent.id)
                        if let id = agent.agentId { LabeledContent("Agent ID", value: id) }
                        if let name = agent.agentName { LabeledContent("Agent Name", value: name) }
                        LabeledContent("PID", value: "\(agent.panePid)")
                        LabeledContent("TTY", value: agent.paneTty)
                        LabeledContent("Window", value: agent.windowName)
                        LabeledContent("Role", value: agent.isParent ? "Parent" : "Sub-agent")
                    }
                    .padding(4)
                }
                GroupBox("Timing") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Started", value: agent.startTime.formatted(date: .abbreviated, time: .standard))
                        if let end = agent.endTime {
                            LabeledContent("Ended", value: end.formatted(date: .abbreviated, time: .standard))
                        }
                        LabeledContent("Elapsed", value: agent.elapsedFormatted)
                    }
                    .padding(4)
                }
                GroupBox("Last Output") {
                    Text(agent.summary.isEmpty ? "(empty)" : agent.summary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                Spacer()
            }
            .padding()
        }
    }

    private var statusColor: Color {
        switch agent.status {
        case .running: return .green
        case .idle: return .gray
        case .completed: return .blue
        case .error: return .red
        }
    }
}
