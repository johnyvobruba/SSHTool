import Foundation
import AppKit
import SwiftUI

// RDP přes FreeRDP 3 (SDL klient) – každá relace se otevře ve vlastním okně FreeRDP.
// Instalace: brew install freerdp. S uloženým heslem se celý příkazový řádek (včetně /p:) předává
// přes stdin (/args-from:stdin) – heslo nikdy není v argumentech procesu (bylo by vidět v `ps`).
// Bez uloženého hesla se FreeRDP zeptá ve vlastním okně.

enum FreeRDP {
    static let candidates = ["sdl-freerdp", "sdl-freerdp3", "sdl3-freerdp", "xfreerdp3", "xfreerdp"]
    static let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

    /// Cesta ke klientovi: vlastní z nastavení, jinak první nalezený (SDL má přednost – nepotřebuje XQuartz).
    @MainActor static var binary: String? {
        let custom = Prefs.current.freerdpPath.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return FileManager.default.isExecutableFile(atPath: custom) ? custom : nil }
        // přibalený v aplikaci (vydání z GitHubu)
        // (od 0.26.5 jako vnořená SSHTool-RDP.app kvůli ikoně v Docku; starší umístění jako záloha)
        for rel in ["Contents/Helpers/SSHTool-RDP.app/Contents/MacOS/sdl-freerdp", "Contents/Helpers/FreeRDP/sdl-freerdp"] {
            let bundled = Bundle.main.bundleURL.appendingPathComponent(rel).path
            if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        }
        for c in candidates { for d in dirs where FileManager.default.isExecutableFile(atPath: "\(d)/\(c)") { return "\(d)/\(c)" } }
        return nil
    }

    @MainActor static func missingAlert() {
        let a = NSAlert()
        a.messageText = "FreeRDP není nainstalovaný"
        a.informativeText = "Tato kopie SSHTool nemá FreeRDP přibalený (vydání z GitHubu ho obsahují).\n\nNainstaluj ho v Terminálu:\n    brew install freerdp\n\nPokud je jinde, nastav cestu v Nastavení → Obecné → FreeRDP."
        a.addButton(withTitle: "Kopírovat příkaz")
        a.addButton(withTitle: "Zavřít")
        if a.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("brew install freerdp", forType: .string)
        }
    }

    /// Velikost okna pro start relace: viditelná plocha hlavní obrazovky (body), ne výchozích 1024×768.
    @MainActor static var initialSize: String? {
        guard let f = NSScreen.main?.visibleFrame, f.width > 400, f.height > 300 else { return nil }
        return "\(Int(f.width))x\(Int(f.height) - 32)"      // rezerva na titulek okna
    }

    /// Log poslední relace: ~/Library/Logs/SSHTool/rdp-<název>.log
    static func logURL(for s: SSHSession) -> URL {
        let safe = String(s.name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" })
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SSHTool", isDirectory: true)
            .appendingPathComponent("rdp-\(safe.isEmpty ? s.id.uuidString : safe).log")
    }

    /// Vybrané sdílené složky jako (název ve Windows, cesta). Neexistující se přeskočí, názvy jsou unikátní.
    static func sharedFolders(_ s: SSHSession) -> [(String, String)] {
        var used: Set<String> = s.rdpShareHome ? ["home"] : []
        var out: [(String, String)] = []
        for path in s.rdpFolders {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            // název disku: poslední část cesty, bez čárek (oddělovač argumentu) a zpětných lomítek
            var base = URL(fileURLWithPath: path).lastPathComponent
                .replacingOccurrences(of: ",", with: "_").replacingOccurrences(of: "\\", with: "_")
            if base.isEmpty || base == "/" { base = "Mac" }
            var name = base, n = 2
            while used.contains(name.lowercased()) { name = "\(base)-\(n)"; n += 1 }
            used.insert(name.lowercased())
            out.append((name, path))
        }
        return out
    }

    /// Měřítko Windows plochy. Automaticky: celá obrazovka na Retině 150 %, jinak 100 % (bez parametru).
    /// Dynamický režim posílá velikost v bodech – tam by vyšší měřítko vše ještě zvětšilo.
    @MainActor static func scale(for s: SSHSession) -> Int? {
        if s.rdpScale > 0 { return s.rdpScale == 100 ? nil : s.rdpScale }
        guard s.rdpSize == "fullscreen", (targetScreen(s)?.backingScaleFactor ?? 1) >= 2 else { return nil }
        return 150
    }

    // MARK: Monitor pro celou obrazovku

    /// Obrazovka, na které se má relace otevřít: zvolená podle názvu, jinak ta s oknem SSHTool.
    @MainActor static func targetScreen(_ s: SSHSession) -> NSScreen? {
        if !s.rdpMonitor.isEmpty, let sc = NSScreen.screens.first(where: { $0.localizedName == s.rdpMonitor }) { return sc }
        return NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
    }

    /// Monitory podle FreeRDP (`/list:monitor`): ID → název. Řádky typu „ * [1] [Built-in Retina Display] 1470x956 +0+0“.
    static func listMonitors(bin: String) -> [(id: Int, name: String)] {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["/list:monitor"]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return [] }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let re = try? NSRegularExpression(pattern: #"\[(\d+)\]\s+\[([^\]]+)\]"#) else { return [] }
        var res: [(Int, String)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let l = String(line)
            guard let m = re.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
                  let r1 = Range(m.range(at: 1), in: l), let r2 = Range(m.range(at: 2), in: l),
                  let id = Int(l[r1]) else { continue }
            res.append((id, String(l[r2])))
        }
        return res
    }

    /// Argumenty pro FreeRDP (bez hesla).
    @MainActor static func arguments(_ s: SSHSession) -> [String] {
        let host = s.host.contains(":") && !s.host.hasPrefix("[") ? "[\(s.host)]" : s.host
        var a = ["/v:\(host):\(s.port)", "/title:SSHTool – \(s.name)"]
        if !s.user.isEmpty { a.append("/u:\(s.user)") }
        if !s.rdpDomain.isEmpty { a.append("/d:\(s.rdpDomain)") }
        switch s.rdpSize {
        case "fullscreen": a.append("/f")
        case "dynamic", "":
            a.append("/dynamic-resolution")
            if let size = initialSize { a.append("/size:\(size)") }
        default: a.append("/size:\(s.rdpSize)")
        }
        if let scale = scale(for: s), !s.rdpExtraArgs.contains("/scale-desktop") { a.append("/scale-desktop:\(scale)") }
        if s.rdpMultiMon { a.append("/multimon") }
        else if s.rdpSize == "fullscreen", let mid = s.rdpMonitorID, !s.rdpExtraArgs.contains("/monitors") {
            a.append("/monitors:\(mid)")
        }
        // levý ⌘ (RDP scancode LWin 0x15B) → levý Ctrl (0x1D); ruční /kbd v Dalších argumentech má přednost
        if s.rdpMacKeys, !s.rdpExtraArgs.contains("/kbd:") { a.append("/kbd:remap:0x15b=0x1d") }
        a.append(s.rdpClipboard ? "+clipboard" : "-clipboard")
        if s.rdpShareHome { a.append("/drive:Home,\(NSHomeDirectory())") }
        for (name, path) in sharedFolders(s) { a.append("/drive:\(name),\(path)") }
        if !s.rdpGateway.isEmpty { a.append("/g:\(s.rdpGateway)") }
        if s.rdpCertPolicy == "tofu" { a.append("/cert:tofu") }      // „ignore“ se záměrně nenabízí
        if !s.rdpSecurity.isEmpty { a.append("/sec:\(s.rdpSecurity)") }
        if s.rdpBpp > 0 { a.append("/bpp:\(s.rdpBpp)") }
        if !s.rdpGfx { a.append("-gfx") }
        if !s.rdpUDP { a.append("-multitransport") }
        if s.rdpDebugLog { a.append("/log-level:DEBUG") }
        // INFO jen pro client.common – zpráva o přihlášení (Logon Info) = relace se úspěšně spustila
        else { a.append("/log-filters:com.freerdp.client.common:INFO") }
        a += s.rdpExtraArgs.split(separator: " ").map(String.init)
        return a
    }

    @MainActor static func commandLine(_ s: SSHSession) -> String {
        (["sdl-freerdp"] + arguments(s)).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    }
}

/// Běžící RDP relace (procesy FreeRDP).
@MainActor
final class RDPLauncher: ObservableObject {
    static let shared = RDPLauncher()
    @Published private(set) var running: [UUID: Process] = [:]
    /// Relace ukončené uživatelem z SSHTool (⏏ / Odpojit) – po ukončení se nehlásí chyba.
    private var stopping: Set<UUID> = []
    /// Značky ve výstupu FreeRDP, že proběhlo přihlášení do Windows.
    static let logonMarkers = ["save_session_info", "Logon Extended Info", "LogonId"]
    var onChange: (() -> Void)?

    func isRunning(_ id: UUID) -> Bool { running[id] != nil }

    /// Finder: výběr složek ke sdílení jen pro toto připojení. nil = uživatel zrušil celé připojení.
    static func pickFolders(for s: SSHSession) -> [String]? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        p.canCreateDirectories = true
        p.prompt = "Sdílet a připojit"
        p.message = "Složky Macu, které budou v relaci „\(s.name)“ dostupné jako \\\\tsclient\\<název>"
        p.directoryURL = URL(fileURLWithPath: s.rdpFolders.last ?? NSHomeDirectory())
        guard p.runModal() == .OK else { return nil }
        return p.urls.map(\.path)
    }

    /// Připojení se složkami vybranými ve Finderu (jen pro tuto relaci, do serveru se neukládají).
    func launchWithFolderPicker(_ s: SSHSession) {
        guard let picked = Self.pickFolders(for: s) else { return }
        var t = s
        t.rdpFolders += picked.filter { !t.rdpFolders.contains($0) }
        t.rdpAskFolder = false
        launch(t)
    }

    func launch(_ s: SSHSession, confirmed: Bool = false) {
        if s.rdpAskFolder { launchWithFolderPicker(s); return }
        if !confirmed, let p = running[s.id], p.isRunning {
            let a = NSAlert()
            a.messageText = "RDP relace „\(s.name)“ už běží"
            a.informativeText = "Okno FreeRDP najdeš v Docku / ⌘Tab. Otevřít další relaci?"
            a.addButton(withTitle: "Otevřít další"); a.addButton(withTitle: "Zrušit")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        guard let bin = FreeRDP.binary else { FreeRDP.missingAlert(); return }
        // přibalená SSHTool-RDP.app: karanténa by vedla k „Not Opened“ od Gatekeeperu → odstranit předem
        if let r = bin.range(of: ".app/Contents/MacOS/") {
            let helper = URL(fileURLWithPath: String(bin[..<r.lowerBound]) + ".app")
            let left = Quarantine.strip(helper)
            if !left.isEmpty {
                let a = NSAlert(); a.alertStyle = .warning
                a.messageText = "macOS blokuje přibalený FreeRDP (karanténa)"
                a.informativeText = "Aplikace má po stažení atribut karantény a Gatekeeper by spuštění RDP zablokoval.\n\n" + Quarantine.manualFix
                a.addButton(withTitle: "Kopírovat příkazy"); a.addButton(withTitle: "Zavřít")
                if a.runModal() == .alertFirstButtonReturn {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("sudo chmod -R u+w /Applications/SSHTool.app\nxattr -dr com.apple.quarantine /Applications/SSHTool.app", forType: .string)
                }
                return
            }
        }
        if s.envTag == "prod", !confirmed {
            let a = NSAlert(); a.alertStyle = .warning
            a.messageText = "Připojit se k produkčnímu serveru \(s.name)?"
            a.informativeText = "\(s.host) je označený jako PROD."
            a.addButton(withTitle: "Připojit"); a.addButton(withTitle: "Zrušit")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        Self.showHotkeysOnce()
        let stored = s.hasStoredPassword
        let sid = s.id.uuidString, needAuth = s.requireUserAuth, name = s.name
        // celá obrazovka: na kterém monitoru (název z macOS → ID podle FreeRDP)
        let wantFull = s.rdpSize == "fullscreen" && !s.rdpMultiMon
        let screenName = wantFull ? FreeRDP.targetScreen(s)?.localizedName : nil
        Task.detached {
            var password: String?
            if stored {
                if needAuth, !UserAuth.authenticate(reason: "použít uložené heslo pro RDP „\(name)“") { return }
                password = KeychainStore.password(for: sid)
            }
            var t = s
            if let screenName {
                t.rdpMonitorID = FreeRDP.listMonitors(bin: bin).first(where: { $0.name == screenName })?.id
            }
            await MainActor.run { self.start(bin: bin, session: t, password: password) }
        }
    }

    // MARK: Automatická detekce kompatibilního režimu

    /// Chyby, u kterých má smysl zkusit kompatibilnější nastavení (grafika, transport, vyjednání zabezpečení).
    private static let retryMarkers = ["TRANSPORT_FAILED", "wait_for_activation", "ACTIVATION", "SECURITY_NEGO",
                                       "nla_recv", "nla_client", "credssp", "CredSSP", "post_connect"]
    /// Chyby, kde další pokus nic nevyřeší (heslo, účet, certifikát, síť, zrušení) – neopakovat.
    private static let noRetryMarkers = ["LOGON_FAILURE", "AUTHENTICATION_FAILED", "PASSWORD", "ACCOUNT_", "LOGON_TYPE",
                                         "WRONG_PASSWORD", "ACCESS_DENIED", "CONNECT_CANCELLED", "DNS_NAME_NOT_FOUND",
                                         "ERRCONNECT_CONNECT_FAILED", "INSUFFICIENT_PRIVILEGES"]

    static func isRetryable(_ log: String) -> Bool {
        if noRetryMarkers.contains(where: { log.contains($0) }) { return false }
        return retryMarkers.contains(where: { log.contains($0) })
    }

    /// Další stupeň kompatibility: 1) bez GFX/UDP, 24 bit  2) TLS místo NLA (jen se souhlasem a jen při „Automaticky“).
    static func nextStep(after s: SSHSession) -> (session: SSHSession, needsConsent: Bool)? {
        var n = s
        if s.rdpGfx || s.rdpUDP || (s.rdpBpp != 24 && s.rdpBpp != 16) {
            n.rdpGfx = false; n.rdpUDP = false
            if n.rdpBpp != 16 { n.rdpBpp = 24 }
            return (n, false)
        }
        if s.rdpSecurity.isEmpty {          // výslovně zvolené NLA/TLS/RDP se nemění
            n.rdpSecurity = "tls"
            return (n, true)
        }
        return nil
    }

    private func confirmTLS(_ s: SSHSession) -> Bool {
        let a = NSAlert(); a.alertStyle = .warning
        a.messageText = "RDP „\(s.name)“ se nepřipojilo ani v kompatibilním režimu"
        var info = "Server zřejmě nezvládá přihlášení přes NLA. Lze to zkusit přes TLS bez NLA.\n\n" +
            "Bez NLA server ukáže přihlašovací obrazovku ještě před ověřením uživatele. Pokud to nečekáš " +
            "(server dřív přes NLA fungoval), může jít o pokus o downgrade útočníkem v síti – v tom případě nepokračuj."
        if s.envTag == "prod" { info += "\n\nServer je označený jako PROD." }
        a.informativeText = info
        a.addButton(withTitle: "Připojit přes TLS a zapamatovat")
        a.addButton(withTitle: "Zrušit")
        return a.runModal() == .alertFirstButtonReturn
    }

    /// Uloží nastavení, se kterým se relace úspěšně spustila (jen 4 pole kompatibility).
    private func persist(_ tuned: SSHSession) {
        guard let store = AppStore.shared, let i = store.sessions.firstIndex(where: { $0.id == tuned.id }) else { return }
        store.sessions[i].rdpGfx = tuned.rdpGfx
        store.sessions[i].rdpUDP = tuned.rdpUDP
        store.sessions[i].rdpBpp = tuned.rdpBpp
        store.sessions[i].rdpSecurity = tuned.rdpSecurity
        var parts = ["grafický kanál GFX vypnut", "UDP vypnuto", "\(tuned.rdpBpp) bit"]
        if !tuned.rdpSecurity.isEmpty { parts.append("zabezpečení \(tuned.rdpSecurity.uppercased())") }
        let a = NSAlert()
        a.messageText = "RDP „\(tuned.name)“: uloženo kompatibilní nastavení"
        a.informativeText = parts.joined(separator: ", ") +
            ".\n\nPříště se použije rovnou. Změnit nebo vrátit ho můžeš v editoru serveru (Zabezpečení a kompatibilita)."
        a.runModal()
    }

    private func start(bin: String, session s: SSHSession, password: String?, tuned: Bool = false) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        // přibalený OpenSSL legacy provider (MD4 → NTLM → NLA bez domény)
        let binDir = URL(fileURLWithPath: bin).deletingLastPathComponent()
        if let modules = [binDir.appendingPathComponent("../Frameworks/ossl-modules").standardized.path,
                          binDir.appendingPathComponent("ossl-modules").path]
            .first(where: { FileManager.default.fileExists(atPath: $0 + "/legacy.dylib") }) {
            var env = ProcessInfo.processInfo.environment
            env["OPENSSL_MODULES"] = modules
            p.environment = env
        }
        let args = FreeRDP.arguments(s)
        p.arguments = password == nil ? args : ["/args-from:stdin"]
        let inPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = errPipe            // WLog píše část chyb na stdout – sbíráme obojí
        p.standardError = errPipe
        let errBox = Box<String>("")
        let df = ISO8601DateFormatter()
        let shown = args.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
        let sink = RDPLogSink(url: FreeRDP.logURL(for: s), fresh: !tuned,
                              header: "\n===== \(df.string(from: Date())) · \(tuned ? "kompatibilní pokus" : "připojení") · \(s.name)\n" +
                                      "FreeRDP: \(bin)\nArgumenty: \(shown)\(password == nil ? "" : " /p:********")\n\n",
                              secret: password)
        let loggedOn = Box<Bool>(false), persisted = Box<Bool>(false)
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            let text = String(decoding: d, as: UTF8.self)
            sink.write(text)
            if !loggedOn.value, RDPLauncher.logonMarkers.contains(where: { text.contains($0) }) {
                loggedOn.value = true
                if tuned {
                    // přihlášení v upraveném režimu prošlo → uložit nastavení hned (ne až po 30 s)
                    DispatchQueue.main.async {
                        guard !persisted.value else { return }
                        persisted.value = true
                        self.persist(s)
                    }
                }
            }
            errBox.mutate {
                $0 += text
                if $0.count > 64000 { $0 = String($0.suffix(48000)) }
            }
        }
        let started = Date(), id = s.id, name = s.name
        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            sink.close("\n===== konec · kód \(code) · \(Int(Date().timeIntervalSince(started))) s\n")
            DispatchQueue.main.async {
                if self.running[id] === proc { self.running[id] = nil }
                self.stopWatch(id, pid: proc.processIdentifier)
                let byUser = self.stopping.remove(id) != nil
                self.onChange?()
                // relace proběhla (přihlášení) nebo ji ukončil uživatel → zavření okna není chyba
                if loggedOn.value || byUser { return }
                // rychlé ukončení s chybou = chyba připojení / přihlášení
                guard code != 0, Date().timeIntervalSince(started) < 90 else { return }
                if errBox.value.contains("CONNECT_CANCELLED") { return }      // zrušeno uživatelem (okno/dialog)
                let log = errBox.value
                if s.rdpAutoDetect, RDPLauncher.isRetryable(log), let step = RDPLauncher.nextStep(after: s) {
                    if step.needsConsent, !self.confirmTLS(s) { return }
                    self.start(bin: bin, session: step.session, password: password, tuned: true)
                    return
                }
                let lines = log.split(whereSeparator: \.isNewline).map(String.init)
                    .filter { $0.contains("ERROR") || $0.contains("error") || $0.contains("failed") }
                let a = NSAlert()
                a.messageText = "RDP „\(name)“ se nepřipojilo (kód \(code))"
                var info = lines.suffix(4).joined(separator: "\n")
                if info.isEmpty { info = "FreeRDP skončil chybou. Zkontroluj host, port a přihlašovací údaje." }
                if tuned { info += "\n\nZkoušel jsem i kompatibilní režim (bez GFX/UDP, 24 bit\(s.rdpSecurity == "tls" ? ", TLS" : ""))." }
                a.informativeText = info
                a.addButton(withTitle: "OK")
                a.addButton(withTitle: "Zobrazit log")
                if a.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(FreeRDP.logURL(for: s)) }
            }
        }
        do {
            try p.run()
        } catch {
            sink.close("Spuštění selhalo: \(error.localizedDescription)\n")
            let a = NSAlert(); a.messageText = "FreeRDP nelze spustit"; a.informativeText = error.localizedDescription; a.runModal()
            return
        }
        if let password {
            // jeden argument na řádek; heslo jen tady (stdin), ne v argv
            inPipe.fileHandleForWriting.write(Data((args + ["/p:\(password)"]).joined(separator: "\n").utf8 + Data("\n".utf8)))
        }
        try? inPipe.fileHandleForWriting.close()
        running[s.id] = p
        onChange?()
        if s.rdpSize == "fullscreen", !s.rdpMultiMon, s.rdpAutoMonitor {
            currentScreen[s.id] = nil
            startWatch(s, pid: p.processIdentifier, ready: loggedOn)
        }
        if tuned {
            // relace v upraveném režimu vydržela → nastavení uložit do serveru
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak p] in
                guard let p, p.isRunning, !persisted.value else { return }
                persisted.value = true
                self.persist(s)
            }
        }
    }

    static let hotkeysText = """
    Okno FreeRDP se ovládá zkratkami s pravým Shiftem:
      pravý ⇧ + Enter – celá obrazovka / okno
      pravý ⇧ + D – odpojit relaci
      pravý ⇧ + M – minimalizovat
      pravý ⇧ + G – zachytávání klávesnice (⌘Tab apod. jde do Windows)
      pravý ⇧ + R – povolit změnu velikosti okna
    Odpojit jde také tlačítkem ⏏ u serveru v levém panelu SSHTool.
    """

    private static func showHotkeysOnce() {
        let key = "SSHTool.rdpHotkeysShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let a = NSAlert()
        a.messageText = "Ovládání RDP relace"
        a.informativeText = hotkeysText
        a.runModal()
    }

    /// Odpojí běžící relaci a připojí ji znovu na zvoleném monitoru (Windows relace zůstává, okna se neztratí).
    /// monitor != nil → celá obrazovka na tomto monitoru; nil → stejné rozložení jako dosud.
    func reconnect(_ s: SSHSession, monitor: String?) {
        var t = s
        if let monitor { t.rdpMonitor = monitor; t.rdpSize = "fullscreen" }
        t.rdpAskFolder = false
        t.rdpMonitorID = nil
        stopWatch(s.id)
        guard let p = running[s.id] else { launch(t); return }
        stopping.insert(s.id)
        p.terminate()
        // již potvrzeno (PROD) – bez dalších dotazů
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.launch(t, confirmed: true) }
    }

    /// Změna měřítka (DPI) ve Windows – uloží se k serveru a běžící relace se přepojí.
    func setScale(_ s: SSHSession, _ value: Int) {
        if let store = AppStore.shared, let i = store.sessions.firstIndex(where: { $0.id == s.id }) {
            store.sessions[i].rdpScale = value
        }
        var t = s
        t.rdpScale = value
        guard isRunning(s.id) else { return }
        reconnect(t, monitor: t.rdpSize == "fullscreen" ? currentScreen[s.id] : nil)
    }

    // MARK: Hlídání monitoru (celá obrazovka)
    // FreeRDP (SDL) po přesunu celé obrazovky na jiný monitor nepošle nové rozlišení → plocha se ořízne.
    // SSHTool proto sleduje, na kterém monitoru je okno relace (CGWindowList – pozice oken jiných aplikací
    // nevyžaduje žádné oprávnění), a když okno 2 s zůstane na jiném monitoru, relaci na něm přepojí.

    private struct Watch { let timer: Timer; let pid: Int32; let ready: Box<Bool> }
    private var watches: [UUID: Watch] = [:]
    private var currentScreen: [UUID: String] = [:]
    private var pendingScreen: [UUID: (name: String, ticks: Int)] = [:]

    /// ready = přihlášení do Windows proběhlo (do té doby je vidět jen připojovací dialog – ten se nehlídá).
    private func startWatch(_ s: SSHSession, pid: Int32, ready: Box<Bool>) {
        stopWatch(s.id)
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async { self.tick(s, pid: pid) }
        }
        watches[s.id] = Watch(timer: timer, pid: pid, ready: ready)
    }

    private func stopWatch(_ id: UUID, pid: Int32? = nil) {
        guard let w = watches[id], pid == nil || w.pid == pid else { return }
        w.timer.invalidate()
        watches[id] = nil
        pendingScreen[id] = nil
    }

    /// Název monitoru, na kterém je největší okno daného procesu (nil = okno teď není vidět, např. jiný Space).
    static func screenOfWindow(pid: Int32) -> String? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        var best: CGRect = .zero
        for w in info {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
            if r.width * r.height > best.width * best.height { best = r }
        }
        guard best.width > 200, let primary = NSScreen.screens.first else { return nil }
        // CG souřadnice (počátek vlevo nahoře) → AppKit (vlevo dole)
        let center = NSPoint(x: best.midX, y: primary.frame.maxY - best.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) })?.localizedName
    }

    private func tick(_ s: SSHSession, pid: Int32) {
        guard let w = watches[s.id], w.pid == pid, w.ready.value else { return }
        guard let name = Self.screenOfWindow(pid: pid) else { return }
        guard let current = currentScreen[s.id] else { currentScreen[s.id] = name; return }
        if name == current { pendingScreen[s.id] = nil; return }
        let n = (pendingScreen[s.id]?.name == name ? pendingScreen[s.id]!.ticks : 0) + 1
        pendingScreen[s.id] = (name, n)
        if n >= 2 {                                   // okno je na jiném monitoru ≥ 2 s
            currentScreen[s.id] = name
            reconnect(s, monitor: name)
        }
    }

    func disconnect(_ id: UUID) {
        guard let p = running[id] else { return }
        stopping.insert(id)
        p.terminate()
    }
}

/// Zápis výstupu FreeRDP do logu (z vlákna čtení roury). Heslo se v logu maskuje.
final class RDPLogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var h: FileHandle?
    private let secret: String?

    init(url: URL, fresh: Bool, header: String, secret: String?) {
        self.secret = (secret?.isEmpty ?? true) ? nil : secret
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fresh || !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        h = try? FileHandle(forWritingTo: url)
        if fresh { try? h?.truncate(atOffset: 0) }
        _ = try? h?.seekToEnd()
        write(header)
    }

    func write(_ text: String) {
        var t = text
        if let secret { t = t.replacingOccurrences(of: secret, with: "********") }
        lock.lock(); defer { lock.unlock() }
        h?.write(Data(t.utf8))
    }

    func close(_ footer: String) {
        write(footer)
        lock.lock(); defer { lock.unlock() }
        try? h?.close(); h = nil
    }
}
