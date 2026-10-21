import Foundation

@main
struct CoreTests {
    static func main() async throws {
        var passed = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            guard value() else { fatalError("FAIL: \(name)") }
            passed += 1
            print("PASS: \(name)")
        }
        check(ClipRules.adding("  \n ", to: []).isEmpty, "Reject empty clips")
        let first = ClipRules.adding("  hello  ", to: [])
        check(first.count == 1 && first[0].text == "hello", "Trim saved text")
        let repeated = ClipRules.adding("hello", to: first)
        check(repeated.count == 1 && repeated[0].id == first[0].id, "Saving twice preserves identity")
        let pinned = Clip(text: "keep me", createdAt: .distantPast, pinned: true)
        var clips = [pinned]
        for number in 0..<105 { clips = ClipRules.adding("clip \(number)", to: clips) }
        check(clips.count == 101, "Cap unpinned history at 100")
        check(clips.contains(pinned), "Never evict pinned clips")
        check(ClipRules.sorted(clips).first?.id == pinned.id, "Pinned clips sort first")
        check(!clips.contains { $0.text == "clip 0" }, "Evict oldest unpinned clip")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipStore(directory: directory)
        let empty = try store.loadClips()
        check(empty.isEmpty, "Missing storage is empty")
        try store.saveClips(clips)
        let loaded = try store.loadClips()
        check(loaded == clips, "Persist clips including IDs and pin state")
        let id = UUID()
        try store.requestStop(id)
        check(store.stopRequested(for: id), "Stop request reaches matching session")
        check(!store.stopRequested(for: UUID()), "Ignore stale stop request")
        try store.saveSnapshot(RecordingSnapshot(id: id, phase: "ready", text: "नमस्ते 👋"))
        let snapshot = try store.snapshot()
        check(snapshot?.text == "नमस्ते 👋", "Unicode transcript round trip")
        try store.clearSnapshot()
        let cleared = try store.snapshot()
        check(cleared == nil, "Clear temporary transcript")
        try Data("broken".utf8).write(to: directory.appendingPathComponent("clips.json"))
        do { _ = try store.loadClips(); fatalError("Corruption silently ignored") }
        catch { passed += 1; print("PASS: Corruption is surfaced instead of overwritten") }
        let now = Date()
        let token = UUID()
        var live = RecordingSnapshot(id: UUID(), phase: "idle", text: "", updatedAt: now,
            sessionToken: token, sessionExpiresAt: now.addingTimeInterval(300))
        var command = KeyboardCommand(sessionToken: token, utteranceID: live.id, action: .start, createdAt: now)
        check(SessionRules.accepts(command, snapshot: live, now: now), "Accept start in live idle session")
        command.sessionToken = UUID()
        check(!SessionRules.accepts(command, snapshot: live, now: now), "Reject another session's command")
        command.sessionToken = token; command.createdAt = now.addingTimeInterval(-5)
        check(!SessionRules.accepts(command, snapshot: live, now: now), "Reject delayed command")
        command.createdAt = now; live.lastCommandID = command.id
        check(!SessionRules.accepts(command, snapshot: live, now: now), "Reject replayed command")
        live.lastCommandID = nil; live.phase = "processing"
        check(!SessionRules.accepts(command, snapshot: live, now: now), "Cannot start while processing")
        command.action = .cancel
        check(SessionRules.accepts(command, snapshot: live, now: now), "Can cancel processing")
        command.utteranceID = UUID()
        check(!SessionRules.accepts(command, snapshot: live, now: now), "Reject cancellation of a different utterance")
        command.utteranceID = live.id; command.action = .stop; live.phase = "recording"
        check(SessionRules.accepts(command, snapshot: live, now: now), "Can stop a matching recording")
        live.updatedAt = now.addingTimeInterval(-6)
        check(!SessionRules.accepts(command, snapshot: live, now: now), "Reject stale app heartbeat")
        live.updatedAt = now; live.sessionExpiresAt = now
        check(!SessionRules.accepts(command, snapshot: live, now: now), "Reject expired microphone session")
        let profile = try PropertyListSerialization.data(fromPropertyList: ["Entitlements": [
            "com.apple.security.application-groups": [ClipStore.groupID + ".TEAM", "group.other", ClipStore.groupID + "wrong"]]], format: .xml, options: 0)
        check(AppGroupResolver.groups(in: profile, base: ClipStore.groupID) == [ClipStore.groupID + ".TEAM"], "Resolve re-signed App Group suffix without selecting unrelated groups")
        check(AppGroupResolver.groups(in: Data("invalid".utf8), base: ClipStore.groupID).isEmpty, "Ignore malformed provisioning data")
        let request = try GroqTranscriber.request(audio: Data([0, 1, 255, 4]), key: "test-key", model: "whisper-large-v3-turbo", language: "en", vocabulary: "Vijit Pugalia\nMurmur", boundary: "test-boundary")
        check(request.url?.path == "/openai/v1/audio/transcriptions", "Use transcription, not translation endpoint")
        check(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "Send explicit API credential")
        let body = request.httpBody!
        check(body.range(of: Data([0, 1, 255, 4])) != nil, "Multipart preserves binary audio")
        check(body.range(of: Data("Vijit Pugalia, Murmur".utf8)) != nil, "Vocabulary supplied as context")
        check(body.suffix(Data("--test-boundary--\r\n".utf8).count) == Data("--test-boundary--\r\n".utf8), "Multipart has final boundary")
        check(GroqTranscriber.vocabulary(String(repeating: "term\n", count: 1000)).count <= 400, "Bound vocabulary size")
        do {
            _ = try GroqTranscriber.request(audio: Data([1]), key: " ", model: "whisper-large-v3", language: "en", vocabulary: "")
            fatalError("Missing key accepted")
        } catch { passed += 1; print("PASS: Reject missing key before network") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGroqProtocol.self]
        let network = URLSession(configuration: configuration)
        defer { network.invalidateAndCancel() }
        let client = GroqTranscriber(session: network)
        MockGroqProtocol.reply = (200, Data(#"{"text":"My name is Vijit Pugalia, and Ajit is my colleague."}"#.utf8))
        let transcript = try await client.transcribe(audio: Data([1]), key: "test-key", model: "whisper-large-v3-turbo", language: "en", vocabulary: "Vijit Pugalia")
        check(transcript == "My name is Vijit Pugalia, and Ajit is my colleague.", "Preserve provider words without hard-coded name replacement")
        for (status, payload) in [(401, "{}"), (429, "{}"), (500, "{}"), (200, "not-json"), (200, #"{"text":" "}"#)] {
            MockGroqProtocol.reply = (status, Data(payload.utf8))
            do {
                _ = try await client.transcribe(audio: Data([1]), key: "test-key", model: "whisper-large-v3", language: "en", vocabulary: "")
                fatalError("Invalid response accepted")
            } catch { passed += 1; print("PASS: Reject HTTP \(status) / invalid result without fallback") }
        }
        MockGroqProtocol.hold = true
        let pending = Task { try await client.transcribe(audio: Data([1]), key: "test-key", model: "whisper-large-v3", language: "en", vocabulary: "") }
        try await Task.sleep(nanoseconds: 100_000_000)
        pending.cancel()
        do { _ = try await pending.value; fatalError("Cancelled upload returned text") }
        catch { passed += 1; print("PASS: Cancellation does not return a late transcript") }
        print("\(passed) tests passed, 0 failures")
    }
}

final class MockGroqProtocol: URLProtocol {
    static var reply = (200, Data())
    static var hold = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.hold { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.reply.0, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.reply.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
