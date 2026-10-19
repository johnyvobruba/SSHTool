import SwiftUI
import AppKit

// Nastavení → Zvýrazňování: kompaktní seznam pravidel (klik = detail), vyhledávání, filtry, skupiny,
// test výrazu, detekce konfliktů a přeřazení tažením. Bez @State/@Binding (makra nejsou v CLT).
//
// Priorita: pořadí shora. Každý znak textu obarví nejvýše jedno pravidlo – to první (s nejvyšší prioritou),
// které ho chytne. Zvýraznění se aplikuje jen na zobrazení; log a data relace zůstávají beze změny.

final class RulesEditorModel: ObservableObject {
    @Published var query = ""
    @Published var filter = "all"            // all | on | off | regex | literal
    @Published var expanded: UUID?
    @Published var paused: Set<UUID> = HighlightCenter.shared.paused
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: HighlightCenter.pausedChanged,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.paused = HighlightCenter.shared.paused
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var isFiltering: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty || filter != "all" }

    func matches(_ r: HighlightRule) -> Bool {
        switch filter {
        case "on": if !r.enabled { return false }
        case "off": if r.enabled { return false }
        case "regex": if !r.isRegex { return false }
        case "literal": if r.isRegex { return false }
        default: break
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return [r.pattern, r.group, r.testText].contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

// MARK: - Analýza (náhled s prioritou, konflikty)

enum RuleAnalysis {
    /// Aktivní pravidla tak, jak je použije terminál (vypnuté skupiny a pravidla vynechá).
    static func effective(_ rules: [HighlightRule], disabledGroups: [String]) -> [HighlightRule] {
        let off = Set(disabledGroups)
        return rules.filter { $0.enabled && !off.contains($0.group) && $0.compiledRegex != nil && !$0.sgrOpen.isEmpty }
    }

    /// Stejný algoritmus jako AnsiHighlighter: pravidla v pořadí, obsazené znaky už nikdo nepřebarví.
    static func assign(_ text: String, rules: [HighlightRule]) -> [(range: NSRange, rule: HighlightRule)] {
        var taken = IndexSet()
        var out: [(range: NSRange, rule: HighlightRule)] = []
        for r in rules {
            for m in r.matches(in: text) {
                guard let rr = Range<Int>(m), !taken.intersects(integersIn: rr) else { continue }
                taken.insert(integersIn: rr)
                out.append((range: m, rule: r))
            }
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// Text pro test pravidla: vlastní testovací text, jinak u doslovného výrazu samotný výraz.
    static func sample(for r: HighlightRule) -> String {
        if !r.testText.isEmpty { return r.testText }
        return r.isRegex ? "" : r.pattern
    }

    /// Pravidlo s vyšší prioritou, které přebírá (část) shody pravidla `r` v jeho testovacím textu.
    static func conflict(for r: HighlightRule, in all: [HighlightRule]) -> HighlightRule? {
        guard r.enabled else { return nil }
        let text = sample(for: r)
        guard !text.isEmpty else { return nil }
        let own = r.matches(in: text)
        guard !own.isEmpty, let idx = all.firstIndex(where: { $0.id == r.id }) else { return nil }
        let higher = all[..<idx].filter { $0.enabled }
        let assigned = assign(text, rules: Array(higher) + [r])
        for (range, rule) in assigned where rule.id != r.id {
            if own.contains(where: { NSIntersectionRange($0, range).length > 0 }) { return rule }
        }
        return nil
    }

    /// Obarvený text (pro náhledy) v barvách terminálového profilu.
    static func styled(_ text: String, rules: [HighlightRule], size: CGFloat = 11.5) -> AttributedString {
        var a = AttributedString(text)
        typealias A = AttributeScopes.SwiftUIAttributes
        a[A.FontAttribute.self] = Font.system(size: size, design: .monospaced)
        a[A.ForegroundColorAttribute.self] = SwiftUI.Color(hex: ThemeStore.terminal.foreground) ?? .white
        for (range, rule) in assign(text, rules: rules) {
            guard let r = Range(range, in: a) else { continue }
            if let fg = rule.foreground.flatMap({ SwiftUI.Color(hex: $0) }) { a[r][A.ForegroundColorAttribute.self] = fg }
            if let bg = rule.background.flatMap({ SwiftUI.Color(hex: $0) }) { a[r][A.BackgroundColorAttribute.self] = bg }
            if rule.bold { a[r][A.FontAttribute.self] = Font.system(size: size, weight: .bold, design: .monospaced) }
        }
        return a
    }
}

// MARK: - Panel nástrojů v záhlaví

struct RulesToolbar: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var model: RulesEditorModel

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(UI.textSecondary).font(.system(size: 11))
                TextField("Hledat pravidlo…", text: $model.query).textFieldStyle(.plain).font(SK.bodyFont)
            }
            .padding(.horizontal, 10)
            .frame(width: 190, height: SK.inputHeight)
            .background(RoundedRectangle(cornerRadius: SK.inputRadius).fill(UI.app))
            .overlay(RoundedRectangle(cornerRadius: SK.inputRadius).stroke(UI.border, lineWidth: 1))
            SKMenuPicker(selection: $model.filter,
                         options: [("all", "Všechna"), ("on", "Aktivní"), ("off", "Neaktivní"),
                                   ("regex", "Regex"), ("literal", "Doslovné")],
                         width: 120)
            Menu {
                Button("Importovat pravidla…") { store.importRulesPanel() }
                Button("Exportovat pravidla…") { store.exportRulesPanel() }
                Divider()
                Button("Obnovit výchozí sadu (Tabby)") { confirmReset() }
            } label: {
                Image(systemName: "ellipsis").frame(width: 32, height: SK.inputHeight)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .background(RoundedRectangle(cornerRadius: SK.inputRadius).fill(UI.card))
            .overlay(RoundedRectangle(cornerRadius: SK.inputRadius).stroke(UI.border, lineWidth: 1))
            Button {
                let r = HighlightRule(pattern: "", foreground: "#FFD866")
                store.rules.insert(r, at: 0)
                model.query = ""; model.filter = "all"
                model.expanded = r.id
            } label: { Label("Přidat pravidlo", systemImage: "plus") }
            .buttonStyle(SKButton(kind: .primary))
        }
    }

    private func confirmReset() {
        let a = NSAlert()
        a.messageText = "Obnovit výchozí pravidla?"
        a.informativeText = "Současná pravidla budou nahrazena sadou převzatou z Tabby. Tip: nejdřív je exportuj."
        a.addButton(withTitle: "Obnovit"); a.addButton(withTitle: "Zrušit")
        if a.runModal() == .alertFirstButtonReturn { store.resetRules() }
    }
}

// MARK: - Obsah

struct RulesEditorView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var model: RulesEditorModel

    private var effective: [HighlightRule] {
        RuleAnalysis.effective(store.rules, disabledGroups: store.settings.disabledRuleGroups)
    }

    var body: some View {
        if !store.settings.highlightEnabled {
            Label("Automatické zvýrazňování je vypnuté (Obecné → Automatické zvýrazňování).", systemImage: "pause.circle")
                .font(SK.helpFont).foregroundStyle(UI.connecting)
        }
        SKSection("Skupiny pravidel", subtitle: "Vypnutá skupina se v terminálu nepoužije. Skupinu pravidla změníš v jeho detailu nebo přetažením do jiné skupiny.", plain: true) {
            HStack(spacing: 8) {
                ForEach(store.ruleGroups, id: \.self) { g in groupChip(g) }
                Spacer()
            }
        }
        SKSection("Pravidla", subtitle: "Priorita = pořadí shora (#1 má přednost). Každý úsek textu obarví jen první pravidlo, které ho chytne. Pořadí změníš tažením za ≡. Změny se projeví okamžitě i v otevřených záložkách.", plain: true) {
            let all = store.rules
            let visible = all.indices.filter { model.matches(all[$0]) }
            if visible.isEmpty {
                Text(all.isEmpty ? "Žádná pravidla. Přidej první tlačítkem „Přidat pravidlo“." : "Žádné pravidlo neodpovídá hledání / filtru.")
                    .font(SK.bodyFont).foregroundStyle(UI.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            ForEach(store.ruleGroups, id: \.self) { g in
                let idx = visible.filter { all[$0].group == g }
                if !idx.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(g.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.4)
                            SKTag(text: "\(idx.count)")
                            if store.settings.disabledRuleGroups.contains(g) { SKTag(text: "vypnuto", color: UI.connecting) }
                        }
                        .foregroundStyle(UI.textSecondary)
                        .padding(.top, 6)
                        VStack(spacing: 0) {
                            ForEach(Array(idx.enumerated()), id: \.element) { n, i in
                                RuleItem(rule: binding(all[i].id), priority: i + 1, first: n == 0,
                                         model: model, all: all, effective: effective,
                                         onDelete: { delete(all[i].id) },
                                         onMove: { move(all[i].id, by: $0) },
                                         onDrop: { dropped in drop(dropped, onto: all[i].id) })
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: SK.cardRadius).fill(UI.card.opacity(0.55)))
                        .overlay(RoundedRectangle(cornerRadius: SK.cardRadius).stroke(UI.border, lineWidth: 1))
                    }
                }
            }
        }
    }

    private func groupChip(_ g: String) -> some View {
        let on = !store.settings.disabledRuleGroups.contains(g)
        let n = store.rules.filter { $0.group == g }.count
        return Button {
            if on { store.settings.disabledRuleGroups.append(g) }
            else { store.settings.disabledRuleGroups.removeAll { $0 == g } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? UI.accent : UI.textTertiary)
                Text(g).font(.system(size: 12, weight: .medium))
                Text("\(n)").font(.system(size: 10.5)).foregroundStyle(UI.textTertiary)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(Capsule().fill(on ? UI.rowSelected.opacity(0.6) : UI.card.opacity(0.55)))
            .overlay(Capsule().stroke(on ? UI.accent.opacity(0.6) : UI.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? UI.text : UI.textSecondary)
        .help(on ? "Vypnout skupinu" : "Zapnout skupinu")
    }

    private func binding(_ id: UUID) -> Binding<HighlightRule> {
        Binding(get: { store.rules.first { $0.id == id } ?? HighlightRule(pattern: "") },
                set: { new in if let i = store.rules.firstIndex(where: { $0.id == id }) { store.rules[i] = new } })
    }

    private func delete(_ id: UUID) {
        guard let r = store.rules.first(where: { $0.id == id }) else { return }
        if !r.pattern.isEmpty {
            let a = NSAlert()
            a.messageText = "Smazat pravidlo „\(r.pattern)“?"
            a.addButton(withTitle: "Smazat"); a.addButton(withTitle: "Zrušit")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        store.rules.removeAll { $0.id == id }
    }

    /// by: -1 nahoru, +1 dolů, Int.min na začátek.
    private func move(_ id: UUID, by d: Int) {
        guard let i = store.rules.firstIndex(where: { $0.id == id }) else { return }
        let j = d == Int.min ? 0 : min(max(i + d, 0), store.rules.count - 1)
        guard i != j else { return }
        let r = store.rules.remove(at: i)
        store.rules.insert(r, at: j)
    }

    /// Přetažení: pravidlo se vloží před cílové a převezme jeho skupinu.
    private func drop(_ dragged: String, onto target: UUID) -> Bool {
        guard let did = UUID(uuidString: dragged), did != target,
              var r = store.rules.first(where: { $0.id == did }) else { return false }
        var rules = store.rules
        rules.removeAll { $0.id == did }
        guard let t = rules.firstIndex(where: { $0.id == target }) else { return false }
        r.group = rules[t].group
        rules.insert(r, at: t)
        store.rules = rules
        return true
    }
}

// MARK: - Jedno pravidlo (kompaktní řádek + detail)

private struct RuleItem: View {
    let rule: Binding<HighlightRule>
    let priority: Int
    let first: Bool
    @ObservedObject var model: RulesEditorModel
    let all: [HighlightRule]
    let effective: [HighlightRule]
    let onDelete: () -> Void
    let onMove: (Int) -> Void
    let onDrop: (String) -> Bool
    @EnvironmentObject private var store: AppStore

    private var r: HighlightRule { rule.wrappedValue }
    private var open: Bool { model.expanded == r.id }

    var body: some View {
        VStack(spacing: 0) {
            compact
            if open { detail }
        }
        .overlay(alignment: .top) { if !first { SKDivider() } }
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first else { return false }
            return onDrop(s)
        }
    }

    // MARK: Kompaktní řádek (~52 pt)

    private var compact: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11)).foregroundStyle(UI.textTertiary)
                .frame(width: 14)
                .draggable(r.id.uuidString) {
                    Text(r.pattern.isEmpty ? "pravidlo" : r.pattern).font(SK.monoFont).padding(6)
                }
                .help("Táhni pro změnu pořadí")
            Text("#\(priority)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(UI.textTertiary)
                .frame(width: 26, alignment: .leading)
            SKToggle(isOn: rule.enabled).help(r.enabled ? "Aktivní – klikni pro vypnutí" : "Neaktivní")

            VStack(alignment: .leading, spacing: 3) {
                Text(r.pattern.isEmpty ? "(prázdný výraz)" : r.pattern)
                    .font(SK.monoFont)
                    .foregroundStyle(r.pattern.isEmpty ? UI.textTertiary : UI.text)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    previewChip
                    status
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SKTag(text: r.isRegex ? "Regex" : "Text", color: r.isRegex ? UI.accent : nil)
                .help(r.isRegex ? "Regex – regulární výraz" : "Text – doslovná shoda")
            if r.caseSensitive { SKTag(text: "Aa").help("Aa – rozlišuje velikost písmen") }
            if r.bold { SKTag(text: "B").help("B – tučné písmo") }
            colorDot(r.foreground, label: "Text")
            colorDot(r.background, label: "Pozadí")

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(UI.textTertiary)
                .rotationEffect(.degrees(open ? 90 : 0))
            Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundStyle(UI.textTertiary)
                .help("Smazat pravidlo")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
        .background(open ? UI.rowSelected.opacity(0.35) : SwiftUI.Color.clear)
        .opacity(r.enabled ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture { model.expanded = open ? nil : r.id }
    }

    private func colorDot(_ hex: String?, label: String) -> some View {
        Group {
            if let c = hex.flatMap({ SwiftUI.Color(hex: $0) }) {
                RoundedRectangle(cornerRadius: 4).fill(c).frame(width: 14, height: 14)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(UI.border, lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: 4).stroke(UI.border, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(width: 14, height: 14)
            }
        }
        .help("\(label): \(hex ?? "bez barvy")")
    }

    /// Skutečný barevný náhled shody.
    private var previewChip: some View {
        let sample: String = {
            let s = RuleAnalysis.sample(for: r)
            if r.isRegex, let m = r.matches(in: s).first { return (s as NSString).substring(with: m) }
            return s
        }()
        return Group {
            if sample.isEmpty {
                Text("Bez testovacího textu").font(.system(size: 10.5)).foregroundStyle(UI.textTertiary)
            } else {
                Text(RuleAnalysis.styled(sample, rules: [r], size: 11))
                    .lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(SwiftUI.Color(hex: ThemeStore.terminal.background) ?? .black))
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let err = r.regexError {
            Label(err, systemImage: "exclamationmark.triangle.fill").font(.system(size: 10.5)).foregroundStyle(UI.error).lineLimit(1)
        } else if model.paused.contains(r.id) {
            Label("Pozastaveno – výraz je příliš pomalý", systemImage: "tortoise.fill").font(.system(size: 10.5)).foregroundStyle(UI.connecting)
        } else if r.foreground == nil && r.background == nil && !r.bold {
            Label("Bez stylu – nic nezvýrazní", systemImage: "eye.slash").font(.system(size: 10.5)).foregroundStyle(UI.textTertiary)
        } else if let c = RuleAnalysis.conflict(for: r, in: all), let n = all.firstIndex(where: { $0.id == c.id }) {
            Label("Konflikt s #\(n + 1) „\(c.pattern)“", systemImage: "exclamationmark.triangle")
                .font(.system(size: 10.5)).foregroundStyle(UI.connecting).lineLimit(1)
                .help("Pravidlo #\(n + 1) má vyšší prioritu a obarví část stejného textu dřív.")
        }
    }

    // MARK: Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("Výraz") {
                TextField(r.isRegex ? "regulární výraz, např. \\b(?:zel|vap)-core-\\d+" : "hledaný text", text: rule.pattern)
                    .skField(mono: true)
            }
            HStack(spacing: 20) {
                field("Typ") {
                    Picker("", selection: rule.isRegex) {
                        Text("Text").tag(false)
                        Text("Regex").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                }
                field("Velikost písmen") {
                    HStack(spacing: 6) { SKToggle(isOn: rule.caseSensitive); Text("Rozlišovat (Aa)").font(SK.bodyFont) }
                        .frame(height: SK.inputHeight)
                }
                field("Tučné") {
                    HStack(spacing: 6) { SKToggle(isOn: rule.bold); Text("B").bold() }.frame(height: SK.inputHeight)
                }
                Spacer()
            }
            HStack(spacing: 28) {
                field("Barva textu") { SKColorChoice(hex: rule.foreground).frame(height: SK.inputHeight) }
                field("Barva pozadí") { SKColorChoice(hex: rule.background, noneLabel: "Bez pozadí").frame(height: SK.inputHeight) }
                field("Skupina") {
                    HStack(spacing: 4) {
                        TextField("General", text: rule.group).skField(width: 150)
                        Menu {
                            ForEach(store.ruleGroups, id: \.self) { g in Button(g) { rule.wrappedValue.group = g } }
                        } label: { Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
                Spacer()
            }
            field("Otestovat výraz") {
                TextField("vlož řádek ze skutečného výstupu, např. vap-core-vsx1-ch01-02", text: rule.testText)
                    .skField(mono: true)
            }
            testResult
            HStack(spacing: 8) {
                Text("Priorita #\(priority)").font(SK.helpFont).foregroundStyle(UI.textSecondary)
                Button("Na začátek") { onMove(Int.min) }.buttonStyle(SKButton(kind: .subtle)).disabled(priority == 1)
                Button { onMove(-1) } label: { Image(systemName: "arrow.up") }.buttonStyle(SKButton()).disabled(priority == 1)
                Button { onMove(1) } label: { Image(systemName: "arrow.down") }.buttonStyle(SKButton()).disabled(priority == all.count)
                Spacer()
                if model.paused.contains(r.id) {
                    Button("Znovu povolit") { HighlightCenter.shared.resume(r.id) }.buttonStyle(SKButton())
                }
                Button("Smazat", role: .destructive, action: onDelete).buttonStyle(SKButton(kind: .danger))
                Button("Hotovo") { model.expanded = nil }.buttonStyle(SKButton(kind: .primary))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(UI.rowSelected.opacity(0.2))
    }

    @ViewBuilder private var testResult: some View {
        let text = r.testText
        if let err = r.regexError {
            Label(err, systemImage: "xmark.octagon.fill").font(SK.helpFont).foregroundStyle(UI.error)
        } else if !text.isEmpty {
            let own = r.matches(in: text)
            VStack(alignment: .leading, spacing: 6) {
                if own.isEmpty {
                    Label("Výraz neodpovídá testovacímu textu", systemImage: "xmark.circle").foregroundStyle(UI.error)
                } else {
                    Label("Výraz odpovídá (\(own.count)×): " + own.prefix(3).map { "„" + (text as NSString).substring(with: $0) + "“" }.joined(separator: ", "),
                          systemImage: "checkmark.circle.fill").foregroundStyle(UI.ok)
                }
                if let c = RuleAnalysis.conflict(for: r, in: all), let n = all.firstIndex(where: { $0.id == c.id }) {
                    Label("Část shody obarví dřív pravidlo #\(n + 1) „\(c.pattern)“ (vyšší priorita). Přesuň toto pravidlo výš, pokud má mít přednost.",
                          systemImage: "exclamationmark.triangle").foregroundStyle(UI.connecting)
                }
                let used = RuleAnalysis.assign(text, rules: effective.contains(where: { $0.id == r.id }) ? effective : effective + [r])
                if !used.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(used.indices, id: \.self) { k in
                            let u = used[k]
                            let n = (all.firstIndex(where: { $0.id == u.rule.id }) ?? 0) + 1
                            HStack(spacing: 6) {
                                Text("„" + (text as NSString).substring(with: u.range) + "“").font(SK.monoFont)
                                Image(systemName: "arrow.right").font(.system(size: 9))
                                Text("použito pravidlo #\(n)" + (u.rule.id == r.id ? " (toto)" : " „\(u.rule.pattern)“"))
                                    .foregroundStyle(u.rule.id == r.id ? UI.ok : UI.connecting)
                            }
                        }
                    }
                }
                Text("Náhled se všemi aktivními pravidly (skutečná priorita):").foregroundStyle(UI.textSecondary)
                Text(RuleAnalysis.styled(text, rules: effective.contains(where: { $0.id == r.id }) ? effective : effective + [r]))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(SwiftUI.Color(hex: ThemeStore.terminal.background) ?? .black))
            }
            .font(SK.helpFont)
        }
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(UI.textSecondary)
            c()
        }
    }
}
