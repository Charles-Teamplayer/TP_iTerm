import SwiftUI

struct ContentView: View {
    @StateObject private var monitor = SessionMonitor()
    @State private var selectedSidebar: SidebarItem? = .sessions

    enum SidebarItem: String, CaseIterable, Identifiable {
        case sessions = "세션"
        case profiles = "Smug 프로필"
        case backup = "백업"
        case system = "시스템"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .sessions: return "terminal"
            case .profiles: return "rectangle.3.group"
            case .backup: return "externaldrive"
            case .system: return "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selectedSidebar) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationTitle("MAGI Restore")
        } detail: {
            switch selectedSidebar {
            case .sessions:
                SessionsView(monitor: monitor)
                    .navigationTitle("Claude 세션")
            case .profiles:
                ProfilesView()
                    .navigationTitle("Smug 프로필")
            case .backup:
                BackupView()
                    .navigationTitle("백업")
            case .system:
                SystemView()
                    .navigationTitle("시스템")
            case nil:
                EmptyStateView(title: "항목을 선택하세요", systemImage: "sidebar.left")
            }
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
