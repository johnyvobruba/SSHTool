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
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-S", controlPath, "-O", "check", destination]
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
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-S", controlPath, "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-T",
                       destination, Self.script]
        var env = ProcessInfo.processInfo.environment
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

    private func publish(state s: State) {
        DispatchQueue.main.async { [weak self] in if self?.state != s { self?.state = s } }
    }
}

// MARK: - Stavový řádek

struct MonitorLabel: View {
    @ObservedObject var monitor: RemoteMonitor

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
                    HStack(spacing: 4) {
                        Text("CPU").foregroundStyle(UI.textTertiary)
                        bar(s.cpu, level(s.cpu, warn: 80, crit: 95))
                        Text("\(Int(s.cpu.rounded())) %").monospacedDigit().foregroundStyle(level(s.cpu, warn: 80, crit: 95))
                    }
                    HStack(spacing: 4) {
                        Text("RAM").foregroundStyle(UI.textTertiary)
                        bar(memUsedPct, level(memUsedPct, warn: 85, crit: 95))
                        Text("\(gb(s.memAvailKB)) volno").monospacedDigit().foregroundStyle(level(memUsedPct, warn: 85, crit: 95))
                    }
                    HStack(spacing: 4) {
                        Text("Disk").foregroundStyle(UI.textTertiary)
                        bar(disk, level(disk, warn: 85, crit: 95))
                        Text("\(Int(disk)) %" + (s.worstPct > s.rootPct && !s.worstMount.isEmpty ? " \(s.worstMount)" : ""))
                            .monospacedDigit().foregroundStyle(level(disk, warn: 85, crit: 95))
                    }
                    Text("load \(s.load)").monospacedDigit()
                }
                .help("CPU \(Int(s.cpu.rounded())) % · RAM volno \(gb(s.memAvailKB)) z \(gb(s.memTotalKB)) · "
                      + "Disk / \(s.rootPct) %" + (s.worstMount.isEmpty ? "" : ", nejplnější \(s.worstMount) \(s.worstPct) %")
                      + " · load \(s.load)\nAktualizace každých \(RemoteMonitor.interval) s přes stejné SSH spojení.")
            } else {
                Label("Monitor…", systemImage: "chart.bar")
            }
        }
    }
}
