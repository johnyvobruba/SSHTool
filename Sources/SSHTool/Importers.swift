import Foundation
import UniformTypeIdentifiers

// Import serverů z jiných nástrojů. Hesla se nikdy neimportují (u mRemoteNG / RDCMan jsou šifrovaná klíčem
// původní aplikace). Výsledek prochází stejnou kontrolou jako import JSON (validace polí, odstranění rizikových voleb).
enum ServerImporter {
    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Typy souborů v dialogu importu.
    static var contentTypes: [UTType] {
        [.json, .xml, .commaSeparatedText, .plainText] + ["rdg", "rdp", "csv"].compactMap { UTType(filenameExtension: $0) }
    }

    static func load(_ urls: [URL]) throws -> [SSHSession] {
        var all: [SSHSession] = []
        for u in urls { all += try load(u) }
        return all
    }

    static func load(_ url: URL) throws -> [SSHSession] {
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        let base = url.deletingPathExtension().lastPathComponent
        switch ext {
        case "rdp": return [try rdpFile(data, name: base)]
        case "rdg": return try rdcman(data, file: base)
        case "csv": return try csv(data)
        case "xml": return try mremote(data)
        default:
            // JSON: nejdřív formát SSHTool, potom profily iTerm2
            if let a = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], a.first?["host"] != nil {
                return try JSONDecoder().decode([SSHSession].self, from: data)      // formát SSHTool – chyby s popisem
            }
            if let s = try iterm(data), !s.isEmpty { return s }
            if let txt = String(data: data, encoding: .utf8), txt.contains("<mrng:Connections") || txt.contains("<Connections") {
                return try mremote(data)
            }
            throw ImportError(message: "Nerozpoznaný formát souboru „\(url.lastPathComponent)“. Podporováno: JSON (SSHTool, iTerm2), RDCMan .rdg, mRemoteNG confCons.xml, CSV, .rdp.")
        }
    }

    private static func make(_ name: String, _ host: String, proto: String, port: Int?, user: String = "",
                              group: String, domain: String = "", notes: String = "") -> SSHSession {
        var s = SSHSession(name: name.isEmpty ? host : name, host: host)
        s.proto = proto
        s.port = port ?? (proto == "rdp" ? 3389 : proto == "telnet" ? 23 : 22)
        s.user = user
        s.group = group.isEmpty ? "Import" : group
        s.rdpDomain = domain
        s.notes = notes
        s.colorHex = ""
        s.auth = proto == "ssh" ? .agent : .password
        s.requireUserAuth = true
        return s
    }

    // MARK: .rdp (Microsoft Remote Desktop)

    static func rdpFile(_ data: Data, name: String) throws -> SSHSession {
        let text = String(data: data, encoding: .utf16LittleEndian) ?? String(data: data, encoding: .utf8) ?? ""
        var kv: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { continue }
            kv[parts[0].trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))] = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard var addr = kv["full address"], !addr.isEmpty else { throw ImportError(message: "Soubor \(name).rdp nemá „full address“.") }
        var port: Int?
        if !addr.hasPrefix("["), let i = addr.lastIndex(of: ":"), addr.filter({ $0 == ":" }).count == 1 {
            port = Int(addr[addr.index(after: i)...]); addr = String(addr[..<i])
        }
        var user = kv["username"] ?? "", domain = kv["domain"] ?? ""
        if let bs = user.firstIndex(of: "\\") { domain = String(user[..<bs]); user = String(user[user.index(after: bs)...]) }
        var s = make(name, addr, proto: "rdp", port: port, user: user, group: "Import/RDP", domain: domain)
        if let g = kv["gatewayhostname"], !g.isEmpty, kv["gatewayusagemethod"] != "0" { s.rdpGateway = g }
        if kv["screen mode id"] == "2" { s.rdpSize = "fullscreen" }
        else if let w = kv["desktopwidth"], let h = kv["desktopheight"], Int(w) != nil, Int(h) != nil { s.rdpSize = "\(w)x\(h)" }
        if kv["use multimon"] == "1" { s.rdpMultiMon = true }
        if kv["redirectclipboard"] == "0" { s.rdpClipboard = false }
        return s
    }

    // MARK: CSV (name, host, port, user, protocol, folder, domain, notes, environment)

    static func csv(_ data: Data) throws -> [SSHSession] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1250) else {
            throw ImportError(message: "CSV není v UTF-8 ani Windows-1250.")
        }
        let first = text.prefix { $0 != "\n" && $0 != "\r" }
        let sep: Character = first.filter { $0 == ";" }.count > first.filter { $0 == "," }.count ? ";" : ","
        let rows = parseCSV(text, sep: sep)
        guard let header = rows.first else { return [] }
        let h = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")) }
        func col(_ names: [String]) -> Int? { h.firstIndex { names.contains($0) } }
        guard let hostC = col(["host", "hostname", "address", "ip", "ip address", "adresa", "server"]) else {
            throw ImportError(message: "CSV musí mít sloupec host (také hostname / address / ip). Volitelně: name, port, user, protocol (ssh/rdp/telnet), folder, domain, notes, environment.")
        }
        let nameC = col(["name", "název", "nazev", "display name", "label"]), portC = col(["port"])
        let userC = col(["user", "username", "login", "uživatel"]), protoC = col(["protocol", "proto", "type", "protokol"])
        let groupC = col(["folder", "group", "path", "složka", "slozka"]), domC = col(["domain", "doména"])
        let notesC = col(["notes", "note", "description", "popis", "poznámka"]), envC = col(["environment", "env", "prostředí"])
        var out: [SSHSession] = []
        for r in rows.dropFirst() {
            func v(_ c: Int?) -> String { c.flatMap { $0 < r.count ? r[$0].trimmingCharacters(in: .whitespaces) : nil } ?? "" }
            let host = v(hostC)
            guard !host.isEmpty else { continue }
            var proto = v(protoC).lowercased()
            proto = proto.hasPrefix("rdp") ? "rdp" : proto.hasPrefix("telnet") ? "telnet" : "ssh"
            var s = make(v(nameC), host, proto: proto, port: Int(v(portC)), user: v(userC),
                         group: v(groupC).replacingOccurrences(of: "\\", with: "/"), domain: v(domC), notes: v(notesC))
            let env = v(envC).lowercased()
            if ["prod", "stage", "test", "dev"].contains(env) { s.environment = env; s.production = env == "prod" }
            out.append(s)
        }
        return out
    }

    static func parseCSV(_ text: String, sep: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var it = Array(text).makeIterator()
        var pending: Character? = nil
        while let c = pending ?? it.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let n = it.next() { if n == "\"" { field.append("\"") } else { quoted = false; pending = n } }
                    else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == sep { row.append(field); field = "" }
            else if c == "\n" || c == "\r" || c == "\r\n" {
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    // MARK: iTerm2 (export profilů / Dynamic Profiles JSON)

    static func iterm(_ data: Data) throws -> [SSHSession]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let profiles: [[String: Any]]
        if let d = obj as? [String: Any], let p = d["Profiles"] as? [[String: Any]] { profiles = p }
        else if let a = obj as? [[String: Any]], a.first?["Guid"] != nil || a.first?["Command"] != nil { profiles = a }
        else if let d = obj as? [String: Any], d["Command"] != nil { profiles = [d] }
        else { return nil }
        var out: [SSHSession] = []
        for p in profiles {
            guard let cmd = (p["Command"] as? String)?.trimmingCharacters(in: .whitespaces), !cmd.isEmpty else { continue }
            let tokens = cmd.split(separator: " ").map(String.init)
            guard let prog = tokens.first.map({ ($0 as NSString).lastPathComponent }), ["ssh", "telnet"].contains(prog) else { continue }
            let name = p["Name"] as? String ?? ""
            let tag = (p["Tags"] as? [String])?.first ?? ""
            let group = "iTerm2" + (tag.isEmpty ? "" : "/" + tag)
            if prog == "telnet" {
                let args = tokens.dropFirst().filter { !$0.hasPrefix("-") }
                guard let host = args.first else { continue }
                out.append(make(name, host, proto: "telnet", port: args.dropFirst().first.flatMap { Int($0) }, group: group))
                continue
            }
            var port: Int?, user = "", jump = "", ident = "", dest = ""
            var i = 1
            let withArg: Set<String> = ["-p", "-l", "-J", "-i", "-o", "-F", "-L", "-R", "-D", "-b", "-c", "-e", "-m", "-S", "-W", "-w", "-E", "-I", "-O", "-Q", "-B"]
            while i < tokens.count {
                let t = tokens[i]
                if withArg.contains(t), i + 1 < tokens.count {
                    let v = tokens[i + 1]
                    switch t { case "-p": port = Int(v); case "-l": user = v; case "-J": jump = v; case "-i": ident = v; default: break }
                    i += 2; continue
                }
                if t.hasPrefix("-p"), t.count > 2 { port = Int(t.dropFirst(2)) }
                else if !t.hasPrefix("-"), dest.isEmpty { dest = t }
                i += 1
            }
            guard !dest.isEmpty else { continue }
            if let at = dest.lastIndex(of: "@") { user = String(dest[..<at]); dest = String(dest[dest.index(after: at)...]) }
            var s = make(name, dest, proto: "ssh", port: port, user: user, group: group)
            s.jumpHost = jump
            if !ident.isEmpty { s.auth = .key; s.identityFile = ident }
            out.append(s)
        }
        return out
    }

    // MARK: XML (RDCMan, mRemoteNG)

    final class Node {
        let name: String
        let attrs: [String: String]
        var children: [Node] = []
        var text = ""
        init(_ name: String, _ attrs: [String: String]) { self.name = name; self.attrs = attrs }
        func child(_ n: String) -> Node? { children.first { $0.name == n } }
        func value(_ path: String...) -> String? {
            var cur: Node? = self
            for p in path { cur = cur?.child(p) }
            return cur.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var stack: [Node] = [Node("#root", [:])]
        func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            let n = Node(e, attributes)
            stack.last?.children.append(n)
            stack.append(n)
        }
        func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
        func parser(_ parser: XMLParser, foundCharacters s: String) { stack.last?.text += s }
    }

    static func xmlTree(_ data: Data) throws -> Node {
        let p = XMLParser(data: data)
        p.shouldResolveExternalEntities = false            // XXE
        let b = TreeBuilder()
        p.delegate = b
        guard p.parse(), let root = b.stack.first else {
            throw ImportError(message: "Neplatné XML: \(p.parserError?.localizedDescription ?? "neznámá chyba")")
        }
        return root
    }

    /// RDCMan (.rdg) – skupiny → složky, servery jako RDP. Hesla (šifrovaná DPAPI) se nepřenáší.
    static func rdcman(_ data: Data, file: String) throws -> [SSHSession] {
        let root = try xmlTree(data)
        var out: [SSHSession] = []
        func props(_ n: Node) -> Node { n.child("properties") ?? n }
        func walk(_ n: Node, _ path: [String]) {
            for c in n.children {
                switch c.name {
                case "file", "group":
                    let gname = props(c).value("name") ?? ""
                    walk(c, gname.isEmpty ? path : path + [gname])
                case "server":
                    let p = props(c)
                    guard let host = p.value("name"), !host.isEmpty else { continue }
                    let disp = p.value("displayName") ?? ""
                    let cred = c.child("logonCredentials")
                    let port = c.value("connectionSettings", "port").flatMap { Int($0) }
                    out.append(make(disp, host, proto: "rdp", port: port, user: cred?.value("userName") ?? "",
                                    group: (["RDCMan"] + path).joined(separator: "/"), domain: cred?.value("domain") ?? "",
                                    notes: p.value("comment") ?? ""))
                default:
                    walk(c, path)
                }
            }
        }
        walk(root, [])
        if out.isEmpty { throw ImportError(message: "V souboru RDCMan \(file).rdg nebyly nalezeny žádné servery.") }
        return out
    }

    /// mRemoteNG (confCons.xml) – kontejnery → složky; RDP, SSH1/2, Telnet. Ostatní protokoly se přeskočí.
    static func mremote(_ data: Data) throws -> [SSHSession] {
        let root = try xmlTree(data)
        guard let conns = root.children.first(where: { $0.name.hasSuffix("Connections") }) else {
            throw ImportError(message: "Soubor nevypadá jako mRemoteNG confCons.xml.")
        }
        if conns.attrs["FullFileEncryption"]?.lowercased() == "true" {
            throw ImportError(message: "Soubor mRemoteNG je celý šifrovaný. V mRemoteNG ho exportuj bez šifrování celého souboru (File → Export, hesla neexportovat).")
        }
        var out: [SSHSession] = []
        func walk(_ n: Node, _ path: [String]) {
            for c in n.children where c.name == "Node" {
                let name = c.attrs["Name"] ?? ""
                if c.attrs["Type"] == "Container" { walk(c, path + [name]); continue }
                guard let host = c.attrs["Hostname"], !host.isEmpty else { continue }
                let pr = (c.attrs["Protocol"] ?? "").uppercased()
                let proto = pr == "RDP" ? "rdp" : pr.hasPrefix("SSH") ? "ssh" : pr == "TELNET" ? "telnet" : ""
                guard !proto.isEmpty else { continue }
                out.append(make(name, host, proto: proto, port: c.attrs["Port"].flatMap { Int($0) }, user: c.attrs["Username"] ?? "",
                                group: (["mRemoteNG"] + path).joined(separator: "/"), domain: c.attrs["Domain"] ?? "",
                                notes: c.attrs["Descr"] ?? ""))
            }
        }
        walk(conns, [])
        return out
    }
}
