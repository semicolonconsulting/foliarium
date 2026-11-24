#if !APPSTORE
import AppKit
import Security
import SwiftUI

/// Keeps the Developer ID edition (the DMG) up to date from the project's GitHub releases. The App Store
/// edition is built with APPSTORE set and leaves all of this out: the App Store does its updates.
///
/// Once a day it asks GitHub for the latest release. When that is newer than the running copy and has a DMG,
/// it offers to install it. Installing downloads the DMG, copies the app out of it, checks that the copy is
/// signed by our Developer ID team and notarized, swaps it in for the running app and opens it again.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    /// Outside the sandbox only, as a second guard next to the APPSTORE build flag.
    static var isAvailable: Bool { !Edition.isSandboxed }

    struct Release: Equatable, Sendable {
        let version: String
        let notesURL: URL
        let dmgURL: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing(Release)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastCheck: Date?
    @Published var checksAutomatically: Bool {
        didSet {
            defaults.set(checksAutomatically, forKey: Keys.automatic)
            scheduleChecks()
        }
    }

    nonisolated static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    nonisolated private static let latestReleaseURL = URL(string: "https://api.github.com/repos/semicolonconsulting/foliarium/releases/latest")!
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    /// The Developer ID team the update must be signed by, and its bundle identifier.
    nonisolated private static let teamID = "C6ZRF9KM22"
    nonisolated private static let bundleID = "com.semicolonc.foliarium"

    private enum Keys {
        static let automatic = "checksForUpdates"
        static let lastCheck = "lastUpdateCheck"
        static let skipped = "skippedUpdateVersion"
    }

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    /// The version an automatic check last told the user about, so it asks once per launch at most.
    private var announced: String?

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Keys.automatic: true])
        checksAutomatically = defaults.bool(forKey: Keys.automatic)
        lastCheck = defaults.object(forKey: Keys.lastCheck) as? Date
    }

    /// Starts the daily checks. The first one waits a little, so launching stays quick.
    func start() {
        guard Self.isAvailable else { return }
        scheduleChecks()
    }

    private func scheduleChecks() {
        timer?.invalidate()
        timer = nil
        guard checksAutomatically, Self.isAvailable else { return }
        // Wake every hour and check when a day has passed, so sleep and long uptimes don't skip a check.
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        timer.tolerance = 5 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.checkIfDue()
        }
    }

    private func checkIfDue() {
        guard checksAutomatically else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.checkInterval { return }
        check(userInitiated: false)
    }

    var isBusy: Bool {
        switch state {
        case .checking, .installing: true
        default: false
        }
    }

    /// Asks GitHub for the latest release. With `showResult`, a check the user asked for reports what it found
    /// in an alert; an automatic check only speaks up about a new version the user hasn't skipped.
    func check(userInitiated: Bool, showResult: Bool = false) {
        guard !isBusy else { return }
        state = .checking
        Task {
            do {
                let release = try await Self.fetchLatest()
                lastCheck = Date()
                defaults.set(lastCheck, forKey: Keys.lastCheck)
                guard let release, Self.isNewer(release.version, than: Self.currentVersion) else {
                    state = .upToDate
                    if showResult { alertUpToDate() }
                    return
                }
                state = .available(release)
                if userInitiated {
                    if showResult { offer(release, automatic: false) }
                } else if defaults.string(forKey: Keys.skipped) != release.version, announced != release.version {
                    announced = release.version
                    offer(release, automatic: true)
                }
            } catch {
                state = .failed("Couldn't check for updates: \(error.localizedDescription)")
                if showResult { alert(title: "Couldn't check for updates", text: error.localizedDescription) }
            }
        }
    }

    /// Downloads `release`, checks it, puts it in place of this copy and opens it.
    func install(_ release: Release) {
        guard !isBusy else { return }
        let appURL = Bundle.main.bundleURL
        let folder = appURL.deletingLastPathComponent()
        // A copy macOS runs from a randomised read-only place (opened straight from a download), or one in a
        // folder the user can't write to, can't replace itself: send the user to the download instead.
        if appURL.path.contains("/AppTranslocation/") || !FileManager.default.isWritableFile(atPath: folder.path) {
            state = .available(release)
            alert(title: "Foliarium can't update itself here",
                  text: "Move Foliarium to the Applications folder, or download version \(release.version) from the release page and drag it there.")
            NSWorkspace.shared.open(release.notesURL)
            return
        }
        state = .installing(release)
        Task {
            do {
                let staged = try await Self.prepare(release, next: appURL)
                _ = try FileManager.default.replaceItemAt(appURL, withItemAt: staged)
                relaunch(appURL)
            } catch {
                state = .failed("Couldn't install \(release.version): \(error.localizedDescription)")
                alert(title: "Couldn't install Foliarium \(release.version)", text: error.localizedDescription)
            }
        }
    }

    // MARK: Alerts

    private func offer(_ release: Release, automatic: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Foliarium \(release.version) is available"
        alert.informativeText = "You have \(Self.currentVersion). Foliarium will quit and open again to finish installing."
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        if automatic { alert.addButton(withTitle: "Skip This Version") }
        alert.showsHelp = true
        alert.delegate = ReleaseNotesHelp.shared
        ReleaseNotesHelp.shared.url = release.notesURL
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(release)
        case .alertThirdButtonReturn: defaults.set(release.version, forKey: Keys.skipped)
        default: break
        }
    }

    private func alertUpToDate() {
        alert(title: "Foliarium is up to date", text: "Version \(Self.currentVersion) is the latest.")
    }

    private func alert(title: String, text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    /// Waits for this process to quit, then opens the new copy.
    private func relaunch(_ appURL: URL) {
        let script = "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), appURL.path]
        do {
            try process.run()
        } catch {
            NSLog("Foliarium: could not schedule the relaunch: \(error.localizedDescription)")
        }
        NSApp.terminate(nil)
    }

    // MARK: Work off the main thread

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let html_url: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): text }
        }
    }

    /// The latest published release with a DMG, or nil when there isn't one.
    nonisolated private static func fetchLatest() async throws -> Release? {
        var request = URLRequest(url: latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Foliarium/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw UpdateError.message("GitHub answered with status \(status).") }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease,
              let dmg = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else { return nil }
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        return Release(version: version, notesURL: release.html_url, dmgURL: dmg.browser_download_url)
    }

    /// Downloads the DMG and copies the app out of it, next to `appURL` (so the swap stays on one volume), then
    /// checks the copy. Returns the checked copy.
    nonisolated private static func prepare(_ release: Release, next appURL: URL) async throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Foliarium-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let (download, response) = try await URLSession.shared.download(from: release.dmgURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.message("The download failed (status \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let dmg = work.appendingPathComponent("Foliarium.dmg")
        try FileManager.default.moveItem(at: download, to: dmg)

        return try await Task.detached {
            let mount = work.appendingPathComponent("mount")
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try Updater.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
            defer { _ = try? Updater.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

            let source = mount.appendingPathComponent("Foliarium.app")
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw UpdateError.message("The disk image has no Foliarium.app.")
            }
            let staged = appURL.deletingLastPathComponent().appendingPathComponent(".Foliarium-update.app")
            try? FileManager.default.removeItem(at: staged)
            try Updater.run("/usr/bin/ditto", [source.path, staged.path])
            do {
                try Updater.verify(staged, version: release.version)
            } catch {
                try? FileManager.default.removeItem(at: staged)
                throw error
            }
            return staged
        }.value
    }

    /// Checks that `app` is Foliarium, signed by our Developer ID team, notarized, and the version expected.
    nonisolated private static func verify(_ app: URL, version: String) throws {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let found = info?["CFBundleShortVersionString"] as? String ?? ""
        guard found == version, isNewer(found, than: currentVersion) else {
            throw UpdateError.message("The downloaded app is version \(found.isEmpty ? "unknown" : found), not \(version).")
        }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.message("The downloaded app's signature couldn't be read.")
        }
        var requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError.message("The signature requirement is invalid.")
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSStrictValidate) | UInt32(kSecCSCheckNestedCode))
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            throw UpdateError.message("The downloaded app isn't signed by Semicolon Consulting (error \(status)).")
        }
        // Gatekeeper's verdict: accepted only when it's notarized.
        do {
            try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        } catch {
            throw UpdateError.message("macOS doesn't accept the downloaded app (it isn't notarized).")
        }
    }

    /// Runs a command line tool and returns what it printed; throws when it fails.
    @discardableResult
    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw UpdateError.message("\((tool as NSString).lastPathComponent) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }

    /// "1.10" is newer than "1.9"; "1.1" and "1.1.0" are the same.
    nonisolated static func isNewer(_ version: String, than other: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = other.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// The ? button on the update alert opens the release notes.
@MainActor
private final class ReleaseNotesHelp: NSObject, NSAlertDelegate {
    static let shared = ReleaseNotesHelp()
    var url: URL?

    func alertShowHelp(_ alert: NSAlert) -> Bool {
        if let url { NSWorkspace.shared.open(url) }
        return true
    }
}

/// The Updates section of the General tab.
struct UpdatesSection: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Foliarium \(Updater.currentVersion)")
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                switch updater.state {
                case .available(let release):
                    Button("Release Notes") { NSWorkspace.shared.open(release.notesURL) }
                    Button("Install and Relaunch") { updater.install(release) }
                case .installing:
                    ProgressView().controlSize(.small)
                default:
                    Button("Check Now") { updater.check(userInitiated: true) }
                        .disabled(updater.isBusy)
                }
            }
        } header: {
            Text("Updates")
        }
    }

    private var detail: String {
        switch updater.state {
        case .checking: return "Checking for updates…"
        case .upToDate: return "Up to date" + checkedText
        case .available(let release): return "Version \(release.version) is available."
        case .installing(let release): return "Downloading and installing \(release.version)…"
        case .failed(let message): return message
        case .idle:
            guard let last = updater.lastCheck else { return "Not checked yet" }
            return "Last checked " + last.formatted(.relative(presentation: .named))
        }
    }

    /// ", checked today at 09:00".
    private var checkedText: String {
        guard let last = updater.lastCheck else { return "" }
        return ", checked " + last.formatted(.relative(presentation: .named))
    }
}
#endif
