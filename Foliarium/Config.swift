import Foundation
import UniformTypeIdentifiers

/// Everything the user sets in the Settings window. Saved as JSON (see ConfigStore).
struct Config: Codable, Equatable {
    /// Checked from top to bottom. Each rule has its own on/off switch; there's no global one.
    var rules: [Rule] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case rules
        // Older versions: a global "watch" switch (ignored now), and version 1's single folder with the actions
        // as switches.
        case watch
        case targetPath, convertAliases, convertWeblocs, moveFiles
    }

    // Every key is optional when decoding, so a config file from an older version still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        let watching = try c.decodeIfPresent(Bool.self, forKey: .watch)
        guard c.contains(.targetPath) || c.contains(.convertAliases) else { return }
        // Version 1: turn the folder and the switches into rules for that folder.
        let folder = try c.decodeIfPresent(String.self, forKey: .targetPath) ?? ""
        let trigger: Rule.Trigger = watching == true ? .changes : .manual
        let moveFiles = try c.decodeIfPresent(Bool.self, forKey: .moveFiles) ?? true
        var converted: [Rule] = []
        for (key, action) in [(CodingKeys.convertAliases, Rule.Action.convertAliases), (.convertWeblocs, .convertWeblocs)] {
            guard try c.decodeIfPresent(Bool.self, forKey: key) ?? true, !folder.isEmpty else { continue }
            var rule = Rule()
            rule.action = action
            converted.append(rule)
        }
        for index in rules.indices where !moveFiles { rules[index].enabled = false }
        rules = converted + rules
        for index in rules.indices where rules[index].folderPath.isEmpty {
            rules[index].folderPath = folder
            rules[index].trigger = trigger
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rules, forKey: .rules)
    }
}

/// One rule: where to look (a folder), when to run, and what to do with the files there.
struct Rule: Codable, Identifiable, Hashable {
    enum Trigger: String, Codable, CaseIterable, Identifiable {
        /// A few seconds after files are added or changed (while automatic rules are on).
        case changes
        /// At the times in `schedule`, on every file in the folder (while automatic rules are on).
        case schedule
        /// Only when the user clicks Run Now.
        case manual

        var id: String { rawValue }

        var title: String {
            switch self {
            case .changes: return "When files are added or changed"
            case .schedule: return "On a schedule"
            case .manual: return "Only when I click Run Now"
            }
        }

        /// Runs without the user clicking Run Now.
        var isAutomatic: Bool { self != .manual }
    }

    enum Action: String, Codable, CaseIterable, Identifiable {
        case move, delete, changeExtension
        case convertAliases, convertWeblocs, convertTextClippings, extractZip

        var id: String { rawValue }

        var title: String {
            switch self {
            case .move: return "Move files"
            case .delete: return "Delete files (to the Trash)"
            case .changeExtension: return "Change the extension"
            case .convertAliases: return "Convert aliases to symlinks"
            case .convertWeblocs: return "Convert .webloc files to .url"
            case .convertTextClippings: return "Convert .textClipping files to .txt"
            case .extractZip: return "Extract .zip archives"
            }
        }

        var symbol: String {
            switch self {
            case .move: return "folder"
            case .delete: return "trash"
            case .changeExtension: return "pencil"
            case .convertAliases: return "arrowshape.turn.up.right"
            case .convertWeblocs: return "link"
            case .convertTextClippings: return "doc.plaintext"
            case .extractZip: return "doc.zipper"
            }
        }

        /// Actions that pick files with Kind, Extensions and File name. The conversions each handle one
        /// kind of file, so they don't.
        var usesConditions: Bool { self == .move || self == .delete || self == .changeExtension }
    }

    var id = UUID()
    var enabled = true

    // Where
    var folderPath = ""
    /// When off, only files directly in the folder are handled.
    var includeSubfolders = true

    // When
    var trigger: Trigger = .changes
    var schedule = Schedule()

    // What
    var action: Action = .move
    /// For moves: which files, and where to. Every condition that's filled in must match.
    var kind: FileKind = .any
    /// Comma- or space-separated, with or without dots: "pdf, png" or ".pdf .png".
    var extensions = ""
    /// Text the name contains, or a pattern with * and ? (for example "Screenshot*").
    var namePattern = ""
    var destinationPath = ""
    /// For "Change the extension": the extension files get, such as "md".
    var newExtension = ""
    /// For moves: the new name, or empty to keep it. `*` is the original name without its extension, and
    /// YYYY, MM and DD are the date of the move. The extension is always kept.
    var renamePattern = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Rule()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath) ?? d.folderPath
        includeSubfolders = try c.decodeIfPresent(Bool.self, forKey: .includeSubfolders) ?? d.includeSubfolders
        trigger = (try? c.decodeIfPresent(Trigger.self, forKey: .trigger)) ?? d.trigger
        schedule = (try? c.decodeIfPresent(Schedule.self, forKey: .schedule)) ?? d.schedule
        action = (try? c.decodeIfPresent(Action.self, forKey: .action)) ?? d.action
        kind = (try? c.decodeIfPresent(FileKind.self, forKey: .kind)) ?? d.kind
        extensions = try c.decodeIfPresent(String.self, forKey: .extensions) ?? d.extensions
        namePattern = try c.decodeIfPresent(String.self, forKey: .namePattern) ?? d.namePattern
        destinationPath = try c.decodeIfPresent(String.self, forKey: .destinationPath) ?? d.destinationPath
        renamePattern = try c.decodeIfPresent(String.self, forKey: .renamePattern) ?? d.renamePattern
        newExtension = try c.decodeIfPresent(String.self, forKey: .newExtension) ?? d.newExtension
    }

    var extensionList: [String] {
        extensions
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map { $0.drop(while: { $0 == "." || $0 == "*" }).lowercased() }
            .filter { !$0.isEmpty }
    }

    private var trimmedPattern: String { namePattern.trimmingCharacters(in: .whitespaces) }

    var hasCondition: Bool { kind != .any || !extensionList.isEmpty || !trimmedPattern.isEmpty }

    /// Why the rule can't be used yet, or nil when it's complete. A move rule with no conditions would
    /// match every file, so at least one is required ("*" in the name field matches everything on purpose).
    var problem: String? {
        if folderPath.isEmpty { return "Choose a folder to look in." }
        if action.usesConditions && !hasCondition { return "Fill in at least one condition." }
        switch action {
        case .move:
            if destinationPath.isEmpty { return "Choose a folder to move files to." }
            if renamePattern.contains("/") || renamePattern.contains(":") { return "The new name can't contain / or :." }
        case .changeExtension:
            if cleanNewExtension.isEmpty { return "Type the new extension." }
            if cleanNewExtension.contains(where: { "/:".contains($0) }) { return "The extension can't contain / or :." }
        default:
            break
        }
        return nil
    }

    /// The new extension without spaces or leading dots: " .md" → "md".
    var cleanNewExtension: String {
        String(newExtension.trimmingCharacters(in: .whitespaces).drop(while: { $0 == "." }))
    }

    private var trimmedRename: String { renamePattern.trimmingCharacters(in: .whitespaces) }

    /// The name a moved file gets: "Picture1.png" with "YYYYMMDD_*" becomes "20261117_Picture1.png". A name
    /// that already has the pattern's shape ("20261105_Scan.png") is kept, so a file never gets two dates.
    func newName(for name: String, date: Date) -> String {
        let pattern = trimmedRename
        guard !pattern.isEmpty else { return name }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        if fnmatch(Self.glob(fromRename: pattern), base.precomposedStringWithCanonicalMapping, 0) == 0 { return name }
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let filled = pattern
            .replacingOccurrences(of: "YYYY", with: String(format: "%04d", parts.year ?? 0))
            .replacingOccurrences(of: "MM", with: String(format: "%02d", parts.month ?? 0))
            .replacingOccurrences(of: "DD", with: String(format: "%02d", parts.day ?? 0))
            .replacingOccurrences(of: "*", with: base)
        let newBase = filled.trimmingCharacters(in: .whitespaces)
        guard !newBase.isEmpty else { return name }
        return ext.isEmpty ? newBase : newBase + "." + ext
    }

    /// "20261117_Picture1.png": what "YYYYMMDD_*" does today, for the editor's help text.
    static var exampleRename: String {
        var rule = Rule()
        rule.renamePattern = "YYYYMMDD_*"
        return rule.newName(for: "Picture1.png", date: Date())
    }

    /// "YYYYMMDD_*" → "[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_*", for spotting names that already fit.
    private static func glob(fromRename pattern: String) -> String {
        var glob = ""
        var rest = Substring(pattern.precomposedStringWithCanonicalMapping)
        while let first = rest.first {
            if rest.hasPrefix("YYYY") {
                glob += String(repeating: "[0-9]", count: 4)
                rest = rest.dropFirst(4)
            } else if rest.hasPrefix("MM") || rest.hasPrefix("DD") {
                glob += "[0-9][0-9]"
                rest = rest.dropFirst(2)
            } else {
                if "[]?\\".contains(first) { glob += "\\" }
                glob.append(first)
                rest = rest.dropFirst()
            }
        }
        return glob
    }

    var isUsable: Bool { enabled && problem == nil }

    func matches(name fileName: String, type: UTType?) -> Bool {
        let name = fileName.precomposedStringWithCanonicalMapping
        if !kind.matches(type) { return false }
        let exts = extensionList
        if !exts.isEmpty {
            let ext = (name as NSString).pathExtension.lowercased()
            if !exts.contains(ext.precomposedStringWithCanonicalMapping) { return false }
        }
        let pattern = trimmedPattern.precomposedStringWithCanonicalMapping
        if !pattern.isEmpty {
            if pattern.contains(where: { "*?[".contains($0) }) {
                if fnmatch(pattern, name, FNM_CASEFOLD) != 0 { return false }
            } else if !name.localizedCaseInsensitiveContains(pattern) {
                return false
            }
        }
        return true
    }

    /// For the When column: "Files change", "Daily 09:00", "Run Now only".
    var whenSummary: String {
        switch trigger {
        case .changes: return "Files change"
        case .schedule: return schedule.summary
        case .manual: return "Run Now only"
        }
    }

    /// The folder's name, for the Where column.
    var folderName: String {
        folderPath.isEmpty ? "No folder" : (folderPath as NSString).lastPathComponent
    }

    /// Which files a move rule picks, like "Image · .png, .jpg · named Screenshot*".
    var conditionSummary: String {
        var parts: [String] = []
        if kind != .any { parts.append(kind.title) }
        let exts = extensionList
        if !exts.isEmpty { parts.append(exts.map { "." + $0 }.joined(separator: ", ")) }
        let pattern = trimmedPattern
        if !pattern.isEmpty {
            parts.append(pattern.contains(where: { "*?[".contains($0) }) ? "named \(pattern)" : "name contains “\(pattern)”")
        }
        return parts.isEmpty ? "No conditions" : parts.joined(separator: " · ")
    }

    /// For the What column: "Move .pdf → Docs" (inside the rule's folder) or "→ ~/Documents/PDFs", or the conversion.
    var actionSummary: String {
        switch action {
        case .move:
            let destination = destinationPath.isEmpty ? "no folder chosen" : Paths.relative(destinationPath, to: folderPath)
            let rename = trimmedRename.isEmpty ? "" : " as \(trimmedRename)"
            return "Move \(conditionSummary) → \(destination)\(rename)"
        case .delete:
            return "Delete \(conditionSummary) (to the Trash)"
        case .changeExtension:
            return "Change \(conditionSummary) to .\(cleanNewExtension.isEmpty ? "?" : cleanNewExtension)"
        default:
            return action.title
        }
    }
}

/// When a scheduled rule runs: every few minutes or hours, every day at a time, or every week on a day at a time.
struct Schedule: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case minutes, hours, daily, weekly

        var id: String { rawValue }

        var title: String {
            switch self {
            case .minutes: return "Every few minutes"
            case .hours: return "Every few hours"
            case .daily: return "Every day"
            case .weekly: return "Every week"
            }
        }
    }

    var kind: Kind = .daily
    /// For minutes and hours: how many.
    var every = 30
    var hour = 9
    var minute = 0
    /// 1 is Sunday, as in Calendar.
    var weekday = 2

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Schedule()
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? d.kind
        every = try c.decodeIfPresent(Int.self, forKey: .every) ?? d.every
        hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? d.hour
        minute = try c.decodeIfPresent(Int.self, forKey: .minute) ?? d.minute
        weekday = try c.decodeIfPresent(Int.self, forKey: .weekday) ?? d.weekday
    }

    /// The allowed counts: up to a day of minutes, up to a week of hours.
    var everyRange: ClosedRange<Int> { kind == .minutes ? 1...1440 : 1...168 }

    private var count: Int { min(max(every, everyRange.lowerBound), everyRange.upperBound) }

    /// The first time after `date` that the rule is due. A run that was missed (asleep, or Foliarium not
    /// running) is due straight away, once: the next one is counted from when it actually ran.
    func nextRun(after date: Date, calendar: Calendar = .current) -> Date {
        let time = DateComponents(hour: min(max(hour, 0), 23), minute: min(max(minute, 0), 59), second: 0)
        switch kind {
        case .minutes:
            return date.addingTimeInterval(Double(count) * 60)
        case .hours:
            return date.addingTimeInterval(Double(count) * 3600)
        case .daily:
            return calendar.nextDate(after: date, matching: time, matchingPolicy: .nextTime)
                ?? date.addingTimeInterval(86_400)
        case .weekly:
            var components = time
            components.weekday = min(max(weekday, 1), 7)
            return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
                ?? date.addingTimeInterval(7 * 86_400)
        }
    }

    /// "09:00" (in the user's time format).
    var timeText: String {
        let date = Calendar.current.date(bySettingHour: min(max(hour, 0), 23), minute: min(max(minute, 0), 59),
                                         second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var weekdayIndex: Int { min(max(weekday, 1), 7) - 1 }

    /// For the When column: "Every 30 min", "Every hour", "Daily 09:00", "Mon 09:00".
    var summary: String {
        switch kind {
        case .minutes: return count == 1 ? "Every minute" : "Every \(count) min"
        case .hours: return count == 1 ? "Every hour" : "Every \(count) hours"
        case .daily: return "Daily \(timeText)"
        case .weekly: return "\(Calendar.current.shortWeekdaySymbols[weekdayIndex]) \(timeText)"
        }
    }

    /// "14:30" today, "tomorrow 09:00", or "Mon 09:00" further out.
    static func whenText(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInTomorrow(date) { return "tomorrow \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }

    /// For intervals: "30 minutes", "an hour", "2 hours".
    var intervalText: String {
        switch kind {
        case .minutes: return count == 1 ? "a minute" : "\(count) minutes"
        case .hours: return count == 1 ? "an hour" : "\(count) hours"
        case .daily: return "a day"
        case .weekly: return "a week"
        }
    }

    /// "Every Monday at 09:00", for tooltips.
    var description: String {
        switch kind {
        case .minutes: return count == 1 ? "Every minute" : "Every \(count) minutes"
        case .hours: return count == 1 ? "Every hour" : "Every \(count) hours"
        case .daily: return "Every day at \(timeText)"
        case .weekly: return "Every \(Calendar.current.weekdaySymbols[weekdayIndex]) at \(timeText)"
        }
    }
}

/// A rough kind of file, judged by the file's type (which comes from its extension).
enum FileKind: String, Codable, CaseIterable, Identifiable {
    case any, image, movie, audio, pdf, document, archive, installer, application

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: return "Any kind"
        case .image: return "Image"
        case .movie: return "Movie"
        case .audio: return "Audio"
        case .pdf: return "PDF"
        case .document: return "Document"
        case .archive: return "Archive"
        case .installer: return "Disk image or installer"
        case .application: return "Application"
        }
    }

    private static let documentTypes: [UTType] = [.text, .rtf, .rtfd, .pdf, .spreadsheet, .presentation] + [
        "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
        "org.oasis-open.opendocument.text", "com.apple.iwork.pages.sffpages", "com.apple.iwork.pages.pages",
    ].compactMap { UTType($0) }

    private static let installerTypes: [UTType] = [.diskImage] + [
        "com.apple.installer-package-archive", "com.apple.installer-package",
    ].compactMap { UTType($0) }

    func matches(_ type: UTType?) -> Bool {
        if self == .any { return true }
        guard let type else { return false }
        let targets: [UTType]
        switch self {
        case .any: return true
        case .image: targets = [.image]
        case .movie: targets = [.movie]
        case .audio: targets = [.audio]
        case .pdf: targets = [.pdf]
        case .document: targets = Self.documentTypes
        case .archive:
            // Disk images and installer packages count as archives to macOS; here they have their own kind.
            return type.conforms(to: .archive) && !Self.installerTypes.contains { type.conforms(to: $0) }
        case .installer: targets = Self.installerTypes
        case .application: targets = [.application, .applicationBundle]
        }
        return targets.contains { type.conforms(to: $0) }
    }
}

/// Where the config lives: ~/Library/Application Support/Foliarium/config.json.
/// Launch with `-configPath /some/file.json` to use another file (handy for testing); the
/// activity log and watch state then live next to it too.
enum ConfigStore {
    static var url: URL {
        if let custom = UserDefaults.standard.string(forKey: "configPath"), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Foliarium/config.json")
    }

    static var directory: URL { url.deletingLastPathComponent() }

    /// The app used to be called Foldertidy. The first time Foliarium runs, it moves the old settings folder
    /// (rules, watch and schedule state) and log folder to the new names, so nothing is lost.
    static func moveSettingsFromFoldertidy() {
        guard !usesCustomPath else { return }
        let fm = FileManager.default
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        for parent in ["Application Support", "Logs"] {
            let old = library.appendingPathComponent("\(parent)/Foldertidy")
            let new = library.appendingPathComponent("\(parent)/Foliarium")
            guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { continue }
            do {
                try fm.moveItem(at: old, to: new)
            } catch {
                NSLog("Foliarium: couldn't move \(old.path) to \(new.path): \(error)")
            }
        }
    }

    static var usesCustomPath: Bool {
        !(UserDefaults.standard.string(forKey: "configPath") ?? "").isEmpty
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: url) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            // Keep the unreadable file instead of overwriting it with defaults on the next save.
            let backup = url.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            NSLog("Foliarium: couldn't read \(url.path) (\(error)); copied it to \(backup.lastPathComponent)")
            return Config()
        }
    }

    static func save(_ config: Config) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(config).write(to: url, options: .atomic)
        } catch {
            NSLog("Foliarium: couldn't save \(url.path): \(error)")
        }
    }
}

enum Paths {
    /// The real path, with symlinks resolved (/tmp → /private/tmp), as FSEvents reports it.
    /// Nil when nothing exists there.
    static func canonical(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard let resolved = realpath(expanded, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether `path` is `folder` or anything inside it.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        if folder == "/" { return path.hasPrefix("/") }
        return path == folder || path.hasPrefix(folder + "/")
    }

    /// The path with the home folder shown as ~.
    static func display(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// The path relative to `root` when it's inside it, otherwise the display path.
    static func relative(_ path: String, to root: String?) -> String {
        guard let root, path.hasPrefix(root + "/") else { return display(path) }
        return String(path.dropFirst(root.count + 1))
    }
}
