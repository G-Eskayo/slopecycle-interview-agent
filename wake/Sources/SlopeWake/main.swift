import AppKit
import WakeCore

// slope-wake [URL]   (default http://127.0.0.1:5678/webhook/slopecycle-run, or $SLOPE_RUN_URL)
// Rings once at start (login) and on every wake from sleep. Runs as a launchd agent; logs to stderr.

let target = CommandLine.arguments.dropFirst().first ?? ProcessInfo.processInfo.environment["SLOPE_RUN_URL"]
    ?? "http://127.0.0.1:5678/webhook/slopecycle-run"
guard let url = URL(string: target), url.scheme == "http" || url.scheme == "https" else {
    FileHandle.standardError.write(Data("slope-wake: bad URL \(target)\n".utf8))
    exit(2)
}
let bell = Doorbell(url: url)
let debouncer = Debouncer()

@Sendable func ring(_ why: String) {
    Task {
        guard await debouncer.shouldRing() else { return }
        let attempt = await bell.ring()
        let msg = attempt.map { "rang after \(why) (attempt \($0))" } ?? "could not reach \(url.absoluteString) after \(why)"
        FileHandle.standardError.write(Data("slope-wake: \(msg)\n".utf8))
    }
}

let center = NSWorkspace.shared.notificationCenter
center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in ring("wake") }
center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { _ in ring("login") }
if CommandLine.arguments.contains("--simulate-wake") {
    // For testing the event path without putting the Mac to sleep.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { center.post(name: NSWorkspace.didWakeNotification, object: nil) }
} else {
    ring("start")
}
RunLoop.main.run()
