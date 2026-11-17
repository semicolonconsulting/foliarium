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
    /// Small enough to tuck away, big enough that the Rules tab's footer and the table headers still fit.
    static let minContentSize = NSSize(width: 560, height: 420)
    private static let autosaveName = "SettingsWindow"

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
        let tabs = SettingsTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(item(GeneralView(model: model, showRules: { [weak self] in self?.show(.rules) },
                                             showActivity: { [weak self] in self?.show(.activity) }),
                                 label: "General", symbol: "gearshape"))
        tabs.addTabViewItem(item(RulesView(model: model), label: "Rules", symbol: "arrow.triangle.branch"))
        tabs.addTabViewItem(item(ActivityView(model: model), label: "Activity", symbol: "clock.arrow.circlepath"))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = Self.minContentSize
        // Reopen at the size and place the window was left at; the first time, use the default size, centred.
        if !window.setFrameUsingName(Self.autosaveName) {
            window.setContentSize(Self.contentSize)
            window.center()
        }
        window.setFrameAutosaveName(Self.autosaveName)
        self.tabs = tabs
        self.window = window
    }

    private func item<Content: View>(_ view: Content, label: String, symbol: String) -> NSTabViewItem {
        // Each tab fills whatever size the window is. Without the empty sizing options the hosting controller
        // would pin the window to the view's ideal size, and switching tabs would snap it back.
        let host = NSHostingController(rootView: view.frame(minWidth: Self.minContentSize.width, maxWidth: .infinity,
                                                            minHeight: Self.minContentSize.height, maxHeight: .infinity))
        host.sizingOptions = []
        host.title = label
        let item = NSTabViewItem(viewController: host)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }
}

/// Keeps the window's size when switching tabs. A toolbar-style tab view controller sizes the window to the
/// incoming tab's view, which still has the size it had when it was last shown.
private final class SettingsTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        if let current = tabViewItems[safe: selectedTabViewItemIndex]?.viewController?.view,
           let incoming = tabViewItem?.viewController?.view, incoming !== current {
            incoming.setFrameSize(current.frame.size)
        }
        super.tabView(tabView, willSelect: tabViewItem)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
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
