import SwiftUI
import CleanMicCore

// MARK: - Formatiranje

enum Fmt {
    /// 00:12:34 — veliki tajmer u popoveru.
    static func clock(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    /// 12:34 ili 1:02:03 — kratko, za menu bar.
    static func short(_ seconds: Int) -> String {
        seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func usd(_ value: Double) -> String {
        String(format: "$%.2f", max(value, 0.01))
    }
}

extension CleanMicMode {
    var label: String {
        switch self {
        case .light: return "Blago"
        case .balanced: return "Balansirano"
        case .maximum: return "Maksimalno"
        }
    }

    var help: String {
        switch self {
        case .light: return "Najprirodniji glas — za tihu sobu."
        case .balanced: return "Preporučeno — kancelarija, kafić."
        case .maximum: return "Najjače čišćenje — ventilator, ulica."
        }
    }
}

// MARK: - Gradivni elementi

struct Card<Content: View>: View {
    private let content: Content

    init(@ViewBuilder _ content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct AppGlyph: View {
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.55, blue: 0.98), Color(red: 0.30, green: 0.26, blue: 0.86)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(Image(systemName: "waveform")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white))
    }
}

struct StatusChip: View {
    let text: String
    let color: Color
    var pulsing = false
    @State private var dim = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
                .opacity(pulsing && dim ? 0.3 : 1)
            Text(text).font(.caption).fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
        }
    }
}

/// Nivo na dB skali (−60 dB … 0 dB), da se i tih govor vidi na metru.
struct LevelBar: View {
    let label: String
    let level: Float
    let tint: Color

    private var fraction: CGFloat {
        let db = 20 * log10(max(level, 0.000_01))
        return CGFloat(min(1, max(0, (db + 60) / 60)))
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(tint.gradient)
                        .frame(width: max(6, geo.size.width * fraction))
                        .animation(.linear(duration: 0.1), value: fraction)
                }
            }
            .frame(height: 6)
        }
    }
}

struct BannerView: View {
    let banner: Banner
    let dismiss: () -> Void

    private var style: (icon: String, color: Color, text: String) {
        switch banner {
        case .info(let t): return ("info.circle.fill", .blue, t)
        case .warning(let t): return ("exclamationmark.triangle.fill", .orange, t)
        case .error(let t): return ("xmark.octagon.fill", .red, t)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: style.icon).foregroundStyle(style.color)
            Text(style.text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Zatvori")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(style.color.opacity(0.12)))
    }
}

// MARK: - Prozori

/// Menu-bar (accessory) aplikacija nema Dock ikonu, pa njeni prozori ne dolaze
/// sami u prvi plan. Iznad full-screen aplikacije se bez ovoga uopšte ne vide:
/// izmjereno — prozor Podešavanja se otvori i za ~1 s ostane na drugom Space-u.
/// Zato prozor ide na aktivni Space, smije stajati uz full-screen prozor i
/// eksplicitno se dovodi naprijed.
struct FrontWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // fullScreenPrimary (koji SwiftUI stavlja na prozore promjenjive veličine)
            // i fullScreenAuxiliary se međusobno isključuju.
            var behavior = window.collectionBehavior
            behavior.remove([.fullScreenPrimary, .canJoinAllSpaces])
            behavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
            window.collectionBehavior = behavior
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }
}

// MARK: - Markdown

/// Prikaz izvještaja: naslovi, stavke i pasusi. Dovoljno za ono što ReportService
/// pravi, bez vanjske biblioteke — izvještaj se čita isto na svakom Macu.
struct MarkdownText: View {
    let markdown: String

    private enum Block {
        case h1(String), h2(String), h3(String), bullet(String), paragraph(String)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("### ") {
                out.append(.h3(String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                out.append(.h2(String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                out.append(.h1(String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                out.append(.bullet(String(line.dropFirst(2))))
            } else {
                out.append(.paragraph(line))
            }
        }
        return out
    }

    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .h1(let t):
                    Text(inline(t)).font(.title2.bold())
                case .h2(let t):
                    Text(inline(t)).font(.title3.bold()).padding(.top, 10)
                case .h3(let t):
                    Text(inline(t)).font(.headline).padding(.top, 4)
                case .bullet(let t):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(t)).fixedSize(horizontal: false, vertical: true)
                    }
                case .paragraph(let t):
                    Text(inline(t)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}
