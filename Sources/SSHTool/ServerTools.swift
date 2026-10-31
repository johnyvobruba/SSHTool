import SwiftUI
import AppKit

// MARK: - Koš smazaných serverů

struct TrashSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Koš – smazané servery (\(store.trash.count))") {
                    if store.trash.isEmpty { Text("Koš je prázdný.").foregroundStyle(.secondary) }
                    ForEach(store.trash) { t in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.session.name)
                                Text("\(t.session.group) · \(t.session.host) · smazáno \(Self.df.string(from: t.deletedAt))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Obnovit") { store.restore(t.session.id) }
                            Button("Smazat trvale") { confirmPurge([t]) }.foregroundStyle(UI.error)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("Položky starší 30 dní se mažou trvale (i s heslem v Klíčence) při spuštění aplikace.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Vysypat koš…") { confirmPurge(store.trash) }
                    .buttonStyle(SKButton(kind: .danger)).disabled(store.trash.isEmpty)
                Button("Zavřít") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(SKButton())
            }
            .padding(12)
        }
        .frame(width: 600, height: 460)
    }

    private func confirmPurge(_ items: [TrashedSession]) {
        let a = NSAlert(); a.alertStyle = .warning
        a.messageText = items.count == 1 ? "Trvale smazat „\(items[0].session.name)“?" : "Trvale smazat \(items.count) serverů z koše?"
        a.informativeText = "Smaže se i uložené heslo v Klíčence. Nelze vrátit."
        a.addButton(withTitle: "Smazat trvale"); a.addButton(withTitle: "Zrušit")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if items.count == store.trash.count { store.emptyTrash() } else { items.forEach { store.purge($0.session.id) } }
    }
}

// MARK: - Hromadná úprava

@MainActor
final class BulkEditModel: ObservableObject {
    @Published var selected = Set<UUID>()
    @Published var filter = ""
    // co měnit (zaškrtnuté) a na co
    @Published var setGroup = false
    @Published var group = ""
    @Published var setUser = false
    @Published var user = ""
    @Published var setPort = false
    @Published var port = 22
    @Published var setJump = false
    @Published var jump = ""
    @Published var setEnv = false
    @Published var env = ""
    @Published var setColor = false
    @Published var color = ""
    @Published var setLegacy = false
    @Published var legacy = false
    @Published var setX11 = false
    @Published var x11 = ""
    @Published var setKeepAlive = false
    @Published var keepAlive = 0
    @Published var setHostKey = false
    @Published var hostKey = ""
}

struct BulkEditSheet: View {
    let group: String                  // "" = všechny servery
    @EnvironmentObject private var store: AppStore
    @StateObject private var m = BulkEditModel()
    @Environment(\.dismiss) private var dismiss

    private var candidates: [SSHSession] {
        let base = group.isEmpty ? store.sessions : store.sessions.filter { AppStore.inSubtree($0.group, group) }
        let q = m.filter.lowercased()
        return (q.isEmpty ? base : base.filter { "\($0.name) \($0.host) \($0.group)".lowercased().contains(q) })
            .sorted { ($0.group, $0.name) < ($1.group, $1.name) }
    }

    private func binding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { m.selected.contains(id) }, set: { if $0 { m.selected.insert(id) } else { m.selected.remove(id) } })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                // servery
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Filtr (název, IP, složka)", text: $m.filter).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Vybrat vše") { m.selected.formUnion(candidates.map(\.id)) }
                        Button("Nic") { m.selected = [] }
                        Spacer()
                        Text("\(m.selected.count) vybráno").font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    List(candidates) { s in
                        Toggle(isOn: binding(s.id)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.name)
                                Text("\(s.group) · \(s.host)\(s.isRDP ? " · RDP" : s.isTelnet ? " · Telnet" : "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(12)
                .frame(width: 300)
                Divider()
                // změny
                Form {
                    Section("Změnit u vybraných (jen zaškrtnuté položky)") {
                        row("Složka", $m.setGroup) {
                            Picker("", selection: $m.group) {
                                ForEach(store.groupNames, id: \.self) { Text($0).tag($0) }
                            }.labelsHidden()
                        }
                        row("Uživatel", $m.setUser) { TextField("", text: $m.user).labelsHidden() }
                        row("Port", $m.setPort) { TextField("", value: $m.port, format: .number.grouping(.never)).labelsHidden().frame(width: 80) }
                        row("Jump host (SSH)", $m.setJump) { TextField("", text: $m.jump, prompt: Text("prázdné = žádný")).labelsHidden() }
                        row("Prostředí", $m.setEnv) {
                            Picker("", selection: $m.env) {
                                Text("Production").tag("prod"); Text("Staging").tag("stage")
                                Text("Development").tag("dev"); Text("Test").tag("test"); Text("Neoznačeno").tag("")
                            }.labelsHidden()
                        }
                        row("Barva", $m.setColor) {
                            Picker("", selection: $m.color) {
                                Text("Podle složky").tag(""); Text("Bez barvy").tag("none")
                                ForEach(["#E5747A", "#E7B765", "#4BC995", "#7299FF", "#C69AE8", "#76C7D9"], id: \.self) { Text($0).tag($0) }
                            }.labelsHidden()
                        }
                        row("Legacy algoritmy (SSH)", $m.setLegacy) { Toggle("", isOn: $m.legacy).labelsHidden() }
                        row("X11 forwarding (SSH)", $m.setX11) {
                            Picker("", selection: $m.x11) {
                                Text("Vypnuto").tag(""); Text("Nedůvěryhodné (-X)").tag("untrusted"); Text("Důvěryhodné (-Y)").tag("trusted")
                            }.labelsHidden()
                        }
                        row("KeepAlive (s, SSH)", $m.setKeepAlive) { TextField("", value: $m.keepAlive, format: .number.grouping(.never)).labelsHidden().frame(width: 80) }
                        row("Kontrola klíče serveru", $m.setHostKey) {
                            Picker("", selection: $m.hostKey) {
                                Text("Výchozí").tag(""); Text("ask").tag("ask"); Text("yes").tag("yes"); Text("accept-new").tag("accept-new")
                            }.labelsHidden()
                        }
                    }
                }
                .formStyle(.grouped)
            }
            HStack {
                Text("Hesla, názvy a hosty se hromadně nemění. Neplatné hodnoty (host / uživatel s mezerou nebo „-“) se odmítnou.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Zavřít") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(SKButton())
                Button("Použít na \(m.selected.count) serverů") { apply() }
                    .keyboardShortcut(.defaultAction).buttonStyle(SKButton(kind: .primary))
                    .disabled(m.selected.isEmpty || !anyChange)
            }
            .padding(12)
        }
        .frame(width: 860, height: 600)
        .onAppear {
            if m.group.isEmpty { m.group = group.isEmpty ? (store.groupNames.first ?? "Default") : group }
            m.selected = Set(candidates.map(\.id))
        }
    }

    private var anyChange: Bool {
        m.setGroup || m.setUser || m.setPort || m.setJump || m.setEnv || m.setColor || m.setLegacy || m.setX11 || m.setKeepAlive || m.setHostKey
    }

    private func row<C: View>(_ title: String, _ on: Binding<Bool>, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Toggle(title, isOn: on).toggleStyle(.checkbox).frame(width: 190, alignment: .leading)
            content().disabled(!on.wrappedValue)
        }
    }

    private func apply() {
        let user = m.user.trimmingCharacters(in: .whitespaces), jump = m.jump.trimmingCharacters(in: .whitespaces)
        var probe = SSHSession(name: "x", host: "x")
        probe.user = m.setUser ? user : ""; probe.jumpHost = m.setJump ? jump : ""
        if let p = AppStore.fieldProblem(probe) { info("Nelze použít", p); return }
        guard !m.setPort || (1...65535).contains(m.port) else { info("Nelze použít", "Port musí být 1–65535."); return }
        let a = NSAlert()
        a.messageText = "Změnit \(m.selected.count) serverů?"
        a.informativeText = "Změnu lze vrátit jen ruční úpravou (případně importem zálohy / exportu)."
        a.addButton(withTitle: "Změnit"); a.addButton(withTitle: "Zrušit")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var list = store.sessions
        for i in list.indices where m.selected.contains(list[i].id) {
            if m.setGroup { list[i].group = m.group }
            if m.setUser { list[i].user = user }
            if m.setPort { list[i].port = m.port }
            if m.setJump, !list[i].isRDP { list[i].jumpHost = jump }
            if m.setEnv { list[i].environment = m.env; list[i].production = m.env == "prod" }
            if m.setColor { list[i].colorHex = m.color }
            if m.setLegacy, !list[i].isRDP { list[i].legacyAlgorithms = m.legacy }
            if m.setX11, !list[i].isRDP { list[i].x11 = m.x11 }
            if m.setKeepAlive { list[i].keepAlive = max(0, m.keepAlive) }
            if m.setHostKey { list[i].hostKeyPolicy = m.hostKey }
        }
        store.sessions = list
        dismiss()
    }

    private func info(_ t: String, _ s: String) {
        let a = NSAlert(); a.messageText = t; a.informativeText = s; a.runModal()
    }
}
