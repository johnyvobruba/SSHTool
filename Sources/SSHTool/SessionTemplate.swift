import Foundation
import AppKit
import UniformTypeIdentifiers

// Vzor JSON souboru se servery pro kolegy (menu „+“ → Uložit vzor JSON…).
// Stejný obsah je v projektu jako examples/sshtool-servers-template.json.

extension AppStore {
    static let sessionsTemplateJSON = #"""
[
  {
    "_poznamka": "VZOR – adresy jsou z dokumentačních rozsahů (RFC 5737), nahraď je skutečnými. Klíče začínající _ se ignorují. Povinné jsou jen name a host, ostatní mají výchozí hodnoty. Hesla se do souboru nikdy nepíší – zadávají se v aplikaci (Klíčenka macOS).",
    "name": "fw1-praha",
    "host": "192.0.2.10",
    "port": 22,
    "user": "admin",
    "group": "ZAKAZNIK-A",
    "colorHex": "#E5747A",
    "environment": "prod",
    "auth": "agent",
    "agentSocket": "",
    "favorite": true
  },
  {
    "_poznamka": "Přihlášení konkrétním klíčem; passphrase se uloží do Klíčenky (useKeychain).",
    "name": "fw2-praha",
    "host": "192.0.2.11",
    "user": "admin",
    "group": "ZAKAZNIK-A",
    "colorHex": "#E5747A",
    "environment": "prod",
    "auth": "key",
    "identityFile": "~/.ssh/id_ed25519",
    "useKeychain": true
  },
  {
    "_poznamka": "Heslo z Klíčenky – heslo zadáš po importu v editoru serveru (Upravit). requireUserAuth = Touch ID před použitím.",
    "name": "mgmt-test",
    "host": "198.51.100.20",
    "port": 22,
    "user": "admin",
    "group": "ZAKAZNIK-B",
    "colorHex": "#E7B765",
    "environment": "test",
    "auth": "password",
    "requireUserAuth": true
  },
  {
    "_poznamka": "Přes bastion (ProxyJump), heslo/OTP zadávané ručně, pokročilé volby.",
    "name": "core-sw1",
    "host": "203.0.113.5",
    "user": "netadmin",
    "group": "ZAKAZNIK-B",
    "colorHex": "#4BC995",
    "environment": "stage",
    "auth": "interactive",
    "jumpHost": "jump@bastion.example.com",
    "keepAlive": 30,
    "connectTimeout": 10,
    "hostKeyPolicy": "ask",
    "extraArgs": "-o ServerAliveCountMax=3"
  },
  {
    "_poznamka": "Hostname místo IP a SSH agent Bitwardenu.",
    "name": "lab-linux",
    "host": "lab01.example.com",
    "user": "root",
    "group": "LAB",
    "colorHex": "#7299FF",
    "environment": "dev",
    "auth": "agent",
    "agentSocket": "bitwarden"
  }
]
"""#

    func saveSessionsTemplatePanel() {
        let panel = NSSavePanel()
        panel.title = "Uložit vzor JSON se servery"
        panel.message = "Vzor pro kolegy: uprav hodnoty a nahraj přes „Importovat servery (JSON)…“. Hesla se do souboru nepíší."
        panel.nameFieldStringValue = "sshtool-servers-vzor.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(Self.sessionsTemplateJSON.utf8).write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            Self.info("Uložení vzoru selhalo", error.localizedDescription)
        }
    }

    /// Srozumitelný popis chyby importu (který záznam a které pole).
    static func describeImportError(_ error: Error) -> String {
        func path(_ c: [CodingKey]) -> String {
            c.map { $0.intValue.map { "záznam \($0 + 1)" } ?? $0.stringValue }.joined(separator: " → ")
        }
        switch error {
        case DecodingError.keyNotFound(let k, let ctx):
            return "Chybí povinné pole „\(k.stringValue)“ (\(path(ctx.codingPath)))."
        case DecodingError.typeMismatch(_, let ctx), DecodingError.valueNotFound(_, let ctx):
            return "Špatný typ hodnoty: \(path(ctx.codingPath)). Čísla (port, keepAlive) bez uvozovek, true/false bez uvozovek."
        case DecodingError.dataCorrupted(let ctx):
            let p = path(ctx.codingPath)
            if p.hasSuffix("auth") { return "Neplatná hodnota auth (\(p)). Povolené: agent, key, password, interactive." }
            return "Soubor není platný JSON\(p.isEmpty ? "" : " (" + p + ")"). Zkontroluj čárky a uvozovky."
        default:
            return error.localizedDescription
        }
    }
}
