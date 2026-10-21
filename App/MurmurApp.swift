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
                            .disabled(dictation.phase == "permission" || dictation.phase == "finishing")
                            if dictation.busy {
                                Button("Cancel recording", role: .cancel) { dictation.cancel() }
                            }
                        }
                        if let error = dictation.error {
                            Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Transcript").font(.headline)
                            TextEditor(text: $dictation.text)
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
                        #if STANDALONE
                        Text("LiveContainer test: dictate here, tap Copy, then paste in your messaging app. The keyboard is available in the separate SideStore build.")
                            .font(.footnote).foregroundStyle(.secondary)
                        #else
                        Text("To dictate into another app: start here, switch apps, then choose the Murmur keyboard. Tap Stop there, then Insert. Recordings stop after 55 seconds in this test build.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if !dictation.sharingAvailable {
                            Text("Keyboard sharing is unavailable with this installation. Copy and paste still work. Check the installation guide before testing the keyboard.")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                        #endif
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
        .onChange(of: dictation.text) { _ in dictation.shareEdits() }
    }

    private var recordingLabel: String {
        switch dictation.phase {
        case "recording": return "Stop · \(dictation.seconds)s"
        case "permission": return "Checking permissions…"
        case "finishing": return "Finishing…"
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
    @State private var confirmDelete = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Dictation") {
                    Picker("Language", selection: $speechLocale) {
                        Text("English (Australia)").tag("en-AU")
                        Text("English (India)").tag("en-IN")
                        Text("English (United States)").tag("en-US")
                        Text("English (United Kingdom)").tag("en-GB")
                        Text("Hindi").tag("hi-IN")
                    }
                    Toggle("Allow Apple network recognition", isOn: $allowNetwork)
                    Text("Murmur uses on-device recognition when available. Enabling this option allows speech to be sent to Apple if on-device recognition is unavailable. No Murmur server or API key is used.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.disabled(dictation.busy)
                Section("Saved text") {
                    Toggle("Save completed dictations", isOn: $saveHistory)
                    Text("Keeps the latest 100 unpinned clips, plus your pinned clips. Turning this off affects future dictations; delete existing clips below. The latest transcript remains available for keyboard insertion until you clear it or start again.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Delete all clips and current transcript", role: .destructive) { confirmDelete = true }
                        .disabled(dictation.busy)
                }
                Section("Using the keyboard") {
                    Text("Install the keyboard build directly through SideStore or Sideloadly, keeping its extension. In iPhone Settings → General → Keyboard → Keyboards → Add New Keyboard, choose Murmur. Allow Full Access so it can read the text shared by Murmur. This prototype keyboard makes no network requests.")
                    Text("LiveContainer cannot register Murmur's keyboard. In LiveContainer, use Copy and Paste instead. Some apps do not permit third-party keyboards.")
                }.font(.footnote)
                Section("About") {
                    Text("Murmur · 0.1.0 test build")
                    Text("Made by Vijit Pugalia").foregroundStyle(.secondary)
                    Text("No audio files are saved. Clips stay in this installation's storage and may be included in device backups. This app does not monitor your clipboard.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
            .confirmationDialog("Delete all saved clips and the current transcript?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { dictation.deleteAll() }
            }
        }
    }
}
