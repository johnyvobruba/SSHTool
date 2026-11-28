import Foundation
import Darwin

/// Lokální terminál: když v něm spustíš `ssh …` (i přes alias nebo z historie), uloží se server do složky
/// „Nezařazené“ – jen pokud ho ještě nemáš uložený (shoda server + port + uživatel) a není v koši.
/// Sleduje procesy spuštěné z lokálního shellu (každé 2 s), nic nečte z klávesnice ani z výstupu terminálu.
/// Ukládá jen uživatele, server, port, klíč (-i) a jump host (-J) – žádná hesla ani další volby (-o).
@MainActor
final class LocalSSHCapture {
    nonisolated static let group = "Nezařazené"
    nonisolated static let settingKey = "SSHTool.captureLocalSSH"
    static var enabled: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }

    private let shellPid: pid_t
    private var timer: Timer?
    private var seen = Set<pid_t>()

    init(shellPid: pid_t) {
        self.shellPid = shellPid
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard kill(shellPid, 0) == 0 else { stop(); return }
        guard Self.enabled else { return }
        for pid in Self.descendants(of: shellPid, depth: 3) where !seen.contains(pid) {
            guard let argv = Self.arguments(pid), let exe = argv.first,
                  (exe as NSString).lastPathComponent == "ssh" else { continue }
            seen.insert(pid)
            if let t = Self.parse(Array(argv.dropFirst())) { Self.save(t) }
        }
        if seen.count > 1000 { seen.removeAll() }
    }

    // MARK: Procesy

    nonisolated static func children(_ pid: pid_t) -> [pid_t] {
        var buf = [pid_t](repeating: 0, count: 256)
        let got = proc_listchildpids(pid, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }
        // podle verze macOS vrací počet PID nebo počet bajtů
        let n = Int(got) <= buf.count ? Int(got) : Int(got) / MemoryLayout<pid_t>.size
        return buf.prefix(min(n, buf.count)).filter { $0 > 0 }
    }

    nonisolated static func descendants(of pid: pid_t, depth: Int) -> [pid_t] {
        guard depth > 0 else { return [] }
        return children(pid).flatMap { [$0] + descendants(of: $0, depth: depth - 1) }
    }

    /// Argumenty procesu (KERN_PROCARGS2) – jde jen u vlastních procesů uživatele.
    nonisolated static func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        guard argc > 0, argc < 4096 else { return nil }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }          // cesta ke spustitelnému souboru
        while i < size && buf[i] == 0 { i += 1 }          // zarovnání
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args.count == argc ? args : nil
    }

    // MARK: Argumenty ssh

    struct Target: Equatable { var host: String; var user: String; var port: Int; var identity: String; var jump: String }

    /// `ssh [volby] [user@]host [příkaz]` → cíl. nil = nejde o přihlášení na server (ssh -V, -O, -Q, -W, git…).
    nonisolated static func parse(_ a: [String]) -> Target? {
        let withArg: Set<Character> = Set("BbcDEeFIiJLlmOoPpQRSWw")
        var user = "", port = 22, identity = "", jump = "", userFromOption = false
        var dest: String?
        var i = 0
        func opt(_ c: Character, _ v: String) -> Bool {
            switch c {
            case "l": user = v; userFromOption = true
            case "p": port = Int(v) ?? port
            case "i": identity = v
            case "J": jump = v
            case "o":
                let parts = v.split(maxSplits: 1, whereSeparator: { $0 == "=" || $0 == " " }).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { break }
                switch parts[0].lowercased() {
                case "user": user = parts[1]; userFromOption = true
                case "port": port = Int(parts[1]) ?? port
                case "identityfile": identity = parts[1]
                case "proxyjump": jump = parts[1]
                default: break
                }
            case "O", "Q", "W": return false            // řízení masteru, dotaz, stdio forward
            default: break
            }
            return true
        }
        while i < a.count {
            let s = a[i]
            if s == "--" { i += 1; dest = i < a.count ? a[i] : nil; break }
            if s.hasPrefix("-"), s.count > 1 {
                let chars = Array(s.dropFirst())
                var j = 0
                while j < chars.count {
                    let c = chars[j]
                    if c == "V" || c == "G" { return nil }   // verze / výpis konfigurace
                    if withArg.contains(c) {
                        var v = String(chars[(j + 1)...])
                        if v.isEmpty { i += 1; guard i < a.count else { return nil }; v = a[i] }
                        if !opt(c, v) { return nil }
                        break
                    }
                    j += 1
                }
                i += 1
                continue
            }
            dest = s
            break
        }
        guard var d = dest?.trimmingCharacters(in: .whitespaces), !d.isEmpty else { return nil }
        let command = a.dropFirst(i + 1).joined(separator: " ").lowercased()
        if command.contains("git-upload") || command.contains("git-receive") || command.contains("git-lfs") { return nil }
        if d.lowercased().hasPrefix("ssh://") {
            d = String(d.dropFirst(6))
            if let slash = d.firstIndex(of: "/") { d = String(d[..<slash]) }
            if let colon = d.lastIndex(of: ":"), !d.contains("["), let p = Int(d[d.index(after: colon)...]) {
                port = p; d = String(d[..<colon])
            }
        }
        if let at = d.lastIndex(of: "@") {
            if !userFromOption { user = String(d[..<at]) }
            d = String(d[d.index(after: at)...])
        }
        d = d.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard d.range(of: #"^[A-Za-z0-9._:%-]+$"#, options: .regularExpression) != nil,
              !["localhost", "127.0.0.1", "::1"].contains(d.lowercased()) else { return nil }
        return Target(host: d, user: user, port: port, identity: identity, jump: jump)
    }

    // MARK: Uložení

    static func save(_ t: Target) {
        guard let store = AppStore.shared else { return }
        let h = t.host.lowercased()
        func same(_ s: SSHSession) -> Bool {
            s.proto == "ssh" && s.host.lowercased() == h && s.port == t.port
                && (s.user.isEmpty || t.user.isEmpty || s.user == t.user)
        }
        // už uložený, nebo ho uživatel smazal (koš) → nic
        guard !store.sessions.contains(where: same), !store.trash.contains(where: { same($0.session) }) else { return }
        var s = SSHSession(name: t.user.isEmpty ? t.host : "\(t.user)@\(t.host)", host: t.host, group: group, colorHex: "#8E8E93")
        s.port = t.port
        s.user = t.user
        if !t.identity.isEmpty { s.identityFile = t.identity; s.auth = .key }
        s.jumpHost = t.jump
        let df = DateFormatter(); df.dateFormat = "d. M. yyyy HH:mm"
        s.notes = "Uloženo automaticky z lokálního terminálu \(df.string(from: Date()))."
        store.sessions.append(s)
    }
}
