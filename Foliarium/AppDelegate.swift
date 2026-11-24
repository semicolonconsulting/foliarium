import AppKit
import Combine

@main
enum FoliariumApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// A menu bar app: the status item's menu has Run Now, Preview, the watch switch and Settings.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel.shared
    private var statusItem: NSStatusItem?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything checks the rules: in the App Store edition a rule can only use folders the user chose.
        FolderAccess.restore()
        installMainMenu()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        model.$config.map { $0.rules.contains { $0.isUsable && $0.trigger.isAutomatic } }.removeDuplicates()
            .combineLatest(model.$problem.map { $0 != nil }.removeDuplicates())
            .sink { [weak self] watching, hasProblem in self?.updateIcon(watching: watching, problem: hasProblem) }
            .store(in: &subscriptions)

        model.start()
        #if !APPSTORE
        Updater.shared.start()
        #endif
        // Nothing happens until there's a rule, so a first launch opens the Rules tab.
        if model.config.rules.isEmpty { Windows.settings.show(.rules) }
        openWindowsFromArguments()
    }

    /// `-openSettings general|rules|activity` and `-openPreview YES` open those windows at launch
    /// (for screenshots and scripts).
    private func openWindowsFromArguments() {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "openSettings") {
        case "general": Windows.settings.show(.general)
        case "rules": Windows.settings.show(.rules)
        case "activity": Windows.settings.show(.activity)
        default: break
        }
        if defaults.bool(forKey: "openPreview") { Windows.preview.show() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    /// Opening the app again (from Finder or Spotlight) shows the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Windows.settings.show()
        return false
    }

    private func updateIcon(watching: Bool, problem: Bool) {
        let name = problem ? "folder.badge.questionmark" : watching ? "folder.badge.gearshape" : "folder"
        let description = problem ? "Foliarium: needs attention" : watching ? "Foliarium: running rules automatically" : "Foliarium: no automatic rules"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "folder", accessibilityDescription: description)
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = description
    }

    // MARK: Status menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let config = model.config
        let folders = model.folders

        if config.rules.isEmpty {
            info(menu, "No rules yet")
        } else {
            let rules = config.rules.filter(\.enabled).count
            info(menu, (rules == 1 ? "1 rule" : "\(rules) rules") + " in " + (folders.count == 1 ? "1 folder" : "\(folders.count) folders"))
            info(menu, model.automationSummary)
        }
        if let problem = model.problem { info(menu, "⚠︎ " + problem) }
        if model.isRunning {
            info(menu, "Running…")
        } else if let last = model.lastRun {
            info(menu, "Last run \(last.date.formatted(date: .omitted, time: .shortened)): \(last.summary)")
        }
        menu.addItem(.separator())

        let usable = model.hasUsableRules
        add(menu, "Run Now", #selector(runNow), key: "r", enabled: usable)
        add(menu, "Preview…", #selector(preview), enabled: usable)
        menu.addItem(.separator())
        if folders.count == 1 {
            add(menu, "Open “\((folders[0] as NSString).lastPathComponent)”", #selector(openFolder(_:))).representedObject = folders[0]
        } else if folders.count > 1 {
            let item = NSMenuItem(title: "Open Folder", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for folder in folders {
                add(submenu, (folder as NSString).lastPathComponent, #selector(openFolder(_:))).representedObject = folder
            }
            item.submenu = submenu
            menu.addItem(item)
        }
        add(menu, "Activity…", #selector(showActivity))
        add(menu, "Settings…", #selector(showSettings), key: ",")
        #if !APPSTORE
        if Updater.isAvailable {
            if case .available(let release) = Updater.shared.state {
                add(menu, "Update to Foliarium \(release.version)…", #selector(installUpdate))
            } else {
                add(menu, "Check for Updates…", #selector(checkForUpdates), enabled: !Updater.shared.isBusy)
            }
        }
        #endif
        menu.addItem(.separator())
        add(menu, "Quit Foliarium", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp)
    }

    private func info(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "",
                     enabled: Bool = true, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: key)
        item.target = target ?? self
        menu.addItem(item)
        return item
    }

    @objc private func runNow() { model.runNow() }
    @objc private func preview() { Windows.preview.show() }
    @objc private func openFolder(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { model.open(folder: path) }
    }
    @objc private func showActivity() { Windows.settings.show(.activity) }
    @objc private func showSettings() { Windows.settings.show() }
    #if !APPSTORE
    @objc private func checkForUpdates() { Updater.shared.check(userInitiated: true, showResult: true) }
    @objc private func installUpdate() {
        if case .available(let release) = Updater.shared.state { Updater.shared.install(release) }
    }
    #endif

    // MARK: Main menu

    /// A menu bar app has no visible main menu, but text fields need one for ⌘C, ⌘V, ⌘A and undo.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Foliarium")
        appMenu.addItem(withTitle: "Quit Foliarium", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}
