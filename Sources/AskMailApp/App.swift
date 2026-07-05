import AppKit

@main
struct AskMailMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu-bar utility: no Dock icon, panel appears over any app.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
