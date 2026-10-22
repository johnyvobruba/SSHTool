import Foundation
import SwiftUI
import AppKit

// MARK: - Nastavení aplikace (settings.json)

struct AppSettings: Codable, Equatable {
    var copyOnSelect = true          // označený text → automaticky do schránky
    var rightClickPaste = true       // pravé tlačítko → vložit ze schránky
    var logEnabled = false           // logovat automaticky každou novou záložku
    var logDirectory = "~/Documents/SSHTool-logs"
    var logPlainText = true          // bez ANSI escape kódů
    var scrollback = 20_000          // počet řádků historie terminálu (SwiftTerm výchozí: 500)
    var fontSize: Double = 13        // velikost písma terminálu (⌘+ / ⌘- / ⌥⌘ + dva prsty)
    var serialBaud: [String: Int] = [:]   // poslední rychlost pro každý sériový port (/dev/cu.*)
    var collapsedGroups: [String] = []    // sbalené skupiny v levém panelu
    var fontName = ""                     // "" = SF Mono (systémové neproporcionální), jinak PostScript název
    var lineSpacing: Double = 1.15        // násobek výšky řádku (rozsah 1,0–1,5, krok 0,05)
    var highlightEnabled = true           // automatické zvýrazňování výstupu (ANSI barvy serveru zůstávají vždy)
    var sidebarComfortable = false        // levý panel: false = kompaktní (1 řádek), true = 2 řádky (název / IP)
    var latencyEnabled = true             // latence ve stavovém řádku (ICMP ping každých 10 s)
    var themeID = "midnight"              // barevný profil aplikace
    var appearance = "dark"               // dark | light | system
    var terminalFollowsApp = true
    var terminalThemeID = "midnight"
    var showFavorites = true
    var disabledRuleGroups: [String] = [] // vypnuté skupiny pravidel zvýraznění
    var logMaxMB = 0                      // 0 = bez limitu, jinak rotace logu po N MB
    var logRetentionDays = 30             // logy starší než N dní se při spuštění smažou (0 = neomezeně)
    var optionAsMeta = false              // false: ⌥ píše znaky macOS (⌥2 = @), true: ⌥ = Meta/Esc
    var groupColors: [String: String] = [:]   // ruční barvy skupin (jinak automatická z názvu)
    var focusShowStatus = true            // režim soustředění: ponechat stavový řádek
    var monitorAuto = false               // monitor CPU/RAM/disk spouštět automaticky po přihlášení
    var autoUpdateCheck = true            // kontrolovat nové verze na GitHubu při spuštění
    var folders: [String] = []            // složky (i prázdné) – cesty „A/B/C“
    var freerdpPath = ""                  // "" = automaticky (Homebrew), jinak cesta ke klientovi FreeRDP

    /// Volitelná písma terminálu – v nastavení se nabídnou jen nainstalovaná.
    static let fontChoices: [(name: String, label: String)] = [
        ("", "SF Mono (systémové)"), ("JetBrainsMono-Regular", "JetBrains Mono"),
        ("GeistMono-Regular", "Geist Mono"), ("BerkeleyMono-Regular", "Berkeley Mono"),
        ("Menlo-Regular", "Menlo"), ("Monaco", "Monaco"),
    ]

    static let fontSizeRange: ClosedRange<Double> = 8...36
    static let fontSizeChanged = Notification.Name("SSHToolFontSizeChanged")

    static let scrollbackChoices = [5_000, 10_000, 20_000, 50_000, 100_000]
    static let scrollbackChanged = Notification.Name("SSHToolScrollbackChanged")

    enum CodingKeys: String, CodingKey {
        case copyOnSelect, rightClickPaste, logEnabled, logDirectory, logPlainText, scrollback, fontSize, serialBaud, collapsedGroups,
             fontName, lineSpacing, highlightEnabled, sidebarComfortable, latencyEnabled,
             themeID, appearance, terminalFollowsApp, terminalThemeID, showFavorites, disabledRuleGroups, logMaxMB, logRetentionDays, optionAsMeta, groupColors, focusShowStatus, monitorAuto, autoUpdateCheck, folders, freerdpPath
    }

    var logDirectoryURL: URL {
        URL(fileURLWithPath: (logDirectory as NSString).expandingTildeInPath, isDirectory: true)
    }
}

extension AppSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        copyOnSelect = try c.decodeIfPresent(Bool.self, forKey: .copyOnSelect) ?? d.copyOnSelect
        rightClickPaste = try c.decodeIfPresent(Bool.self, forKey: .rightClickPaste) ?? d.rightClickPaste
        logEnabled = try c.decodeIfPresent(Bool.self, forKey: .logEnabled) ?? d.logEnabled
        logDirectory = try c.decodeIfPresent(String.self, forKey: .logDirectory) ?? d.logDirectory
        logPlainText = try c.decodeIfPresent(Bool.self, forKey: .logPlainText) ?? d.logPlainText
        scrollback = try c.decodeIfPresent(Int.self, forKey: .scrollback) ?? d.scrollback
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        serialBaud = try c.decodeIfPresent([String: Int].self, forKey: .serialBaud) ?? d.serialBaud
        collapsedGroups = try c.decodeIfPresent([String].self, forKey: .collapsedGroups) ?? d.collapsedGroups
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? d.fontName
        lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? d.lineSpacing
        highlightEnabled = try c.decodeIfPresent(Bool.self, forKey: .highlightEnabled) ?? d.highlightEnabled
        sidebarComfortable = try c.decodeIfPresent(Bool.self, forKey: .sidebarComfortable) ?? d.sidebarComfortable
        latencyEnabled = try c.decodeIfPresent(Bool.self, forKey: .latencyEnabled) ?? d.latencyEnabled
        themeID = try c.decodeIfPresent(String.self, forKey: .themeID) ?? d.themeID
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? d.appearance
        terminalFollowsApp = try c.decodeIfPresent(Bool.self, forKey: .terminalFollowsApp) ?? d.terminalFollowsApp
        terminalThemeID = try c.decodeIfPresent(String.self, forKey: .terminalThemeID) ?? d.terminalThemeID
        showFavorites = try c.decodeIfPresent(Bool.self, forKey: .showFavorites) ?? d.showFavorites
        disabledRuleGroups = try c.decodeIfPresent([String].self, forKey: .disabledRuleGroups) ?? d.disabledRuleGroups
        logMaxMB = try c.decodeIfPresent(Int.self, forKey: .logMaxMB) ?? d.logMaxMB
        let keep = try c.decodeIfPresent(Int.self, forKey: .logRetentionDays) ?? d.logRetentionDays
        logRetentionDays = max(0, keep)
        optionAsMeta = try c.decodeIfPresent(Bool.self, forKey: .optionAsMeta) ?? d.optionAsMeta
        groupColors = try c.decodeIfPresent([String: String].self, forKey: .groupColors) ?? d.groupColors
        focusShowStatus = try c.decodeIfPresent(Bool.self, forKey: .focusShowStatus) ?? d.focusShowStatus
        monitorAuto = try c.decodeIfPresent(Bool.self, forKey: .monitorAuto) ?? d.monitorAuto
        autoUpdateCheck = try c.decodeIfPresent(Bool.self, forKey: .autoUpdateCheck) ?? d.autoUpdateCheck
        folders = try c.decodeIfPresent([String].self, forKey: .folders) ?? d.folders
        freerdpPath = try c.decodeIfPresent(String.self, forKey: .freerdpPath) ?? d.freerdpPath
    }
}

/// Aktuální nastavení dostupné i mimo SwiftUI (terminálové view). Plní ho AppStore.
@MainActor
enum Prefs {
    static var current = AppSettings()
}

// MARK: - Zoom písma: ⌥⌘ + posun dvěma prsty (nahoru = větší, dolů = menší)

/// SwiftTerm má scrollWheel jako `public` (ne `open`), nejde přepsat v podtřídě →
/// gesto zachytává lokální monitor událostí aplikace. Bez ⌥⌘ se událost předá dál beze změny.
final class ZoomGesture: @unchecked Sendable {
    static let shared = ZoomGesture()
    private var monitor: Any?
    private var accumulator: CGFloat = 0
    private let stepPoints: CGFloat = 14      // kolik bodů posunu trackpadu = 1 pt písma

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            ZoomGesture.shared.handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command), mods.contains(.option) else {
            accumulator = 0
            return event
        }
        if event.phase == .began { accumulator = 0 }
        guard event.momentumPhase.isEmpty else { return nil }     // setrvačnost ignorovat
        // fyzický směr prstů: + = nahoru (nezávisle na „přirozeném posouvání“)
        // přirozené posouvání: prsty nahoru → scrollingDeltaY < 0; klasické: prsty nahoru → > 0
        let dy = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        var steps = 0
        if event.hasPreciseScrollingDeltas {
            accumulator += dy
            while abs(accumulator) >= stepPoints {
                steps += accumulator > 0 ? 1 : -1
                accumulator -= accumulator > 0 ? stepPoints : -stepPoints
            }
        } else if dy != 0 {
            steps = dy > 0 ? 1 : -1                                  // kolečko myši: 1 krok
        }
        if steps != 0 {
            let s = steps
            Task { @MainActor in AppStore.shared?.changeFontSize(by: Double(s)) }
        }
        return nil                                                  // spotřebováno, terminál nescrolluje
    }
}

// MARK: - Logování výstupu session do souboru

/// Zapisuje výstup ssh/sftp/shellu do souboru (soubor 0600, složka 0700).
/// Ukládá výstup ze serveru *před* zvýrazněním – v logu tedy nejsou barvy přidané SSHToolem.
final class SessionLogger: @unchecked Sendable {
    private(set) var url: URL
    private var handle: FileHandle
    private let plain: Bool
    private let lock = NSLock()
    private var state = 0          // 0 text, 1 ESC, 2 CSI, 3 OSC/DCS, 4 ESC v OSC, 5 ESC ( X
    private var closed = false
    private var written = 0
    private let maxBytes: Int
    private let baseURL: URL
    private var part = 1

    init?(settings: AppSettings, session: SSHSession, kind: TabKind) {
        let dir = settings.logDirectoryURL
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let safe = session.name.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "_", options: .regularExpression)
        let suffix = kind == .sftp ? "_sftp" : (kind == .local ? "_local" : "")
        url = dir.appendingPathComponent("\(df.string(from: Date()))_\(safe)\(suffix).log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]),
              let h = try? FileHandle(forWritingTo: url) else { return nil }
        handle = h
        baseURL = url
        maxBytes = max(0, settings.logMaxMB) * 1_048_576
        plain = settings.logPlainText
        let target = kind == .local ? "localhost" : (session.user.isEmpty ? session.host : "\(session.user)@\(session.host)")
        writeLine("=== SSHTool log: \(session.name) [\(kind.rawValue)] \(target):\(session.port) – začátek \(Self.stamp()) ===")
    }

    deinit { close() }

    static func stamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: Date())
    }

    func write(_ bytes: ArraySlice<UInt8>) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        let out = plain ? strip(bytes) : Array(bytes)
        if !out.isEmpty {
            handle.write(Data(out))
            written += out.count
            if maxBytes > 0, written >= maxBytes { rotate() }
        }
    }

    /// Rotace: aktuální soubor uzavře a pokračuje do <název>_partN.log (nic se nemaže).
    private func rotate() {
        part += 1
        let next = baseURL.deletingPathExtension().path + "_part\(part).log"
        guard FileManager.default.createFile(atPath: next, contents: nil, attributes: [.posixPermissions: 0o600]),
              let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: next)) else { return }
        handle.write(Data("\n=== pokračuje v \((next as NSString).lastPathComponent) ===\n".utf8))
        try? handle.close()
        handle = h
        url = URL(fileURLWithPath: next)
        written = 0
        handle.write(Data("=== pokračování logu (část \(part)) \(Self.stamp()) ===\n".utf8))
    }

    func writeLine(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        handle.write(Data((s + "\n").utf8))
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        handle.write(Data("\n=== konec logu \(Self.stamp()) ===\n".utf8))
        try? handle.close()
        closed = true
    }

    /// Odstraní escape sekvence a řídicí znaky (stav drží i přes hranice chunků).
    private func strip(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        for b in bytes {
            switch state {
            case 0:
                switch b {
                case 0x1B: state = 1
                case 0x0D, 0x07, 0x7F: break                         // CR, BEL, DEL
                case 0x08: if let l = out.last, l < 0x80 { out.removeLast() }   // backspace
                case 0x0A, 0x09: out.append(b)
                case 0x00..<0x20: break
                default: out.append(b)
                }
            case 1:
                switch b {
                case 0x5B: state = 2                                    // CSI
                case 0x5D, 0x50, 0x5E, 0x5F: state = 3                  // OSC, DCS, PM, APC
                case 0x28...0x2B: state = 5
                default: state = 0
                }
            case 2: if (0x40...0x7E).contains(b) { state = 0 }
            case 3: if b == 0x07 { state = 0 } else if b == 0x1B { state = 4 }
            case 4: state = (b == 0x5C) ? 0 : 3
            default: state = 0
            }
        }
        return out
    }
}

// Okno nastavení: viz SettingsUI.swift

/// Retence logů: při spuštění smaže logy starší než nastavený počet dní.
/// Maže jen soubory, které vytvořil SSHTool (podle názvu), nic jiného ve složce logů.
enum LogRetention {
    static func prune(_ settings: AppSettings) {
        let days = settings.logRetentionDays
        guard days > 0 else { return }
        let limit = Date().addingTimeInterval(-Double(days) * 86_400)
        let fm = FileManager.default
        func old(_ url: URL) -> Bool {
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (d ?? Date()) < limit
        }
        // 1) logy relací: RRRR-MM-DD_HH-MM-SS_<server>[_sftp|_local][_partN].log
        let sessionRe = #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_.+\.log$"#
        if let items = try? fm.contentsOfDirectory(at: settings.logDirectoryURL, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for u in items where u.lastPathComponent.range(of: sessionRe, options: .regularExpression) != nil && old(u) {
                try? fm.removeItem(at: u)
            }
        }
        // 2) RDP logy: ~/Library/Logs/SSHTool/rdp-*.log
        let logs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SSHTool", isDirectory: true)
        if let items = try? fm.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for u in items where u.lastPathComponent.hasPrefix("rdp-") && u.pathExtension == "log" && old(u) {
                try? fm.removeItem(at: u)
            }
        }
        // 3) multisend.log: jeden soubor – ponechat jen záznamy mladší než limit (bloky „===== <ISO8601>“)
        let ms = logs.appendingPathComponent("multisend.log")
        guard let text = try? String(contentsOf: ms, encoding: .utf8) else { return }
        let iso = ISO8601DateFormatter()
        var kept: [String] = []
        for block in text.components(separatedBy: "===== ").dropFirst() {
            let stamp = String(block.prefix(while: { !$0.isWhitespace && $0 != "(" }))
            if let d = iso.date(from: stamp), d < limit { continue }
            kept.append("===== " + block)
        }
        let out = kept.joined()
        if out.count != text.count {
            try? out.write(to: ms, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ms.path)
        }
    }
}
