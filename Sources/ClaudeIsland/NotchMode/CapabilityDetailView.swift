import SwiftUI
import AppKit

// A capability row expanded into its own page.
struct CapabilityDetail: Equatable {
    struct Field: Equatable {
        let label: String
        let value: String
    }

    let kind: String
    let title: String
    let source: String
    let description: String
    var monospaced: Bool = false
    var active: Bool = false
    var activeLabel: String = "active"
    var path: String?
    var fields: [Field] = []
}

// Full-page view of one capability in the large panel: an identity rail
// on the left, the complete description as a card on the right.
struct CapabilityDetailView: View {
    @ObservedObject var appState: AppState
    let detail: CapabilityDetail
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                IslandActionButton("‹") { close() }
                Text(detail.kind)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            .padding(.leading, -10)

            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        if detail.active {
                            StatusDot(
                                color: appState.colors.active,
                                pulsing: true,
                                symbol: appState.symbolsEnabled ? "bolt.fill" : nil
                            )
                        }
                        Text(detail.title)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 6) {
                        SourceBadge(source: detail.source, projectName: appState.selectedProjectName)
                        if detail.active {
                            Text(detail.activeLabel)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(appState.colors.active)
                        }
                    }
                    ForEach(Array(detail.fields.enumerated()), id: \.offset) { _, field in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.label.uppercased())
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.gray)
                            Text(field.value)
                                .font(.system(size: 11).monospaced())
                                .foregroundColor(.white)
                                .lineLimit(4)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                    if let path = detail.path {
                        VStack(alignment: .leading, spacing: 5) {
                            Divider()
                                .overlay(Color.gray.opacity(0.35))
                            // Label and action share the row; the path gets
                            // the full width beneath.
                            HStack {
                                Text("FILE")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.gray)
                                Spacer()
                                Button {
                                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "folder")
                                            .font(.system(size: 8, weight: .semibold))
                                        Text("Reveal")
                                            .font(.system(size: 9, weight: .semibold))
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.islandChipFill))
                                    .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .help("Reveal in Finder")
                            }
                            Text(path.abbreviatingHomeDirectory)
                                .font(.system(size: 10).monospaced())
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(width: 210, alignment: .leading)

                ScrollView {
                    Text(detail.description)
                        .font(detail.monospaced ? .system(size: 12).monospaced() : .system(size: 13))
                        .foregroundColor(.white)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(14)
                }
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.06))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
