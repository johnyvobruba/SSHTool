import Foundation
import SwiftUI
import AppKit

// Snippety – uložené příkazy. Vkládají se do aktivního terminálu bez Enteru (nic se nespustí),
// „Vložit a spustit“ přidá Enter; u produkčních serverů a při broadcastu se vyžaduje potvrzení.

struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var command: String
    /// "" = všechny servery, jinak jen servery v této skupině.
    var group = ""
    /// Kategorie (název šablony, např. „Cisco ASA 9.x“); "" = vlastní.
    var category = ""

    enum CodingKeys: String, CodingKey { case id, name, command, group, category }

    /// Výchozí stav: žádné snippety – přidávají se ze šablon podle technologie.
    static let defaults: [Snippet] = []
}

extension Snippet {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
    }
}

/// Automatické barvy skupin (stabilní podle názvu) + ruční přepsání z nastavení.
enum GroupPalette {
    static let colors = ["#7299FF", "#4BC995", "#E7B765", "#C69AE8", "#76C7D9", "#E5747A", "#F08CC0", "#9DB36B"]
    nonisolated(unsafe) static var overrides: [String: String] = [:]

    static func name(_ hex: String) -> String {
        ["#7299FF": "Modrá", "#4BC995": "Zelená", "#E7B765": "Žlutá", "#C69AE8": "Fialová",
         "#76C7D9": "Tyrkysová", "#E5747A": "Červená", "#F08CC0": "Růžová", "#9DB36B": "Olivová"][hex] ?? hex
    }

    static func color(for group: String) -> String {
        // ruční barva složky, jinak nejbližší nadřazené; automatická podle složky nejvyšší úrovně
        var p = group
        while true {
            if let c = overrides[p] { return c }
            guard let slash = p.lastIndex(of: "/") else { break }
            p = String(p[..<slash])
        }
        let top = group.split(separator: "/").first.map(String.init) ?? group
        var h: UInt32 = 5381                                     // djb2 – stabilní mezi spuštěními
        for b in top.utf8 { h = (h &* 33) &+ UInt32(b) }
        return colors[Int(h % UInt32(colors.count))]
    }
}

@MainActor
extension TabManager {
    /// Snippety pro aktivní relaci (globální + skupina serveru).
    func snippetsForSelected(_ all: [Snippet]) -> [Snippet] {
        guard let t = selected else { return [] }
        return all.filter { $0.group.isEmpty || $0.group == t.session.group }
    }

    func insertSnippet(_ s: Snippet, run: Bool) {
        guard let t = selected, t.running else { NSSound.beep(); return }
        if run {
            let targets = broadcast ? broadcastTargets : [t]
            let prod = targets.filter { $0.session.envTag == "prod" }
            if !prod.isEmpty || targets.count > 1 {
                let a = NSAlert()
                a.messageText = "Spustit „\(s.command)“?"
                a.informativeText = "Cíle (\(targets.count)): " + targets.map { $0.session.name }.joined(separator: ", ")
                    + (prod.isEmpty ? "" : "\n\nProdukční zařízení: " + prod.map { $0.session.name }.joined(separator: ", "))
                a.alertStyle = prod.isEmpty ? .informational : .warning
                a.addButton(withTitle: "Spustit"); a.addButton(withTitle: "Zrušit")
                guard a.runModal() == .alertFirstButtonReturn else { return }
            }
        }
        let text = s.command + (run ? "\r" : "")
        // přes send(source:) → při zapnutém broadcastu se pošle i do ostatních relací
        t.view.send(source: t.view, data: Array(text.utf8)[...])
        t.view.window?.makeFirstResponder(t.view)
    }
}

// MARK: - Nastavení → Snippety

struct SettingsSnippetsPane: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        SKSection("Šablony podle technologie", subtitle: "Přidají sadu diagnostických (čtecích) příkazů. Syntaxi ověř proti verzi zařízení.") {
            ForEach(SnippetPack.all.indices, id: \.self) { i in
                let p = SnippetPack.all[i]
                let added = store.snippets.contains { $0.category == p.id }
                SKRow(p.id, help: "\(p.note) · \(p.items.count) příkazů", first: i == 0) {
                    Menu(added ? "Přidáno ✓" : "Přidat…") {
                        Button("Pro všechny servery") { add(p, group: "") }
                        if !store.groupNames.isEmpty {
                            Divider()
                            ForEach(store.groupNames, id: \.self) { g in Button("Jen pro složku \(g)") { add(p, group: g) } }
                        }
                        if added {
                            Divider()
                            Button("Odebrat šablonu") { store.snippets.removeAll { $0.category == p.id } }
                        }
                    }
                    .fixedSize()
                }
            }
        }
        SKSection("Uložené příkazy", subtitle: store.snippets.isEmpty
                  ? "Zatím žádné snippety. Přidej šablonu výše nebo vlastní příkaz."
                  : "Vkládají se do aktivního terminálu bez spuštění. Složka omezí snippet na servery v dané složce.") {
            ForEach(store.snippets.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    TextField("Název", text: binding(i, \.name)).skField(width: 160)
                    TextField("Příkaz", text: binding(i, \.command)).skField(mono: true)
                    SKMenuPicker(selection: binding(i, \.group),
                                 options: [("", "Všechny servery")] + store.groupNames.map { ($0, $0) }, width: 150)
                    Button { store.snippets.remove(at: i) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(UI.textTertiary).help("Smazat")
                }
                .padding(.horizontal, SK.hPad).padding(.vertical, 6)
                .overlay(alignment: .top) { if i > 0 { SKDivider() } }
            }
            HStack {
                Button { store.snippets.append(Snippet(name: "", command: "")) } label: { Label("Přidat snippet", systemImage: "plus") }
                    .buttonStyle(SKButton(kind: .primary))
                Spacer()
                if !store.snippets.isEmpty {
                    Button("Smazat všechny…") {
                        let a = NSAlert()
                        a.messageText = "Smazat všech \(store.snippets.count) snippetů?"
                        a.addButton(withTitle: "Smazat"); a.addButton(withTitle: "Zrušit")
                        if a.runModal() == .alertFirstButtonReturn { store.snippets = [] }
                    }
                    .buttonStyle(SKButton(kind: .danger))
                }
            }
            .padding(SK.hPad)
            .overlay(alignment: .top) { SKDivider() }
        }
        Label("Snippety neukládej s hesly ani tokeny – soubor snippets.json není šifrovaný.", systemImage: "exclamationmark.shield")
            .font(SK.helpFont).foregroundStyle(UI.textSecondary)
    }

    /// Přidá šablonu (duplicitní příkazy ve stejné skupině přeskočí).
    private func add(_ p: SnippetPack, group: String) {
        let have = Set(store.snippets.filter { $0.group == group }.map(\.command))
        store.snippets.append(contentsOf: p.snippets(group: group).filter { !have.contains($0.command) })
    }

    private func binding(_ i: Int, _ kp: WritableKeyPath<Snippet, String>) -> Binding<String> {
        Binding(get: { store.snippets.indices.contains(i) ? store.snippets[i][keyPath: kp] : "" },
                set: { v in if store.snippets.indices.contains(i) { store.snippets[i][keyPath: kp] = v } })
    }
}
