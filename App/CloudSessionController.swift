import AVFoundation
import Foundation

@MainActor
final class CloudSessionController {
    private let capture = SegmentCapture()
    private let store: ClipStore?
    private var timer: Timer?
    private var operation: Task<Void, Never>?
    private var activationID = UUID()
    private var key = ""
    private var model = "whisper-large-v3-turbo"
    private var language = "en"
    private var vocabulary = ""
    private var startedAt = Date()
    private var stopTime = Date()
    private var snapshot = RecordingSnapshot(id: UUID(), phase: "idle", text: "")
    var onUpdate: ((RecordingSnapshot, Int) -> Void)?
    var onResult: ((String) -> Void)?
    var active: Bool { snapshot.sessionToken != nil }

    init(store: ClipStore?) { self.store = store; SegmentCapture.cleanAbandonedFiles() }

    func activate(key: String, model: String, language: String, vocabulary: String) async throws {
        guard !active else { return }
        guard !key.isEmpty else { throw TranscriptionFailure.message("Add your Groq API key in Settings first.") }
        let activation = UUID(); activationID = activation
        let granted = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard activationID == activation else { throw CancellationError() }
        guard granted else { throw TranscriptionFailure.message("Allow Murmur to use the microphone in iPhone Settings.") }
        do { try capture.activate() } catch { capture.deactivate(); throw error }
        self.key = key; self.model = model; self.language = language; self.vocabulary = vocabulary
        snapshot = RecordingSnapshot(id: UUID(), phase: "idle", text: "",
            sessionToken: UUID(), sessionExpiresAt: Date().addingTimeInterval(300),
            message: "Keyboard session active. Switch apps and tap Record in Murmur's keyboard.")
        emit()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func start() {
        guard active, ["idle", "ready", "error"].contains(snapshot.phase) else { return }
        guard let expiry = snapshot.sessionExpiresAt, expiry.timeIntervalSinceNow > 5 else {
            end(message: "Session ended. Open Murmur to activate another session."); return
        }
        do {
            try capture.begin()
            snapshot.id = UUID(); snapshot.phase = "recording"; snapshot.text = ""; snapshot.latencyMS = nil
            snapshot.message = "Listening. Tap Stop when finished."
            startedAt = Date(); emit()
        } catch { fail(error.localizedDescription) }
    }

    func stop() {
        guard snapshot.phase == "recording" else { return }
        snapshot.phase = "finishing"; snapshot.message = "Finishing audio…"; stopTime = Date()
        let id = snapshot.id
        emit()
        operation = Task { [weak self] in
            // Capture a small tail after the stop tap so the final phoneme is not cut off.
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard let self, self.snapshot.id == id, self.active else { return }
            do {
                let recording = try self.capture.finish()
                defer { try? FileManager.default.removeItem(at: recording.url) }
                guard recording.duration >= 0.25, recording.peak > 0.0005 else {
                    throw TranscriptionFailure.message("No usable speech captured. Tap Record and speak after Listening appears.")
                }
                self.snapshot.phase = "processing"; self.snapshot.message = "Transcribing with Groq…"; self.emit()
                let audio = try Data(contentsOf: recording.url)
                let result = try await GroqTranscriber().transcribe(audio: audio, key: self.key,
                    model: self.model, language: self.language, vocabulary: self.vocabulary)
                guard self.snapshot.id == id, self.active, !Task.isCancelled else { return }
                self.snapshot.text = result; self.snapshot.phase = "ready"
                self.snapshot.latencyMS = Int(Date().timeIntervalSince(self.stopTime) * 1000)
                self.snapshot.message = "Ready to insert."
                self.emit(); self.onResult?(result)
            } catch {
                guard self.snapshot.id == id, !Task.isCancelled else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    func cancel() {
        operation?.cancel(); operation = nil
        capture.discard()
        snapshot.id = UUID(); snapshot.phase = "idle"; snapshot.text = ""; snapshot.latencyMS = nil
        snapshot.message = "Cancelled. Tap Record to try again."
        emit()
    }

    func end(message: String = "Keyboard session ended. Microphone off.") {
        activationID = UUID()
        operation?.cancel(); operation = nil
        timer?.invalidate(); timer = nil
        capture.deactivate(); key = ""
        let completed = snapshot.phase == "ready"
        snapshot.id = UUID(); snapshot.sessionToken = nil; snapshot.sessionExpiresAt = nil
        snapshot.phase = completed ? "ready" : "idle"
        if !completed { snapshot.text = "" }
        snapshot.message = message
        emit()
    }

    func edit(_ text: String) {
        guard ["idle", "ready", "error"].contains(snapshot.phase) else { return }
        snapshot.id = UUID(); snapshot.text = text
        snapshot.phase = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "idle" : "ready"
        emit()
    }

    private func tick() {
        guard active else { return }
        guard capture.isRunning else { end(message: "Microphone session interrupted. Open Murmur to reactivate it."); return }
        guard let expiry = snapshot.sessionExpiresAt, expiry > Date() else {
            end(message: "Five-minute session expired. Unfinished dictation cancelled; microphone off."); return
        }
        if snapshot.phase == "recording", Date().timeIntervalSince(startedAt) >= 55 { stop() }
        if let command = try? store?.command(), SessionRules.accepts(command, snapshot: snapshot) {
            snapshot.lastCommandID = command.id
            switch command.action {
            case .start: start()
            case .stop: stop()
            case .cancel: cancel()
            case .end: end()
            }
        }
        emit()
    }

    private func fail(_ reason: String) {
        capture.discard()
        snapshot.phase = "error"; snapshot.text = ""; snapshot.message = reason; snapshot.latencyMS = nil
        emit()
    }

    private func emit() {
        snapshot.updatedAt = Date()
        do { try store?.saveSnapshot(snapshot) }
        catch {
            // Do not keep a microphone session alive when its keyboard control channel fails.
            timer?.invalidate(); timer = nil; operation?.cancel(); capture.deactivate(); key = ""
            snapshot.sessionToken = nil; snapshot.sessionExpiresAt = nil
            snapshot.phase = "error"; snapshot.message = "Shared storage failed. Microphone stopped. \(error.localizedDescription)"
        }
        let seconds = snapshot.phase == "recording" ? Int(Date().timeIntervalSince(startedAt)) : 0
        onUpdate?(snapshot, seconds)
    }
}
