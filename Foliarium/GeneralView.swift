import SwiftUI

struct GeneralView: View {
    @ObservedObject var model: AppModel
    let showRules: () -> Void
    let showActivity: () -> Void
    @State private var openAtLogin = LoginItem.isEnabled
    /// Hidden until Show List is clicked. `-showActivityList YES` starts it open (for screenshots).
    @State private var showList = UserDefaults.standard.bool(forKey: "showActivityList")

    static let recentCount = 10

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open at Login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        if on != LoginItem.isEnabled { openAtLogin = LoginItem.set(on) }
                    }
            }

            // Where, when and what are set for each rule in the Rules tab; this is a summary with a way there.
            Section {
                overviewRow
                if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Rules")
            }

            Section {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.isRunning ? "Running…" : "Last run")
                        Text(lastRunText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Preview…") { Windows.preview.show() }
                        .help("List what Run Now would do, without changing anything")
                    Button("Run Now") { model.runNow() }
                        .help("Go through every file in the folder now")
                }
                .disabled(!model.hasUsableRules)

                // The list stays hidden until Show List is clicked.
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Activity log")
                        Text(activitySummary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(showList ? "Hide List" : "Show List") {
                        withAnimation(.easeInOut(duration: 0.2)) { showList.toggle() }
                    }
                    .disabled(model.activity.isEmpty)
                }
                if showList {
                    ForEach(model.activity.prefix(Self.recentCount)) { record in
                        RecentRow(record: record)
                    }
                    HStack {
                        Text(model.activity.count > Self.recentCount
                             ? "The \(Self.recentCount) most recent of \(model.activity.count). Double-click a file to show it in Finder."
                             : "Double-click a file to show it in Finder.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Show All…", action: showActivity)
                    }
                    // The list opens at the bottom of the form: bring it into view.
                    .background(ScrollIntoViewOnAppear())
                }
            } header: {
                Text("Run")
            }

            #if !APPSTORE
            if Updater.isAvailable { UpdatesSection(updater: .shared) }
            #endif
        }
        .formStyle(.grouped)
        .onAppear { openAtLogin = LoginItem.isEnabled }
    }

    private var activitySummary: String {
        guard let latest = model.activity.first else { return "Nothing converted or moved yet" }
        let count = model.activity.count
        return (count == 1 ? "1 entry" : "\(count) entries") + ", latest \(latest.timeText)"
    }

    private var overviewRow: some View {
        HStack(spacing: 10) {
            Image(systemName: model.config.rules.isEmpty ? "folder.badge.questionmark" : "arrow.triangle.branch")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(rulesTitle)
                    .fontWeight(.medium)
                Text(setupSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(model.config.rules.isEmpty ? "Add Rules…" : "Edit Rules…", action: showRules)
        }
        .padding(.vertical, 2)
    }

    /// "3 rules in 2 folders".
    private var rulesTitle: String {
        let rules = model.config.rules.filter(\.enabled).count
        if model.config.rules.isEmpty { return "No rules yet" }
        let folders = model.folders.count
        return (rules == 1 ? "1 rule" : "\(rules) rules") + " in " + (folders == 1 ? "1 folder" : "\(folders) folders")
    }

    /// "Sync Inbox and Downloads. Watching for changes."
    private var setupSummary: String {
        if model.config.rules.isEmpty { return "A rule says which folder to tidy, when, and what to do with the files." }
        let names = model.folders.map { ($0 as NSString).lastPathComponent }
        let list = names.count <= 2 ? names.joined(separator: " and ") : names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) more"
        let automation = model.automationSummary
        return list.isEmpty ? automation + "." : "\(list). \(automation)."
    }

    private var lastRunText: String {
        guard let last = model.lastRun else { return "Not run yet since Foliarium opened" }
        return "\(last.date.formatted(date: .omitted, time: .shortened)): \(last.summary)"
    }
}

/// One line of the recent activity list: what happened to which file, and when.
private struct RecentRow: View {
    let record: ActionRecord

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: record.kind.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .help(record.kind.title)
            Text((record.source as NSString).lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
                .help(record.source)
            ResultText(record: record)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(record.timeText)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.callout)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { ActionRecord.reveal([record]) }
        .contextMenu {
            Button("Show in Finder") { ActionRecord.reveal([record]) }
        }
    }
}

/// Scrolls the enclosing scroll view so this spot is visible, each time it appears. (ScrollViewReader
/// doesn't reach into a grouped Form on macOS.)
private struct ScrollIntoViewOnAppear: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Marker() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Marker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // Wait for the rows above to be laid out, so the scroll goes all the way down.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, let clip = self.enclosingScrollView?.contentView else { return }
                let rect = self.convert(self.bounds.insetBy(dx: 0, dy: -16), to: clip)
                let visible = clip.bounds
                guard rect.maxY > visible.maxY || rect.minY < visible.minY else { return }
                var origin = visible.origin
                origin.y += clip.isFlipped ? rect.maxY - visible.maxY : rect.minY - visible.minY
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    clip.animator().setBoundsOrigin(clip.constrainBoundsRect(NSRect(origin: origin, size: visible.size)).origin)
                }
                self.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }
    }
}
