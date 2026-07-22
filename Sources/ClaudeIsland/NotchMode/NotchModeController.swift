import AppKit
import SwiftUI
import QuartzCore
import Combine

enum CapabilityTab: String, CaseIterable, Identifiable {
    case subagents = "Subagents"
    case skills = "Skills"
    case hooks = "Hooks"

    var id: String { rawValue }
}

@MainActor
final class NotchUIModel: ObservableObject {
    @Published var expanded: Bool = false
    // Lives here (not view @State) so the controller can grow the panel
    // while the settings pane is showing.
    @Published var showingSettings: Bool = false
    // Capability detail pages borrow the large panel too.
    @Published var largePane: Bool = false
    // Navigation state lives here, not in view @State: collapsing destroys
    // the expanded view, and reopening must land right where the user left.
    @Published var selectedTab: CapabilityTab = .subagents
    @Published var showingContext: Bool = false
    @Published var onlyActive: Bool = false
    @Published var capabilityDetail: CapabilityDetail?
    // True while the question page is on screen — it gets a taller panel so
    // long questions and option lists breathe.
    @Published var decisionPane: Bool = false

    // Detail pages ride in the large panel; open/close keep the two flags
    // in step.
    func openDetail(_ detail: CapabilityDetail) {
        capabilityDetail = detail
        largePane = true
    }

    func closeDetail() {
        capabilityDetail = nil
        largePane = false
    }
}

@MainActor
final class NotchModeController {
    private let appState: AppState
    private let uiModel = NotchUIModel()
    private var panel: NSPanel?
    private var hostingView: NSHostingView<NotchRootView>?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var attentionCancellable: AnyCancellable?
    private var settingsCancellable: AnyCancellable?
    private var autoExpanded = false
    private var lastPromptIdentities: [String: String] = [:]

    // Width of each side wing (logo / %); CollapsedNotchView lays out its
    // wings from this same constant — the panel width is computed from it.
    static let wingWidth: CGFloat = 76
    private static let expandedSize = NSSize(width: 660, height: 300)
    // The question page runs taller: long questions, wrapped option rows,
    // the wizard breadcrumb, and a pinned footer all want vertical room.
    private static let decisionSize = NSSize(width: 660, height: 360)
    // Settings get their own roomier size: a usage overview column plus the
    // full form, nothing cramped.
    private static let settingsSize = NSSize(width: 740, height: 500)
    private static let animationDuration: TimeInterval = 0.25
    // Transparent slack around the island so border-trail strokes and glow
    // aren't clipped by the panel edge; the views pad by strokeSlack/2.
    static let strokeSlack: CGFloat = 6

    init(appState: AppState) {
        self.appState = appState
    }

    func activate() {
        if panel == nil {
            buildPanel()
        } else if let screen = targetScreen() {
            hostingView?.rootView = makeRootView(notchWidth: notchWidth(for: screen))
        }
        applyFrame(animated: false)
        panel?.orderFrontRegardless()
        if DebugFlags.openContext {
            uiModel.showingContext = true
        }
        if DebugFlags.openSettings {
            uiModel.showingSettings = true
            setExpanded(true)
        } else if DebugFlags.startExpanded {
            setExpanded(true)
        }
        // The settings and detail panes need the roomier frame the moment
        // they open.
        settingsCancellable = uiModel.$showingSettings
            .removeDuplicates()
            .combineLatest(uiModel.$largePane.removeDuplicates(),
                           uiModel.$decisionPane.removeDuplicates())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
                guard let self, self.uiModel.expanded else { return }
                self.applyFrame(animated: true)
            }
        // Auto-expand when a session starts waiting on the user; collapse
        // again once answered (only if the expansion was automatic). Keyed on
        // per-session prompt identity: a new waiting session or new prompt
        // content re-expands even after a manual collapse, but a prompt's
        // content DISAPPEARING (the brief resolved-while-status-lags window
        // reports nil content) must not pop the island open again.
        attentionCancellable = appState.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                guard let self else { return }
                let waiting = sessions.filter(\.needsAttention)
                var identities: [String: String] = [:]
                for session in waiting {
                    identities[session.id] = session.pendingPrompt.map { $0.title + "|" + $0.detail } ?? ""
                }
                defer { self.lastPromptIdentities = identities }
                if waiting.isEmpty {
                    if self.autoExpanded {
                        self.autoExpanded = false
                        self.setExpanded(false)
                    }
                    return
                }
                let newAttention = identities.contains { id, identity in
                    guard let previous = self.lastPromptIdentities[id] else { return true }
                    return !identity.isEmpty && identity != previous
                }
                // Identity bookkeeping above stays unconditional so flipping
                // the setting on later doesn't replay stale prompts.
                if newAttention, !self.uiModel.expanded,
                   self.appState.settings.autoExpandOnPrompt {
                    self.setExpanded(true)
                    self.autoExpanded = true
                }
            }
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.screenParametersChanged() }
            }
        }
    }

    func deactivate() {
        attentionCancellable = nil
        settingsCancellable = nil
        autoExpanded = false
        removeMonitors()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        uiModel.expanded = false
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }

    private func buildPanel() {
        guard let screen = targetScreen() else { return }
        let frame = collapsedFrame(on: screen)
        let panel = NotchPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        // Above the menu-bar layer, or clicks in that strip never reach us.
        // Must come after other panel config: isFloatingPanel & friends reset level.
        panel.level = .screenSaver
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        // The hosting view must NOT be the contentView: in that position
        // NSHostingView drives the window's size (updateAnimatedWindowSize),
        // which collides with our own frame animation inside the display
        // cycle and crashes with an NSInternalInconsistencyException.
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        let hosting = FirstMouseHostingView(rootView: makeRootView(notchWidth: notchWidth(for: screen)))
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        hostingView = hosting
        self.panel = panel
    }

    private func makeRootView(notchWidth: CGFloat) -> NotchRootView {
        let screen = targetScreen()
        return NotchRootView(
            appState: appState,
            model: uiModel,
            notchWidth: notchWidth,
            topInset: screen.map { notchHeight(for: $0) } ?? 32,
            expand: { [weak self] in self?.setExpanded(true) },
            collapse: { [weak self] in self?.setExpanded(false) }
        )
    }

    private func setExpanded(_ expanded: Bool) {
        guard uiModel.expanded != expanded else { return }
        if !expanded {
            autoExpanded = false
        }
        withAnimation(.easeInOut(duration: Self.animationDuration)) {
            uiModel.expanded = expanded
        }
        applyFrame(animated: true)
        if expanded {
            installMonitors()
        } else {
            removeMonitors()
        }
    }

    private func applyFrame(animated: Bool) {
        guard let panel, let screen = targetScreen() else { return }
        let frame = uiModel.expanded ? expandedFrame(on: screen) : collapsedFrame(on: screen)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func screenParametersChanged() {
        guard let screen = targetScreen() else { return }
        if panel == nil {
            // activate() ran while no screen was available; recover now.
            buildPanel()
            panel?.orderFrontRegardless()
        } else {
            hostingView?.rootView = makeRootView(notchWidth: notchWidth(for: screen))
        }
        applyFrame(animated: false)
    }

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in self?.collapseIfClickedOutside(at: location) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let location = NSEvent.mouseLocation
            Task { @MainActor in self?.collapseIfClickedOutside(at: location) }
            return event
        }
    }

    private func removeMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
    }

    private func collapseIfClickedOutside(at location: NSPoint) {
        guard let panel, uiModel.expanded else { return }
        if !panel.frame.contains(location) {
            // The user can turn click-away collapsing off; the island then
            // stays open until collapsed via its own logo button.
            if appState.settings.collapseOnClickAway {
                setExpanded(false)
            }
        } else {
            // A click inside the expanded island means the user took over
            // (opening Settings, browsing tabs): stop treating the expansion
            // as automatic so answering a prompt can't yank the panel shut
            // mid-interaction and discard their view state.
            autoExpanded = false
        }
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
    }

    private func notchWidth(for screen: NSScreen) -> CGFloat {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            return 200
        }
        let width = screen.frame.width - left.width - right.width
        return width > 0 ? width : 200
    }

    private func notchHeight(for screen: NSScreen) -> CGFloat {
        max(screen.safeAreaInsets.top, 32)
    }

    private func collapsedFrame(on screen: NSScreen) -> NSRect {
        // +3 makes the island read slightly taller than the notch itself.
        let width = notchWidth(for: screen) + Self.wingWidth * 2 + Self.strokeSlack
        let height = notchHeight(for: screen) + 3 + Self.strokeSlack
        return topCenteredRect(width: width, height: height, on: screen)
    }

    // The physical notch occupies the top notchHeight points of the panel,
    // so the expanded island grows by that much and the content starts
    // below the camera housing instead of hiding behind it.
    private func expandedFrame(on screen: NSScreen) -> NSRect {
        let base: NSSize
        if uiModel.showingSettings || uiModel.largePane {
            base = Self.settingsSize
        } else if uiModel.decisionPane {
            base = Self.decisionSize
        } else {
            base = Self.expandedSize
        }
        return topCenteredRect(
            width: base.width + Self.strokeSlack,
            height: base.height + notchHeight(for: screen) + Self.strokeSlack,
            on: screen
        )
    }

    private func topCenteredRect(width: CGFloat, height: CGFloat, on screen: NSScreen) -> NSRect {
        NSRect(
            x: (screen.frame.midX - width / 2).rounded(),
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
    }
}

private struct NotchRootView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var model: NotchUIModel
    let notchWidth: CGFloat
    let topInset: CGFloat
    let expand: () -> Void
    let collapse: () -> Void

    var body: some View {
        Group {
            if model.expanded {
                ExpandedIslandView(
                    appState: appState,
                    uiModel: model,
                    topInset: topInset,
                    notchWidth: notchWidth,
                    collapse: collapse
                )
            } else {
                CollapsedNotchView(appState: appState, notchWidth: notchWidth, expand: expand)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Nonactivating panels don't activate the app on click; accept the first
// click so taps land on the SwiftUI content immediately.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// AppKit constrains borderless windows below the menu bar; the whole point
// of this panel is to sit on top of it, flush with the screen edge.
private final class NotchPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    // Borderless windows refuse key status by default; without it the
    // nonactivating panel never receives clicks for its SwiftUI content.
    override var canBecomeKey: Bool { true }
}
