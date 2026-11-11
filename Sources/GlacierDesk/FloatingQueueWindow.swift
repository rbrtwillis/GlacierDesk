import AppKit
import SwiftUI

/// Hosts a SwiftUI view in a normal, independently movable and resizable window.
struct FloatingQueueWindow<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let content: Content

    func makeCoordinator() -> Coordinator { Coordinator(isPresented: $isPresented) }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isPresented = $isPresented
        if isPresented {
            if let host = coordinator.host { host.rootView = content }
            else {
                let host = NSHostingController(rootView: content)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
                window.title = "Legacy transfer queue"
                window.minSize = NSSize(width: 650, height: 450)
                window.contentViewController = host
                window.isReleasedWhenClosed = false
                window.delegate = coordinator
                window.center()
                coordinator.host = host; coordinator.window = window
                window.makeKeyAndOrderFront(nil)
            }
        } else if let window = coordinator.window {
            window.orderOut(nil); coordinator.window = nil; coordinator.host = nil
        }
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.window?.delegate = nil; coordinator.window?.close(); coordinator.window = nil; coordinator.host = nil
    }
    final class Coordinator: NSObject, NSWindowDelegate {
        var isPresented: Binding<Bool>
        var window: NSWindow?
        var host: NSHostingController<Content>?
        init(isPresented: Binding<Bool>) { self.isPresented = isPresented }
        func windowWillClose(_ notification: Notification) {
            window = nil; host = nil
            DispatchQueue.main.async { self.isPresented.wrappedValue = false }
        }
    }
}
