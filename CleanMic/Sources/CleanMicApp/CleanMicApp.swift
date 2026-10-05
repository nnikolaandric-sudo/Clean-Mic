import SwiftUI
import CleanMicCore

@main
struct CleanMicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            MenuBarLabel(model: model, meters: model.meters)
        }
        .menuBarExtraStyle(.window)

        Window("CleanMic — Podešavanja", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)

        Window("CleanMic — Izvještaj", id: "report") {
            ReportView(model: model)
        }
        .defaultSize(width: 660, height: 740)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Postavlja AppModel: zatvori snimak u toku prije izlaska.
    static var shutdown: (() -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        Self.shutdown?()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["CLEANMIC_DEBUG"] != nil { traceWindows() }
    }

    /// CLEANMIC_DEBUG=1: ispis događaja prozora/aktivacije na stderr — za slučaj
    /// "prozor se otvorio pa nestao", koji se inače ne može vidjeti spolja.
    private func traceWindows() {
        let start = Date()
        let center = NotificationCenter.default
        let windowEvents: [(Notification.Name, String)] = [
            (NSWindow.didBecomeKeyNotification, "key"), (NSWindow.didResignKeyNotification, "resignKey"),
            (NSWindow.willCloseNotification, "willClose"), (NSWindow.didChangeOcclusionStateNotification, "occlusion"),
        ]
        for (name, label) in windowEvents {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    guard let w = note.object as? NSWindow else { return }
                    traceLine(start, "\(label): '\(w.title)' id=\(w.identifier?.rawValue ?? "-") visible=\(w.isVisible) onActiveSpace=\(w.isOnActiveSpace) occluded=\(!w.occlusionState.contains(.visible))")
                }
            }
        }
        for (name, label) in [(NSApplication.didBecomeActiveNotification, "app active"),
                              (NSApplication.didResignActiveNotification, "app resignActive"),
                              (NSApplication.didHideNotification, "app hidden")] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in traceLine(start, label) }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            traceLine(start, "aktivirana aplikacija: \(app?.localizedName ?? "?")")
        }
        workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            traceLine(start, "promjena Space-a")
        }
    }
}

/// stderr nije baferovan, pa ispis preživi i nasilno gašenje.
private func traceLine(_ start: Date, _ text: String) {
    let line = String(format: "[win %.2f] %@\n", Date().timeIntervalSince(start), text)
    FileHandle.standardError.write(Data(line.utf8))
}
