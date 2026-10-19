import Foundation

/// Ekvivalent řádku z Tabby highlight pluginu: zapnuto, (.*) regex, Aa case-sensitive, keyword, styl.
/// Pořadí v poli = priorita (první pravidlo, které chytne daný úsek textu, vyhrává).
struct HighlightRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var enabled = true
    var pattern: String
    var isRegex = false
    var caseSensitive = false
    var foreground: String? = nil   // "#RRGGBB"
    var background: String? = nil
    var bold = false
    /// Skupina pravidel (General, Check Point, Networking…) – celou skupinu lze vypnout.
    var group = "General"
    /// Vlastní testovací text pro ověření výrazu v editoru.
    var testText = ""

    enum CodingKeys: String, CodingKey {
        case id, enabled, pattern, isRegex, caseSensitive, foreground, background, bold, group, testText
    }

    /// Zkompilovaný výraz (literál je escapovaný), nil = neplatný nebo prázdný.
    var compiledRegex: NSRegularExpression? {
        guard !pattern.isEmpty else { return nil }
        let p = isRegex ? pattern : NSRegularExpression.escapedPattern(for: pattern)
        return try? NSRegularExpression(pattern: p, options: caseSensitive ? [] : [.caseInsensitive])
    }

    /// Shody v textu (pro test a náhled v editoru).
    func matches(in text: String) -> [NSRange] {
        guard let re = compiledRegex else { return [] }
        return re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            .map(\.range).filter { $0.length > 0 }
    }

    /// SGR sekvence, která zapne styl (truecolor).
    var sgrOpen: [UInt8] {
        var parts: [String] = []
        if bold { parts.append("1") }
        if let c = foreground.flatMap(RGBColor.init(hex:)) { parts.append("38;2;\(c.r);\(c.g);\(c.b)") }
        if let c = background.flatMap(RGBColor.init(hex:)) { parts.append("48;2;\(c.r);\(c.g);\(c.b)") }
        guard !parts.isEmpty else { return [] }
        return Array("\u{1B}[\(parts.joined(separator: ";"))m".utf8)
    }

    /// Chyba kompilace regexu (pro editor), nil = v pořádku.
    var regexError: String? {
        guard isRegex, !pattern.isEmpty else { return nil }
        do { _ = try NSRegularExpression(pattern: pattern); return nil }
        catch {
            return "Neplatný regulární výraz – zkontroluj závorky, [ ] a escapování \\"
        }
    }

    /// Převzato z Tabby (highlightPlugin → profil Default). Indexy barev Tabby jsou převedené
    /// na RGB podle schématu „Tabby Default“ (0 #000000, 1 #FF615A, 2 #B1E969, 3 #EBD99C,
    /// 4 #5DA9F6, 7 #DEDACF, 9 #F58C80).
    static let defaults: [HighlightRule] = [
        .init(pattern: "R81", foreground: "#000000", background: "#B1E969", group: "Check Point"),
        .init(pattern: "ACTIVE", foreground: "#5DA9F6", bold: true, testText: "1 (local)  10.0.0.1  ACTIVE"),
        .init(pattern: "BOOTING", foreground: "#000000", background: "#FF615A"),
        .init(pattern: #"(?<!\d)1_\d+(?!\d)"#, isRegex: true, foreground: "#B1E969", group: "Check Point"),
        .init(pattern: #"\b(?:zel|vap)-core-vsx1-ch\d{2}-\d{2}\b"#, isRegex: true, foreground: "#DEDACF", bold: true, group: "Check Point", testText: "vap-core-vsx1-ch01-02"),
        .init(pattern: #"failed?"#, isRegex: true, foreground: "#F58C80"),
        .init(pattern: "TX", caseSensitive: true, foreground: "#EBD99C", group: "Networking"),
        .init(pattern: "RX", caseSensitive: true, foreground: "#EBD99C", group: "Networking"),
        // rozhraní: eth*, bond*, Sync, magg* + subinterface (.848, -1, _x)
        .init(pattern: #"(?<![A-Za-z0-9_])(eths?[A-Za-z0-9]+|bond[0-9]+|Sync|magg[0-9]*)(?:[._-][A-Za-z0-9]+)*(?![A-Za-z0-9_])"#,
              isRegex: true, foreground: "#0092B3", group: "Networking", testText: "eth1-02.848 bond0 Sync magg1"),
        // IPv6 vč. zkrácených tvarů (fe80::1, 2001:db8::/32) a prefixu. Oproti Tabby opraveno:
        // původní regex zvýrazňoval MAC adresy a časy a nechytal zkrácené adresy s „::“ uprostřed.
        .init(pattern: #"(?<![0-9A-Fa-f:.])(?:(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|(?:[0-9A-Fa-f]{1,4}:){1,7}:|(?:[0-9A-Fa-f]{1,4}:){1,6}:[0-9A-Fa-f]{1,4}|(?:[0-9A-Fa-f]{1,4}:){1,5}(?::[0-9A-Fa-f]{1,4}){1,2}|(?:[0-9A-Fa-f]{1,4}:){1,4}(?::[0-9A-Fa-f]{1,4}){1,3}|(?:[0-9A-Fa-f]{1,4}:){1,3}(?::[0-9A-Fa-f]{1,4}){1,4}|(?:[0-9A-Fa-f]{1,4}:){1,2}(?::[0-9A-Fa-f]{1,4}){1,5}|[0-9A-Fa-f]{1,4}:(?::[0-9A-Fa-f]{1,4}){1,6}|:(?:(?::[0-9A-Fa-f]{1,4}){1,7}|:))(?:/(?:12[0-8]|1[01]\d|\d?\d))?(?![0-9A-Fa-f:])"#,
              isRegex: true, foreground: "#00B336", group: "Networking", testText: "fe80::1 2001:db8::/32 00:1c:7f:aa:bb:cc 12:30:01"),
        .init(pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, isRegex: true, foreground: "#00B336", bold: true, group: "Networking", testText: "eth1: 192.0.2.10"),
        .init(pattern: #"errors?"#, isRegex: true, foreground: "#FF615A"),
    ]
}

/// Tolerantní dekódování – chybějící klíče (starší / importované soubory) dostanou výchozí hodnotu.
extension HighlightRule {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        isRegex = try c.decodeIfPresent(Bool.self, forKey: .isRegex) ?? false
        caseSensitive = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
        foreground = try c.decodeIfPresent(String.self, forKey: .foreground)
        background = try c.decodeIfPresent(String.self, forKey: .background)
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? "General"
        testText = try c.decodeIfPresent(String.self, forKey: .testText) ?? ""
    }
}
