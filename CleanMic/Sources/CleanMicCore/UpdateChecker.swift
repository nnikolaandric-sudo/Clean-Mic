import Foundation

/// Nova verzija na GitHub Releases. Aplikacija nije u App Storeu ni notarizovana, pa
/// nema ko drugi da korisniku javi da postoji novija — zato ovo provjerava sama.
public struct UpdateInfo: Equatable, Sendable {
    public let version: String
    /// Stranica izdanja (bilješke + preuzimanje).
    public let pageURL: URL
    /// Direktan link na .dmg, ako izdanje ima jedan.
    public let downloadURL: URL?
    public let notes: String

    /// Šta se otvara u pregledniku kad korisnik klikne "Preuzmi".
    public var openURL: URL { downloadURL ?? pageURL }
}

public enum AppVersion {
    /// Verzija ove aplikacije ("1.3.0"). CLI nema bundle, pa tamo "0".
    public static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Radi li aplikacija direktno iz otvorenog diska (DMG-a) umjesto iz Applications.
    /// Takva kopija nestaje kad se disk izbaci, ne pokreće se pri prijavi i ne može se ažurirati.
    public static var runsFromDiskImage: Bool {
        Bundle.main.bundlePath.hasPrefix("/Volumes/")
    }
}

public enum UpdateChecker {
    public static let repo = "nnikolaandric-sudo/Clean-Mic"

    public enum UpdateError: Error, CustomStringConvertible {
        case network(String)
        case http(Int)
        case badResponse

        public var description: String {
            switch self {
            case .network(let m): return "Nema veze sa GitHubom (\(m))."
            case .http(403), .http(429): return "GitHub trenutno ograničava zahtjeve. Pokušaj za sat vremena."
            case .http(let code): return "GitHub je vratio grešku \(code)."
            case .badResponse: return "Neočekivan odgovor GitHuba."
            }
        }
    }

    /// Je li `candidate` novija verzija od `current`? Poredi brojeve po dijelovima
    /// ("1.10.0" je novije od "1.9.0"), ignoriše vodeće "v" i sufiks poslije "-" ili "+".
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        guard !a.isEmpty, !b.isEmpty else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func components(_ version: String) -> [Int] {
        var v = version.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        if let cut = v.firstIndex(where: { $0 == "-" || $0 == "+" }) { v = String(v[..<cut]) }
        let parts = v.split(separator: ".").map { Int($0) }
        return parts.contains(where: { $0 == nil }) ? [] : parts.compactMap { $0 }
    }

    /// Iz JSON-a `releases/latest`. Linkove prihvata samo sa github.com preko https —
    /// odgovor se ne smije moći iskoristiti da korisnika pošalje negdje drugdje.
    public static func parse(_ json: [String: Any]) -> UpdateInfo? {
        guard let tag = json["tag_name"] as? String, !components(tag).isEmpty,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              isTrusted(page) else { return nil }
        var version = tag
        if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }

        var dmg: URL?
        for asset in (json["assets"] as? [[String: Any]]) ?? [] {
            guard let name = asset["name"] as? String, name.lowercased().hasSuffix(".dmg"),
                  let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
                  isTrusted(url) else { continue }
            dmg = url
            break
        }
        return UpdateInfo(version: version, pageURL: page, downloadURL: dmg, notes: (json["body"] as? String) ?? "")
    }

    static func isTrusted(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "github.com"
    }

    /// Najnovije izdanje ako je novije od `currentVersion`, inače nil. Sinhrono — zvati sa
    /// pozadinske niti (ili iz CLI-ja). Ne šalje ništa osim običnog GET zahtjeva.
    public static func check(currentVersion: String, timeout: TimeInterval = 10) throws -> UpdateInfo? {
        guard let latest = try latest(timeout: timeout) else { return nil }
        return isNewer(latest.version, than: currentVersion) ? latest : nil
    }

    /// Najnovije objavljeno izdanje (bez obzira na trenutnu verziju); nil ako ih još nema.
    public static func latest(timeout: TimeInterval = 10) throws -> UpdateInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { throw UpdateError.badResponse }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("CleanMic/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")

        let done = DispatchSemaphore(value: 0)
        let box = LockedBox<(Data?, URLResponse?, Error?)>((nil, nil, nil))
        URLSession.shared.dataTask(with: req) { data, resp, err in
            box.withLock { $0 = (data, resp, err) }
            done.signal()
        }.resume()
        done.wait()

        let (data, resp, err) = box.get
        if let err { throw UpdateError.network((err as NSError).localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw UpdateError.badResponse }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw UpdateError.http(http.statusCode) }
        guard let data, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let info = parse(json) else { throw UpdateError.badResponse }
        return info
    }
}
