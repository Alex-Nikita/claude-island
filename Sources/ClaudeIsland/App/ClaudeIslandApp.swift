import AppKit
import SwiftUI
import Combine

@main
struct ClaudeIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        SwiftUI.Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState!
    private var pillController: PillModeController?
    private var notchController: NotchModeController?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        HookCapture.refreshScriptsIfInstalled()

        let state = AppState(settings: AppSettings())
        appState = state
        state.start()

        applyMode(state.settings.displayMode)
        state.settings.$displayMode
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in self?.applyMode(mode) }
            .store(in: &cancellables)
    }

    private func applyMode(_ mode: DisplayMode) {
        switch mode {
        case .pill:
            notchController?.deactivate()
            notchController = nil
            if pillController == nil {
                pillController = PillModeController(appState: appState)
            }
            pillController?.activate()
        case .notch:
            pillController?.deactivate()
            pillController = nil
            if notchController == nil {
                notchController = NotchModeController(appState: appState)
            }
            notchController?.activate()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.stop()
        pillController?.deactivate()
        notchController?.deactivate()
    }
}
