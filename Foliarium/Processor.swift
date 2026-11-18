import CoreServices
import Foundation

/// Runs the engine on a background queue, for Run Now, Preview and the folder watchers. Everything in here
/// happens on `queue`, one run at a time.
final class Processor {
    enum Trigger { case manual, watch, schedule }

    /// A file must have been left alone this long before an automatic run touches it, so files that are
    /// still being copied or downloaded aren't moved halfway through.
    static let settleTime: TimeInterval = 3

    let queue = DispatchQueue(label: "com.semicolonc.foliarium.processor", qos: .utility)
    /// Called on `queue`.
    var onReport: ((RunReport, Trigger) -> Void)?
    /// Called on `queue`.
    var onRunningChange: ((Bool) -> Void)?
    /// When each scheduled rule runs next. Called on `queue`.
    var onSchedule: (([UUID: Date]) -> Void)?
    /// How originals are moved to the Trash. Tests swap in a stand-in.
    var trash: Engine.Trash = Engine.systemTrash

    private var config = Config()
    /// One watcher per watched folder (real path).
    private var watchers: [String: FolderWatcher] = [:]
    /// The last event handled in each watched folder, saved so the next launch can catch up.
    private var eventIDs: [String: UInt64] = [:]
    private var retryPaths = Set<String>()
    private var retryScheduled = false
    /// When each scheduled rule last ran (or was set up), saved so a run missed while Foliarium was quit or the
    /// Mac was asleep happens once at the next chance.
    private var lastRuns: [UUID: Date] = [:]
    private var scheduleTimer: DispatchSourceTimer?

    /// At launch: pick up each watched folder from where the last session stopped.
    func start(with config: Config) {
        queue.async {
            self.config = config
            self.eventIDs = WatchState.load()
            self.updateWatchers(resume: true)
            self.lastRuns = ScheduleState.load()
            self.updateSchedules()
            self.runDueSchedules()
            self.makeFolders(self.folderRules)
        }
    }

    func update(_ config: Config, previous: Config) {
        queue.async {
            self.config = config
            self.updateWatchers(resume: false)
            self.updateSchedules()
            self.makeFolders(self.folderRules.filter { !previous.rules.contains($0) })
        }
    }

    /// "Create a folder" rules that run when files change: their folders are made straight away (at launch, and
    /// when a rule is added or changed), not only once something in the folder changes.
    private var folderRules: [Rule] {
        watchRules.filter { $0.action == .createFolder }
    }

    private func makeFolders(_ rules: [Rule]) {
        if !rules.isEmpty { run(nil, rules: rules, trigger: .watch) }
    }

    func runNow() {
        queue.async { self.run(nil, rules: self.config.rules, trigger: .manual) }
    }

    /// What Run Now would do.
    func preview(_ completion: @escaping (RunReport) -> Void) {
        queue.async { completion(Engine(rules: self.config.rules, dryRun: true).run()) }
    }

    func stop() {
        queue.sync {
            for watcher in watchers.values { watcher.stop() }
            watchers = [:]
            scheduleTimer?.cancel()
            scheduleTimer = nil
        }
    }

    // MARK: Watching

    /// The rules that run when files change.
    private var watchRules: [Rule] {
        config.rules.filter { $0.isUsable && $0.trigger == .changes }
    }

    /// Starts watching folders that gained a "when files change" rule and stops watching ones that lost it.
    /// Folders already being watched carry on. A newly watched folder starts from now: files already in it
    /// wait for Run Now. At launch, folders pick up from their saved event instead.
    private func updateWatchers(resume: Bool) {
        // FSEvents watches a whole tree, so a folder inside another watched folder needs no watcher of its own.
        let folders = Set(watchRules.compactMap { Paths.canonical($0.folderPath) })
        let wanted = folders.filter { folder in !folders.contains { $0 != folder && Paths.isInside(folder, $0) } }
        for (root, watcher) in watchers where !wanted.contains(root) {
            watcher.stop()
            watchers[root] = nil
        }
        var problems: [String] = []
        for root in wanted.sorted() where watchers[root] == nil {
            var since = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
            if resume, let saved = eventIDs[root] {
                since = saved
            } else {
                eventIDs[root] = FSEventsGetCurrentEventId()
            }
            let watcher = FolderWatcher(queue: queue) { [weak self] batch in self?.handle(batch, root: root) }
            if watcher.start(path: root, since: since) {
                watchers[root] = watcher
            } else {
                problems.append("“\((root as NSString).lastPathComponent)” can't be watched")
            }
        }
        eventIDs = eventIDs.filter { watchers[$0.key] != nil }
        WatchState.save(eventIDs)
        if !problems.isEmpty { onReport?(RunReport(problems: problems), .watch) }
    }

    private func handle(_ batch: FSEventBatch, root: String) {
        guard watchers[root] != nil else { return }
        if batch.lastEventID > 0 {
            eventIDs[root] = batch.lastEventID
            WatchState.save(eventIDs)
        }
        if batch.rootChanged, Paths.canonical(root) != root {
            watchers[root]?.stop()
            watchers[root] = nil
            eventIDs[root] = nil
            WatchState.save(eventIDs)
            onReport?(RunReport(problems: ["The folder “\((root as NSString).lastPathComponent)” was moved or deleted"]), .watch)
            return
        }
        if batch.rescanAll {
            run([ScanItem(path: root, depth: .tree)], rules: watchRules, trigger: .watch)
        } else if !batch.items.isEmpty {
            run(batch.items, rules: watchRules, trigger: .watch)
        }
    }

    private func scheduleRetry(_ paths: [String]) {
        retryPaths.formUnion(paths)
        guard !retryScheduled else { return }
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + Self.settleTime + 0.5) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            let items = self.retryPaths.sorted().map { ScanItem(path: $0, depth: .item) }
            self.retryPaths.removeAll()
            if !self.watchers.isEmpty { self.run(items, rules: self.watchRules, trigger: .watch) }
        }
    }

    // MARK: Schedules

    /// The rules that run on a schedule.
    private var scheduledRules: [Rule] {
        config.rules.filter { $0.isUsable && $0.trigger == .schedule }
    }

    /// Keeps the list of scheduled rules and the timer in step with the config. A rule that has just become
    /// scheduled (new, changed to a schedule, or switched back on) starts counting from
    /// now, so it doesn't run straight away.
    private func updateSchedules() {
        let rules = scheduledRules
        let ids = Set(rules.map(\.id))
        var changed = false
        for rule in rules where lastRuns[rule.id] == nil {
            lastRuns[rule.id] = Date()
            changed = true
        }
        if lastRuns.keys.contains(where: { !ids.contains($0) }) {
            lastRuns = lastRuns.filter { ids.contains($0.key) }
            changed = true
        }
        if changed { ScheduleState.save(lastRuns) }

        if rules.isEmpty {
            scheduleTimer?.cancel()
            scheduleTimer = nil
        } else if scheduleTimer == nil {
            // Wall-clock time, so the timer counts time the Mac spent asleep and fires soon after it wakes.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(wallDeadline: .now() + 30, repeating: 30, leeway: .seconds(5))
            timer.setEventHandler { [weak self] in self?.runDueSchedules() }
            timer.resume()
            scheduleTimer = timer
        }
        publishSchedule()
    }

    private func runDueSchedules() {
        let now = Date()
        let due = scheduledRules.filter { rule in
            guard let last = lastRuns[rule.id] else { return false }
            return rule.schedule.nextRun(after: last) <= now
        }
        guard !due.isEmpty else { return }
        for rule in due { lastRuns[rule.id] = now }
        ScheduleState.save(lastRuns)
        publishSchedule()
        run(nil, rules: due, trigger: .schedule)
    }

    private func publishSchedule() {
        var next: [UUID: Date] = [:]
        for rule in scheduledRules {
            next[rule.id] = rule.schedule.nextRun(after: lastRuns[rule.id] ?? Date())
        }
        onSchedule?(next)
    }

    /// Files a scheduled run found still being written: tried again with the same rules once they've settled,
    /// a few times at most, rather than waiting for the next scheduled time.
    private func retryScheduled(_ paths: [String], ruleIDs: Set<UUID>, attempt: Int) {
        guard attempt < 5 else { return }
        queue.asyncAfter(deadline: .now() + Self.settleTime + 0.5) { [weak self] in
            guard let self else { return }
            let rules = self.scheduledRules.filter { ruleIDs.contains($0.id) }
            guard !rules.isEmpty else { return }
            self.run(paths.map { ScanItem(path: $0, depth: .item) }, rules: rules, trigger: .schedule, attempt: attempt + 1)
        }
    }

    // MARK: Running

    /// Run Now uses every rule that's turned on, watching the rules that run when files change, and a schedule
    /// the rules that are due. Automatic runs leave alone files that changed in the last few seconds.
    private func run(_ items: [ScanItem]?, rules: [Rule], trigger: Trigger, attempt: Int = 0) {
        guard rules.contains(where: \.isUsable) else { return }
        onRunningChange?(true)
        let engine = Engine(rules: rules, dryRun: false, settleTime: trigger == .manual ? 0 : Self.settleTime, trash: trash)
        let report = engine.run(items)
        onRunningChange?(false)
        if !report.deferred.isEmpty {
            switch trigger {
            case .watch: scheduleRetry(report.deferred)
            case .schedule: retryScheduled(report.deferred, ruleIDs: Set(rules.map(\.id)), attempt: attempt)
            case .manual: break
            }
        }
        onReport?(report, trigger)
    }
}

/// When each scheduled rule last ran, saved next to the config.
enum ScheduleState {
    private static var url: URL { ConfigStore.directory.appendingPathComponent("schedule-state.json") }

    static func load() -> [UUID: Date] {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        var result: [UUID: Date] = [:]
        for (key, seconds) in saved {
            if let id = UUID(uuidString: key) { result[id] = Date(timeIntervalSince1970: seconds) }
        }
        return result
    }

    static func save(_ lastRuns: [UUID: Date]) {
        guard !lastRuns.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let saved = Dictionary(uniqueKeysWithValues: lastRuns.map { ($0.key.uuidString, $0.value.timeIntervalSince1970) })
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: ConfigStore.directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// The last FSEvents event ID handled in each watched folder, saved next to the config, so the next launch
/// can catch up on what changed while Foliarium wasn't running.
enum WatchState {
    private struct Saved: Codable {
        var folders: [String: UInt64]
    }

    /// Version 1 watched a single folder.
    private struct SavedV1: Codable {
        var root: String
        var eventID: UInt64
    }

    private static var url: URL { ConfigStore.directory.appendingPathComponent("watch-state.json") }

    static func load() -> [String: UInt64] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        if let saved = try? JSONDecoder().decode(Saved.self, from: data) { return saved.folders }
        if let old = try? JSONDecoder().decode(SavedV1.self, from: data) { return [old.root: old.eventID] }
        return [:]
    }

    static func save(_ folders: [String: UInt64]) {
        guard !folders.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(Saved(folders: folders)) else { return }
        try? FileManager.default.createDirectory(at: ConfigStore.directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
