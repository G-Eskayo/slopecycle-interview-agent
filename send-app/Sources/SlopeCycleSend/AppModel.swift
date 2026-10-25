import AppKit
import Network
import Observation
import SlopeSendCore
import UniformTypeIdentifiers

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    // The form
    var respondent = ""
    var interviewType: InterviewType = .parent
    var date = Date()
    var notes = ""
    var recordingURL: URL?

    /// The one status line under the buttons.
    var status: String?
    var isSending = false

    let service: SendService
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var wasOnline: Bool?

    init() {
        service = SendService(outbox: Outbox(root: Outbox.defaultRoot), client: URLSessionHTTPClient(),
                              appVersion: AppInfo.version, settings: AppInfo.currentSettings)
        // Event-driven: the first path update (at launch) and every change back to online send the outbox.
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "com.slopecycle.send.network"))
    }

    var draft: Draft {
        Draft(respondentLabel: respondent, interviewType: interviewType,
              interviewDate: InterviewDate.string(from: date), notes: notes, recordingURL: recordingURL)
    }

    var showsNameWarning: Bool { RespondentLabel.looksLikeFullName(respondent) }
    var canSend: Bool { draft.canSend && !isSending }
    var isPristine: Bool { respondent.isEmpty && notes.isEmpty && recordingURL == nil }

    private func networkChanged(online: Bool) {
        defer { wasOnline = online }
        if online && wasOnline != true { sendWaiting() }
    }

    /// Send anything waiting in the outbox (also after Settings are fixed).
    func sendWaiting() {
        Task { await service.flush() }
    }

    func send(openSettings: @escaping () -> Void) {
        guard canSend else { return }
        isSending = true
        status = recordingURL == nil ? "Sending…" : "Compressing and sending…"
        let draft = self.draft
        Task {
            defer { isSending = false }
            do {
                // Runs on the SendService actor, off the main thread (compression included).
                switch try await service.submit(draft) {
                case .sent(_, let recording):
                    status = recording == .sentOriginal
                        ? "✓ Sent to the queue (recording sent uncompressed)"
                        : "✓ Sent to the queue"
                    clearForm()
                case .queued(_, _, let reason):
                    status = reason.isOffline
                        ? "Saved. It will be sent automatically when you're back online."
                        : "Saved, not sent yet (\(reason.localizedDescription)). It will be sent automatically when back online."
                    clearForm()
                }
            } catch let problem as SettingsProblem {
                status = problem.localizedDescription
                openSettings()
            } catch {
                // Nothing was saved; the form keeps everything so the user can fix it.
                status = error.localizedDescription
            }
        }
    }

    func chooseRecording() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audiovisualContent]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recordingURL = url
    }

    func clearForm() {
        respondent = ""
        interviewType = .parent
        date = Date()
        notes = ""
        recordingURL = nil
    }

    func cancel() {
        clearForm()
        status = nil
    }

    func windowOpened() {
        if isPristine { date = Date() }
    }
}
