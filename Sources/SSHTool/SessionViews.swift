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

    /// Přesun přetaženého serveru do skupiny.
    private func dropSession(_ items: [String], to group: String) -> Bool {
        guard let raw = items.first, raw.hasPrefix(Self.dragPrefix),
              let id = UUID(uuidString: String(raw.dropFirst(Self.dragPrefix.count))),
              let s = store.session(id), s.group != group else { return false }
        store.move(id, toGroup: group)
        if store.isGroupCollapsed(group) { store.toggleGroup(group) }   // ukázat, kam server přibyl
        return true
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
    private func row(_ s: SSHSession, inGroup: Bool = false) -> some View {
        let favVisible = store.settings.showFavorites && s.favorite && !collapsed(Self.favoritesKey)
        return SidebarSessionRow(session: s, state: tabs.state(for: s.id),
                          active: tabs.activeSessionID == s.id && !(inGroup && favVisible),
                          comfortable: store.settings.sidebarComfortable,
                          query: ui.search,
                          toggleFavorite: { store.toggleFavorite(s.id) })
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
            Button("Sbalit všechny skupiny") { store.collapseAll(true) }
            Button("Rozbalit všechny skupiny") { store.collapseAll(false) }
            if g == Self.favoritesKey {
                Divider()
                Button("Skrýt sekci Oblíbené") { store.settings.showFavorites = false }
            } else {
                Divider()
                Button("Přejmenovat skupinu…") {
                    if let n = askText("Přejmenovat skupinu", "Nový název skupiny „\(g)“:", initial: g) { store.renameGroup(g, to: n) }
                }
                Menu("Barva skupiny") {
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
                    Button("Rychlé připojení…  ⇧⌘K") { tabs.showQuickConnect = true }
                    Divider()
                    Button("Sbalit všechny skupiny") { store.collapseAll(true) }
                    Button("Rozbalit všechny skupiny") { store.collapseAll(false) }
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
                ForEach(grouped, id: \.group) { g in
                    GroupHeaderRow(title: g.group.uppercased(), count: g.items.count,
                                   collapsed: collapsed(g.group),
                                   color: UI.sessionColor(GroupPalette.color(for: g.group))) {
                        store.toggleGroup(g.group)
                    }
                    .onDrop(of: [.plainText, .utf8PlainText, .text],
                            isTargeted: Binding(get: { ui.dropTarget == g.group },
                                                set: { setTarget($0, g.group) })) { providers in
                        handleDrop(providers, to: g.group)
                    }
                    .background(RoundedRectangle(cornerRadius: 5)
                        .stroke(UI.accent, lineWidth: ui.dropTarget == g.group ? 1.5 : 0))
                    .contextMenu { groupMenu(g.group) }
                    if !collapsed(g.group) {
                        ForEach(g.items) { s in row(s, inGroup: true) }
                    }
                }
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
    private func newSession() -> SSHSession {
        var s = SSHSession(name: "", host: "")
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
        let live = tabs.liveTab(for: session.id)
        if let live {
            Button("Přejít na otevřenou relaci") { tabs.selectedID = live.id }
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
        Divider()
        Button(session.favorite ? "Odebrat z oblíbených" : "Přidat do oblíbených") { store.toggleFavorite(session.id) }
        Menu("Přesunout do skupiny") {
            ForEach(store.groupNames.filter { $0 != session.group }, id: \.self) { g in
                Button(g) { store.move(session.id, toGroup: g) }
            }
            Divider()
            Button("Nová skupina…") {
                if let g = askText("Nová skupina", "Název skupiny:") { store.move(session.id, toGroup: g) }
            }
        }
        Divider()
        Button("Smazat server…", role: .destructive) {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "Smazat server „\(session.name)“?"
            a.informativeText = "Smaže se i uložené heslo v Klíčence. Otevřené relace zůstanou do zavření."
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
        if s.user.contains(where: { $0 == " " || $0 == "@" }) { p.append("Uživatel nesmí obsahovat mezeru ani „@“.") }
        if s.jumpHost.contains(" ") { p.append("Jump host nesmí obsahovat mezeru (formát user@bastion:port).") }
        if s.group.trimmingCharacters(in: .whitespaces).isEmpty { p.append("Vyber nebo zadej skupinu.") }
        if !name.isEmpty, existing.contains(where: {
            $0.id != s.id && $0.group == s.group && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            p.append("Ve skupině „\(s.group)“ už server s tímto názvem existuje.")
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
        onSave(s, m.password.isEmpty ? nil : m.password)
        dismiss()
    }

    private var form: some View {
        Form {
            Section("Základní informace") {
                TextField("Název serveru", text: $m.session.name, prompt: Text("např. fw1-praha"))
                LabeledContent("Skupina") {
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
                TextField("Jump host", text: $m.session.jumpHost, prompt: Text("user@bastion (ProxyJump)"))
            }
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
                        TextField("Další argumenty", text: $m.session.extraArgs, prompt: Text("-o ServerAliveCountMax=3"))
                            .font(.system(.body, design: .monospaced))
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
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
            SecureField(m.session.hasStoredPassword ? "Heslo (uloženo, vyplň jen pro změnu)" : "Heslo",
                        text: $m.password)
            Toggle("Před použitím hesla vyžadovat Touch ID / heslo Macu", isOn: $m.session.requireUserAuth)
            Text("Heslo je jen v Klíčence macOS, nikdy v souboru serverů ani v exportu.")
                .font(.caption).foregroundStyle(.secondary)
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
                Text(m.session.group.isEmpty ? "Vybrat skupinu" : m.session.group)
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
                    Text("Skupina").font(.system(size: 11))
                }
                .padding(.horizontal, 7).frame(height: 22)
                .background(Capsule().stroke(m.session.colorHex.isEmpty ? UI.accent : UI.border, lineWidth: m.session.colorHex.isEmpty ? 2 : 1))
            }
            .buttonStyle(.plain).help("Automaticky podle skupiny (výchozí)")
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
                TextField("Hledat nebo nová skupina…", text: $m.groupQuery).textFieldStyle(.plain)
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
                                Text(g)
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
                Button { pick(q) } label: { Label("Vytvořit skupinu „\(q)“", systemImage: "plus") }.buttonStyle(.plain)
            } else {
                Button {
                    if let n = askText("Nová skupina", "Název skupiny:") { pick(n) }
                } label: { Label("Nová skupina…", systemImage: "plus") }.buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(width: 280)
    }

    private func pick(_ g: String) {
        let v = g.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        // existující skupinu použij v původním zápisu (bez duplicit HOME / home)
        m.session.group = groups.first { $0.caseInsensitiveCompare(v) == .orderedSame } ?? v
        m.showGroups = false
    }
}
