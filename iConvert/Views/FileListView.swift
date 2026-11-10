import AppKit
import SwiftUI

struct FileListView: View {
    @Environment(ConversionQueue.self) private var queue
    let showTools: () -> Void

    @State private var selection = Set<QueueItem.ID>()

    var body: some View {
        List(queue.items, selection: $selection) { item in
            FileRow(item: item, showTools: showTools)
                .contextMenu { contextMenu(for: item) }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .onDeleteCommand {
            queue.items.filter { selection.contains($0.id) }.forEach(queue.remove)
            selection.removeAll()
        }
    }

    @ViewBuilder
    private func contextMenu(for item: QueueItem) -> some View {
        Button("Mostra originale nel Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
        if case let .done(outputs) = item.status {
            Button("Mostra risultato nel Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(outputs)
            }
        }
        Divider()
        Button("Togli dalla lista") { queue.remove(item) }
            .disabled(item.isRunning)
    }
}

private struct FileRow: View {
    @Environment(ConversionQueue.self) private var queue
    let item: QueueItem
    let showTools: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var detail: some View {
        switch item.status {
        case .pending:
            if item.routes.isEmpty {
                unsupportedDetail
            } else {
                Text(sourceDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case let .running(value):
            // Some tools never report progress, and a bar stuck at zero looks frozen.
            Group {
                if value > 0 {
                    ProgressView(value: value)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            .accessibilityLabel("Avanzamento di \(item.url.lastPathComponent)")
            .padding(.top, 2)
        case let .done(outputs):
            Label(doneDescription(outputs), systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .lineLimit(1)
                .truncationMode(.middle)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(message)
        }
    }

    @ViewBuilder
    private var unsupportedDetail: some View {
        if let tool = item.missingTool {
            HStack(spacing: 6) {
                Text("Per questo formato serve \(tool.title).")
                    .foregroundStyle(.secondary)
                Button("Come installarlo", action: showTools)
                    .buttonStyle(.link)
            }
            .font(.callout)
        } else {
            Text("Formato non supportato")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch item.status {
        case let .done(outputs):
            Button("Mostra") {
                NSWorkspace.shared.activateFileViewerSelecting(outputs)
            }
        case .running:
            Text(targetName)
                .font(.callout)
                .foregroundStyle(.secondary)
        case .pending, .failed:
            if !item.routes.isEmpty { targetPicker }
        }
    }

    private var targetPicker: some View {
        Picker(
            "Converti \(item.url.lastPathComponent) in",
            selection: Binding(
                get: { queue.target(for: item) ?? item.routes[0] },
                set: { queue.setTarget($0, for: item) }
            )
        ) {
            FormatMenuItems(formats: item.routes)
        }
        .labelsHidden()
        .frame(width: 190)
    }

    private var targetName: String {
        queue.target(for: item)?.name ?? ""
    }

    private var sourceDescription: String {
        let size = ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file)
        return "\(item.format?.name ?? "") · \(size)"
    }

    private func doneDescription(_ outputs: [URL]) -> String {
        if outputs.count > 1 { return "\(outputs.count) file creati" }
        guard let output = outputs.first else { return "Completato" }
        let size = (try? output.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        return "\(output.lastPathComponent) · \(formatted)"
    }
}

/// Picker contents with targets grouped by kind, so "video to audio" reads as a clear choice.
struct FormatMenuItems: View {
    let formats: [Format]

    var body: some View {
        ForEach(FormatCategory.allCases) { category in
            let group = formats.filter { $0.category == category }
            if !group.isEmpty {
                Section(category.title) {
                    ForEach(group) { format in
                        Text(format.name).tag(format)
                    }
                }
            }
        }
    }
}
