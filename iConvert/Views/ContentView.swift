import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ConversionQueue.self) private var queue
    @Environment(\.scenePhase) private var scenePhase

    @State private var isDropTargeted = false
    @State private var isInspectorVisible = true
    @State private var isToolsPresented = false

    var body: some View {
        @Bindable var queue = queue

        Group {
            if queue.items.isEmpty {
                EmptyDropView(isTargeted: isDropTargeted) {
                    queue.isImporterPresented = true
                }
            } else {
                FileListView(showTools: { isToolsPresented = true })
                    .safeAreaInset(edge: .bottom, spacing: 0) { ActionBar() }
            }
        }
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 380, maxHeight: .infinity)
        .overlay {
            if isDropTargeted && !queue.items.isEmpty {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.tint, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            queue.add(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .inspector(isPresented: Binding(
            get: { isInspectorVisible && !queue.items.isEmpty },
            set: { isInspectorVisible = $0 }
        )) {
            OptionsPanel()
                .inspectorColumnWidth(min: 260, ideal: 290, max: 360)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Aggiungi file", systemImage: "plus") {
                    queue.isImporterPresented = true
                }
                .help("Aggiungi file o cartelle")

                Button("Altri formati", systemImage: "puzzlepiece.extension") {
                    isToolsPresented = true
                }
                .help("Strumenti facoltativi che aggiungono altri formati")

                if !queue.items.isEmpty {
                    Button("Opzioni", systemImage: "sidebar.trailing") {
                        isInspectorVisible.toggle()
                    }
                    .help("Mostra o nascondi le opzioni")
                }
            }
        }
        .fileImporter(
            isPresented: $queue.isImporterPresented,
            allowedContentTypes: [.item, .folder],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result { queue.add(urls) }
        }
        .sheet(isPresented: $isToolsPresented) {
            ToolsView()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { queue.refreshTools() }
        }
    }
}

private struct EmptyDropView: View {
    let isTargeted: Bool
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text("Trascina qui file o cartelle")
                .font(.title2.weight(.medium))
            Text("Video, audio, immagini e documenti. I file convertiti finiscono accanto agli originali.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Scegli file…", action: choose)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: isTargeted ? [] : [7, 5])
                )
                .padding(20)
        }
    }
}

private struct ActionBar: View {
    @Environment(ConversionQueue.self) private var queue

    var body: some View {
        HStack(spacing: 12) {
            if queue.isRunning {
                ProgressView(value: queue.overallProgress)
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Avanzamento totale")
            }
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.numericText())

            Spacer(minLength: 8)

            if queue.isRunning {
                Button("Interrompi", role: .cancel) { queue.stop() }
                    .controlSize(.large)
            } else {
                if queue.completedCount > 0 {
                    Button("Togli completati") { queue.removeCompleted() }
                        .controlSize(.large)
                }
                Button(convertTitle) { queue.start() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(queue.runnableCount == 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var summary: String {
        let total = queue.items.count
        let files = total == 1 ? "1 file" : "\(total) file"
        let done = queue.completedCount
        guard done > 0 else { return files }
        return done == 1 ? "\(files), 1 completato" : "\(files), \(done) completati"
    }

    private var convertTitle: String {
        let count = queue.runnableCount
        return count == 0 ? "Converti" : "Converti \(count) file"
    }
}
