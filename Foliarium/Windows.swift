import AppKit
import SwiftUI

@MainActor
enum Windows {
    static let settings = SettingsWindowController(model: .shared)
    static let preview = PreviewWindowController(model: .shared)
}

/// The Settings window: General, Rules and Activity tabs in a toolbar, each a SwiftUI view.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    enum Tab: Int { case general, rules, activity }

    static let contentSize = NSSize(width: 640, height: 680)

    private let model: AppModel
    private var window: NSWindow?
    private var tabs: NSTabViewController?

    init(model: AppModel) {
        self.model = model
    }

    func show(_ tab: Tab? = nil) {
        if window == nil { build() }
        if let tab { tabs?.selectedTabViewItemIndex = tab.rawValue }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(item(GeneralView(model: model, showRules: { [weak self] in self?.show(.rules) },
                                             showActivity: { [weak self] in self?.show(.activity) }),
                                 label: "General", symbol: "gearshape"))
        tabs.addTabViewItem(item(RulesView(model: model), label: "Rules", symbol: "arrow.triangle.branch"))
        tabs.addTabViewItem(item(ActivityView(model: model), label: "Activity", symbol: "clock.arrow.circlepath"))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(Self.contentSize)
        window.center()
        self.tabs = tabs
        self.window = window
    }

    private func item<Content: View>(_ view: Content, label: String, symbol: String) -> NSTabViewItem {
        let host = NSHostingController(rootView: view.frame(width: Self.contentSize.width, height: Self.contentSize.height))
        host.title = label
        let item = NSTabViewItem(viewController: host)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }
}

/// Lists what Run Now would do, without changing anything.
@MainActor
final class PreviewWindowController: NSObject {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: PreviewView(model: model))
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            window.title = "Preview"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 820, height: 480))
            window.contentMinSize = NSSize(width: 560, height: 300)
            window.center()
            self.window = window
        }
        model.previewRequest += 1
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
