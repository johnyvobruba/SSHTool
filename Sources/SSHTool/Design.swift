import SwiftUI
import AppKit

// MARK: - Paleta UI („Slate“, upravená dle zadání v2)

enum UI {
    static func hex(_ h: String) -> SwiftUI.Color { SwiftUI.Color(hex: h) ?? .gray }
    private static var t: Theme { ThemeStore.ui }

    static var app: SwiftUI.Color           { hex(t.appBackground) }
    static var main: SwiftUI.Color          { hex(ThemeStore.terminal.background) }   // terminál
    static var sidebar: SwiftUI.Color       { hex(t.sidebarBackground) }
    static var chrome: SwiftUI.Color        { hex(t.toolbarBackground) }
    static var statusBar: SwiftUI.Color     { hex(t.appBackground) }
    static var card: SwiftUI.Color          { hex(t.tabInactiveBackground) }
    static var cardSelected: SwiftUI.Color  { hex(t.tabActiveBackground) }
    static var hover: SwiftUI.Color         { hex(t.itemHoverBackground) }
    static var rowSelected: SwiftUI.Color   { hex(t.itemSelectedBackground) }
    static var border: SwiftUI.Color        { hex(t.borderColor) }
    static var text: SwiftUI.Color          { hex(t.textPrimary) }
    static var textSecondary: SwiftUI.Color { hex(t.textSecondary) }
    static var textIP: SwiftUI.Color        { hex(t.textSecondary) }
    static var textStatus: SwiftUI.Color    { hex(t.textSecondary) }
    static var textTertiary: SwiftUI.Color  { hex(t.textTertiary) }
    static var accent: SwiftUI.Color        { hex(t.accentColor) }

    static var ok: SwiftUI.Color         { hex(t.statusConnected) }
    static var connecting: SwiftUI.Color { hex(t.statusConnecting) }
    static var idle: SwiftUI.Color       { hex(t.statusDisconnected) }
    static var error: SwiftUI.Color      { hex(t.statusError) }

    static func sessionColor(_ hex: String) -> SwiftUI.Color {
        hex == "none" ? textTertiary.opacity(0.5) : (SwiftUI.Color(hex: hex) ?? textSecondary)
    }
}

/// Stav SSH relace (ne dostupnost serveru!). Server bez otevřené relace = šedá.
enum ConnState: Equatable {
    case connected, connecting, disconnected, error

    var color: SwiftUI.Color {
        switch self {
        case .connected: return UI.ok
        case .connecting: return UI.connecting
        case .disconnected: return UI.idle
        case .error: return UI.error
        }
    }

    var label: String {
        switch self {
        case .connected: return "Připojeno"
        case .connecting: return "Připojování…"
        case .disconnected: return "Odpojeno"
        case .error: return "Chyba spojení"
        }
    }
}

struct StatusDot: View {
    let color: SwiftUI.Color
    var size: CGFloat = 7
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

struct KeyHint: View {
    let text: String
    var dark = false
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(dark ? SwiftUI.Color.white.opacity(0.2) : UI.cardSelected))
    }
}

/// Štítek prostředí (PROD / TEST / DEV) – oddělený od barvy serveru i od stavu SSH.
struct EnvBadge: View {
    let tag: String
    private var info: (String, SwiftUI.Color, String)? {
        switch tag {
        case "prod": return ("PROD", UI.error, "Produkční prostředí")
        case "stage": return ("STAGE", SwiftUI.Color.purple, "Staging")
        case "test": return ("TEST", SwiftUI.Color.orange, "Testovací prostředí")
        case "dev":  return ("DEV", UI.accent, "Vývojové prostředí")
        default: return nil
        }
    }
    var body: some View {
        if let i = info {
            let (t, c, h) = i
            Text(t)
                .font(.system(size: 8.5, weight: .bold))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(c.opacity(0.85)))
                .foregroundStyle(SwiftUI.Color.white)
                .fixedSize()
                .help(h)
        }
    }
}

/// Zpětná kompatibilita.
struct ProdBadge: View { var body: some View { EnvBadge(tag: "prod") } }

/// Hover stav bez @State (CLT SDK nemá SwiftUI makra).
final class HoverModel: ObservableObject { @Published var on = false }

/// Text se zvýrazněnou shodou s hledaným výrazem.
func highlighted(_ text: String, _ query: String, color: SwiftUI.Color) -> Text {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty, let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else {
        return Text(text).foregroundColor(color)
    }
    return Text(text[..<r.lowerBound]).foregroundColor(color)
        + Text(text[r]).foregroundColor(UI.accent).bold()
        + Text(text[r.upperBound...]).foregroundColor(color)
}

// MARK: - Levý panel

struct SidebarSearchField: View {
    let text: Binding<String>
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(UI.textSecondary)
            TextField("Název, IP nebo složka…", text: text)
                .textFieldStyle(.plain)
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(UI.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(UI.card))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(UI.border, lineWidth: 1))
    }
}

/// Záhlaví skupiny – jemné, klik sbalí/rozbalí, počet v odznaku, zvýraznění při najetí.
struct GroupHeaderRow: View {
    let title: String
    let count: Int
    let collapsed: Bool
    var icon: String? = nil
    var color: SwiftUI.Color? = nil
    var depth = 0
    let toggle: () -> Void
    @StateObject private var hover = HoverModel()

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .frame(width: 12, height: 12, alignment: .center)
            if let icon { Image(systemName: icon).font(.system(size: 9)).frame(width: 12) }
            else if let color { Circle().fill(color).frame(width: 6, height: 6).frame(width: 12) }
            Text(title).font(.system(size: 10.5, weight: .semibold)).tracking(0.4).lineLimit(1)
            Spacer()
            Text("\(count)")
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(UI.card))
                .foregroundStyle(UI.textSecondary)
        }
        .foregroundStyle(hover.on ? UI.text : UI.textSecondary)
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(hover.on ? UI.card.opacity(0.6) : SwiftUI.Color.clear))
        .padding(.top, depth == 0 ? 12 : 2)
        .padding(.leading, CGFloat(depth) * 14)
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .onTapGesture(perform: toggle)
        .help(collapsed ? "Rozbalit složku" : "Sbalit složku")
    }
}

struct SidebarSessionRow: View {
    let session: SSHSession
    let state: ConnState?
    let active: Bool               // server aktivní záložky
    let comfortable: Bool
    let query: String
    let toggleFavorite: () -> Void

    private var dot: some View { StatusDot(color: state?.color ?? UI.idle, size: 6) }

    private var star: some View {
        Button(action: toggleFavorite) {
            Image(systemName: session.favorite ? "star.fill" : "star")
                .font(.system(size: 10))
                .foregroundStyle(session.favorite ? SwiftUI.Color.yellow : UI.textTertiary)
        }
        .buttonStyle(.plain)
        .help(session.favorite ? "Odebrat z oblíbených" : "Přidat do oblíbených")
    }

    private var name: some View {
        highlighted(session.displayName, query, color: UI.text)
            .font(.system(size: 12.5, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var ip: some View {
        highlighted(session.host, query, color: UI.textIP)
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .fixedSize()                    // IP je vždy celá
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.isRDP ? "display" : "desktopcomputer")
                .font(.system(size: 11))
                .foregroundStyle(UI.sessionColor(session.resolvedColorHex))
            if comfortable {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) { name; EnvBadge(tag: session.envTag) }
                    ip
                }
                Spacer(minLength: 4)
            } else {
                name.frame(maxWidth: .infinity, alignment: .leading)
                EnvBadge(tag: session.envTag)
                ip.layoutPriority(1)
            }
            if session.isRDP, RDPLauncher.shared.isRunning(session.id) {
                Button { RDPLauncher.shared.disconnect(session.id) } label: {
                    Image(systemName: "eject.fill").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(UI.textTertiary)
                .help("Odpojit RDP relaci")
            }
            dot
            star
        }
        .padding(.vertical, comfortable ? 6 : 3)
        .padding(.leading, 8).padding(.trailing, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(active ? UI.rowSelected : SwiftUI.Color.clear))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(UI.accent).frame(width: 3).padding(.vertical, 4)
                .opacity(active ? 1 : 0)
        }
        .help("\(session.name)\n\(session.user.isEmpty ? "" : session.user + "@")\(session.host):\(session.port) · \(session.group)\n\(state?.label ?? "Bez otevřené relace")")
    }
}

// MARK: - Karta záložky

struct TabCard: View {
    @ObservedObject var tab: TerminalTab
    let title: String
    let selected: Bool          // viditelná (v jednom z panelů)
    let focused: Bool           // aktivní panel
    let select: () -> Void
    let close: () -> Void

    private var tooltip: String {
        let mins = Int(Date().timeIntervalSince(tab.startedAt)) / 60
        let secs = Int(Date().timeIntervalSince(tab.startedAt)) % 60
        let kind = tab.kind == .sftp ? "SFTP" : tab.kind == .local ? "Lokální" : tab.kind == .serial ? "Sériová" : "SSH"
        return "\(title)\n\(tab.session.name) · \(tab.subtitle)\n\(kind) • \(tab.state.label)\n"
            + (tab.running ? "Připojeno \(mins) min \(secs) s" : "Relace skončila")
    }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)                                  // identita serveru/skupiny
                .fill(UI.sessionColor(tab.session.resolvedColorHex))
                .frame(width: 3, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 12, weight: focused ? .semibold : .medium))
                        .foregroundStyle(tab.running ? UI.text : UI.textSecondary)
                        .lineLimit(1)
                    EnvBadge(tag: tab.session.envTag)
                }
                HStack(spacing: 4) {
                    StatusDot(color: tab.state.color, size: 6)                   // stav SSH
                        .overlay(Circle().stroke(UI.chrome, lineWidth: 1))
                    Text(tab.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(UI.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 2)
            if tab.logging {
                Image(systemName: "record.circle").font(.system(size: 9)).foregroundStyle(UI.error)
            }
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(UI.textTertiary)
            .help("Zavřít záložku (⌘W)")
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .frame(minWidth: 130, maxWidth: 220)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? UI.cardSelected : UI.card))
        .overlay(alignment: .bottom) {
            Rectangle().fill(UI.accent).frame(height: 2).padding(.horizontal, 8)
                .opacity(focused ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .help(tooltip)
    }
}

// MARK: - Nenápadná lišta „spojení ukončeno“ (výstup terminálu zůstává vidět)

struct DisconnectBanner: View {
    @ObservedObject var tab: TerminalTab
    @EnvironmentObject private var tabs: TabManager

    private var title: String {
        switch tab.kind {
        case .ssh: return "SSH spojení ukončeno"
        case .sftp: return "SFTP spojení ukončeno"
        case .local: return "Terminál ukončen"
        case .serial: return "Sériová konzole odpojena"
        }
    }

    private var reason: String {
        guard let code = tab.exitCode else { return "Proces ukončen signálem" }
        switch (tab.kind, code) {
        case (.serial, 2): return "Kabel byl odpojen"
        case (_, 0): return "Odhlášení nebo neaktivita (auto-logout)"
        case (.ssh, 255), (.sftp, 255): return "Síť, ověření nebo klíč serveru – viz výstup"
        default: return "Kód \(code)"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            StatusDot(color: tab.state.color, size: 7).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(UI.text)
                Text(reason).font(.system(size: 11)).foregroundStyle(UI.textSecondary).lineLimit(2)
                Button { tabs.reconnect(tab.id) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
                        Text("Znovu připojit").font(.system(size: 11, weight: .semibold))
                        KeyHint(text: "⌘R", dark: true)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(UI.accent))
                    .foregroundStyle(SwiftUI.Color.white)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            Button { tab.overlayDismissed = true } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(UI.textTertiary)
            .help("Skrýt (stav zůstává ve stavovém řádku)")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(UI.card.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(UI.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }
}

/// Terminál + při odpojení tenká lišta dole (nezakrývá poslední výstup nahoře).
struct TerminalWithOverlay: View {
    @ObservedObject var tab: TerminalTab
    let focus: Bool

    var body: some View {
        if tab.kind == .sftp, let b = tab.browser() {
            // SFTP záložka: prohlížeč souborů + malý terminál pro přihlášení / stav spojení
            VStack(spacing: 0) {
                FileBrowserPanel(b: b, embedded: true)
                Rectangle().fill(UI.border).frame(height: 1)
                terminal.frame(height: 96)
            }
        } else {
            terminal
        }
    }

    private var terminal: some View {
        TerminalHost(target: tab.view, focus: focus)
            .overlay(alignment: .topTrailing) {
                if !tab.running && !tab.overlayDismissed {
                    DisconnectBanner(tab: tab).padding(12)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeOut(duration: 0.2), value: tab.overlayDismissed)
    }
}

// MARK: - Stavový řádek

struct StatusBar: View {
    @ObservedObject var tab: TerminalTab
    @EnvironmentObject private var tabs: TabManager

    private var context: String {
        switch tab.kind {
        case .ssh: return "\(tab.session.group) / \(tabs.displayTitle(tab))"
        case .sftp: return "SFTP · \(tab.session.group) / \(tab.session.displayName)"
        case .local: return "Lokální / \(tab.subtitle)"
        case .serial: return "Sériová / \(tab.session.host)"
        }
    }

    private func duration(_ now: Date) -> String {
        let end = tab.endedAt ?? now
        let s = max(0, Int(end.timeIntervalSince(tab.startedAt)))
        return s >= 3600 ? "\(s / 3600) h \(s % 3600 / 60) min" : s >= 60 ? "\(s / 60) min \(s % 60) s" : "\(s) s"
    }

    private var sep: some View { Rectangle().fill(UI.border).frame(width: 1, height: 12) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 10) {
                Button { if !tab.running { tabs.reconnect(tab.id) } } label: {
                    HStack(spacing: 5) {
                        StatusDot(color: tab.state.color)
                        Text(tab.state.label).foregroundStyle(tab.state == .connected ? UI.ok : tab.state.color)
                        if !tab.running {
                            Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(UI.accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.running ? tab.state.label : "Kliknutím znovu připojit (⌘R)")
                sep
                Text(context).lineLimit(1)
                EnvBadge(tag: tab.session.envTag)
                if tab.kind == .ssh || tab.kind == .sftp {
                    sep
                    Text(tab.session.host).font(.system(size: 11, design: .monospaced))
                }
                sep
                Text(tab.running ? duration(ctx.date) : "Poslední relace: \(duration(ctx.date))")
                if tab.running, let probe = tab.latency { sep; LatencyLabel(probe: probe) }
                if tab.running, tab.kind == .ssh, !tab.forwards.isEmpty {
                    sep
                    Button { tabs.tunnelsTab = tab } label: {
                        Label("\(tab.forwards.count)", systemImage: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.plain)
                    .help("Tunely:\n" + tab.forwards.map { $0.label + ($0.note.isEmpty ? "" : "  – " + $0.note) }.joined(separator: "\n"))
                }
                if let live = tabs.liveCapture { sep; LiveCaptureBadge(capture: live) }
                if tab.running, let mon = tab.monitor {
                    sep
                    MonitorLabel(monitor: mon)
                        .contextMenu { Button("Vypnout monitor") { tab.stopMonitor() } }
                } else if tab.canMonitor {
                    sep
                    Button { tab.startMonitor() } label: { Label("Monitor", systemImage: "chart.bar") }
                        .buttonStyle(.plain)
                        .help("Zobrazit CPU, RAM a disk serveru (Linux / Gaia s bash). Čte /proc přes stejné SSH spojení, nic nemění.")
                }
                if tabs.broadcast {
                    sep
                    Label("Broadcast · \(tabs.broadcastTargets.count)", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(UI.error)
                }
                Spacer()
                if tabs.focusMode {
                    Button { tabs.toggleFocus() } label: { Label("Soustředění", systemImage: "arrow.down.right.and.arrow.up.left") }
                        .buttonStyle(.plain).foregroundStyle(UI.accent).help("Ukončit režim soustředění (⌥⌘F)")
                    sep
                }
                Text("UTF-8")
                sep
                let d = tab.view.terminalDimensions
                Text("\(d.cols)×\(d.rows)")
                sep
                Button { tabs.showPicker = true } label: {
                    HStack(spacing: 5) { KeyHint(text: "⌘K"); Text("Paleta") }
                }
                .buttonStyle(.plain)
                sep
                SettingsButton()
            }
            .font(.system(size: 11))
            .foregroundStyle(UI.textStatus)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(UI.statusBar)
        }
    }
}

struct LatencyLabel: View {
    @ObservedObject var probe: LatencyProbe
    var body: some View {
        if let ms = probe.ms {
            Text("\(max(1, Int(ms.rounded()))) ms")
                .foregroundStyle(ms > 150 ? UI.connecting : UI.textStatus)
                .help("Latence ICMP (ping) k serveru")
        } else {
            Text(probe.failed ? "ICMP –" : "… ms")
                .help(probe.failed ? "Server neodpovídá na ping (ICMP může být blokované – SSH tím není ovlivněno)" : "Měřím…")
        }
    }
}

struct SettingsButton: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.plain)
                .help("Nastavení (⌘,)")
        } else {
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: { Image(systemName: "gearshape") }
            .buttonStyle(.plain)
            .help("Nastavení (⌘,)")
        }
    }
}

// MARK: - Latence (ICMP ping – neovlivňuje SSH relaci ani nevytváří záznamy v logu sshd)

final class LatencyProbe: ObservableObject, @unchecked Sendable {
    @Published var ms: Double?
    @Published var failed = false
    private let host: String
    private var timer: Timer?

    init(host: String) {
        self.host = host
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }

    private func tick() {
        let h = host
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = LatencyProbe.ping(h)
            DispatchQueue.main.async {
                guard let self else { return }
                let rounded = r.map { ($0 * 10).rounded() / 10 }
                if self.ms != rounded { self.ms = rounded }
                if self.failed != (r == nil) { self.failed = (r == nil) }
            }
        }
    }

    static func ping(_ host: String) -> Double? {
        guard !host.hasPrefix("-") else { return nil }      // host nesmí být vyložen jako volba pingu
        let p = Process()
        let v6 = host.contains(":")
        p.executableURL = URL(fileURLWithPath: v6 ? "/sbin/ping6" : "/sbin/ping")
        p.arguments = v6 ? ["-c", "1", host] : ["-c", "1", "-t", "2", "-n", host]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        // pojistka: ping bez odpovědi ukončit po 3 s
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self)
        guard let r = s.range(of: #"time[=<]\s*([0-9.]+)"#, options: .regularExpression) else { return nil }
        let num = s[r].split(whereSeparator: { $0 == "=" || $0 == "<" }).last?.trimmingCharacters(in: .whitespaces)
        return num.flatMap(Double.init)
    }
}

// MARK: - Okno bez titulkové lišty

/// Prázdné místo lišty, za které jde okno táhnout (titulková lišta je skrytá).
struct WindowDragHandle: NSViewRepresentable {
    var onDoubleClick: (() -> Void)? = nil
    final class DragView: NSView {
        var onDoubleClick: (() -> Void)?
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                if let onDoubleClick { onDoubleClick() } else { window?.zoom(nil) }
            } else { window?.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> NSView { let v = DragView(); v.onDoubleClick = onDoubleClick; return v }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? DragView)?.onDoubleClick = onDoubleClick }
}

/// Kontejner terminálu s vnitřním okrajem 14 × 10 px. Okraj je řešen rámcem terminálového view,
/// takže SwiftTerm počítá sloupce/řádky (a velikost vzdáleného PTY) z plochy bez okrajů.
final class PaddedHost: NSView {
    static let padX: CGFloat = 14
    static let padY: CGFloat = 10

    /// Pořadí vzniku: při přepnutí rozložení (vedle sebe ↔ pod sebou) vzniká nový host dřív, než starý
    /// zmizí. Terminál si smí vzít jen novější host – dřív si ho starý (mizející) host vzal zpět
    /// a terminál zůstal prázdný, dokud se nepřekliklo.
    nonisolated(unsafe) private static var counter = 0
    nonisolated(unsafe) private static let all = NSHashTable<PaddedHost>.weakObjects()
    let generation: Int
    private weak var wanted: NSView?
    private var wantsFocus = false

    override init(frame: NSRect) {
        PaddedHost.counter += 1
        generation = PaddedHost.counter
        super.init(frame: frame)
        PaddedHost.all.add(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) není podporováno") }

    func claim(_ target: NSView, focus: Bool) {
        wanted = target
        wantsFocus = focus
        var released = false
        for s in subviews where s !== target { s.removeFromSuperview(); released = true }
        attachIfAllowed()
        // uvolněný terminál si může vzít jiný panel (např. prohození panelů)
        if released { for h in PaddedHost.all.allObjects where h !== self { h.attachIfAllowed() } }
    }

    private func attachIfAllowed() {
        guard let target = wanted else { return }
        if target.superview !== self {
            // jiný (novější) host v okně, který terminál pořád chce → nechat mu ho
            if let other = target.superview as? PaddedHost, other.window != nil,
               other.wanted === target, other.generation > generation { return }
            if window == nil, target.window != nil { return }      // nejsem v okně – nekrást
            target.removeFromSuperview()
            target.autoresizingMask = []
            addSubview(target)
            place()
            target.needsLayout = true
            target.needsDisplay = true
        }
        guard wantsFocus, let w = window, w.firstResponder !== target else { return }
        DispatchQueue.main.async { [weak target] in
            guard let target, let w = target.window, w.firstResponder !== target else { return }
            w.makeFirstResponder(target)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { attachIfAllowed() }       // nový host se dostal do okna → převezmi terminál
    }

    func place() {
        let r = bounds.insetBy(dx: Self.padX, dy: Self.padY)
        for s in subviews { s.frame = (r.width > 40 && r.height > 40) ? r : bounds }
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) { place() }
    override func layout() {
        super.layout()
        place()
        for s in subviews { s.needsDisplay = true }   // po změně rozložení překreslit obsah
    }
}
