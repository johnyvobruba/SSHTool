import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Pozn.: místo @State používáme ObservableObject + @StateObject.
// @State je v novém SDK makro (SwiftUIMacros), jehož plugin Command Line Tools nemají.

final class SessionListModel: ObservableObject {
    @Published var selection = Set<UUID>()
    @Published var editing: SSHSession?
    @Published var search = ""
    @Published var dropTarget: String?          // skupina, nad kterou se táhne server
}

final class SessionEditorModel: ObservableObject {
    @Published var session: SSHSession
    @Published var password = ""
    @Published var showGroups = false
    @Published var groupQuery = ""
    @Published var advanced = false
    @Published var rdpAdvanced = false
    @Published var authMore = false
    init(_ session: SSHSession) {
        self.session = session
        advanced = !session.extraArgs.isEmpty || session.keepAlive > 0 || session.connectTimeout > 0 || !session.hostKeyPolicy.isEmpty
    }
}

struct SessionListView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var tabs: TabManager
    @StateObject private var ui = SessionListModel()

    private static let favoritesKey = "★"
    static let dragPrefix = "sshtool-server:"
    static let folderPrefix = "sshtool-folder:"

    /// Přesun přetaženého serveru nebo celé složky do složky.
    private func dropSession(_ items: [String], to group: String) -> Bool {
        guard let raw = items.first else { return false }
        if raw.hasPrefix(Self.folderPrefix) {
            let path = String(raw.dropFirst(Self.folderPrefix.count))
            let parent = (path as NSString).deletingLastPathComponent
            guard path != group, parent != group else { return false }
            store.moveFolder(path, into: group)
            return true
        }
        guard raw.hasPrefix(Self.dragPrefix),
              let id = UUID(uuidString: String(raw.dropFirst(Self.dragPrefix.count))),
              let s = store.session(id), s.group != group else { return false }
        store.move(id, toGroup: group)
        if store.isGroupCollapsed(group) { store.toggleGroup(group) }   // ukázat, kam server přibyl
        return true
    }

    // MARK: Strom složek

    final class FolderNode: Identifiable {
        let path: String
        let name: String
        var children: [FolderNode] = []
        var sessions: [SSHSession] = []
        var total = 0
        var id: String { path }
        init(path: String) {
            self.path = path
            name = path.split(separator: "/").last.map(String.init) ?? path
        }
    }

    /// Strom složek se servery (při hledání jen větve se shodou).
    private var tree: [FolderNode] {
        var nodes: [String: FolderNode] = [:]
        for p in store.groupNames { nodes[p] = FolderNode(path: p) }
        for s in store.sessions where matches(s) {
            let g = AppStore.normPath(s.group).isEmpty ? "Default" : s.group
            if nodes[g] == nil { nodes[g] = FolderNode(path: g) }
            nodes[g]!.sessions.append(s)
        }
        var roots: [FolderNode] = []
        for (p, n) in nodes {
            if let slash = p.lastIndex(of: "/"), let parent = nodes[String(p[..<slash])] { parent.children.append(n) }
            else { roots.append(n) }
        }
        func finish(_ n: FolderNode) -> Int {
            n.children.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            n.sessions.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            n.total = n.sessions.count + n.children.map(finish).reduce(0, +)
            if !ui.search.isEmpty { n.children.removeAll { $0.total == 0 } }
            return n.total
        }
        roots.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        roots.forEach { _ = finish($0) }
        return ui.search.isEmpty ? roots : roots.filter { $0.total > 0 }
    }

    private func folderView(_ n: FolderNode, depth: Int) -> AnyView {
        AnyView(Group {
            GroupHeaderRow(title: depth == 0 ? n.name.uppercased() : n.name, count: n.total,
                           collapsed: collapsed(n.path),
                           icon: depth == 0 ? nil : (collapsed(n.path) ? "folder" : "folder.fill"),
                           color: UI.sessionColor(GroupPalette.color(for: n.path)),
                           depth: depth) {
                store.toggleGroup(n.path)
            }
            .onDrag { NSItemProvider(object: (Self.folderPrefix + n.path) as NSString) }
            .onDrop(of: [.plainText, .utf8PlainText, .text],
                    isTargeted: Binding(get: { ui.dropTarget == n.path },
                                        set: { setTarget($0, n.path) })) { providers in
                handleDrop(providers, to: n.path)
            }
            .background(RoundedRectangle(cornerRadius: 5)
                .stroke(UI.accent, lineWidth: ui.dropTarget == n.path ? 1.5 : 0))
            .contextMenu { groupMenu(n.path) }
            if !collapsed(n.path) {
                ForEach(n.children) { c in folderView(c, depth: depth + 1) }
                ForEach(n.sessions) { s in row(s, inGroup: true, depth: depth + 1) }
            }
        })
    }

    /// Drop přes NSItemProvider (spolehlivé uvnitř List na macOS – .dropDestination v Listu nereaguje).
    private func handleDrop(_ providers: [NSItemProvider], to group: String) -> Bool {
        guard let p = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = p.loadObject(ofClass: NSString.self) { obj, _ in
            guard let str = obj as? String else { return }
            DispatchQueue.main.async {
                _ = dropSession([str], to: group)
                ui.dropTarget = nil
            }
        }
        return true
    }

    private func setTarget(_ on: Bool, _ group: String) {
        if on { ui.dropTarget = group } else if ui.dropTarget == group { ui.dropTarget = nil }
    }

    private func matches(_ s: SSHSession) -> Bool {
        let q = ui.search.lowercased().trimmingCharacters(in: .whitespaces)
        return q.isEmpty || s.name.lowercased().contains(q) || s.host.contains(q) || s.group.lowercased().contains(q)
    }

    private var favorites: [SSHSession] {
        store.sessions.filter { $0.favorite && matches($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var grouped: [(group: String, items: [SSHSession])] {
        store.groupedSessions
            .map { g in (group: g.group, items: g.items.filter { matches($0) }) }
            .filter { !$0.items.isEmpty }
    }

    /// Při hledání jsou všechny skupiny rozbalené.
    private func collapsed(_ g: String) -> Bool { ui.search.isEmpty && store.isGroupCollapsed(g) }

    /// Řádek serveru: dvojklik = připojit (nebo přejít na otevřenou relaci), pravé tlačítko = menu.
    /// Bez výběru Listu → žádné dvojí zvýraznění; zvýrazněný je jen server aktivní záložky.
    private func row(_ s: SSHSession, inGroup: Bool = false, depth: Int = 0) -> some View {
        let favVisible = store.settings.showFavorites && s.favorite && !collapsed(Self.favoritesKey)
        return SidebarSessionRow(session: s, state: tabs.state(for: s.id),
                          active: tabs.activeSessionID == s.id && !(inGroup && favVisible),
                          comfortable: store.settings.sidebarComfortable,
                          query: ui.search,
                          toggleFavorite: { store.toggleFavorite(s.id) })
            .padding(.leading, CGFloat(max(0, depth - 1)) * 14)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { tabs.openOrFocus(s) }
            .contextMenu { ServerContextMenu(session: s, edit: { ui.editing = s }) }
            // přetažení serveru na jinou skupinu (záhlaví nebo server v ní) = přesun do skupiny
            .onDrag {
                NSItemProvider(object: (Self.dragPrefix + s.id.uuidString) as NSString)
            }
            .onDrop(of: [.plainText, .utf8PlainText, .text],
                    isTargeted: Binding(get: { inGroup && ui.dropTarget == s.group },
                                        set: { if inGroup { setTarget($0, s.group) } })) { providers in
                inGroup ? handleDrop(providers, to: s.group) : false
            }
            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 6))
    }

    private func groupMenu(_ g: String) -> some View {
        Group {
            Button("Sbalit všechny složky") { store.collapseAll(true) }
            Button("Rozbalit všechny složky") { store.collapseAll(false) }
            if g == Self.favoritesKey {
                Divider()
                Button("Skrýt sekci Oblíbené") { store.settings.showFavorites = false }
            } else {
                Divider()
                Button("Nový server v této složce…") { ui.editing = newSession(in: g) }
                Button("Hromadná úprava serverů ve složce…") { tabs.bulkEditGroup = g }
                Button("Nová podsložka…") {
                    if let n = askText("Nová podsložka", "Název podsložky v „\(g)“:") { store.createFolder(g + "/" + n) }
                }
                Divider()
                Button("Přejmenovat složku…") {
                    let leaf = g.split(separator: "/").last.map(String.init) ?? g
                    if let n = askText("Přejmenovat složku", "Nový název složky „\(leaf)“:", initial: leaf), !n.contains("/") {
                        let parent = (g as NSString).deletingLastPathComponent
                        store.renameGroup(g, to: parent.isEmpty ? n : parent + "/" + n)
                    }
                }
                Menu("Přesunout do složky") {
                    if g.contains("/") { Button("Do kořene") { store.moveFolder(g, into: nil) } ; Divider() }
                    ForEach(store.groupNames.filter { !AppStore.inSubtree($0, g) && $0 != (g as NSString).deletingLastPathComponent }, id: \.self) { t in
                        Button(t.replacingOccurrences(of: "/", with: " / ")) { store.moveFolder(g, into: t) }
                    }
                }
                if !store.sessions.contains(where: { AppStore.inSubtree($0.group, g) }) {
                    Button("Smazat prázdnou složku") { store.deleteFolder(g) }
                }
                Menu("Barva složky") {
                    Button("Automatická") { store.setGroupColor(g, nil) }
                    Divider()
                    ForEach(GroupPalette.colors, id: \.self) { h in
                        Button(GroupPalette.name(h)) { store.setGroupColor(g, h) }
                    }
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SidebarSearchField(text: $ui.search)
                Menu {
                    Button("Nový server…") { ui.editing = newSession() }
                    Button("Nová složka…") {
                        if let n = askText("Nová složka", "Název složky (podsložky odděl lomítkem, např. ANECT/Praha):") { store.createFolder(n) }
                    }
                    Button("Rychlé připojení…  ⇧⌘K") { tabs.showQuickConnect = true }
                    Divider()
                    Button("Sbalit všechny složky") { store.collapseAll(true) }
                    Button("Rozbalit všechny složky") { store.collapseAll(false) }
                    Button(store.settings.showFavorites ? "Skrýt Oblíbené" : "Zobrazit Oblíbené") {
                        store.settings.showFavorites.toggle()
                    }
                    Divider()
                    Button("Importovat servery (JSON)…") { store.importSessionsPanel() }
                    Button("Exportovat servery bez hesel…") { store.exportSessionsPanel() }
                    Button("Uložit vzor JSON pro kolegy…") { store.saveSessionsTemplatePanel() }
                } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                } primaryAction: {
                    ui.editing = newSession()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(UI.card))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(UI.border, lineWidth: 1))
                .help("Nový server (klik) · podrž pro další volby")
            }
            .padding(.horizontal, 10)
            .padding(.top, 34)                 // místo pro semafor okna (titulková lišta je skrytá)
            .padding(.bottom, 10)
            .background(WindowDragHandle())
            List {
                SerialPortsSection()
                if store.settings.showFavorites, !favorites.isEmpty {
                    GroupHeaderRow(title: "Oblíbené", count: favorites.count,
                                   collapsed: collapsed(Self.favoritesKey), icon: "star.fill") {
                        store.toggleGroup(Self.favoritesKey)
                    }
                    .contextMenu { groupMenu(Self.favoritesKey) }
                    if !collapsed(Self.favoritesKey) {
                        ForEach(favorites) { s in row(s) }
                    }
                }
                ForEach(tree) { n in folderView(n, depth: 0) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(UI.sidebar)
        .sheet(item: $ui.editing) { s in
            SessionEditor(session: s, groups: store.groupNames, groupColors: store.groupColors,
                          existing: store.sessions) { store.upsert($0, password: $1) }
        }
        .frame(minWidth: 220, minHeight: 300)
    }

    /// Nový server – předvyplněná skupina = skupina aktivní záložky (jinak první existující).
    private func newSession(in folder: String? = nil) -> SSHSession {
        var s = SSHSession(name: "", host: "")
        if let folder { s.colorHex = ""; s.group = folder; return s }
        s.colorHex = ""                        // výchozí: barva skupiny
        s.group = tabs.selected.map { $0.session.group }.flatMap { store.groupNames.contains($0) ? $0 : nil }
            ?? store.groupNames.first ?? "Default"
        return s
    }
}

/// Kontextové menu serveru – přizpůsobí se tomu, zda je relace otevřená.
struct ServerContextMenu: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var tabs: TabManager
    let session: SSHSession
    let edit: () -> Void

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    var body: some View {
        if session.isRDP { rdpMenu } else if session.isTelnet || session.isFTP { telnetMenu } else { sshMenu }
    }

    @ViewBuilder private var rdpMenu: some View {
        Button("Připojit (RDP)") { RDPLauncher.shared.launch(session) }
        Button("Připojit se sdílenou složkou…") { RDPLauncher.shared.launchWithFolderPicker(session) }
        if NSScreen.screens.count > 1 {
            Menu(RDPLauncher.shared.isRunning(session.id) ? "Přepojit na monitor" : "Připojit na monitoru") {
                ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { name in
                    Button(name) { RDPLauncher.shared.reconnect(session, monitor: name) }
                }
            }
        }
        Menu(RDPLauncher.shared.isRunning(session.id) ? "Měřítko ve Windows (přepojí)" : "Měřítko ve Windows") {
            ForEach([0, 100, 125, 150, 175, 200], id: \.self) { v in
                Button((session.rdpScale == v ? "✓ " : "") + (v == 0 ? "Automaticky" : "\(v) %")) {
                    RDPLauncher.shared.setScale(session, v)
                }
            }
        }
        if RDPLauncher.shared.isRunning(session.id) {
            Button("Celá obrazovka (přepojit)") {
                RDPLauncher.shared.reconnect(session, monitor: FreeRDP.targetScreen(session)?.localizedName)
            }
            Button("V okně (přepojit)") { RDPLauncher.shared.reconnectWindowed(session) }
            Button("Odpojit") { RDPLauncher.shared.disconnect(session.id) }
        }
        Divider()
        Button("Upravit server…") { edit() }
        Button("Duplikovat server") { store.duplicate(session) }
        Button("Kopírovat IP adresu") { copy(session.host) }
        Button("Kopírovat příkaz FreeRDP (bez hesla)") { copy(FreeRDP.commandLine(session)) }
        commonTail
    }

    @ViewBuilder private var telnetMenu: some View {
        if let live = tabs.liveTab(for: session.id) {
            Button("Přejít na otevřenou relaci") { tabs.focus(live) }
            Button("Připojit znovu v nové záložce") { tabs.open(session) }
        } else {
            Button(session.isFTP ? "Otevřít soubory (FTP)" : "Připojit (Telnet)") { tabs.open(session) }
        }
        Button("Připojit v rozděleném panelu") { tabs.openInSplit(session) }
        Divider()
        Button("Upravit server…") { edit() }
        Button("Duplikovat server") { store.duplicate(session) }
        Button("Kopírovat IP adresu") { copy(session.host) }
        commonTail
    }

    @ViewBuilder private var sshMenu: some View {
        let live = tabs.liveTab(for: session.id)
        if let live {
            Button("Přejít na otevřenou relaci") { tabs.focus(live) }
            Button("Odpojit") { tabs.disconnect(live.id) }
            Button("Připojit znovu v nové záložce") { tabs.open(session) }
        } else {
            Button("Připojit") { tabs.open(session) }
        }
        Button("Připojit v rozděleném panelu") { tabs.openInSplit(session) }
        Button("Otevřít SFTP") { tabs.openSFTP(session) }
        if let url = session.webURL {
            Button("Otevřít web (\(url.absoluteString))") { WebOpener.open(session) }
        }
        Divider()
        Button("Upravit server…") { edit() }
        Button("Duplikovat server") { store.duplicate(session) }
        Button("Kopírovat IP adresu") { copy(session.host) }
        Button("Kopírovat SSH příkaz") { copy(session.sshCommand) }
        commonTail
    }

    @ViewBuilder private var commonTail: some View {
        Divider()
        Button(session.favorite ? "Odebrat z oblíbených" : "Přidat do oblíbených") { store.toggleFavorite(session.id) }
        Menu("Přesunout do složky") {
            ForEach(store.groupNames.filter { $0 != session.group }, id: \.self) { g in
                Button(g) { store.move(session.id, toGroup: g) }
            }
            Divider()
            Button("Nová složka…") {
                if let g = askText("Nová složka", "Název složky (podsložka: A/B):") { store.move(session.id, toGroup: g) }
            }
        }
        Divider()
        Button("Smazat server…", role: .destructive) {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "Přesunout server „\(session.name)“ do koše?"
            a.informativeText = "Z koše ho do 30 dní obnovíš (Soubor → Koš…), včetně uloženého hesla. Otevřené relace zůstanou do zavření."
            a.addButton(withTitle: "Smazat")
            a.addButton(withTitle: "Zrušit")
            if a.runModal() == .alertFirstButtonReturn { store.delete(session.id) }
        }
    }
}

/// Jednoduchý dialog s textovým polem.
@MainActor
func askText(_ title: String, _ label: String, initial: String = "") -> String? {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = label
    let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    f.stringValue = initial
    a.accessoryView = f
    a.addButton(withTitle: "OK")
    a.addButton(withTitle: "Zrušit")
    a.window.initialFirstResponder = f
    guard a.runModal() == .alertFirstButtonReturn else { return nil }
    let v = f.stringValue.trimmingCharacters(in: .whitespaces)
    return v.isEmpty ? nil : v
}

struct SessionRow: View {
    let session: SSHSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(Color(hex: session.colorHex) ?? .secondary)
            Text(session.name)
            Text(session.host)
                .font(.callout)
                .foregroundStyle(.secondary)
            if session.usesStoredPassword {
                Image(systemName: session.requireUserAuth ? "touchid" : "key.fill")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .help(session.requireUserAuth ? "Uložené heslo, chráněné Touch ID / heslem Macu" : "Uložené heslo bez ochrany")
            }
        }
    }
}

// MARK: - Editor serveru (Přidat / Upravit)

struct SessionEditor: View {
    @StateObject private var m: SessionEditorModel
    @StateObject private var tester = ConnectionTester()
    @AppStorage("SSHTool.rdpCurtain") private var rdpCurtain = true
    @AppStorage("SSHTool.rdpToolbar") private var rdpToolbar = true
    @Environment(\.dismiss) private var dismiss
    private let onSave: (SSHSession, String?) -> Void
    private let groups: [String]
    private let groupColors: [String: String]
    private let existing: [SSHSession]

    static let palette = ["#E5747A", "#E7B765", "#4BC995", "#76C7D9", "#7299FF", "#C69AE8", "#F08CC0", "#8E8E93"]

    init(session: SSHSession, groups: [String] = [], groupColors: [String: String] = [:],
         existing: [SSHSession] = [], onSave: @escaping (SSHSession, String?) -> Void) {
        _m = StateObject(wrappedValue: SessionEditorModel(session))
        self.groups = groups
        self.groupColors = groupColors
        self.existing = existing
        self.onSave = onSave
    }

    // MARK: Validace

    private var problems: [String] {
        let s = m.session
        var p: [String] = []
        let name = s.name.trimmingCharacters(in: .whitespaces)
        let host = s.host.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { p.append("Vyplň název serveru.") }
        if host.isEmpty { p.append("Vyplň host (IP adresu nebo hostname).") }
        else if host.contains("@") { p.append("Host nemá obsahovat „@“ – uživatele zadej do pole Uživatel.") }
        else if host.range(of: #"^[A-Za-z0-9._:%\[\]-]+$"#, options: .regularExpression) == nil {
            p.append("Host obsahuje nepovolené znaky (mezera, /, …).")
        }
        if !(1...65535).contains(s.port) { p.append("Port musí být 1–65535.") }
        if s.user.contains(" ") || (!s.isRDP && !s.isFTP && s.user.contains("@")) { p.append("Uživatel nesmí obsahovat mezeru ani „@“.") }
        if s.jumpHost.contains(" ") { p.append("Jump host nesmí obsahovat mezeru (formát user@bastion:port).") }
        if s.group.trimmingCharacters(in: .whitespaces).isEmpty { p.append("Vyber nebo zadej složku.") }
        if !name.isEmpty, existing.contains(where: {
            $0.id != s.id && $0.group == s.group && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            p.append("Ve složce „\(s.group)“ už server s tímto názvem existuje.")
        }
        // Stejná IP u více záznamů je v pořádku (různé účty / porty).
        return p
    }

    var body: some View {
        VStack(spacing: 0) {
            form
            Rectangle().fill(UI.border).frame(height: 1)
            // fixní spodní lišta – obsah nad ní se posouvá, okno neroste
            HStack(spacing: 10) {
                if let p = problems.first {
                    Label(p, systemImage: "exclamationmark.circle").font(.system(size: 11.5))
                        .foregroundStyle(UI.error).lineLimit(1).help(problems.joined(separator: "\n"))
                }
                Spacer()
                Button("Zrušit") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(SKButton())
                Button("Uložit") { save() }.keyboardShortcut(.defaultAction)
                    .buttonStyle(SKButton(kind: .primary)).disabled(!problems.isEmpty)
            }
            .padding(.horizontal, 20).frame(height: 56)
            .background(UI.chrome)
        }
        .frame(width: 660, height: 640)
        .background(UI.sidebar)
        .tint(UI.accent)
    }

    private func save() {
        var s = m.session
        s.name = s.name.trimmingCharacters(in: .whitespaces)
        s.host = s.host.trimmingCharacters(in: .whitespaces)
        s.group = s.group.trimmingCharacters(in: .whitespaces)
        s.keepAlive = max(0, s.keepAlive); s.connectTimeout = max(0, s.connectTimeout)
        s.user = s.user.trimmingCharacters(in: .whitespaces)
        s.jumpHost = s.jumpHost.trimmingCharacters(in: .whitespaces)
        if let problem = AppStore.fieldProblem(s) {
            let a = NSAlert(); a.alertStyle = .warning
            a.messageText = "Server nelze uložit"
            a.informativeText = problem
            a.runModal()
            return
        }
        onSave(s, m.password.isEmpty ? nil : m.password)
        dismiss()
    }

    private var form: some View {
        Form {
            Section("Základní informace") {
                Picker("Protokol", selection: protoBinding) {
                    Text("SSH").tag("ssh")
                    Text("RDP (Windows)").tag("rdp")
                    Text("Telnet").tag("telnet")
                    Text("FTP").tag("ftp")
                }
                .pickerStyle(.segmented)
                TextField("Název serveru", text: $m.session.name, prompt: Text("např. fw1-praha"))
                LabeledContent("Složka") {
                    HStack(spacing: 12) {
                        groupButton
                        Spacer()
                        Text("Prostředí").foregroundStyle(.secondary)
                        Picker("", selection: envBinding) {
                            Text("Production").tag("prod")
                            Text("Staging").tag("stage")
                            Text("Development").tag("dev")
                            Text("Test").tag("test")
                            Divider()
                            Text("Neoznačeno").tag("")
                        }
                        .labelsHidden().frame(width: 140)
                    }
                }
                LabeledContent("Barva") { colorPalette }
            }
            Section("Připojení") {
                LabeledContent("Host") {
                    HStack(spacing: 8) {
                        TextField("", text: $m.session.host, prompt: Text("192.0.2.10 nebo fw1.example.com"))
                            .labelsHidden()
                        Text("Port").foregroundStyle(.secondary)
                        TextField("", value: $m.session.port, format: .number.grouping(.never))
                            .labelsHidden().frame(width: 64)
                    }
                }
                TextField("Uživatel", text: $m.session.user, prompt: Text("admin"))
                if m.session.isRDP {
                    TextField("Doména", text: $m.session.rdpDomain, prompt: Text("CORP (volitelné)"))
                } else if m.session.isFTP {
                    Picker("Šifrování", selection: ftpTLSBinding) {
                        Text("FTPS – explicitní (AUTH TLS)").tag("explicit")
                        Text("FTPS – implicitní (port 990)").tag("implicit")
                        Text("Bez šifrování (FTP)").tag("")
                    }
                    if m.session.ftpTLS.isEmpty {
                        Label("Nešifrované FTP – jméno, heslo i obsah souborů jdou sítí čitelně. Jen pro zařízení, která FTPS ani SFTP neumí.",
                              systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.orange)
                    } else {
                        Toggle("Nekontrolovat certifikát serveru (self-signed)", isOn: $m.session.ftpInsecure)
                        if m.session.ftpInsecure {
                            Text("Šifrované, ale bez ověření identity serveru – útočník v síti se může vydávat za server a získat heslo. Lepší je přidat certifikát/CA do Klíčenky.")
                                .font(.caption).foregroundStyle(Color.orange)
                        }
                    }
                } else if m.session.isTelnet {
                    Label("Telnet není šifrovaný – přihlašovací jméno, heslo i celý výstup jdou sítí čitelně. Používej jen tam, kde zařízení SSH neumí, ideálně ve správcovské síti.",
                          systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.orange)
                } else {
                    TextField("Jump host", text: $m.session.jumpHost, prompt: Text("user@bastion (ProxyJump)"))
                }
            }
            Section("Poznámky") {
                TextEditor(text: $m.session.notes)
                    .font(.system(.body))
                    .frame(minHeight: 60)
                Text("Např. umístění, kontakt, číslo smlouvy, specifika přihlášení. Nepiš sem hesla – poznámky jsou v sessions.json a v exportu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if m.session.isRDP { rdpSections } else if m.session.isTelnet { EmptyView() } else if m.session.isFTP { ftpSections } else {
            Section("Autentizace") {
                Picker("Způsob přihlášení", selection: $m.session.auth) {
                    Text("SSH agent / ~/.ssh/config").tag(AuthMethod.agent)
                    Text("Soukromý SSH klíč").tag(AuthMethod.key)
                    Text("Heslo v Klíčence macOS").tag(AuthMethod.password)
                    Text("Interaktivní (heslo / OTP při připojení)").tag(AuthMethod.interactive)
                }
                authFields
            }
            Section {
                DisclosureGroup("Pokročilé SSH nastavení", isExpanded: $m.advanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Další argumenty") {
                            TextField("", text: $m.session.extraArgs, prompt: Text("-o ServerAliveCountMax=3"))
                                .labelsHidden().font(.system(.body, design: .monospaced))
                        }
                        ForEach(m.session.extraArgsWarnings, id: \.self) { w in
                            Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.orange)
                        }
                        HStack {
                            Text("KeepAlive (s)")
                            Spacer()
                            TextField("", value: $m.session.keepAlive, format: .number.grouping(.never))
                                .frame(width: 70).multilineTextAlignment(.trailing)
                            Text("0 = výchozí").font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                        }
                        HStack {
                            Text("Timeout připojení (s)")
                            Spacer()
                            TextField("", value: $m.session.connectTimeout, format: .number.grouping(.never))
                                .frame(width: 70).multilineTextAlignment(.trailing)
                            Text("0 = výchozí").font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                        }
                        Picker("X11 forwarding", selection: $m.session.x11) {
                            Text("Vypnuto").tag("")
                            Text("Nedůvěryhodné (-X) – doporučeno").tag("untrusted")
                            Text("Důvěryhodné (-Y)").tag("trusted")
                        }
                        if !m.session.x11.isEmpty {
                            Text((FileManager.default.fileExists(atPath: "/Applications/Utilities/XQuartz.app") ? "" : "Pro zobrazení oken je potřeba XQuartz (brew install --cask xquartz). ")
                                 + (m.session.x11 == "trusted" ? "Důvěryhodné X11 dává serveru plný přístup k tvému displeji (i zachytávání kláves) – jen pro důvěryhodné servery." : "Grafické aplikace ze serveru (např. Wireshark, xterm) se otevřou na Macu."))
                                .font(.caption).foregroundStyle(m.session.x11 == "trusted" ? Color.orange : .secondary)
                        }
                        Toggle("Starší zařízení – povolit legacy algoritmy", isOn: $m.session.legacyAlgorithms)
                        Text(m.session.legacyAlgorithms
                             ? "Přidá k výchozím: ssh-rsa (SHA-1), diffie-hellman-group14/1-sha1, CBC šifry, hmac-sha1 – jen ty, které klient ssh ještě zná. Slabší šifrování, používej jen pro staré Cisco IOS/ASA, F5, Gaia apod. Algoritmus, který OpenSSH úplně odstranil (DSA), vrátí jen jiný klient ssh (Nastavení → Obecné → Klient SSH)."
                             : "Pro zařízení, která po aktualizaci macOS hlásí „no matching key exchange / host key type / cipher“.")
                            .font(.caption).foregroundStyle(m.session.legacyAlgorithms ? Color.orange : .secondary)
                        Picker("Přenos souborů", selection: $m.session.fileTransfer) {
                            Text("SFTP (výchozí)").tag("")
                            Text("SCP – zařízení bez SFTP").tag("scp")
                        }
                        if m.session.fileTransfer == "scp" {
                            Text("Prohlížeč souborů použije scp -O a příkazy ls/mkdir/mv/rm přes stejné SSH spojení. Server musí mít běžný shell.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Picker("Kontrola klíče serveru", selection: $m.session.hostKeyPolicy) {
                            Text("Výchozí (~/.ssh/config)").tag("")
                            Text("Zeptat se u nového klíče (ask)").tag("ask")
                            Text("Striktní – jen známé klíče (yes)").tag("yes")
                            Text("Přijmout nový, odmítnout změněný (accept-new)").tag("accept-new")
                        }
                        Text("Ignorování kontroly klíče se záměrně nenabízí. ProxyJump = pole Jump host. ~/.ssh/config se použije vždy – alias z configu lze zadat jako Host.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }
            }
            Section("Tunelování portů") {
                ForEach($m.session.forwards) { $f in
                    HStack(alignment: .top) {
                        Toggle("", isOn: $f.enabled).labelsHidden().help("Tunel zapnutý")
                        ForwardEditorRow(f: $f)
                        Button { m.session.forwards.removeAll { $0.id == f.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Odebrat tunel")
                    }
                    .padding(.vertical, 4)
                }
                Button("Přidat tunel") { m.session.forwards.append(PortForward()) }
                Text("Jako v PuTTY (Connection → SSH → Tunnels). Tunely se otevřou při připojení SSH záložky; za běhu je přidáš / zrušíš pravým tlačítkem na záložce → „Tunely…“.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Test připojení") {
                HStack {
                    Button {
                        tester.run(m.session)
                    } label: {
                        Label(tester.running ? "Testuji…" : "Otestovat připojení", systemImage: "bolt.horizontal")
                    }
                    .disabled(tester.running || m.session.host.isEmpty)
                    Spacer()
                    if tester.running { ProgressView().controlSize(.small) }
                }
                ForEach(tester.steps) { st in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        stepIcon(st.status).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(st.title)
                            if !st.detail.isEmpty {
                                Text(st.detail).font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if tester.steps.isEmpty {
                    Text("Postupně ověří DNS / IP, TCP port, SSH handshake, klíč serveru v known_hosts a přihlášení bez interakce. Test nemění known_hosts a heslo nepoužívá. Na zařízení se zaloguje krátké přihlášení.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: RDP

    private var protoBinding: Binding<String> {
        Binding(get: { m.session.proto }, set: { new in
            let defaults = ["ssh": 22, "rdp": 3389, "telnet": 23, "ftp": m.session.ftpTLS == "implicit" ? 990 : 21]
            if defaults.values.contains(m.session.port) || [21, 990].contains(m.session.port), let p = defaults[new] { m.session.port = p }
            m.session.proto = new
        })
    }

    private var ftpTLSBinding: Binding<String> {
        Binding(get: { m.session.ftpTLS }, set: { new in
            if new == "implicit", m.session.port == 21 { m.session.port = 990 }
            if new != "implicit", m.session.port == 990 { m.session.port = 21 }
            m.session.ftpTLS = new
            if new.isEmpty { m.session.ftpInsecure = false }
        })
    }

    @ViewBuilder private var ftpSections: some View {
        Section("Přihlášení") {
            PasswordSourceFields(m: m)
            Text("Prázdný uživatel = anonymní přístup. Bez uloženého hesla se SSHTool zeptá při otevření. Heslo dostane curl přes stdin (není vidět v seznamu procesů). Složky se přes FTP přenášejí jen po souborech.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func addSharedFolders() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        p.prompt = "Sdílet"; p.message = "Vyber složky, které budou dostupné v RDP relaci"
        guard p.runModal() == .OK else { return }
        for u in p.urls where !m.session.rdpFolders.contains(u.path) { m.session.rdpFolders.append(u.path) }
    }

    /// Pokročilé RDP nastavení se liší od výchozího (zobrazí se v nadpisu sbalené sekce).
    private var rdpAdvancedChanged: Bool {
        let x = m.session
        return !x.rdpSecurity.isEmpty || x.rdpBpp != 0 || !x.rdpGfx || !x.rdpUDP || !x.rdpAutoDetect
            || !x.rdpExtraArgs.isEmpty || x.rdpDebugLog
    }

    @ViewBuilder private var rdpSections: some View {
        Section("Přihlášení") {
            PasswordSourceFields(m: m)
            Text("FreeRDP dostane heslo přes stdin (není vidět v seznamu procesů). Bez hesla se zeptá okno FreeRDP.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Zobrazení") {
            Picker("Rozlišení", selection: $m.session.rdpSize) {
                Text("Dynamické (podle okna)").tag("dynamic")
                Text("Celá obrazovka").tag("fullscreen")
                Text("1920 × 1080").tag("1920x1080")
                Text("1680 × 1050").tag("1680x1050")
                Text("1440 × 900").tag("1440x900")
                Text("1280 × 800").tag("1280x800")
            }
            Picker("Měřítko ve Windows", selection: $m.session.rdpScale) {
                Text("Automaticky").tag(0)
                Text("100 %").tag(100)
                Text("125 %").tag(125)
                Text("150 %").tag(150)
                Text("175 %").tag(175)
                Text("200 %").tag(200)
            }
            Text("Velikost písma a ovládacích prvků ve Windows. Automaticky: celá obrazovka na Retině 150 %, jinak 100 %.")
                .font(.caption).foregroundStyle(.secondary)
            if m.session.rdpSize == "fullscreen" && !m.session.rdpMultiMon {
                Picker("Monitor", selection: $m.session.rdpMonitor) {
                    Text("Kde je okno SSHTool").tag("")
                    ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { Text($0).tag($0) }
                    if !m.session.rdpMonitor.isEmpty && !NSScreen.screens.contains(where: { $0.localizedName == m.session.rdpMonitor }) {
                        Text("\(m.session.rdpMonitor) (nepřipojený)").tag(m.session.rdpMonitor)
                    }
                }
                Toggle("Po přesunu na jiný monitor automaticky přepojit", isOn: $m.session.rdpAutoMonitor)
                Text(m.session.rdpAutoMonitor
                     ? "Přesun: pravý ⇧ + Enter (okno) → přetáhnout na monitor → asi za 2 s se relace přepojí na celou obrazovku v jeho rozlišení. Windows relace i aplikace zůstanou."
                     : "Celá obrazovka převezme rozlišení tohoto monitoru. Přesun na jiný monitor ji ořízne – pravé tlačítko → „Přepojit na monitor“.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Plynulý přechod do celé obrazovky", isOn: $rdpCurtain)
                Text("Při připojení a přepojení zakryje monitor černým pozadím, dokud se relace nezobrazí – bez bliknutí plochy. Platí pro všechny RDP servery.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Více monitorů", isOn: $m.session.rdpMultiMon)
            Toggle("Lišta relace po najetí myší nahoru (rozlišení, měřítko, celá obrazovka, odpojit)", isOn: $rdpToolbar)
        }
        Section("Klávesnice a schránka") {
            Toggle("Sdílená schránka", isOn: $m.session.rdpClipboard)
            Toggle("Levý ⌘ jako Ctrl (⌘C, ⌘V, ⌘A… ve Windows)", isOn: $m.session.rdpMacKeys)
            if m.session.rdpMacKeys {
                Text("Pravý ⌘ zůstává klávesou Windows. ⌘Tab dál přepíná aplikace na Macu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Klávesové zkratky v okně RDP") {
                Text(RDPLauncher.hotkeysText).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        Section("Složky") {
            Toggle("Sdílet domovskou složku Macu do relace", isOn: $m.session.rdpShareHome)
            if m.session.rdpShareHome {
                Label("Vzdálený server (a kdokoli s přístupem k relaci) uvidí soubory ve tvé domovské složce.",
                      systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.orange)
            }
            ForEach(m.session.rdpFolders, id: \.self) { path in
                HStack {
                    Image(systemName: FileManager.default.fileExists(atPath: path) ? "folder" : "questionmark.folder")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button { m.session.rdpFolders.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Přestat sdílet")
                }
            }
            Button("Přidat složku…") { addSharedFolders() }
            Toggle("Při každém připojení vybrat složku ve Finderu", isOn: $m.session.rdpAskFolder)
            Text("Jednorázově: pravé tlačítko na serveru → „Připojit se sdílenou složkou…“. Takto vybrané složky se neukládají.")
                .font(.caption).foregroundStyle(.secondary)
            if m.session.rdpFolders.isEmpty {
                Text("Vybrané složky Macu se ve Windows objeví v Průzkumníku jako „\\\\tsclient\\<název>“ (Tento počítač → Přesměrované jednotky).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Server i kdokoli s přístupem k relaci může v těchto složkách číst, měnit a mazat soubory. Sdílej jen to, co je potřeba.",
                      systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.orange)
            }
        }
        Section("Brána a certifikát") {
            TextField("RD Gateway", text: $m.session.rdpGateway, prompt: Text("gw.example.com (volitelné)"))
            Picker("Certifikát serveru", selection: $m.session.rdpCertPolicy) {
                Text("Zeptat se při neznámém / změněném").tag("")
                Text("Důvěřovat při prvním připojení (TOFU)").tag("tofu")
            }
        }
        Section {
            DisclosureGroup(isExpanded: $m.rdpAdvanced) {
                Picker("Zabezpečení", selection: $m.session.rdpSecurity) {
                    Text("Automaticky").tag("")
                    Text("NLA (doporučeno)").tag("nla")
                    Text("TLS (bez NLA)").tag("tls")
                    Text("RDP (starší, nešifrované ověření)").tag("rdp")
                }
                if m.session.rdpSecurity == "tls" || m.session.rdpSecurity == "rdp" {
                    Label("Bez NLA server ukáže přihlášení ještě před ověřením uživatele. Používej jen tam, kde NLA nefunguje.",
                          systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.orange)
                }
                Picker("Barevná hloubka", selection: $m.session.rdpBpp) {
                    Text("Výchozí (32 bit)").tag(0)
                    Text("24 bit").tag(24)
                    Text("16 bit").tag(16)
                }
                Toggle("Grafický kanál GFX (H.264)", isOn: $m.session.rdpGfx)
                Toggle("UDP multitransport", isOn: $m.session.rdpUDP)
                Toggle("Automaticky najít kompatibilní režim", isOn: $m.session.rdpAutoDetect)
                Text("Když se relace hned po otevření ukončí (TRANSPORT_FAILED), SSHTool to zkusí znovu bez GFX a UDP s 24 bity a funkční nastavení uloží sem. Přechod na TLS bez NLA vždy potvrzuješ ty. Výslovně zvolené zabezpečení se nemění.")
                    .font(.caption).foregroundStyle(.secondary)
                if !m.session.rdpGfx || !m.session.rdpUDP || m.session.rdpBpp != 0 || !m.session.rdpSecurity.isEmpty {
                    Button("Obnovit výchozí a detekovat znovu") {
                        m.session.rdpGfx = true; m.session.rdpUDP = true
                        m.session.rdpBpp = 0; m.session.rdpSecurity = ""
                        m.session.rdpAutoDetect = true
                    }
                }
                LabeledContent("Další argumenty FreeRDP") {
                    TextField("", text: $m.session.rdpExtraArgs, prompt: Text("/network:auto /sound"))
                        .labelsHidden().font(.system(.body, design: .monospaced)).multilineTextAlignment(.trailing)
                }
                Toggle("Podrobný log (diagnostika)", isOn: $m.session.rdpDebugLog)
                HStack {
                    Text(m.session.rdpDebugLog
                         ? "Přidá /log-level:DEBUG. Log obsahuje uživatele, IP a název počítače – po diagnostice vypni."
                         : "Výstup FreeRDP se ukládá do ~/Library/Logs/SSHTool (heslo se maskuje).")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Zobrazit log") { NSWorkspace.shared.open(FreeRDP.logURL(for: m.session)) }
                        .disabled(!FileManager.default.fileExists(atPath: FreeRDP.logURL(for: m.session).path))
                }
                if let v = Bundle.main.url(forResource: "FreeRDP-VERSIONS", withExtension: "txt") {
                    Button("Verze přibalených knihoven…") { NSWorkspace.shared.open(v) }
                        .help("Verze FreeRDP, OpenSSL, FFmpeg, SDL… – pro kontrolu známých zranitelností (CVE)")
                }
                if let bin = FreeRDP.binary {
                    Label("FreeRDP: \(bin)", systemImage: "checkmark.circle").font(.caption).foregroundStyle(Color.green)
                } else {
                    Label("FreeRDP nenalezen – nainstaluj: brew install freerdp", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Color.orange)
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Pokročilé – zabezpečení, kompatibilita, diagnostika")
                    if rdpAdvancedChanged {
                        Text("upraveno").font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.2))).foregroundStyle(Color.orange)
                    }
                }
            }
        }
    }

    // MARK: Autentizace

    @ViewBuilder private var authFields: some View {
        switch m.session.auth {
        case .agent:
            Picker("SSH agent", selection: agentMode) {
                Text("Systémový (SSH_AUTH_SOCK, ~/.ssh/config)").tag("")
                Text("Bitwarden").tag("bitwarden")
                Text("Vlastní socket…").tag("custom")
            }
            if agentMode.wrappedValue == "custom" {
                TextField("Socket", text: $m.session.agentSocket, prompt: Text("~/cesta/k/agent.sock"))
                    .font(.system(.body, design: .monospaced))
            }
            if let sock = m.session.resolvedAgentSocket {
                let ok = FileManager.default.fileExists(atPath: sock)
                Label(ok ? "Socket nalezen: \(sock)" : "Socket nenalezen: \(sock) – je agent spuštěný? (Bitwarden: Nastavení → Povolit SSH agenta)",
                      systemImage: ok ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(ok ? Color.green : Color.orange)
            }
            DisclosureGroup("Další možnosti autentizace", isExpanded: $m.authMore) {
                Button("Zkopírovat veřejné klíče z agenta") {
                    SSHKeys.copyAgentPublicKeys(socket: m.session.resolvedAgentSocket)
                }
                .help("ssh-add -L – pro vložení do authorized_keys na zařízení")
            }
        case .key:
            HStack {
                TextField("Soukromý klíč", text: $m.session.identityFile, prompt: Text("~/.ssh/id_ed25519"))
                    .font(.system(.body, design: .monospaced))
                Menu("Vybrat") {
                    ForEach(SSHKeys.listPrivateKeys(), id: \.self) { k in
                        Button(k) { m.session.identityFile = "~/.ssh/" + k }
                    }
                    Divider()
                    Button("Jiný soubor…") {
                        if let p = SSHKeys.pickKeyFile() { m.session.identityFile = p }
                    }
                }
                .fixedSize()
            }
            DisclosureGroup("Další možnosti autentizace", isExpanded: $m.authMore) {
                Toggle("Passphrase klíče uložit do Klíčenky macOS", isOn: $m.session.useKeychain)
                Button("Zkopírovat veřejný klíč (.pub)") {
                    SSHKeys.copyPublicKey(ofPrivateKey: m.session.identityFile)
                }
                .disabled(m.session.identityFile.isEmpty)
            }
        case .password:
            PasswordSourceFields(m: m)
        case .interactive:
            Text("Heslo nebo jednorázový kód zadáš v terminálu při každém připojení. Nic se neukládá.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Skupina (vyhledávání + nová skupina)

    private var groupButton: some View {
        Button { m.groupQuery = ""; m.showGroups = true } label: {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: groupColors[m.session.group] ?? m.session.colorHex) ?? .gray).frame(width: 8, height: 8)
                Text(m.session.group.isEmpty ? "Vybrat složku" : m.session.group)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $m.showGroups, arrowEdge: .bottom) {
            GroupPickerPopover(m: m, groups: groups, groupColors: groupColors)
        }
    }

    // MARK: Barva

    private var colorPalette: some View {
        HStack(spacing: 6) {
            let groupHex = groupColors[m.session.group] ?? GroupPalette.color(for: m.session.group)
            Button { m.session.colorHex = "" } label: {
                HStack(spacing: 4) {
                    Circle().fill(Color(hex: groupHex) ?? .gray).frame(width: 12, height: 12)
                    Text("Složka").font(.system(size: 11))
                }
                .padding(.horizontal, 7).frame(height: 22)
                .background(Capsule().stroke(m.session.colorHex.isEmpty ? UI.accent : UI.border, lineWidth: m.session.colorHex.isEmpty ? 2 : 1))
            }
            .buttonStyle(.plain).help("Automaticky podle složky (výchozí)")
            ForEach(Self.palette, id: \.self) { h in
                let sel = m.session.colorHex.uppercased() == h.uppercased()
                Circle().fill(Color(hex: h) ?? .gray).frame(width: 16, height: 16)
                    .overlay(Circle().stroke(sel ? UI.text : Color.clear, lineWidth: 2).padding(-3))
                    .contentShape(Circle())
                    .onTapGesture { m.session.colorHex = h }
            }
            Button { m.session.colorHex = "none" } label: {
                Image(systemName: "circle.slash").font(.system(size: 15))
                    .foregroundStyle(m.session.colorHex == "none" ? UI.accent : UI.textTertiary)
            }
            .buttonStyle(.plain).help("Bez barvy")
            ColorPicker("", selection: colorBinding, supportsOpacity: false).labelsHidden()
                .help("Vlastní barva")
        }
    }

    @ViewBuilder private func stepIcon(_ s: ConnectionTester.Status) -> some View {
        switch s {
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.mini)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(UI.ok)
        case .fail: Image(systemName: "xmark.octagon.fill").foregroundStyle(UI.error)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    private var envBinding: Binding<String> {
        Binding(get: { m.session.envTag },
                set: { m.session.environment = $0; m.session.production = ($0 == "prod") })
    }

    /// Picker agenta: "" / "bitwarden" / "custom" (vlastní cesta je přímo v agentSocket).
    private var agentMode: Binding<String> {
        Binding(
            get: {
                switch m.session.agentSocket {
                case "", "bitwarden": return m.session.agentSocket
                default: return "custom"
                }
            },
            set: { mode in
                switch mode {
                case "custom":
                    if m.session.agentSocket.isEmpty || m.session.agentSocket == "bitwarden" {
                        m.session.agentSocket = "~/.ssh/agent.sock"
                    }
                default: m.session.agentSocket = mode
                }
            })
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(hex: m.session.colorHex) ?? .gray },
                set: { [m] in m.session.colorHex = $0.hexString })
    }
}

/// Výběr skupiny s vyhledáváním a založením nové.
private struct GroupPickerPopover: View {
    @ObservedObject var m: SessionEditorModel
    let groups: [String]
    let groupColors: [String: String]

    private var filtered: [String] {
        let q = m.groupQuery.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? groups : groups.filter { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Hledat nebo nová (podsložka: A/B)…", text: $m.groupQuery).textFieldStyle(.plain)
                    .onSubmit { pick(m.groupQuery) }
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered, id: \.self) { g in
                        Button { pick(g) } label: {
                            HStack(spacing: 8) {
                                Circle().fill(Color(hex: groupColors[g] ?? "#8E8E93") ?? .gray).frame(width: 8, height: 8)
                                Text(g.replacingOccurrences(of: "/", with: " / "))
                                Spacer()
                                if g == m.session.group { Image(systemName: "checkmark").foregroundStyle(UI.accent) }
                            }
                            .padding(.horizontal, 8).frame(height: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 240)
            Divider()
            let q = m.groupQuery.trimmingCharacters(in: .whitespaces)
            if !q.isEmpty, !groups.contains(where: { $0.caseInsensitiveCompare(q) == .orderedSame }) {
                Button { pick(q) } label: { Label("Vytvořit složku „\(q)“", systemImage: "plus") }.buttonStyle(.plain)
            } else {
                Button {
                    if let n = askText("Nová složka", "Název složky (podsložka: A/B):") { pick(n) }
                } label: { Label("Nová složka…", systemImage: "plus") }.buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(width: 280)
    }

    private func pick(_ g: String) {
        let v = g.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        // existující skupinu použij v původním zápisu (bez duplicit HOME / home)
        let norm = AppStore.normPath(v)
        m.session.group = groups.first { $0.caseInsensitiveCompare(norm) == .orderedSame } ?? norm
        m.showGroups = false
    }
}

/// Heslo: Klíčenka macOS, nebo odkaz do správce hesel (1Password / Bitwarden / KeePassXC).
struct PasswordSourceFields: View {
    @ObservedObject var m: SessionEditorModel
    @StateObject private var test = PasswordTestState()

    private var source: Binding<String> {
        Binding(get: { ExternalSecrets.kind(of: m.session.passwordRef)?.rawValue ?? "" },
                set: { new in
                    if new.isEmpty { m.session.passwordRef = "" }
                    else if ExternalSecrets.kind(of: m.session.passwordRef)?.rawValue != new { m.session.passwordRef = new }
                    test.result = ""
                })
    }

    var body: some View {
        Picker("Zdroj hesla", selection: source) {
            Text("Klíčenka macOS").tag("")
            ForEach(ExternalSecrets.Kind.allCases) { Text($0.title).tag($0.rawValue) }
        }
        if let k = ExternalSecrets.kind(of: m.session.passwordRef) {
            TextField("Odkaz", text: $m.session.passwordRef, prompt: Text(k.example))
                .font(.system(.body, design: .monospaced))
            HStack {
                Button("Otestovat načtení") {
                    let ref = m.session.passwordRef
                    test.result = "Načítám…"
                    Task.detached {
                        let r = ExternalSecrets.fetch(ref)
                        await MainActor.run {
                            switch r {
                            case .success(let p): test.result = "✓ Heslo načteno (\(p.count) znaků)"
                            case .failure(let f): test.result = "✗ " + f.message
                            }
                        }
                    }
                }
                Text(test.result).font(.caption).foregroundStyle(test.result.hasPrefix("✓") ? UI.ok : .secondary)
                    .lineLimit(2)
            }
            Text(k.cli == nil ? "CLI nenalezeno – \(k.install)."
                              : "Heslo se načte z \(k.title) až při připojení a nikam se neukládá. \(k == .onepassword ? "Ověření řeší aplikace 1Password (Touch ID)." : "Při připojení se zeptá na heslo k trezoru / databázi.")")
                .font(.caption).foregroundStyle(k.cli == nil ? Color.orange : .secondary)
        } else {
            SecureField(m.session.hasStoredPassword ? "Heslo (uloženo, vyplň jen pro změnu)" : "Heslo", text: $m.password)
            Toggle("Před použitím hesla vyžadovat Touch ID / heslo Macu", isOn: $m.session.requireUserAuth)
            Text("Heslo je jen v Klíčence macOS, nikdy v souboru serverů ani v exportu.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class PasswordTestState: ObservableObject {
    @Published var result = ""
}
