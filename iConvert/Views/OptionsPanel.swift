import AppKit
import SwiftUI

struct OptionsPanel: View {
    @Environment(ConversionQueue.self) private var queue

    var body: some View {
        @Bindable var queue = queue

        Form {
            if !queue.presentCategories.isEmpty {
                Section("Convert To") {
                    ForEach(queue.presentCategories) { category in
                        Picker(category.title, selection: Binding(
                            get: { queue.sharedTarget(for: category) ?? .mp4 },
                            set: { queue.setSharedTarget($0, for: category) }
                        )) {
                            FormatMenuItems(formats: queue.routes(for: category))
                        }
                    }
                }
            }

            if queue.needsVideoOptions || queue.needsAudioBitrate || queue.needsImageQuality || queue.needsImageSize {
                Section("Quality") {
                    if queue.needsVideoOptions {
                        Picker("Video", selection: $queue.options.videoPreset) {
                            ForEach(VideoPreset.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    if queue.needsAudioBitrate {
                        Picker("Audio", selection: $queue.options.audioBitrate) {
                            ForEach(ConversionOptions.audioBitrates, id: \.self) { Text("\($0) kbps").tag($0) }
                        }
                    }
                    if queue.needsImageQuality {
                        LabeledContent("Images") {
                            HStack {
                                Slider(value: $queue.options.imageQuality, in: 0.4...1, step: 0.05)
                                    .labelsHidden()
                                    .accessibilityLabel("Image quality")
                                Text(queue.options.imageQuality, format: .percent.precision(.fractionLength(0)))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 42, alignment: .trailing)
                            }
                        }
                    }
                    if queue.needsImageSize {
                        Picker("Longest side", selection: $queue.options.imageMaxDimension) {
                            Text("Original").tag(Int?.none)
                            ForEach(ConversionOptions.imageDimensions, id: \.self) { Text("\($0) px").tag(Int?.some($0)) }
                        }
                    }
                }
            }

            Section("Save To") {
                Picker("Destination", selection: destinationMode) {
                    Text("Next to originals").tag(false)
                    Text("Chosen folder").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)

                if case let .folder(url) = queue.destination {
                    LabeledContent {
                        Button("Change…", action: chooseFolder)
                    } label: {
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(url.path)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var destinationMode: Binding<Bool> {
        Binding(
            get: {
                if case .folder = queue.destination { return true }
                return false
            },
            set: { wantsFolder in
                if wantsFolder {
                    chooseFolder()
                } else {
                    queue.destination = .besideOriginals
                }
            }
        )
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            queue.destination = .folder(url)
        }
    }
}
