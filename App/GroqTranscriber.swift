import Foundation

enum TranscriptionFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

struct GroqTranscriber {
    static let models = ["whisper-large-v3-turbo", "whisper-large-v3"]
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    static func vocabulary(_ text: String) -> String {
        // Keep context short; do not insert it into the transcript or rewrite recognised names.
        let words = text.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return String(words.prefix(24).joined(separator: ", ").prefix(400))
    }

    static func request(audio: Data, key: String, model: String, language: String, vocabulary: String,
                        boundary: String = "Murmur-" + UUID().uuidString) throws -> URLRequest {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionFailure.message("Add your Groq API key in Settings.")
        }
        guard models.contains(model) else { throw TranscriptionFailure.message("Choose a supported transcription model.") }
        guard !audio.isEmpty, audio.count < 25_000_000 else {
            throw TranscriptionFailure.message("Recording is empty or too large. Try a shorter dictation.")
        }
        var body = Data()
        func append(_ value: String) { body.append(Data(value.utf8)) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("model", model); field("response_format", "json"); field("temperature", "0")
        if !language.isEmpty { field("language", language) }
        let prompt = Self.vocabulary(vocabulary)
        if !prompt.isEmpty { field("prompt", prompt) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(audio); append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    func transcribe(audio: Data, key: String, model: String, language: String, vocabulary: String) async throws -> String {
        let request = try Self.request(audio: audio, key: key, model: model, language: language, vocabulary: vocabulary)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else {
            throw TranscriptionFailure.message("Groq returned an invalid response.")
        }
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw TranscriptionFailure.message("Groq rejected the API key or model access. Check Settings.")
        case 429: throw TranscriptionFailure.message("Groq's usage limit was reached. Wait and try again. Nothing was inserted.")
        default: throw TranscriptionFailure.message("Transcription failed (HTTP \(response.statusCode)). Try again. Nothing was inserted.")
        }
        struct Result: Decodable { let text: String }
        guard let result = try? JSONDecoder().decode(Result.self, from: data) else {
            throw TranscriptionFailure.message("Groq returned an unreadable transcript.")
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionFailure.message("No speech was recognised. Try again closer to the microphone.") }
        return text
    }
}
