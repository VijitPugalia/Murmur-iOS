import Foundation

struct Clip: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var text: String
    var createdAt: Date = Date()
    var pinned: Bool = false
}

struct RecordingSnapshot: Codable {
    var id: UUID
    var phase: String
    var text: String
    var updatedAt: Date = Date()
    var sessionToken: UUID?
    var sessionExpiresAt: Date?
    var message: String?
    var lastCommandID: UUID?
    var latencyMS: Int?
}

struct StopRequest: Codable {
    var sessionID: UUID
}

enum ClipRules {
    static func adding(_ text: String, to clips: [Clip], limit: Int = 100) -> [Clip] {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return clips }
        var result = clips
        // Do not duplicate a clip when the user saves the same transcript twice.
        if let existing = result.firstIndex(where: { $0.text == value }) {
            result[existing].createdAt = Date()
        } else {
            result.append(Clip(text: value))
        }
        let pinned = result.filter(\.pinned)
        let recent = result.filter { !$0.pinned }.sorted { $0.createdAt > $1.createdAt }
        return pinned + Array(recent.prefix(max(0, limit)))
    }

    static func sorted(_ clips: [Clip]) -> [Clip] {
        clips.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.createdAt > $1.createdAt
        }
    }
}

struct ClipStore {
    static let groupID = "group.com.vijitpugalia.murmur.ios"
    let directory: URL

    static var sharedDirectory: URL? {
        AppGroupResolver.directory(base: groupID)
    }

    static func appStore() throws -> ClipStore {
        let base = try sharedDirectory ?? FileManager.default.url(for: .applicationSupportDirectory,
                                  in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("Murmur", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ClipStore(directory: directory)
    }

    static func keyboardStore() -> ClipStore? {
        guard let base = sharedDirectory else { return nil }
        return ClipStore(directory: base.appendingPathComponent("Murmur", isDirectory: true))
    }

    func loadClips() throws -> [Clip] { try read([Clip].self, name: "clips.json") ?? [] }
    func saveClips(_ clips: [Clip]) throws { try write(clips, name: "clips.json") }
    func snapshot() throws -> RecordingSnapshot? { try read(RecordingSnapshot.self, name: "session.json") }
    func saveSnapshot(_ snapshot: RecordingSnapshot) throws { try write(snapshot, name: "session.json") }
    func requestStop(_ id: UUID) throws { try write(StopRequest(sessionID: id), name: "stop.json") }
    func command() throws -> KeyboardCommand? { try read(KeyboardCommand.self, name: "command.json") }
    func send(_ command: KeyboardCommand) throws { try write(command, name: "command.json") }
    func stopRequested(for id: UUID) -> Bool {
        (try? read(StopRequest.self, name: "stop.json"))?.sessionID == id
    }
    func clearSnapshot() throws {
        let url = directory.appendingPathComponent("session.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private func read<T: Decodable>(_ type: T.Type, name: String) throws -> T? {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    private func write<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        #if os(iOS)
        try data.write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUnlessOpen])
        #else
        try data.write(to: directory.appendingPathComponent(name), options: [.atomic])
        #endif
    }
}
