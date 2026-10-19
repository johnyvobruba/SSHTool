import Foundation
import AppKit
import UniformTypeIdentifiers

/// Pomocné funkce pro SSH klíče a agenty (výběr klíče, Bitwarden agent, kopírování veřejného klíče).
enum SSHKeys {
    static var sshDir: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh", isDirectory: true) }

    /// Známé cesty socketu SSH agenta Bitwardenu (verze z webu / z App Store).
    static let bitwardenSockets = ["~/.bitwarden-ssh-agent.sock",
                                   "~/Library/Containers/com.bitwarden.desktop/Data/.bitwarden-ssh-agent.sock"]

    static func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }

    /// První existující socket Bitwardenu (nebo první kandidát, když žádný neexistuje).
    static var bitwardenSocket: String {
        bitwardenSockets.map(expand).first { FileManager.default.fileExists(atPath: $0) } ?? expand(bitwardenSockets[0])
    }

    /// Soukromé klíče v ~/.ssh = soubory, ke kterým existuje <název>.pub.
    static func listPrivateKeys() -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: sshDir.path) else { return [] }
        return names.filter { n in
            !n.hasSuffix(".pub") && names.contains(n + ".pub")
        }.sorted()
    }

    static func pickKeyFile() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Vyber soukromý SSH klíč"
        panel.directoryURL = sshDir
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// Zkopíruje <klíč>.pub do schránky (pro vložení do authorized_keys na zařízení).
    static func copyPublicKey(ofPrivateKey path: String) {
        let pub = expand(path) + ".pub"
        guard let text = try? String(contentsOfFile: pub, encoding: .utf8) else {
            info("Veřejný klíč nenalezen", "Soubor \(pub) neexistuje.")
            return
        }
        copy(text.trimmingCharacters(in: .whitespacesAndNewlines))
        info("Veřejný klíč zkopírován", "Obsah \((pub as NSString).abbreviatingWithTildeInPath) je ve schránce.")
    }

    /// `ssh-add -L` proti zvolenému agentovi → veřejné klíče do schránky.
    static func copyAgentPublicKeys(socket: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        p.arguments = ["-L"]
        var env = ProcessInfo.processInfo.environment
        if let socket { env["SSH_AUTH_SOCK"] = socket }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch {
            info("ssh-add selhal", error.localizedDescription); return
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0, !text.isEmpty else {
            info("Agent nevrátil žádné klíče",
                 "Agent neběží, je zamčený, nebo v něm nejsou klíče. (Bitwarden: odemkni trezor a zapni SSH agenta v nastavení aplikace.)")
            return
        }
        copy(text)
        let n = text.split(separator: "\n").count
        info("Veřejné klíče zkopírovány", "\(n) klíč(e) z agenta je ve schránce.")
    }

    private static func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    private static func info(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
