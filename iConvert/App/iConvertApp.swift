import AppKit
import SwiftUI

@main
struct iConvertApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("iConvert", id: "main") {
            ContentView()
                .environment(appDelegate.queue)
        }
        .defaultSize(width: 920, height: 580)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { appDelegate.queue.isImporterPresented = true }
                    .keyboardShortcut("o")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let queue = ConversionQueue()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        queue.add(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Finder's "Convert with iConvert" service. The name matches `NSMessage` in the Info.plist.
    @objc func convertFiles(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        queue.add(urls)
        NSApp.activate()
    }
}
