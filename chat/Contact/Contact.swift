import Foundation
import ExyteChat

struct Contact: Identifiable, Codable {
    var id: String
    var name: String
    var user: User
    var isLinked: Bool = false
}

