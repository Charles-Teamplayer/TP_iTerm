import Foundation

struct SmugProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var root: String
    var delay: Int
    var enabled: Bool
}
