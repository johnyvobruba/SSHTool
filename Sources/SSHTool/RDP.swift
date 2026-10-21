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

    private func start(bin: String, session s: SSHSession, password: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        let args = FreeRDP.arguments(s)
        p.arguments = password == nil ? args : ["/args-from:stdin"]
        let inPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errPipe
        let errBox = Box<String>("")
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            errBox.mutate { if $0.count < 8000 { $0 += String(decoding: d, as: UTF8.self) } }
        }
        let started = Date(), id = s.id, name = s.name
        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            DispatchQueue.main.async {
                self.running[id] = nil
                self.onChange?()
                // rychlé ukončení s chybou = nejspíš chyba připojení / přihlášení
                if code != 0, Date().timeIntervalSince(started) < 20 {
                    let lines = errBox.value.split(whereSeparator: \.isNewline).map(String.init)
                        .filter { $0.contains("ERROR") || $0.contains("error") || $0.contains("failed") }
                    let a = NSAlert()
                    a.messageText = "RDP „\(name)“ se nepřipojilo (kód \(code))"
                    a.informativeText = lines.suffix(4).joined(separator: "\n").isEmpty
                        ? "FreeRDP skončil chybou. Zkontroluj host, port a přihlašovací údaje."
                        : lines.suffix(4).joined(separator: "\n")
                    a.runModal()
                }
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
    }

    func disconnect(_ id: UUID) {
        running[id]?.terminate()
    }
}
