import AppKit
import SlopeSendCore

/// Developer checks, inert unless an environment variable is set.
/// `SLOPE_SEND_SNAPSHOT_DIR=<dir>`: renders the window to send-window.png (empty) and send-window-filled.png.
/// `SLOPE_SEND_SELFTEST=1`: drives the real notes box in-process the way dictation tools do (typed key
/// events, Cmd-V paste through the menu key-equivalent path, NSTextInputClient insertText, a very long paste),
/// prints PASS/FAIL lines, restores the clipboard, clears the form and quits. Never sends anything.
@MainActor
enum SelfTest {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["SLOPE_SEND_SNAPSHOT_DIR"] {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                WindowOpener.shared.openSendWindow()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("send-window.png"))
                let m = AppModel.shared
                m.respondent = "Jane Doe"
                m.notes = "SYNTHETIC TEST DATA. Example dictated notes."
                m.recordingURL = env["SLOPE_SEND_SNAPSHOT_RECORDING"].map { URL(fileURLWithPath: $0) }
                m.status = "✓ Sent to the queue"
                try? await Task.sleep(nanoseconds: 800_000_000)
                snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("send-window-filled.png"))
                m.cancel()
                NSApp.terminate(nil)
            }
            return
        }
        guard env["SLOPE_SEND_SELFTEST"] == "1" else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            WindowOpener.shared.openSendWindow()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let ok = await run()
            print(ok ? "SELFTEST RESULT: PASS" : "SELFTEST RESULT: FAIL")
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    /// Renders the whole window (title bar included) without needing Screen Recording permission.
    static func snapshot(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.title == "SlopeCycle Send" && $0.isVisible }),
              let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
            print("SNAPSHOT FAIL: no window"); return
        }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        do {
            try rep.representation(using: .png, properties: [:])!.write(to: url)
            print("SNAPSHOT \(url.path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
        } catch {
            print("SNAPSHOT FAIL: \(error)")
        }
    }

    static func findTextView(_ view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView, tv.isEditable, !tv.isFieldEditor { return tv }
        for sub in view.subviews { if let tv = findTextView(sub) { return tv } }
        return nil
    }

    static func key(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = [], window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            NSApp.sendEvent(e)
        }
    }

    static func check(_ name: String, _ condition: Bool) -> Bool {
        let m = AppModel.shared
        print("SELFTEST \(condition ? "PASS" : "FAIL"): \(name)"
              + (condition ? "" : " [notes=\(m.notes.prefix(80).debugDescription) (\(m.notes.count) chars) respondent=\(m.respondent.debugDescription) firstResponder=\(String(describing: NSApp.keyWindow?.firstResponder.map { type(of: $0) }))]"))
        return condition
    }

    static func run() async -> Bool {
        let model = AppModel.shared
        guard let window = NSApp.windows.first(where: { $0.title == "SlopeCycle Send" && $0.isVisible }),
              let content = window.contentView, let tv = findTextView(content) else {
            return check("send window with an editable notes box is open", false)
        }
        var ok = check("send window with an editable notes box is open", true)
        ok = check("Send disabled on an empty form", !model.canSend) && ok
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        _ = window.makeFirstResponder(tv)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let editItems = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] }
            .filter { $0.keyEquivalent == "v" }.map { "\($0.title) -> \(String(describing: $0.action))" } ?? []
        print("SELFTEST INFO: active=\(NSApp.isActive) key=\(window.isKeyWindow) menus=\(NSApp.mainMenu?.items.map(\.title) ?? []) cmdV=\(editItems)")
        _ = check("paste is wired to a Cmd-V menu item", editItems.contains { $0.contains("paste") })
        let settle = { try? await Task.sleep(nanoseconds: 300_000_000) }

        // 1. Typed keys (what keyboard-emulating dictation does).
        for (c, code) in [("h", UInt16(4)), ("i", 34), (" ", 49)] { key(c, code: code, window: window) }
        await settle()
        ok = check("typed key events reach the notes", model.notes == "hi ") && ok

        // 2. Cmd-V paste (what Wispr Flow does) through the app's menu key equivalents.
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        } ?? []
        defer { pb.clearContents(); if !saved.isEmpty { pb.writeObjects(saved) } }
        let dictated = "SYNTHETIC TEST DATA dictated — naïve café 👩🏽‍💻 ✅\nNew paragraph."
        pb.clearContents()
        pb.setString(dictated, forType: .string)
        key("v", code: 9, flags: .command, window: window)
        await settle()
        ok = check("Cmd-V paste inserts clipboard text", model.notes == "hi " + dictated) && ok

        // 3. NSTextInputClient insertText (system dictation / input methods / accessibility insertion).
        tv.insertText(" inserted", replacementRange: NSRange(location: NSNotFound, length: 0))
        await settle()
        ok = check("insertText reaches the notes", model.notes.hasSuffix("New paragraph. inserted")) && ok

        // 4. Long text: ~1 MB pasted in one go, then the window still responds.
        let long = String(repeating: "SYNTHETIC TEST DATA long dictation sentence with ünïcödé. ", count: 18_000)
        pb.clearContents()
        pb.setString(long, forType: .string)
        tv.selectAll(nil)
        key("v", code: 9, flags: .command, window: window)
        await settle()
        ok = check("long paste (\(long.utf8.count) bytes) lands intact", model.notes == long) && ok

        model.respondent = "Jane Doe"
        await settle()
        ok = check("name warning shows for a full name", model.showsNameWarning) && ok
        ok = check("Send enabled with respondent + notes", model.canSend) && ok
        model.respondent = "P-07"
        ok = check("no warning for P-07", !model.showsNameWarning) && ok

        model.cancel()
        return ok
    }
}
