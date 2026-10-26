import AppKit
import SwiftUI

/// The settings window's panes, switched from its toolbar (HIG Settings, macOS: a noncustomizable toolbar that shows
/// the active pane, the window title naming it, the last viewed pane restored). See DESIGN.md, "설정 창".
enum SettingsPane: Int, CaseIterable {
    case general, keys

    var title: String {
        switch self {
        case .general: String(localized: "일반")
        case .keys: String(localized: "키 관리")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .keys: "key"
        }
    }

    static var lastViewed: Self {
        get { Self(rawValue: UserDefaults.standard.integer(forKey: "settingsPane")) ?? .general }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "settingsPane") }
    }
}

@MainActor
final class SettingsPanesController: NSTabViewController {
    /// Off for offscreen captures, which must not change the pane the user last viewed.
    var remembersPane = true

    init(model: AppModel) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        for pane in SettingsPane.allCases {
            let content: AnyView = switch pane {
            case .general: AnyView(SettingsView(model: model))
            case .keys: AnyView(KeysView(model: model))
            }
            let hosting = NSHostingController(rootView: content)
            // The window keeps the size the user gave it; a pane does not resize it to its ideal height.
            hosting.sizingOptions = []
            hosting.title = pane.title
            let item = NSTabViewItem(viewController: hosting)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil)
            // The toolbar uses the identifier as its item identifier, so it must be a string.
            item.identifier = "settings-pane-\(pane)"
            addTabViewItem(item)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var pane: SettingsPane {
        get { SettingsPane(rawValue: selectedTabViewItemIndex) ?? .general }
        set { selectedTabViewItemIndex = newValue.rawValue }
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        view.window?.title = pane.title
        if remembersPane { SettingsPane.lastViewed = pane }
    }

    static func window(model: AppModel, size: NSSize, pane: SettingsPane = .lastViewed,
                       remembersPane: Bool = true) -> (NSWindow, SettingsPanesController) {
        let panes = SettingsPanesController(model: model)
        panes.remembersPane = remembersPane
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.toolbarStyle = .preference
        window.contentViewController = panes
        panes.pane = pane
        window.title = pane.title
        window.setContentSize(size)
        window.minSize = NSSize(width: 440, height: 420)
        window.isReleasedWhenClosed = false
        return (window, panes)
    }
}
