import AppKit

extension TerminalTarget {
    /// Brings the session's terminal to the front: the app the session runs in first,
    /// then the first running known terminal. Returns false if none is running.
    @discardableResult
    static func activate(sessionBundleId: String?) -> Bool {
        let apps = NSWorkspace.shared.runningApplications
        let running = Set(apps.compactMap(\.bundleIdentifier))
        guard let id = pick(sessionBundleId: sessionBundleId, running: running),
              let app = apps.first(where: { $0.bundleIdentifier == id }) else { return false }
        
        // 1. AppKit activate
        let success = app.activate(options: .activateIgnoringOtherApps)
        
        // 2. On macOS full-screen / Space switches, NSRunningApplication.activate()
        // often does not switch Spaces. AppleScript tell application ... to activate
        // reliably triggers WindowServer to switch desktop/Space to the terminal window.
        let script = "tell application id \"\(id)\" to activate"
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
        
        return success
    }
}
