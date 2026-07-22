import SwiftUI
import AppKit

// The expanded island shell: shape, borders, the wing strip, and routing
// to whichever screen is active. The screens themselves live in their own
// files — DecisionPaneView, CapabilityBrowserView, CapabilityDetailView,
// ContextScreenView, IslandSettingsPane, SessionPickerOverlay.
struct ExpandedIslandView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var uiModel: NotchUIModel
    // Height of the physical notch: content must start below the camera.
    let topInset: CGFloat
    // Width of the camera housing: the logo/% wings flank it in the top
    // strip at the same positions as the collapsed bar.
    let notchWidth: CGFloat
    let collapse: () -> Void

    @State private var showSessionPicker = false
    @State private var showSessionsInstead = false
    @State private var captureInstalled = false
    @State private var clickToAnswerReady = false

    var body: some View {
        // .top pins the content: if it ever outgrows the fixed panel again,
        // the overflow goes down past the shape's bottom edge, never up over
        // the menu bar.
        ZStack(alignment: .top) {
            NotchShape(bottomRadius: 24)
                .fill(Color.black)
            BorderTrail(trigger: appState.completionPulseCount, color: .claudeOrange, bottomRadius: 24)
            AttentionBorder(active: appState.needsUserAttention, bottomRadius: 24)
            wingStrip
            VStack(alignment: .leading, spacing: 10) {
                if uiModel.showingSettings {
                    IslandSettingsPane(appState: appState, uiModel: uiModel)
                } else if let waiting = appState.attentionSession, !showSessionsInstead {
                    // Content can genuinely be unavailable (hook capture off,
                    // or a dialog type no hook reports); show an honest pane.
                    DecisionPaneView(
                        appState: appState,
                        uiModel: uiModel,
                        session: waiting,
                        prompt: waiting.pendingPrompt ?? fallbackPrompt,
                        clickToAnswerReady: clickToAnswerReady,
                        showSessionsInstead: $showSessionsInstead
                    )
                } else if uiModel.showingContext, let session = appState.selectedSession {
                    ContextScreenView(
                        appState: appState,
                        session: session,
                        showSessionPicker: $showSessionPicker,
                        close: { uiModel.showingContext = false }
                    )
                } else if let detail = uiModel.capabilityDetail {
                    CapabilityDetailView(appState: appState, detail: detail) {
                        uiModel.closeDetail()
                    }
                } else {
                    CapabilityBrowserView(
                        appState: appState,
                        uiModel: uiModel,
                        showSessionPicker: $showSessionPicker,
                        showSessionsInstead: $showSessionsInstead
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .padding(.top, topInset + 8)
        }
        .padding(.horizontal, NotchModeController.strokeSlack / 2)
        .padding(.bottom, NotchModeController.strokeSlack)
        .onAppear {
            captureInstalled = HookCapture.isInstalled
            clickToAnswerReady = HookCapture.isClickToAnswerInstalled
        }
        .overlay(alignment: .topLeading) {
            if showSessionPicker {
                SessionPickerOverlay(
                    appState: appState,
                    isPresented: $showSessionPicker,
                    topInset: topInset
                )
            }
        }
        .onChange(of: appState.needsUserAttention) { _, hasAttention in
            if !hasAttention { showSessionsInstead = false }
            showSessionPicker = false
        }
        .onChange(of: uiModel.showingSettings) { _, _ in
            showSessionPicker = false
        }
        .onChange(of: uiModel.selectedTab) { _, _ in
            uiModel.closeDetail()
        }
        .onChange(of: appState.selectedSessionIndex) { _, _ in
            uiModel.closeDetail()
        }
    }

    // Shown when a session is waiting but no prompt content was captured.
    private var fallbackPrompt: PendingPrompt {
        PendingPrompt(
            toolName: "",
            title: "Waiting for your decision",
            detail: captureInstalled
                ? "This session has a prompt open — Claude Code hasn't reported its details. Answer in the terminal."
                : "This session has a prompt open. Enable “Precise prompt capture” in Settings to see the exact prompt here.",
            options: []
        )
    }

    // The logo and % stay glued to their collapsed-bar wing positions,
    // flanking the physical notch in the top strip — expansion doesn't
    // teleport them to the panel corners.
    private var wingStrip: some View {
        ZStack {
            // The % and its reset caption sit as one group, centered in the
            // region right of the notch.
            HStack(spacing: 0) {
                Color.clear
                    .frame(maxWidth: .infinity)
                Spacer()
                    .frame(width: notchWidth)
                HStack(spacing: 8) {
                    Text(appState.percentLeftText)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundColor(.white)
                        .help(appState.percentDescription)
                    resetCaption
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity)
            }
            // The logo anchors the island's far left edge when expanded.
            HStack {
                Button(action: collapse) {
                    ClaudeLogoBadge(
                        active: appState.isAnySessionBusy,
                        pulseTrigger: appState.completionPulseCount,
                        attention: appState.needsUserAttention
                    )
                    .frame(width: 16, height: 16)
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal, 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .frame(height: topInset + 3)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var resetCaption: some View {
        if let snapshot = appState.snapshot {
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.windowLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let resetsAt = snapshot.resetsAt {
                    (Text("resets in ") + Text(resetsAt, style: .relative))
                        .font(.system(size: 8))
                        .foregroundColor(.gray.opacity(0.75))
                        .lineLimit(1)
                }
            }
            // Hug the content — a flexible frame here would soak up slack
            // and shove the % off-center (the stretchy-frame bug again).
            .fixedSize()
        }
    }
}
