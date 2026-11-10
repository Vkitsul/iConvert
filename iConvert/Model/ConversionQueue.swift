import Foundation
import Observation

@Observable
final class QueueItem: Identifiable {
    enum Status: Equatable {
        case pending
        case running(Double)
        case done([URL])
        case failed(String)
    }

    let id = UUID()
    let url: URL
    let format: Format?
    let fileSize: Int64
    var routes: [Format] = []
    var missingTool: ExternalTool?
    /// A choice made on this row, which wins over the choice for its whole category.
    var targetOverride: Format?
    var status: Status = .pending

    init(url: URL) {
        self.url = url
        format = Format.detect(url)
        fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    var isRunnable: Bool {
        guard !routes.isEmpty else { return false }
        switch status {
        case .pending, .failed: return true
        case .running, .done: return false
        }
    }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    var isDone: Bool {
        if case .done = status { return true }
        return false
    }
}

@Observable
final class ConversionQueue {
    enum Destination: Equatable {
        case besideOriginals
        case folder(URL)
    }

    private(set) var items: [QueueItem] = []
    private(set) var isRunning = false
    private(set) var tools: [ExternalTool: URL] = [:]
    private var registry = EngineRegistry(tools: [:])
    private var runTask: Task<Void, Never>?
    private let defaults: UserDefaults

    var isImporterPresented = false

    var options: ConversionOptions {
        didSet {
            if let data = try? JSONEncoder().encode(options) {
                defaults.set(data, forKey: Keys.options)
            }
        }
    }

    var destination: Destination {
        didSet {
            if case let .folder(url) = destination {
                defaults.set(url.path, forKey: Keys.destination)
            } else {
                defaults.removeObject(forKey: Keys.destination)
            }
        }
    }

    private var categoryTargets: [FormatCategory: Format]

    private enum Keys {
        static let options = "conversionOptions"
        static let destination = "destinationFolder"
        static func target(_ category: FormatCategory) -> String { "target.\(category.rawValue)" }
    }

    private static let defaultTargets: [FormatCategory: Format] = [
        .video: .mp4, .audio: .m4a, .image: .jpg, .document: .pdf,
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        options = defaults.data(forKey: Keys.options)
            .flatMap { try? JSONDecoder().decode(ConversionOptions.self, from: $0) }
            ?? ConversionOptions()
        destination = defaults.string(forKey: Keys.destination)
            .map { .folder(URL(filePath: $0, directoryHint: .isDirectory)) }
            ?? .besideOriginals
        categoryTargets = Self.defaultTargets
        for category in FormatCategory.allCases {
            if let id = defaults.string(forKey: Keys.target(category)), let format = Format.withID(id) {
                categoryTargets[category] = format
            }
        }
        refreshTools()
    }

    // MARK: Tools

    func refreshTools() {
        let found = ExternalTool.locateAll()
        guard found != tools || registry.engines.isEmpty else { return }
        tools = found
        registry = EngineRegistry(tools: found)
        items.forEach(applyRoutes)
    }

    private func applyRoutes(_ item: QueueItem) {
        guard let format = item.format else { return }
        item.routes = registry.routes(from: format)
        item.missingTool = item.routes.isEmpty ? registry.missingTool(for: format) : nil
        if let override = item.targetOverride, !item.routes.contains(override) {
            item.targetOverride = nil
        }
    }

    // MARK: Adding and removing

    func add(_ urls: [URL]) {
        Task { await addAndWait(urls) }
    }

    func addAndWait(_ urls: [URL]) async {
        let expanded = await Self.expand(urls)
        let known = Set(items.map(\.url))
        for url in expanded where !known.contains(url) {
            let item = QueueItem(url: url)
            applyRoutes(item)
            items.append(item)
        }
    }

    /// Replaces folders with the files inside them, at any depth. A file named directly is
    /// kept even if unknown, so its row can say why it can't be converted; inside a folder,
    /// unknown files are skipped.
    @concurrent
    private static func expand(_ urls: [URL]) async -> [URL] {
        var result: [URL] = []
        var seen = Set<URL>()
        let fileManager = FileManager.default

        func append(_ url: URL) {
            let normalized = url.standardizedFileURL
            if seen.insert(normalized).inserted { result.append(normalized) }
        }

        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values?.isDirectory == true, values?.isPackage != true else {
                append(url)
                continue
            }
            let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            var found: [URL] = []
            while let file = enumerator?.nextObject() as? URL {
                let isFile = (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                if isFile, Format.detect(file) != nil { found.append(file) }
            }
            found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            found.forEach(append)
        }
        return result
    }

    func remove(_ item: QueueItem) {
        guard !item.isRunning else { return }
        items.removeAll { $0.id == item.id }
    }

    func removeAll() {
        guard !isRunning else { return }
        items.removeAll()
    }

    func removeCompleted() {
        items.removeAll(where: \.isDone)
    }

    // MARK: Targets

    /// What this item will become: its own choice, then its category's, then the first it can do.
    func target(for item: QueueItem) -> Format? {
        if let override = item.targetOverride { return override }
        guard let category = item.format?.category else { return nil }
        if let shared = categoryTargets[category], item.routes.contains(shared) { return shared }
        return item.routes.first
    }

    func setTarget(_ target: Format, for item: QueueItem) {
        guard !item.isRunning else { return }
        item.targetOverride = target
        item.status = .pending
    }

    var presentCategories: [FormatCategory] {
        let present = Set(items.filter { !$0.routes.isEmpty }.compactMap(\.format?.category))
        return FormatCategory.allCases.filter(present.contains)
    }

    /// Every target at least one item of the category can reach.
    func routes(for category: FormatCategory) -> [Format] {
        let reachable = items
            .filter { $0.format?.category == category }
            .reduce(into: Set<Format>()) { $0.formUnion($1.routes) }
        return Format.all.filter(reachable.contains)
    }

    func sharedTarget(for category: FormatCategory) -> Format? {
        let routes = routes(for: category)
        if let chosen = categoryTargets[category], routes.contains(chosen) { return chosen }
        return routes.first
    }

    func setSharedTarget(_ target: Format, for category: FormatCategory) {
        categoryTargets[category] = target
        defaults.set(target.id, forKey: Keys.target(category))
        for item in items where item.format?.category == category && !item.isRunning {
            item.targetOverride = nil
            item.status = .pending
        }
    }

    private var pendingTargets: [Format] {
        items.filter { !$0.isDone }.compactMap(target(for:))
    }

    var needsVideoOptions: Bool {
        pendingTargets.contains { $0.category == .video || $0 == .gif }
    }

    var needsAudioBitrate: Bool {
        pendingTargets.contains { $0.category == .audio && $0.isLossy }
    }

    var needsImageQuality: Bool {
        pendingTargets.contains { $0.category == .image && $0.isLossy }
    }

    var needsImageSize: Bool {
        pendingTargets.contains { $0.category == .image && $0 != .gif }
            || items.contains { !$0.isDone && $0.format?.category == .image && target(for: $0) == .pdf }
    }

    // MARK: Running

    var runnableCount: Int { items.filter(\.isRunnable).count }
    var completedCount: Int { items.filter(\.isDone).count }

    /// Average across the rows taking part in this run.
    var overallProgress: Double {
        let active = items.filter { !$0.routes.isEmpty }
        guard !active.isEmpty else { return 0 }
        let total = active.reduce(0.0) { sum, item in
            switch item.status {
            case let .running(value): sum + value
            case .done, .failed: sum + 1
            case .pending: sum
            }
        }
        return total / Double(active.count)
    }

    private static var parallelJobs: Int {
        min(max(ProcessInfo.processInfo.activeProcessorCount / 2, 2), 4)
    }

    func start() {
        guard !isRunning else { return }
        let pending = items.filter(\.isRunnable)
        guard !pending.isEmpty else { return }
        isRunning = true
        runTask = Task {
            await run(pending)
            isRunning = false
            runTask = nil
        }
    }

    func stop() {
        runTask?.cancel()
    }

    func startAndWait() async {
        start()
        await runTask?.value
    }

    private func run(_ pending: [QueueItem]) async {
        await withTaskGroup(of: Void.self) { group in
            var remaining = pending[...]
            for _ in 0..<Self.parallelJobs {
                guard let item = remaining.popFirst() else { break }
                group.addTask { await self.convert(item) }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, let item = remaining.popFirst() else { continue }
                group.addTask { await self.convert(item) }
            }
        }
    }

    private func convert(_ item: QueueItem) async {
        guard let format = item.format,
              let target = target(for: item),
              let engine = registry.engine(from: format, to: target)
        else {
            item.status = .failed(ConversionError.noRoute.localizedDescription)
            return
        }

        item.status = .running(0)
        // Keeping only the newest value means slow UI updates can't pile up or arrive out of order.
        let (updates, continuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
        let observer = Task {
            for await value in updates { item.status = .running(value) }
        }

        var folder: URL?
        if case let .folder(url) = destination { folder = url }

        let outcome: QueueItem.Status
        do {
            let outputs = try await ConversionRunner.run(
                source: item.url,
                sourceFormat: format,
                target: target,
                options: options,
                engine: engine,
                destination: folder,
                progress: { continuation.yield($0) }
            )
            outcome = .done(outputs)
        } catch {
            outcome = Task.isCancelled || error is CancellationError
                ? .pending
                : .failed(error.localizedDescription)
        }
        continuation.finish()
        await observer.value
        item.status = outcome
    }
}
