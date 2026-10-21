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
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/FreeRDP/sdl-freerdp").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
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

    /// Argumenty pro FreeRDP (bez hesla).
    static func arguments(_ s: SSHSession) -> [String] {
        let host = s.host.contains(":") && !s.host.hasPrefix("[") ? "[\(s.host)]" : s.host
        var a = ["/v:\(host):\(s.port)", "/title:SSHTool – \(s.name)"]
        if !s.user.isEmpty { a.append("/u:\(s.user)") }
        if !s.rdpDomain.isEmpty { a.append("/d:\(s.rdpDomain)") }
        switch s.rdpSize {
        case "fullscreen": a.append("/f")
        case "dynamic", "": a.append("/dynamic-resolution")
        default: a.append("/size:\(s.rdpSize)")
        }
        if s.rdpMultiMon { a.append("/multimon") }
        a.append(s.rdpClipboard ? "+clipboard" : "-clipboard")
        if s.rdpShareHome { a.append("/drive:Home,\(NSHomeDirectory())") }
        if !s.rdpGateway.isEmpty { a.append("/g:\(s.rdpGateway)") }
        if s.rdpCertPolicy == "tofu" { a.append("/cert:tofu") }      // „ignore“ se záměrně nenabízí
        if !s.rdpSecurity.isEmpty { a.append("/sec:\(s.rdpSecurity)") }
        if s.rdpBpp > 0 { a.append("/bpp:\(s.rdpBpp)") }
        if !s.rdpGfx { a.append("-gfx") }
        if !s.rdpUDP { a.append("-multitransport") }
        a += s.rdpExtraArgs.split(separator: " ").map(String.init)
        return a
    }

    static func commandLine(_ s: SSHSession) -> String {
        (["sdl-freerdp"] + arguments(s)).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    }
}

/// Běžící RDP relace (procesy FreeRDP).
@MainActor
final class RDPLauncher: ObservableObject {
    static let shared = RDPLauncher()
    @Published private(set) var running: [UUID: Process] = [:]
    var onChange: (() -> Void)?

    func isRunning(_ id: UUID) -> Bool { running[id] != nil }

    func launch(_ s: SSHSession) {
        if let p = running[s.id], p.isRunning {
            let a = NSAlert()
            a.messageText = "RDP relace „\(s.name)“ už běží"
            a.informativeText = "Okno FreeRDP najdeš v Docku / ⌘Tab. Otevřít další relaci?"
            a.addButton(withTitle: "Otevřít další"); a.addButton(withTitle: "Zrušit")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        guard let bin = FreeRDP.binary else { FreeRDP.missingAlert(); return }
        if s.envTag == "prod" {
            let a = NSAlert(); a.alertStyle = .warning
            a.messageText = "Připojit se k produkčnímu serveru \(s.name)?"
            a.informativeText = "\(s.host) je označený jako PROD."
            a.addButton(withTitle: "Připojit"); a.addButton(withTitle: "Zrušit")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        let stored = s.hasStoredPassword
        let sid = s.id.uuidString, needAuth = s.requireUserAuth, name = s.name
        Task.detached {
            var password: String?
            if stored {
                if needAuth, !UserAuth.authenticate(reason: "použít uložené heslo pro RDP „\(name)“") { return }
                password = KeychainStore.password(for: sid)
            }
            await MainActor.run { self.start(bin: bin, session: s, password: password) }
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
        let args = FreeRDP.arguments(s)
        p.arguments = password == nil ? args : ["/args-from:stdin"]
        let inPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = errPipe            // WLog píše část chyb na stdout – sbíráme obojí
        p.standardError = errPipe
        let errBox = Box<String>("")
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            errBox.mutate {
                $0 += String(decoding: d, as: UTF8.self)
                if $0.count > 16000 { $0 = String($0.suffix(12000)) }
            }
        }
        let started = Date(), id = s.id, name = s.name
        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            DispatchQueue.main.async {
                if self.running[id] === proc { self.running[id] = nil }
                self.onChange?()
                // rychlé ukončení s chybou = chyba připojení / přihlášení
                guard code != 0, Date().timeIntervalSince(started) < 90 else { return }
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
                a.runModal()
            }
        }
        do {
            try p.run()
        } catch {
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
        if tuned {
            // relace v upraveném režimu vydržela → nastavení uložit do serveru
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak p] in
                guard let p, p.isRunning else { return }
                self.persist(s)
            }
        }
    }

    func disconnect(_ id: UUID) {
        running[id]?.terminate()
    }
}
