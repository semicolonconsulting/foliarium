import SwiftUI

/// The Rules tab: one row per rule, saying where it looks, when it runs and what it does.
struct RulesView: View {
    @ObservedObject var model: AppModel
    @State private var selection: Rule.ID?
    @State private var editing: Draft?

    /// A copy of a rule being edited in the sheet. Changes are only saved on Save, so a half-made rule
    /// never touches anything.
    struct Draft: Identifiable {
        var rule: Rule
        let isNew: Bool
        var id: UUID { rule.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rules are checked from top to bottom, and the first move or delete rule that matches a file decides what happens to it. Files already inside a rule's destination folder stay where they are. Use a rule's switch to turn it off.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            table

            HStack(spacing: 8) {
                // The same frame for both symbols: the minus glyph is shorter, which made its button shorter.
                Button(action: add) { Image(systemName: "plus").frame(width: 16, height: 16) }
                    .help("Add a rule")
                Button { if let selection { delete(selection) } } label: { Image(systemName: "minus").frame(width: 16, height: 16) }
                    .help("Delete the selected rule")
                    .disabled(selection == nil)
                Text("Double-click a rule to edit it. Right-click to move it up or down.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                Spacer()
                Button("Edit…") { if let selection { edit(selection) } }
                    .disabled(selection == nil)
            }
        }
        .padding(20)
        .onAppear {
            // `-editRule first` opens the editor at launch (for screenshots).
            if UserDefaults.standard.string(forKey: "editRule") == "first", let first = model.config.rules.first {
                edit(first.id)
            }
        }
        .sheet(item: $editing) { draft in
            RuleEditor(draft: draft.rule, isNew: draft.isNew,
                       onDelete: draft.isNew ? nil : { delete(draft.id) }) { saved in
                if let index = model.config.rules.firstIndex(where: { $0.id == saved.id }) {
                    model.config.rules[index] = saved
                } else {
                    model.config.rules.append(saved)
                }
                selection = saved.id
            }
        }
    }

    private var table: some View {
        Table(of: Rule.self, selection: $selection) {
            TableColumn("Automation") { rule in
                Toggle("Turned on", isOn: enabledBinding(rule.id))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    // Smaller than the smallest control size, so the switch doesn't crowd the row.
                    .scaleEffect(0.8)
                    .tint(.green)
                    .labelsHidden()
                    .help(rule.enabled ? "On: turn this rule off" : "Off: turn this rule on")
                    .frame(maxWidth: .infinity)
            }
            .width(70)
            TableColumn("Status") { rule in
                StatusCell(rule: rule, nextRun: model.nextRuns[rule.id])
            }
            .width(min: 80, ideal: 87, max: 130)
            TableColumn("Where") { rule in
                WhereCell(rule: rule)
                    .opacity(rule.enabled ? 1 : 0.5)
            }
            .width(min: 90, ideal: 180, max: 180)
            TableColumn("When") { rule in
                Text(rule.whenSummary)
                    .lineLimit(1)
                    .help(whenHelp(rule))
                    .opacity(rule.enabled ? 1 : 0.5)
            }
            .width(min: 90, ideal: 125, max: 125)
            TableColumn("What") { rule in
                WhatCell(rule: rule)
                    .opacity(rule.enabled ? 1 : 0.5)
            }
        } rows: {
            ForEach(model.config.rules) { rule in
                TableRow(rule)
                    .draggable(rule.id.uuidString)
            }
            .dropDestination(for: String.self) { index, ids in
                move(ids, to: index)
            }
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .overlay {
            if model.config.rules.isEmpty {
                ContentUnavailableView {
                    Label("No Rules", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("Add a rule to tidy a folder, for example to move every PDF in Downloads into Documents.")
                } actions: {
                    Button("Add Rule…", action: add)
                }
            }
        }
        .contextMenu(forSelectionType: Rule.ID.self) { ids in
            if let id = ids.first { ruleMenu(id) }
        } primaryAction: { ids in
            if let id = ids.first { edit(id) }
        }
        .onDeleteCommand { if let selection { delete(selection) } }
    }

    @ViewBuilder
    private func ruleMenu(_ id: Rule.ID) -> some View {
        let rules = model.config.rules
        let index = rules.firstIndex { $0.id == id }
        Button("Edit…") { edit(id) }
        Button("Duplicate") { duplicate(id) }
        Divider()
        Button("Move Up") { step(id, by: -1) }
            .disabled(index == nil || index == 0)
        Button("Move Down") { step(id, by: 1) }
            .disabled(index == nil || index == rules.count - 1)
        Divider()
        Button("Delete") { delete(id) }
    }

    private func whenHelp(_ rule: Rule) -> String {
        switch rule.trigger {
        case .schedule:
            guard let next = model.nextRuns[rule.id] else { return rule.schedule.description }
            return "\(rule.schedule.description). Next run: \(Schedule.whenText(next))"
        default:
            return rule.trigger.title
        }
    }

    private func enabledBinding(_ id: Rule.ID) -> Binding<Bool> {
        Binding {
            model.config.rules.first { $0.id == id }?.enabled ?? false
        } set: { on in
            if let index = model.config.rules.firstIndex(where: { $0.id == id }) { model.config.rules[index].enabled = on }
        }
    }

    /// A new rule starts in the same folder, with the same timing, as the selected (or last) rule.
    private func add() {
        var rule = Rule()
        if let base = model.config.rules.first(where: { $0.id == selection }) ?? model.config.rules.last {
            // A Trash rule's folder is the Trash, which a new rule shouldn't start in.
            if base.action != .emptyTrash { rule.folderPath = base.folderPath }
            rule.includeSubfolders = base.includeSubfolders
            rule.trigger = base.trigger
        }
        editing = Draft(rule: rule, isNew: true)
    }

    private func edit(_ id: Rule.ID) {
        guard let rule = model.config.rules.first(where: { $0.id == id }) else { return }
        editing = Draft(rule: rule, isNew: false)
    }

    private func duplicate(_ id: Rule.ID) {
        guard let index = model.config.rules.firstIndex(where: { $0.id == id }) else { return }
        var copy = model.config.rules[index]
        copy.id = UUID()
        model.config.rules.insert(copy, at: index + 1)
        selection = copy.id
    }

    private func step(_ id: Rule.ID, by offset: Int) {
        guard let index = model.config.rules.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard model.config.rules.indices.contains(target) else { return }
        model.config.rules.swapAt(index, target)
    }

    /// Rows dropped at `index`. Only this table's own rows count; other dragged text is ignored.
    private func move(_ ids: [String], to index: Int) {
        let moving = Set(ids.compactMap(UUID.init(uuidString:)))
        let offsets = IndexSet(model.config.rules.indices.filter { moving.contains(model.config.rules[$0].id) })
        guard !offsets.isEmpty else { return }
        model.config.rules.move(fromOffsets: offsets, toOffset: min(index, model.config.rules.count))
    }

    private func delete(_ id: Rule.ID) {
        model.config.rules.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }
}

/// The Status column: a coloured dot and a word for what the rule is doing. Green while it runs by itself,
/// orange when something needs fixing, grey when it's off or waits for Run Now.
private struct StatusCell: View {
    let rule: Rule
    let nextRun: Date?

    private var state: (text: String, color: Color, help: String) {
        if !rule.enabled { return ("Off", .secondary, "Turned off: this rule doesn't run, not even with Run Now") }
        if !rule.folderPath.isEmpty && Paths.canonical(rule.folderPath) == nil {
            return ("Folder missing", .orange, "The folder “\(rule.folderName)” can't be found")
        }
        if let problem = rule.problem { return ("Needs setup", .orange, problem) }
        switch rule.trigger {
        case .changes:
            return ("Running", .green, "Watching for files added or changed")
        case .schedule:
            let next = nextRun.map { ". Next run: \(Schedule.whenText($0))" } ?? ""
            return ("Running", .green, "\(rule.schedule.description)\(next)")
        case .manual:
            return ("Manual", .secondary, "Runs only when you click Run Now")
        }
    }

    var body: some View {
        let state = state
        HStack(spacing: 6) {
            Circle()
                .fill(state.color)
                .frame(width: 8, height: 8)
            Text(state.text)
                .lineLimit(1)
                .foregroundStyle(rule.enabled ? .primary : .secondary)
        }
        .help(state.help)
        .accessibilityElement(children: .combine)
    }
}

private struct WhereCell: View {
    let rule: Rule

    private var missing: Bool { !rule.folderPath.isEmpty && Paths.canonical(rule.folderPath) == nil }

    var body: some View {
        HStack(spacing: 6) {
            if rule.folderPath.isEmpty || missing {
                Image(systemName: "folder.badge.questionmark")
                    .foregroundStyle(missing ? .orange : .secondary)
                    .frame(width: 16)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: rule.folderPath))
                    .resizable()
                    .frame(width: 16, height: 16)
            }
            Text(rule.folderName)
                .lineLimit(1)
                .truncationMode(.middle)
            if rule.action.handlesFiles && !rule.includeSubfolders {
                Text("top level")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help(help)
    }

    private var help: String {
        if rule.folderPath.isEmpty { return "No folder chosen" }
        let path = Paths.display(rule.folderPath)
        if missing { return "\(path) can't be found" }
        if !rule.action.handlesFiles { return path }
        return rule.includeSubfolders ? "\(path) and the folders inside it" : "\(path), without the folders inside it"
    }
}

private struct WhatCell: View {
    let rule: Rule

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: rule.action.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(rule.actionSummary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(rule.actionSummary)
            Spacer(minLength: 4)
            if let problem = rule.problem {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(problem)
            }
        }
    }
}

/// The sheet for adding or changing a rule: Where, When and What.
struct RuleEditor: View {
    @State var draft: Rule
    let isNew: Bool
    /// Deletes the rule being edited. Nil for a new rule.
    let onDelete: (() -> Void)?
    let onSave: (Rule) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if draft.action == .emptyTrash {
                        LabeledContent("Folder") {
                            Label("Trash", systemImage: "trash")
                        }
                    } else {
                        LabeledContent("Folder") {
                            folderButton(draft.folderPath, empty: "No folder chosen") {
                                AppModel.chooseFolder(message: "Choose the folder this rule looks in.",
                                                      startingAt: draft.folderPath, toLookIn: true)
                            } set: { draft.folderPath = $0 }
                        }
                    }
                    if draft.action.handlesFiles {
                        Toggle("Also look in subfolders", isOn: $draft.includeSubfolders)
                    }
                } header: {
                    Text("Where")
                } footer: {
                    Text(draft.action == .emptyTrash
                         ? "Only items already in your Trash are deleted. Foliarium needs Full Disk Access to read the Trash: turn it on in System Settings → Privacy & Security → Full Disk Access."
                         : draft.action.handlesFiles ? "Hidden files and the contents of apps are left alone."
                                                     : "The new folder is made inside this folder.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Run", selection: $draft.trigger) {
                        ForEach(Rule.Trigger.allCases) { trigger in
                            Text(trigger.title).tag(trigger)
                        }
                    }
                    if draft.trigger == .schedule {
                        Picker("Repeat", selection: $draft.schedule.kind) {
                            ForEach(Schedule.Kind.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        .onChange(of: draft.schedule.kind) { _, kind in
                            if kind == .minutes { draft.schedule.every = 30 }
                            if kind == .hours { draft.schedule.every = 1 }
                        }
                        switch draft.schedule.kind {
                        case .minutes, .hours:
                            LabeledContent("Every") {
                                HStack(spacing: 6) {
                                    TextField("Every", value: $draft.schedule.every, format: .number)
                                        .labelsHidden()
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 56)
                                    Stepper("Every", value: $draft.schedule.every, in: draft.schedule.everyRange)
                                        .labelsHidden()
                                    Text(draft.schedule.kind == .minutes ? "minutes" : "hours")
                                }
                            }
                        case .daily:
                            DatePicker("At", selection: timeBinding, displayedComponents: .hourAndMinute)
                        case .weekly:
                            Picker("On", selection: $draft.schedule.weekday) {
                                ForEach(Self.weekdays, id: \.self) { day in
                                    Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                                }
                            }
                            DatePicker("At", selection: timeBinding, displayedComponents: .hourAndMinute)
                        }
                    }
                } header: {
                    Text("When")
                } footer: {
                    Text(whenFooter)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Action", selection: $draft.action) {
                        ForEach([Rule.Action.move, .delete, .emptyTrash, .changeExtension]) { action in
                            Text(action.title).tag(action)
                        }
                        Divider()
                        ForEach([Rule.Action.convertAliases, .convertWeblocs, .convertTextClippings, .extractZip]) { action in
                            Text(action.title).tag(action)
                        }
                        Divider()
                        Text(Rule.Action.createFolder.title).tag(Rule.Action.createFolder)
                    }
                    if draft.action == .createFolder {
                        TextField("Folder name", text: $draft.newFolderName, prompt: Text("Invoices"))
                        if draft.problem == nil {
                            LabeledContent("Today") {
                                Text(Paths.display((draft.folderPath as NSString)
                                    .appendingPathComponent(draft.folderToCreate(date: Date()))))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if draft.action.usesConditions {
                        Picker("Kind", selection: $draft.kind) {
                            ForEach(FileKind.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        TextField("Extensions", text: $draft.extensions, prompt: Text(draft.action == .changeExtension ? "txt" : "pdf, png"))
                        TextField("File name", text: $draft.namePattern, prompt: Text("Screenshot*"))
                    }
                    if draft.action == .emptyTrash {
                        LabeledContent("In the Trash for") {
                            HStack(spacing: 6) {
                                TextField("Days", value: $draft.minDaysInTrash, format: .number)
                                    .labelsHidden()
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 56)
                                Stepper("Days", value: $draft.minDaysInTrash, in: 0...3650)
                                    .labelsHidden()
                                Text(draft.minDaysInTrash == 0 ? "days or more (0: any time)" : "days or more")
                            }
                        }
                    }
                    if draft.action == .changeExtension {
                        TextField("New extension", text: $draft.newExtension, prompt: Text("md"))
                    }
                    if draft.action == .move {
                        LabeledContent("Move to") {
                            folderButton(draft.destinationPath, empty: "No folder chosen") {
                                AppModel.chooseFolder(message: "Choose the folder that matching files are moved to.",
                                                      startingAt: draft.destinationPath.isEmpty ? draft.folderPath : draft.destinationPath,
                                                      toLookIn: false)
                            } set: { draft.destinationPath = $0 }
                        }
                        TextField("Rename to", text: $draft.renamePattern, prompt: Text("Keep the name"))
                        if !draft.renamePattern.trimmingCharacters(in: .whitespaces).isEmpty {
                            LabeledContent("Example") {
                                Text("Picture1.png → \(draft.newName(for: "Picture1.png", date: Date()))")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("What")
                } footer: {
                    Text(whatFooter)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .onChange(of: draft.action) { old, new in
                // "Delete files in Trash" always looks in the Trash; switching away gives the folder back to choose.
                if new == .emptyTrash {
                    draft.folderPath = Paths.trash
                } else if old == .emptyTrash, draft.folderPath == Paths.trash {
                    draft.folderPath = ""
                }
            }

            Divider()
            HStack {
                if let onDelete {
                    Button("Delete Rule") {
                        onDelete()
                        dismiss()
                    }
                }
                if let problem = draft.problem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Rule" : "Save") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.problem != nil)
            }
            .padding(16)
        }
        .frame(width: 540, height: 660)
    }

    private var whenFooter: String {
        if draft.action == .createFolder {
            switch draft.trigger {
            case .changes:
                return "The folder is made when you save the rule and when Foliarium starts, and made again a few seconds after anything in the folder changes, if it's missing then."
            case .schedule:
                return "The folder is made at these times, if it's missing then. If the Mac is asleep or Foliarium isn't running, the rule runs once as soon as it can."
            case .manual:
                return "The folder is made when you click Run Now, if it's missing. Run Now is in the General tab and the menu bar."
            }
        }
        switch draft.trigger {
        case .changes:
            return "Files are handled a few seconds after they arrive, even if Foliarium wasn't running then. Files that are already there wait for Run Now."
        case .schedule:
            let first: String
            switch draft.schedule.kind {
            case .minutes, .hours: first = "The first run is \(draft.schedule.intervalText) after you save."
            case .daily, .weekly: first = "Next run: \(Schedule.whenText(draft.schedule.nextRun(after: Date())))."
            }
            return "Goes through every file in the folder at these times. If the Mac is asleep or Foliarium isn't running then, the rule runs once as soon as it can. " + first
        case .manual:
            return "Run Now is in the General tab and the menu bar."
        }
    }

    /// Monday first, or whichever day the user's calendar starts the week with (1 is Sunday).
    static var weekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    /// The schedule's hour and minute as a Date today, for the time picker.
    private var timeBinding: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: draft.schedule.hour, minute: draft.schedule.minute, second: 0, of: Date()) ?? Date()
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            draft.schedule.hour = parts.hour ?? 9
            draft.schedule.minute = parts.minute ?? 0
        }
    }

    private var whatFooter: String {
        let conditions = "Every condition you fill in must match. For the name, type text it contains, or a pattern with * and ? such as Invoice-*.pdf. Use * to match every file. Case doesn't matter."
        switch draft.action {
        case .move:
            return conditions + "\n\nRename to: * is the original name, and YYYY, MM and DD are the date of the move, so YYYYMMDD_* gives \(Rule.exampleRename). The extension stays, and a name that already starts with a date keeps it."
        case .delete:
            return conditions + "\n\nMatching files go to the Trash, where Put Back works. With “When files are added or changed”, a new matching file is deleted a few seconds after it arrives."
        case .changeExtension:
            return conditions + "\n\nOnly the name changes, not what's inside: with Extensions txt and New extension md, notes.txt becomes notes.md."
        case .convertAliases:
            return "Replaces each Finder alias with a symlink to the same item. The alias goes to the Trash."
        case .convertWeblocs:
            return "Replaces each .webloc file with a Windows .url shortcut to the same address. The .webloc goes to the Trash."
        case .convertTextClippings:
            return "Replaces each .textClipping (text dragged out of an app into Finder) with a .txt file of the same name holding its text. The clipping goes to the Trash."
        case .extractZip:
            return "Extracts each .zip next to itself: a single item comes out as it is, several go into a folder named after the archive. The .zip goes to the Trash."
        case .emptyTrash:
            return conditions + "\n\nItems in the Trash that match are deleted for good and can't be put back. Folders in the Trash count by their own name. Set a number of days to keep things you binned recently, and use * as the name to match everything."
        case .createFolder:
            return "Makes a folder with this name in the rule's folder, if it isn't there yet. Nothing happens to files. YYYY, MM and DD are the date, so Scans YYYY-MM on a monthly schedule makes a new folder each month. Use / for a folder inside a folder, such as Projects/YYYY."
        }
    }

    /// The chosen folder's icon and path, and a Choose… button.
    private func folderButton(_ path: String, empty: String, choose: @escaping () -> String?,
                              set: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            if path.isEmpty {
                Text(empty)
                    .foregroundStyle(.secondary)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(Paths.display(path))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 250, alignment: .trailing)
                    .help(path)
            }
            Button("Choose…") {
                if let chosen = choose() { set(chosen) }
            }
        }
    }
}
