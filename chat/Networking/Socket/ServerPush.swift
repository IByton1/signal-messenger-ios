import Foundation

struct ServerPush: Decodable {
    let type: String?
    let roomId: String
    let peer: String?
    let payload: String?
    let timestamp: TimeInterval?
}
