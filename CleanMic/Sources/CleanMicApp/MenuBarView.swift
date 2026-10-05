import SwiftUI
import CleanMicCore

/// Ikona u menu baru; dok snima pokazuje i proteklo vrijeme, da se vidi da radi.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var meters: LiveMeters

    var body: some View {
        if model.isRecording {
            Label {
                Text(Fmt.short(meters.elapsedSeconds)).monospacedDigit()
            } icon: {
                Image(systemName: "record.circle.fill")
            }
            .labelStyle(.titleAndIcon)
        } else if model.isTranscribing {
            Image(systemName: "ellipsis.bubble")
        } else {
            Image(systemName: "waveform.circle")
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var contentHeight: CGFloat = 430

    /// Popover se širi prema sadržaju, ali nikad preko ekrana — na 13" laptopu
    /// sadržaj se skroluje umjesto da izađe ispod donje ivice.
    private var maxHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return min(760, screen - 24)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let banner = model.banner {
                    BannerView(banner: banner) { model.banner = nil }
                }
                if model.micPermission == "denied" || model.micPermission == "restricted" {
                    permissionCard
                }
                RecorderCard(model: model, meters: model.meters)
                optionsCard
                if let pending = model.pendingConfirm {
                    ConfirmCard(model: model, info: pending)
                }
                if let recording = model.lastRecording {
                    LastRecordingCard(model: model, info: recording, openReport: { open("report") })
                }
                footer
            }
            .padding(14)
            .background(GeometryReader { geo in
                Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
            })
        }
        .onPreferenceChange(ContentHeightKey.self) { height in
            if height > 0 { contentHeight = height }
        }
        .frame(width: 360, height: min(contentHeight, maxHeight))
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
        // Prozor koji već postoji (npr. ostao na drugom Space-u) dovedi ovdje.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            for window in NSApp.windows where window.identifier?.rawValue.contains(id) == true {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }

    // MARK: Sekcije

    private var header: some View {
        HStack(spacing: 10) {
            AppGlyph(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("CleanMic").font(.headline)
                Text("Čist zvuk · transkript · izvještaj")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRecording {
                StatusChip(text: "Snima", color: .red, pulsing: true)
            } else if model.isTranscribing {
                StatusChip(text: "Obrada", color: .blue, pulsing: true)
            } else {
                StatusChip(text: "Spreman", color: .green)
            }
        }
    }

    private var permissionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("CleanMic nema dozvolu za mikrofon", systemImage: "mic.slash.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
                Text("Uključi CleanMic u System Settings → Privacy & Security → Microphone, pa pokušaj ponovo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Otvori System Settings") { model.openMicrophoneSettings() }
            }
        }
    }

    private var optionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Mikrofon").font(.caption).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
                    Picker("Mikrofon", selection: Binding(
                        get: { model.selectedDeviceUID },
                        set: { model.setDevice(uid: $0) }
                    )) {
                        Text("Sistemski (\(model.defaultDeviceName))").tag(String?.none)
                        ForEach(model.devices.filter { $0.uid != nil }) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .disabled(model.isRecording)
                    .help(model.isRecording ? "Mikrofon se bira prije snimanja" : "Sistemski prati izbor u System Settings")
                }
                HStack {
                    Text("Čišćenje").font(.caption).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
                    Picker("Čišćenje", selection: Binding(
                        get: { model.selectedMode },
                        set: { model.setMode($0) }
                    )) {
                        ForEach(CleanMicMode.allCases, id: \.rawValue) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Text(model.selectedMode.help)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 70)
                Divider()
                HStack {
                    Text("Transkribuj i napravi izvještaj kad zaustavim").font(.caption)
                    Spacer()
                    Toggle("Automatska transkripcija", isOn: Binding(get: { model.autoTranscribe },
                                                                     set: { model.setAutoTranscribe($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                if model.autoTranscribe && !model.hasAPIKey {
                    HStack(spacing: 6) {
                        Image(systemName: "key.fill").foregroundStyle(.orange)
                        Text("Nedostaje OpenRouter ključ.").font(.caption2)
                        Button("Unesi…") { open("settings") }
                            .buttonStyle(.link)
                            .font(.caption2)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("Čišćenje lokalno · transkript preko OpenRoutera")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Menu {
                Button("Otvori postojeći snimak…") { model.chooseRecording() }
                Button("Folder sa snimcima") { model.openSaveFolder() }
                Divider()
                Button("Podešavanja…") { open("settings") }
                Divider()
                Button(model.isRecording ? "Sačuvaj snimak i izađi" : "Izađi") {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Image(systemName: "gearshape.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Podešavanja i izlaz")
        }
    }
}

// MARK: - Snimanje

private struct RecorderCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var meters: LiveMeters

    var body: some View {
        Card {
            if model.isRecording {
                VStack(spacing: 10) {
                    Text(Fmt.clock(meters.elapsedSeconds))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("\(Fmt.size(meters.bytes)) · \(model.activeMicName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    VStack(spacing: 6) {
                        LevelBar(label: "Ulaz", level: meters.input, tint: .blue)
                        LevelBar(label: "Čisto", level: meters.clean, tint: .green)
                    }
                    Button {
                        model.stopRecording()
                    } label: {
                        Label(model.isStopping ? "Čuvam…" : "Zaustavi i sačuvaj", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .disabled(model.isStopping)
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        model.startRecording()
                    } label: {
                        Label("Pokreni snimanje", systemImage: "record.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isStopping)
                    Text("Snima očišćen zvuk sve dok ne zaustaviš — bez vremenskog ograničenja.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Potvrda za snimak duži od 1 h

private struct ConfirmCard: View {
    @ObservedObject var model: AppModel
    let info: RecordingInfo

    var body: some View {
        let cost = TranscriptionService.estimatedCostUSD(seconds: info.duration)
        let eta = TranscriptionService.estimatedProcessingSeconds(audioSeconds: info.duration)
        VStack(alignment: .leading, spacing: 8) {
            Label("Snimak traje \(ReportService.humanDuration(info.duration))", systemImage: "clock.badge.exclamationmark")
                .font(.callout.weight(.semibold))
            Text("Duži je od 1 sata. Transkripcija šalje cijeli snimak na OpenRouter — oko \(Fmt.usd(cost)), obrada oko \(ReportService.humanDuration(eta)). Transkribovati?")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Transkribuj") { model.confirmPending() }
                    .buttonStyle(.borderedProminent)
                Button("Ne sada") { model.declinePending() }
                Spacer()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.45)))
    }
}

// MARK: - Posljednji snimak

private struct LastRecordingCard: View {
    @ObservedObject var model: AppModel
    let info: RecordingInfo
    let openReport: () -> Void
    @State private var copied = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Posljednji snimak").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { NSWorkspace.shared.open(info.url) } label: { Image(systemName: "play.fill") }
                        .help("Pusti snimak")
                    Button { NSWorkspace.shared.activateFileViewerSelecting([info.url]) } label: { Image(systemName: "folder") }
                        .help("Prikaži u Finderu")
                }
                .buttonStyle(.borderless)

                Text(info.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(ReportService.humanDuration(info.duration)) · \(Fmt.size(info.bytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.isTranscribing {
                    ProgressView(value: model.transcribeProgress)
                    Text(model.transcriptStatus).font(.caption).foregroundStyle(.secondary)
                } else {
                    if !model.transcriptStatus.isEmpty {
                        Label(model.transcriptStatus,
                              systemImage: model.transcriptFailed ? "exclamationmark.triangle.fill" : "info.circle")
                            .font(.caption)
                            .foregroundStyle(model.transcriptFailed ? Color.orange : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    results
                }
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        if !model.reportSummary.isEmpty {
            Divider()
            Text("Sažetak").font(.caption.weight(.semibold))
            Text(model.reportSummary)
                .font(.caption)
                .lineLimit(9)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack {
                Button("Otvori izvještaj", action: openReport)
                    .buttonStyle(.borderedProminent)
                Button(copied ? "Kopirano ✓" : "Kopiraj") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.reportMarkdown, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                Spacer()
                moreMenu
            }
            .controlSize(.small)
        } else if !model.transcriptText.isEmpty {
            // Transkript postoji, izvještaja nema (npr. izvještaj nije uspio).
            HStack {
                Button("Napravi izvještaj") { model.regenerateReport() }
                    .buttonStyle(.borderedProminent)
                Button("Transkript") { NSWorkspace.shared.open(info.transcriptURL) }
                Spacer()
            }
            .controlSize(.small)
        } else if model.pendingConfirm == nil {
            Button {
                model.requestTranscription(info)
            } label: {
                Label("Transkribuj i napravi izvještaj", systemImage: "text.bubble")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!model.hasAPIKey)
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Otvori transkript (.txt)") { NSWorkspace.shared.open(info.transcriptURL) }
            Button("Otvori izvještaj (.md)") { NSWorkspace.shared.open(info.reportURL) }
            Divider()
            Button("Ponovo napravi izvještaj") { model.regenerateReport() }
            Button("Ponovo transkribuj snimak") { model.requestTranscription(info) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
