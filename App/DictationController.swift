import AVFoundation
import Speech
import SwiftUI

@MainActor
final class DictationController: ObservableObject {
    @Published var text = ""
    @Published var phase = "idle"
    @Published var message = "Tap the microphone to start."
    @Published var error: String?
    @Published var seconds = 0
    @Published var clips: [Clip] = []
    @Published var storageReady = false
    @Published var localRecognition = false
    @Published var sessionEnabled = false
    @Published var sessionRemaining = 0
    @Published var latencyMS: Int?
    private var cloud: CloudSessionController!
    var onFinished: ((String) -> Void)?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timer: Timer?
    private var finalizationTask: Task<Void, Never>?
    private var sessionID = UUID()
    private var startedAt = Date()
    private var tapInstalled = false
    private var store: ClipStore?
    private var observers: [NSObjectProtocol] = []
    var busy: Bool { ["permission", "recording", "finishing", "processing"].contains(phase) }
    var sharingAvailable: Bool {
        return ClipStore.sharedDirectory != nil
    }

    init() {
        do {
            store = try ClipStore.appStore()
            clips = try store!.loadClips()
            storageReady = true
            try store!.clearSnapshot()
        } catch { self.error = "Could not open saved clips: \(error.localizedDescription)" }
        cloud = CloudSessionController(store: store)
        cloud.onUpdate = { [weak self] snapshot, seconds in
            guard let self else { return }
            self.phase = snapshot.phase; self.text = snapshot.text; self.seconds = seconds
            self.sessionEnabled = snapshot.sessionToken != nil
            self.sessionRemaining = max(0, Int(snapshot.sessionExpiresAt?.timeIntervalSinceNow ?? 0))
            self.message = snapshot.message ?? ""
            self.latencyMS = snapshot.latencyMS
            self.error = snapshot.phase == "error" ? snapshot.message : nil
        }
        cloud.onResult = { [weak self] text in self?.onFinished?(text) }
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                object: nil, queue: .main) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in
                guard let self else { return }
                if self.cloud.active { self.cloud.end(message: "Microphone interrupted. Unfinished dictation cancelled. Activate a new session.") }
                else { self.stop(reason: "Recording interrupted. Review the captured text.") }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                object: nil, queue: .main) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor in
                guard let self else { return }
                if self.cloud.active { self.cloud.end(message: "Microphone disconnected. Activate a new session.") }
                else { self.stop(reason: "Microphone disconnected. Review the captured text.") }
            }
        })
    }

    func start(localeID: String, allowNetwork: Bool) async {
        guard !busy else { return }
        if (UserDefaults.standard.string(forKey: "transcriptionProvider") ?? "groq") == "groq" {
            if !cloud.active {
                let activated = await activateKeyboardSession(requireSharing: false)
                guard activated else { return }
            }
            if cloud.active { cloud.start() }
            return
        }
        error = nil
        phase = "permission"
        let id = UUID()
        sessionID = id
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        let microphone = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard sessionID == id, phase == "permission" else { return }
        guard speechStatus == .authorized, microphone else {
            fail("Allow Microphone and Speech Recognition for Murmur in iPhone Settings.")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)), recognizer.isAvailable else {
            fail("Speech recognition is unavailable for this language right now. Check the language and try again.")
            return
        }
        localRecognition = recognizer.supportsOnDeviceRecognition
        guard localRecognition || allowNetwork else {
            fail("On-device recognition is unavailable for this language. Choose another language or enable Apple network recognition in Settings.")
            return
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement, options: [.allowBluetooth])
            try audio.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw NSError(domain: "Murmur", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input is available."])
            }
            let bufferRequest = SFSpeechAudioBufferRecognitionRequest()
            bufferRequest.shouldReportPartialResults = true
            bufferRequest.requiresOnDeviceRecognition = localRecognition
            bufferRequest.addsPunctuation = true
            bufferRequest.contextualStrings = GroqTranscriber.vocabulary(
                UserDefaults.standard.string(forKey: "personalVocabulary") ?? "Vijit Pugalia")
                .components(separatedBy: ", ")
            request = bufferRequest
            text = ""
            seconds = 0
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                bufferRequest.append(buffer)
            }
            tapInstalled = true
            task = recognizer.recognitionTask(with: bufferRequest) { [weak self] result, failure in
                // Keep speech callbacks off observable state until on the main actor.
                let transcript = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                let failureMessage = failure?.localizedDescription
                Task { @MainActor in
                    guard let self, self.sessionID == id,
                          ["recording", "finishing"].contains(self.phase) else { return }
                    if let transcript { self.text = transcript; self.publish() }
                    if final { self.finish() }
                    else if let failureMessage {
                        self.error = "Recognition stopped: \(failureMessage). Review any text captured below."
                        self.finish()
                    }
                }
            }
            engine.prepare()
            try engine.start()
            phase = "recording"
            message = localRecognition ? "Listening on this iPhone" : "Listening with Apple network recognition"
            startedAt = Date()
            publish()
            timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.phase == "recording" else { return }
                    self.seconds = Int(Date().timeIntervalSince(self.startedAt))
                    if self.seconds >= 55 { self.stop(reason: "Reached the 55-second test limit. Start again for more.") }
                    else if self.store?.stopRequested(for: id) == true { self.stop() }
                    else { self.publish() }
                }
            }
        } catch { fail(error.localizedDescription) }
    }

    func stop(reason: String? = nil) {
        if cloud.active { cloud.stop(); return }
        guard phase == "recording" else { return }
        phase = "finishing"
        message = reason ?? "Finishing your transcript…"
        stopAudio()
        request?.endAudio()
        publish()
        let id = sessionID
        finalizationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self, self.sessionID == id, self.phase == "finishing" else { return }
            self.error = "Apple did not return a final transcript within 10 seconds. The text below may be incomplete."
            self.finish()
        }
    }

    func cancel() {
        if cloud.active || phase == "permission" {
            if cloud.active { cloud.cancel(); return }
            cloud.end()
        }
        sessionID = UUID()
        stopAudio()
        task?.cancel(); task = nil; request = nil
        finalizationTask?.cancel()
        text = ""; phase = "idle"; message = "Recording cancelled."
        publish()
    }

    private func finish() {
        guard ["recording", "finishing"].contains(phase) else { return }
        stopAudio()
        finalizationTask?.cancel()
        task?.cancel(); task = nil; request = nil
        phase = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "idle" : "ready"
        if phase == "idle" { message = "No speech detected. Try speaking closer to the microphone." }
        else if !message.contains("limit") && !message.contains("interrupted") && !message.contains("disconnected") {
            message = "Ready. Review, copy, or save your text."
        }
        publish()
        if phase == "ready" { onFinished?(text) }
    }

    private func stopAudio() {
        timer?.invalidate(); timer = nil
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func fail(_ message: String) {
        stopAudio()
        task?.cancel(); task = nil; request = nil
        phase = "idle"; error = message
        self.message = "Could not start dictation."
        publish()
    }

    private func publish() {
        guard let store else { return }
        do { try store.saveSnapshot(RecordingSnapshot(id: sessionID, phase: phase, text: text)) }
        catch { self.error = "Could not share the transcript with the keyboard: \(error.localizedDescription)" }
    }

    func shareEdits() {
        guard !busy else { return }
        if cloud.active { cloud.edit(text); return }
        sessionID = UUID()
        phase = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "idle" : "ready"
        publish()
    }

    @discardableResult
    func activateKeyboardSession(requireSharing: Bool = true) async -> Bool {
        guard !busy, !cloud.active else { return false }
        if requireSharing && !sharingAvailable {
            error = "Keyboard sharing is unavailable. Install through SideStore with the extension and App Group retained."; return false
        }
        phase = "permission"; error = nil
        let activation = UUID(); sessionID = activation
        do {
            let defaults = UserDefaults.standard
            let locale = defaults.string(forKey: "speechLocale") ?? "en-AU"
            try await cloud.activate(key: APIKeyStore.load(),
                model: defaults.string(forKey: "groqModel") ?? "whisper-large-v3-turbo",
                language: locale.hasPrefix("hi") ? "hi" : "en",
                vocabulary: defaults.string(forKey: "personalVocabulary") ?? "Vijit Pugalia")
            return sessionID == activation && cloud.active
        } catch {
            guard sessionID == activation else { return false }
            phase = "idle"
            if !(error is CancellationError) { self.error = error.localizedDescription }
            return false
        }
    }

    func endKeyboardSession() { cloud.end() }

    @discardableResult
    func save(_ value: String) -> Bool {
        updateClips(ClipRules.adding(value, to: clips))
    }
    func delete(_ clip: Clip) { _ = updateClips(clips.filter { $0.id != clip.id }) }
    func pin(_ clip: Clip) {
        var updated = clips
        if let index = updated.firstIndex(where: { $0.id == clip.id }) { updated[index].pinned.toggle() }
        _ = updateClips(updated)
    }
    func deleteAll() {
        guard updateClips([]) else { return }
        text = ""
        do { try store?.clearSnapshot() } catch { self.error = error.localizedDescription }
    }
    private func updateClips(_ updated: [Clip]) -> Bool {
        guard storageReady, let store else { error = "Clip storage is unavailable. Copy your text to keep it."; return false }
        do { try store.saveClips(updated); clips = ClipRules.sorted(updated); return true }
        catch { self.error = "Could not save clips: \(error.localizedDescription)"; return false }
    }
}
