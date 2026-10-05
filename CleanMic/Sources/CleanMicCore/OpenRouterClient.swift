import Foundation

public enum OpenRouterError: Error, CustomStringConvertible {
    case missingAPIKey
    case http(Int, String)
    case network(String)
    case badResponse(String)

    public var description: String {
        switch self {
        case .missingAPIKey:
            return "Nedostaje OpenRouter ključ. Unesi ga u Podešavanja → Transkript (ili: cleanmic-cli set-key sk-or-...)."
        case .http(401, _), .http(403, _):
            return "OpenRouter je odbio ključ (neispravan ili opozvan). Provjeri ključ u Podešavanja → Transkript."
        case .http(402, _):
            return "Nema dovoljno kredita na OpenRouter računu. Dopuni na openrouter.ai/credits."
        case .http(429, let m):
            return "OpenRouter trenutno ograničava zahtjeve (429). Pokušaj ponovo za minut. \(m)"
        case .http(let code, let m):
            return "OpenRouter greška \(code): \(m)"
        case .network(let m):
            return "Mrežna greška: \(m)"
        case .badResponse(let m):
            return "Neočekivan odgovor OpenRoutera: \(m)"
        }
    }

    /// Prolazne greške — vrijedi probati ponovo isti zahtjev.
    var isRetryable: Bool {
        switch self {
        case .network: return true
        case .http(let code, _): return code == 408 || code == 409 || code == 425 || code == 429 || code >= 500
        case .missingAPIKey, .badResponse: return false
        }
    }

    /// Ključ ili kredit — drugi model neće pomoći, odmah javi korisniku.
    var isAuthOrBilling: Bool {
        switch self {
        case .missingAPIKey: return true
        case .http(let code, _): return code == 401 || code == 402 || code == 403
        default: return false
        }
    }
}

/// Sinhroni HTTP prema OpenRouteru. Zvati sa pozadinske niti (ili iz CLI-ja).
public enum OpenRouterClient {
    public static func postJSON(url: URL, body: [String: Any], apiKey: String, timeout: TimeInterval) throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try send(req, apiKey: apiKey, timeout: timeout)
    }

    public static func getJSON(url: URL, apiKey: String?, timeout: TimeInterval) throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        return try send(req, apiKey: apiKey, timeout: timeout)
    }

    private static func send(_ request: URLRequest, apiKey: String?, timeout: TimeInterval) throws -> [String: Any] {
        var req = request
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("CleanMic (macOS)", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("CleanMic", forHTTPHeaderField: "X-Title")
        req.timeoutInterval = timeout

        let done = DispatchSemaphore(value: 0)
        let box = LockedBox<(Data?, URLResponse?, Error?)>((nil, nil, nil))
        URLSession.shared.dataTask(with: req) { data, resp, err in
            box.withLock { $0 = (data, resp, err) }
            done.signal()
        }.resume()
        done.wait()

        let (data, resp, err) = box.get
        if let err {
            throw OpenRouterError.network(err.localizedDescription)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            throw OpenRouterError.http(code, errorMessage(from: data))
        }
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenRouterError.badResponse("odgovor nije JSON (\(data?.count ?? 0) B)")
        }
        // OpenRouter zna vratiti HTTP 200 sa {"error": {...}} kad provider padne.
        if let e = json["error"] as? [String: Any] {
            let inner = (e["code"] as? Int) ?? 502
            throw OpenRouterError.http(inner, errorMessage(from: data))
        }
        return json
    }

    /// Izvuci čitljivu poruku iz {"error": {"message": ..., "metadata": {"raw": ...}}}.
    static func errorMessage(from data: Data?) -> String {
        guard let data, !data.isEmpty else { return "(prazan odgovor)" }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let e = json["error"] as? [String: Any] {
            var msg = (e["message"] as? String) ?? ""
            if let meta = e["metadata"] as? [String: Any], let raw = meta["raw"] as? String, !raw.isEmpty {
                msg += msg.isEmpty ? raw : " — \(raw)"
            }
            if !msg.isEmpty { return String(msg.prefix(400)) }
        }
        return String((String(data: data, encoding: .utf8) ?? "(binarni odgovor)").prefix(400))
    }

    // MARK: - Ključ

    public struct KeyInfo {
        public let label: String?
        public let usageUSD: Double?
        public let limitUSD: Double?
        public let remainingUSD: Double?

        public var summary: String {
            var parts: [String] = []
            if let u = usageUSD { parts.append(String(format: "potrošeno $%.2f", u)) }
            if let r = remainingUSD {
                parts.append(String(format: "preostalo $%.2f", r))
            } else if limitUSD == nil {
                parts.append("bez limita na ključu")
            }
            return parts.isEmpty ? "ključ je ispravan" : parts.joined(separator: " · ")
        }
    }

    /// Provjera da li ključ radi (ne troši kredit).
    public static func checkKey(_ apiKey: String) throws -> KeyInfo {
        let json = try getJSON(url: OpenRouterConfig.keyInfoURL, apiKey: apiKey, timeout: 20)
        let d = (json["data"] as? [String: Any]) ?? json
        func num(_ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
        return KeyInfo(label: d["label"] as? String,
                       usageUSD: num("usage"),
                       limitUSD: num("limit"),
                       remainingUSD: num("limit_remaining"))
    }

    // MARK: - Modeli

    public struct ModelInfo {
        public let id: String
        public let name: String
        public let contextLength: Int?
        /// USD po milion tokena.
        public let inputPerM: Double?
        public let outputPerM: Double?

        public var summary: String {
            var parts = [name]
            if let i = inputPerM, let o = outputPerM {
                parts.append(String(format: "$%.2f / $%.2f po milion tokena (ulaz / izlaz)", i, o))
            }
            if let c = contextLength { parts.append("kontekst \(c / 1000)k") }
            return parts.joined(separator: " · ")
        }
    }

    /// Javna lista chat modela (ne treba ključ). Transkripcijski modeli nisu na njoj.
    public static func listModels() throws -> [ModelInfo] {
        let json = try getJSON(url: OpenRouterConfig.modelsURL, apiKey: nil, timeout: 30)
        guard let data = json["data"] as? [[String: Any]] else {
            throw OpenRouterError.badResponse("lista modela nema 'data'")
        }
        func perM(_ value: Any?) -> Double? {
            guard let s = value as? String, let d = Double(s) else { return nil }
            return d * 1_000_000
        }
        return data.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            let pricing = m["pricing"] as? [String: Any]
            return ModelInfo(id: id,
                             name: (m["name"] as? String) ?? id,
                             contextLength: (m["context_length"] as? NSNumber)?.intValue,
                             inputPerM: perM(pricing?["prompt"]),
                             outputPerM: perM(pricing?["completion"]))
        }
    }

    /// nil ako model sa tim ID-jem ne postoji na OpenRouteru.
    public static func modelInfo(id: String) throws -> ModelInfo? {
        let wanted = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return try listModels().first(where: { $0.id == wanted })
    }
}
