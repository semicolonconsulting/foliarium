import SwiftUI

struct ActivityView: View {
    @ObservedObject var model: AppModel
    @State private var selection = Set<ActionRecord.ID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.activity.isEmpty {
                ContentUnavailableView {
                    Label("No Activity Yet", systemImage: "clock")
                } description: {
                    Text("Files that Foliarium converts or moves are listed here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RecordTable(records: model.activity, compact: true, selection: $selection)
            }
            HStack {
                Button("Show Log File") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.log.url])
                }
                .disabled(!FileManager.default.fileExists(atPath: model.log.url.path))
                Spacer()
                Button("Clear List") {
                    selection = []
                    model.clearActivity()
                }
                .disabled(model.activity.isEmpty)
            }
        }
        .padding(20)
    }
}

struct PreviewView: View {
    @ObservedObject var model: AppModel
    @State private var report: RunReport?
    @State private var loading = false
    @State private var selection = Set<ActionRecord.ID>()

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Refresh") { model.previewRequest += 1 }
                    .disabled(loading)
                Button("Run Now") {
                    model.runNow()
                    model.previewRequest += 1
                }
                .keyboardShortcut(.defaultAction)
                .disabled(loading || plannedCount == 0)
            }
            .padding(16)
            Divider()
            Group {
                if loading && report == nil {
                    ProgressView("Looking through the folder…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let report, !report.records.isEmpty {
                    RecordTable(records: report.records, compact: false, selection: $selection)
                        .padding(12)
                } else {
                    ContentUnavailableView {
                        Label("Nothing to Do", systemImage: "checkmark.circle")
                    } description: {
                        Text(model.config.rules.isEmpty
                             ? "Add a rule in Settings first."
                             : "No file in the rules' folders needs converting or moving.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: model.previewRequest) {
            loading = true
            report = await model.preview()
            loading = false
        }
    }

    private var plannedCount: Int { report?.records.filter { $0.status == .planned }.count ?? 0 }

    private var title: String {
        if loading { return "Looking…" }
        guard let report else { return "Preview" }
        let planned = plannedCount
        let failed = report.records.count - planned
        var text = planned == 1 ? "1 change" : "\(planned) changes"
        if failed > 0 { text += ", \(failed) can't be done" }
        return text
    }

    private var subtitle: String {
        var text = "Nothing changes until you click Run Now."
        if let report {
            let folders = model.folders.count
            text = "\(report.filesChecked) files checked in " + (folders == 1 ? "1 folder" : "\(folders) folders") + ". " + text
            if let problem = report.problems.first { text = problem + ". " + text }
        }
        return text
    }
}

/// The table of actions used by Activity and Preview.
struct RecordTable: View {
    let records: [ActionRecord]
    /// For the narrower Activity tab: a time column, and file names instead of paths.
    let compact: Bool
    @Binding var selection: Set<ActionRecord.ID>

    var body: some View {
        Table(records, selection: $selection) {
            TableColumn("Time") { record in
                Text(record.timeText)
                    .foregroundStyle(.secondary)
            }
            .width(min: 0, ideal: compact ? 78 : 0, max: compact ? 120 : 0)
            TableColumn("Action") { record in
                Label(record.kind.title, systemImage: record.kind.symbol)
                    .lineLimit(1)
            }
            .width(min: 110, ideal: 128, max: 160)
            TableColumn("File") { record in
                Text(compact ? (record.source as NSString).lastPathComponent : Paths.display(record.source))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(record.source)
            }
            TableColumn("Result") { record in
                ResultText(record: record)
            }
        }
        .contextMenu(forSelectionType: ActionRecord.ID.self) { ids in
            Button("Show in Finder") { ActionRecord.reveal(records.filter { ids.contains($0.id) }) }
                .disabled(ids.isEmpty)
        } primaryAction: { ids in
            ActionRecord.reveal(records.filter { ids.contains($0.id) })
        }
    }
}

extension ActionRecord {
    /// "14:45" today, "Nov 17, 14:45" before that.
    var timeText: String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// Where the file is now: the new or moved file after a successful run, otherwise the original. (An
    /// alias's destination is the item the symlink points to, so the symlink itself is at the source.)
    var currentPath: String {
        guard status == .done, kind != .alias, kind != .delete else { return source }
        return destination ?? source
    }

    /// Shows the files in Finder, skipping any that are gone by now.
    static func reveal(_ records: [ActionRecord]) {
        let fm = FileManager.default
        let urls = records.map(\.currentPath)
            .filter { fm.fileExists(atPath: $0) || (try? fm.destinationOfSymbolicLink(atPath: $0)) != nil }
            .map { URL(fileURLWithPath: $0) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
}

struct ResultText: View {
    let record: ActionRecord

    var body: some View {
        switch record.status {
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(1)
                .help(message)
        case .done, .planned:
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(record.destination ?? "")
        }
    }

    private var text: String {
        if record.kind == .delete { return "→ Trash" }
        if record.kind == .folder { return "Created" }
        guard let destination = record.destination else { return "" }
        switch record.kind {
        case .webloc, .extensionChange, .clipping, .zip, .delete, .folder: return "→ " + (destination as NSString).lastPathComponent
        case .alias: return "→ symlink to " + Paths.display(destination)
        // Shown from the file's own folder: "→ Docs/report.pdf", or the full path when it went elsewhere.
        case .move: return "→ " + Paths.relative(destination, to: (record.source as NSString).deletingLastPathComponent)
        }
    }
}
