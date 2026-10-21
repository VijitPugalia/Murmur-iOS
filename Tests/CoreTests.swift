import Foundation

@main
struct CoreTests {
    static func main() throws {
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
        print("\(passed) tests passed, 0 failures")
    }
}
