import AppKit
import SwiftUI
import Combine

@MainActor
final class PillModeController: NSObject {
    private let appState: AppState
    private var statusItem: NSStatusItem?
    private var hostingView: NSHostingView<PillView>?
    private var popover: NSPopover?
    private var sizeCancellable: AnyCancellable?

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    func activate() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            let hosting = NSHostingView(rootView: PillView(appState: appState))
            hosting.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                hosting.topAnchor.constraint(equalTo: button.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            hostingView = hosting
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        updateLength()
        // objectWillChange fires before the new value lands; measure on the next runloop tick.
        sizeCancellable = appState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateLength() }
            }
    }

    private func updateLength() {
        guard let hosting = hostingView, let item = statusItem else { return }
        let width = max(30, hosting.fittingSize.width)
        if abs(item.length - width) > 0.5 {
            item.length = width
        }
    }

    func deactivate() {
        sizeCancellable = nil
        popover?.performClose(nil)
        popover = nil
        hostingView = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    @objc private func togglePopover(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let button = statusItem?.button else { return }
        let popover = self.popover ?? makePopover()
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let controller = NSHostingController(rootView: DropdownView(appState: appState, settings: appState.settings))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        return popover
    }
}
