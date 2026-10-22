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

/// Panel ve spodní části okna (přes všechny relace) – nemodální, relace se dají dál normálně používat.
struct MultiSendBar: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var tabs: TabManager
    @ObservedObject var m: MultiSendModel

    private var candidates: [TerminalTab] { MultiSendModel.candidates(tabs) }
    private var selectedCount: Int { m.selected.intersection(Set(candidates.map(\.id))).count }
    private var folders: [String] {
        Array(Set(candidates.map { $0.session.group }.filter { !$0.isEmpty })).sorted()
    }
    private var prodSelected: Bool {
        candidates.contains { m.selected.contains($0.id) && $0.session.envTag == "prod" }
    }

    private func binding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { m.selected.contains(id) },
                set: { on in if on { m.selected.insert(id) } else { m.selected.remove(id) } })
    }

    private var targetsMenu: some View {
        Menu {
            if candidates.isEmpty { Text("Žádná aktivní SSH relace") }
            ForEach(candidates) { t in
                Toggle("\(t.title)  ·  \(t.subtitle)\(t.session.envTag == "prod" ? "  ⚠️ PROD" : "")", isOn: binding(t.id))
            }
            if candidates.count > 1 {
                Divider()
                Button("Vše") { m.selected = Set(candidates.map(\.id)) }
                Button("Nic") { m.selected = [] }
                Button("Bez PROD") { m.selected = Set(candidates.filter { $0.session.envTag != "prod" }.map(\.id)) }
                if !folders.isEmpty {
                    Menu("Jen složka") {
                        ForEach(folders, id: \.self) { f in
                            Button(f) { m.selected = Set(candidates.filter { AppStore.inSubtree($0.session.group, f) }.map(\.id)) }
                        }
                    }
                }
            }
        } label: {
            Label("Cíle: \(selectedCount) z \(candidates.count)", systemImage: "rectangle.stack")
        }
        .fixedSize()
        .help(candidates.filter { m.selected.contains($0.id) }.map { $0.title }.joined(separator: ", "))
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Label("Odeslat příkazy do relací", systemImage: "paperplane").font(.system(size: 11.5, weight: .semibold))
                targetsMenu
                if prodSelected {
                    Text("PROD").font(.system(size: 10, weight: .bold)).foregroundStyle(UI.error)
                        .help("Mezi cíli je produkční zařízení")
                }
                Toggle("Enter", isOn: $m.appendEnter).toggleStyle(.checkbox)
                    .help("Za každý řádek poslat Enter (spustit). Vypnuto = text se jen vloží.")
                Toggle("Bez #", isOn: $m.skipComments).toggleStyle(.checkbox)
                    .help("Vynechat řádky začínající #")
                Stepper(value: $m.delayMs, in: 0...10_000, step: 100) {
                    Text("\(m.delayMs) ms").font(.system(size: 11, design: .monospaced))
                }
                .fixedSize()
                .help("Prodleva mezi řádky – u pomalých CLI (clish) zvyš na 1000 ms a víc")
                if !store.snippets.isEmpty {
                    Menu("Snippet") {
                        ForEach(store.snippets) { s in
                            Button("\(s.name) – \(s.command)") {
                                m.commands += (m.commands.isEmpty || m.commands.hasSuffix("\n") ? "" : "\n") + s.command
                            }
                        }
                    }
                    .fixedSize()
                }
                Spacer()
                Text(m.progress).font(.caption).foregroundStyle(UI.textSecondary).lineLimit(1)
                Button { NSWorkspace.shared.open(MultiSendModel.auditURL) } label: { Image(systemName: "doc.text.magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Auditní log odeslaných příkazů (~/Library/Logs/SSHTool/multisend.log)")
                    .disabled(!FileManager.default.fileExists(atPath: MultiSendModel.auditURL.path))
                Button { tabs.showMultiSend = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Zavřít panel  ⌥⌘I")
            }
            .font(.system(size: 11.5))
            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $m.commands)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(SwiftUI.Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(UI.border))
                    .overlay(alignment: .topLeading) {
                        if m.commands.isEmpty {
                            Text("Příkazy, jeden na řádek…  (⌘↩ odeslat)")
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(UI.textTertiary)
                                .padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
                        }
                    }
                VStack(spacing: 6) {
                    Text("\(m.lines.count) ř.").font(.caption).foregroundStyle(UI.textSecondary)
                    if m.running {
                        Button("Zastavit") { m.stop() }.buttonStyle(SKButton(kind: .danger))
                    } else {
                        Button("Odeslat") { m.run(tabs) }
                            .keyboardShortcut(.return, modifiers: .command)
                            .buttonStyle(SKButton(kind: .primary))
                            .disabled(m.lines.isEmpty || selectedCount == 0)
                    }
                }
                .frame(width: 84)
            }
            .frame(height: 96)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(UI.statusBar)
        .onAppear { m.prepare(tabs) }
    }
}
