import AppKit
import Darwin

// Ochrana proti spuštění souboru ze serveru na Macu:
//  • stažené soubory dostanou karanténu macOS (jako ze Safari/Chrome) → Gatekeeper je při otevření zkontroluje,
//  • spustitelné typy (.command, .app, .pkg, .jar…) se neotevřou výchozí aplikací bez potvrzení.

extension Quarantine {
    /// Označí stažené položky karanténou (u složky i vše uvnitř). Nic nemaže ani nemění obsah.
    static func mark(_ root: URL, agent: String = "SSHTool") {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else { return }
        var paths = [root.path]
        if isDir.boolValue, let e = fm.enumerator(atPath: root.path) {
            for case let rel as String in e { paths.append(root.path + "/" + rel) }
        }
        // formát: příznaky;čas (hex);agent;UUID – 0081 = staženo, dosud neotevřeno
        let value = "0081;" + String(Int(Date().timeIntervalSince1970), radix: 16) + ";" + agent + ";" + UUID().uuidString
        for p in paths where !has(p) {
            _ = value.withCString { setxattr(p, attr, $0, strlen($0), 0, XATTR_NOFOLLOW) }
        }
    }
}

@MainActor
enum SafeOpen {
    /// Typy, které výchozí aplikace macOS spouští nebo instaluje (ne jen zobrazí).
    static let riskyExtensions: Set<String> = [
        "command", "tool", "terminal", "app", "pkg", "mpkg", "dmg", "jar", "jnlp",
        "scpt", "scptd", "applescript", "workflow", "action", "shortcut",
        "fileloc", "webloc", "inetloc", "url", "prefpane", "kext", "plugin", "osax", "bundle", "mobileconfig",
        "sh", "bash", "zsh", "csh", "ksh", "py", "pyw", "pl", "rb", "php", "js", "jxa",
        "exe", "msi", "bat", "cmd", "ps1", "vbs",
    ]

    static func isRisky(name: String) -> Bool {
        riskyExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Spustitelný typ podle přípony, nebo soubor bez přípony s právem spuštění (Finder by ho pustil v Terminálu).
    static func isRisky(_ url: URL) -> Bool {
        if isRisky(name: url.lastPathComponent) { return true }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && !isDir.boolValue && url.pathExtension.isEmpty && FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// Dotaz u spustitelného typu. allowDefault = nabídnout i otevření výchozí aplikací.
    /// Vrací "text", "default", nebo nil (zrušeno).
    static func confirm(_ name: String, allowDefault: Bool) -> String? {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "„\(name)“ je spustitelný typ souboru"
        a.informativeText = "Výchozí aplikace by ho mohla spustit nebo nainstalovat (např. .command v Terminálu). "
            + "Soubor pochází ze serveru – pokud si nejsi jistý obsahem, otevři ho jen jako text."
        a.addButton(withTitle: "Otevřít jako text")
        if allowDefault { a.addButton(withTitle: "Otevřít výchozí aplikací") }
        a.addButton(withTitle: "Zrušit")
        switch a.runModal() {
        case .alertFirstButtonReturn: return "text"
        case .alertSecondButtonReturn: return allowDefault ? "default" : nil
        default: return nil
        }
    }

    static func openAsText(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", url.path]
        try? p.run()
    }

    /// Otevření souboru z prohlížeče souborů (dvojklik v panelu Mac).
    static func open(_ url: URL) {
        guard isRisky(url) else { NSWorkspace.shared.open(url); return }
        switch confirm(url.lastPathComponent, allowDefault: true) {
        case "text": openAsText(url)
        case "default": NSWorkspace.shared.open(url)      // s karanténou ho ještě zkontroluje Gatekeeper
        default: break
        }
    }

    /// Pracovní kopie pro úpravy: spustitelný typ jen jako text, ostatní výchozím editorem (jinak TextEdit).
    static func openForEditing(_ url: URL) {
        if isRisky(name: url.lastPathComponent) { openAsText(url); return }
        if !NSWorkspace.shared.open(url) { openAsText(url) }
    }
}
