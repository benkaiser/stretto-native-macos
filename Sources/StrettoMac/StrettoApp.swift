import AppKit
import SwiftUI
import StrettoCore
import StrettoMedia

@MainActor
final class StrettoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct StrettoApp: App {
    @NSApplicationDelegateAdaptor(StrettoAppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @AppStorage("appearance") private var appearance = "light"
    @AppStorage("menuBarPlayer") private var menuBarPlayer = true
    private var colorScheme: ColorScheme? { appearance == "system" ? nil : appearance == "dark" ? .dark : .light }

    var body: some Scene {
        WindowGroup("Stretto", id: "library") {
            RootView(model: model)
                .preferredColorScheme(colorScheme)
                .tint(Color(red: 68 / 255, green: 187 / 255, blue: 1))
                .frame(minWidth: 860, minHeight: 600)
                .onOpenURL { url in
                    if url.host == "reset",
                       let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "token" })?.value {
                        model.resetToken = token
                    }
                }
        }
        .defaultSize(width: 1140, height: 780)
        .commands { StrettoCommands(model: model) }

        Window("Stretto Mini Player", id: "mini-player") {
            MiniPlayerView(model: model)
                .preferredColorScheme(colorScheme)
                .frame(width: 330)
                .background(WindowLevelView())
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(model: model).preferredColorScheme(colorScheme)
        }

        MenuBarExtra("Stretto", systemImage: "music.note", isInserted: $menuBarPlayer) {
            MiniPlayerView(model: model).preferredColorScheme(colorScheme).frame(width: 320)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct StrettoCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandMenu("Playback") {
            Button("Play / Pause") { model.player.toggle() }.keyboardShortcut(.space, modifiers: [])
            Button("Next Track") { model.player.next() }.keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous Track") { model.player.previous() }.keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Button("Mini Player") { openWindow(id: "mini-player") }.keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Main Window") { openWindow(id: "library") }.keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("Sync Library") { Task { await model.sync() } }.keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }
}

private struct WindowLevelView: NSViewRepresentable {
    @AppStorage("miniAlwaysOnTop") private var alwaysOnTop = false
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.level = alwaysOnTop ? .floating : .normal }
    }
}
