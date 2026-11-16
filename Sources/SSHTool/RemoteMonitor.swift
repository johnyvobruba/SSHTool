import Foundation
import SwiftUI

/// Monitor vytížení serveru ve stavovém řádku (jako MobaXterm): CPU, volná RAM, disk, load.
///
/// Jak to funguje: hlavní ssh relace běží jako ControlMaster s vlastním socketem (jeden na záložku).
/// Monitor otevře přes stejné, už přihlášené spojení jeden další kanál (žádné nové přihlášení, žádné
/// nové TCP spojení, funguje i s heslem) a v něm smyčku, která každých 5 s přečte /proc a df.
/// Na zařízení se nic nemění. Funguje na Linuxu / Gaia s uživatelem, který má shell bash/sh
/// (clish, Cisco, PAN-OS apod. → „Monitor nedostupný“).
final class RemoteMonitor: ObservableObject, @unchecked Sendable {
    struct Stats: Equatable {
        var cpu: Double            // %
        var memTotalKB: Double
        var memAvailKB: Double
        var rootPct: Int
        var worstPct: Int
        var worstMount: String
        var load: String
    }

    enum State: Equatable { case waiting, running, unavailable(String), stopped }

    @Published private(set) var stats: Stats?
    @Published private(set) var state: State = .waiting

    private let controlPath: String
    private let destination: String
    private var process: Process?
    private var buffer = ""
    private var prevCPU: [Double]?
    private var attempts = 0
    private var stopped = false
    private var stderrText = ""

    static let interval = 5

    /// Skript pro vzdálený shell (POSIX sh). Vypisuje jeden řádek @@SSHTOOL každých N sekund.
    private static var script: String {
        """
        while :; do \
        set -- $(head -n1 /proc/stat); shift; c="$*"; \
        mt=$(awk '/^MemTotal:/{print $2}' /proc/meminfo); \
        ma=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo); \
        [ -z "$ma" ] && ma=$(awk '/^(MemFree|Buffers|Cached):/{s+=$2} END{print s}' /proc/meminfo); \
        r=$(df -Pk / 2>/dev/null | awk 'NR==2{print $5+0}'); \
        w=$(df -Pk 2>/dev/null | awk 'NR>1 && $1 !~ /^(tmpfs|devtmpfs|none|udev|overlay)$/ {p=$5+0; if(p>m){m=p; n=$6}} END{print m+0, n}'); \
        l=$(cut -d' ' -f1 /proc/loadavg); \
        echo "@@SSHTOOL cpu $c mem $mt $ma root $r worst $w load $l"; \
        sleep \(interval); \
        done
        """
    }

    /// Socket ControlMaster pro jednu záložku (krátká cesta – limit unix socketu je 104 znaků).
    static func controlPath(for id: UUID) -> String {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SSHTool", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("cm-" + id.uuidString.prefix(8).lowercased()).path
    }

    init(controlPath: String, destination: String) {
        self.controlPath = controlPath
        self.destination = destination
        tryStart()
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
        DispatchQueue.main.async { self.state = .stopped }
    }

    deinit { process?.terminate() }

    // MARK: Start – čeká, až je hlavní spojení přihlášené (socket master odpovídá)

    private func tryStart() {
        guard !stopped else { return }
        attempts += 1
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if self.masterReady() {
                self.launch()
            } else if self.attempts < 60 {                 // až 5 minut (přihlašování, Touch ID…)
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in self?.tryStart() }
            } else {
                self.publish(state: .unavailable("SSH spojení nepodporuje multiplexing"))
            }
        }
    }

    private func masterReady() -> Bool {
        guard FileManager.default.fileExists(atPath: controlPath) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: SSHBinary.path)
        p.arguments = ["-S", controlPath, "-O", "check", "--", destination]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private func launch() {
        guard !stopped else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: SSHBinary.path)
        p.arguments = ["-S", controlPath, "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-T",
                       destination, Self.script]
        var env = ProcessInfo.sanitizedEnvironment
        env.removeValue(forKey: "SSH_ASKPASS")
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            self?.consume(String(decoding: d, as: UTF8.self))
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            if let self, self.stderrText.count < 2000 { self.stderrText += String(decoding: d, as: UTF8.self) }
        }
        p.terminationHandler = { [weak self] _ in
            guard let self, !self.stopped else { return }
            let reason = self.stderrText.split(whereSeparator: \.isNewline).last.map(String.init)
            self.publish(state: .unavailable(self.stats == nil
                ? (reason.map { "Server nepodporuje (\($0))" } ?? "Server nepodporuje – potřebuje Linux s bash/sh")
                : "Monitor ukončen"))
        }
        do { try p.run(); process = p } catch { publish(state: .unavailable("Nelze spustit ssh")) }
    }

    // MARK: Zpracování výstupu

    private func consume(_ s: String) {
        buffer += s
        while let r = buffer.range(of: "\n") {
            let line = String(buffer[..<r.lowerBound])
            buffer.removeSubrange(..<r.upperBound)
            parse(line)
        }
        if buffer.count > 8192 { buffer = "" }
    }

    private func parse(_ line: String) {
        guard let start = line.range(of: "@@SSHTOOL ") else { return }
        let t = line[start.upperBound...].split(separator: " ").map(String.init)
        func after(_ key: String, _ n: Int) -> [String]? {
            guard let i = t.firstIndex(of: key), i + n < t.count else { return nil }
            return Array(t[(i + 1)...(i + n)])
        }
        guard let ci = t.firstIndex(of: "cpu"), let mi = t.firstIndex(of: "mem"), mi > ci + 4 else { return }
        let cpuVals = t[(ci + 1)..<mi].compactMap(Double.init)
        guard cpuVals.count >= 4, let mem = after("mem", 2),
              let mt = Double(mem[0]), let ma = Double(mem[1]) else { return }
        let root = after("root", 1).flatMap { Int($0[0]) } ?? 0
        var worstPct = 0, worstMount = ""
        if let i = t.firstIndex(of: "worst"), i + 1 < t.count {
            worstPct = Int(t[i + 1]) ?? 0
            if i + 2 < t.count, t[i + 2] != "load" { worstMount = t[i + 2] }
        }
        let load = after("load", 1)?[0] ?? ""

        // CPU % z rozdílu dvou vzorků /proc/stat (idle + iowait = nečinnost)
        var cpu = 0.0
        if let prev = prevCPU, prev.count == cpuVals.count {
            let total = zip(cpuVals, prev).map { $0 - $1 }.reduce(0, +)
            let idle = (cpuVals[3] - prev[3]) + (cpuVals.count > 4 ? cpuVals[4] - prev[4] : 0)
            cpu = total > 0 ? max(0, min(100, (total - idle) / total * 100)) : 0
        }
        let first = prevCPU == nil
        prevCPU = cpuVals
        if first { publish(state: .running); return }        // první vzorek jen pro výpočet rozdílu
        let st = Stats(cpu: cpu, memTotalKB: mt, memAvailKB: ma, rootPct: root,
                       worstPct: worstPct, worstMount: worstMount, load: load)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.stats != st { self.stats = st }
            if self.state != .running { self.state = .running }
        }
    }

    /// Jednorázový příkaz přes stejné ControlMaster spojení (podrobnosti po najetí myší).
    /// Skripty jsou pevné (žádný vstup od uživatele), na serveru jen čtou /proc, df a ps.
    func runOnce(_ script: String, timeout: TimeInterval = 10, completion: @escaping (String?) -> Void) {
        let cp = controlPath, dest = destination
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: SSHBinary.path)
            p.arguments = ["-S", cp, "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-T", "--", dest, script]
            var env = ProcessInfo.sanitizedEnvironment
            env.removeValue(forKey: "SSH_ASKPASS")
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { completion(nil); return }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            completion(data.isEmpty ? nil : String(decoding: data, as: UTF8.self))
        }
    }

    private func publish(state s: State) {
        DispatchQueue.main.async { [weak self] in if self?.state != s { self?.state = s } }
    }
}

// MARK: - Stavový řádek

struct MonitorLabel: View {
    @ObservedObject var monitor: RemoteMonitor
    @StateObject private var detail = MonitorDetail()

    private func gb(_ kb: Double) -> String {
        let g = kb / 1_048_576
        return g >= 10 ? String(format: "%.0f GB", g) : String(format: "%.1f GB", g)
    }

    private func level(_ v: Double, warn: Double, crit: Double) -> SwiftUI.Color {
        v >= crit ? UI.error : v >= warn ? UI.connecting : UI.textStatus
    }

    private func bar(_ pct: Double, _ color: SwiftUI.Color) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(UI.border)
            Capsule().fill(color == UI.textStatus ? UI.ok : color).frame(width: 26 * min(1, max(0.04, pct / 100)))
        }
        .frame(width: 26, height: 5)
    }

    /// Úsek stavového řádku: po najetí myší (~½ s) se otevře okénko s podrobnostmi (jako MobaXterm).
    private func segment<C: View>(_ kind: MonitorDetailKind, @ViewBuilder _ content: () -> C) -> some View {
        content()
            .contentShape(Rectangle())
            .onHover { detail.hover(kind, $0, monitor: monitor) }
            .onTapGesture { detail.open(kind, monitor) }
            .popover(isPresented: Binding(get: { detail.shown == kind }, set: { if !$0 { detail.close() } }),
                     arrowEdge: .top) {
                MonitorDetailView(d: detail, kind: kind) { detail.refresh(monitor) }
            }
    }

    var body: some View {
        switch monitor.state {
        case .waiting:
            Label("Monitor…", systemImage: "chart.bar").help("Čekám na přihlášení relace")
        case .unavailable(let why):
            Label("Monitor –", systemImage: "chart.bar").foregroundStyle(UI.textTertiary).help(why)
        case .stopped:
            EmptyView()
        case .running:
            if let s = monitor.stats {
                let memUsedPct = s.memTotalKB > 0 ? (1 - s.memAvailKB / s.memTotalKB) * 100 : 0
                let disk = Double(max(s.rootPct, s.worstPct))
                HStack(spacing: 10) {
                    segment(.cpu) {
                        HStack(spacing: 4) {
                            Text("CPU").foregroundStyle(UI.textTertiary)
                            bar(s.cpu, level(s.cpu, warn: 80, crit: 95))
                            Text("\(Int(s.cpu.rounded())) %").monospacedDigit().foregroundStyle(level(s.cpu, warn: 80, crit: 95))
                        }
                    }
                    segment(.ram) {
                        HStack(spacing: 4) {
                            Text("RAM").foregroundStyle(UI.textTertiary)
                            bar(memUsedPct, level(memUsedPct, warn: 85, crit: 95))
                            Text("\(gb(s.memAvailKB)) volno").monospacedDigit().foregroundStyle(level(memUsedPct, warn: 85, crit: 95))
                        }
                    }
                    segment(.disk) {
                        HStack(spacing: 4) {
                            Text("Disk").foregroundStyle(UI.textTertiary)
                            bar(disk, level(disk, warn: 85, crit: 95))
                            Text("\(Int(disk)) %" + (s.worstPct > s.rootPct && !s.worstMount.isEmpty ? " \(s.worstMount)" : ""))
                                .monospacedDigit().foregroundStyle(level(disk, warn: 85, crit: 95))
                        }
                    }
                    segment(.load) {
                        Text("load \(s.load)").monospacedDigit()
                    }
                }
            } else {
                Label("Monitor…", systemImage: "chart.bar")
            }
        }
    }
}

// MARK: - Podrobnosti po najetí myší

enum MonitorDetailKind { case cpu, ram, disk, load }

/// Stav okénka s podrobnostmi. Data se načtou jednorázově při otevření (a tlačítkem Obnovit)
/// přes stejné SSH spojení – pevné skripty, na serveru jen čtení /proc, df a ps.
final class MonitorDetail: ObservableObject, @unchecked Sendable {
    struct Core: Hashable { let name: String; let pct: Double }
    struct DiskRow: Hashable { let line: String; let pct: Int }

    @Published var shown: MonitorDetailKind?
    @Published var loading = false
    @Published var error: String?
    @Published var cores: [Core] = []
    @Published var lines: [String] = []          // free -m / uptime …
    @Published var procs: [String] = []          // ps – nejnáročnější procesy
    @Published var disks: [DiskRow] = []
    @Published var diskHeader = ""
    @Published var updated: Date?

    private var hovered: MonitorDetailKind?
    private var insidePopover = false
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?

    func hover(_ k: MonitorDetailKind, _ inside: Bool, monitor: RemoteMonitor) {
        if inside {
            hovered = k
            closeWork?.cancel()
            guard shown != k else { return }
            openWork?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.hovered == k else { return }
                self.open(k, monitor)
            }
            openWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w)
        } else {
            openWork?.cancel()
            if hovered == k { hovered = nil }
            scheduleClose()
        }
    }

    func popoverHover(_ inside: Bool) {
        insidePopover = inside
        if inside { closeWork?.cancel() } else { scheduleClose() }
    }

    private func scheduleClose() {
        closeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.insidePopover, self.hovered == nil else { return }
            self.close()
        }
        closeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    func open(_ k: MonitorDetailKind, _ monitor: RemoteMonitor) {
        if shown != k {
            cores = []; lines = []; procs = []; disks = []; diskHeader = ""; error = nil
        }
        shown = k
        refresh(monitor)
    }

    func close() { shown = nil; insidePopover = false }

    func refresh(_ monitor: RemoteMonitor) {
        guard let k = shown else { return }
        loading = true
        monitor.runOnce(Self.script(k)) { [weak self] out in
            DispatchQueue.main.async {
                guard let self, self.shown == k else { return }
                self.loading = false
                guard let out else { self.error = "Podrobnosti se nepodařilo načíst."; return }
                self.error = nil
                self.apply(k, out)
                self.updated = Date()
            }
        }
    }

    private static let topCPU = "ps -eo pcpu,pid,user,comm --sort=-pcpu 2>/dev/null | head -n 9"
    private static let topMem = "ps -eo pmem,rss,pid,user,comm --sort=-pmem 2>/dev/null | head -n 9"

    static func script(_ k: MonitorDetailKind) -> String {
        switch k {
        case .cpu:
            return "export LC_ALL=C; grep '^cpu' /proc/stat; sleep 1; echo @@SEP; grep '^cpu' /proc/stat; echo @@SEP; \(topCPU)"
        case .ram:
            return "export LC_ALL=C; free -m 2>/dev/null || grep -E '^(Mem|Swap|Buffers|Cached)' /proc/meminfo; echo @@SEP; \(topMem)"
        case .disk:
            return "export LC_ALL=C; df -hP 2>/dev/null"
        case .load:
            return "export LC_ALL=C; uptime; echo \"CPU jader: $(grep -c '^processor' /proc/cpuinfo)\"; "
                + "echo \"Procesy (běžící/celkem): $(cut -d' ' -f4 /proc/loadavg)\"; echo @@SEP; \(topCPU)"
        }
    }

    private func apply(_ k: MonitorDetailKind, _ out: String) {
        let parts = out.components(separatedBy: "@@SEP").map {
            $0.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        switch k {
        case .cpu:
            guard parts.count >= 2 else { return }
            cores = Self.cpuUsage(parts[0], parts[1])
            procs = parts.count > 2 ? parts[2] : []
        case .ram:
            lines = parts.first ?? []
            procs = parts.count > 1 ? parts[1] : []
        case .disk:
            let rows = parts.first ?? []
            diskHeader = rows.first ?? ""
            disks = rows.dropFirst().compactMap { l in
                let cols = l.split(separator: " ")
                guard cols.count >= 6 else { return nil }
                let fs = String(cols[0])
                if ["tmpfs", "devtmpfs", "none", "udev", "overlay", "shm"].contains(fs) { return nil }
                return DiskRow(line: l, pct: Int(cols[4].dropLast()) ?? 0)
            }
        case .load:
            lines = parts.first ?? []
            procs = parts.count > 1 ? parts[1] : []
        }
    }

    /// Vytížení jednotlivých CPU z rozdílu dvou výpisů /proc/stat (idle + iowait = nečinnost).
    static func cpuUsage(_ a: [String], _ b: [String]) -> [Core] {
        func parse(_ l: [String]) -> [String: [Double]] {
            var d: [String: [Double]] = [:]
            for line in l {
                let t = line.split(separator: " ")
                guard let n = t.first, n.hasPrefix("cpu") else { continue }
                d[String(n)] = t.dropFirst().compactMap { Double($0) }
            }
            return d
        }
        let x = parse(a), y = parse(b)
        var res: [Core] = []
        for (name, v2) in y {
            guard let v1 = x[name], v1.count == v2.count, v2.count >= 4 else { continue }
            let total = zip(v2, v1).map { $0 - $1 }.reduce(0, +)
            let idle = (v2[3] - v1[3]) + (v2.count > 4 ? v2[4] - v1[4] : 0)
            let pct = total > 0 ? max(0, min(100, (total - idle) / total * 100)) : 0
            res.append(Core(name: name == "cpu" ? "celkem" : name, pct: pct))
        }
        // celkem první, pak cpu0, cpu1 … číselně
        return res.sorted { a, b in
            if a.name == "celkem" { return true }
            if b.name == "celkem" { return false }
            return (Int(a.name.dropFirst(3)) ?? 0) < (Int(b.name.dropFirst(3)) ?? 0)
        }
    }
}

struct MonitorDetailView: View {
    @ObservedObject var d: MonitorDetail
    let kind: MonitorDetailKind
    let refresh: () -> Void

    private var title: String {
        switch kind {
        case .cpu: return "CPU – vytížení jader (1 s)"
        case .ram: return "Paměť"
        case .disk: return "Disky (df -h)"
        case .load: return "Zátěž systému"
        }
    }

    private func color(_ pct: Double, warn: Double, crit: Double) -> SwiftUI.Color {
        pct >= crit ? UI.error : pct >= warn ? UI.connecting : UI.ok
    }

    private func meter(_ pct: Double, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(UI.border)
            Capsule().fill(color(pct, warn: 80, crit: 95)).frame(width: width * min(1, max(0.03, pct / 100)))
        }
        .frame(width: width, height: 6)
    }

    private var mono: Font { .system(size: 11, design: .monospaced) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Spacer()
                if d.loading { ProgressView().controlSize(.small) }
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Načíst znovu")
            }
            if let e = d.error { Text(e).font(.caption).foregroundStyle(UI.error) }
            switch kind {
            case .cpu:
                if let total = d.cores.first(where: { $0.name == "celkem" }) {
                    HStack(spacing: 6) {
                        Text("Celkem").font(.system(size: 11, weight: .medium)).frame(width: 52, alignment: .leading)
                        meter(total.pct, width: 160)
                        Text("\(Int(total.pct.rounded())) %").font(mono).frame(width: 40, alignment: .trailing)
                        Text("· \(d.cores.count - 1) jader").font(.caption).foregroundStyle(UI.textSecondary)
                    }
                }
                let cores = d.cores.filter { $0.name != "celkem" }
                let cols = cores.count > 32 ? 4 : cores.count > 8 ? 3 : 2
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: cols), alignment: .leading, spacing: 4) {
                        ForEach(cores, id: \.self) { c in
                            HStack(spacing: 4) {
                                Text(c.name).font(mono).foregroundStyle(UI.textSecondary).frame(width: 46, alignment: .leading)
                                meter(c.pct, width: 50)
                                Text("\(Int(c.pct.rounded()))%").font(mono).frame(width: 34, alignment: .trailing)
                            }
                        }
                    }
                }
                // ScrollView v popoveru nemá vlastní výšku (sbalí se na 0) → výška podle počtu řádků, max. 260
                .frame(height: min(260, CGFloat((cores.count + cols - 1) / cols) * 18 + 2))
                procList("Nejvíc CPU")
            case .ram:
                ForEach(d.lines, id: \.self) { Text($0).font(mono) }
                procList("Nejvíc paměti (RSS v kB)")
            case .disk:
                if !d.diskHeader.isEmpty { Text(d.diskHeader).font(mono).foregroundStyle(UI.textSecondary) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(d.disks, id: \.self) { r in
                            Text(r.line).font(mono)
                                .foregroundStyle(r.pct >= 95 ? UI.error : r.pct >= 85 ? UI.connecting : UI.text)
                        }
                    }
                }
                .frame(height: min(280, CGFloat(d.disks.count) * 16 + 4))
            case .load:
                ForEach(d.lines, id: \.self) { Text($0).font(mono) }
                procList("Nejvíc CPU")
            }
            if let u = d.updated {
                Text("Načteno \(u.formatted(date: .omitted, time: .standard)) přes stejné SSH spojení · ↻ znovu")
                    .font(.system(size: 10)).foregroundStyle(UI.textTertiary)
            }
        }
        .padding(12)
        .frame(width: kind == .cpu && d.cores.count > 33 ? 640 : 520)
        .textSelection(.enabled)
        .onHover { d.popoverHover($0) }
    }

    @ViewBuilder private func procList(_ title: String) -> some View {
        if !d.procs.isEmpty {
            Divider()
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(UI.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(d.procs.enumerated()), id: \.offset) { Text($0.element).font(mono).lineLimit(1) }
            }
        }
    }
}
