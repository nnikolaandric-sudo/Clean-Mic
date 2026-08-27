import SwiftUI
import CleanMicCore
import AVFoundation

// MARK: - App

@main
struct CleanMicApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Label {
                Text("CleanMic")
            } icon: {
                Image(systemName: model.isRunning ? "waveform.circle.fill" : "waveform.circle")
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .menuBarExtraStyle(.window)

        Window("CleanMic Settings", id: "settings") {
            SettingsView(model: model)
                .frame(width: 480, height: 360)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Model

@MainActor
final class AppModel: ObservableObject {
    @Published var isRunning = false
    @Published var selectedMode: CleanMicMode = .balanced
    @Published var devices: [AudioDevice] = []
    @Published var selectedDeviceID: AudioDeviceID?
    @Published var inputLevel: Float = 0
    @Published var processedLevel: Float = 0
    @Published var statusText = "Spreman"
    @Published var metricsText = ""

    private var capture: AudioCapture?
    private var inputRing: RingBuffer?
    private var outputRing: RingBuffer?
    private var engine: ProcessingEngine?
    private var levelTimer: Timer?
    private var drainTimer: Timer?

    init() {
        refreshDevices()
        // Poll for device changes every 2s (TODO: CoreAudio listener in Faza 1)
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices() }
        }
    }

    func refreshDevices() {
        let list = DeviceLister.listInputDevices()
        // Only update if changed to avoid flicker
        if list.map(\.id) != devices.map(\.id) {
            devices = list
            if selectedDeviceID == nil {
                selectedDeviceID = DeviceLister.defaultInputDeviceID()
            }
        }
    }

    func toggle() {
        if isRunning { stop() } else { start() }
    }

    func start() {
        // Ako dozvola nije data, zatraži je pre starta (macOS prompt)
        let perm = DeviceLister.checkMicrophonePermission()
        if perm == "notDetermined" {
            statusText = "Tražim dozvolu za mikrofon…"
            DeviceLister.requestMicrophonePermission { [weak self] granted in
                Task { @MainActor in
                    if granted { self?.start() } else { self?.statusText = "Dozvola odbijena — uključi u System Settings" }
                }
            }
            return
        }
        if perm == "denied" || perm == "restricted" {
            statusText = "Microphone: denied — uključi u System Settings → Privacy → Microphone"
            // ponudi prompt da otvori Settings
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
            return
        }

        let cap = AudioCapture()
        let ir = RingBuffer(capacityFrames: 16384)
        let or = RingBuffer(capacityFrames: 16384)
        let eng = ProcessingEngine(inputRing: ir, outputRing: or, mode: selectedMode)

        cap.onPCM = { [weak ir] buffer in
            guard let ir = ir, let data = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            ir.write(data[0], frames: frames)
        }
        cap.onLevel = { [weak self] lvl in
            Task { @MainActor in self?.inputLevel = lvl }
        }
        eng.onMetrics = { [weak self] ms, vad in
            Task { @MainActor in
                // map vad to pseudo processed level
                self?.processedLevel = vad * 0.8
                self?.metricsText = String(format: "%.2f ms  VAD %.2f", ms, vad)
            }
        }

        do {
            try cap.start()
            eng.start()
            self.capture = cap
            self.inputRing = ir
            self.outputRing = or
            self.engine = eng
            self.isRunning = true
            self.statusText = "Radi ✓ — \(selectedMode)"
            print("[App] started")

            // Drain outputRing — bez ovoga ProcessingEngine staje nakon ~0.3s
            // (outputRing 16384 frameova se napuni, a niko ga ne cita). U Fazi 2.x
            // ce ga citati HAL driver; do tada ga samo odbacujemo.
            drainTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak or] _ in
                guard let or = or else { return }
                var tmp = [Float](repeating: 0, count: 480)
                // isprazni sve dostupne frameove (max 5 frameova po ticku da ne blokiramo main)
                var drained = 0
                while or.availableRead >= 480 && drained < 10 {
                    _ = or.read(into: &tmp, frames: 480)
                    drained += 1
                }
            }

            // Animate level meters
            levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                // decay — daje smooth pad metara kad nema glasa
                Task { @MainActor in
                    self?.inputLevel *= 0.92
                    self?.processedLevel *= 0.85
                }
            }
        } catch {
            statusText = "Greška: \(error)"
            print("[App] start failed: \(error)")
        }
    }

    func stop() {
        capture?.stop()
        engine?.stop()
        levelTimer?.invalidate()
        drainTimer?.invalidate()
        levelTimer = nil
        drainTimer = nil
        capture = nil
        engine = nil
        inputRing = nil
        outputRing = nil
        isRunning = false
        statusText = "Zaustavljen"
        inputLevel = 0
        processedLevel = 0
        print("[App] stopped")
    }

    func setMode(_ mode: CleanMicMode) {
        selectedMode = mode
        engine?.setMode(mode)
        if isRunning { statusText = "Radi ✓ — \(mode)" }
    }
}

// MARK: - MenuBar View

struct MenuBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: model.isRunning ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(model.isRunning ? .green : .secondary)
                Text("CleanMic")
                    .font(.headline)
                Spacer()
                Circle().fill(model.isRunning ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(model.isRunning ? "ON" : "OFF")
                    .font(.caption).bold()
                    .foregroundStyle(model.isRunning ? .green : .secondary)
            }

            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            // ON/OFF
            Button(model.isRunning ? "⏹ Zaustavi" : "▶ Pokreni") {
                model.toggle()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)

            // Device picker
            VStack(alignment: .leading, spacing: 4) {
                Text("Ulaz (mikrofon)").font(.caption).bold()
                Picker("Device", selection: $model.selectedDeviceID) {
                    ForEach(model.devices) { d in
                        Text(d.name).tag(Optional(d.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                Text("\(model.devices.count) uređaja • \(DeviceLister.checkMicrophonePermission())")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            // Mode
            VStack(alignment: .leading, spacing: 4) {
                Text("Mod").font(.caption).bold()
                Picker("Mode", selection: $model.selectedMode) {
                    ForEach(CleanMicMode.allCases, id: \.rawValue) { m in
                        Text(m.description).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: model.selectedMode) { _, new in model.setMode(new) }
                Text(helpForMode(model.selectedMode))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            // Level meters
            VStack(alignment: .leading, spacing: 6) {
                LevelRow(label: "Input", level: model.inputLevel, color: .blue)
                LevelRow(label: "Clean", level: model.processedLevel, color: .green)
                if !model.metricsText.isEmpty {
                    Text(model.metricsText).font(.caption2).monospaced().foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Text("Local only — nema cloud-a")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Settings…") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    NSApp.activate(ignoringOtherApps: true)
                }.font(.caption)

                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .font(.caption)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    func helpForMode(_ m: CleanMicMode) -> String {
        switch m {
        case .light: return "Blago — čuva prirodan glas"
        case .balanced: return "Balansirano — preporučeno"
        case .maximum: return "Maksimalno — agresivno"
        }
    }
}

struct LevelRow: View {
    let label: String
    let level: Float
    let color: Color
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption2).frame(width: 36, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3).fill(color)
                        .frame(width: geo.size.width * CGFloat(min(1, level * 6)))
                        .animation(.linear(duration: 0.05), value: level)
                }
            }
            .frame(height: 8)
            Text(String(format: "%.0f%%", min(100, level * 300))).font(.caption2).monospaced().frame(width: 36, alignment: .trailing)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        TabView {
            VStack(alignment: .leading, spacing: 12) {
                Text("General").font(.title3).bold()
                Toggle("Pokreni pri login-u", isOn: .constant(false))
                Text("TODO Faza 3 — Launch at login").font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("CleanMic v0.1 — Faza 0 Spike").font(.caption)
                Text("Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-")").font(.caption2).foregroundStyle(.secondary)
            }.tabItem { Label("General", systemImage: "gear") }.padding()

            VStack(alignment: .leading, spacing: 12) {
                Text("Audio").font(.title3).bold()
                Text("Input: \(model.devices.first(where: { $0.id == model.selectedDeviceID })?.name ?? "-")").font(.caption)
                Text("Target: 48k / mono / Float32").font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Status: \(model.statusText)").font(.caption)
                Text(model.metricsText).font(.caption).monospaced()
            }.tabItem { Label("Audio", systemImage: "waveform") }.padding()

            VStack(alignment: .leading, spacing: 12) {
                Text("Privacy").font(.title3).bold()
                Label("Audio se obrađuje lokalno, nema upload-a", systemImage: "lock.shield.fill")
                Text("MVP ne šalje govor na server (vidi PRD-06).").font(.caption).foregroundStyle(.secondary)
                Link("Privacy Policy", destination: URL(string: "https://example.com/privacy")!)
            }.tabItem { Label("About", systemImage: "info.circle") }.padding()
        }
        .frame(width: 480, height: 360)
    }
}
