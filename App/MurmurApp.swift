import SwiftUI
import UIKit

@main
struct MurmurApp: App {
    @StateObject private var dictation = DictationController()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(dictation).tint(.teal) }
    }
}

struct ContentView: View {
    @EnvironmentObject var dictation: DictationController
    @AppStorage("saveHistory") private var saveHistory = true
    @AppStorage("allowNetwork") private var allowNetwork = false
    @AppStorage("speechLocale") private var speechLocale = "en-AU"
    @AppStorage("transcriptionProvider") private var provider = "groq"
    @State private var settings = false
    @State private var addClip = false
    @State private var clipText = ""
    @State private var search = ""
    @State private var feedback = ""

    var body: some View {
        TabView {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Your voice, in words.").font(.title2.weight(.semibold))
                        Text(dictation.message).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently)
                        VStack(spacing: 12) {
                            Button {
                                if dictation.phase == "recording" { dictation.stop() }
                                else { Task { await dictation.start(localeID: speechLocale, allowNetwork: allowNetwork) } }
                            } label: {
                                VStack(spacing: 10) {
                                    Image(systemName: dictation.phase == "recording" ? "stop.fill" : "mic.fill")
                                        .font(.system(size: 34))
                                    Text(recordingLabel).font(.headline)
                                }
                                .frame(maxWidth: .infinity).frame(minHeight: 116)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(["permission", "finishing", "processing"].contains(dictation.phase))
                            if dictation.busy {
                                Button("Cancel recording", role: .cancel) { dictation.cancel() }
                            }
                        }
                        if provider == "groq" {
                            VStack(alignment: .leading, spacing: 10) {
                                if dictation.sessionEnabled {
                                    Label("Microphone active · \(dictation.sessionRemaining)s left", systemImage: "mic.fill")
                                        .font(.callout).foregroundStyle(.orange)
                                    Button("End keyboard session", role: .destructive) { dictation.endKeyboardSession() }
                                } else {
                                    Button("Activate keyboard session") { Task { await dictation.activateKeyboardSession() } }
                                        .buttonStyle(.bordered).disabled(dictation.busy)
                                }
                                Text("Groq mode keeps the microphone active for up to five minutes so the keyboard can start each dictation. Idle audio is discarded. Only recordings you start are sent to Groq. End the session to turn the microphone off.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        if let error = dictation.error {
                            Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Transcript").font(.headline)
                            TextEditor(text: Binding(get: { dictation.text }, set: { dictation.text = $0; dictation.shareEdits() }))
                                .frame(minHeight: 180)
                                .padding(8)
                                .scrollContentBackground(.hidden)
                                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                                .disabled(dictation.busy)
                                .accessibilityLabel("Editable transcript")
                            HStack {
                                Button { copy(dictation.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                                Button { if dictation.save(dictation.text) { feedback = "Saved to Clips" } } label: {
                                    Label("Save", systemImage: "bookmark")
                                }.disabled(!dictation.storageReady)
                                ShareLink(item: dictation.text) { Image(systemName: "square.and.arrow.up") }
                                    .accessibilityLabel("Share transcript")
                            }
                            .buttonStyle(.bordered)
                            .disabled(dictation.busy || dictation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if !feedback.isEmpty { Text(feedback).font(.callout).foregroundStyle(.secondary) }
                        if let milliseconds = dictation.latencyMS {
                            Text(String(format: "Last transcription: %.1f seconds after Stop", Double(milliseconds) / 1000))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Activate a keyboard session here, switch to your messaging app, then choose Murmur with the globe key. Tap Record, speak after Listening appears, then Stop & Insert. Each dictation can last up to 55 seconds.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if !dictation.sharingAvailable {
                            Text("Keyboard sharing is unavailable with this installation. Copy and paste still work. Check the installation guide before testing the keyboard.")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    }.padding(20)
                }
                .navigationTitle("Murmur")
                .toolbar { Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings") }
            }
            .tabItem { Label("Dictate", systemImage: "mic") }

            NavigationStack {
                List {
                    if dictation.clips.isEmpty {
                        Text("Your saved words will appear here. Dictate something or add a clip.").foregroundStyle(.secondary)
                    }
                    ForEach(ClipRules.sorted(dictation.clips).filter {
                        search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)
                    }) { clip in
                        VStack(alignment: .leading, spacing: 10) {
                            if clip.pinned { Label("Pinned", systemImage: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                            Text(clip.text).textSelection(.enabled)
                            HStack {
                                Button("Copy") { copy(clip.text) }.buttonStyle(.borderless)
                                Button(clip.pinned ? "Unpin" : "Pin") { dictation.pin(clip) }.buttonStyle(.borderless)
                                Spacer()
                                Text(clip.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 6)
                        .swipeActions { Button("Delete", role: .destructive) { dictation.delete(clip) } }
                    }
                }
                .searchable(text: $search, prompt: "Find a clip")
                .navigationTitle("Clips")
                .toolbar { Button { addClip = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add clip") }
                .safeAreaInset(edge: .bottom) {
                    if !feedback.isEmpty { Text(feedback).font(.caption).padding(8).frame(maxWidth: .infinity).background(.regularMaterial) }
                }
            }
            .tabItem { Label("Clips", systemImage: "clipboard") }
        }
        .sheet(isPresented: $settings) { SettingsView().environmentObject(dictation) }
        .sheet(isPresented: $addClip) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Paste or type text you want to use again.").foregroundStyle(.secondary)
                    TextEditor(text: $clipText).accessibilityLabel("New clip text")
                    PasteButton(payloadType: String.self) { strings in clipText = strings.joined(separator: "\n") }
                    if let error = dictation.error { Text(error).foregroundStyle(.red).font(.footnote) }
                }.padding()
                .navigationTitle("New clip")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { addClip = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if dictation.save(clipText) { clipText = ""; addClip = false }
                        }
                            .disabled(clipText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !dictation.storageReady)
                    }
                }
            }
        }
        .onAppear { dictation.onFinished = { value in if saveHistory { dictation.save(value) } } }
    }

    private var recordingLabel: String {
        switch dictation.phase {
        case "recording": return "Stop · \(dictation.seconds)s"
        case "permission": return "Checking permissions…"
        case "finishing": return "Finishing…"
        case "processing": return "Transcribing…"
        default: return "Start dictation"
        }
    }
    private func copy(_ text: String) {
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: text]], options: [.localOnly: true])
        feedback = "Copied. Paste into your message."
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var dictation: DictationController
    @AppStorage("saveHistory") private var saveHistory = true
    @AppStorage("allowNetwork") private var allowNetwork = false
    @AppStorage("speechLocale") private var speechLocale = "en-AU"
    @AppStorage("transcriptionProvider") private var provider = "groq"
    @AppStorage("groqModel") private var groqModel = "whisper-large-v3-turbo"
    @AppStorage("personalVocabulary") private var vocabulary = "Vijit Pugalia"
    @State private var apiKey = ""
    @State private var keyStatus = ""
    @State private var confirmDelete = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Dictation") {
                    Picker("Recognition", selection: $provider) {
                        Text("Groq Whisper").tag("groq")
                        Text("Apple (in-app dictation)").tag("apple")
                    }
                    Picker("Language", selection: $speechLocale) {
                        Text("English (Australia)").tag("en-AU")
                        Text("English (India)").tag("en-IN")
                        Text("English (United States)").tag("en-US")
                        Text("English (United Kingdom)").tag("en-GB")
                        Text("Hindi").tag("hi-IN")
                    }
                    if provider == "groq" {
                        Picker("Model", selection: $groqModel) {
                            Text("Large V3 Turbo · faster").tag("whisper-large-v3-turbo")
                            Text("Large V3 · accuracy option").tag("whisper-large-v3")
                        }
                        SecureField("Groq API key", text: $apiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Save API key") {
                            do { try APIKeyStore.save(apiKey); apiKey = ""; keyStatus = "API key saved in Keychain." }
                            catch { keyStatus = error.localizedDescription }
                        }.disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Remove saved API key", role: .destructive) {
                            do { try APIKeyStore.delete(); keyStatus = "API key removed." }
                            catch { keyStatus = error.localizedDescription }
                        }
                        if !keyStatus.isEmpty { Text(keyStatus).font(.footnote) }
                        Text("Recordings are sent to Groq over the internet after you tap Stop. Your key stays in this app's Keychain, not in the keyboard. Your Groq account's usage limits and charges apply. There is no automatic provider fallback or AI rewriting.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Toggle("Allow Apple network recognition", isOn: $allowNetwork)
                        Text("Apple mode is for dictation inside Murmur. On-device recognition is preferred; enabling network recognition allows Apple to process speech when local recognition is unavailable.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.disabled(dictation.busy || dictation.sessionEnabled)
                Section("Personal vocabulary") {
                    TextEditor(text: $vocabulary).frame(minHeight: 90).accessibilityLabel("Names and vocabulary")
                    Text("One name or term per line. These spellings guide recognition; they are not automatic replacements. Keep the list short (up to 24 terms and 400 characters are sent).")
                        .font(.footnote).foregroundStyle(.secondary)
                }.disabled(dictation.busy || dictation.sessionEnabled)
                Section("Saved text") {
                    Toggle("Save completed dictations", isOn: $saveHistory)
                    Text("Keeps the latest 100 unpinned clips, plus your pinned clips. Turning this off affects future dictations; delete existing clips below. The latest transcript remains available for keyboard insertion until you clear it or start again.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Delete all clips and current transcript", role: .destructive) { confirmDelete = true }
                        .disabled(dictation.busy || dictation.sessionEnabled)
                }
                Section("Using the keyboard") {
                    Text("Install the single Murmur IPA through SideStore, keeping its extension. In iPhone Settings → General → Keyboard → Keyboards → Add New Keyboard, choose Murmur. Allow Full Access for its shared session and clips. The keyboard itself makes no network requests.")
                    Text("Choose Groq mode, save a key, then activate a session in Murmur. Switch apps and use Record / Stop & Insert in the keyboard. If iOS ends the session, return to Murmur to activate it again. Some apps do not permit third-party keyboards.")
                }.font(.footnote)
                Section("About") {
                    Text("Murmur · 0.2.0 test build")
                    Text("Made by Vijit Pugalia").foregroundStyle(.secondary)
                    Text("Groq recordings use temporary audio files, removed after completion, failure, or cancellation. Abandoned temporary files are cleared on next launch. Idle audio is discarded. Clips may be included in device backups. Murmur does not monitor your clipboard.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
            .onAppear {
                do { keyStatus = try APIKeyStore.load().isEmpty ? "No API key saved." : "A Groq API key is saved." }
                catch { keyStatus = error.localizedDescription }
            }
            .confirmationDialog("Delete all saved clips and the current transcript?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { dictation.deleteAll() }
            }
        }
    }
}
