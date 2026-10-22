import SwiftUI
import AppKit
import Combine

// Pozn.: žádné @State / @Binding – v SDK z Command Line Tools jsou to makra bez pluginu.
// Stav drží ObservableObject třídy (@StateObject / @EnvironmentObject / @ObservedObject).

/// Jedna záložka = jedno SSH spojení se svým terminálem.
@MainActor
final class TerminalTab: ObservableObject, Identifiable {
    let id = UUID()
    let session: SSHSession
    let kind: TabKind
    let view: SSHTerminalView
    @Published var running = true
    @Published var logging = false
    @Published var hasOutput = false          // první data ze serveru → „Připojeno“
    @Published var exitCode: Int32?
    @Published var endedAt: Date?
    @Published var overlayDismissed = false
    /// Vlastní název záložky (platí jen pro tuto relaci, uložený server se nemění).
    @Published var customTitle: String?
    let startedAt = Date()

    /// Skutečný stav relace: běží → připojuje se / připojeno; skončila → odpojeno (kód 0) nebo chyba.
    var state: ConnState {
        if running { return hasOutput ? .connected : .connecting }
        return exitCode == 0 ? .disconnected : .error
    }

    /// Měření latence (ICMP) – jen SSH/SFTP bez jump hostu; samostatný objekt, aby nepřekresloval celé okno.
    private(set) var latency: LatencyProbe?
    /// Monitor CPU / RAM / disk serveru (jen SSH) – samostatný objekt, překresluje jen stavový řádek.
    private(set) var monitor: RemoteMonitor?

    var canMonitor: Bool { kind == .ssh && running && view.controlPath != nil }

    /// SSH i SFTP záložka mají ControlMaster → lze procházet soubory serveru.
    var canBrowse: Bool { (kind == .ssh || kind == .sftp) && running && view.controlPath != nil }

    /// Prohlížeč souborů (SFTP) přes spojení této záložky – vytváří se při prvním otevření panelu.
    private(set) var filesBrowser: SFTPBrowser?
    func browser() -> SFTPBrowser? {
        if filesBrowser == nil, canBrowse, let cp = view.controlPath {
            filesBrowser = SFTPBrowser(controlPath: cp, destination: session.destinationString,
                                       sessionName: session.name, production: session.envTag == "prod")
        }
        return filesBrowser
    }

    func startMonitor() {
        guard canMonitor, monitor == nil, let cp = view.controlPath else { return }
        monitor = RemoteMonitor(controlPath: cp, destination: session.destinationString)
        objectWillChange.send()
    }

    func stopMonitor() {
        monitor?.stop()
        monitor = nil
        objectWillChange.send()
    }

    /// Druhý řádek karty: host, shell nebo port.
    var subtitle: String {
        switch kind {
        case .ssh: return session.host
        case .sftp: return "sftp · " + session.host
        case .local:
            let sh = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return (sh as NSString).lastPathComponent
        case .serial: return "\(session.host) · \(serial?.baud ?? 0) baud"
        }
    }

    var title: String {
        switch kind {
        case .ssh: return session.name
        case .sftp: return "SFTP · " + session.name
        case .local, .serial: return session.name
        }
    }

    var icon: String {
        switch kind {
        case .ssh: return "desktopcomputer"
        case .sftp: return "folder"
        case .local: return "terminal"
        case .serial: return "cable.connector"
        }
    }

    let serial: SerialConfig?

    init(session: SSHSession, kind: TabKind = .ssh, serial: SerialConfig? = nil) {
        self.session = session
        self.kind = kind
        self.serial = serial
        view = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        view.onTerminated = { [weak self] code in
            self?.running = false
            self?.logging = false
            self?.exitCode = code
            self?.endedAt = Date()
            self?.latency?.stop()
            self?.monitor?.stop()
            // oznámení vpravo nahoře samo zmizí, stav zůstává ve stavovém řádku
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self?.overlayDismissed = true }
        }
        view.onFirstOutput = { [weak self] in
            self?.hasOutput = true
            if Prefs.current.monitorAuto { self?.startMonitor() }   // čeká, až bude relace přihlášená
        }
        view.start(kind: kind, session: session, serial: serial)
        if Prefs.current.logEnabled { logging = view.startLogging() }
        if (kind == .ssh || kind == .sftp), session.jumpHost.isEmpty, Prefs.current.latencyEnabled {
            latency = LatencyProbe(host: session.host)
        }
    }

    func toggleLogging() {
        if view.isLogging { view.stopLogging() } else if running { view.startLogging() }
        logging = view.isLogging
    }
}

/// Rozdělení okna: .vertical = panely vedle sebe (svislá dělicí čára), .horizontal = pod sebou.
enum SplitAxis { case vertical, horizontal }

@MainActor
final class TabManager: ObservableObject {
    @Published var tabs: [TerminalTab] = []
    /// Aktivní záložka = panel s fokusem (na ni míří všechny příkazy ⌘L, ⇧⌘L, ⌘W…).
    @Published var selectedID: UUID? {
        didSet {
            // Při rozdělení: výběr jiné (neviditelné) záložky ji zobrazí místo aktivního panelu.
            guard var p = panes, let new = selectedID, new != oldValue, !p.contains(new) else { return }
            if let old = oldValue, let i = p.firstIndex(of: old) { p[i] = new } else { p[0] = new }
            panes = p
        }
    }
    /// Rozdělené zobrazení: 2 viditelné záložky (pořadí = vlevo/nahoře, vpravo/dole), nil = jedna.
    @Published var panes: [UUID]?
    @Published var splitAxis: SplitAxis = .vertical
    @Published var showPicker = false
    @Published var showQuickConnect = false     // ⇧⌘K – připojení zadáním user@host:port
    @Published var showCapture = false          // ⌥⌘P – průvodce tcpdump / fw monitor
    let capture = CaptureModel()                // parametry zůstávají mezi otevřeními
    @Published var showMultiSend = false        // ⌥⌘I – odeslat příkazy do vybraných relací
    let multiSend = MultiSendModel()            // text a výběr zůstávají mezi otevřeními
    @Published var liveCapture: LiveCapture?    // živý odchyt do Wiresharku (jeden současně)
    @Published var showFiles = false            // ⇧⌘E – panel souborů serveru (SFTP)

    func toggleFiles() {
        if showFiles { showFiles = false; return }
        guard let t = selected, t.canBrowse else {
            let a = NSAlert()
            a.messageText = "Soubory serveru jsou dostupné pro připojenou SSH záložku"
            a.informativeText = "Připoj se k serveru přes SSH (ne SFTP záložku) a panel otevři znovu – použije stejné přihlášení."
            a.runModal()
            return
        }
        _ = t.browser()
        showFiles = true
    }
    @Published var quickTarget = ""
    /// Broadcast: vstup z aktivní relace se posílá i do ostatních (viz broadcastTargets).
    @Published var broadcast = false
    static let maxPanes = 4
    @Published var pickerQuery = ""
    /// Viditelnost levého panelu se session (⌃⌘S / tlačítko v liště záložek).
    @Published var sidebar: NavigationSplitViewVisibility = .all

    func toggleSidebar() {
        sidebar = (sidebar == .detailOnly) ? .all : .detailOnly
    }

    // MARK: Režim soustředění (jen terminál, volitelně stavový řádek)

    @Published var focusMode = false
    private var sidebarBeforeFocus: NavigationSplitViewVisibility = .all

    func toggleFocus() {
        if focusMode {
            focusMode = false
            sidebar = sidebarBeforeFocus
        } else {
            sidebarBeforeFocus = sidebar
            sidebar = .detailOnly
            focusMode = true
        }
    }

    // MARK: Názvy záložek

    /// Název na kartě: vlastní název, jinak název serveru; více relací stejného serveru se čísluje (· 1, · 2).
    func displayTitle(_ t: TerminalTab) -> String {
        if let c = t.customTitle, !c.isEmpty { return c }
        let base = t.kind == .ssh ? t.session.displayName : t.title
        let same = tabs.filter { $0.session.id == t.session.id && $0.kind == t.kind && ($0.customTitle ?? "").isEmpty }
        guard same.count > 1, let n = same.firstIndex(where: { $0.id == t.id }) else { return base }
        return "\(base) · \(n + 1)"
    }

    func rename(_ id: UUID) {
        guard let t = tab(id) else { return }
        if let v = askText("Přejmenovat záložku", "Název platí jen pro tuto relaci (uložený server se nemění).",
                           initial: t.customTitle ?? displayTitle(t)) {
            t.customTitle = v
            objectWillChange.send()
        }
    }

    func resetTitle(_ id: UUID) { tab(id)?.customTitle = nil; objectWillChange.send() }

    // MARK: Akce panelu

    /// Vyjme panel z rozdělení – relace zůstává jako samostatná záložka.
    func detachPane(_ id: UUID) {
        guard var p = panes else { return }
        p.removeAll { $0 == id }
        if selectedID == id { selectedID = p.first }
        panes = p.count >= 2 ? p : nil
        if panes == nil, broadcast { broadcast = false }
    }

    func splitFrom(_ id: UUID, _ axis: SplitAxis) {
        if selectedID != id { selectedID = id }
        split(axis)
    }

    var selected: TerminalTab? { tabs.first { $0.id == selectedID } }
    func tab(_ id: UUID) -> TerminalTab? { tabs.first { $0.id == id } }
    private func index(_ id: UUID?) -> Int? { tabs.firstIndex { $0.id == id } }

    func isVisible(_ id: UUID) -> Bool { panes?.contains(id) ?? (id == selectedID) }

    private var tabObservers: [UUID: AnyCancellable] = [:]

    /// Stav session pro levý panel (bere nejlepší stav ze záložek SSH/SFTP této session).
    func state(for sessionID: UUID) -> ConnState? {
        if RDPLauncher.shared.isRunning(sessionID) { return .connected }
        let ts = tabs.filter { $0.session.id == sessionID && ($0.kind == .ssh || $0.kind == .sftp) }
        if ts.contains(where: { $0.state == .connected }) { return .connected }
        if ts.contains(where: { $0.state == .connecting }) { return .connecting }
        if ts.contains(where: { $0.state == .error }) { return .error }
        return nil                                      // bez živé relace = šedá
    }

    /// ⌘R: odpojená záložka → znovu připojit, jinak Ctrl+R (hledání v historii příkazů).
    func smartR() {
        guard let t = selected else { return }
        if t.running { t.view.sendControl(0x12) } else { reconnect(t.id) }
    }

    /// Tlačítka v liště: stejné rozdělení podruhé = zrušit.
    func toggleSplit(_ axis: SplitAxis) {
        guard let p = panes else { split(axis); return }
        if p.count == 2 && splitAxis == axis { unsplit() } else { splitAxis = axis }
    }

    /// Klik do terminálu přesune fokus na jeho panel; změny stavu záložky překreslí lištu i levý panel.
    private func register(_ t: TerminalTab) {
        tabObservers[t.id] = t.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        t.view.onUserInput = { [weak self, weak t] data in
            guard let self, let t, self.broadcast, t.id == self.selectedID else { return }
            for other in self.broadcastTargets where other.id != t.id { other.view.sendRaw(data) }
        }
        t.view.onFocus = { [weak self, weak t] in
            guard let self, let t, self.selectedID != t.id else { return }
            self.selectedID = t.id
        }
    }

    // MARK: Rozdělené zobrazení

    /// Přidá panel (max. 4): další záložku, která ještě není vidět; když žádná není, novou kopii aktivní session.
    /// Rozložení: 2 = vedle sebe / pod sebou, 3 = jeden velký + dva, 4 = mřížka 2×2.
    func split(_ axis: SplitAxis) {
        guard let cur = selected, let i = index(cur.id) else { return }
        var p = panes ?? [cur.id]
        guard p.count < Self.maxPanes else { NSSound.beep(); return }
        splitAxis = axis
        let partner: UUID
        let candidates = Array(tabs[(i + 1)...]) + Array(tabs[..<i])
        if let t = candidates.first(where: { !p.contains($0.id) }) {
            partner = t.id
        } else if cur.kind != .serial {
            let t = TerminalTab(session: cur.session, kind: cur.kind, serial: nil)
            register(t)
            tabs.insert(t, at: i + 1)
            partner = t.id
        } else { return }
        p.append(partner)
        panes = p
        selectedID = partner
    }

    /// Zobrazí konkrétní záložku jako další panel.
    func split(with id: UUID, _ axis: SplitAxis) {
        guard let cur = selectedID, cur != id, index(id) != nil else { return }
        var p = panes ?? [cur]
        guard !p.contains(id), p.count < Self.maxPanes else { NSSound.beep(); return }
        splitAxis = axis
        p.append(id)
        panes = p
        selectedID = id
    }

    func unsplit() {
        panes = nil
        if broadcast { broadcast = false }
    }

    /// Otočí pořadí panelů.
    func swapPanes() {
        guard var p = panes, p.count > 1 else { return }
        p.append(p.removeFirst())
        panes = p
    }

    /// Fokus na další panel (⌥⌘→) / předchozí (⌥⌘←).
    func focusPane(_ d: Int) {
        guard let p = panes, let cur = selectedID, let i = p.firstIndex(of: cur) else { return }
        selectedID = p[(i + d + p.count) % p.count]
    }

    func focusOtherPane() { focusPane(1) }

    // MARK: Broadcast vstupu

    /// Cíle: při rozdělení viditelné panely, jinak všechny běžící záložky (bez lokálních terminálů).
    var broadcastTargets: [TerminalTab] {
        if let p = panes { return p.compactMap { tab($0) }.filter { $0.running } }
        return tabs.filter { $0.running && $0.kind != .local }
    }

    /// Zapnutí vyžaduje potvrzení se seznamem relací.
    func toggleBroadcast() {
        if broadcast { broadcast = false; return }
        let targets = broadcastTargets
        guard targets.count >= 2 else {
            let a = NSAlert()
            a.messageText = "Broadcast potřebuje alespoň dvě aktivní relace"
            a.informativeText = "Rozděl okno (⇧⌘D / ⌘D) nebo otevři více SSH záložek."
            a.runModal()
            return
        }
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = "Zapnout broadcast vstupu?"
        a.informativeText = "Vše, co napíšeš nebo vložíš do aktivní relace, se současně odešle do \(targets.count) relací:\n\n"
            + targets.map { "• \($0.title) (\($0.subtitle))" }.joined(separator: "\n")
            + "\n\nPozor: příkazy měnící konfiguraci se provedou na všech zařízeních."
            + { let n = targets.filter { $0.session.envTag == "prod" }.count
                return n > 0 ? "\n\n⚠️ \(n) z cílů je PRODUKČNÍ zařízení." : "" }()
        a.addButton(withTitle: "Zapnout broadcast")
        a.addButton(withTitle: "Zrušit")
        if a.runModal() == .alertFirstButtonReturn { broadcast = true }
    }

    // MARK: Rychlé připojení (⇧⌘K)

    /// „user@host:port“, „host“, „user@[IPv6]:port“ → dočasná session (neukládá se, pokud save == false).
    func quickConnect(_ text: String, save store: AppStore?) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var user = "", rest = t
        if let at = t.lastIndex(of: "@") { user = String(t[..<at]); rest = String(t[t.index(after: at)...]) }
        var host = rest, port = 22
        if rest.hasPrefix("["), let end = rest.firstIndex(of: "]") {
            host = String(rest[rest.index(after: rest.startIndex)..<end])
            let after = rest[rest.index(after: end)...]
            if after.hasPrefix(":"), let p = Int(after.dropFirst()) { port = p }
        } else if rest.filter({ $0 == ":" }).count == 1, let c = rest.firstIndex(of: ":"),
                  let p = Int(rest[rest.index(after: c)...]) {
            host = String(rest[..<c]); port = p
        }
        var s = SSHSession(name: user.isEmpty ? host : "\(user)@\(host)", host: host, port: port, user: user,
                           group: "Rychlé připojení", colorHex: "#7799E8")
        s.requireUserAuth = false
        if let store { store.upsert(s, password: nil) }
        open(s)
    }

    func open(_ s: SSHSession, kind: TabKind = .ssh) {
        if s.isRDP { RDPLauncher.shared.launch(s); return }      // RDP = samostatné okno FreeRDP
        insert(TerminalTab(session: s, kind: kind))
    }

    private func insert(_ t: TerminalTab) {
        register(t)
        if let i = index(selectedID) { tabs.insert(t, at: i + 1) } else { tabs.append(t) }
        selectedID = t.id
    }

    /// Sériová konzole; běžící záložka pro stejný port se jen vybere (port je výhradní).
    func openSerial(_ port: SerialPort, baud: Int) {
        if let t = tabs.first(where: { $0.kind == .serial && $0.serial?.path == port.path && $0.running }),
           t.serial?.baud == baud {
            selectedID = t.id
            return
        }
        if let old = tabs.first(where: { $0.kind == .serial && $0.serial?.path == port.path && $0.running }) {
            close(old.id)                                  // jiná rychlost → starou záložku zavřít
        }
        let s = SSHSession(name: "Konzole · \(port.title)", host: port.device, group: "Sériové",
                           colorHex: SerialPort.color)
        insert(TerminalTab(session: s, kind: .serial, serial: SerialConfig(path: port.path, baud: baud)))
    }

    func sendBreakToSelected() { selected?.view.sendBreak() }

    func close(_ id: UUID) {
        guard let i = index(id) else { return }
        tabs[i].view.stop()
        tabs.remove(at: i)
        tabObservers[id] = nil
        if var p = panes, let pi = p.firstIndex(of: id) {      // zavřený panel zmizí z rozložení
            p.remove(at: pi)
            if p.count <= 1 {
                panes = nil
                if broadcast { broadcast = false }
                selectedID = p.first
            } else {
                panes = p
                selectedID = p[min(pi, p.count - 1)]
            }
            return
        }
        if selectedID == id { selectedID = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)].id }
    }

    func reconnect(_ id: UUID) {
        guard let i = index(id) else { return }
        tabs[i].view.stop()
        let t = TerminalTab(session: tabs[i].session, kind: tabs[i].kind, serial: tabs[i].serial)
        register(t)
        tabs[i] = t
        if var p = panes, let pi = p.firstIndex(of: id) { p[pi] = t.id; panes = p }
        selectedID = t.id
    }

    func duplicate(_ id: UUID) {
        guard let i = index(id), tabs[i].kind != .serial else { return }   // port je výhradní
        open(tabs[i].session, kind: tabs[i].kind)
    }

    func openLocal() { open(.local, kind: .local) }

    /// Běžící SSH záložka serveru (pro „Připojit“ = přejít na otevřenou relaci).
    func liveTab(for sessionID: UUID) -> TerminalTab? {
        tabs.first { $0.session.id == sessionID && $0.kind == .ssh && $0.running }
    }

    /// Dvojklik / „Připojit“: otevřená relace → přepnout na ni, jinak nová záložka.
    func openOrFocus(_ s: SSHSession) {
        if s.isRDP { RDPLauncher.shared.launch(s); return }
        if let t = liveTab(for: s.id) { selectedID = t.id } else { open(s) }
    }

    /// Nová relace jako další panel vedle aktivní záložky.
    func openInSplit(_ s: SSHSession, _ axis: SplitAxis = .vertical) {
        if s.isRDP { RDPLauncher.shared.launch(s); return }
        guard let cur = selectedID else { open(s); return }
        open(s)
        guard let new = selectedID, new != cur else { return }
        var p = panes ?? [cur]
        guard p.count < Self.maxPanes else { return }
        splitAxis = axis
        p.append(new)
        panes = p
    }

    /// Ukončí relaci (záložka zůstane s výstupem).
    func disconnect(_ id: UUID) { tab(id)?.view.stop() }

    func openSFTP(_ s: SSHSession) { open(s, kind: .sftp) }

    /// SFTP ke stejné session jako aktivní SSH záložka.
    func sftpForSelected() {
        guard let t = selected, t.kind == .ssh || t.kind == .sftp else { return }
        openSFTP(t.session)
    }

    func closeOthers(_ id: UUID) { for t in tabs where t.id != id { close(t.id) } }

    func select(index i: Int) { if tabs.indices.contains(i) { selectedID = tabs[i].id } }

    func cycle(_ d: Int) {
        guard !tabs.isEmpty else { return }
        let i = index(selectedID) ?? 0
        selectedID = tabs[(i + d + tabs.count) % tabs.count].id
    }

    /// Přetažení záložky: přesune `id` před `target`.
    func moveTab(_ id: UUID, before target: UUID) {
        guard id != target, let from = index(id) else { return }
        let t = tabs.remove(at: from)
        let to = index(target) ?? tabs.count
        tabs.insert(t, at: to)
    }

    /// Server aktivní (fokusované) záložky – pro zvýraznění v levém panelu.
    var activeSessionID: UUID? {
        guard let t = selected, t.kind == .ssh || t.kind == .sftp else { return nil }
        return t.session.id
    }

    func moveSelected(_ d: Int) {
        guard let i = index(selectedID) else { return }
        let j = i + d
        guard tabs.indices.contains(j) else { return }
        tabs.swapAt(i, j)
    }

    func toggleLogging(_ id: UUID) {
        guard let i = index(id) else { return }
        tabs[i].toggleLogging()
        objectWillChange.send()          // ať se překreslí kontextové menu lišty
    }

    func toggleLoggingSelected() { if let id = selectedID { toggleLogging(id) } }

    func closeSelected() { if let id = selectedID { close(id) } }
    func clearSelected() { selected?.view.clearScreen() }
    func sendControlToSelected(_ byte: UInt8) { selected?.view.sendControl(byte) }
    func reconnectSelected() { if let id = selectedID { reconnect(id) } }
    func duplicateSelected() { if let id = selectedID { duplicate(id) } }
}

// MARK: - Hlavní okno

struct MainView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var tabs: TabManager
    @EnvironmentObject private var serial: SerialMonitor

    @StateObject private var sidebarWidth = SidebarWidth()

    // Vlastní rozložení místo NavigationSplitView: novější macOS SDK u NavigationSplitView vyhrazuje
    // nahoře místo pro toolbar (velká mezera) a se skrytým toolbarem schová i tlačítka okna.
    var body: some View {
        HStack(spacing: 0) {
            if tabs.sidebar != .detailOnly {
                SessionListView()
                    .frame(width: sidebarWidth.value)
                SidebarResizeHandle(width: sidebarWidth)
            }
            VStack(spacing: 0) {
                if tabs.focusMode {
                    // pruh pro semafor okna a tažení; dvojklik = ukončit režim soustředění
                    HStack {
                        Spacer()
                        Button { tabs.toggleFocus() } label: {
                            Label("Ukončit soustředění  ⌥⌘F", systemImage: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 10.5))
                        }
                        .buttonStyle(.plain).foregroundStyle(UI.textTertiary).padding(.trailing, 10)
                    }
                    .frame(height: 28)
                    .background(UI.main)
                    .background(WindowDragHandle(onDoubleClick: { tabs.toggleFocus() }))
                } else {
                    TabBar()
                    Rectangle().fill(UI.border).frame(height: 1)
                }
                HStack(spacing: 0) {
                    Group {
                        if let p = tabs.panes, p.count >= 2 {
                            PanesView(ids: p)
                        } else if let tab = tabs.selected {
                            TerminalWithOverlay(tab: tab, focus: true)
                        } else {
                            EmptyTabsView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if tabs.showFiles, let t = tabs.selected, t.kind == .ssh, let b = t.browser() {
                        Rectangle().fill(UI.border).frame(width: 1)
                        FileBrowserPanel(b: b).frame(width: 430)
                            .id(t.id)                    // každá záložka má vlastní prohlížeč
                    }
                }
                if tabs.focusMode && !store.settings.focusShowStatus {
                    EmptyView()
                } else if let tab = tabs.selected {
                    Rectangle().fill(UI.border).frame(height: 1)
                    StatusBar(tab: tab)
                } else {
                    HStack { Spacer(); SettingsButton() }
                        .font(.system(size: 11)).foregroundStyle(UI.textSecondary)
                        .padding(.horizontal, 12).frame(height: 28).background(UI.statusBar)
                }
            }
            .background(UI.app)
        }
        .background(UI.sidebar)
        .ignoresSafeArea(.container, edges: .top)   // obsah až pod průhlednou titulkovou lištu
        .background(WindowConfigurator(title: tabs.selected?.title ?? "SSHTool"))
        .sheet(isPresented: $tabs.showPicker) {
            QuickConnectView().environmentObject(store).environmentObject(tabs)
        }
        .sheet(isPresented: $tabs.showCapture) {
            CaptureSheet(m: tabs.capture).environmentObject(store).environmentObject(tabs)
        }
        .sheet(isPresented: $tabs.showMultiSend) {
            MultiSendSheet(m: tabs.multiSend).environmentObject(store).environmentObject(tabs)
        }
        .alert(item: $serial.announce) { p in
            let baud = store.serialBaud(for: p)
            return Alert(
                title: Text("Připojena sériová konzole"),
                message: Text("\(p.title)\(p.vendor.map { " (\($0))" } ?? "")\n\(p.path)"),
                primaryButton: .default(Text("Připojit (\(baud) baud)")) { tabs.openSerial(p, baud: baud) },
                secondaryButton: .cancel(Text("Zavřít")))
        }
        .frame(minWidth: 960, minHeight: 560)
        .onAppear {
            ZoomGesture.shared.install()
            serial.start()
            Updater.shared.checkOnLaunch()
            let t = tabs
            RDPLauncher.shared.onChange = { [weak t] in t?.objectWillChange.send() }   // tečka stavu RDP v levém panelu
        }
    }
}

/// Rozložení 2–4 panelů (táhlem jde měnit velikost).
struct PanesView: View {
    @EnvironmentObject private var tabs: TabManager
    let ids: [UUID]

    private func pane(_ i: Int) -> some View {
        let t = tabs.tab(ids[i])
        return Group {
            if let t { TerminalPane(tab: t, focused: t.id == tabs.selectedID) } else { EmptyView() }
        }
    }

    var body: some View {
        switch ids.count {
        case 2:
            if tabs.splitAxis == .vertical {
                HSplitView { pane(0); pane(1) }
            } else {
                VSplitView { pane(0); pane(1) }
            }
        case 3:
            if tabs.splitAxis == .vertical {
                HSplitView { pane(0); VSplitView { pane(1); pane(2) } }
            } else {
                VSplitView { pane(0); HSplitView { pane(1); pane(2) } }
            }
        default:
            VSplitView {
                HSplitView { pane(0); pane(1) }
                HSplitView { pane(2); pane(3) }
            }
        }
    }
}

/// Jeden panel rozděleného zobrazení: záhlaví s barvou session + terminál.
struct TerminalPane: View {
    @EnvironmentObject private var tabs: TabManager
    @ObservedObject var tab: TerminalTab
    let focused: Bool
    @StateObject private var hover = HoverModel()

    private var broadcastTarget: Bool { tabs.broadcast && tabs.broadcastTargets.contains { $0.id == tab.id } }

    var body: some View {
        VStack(spacing: 0) {
            // hlavička 24 pt: ● název · IP  …  (aktivní panel = akcentová linka nahoře + světlejší pozadí)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1).fill(UI.sessionColor(tab.session.resolvedColorHex)).frame(width: 3, height: 12)
                StatusDot(color: tab.state.color, size: 6).help(tab.state.label)
                Text(tabs.displayTitle(tab))
                    .font(.system(size: 11, weight: focused ? .semibold : .regular)).lineLimit(1)
                if tab.kind != .local {
                    Text("· \(tab.session.host)").font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(UI.textTertiary).lineLimit(1)
                }
                EnvBadge(tag: tab.session.envTag)
                Spacer(minLength: 4)
                if focused {
                    Text("AKTIVNÍ").font(.system(size: 8.5, weight: .bold)).tracking(0.5).foregroundStyle(UI.accent)
                }
                Menu {
                    Button("Přesunout do samostatné záložky") { tabs.detachPane(tab.id) }
                    Button("Rozdělit vedle  (vertikálně)") { tabs.splitFrom(tab.id, .vertical) }
                    Button("Rozdělit pod  (horizontálně)") { tabs.splitFrom(tab.id, .horizontal) }
                    Divider()
                    Button("Přejmenovat záložku…") { tabs.rename(tab.id) }
                    Button("Znovu připojit") { tabs.reconnect(tab.id) }
                    Divider()
                    Button("Zavřít panel (ukončit relaci)") { tabs.close(tab.id) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).frame(width: 20, height: 18)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .opacity(hover.on || focused ? 1 : 0.35)
                .help("Akce panelu")
            }
            .foregroundStyle(focused ? UI.text : UI.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(focused ? UI.cardSelected : UI.chrome)
            .overlay(alignment: .top) {
                Rectangle().fill(broadcastTarget ? UI.error : UI.accent).frame(height: 2)
                    .opacity(focused || broadcastTarget ? 1 : 0)
            }
            .contentShape(Rectangle())
            .onHover { hover.on = $0 }
            .onTapGesture { tabs.selectedID = tab.id }
            TerminalWithOverlay(tab: tab, focus: focused)
                .opacity(focused ? 1 : 0.92)                  // neaktivní panel jemně utlumený
        }
        .overlay(Rectangle().stroke(broadcastTarget ? UI.error : SwiftUI.Color.clear, lineWidth: 1))
        .frame(minWidth: 200, minHeight: 120)
    }
}

/// Drží v sobě vždy jen terminál daného panelu; ostatní terminály žijí dál mimo hierarchii.
struct TerminalHost: NSViewRepresentable {
    let target: SSHTerminalView
    var focus = true

    func makeNSView(context: Context) -> PaddedHost {
        let v = PaddedHost()
        v.wantsLayer = true
        v.layer?.backgroundColor = TabbyTheme.nsColor(TabbyTheme.background).cgColor
        return v
    }

    func updateNSView(_ host: PaddedHost, context: Context) {
        host.claim(target, focus: focus)
    }
}

struct EmptyTabsView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal").font(.system(size: 40)).foregroundStyle(UI.textTertiary)
            Text("Žádná otevřená záložka").font(.title3).foregroundStyle(UI.text)
            Text("Dvojklik na server vlevo, ⌘K nebo + v liště záložek · ⇧⌘N lokální terminál")
                .foregroundStyle(UI.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SwiftUI.Color(hex: TabbyTheme.background) ?? .black)
    }
}

// MARK: - Lišta záložek

struct TabBar: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var tabs: TabManager
    @EnvironmentObject private var serial: SerialMonitor

    private func chromeButton(_ icon: String, active: Bool = false) -> some View {
        Image(systemName: icon)
            .font(.system(size: 13))
            .frame(width: 28, height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? UI.cardSelected : SwiftUI.Color.clear))
            .foregroundStyle(active ? UI.text : UI.textSecondary)
            .contentShape(Rectangle())
    }

    var body: some View {
        HStack(spacing: 6) {
            Button { tabs.toggleSidebar() } label: { chromeButton("sidebar.left") }
                .buttonStyle(.plain)
                .help(tabs.sidebar == .detailOnly ? "Zobrazit seznam serverů (⌃⌘S)" : "Skrýt seznam serverů (⌃⌘S)")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(tabs.tabs) { tab in
                        TabCard(tab: tab, title: tabs.displayTitle(tab), selected: tabs.isVisible(tab.id),
                                focused: tab.id == tabs.selectedID,
                                select: { tabs.selectedID = tab.id },
                                close: { tabs.close(tab.id) })
                        .contextMenu { TabContextMenu(tab: tab) }
                        .draggable(tab.id.uuidString)
                        .dropDestination(for: String.self) { items, _ in
                            guard let s = items.first, let id = UUID(uuidString: s) else { return false }
                            tabs.moveTab(id, before: tab.id)
                            return true
                        }
                    }
                    NewTabMenu()
                }
                .padding(.vertical, 8)
            }

            if tabs.tabs.count > 1 {
                Menu {
                    ForEach(tabs.tabs) { t in
                        Button("\(tabs.displayTitle(t))  —  \(t.subtitle)") { tabs.selectedID = t.id }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(UI.textSecondary)
                .help("Všechny otevřené relace (\(tabs.tabs.count))")
            }

            Spacer(minLength: 0)

            if tabs.broadcast {
                Button { tabs.toggleBroadcast() } label: {
                    Label("BROADCAST · \(tabs.broadcastTargets.count)", systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(UI.error))
                        .foregroundStyle(SwiftUI.Color.white)
                }
                .buttonStyle(.plain)
                .help("Broadcast vstupu je zapnutý – klikni pro vypnutí (⇧⌘I)")
            }

            HStack(spacing: 0) {
                Button { tabs.toggleSplit(.vertical) } label: {
                    chromeButton("rectangle.split.2x1", active: tabs.panes != nil && tabs.splitAxis == .vertical)
                }
                .help("Vedle sebe (⇧⌘D)")
                Button { tabs.toggleSplit(.horizontal) } label: {
                    chromeButton("rectangle.split.1x2", active: tabs.panes != nil && tabs.splitAxis == .horizontal)
                }
                .help("Pod sebou (⌘D)")
            }
            .buttonStyle(.plain)
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8).stroke(UI.border, lineWidth: 1))

            Button { tabs.showPicker = true } label: { chromeButton("magnifyingglass") }
                .buttonStyle(.plain)
                .help("Hledat server / příkazová paleta (⌘K)")

            Menu {
                let list = tabs.snippetsForSelected(store.snippets)
                if list.isEmpty { Text("Žádné snippety – přidej šablonu v Nastavení → Snippety") }
                let cats = list.reduce(into: [String]()) { if !$0.contains($1.category) { $0.append($1.category) } }
                ForEach(cats, id: \.self) { c in
                    let items = list.filter { $0.category == c }
                    if cats.count > 1 {
                        Menu(c.isEmpty ? "Vlastní" : c) { SnippetMenuItems(items: items) }
                    } else {
                        SnippetMenuItems(items: items)
                    }
                }
                Divider()
                Button("Upravit snippety…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
            } label: {
                Image(systemName: "text.append").font(.system(size: 13))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(UI.textSecondary)
            .disabled(tabs.selected == nil)
            .help("Snippety – uložené příkazy")

            Button { tabs.toggleFiles() } label: { chromeButton("folder", active: tabs.showFiles) }
                .buttonStyle(.plain)
                .disabled(tabs.selected == nil)
                .help("Soubory serveru – procházení, nahrání ↑ a stažení ↓ (⇧⌘E)")

            Button { tabs.showCapture = true } label: { chromeButton("waveform.path.ecg") }
                .buttonStyle(.plain)
                .disabled(tabs.selected == nil)
                .help("Zachytávání paketů – tcpdump / fw monitor (⌥⌘P)")

            Button { tabs.toggleFocus() } label: { chromeButton("arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.plain)
                .help("Režim soustředění – jen terminál (⌥⌘F)")

            Menu {
                Button("Přidat panel vedle  ⇧⌘D") { tabs.split(.vertical) }
                Button("Přidat panel pod  ⌘D") { tabs.split(.horizontal) }
                if tabs.panes != nil {
                    Button("Další panel  ⌥⌘→") { tabs.focusPane(1) }
                    Button("Otočit pořadí panelů") { tabs.swapPanes() }
                    Button("Zrušit rozdělení  ⌥⌘U") { tabs.unsplit() }
                }
                Divider()
                Button(tabs.broadcast ? "Vypnout broadcast  ⇧⌘I" : "Broadcast vstupu…  ⇧⌘I") { tabs.toggleBroadcast() }
                Button("Odeslat příkazy do relací…  ⌥⌘I") { tabs.showMultiSend = true }
                Button("Hledat ve výstupu  ⌘F") { tabs.selected?.view.showFind() }
                Button("Zachytávání paketů…  ⌥⌘P") { tabs.showCapture = true }
                Button("Rychlé připojení…  ⇧⌘K") { tabs.showQuickConnect = true }
                Divider()
                Button("Lokální terminál  ⇧⌘N") { tabs.openLocal() }
                if let t = tabs.selected {
                    Button(t.logging ? "Vypnout logování  ⇧⌘L" : "Zapnout logování  ⇧⌘L") { tabs.toggleLoggingSelected() }
                    Button("Vyčistit obrazovku  ⌘L") { tabs.clearSelected() }
                }
                Divider()
                Menu("Barevný profil") {
                    ForEach(Theme.all) { t in
                        Button((store.settings.themeID == t.id ? "✓ " : "") + t.name) { store.selectTheme(t.id) }
                    }
                }
                Button("Importovat servery…") { store.importSessionsPanel() }
                Button("Uložit vzor JSON se servery…") { store.saveSessionsTemplatePanel() }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(UI.textSecondary)
            .padding(.trailing, 4)
        }
        .padding(.horizontal, 8)
        // se skrytým levým panelem je vlevo nahoře semafor okna
        .padding(.leading, tabs.sidebar == .detailOnly ? 70 : 0)
        .frame(height: 54)
        .background(UI.chrome)
        .background(WindowDragHandle(onDoubleClick: { tabs.showPicker = true }))   // dvojklik do prázdna = nová záložka
        .sheet(isPresented: $tabs.showQuickConnect) {
            QuickConnectSheet().environmentObject(store).environmentObject(tabs)
        }
    }
}

/// „+“ – nová záložka.
struct NewTabMenu: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var tabs: TabManager
    @EnvironmentObject private var serial: SerialMonitor

    var body: some View {
        Menu {
            Button("Hledat server…  ⌘K") { tabs.showPicker = true }
            Button("Lokální terminál  ⇧⌘N") { tabs.openLocal() }
            Menu("Sériová konzole") {
                if serial.ports.isEmpty {
                    Text("Žádný sériový port – připoj USB konzolový kabel")
                }
                ForEach(serial.ports) { p in
                    Menu(p.title + "  (" + p.device + ")") { SerialPortMenuItems(port: p) }
                }
            }
            Divider()
            ForEach(store.groupedSessions, id: \.group) { g in
                Menu(g.group) {
                    ForEach(g.items) { s in
                        Button(s.name) { tabs.open(s) }
                    }
                }
            }
            Divider()
            Menu("SFTP") {
                ForEach(store.groupedSessions, id: \.group) { g in
                    Menu(g.group) {
                        ForEach(g.items) { s in
                            Button(s.name) { tabs.openSFTP(s) }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 14, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 34, height: 38)
        .background(RoundedRectangle(cornerRadius: 8).fill(UI.card))
        .help("Nová záložka")
    }
}

struct TabContextMenu: View {
    @EnvironmentObject private var tabs: TabManager
    let tab: TerminalTab

    var body: some View {
        if tab.id != tabs.selectedID {
            Button("Zobrazit vedle aktivní záložky") { tabs.split(with: tab.id, .vertical) }
            Button("Zobrazit pod aktivní záložkou") { tabs.split(with: tab.id, .horizontal) }
            Divider()
        }
        Button("Přejmenovat záložku…") { tabs.rename(tab.id) }
        if tab.customTitle != nil { Button("Obnovit původní název") { tabs.resetTitle(tab.id) } }
        Divider()
        Button("Znovu připojit") { tabs.reconnect(tab.id) }
        if tab.kind != .serial {
            Button("Duplikovat") { tabs.duplicate(tab.id) }
        } else {
            Button("Poslat Break") { tab.view.sendBreak() }
        }
        if tab.kind == .ssh {
            Button("Otevřít SFTP") { tabs.openSFTP(tab.session) }
        }
        if tab.kind == .ssh || tab.kind == .sftp, let url = tab.session.webURL {
            Button("Otevřít web (\(url.absoluteString))") { WebOpener.open(tab.session) }
        }
        Divider()
        if tab.running || tab.logging {
            Button(tab.logging ? "Vypnout logování" : "Zapnout logování do souboru") {
                tabs.toggleLogging(tab.id)
            }
        }
        if let url = tab.view.logURL {
            Button("Zobrazit log ve Finderu") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        Divider()
        Button("Zavřít") { tabs.close(tab.id) }
        Button("Zavřít ostatní") { tabs.closeOthers(tab.id) }
    }
}

// MARK: - Příkazová paleta (⌘K / ⌘T)

struct PaletteAction: Identifiable {
    let id: String
    let icon: String
    let hint: String
    let run: @MainActor () -> Void
    var title: String { id }
}

struct QuickConnectView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var tabs: TabManager

    private var query: String { tabs.pickerQuery.lowercased().trimmingCharacters(in: .whitespaces) }

    private var servers: [SSHSession] {
        let q = query
        return store.groupedSessions.flatMap(\.items).filter {
            q.isEmpty || $0.name.lowercased().contains(q) || $0.host.contains(q) || $0.group.lowercased().contains(q)
        }
    }

    private var actions: [PaletteAction] {
        let t = tabs
        let all: [PaletteAction] = [
            PaletteAction(id: "Rychlé připojení (user@host:port)…", icon: "bolt", hint: "⇧⌘K") { t.showQuickConnect = true },
            PaletteAction(id: "Lokální terminál", icon: "terminal", hint: "⇧⌘N") { t.openLocal() },
            PaletteAction(id: "Přidat panel vedle", icon: "rectangle.split.2x1", hint: "⇧⌘D") { t.split(.vertical) },
            PaletteAction(id: "Přidat panel pod", icon: "rectangle.split.1x2", hint: "⌘D") { t.split(.horizontal) },
            PaletteAction(id: "Zrušit rozdělení", icon: "rectangle", hint: "⌥⌘U") { t.unsplit() },
            PaletteAction(id: "Broadcast vstupu do více relací", icon: "dot.radiowaves.left.and.right", hint: "⇧⌘I") { t.toggleBroadcast() },
            PaletteAction(id: "Hledat ve výstupu terminálu", icon: "magnifyingglass", hint: "⌘F") { t.selected?.view.showFind() },
            PaletteAction(id: "Vyčistit obrazovku", icon: "eraser", hint: "⌘L") { t.clearSelected() },
            PaletteAction(id: "Znovu připojit aktivní záložku", icon: "arrow.clockwise", hint: "⇧⌘R") { t.reconnectSelected() },
            PaletteAction(id: "Zapnout / vypnout logování", icon: "record.circle", hint: "⇧⌘L") { t.toggleLoggingSelected() },
            PaletteAction(id: "Otevřít SFTP k aktivní session", icon: "folder", hint: "⇧⌘S") { t.sftpForSelected() },
            PaletteAction(id: "Skrýt / zobrazit seznam serverů", icon: "sidebar.left", hint: "⌃⌘S") { t.toggleSidebar() },
            PaletteAction(id: "Importovat servery…", icon: "square.and.arrow.down", hint: "") { AppStore.shared?.importSessionsPanel() },
            PaletteAction(id: "Nastavení", icon: "gearshape", hint: "⌘,") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            },
        ]
        let themes = Theme.all.map { th in
            PaletteAction(id: "Barevný profil: " + th.name, icon: "paintpalette", hint: "") {
                AppStore.shared?.selectTheme(th.id)
            }
        }
        let q = query
        return q.isEmpty ? all : (all + themes).filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(UI.textSecondary)
                TextField("Hledat server nebo akci…  (Enter = první výsledek)", text: $tabs.pickerQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .onSubmit(runFirst)
            }
            .padding(14)
            Rectangle().fill(UI.border).frame(height: 1)
            List {
                if !query.isEmpty, !servers.isEmpty { serverSection }
                if !actions.isEmpty {
                    Section("AKCE") {
                        ForEach(actions) { a in
                            Button { run(a) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: a.icon).frame(width: 18).foregroundStyle(UI.accent)
                                    Text(a.title).foregroundStyle(UI.text)
                                    Spacer()
                                    if !a.hint.isEmpty { KeyHint(text: a.hint) }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if query.isEmpty, !servers.isEmpty { serverSection }
            }
            .scrollContentBackground(.hidden)
            HStack {
                Text("⌘K paleta · ⇧⌘K rychlé připojení").font(.caption).foregroundStyle(UI.textTertiary)
                Spacer()
                Button("Zavřít") { tabs.showPicker = false }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
        .frame(width: 600, height: 480)
        .background(UI.sidebar)
    }

    private var serverSection: some View {
        Section("SERVERY") {
            ForEach(servers) { s in
                HStack(spacing: 8) {
                    Button { connect(s) } label: {
                        HStack(spacing: 8) {
                            StatusDot(color: tabs.state(for: s.id)?.color ?? UI.idle, size: 6)
                            Image(systemName: "desktopcomputer").font(.system(size: 11))
                                .foregroundStyle(UI.sessionColor(s.resolvedColorHex))
                            Text(s.name).foregroundStyle(UI.text)
                            Text(s.host).font(.system(size: 11, design: .monospaced)).foregroundStyle(UI.textSecondary)
                            Spacer()
                            Text(s.group).font(.caption).foregroundStyle(UI.textTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button("SFTP") { connect(s, kind: .sftp) }
                        .controlSize(.small)
                }
            }
        }
    }

    private func runFirst() {
        if !query.isEmpty, let s = servers.first { connect(s) }
        else if let a = actions.first { run(a) }
        else if let s = servers.first { connect(s) }
    }

    private func run(_ a: PaletteAction) {
        tabs.showPicker = false
        tabs.pickerQuery = ""
        // akce může otevřít další okno/list → až po zavření palety
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            a.run()
        }
    }

    private func connect(_ s: SSHSession, kind: TabKind = .ssh) {
        tabs.showPicker = false
        tabs.pickerQuery = ""
        tabs.open(s, kind: kind)
    }
}

// MARK: - Rychlé připojení (⇧⌘K)

struct QuickConnectSheet: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var tabs: TabManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Rychlé připojení", systemImage: "bolt").font(.headline).foregroundStyle(UI.text)
            HStack(spacing: 8) {
                Image(systemName: "terminal").foregroundStyle(UI.textSecondary)
                TextField("uživatel@host:port  (např. admin@10.0.0.1:2222)", text: $tabs.quickTarget)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, design: .monospaced))
                    .onSubmit { go(save: false) }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(UI.card))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(UI.border, lineWidth: 1))
            Text("Enter = připojit bez uložení. Port je volitelný (výchozí 22), IPv6 piš v [hranatých] závorkách.")
                .font(.caption).foregroundStyle(UI.textSecondary)
            HStack {
                Button("Zrušit") { tabs.showQuickConnect = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Připojit a uložit do seznamu") { go(save: true) }
                Button("Připojit") { go(save: false) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520)
        .background(UI.sidebar)
    }

    private func go(save: Bool) {
        let t = tabs.quickTarget
        tabs.showQuickConnect = false
        tabs.quickTarget = ""
        tabs.quickConnect(t, save: save ? store : nil)
    }
}

/// Položky menu snippetů: klik = vložit bez spuštění, podmenu = i spustit.
struct SnippetMenuItems: View {
    @EnvironmentObject private var tabs: TabManager
    let items: [Snippet]
    var body: some View {
        ForEach(items) { s in
            Menu(s.name.isEmpty ? s.command : "\(s.name)  —  \(s.command)") {
                Button("Vložit (bez spuštění)") { tabs.insertSnippet(s, run: false) }
                Button("Vložit a spustit") { tabs.insertSnippet(s, run: true) }
            }
        }
    }
}


// MARK: - Okno a levý panel

/// Šířka levého panelu (pamatuje se mezi spuštěními).
final class SidebarWidth: ObservableObject {
    static let range: ClosedRange<CGFloat> = 220...460
    @Published var value: CGFloat {
        didSet { UserDefaults.standard.set(Double(value), forKey: "SSHToolSidebarWidth") }
    }
    var dragStart: CGFloat?
    init() {
        let v = UserDefaults.standard.double(forKey: "SSHToolSidebarWidth")
        value = v > 0 ? min(max(CGFloat(v), Self.range.lowerBound), Self.range.upperBound) : 290
    }
}

/// Táhlo mezi levým panelem a terminálem (1 px čára, 7 px úchop). Dvojklik = výchozí šířka.
struct SidebarResizeHandle: View {
    @ObservedObject var width: SidebarWidth

    var body: some View {
        Rectangle().fill(UI.border).frame(width: 1)
            .overlay(
                Color.clear.frame(width: 7).contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { g in
                            let start = width.dragStart ?? width.value
                            if width.dragStart == nil { width.dragStart = start }
                            width.value = min(max(start + g.translation.width, SidebarWidth.range.lowerBound),
                                              SidebarWidth.range.upperBound)
                        }
                        .onEnded { _ in width.dragStart = nil })
                    .onTapGesture(count: 2) { width.value = 290 }
            )
    }
}

/// Nastaví okno přímo přes AppKit: průhledná titulková lišta bez názvu, obsah pod ní,
/// viditelná tlačítka okna (zavřít / minimalizovat / celá obrazovka) – nezávisle na verzi SDK.
struct WindowConfigurator: NSViewRepresentable {
    let title: String

    final class V: NSView {
        var title = ""
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }
        func configure() {
            guard let w = window else { return }
            w.title = title
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.styleMask.insert(.fullSizeContentView)
            w.toolbar = nil
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                w.standardWindowButton(b)?.isHidden = false
            }
        }
    }

    func makeNSView(context: Context) -> V { let v = V(); v.title = title; return v }
    func updateNSView(_ v: V, context: Context) {
        v.title = title
        DispatchQueue.main.async { v.configure() }
    }
}
