#if !APPSTORE
import Foundation
import AppKit
import Combine

// MARK: - Media Controller (Now Playing)

/// Universal now-playing controller.
///
/// Preferred path: the `media-control` CLI (Homebrew port of ungive/mediaremote-adapter,
/// BSD-3) which streams system-wide now-playing information via the MediaRemote
/// framework. This covers browsers (YouTube, YouTube Music, Spotify Web, SoundCloud
/// in Chrome/Safari/Arc/Brave) and desktop apps (Spotify, Apple Music, Tidal, …).
///
/// Fallback when the CLI is absent: Apple Music only, through distributed
/// notifications + AppleScript (requires the Automation permission prompt).
///
/// Singleton, @MainActor, GitHub build only.
@MainActor
final class MusicController: ObservableObject {
    static let shared = MusicController()

    @Published var trackTitle: String?
    @Published var artist: String?
    @Published var album: String?
    /// Bundle id of the app currently playing, when known (media-control path).
    @Published var sourceBundleId: String?
    /// True when universal detection via media-control is available.
    let usesMediaControl: Bool

    private var notifTokens: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "com.ismailalam.coucou.music")

    private var mediaControlBin: String = ""
    private var mcStreamProcess: Process?
    private var mcRestartWorkItem: DispatchWorkItem?

    private static let mediaControlCandidates = [
        ProcessInfo.processInfo.environment["MEDIA_CONTROL_BIN"],
        "/opt/homebrew/bin/media-control",
        "/usr/local/bin/media-control",
    ].compactMap { $0 }

    static func findMediaControl() -> String? {
        mediaControlCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private var isPillActive: Bool {
        AppState.shared.activeIntegrations.contains("integration_music")
    }

    private init() {
        let mc = Self.findMediaControl()
        mediaControlBin = mc ?? ""
        usesMediaControl = (mc != nil)
        // Stop the stream child when the app quits (avoid orphan media-control processes)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.stopMediaControlStream()
        }
        if let mc {
            NSLog("[ZuddyMusic] universal mode via %@", mc)
            observePillActivation()
            if isPillActive { startMediaControlStream() }
        } else {
            NSLog("[ZuddyMusic] legacy Apple Music mode (media-control not found)")
            startLegacyObservers()
            observePillActivation()
        }
    }

    // MARK: - Pill activation (both modes)

    private func observePillActivation() {
        AppState.shared.$activeIntegrations
            .sink { [weak self] integrations in
                guard let self else { return }
                if integrations.contains("integration_music") {
                    if self.usesMediaControl {
                        self.startMediaControlStream()
                        self.fetchOnceViaMediaControl()
                    } else if self.isMusicRunning(),
                              UserDefaults.standard.bool(forKey: "coucou.musicAutomationGranted") {
                        self.fetchAndApply()
                    }
                } else {
                    self.clearState()
                    if self.usesMediaControl { self.stopMediaControlStream() }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Universal path (media-control stream)

    private func startMediaControlStream() {
        stopMediaControlStream()
        guard isPillActive, !mediaControlBin.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: mediaControlBin)
        p.arguments = ["stream", "--no-diff", "--no-artwork"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            buffer.append(data)
            for line in buffer.drainLines() {
                Task { @MainActor [weak self] in self?.consumeMediaControlLine(line) }
            }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.mcStreamProcess = nil
                // media-control died (update / crash): restart while the pill is active
                guard self.isPillActive, self.mcStreamProcess == nil else { return }
                let item = DispatchWorkItem { [weak self] in self?.startMediaControlStream() }
                self.mcRestartWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
            }
        }
        do {
            try p.run()
            mcStreamProcess = p
            NSLog("[ZuddyMusic] stream started pid=%d", p.processIdentifier)
        } catch {
            NSLog("[ZuddyMusic] stream start FAILED: %@", error.localizedDescription)
        }
    }

    private func stopMediaControlStream() {
        mcRestartWorkItem?.cancel()
        mcRestartWorkItem = nil
        guard let p = mcStreamProcess else { return }
        p.terminationHandler = nil
        p.terminate()
        mcStreamProcess = nil
    }

    private func consumeMediaControlLine(_ line: String) {
        guard isPillActive,
              let d = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              obj["type"] as? String == "data",
              let payload = obj["payload"] as? [String: Any] else { return }
        if payload.isEmpty { clearState(); return }
        applyNowPlaying(payload)
    }

    private func fetchOnceViaMediaControl() {
        let bin = mediaControlBin
        let pipe = Pipe()
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["get", "--no-artwork"]
            p.standardOutput = pipe
            p.standardError = Pipe()
            p.terminationHandler = { _ in }
            do { try p.run() } catch { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isPillActive, self.usesMediaControl,
                      let d = s.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                else { return }
                if payload.isEmpty { self.clearState() } else { self.applyNowPlaying(payload) }
            }
        }
    }

    private func applyNowPlaying(_ payload: [String: Any]) {
        let playing = (payload["playing"] as? Bool) ?? false
        let wasPlaying = AppState.shared.musicPlaying

        trackTitle = (payload["title"] as? String).flatMap { $0.isEmpty ? nil : Self.shortTitle($0) }
        artist     = (payload["artist"] as? String).flatMap { $0.isEmpty ? nil : Self.shortArtist($0) }
        album      = payload["album"] as? String
        sourceBundleId = (payload["bundleIdentifier"] as? String) ?? (payload["bundle_identifier"] as? String)

        AppState.shared.musicPlaying = playing
        syncTaskName()

        if playing != wasPlaying {
            NSLog("[ZuddyMusic] playing=%d title=%@", playing ? 1 : 0, trackTitle ?? "-")
        }

        // Reveal only on transition from not-playing → playing
        if playing && !wasPlaying {
            NotificationCenter.default.post(name: .musicReveal, object: nil)
        }
    }

    /// Bring the source app forward (e.g. Chrome playing YouTube, Spotify desktop).
    func openMediaSource() {
        if let bid = sourceBundleId,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }) {
            app.activate(options: .activateIgnoringOtherApps)
            return
        }
        openMusic()
    }

    // MARK: - Playback controls (universal first, AppleScript fallback)

    func playPause() {
        if usesMediaControl { sendMediaCommand("toggle-play-pause") }
        else if isMusicRunning() {
            Task { await runAppleScript(#"tell application id "com.apple.Music" to playpause"#) }
        }
    }

    func nextTrack() {
        if usesMediaControl { sendMediaCommand("next-track") }
        else if isMusicRunning() {
            Task { await runAppleScript(#"tell application id "com.apple.Music" to next track"#) }
        }
    }

    func previousTrack() {
        if usesMediaControl { sendMediaCommand("previous-track") }
        else if isMusicRunning() {
            Task { await runAppleScript(#"tell application id "com.apple.Music" to back track"#) }
        }
    }

    private func sendMediaCommand(_ command: String) {
        let bin = mediaControlBin
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = [command]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            p.terminationHandler = { _ in }
            try? p.run()
        }
    }

    // MARK: - Legacy path (Apple Music only, no media-control installed)

    private func startLegacyObservers() {
        // playerInfo fires whenever Music state changes (play/pause/track change).
        // Extract Sendable String? values before crossing into @MainActor.
        let tok1 = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let info        = notif.userInfo
            let playerState = info?["Player State"] as? String
            let name        = info?["Name"]          as? String
            let artist      = info?["Artist"]        as? String
            let album       = info?["Album"]         as? String
            Task { @MainActor [weak self] in
                self?.handlePlayerInfo(playerState: playerState, name: name, artist: artist, album: album)
            }
        }
        notifTokens.append(tok1)

        // Track Music launch — read current state only if granted and pill active
        let tok2 = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let bundleId = (notif.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier
            guard bundleId == "com.apple.Music" else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isPillActive,
                      UserDefaults.standard.bool(forKey: "coucou.musicAutomationGranted") else { return }
                self.fetchAndApply()
            }
        }
        notifTokens.append(tok2)

        // Clear state when Music quits
        let tok3 = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let bundleId = (notif.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier
            guard bundleId == "com.apple.Music" else { return }
            Task { @MainActor [weak self] in self?.clearState() }
        }
        notifTokens.append(tok3)
    }

    private func isMusicRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Music" }
    }

    // MARK: - Metadata cleaners

    private static func shortTitle(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var s = raw
        // Cut at first " - "
        if let r = s.range(of: " - ") {
            s = String(s[..<r.lowerBound])
        }
        // Strip trailing (...) or [...] groups repeatedly
        var changed = true
        while changed {
            changed = false
            let t = s.trimmingCharacters(in: .whitespaces)
            guard let last = t.last, (last == ")" || last == "]") else { break }
            let open: Character = last == ")" ? "(" : "["
            if let idx = t.lastIndex(of: open) {
                let candidate = String(t[..<idx]).trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty { s = candidate; changed = true }
            } else { break }
        }
        let result = s.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? raw : result
    }

    private static func shortArtist(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        let lower = raw.lowercased()
        for tag in [" feat.", " ft."] {
            if let r = lower.range(of: tag) {
                let result = String(raw[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                return result.isEmpty ? raw : result
            }
        }
        return raw
    }

    private func handlePlayerInfo(playerState: String?, name: String?, artist inputArtist: String?, album inputAlbum: String?) {
        guard isPillActive else { return }

        let playing = playerState == "Playing"
        let wasPlaying = AppState.shared.musicPlaying

        trackTitle = name.map { Self.shortTitle($0) }.flatMap { $0.isEmpty ? nil : $0 }
        artist     = inputArtist.map { Self.shortArtist($0) }.flatMap { $0.isEmpty ? nil : $0 }
        album      = inputAlbum

        AppState.shared.musicPlaying = playing
        syncTaskName()

        // Reveal only on transition from not-playing → playing
        if playing && !wasPlaying {
            NotificationCenter.default.post(name: .musicReveal, object: nil)
        }
    }

    private func fetchAndApply() {
        Task {
            let result = await runAppleScript("""
                tell application id "com.apple.Music"
                    set ps to player state as string
                    if ps is "stopped" then return {ps, "", "", ""}
                    try
                        set tr to current track
                        set n to name of tr
                    on error
                        return {ps, "", "", ""}
                    end try
                    set ar to ""
                    set al to ""
                    try
                        set ar to artist of tr
                    end try
                    try
                        set al to album of tr
                    end try
                    return {ps, n, ar, al}
                end tell
            """)
            guard case .success(let values) = result, values.count >= 4 else { return }
            let playing    = values[0] == "playing"
            let wasPlaying = AppState.shared.musicPlaying
            trackTitle = values[1].isEmpty ? nil : Self.shortTitle(values[1])
            artist     = values[2].isEmpty ? nil : Self.shortArtist(values[2])
            album      = values[3].isEmpty ? nil : values[3]
            AppState.shared.musicPlaying = playing
            syncTaskName()
            if playing && !wasPlaying {
                NotificationCenter.default.post(name: .musicReveal, object: nil)
            }
        }
    }

    private func clearState() {
        trackTitle = nil; artist = nil; album = nil
        sourceBundleId = nil
        AppState.shared.musicPlaying = false
        syncTaskName()
    }

    private func syncTaskName() {
        guard let idx = AppState.shared.tasks.firstIndex(where: { $0.id == "integration_music" }) else { return }
        let title = trackTitle ?? ""
        AppState.shared.tasks[idx].name = title.isEmpty
            ? (PillCatalog.definition(for: "integration_music")?.name ?? "Now Playing")
            : title
    }

    func openMusic() {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.Music" }) {
            app.activate(options: .activateIgnoringOtherApps)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Music.app"))
        }
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - AppleScript runner

    enum ScriptResult { case success([String]), denied, error }

    @discardableResult
    private func runAppleScript(_ source: String) async -> ScriptResult {
        await withCheckedContinuation { cont in
            queue.async {
                let script = NSAppleScript(source: source)!
                var errDict: NSDictionary?
                let desc = script.executeAndReturnError(&errDict)
                if let errDict {
                    let code = (errDict[NSAppleScript.errorNumber] as? Int) ?? 0
                    if code == -1743 {
                        Task { @MainActor in
                            AppState.shared.musicAutomationDenied = true
                            UserDefaults.standard.set(false, forKey: "coucou.musicAutomationGranted")
                        }
                        cont.resume(returning: .denied)
                    } else {
                        cont.resume(returning: .error)
                    }
                    return
                }
                Task { @MainActor in
                    UserDefaults.standard.set(true, forKey: "coucou.musicAutomationGranted")
                    AppState.shared.musicAutomationDenied = false
                }
                // Extract values on this queue before resuming (avoids NSAppleEventDescriptor Sendable issues)
                var values: [String] = []
                let count = desc.numberOfItems
                if count > 0 {
                    for i in 1...count {
                        values.append(desc.atIndex(i)?.stringValue ?? "")
                    }
                } else {
                    values = [desc.stringValue ?? ""]
                }
                cont.resume(returning: .success(values))
            }
        }
    }
}

// MARK: - Stream line buffer (thread-safe)

/// Accumulates stream bytes from a background readabilityHandler and yields
/// complete newline-terminated lines. All state guarded by a lock.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""

    func append(_ data: Data) {
        lock.lock()
        pending += String(decoding: data, as: UTF8.self)
        lock.unlock()
    }

    func drainLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var lines: [String] = []
        while let nl = pending.firstIndex(of: "\n") {
            let line = String(pending[..<nl])
            pending.removeSubrange(pending.startIndex...nl)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}
#endif
