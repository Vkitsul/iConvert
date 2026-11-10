import AppKit
import SwiftUI

struct ToolsView: View {
    @Environment(ConversionQueue.self) private var queue
    @Environment(\.dismiss) private var dismiss

    private var isHomebrewInstalled: Bool {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .contains(where: FileManager.default.isExecutableFile(atPath:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("More Formats")
                    .font(.title2.weight(.semibold))
                Text("iConvert already works with what's built into macOS. These free tools are optional, and once installed they're used automatically.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(Array(ExternalTool.allCases.enumerated()), id: \.element) { index, tool in
                    if index > 0 { Divider() }
                    ToolRow(tool: tool, isInstalled: queue.tools[tool] != nil)
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 10))

            if !isHomebrewInstalled {
                HStack(spacing: 4) {
                    Text("These commands need Homebrew, which isn't installed.")
                        .foregroundStyle(.secondary)
                    Link("Learn how to install it", destination: URL(string: "https://brew.sh")!)
                }
                .font(.callout)
            }

            HStack {
                Button("Check Again") { queue.refreshTools() }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear { queue.refreshTools() }
    }
}

private struct ToolRow: View {
    let tool: ExternalTool
    let isInstalled: Bool

    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: isInstalled ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isInstalled ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                .accessibilityLabel(isInstalled ? "Installed" : "Not installed")

            VStack(alignment: .leading, spacing: 3) {
                Text(tool.title).fontWeight(.medium)
                Text(tool.unlocks)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !isInstalled {
                    Text(tool.installCommand)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isInstalled {
                Button(didCopy ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tool.installCommand, forType: .string)
                    didCopy = true
                }
                .accessibilityLabel("Copy the command for \(tool.title)")
            }
        }
        .padding(12)
    }
}
