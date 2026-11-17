import AppKit
import Foundation

/// The app's state, shared by the menu bar menu and the windows.
@MainActor
final class AppModel: ObservableObject {
    static let shared: AppModel = {
        // Before anything reads the settings or the log.
        ConfigStore.moveSettingsFromFoldertidy()
        return AppModel()
    }()

    struct LastRun {
        let date: Date
        let summary: String
    }

    @Published var config: Config {
        didSet { configDidChange(from: oldValue) }
    }
    /// Newest first. The full history is in the activity log file.
    @Published private(set) var activity: [ActionRecord] = []
    @Published private(set) var lastRun: LastRun?
    @Published private(set) var isRunning = false
    /// Something wrong with a rule's folder, such as it being missing.
    @Published private(set) var problem: String?
    /// When each scheduled rule runs next.
    @Published private(set) var nextRuns: [UUID: Date] = [:]
    /// Bumped to make the Preview window look again.
    @Published var previewRequest = 0

    let log = ActivityLog()
    private let processor = Processor()

    private init() {
        config = ConfigStore.load()
        activity = log.loadRecent(limit: 500)
        processor.onReport = { [weak self] report, trigger in
            Task { @MainActor in self?.receive(report, trigger: trigger) }
        }
        processor.onRunningChange = { [weak self] running in
            Task { @MainActor in self?.isRunning = running }
        }
        processor.onSchedule = { [weak self] next in
            Task { @MainActor in self?.nextRuns = next }
        }
    }

    /// The rules' folders, each once, in list order.
    var folders: [String] {
        var seen = Set<String>()
        return config.rules.map(\.folderPath).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Whether Run Now has anything to do.
    var hasUsableRules: Bool { config.rules.contains(where: \.isUsable) }

    /// Whether some rule runs by itself right now (watching a folder, or on a schedule).
    var isAutomatic: Bool { config.rules.contains { $0.isUsable && $0.trigger.isAutomatic } }

    /// "Watching for changes; next scheduled run 09:00".
    var automationSummary: String {
        let usable = config.rules.filter(\.isUsable)
        let watches = usable.contains { $0.trigger == .changes }
        let schedules = usable.contains { $0.trigger == .schedule }
        if !watches && !schedules { return "Every rule waits for Run Now" }
        var parts: [String] = []
        if watches { parts.append("watching for changes") }
        if schedules, let next = nextRuns.values.min() { parts.append("next scheduled run \(Schedule.whenText(next))") }
        let text = parts.joined(separator: "; ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    func start() {
        problem = missingFolderProblem()
        processor.start(with: config)
    }

    func stop() { processor.stop() }

    func runNow() { processor.runNow() }

    func preview() async -> RunReport {
        await withCheckedContinuation { continuation in
            processor.preview { continuation.resume(returning: $0) }
        }
    }

    func clearActivity() { activity = [] }

    func open(folder path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Asks for a folder. For a rule's own folder (`toLookIn`), the whole disk is refused and the home folder
    /// needs a second yes, since every file inside would be handled.
    static func chooseFolder(message: String, startingAt start: String?, toLookIn: Bool) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = message
        if let start, !start.isEmpty { panel.directoryURL = URL(fileURLWithPath: start) }
        guard panel.runModal() == .OK, let path = panel.url?.path else { return nil }
        guard toLookIn else { return path }
        if path == "/" {
            let alert = NSAlert()
            alert.messageText = "The whole disk can't be a rule's folder."
            alert.informativeText = "Choose a folder inside it instead."
            alert.runModal()
            return nil
        }
        if path == NSHomeDirectory() {
            let confirm = NSAlert()
            confirm.messageText = "Use your whole home folder?"
            confirm.informativeText = "Every file in it, and in every folder inside it, would be checked against this rule. A smaller folder is usually safer."
            confirm.addButton(withTitle: "Use Home Folder")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return nil }
        }
        return path
    }

    /// A rule that's turned on whose folder is missing.
    private func missingFolderProblem() -> String? {
        for rule in config.rules where rule.enabled && !rule.folderPath.isEmpty {
            if Paths.canonical(rule.folderPath) == nil { return "The folder “\(rule.folderName)” can't be found" }
        }
        return nil
    }

    // MARK: Private

    private func configDidChange(from old: Config) {
        guard config != old else { return }
        ConfigStore.save(config)
        processor.update(config, previous: old)
        problem = missingFolderProblem()
    }

    private func receive(_ report: RunReport, trigger: Processor.Trigger) {
        if !report.problems.isEmpty {
            problem = report.problems.first
        } else if trigger != .watch || !report.records.isEmpty {
            problem = nil
        }
        if !report.records.isEmpty {
            activity.insert(contentsOf: report.records.reversed(), at: 0)
            if activity.count > 1000 { activity.removeLast(activity.count - 1000) }
            log.append(report.records)
        }
        if trigger != .watch || !report.records.isEmpty || !report.problems.isEmpty {
            lastRun = LastRun(date: Date(), summary: report.summary)
        }
    }
}

/// Every action is appended to a tab-separated log, so there's a record of what moved where:
/// ~/Library/Logs/Foliarium/activity.log (next to the config when it's in a custom place).
final class ActivityLog {
    let url: URL = {
        if ConfigStore.usesCustomPath { return ConfigStore.directory.appendingPathComponent("activity.log") }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Logs/Foliarium/activity.log")
    }()

    private static let maxSize = 5_000_000

    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()

    func append(_ records: [ActionRecord]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > Self.maxSize {
            let old = url.deletingPathExtension().appendingPathExtension("1.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let text = records.map(line).joined()
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    func loadRecent(limit: Int) -> [ActionRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n").suffix(limit)
        return lines.reversed().compactMap { parse(String($0)) }
    }

    private func line(_ record: ActionRecord) -> String {
        let status: String
        var message = ""
        switch record.status {
        case .done: status = "done"
        case .planned: status = "planned"
        case .failed(let text): status = "failed"; message = text
        }
        let fields = [dateFormatter.string(from: record.date), record.kind.rawValue, status,
                      record.source, record.destination ?? "", message]
        return fields.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: "\t") + "\n"
    }

    private func parse(_ line: String) -> ActionRecord? {
        let fields = line.components(separatedBy: "\t")
        guard fields.count >= 6, let date = dateFormatter.date(from: fields[0]),
              let kind = ActionKind(rawValue: fields[1]) else { return nil }
        let status: ActionRecord.Status
        switch fields[2] {
        case "done": status = .done
        case "planned": status = .planned
        default: status = .failed(fields[5])
        }
        return ActionRecord(date: date, kind: kind, source: fields[3],
                            destination: fields[4].isEmpty ? nil : fields[4], status: status)
    }
}
