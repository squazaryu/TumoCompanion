import SwiftUI

/// Configure the current Home dashboard model.
///
/// The console actions are fixed so the device card stays predictable. Only
/// the Tools Quick Access set is user-editable; all other tools remain in the
/// More Tools drawer automatically.
struct CustomizeHomeView: View {
    @ObservedObject private var layout = HomeLayoutStore.shared

    private let consoleActions: [HomeTileID] = [.info, .files, .apps, .backup]

    private var availableTools: [HomeToolSpec] {
        layout.toolCandidates.filter { !layout.isToolQuickAccess($0.id) }
    }

    var body: some View {
        List {
            Section {
                ForEach(consoleActions) { tile in
                    HStack(spacing: 12) {
                        icon(tile.systemImage, .secondary)
                        Text(tile.title)
                        Spacer()
                        Text("Always available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Label("Flipper Console", systemImage: "rectangle.on.rectangle")
            } footer: {
                Text("These four actions stay in the console card and are not affected by Tools Quick Access.")
            }

            Section {
                if layout.toolsQuickAccessTiles.isEmpty {
                    Text("Nothing selected — add up to six tools below.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(layout.toolsQuickAccessTiles) { tool in
                        HStack(spacing: 12) {
                            icon(tool.systemImage, tool.tint)
                            Text(tool.title)
                            Spacer()
                            Button {
                                withAnimation { layout.toggleToolQuickAccess(tool.id) }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(tool.title) from Quick Access")
                        }
                    }
                    .onMove { layout.reorderToolQuickAccess(from: $0, to: $1) }
                }

                ForEach(availableTools) { tool in
                    Button {
                        withAnimation { layout.toggleToolQuickAccess(tool.id) }
                    } label: {
                        HStack(spacing: 12) {
                            icon(tool.systemImage, tool.tint)
                            Text("Add \(tool.title)")
                            Spacer()
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(layout.canAddToolQuickAccess(tool.id) ? Theme.accent : Color.secondary.opacity(0.45))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!layout.canAddToolQuickAccess(tool.id))
                }
            } header: {
                Label("Quick Access", systemImage: "square.grid.3x2")
            } footer: {
                Text("Choose up to six tools for the Home dashboard. Selected tools are hidden from More Tools. Drag the selected rows to reorder them.")
            }

            Section {
                HStack(spacing: 12) {
                    icon("folder", .secondary)
                    Text("More Tools")
                    Spacer()
                    Text("\(availableTools.count) available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Tools that are not in Quick Access remain available from the folder tab at the bottom of Home.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Drawer", systemImage: "folder")
            }
        }
        .navigationTitle("Home Layout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { layout.resetToolsQuickAccess() } label: {
                        Label("Reset Quick Access", systemImage: "arrow.counterclockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private func icon(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name)
            .foregroundStyle(tint)
            .frame(width: 28, alignment: .center)
    }
}
