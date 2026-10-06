import Foundation

/// Nova verzija preuzeta, provjerena i složena pored stare, spremna za zamjenu.
public struct StagedUpdate: Sendable {
    public let version: String
    /// `<stageDir>/CleanMic.app` — na istom disku kao `target`, pa je zamjena atomski `mv`.
    public let stagedApp: URL
    public let stageDir: URL
    /// Aplikacija koja se zamjenjuje (ona koja trenutno radi).
    public let target: URL
}

/// Samoažuriranje: preuzmi → provjeri potpis → izvuci iz DMG-a → provjeri aplikaciju → zamijeni.
///
/// Nikad se ne dira instalirana aplikacija dok sve prethodno nije uspjelo. Sama zamjena radi
/// mali skript koji sačeka da se CleanMic ugasi, odmakne staru verziju, stavi novu i pokrene je;
/// ako zamjena ne uspije, vraća staru.
public enum UpdateInstaller {
    public enum InstallError: Error, CustomStringConvertible {
        case notInstallable(String)
        case notNewer(String, String)
        case download(String)
        case tooSmall
        case disk(String)
        case invalidApp(String)

        public var description: String {
            switch self {
            case .notInstallable(let why): return "Ova kopija se ne može sama zamijeniti: \(why)."
            case .notNewer(let new, let current): return "Verzija \(new) nije novija od \(current)."
            case .download(let m): return "Preuzimanje nije uspjelo: \(m)"
            case .tooSmall: return "Preuzeti fajl je premali da bi bio CleanMic."
            case .disk(let m): return "Priprema nove verzije nije uspjela: \(m)"
            case .invalidApp(let m): return "Nova verzija ne prolazi provjeru: \(m)"
            }
        }
    }

    public static let appName = "CleanMic.app"
    private static let stagePrefix = ".CleanMic-update-"
    private static let backupSuffix = ".old-update"

    // MARK: - Može li se sama zamijeniti?

    /// nil = može. Inače razlog (ljudskim jezikom) — tada ostaje ručno preuzimanje.
    public static func cannotInstallReason(bundleURL: URL = Bundle.main.bundleURL) -> String? {
        let path = bundleURL.path
        if !path.hasSuffix(".app") { return "ne radi kao .app" }
        if path.hasPrefix("/Volumes/") { return "radi direktno sa diska; prevuci je u Applications" }
        if path.contains("/AppTranslocation/") { return "macOS je pokrenuo iz privremene kopije; prevuci je u Applications" }
        if !FileManager.default.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) {
            return "nemaš pravo upisa u \(bundleURL.deletingLastPathComponent().path)"
        }
        return nil
    }

    // MARK: - Priprema

    /// Preuzmi DMG i potpis, provjeri potpis, izvuci aplikaciju pored `target`-a i provjeri je.
    /// Blokira — zvati sa pozadinske niti. Instalirana aplikacija se u ovom koraku ne dira.
    public static func prepare(
        dmg dmgURL: URL, signature signatureURL: URL, version: String, currentVersion: String,
        target: URL, bundleID: String,
        publicKeyBase64: String = UpdateSigning.publicKeyBase64,
        progress: ((Double) -> Void)? = nil
    ) throws -> StagedUpdate {
        if let why = cannotInstallReason(bundleURL: target) { throw InstallError.notInstallable(why) }
        guard UpdateChecker.isNewer(version, than: currentVersion) else {
            throw InstallError.notNewer(version, currentVersion)
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("CleanMic-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 1) Preuzmi (potpis je mali tekst).
        let dmg = work.appendingPathComponent("CleanMic.dmg")
        try Downloader.fetch(dmgURL, to: dmg, progress: progress)
        let sigFile = work.appendingPathComponent("CleanMic.dmg.sig")
        try Downloader.fetch(signatureURL, to: sigFile, progress: nil)
        let signature = (try? String(contentsOf: sigFile, encoding: .utf8)) ?? ""

        // 2) Potpis. Ništa se ne montira ni otvara dok ovo ne prođe.
        let size = (try? fm.attributesOfItem(atPath: dmg.path)[.size] as? Int64) ?? 0
        guard size > 1_000_000 else { throw InstallError.tooSmall }
        do {
            try UpdateSigning.verify(dmg: dmg, version: version, signatureBase64: signature,
                                     publicKeyBase64: publicKeyBase64)
        } catch {
            throw InstallError.invalidApp("\(error)")
        }

        // 3) Izvuci aplikaciju iz DMG-a u folder pored instalirane.
        let stageDir = target.deletingLastPathComponent()
            .appendingPathComponent("\(stagePrefix)\(UUID().uuidString.prefix(8))", isDirectory: true)
        let stagedApp = stageDir.appendingPathComponent(appName)
        let mount = work.appendingPathComponent("mnt", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        do {
            try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
            let attach = try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly",
                                                      "-noautoopen", "-noverify", "-mountpoint", mount.path, "-quiet"])
            guard attach.status == 0 else { throw InstallError.disk("hdiutil attach: \(attach.output)") }
            defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"]) }

            let source = mount.appendingPathComponent(appName)
            guard fm.fileExists(atPath: source.path) else { throw InstallError.invalidApp("u DMG-u nema \(appName)") }
            let copy = try run("/usr/bin/ditto", [source.path, stagedApp.path])
            guard copy.status == 0 else { throw InstallError.disk("ditto: \(copy.output)") }
        } catch {
            try? fm.removeItem(at: stageDir)
            throw error
        }

        // 4) Provjeri to što smo izvukli.
        do {
            try validate(app: stagedApp, bundleID: bundleID, version: version)
        } catch {
            try? fm.removeItem(at: stageDir)
            throw error
        }
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", stagedApp.path])
        return StagedUpdate(version: version, stagedApp: stagedApp, stageDir: stageDir, target: target)
    }

    /// Ista aplikacija (bundle ID), tražena verzija, ispravan potpis, izvršni fajl postoji.
    static func validate(app: URL, bundleID: String, version: String) throws {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plistURL) as? [String: Any] else {
            throw InstallError.invalidApp("nema Info.plist")
        }
        guard info["CFBundleIdentifier"] as? String == bundleID else {
            throw InstallError.invalidApp("pogrešan bundle ID (\(info["CFBundleIdentifier"] as? String ?? "-"))")
        }
        guard info["CFBundleShortVersionString"] as? String == version else {
            throw InstallError.invalidApp("verzija u aplikaciji (\(info["CFBundleShortVersionString"] as? String ?? "-")) nije \(version)")
        }
        guard let exe = info["CFBundleExecutable"] as? String,
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/\(exe)").path) else {
            throw InstallError.invalidApp("nema izvršnog fajla")
        }
        let verify = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard verify.status == 0 else { throw InstallError.invalidApp("potpis aplikacije: \(verify.output)") }
    }

    // MARK: - Zamjena

    /// Pokreni odvojeni skript koji čeka da proces `pid` izađe, pa zamijeni aplikaciju.
    /// Zvati neposredno prije gašenja aplikacije; skript preživljava gašenje.
    public static func launchSwap(_ staged: StagedUpdate, pid: Int32 = getpid(), relaunch: Bool = true,
                                  waitSeconds: Double = 30, log: URL? = nil) throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanmic-swap-\(UUID().uuidString.prefix(8)).sh")
        try swapScript.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let logPath = (log ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CleanMic/update.log")).path
        let args = [script.path, String(pid), staged.target.path, staged.stagedApp.path,
                    relaunch ? "1" : "0", logPath, String(Int(waitSeconds * 10))]
        // nohup + & : skript ostaje živ i kad se roditelj ugasi.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "nohup /bin/sh \"$@\" >/dev/null 2>&1 &", "swap"] + args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
    }

    /// Argumenti: PID TARGET STAGED RELAUNCH(1|0) LOG WAIT_TENTHS_OF_SECOND
    static let swapScript = """
    #!/bin/sh
    PID="$1"; TARGET="$2"; STAGED="$3"; RELAUNCH="$4"; LOG="$5"; WAIT="${6:-300}"
    BACKUP="$TARGET\(backupSuffix)"
    mkdir -p "$(dirname "$LOG")"
    log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
    reopen() { [ "$RELAUNCH" = "1" ] && open -n "$TARGET"; }
    i=0
    while kill -0 "$PID" 2>/dev/null; do
      i=$((i+1))
      if [ "$i" -gt "$WAIT" ]; then log "aplikacija ($PID) se nije ugasila — odustajem, ništa nije dirnuto"; exit 1; fi
      sleep 0.1
    done
    if [ ! -d "$STAGED" ]; then log "nema pripremljene verzije: $STAGED"; reopen; exit 1; fi
    rm -rf "$BACKUP"
    if ! mv "$TARGET" "$BACKUP"; then log "ne mogu odmaknuti staru verziju"; reopen; exit 1; fi
    if mv "$STAGED" "$TARGET"; then
      log "zamijenjeno: $TARGET"
      rm -rf "$BACKUP" "$(dirname "$STAGED")"
      reopen
      exit 0
    else
      log "zamjena nije uspjela — vraćam staru verziju"
      mv "$BACKUP" "$TARGET"
      reopen
      exit 1
    fi
    """

    /// Ostaci prekinutog ažuriranja (pripremljeni folderi, stara verzija) — briše starije od 10 min.
    public static func cleanupLeftovers(near target: URL = Bundle.main.bundleURL) {
        let fm = FileManager.default
        let dir = target.deletingLastPathComponent()
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for url in items {
            let name = url.lastPathComponent
            guard name.hasPrefix(stagePrefix) || name.hasSuffix(backupSuffix) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) > 600 { try? fm.removeItem(at: url) }
        }
    }

    // MARK: - Pomoćno

    static func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Preuzimanje u fajl sa napretkom. `file://` se samo kopira (provjere i razvoj).
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var tempFile: URL?
    private var failure: String?
    private let progress: ((Double) -> Void)?

    private init(progress: ((Double) -> Void)?) { self.progress = progress }

    static func fetch(_ url: URL, to destination: URL, progress: ((Double) -> Void)?) throws {
        let fm = FileManager.default
        if url.isFileURL {
            try? fm.removeItem(at: destination)
            do { try fm.copyItem(at: url, to: destination) } catch {
                throw UpdateInstaller.InstallError.download("\(error.localizedDescription)")
            }
            progress?(1)
            return
        }
        let d = Downloader(progress: progress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 900
        let session = URLSession(configuration: config, delegate: d, delegateQueue: nil)
        var req = URLRequest(url: url)
        req.setValue("CleanMic/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        session.downloadTask(with: req).resume()
        d.done.wait()
        session.finishTasksAndInvalidate()

        let (file, failure) = d.lock.withLock { (d.tempFile, d.failure) }
        if let failure { throw UpdateInstaller.InstallError.download(failure) }
        guard let file else { throw UpdateInstaller.InstallError.download("nema podataka") }
        try? fm.removeItem(at: destination)
        do { try fm.moveItem(at: file, to: destination) } catch {
            throw UpdateInstaller.InstallError.download("\(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress?(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // `location` se briše čim ova metoda završi — premjesti odmah.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            lock.withLock { failure = "HTTP \(http.statusCode)" }
            return
        }
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("cleanmic-dl-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: keep)
            lock.withLock { tempFile = keep }
        } catch {
            lock.withLock { failure = error.localizedDescription }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { lock.withLock { failure = (error as NSError).localizedDescription } }
        done.signal()
    }
}
