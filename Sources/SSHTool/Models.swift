import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum AuthMethod: String, Codable, CaseIterable {
    case agent      // ssh-agent / ~/.ssh/config
    case key        // konkrétní klíč (-i)
    case password   // heslo z Keychainu přes SSH_ASKPASS
    case interactive // heslo / OTP zadané ručně v terminálu (nic se neukládá)
}

struct SSHSession: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int = 22
    var user: String = ""
    var group: String = "Default"
    var colorHex: String = "#8E8E93"
    var auth: AuthMethod = .agent
    var identityFile: String = ""
    var jumpHost: String = ""
    var extraArgs: String = ""
    var hasStoredPassword = false
    /// Před použitím uloženého hesla vyžadovat Touch ID / heslo macOS (skutečný příznak je v Keychainu).
    var requireUserAuth = true
    /// SSH agent pro auth == .agent: "" = systémový (SSH_AUTH_SOCK / ~/.ssh/config), "bitwarden", jinak cesta k socketu.
    var agentSocket = ""
    /// auth == .key: passphrase klíče ukládat do Klíčenky macOS (UseKeychain + AddKeysToAgent).
    var useKeychain = true
    var favorite = false
    /// Produkční zařízení – nenápadný štítek PROD v seznamu, záložce a stavovém řádku.
    var production = false
    /// Prostředí: "" (žádné), "prod", "test", "dev" – štítek v seznamu, záložce a stavovém řádku.
    var environment = ""
    /// Pokročilé: ServerAliveInterval (s), ConnectTimeout (s), 0 = výchozí z ~/.ssh/config.
    var keepAlive = 0
    var connectTimeout = 0
    /// Politika ověření klíče serveru: "" = výchozí (ssh config), "ask", "yes" (striktní), "accept-new".
    /// Hodnota „no“ (ignorovat) se záměrně nenabízí.
    var hostKeyPolicy = ""
    /// Protokol: "ssh" (výchozí) nebo "rdp" (FreeRDP v samostatném okně).
    var proto = "ssh"
    var rdpDomain = ""
    var rdpGateway = ""                 // RD Gateway (user@gw nebo gw)
    var rdpSize = "dynamic"             // dynamic | fullscreen | 1920x1080 …
    var rdpMultiMon = false
    var rdpClipboard = true
    var rdpShareHome = false            // přesměrování domovské složky Macu do RDP relace
    var rdpCertPolicy = ""              // "" = zeptat se, "tofu" = důvěřovat při prvním připojení
    var rdpExtraArgs = ""

    var isRDP: Bool { proto == "rdp" }

    var envTag: String { environment.isEmpty && production ? "prod" : environment }

    /// Barva pro zobrazení: "" = podle skupiny, "none" = bez barvy, jinak #RRGGBB.
    var resolvedColorHex: String {
        switch colorHex {
        case "": return GroupPalette.color(for: group)
        case "none": return "none"
        default: return colorHex
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, user, group, colorHex, auth, identityFile, jumpHost, extraArgs, hasStoredPassword, requireUserAuth, agentSocket, useKeychain, favorite, production, environment, keepAlive, connectTimeout, hostKeyPolicy,
             proto, rdpDomain, rdpGateway, rdpSize, rdpMultiMon, rdpClipboard, rdpShareHome, rdpCertPolicy, rdpExtraArgs
    }

    var usesStoredPassword: Bool { auth == .password && hasStoredPassword }

    /// Volby společné pro ssh i sftp (klíč, jump host, heslo).
    private var commonOptions: [String] {
        var a: [String] = []
        if auth == .key, !identityFile.isEmpty {
            a += ["-i", (identityFile as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
            if useKeychain { a += ["-o", "UseKeychain=yes", "-o", "AddKeysToAgent=yes"] }
        }
        if auth == .agent, let sock = resolvedAgentSocket {
            a += ["-o", sock.contains(" ") ? "IdentityAgent=\"\(sock)\"" : "IdentityAgent=\(sock)"]
        }
        if !jumpHost.isEmpty { a += ["-J", jumpHost] }
        if auth == .password || auth == .interactive {
            a += ["-o", "PreferredAuthentications=password,keyboard-interactive",
                  "-o", "PubkeyAuthentication=no"]
        }
        if keepAlive > 0 { a += ["-o", "ServerAliveInterval=\(keepAlive)"] }
        if connectTimeout > 0 { a += ["-o", "ConnectTimeout=\(connectTimeout)"] }
        if ["ask", "yes", "accept-new"].contains(hostKeyPolicy) {
            a += ["-o", "StrictHostKeyChecking=\(hostKeyPolicy)"]
        } else if usesStoredPassword {
            // askpass neumí odpovědět yes/no na nový host key → nové klíče přijmout, změněné dál odmítat
            a += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        return a
    }

    /// Skutečná cesta socketu agenta, nil = systémový.
    var resolvedAgentSocket: String? {
        switch agentSocket {
        case "": return nil
        case "bitwarden": return SSHKeys.bitwardenSocket
        default: return SSHKeys.expand(agentSocket)
        }
    }

    private var destination: String { user.isEmpty ? host : "\(user)@\(host)" }
    var destinationString: String { destination }

    /// Varování k „Dalším argumentům“ (neblokuje uložení).
    var extraArgsWarnings: [String] {
        let t = extraArgs.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return [] }
        var w: [String] = []
        if let f = extraTokens.first, !f.hasPrefix("-") { w.append("Argumenty mají začínat přepínačem (např. -o, -A, -L).") }
        if t.contains(where: { ";|&`$<>\n".contains($0) }) {
            w.append("Argumenty se nepředávají přes shell – znaky ; | & $ ` < > nemají očekávaný efekt.")
        }
        let low = t.lowercased()
        if low.contains("stricthostkeychecking=no") || low.contains("userknownhostsfile=/dev/null") {
            w.append("Bezpečnost: vypnutá kontrola klíče serveru umožňuje MITM útok.")
        }
        if low.contains("proxycommand") || low.contains("localcommand") || low.contains("permitlocalcommand") {
            w.append("ProxyCommand / LocalCommand spouští lokální příkazy – používej jen důvěryhodné hodnoty.")
        }
        if t.filter({ $0 == "\"" || $0 == "'" }).count > 0 {
            w.append("Uvozovky se neinterpretují – hodnoty s mezerou nejsou podporované.")
        }
        return w
    }

    private var extraTokens: [String] { extraArgs.split(separator: " ").map(String.init) }

    /// ssh s vlastním ControlMaster socketem (jeden na záložku) – pro monitor ve stavovém řádku.
    /// Vlastní socket na záložku = zavření jedné záložky nikdy neshodí jinou.
    func sshArguments(controlPath: String) -> [String] {
        ["-o", "ControlMaster=auto", "-o", "ControlPath=\(controlPath)", "-o", "ControlPersist=no"] + sshArguments()
    }

    func sshArguments() -> [String] {
        ["-p", String(port)] + commonOptions + extraTokens + [destination]
    }

    /// sftp má port jako -P a nezná ssh-only přepínače (-t, -A, -L…) → z „Dalších argumentů“ bere jen -o volby.
    func sftpArguments() -> [String] {
        var extra: [String] = []
        var it = extraTokens.makeIterator()
        while let t = it.next() {
            if t == "-o", let v = it.next() { extra += ["-o", v] }
            else if t.hasPrefix("-o") { extra.append(t) }
        }
        return ["-P", String(port)] + commonOptions + extra + [destination]
    }

    /// https://<host> pro webové rozhraní zařízení (Gaia WebUI, Radware…); IPv6 v hranatých závorkách.
    var webURL: URL? {
        guard host != "localhost", !host.isEmpty else { return nil }
        let h = host.contains(":") ? "[\(host)]" : host
        return URL(string: "https://\(h)")
    }

    /// Název bez IP adresy (IP se zobrazuje zvlášť), např. „fw1 - 192.0.2.10“ → „fw1“.
    var displayName: String {
        guard !host.isEmpty, name.contains(host) else { return name }
        var n = name.replacingOccurrences(of: host, with: " ")
        n = n.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        n = n.trimmingCharacters(in: CharacterSet(charactersIn: " -–:|/,"))
        n = n.replacingOccurrences(of: " - - ", with: " - ")
        return n.isEmpty ? name : n
    }

    /// Ekvivalentní příkaz pro Terminál (pro „Kopírovat SSH příkaz“).
    var sshCommand: String {
        let quoted = sshArguments().map { a -> String in
            a.contains(where: { " \"'$`\\".contains($0) }) ? "'" + a.replacingOccurrences(of: "'", with: "'\\''") + "'" : a
        }
        return "ssh " + quoted.joined(separator: " ")
    }

    /// Pseudo-session pro lokální terminál (bez přihlášení).
    static let local = SSHSession(name: "Lokální terminál", host: "localhost", group: "Lokální", colorHex: "#8E8E93")
}

@MainActor
final class AppStore: ObservableObject {
    /// Pro místa mimo SwiftUI (monitor gest). Nastaví se v init.
    static weak var shared: AppStore?
    @Published var sessions: [SSHSession] = [] { didSet { save(sessions, to: "sessions.json") } }
    @Published var rules: [HighlightRule] = [] {
        didSet {
            save(rules, to: "rules.json")
            applyHighlight()
        }
    }

    @Published var snippets: [Snippet] = [] {
        didSet { save(snippets, to: "snippets.json") }
    }

    @Published var settings = AppSettings() {
        didSet {
            save(settings, to: "settings.json")
            Prefs.current = settings
            GroupPalette.overrides = settings.groupColors
            if settings.scrollback != oldValue.scrollback {
                NotificationCenter.default.post(name: AppSettings.scrollbackChanged, object: nil)
            }
            if settings.fontSize != oldValue.fontSize || settings.fontName != oldValue.fontName
                || settings.lineSpacing != oldValue.lineSpacing || settings.optionAsMeta != oldValue.optionAsMeta {
                NotificationCenter.default.post(name: AppSettings.fontSizeChanged, object: nil)
            }
            if settings.highlightEnabled != oldValue.highlightEnabled
                || settings.disabledRuleGroups != oldValue.disabledRuleGroups { applyHighlight() }
            applyTheme()
        }
    }

    /// ~/Library/Application Support/SSHTool/
    let directory: URL

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SSHTool", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sessions = load("sessions.json") ?? []
        if let r: [HighlightRule] = load("rules.json") {
            rules = r
        } else {
            rules = HighlightRule.defaults
            save(rules, to: "rules.json")
        }
        settings = load("settings.json") ?? AppSettings()
        Prefs.current = settings
        GroupPalette.overrides = settings.groupColors
        snippets = load("snippets.json") ?? Snippet.defaults
        AppStore.shared = self
        applyHighlight()                         // didSet se v init nevolá
        applyTheme()
        // „Podle macOS“: reagovat na přepnutí tmavého/světlého režimu systému
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { _ in
            Task { @MainActor in AppStore.shared?.applyTheme() }
        }
    }

    func session(_ id: UUID) -> SSHSession? { sessions.first { $0.id == id } }

    func upsert(_ s: SSHSession, password: String?) {
        var s = s
        let old = session(s.id)
        // Vypnutí ochrany smí jen vlastník Macu.
        if let old, old.hasStoredPassword, old.requireUserAuth, !s.requireUserAuth,
           !UserAuth.authenticate(reason: "vypnout ochranu uloženého hesla pro „\(s.name)“") {
            s.requireUserAuth = true
        }
        if let password {
            do {
                try KeychainStore.setPassword(password, for: s.id.uuidString, requireAuth: s.requireUserAuth)
                s.hasStoredPassword = true
            } catch {
                NSLog("Keychain error: \(error)")
            }
        } else if s.hasStoredPassword, old?.requireUserAuth != s.requireUserAuth {
            do { try KeychainStore.setRequireAuth(s.requireUserAuth, for: s.id.uuidString) }
            catch {
                NSLog("Keychain error: \(error)")
                s.requireUserAuth = old?.requireUserAuth ?? s.requireUserAuth
            }
        }
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.append(s) }
    }

    func duplicate(_ s: SSHSession) {
        var c = s
        c.id = UUID()
        c.name += " (kopie)"
        c.hasStoredPassword = false
        sessions.append(c)
    }

    func delete(_ id: UUID) {
        KeychainStore.delete(id.uuidString)
        sessions.removeAll { $0.id == id }
    }

    /// Session seskupené podle skupiny (abecedně), uvnitř podle názvu.
    var groupedSessions: [(group: String, items: [SSHSession])] {
        Dictionary(grouping: sessions, by: \.group)
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { ($0.key, $0.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
    }

    // MARK: Import / export

    /// Import session z JSON (formát sessions.json). Session se stejným id se přeskočí – existující úpravy se nepřepíšou.
    func importSessionsPanel() {
        guard let url = Self.openJSON(title: "Importovat session") else { return }
        do {
            let incoming = try JSONDecoder().decode([SSHSession].self, from: Data(contentsOf: url))
            let known = Set(sessions.map(\.id))
            // duplicita = stejné id, nebo stejný název + skupina + host + port (vzor bez id lze nahrát opakovaně)
            func key(_ s: SSHSession) -> String { "\(s.name.lowercased())|\(s.group.lowercased())|\(s.host.lowercased())|\(s.port)" }
            var seen = Set(sessions.map(key))
            var added: [SSHSession] = []
            var invalid = 0
            for var s in incoming {
                guard !known.contains(s.id), !seen.contains(key(s)) else { continue }
                s.name = s.name.trimmingCharacters(in: .whitespaces)
                s.host = s.host.trimmingCharacters(in: .whitespaces)
                guard !s.name.isEmpty, !s.host.isEmpty, (1...65535).contains(s.port) else { invalid += 1; continue }
                s.hasStoredPassword = false                       // hesla se neimportují
                if !["", "prod", "stage", "test", "dev"].contains(s.environment) { s.environment = "" }
                if s.environment == "prod" { s.production = true }
                if !["", "ask", "yes", "accept-new"].contains(s.hostKeyPolicy) { s.hostKeyPolicy = "" }   // „no“ se nepřijme
                seen.insert(key(s))
                added.append(s)
            }
            sessions.append(contentsOf: added)
            let skipped = incoming.count - added.count - invalid
            Self.info("Import session", "Přidáno: \(added.count), přeskočeno (už existují): \(skipped)"
                      + (invalid > 0 ? ", neplatné (chybí název/host nebo špatný port): \(invalid)" : "") + "."
                      + (added.contains { $0.auth == .password } ? "\nU serverů s heslem zadej heslo v editoru (Upravit)." : ""))
        } catch {
            Self.info("Import session selhal", Self.describeImportError(error))
        }
    }

    func importRulesPanel() {
        guard let url = Self.openJSON(title: "Importovat pravidla") else { return }
        do {
            rules = try JSONDecoder().decode([HighlightRule].self, from: Data(contentsOf: url))
        } catch {
            Self.info("Import pravidel selhal", "\(error.localizedDescription)")
        }
    }

    func exportRulesPanel() {
        let panel = NSSavePanel()
        panel.title = "Exportovat pravidla"
        panel.nameFieldStringValue = "sshtool-rules.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try enc.encode(rules).write(to: url, options: .atomic) }
        catch { Self.info("Export selhal", "\(error.localizedDescription)") }
    }

    func resetRules() { rules = HighlightRule.defaults }

    func changeFontSize(by delta: Double) {
        let r = AppSettings.fontSizeRange
        settings.fontSize = min(max(settings.fontSize + delta, r.lowerBound), r.upperBound)
    }

    func resetFontSize() { settings.fontSize = AppSettings().fontSize }

    /// Klíč aktuálního motivu – při změně se okno přebuduje (relace v TabManageru zůstávají).
    @Published private(set) var themeKey = ""

    func applyTheme() {
        let r = ThemeStore.resolve(settings)
        let key = r.ui.id + "/" + r.terminal.id
        guard key != themeKey else { return }
        ThemeStore.ui = r.ui
        ThemeStore.terminal = r.terminal
        themeKey = key
        NotificationCenter.default.post(name: ThemeStore.changed, object: nil)
    }

    var isDarkUI: Bool { ThemeStore.ui.isDark }

    /// Výběr profilu z menu / palety (světlý profil přepne režim na světlý a naopak).
    func selectTheme(_ id: String) {
        let t = Theme.byID(id)
        settings.themeID = id
        if !t.isDark { settings.appearance = "light" }
        else if settings.appearance == "light" { settings.appearance = "dark" }
    }

    /// Zvýrazňování lze vypnout – výstup se pak vykresluje přesně, jak ho poslal server.
    func applyHighlight() {
        let off = Set(settings.disabledRuleGroups)
        HighlightCenter.shared.setRules(settings.highlightEnabled ? rules.filter { !off.contains($0.group) } : [])
    }

    /// Názvy existujících skupin (pro výběr v editoru a „Přesunout do skupiny“).
    // MARK: Složky (stromová struktura: skupina = cesta „A/B/C“)

    /// Normalizovaná cesta složky: bez prázdných částí a mezer kolem „/“.
    static func normPath(_ p: String) -> String {
        p.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "/")
    }

    /// Všechny složky včetně nadřazených a prázdných, seřazené.
    var groupNames: [String] {
        var set = Set<String>()
        for g in sessions.map(\.group) + settings.folders {
            let parts = g.split(separator: "/").map(String.init)
            for i in parts.indices { set.insert(parts[...i].joined(separator: "/")) }
        }
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Je cesta `p` v podstromu složky `root` (včetně jí samotné)?
    static func inSubtree(_ p: String, _ root: String) -> Bool { p == root || p.hasPrefix(root + "/") }

    func createFolder(_ path: String) {
        let p = Self.normPath(path)
        guard !p.isEmpty, !groupNames.contains(p) else { return }
        settings.folders.append(p)
        let parts = p.split(separator: "/").map(String.init)      // rozbalit cestu k nové složce
        for i in parts.indices.dropLast() {
            let a = parts[...i].joined(separator: "/")
            if isGroupCollapsed(a) { toggleGroup(a) }
        }
    }

    /// Přesune složku (s celým obsahem) do jiné složky; nil = do kořene.
    func moveFolder(_ path: String, into parent: String?) {
        if let parent, Self.inSubtree(parent, path) { NSSound.beep(); return }   // ne do sebe / svého potomka
        let leaf = path.split(separator: "/").last.map(String.init) ?? path
        renameGroup(path, to: parent.map { $0 + "/" + leaf } ?? leaf)
        if let parent, isGroupCollapsed(parent) { toggleGroup(parent) }
    }

    /// Smaže složku – jen když v ní (ani v podsložkách) nejsou servery.
    @discardableResult
    func deleteFolder(_ path: String) -> Bool {
        guard !sessions.contains(where: { Self.inSubtree($0.group, path) }) else { return false }
        settings.folders.removeAll { Self.inSubtree($0, path) }
        return true
    }

    /// Barvy skupin (ruční nebo automatické) – pro výběr skupiny v editoru.
    var groupColors: [String: String] {
        var d: [String: String] = [:]
        for g in groupNames { d[g] = GroupPalette.color(for: g) }
        return d
    }

    func setGroupColor(_ g: String, _ hex: String?) {
        if let hex { settings.groupColors[g] = hex } else { settings.groupColors.removeValue(forKey: g) }
    }

    /// Přejmenuje skupinu u všech serverů (včetně barvy a sbalení).
    func renameGroup(_ old: String, to new: String) {
        let n = Self.normPath(new)
        guard !n.isEmpty, n != old else { return }
        // přejmenuje složku i celý její podstrom (A/B → X/B)
        func remap(_ g: String) -> String { Self.inSubtree(g, old) ? n + g.dropFirst(old.count) : g }
        for i in sessions.indices where Self.inSubtree(sessions[i].group, old) { sessions[i].group = remap(sessions[i].group) }
        var s = settings
        s.folders = Array(Set(s.folders.map(remap)))
        var colors: [String: String] = [:]
        for (k, v) in s.groupColors { colors[remap(k)] = v }
        s.groupColors = colors
        s.collapsedGroups = s.collapsedGroups.map(remap)
        settings = s
    }

    /// Skupiny pravidel zvýraznění v pořadí prvního výskytu.
    var ruleGroups: [String] {
        var seen: [String] = []
        for r in rules where !seen.contains(r.group) { seen.append(r.group) }
        return seen
    }

    func move(_ id: UUID, toGroup g: String) {
        if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].group = g }
    }

    func collapseAll(_ collapse: Bool) {
        settings.collapsedGroups = collapse ? groupNames + ["★"] : []
    }

    /// Export serverů bez hesel a bez cest ke klíčům (bezpečné ke sdílení).
    func exportSessionsPanel() {
        let panel = NSSavePanel()
        panel.title = "Exportovat servery"
        panel.nameFieldStringValue = "sshtool-servers.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let clean = sessions.map { s -> SSHSession in
            var c = s
            c.hasStoredPassword = false
            c.requireUserAuth = false
            c.identityFile = ""
            return c
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try enc.encode(clean).write(to: url, options: .atomic) }
        catch { Self.info("Export selhal", "\(error.localizedDescription)") }
    }

    func toggleFavorite(_ id: UUID) {
        if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].favorite.toggle() }
    }

    func isGroupCollapsed(_ g: String) -> Bool { settings.collapsedGroups.contains(g) }

    func toggleGroup(_ g: String) {
        if let i = settings.collapsedGroups.firstIndex(of: g) { settings.collapsedGroups.remove(at: i) }
        else { settings.collapsedGroups.append(g) }
    }

    func serialBaud(for port: SerialPort) -> Int { settings.serialBaud[port.path] ?? SerialConfig.defaultBaud }
    func setSerialBaud(_ baud: Int, for port: SerialPort) { settings.serialBaud[port.path] = baud }

    func chooseLogDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Složka pro logy session"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.logDirectoryURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.logDirectory = (url.path as NSString).abbreviatingWithTildeInPath
    }

    private static func openJSON(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func info(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    private func load<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, to name: String) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}

/// Tolerantní dekódování – chybějící klíče dostanou výchozí hodnotu (import z jiných zdrojů).
extension SSHSession {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? "Default"
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#8E8E93"
        auth = try c.decodeIfPresent(AuthMethod.self, forKey: .auth) ?? .agent
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile) ?? ""
        jumpHost = try c.decodeIfPresent(String.self, forKey: .jumpHost) ?? ""
        extraArgs = try c.decodeIfPresent(String.self, forKey: .extraArgs) ?? ""
        hasStoredPassword = try c.decodeIfPresent(Bool.self, forKey: .hasStoredPassword) ?? false
        // starší záznamy: položky Keychainu příznak nemají → false (odpovídá skutečnosti)
        requireUserAuth = try c.decodeIfPresent(Bool.self, forKey: .requireUserAuth) ?? false
        agentSocket = try c.decodeIfPresent(String.self, forKey: .agentSocket) ?? ""
        useKeychain = try c.decodeIfPresent(Bool.self, forKey: .useKeychain) ?? true
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        production = try c.decodeIfPresent(Bool.self, forKey: .production) ?? false
        environment = try c.decodeIfPresent(String.self, forKey: .environment) ?? (production ? "prod" : "")
        keepAlive = try c.decodeIfPresent(Int.self, forKey: .keepAlive) ?? 0
        connectTimeout = try c.decodeIfPresent(Int.self, forKey: .connectTimeout) ?? 0
        hostKeyPolicy = try c.decodeIfPresent(String.self, forKey: .hostKeyPolicy) ?? ""
        proto = (try c.decodeIfPresent(String.self, forKey: .proto)) == "rdp" ? "rdp" : "ssh"
        rdpDomain = try c.decodeIfPresent(String.self, forKey: .rdpDomain) ?? ""
        rdpGateway = try c.decodeIfPresent(String.self, forKey: .rdpGateway) ?? ""
        rdpSize = try c.decodeIfPresent(String.self, forKey: .rdpSize) ?? "dynamic"
        rdpMultiMon = try c.decodeIfPresent(Bool.self, forKey: .rdpMultiMon) ?? false
        rdpClipboard = try c.decodeIfPresent(Bool.self, forKey: .rdpClipboard) ?? true
        rdpShareHome = try c.decodeIfPresent(Bool.self, forKey: .rdpShareHome) ?? false
        rdpCertPolicy = (try c.decodeIfPresent(String.self, forKey: .rdpCertPolicy)) == "tofu" ? "tofu" : ""
        rdpExtraArgs = try c.decodeIfPresent(String.self, forKey: .rdpExtraArgs) ?? ""
    }
}

// MARK: - Web

/// Otevře webové rozhraní session v Safari (nová záložka); bez Safari ve výchozím prohlížeči.
@MainActor
enum WebOpener {
    static func open(_ session: SSHSession) {
        guard let url = session.webURL else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
            NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: cfg)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Barvy

struct RGBColor {
    let r, g, b: UInt8
    init?(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        r = UInt8(v >> 16 & 0xFF); g = UInt8(v >> 8 & 0xFF); b = UInt8(v & 0xFF)
    }

    /// Světlá barva → na ní tmavé písmo (vnímaný jas, ITU-R BT.601).
    var isLight: Bool { (0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)) / 255 > 0.6 }
}

extension Color {
    init?(hex: String) {
        guard let c = RGBColor(hex: hex) else { return nil }
        self.init(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }

    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}
