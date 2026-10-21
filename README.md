# SSHTool

Nativní SSH klient pro macOS určený pro správu síťové a bezpečnostní infrastruktury (Check Point, Cisco, Palo Alto, F5, Linux…).
Inspirovaný Tabby, MobaXterm a Termius – ale rychlý, nativní a s důrazem na bezpečnost.

> Vytvořil **Jan Vobruba** · Claude · Vibecoding

## Hlavní funkce

| Oblast | Co umí |
|---|---|
| **Servery** | Skupiny s barvami, oblíbené, hledání, štítky prostředí PROD / STAGE / TEST / DEV, přesun mezi skupinami tažením, import / export JSON (bez hesel), vzor JSON pro kolegy |
| **RDP** | Windows servery přes FreeRDP 3 v samostatném okně, heslo z Klíčenky přes stdin, gateway, více monitorů, schránka – FreeRDP je ve vydáních přibalený |
| **Přihlášení** | SSH agent / `~/.ssh/config`, Bitwarden SSH agent, soukromý klíč (passphrase v Klíčence), heslo v Klíčence macOS s Touch ID, interaktivní (OTP), jump host |
| **Terminál** | Záložky, rozdělení až na 4 panely, broadcast vstupu s potvrzením, režim soustředění, 6 barevných profilů, vyhledávání, scrollback až 100 000 řádků, ⌥ znaky pro CZ klávesnici |
| **Zvýrazňování** | Pravidla (text / regex) ve skupinách, test výrazu, detekce konfliktů, ochrana výkonu |
| **Snippety** | Šablony diagnostických příkazů: Check Point Gaia / Maestro, Palo Alto, Cisco FTD / ASA / IOS, F5, Fortinet, Juniper, Linux |
| **Zachytávání** | Průvodce `tcpdump` / `g_tcpdump` / `fw monitor -F` / `fw monitor -e`, **živě do Wiresharku** přes SSH, stažení odchytu a otevření ve Wiresharku |
| **Monitoring** | CPU, RAM, disk a load serveru ve stavovém řádku (jako MobaXterm), latence |
| **Další** | SFTP, lokální terminál, sériová konzole (USB), logování relací, test připojení (DNS → TCP → SSH → host key → autentizace) |

## Instalace

1. Stáhni nejnovější `SSHTool-x.y.z.zip` z [Releases](../../releases/latest).
2. Rozbal a přesuň `SSHTool.app` do složky **Aplikace**.
3. Při prvním spuštění macOS hlásí *„SSHTool“ Not Opened* (aplikace není notarizovaná Apple). Klikni **Done** a pak:
   - **Nastavení systému → Soukromí a zabezpečení** → dole u „SSHTool was blocked…“ **Otevřít přesto** (Open Anyway) → potvrď heslem, **nebo**
   - v Terminálu: `xattr -dr com.apple.quarantine /Applications/SSHTool.app`

   (macOS 15 Sequoia a novější už neumožňuje obejít kontrolu přes pravé tlačítko → Otevřít.)

Další aktualizace už nabídne aplikace sama (menu **SSHTool → Zkontrolovat aktualizace…**).

Požadavky: macOS 13 Ventura nebo novější (Apple Silicon i Intel při sestavení ze zdrojů).

## Sestavení ze zdrojů

```bash
xcode-select --install        # Command Line Tools (stačí, Xcode není nutný)
bash build-app.sh             # → build/SSHTool.app
bash build-app.sh --install   # → /Applications/SSHTool.app
open build/SSHTool.app        # .app je složka – spouštěj přes open
```

## Aktualizace

- Při každé změně verze v `build-app.sh` na větvi `main` GitHub Actions sestaví aplikaci a publikuje **Release**
  (`SSHTool-x.y.z.zip`, `.sha256`, `.sig`); poznámky se berou z [CHANGELOG.md](CHANGELOG.md).
- Aplikace se při spuštění (max. 4× denně, lze vypnout) zeptá `api.github.com` na nejnovější release.
  Instalace proběhne **až po potvrzení**: stažení → **ověření podpisu Ed25519** veřejným klíčem zabudovaným v aplikaci →
  kontrola bundle id a verze → stará verze do Koše → restart. Bez platného podpisu se nic neinstaluje.

## Bezpečnost

- Hesla jen v Klíčence macOS (volitelně Touch ID); nikdy v souborech ani v exportech.
- Repozitář neobsahuje žádné servery, hesla, klíče ani logy (viz `.gitignore`).
- Kontrola klíče serveru: volbu „ignorovat“ (`StrictHostKeyChecking=no`) aplikace nenabízí; test připojení nikdy nemění `known_hosts`.
- Snippety a průvodce zachytáváním příkazy jen **vkládají**; spuštění u PROD zařízení a při broadcastu vyžaduje potvrzení.
- Monitor a Wireshark používají již přihlášené SSH spojení (ControlMaster, socket jen pro uživatele) – žádné další přihlášení.

## Data

| Soubor | Obsah |
|---|---|
| `~/Library/Application Support/SSHTool/sessions.json` | servery (bez hesel) |
| `~/Library/Application Support/SSHTool/rules.json` | pravidla zvýraznění |
| `~/Library/Application Support/SSHTool/snippets.json` | snippety |
| `~/Library/Application Support/SSHTool/settings.json` | nastavení |
| Klíčenka macOS → „SSHTool“ | hesla |

## Technika

Swift 5.9 · SwiftUI + AppKit · [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.99.0 · systémový `/usr/bin/ssh`.
Kód nepoužívá SwiftUI makra (`@State`, `@Binding`), aby šel sestavit jen s Command Line Tools.

Historie změn: [CHANGELOG.md](CHANGELOG.md) · Publikace a podpis vydání: [PUBLISHING.md](PUBLISHING.md)
