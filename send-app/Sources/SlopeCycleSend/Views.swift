import AppKit
import SlopeSendCore
import SwiftUI

@main
struct SlopeCycleSendApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            MenuBarLabel()
        }
        Window("SlopeCycle Send", id: SendView.windowID) {
            SendView().environment(model)
        }
        .windowResizability(.contentSize)
        Settings {
            SettingsView().environment(model)
        }
    }
}

/// Opening the app again while it runs (Finder, Launchpad, Spotlight) shows the window, because a menu-bar
/// icon can be hidden behind the notch or by a crowded menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { WindowOpener.shared.openSendWindow() }
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { SelfTest.runIfRequested() }
    }
}

@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    var openWindow: OpenWindowAction?

    func openSendWindow() {
        NSApp.activate()
        openWindow?(id: SendView.windowID)
    }
}

/// The menu-bar icon. It is always on screen, so it is where the window-opening action is captured.
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "paperplane")
            .accessibilityLabel("SlopeCycle Send")
            .onAppear { WindowOpener.shared.openWindow = openWindow }
    }
}

struct MenuContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Open SlopeCycle Send") {
            NSApp.activate()
            openWindow(id: SendView.windowID)
        }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit SlopeCycle Send") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct SendView: View {
    static let windowID = "send"

    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Respondent")
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Respondent", text: $model.respondent, prompt: Text("P-07"))
                            .labelsHidden()
                            .frame(width: 180)
                        if model.showsNameWarning {
                            Text(RespondentLabel.nameWarning)
                                .fixedSize()
                        }
                    }
                }
                GridRow {
                    Text("Type")
                    Picker("Type", selection: $model.interviewType) {
                        Text("Parent").tag(InterviewType.parent)
                        Text("Expert").tag(InterviewType.expert)
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                }
                GridRow {
                    Text("Date")
                    DatePicker("Date", selection: $model.date, displayedComponents: .date)
                        .datePickerStyle(.field)
                        .labelsHidden()
                        .fixedSize()
                }
            }

            Text("Notes (dictate with Wispr):")
                .padding(.top, 6)
            TextEditor(text: $model.notes)
                .font(.body)
                .frame(minHeight: 200)
                .border(Color(nsColor: .separatorColor))

            HStack(spacing: 12) {
                Text("Recording")
                Button("Attach file…") { model.chooseRecording() }
                Text(model.recordingURL?.lastPathComponent ?? "(none)")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancel()
                    dismissWindow(id: Self.windowID)
                }
                Button("Send") {
                    model.send(openSettings: {
                        NSApp.activate()
                        openSettings()
                    })
                }
                .disabled(!model.canSend)
            }

            if let status = model.status {
                Text(status)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { model.windowOpened() }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKeys.interviewer) private var interviewer = ""
    @AppStorage(SettingsKeys.repository) private var repository = ""
    @State private var accessKey = ""
    @State private var testResult = ""
    @State private var testing = false

    var body: some View {
        Form {
            TextField("Your name", text: $interviewer)
            TextField("Queue repository", text: $repository, prompt: Text("owner/name"))
            SecureField("Access key", text: $accessKey)
                .onChange(of: accessKey) { _, value in Keychain.write(value) }
            HStack {
                Button("Test connection") { test() }
                    .disabled(testing)
                Text(testResult)
                    .lineLimit(2)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { accessKey = Keychain.read() }
    }

    private func test() {
        testing = true
        testResult = "Checking…"
        let settings = QueueSettings(interviewer: interviewer.isEmpty ? "-" : interviewer,
                                     repository: repository, token: accessKey)
        Task {
            defer { testing = false }
            do {
                let valid = try settings.validated()
                let writer = GitHubQueueWriter(client: URLSessionHTTPClient(), repo: valid.repo, token: valid.token)
                try await writer.checkConnection()
                testResult = "✓ The key can see \(valid.repo)"
                model.sendWaiting()
            } catch {
                testResult = error.localizedDescription
            }
        }
    }
}
