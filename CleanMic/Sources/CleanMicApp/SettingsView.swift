import SwiftUI
import CleanMicCore

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            general.tabItem { Label("Opšte", systemImage: "gearshape") }
            transcript.tabItem { Label("Transkript", systemImage: "text.bubble") }
            about.tabItem { Label("O aplikaciji", systemImage: "info.circle") }
        }
        .frame(width: 540, height: 620)
        .background(FrontWindow())
    }

    // MARK: Opšte

    private var general: some View {
        Form {
            Section("Snimanje") {
                LabeledContent("Folder za snimke") {
                    HStack {
                        Text(model.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Button("Promijeni…") { model.chooseSaveFolder() }
                        Button("Otvori") { model.openSaveFolder() }
                    }
                }
                Text("Snima se sve dok ne zaustaviš. 16-bit WAV, oko 350 MB po satu; jedan fajl može do ~12 h.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Pokretanje") {
                Toggle("Pokreni CleanMic pri prijavi na Mac", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Text("Radi kad je CleanMic u folderu Applications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Dijagnostika") {
                LabeledContent("Log") {
                    Button("Prikaži log u Finderu") {
                        NSWorkspace.shared.activateFileViewerSelecting([DebugLog.fileURL])
                    }
                }
                Text("Ako transkripcija ili izvještaj ne uspiju, u logu piše zašto (bez ključa i bez sadržaja snimka).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Transkript

    private var transcript: some View {
        Form {
            Section("OpenRouter ključ") {
                HStack {
                    SecureField("sk-or-v1-…", text: $model.apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    Button("Sačuvaj") { model.saveKey() }
                    Button("Provjeri") { model.checkKey() }
                        .disabled(!model.hasAPIKey)
                }
                Text(model.hasAPIKey ? "Sačuvan: \(model.apiKeyHint)" : "Ključ nije postavljen — napravi ga na openrouter.ai/keys.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.keyCheckStatus.isEmpty {
                    Text(model.keyCheckStatus)
                        .font(.caption)
                        .foregroundStyle(model.keyCheckStatus.hasPrefix("✗") ? Color.red : Color.secondary)
                }
                Text("Ključ ostaje samo na ovom Macu (~/.config/cleanmic). Na svakom laptopu se unosi jednom.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Transkripcija i izvještaj") {
                Toggle("Transkribuj i napravi izvještaj kad zaustavim snimanje", isOn: Binding(
                    get: { model.autoTranscribe },
                    set: { model.setAutoTranscribe($0) }
                ))
                Picker("Jezik", selection: Binding(get: { model.transcribeLanguage }, set: { model.setLanguage($0) })) {
                    ForEach(model.languageOptions, id: \.code) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                Picker("Model za izvještaj", selection: Binding(get: { model.reportModelPickerValue },
                                                               set: { model.pickReportModel($0) })) {
                    ForEach(model.reportModelOptions, id: \.id) { option in
                        Text(option.id == OpenRouterConfig.reportModelDefault ? "\(option.name) (preporučeno)" : option.name)
                            .tag(option.id)
                    }
                    Divider()
                    Text("Drugi model…").tag(AppModel.customModelTag)
                }
                if model.customModelMode {
                    HStack {
                        TextField("ID sa openrouter.ai/models, npr. anthropic/claude-haiku-4.5", text: $model.customModelInput)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .onSubmit { model.applyCustomReportModel() }
                        Button("Provjeri i sačuvaj") { model.applyCustomReportModel() }
                    }
                    if !model.modelCheckStatus.isEmpty {
                        Text(model.modelCheckStatus)
                            .font(.caption)
                            .foregroundStyle(model.modelCheckStatus.hasPrefix("✗") ? Color.red : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                LabeledContent("Koristi se") {
                    Text(model.reportModel).foregroundStyle(.secondary).textSelection(.enabled)
                }
                LabeledContent("Model za transkript") {
                    Text(model.transcribeModel).foregroundStyle(.secondary)
                }
                Text("Snimak duži od 1 sata se ne šalje automatski — prvo se traži potvrda, uz procjenu troška.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: O aplikaciji

    private var about: some View {
        VStack(spacing: 12) {
            AppGlyph(size: 64)
            Text(model.versionText).font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                Label("Čišćenje zvuka (RNNoise) radi lokalno na ovom Macu.", systemImage: "lock.shield.fill")
                Label("Transkripcija i izvještaj šalju snimak na OpenRouter — samo kad je uključeno automatski ili kad klikneš Transkribuj.",
                      systemImage: "icloud.and.arrow.up")
                Label("Snimci, transkripti i izvještaji ostaju u tvom folderu za snimke.", systemImage: "folder")
            }
            .font(.callout)
            .frame(maxWidth: 420, alignment: .leading)
            Spacer()
        }
        .padding(24)
    }
}

/// Izvještaj u prozoru aplikacije — ne treba Markdown preglednik na svakom Macu.
struct ReportView: View {
    @ObservedObject var model: AppModel
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.lastRecording?.name ?? "Izvještaj").font(.headline).lineLimit(1).truncationMode(.middle)
                    if let info = model.lastRecording {
                        Text("\(ReportService.humanDuration(info.duration)) · \(Fmt.size(info.bytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(copied ? "Kopirano ✓" : "Kopiraj sve") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.reportMarkdown, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .disabled(model.reportMarkdown.isEmpty)
                Button("Prikaži u Finderu") {
                    if let info = model.lastRecording {
                        NSWorkspace.shared.activateFileViewerSelecting([info.reportURL])
                    }
                }
                .disabled(model.reportMarkdown.isEmpty)
            }
            .padding(12)
            Divider()
            if model.reportMarkdown.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Još nema izvještaja").font(.headline)
                    Text("Snimi nešto, pa će se ovdje pojaviti sažetak i transkript.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    MarkdownText(markdown: model.reportMarkdown)
                        .padding(20)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .background(FrontWindow())
    }
}
