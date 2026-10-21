import SwiftUI
import AppKit

// Okno nastavení (⌘,) – postranní navigace jako v Nastavení systému, fixní záhlaví, scrollovatelný obsah.
// Jednotný systém komponent (SK*): vstupy a tlačítka 32 pt, řádek 44 pt, karty 10 pt, sekce 24 pt.

// MARK: - Design tokeny

enum SK {
    static let inputHeight: CGFloat = 32
    static let rowHeight: CGFloat = 44
    static let compactRow: CGFloat = 36
    static let toolbarHeight: CGFloat = 56
    static let inputRadius: CGFloat = 7
    static let cardRadius: CGFloat = 10
    static let hPad: CGFloat = 16
    static let sectionGap: CGFloat = 24
    static let titleFont = Font.system(size: 15, weight: .semibold)      // název sekce
    static let pageTitleFont = Font.system(size: 22, weight: .semibold)  // název stránky
    static let subtitleFont = Font.system(size: 13)                       // podtitulek stránky
    static let contentMaxWidth: CGFloat = 760
    static let bodyFont = Font.system(size: 13)
    static let helpFont = Font.system(size: 11.5)
    static let monoFont = Font.system(size: 12, design: .monospaced)
}

// MARK: - Komponenty

/// Sekce: nadpis 14 pt, volitelný popis, obsah v kartě (nebo bez karty – `plain`).
struct SKSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var plain = false
    let content: Content

    init(_ title: String, subtitle: String? = nil, plain: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.plain = plain; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(SK.titleFont).foregroundStyle(UI.text)
                if let subtitle {
                    Text(subtitle).font(SK.helpFont).foregroundStyle(UI.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if plain {
                content
            } else {
                VStack(spacing: 0) { content }
                    .background(RoundedRectangle(cornerRadius: SK.cardRadius).fill(UI.card.opacity(0.55)))
                    .overlay(RoundedRectangle(cornerRadius: SK.cardRadius).stroke(UI.border, lineWidth: 1))
            }
        }
    }
}

/// Řádek nastavení: popisek (13 pt) + nápověda (11,5 pt) vlevo, ovládací prvek vpravo.
struct SKRow<Control: View>: View {
    let title: String
    var help: String? = nil
    var first = false
    let control: Control

    init(_ title: String, help: String? = nil, first: Bool = false, @ViewBuilder control: () -> Control) {
        self.title = title; self.help = help; self.first = first; self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(SK.bodyFont).foregroundStyle(UI.text)
                if let help {
                    Text(help).font(SK.helpFont).foregroundStyle(UI.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, SK.hPad).padding(.vertical, 8)
        .frame(minHeight: SK.rowHeight)
        .overlay(alignment: .top) { if !first { SKDivider() } }
    }
}

struct SKDivider: View {
    var body: some View { Rectangle().fill(UI.border.opacity(0.6)).frame(height: 1).padding(.leading, SK.hPad) }
}

/// Jednotný přepínač (vždy stejná velikost).
struct SKToggle: View {
    let isOn: Binding<Bool>
    var body: some View {
        Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
    }
}

/// Jednotné textové pole 32 pt.
extension View {
    func skField(width: CGFloat? = nil, mono: Bool = false) -> some View {
        self.textFieldStyle(.plain)
            .font(mono ? SK.monoFont : SK.bodyFont)
            .padding(.horizontal, 10)
            .frame(width: width, height: SK.inputHeight)
            .background(RoundedRectangle(cornerRadius: SK.inputRadius).fill(UI.app))
            .overlay(RoundedRectangle(cornerRadius: SK.inputRadius).stroke(UI.border, lineWidth: 1))
    }
}

/// Jednotná tlačítka 32 pt.
struct SKButton: ButtonStyle {
    enum Kind { case normal, primary, danger, subtle }
    var kind: Kind = .normal
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let bg: SwiftUI.Color = {
            switch kind {
            case .primary: return UI.accent
            case .danger: return UI.error.opacity(0.15)
            case .normal: return UI.card
            case .subtle: return SwiftUI.Color.clear
            }
        }()
        let fg: SwiftUI.Color = kind == .primary ? .white : (kind == .danger ? UI.error : UI.text)
        return configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: SK.inputHeight)
            .background(RoundedRectangle(cornerRadius: SK.inputRadius).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: SK.inputRadius)
                .stroke(kind == .normal ? UI.border : SwiftUI.Color.clear, lineWidth: 1))
            .foregroundStyle(fg)
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

/// Rozbalovací výběr ve stylu vstupního pole (32 pt).
struct SKMenuPicker<T: Hashable>: View {
    let selection: Binding<T>
    let options: [(T, String)]
    var width: CGFloat = 220

    var body: some View {
        let current = options.first { $0.0 == selection.wrappedValue }?.1 ?? "Vlastní"
        Menu {
            ForEach(options.indices, id: \.self) { i in
                Button {
                    selection.wrappedValue = options[i].0
                } label: {
                    if options[i].0 == selection.wrappedValue { Label(options[i].1, systemImage: "checkmark") }
                    else { Text(options[i].1) }
                }
            }
        } label: {
            HStack {
                Text(current).font(SK.bodyFont).foregroundStyle(UI.text).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(UI.textSecondary)
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: SK.inputHeight)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: width, height: SK.inputHeight)
        .background(RoundedRectangle(cornerRadius: SK.inputRadius).fill(UI.app))
        .overlay(RoundedRectangle(cornerRadius: SK.inputRadius).stroke(UI.border, lineWidth: 1))
    }
}

/// Výběr barvy: kroužek (klik = macOS Color Picker) + HEX + „Bez barvy“. Žádný checkbox.
struct SKColorChoice: View {
    let hex: Binding<String?>
    var noneLabel = "Bez barvy"

    var body: some View {
        HStack(spacing: 8) {
            ColorPicker("", selection: Binding(
                get: { SwiftUI.Color(hex: hex.wrappedValue ?? "#808080") ?? .gray },
                set: { hex.wrappedValue = $0.hexString }),
                supportsOpacity: false)
                .labelsHidden()
                .opacity(hex.wrappedValue == nil ? 0.35 : 1)
                .help("Klikni pro výběr barvy")
            if let h = hex.wrappedValue {
                Text(h.uppercased()).font(.system(size: 11, design: .monospaced)).foregroundStyle(UI.textSecondary)
                Button { hex.wrappedValue = nil } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(UI.textTertiary)
                .help(noneLabel)
            } else {
                Text(noneLabel).font(.system(size: 11)).foregroundStyle(UI.textTertiary)
            }
        }
    }
}

/// Malý štítek (Regex, Aa, skupina…).
struct SKTag: View {
    let text: String
    var color: SwiftUI.Color? = nil
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill((color ?? UI.textSecondary).opacity(0.16)))
            .foregroundStyle(color ?? UI.textSecondary)
            .fixedSize()
    }
}

// MARK: - Kořen okna nastavení

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, terminal, highlight, snippets, logging, servers, shortcuts, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "Obecné"
        case .appearance: return "Vzhled"
        case .terminal: return "Terminál"
        case .highlight: return "Zvýrazňování"
        case .logging: return "Logování"
        case .servers: return "Import serverů"
        case .snippets: return "Snippety"
        case .shortcuts: return "Klávesové zkratky"
        case .about: return "O aplikaci"
        }
    }
    var subtitle: String {
        switch self {
        case .general: return "Rozhraní a chování aplikace"
        case .appearance: return "Barevný profil aplikace a terminálu"
        case .terminal: return "Písmo, historie, schránka"
        case .highlight: return "Pravidla barevného zvýraznění výstupu"
        case .logging: return "Automatické ukládání výstupu relací"
        case .servers: return "Import a export serverů, vzor JSON pro kolegy"
        case .snippets: return "Uložené příkazy pro rychlé vložení do terminálu"
        case .shortcuts: return "Přehled klávesových zkratek"
        case .about: return AppCredits.line
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .terminal: return "terminal"
        case .highlight: return "paintbrush"
        case .logging: return "doc.text"
        case .servers: return "square.and.arrow.down"
        case .snippets: return "text.append"
        case .shortcuts: return "keyboard"
        case .about: return "info.circle"
        }
    }
}

final class SettingsNav: ObservableObject {
    @Published var pane: SettingsPane = .appearance
}

struct SettingsRootView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var nav = SettingsNav()
    @StateObject private var rules = RulesEditorModel()

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(UI.border).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(UI.border).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: SK.sectionGap) { content }
                        .frame(maxWidth: SK.contentMaxWidth, alignment: .leading)   // obsah se neroztahuje
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(nav.pane)          // nová sekce začíná nahoře; změna tématu pozici scrollu zachová
            }
            .background(UI.app)
        }
        .frame(minWidth: 850, idealWidth: 1040, maxWidth: .infinity, minHeight: 600, idealHeight: 720, maxHeight: .infinity)
        .tint(UI.accent)
        .background(WindowTitleSetter(title: "Nastavení"))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Nastavení")
                .font(.system(size: 11, weight: .semibold)).tracking(0.4)
                .foregroundStyle(UI.textTertiary)
                .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 6)
            ForEach(SettingsPane.allCases) { p in
                let on = nav.pane == p
                Button { nav.pane = p } label: {
                    HStack(spacing: 10) {
                        Image(systemName: p.icon).font(.system(size: 12)).frame(width: 18)
                            .foregroundStyle(on ? UI.accent : UI.textSecondary)
                        Text(p.title).font(.system(size: 13, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? UI.text : UI.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: SK.inputRadius).fill(on ? UI.rowSelected : SwiftUI.Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 2) {
                Text("SSHTool \(version)").font(.system(size: 10.5, weight: .medium))
                Text(AppCredits.line).font(.system(size: 10))
            }
            .foregroundStyle(UI.textTertiary)
            .padding(10)
        }
        .padding(.horizontal, 10)
        .frame(width: 230)
        .background(UI.sidebar)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(nav.pane.title).font(SK.pageTitleFont).foregroundStyle(UI.text)
                Text(nav.pane.subtitle).font(SK.subtitleFont).foregroundStyle(UI.textSecondary)
            }
            Spacer()
            if nav.pane == .highlight { RulesToolbar(model: rules) }
        }
        .padding(.horizontal, 28)
        .frame(height: 76)
        .background(UI.chrome)
    }

    @ViewBuilder private var content: some View {
        switch nav.pane {
        case .general: SettingsGeneralPane()
        case .appearance: SettingsAppearancePane()
        case .terminal: SettingsTerminalPane()
        case .highlight: RulesEditorView(model: rules)
        case .logging: SettingsLoggingPane()
        case .servers: SettingsServersPane()
        case .snippets: SettingsSnippetsPane()
        case .shortcuts: SettingsShortcutsPane()
        case .about: SettingsAboutPane()
        }
    }
}

// MARK: - Obecné (Rozhraní a chování)

struct SettingsGeneralPane: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        SKSection("Rozhraní a chování") {
            SKRow("Režim levého panelu", help: "Kompaktní zobrazení názvu a IP adresy.", first: true) {
                SKMenuPicker(selection: $store.settings.sidebarComfortable,
                             options: [(false, "Kompaktní (1 řádek)"), (true, "Dvouřádkový (název / IP)")])
                    .help("Kompaktní: název a IP na jednom řádku – IP vždy celá, dlouhý název se zkrátí „…“. Dvouřádkový: IP pod názvem.")
            }
            SKRow("Zobrazit sekci Oblíbené") { SKToggle(isOn: $store.settings.showFavorites) }
            SKRow("Automatické zvýrazňování", help: "Pravidla v sekci Zvýrazňování.") {
                SKToggle(isOn: $store.settings.highlightEnabled)
            }
            SKRow("Měření latence", help: "Ping každých 10 s u připojené relace.") {
                SKToggle(isOn: $store.settings.latencyEnabled)
                    .help("ICMP ping k serveru – nevytváří SSH spojení ani záznamy v logu sshd. Pokud ICMP blokuje firewall, ukáže se „ICMP –“.")
            }
            SKRow("FreeRDP (RDP relace)", help: FreeRDP.binary.map { "Nalezeno: \($0)" } ?? "Nenalezeno – brew install freerdp") {
                HStack(spacing: 6) {
                    TextField("automaticky", text: $store.settings.freerdpPath).skField(width: 200, mono: true)
                    Button("Vybrat…") {
                        let p = NSOpenPanel(); p.title = "Klient FreeRDP (sdl-freerdp / xfreerdp)"
                        p.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
                        if p.runModal() == .OK, let u = p.url { store.settings.freerdpPath = u.path }
                    }.buttonStyle(SKButton())
                }
            }
            SKRow("Monitor serveru automaticky", help: "CPU, RAM a disk ve stavovém řádku po přihlášení.") {
                SKToggle(isOn: $store.settings.monitorAuto)
                    .help("Přes stejné SSH spojení (bez nového přihlášení) čte každých 5 s /proc a df. Jen Linux / Gaia s uživatelem s bash/sh; jinak „Monitor –“. Vypnuto: monitor zapneš kliknutím na „Monitor“ ve stavovém řádku.")
            }
            SKRow("Režim soustředění: stavový řádek", help: "⌥⌘F skryje levý panel a záložky.") {
                SKToggle(isOn: $store.settings.focusShowStatus)
            }
        }
    }
}

// MARK: - Vzhled

struct SettingsAppearancePane: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        SKSection("Barevný profil aplikace",
                  subtitle: "Profil aktivuješ kliknutím na kartu. Změna nerestartuje SSH relace ani nemaže historii.",
                  plain: true) {
            VStack(spacing: 8) {
                ForEach(Theme.all) { t in
                    ThemeCard(theme: t, selected: store.settings.themeID == t.id) { pick(t) }
                }
            }
        }
        SKSection("Barevný profil terminálu", subtitle: "Např. tmavé rozhraní a jiná paleta samotného terminálu.") {
            SKRow("Profil terminálu", first: true) {
                Picker("", selection: $store.settings.terminalFollowsApp) {
                    Text("Stejný jako aplikace").tag(true)
                    Text("Vlastní profil").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 280)
            }
            if !store.settings.terminalFollowsApp {
                SKRow("Vlastní profil") {
                    SKMenuPicker(selection: $store.settings.terminalThemeID,
                                 options: Theme.all.map { ($0.id, $0.name) })
                }
            }
        }
        SKSection("Automatický vzhled") {
            SKRow("Režim", help: "Podle macOS: ve tmavém režimu zvolený tmavý profil, ve světlém Arctic Light.", first: true) {
                Picker("", selection: $store.settings.appearance) {
                    Text("Světlý").tag("light")
                    Text("Tmavý").tag("dark")
                    Text("Podle macOS").tag("system")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 280)
            }
        }
    }

    private func pick(_ t: Theme) {
        store.settings.themeID = t.id
        // výběr světlého/tmavého profilu přepne i režim, ať je změna hned vidět
        if !t.isDark { store.settings.appearance = "light" }
        else if store.settings.appearance == "light" { store.settings.appearance = "dark" }
    }
}

/// Karta profilu – celá klikací, bez radio buttonu. Aktivní: jemné pozadí, rámeček, ✓ „Aktivní“.
final class ThemeCardModel: ObservableObject {
    @Published var hover = false
    @Published var showUI = false
}

struct ThemeCard: View {
    let theme: Theme
    let selected: Bool
    let pick: () -> Void
    @StateObject private var m = ThemeCardModel()

    private func c(_ h: String) -> SwiftUI.Color { SwiftUI.Color(hex: h) ?? .gray }

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(theme.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(UI.text)
                        if selected {
                            HStack(spacing: 3) {
                                Image(systemName: "checkmark.circle.fill")
                                Text("Aktivní")
                            }
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(UI.accent)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(UI.accent.opacity(0.15)))
                        }
                    }
                    Text(theme.note).font(SK.helpFont).foregroundStyle(UI.textSecondary).lineLimit(1)
                    HStack(spacing: 4) {
                        ForEach([theme.sidebarBackground, theme.tabActiveBackground, theme.accentColor,
                                 theme.statusConnected, theme.statusConnecting, theme.statusError], id: \.self) { h in
                            RoundedRectangle(cornerRadius: 3).fill(c(h)).frame(width: 12, height: 12)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(UI.border, lineWidth: 0.5))
                        }
                        Button { m.showUI = true } label: {
                            Label("Náhled rozhraní", systemImage: "macwindow").font(.system(size: 10.5))
                        }
                        .buttonStyle(.plain).foregroundStyle(UI.accent)
                        .padding(.leading, 8)
                        .opacity(m.hover || m.showUI ? 1 : 0)
                        .popover(isPresented: $m.showUI, arrowEdge: .trailing) { AppUIPreview(theme: theme).padding(12) }
                    }
                }
                .frame(width: (g.size.width - 46) * 0.6, alignment: .leading)
                ThemePreview(theme: theme, width: (g.size.width - 46) * 0.4)
            }
            .padding(.horizontal, 16)
            .frame(width: g.size.width, height: g.size.height)
        }
        .frame(height: 96)
        .background(RoundedRectangle(cornerRadius: SK.cardRadius)
            .fill(selected ? UI.rowSelected.opacity(0.6) : m.hover ? UI.hover : UI.card.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: SK.cardRadius)
            .stroke(selected ? UI.accent : UI.border, lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
        .onHover { m.hover = $0 }
        .onTapGesture(perform: pick)
        .help(selected ? "Aktivní profil" : "Kliknutím aktivovat")
    }
}

/// Zmenšený náhled celé aplikace v barvách profilu: lišta záložek, levý panel, terminál, stavový řádek.
struct AppUIPreview: View {
    let theme: Theme
    private func c(_ h: String) -> SwiftUI.Color { SwiftUI.Color(hex: h) ?? .gray }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(theme.name) – náhled rozhraní").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 0) {
                // levý panel
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) { Circle().fill(c("#FF5F57")); Circle().fill(c("#FEBC2E")); Circle().fill(c("#28C840")) }
                        .frame(height: 8).padding(.bottom, 6)
                    RoundedRectangle(cornerRadius: 5).fill(c(theme.tabInactiveBackground)).frame(height: 18)
                        .overlay(Text("Hledat…").font(.system(size: 9)).foregroundColor(c(theme.textTertiary)).padding(.leading, 6), alignment: .leading)
                    Text("ZÁKAZNÍK A").font(.system(size: 8.5, weight: .semibold)).foregroundColor(c(theme.textSecondary)).padding(.top, 4)
                    row("fw1-praha", "192.0.2.10", theme.statusConnected, selected: true)
                    row("fw2-praha", "192.0.2.11", theme.statusConnecting)
                    Text("LAB").font(.system(size: 8.5, weight: .semibold)).foregroundColor(c(theme.textSecondary)).padding(.top, 4)
                    row("lab-linux", "203.0.113.5", theme.textTertiary)
                    Spacer()
                }
                .padding(8).frame(width: 150).background(c(theme.sidebarBackground))
                Rectangle().fill(c(theme.borderColor)).frame(width: 1)
                VStack(spacing: 0) {
                    // lišta záložek
                    HStack(spacing: 4) {
                        tab("fw1-praha", active: true, dot: theme.statusConnected)
                        tab("lab-linux", active: false, dot: theme.statusError)
                        Spacer()
                    }
                    .padding(6).background(c(theme.toolbarBackground))
                    Rectangle().fill(c(theme.borderColor)).frame(height: 1)
                    ThemePreview(theme: theme, width: 290, bordered: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(c(theme.background))
                    Rectangle().fill(c(theme.borderColor)).frame(height: 1)
                    HStack(spacing: 6) {
                        Circle().fill(c(theme.statusConnected)).frame(width: 5, height: 5)
                        Text("Připojeno").foregroundColor(c(theme.statusConnected))
                        Text("· ZÁKAZNÍK A / fw1-praha · 192.0.2.10 · 3 ms").foregroundColor(c(theme.textSecondary))
                        Spacer()
                    }
                    .font(.system(size: 8.5)).padding(.horizontal, 6).frame(height: 18).background(c(theme.appBackground))
                }
            }
            .frame(width: 470, height: 230)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(c(theme.borderColor), lineWidth: 1))
        }
    }

    private func row(_ name: String, _ ip: String, _ dot: String, selected: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "desktopcomputer").font(.system(size: 8)).foregroundColor(c(theme.accentColor))
            Text(name).font(.system(size: 9, weight: .medium)).foregroundColor(c(theme.textPrimary))
            Spacer(minLength: 2)
            Text(ip).font(.system(size: 8, design: .monospaced)).foregroundColor(c(theme.textSecondary))
            Circle().fill(c(dot)).frame(width: 5, height: 5)
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? c(theme.itemSelectedBackground) : SwiftUI.Color.clear))
    }

    private func tab(_ name: String, active: Bool, dot: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(c(theme.accentColor)).frame(width: 2, height: 12)
            Text(name).font(.system(size: 9, weight: active ? .semibold : .regular))
                .foregroundColor(c(active ? theme.textPrimary : theme.textSecondary))
            Circle().fill(c(dot)).frame(width: 5, height: 5)
        }
        .padding(.horizontal, 6).frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 5).fill(c(active ? theme.tabActiveBackground : theme.tabInactiveBackground)))
        .overlay(alignment: .bottom) { if active { Rectangle().fill(c(theme.accentColor)).frame(height: 1.5).padding(.horizontal, 4) } }
    }
}

/// Náhled terminálu 280 × 76 pt, SF Mono 10,5 pt – obsahuje všechny důležité barvy.
struct ThemePreview: View {
    let theme: Theme
    var width: CGFloat = 240
    var bordered = true
    private func c(_ h: String) -> SwiftUI.Color { SwiftUI.Color(hex: h) ?? .gray }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            (Text("[Expert@fw1:0]# ").foregroundColor(c(theme.ansiNormal[2]))
             + Text("cphaprob state").foregroundColor(c(theme.foreground)))
            (Text("1 (local)  ").foregroundColor(c(theme.foreground))
             + Text("10.0.0.1").foregroundColor(c(theme.ansiNormal[6]))
             + Text("  ACTIVE").foregroundColor(c(theme.ansiNormal[4])).bold())
            (Text("2          ").foregroundColor(c(theme.foreground))
             + Text("10.0.0.2").foregroundColor(c(theme.ansiNormal[6]))
             + Text("  STANDBY").foregroundColor(c(theme.ansiNormal[3])))
            (Text("eth1 ").foregroundColor(c(theme.ansiNormal[5]))
             + Text("errors 0 ").foregroundColor(c(theme.foreground))
             + Text("failed").foregroundColor(c(theme.ansiNormal[1])))
        }
        .font(.system(size: 10, design: .monospaced))
        .lineLimit(1)
        .padding(10)
        .frame(width: width, height: 76, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(c(theme.background)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(c(theme.borderColor), lineWidth: bordered ? 1 : 0))
    }
}

// MARK: - Terminál

struct SettingsTerminalPane: View {
    @EnvironmentObject private var store: AppStore

    private var fontOptions: [(String, String)] {
        AppSettings.fontChoices
            .filter { $0.name.isEmpty || NSFont(name: $0.name, size: 13) != nil }
            .map { ($0.name, $0.label) }
    }

    private var scrollbackOptions: [(Int, String)] {
        var o: [(Int, String)] = AppSettings.scrollbackChoices.map { ($0, "\($0.formatted()) řádků") }
        let cur = store.settings.scrollback
        o.append((AppSettings.scrollbackChoices.contains(cur) ? 30_000 : cur, "Vlastní hodnota…"))
        return o
    }

    private var scrollbackBinding: Binding<Int> {
        Binding(get: { store.settings.scrollback },
                set: { store.settings.scrollback = min(max($0, 1_000), 1_000_000) })
    }

    var body: some View {
        SKSection("Písmo") {
            SKRow("Písmo terminálu", help: "JetBrains / Geist / Berkeley Mono se nabídnou, jen pokud jsou nainstalované.", first: true) {
                SKMenuPicker(selection: $store.settings.fontName, options: fontOptions)
            }
            SKRow("Velikost písma", help: "⌘+ / ⌘− / ⌘0, nebo ⌥⌘ + dva prsty.") {
                HStack(spacing: 8) {
                    Text("\(Int(store.settings.fontSize)) pt").font(SK.bodyFont).monospacedDigit().frame(width: 44, alignment: .trailing)
                    Stepper("", value: $store.settings.fontSize, in: AppSettings.fontSizeRange, step: 1).labelsHidden()
                }
            }
            SKRow("Řádkování", help: "Výchozí Normal 1,15×. Dvojklik na hodnotu obnoví výchozí.") {
                VStack(alignment: .trailing, spacing: 6) {
                    Picker("", selection: Binding(
                        get: { [1.05, 1.15, 1.25].first { abs($0 - store.settings.lineSpacing) < 0.001 } ?? 0 },
                        set: { if $0 > 0 { store.settings.lineSpacing = $0 } })) {
                        Text("Compact").tag(1.05)
                        Text("Normal").tag(1.15)
                        Text("Comfortable").tag(1.25)
                        if ![1.05, 1.15, 1.25].contains(where: { abs($0 - store.settings.lineSpacing) < 0.001 }) {
                            Text("Vlastní").tag(0.0)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                    HStack(spacing: 10) {
                        Slider(value: $store.settings.lineSpacing, in: 1.0...1.5, step: 0.05).frame(width: 200)
                        Text(String(format: "%.2f×", store.settings.lineSpacing))
                            .font(SK.bodyFont).monospacedDigit().frame(width: 48, alignment: .trailing)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { store.settings.lineSpacing = 1.15 }
                            .help("Dvojklik = výchozí 1,15×")
                    }
                }
            }
            FontPreview(settings: store.settings)
                .padding(.horizontal, SK.hPad).padding(.bottom, 14).padding(.top, 4)
        }
        SKSection("Historie terminálu (scrollback)") {
            SKRow("Počet řádků", help: "\(store.settings.scrollback.formatted()) řádků · spotřeba paměti závisí na délce a formátování výstupu.", first: true) {
                HStack(spacing: 8) {
                    if !AppSettings.scrollbackChoices.contains(store.settings.scrollback) {
                        TextField("", value: scrollbackBinding, format: .number).skField(width: 110)
                    }
                    SKMenuPicker(selection: $store.settings.scrollback, options: scrollbackOptions, width: 180)
                }
            }
            SKRow("Vymazat historii aktuální relace", help: "V nabídce Terminál → Vymazat obrazovku (⌘L).") { EmptyView() }
        }
        SKSection("Klávesnice") {
            SKRow("Option (⌥) jako Meta", help: "Vypnuto (doporučeno pro CZ klávesnici): ⌥ píše znaky macOS – ⌥2 = @, ⌥3 = #, ⌥5 = [ … Zapnuto: ⌥ posílá Esc+klávesu (emacs, bash ⌥B/⌥F).", first: true) {
                SKToggle(isOn: $store.settings.optionAsMeta)
            }
        }
        SKSection("Schránka a myš") {
            SKRow("Kopírovat označený text", help: "Označený text se automaticky zkopíruje do schránky.", first: true) {
                SKToggle(isOn: $store.settings.copyOnSelect)
            }
            SKRow("Pravé tlačítko vloží", help: "⌘C / ⌘V fungují vždy. Ctrl+C v terminálu je přerušení (SIGINT).") {
                SKToggle(isOn: $store.settings.rightClickPaste)
            }
        }
    }
}

/// Živý náhled písma a řádkování v barvách terminálového profilu.
struct FontPreview: View {
    let settings: AppSettings
    private func c(_ h: String) -> SwiftUI.Color { SwiftUI.Color(hex: h) ?? .gray }

    var body: some View {
        let t = ThemeStore.terminal
        let size = CGFloat(settings.fontSize)
        let font: Font = settings.fontName.isEmpty ? .system(size: size, design: .monospaced) : .custom(settings.fontName, size: size)
        VStack(alignment: .leading, spacing: size * CGFloat(settings.lineSpacing - 1) + 2) {
            (Text("[Expert@fw1:0]# ").foregroundColor(c(t.ansiNormal[2])) + Text("show version").foregroundColor(c(t.foreground)))
            (Text("Check Point ").foregroundColor(c(t.foreground)) + Text("R82").bold().foregroundColor(c(t.foreground))
             + Text("  tučné / běžné").foregroundColor(c(t.textSecondary)))
            (Text("eth1").foregroundColor(c(t.ansiNormal[6])) + Text(": ").foregroundColor(c(t.foreground))
             + Text("192.0.2.10/24").foregroundColor(c(t.ansiNormal[2])).bold()
             + Text("  mtu 1500").foregroundColor(c(t.foreground)))
            HStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { i in Text("■").foregroundColor(c(t.ansiNormal[i])) }
                Text(" ").foregroundColor(c(t.foreground))
                ForEach(0..<8, id: \.self) { i in Text("■").foregroundColor(c(t.ansiBright[i])) }
                Text("  ANSI").foregroundColor(c(t.textSecondary))
            }
            HStack(spacing: 0) {
                Text("0O 1lI | {}[]() <=> != -> @#$%~ ").foregroundColor(c(t.foreground))
                Text("_").foregroundColor(c(t.cursorText))
                    .background(c(t.cursor))                       // blokový kurzor
            }
        }
        .font(font)
        .lineLimit(1)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(c(t.background)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(c(t.borderColor), lineWidth: 1))
    }
}

// MARK: - Logování

struct SettingsLoggingPane: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        SKSection("Automatické ukládání") {
            SKRow("Logovat každou novou záložku", help: "Jednotlivou záložku přepneš pravým tlačítkem na záložce nebo ⇧⌘L.", first: true) {
                SKToggle(isOn: $store.settings.logEnabled)
            }
            SKRow("Umístění logů") {
                HStack(spacing: 8) {
                    Text(store.settings.logDirectory)
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(UI.textSecondary)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 240, alignment: .trailing)
                    Button("Vybrat…") { store.chooseLogDirectory() }.buttonStyle(SKButton())
                    Button("Otevřít") {
                        let u = store.settings.logDirectoryURL
                        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true,
                                                                 attributes: [.posixPermissions: 0o700])
                        NSWorkspace.shared.open(u)
                    }
                    .buttonStyle(SKButton())
                }
            }
        }
        SKSection("Formát a velikost") {
            SKRow("Formát souboru", help: "Soubor RRRR-MM-DD_HH-MM-SS_<server>.log, práva 600. Do logu jde výstup serveru bez zvýraznění aplikace.", first: true) {
                Picker("", selection: $store.settings.logPlainText) {
                    Text("Čistý text").tag(true)
                    Text("S barvami (ANSI)").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
            }
            SKRow("Rotace logu", help: "Po dosažení velikosti pokračuje log do souboru _part2, _part3… Nic se nemaže.") {
                SKMenuPicker(selection: $store.settings.logMaxMB,
                             options: [(0, "Bez limitu"), (10, "Po 10 MB"), (50, "Po 50 MB"), (100, "Po 100 MB"), (500, "Po 500 MB")],
                             width: 180)
            }
            SKRow("Retence", help: "Aplikace staré logy nemaže. Retenci řeš politikou úložiště / zálohování.") { EmptyView() }
        }
        Label("Log obsahuje vše, co server vypsal (konfigurace, případně citlivé údaje). Složka má práva 700.",
              systemImage: "exclamationmark.shield")
            .font(SK.helpFont).foregroundStyle(UI.connecting)
    }
}

// MARK: - Klávesové zkratky (přehled)

struct SettingsShortcutsPane: View {
    private let groups: [(String, [(String, String)])] = [
        ("Záložky", [("⌘T", "Nová záložka (paleta)"), ("⌘W", "Zavřít záložku"), ("⌘1 – ⌘9", "Přejít na záložku"),
                     ("⇧⌘] / ⇧⌘[", "Další / předchozí záložka"), ("⌃⇥ / ⌃⇧⇥", "Další / předchozí záložka"),
                     ("⇧⌘← / ⇧⌘→", "Posunout záložku"), ("⇧⌘R", "Znovu připojit"), ("⇧⌘L", "Logování záložky")]),
        ("Panely", [("⇧⌘D / ⌘D", "Rozdělit vedle / pod sebe"), ("⌥⌘← / ⌥⌘→", "Přepnout panel"), ("⌥⌘U", "Zrušit rozdělení")]),
        ("Terminál", [("⌘K", "Paleta příkazů"), ("⇧⌘K", "Rychlé připojení"), ("⌘F / ⌘G", "Hledat / další výskyt"),
                      ("⌘L", "Vymazat obrazovku"), ("⌘R", "Znovu připojit odpojenou relaci"), ("⇧⌘I", "Broadcast"),
                      ("⌥⌘B", "Break (sériová konzole)"), ("⌘+ / ⌘− / ⌘0", "Velikost písma")]),
        ("Okno", [("⌃⌘S", "Levý panel"), ("⇧⌘N", "Lokální terminál"), ("⇧⌘S", "SFTP"), ("⇧⌘O", "Webové rozhraní"), ("⌘,", "Nastavení")]),
    ]

    var body: some View {
        Text("Přehled aktuálních zkratek. Vlastní přiřazení zatím není podporováno.")
            .font(SK.helpFont).foregroundStyle(UI.textSecondary)
        ForEach(groups.indices, id: \.self) { gi in
            let g = groups[gi]
            SKSection(g.0) {
                ForEach(Array(g.1.enumerated()), id: \.offset) { i, item in
                    HStack {
                        Text(item.1).font(SK.bodyFont).foregroundStyle(UI.text)
                        Spacer()
                        KeyHint(text: item.0)
                    }
                    .padding(.horizontal, SK.hPad)
                    .frame(height: SK.compactRow)
                    .overlay(alignment: .top) { if i > 0 { SKDivider() } }
                }
            }
        }
    }
}

// MARK: - Autorství

enum AppCredits {
    static let author = "Jan Vobruba"
    static let line = "Vytvořil Jan Vobruba · Claude · Vibecoding"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// Standardní okno „O aplikaci“ s doplněným autorstvím.
    @MainActor static func showAbout() {
        let credits = NSAttributedString(
            string: "Vytvořil \(author)\nClaude · Vibecoding\n\nSSH klient pro správu síťové a bezpečnostní infrastruktury.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }()])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsAboutPane: View {
    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text("SSHTool").font(.system(size: 20, weight: .semibold)).foregroundStyle(UI.text)
                Text("Verze \(AppCredits.version)").font(SK.bodyFont).foregroundStyle(UI.textSecondary)
                Text(AppCredits.line).font(SK.bodyFont).foregroundStyle(UI.text)
            }
        }
        UpdateSection()
        SKSection("Autorství") {
            SKRow("Autor", first: true) { Text(AppCredits.author).font(SK.bodyFont) }
            SKRow("Vytvořeno s") { Text("Claude (Anthropic) · Vibecoding").font(SK.bodyFont) }
            SKRow("Terminál", help: "Open-source knihovna SwiftTerm (MIT).") { EmptyView() }
        }
    }
}

// MARK: - Import serverů (vzor JSON)

struct SettingsServersPane: View {
    @EnvironmentObject private var store: AppStore

    private let fields: [(String, String, String)] = [
        ("name", "ano", "Název serveru"),
        ("host", "ano", "IP adresa nebo hostname"),
        ("port", "ne", "22"),
        ("user", "ne", "Uživatel, např. admin"),
        ("group", "ne", "Složka v levém panelu, podsložky odděl „/“ (výchozí „Default“)"),
        ("colorHex", "ne", "Barva serveru, \"#RRGGBB\""),
        ("environment", "ne", "prod, stage, test, dev nebo \"\""),
        ("auth", "ne", "agent (výchozí), key, password, interactive"),
        ("identityFile", "ne", "Cesta ke klíči (auth = key), např. ~/.ssh/id_ed25519"),
        ("useKeychain", "ne", "true/false – passphrase klíče do Klíčenky"),
        ("agentSocket", "ne", "\"\" systémový, \"bitwarden\" nebo cesta k socketu"),
        ("requireUserAuth", "ne", "true/false – Touch ID před použitím hesla"),
        ("jumpHost", "ne", "user@bastion (ProxyJump)"),
        ("keepAlive", "ne", "ServerAliveInterval v sekundách, 0 = výchozí"),
        ("connectTimeout", "ne", "Timeout připojení v sekundách, 0 = výchozí"),
        ("hostKeyPolicy", "ne", "\"\", ask, yes, accept-new (\"no\" se při importu zahodí)"),
        ("extraArgs", "ne", "Další argumenty ssh, např. -o ServerAliveCountMax=3"),
        ("favorite", "ne", "true/false – Oblíbené"),
        ("proto", "ne", "ssh (výchozí) nebo rdp"),
        ("rdpDomain, rdpGateway", "ne", "RDP: doména, RD Gateway"),
        ("rdpSize", "ne", "RDP: dynamic, fullscreen nebo 1920x1080…"),
        ("rdpClipboard, rdpMultiMon", "ne", "RDP: true/false"),
        ("rdpSecurity", "ne", "RDP: \"\" (auto), nla, tls, rdp"),
        ("rdpBpp", "ne", "RDP: 0 (výchozí), 24, 16"),
        ("rdpGfx, rdpUDP", "ne", "RDP: true/false – grafický kanál GFX, UDP multitransport"),
        ("rdpAutoDetect", "ne", "RDP: true/false – automaticky najít kompatibilní režim (výchozí true)"),
        ("rdpDebugLog", "ne", "RDP: true/false – podrobný log FreeRDP (diagnostika)"),
        ("rdpFolders", "ne", "RDP: pole cest ke sdíleným složkám, např. [\"/Users/jan/RDP\"]"),
        ("rdpMacKeys", "ne", "RDP: true/false – levý ⌘ jako Ctrl (výchozí true)"),
        ("rdpAskFolder", "ne", "RDP: true/false – při každém připojení vybrat sdílenou složku ve Finderu"),
    ]

    var body: some View {
        SKSection("Servery") {
            SKRow("Importovat servery (JSON)", help: "Přidá nové servery. Duplicity (název + složka + host + port) přeskočí. Hesla se nenačítají.", first: true) {
                Button("Importovat…") { store.importSessionsPanel() }.buttonStyle(SKButton(kind: .primary))
            }
            SKRow("Exportovat servery", help: "Bez hesel a bez cest ke klíčům – bezpečné ke sdílení s kolegy.") {
                Button("Exportovat…") { store.exportSessionsPanel() }.buttonStyle(SKButton())
            }
        }
        SKSection("Vzor JSON pro kolegy",
                  subtitle: "Uprav hodnoty, ulož jako .json a nahraj přes Importovat. Adresy ve vzoru jsou z dokumentačních rozsahů (RFC 5737). Klíče začínající _ se ignorují.") {
            HStack(spacing: 8) {
                Button { copyTemplate() } label: { Label("Kopírovat vzor", systemImage: "doc.on.doc") }
                    .buttonStyle(SKButton())
                Button { store.saveSessionsTemplatePanel() } label: { Label("Uložit vzor jako soubor…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(SKButton())
                Spacer()
                Text("\(AppStore.sessionsTemplateJSON.split(separator: "\n").count) řádků")
                    .font(SK.helpFont).foregroundStyle(UI.textTertiary)
            }
            .padding(.horizontal, SK.hPad).padding(.vertical, 10)
            ScrollView([.vertical, .horizontal]) {
                Text(AppStore.sessionsTemplateJSON)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(UI.text)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 320)
            .background(RoundedRectangle(cornerRadius: 8).fill(UI.main))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(UI.border, lineWidth: 1))
            .padding(.horizontal, SK.hPad).padding(.bottom, 14)
        }
        SKSection("Pole záznamu") {
            ForEach(fields.indices, id: \.self) { i in
                let f = fields[i]
                HStack(spacing: 12) {
                    Text(f.0).font(SK.monoFont).foregroundStyle(UI.text).frame(width: 130, alignment: .leading)
                    Text(f.1 == "ano" ? "povinné" : "volitelné")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(f.1 == "ano" ? UI.accent : UI.textTertiary)
                        .frame(width: 64, alignment: .leading)
                    Text(f.2).font(SK.helpFont).foregroundStyle(UI.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, SK.hPad)
                .frame(minHeight: SK.compactRow)
                .overlay(alignment: .top) { if i > 0 { SKDivider() } }
            }
        }
        Label("Hesla se do souboru nikdy nepíší. Po importu je zadej v editoru serveru (Upravit) – uloží se do Klíčenky macOS.",
              systemImage: "lock.shield")
            .font(SK.helpFont).foregroundStyle(UI.textSecondary)
    }

    private func copyTemplate() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AppStore.sessionsTemplateJSON, forType: .string)
    }
}

/// Nastaví titulek okna (Nastavení – místo systémového „SSHTool Settings“).
struct WindowTitleSetter: NSViewRepresentable {
    let title: String
    final class V: NSView {
        var title = ""
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.title = title }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.title = title; return v }
    func updateNSView(_ v: V, context: Context) { v.title = title; if v.window?.title != title { v.window?.title = title } }
}

/// Nastavení → O aplikaci: aktualizace z GitHubu.
struct UpdateSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var up = Updater.shared

    var body: some View {
        SKSection("Aktualizace") {
            SKRow("Verze \(up.currentVersion)", help: up.repo.map { "Zdroj: github.com/\($0)" } ?? "Repozitář není nastavený (sestavení mimo git).", first: true) {
                HStack(spacing: 8) {
                    if up.checking { ProgressView().controlSize(.small) }
                    if !up.status.isEmpty { Text(up.status).font(SK.helpFont).foregroundStyle(UI.textSecondary) }
                    Button("Zkontrolovat") { up.check(interactive: true) }
                        .buttonStyle(SKButton()).disabled(up.checking || up.repo == nil)
                }
            }
            SKRow("Kontrolovat automaticky", help: "Při spuštění (max. 4× denně) se zeptá GitHubu na novou verzi.") {
                SKToggle(isOn: $store.settings.autoUpdateCheck)
                    .help("Jen dotaz na api.github.com (veřejné repo, bez přihlášení). Instalace vždy až po potvrzení; balíček musí mít platný podpis Ed25519.")
            }
            if let r = up.repo, let u = URL(string: "https://github.com/\(r)") {
                SKRow("Projekt na GitHubu", help: "Popis, změny a stažení") {
                    Button("Otevřít") { NSWorkspace.shared.open(u) }.buttonStyle(SKButton())
                }
            }
        }
    }
}
