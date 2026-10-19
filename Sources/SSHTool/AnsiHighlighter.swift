import Foundation

/// Zkompilované pravidlo (regex + SGR sekvence).
struct CompiledRule { let id: UUID; let regex: NSRegularExpression; let open: [UInt8] }

/// Sdílená, vláknově bezpečná sada pravidel pro všechny terminály.
/// AppStore sem zapíše při každé změně pravidel → projeví se okamžitě i v otevřených záložkách.
final class HighlightCenter: @unchecked Sendable {
    static let shared = HighlightCenter()
    private let lock = NSLock()
    private var _compiled: [CompiledRule] = []
    private var _all: [CompiledRule] = []
    private var slowHits: [UUID: Int] = [:]
    private var _paused: Set<UUID> = []
    /// Pravidlo bylo pozastaveno kvůli výkonu (object = nic, čti `paused`).
    static let pausedChanged = Notification.Name("SSHToolHighlightPaused")

    var compiled: [CompiledRule] { lock.lock(); defer { lock.unlock() }; return _compiled }
    var paused: Set<UUID> { lock.lock(); defer { lock.unlock() }; return _paused }

    /// Výraz překročil časový limit. Po 3 překročeních se pravidlo pozastaví (do „Znovu povolit“).
    func reportSlow(_ id: UUID) {
        lock.lock()
        slowHits[id, default: 0] += 1
        var changed = false
        if slowHits[id]! >= 3, !_paused.contains(id) {
            _paused.insert(id); changed = true
            _compiled = _all.filter { !_paused.contains($0.id) }
        }
        lock.unlock()
        if changed {
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.pausedChanged, object: nil) }
        }
    }

    func resume(_ id: UUID) {
        lock.lock()
        _paused.remove(id); slowHits[id] = 0
        _compiled = _all.filter { !_paused.contains($0.id) }
        lock.unlock()
        NotificationCenter.default.post(name: Self.pausedChanged, object: nil)
    }

    func setRules(_ rules: [HighlightRule]) {
        let c: [CompiledRule] = rules.compactMap { rule in
            guard rule.enabled, !rule.pattern.isEmpty else { return nil }
            let open = rule.sgrOpen
            guard !open.isEmpty else { return nil }
            let pattern = rule.isRegex ? rule.pattern : NSRegularExpression.escapedPattern(for: rule.pattern)
            let options: NSRegularExpression.Options = rule.caseSensitive ? [] : [.caseInsensitive]
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
            return CompiledRule(id: rule.id, regex: re, open: open)
        }
        lock.lock(); _all = c; _compiled = c.filter { !_paused.contains($0.id) }; lock.unlock()
    }
}

/// Přepisuje výstup z ssh dřív, než ho dostane terminál: kolem shod vloží ANSI barvy.
/// - Escape sekvence ze serveru nechává netknuté, regexy běží jen nad čistým textem mezi nimi.
/// - Po zvýraznění obnoví barvy, které tam předtím nastavil server (sleduje SGR stav).
/// - V alternate screen (vim, top, less, mc…) nezvýrazňuje nic, aby nerozbil full-screen aplikace.
/// - Neúplnou escape sekvenci / UTF-8 znak na konci chunku podrží do dalšího chunku.
final class AnsiHighlighter {
    private var compiled: [CompiledRule] = []
    private var pending: [UInt8] = []
    private var sgrState: [UInt8] = []
    private var altScreen = false
    private static let reset: [UInt8] = Array("\u{1B}[0m".utf8)
    private static let maxSegment = 64 * 1024                 // B textu mezi escape sekvencemi
    private static let ruleBudget: UInt64 = 8_000_000         // 8 ms na pravidlo a blok
    private static let chunkBudget: UInt64 = 25_000_000       // 25 ms na blok celkem

    func process(_ chunk: ArraySlice<UInt8>) -> [UInt8] {
        compiled = HighlightCenter.shared.compiled
        let d = pending + Array(chunk)
        pending.removeAll(keepingCapacity: true)
        var out: [UInt8] = []
        out.reserveCapacity(d.count + 64)

        var i = 0, textStart = 0
        while i < d.count {
            guard d[i] == 0x1B else { i += 1; continue }
            emitText(d[textStart..<i], into: &out)
            guard let end = Self.escapeEnd(d, from: i) else {
                // neúplná sekvence na konci – počkat na další data (s pojistkou proti nekonečnému bufferu)
                if d.count - i > 4096 { out += d[i...] } else { pending = Array(d[i...]) }
                return out
            }
            let seq = d[i..<end]
            track(seq)
            out += seq
            i = end
            textStart = end
        }

        let tail = Self.incompleteUTF8Tail(d[textStart..<d.count])
        emitText(d[textStart..<(d.count - tail)], into: &out)
        if tail > 0 { pending = Array(d[(d.count - tail)...]) }
        return out
    }

    // MARK: - Zvýraznění textu

    private func emitText(_ bytes: ArraySlice<UInt8>, into out: inout [UInt8]) {
        guard !bytes.isEmpty else { return }
        // pojistka: velké bloky (cat velkého souboru) se nezvýrazňují, terminál nesmí zamrznout
        guard !altScreen, !compiled.isEmpty, bytes.count <= Self.maxSegment,
              let text = String(bytes: bytes, encoding: .utf8) else {
            out += bytes
            return
        }

        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var taken = IndexSet()
        var hits: [(range: NSRange, open: [UInt8])] = []

        let chunkStart = DispatchTime.now().uptimeNanoseconds
        for rule in compiled {
            let start = DispatchTime.now().uptimeNanoseconds
            if start - chunkStart > Self.chunkBudget { break }          // celkový rozpočet na blok
            var slow = false
            rule.regex.enumerateMatches(in: text, options: [.reportProgress], range: full) { m, _, stop in
                if DispatchTime.now().uptimeNanoseconds - start > Self.ruleBudget { slow = true; stop.pointee = true; return }
                guard let m, m.range.length > 0,
                      let r = Range<Int>(m.range), !taken.intersects(integersIn: r) else { return }
                taken.insert(integersIn: r)
                hits.append((m.range, rule.open))
            }
            if slow { HighlightCenter.shared.reportSlow(rule.id) }
        }
        guard !hits.isEmpty else { out += bytes; return }
        hits.sort { $0.range.location < $1.range.location }

        var cursor = 0
        for hit in hits {
            out.append(contentsOf: ns.substring(with: NSRange(location: cursor, length: hit.range.location - cursor)).utf8)
            out += hit.open
            out.append(contentsOf: ns.substring(with: hit.range).utf8)
            out += Self.reset
            out += sgrState            // vrátit styl, který nastavil server
            cursor = NSMaxRange(hit.range)
        }
        out.append(contentsOf: ns.substring(from: cursor).utf8)
    }

    // MARK: - Sledování stavu terminálu

    private func track(_ seq: ArraySlice<UInt8>) {
        guard seq.count >= 3, seq[seq.startIndex + 1] == 0x5B, let final = seq.last else { return } // jen CSI
        let params = String(decoding: seq.dropFirst(2).dropLast(), as: UTF8.self)

        switch final {
        case UInt8(ascii: "m"):
            if params.isEmpty || params == "0" { sgrState = [] }
            else if params.hasPrefix("0;") { sgrState = Array(seq) }
            else { sgrState += seq }
            if sgrState.count > 256 { sgrState = Array(seq) }
        case UInt8(ascii: "h"), UInt8(ascii: "l"):
            guard params.hasPrefix("?") else { return }
            let modes = params.dropFirst().split(separator: ";").map(String.init)
            if modes.contains(where: { ["47", "1047", "1049"].contains($0) }) {
                altScreen = (final == UInt8(ascii: "h"))
            }
        default:
            break
        }
    }

    /// Index za koncem escape sekvence začínající na `i`, nebo nil, pokud je neúplná.
    private static func escapeEnd(_ d: [UInt8], from i: Int) -> Int? {
        let n = d.count
        guard i + 1 < n else { return nil }
        switch d[i + 1] {
        case 0x5B: // CSI: ESC [ params intermediates final(0x40–0x7E)
            var j = i + 2
            while j < n {
                if (0x40...0x7E).contains(d[j]) { return j + 1 }
                j += 1
            }
            return nil
        case 0x5D, 0x50, 0x5E, 0x5F: // OSC, DCS, PM, APC – končí BEL nebo ST (ESC \)
            var j = i + 2
            while j < n {
                if d[j] == 0x07 { return j + 1 }
                if d[j] == 0x1B {
                    guard j + 1 < n else { return nil }
                    return d[j + 1] == 0x5C ? j + 2 : j
                }
                j += 1
            }
            return nil
        case 0x28...0x2B: // ESC ( X – volba znakové sady
            return i + 3 <= n ? i + 3 : nil
        default:
            return i + 2
        }
    }

    /// Kolik bajtů na konci tvoří nedokončený UTF-8 znak.
    private static func incompleteUTF8Tail(_ s: ArraySlice<UInt8>) -> Int {
        var k = 0
        var idx = s.endIndex
        while idx > s.startIndex && k < 4 {
            idx -= 1
            k += 1
            let b = s[idx]
            if b & 0xC0 == 0x80 { continue } // continuation byte
            let need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
            return need > k ? k : 0
        }
        return 0
    }
}
