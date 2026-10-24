import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Darwin

// Prohlížeč souborů serveru (SFTP) v pravém panelu vedle terminálu.
// Používá /usr/bin/sftp v dávkovém režimu přes ControlMaster socket SSH záložky →
// žádné nové přihlášení (funguje i s heslem / Touch ID), stejný uživatel a práva jako v terminálu.
// Server musí mít povolený SFTP subsystém (Check Point Gaia: uživatel se shellem /bin/bash).

@MainActor
final class SFTPBrowser: ObservableObject {
    struct Entry: Identifiable, Hashable {
        let name: String
        let isDir: Bool
        let isLink: Bool
        let size: Int64
        let date: String
        let perms: String
        let owner: String
        var id: String { name }
    }

    struct Transfer: Identifiable {
        enum State { case running, ok, failed }
        let id = UUID()
        let title: String
        var state: State = .running
        var detail = ""
        var reveal: URL?
        var total: Int64 = 0            // 0 = neznámá velikost (složka ke stažení)
        var done: Int64 = 0
        var speed: Double = 0           // B/s (klouzavý průměr)
        let started = Date()

        var fraction: Double? { total > 0 ? min(1, Double(done) / Double(total)) : nil }

        /// „45 % · 120 MB z 1,2 GB · 15 MB/s · zbývá 1:10“
        var progressText: String {
            let f = ByteCountFormatter()
            var parts: [String] = []
            if let fr = fraction { parts.append("\(Int(fr * 100)) %") }
            parts.append(total > 0 ? "\(f.string(fromByteCount: done)) z \(f.string(fromByteCount: total))"
                                   : f.string(fromByteCount: done))
            if speed > 0 {
                parts.append("\(f.string(fromByteCount: Int64(speed)))/s")
                if total > done {
                    let s = Int(Double(total - done) / speed)
                    parts.append("zbývá " + (s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                                                       : String(format: "%d:%02d", s / 60, s % 60)))
                }
            }
            return parts.joined(separator: " · ")
        }
    }

    @Published private(set) var path = ""
    @Published var pathField = ""
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var selection = Set<String>()
    @Published private(set) var transfers: [Transfer] = []
    @Published var showHidden = false
    @Published var dropTargeted = false
    @Published private(set) var waiting = false

    let controlPath: String
    let destination: String
    let sessionName: String
    let production: Bool
    private var home = ""

    init(controlPath: String, destination: String, sessionName: String, production: Bool) {
        self.controlPath = controlPath
        self.destination = destination
        self.sessionName = sessionName
        self.production = production
        Task { await self.waitForLogin() }
    }

    /// Počká, až je hlavní SSH spojení přihlášené (socket ControlMaster odpovídá), pak otevře domovskou složku.
    private func waitForLogin() async {
        let cp = controlPath, dest = destination
        for i in 0..<180 {                                        // až 3 minuty (heslo, OTP, Touch ID)
            let ready = await Task.detached { Self.masterReady(cp, dest) }.value
            if ready { waiting = false; await goHome(); return }
            if i == 1 { waiting = true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        waiting = false
        error = "Spojení se nepřihlásilo do 3 minut – zkontroluj terminál pod seznamem (⌘R = znovu připojit)."
    }

    nonisolated static func masterReady(_ cp: String, _ dest: String) -> Bool {
        guard FileManager.default.fileExists(atPath: cp) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-S", cp, "-O", "check", dest]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    var visibleEntries: [Entry] { showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") } }

    // MARK: sftp v dávkovém režimu

    /// Cesta / název v uvozovkách pro příkazy sftp (escapuje \ a ").
    nonisolated static func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    nonisolated static func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : (dir.hasSuffix("/") ? dir + name : dir + "/" + name)
    }

    private func run(_ commands: [String], pid: Box<Int32>? = nil) async -> (ok: Bool, out: String, err: String) {
        let cp = controlPath, dest = destination
        return await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
            p.arguments = ["-b", "-", "-o", "ControlPath=\(cp)", "-o", "ControlMaster=no",
                           "-o", "BatchMode=yes", dest]
            var env = ProcessInfo.sanitizedEnvironment
            env.removeValue(forKey: "SSH_ASKPASS")
            p.environment = env
            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            p.standardInput = inPipe
            p.standardOutput = outPipe
            p.standardError = errPipe
            do { try p.run() } catch { return (false, "", "Nelze spustit /usr/bin/sftp") }
            pid?.value = p.processIdentifier
            inPipe.fileHandleForWriting.write(Data((commands.joined(separator: "\n") + "\n").utf8))
            try? inPipe.fileHandleForWriting.close()
            // stdout a stderr číst souběžně (velký výpis nesmí zablokovat rouru)
            let errBox = Box<Data>(Data())
            let g = DispatchGroup()
            g.enter()
            DispatchQueue.global().async { errBox.value = errPipe.fileHandleForReading.readDataToEndOfFile(); g.leave() }
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            g.wait()
            let errData = errBox.value
            p.waitUntilExit()
            return (p.terminationStatus == 0,
                    String(decoding: outData, as: UTF8.self),
                    String(decoding: errData, as: UTF8.self))
        }.value
    }

    private static func cleanErr(_ e: String) -> String {
        let lines = e.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("sftp>") }
        return lines.last ?? "Operace selhala"
    }

    // MARK: Procházení

    func goHome() async {
        loading = true
        let r = await run(["pwd"])
        if let line = r.out.split(whereSeparator: \.isNewline).first(where: { $0.contains("Remote working directory:") }) {
            home = line.components(separatedBy: "Remote working directory:").last?.trimmingCharacters(in: .whitespaces) ?? "/"
            await list(home)
        } else {
            loading = false
            error = r.err.isEmpty ? "SFTP není dostupné" : Self.cleanErr(r.err)
                + "\nTip: Check Point Gaia potřebuje uživatele se shellem /bin/bash a povolený SFTP."
        }
    }

    func list(_ dir: String) async {
        loading = true
        let r = await run(["ls -la " + Self.q(dir)])
        loading = false
        guard r.ok else { error = Self.cleanErr(r.err); return }
        error = nil
        path = dir
        pathField = dir
        selection = []
        entries = Self.parse(r.out)
    }

    /// Parsování „ls -la“ ze sftp (longname ve formátu ls -l).
    nonisolated static func parse(_ out: String) -> [Entry] {
        let re = try! NSRegularExpression(pattern:
            #"^([\-dlcbps][rwxsStT\-]{9}[+@.]?)\s+\d+\s+(\S+)\s+(\S+)\s+(\d+)\s+([A-Z][a-z]{2}\s+\d{1,2}\s+[\d:]{4,5})\s(.+)$"#)
        var res: [Entry] = []
        for raw in out.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard !line.hasPrefix("sftp>"),
                  let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
            func g(_ i: Int) -> String { Range(m.range(at: i), in: line).map { String(line[$0]) } ?? "" }
            let perms = g(1)
            var name = g(6)
            // sftp vypisuje u „ls cesta“ celou cestu – ponechat jen název
            if let slash = name.lastIndex(of: "/"), !name.hasSuffix("/") { name = String(name[name.index(after: slash)...]) }
            let isLink = perms.hasPrefix("l")
            if isLink, let r = name.range(of: " -> ") { name = String(name[..<r.lowerBound]) }
            guard name != ".", name != ".." else { continue }
            res.append(Entry(name: name, isDir: perms.hasPrefix("d"), isLink: isLink,
                             size: Int64(g(4)) ?? 0, date: g(5), perms: perms, owner: g(2)))
        }
        return res.sorted { a, b in
            a.isDir != b.isDir ? a.isDir : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    func open(_ e: Entry) {
        if e.isDir || e.isLink {
            Task { await list(Self.join(path, e.name)) }   // odkaz zkusí otevřít jako složku
        } else {
            download([e])
        }
    }

    func up() {
        guard path != "/" else { return }
        let parent = (path as NSString).deletingLastPathComponent
        Task { await list(parent.isEmpty ? "/" : parent) }
    }

    func refresh() { Task { await list(path.isEmpty ? home : path) } }
    func goToField() {
        let p = pathField.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        Task { await list(p.hasPrefix("/") ? p : Self.join(path, p)) }
    }
    func homeDir() { Task { await list(home.isEmpty ? "/" : home) } }

    // MARK: Přenosy

    private func addTransfer(_ title: String) -> UUID {
        let t = Transfer(title: title)
        transfers.insert(t, at: 0)
        if transfers.count > 20 { transfers.removeLast() }
        return t.id
    }

    /// Průběh přenosu: každou ½ s zjistí z otevřených souborů procesu sftp, kolik bajtů je přečteno / zapsáno
    /// (offset souboru na Macu pod `roots`). Nic neposílá na server, nezpomaluje přenos.
    private func track(_ id: UUID, pid: Box<Int32>, roots: [String]) {
        Task { @MainActor in
            var seen: [String: Int64] = [:]       // soubor → poslední offset
            var current: String?
            var lastDone: Int64 = 0, lastTime = Date()
            while let i = transfers.firstIndex(where: { $0.id == id }), transfers[i].state == .running {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let p = pid.value
                guard p > 0 else { continue }
                let open = FDProgress.openFiles(pid: p).filter { f in roots.contains { f.path == $0 || f.path.hasPrefix($0 + "/") } }
                if let f = open.first {
                    if let c = current, c != f.path, let s = FDProgress.size(c) { seen[c] = s }   // předchozí hotový
                    current = f.path
                    seen[f.path] = f.offset
                }
                guard let j = transfers.firstIndex(where: { $0.id == id }), transfers[j].state == .running else { break }
                let done = seen.values.reduce(0, +)
                let now = Date(), dt = now.timeIntervalSince(lastTime)
                if dt > 0, done >= lastDone {
                    let inst = Double(done - lastDone) / dt
                    transfers[j].speed = transfers[j].speed == 0 ? inst : transfers[j].speed * 0.7 + inst * 0.3
                }
                lastDone = done; lastTime = now
                transfers[j].done = transfers[j].total > 0 ? min(done, transfers[j].total) : done
            }
        }
    }

    private func finish(_ id: UUID, _ ok: Bool, _ detail: String, reveal: URL? = nil) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        if ok, transfers[i].total > 0 { transfers[i].done = transfers[i].total }
        transfers[i].state = ok ? .ok : .failed
        transfers[i].detail = detail
        transfers[i].reveal = reveal
    }

    /// ↓ Stáhnout: jeden soubor → dialog Uložit, více položek / složka → výběr cílové složky.
    func download(_ items: [Entry]) {
        guard !items.isEmpty else { return }
        var targetDir: URL
        var single: URL?
        if items.count == 1, !items[0].isDir {
            let panel = NSSavePanel()
            panel.title = "Stáhnout ze serveru \(sessionName)"
            panel.nameFieldStringValue = items[0].name
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            guard panel.runModal() == .OK, let u = panel.url else { return }
            single = u
            targetDir = u.deletingLastPathComponent()
        } else {
            let panel = NSOpenPanel()
            panel.title = "Kam stáhnout \(items.count) položek"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Stáhnout sem"
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            guard panel.runModal() == .OK, let u = panel.url else { return }
            targetDir = u
        }
        let title = items.count == 1 ? "↓ \(items[0].name)" : "↓ \(items.count) položek"
        let id = addTransfer(title)
        if let i = transfers.firstIndex(where: { $0.id == id }), !items.contains(where: \.isDir) {
            transfers[i].total = items.reduce(0) { $0 + $1.size }       // u složek velikost předem neznáme
        }
        let roots = single.map { [$0.path] } ?? items.map { targetDir.appendingPathComponent($0.name).path }
        let pid = Box<Int32>(0)
        track(id, pid: pid, roots: roots)
        let dir = path
        var cmds = ["lcd " + Self.q(targetDir.path), "cd " + Self.q(dir)]
        if let single {
            cmds.append("get -p " + Self.q(items[0].name) + " " + Self.q(single.lastPathComponent))
        } else {
            cmds += items.map { "get -r -p " + Self.q($0.name) }
        }
        Task {
            let r = await run(cmds, pid: pid)
            let reveal = single ?? (items.count == 1 ? targetDir.appendingPathComponent(items[0].name) : targetDir)
            finish(id, r.ok, r.ok ? "Uloženo do \(targetDir.path)" : Self.cleanErr(r.err), reveal: r.ok ? reveal : nil)
        }
    }

    /// ↑ Nahrát: výběr souborů / složek z Macu do aktuální složky serveru.
    func chooseUpload() {
        let panel = NSOpenPanel()
        panel.title = "Nahrát na \(sessionName): \(path)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Nahrát"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        upload(panel.urls)
    }

    func upload(_ urls: [URL]) {
        guard !urls.isEmpty, confirmWrite("Nahrát \(urls.count == 1 ? "„\(urls[0].lastPathComponent)“" : "\(urls.count) položek") do \(path)") else { return }
        let existing = Set(entries.map(\.name))
        let clash = urls.map(\.lastPathComponent).filter { existing.contains($0) }
        if !clash.isEmpty {
            let a = NSAlert()
            a.messageText = "Přepsat existující soubory na serveru?"
            a.informativeText = clash.prefix(10).joined(separator: "\n")
            a.addButton(withTitle: "Přepsat"); a.addButton(withTitle: "Zrušit")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        let id = addTransfer(urls.count == 1 ? "↑ \(urls[0].lastPathComponent)" : "↑ \(urls.count) položek")
        if let i = transfers.firstIndex(where: { $0.id == id }) { transfers[i].total = FDProgress.totalSize(urls) }
        let pid = Box<Int32>(0)
        track(id, pid: pid, roots: urls.map { $0.resolvingSymlinksInPath().path })
        let dir = path
        let cmds = ["cd " + Self.q(dir)] + urls.map { "put -r -p " + Self.q($0.path) }
        Task {
            let r = await run(cmds, pid: pid)
            finish(id, r.ok, r.ok ? "Nahráno do \(dir)" : Self.cleanErr(r.err))
            if r.ok, path == dir { await list(dir) }
        }
    }

    // MARK: Úpravy na serveru

    private func confirmWrite(_ what: String) -> Bool {
        guard production else { return true }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "\(what)?"
        a.informativeText = "\(sessionName) je produkční zařízení (PROD)."
        a.addButton(withTitle: "Pokračovat"); a.addButton(withTitle: "Zrušit")
        return a.runModal() == .alertFirstButtonReturn
    }

    func mkdir() {
        guard let n = askText("Nová složka", "Název složky v \(path):"), !n.contains("/"),
              confirmWrite("Vytvořit složku „\(n)“") else { return }
        Task {
            let r = await run(["mkdir " + Self.q(Self.join(path, n))])
            if r.ok { await list(path) } else { error = Self.cleanErr(r.err) }
        }
    }

    func rename(_ e: Entry) {
        guard let n = askText("Přejmenovat", "Nový název pro „\(e.name)“:", initial: e.name), n != e.name, !n.contains("/"),
              confirmWrite("Přejmenovat „\(e.name)“ na „\(n)“") else { return }
        Task {
            let r = await run(["rename " + Self.q(Self.join(path, e.name)) + " " + Self.q(Self.join(path, n))])
            if r.ok { await list(path) } else { error = Self.cleanErr(r.err) }
        }
    }

    func delete(_ items: [Entry]) {
        guard !items.isEmpty else { return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Smazat na serveru \(items.count == 1 ? "„\(items[0].name)“" : "\(items.count) položek")?"
        a.informativeText = items.prefix(10).map { ($0.isDir ? "📁 " : "") + $0.name }.joined(separator: "\n")
            + "\n\nSmazání nelze vrátit. Složky musí být prázdné (SFTP neumí mazat rekurzivně)."
            + (production ? "\n\n⚠️ Produkční zařízení (PROD)." : "")
        a.addButton(withTitle: "Smazat"); a.addButton(withTitle: "Zrušit")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let cmds = items.map { ($0.isDir ? "rmdir " : "rm ") + Self.q(Self.join(path, $0.name)) }
        Task {
            let r = await run(cmds)
            if !r.ok { error = Self.cleanErr(r.err) }
            await list(path)
        }
    }

    func copyPath(_ e: Entry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.join(path, e.name), forType: .string)
    }

    func clearFinished() { transfers.removeAll { $0.state != .running } }
}

// MARK: - Panel

struct FileBrowserPanel: View {
    @ObservedObject var b: SFTPBrowser
    var embedded = false                // součást SFTP záložky (bez tlačítka zavřít)
    @EnvironmentObject private var tabs: TabManager

    private var selected: [SFTPBrowser.Entry] { b.visibleEntries.filter { b.selection.contains($0.id) } }

    private func sizeText(_ e: SFTPBrowser.Entry) -> String {
        e.isDir ? "—" : ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file)
    }

    private func tool(_ icon: String, _ help: String, disabled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 12)).frame(width: 24, height: 22) }
            .buttonStyle(.plain).foregroundStyle(disabled ? UI.textTertiary : UI.text)
            .disabled(disabled).help(help)
    }

    var body: some View {
        VStack(spacing: 0) {
            // záhlaví
            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(UI.accent)
                Text((embedded ? "SFTP · " : "Soubory · ") + b.sessionName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if b.production { EnvBadge(tag: "prod") }
                Spacer()
                if !embedded {
                    Button { tabs.showFiles = false } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(UI.textTertiary).help("Zavřít panel (⇧⌘E)")
                }
            }
            .padding(.horizontal, 10).frame(height: 30).background(UI.chrome)

            // nástroje
            HStack(spacing: 2) {
                tool("arrow.up", "O úroveň výš", disabled: b.path == "/") { b.up() }
                tool("house", "Domovská složka") { b.homeDir() }
                tool("arrow.clockwise", "Obnovit") { b.refresh() }
                Divider().frame(height: 16).padding(.horizontal, 4)
                tool("arrow.up.doc", "↑ Nahrát soubory z Macu do této složky") { b.chooseUpload() }
                tool("arrow.down.doc", "↓ Stáhnout vybrané do Macu", disabled: selected.isEmpty) { b.download(selected) }
                tool("folder.badge.plus", "Nová složka") { b.mkdir() }
                tool("trash", "Smazat vybrané", disabled: selected.isEmpty) { b.delete(selected) }
                Spacer()
                Toggle(isOn: $b.showHidden) { Image(systemName: "eye") }
                    .toggleStyle(.button).controlSize(.small).help("Zobrazit skryté soubory (.*)")
            }
            .padding(.horizontal, 6).frame(height: 30)

            // cesta
            HStack(spacing: 4) {
                TextField("/cesta", text: $b.pathField).textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .onSubmit { b.goToField() }
                if b.loading { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(UI.app))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(UI.border, lineWidth: 1))
            .padding(.horizontal, 8).padding(.bottom, 6)

            if b.waiting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Čekám na přihlášení… (heslo / OTP zadej v terminálu dole)").font(.system(size: 11))
                        .foregroundStyle(UI.textSecondary)
                }
                .padding(.horizontal, 10).padding(.bottom, 6)
            }
            if let err = b.error {
                Label(err, systemImage: "exclamationmark.triangle").font(.system(size: 11))
                    .foregroundStyle(UI.error).padding(.horizontal, 10).padding(.bottom, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // seznam
            Table(b.visibleEntries, selection: $b.selection) {
                TableColumn("Název") { e in
                    HStack(spacing: 5) {
                        Image(systemName: e.isDir ? "folder.fill" : e.isLink ? "link" : "doc")
                            .foregroundStyle(e.isDir ? UI.accent : UI.textSecondary).font(.system(size: 11))
                        Text(e.name).lineLimit(1).truncationMode(.middle)
                    }
                    .help("\(e.perms)  \(e.owner)\n\(e.name)")
                }
                TableColumn("Velikost") { e in Text(sizeText(e)).foregroundStyle(UI.textSecondary).monospacedDigit() }
                    .width(min: 50, ideal: 64, max: 90)
                TableColumn("Změněno") { e in Text(e.date).foregroundStyle(UI.textSecondary) }
                    .width(min: 70, ideal: 90, max: 120)
            }
            .font(.system(size: 11.5))
            .contextMenu(forSelectionType: String.self) { ids in
                let items = b.visibleEntries.filter { ids.contains($0.id) }
                if items.isEmpty {
                    Button("↑ Nahrát sem…") { b.chooseUpload() }
                    Button("Nová složka…") { b.mkdir() }
                    Button("Obnovit") { b.refresh() }
                } else {
                    if items.count == 1, items[0].isDir || items[0].isLink { Button("Otevřít") { b.open(items[0]) } }
                    Button("↓ Stáhnout…") { b.download(items) }
                    if items.count == 1 {
                        Button("Kopírovat cestu") { b.copyPath(items[0]) }
                        Button("Vložit cestu do terminálu") {
                            tabs.insertSnippet(Snippet(name: "", command: SFTPBrowser.join(b.path, items[0].name)), run: false)
                        }
                        Divider()
                        Button("Přejmenovat…") { b.rename(items[0]) }
                    }
                    Button("Smazat…") { b.delete(items) }
                }
            } primaryAction: { ids in
                if let e = b.visibleEntries.first(where: { ids.contains($0.id) }) { b.open(e) }
            }
            .onDrop(of: [.fileURL], isTargeted: $b.dropTargeted) { providers in
                let group = DispatchGroup()
                let box = Box<[URL]>([])
                for p in providers {
                    group.enter()
                    _ = p.loadObject(ofClass: URL.self) { u, _ in
                        if let u { box.mutate { $0.append(u) } }
                        group.leave()
                    }
                }
                group.notify(queue: .main) { b.upload(box.value) }
                return true
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(UI.accent, lineWidth: b.dropTargeted ? 2 : 0))

            // přenosy
            if !b.transfers.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Přenosy").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(UI.textSecondary)
                        Spacer()
                        Button("Vyčistit") { b.clearFinished() }.buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(UI.accent)
                    }
                    ForEach(b.transfers.prefix(5)) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                switch t.state {
                                case .running: ProgressView().controlSize(.mini)
                                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(UI.ok)
                                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(UI.error)
                                }
                                Text(t.title).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                if t.state == .running, let fr = t.fraction {
                                    Text("\(Int(fr * 100)) %").font(.system(size: 11, design: .monospaced))
                                }
                                if let u = t.reveal {
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([u]) } label: { Image(systemName: "magnifyingglass") }
                                        .buttonStyle(.plain).foregroundStyle(UI.accent).help("Zobrazit ve Finderu")
                                }
                            }
                            if t.state == .running {
                                if let fr = t.fraction {
                                    ProgressView(value: fr).progressViewStyle(.linear).controlSize(.small)
                                }
                                Text(t.progressText).font(.system(size: 10, design: .monospaced)).foregroundStyle(UI.textSecondary)
                            }
                        }
                        .font(.system(size: 11))
                        .help(t.detail.isEmpty ? t.progressText : t.detail)
                    }
                }
                .padding(8)
                .background(UI.chrome)
            }
            Text("Dvojklik = otevřít složku / stáhnout soubor · soubory z Finderu sem přetáhni pro nahrání")
                .font(.system(size: 9.5)).foregroundStyle(UI.textTertiary)
                .padding(.vertical, 4)
        }
        .background(UI.sidebar)
    }
}

/// Vláknově bezpečná schránka pro hodnotu sdílenou mezi vlákny.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}

/// Průběh přenosu z otevřených souborů procesu (libproc) – offset souboru na Macu, který sftp čte / zapisuje.
enum FDProgress {
    struct OpenFile { let path: String; let offset: Int64 }

    static func openFiles(pid: Int32) -> [OpenFile] {
        let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufSize > 0 else { return [] }
        let count = Int(bufSize) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufSize)
        guard used > 0 else { return [] }
        var out: [OpenFile] = []
        for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            out.append(OpenFile(path: path, offset: info.pfi.fi_offset))
        }
        return out
    }

    static func size(_ path: String) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64
    }

    /// Celková velikost souborů (i ve složkách) k nahrání.
    static func totalSize(_ urls: [URL]) -> Int64 {
        var total: Int64 = 0
        for u in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue { total += size(u.path) ?? 0; continue }
            if let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                for case let f as URL in e {
                    let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
                }
            }
        }
        return total
    }
}
