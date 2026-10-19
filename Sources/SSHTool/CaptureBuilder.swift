import SwiftUI
import AppKit

// Průvodce zachytáváním paketů: tcpdump / fw monitor -F / fw monitor -e (INSPECT).
// Sestaví příkaz z parametrů, ukáže ho a vloží do aktivního terminálu (ve výchozím stavu bez spuštění).
// Všechny vstupy se validují – do vzdáleného shellu se nedostane nic jiného než povolené znaky.

final class CaptureModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case tcpdump, fwF, fwE
        var id: String { rawValue }
        var title: String {
            switch self {
            case .tcpdump: return "tcpdump"
            case .fwF: return "fw monitor -F"
            case .fwE: return "fw monitor -e"
            }
        }
        var help: String {
            switch self {
            case .tcpdump: return "Linux / Gaia expert. Filtr BPF, rozhraní, rozsah portů, zápis do pcap."
            case .fwF: return "Check Point R80.20+: rychlý filtr, funguje i s SecureXL. Port jen jeden (bez rozsahu), bez filtru rozhraní."
            case .fwE: return "Check Point INSPECT filtr – umí rozsah portů. Akcelerovaný provoz (SecureXL) nemusí být vidět."
            }
        }
    }

    @Published var tool: Tool = .tcpdump
    @Published var iface = ""
    @Published var src = ""
    @Published var dst = ""
    @Published var bidirectional = true
    @Published var proto = "any"          // any | tcp | udp | icmp
    @Published var port = ""              // 443 nebo 8000-8100
    @Published var count = 1000           // 0 = bez limitu
    @Published var snaplen = 0            // 0 = celý paket
    @Published var writeFile = false
    @Published var file = "/var/log/capture.pcap"
    @Published var noResolve = true       // -nn  (nepřekládat adresy ani porty)
    @Published var verbose = 0            // 0 / -v / -vv / -vvv
    @Published var lineBuffered = true    // -l  (řádkové bufferování – okamžitý výpis, i do | grep)
    @Published var noPromisc = true       // -p  (bez promiskuitního režimu)
    @Published var linkHeader = true      // -e  (MAC adresy / VLAN tag)
    @Published var securityGroup = false  // Check Point Maestro / Scalable Platform: g_tcpdump na všech SGM
    @Published var useSudo = false        // Wireshark live / stažení: sudo -n (neinteraktivně)
    @Published var vsid = ""              // fw monitor: VSX virtuální systém (volitelně)

    // MARK: Validace

    private static let hostRe = #"^[A-Za-z0-9][A-Za-z0-9.:-]*(/\d{1,3})?$"#
    private static let ifaceRe = #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#
    private static let pathRe = #"^/[A-Za-z0-9._/-]+$"#

    private func ok(_ s: String, _ re: String) -> Bool { s.range(of: re, options: .regularExpression) != nil }
    private func t(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }

    /// (od, do) – jeden port vrací stejné číslo dvakrát.
    var portRange: (Int, Int)? {
        let p = t(port)
        guard !p.isEmpty else { return nil }
        let parts = p.split(separator: "-").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard (1...2).contains(parts.count), parts.allSatisfy({ $0 != nil && (1...65535).contains($0!) }) else { return nil }
        let a = parts[0]!, b = parts.count == 2 ? parts[1]! : parts[0]!
        return a <= b ? (a, b) : nil
    }

    var errors: [String] {
        var e: [String] = []
        if !t(iface).isEmpty, !ok(t(iface), Self.ifaceRe) { e.append("Rozhraní: povolená jsou písmena, číslice a . _ : -") }
        for (n, v) in [("Zdroj", src), ("Cíl", dst)] where !t(v).isEmpty && !ok(t(v), Self.hostRe) {
            e.append("\(n): zadej IP adresu, síť (10.0.0.0/24) nebo hostname")
        }
        if tool != .tcpdump, t(src).contains("/") || t(dst).contains("/") {
            e.append("fw monitor zde podporuje jen jednu IP adresu – pro síť s maskou použij tcpdump")
        }
        if tool != .tcpdump, [src, dst].contains(where: { !t($0).isEmpty && t($0).range(of: #"[A-Za-z]"#, options: .regularExpression) != nil && !t($0).contains(":") }) {
            e.append("fw monitor potřebuje IP adresu, ne hostname")
        }
        if !t(port).isEmpty, portRange == nil { e.append("Port: číslo 1–65535 nebo rozsah 8000-8100") }
        if tool == .fwF, let r = portRange, r.0 != r.1 { e.append("fw monitor -F neumí rozsah portů – použij fw monitor -e nebo tcpdump") }
        if (proto == "icmp"), !t(port).isEmpty { e.append("ICMP nemá porty – port vynech") }
        if writeFile, !ok(t(file), Self.pathRe) { e.append("Soubor: absolutní cesta bez mezer, např. /var/log/capture.pcap") }
        if !t(vsid).isEmpty, Int(t(vsid)) == nil { e.append("VSID musí být číslo") }
        if count < 0 || snaplen < 0 { e.append("Počet a snaplen nesmí být záporné") }
        return e
    }

    var warnings: [String] {
        var w: [String] = []
        if count == 0 { w.append("Bez limitu paketů – na vytíženém zařízení zatíží CPU i disk. Ukonči Ctrl+C.") }
        if t(src).isEmpty, t(dst).isEmpty, t(port).isEmpty, proto == "any" { w.append("Bez filtru se zachytí veškerý provoz.") }
        if tool == .fwE { w.append("Akcelerovaný provoz nemusí být vidět – zvaž fw monitor -F (R80.20+).") }
        if tool == .tcpdump, securityGroup {
            w.append("g_tcpdump běží na všech členech (SGM) Security Group – spouštěj z SMO / člena SG v expert režimu; počet paketů platí pro každého člena.")
            if writeFile { w.append("S g_tcpdump vznikne soubor na každém SGM zvlášť (stejná cesta).") }
        }
        if tool != .tcpdump, !t(iface).isEmpty { w.append("fw monitor nefiltruje podle rozhraní – rozhraní a směr (i I o O) jsou ve výstupu.") }
        if writeFile, tool != .tcpdump { w.append("fw monitor -o zapisuje formát snoop – Wireshark ho otevře.") }
        if writeFile { w.append("Soubor s odchytem obsahuje data provozu – po stažení ho ze zařízení smaž.") }
        return w
    }

    // MARK: Sestavení příkazu

    var command: String {
        switch tool {
        case .tcpdump: return tcpdump
        case .fwF: return fwF
        case .fwE: return fwE
        }
    }

    private func bpfHost(_ v: String, _ dir: String) -> String {
        let x = t(v)
        return x.contains("/") ? "\(dir)net \(x)" : "\(dir)host \(x)"
    }

    private var tcpdump: String {
        // přepínače v jedné skupině jako -lpenni eth1 (i musí být poslední – bere argument)
        var flags = ""
        if lineBuffered { flags += "l" }
        if noPromisc { flags += "p" }
        if linkHeader { flags += "e" }
        if noResolve { flags += "nn" }
        if verbose > 0 { flags += String(repeating: "v", count: min(verbose, 3)) }
        let i = t(iface)
        var a = [securityGroup ? "g_tcpdump" : "tcpdump", "-\(flags)i \(i.isEmpty ? "any" : i)"]
        if count > 0 { a.append("-c \(count)") }
        if snaplen > 0 { a.append("-s \(snaplen)") } else if writeFile { a.append("-s 0") }
        if writeFile { a.append("-w \(t(file))") }
        let f = bpfFilter
        if !f.isEmpty { a.append("'" + f + "'") }
        return a.joined(separator: " ")
    }

    /// BPF filtr (bez uvozovek) ze zadaných parametrů.
    var bpfFilter: String {
        var f: [String] = []
        let s = t(src), d = t(dst)
        switch (s.isEmpty, d.isEmpty) {
        case (false, false):
            f.append(bidirectional
                     ? "((\(bpfHost(s, "src ")) and \(bpfHost(d, "dst "))) or (\(bpfHost(d, "src ")) and \(bpfHost(s, "dst "))))"
                     : "\(bpfHost(s, "src ")) and \(bpfHost(d, "dst "))")
        case (false, true): f.append(bidirectional ? bpfHost(s, "") : bpfHost(s, "src "))
        case (true, false): f.append(bidirectional ? bpfHost(d, "") : bpfHost(d, "dst "))
        default: break
        }
        if proto != "any" { f.append(proto) }
        if let r = portRange { f.append(r.0 == r.1 ? "port \(r.0)" : "portrange \(r.0)-\(r.1)") }
        return f.joined(separator: " and ")
    }

    /// Vzdálený příkaz pro živý odchyt do Wiresharku (pcap na stdout, -U = bez bufferování).
    /// Z odchytu se vyřadí SSH spojení, kterým data tečou (IP a port klienta z $SSH_CLIENT).
    var liveRemoteCommand: String? {
        guard tool == .tcpdump, !securityGroup, errors.isEmpty else { return nil }
        let i = t(iface)
        var a = ["\(useSudo ? "sudo -n " : "")tcpdump", "-U", "-s \(snaplen > 0 ? snaplen : 0)", "-nn"]
        if noPromisc { a.append("-p") }
        a.append("-i \(i.isEmpty ? "any" : i)")
        if count > 0 { a.append("-c \(count)") }
        a.append("-w -")
        let f = bpfFilter
        let own = "not (host $1 and port $2)"
        a.append("\"" + (f.isEmpty ? own : "(\(f)) and \(own)") + "\"")
        return "set -- $SSH_CLIENT; exec " + a.joined(separator: " ")
    }

    private var protoNum: Int { ["tcp": 6, "udp": 17, "icmp": 1][proto] ?? 0 }

    private var fwPrefix: [String] {
        var a = ["fw monitor"]
        if !t(vsid).isEmpty { a.append("-v \(t(vsid))") }
        if count > 0 { a.append("-ci \(count) -co \(count)") }
        if writeFile { a.append("-o \(t(file))") }
        return a
    }

    /// -F "src,sport,dst,dport,proto" – 0 = cokoli, více -F = logické OR.
    private var fwF: String {
        var a = fwPrefix
        let s = t(src).isEmpty ? "0" : t(src)
        let d = t(dst).isEmpty ? "0" : t(dst)
        let p = portRange.map { String($0.0) } ?? "0"
        let pr = protoNum
        var filters: [String] = []
        if p == "0" {
            filters.append("\(s),0,\(d),0,\(pr)")
            if bidirectional, s != d { filters.append("\(d),0,\(s),0,\(pr)") }
        } else {
            // port na straně cíle i zdroje (odpověď)
            filters.append("\(s),0,\(d),\(p),\(pr)")
            filters.append("\(d),\(p),\(s),0,\(pr)")
            if bidirectional, s != d {
                filters.append("\(d),0,\(s),\(p),\(pr)")
                filters.append("\(s),\(p),\(d),0,\(pr)")
            }
        }
        var seen = Set<String>()
        for f in filters where seen.insert(f).inserted { a.append("-F \"\(f)\"") }
        return a.joined(separator: " ")
    }

    /// Klasický INSPECT filtr: fw monitor -e "accept …;"
    private var fwE: String {
        var a = fwPrefix
        var c: [String] = []
        let s = t(src), d = t(dst)
        switch (s.isEmpty, d.isEmpty) {
        case (false, false):
            c.append(bidirectional ? "((src=\(s) and dst=\(d)) or (src=\(d) and dst=\(s)))" : "(src=\(s) and dst=\(d))")
        case (false, true): c.append(bidirectional ? "host(\(s))" : "src=\(s)")
        case (true, false): c.append(bidirectional ? "host(\(d))" : "dst=\(d)")
        default: break
        }
        if protoNum != 0 { c.append("ip_p=\(protoNum)") }
        if let r = portRange {
            c.append(r.0 == r.1
                     ? "(sport=\(r.0) or dport=\(r.0))"
                     : "((sport>=\(r.0) and sport<=\(r.1)) or (dport>=\(r.0) and dport<=\(r.1)))")
        }
        a.append("-e \"accept " + (c.isEmpty ? "" : c.joined(separator: " and ")) + ";\"")
        return a.joined(separator: " ")
    }
}

// MARK: - Okno průvodce

struct CaptureSheet: View {
    @EnvironmentObject private var tabs: TabManager
    @ObservedObject var m: CaptureModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Nástroj", selection: $m.tool) {
                        ForEach(CaptureModel.Tool.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(m.tool.help).font(.caption).foregroundStyle(.secondary)
                }
                Section("Filtr") {
                    TextField("Rozhraní", text: $m.iface, prompt: Text(m.tool == .tcpdump ? "eth1, bond0.100 (prázdné = any)" : "fw monitor nefiltruje rozhraní"))
                        .disabled(m.tool != .tcpdump)
                    TextField("Zdroj", text: $m.src, prompt: Text("10.0.0.10 nebo 10.0.0.0/24"))
                    TextField("Cíl", text: $m.dst, prompt: Text("192.0.2.10"))
                    Toggle("Oba směry (i odpovědi)", isOn: $m.bidirectional)
                    Picker("Protokol", selection: $m.proto) {
                        Text("Vše").tag("any"); Text("TCP").tag("tcp"); Text("UDP").tag("udp"); Text("ICMP").tag("icmp")
                    }
                    .pickerStyle(.segmented)
                    TextField("Port / rozsah", text: $m.port, prompt: Text("443 nebo 8000-8100"))
                }
                Section("Výstup") {
                    LabeledContent("Počet paketů") {
                        HStack {
                            TextField("", value: $m.count, format: .number.grouping(.never)).labelsHidden().frame(width: 80)
                            Text("0 = bez limitu").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if m.tool == .tcpdump {
                        LabeledContent("Snaplen (B)") {
                            HStack {
                                TextField("", value: $m.snaplen, format: .number.grouping(.never)).labelsHidden().frame(width: 80)
                                Text("0 = celý paket").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Toggle("Security Group – Check Point Maestro (g_tcpdump na všech SGM)", isOn: $m.securityGroup)
                        LabeledContent("Přepínače") {
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle("-l  řádkové bufferování (výpis hned, i přes | grep)", isOn: $m.lineBuffered)
                                Toggle("-p  bez promiskuitního režimu", isOn: $m.noPromisc)
                                Toggle("-e  hlavička linkové vrstvy (MAC, VLAN)", isOn: $m.linkHeader)
                                Toggle("-nn  nepřekládat adresy ani porty", isOn: $m.noResolve)
                                Picker("Podrobnost", selection: $m.verbose) {
                                    Text("normální").tag(0); Text("-v").tag(1); Text("-vv").tag(2); Text("-vvv").tag(3)
                                }
                                .pickerStyle(.segmented).frame(width: 260)
                            }
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                        }
                    } else {
                        TextField("VSX – VSID", text: $m.vsid, prompt: Text("volitelné, např. 2"))
                    }
                    Toggle("Zapsat do souboru", isOn: $m.writeFile)
                    if m.writeFile {
                        TextField("Soubor", text: $m.file).font(.system(.body, design: .monospaced))
                    }
                }
                Section("Wireshark (lokálně v Macu)") {
                    HStack(spacing: 8) {
                        Button { tabs.startLiveWireshark(m) } label: {
                            Label("Živě do Wiresharku", systemImage: "dot.radiowaves.left.and.right")
                        }
                        .disabled(m.liveRemoteCommand == nil || !(tabs.selected?.canMonitor ?? false))
                        Button { tabs.downloadCaptureToWireshark(m) } label: {
                            Label("Stáhnout soubor a otevřít", systemImage: "arrow.down.doc")
                        }
                        .disabled(!m.writeFile || !(tabs.selected?.canMonitor ?? false))
                        Spacer()
                    }
                    Toggle("Spouštět přes sudo -n (uživatel bez root práv)", isOn: $m.useSudo)
                    Text(m.tool != .tcpdump ? "Živě funguje jen s tcpdump; soubor z fw monitor (-o) lze stáhnout a otevřít."
                         : m.securityGroup ? "Živě nelze s g_tcpdump (souběžný výstup ze všech SGM by poškodil pcap) – použij soubor."
                         : "Živě: tcpdump -U -w - na serveru → přes stejné SSH spojení (bez nového přihlášení) → Wireshark. Vlastní SSH spojení se z odchytu vyřadí. Po dosažení počtu paketů nebo „Zastavit“ zůstane odchyt ve Wiresharku. Soubor: stáhne se do Stažené/SSHTool-captures (práva 600).")
                        .font(.caption).foregroundStyle(.secondary)
                    if let live = m.liveRemoteCommand {
                        Text("ssh … '\(live)' | wireshark -k -i -")
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Section("Příkaz") {
                    Text(m.command)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(UI.main))
                    ForEach(m.errors, id: \.self) { e in
                        Label(e, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(UI.error)
                    }
                    ForEach(m.warnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.orange)
                    }
                    Text("Spouští se v expert / root shellu. Ukončení: Ctrl+C.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Rectangle().fill(UI.border).frame(height: 1)
            HStack(spacing: 8) {
                if let t = tabs.selected {
                    Text("Cíl: \(tabs.displayTitle(t))").font(.system(size: 11.5)).foregroundStyle(UI.textSecondary).lineLimit(1)
                    EnvBadge(tag: t.session.envTag)
                }
                Spacer()
                Button("Kopírovat") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(m.command, forType: .string)
                }
                .buttonStyle(SKButton()).disabled(!m.errors.isEmpty)
                Button("Zavřít") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(SKButton())
                Button("Vložit a spustit") { insert(run: true) }
                    .buttonStyle(SKButton()).disabled(!canInsert)
                Button("Vložit do terminálu") { insert(run: false) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(SKButton(kind: .primary)).disabled(!canInsert)
            }
            .padding(.horizontal, 20).frame(height: 56)
            .background(UI.chrome)
        }
        .frame(width: 640, height: 660)
        .background(UI.sidebar)
        .tint(UI.accent)
    }

    private var canInsert: Bool { m.errors.isEmpty && (tabs.selected?.running ?? false) }

    private func insert(run: Bool) {
        let s = Snippet(name: "Zachytávání", command: m.command)
        dismiss()
        // po zavření okna, ať fokus skončí v terminálu
        DispatchQueue.main.async { tabs.insertSnippet(s, run: run) }
    }
}
