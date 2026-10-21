import UIKit

final class KeyboardViewController: UIInputViewController, UITableViewDataSource, UITableViewDelegate {
    private let status = UILabel()
    private let recordButton = UIButton(type: .system)
    private let insertButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let endButton = UIButton(type: .system)
    private let table = UITableView(frame: .zero, style: .plain)
    private var clips: [Clip] = []
    private var snapshot: RecordingSnapshot?
    private var poll: Timer?
    private var insertedID: UUID?
    private var pending: (id: UUID, sent: Date)?
    private var autoInsert: (utterance: UUID, document: UUID)?
    private var store: ClipStore? { hasFullAccess ? ClipStore.keyboardStore() : nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let root = UIStackView(); root.axis = .vertical; root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
        let height = view.heightAnchor.constraint(equalToConstant: 340)
        height.priority = .defaultHigh; height.isActive = true
        status.font = .preferredFont(forTextStyle: .footnote); status.numberOfLines = 3
        root.addArrangedSubview(status)
        recordButton.addTarget(self, action: #selector(recordOrStop), for: .touchUpInside)
        insertButton.setTitle("Insert text", for: .normal)
        insertButton.addTarget(self, action: #selector(insertTranscript), for: .touchUpInside)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelRecording), for: .touchUpInside)
        endButton.setTitle("End session", for: .normal)
        endButton.addTarget(self, action: #selector(endSession), for: .touchUpInside)
        for buttons in [[recordButton, insertButton], [cancelButton, endButton]] {
            let row = UIStackView(arrangedSubviews: buttons); row.distribution = .fillEqually
            row.heightAnchor.constraint(equalToConstant: 44).isActive = true
            root.addArrangedSubview(row)
        }
        table.dataSource = self; table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "clip"); root.addArrangedSubview(table)
        let next = UIButton(type: .system); next.setTitle("Next keyboard", for: .normal)
        next.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        let delete = UIButton(type: .system); delete.setTitle("Delete", for: .normal)
        delete.addTarget(self, action: #selector(deleteCharacter), for: .touchUpInside)
        let footer = UIStackView(arrangedSubviews: [next, delete]); footer.distribution = .fillEqually
        footer.heightAnchor.constraint(equalToConstant: 44).isActive = true; root.addArrangedSubview(footer)
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); refresh(); poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated); poll?.invalidate(); poll = nil
        autoInsert = nil; pending = nil
    }
    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
        autoInsert = nil
    }
    private func refresh() {
        guard let store else {
            snapshot = nil; clips = []; table.reloadData(); disableControls()
            status.text = hasFullAccess ? "Shared storage unavailable. Open Murmur once; check SideStore App Group signing if this persists."
                : "Enable Full Access for Murmur in iPhone Keyboard Settings to share dictations and clips."
            return
        }
        do {
            let updated = ClipRules.sorted(try store.loadClips())
            if updated != clips { clips = updated; table.reloadData() }
            snapshot = try store.snapshot()
            guard let snapshot else { disableControls(); status.text = "Open Murmur and activate a keyboard session, then return here."; return }
            if let pending, snapshot.lastCommandID == pending.id { self.pending = nil }
            if let pending, Date().timeIntervalSince(pending.sent) > 4 { self.pending = nil; autoInsert = nil }
            let live = SessionRules.isLive(snapshot)
            let waiting = pending != nil
            recordButton.setTitle(snapshot.phase == "recording" ? "Stop & Insert" : "Record", for: .normal)
            recordButton.isEnabled = live && !waiting && ["idle", "ready", "error", "recording"].contains(snapshot.phase)
            cancelButton.isEnabled = live && !waiting && ["recording", "finishing", "processing"].contains(snapshot.phase)
            endButton.isEnabled = live && !waiting
            insertButton.isEnabled = snapshot.phase == "ready" && !snapshot.text.isEmpty && snapshot.id != insertedID
            if !live {
                autoInsert = nil
                status.text = "Microphone session is off. Open Murmur → Activate keyboard session, then return here. Saved clips still work."
            } else if snapshot.phase == "ready" {
                status.text = snapshot.id == insertedID ? "Inserted. Tap Record for your next message." : snapshot.text
            } else {
                let remaining = max(0, Int(snapshot.sessionExpiresAt?.timeIntervalSinceNow ?? 0))
                status.text = (snapshot.message ?? "Microphone active") + " · " + String(remaining) + "s left"
            }
            if let autoInsert, snapshot.phase == "ready", snapshot.id == autoInsert.utterance,
               textDocumentProxy.documentIdentifier == autoInsert.document, view.window != nil, live {
                self.autoInsert = nil; insertTranscript()
            }
        } catch { disableControls(); autoInsert = nil; status.text = "Could not read Murmur's text. Open Murmur and try again." }
    }
    private func disableControls() {
        for button in [recordButton, insertButton, cancelButton, endButton] { button.isEnabled = false }
    }
    private func send(_ action: SessionAction) {
        guard let snapshot, let token = snapshot.sessionToken, SessionRules.isLive(snapshot), let store else { return }
        let command = KeyboardCommand(sessionToken: token, utteranceID: snapshot.id, action: action)
        do { try store.send(command); pending = (command.id, Date()); refresh() }
        catch { autoInsert = nil; status.text = "Could not send the command. Return to Murmur to stop the microphone." }
    }
    @objc private func recordOrStop() {
        guard let snapshot else { return }
        if snapshot.phase == "recording" {
            autoInsert = (snapshot.id, textDocumentProxy.documentIdentifier); send(.stop)
        } else { autoInsert = nil; send(.start) }
    }
    @objc private func cancelRecording() { autoInsert = nil; send(.cancel) }
    @objc private func endSession() { autoInsert = nil; send(.end) }
    @objc private func insertTranscript() {
        guard let snapshot, snapshot.phase == "ready", !snapshot.text.isEmpty, snapshot.id != insertedID else { return }
        autoInsert = nil; insertedID = snapshot.id
        textDocumentProxy.insertText(snapshot.text); refresh()
    }
    @objc private func deleteCharacter() { autoInsert = nil; textDocumentProxy.deleteBackward() }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { clips.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "clip", for: indexPath)
        var content = cell.defaultContentConfiguration(); let clip = clips[indexPath.row]
        content.text = clip.text; content.textProperties.numberOfLines = 2
        content.image = UIImage(systemName: clip.pinned ? "pin" : "text.bubble")
        cell.contentConfiguration = content; cell.accessibilityHint = "Inserts this clip into the current text field"
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        autoInsert = nil; textDocumentProxy.insertText(clips[indexPath.row].text)
        tableView.deselectRow(at: indexPath, animated: true)
    }
}

