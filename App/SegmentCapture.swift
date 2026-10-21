import AVFoundation

/// The microphone remains explicitly active during a keyboard session. Idle buffers are discarded.
final class SegmentCapture {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var capturedFrames: Int64 = 0
    private var peak: Float = 0
    private var writeFailure: Error?
    private var installed = false
    static var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("MurmurAudio", isDirectory: true) }

    static func cleanAbandonedFiles() {
        // Only Murmur-created temporary WAV files, never arbitrary user recordings.
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if url.pathExtension == "wav" { try? FileManager.default.removeItem(at: url) }
        }
    }

    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetooth])
        try session.setActive(true)
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw TranscriptionFailure.message("No usable microphone input. Check your microphone and try again.")
        }
        outputFormat = target
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        installed = true
        engine.prepare()
        try engine.start()
    }

    func begin() throws {
        lock.lock(); defer { lock.unlock() }
        guard engine.isRunning, let target = outputFormat else {
            throw TranscriptionFailure.message("Microphone session ended. Open Murmur and activate it again.")
        }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let url = Self.directory.appendingPathComponent(UUID().uuidString + ".wav")
        do {
            file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
            ], commonFormat: target.commonFormat, interleaved: false)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: url.path)
            fileURL = url
            capturedFrames = 0; peak = 0; writeFailure = nil
            converter?.reset()
        } catch {
            file = nil; try? FileManager.default.removeItem(at: url); throw error
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let file, writeFailure == nil, let converter, let target = outputFormat else { return }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        if let conversionError { writeFailure = conversionError; return }
        do {
            if converted.frameLength > 0 {
                try file.write(from: converted)
                capturedFrames += Int64(converted.frameLength)
                if let samples = converted.floatChannelData?[0] {
                    for index in 0..<Int(converted.frameLength) { peak = max(peak, abs(samples[index])) }
                }
            }
        } catch { writeFailure = error }
    }

    func finish() throws -> (url: URL, duration: Double, peak: Float) {
        lock.lock(); defer { lock.unlock() }
        guard let url = fileURL else { throw TranscriptionFailure.message("No recording was captured.") }
        // Flush resampler delay before closing the WAV header; never truncate a pending buffer.
        if let file, let converter, let target = outputFormat,
           let tail = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 1024) {
            var error: NSError?
            converter.convert(to: tail, error: &error) { _, status in status.pointee = .endOfStream; return nil }
            if let error { writeFailure = error }
            if tail.frameLength > 0 {
                do { try file.write(from: tail); capturedFrames += Int64(tail.frameLength) }
                catch { writeFailure = error }
            }
        }
        file = nil; fileURL = nil
        if let writeFailure { try? FileManager.default.removeItem(at: url); throw writeFailure }
        return (url, Double(capturedFrames) / 16_000, peak)
    }

    func discard() {
        lock.lock()
        file = nil
        let url = fileURL; fileURL = nil
        lock.unlock()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    func deactivate() {
        engine.stop()
        if installed { engine.inputNode.removeTap(onBus: 0); installed = false }
        discard()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    var isRunning: Bool { engine.isRunning }
}
