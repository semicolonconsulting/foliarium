import Foundation
import UniformTypeIdentifiers

enum ActionKind: String {
    case webloc, alias, move, delete, extensionChange, clipping, zip, folder, purge

    var title: String {
        switch self {
        case .webloc: return "Webloc → URL"
        case .alias: return "Alias → Symlink"
        case .move: return "Move"
        case .delete: return "Delete"
        case .extensionChange: return "New extension"
        case .clipping: return "Clipping → Text"
        case .zip: return "Extract .zip"
        case .folder: return "New folder"
        case .purge: return "Deleted from Trash"
        }
    }

    var symbol: String {
        switch self {
        case .webloc: return "link"
        case .alias: return "arrowshape.turn.up.right"
        case .move: return "folder"
        case .delete: return "trash"
        case .extensionChange: return "pencil"
        case .clipping: return "doc.plaintext"
        case .zip: return "doc.zipper"
        case .folder: return "folder.badge.plus"
        case .purge: return "trash.slash"
        }
    }
}

/// One thing Foliarium did (or, in a preview, would do) to one file.
struct ActionRecord: Identifiable, Hashable {
    enum Status: Hashable {
        case done, planned
        case failed(String)
    }

    let id = UUID()
    var date = Date()
    let kind: ActionKind
    /// The file it started from.
    let source: String
    /// The new .url, .txt or renamed file, the symlink's original item, where the file was moved to, or what
    /// came out of a .zip. Nil for a deleted file.
    let destination: String?
    let status: Status

    var failed: Bool {
        if case .failed = status { return true }
        return false
    }
}

/// What to look at: one item, the items directly inside a folder, or a whole folder tree.
struct ScanItem: Hashable {
    enum Depth { case item, children, tree }
    let path: String
    let depth: Depth
}

struct RunReport {
    var records: [ActionRecord] = []
    /// Files that changed moments ago and may still be being written; tried again shortly.
    var deferred: [String] = []
    /// Problems with the folder itself, such as it being missing or unreadable.
    var problems: [String] = []
    var filesChecked = 0

    var summary: String {
        var parts: [String] = []
        let done = records.filter { $0.status == .done }
        let moved = done.filter { $0.kind == .move }.count
        let deleted = done.filter { $0.kind == .delete }.count
        let created = done.filter { $0.kind == .folder }.count
        let purged = done.filter { $0.kind == .purge }.count
        let converted = done.count - moved - deleted - created - purged
        let planned = records.filter { $0.status == .planned }.count
        let failed = records.filter(\.failed).count
        if converted > 0 { parts.append("\(converted) converted") }
        if moved > 0 { parts.append("\(moved) moved") }
        if deleted > 0 { parts.append("\(deleted) deleted") }
        if purged > 0 { parts.append("\(purged) deleted from the Trash") }
        if created > 0 { parts.append(created == 1 ? "1 folder created" : "\(created) folders created") }
        if planned > 0 { parts.append(planned == 1 ? "1 change" : "\(planned) changes") }
        if failed > 0 { parts.append("\(failed) failed") }
        if let problem = problems.first { parts.append(problem) }
        return parts.isEmpty ? "Nothing to do" : parts.joined(separator: ", ")
    }
}

/// Does the work for one run: finds the files in the rules' folders, then takes each file through three steps:
/// a conversion for its type (.webloc, alias, .textClipping, .zip), a change of extension, then the first move
/// or delete rule that matches. So a converted file can be renamed and moved in the same run. A file is handled by the rules whose folder it's in (directly, or in a subfolder when the rule
/// includes subfolders), in the order of the rules list.
/// Not thread-safe: make one per run, on the processor's queue.
final class Engine {
    typealias Trash = (URL) throws -> Void

    /// Moves to the Trash with NSFileManager (Put Back works), like the webloc2url Quick Action.
    static let systemTrash: Trash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    /// Downloads in progress. The browser renames them when they finish, which is a new event.
    static let inProgressExtensions: Set<String> = ["download", "crdownload", "part", "partial", "opdownload"]

    /// A usable rule with its folders resolved to real paths, as FSEvents reports them.
    private struct Resolved {
        let rule: Rule
        let folder: String
        /// Where a move rule moves files to.
        let destination: String?
        /// A move rule's destination when it's inside the rule's own folder. Files anywhere inside it are never
        /// moved again, so subfolders the user organises inside a destination stay as they are.
        let protected: String?
    }

    let dryRun: Bool
    let settleTime: TimeInterval
    private let trash: Trash
    private let fm = FileManager.default
    private let rules: [Resolved]
    /// "Create a folder" rules. They don't look at files, so they're kept apart from `rules`.
    private let folderRules: [Resolved]
    /// "Delete files in Trash" rules. They go through the Trash's own items, so they're kept apart too.
    private let trashRules: [Resolved]
    /// Rule folders that can't be found.
    private let missing: [String]
    private var report = RunReport()
    /// In a dry run, paths already promised to a new file (so two planned files don't get the same name)
    /// and paths a planned move or conversion would free up.
    private var reserved = Set<String>()
    private var vacated = Set<String>()
    private var packageCache: [String: Bool] = [:]

    /// `rules` are the rules this run may use; disabled and incomplete ones are skipped.
    init(rules: [Rule], dryRun: Bool, settleTime: TimeInterval = 0, trash: @escaping Trash = Engine.systemTrash) {
        self.dryRun = dryRun
        self.settleTime = settleTime
        self.trash = trash
        var resolved: [Resolved] = []
        var folderRules: [Resolved] = []
        var trashRules: [Resolved] = []
        var missing: [String] = []
        for rule in rules where rule.isUsable {
            guard let folder = Paths.canonical(rule.folderPath) else {
                let message = "The folder “\(rule.folderName)” can't be found"
                if !missing.contains(message) { missing.append(message) }
                continue
            }
            var destination: String?
            var protected: String?
            if rule.action == .move {
                let expanded = (rule.destinationPath as NSString).expandingTildeInPath
                let resolvedDestination = Paths.canonical(expanded) ?? (expanded as NSString).standardizingPath
                destination = resolvedDestination
                if resolvedDestination != folder, Paths.isInside(resolvedDestination, folder) { protected = resolvedDestination }
            }
            let item = Resolved(rule: rule, folder: folder, destination: destination, protected: protected)
            if rule.action.handlesFiles {
                resolved.append(item)
            } else if rule.action == .emptyTrash {
                trashRules.append(item)
            } else {
                folderRules.append(item)
            }
        }
        self.rules = resolved
        self.folderRules = folderRules
        self.trashRules = trashRules
        self.missing = missing
    }

    /// The folders a full run looks through, and whether to look inside their subfolders. A folder inside
    /// another one that's searched with its subfolders is left out: it's covered already.
    var roots: [(path: String, recursive: Bool)] {
        var folders: [String: Bool] = [:]
        for rule in rules { folders[rule.folder, default: false] = folders[rule.folder, default: false] || rule.rule.includeSubfolders }
        return folders.keys.sorted().compactMap { folder in
            let covered = folders.contains { other, recursive in recursive && other != folder && Paths.isInside(folder, other) }
            return covered ? nil : (folder, folders[folder]!)
        }
    }

    /// Processes the given items, or every rule's folder when `items` is nil.
    func run(_ items: [ScanItem]? = nil) -> RunReport {
        report = RunReport()
        reserved = []
        vacated = []
        for message in missing { noteProblem(message) }
        // A full run makes every rule's folder; a run for changes, the folders of rules where something changed.
        for rule in folderRules where items?.contains(where: { Paths.isInside($0.path, rule.folder) }) ?? true {
            createFolder(rule)
        }
        for rule in trashRules where items?.contains(where: { Paths.isInside($0.path, rule.folder) }) ?? true {
            emptyTrash(rule)
        }
        guard !rules.isEmpty else { return report }

        var files: [String] = []
        var seen = Set<String>()
        func add(_ path: String) {
            if seen.insert(path).inserted, !applicable(path).isEmpty { files.append(path) }
        }

        let scan = items ?? roots.map { ScanItem(path: $0.path, depth: $0.recursive ? .tree : .children) }
        for item in scan {
            let path = item.path
            guard rules.contains(where: { Paths.isInside(path, $0.folder) }) else { continue }
            let url = URL(fileURLWithPath: path)
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { continue }
            let isFolder = values.isDirectory == true && values.isPackage != true
            if !isFolder {
                add(path)
            } else if item.depth == .tree {
                collect(in: url, recursive: true, add)
            } else if item.depth == .children {
                collect(in: url, recursive: false, add)
            }
        }

        report.filesChecked = files.count
        for path in files.sorted() { process(path) }
        return report
    }

    // MARK: Finding files

    private func collect(in folder: URL, recursive: Bool, _ add: (String) -> Void) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: keys, options: options,
                                             errorHandler: { url, error in
            // A strong capture is fine: the enumerator, and this closure with it, only lives for this scan.
            self.noteProblem("Couldn't read “\(Paths.display(url.path))”: \(error.localizedDescription)")
            return true
        }) else { return }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true && values?.isPackage != true { continue }
            add(url.path)
        }
    }

    /// The rules that look at this file, in list order: its folder is the rule's folder, or a folder inside it
    /// when the rule includes subfolders. Hidden files and folders, and the insides of packages, are skipped.
    private func applicable(_ path: String) -> [Resolved] {
        rules.filter { covers($0, path) }
    }

    private func covers(_ rule: Resolved, _ path: String) -> Bool {
        let folder = rule.folder
        guard path != folder, Paths.isInside(path, folder) else { return false }
        let parts = path.dropFirst(folder == "/" ? 1 : folder.count + 1).split(separator: "/")
        if parts.count > 1 && !rule.rule.includeSubfolders { return false }
        if parts.contains(where: { $0.hasPrefix(".") }) { return false }
        var current = folder
        for part in parts.dropLast() {
            current += (current == "/" ? "" : "/") + part
            if isPackage(current) { return false }
        }
        return true
    }

    private func isPackage(_ folder: String) -> Bool {
        if let known = packageCache[folder] { return known }
        let result = (try? URL(fileURLWithPath: folder).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
        packageCache[folder] = result
        return result
    }

    private func noteProblem(_ message: String) {
        if report.problems.count < 20, !report.problems.contains(message) { report.problems.append(message) }
    }

    // MARK: One file

    private func process(_ path: String) {
        let rules = applicable(path)
        guard !rules.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey, .isDirectoryKey, .isHiddenKey,
            .contentModificationDateKey, .attributeModificationDateKey, .contentTypeKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return } // gone already
        if values.isHidden == true { return }
        let ext = url.pathExtension.lowercased()
        if Self.inProgressExtensions.contains(ext) { return }

        if settleTime > 0 {
            // The attribute (inode change) date moves on every write, even when an app keeps the
            // modification date of a file it's copying.
            let changed = max(values.contentModificationDate ?? .distantPast, values.attributeModificationDate ?? .distantPast)
            if Date().timeIntervalSince(changed) < settleTime {
                report.deferred.append(path)
                return
            }
        }

        func wants(_ action: Rule.Action) -> Bool { rules.contains { $0.rule.action == action } }
        var current = path
        let isSymlink = values.isSymbolicLink == true
        let isFile = values.isRegularFile == true

        // 1. A conversion for the file's type. Each one replaces the file (the original goes to the Trash), and
        //    the new file sits in the same folder, so the same rules apply to it.
        if wants(.convertWeblocs), ext == "webloc", isFile {
            guard let made = convertWebloc(path) else { return }
            current = made
        } else if wants(.convertAliases), values.isAliasFile == true, !isSymlink, values.isDirectory != true {
            guard let made = convertAlias(path) else { return }
            current = made
        } else if wants(.convertTextClippings), ext == "textclipping", isFile {
            guard let made = convertTextClipping(path) else { return }
            current = made
        } else if wants(.extractZip), ext == "zip", isFile {
            // What comes out is new to the folder: watching picks it up from there, and Run Now on its next run.
            extractZip(path)
            return
        }
        let fallbackType = current == path ? values.contentType : nil

        // 2. A new extension, from the first rule whose conditions match.
        let currentName = (current as NSString).lastPathComponent
        if let rule = rules.first(where: {
            $0.rule.action == .changeExtension && $0.rule.matches(name: currentName, type: fileType(currentName, fallbackType))
        }) {
            guard let made = changeExtension(current, to: rule.rule.cleanNewExtension) else { return }
            current = made
        }

        // 3. Move or delete: the first rule that matches decides.
        moveOrDelete(current, rules: rules.filter { $0.rule.action == .move || $0.rule.action == .delete },
                     fallbackType: current == path ? fallbackType : nil)
    }

    private func fileType(_ name: String, _ fallback: UTType?) -> UTType? {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? fallback : UTType(filenameExtension: ext) ?? fallback
    }

    // MARK: New extension

    /// Renames "notes.txt" to "notes.md" in the same folder ("notes (1).md" if that's taken). Only the name
    /// changes. Returns the new path.
    private func changeExtension(_ path: String, to newExtension: String) -> String? {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let newName = base + "." + newExtension
        // Already there, or only the case differs (the same file on a case-insensitive disk).
        if newName.lowercased() == name.lowercased() { return path }
        let folder = (path as NSString).deletingLastPathComponent
        let target = uniquePath(in: folder, name: newName)
        if dryRun {
            reserved.insert(target)
            vacated.insert(path)
            record(.extensionChange, path, target, .planned)
            return target
        }
        do {
            try fm.moveItem(atPath: path, toPath: target)
        } catch {
            record(.extensionChange, path, target, .failed(error.localizedDescription))
            return nil
        }
        record(.extensionChange, path, target, .done)
        return target
    }

    // MARK: .textClipping → .txt

    /// The text of a .textClipping (what Finder makes when text is dragged onto the desktop): the plain text in
    /// its property list's "UTI-Data".
    static func readTextClipping(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let items = plist["UTI-Data"] as? [String: Any]
        else { return nil }
        if let text = items["public.utf8-plain-text"] as? String { return text }
        if let raw = items["public.utf8-plain-text"] as? Data, let text = String(data: raw, encoding: .utf8) { return text }
        if let raw = items["public.utf16-plain-text"] as? Data,
           let text = String(data: raw, encoding: .utf16LittleEndian) ?? String(data: raw, encoding: .utf16) {
            return text
        }
        if let text = items["public.plain-text"] as? String { return text }
        return nil
    }

    /// Writes "Name.txt" (UTF-8) next to "Name.textClipping", then moves the clipping to the Trash.
    private func convertTextClipping(_ path: String) -> String? {
        guard let text = Self.readTextClipping(path) else {
            record(.clipping, path, nil, .failed("No text found in the clipping"))
            return nil
        }
        let folder = (path as NSString).deletingLastPathComponent
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let out = uniquePath(in: folder, name: base + ".txt")
        if dryRun {
            reserved.insert(out)
            vacated.insert(path)
            record(.clipping, path, out, .planned)
            return out
        }
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: out), options: .withoutOverwriting)
        } catch {
            record(.clipping, path, out, .failed("Couldn't write the .txt file: \(error.localizedDescription)"))
            return nil
        }
        do {
            try trash(URL(fileURLWithPath: path))
        } catch {
            record(.clipping, path, out, .failed("Wrote the .txt file, but couldn't move the clipping to the Trash"))
            return nil
        }
        record(.clipping, path, out, .done)
        return out
    }

    // MARK: Extract .zip

    /// Extracts "Name.zip" next to itself, like Archive Utility: a single item comes out as it is, several
    /// items go into a folder called "Name". The archive goes to the Trash afterwards. Extraction happens in a
    /// hidden folder first, so a failed or partial extraction leaves nothing behind.
    private func extractZip(_ path: String) {
        let folder = (path as NSString).deletingLastPathComponent
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if dryRun {
            let out = uniquePath(in: folder, name: base)
            reserved.insert(out)
            vacated.insert(path)
            record(.zip, path, out, .planned)
            return
        }
        let temp = (folder as NSString).appendingPathComponent(".\(base).foliarium-\(getpid())")
        try? fm.removeItem(atPath: temp)
        // ditto is macOS's own command-line copier; -x -k extracts a zip archive (with resource forks).
        if let error = Self.runTool("/usr/bin/ditto", ["-x", "-k", path, temp]) {
            try? fm.removeItem(atPath: temp)
            record(.zip, path, nil, .failed("Couldn't extract the archive: \(error)"))
            return
        }
        let items = ((try? fm.contentsOfDirectory(atPath: temp)) ?? [])
            .filter { $0 != "__MACOSX" && $0 != ".DS_Store" }
        guard !items.isEmpty else {
            try? fm.removeItem(atPath: temp)
            record(.zip, path, nil, .failed("The archive is empty"))
            return
        }
        let out: String
        do {
            if items.count == 1 {
                out = uniquePath(in: folder, name: items[0])
                try fm.moveItem(atPath: (temp as NSString).appendingPathComponent(items[0]), toPath: out)
                try? fm.removeItem(atPath: temp)
            } else {
                try? fm.removeItem(atPath: (temp as NSString).appendingPathComponent("__MACOSX"))
                out = uniquePath(in: folder, name: base)
                try fm.moveItem(atPath: temp, toPath: out)
            }
        } catch {
            try? fm.removeItem(atPath: temp)
            record(.zip, path, nil, .failed("Couldn't put the extracted files in place: \(error.localizedDescription)"))
            return
        }
        do {
            try trash(URL(fileURLWithPath: path))
        } catch {
            record(.zip, path, out, .failed("Extracted the archive, but couldn't move the .zip to the Trash"))
            return
        }
        record(.zip, path, out, .done)
    }

    /// Runs a command-line tool and waits for it. Returns its error output when it fails, nil when it succeeds.
    static func runTool(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        let message = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? "\((tool as NSString).lastPathComponent) stopped with code \(process.terminationStatus)" : message
    }

    // MARK: .webloc → .url

    /// Reads the address from a .webloc: the URL key of its property list (XML or binary), or, in an old
    /// .webloc with an empty data fork, the first URL in its resource fork. Same as webloc2url.
    static func readWeblocURL(_ path: String) -> String? {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty,
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let link = plist["URL"] as? String, !link.isEmpty {
            return link
        }
        guard let fork = try? Data(contentsOf: URL(fileURLWithPath: path + "/..namedfork/rsrc")), !fork.isEmpty,
              let text = String(data: fork, encoding: .isoLatin1),
              let match = text.range(of: #"[a-zA-Z][a-zA-Z0-9+.-]*://[^\x00-\x20\x7F]+"#, options: .regularExpression)
        else { return nil }
        // ISO Latin 1 maps bytes one to one, so this gets the original bytes back; most are UTF-8.
        let bytes = text[match].data(using: .isoLatin1) ?? Data()
        return String(data: bytes, encoding: .utf8) ?? String(text[match])
    }

    /// Writes "Name.url" next to "Name.webloc" (never overwriting: "Name (1).url" if taken), then moves the
    /// .webloc to the Trash. Returns the new file's path.
    private func convertWebloc(_ path: String) -> String? {
        guard let link = Self.readWeblocURL(path) else {
            record(.webloc, path, nil, .failed("No web address found in the file"))
            return nil
        }
        let folder = (path as NSString).deletingLastPathComponent
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let out = uniquePath(in: folder, name: base + ".url")
        if dryRun {
            reserved.insert(out)
            vacated.insert(path)
            record(.webloc, path, out, .planned)
            return out
        }
        let clean = link.components(separatedBy: .newlines).joined()
        // The Windows .url format, with CRLF line endings.
        let text = "[InternetShortcut]\r\nURL=\(clean)\r\n"
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: out), options: .withoutOverwriting)
        } catch {
            record(.webloc, path, out, .failed("Couldn't write the .url file: \(error.localizedDescription)"))
            return nil
        }
        // The .url is written first, so if this fails nothing is lost: the folder keeps both.
        do {
            try trash(URL(fileURLWithPath: path))
        } catch {
            record(.webloc, path, out, .failed("Wrote the .url file, but couldn't move the .webloc to the Trash"))
            return nil
        }
        record(.webloc, path, out, .done)
        return out
    }

    // MARK: Alias → symlink

    /// Replaces the alias with a symlink of the same name pointing to the alias's original item (an absolute
    /// path, as in alias2symlink). The symlink is made first under a hidden name, so if anything fails the
    /// alias stays where it was. Returns the symlink's path.
    private func convertAlias(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let target: String
        do {
            target = try URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]).path
        } catch {
            record(.alias, path, nil, .failed("The alias's original item can't be found"))
            return nil
        }
        if dryRun {
            record(.alias, path, target, .planned)
            return path
        }
        let folder = (path as NSString).deletingLastPathComponent
        let temp = (folder as NSString).appendingPathComponent(".\((path as NSString).lastPathComponent).foliarium-\(getpid())")
        try? fm.removeItem(atPath: temp)
        do {
            try fm.createSymbolicLink(atPath: temp, withDestinationPath: target)
        } catch {
            record(.alias, path, target, .failed("Couldn't create the symlink: \(error.localizedDescription)"))
            return nil
        }
        do {
            try trash(url)
        } catch {
            try? fm.removeItem(atPath: temp)
            record(.alias, path, target, .failed("Couldn't move the alias to the Trash"))
            return nil
        }
        guard Darwin.rename(temp, path) == 0 else {
            record(.alias, path, target, .failed("The alias is in the Trash, but the symlink couldn't be renamed from \(temp)"))
            return nil
        }
        record(.alias, path, target, .done)
        return path
    }

    // MARK: Move and delete rules

    private func moveOrDelete(_ path: String, rules: [Resolved], fallbackType: UTType?) {
        guard !rules.isEmpty else { return }
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        // The first matching rule decides, even when the file is already in its folder; later rules
        // never get a look. That keeps two rules from passing a file back and forth.
        guard let match = rules.first(where: { $0.rule.matches(name: name, type: fileType(name, fallbackType)) }) else { return }

        if match.rule.action == .delete {
            if dryRun {
                vacated.insert(path)
                record(.delete, path, nil, .planned)
                return
            }
            do {
                try trash(URL(fileURLWithPath: path))
                record(.delete, path, nil, .done)
            } catch {
                record(.delete, path, nil, .failed("Couldn't move it to the Trash: \(error.localizedDescription)"))
            }
            return
        }

        // Files already inside a move rule's destination (within that rule's folder) stay where they are.
        if rules.contains(where: { $0.protected.map { Paths.isInside(parent, $0) } ?? false }) { return }
        guard let destination = match.destination else { return }
        if parent == destination { return }

        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: destination, isDirectory: &isFolder), isFolder.boolValue else {
            record(.move, path, destination, .failed("The folder to move to can't be found: \(Paths.display(destination))"))
            return
        }
        let target = uniquePath(in: destination, name: match.rule.newName(for: name, date: Date()))
        if dryRun {
            reserved.insert(target)
            vacated.insert(path)
            record(.move, path, target, .planned)
            return
        }
        do {
            try fm.moveItem(atPath: path, toPath: target)
            record(.move, path, target, .done)
        } catch {
            record(.move, path, target, .failed(error.localizedDescription))
        }
    }

    // MARK: Create a folder

    /// Makes the rule's folder inside the rule's own folder, along with any folders on the way. A folder that's
    /// already there is left as it is, quietly.
    private func createFolder(_ rule: Resolved) {
        let name = rule.rule.folderToCreate(date: Date())
        guard !name.isEmpty else { return }
        let path = (rule.folder as NSString).appendingPathComponent(name)
        var isFolder: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isFolder) {
            if !isFolder.boolValue { record(.folder, path, path, .failed("A file with that name is already there")) }
            return
        }
        if dryRun {
            guard reserved.insert(path).inserted else { return }
            record(.folder, path, path, .planned)
            return
        }
        do {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            record(.folder, path, path, .done)
        } catch {
            record(.folder, path, path, .failed(error.localizedDescription))
        }
    }

    // MARK: Delete files in Trash

    /// Deletes for good the items at the top of the Trash that match the rule: files, and folders by their own
    /// name. Nothing outside the Trash is ever touched. Hidden items such as .DS_Store are left alone.
    private func emptyTrash(_ rule: Resolved) {
        let keys: [URLResourceKey] = [.contentTypeKey, .addedToDirectoryDateKey]
        let items: [URL]
        do {
            items = try fm.contentsOfDirectory(at: URL(fileURLWithPath: rule.folder), includingPropertiesForKeys: keys,
                                               options: [.skipsHiddenFiles])
        } catch {
            noteProblem("Foliarium can't read the Trash. Turn on Full Disk Access for it in System Settings → Privacy & Security.")
            return
        }
        let now = Date()
        let minimumAge = TimeInterval(max(rule.rule.minDaysInTrash, 0)) * 86_400
        for url in items.sorted(by: { $0.path < $1.path }) {
            let path = url.path
            guard Paths.isInside(path, rule.folder), path != rule.folder, !vacated.contains(path) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if minimumAge > 0 {
                // Without a date it went in, the item's age is unknown, so it stays.
                guard let added = values?.addedToDirectoryDate, now.timeIntervalSince(added) >= minimumAge else { continue }
            }
            guard rule.rule.matches(name: url.lastPathComponent, type: values?.contentType) else { continue }
            if dryRun {
                vacated.insert(path)
                record(.purge, path, nil, .planned)
                continue
            }
            do {
                try fm.removeItem(at: url)
                vacated.insert(path)
                record(.purge, path, nil, .done)
            } catch {
                record(.purge, path, nil, .failed("Couldn't delete it: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: Helpers

    /// "Name.ext", or "Name (1).ext", "Name (2).ext"… when that's taken. Never overwrites anything.
    private func uniquePath(in folder: String, name: String) -> String {
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var candidate = (folder as NSString).appendingPathComponent(name)
        var n = 1
        while (exists(candidate) && !vacated.contains(candidate)) || reserved.contains(candidate) {
            let numbered = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = (folder as NSString).appendingPathComponent(numbered)
            n += 1
        }
        return candidate
    }

    /// lstat, so a broken symlink counts as taken.
    private func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private func record(_ kind: ActionKind, _ source: String, _ destination: String?, _ status: ActionRecord.Status) {
        report.records.append(ActionRecord(kind: kind, source: source, destination: destination, status: status))
    }
}
