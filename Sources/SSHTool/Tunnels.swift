import SwiftUI
import AppKit

// Tunelování portů (jako v PuTTY: Connection → SSH → Tunnels).
//   Lokální  (-L): port na Macu → přes server → cíl (např. web zařízení dostupné jen ze serveru)
//   Vzdálený (-R): port na serveru → přes Mac → cíl (cíl z pohledu Macu)
//   Dynamický (-D): SOCKS proxy na Macu – prohlížeč / aplikace jde do sítě přes server
// Ve výchozím stavu poslouchá jen na 127.0.0.1 (Mac) / localhost (server); „z jiných počítačů“ je výslovná volba.

struct PortForward: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case local = "L", remote = "R", dynamic = "D"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .local: return "Lokální"
            case .remote: return "Vzdálený"
            case .dynamic: return "Dynamický (SOCKS)"
            }
        }
    }

    var id = UUID()
    var kind: Kind = .local
    var listenPort = 0
    var destHost = "127.0.0.1"
    var destPort = 0
    var allowRemote = false          // poslouchat na všech rozhraních (jiné počítače se můžou připojit)
    var enabled = true
    var note = ""

    enum CodingKeys: String, CodingKey { case id, kind, listenPort, destHost, destPort, allowRemote, enabled, note }

    init(kind: Kind = .local) { self.kind = kind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .local
        listenPort = try c.decodeIfPresent(Int.self, forKey: .listenPort) ?? 0
        destHost = try c.decodeIfPresent(String.self, forKey: .destHost) ?? "127.0.0.1"
        destPort = try c.decodeIfPresent(Int.self, forKey: .destPort) ?? 0
        allowRemote = try c.decodeIfPresent(Bool.self, forKey: .allowRemote) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    private static let hostRe = #"^[A-Za-z0-9_][A-Za-z0-9._:-]*$"#

    /// Chyba v zadání (nil = v pořádku).
    var problem: String? {
        guard (1...65535).contains(listenPort) else { return "Port pro naslouchání musí být 1–65535." }
        if kind != .dynamic {
            let h = destHost.trimmingCharacters(in: .whitespaces)
            guard !h.isEmpty, h.range(of: Self.hostRe, options: .regularExpression) != nil else {
                return "Cíl: zadej IP adresu nebo název (písmena, číslice, . - _ :)."
            }
            guard (1...65535).contains(destPort) else { return "Cílový port musí být 1–65535." }
        }
        return nil
    }

    private var destSpec: String {
        let h = destHost.trimmingCharacters(in: .whitespaces)
        return (h.contains(":") ? "[\(h)]" : h) + ":\(destPort)"
    }

    /// Argument pro ssh (-L / -R / -D) včetně adresy naslouchání.
    var spec: String {
        switch kind {
        case .local:   return "\(allowRemote ? "*" : "127.0.0.1"):\(listenPort):\(destSpec)"
        case .dynamic: return "\(allowRemote ? "*" : "127.0.0.1"):\(listenPort)"
        case .remote:  return (allowRemote ? "0.0.0.0:" : "") + "\(listenPort):\(destSpec)"
        }
    }

    var flag: String { "-" + kind.rawValue }

    /// Krátký popis pro seznam a stavový řádek.
    var label: String {
        let any = allowRemote ? " ⚠︎" : ""
        switch kind {
        case .local:   return "L \(listenPort) → \(destSpec)\(any)"
        case .remote:  return "R server:\(listenPort) → \(destSpec)\(any)"
        case .dynamic: return "D SOCKS \(listenPort)\(any)"
        }
    }
}

extension SSHSession {
    /// Argumenty tunelů (jen zapnuté a platné) – přidávají se jen u SSH záložky, ne u SFTP / testu.
    var forwardArgs: [String] {
        forwards.filter { $0.enabled && $0.problem == nil }.flatMap { [$0.flag, $0.spec] }
    }
}

// MARK: - Tunely za běhu (ControlMaster: ssh -O forward / -O cancel)

extension TerminalTab {
    /// Přidá / zruší tunel v běžící relaci. Vrací chybovou hlášku (nil = OK).
    func controlForward(_ op: String, _ f: PortForward) async -> String? {
        guard kind == .ssh, running, let cp = view.controlPath else { return "Relace neběží." }
        let dest = session.destinationString
        return await Task.detached {
            let p = Process(), err = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = ["-S", cp, "-O", op, f.flag, f.spec, "--", dest]
            p.environment = ProcessInfo.sanitizedEnvironment
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = err
            do { try p.run() } catch { return "Nelze spustit ssh." }
            p.waitUntilExit()
            if p.terminationStatus == 0 { return nil }
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return msg.isEmpty ? "ssh skončil chybou \(p.terminationStatus)." : msg
        }.value
    }
}

@MainActor
final class TunnelDraft: ObservableObject {
    @Published var f = PortForward()
    @Published var save = false
    @Published var error = ""
    @Published var busy = false
}

/// Okno „Tunely“ pro běžící SSH relaci – přehled, zrušení a přidání tunelu bez odpojení.
struct TunnelsSheet: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var tab: TerminalTab
    @StateObject private var d = TunnelDraft()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Aktivní tunely – \(tab.session.name)") {
                    if tab.forwards.isEmpty {
                        Text("Žádné tunely.").foregroundStyle(.secondary)
                    }
                    ForEach(tab.forwards) { f in
                        HStack {
                            Image(systemName: "arrow.left.arrow.right")
                            Text(f.label).font(.system(.body, design: .monospaced))
                            if !f.note.isEmpty { Text(f.note).foregroundStyle(.secondary) }
                            Spacer()
                            Button("Zrušit") { Task { await cancel(f) } }.disabled(d.busy)
                        }
                    }
                }
                Section("Přidat tunel do běžící relace") {
                    ForwardEditorRow(f: $d.f)
                    Toggle("Uložit i k serveru (použije se při každém připojení)", isOn: $d.save)
                    if !d.error.isEmpty {
                        Label(d.error, systemImage: "exclamationmark.triangle").foregroundStyle(Color.orange).font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("Tunel funguje, dokud je relace připojená. Port na Macu poslouchá na 127.0.0.1, pokud nepovolíš jiné počítače.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Zavřít") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(SKButton())
                Button("Přidat") { Task { await add() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(SKButton(kind: .primary))
                    .disabled(d.f.problem != nil || d.busy || !tab.running)
            }
            .padding(12)
        }
        .frame(width: 600, height: 520)
    }

    private func add() async {
        d.busy = true; d.error = ""
        let f = d.f
        if let e = await tab.controlForward("forward", f) {
            d.error = e
        } else {
            tab.forwards.append(f)
            if d.save, let i = store.sessions.firstIndex(where: { $0.id == tab.session.id }) {
                store.sessions[i].forwards.append(f)
            }
            d.f = PortForward(kind: f.kind)
        }
        d.busy = false
    }

    private func cancel(_ f: PortForward) async {
        d.busy = true; d.error = ""
        if let e = await tab.controlForward("cancel", f) { d.error = e } else { tab.forwards.removeAll { $0.id == f.id } }
        d.busy = false
    }
}

/// Řádek s nastavením jednoho tunelu (editor serveru i okno Tunely).
struct ForwardEditorRow: View {
    @Binding var f: PortForward

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Typ", selection: $f.kind) {
                ForEach(PortForward.Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 6) {
                Text(f.kind == .remote ? "Port na serveru" : "Port na Macu")
                TextField("", value: $f.listenPort, format: .number.grouping(.never))
                    .frame(width: 70).multilineTextAlignment(.trailing)
                if f.kind != .dynamic {
                    Text("→ cíl")
                    TextField("", text: $f.destHost, prompt: Text("10.0.0.5"))
                        .font(.system(.body, design: .monospaced))
                    Text(":")
                    TextField("", value: $f.destPort, format: .number.grouping(.never))
                        .frame(width: 70).multilineTextAlignment(.trailing)
                }
            }
            TextField("Poznámka", text: $f.note, prompt: Text("např. web FW, SmartConsole…"))
            Toggle(f.kind == .remote ? "Povolit připojení k portu na serveru z jiných počítačů"
                                     : "Povolit připojení z jiných počítačů (ne jen z tohoto Macu)", isOn: $f.allowRemote)
            Text(help).font(.caption).foregroundStyle(.secondary)
            if f.allowRemote {
                Label(f.kind == .remote
                      ? "Port na serveru bude dostupný z celé jeho sítě (vyžaduje GatewayPorts na serveru) – vede do tvého Macu / sítě."
                      : "Port bude dostupný z celé sítě, ve které je Mac (Wi-Fi, VPN) – kdokoli se přes něj dostane přes server dál.",
                      systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.orange)
            }
            if let p = f.problem, f.listenPort != 0 || f.destPort != 0 {
                Text(p).font(.caption).foregroundStyle(Color.orange)
            }
        }
    }

    private var help: String {
        switch f.kind {
        case .local:   return "Připoj se na 127.0.0.1:\(f.listenPort == 0 ? "port" : String(f.listenPort)) na Macu – spojení půjde přes server na cíl (cíl z pohledu serveru). ssh \(f.flag) \(f.spec)"
        case .remote:  return "Kdo se na serveru připojí na localhost:\(f.listenPort == 0 ? "port" : String(f.listenPort)), dostane se přes Mac na cíl (cíl z pohledu Macu). ssh \(f.flag) \(f.spec)"
        case .dynamic: return "SOCKS5 proxy na 127.0.0.1:\(f.listenPort == 0 ? "port" : String(f.listenPort)) – nastav ji v prohlížeči; provoz jde do sítě přes server. ssh \(f.flag) \(f.spec)"
        }
    }
}
