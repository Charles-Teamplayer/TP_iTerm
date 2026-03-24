import Foundation
import UniformTypeIdentifiers
import SwiftUI

struct WindowPane: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String           // UI 표시명 (e.g. "메인", "IMSMS")
    var sessionName: String    // tmux 세션명 (e.g. "claude-work", "claude-imsms")
    var profileNames: [String] // SmugProfile.name 순서대로
}

// 드래그앤드롭 전용 전송 타입
struct SessionDragItem: Codable, Transferable {
    let profileName: String
    let sourcePaneId: String   // UUID string, 빈 문자열이면 미배정

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(for: SessionDragItem.self, contentType: .sessionDragItem)
    }
}

extension UTType {
    static let sessionDragItem = UTType(exportedAs: "com.teample.tp-iterm.session-drag")
}
