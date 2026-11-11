import SwiftUI

@main
struct GlacierDeskApp: App {
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About GlacierDesk") { openWindow(id: "about") }
            }
            CommandGroup(replacing: .help) {
                Button("GlacierDesk Help") { openWindow(id: "help") }
                    .keyboardShortcut("?", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {}
        }

        Window("About GlacierDesk", id: "about") {
            VStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 72, height: 72)
                Text("GlacierDesk").font(.title2.weight(.semibold))
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0")")
                    .foregroundStyle(.secondary)
                Link("View on GitHub", destination: URL(string: "https://github.com/rbrtwillis/GlacierDesk")!)
                Text("Copyright © 2026 WillisLabs.ai")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(28).frame(width: 320)
        }
        .windowResizability(.contentSize)

        Window("GlacierDesk Help", id: "help") {
            HelpView().frame(minWidth: 600, minHeight: 480)
        }
    }
}
