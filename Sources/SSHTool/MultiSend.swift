import SwiftUI
import AppKit

// Hromadné odeslání příkazu / sady příkazů do vybraných aktivních relací (SSH, sériová konzole).
// Na rozdíl od broadcastu (živé psaní) se text připraví předem, cíle se vyberou zaškrtnutím,
// řádky se posílají postupně s prodlevou a každé odeslání se zapíše do auditního logu.

@MainActor
final class MultiSendModel: ObservableObject {
    @Published var commands = ""
    @Published var selected = Set<UUID>()          // TerminalTab.id
    @Published var delayMs = 300
    @Published var appendEnter = true
    @Published var skipComments = true
    @Published var running = false
    @Published var progress = ""
    private var cancelled = false

    /// Řádky k odeslání (prázdné a případně komentáře „#“ se vynechají).
    var lines: [String] {
        commands.replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n")
            .filter { l in
                let t = l.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty && !(skipComments && t.hasPrefix("#"))
            }
    }

    static func candidates(_ tabs: TabManager) -> [TerminalTab] {
        tabs.tabs.filter { $0.running && ($0.kind == .ssh || $0.kind == .serial) }
    }

    /// Při otevření: zahodit ukončené relace; když nic nezbude, předvybrat všechny kromě PROD.
    func prepare(_ tabs: TabManager) {
        let ids = Set(Self.candidates(tabs).map(\.id))
        selected = selected.intersection(ids)
        if selected.isEmpty {
            selected = Set(Self.candidates(tabs).filter { $0.session.envTag != "prod" }.map(\.id))
        }
        if !running { progress = "" }
    }

    func stop() { cancelled = true }

    func run(_ tabs: TabManager) {
        let lines = self.lines
        let targets = Self.candidates(tabs).filter { selected.contains($0.id) }
        guard !lines.isEmpty, !targets.isEmpty else { NSSound.beep(); return }

        // potvrzení – vždy, s výpisem cílů a příkazů; PROD zvýrazněně
        let prod = targets.filter { $0.session.envTag == "prod" }
        let a = NSAlert()
        a.alertStyle = prod.isEmpty ? .warning : .critical
        a.messageText = "Odeslat \(lines.count) \(lines.count == 1 ? "příkaz" : "příkazů") do \(targets.count) relací?"
        var info = "Cíle:\n" + targets.map { "• \($0.session.name) (\($0.subtitle))" }.joined(separator: "\n")
        info += "\n\nPříkazy:\n" + lines.prefix(12).map { "  " + $0 }.joined(separator: "\n")
        if lines.count > 12 { info += "\n  … a dalších \(lines.count - 12)" }
        if !prod.isEmpty { info += "\n\n⚠️ PRODUKČNÍ zařízení (\(prod.count)): " + prod.map { $0.session.name }.joined(separator: ", ") }
        if !appendEnter { info += "\n\nBez Enteru – text se jen vloží, nespustí se." }
        a.informativeText = info
        a.addButton(withTitle: "Odeslat"); a.addButton(withTitle: "Zrušit")
        guard a.runModal() == .alertFirstButtonReturn else { return }

        Self.audit(targets: targets, lines: lines, enter: appendEnter)
        cancelled = false
        running = true
        let delay = UInt64(max(0, delayMs)) * 1_000_000
        let enter = appendEnter
        Task { @MainActor in
            var sent = 0
            for (i, line) in lines.enumerated() {
                if self.cancelled { break }
                let data = Array((line + (enter ? "\r" : "")).utf8)[...]
                for t in targets where t.running { t.view.sendRaw(data) }
                sent = i + 1
                self.progress = "Odesláno \(sent)/\(lines.count) řádků do \(targets.filter { $0.running }.count) relací"
                if i < lines.count - 1, delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            }
            self.progress = self.cancelled
                ? "Zastaveno po \(sent)/\(lines.count) řádcích"
                : "Hotovo – \(lines.count) řádků do \(targets.count) relací"
            self.running = false
        }
    }

    /// Auditní záznam: ~/Library/Logs/SSHTool/multisend.log (jen pro uživatele, 0600).
    static func audit(targets: [TerminalTab], lines: [String], enter: Bool) {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SSHTool", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("multisend.log")
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        var text = "===== \(ISO8601DateFormatter().string(from: Date()))\(enter ? "" : " (bez Enteru)")\n"
        text += "Cíle: " + targets.map { "\($0.session.name) [\($0.subtitle)]" }.joined(separator: ", ") + "\n"
        text += lines.map { "> " + $0 }.joined(separator: "\n") + "\n\n"
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd()
            h.write(Data(text.utf8))
            try? h.close()
        }
    }

    static var auditURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SSHTool/multisend.log")
    }
}

struct MultiSendSheet: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var tabs: TabManager
    @ObservedObject var m: MultiSendModel
    @Environment(\.dismiss) private var dismiss

    private var candidates: [TerminalTab] { MultiSendModel.candidates(tabs) }
    private var folders: [String] {
        Array(Set(candidates.map { $0.session.group }.filter { !$0.isEmpty })).sorted()
    }

    private func binding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { m.selected.contains(id) },
                set: { on in if on { m.selected.insert(id) } else { m.selected.remove(id) } })
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if candidates.isEmpty {
                        Text("Žádná aktivní SSH relace. Otevři nejdřív relace, do kterých chceš příkazy poslat.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(candidates) { t in
                        Toggle(isOn: binding(t.id)) {
                            HStack(spacing: 6) {
                                Text(t.title)
                                EnvBadge(tag: t.session.envTag)
                                Spacer()
                                Text(t.subtitle).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if candidates.count > 1 {
                        HStack {
                            Button("Vše") { m.selected = Set(candidates.map(\.id)) }
                            Button("Nic") { m.selected = [] }
                            Button("Bez PROD") { m.selected = Set(candidates.filter { $0.session.envTag != "prod" }.map(\.id)) }
                            if !folders.isEmpty {
                                Menu("Jen složka") {
                                    ForEach(folders, id: \.self) { f in
                                        Button(f) { m.selected = Set(candidates.filter { AppStore.inSubtree($0.session.group, f) }.map(\.id)) }
                                    }
                                }
                                .fixedSize()
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                } header: {
                    Text("Cílové relace (\(m.selected.intersection(Set(candidates.map(\.id))).count) z \(candidates.count))")
                }
                Section {
                    TextEditor(text: $m.commands)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 140)
                    HStack {
                        if !store.snippets.isEmpty {
                            Menu("Vložit snippet") {
                                ForEach(store.snippets) { s in
                                    Button("\(s.name) – \(s.command)") {
                                        m.commands += (m.commands.isEmpty || m.commands.hasSuffix("\n") ? "" : "\n") + s.command
                                    }
                                }
                            }
                            .fixedSize()
                        }
                        Spacer()
                        Text("\(m.lines.count) řádků k odeslání").font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Příkazy (jeden na řádek)")
                }
                Section("Možnosti") {
                    Toggle("Spustit – Enter za každým řádkem", isOn: $m.appendEnter)
                    Toggle("Vynechat řádky začínající #", isOn: $m.skipComments)
                    Stepper(value: $m.delayMs, in: 0...10_000, step: 100) {
                        Text("Prodleva mezi řádky: \(m.delayMs) ms")
                    }
                    Text("Prodleva dává zařízení čas zpracovat předchozí příkaz (u pomalých CLI, např. clish, zvyš na 1000 ms a víc). Každé odeslání se zapíše do ~/Library/Logs/SSHTool/multisend.log – nevkládej do příkazů hesla.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Text(m.progress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Audit log") { NSWorkspace.shared.open(MultiSendModel.auditURL) }
                    .buttonStyle(SKButton())
                    .disabled(!FileManager.default.fileExists(atPath: MultiSendModel.auditURL.path))
                Button("Zavřít") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(SKButton())
                if m.running {
                    Button("Zastavit") { m.stop() }.buttonStyle(SKButton(kind: .danger))
                } else {
                    Button("Odeslat…") { m.run(tabs) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(SKButton(kind: .primary))
                        .disabled(m.lines.isEmpty || m.selected.intersection(Set(candidates.map(\.id))).isEmpty)
                }
            }
            .padding(12)
        }
        .frame(width: 620, height: 640)
        .onAppear { m.prepare(tabs) }
    }
}
