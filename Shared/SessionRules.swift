import Foundation

enum SessionAction: String, Codable { case start, stop, cancel, end }
struct KeyboardCommand: Codable {
    var id = UUID()
    var sessionToken: UUID
    var utteranceID: UUID
    var action: SessionAction
    var createdAt = Date()
}

enum SessionRules {
    static func isLive(_ snapshot: RecordingSnapshot, now: Date = Date()) -> Bool {
        guard snapshot.sessionToken != nil, let expiry = snapshot.sessionExpiresAt else { return false }
        let age = now.timeIntervalSince(snapshot.updatedAt)
        return expiry > now && age >= -1 && age < 4
    }
    static func accepts(_ command: KeyboardCommand, snapshot: RecordingSnapshot, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(command.createdAt)
        guard isLive(snapshot, now: now), age >= -1, age < 4,
              command.sessionToken == snapshot.sessionToken,
              command.id != snapshot.lastCommandID,
              command.utteranceID == snapshot.id else { return false }
        switch command.action {
        case .start: return ["idle", "ready", "error"].contains(snapshot.phase)
        case .stop: return snapshot.phase == "recording"
        case .cancel: return ["recording", "finishing", "processing"].contains(snapshot.phase)
        case .end: return true
        }
    }
}
