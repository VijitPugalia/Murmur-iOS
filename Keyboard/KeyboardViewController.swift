import UIKit

final class KeyboardViewController: UIInputViewController, UITableViewDataSource, UITableViewDelegate {
    private let status = UILabel()
    private let stopButton = UIButton(type: .system)
    private let insertButton = UIButton(type: .system)
    private let table = UITableView(frame: .zero, style: .plain)
    private var clips: [Clip] = []
    private var snapshot: RecordingSnapshot?
    private var poll: Timer?
    private var insertedID: UUID?
    private var store: ClipStore? { hasFullAccess ? ClipStore.keyboardStore() : nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let root = UIStackView()
        root.axis = .vertical; root.spacing = 8; root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
        let height = view.heightAnchor.constraint(equalToConstant: 310)
        height.priority = .defaultHigh; height.isActive = true
        status.font = .preferredFont(forTextStyle: .footnote)
        status.numberOfLines = 3
        root.addArrangedSubview(status)
        let controls = UIStackView(); controls.spacing = 12; controls.distribution = .fillEqually
        stopButton.setTitle("Stop", for: .normal)
        stopButton.addTarget(self, action: #selector(stopRecording), for: .touchUpInside)
        insertButton.setTitle("Insert transcript", for: .normal)
        insertButton.addTarget(self, action: #selector(insertTranscript), for: .touchUpInside)
        controls.addArrangedSubview(stopButton); controls.addArrangedSubview(insertButton)
        controls.heightAnchor.constraint(equalToConstant: 44).isActive = true
        root.addArrangedSubview(controls)
        table.dataSource = self; table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "clip")
        root.addArrangedSubview(table)
        let footer = UIStackView(); footer.distribution = .fillEqually
        let next = UIButton(type: .system)
        next.setTitle("Next keyboard", for: .normal)
        next.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        let delete = UIButton(type: .system)
        delete.setTitle("Delete", for: .normal)
        delete.addTarget(self, action: #selector(deleteCharacter), for: .touchUpInside)
        footer.addArrangedSubview(next); footer.addArrangedSubview(delete)
        footer.heightAnchor.constraint(equalToConstant: 44).isActive = true
        root.addArrangedSubview(footer)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        poll?.invalidate(); poll = nil
    }

    private func refresh() {
        guard let store else {
            snapshot = nil; clips = []; table.reloadData()
            stopButton.isEnabled = false; insertButton.isEnabled = false
            status.text = hasFullAccess
                ? "Shared storage unavailable. Open Murmur once. If this persists, check App Group signing or use Copy/Paste."
                : "Enable Full Access for Murmur in Keyboard Settings to read your saved clips."
            return
        }
        do {
            let updated = ClipRules.sorted(try store.loadClips())
            if updated != clips { clips = updated; table.reloadData() }
            snapshot = try store.snapshot()
            let fresh = snapshot.map { Date().timeIntervalSince($0.updatedAt) < 4 } ?? false
            stopButton.isEnabled = snapshot?.phase == "recording" && fresh
            insertButton.isEnabled = snapshot?.phase == "ready" && !(snapshot?.text.isEmpty ?? true) && snapshot?.id != insertedID
            if snapshot?.phase == "recording", fresh {
                status.text = snapshot!.text.isEmpty ? "Listening… Tap Stop when finished." : snapshot!.text
            } else if snapshot?.phase == "finishing", fresh { status.text = "Finishing your transcript…" }
            else if snapshot?.phase == "ready" {
                status.text = snapshot?.id == insertedID ? "Inserted. Choose a clip or start another recording in Murmur." : snapshot!.text
            } else { status.text = "Start dictation in Murmur, then return here. Tap a saved clip below to insert it." }
        } catch {
            snapshot = nil; clips = []; table.reloadData()
            stopButton.isEnabled = false; insertButton.isEnabled = false
            status.text = "Could not read Murmur's text. Open Murmur and try again."
        }
    }
    @objc private func stopRecording() {
        guard let id = snapshot?.id else { return }
        do { try store?.requestStop(id); status.text = "Stopping…" }
        catch { status.text = "Could not stop recording. Return to Murmur and tap Stop." }
    }
    @objc private func insertTranscript() {
        guard let snapshot, snapshot.phase == "ready", !snapshot.text.isEmpty, snapshot.id != insertedID else { return }
        textDocumentProxy.insertText(snapshot.text)
        insertedID = snapshot.id
        refresh()
    }
    @objc private func deleteCharacter() { textDocumentProxy.deleteBackward() }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { clips.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "clip", for: indexPath)
        var content = cell.defaultContentConfiguration()
        let clip = clips[indexPath.row]
        content.text = clip.text; content.textProperties.numberOfLines = 2
        content.image = UIImage(systemName: clip.pinned ? "pin" : "text.bubble")
        cell.contentConfiguration = content
        cell.accessibilityHint = "Inserts this clip into the current text field"
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        textDocumentProxy.insertText(clips[indexPath.row].text)
        tableView.deselectRow(at: indexPath, animated: true)
    }
}
