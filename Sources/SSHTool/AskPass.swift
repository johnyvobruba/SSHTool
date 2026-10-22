import Foundation
import AppKit
import Darwin

extension ProcessInfo {
    /// Prostředí pro spouštěné procesy bez DYLD_* (vložení knihoven do ssh / FreeRDP, které dostávají heslo).
    static var sanitizedEnvironment: [String: String] {
        processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
    }
}

enum AskPass {
    static func run(sessionID: String, prompt: String) -> Never {
        // Heslo vydáme jen ssh, které spustila běžící aplikace SSHTool (ne libovolný proces s SSHTOOL_SESSION_ID).
        guard calledFromSSHTool() else {
            FileHandle.standardError.write(Data("sshtool: askpass odmítnut – nevolá ho ssh spuštěné z SSHTool\n".utf8))
            exit(1)
        }
        let p = prompt.lowercased()
        // Neznámý klíč serveru (StrictHostKeyChecking=ask): zeptat se uživatele dialogem s otiskem.
        // Dřív se kvůli askpass používalo accept-new = tichý souhlas → MITM při prvním připojení.
        if p.contains("continue connecting") || p.contains("authenticity of host") {
            let ok = confirmHostKey(prompt)
            FileHandle.standardOutput.write(Data((ok ? "yes\n" : "no\n").utf8))
            exit(ok ? 0 : 1)
        }
        // Odpovídáme jen na dotaz na heslo/passphrase. Cokoliv jiného (yes/no apod.) odmítneme.
        guard p.contains("password") || p.contains("passphrase") else {
            FileHandle.standardError.write(Data("sshtool: neznámý askpass dotaz: \(prompt)\n".utf8))
            exit(1)
        }
        // Session s ochranou: před vydáním hesla Touch ID / heslo macOS.
        // Chrání i proti tomu, že binárku v režimu askpass spustí jiný program – uvidíš nečekaný dialog a zrušíš ho.
        if KeychainStore.requiresAuth(for: sessionID) {
            let target = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard UserAuth.authenticate(reason: "použít uložené heslo SSHTool (\(target))") else {
                FileHandle.standardError.write(Data("sshtool: ověření Touch ID / heslem Macu zrušeno nebo selhalo\n".utf8))
                exit(1)
            }
        }
        guard let secret = KeychainStore.password(for: sessionID) else { exit(1) }
        FileHandle.standardOutput.write(Data((secret + "\n").utf8))
        exit(0)
    }

    // MARK: Ověření volajícího

    private static func path(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))     // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// Řetězec rodičů: askpass ← ssh (← ssh u jump hostu …) ← hlavní aplikace SSHTool (stejná binárka).
    static func calledFromSSHTool() -> Bool {
        guard let me = path(of: getpid()) else { return false }
        var pid = getppid()
        guard let first = path(of: pid), (first as NSString).lastPathComponent == "ssh" else { return false }
        for _ in 0..<6 {
            guard let pp = parent(of: pid), pp > 1, let p = path(of: pp) else { return false }
            if (p as NSString).lastPathComponent == "ssh" { pid = pp; continue }    // ProxyJump: ssh pod ssh
            return p == me && pp != getpid()
        }
        return false
    }

    /// Dialog „neznámý klíč serveru“ – výchozí volba je Odmítnout.
    private static func confirmHostKey(_ prompt: String) -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        let text = prompt
            .replacingOccurrences(of: "Are you sure you want to continue connecting (yes/no/[fingerprint])?", with: "")
            .replacingOccurrences(of: "Are you sure you want to continue connecting (yes/no)?", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "SSHTool: neznámý klíč serveru"
        a.informativeText = text + "\n\nPřipojuješ se k serveru poprvé (nebo nemá záznam v known_hosts). "
            + "Ověř otisk SHA256 se správcem nebo na konzoli zařízení (např. ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub). "
            + "Přijmi jen při shodě – jinak může jít o útok typu man-in-the-middle."
        a.addButton(withTitle: "Odmítnout")
        a.addButton(withTitle: "Přijmout a uložit")
        a.window.level = .floating
        return a.runModal() == .alertSecondButtonReturn
    }
}
