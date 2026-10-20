# SSHTool – historie změn

Nejnovější změny jsou na konci souboru. Sekce `## x.y.z` se automaticky použije jako poznámky k vydání na GitHubu.


Nativní macOS SSH klient: uložené session ve skupinách, hesla v Apple Keychain, zvýrazňování výstupu podle pravidel (jako Tabby highlight).

## Sestavení

Potřebuješ macOS 13+ a Xcode (nebo Command Line Tools: `xcode-select --install`).

    ./build-app.sh            # → build/SSHTool.app
    ./build-app.sh --install  # → /Applications/SSHTool.app

Máš-li vývojářský certifikát (zjistíš přes `security find-identity -p codesigning -v`):

    SIGN_IDENTITY="Apple Development: …" ./build-app.sh --install

S ad-hoc podpisem se po každém novém buildu Keychain jednou zeptá na povolení
přístupu k uloženým heslům – zvol „Vždy povolit“. S certifikátem se to neděje.

## Data

- `~/Library/Application Support/SSHTool/sessions.json` – session
- `~/Library/Application Support/SSHTool/rules.json` – pravidla zvýraznění (pořadí = priorita)
- Hesla: Keychain Access → hledej „SSHTool“

## Ovládání (od verze 0.2)

- Jedno okno: vlevo session (hledání, skupiny), vpravo záložky s terminály.
- Dvojklik na session / Enter = nová záložka. `⌘T` rychlé připojení (hledání), `+` v liště záložek = výběr podle skupin.
- `⌘W` zavřít záložku, `⌘R` znovu připojit, `⇧⌘D` duplikovat, `⌘1–9` přepnout, `⌃Tab` / `⌃⇧Tab` další/předchozí, `⇧⌘←/→` přesun záložky.
- `⌘,` editor pravidel zvýraznění: zapnuto, `(.*)` regex, `Aa` velikost písmen, barva písma/pozadí, tučně, pořadí tažením, import/export JSON, „Výchozí (Tabby)“.

## Import session z Tabby

`import/tabby-sessions.json` obsahuje session převedené z Tabby `config.yaml` (bez hesel).
V aplikaci: tlačítko Import v seznamu session (nebo menu File → Importovat session…).
Session se stejným id se při opakovaném importu přeskočí.

## Technické poznámky

- SwiftTerm je zamčený na 1.99.0. V této verzi `LocalProcessTerminalView` posílá výstup procesu interním
  adaptérem, takže zvýraznění je řešeno vlastním `SSHTerminalView` (TerminalView + LocalProcess).
- Kód nepoužívá `@State`/`@Binding`: v SDK z Command Line Tools jsou to makra bez pluginu (SwiftUIMacros).

## Lokální terminál a SFTP (0.3)

- `⇧⌘N` (nebo `+` → Lokální terminál): tvůj login shell v domovské složce – pro scp, rsync, ping…
- SFTP: pravé tlačítko na session → Otevřít SFTP, `+` → SFTP → skupina → session, `⇧⌘S` = SFTP k aktivní záložce,
  v ⌘T tlačítko „SFTP“. Používá `/usr/bin/sftp` se stejným uživatelem, portem, klíčem a jump hostem jako SSH.
- Přetažení souboru z Finderu do terminálu vloží escapovanou cestu (např. `put <cesta>` v SFTP nebo `scp <cesta> …`).
- Check Point Gaia: SFTP/SCP funguje jen pro uživatele se shellem /bin/bash (clish: `set user <jméno> shell /bin/bash`).

## Barevné záložky a web (0.4)

- Záložka má podklad v barvě session (aktivní plná barva + linka, neaktivní tlumená), písmo bílé/černé podle jasu.
- Pravé tlačítko na session nebo záložce → „Otevřít web (https://<host>)“ – otevře v Safari novou záložku. `⇧⌘O` pro aktivní záložku.
- `⌃⌘S` nebo ikona vlevo v liště záložek skryje/zobrazí seznam session (víc místa pro terminál). `⌃⌘F` celá obrazovka.

## Schránka a logy (0.5)

- Označení textu myší ho rovnou zkopíruje, pravé tlačítko vloží ze schránky (vypnutelné v ⌘, → Terminál a logy).
- Logování: ⌘, → Terminál a logy → složka, automatické logování všech záložek, čistý text. Ručně: pravé tlačítko na záložce
  nebo `⇧⌘L`. Soubory `RRRR-MM-DD_HH-MM-SS_<session>.log` s právy 600, složka 700.
- Historie terminálu (scrollback): výchozí 20 000 řádků, nastavitelné v ⌘, → Terminál a logy (1 000 – 100 000).
- Velikost písma: `⌘+` / `⌘−` / `⌘0`, nebo podrž `⌥⌘` a posuň dvěma prsty po trackpadu (nahoru větší, dolů menší). Platí pro všechny záložky a pamatuje se.

## Ochrana uložených hesel (0.7)

- U session s heslem z Keychainu lze zapnout „Před použitím hesla vyžadovat Touch ID / heslo Macu“ (nové session: zapnuto).
- Příznak je uložen v položce Keychainu (ne v sessions.json), takže ho nejde obejít úpravou souboru. Vypnutí vyžaduje ověření.
- Starší uložená hesla ochranu nemají – v editoru session ji zapni a ulož.

## SSH klíče a zkratky (0.8)

- Přihlášení „Klíč“: výběr z ~/.ssh (soubory s .pub) nebo libovolného souboru, passphrase do Klíčenky macOS
  (`UseKeychain`), tlačítko pro zkopírování veřejného klíče.
- Přihlášení „SSH agent“: systémový, **Bitwarden** (socket se najde automaticky) nebo vlastní socket; kontrola, že socket
  existuje, a „Zkopírovat veřejné klíče z agenta“ (`ssh-add -L`).
- `⌘L` / `⌘K` vyčistí obrazovku i historii, `⌘R` = Ctrl+R (hledání v historii příkazů), znovu připojit je nově `⇧⌘R`.

## Sériová konzole (0.9)

- USB konzolové kabely (FTDI, Prolific, CP210x, CH340, Cisco USB console…) se automaticky objeví v levém panelu
  v sekci „Sériové porty“; po zastrčení kabelu aplikace nabídne „Připojit“.
- Dvojklik = připojit (výchozí 9600 baud, 8N1, bez řízení toku), pravé tlačítko = jiná rychlost (pamatuje se pro port).
  Také `+` → Sériová konzole.
- Konzole je běžná záložka (zvýraznění, logování, historie). `⌥⌘B` pošle Break. Odpojení kabelu záložku ukončí.
- Port obsluhuje aplikace sama (žádný screen/minicom); port se otevírá výhradně (TIOCEXCL).

## Rozdělené zobrazení (0.10)

- `⇧⌘D` vedle sebe, `⌘D` pod sebou (jako v Tabby). Zobrazí aktivní a sousední záložku; když je záložka jen jedna,
  otevře se druhé spojení na stejnou session. Pravé tlačítko na záložce → „Zobrazit vedle / pod aktivní záložkou“.
- Panely jdou zvětšovat tažením dělicí čáry. Fokus: klik do panelu nebo `⌥⌘←/→`; příkazy (⌘L, ⇧⌘L, ⌘W…) míří na aktivní panel.
- Klik na jinou záložku v liště ji zobrazí v aktivním panelu. `⌥⌘U` zruší rozdělení, ikona v liště nabízí i prohození panelů.

## Nový vzhled (0.11)

- Grafitový (šedý) vzhled: karty záložek se stavovou tečkou (zelená připojeno, žlutá připojování, červená odpojeno),
  druhý řádek s hostem, podtržení aktivní záložky v barvě session.
- Levý panel: vyhledávání, **Oblíbené** (hvězdička u serveru), skupiny se sbalují/rozbalují klikem na záhlaví
  (stav se pamatuje), počet serverů ve skupině, stav spojení u každého serveru.
- Po odpojení karta „spojení bylo ukončeno“ s důvodem, **Znovu připojit (⌘R)**, Ponechat výstup, Nový terminál.
- Stavový řádek: stav, protokol, host, délka relace, kódování, velikost terminálu, ⌘K příkazová paleta, nastavení.
- `⌘K` = příkazová paleta (hledání serveru), `⌘R` = Ctrl+R, u odpojené záložky znovu připojí.

## Paleta Slate a nové funkce (0.12)

- Barvy: pozadí #14161B, levý panel #1C1F26, lišta #20232B, aktivní záložka #303540, text #E2E5EA / #8D95A3,
  OK #4CC38A, varování #E5A44B, chyba #E06C75, akcent #7799E8. Tečka na záložce = barva session.
- Rozdělení až na 4 panely (2 vedle/pod sebou, 3 = velký + dva, 4 = mřížka 2×2): `⇧⌘D` / `⌘D` přidá panel.
- `⌘K` příkazová paleta (servery + akce), `⇧⌘K` rychlé připojení `user@host:port` (volitelně uložit).
- `⌘F` hledání ve výstupu terminálu, `⌘G` / `⇧⌘G` další / předchozí výskyt.
- `⇧⌘I` broadcast vstupu do více relací (při rozdělení do viditelných panelů, jinak do všech SSH záložek) –
  vyžaduje potvrzení se seznamem relací, zapnutý stav je červeně v liště, rámečcích panelů a stavovém řádku.
- Bez titulkové lišty okna: okno se táhne za prázdné místo v liště záložek nebo nad vyhledáváním (dvojklik = zvětšit),
  „+“ vedle vyhledávání = nový server (podržením rychlé připojení / import).

## Doladění dle zadání v2 (0.13)

- Paleta: sidebar #1E2028, terminál #14161B, lišta #20232B, aktivní záložka #2C303C, neaktivní #242731,
  hover #292E39, vybraná položka #343C4D, akcent #648CFF, čáry #343843. Stavy: připojeno #42C78A,
  připojování #E5B45A, bez relace/odpojeno #747985, chyba spojení #E66B70 (stav relace, ne dostupnost serveru).
- Levý panel: název bez IP (IP zvlášť menším šedým písmem), režim Kompaktní / Pohodlný (⌘, → Terminál a logy),
  aktivní server = server fokusované záložky (podbarvení + modrá linka 3 px), zvýraznění shody při hledání,
  tooltip s celým názvem, oblíbené jsou jen odkazy na stejné záznamy. Šířka 220–420 px (výchozí 290).
- Záložky 38 px (lišta 54 px), mezera 5 px, tečka = barva prostředí, druhý řádek = stav + host, tooltip,
  přetahování záložek myší, menu „všechny relace“, štítek PROD (v editoru serveru).
- Terminál: vnitřní okraj 14 × 10 px (SwiftTerm počítá sloupce/řádky i PTY z plochy bez okraje),
  volba písma (SF Mono / JetBrains / Geist / Berkeley, pokud jsou nainstalované), řádkování, vypínatelné zvýrazňování.
- Odpojení: tenká lišta dole „SSH spojení ukončeno · důvod · Znovu připojit ⌘R“, výstup zůstává.
- Stavový řádek 28 px: stav · SKUPINA / server · PROD · IP · délka relace · latence (ICMP ping á 10 s, vypínatelné)
  · UTF-8 · sloupce×řádky · ⌘K · nastavení.

## Barevné profily (0.14)

- ⌘, → Vzhled: Midnight Graphite (výchozí), Tokyo Night, Nord Frost, Catppuccin Mocha, Emerald Terminal, Arctic Light –
  každý mění celé UI i terminál (popředí, pozadí, kurzor, výběr, 8 + 8 ANSI barev). Náhled s ukázkou výstupu.
- Samostatný profil terminálu (vypni „Terminál podle profilu aplikace“), režim Tmavý / Světlý / Podle macOS.
- Rychlé přepnutí: menu „…“ → Barevný profil, nebo ⌘K → „profil“. Změna se projeví hned, relace i historie zůstanou.
- Stavové barvy mají ve všech profilech stejný význam (zelená/žlutá/šedá/červená), mění se jen odstín.

## 0.15.0

- Editor serveru v barvách aktivního profilu; skupinu lze vybrat ze stávajících (menu vedle pole), prostředí Production / Test / Development.
- Levý panel: jediné zvýraznění (aktivní server), IP vždy celá, název se zkracuje „…“, tooltip s detaily; záhlaví skupin s odznakem počtu, hover, sbalit/rozbalit vše.
- Kontextové menu serveru: Připojit / Přejít, Připojit v rozděleném panelu, Upravit, Duplikovat, Kopírovat IP, Kopírovat SSH příkaz, Oblíbené, Přesunout do skupiny, Smazat (s potvrzením).
- Záložky: identita = svislý barevný pruh (barva serveru), stav SSH = kulatá tečka (zelená/žlutá/šedá/červená), štítek PROD/TEST/DEV.
- Odpojení: kompaktní oznámení vpravo nahoře, samo zmizí po 6 s; stav zůstává ve stavovém řádku, klik na stav = znovu připojit (⌘R zůstává).
- Stavový řádek: latence jen při spojení, celé ms; po odpojení „Poslední relace: …“.
- ⇧⌘] / ⇧⌘[ další/předchozí záložka; dvojklik do prázdné lišty záložek = nová záložka (paleta).
- Export serverů bez hesel a klíčů.

## 0.16.0

- Nastavení s postranní navigací: Obecné, Vzhled, Terminál, Zvýrazňování, Logování, Klávesové zkratky. Fixní záhlaví, scrollovatelný obsah, minimum 900 × 650. Jednotné komponenty (vstupy a tlačítka 32 pt, řádek 44 pt, karty 10 pt).
- Vzhled: klikací karty profilů (88 pt, ✓ Aktivní, rámeček), náhled 280 × 76, samostatně profil terminálu a automatický vzhled.
- Terminál: živý náhled písma, řádkování 1,0–1,5× (výchozí 1,15×), scrollback 5k–100k + vlastní hodnota.
- Logování: samostatná sekce, formát (čistý text / ANSI), rotace po N MB (_part2…, nic se nemaže).
- Zvýrazňování: kompaktní řádky, detail po kliknutí, vyhledávání a filtry, skupiny pravidel (vypínatelné), test výrazu na vlastním textu, chyby regexu u pravidla, detekce konfliktů priorit, přetažení pořadí, náhled se všemi pravidly. Pojistka výkonu: 8 ms na pravidlo, 25 ms na blok, bloky > 64 kB se nezvýrazňují, pomalé pravidlo se po 3 překročeních pozastaví.
- Editor serveru: 620 pt, sekce Základní / Připojení / Autentizace / Pokročilé, výběr skupiny s hledáním a novou skupinou, prostředí Production/Staging/Development/Test, paleta barev, interaktivní přihlášení, KeepAlive, Timeout, politika host key (bez „no“), validace a varování k argumentům, test připojení (DNS, SSH banner, known_hosts, autentizace v BatchMode – nemění known_hosts).

## 0.16.1 – vzor JSON se servery pro kolegy

Menu „+“ v levém panelu (a menu Soubor / „…“) → **Uložit vzor JSON pro kolegy…**. Stejný vzor je v `examples/sshtool-servers-template.json`.
Uprav hodnoty a nahraj přes **Importovat servery (JSON)…**.

| Pole | Povinné | Hodnoty / výchozí |
|---|---|---|
| name, host | ano | název; IP nebo hostname |
| port | ne | 22 |
| user, group | ne | "" / "Default" |
| colorHex | ne | "#RRGGBB" |
| environment | ne | prod, stage, test, dev, "" |
| auth | ne | agent (výchozí), key, password, interactive |
| identityFile, useKeychain | ne | jen pro auth = key |
| agentSocket | ne | "" systémový, "bitwarden", nebo cesta k socketu |
| requireUserAuth | ne | Touch ID před použitím hesla (auth = password) |
| jumpHost | ne | user@bastion |
| keepAlive, connectTimeout | ne | sekundy, 0 = výchozí |
| hostKeyPolicy | ne | "", ask, yes, accept-new („no“ se při importu zahodí) |
| extraArgs, favorite | ne | další argumenty ssh; true/false |

Klíče začínající `_` (např. `_poznamka`) se ignorují. Hesla se do souboru nepíší – zadávají se po importu v editoru (Klíčenka macOS).
Duplicity (stejný název + skupina + host + port) se při importu přeskočí, takže vzor lze nahrát opakovaně.

## 0.16.2

- Nastavení → **Import serverů**: import/export, vzor JSON přímo zobrazený v aplikaci (kopírovat / uložit jako soubor) a tabulka všech polí.
- Nastavení → **O aplikaci** a menu SSHTool → O aplikaci: „Vytvořil Jan Vobruba · Claude · Vibecoding“ (také v Info.plist jako NSHumanReadableCopyright).

---
Vytvořil Jan Vobruba · Claude · Vibecoding

## 0.17.0 – výkon a opravy

- Výkon: čtení z PTY, log a zvýrazňování běží pro každou relaci na vlastní frontě mimo hlavní vlákno; do terminálu se data předávají dávkově. Víc relací s velkým výstupem už neblokuje UI.
- Latence: překreslí se jen při změně hodnoty.
- Rozdělené zobrazení: po přepnutí vedle sebe ↔ pod sebou (i prohození panelů) je text v terminálu hned vidět – terminál si bere vždy nový panel, fokus se nastavuje jen když je potřeba.
- Klávesnice: ⌥ píše znaky macOS (⌥2 = @, ⌥3 = # …). Option jako Meta (Esc+) lze zapnout v Nastavení → Terminál → Klávesnice.

### Jak spustit
`./build-app.sh` → `open build/SSHTool.app` (ne přímo `build/SSHTool.app` – .app je složka). Instalace do Aplikací: `./build-app.sh --install`.

## 0.18.0

- Levý panel: server v Oblíbených se zvýrazní jen jednou (ne zároveň ve skupině). Skupiny mají barvu (automatickou podle názvu, nebo ruční) a jdou přejmenovat – pravým tlačítkem na záhlaví skupiny.
- Záložky: více relací stejného serveru se čísluje (`fw1-praha · 1`, `· 2`); záložku lze přejmenovat (platí jen pro relaci).
- Rozdělené zobrazení: hlavička panelu 24 pt `● název · IP … ⋯`, aktivní panel = akcentová linka + štítek AKTIVNÍ, neaktivní bez rámečku a jemně utlumený; menu ⋯: samostatná záložka, rozdělit vedle/pod, přejmenovat, znovu připojit, zavřít.
- Režim soustředění (⌥⌘F): skryje levý panel i záložky, stavový řádek volitelně.
- Arctic Light: vyšší kontrast sekundárních textů, ikon, čar a počtů.
- Editor serveru: pevná velikost 660 × 640, fixní spodní lišta, skupina + prostředí na jednom řádku, host + port na jednom řádku, barva „Podle skupiny“ (výchozí) / paleta / bez barvy / vlastní. Test připojení v 5 krocích: DNS/IP, TCP port, SSH handshake, klíč serveru, autentizace – s konkrétní příčinou chyby.
- Nastavení: šířka obsahu max. 760 pt, okno 1040 × 720 (min. 850), typografie 22/13/15/13/11,5 pt, kratší popisky (detail v tooltipu), titulek „Nastavení“, aplikace v češtině (CFBundleDevelopmentRegion cs).
- Vzhled: karta profilu 60 % info / 40 % náhled, výška 96 pt, po najetí „Náhled rozhraní“ (levý panel, záložky, terminál, stavový řádek).
- Terminál: řádkování Compact 1,05 / Normal 1,15 / Comfortable 1,25 + slider (dvojklik na hodnotu = výchozí), náhled písma s tučným textem, ANSI barvami, speciálními znaky a blokovým kurzorem.
- Zvýrazňování: tooltipy štítků, „Bez testovacího textu“, pole „Otestovat výraz“, u testu výpis „použito pravidlo #n“.
- Snippety (nová sekce nastavení + tlačítko v liště záložek): vložení bez spuštění, nebo „Vložit a spustit“ s potvrzením u produkce / broadcastu; výchozí sada Check Point.

## 0.19.0

- Přesun serveru do jiné skupiny přetažením (na záhlaví skupiny nebo na server v ní); cílová skupina se zvýrazní a rozbalí.
- Snippety jsou ve výchozím stavu prázdné. Nastavení → Snippety → **Šablony podle technologie**: Check Point Gaia, Check Point Maestro (MHO), Palo Alto Networks, Cisco FTD (Firepower), Cisco ASA 9.x, Cisco IOS 15.x, F5 BIG-IP, Fortinet FortiGate, Juniper Junos, Linux – pro všechny servery nebo jen pro vybranou skupinu. Šablony obsahují jen diagnostické (čtecí) příkazy. V liště záložek jsou snippety řazené podle šablon.

## 0.20.0 – průvodce zachytáváním paketů (⌥⌘P)

Tlačítko s průběhem signálu v liště záložek, menu Terminál nebo „…“. Nástroje:

- **tcpdump** – rozhraní (prázdné = any), zdroj / cíl (IP, síť s maskou, hostname), oba směry, protokol, port nebo rozsah (`portrange`), počet paketů, snaplen, `-nn`, `-v`, zápis do pcap.
- **fw monitor -F** (R80.20+, funguje i se SecureXL) – zdroj, cíl, jeden port, protokol, oba směry (generuje potřebné `-F` filtry včetně odpovědí), VSID, `-ci/-co`, `-o`.
- **fw monitor -e** (INSPECT) – totéž včetně rozsahu portů.

Příkaz se sestavuje živě, vstupy se validují (do shellu jdou jen povolené znaky). „Vložit do terminálu“ příkaz jen vloží (Enter zmáčkneš sám), „Vložit a spustit“ se u produkce / broadcastu ptá. Parametry zůstávají mezi otevřeními.

Příklad: `tcpdump -nn -i eth1 -c 1000 -s 0 -w /var/log/capture.pcap '((src net 10.0.0.0/24 and dst host 192.0.2.10) or (src host 192.0.2.10 and dst net 10.0.0.0/24)) and tcp and portrange 8000-8100'`

## 0.21.0 – monitor serveru ve stavovém řádku

`CPU ▬ 23 % · RAM ▬ 5.1 GB volno · Disk ▬ 87 % /var/log · load 0.52` – barevně (oranžová / červená nad prahy), detail v tooltipu, aktualizace každých 5 s.

- Zapnutí: klik na „Monitor“ ve stavovém řádku, nebo automaticky (Nastavení → Obecné → Monitor serveru automaticky; výchozí vypnuto). Vypnutí: pravým tlačítkem na monitor.
- Jak: hlavní ssh běží jako ControlMaster s vlastním socketem pro každou záložku (`~/Library/Caches/SSHTool/cm-*`, práva 700). Monitor otevře přes stejné přihlášené spojení jeden další kanál – žádné nové přihlášení ani TCP spojení, funguje i s heslem / Touch ID. Ve vzdáleném shellu běží smyčka, která čte `/proc/stat`, `/proc/meminfo`, `/proc/loadavg` a `df -Pk` (nic nemění).
- Disk ukazuje `/` a nejzaplněnější souborový systém (typicky `/var/log` na Gaia).
- Podpora: Linux / Check Point Gaia s uživatelem se shellem bash/sh. U clish, Cisco, PAN-OS apod. se zobrazí „Monitor –“ s důvodem v tooltipu.

## 0.21.1

- Přesun serveru mezi skupinami přímo v levém panelu: chyť server a pusť ho na záhlaví jiné skupiny nebo na server v ní (drag & drop přes NSItemProvider – funguje uvnitř seznamu).
- tcpdump: přepínače `-l` `-p` `-e` `-nn` a podrobnost `-v/-vv/-vvv` lze zapínat; výchozí `tcpdump -lpenni <rozhraní>`.

## 0.21.2

- Průvodce zachytáváním: přepínač **Security Group – Check Point Maestro** → `g_tcpdump -lpenni …` (tcpdump na všech SGM), s upozorněním, že limit paketů i soubor platí pro každého člena zvlášť.

## 0.22.0 – Wireshark

V průvodci zachytáváním (⌥⌘P) sekce **Wireshark (lokálně v Macu)**:

- **Živě do Wiresharku** (tcpdump): na serveru `tcpdump -U -s 0 -nn -w - '<filtr> and not (host $SSH_CLIENT_IP and port $SSH_CLIENT_PORT)'`, stream jde přes stejné, už přihlášené SSH spojení (ControlMaster – bez nového přihlášení, funguje i s heslem) do lokálního `Wireshark -k -i -`. Vlastní SSH spojení se z odchytu vyřadí přesně (IP + port klienta). Ve stavovém řádku „● Wireshark live · velikost · Zastavit“; po dosažení počtu paketů / zastavení zůstane odchyt otevřený ve Wiresharku. Obdoba `ssh host tcpdump -U -s0 -w - 'not port 22' | wireshark -k -i -`.
- **Stáhnout soubor a otevřít**: stáhne soubor z `-w` / `fw monitor -o` přes stejné spojení do `~/Downloads/SSHTool-captures/` (práva 600) a otevře ve Wiresharku.
- Volitelně `sudo -n` pro uživatele bez root práv. Živě nelze s `g_tcpdump` (výstup ze všech SGM by poškodil pcap) – tam použij soubor.
- U PROD zařízení se před odchytem zobrazí potvrzení.
- Požadavek: Wireshark v /Applications, na serveru uživatel s bash/sh (expert).

## 0.23.0

- Projekt připravený pro GitHub: README, CHANGELOG, `.gitignore` (bez session, logů, odchytů a klíčů), GitHub Actions.
- Automatické vydání: při změně verze v `build-app.sh` na větvi `main` se aplikace sestaví na macOS runneru a publikuje jako GitHub Release (`SSHTool-x.y.z.zip`, `.sha256`, `.sig`).
- Aktualizace v aplikaci: kontrola při spuštění (max. 4× denně, vypnutelná) a menu SSHTool → Zkontrolovat aktualizace…; po potvrzení stáhne, ověří podpis Ed25519, nahradí aplikaci (stará verze do Koše) a restartuje.
- `./publish.sh`: kontroly před publikací (verze, CHANGELOG, citlivé soubory a tajné údaje, privátní IP, zkušební build), souhrn, commit a push.

## 0.24.0

- **Soubory serveru (SFTP prohlížeč)** – panel vpravo vedle terminálu (⇧⌘E, ikona složky v liště záložek, menu Terminál):
  - procházení souborového systému serveru (dvojklik do složky, ↑ o úroveň výš, domovská složka, zadání cesty, skryté soubory),
  - **↑ Nahrát**: výběr souborů / složek z Macu do aktuální složky serveru, nebo přetažení z Finderu do panelu (dotaz při přepsání),
  - **↓ Stáhnout**: vybrané soubory / složky do Macu (jeden soubor → dialog Uložit, více → výběr složky), dvojklik na soubor = stáhnout,
  - nová složka, přejmenování, smazání (s potvrzením), kopírování cesty a vložení cesty do terminálu,
  - seznam přenosů se stavem a „Zobrazit ve Finderu“.
- Běží přes stejné přihlášené SSH spojení (ControlMaster) – bez nového přihlášení, funguje i s heslem / Touch ID. U PROD serverů se zápisy potvrzují.

## 0.24.1

- **SFTP záložka = grafický prohlížeč souborů**: „Otevřít SFTP“ (⇧⌘S, menu serveru, +) teď otevře procházení serveru s tlačítky ↑ Nahrát / ↓ Stáhnout, přetažením z Finderu a kontextovým menu. Pod seznamem je malý terminál pro přihlášení (heslo / OTP / potvrzení klíče serveru); prohlížeč počká na přihlášení a pak otevře domovskou složku.
- Panel souborů u SSH záložky (⇧⌘E) zůstává.
- Oprava vzhledu horní lišty u verze stažené z GitHubu (příliš vysoká lišta, chybějící tlačítka okna): aplikace má zapnutý kompatibilní vzhled (UIDesignRequiresCompatibility), takže nové SDK nemění vzhled oken.

## 0.24.2

- Oprava horní části okna: zpět tlačítka okna (zavřít / minimalizovat / celá obrazovka) a bez velké mezery nad záložkami. Levý panel už nepoužívá systémový NavigationSplitView (v novém macOS SDK si vyhrazoval místo pro toolbar), ale vlastní rozložení; okno se nastavuje přímo přes AppKit.
- Šířka levého panelu jde měnit tažením za okraj (pamatuje se), dvojklik na okraj = výchozí šířka.

## 0.25.0

- **Stromová struktura složek** v levém panelu: složky ve složkách (např. `ANECT / Praha / DC1`), libovolná hloubka, počty serverů včetně podsložek.
- Pravým tlačítkem na složku: Nový server v této složce, Nová podsložka, Přejmenovat (přejmenuje celý podstrom), Přesunout do složky / do kořene, Barva (podsložky ji dědí), Smazat prázdnou složku.
- Přetažení: server na složku = přesun serveru; **složka na složku = přesun celé složky i s obsahem** (nelze do sebe sama ani do vlastní podsložky).
- Menu „+“ → Nová složka… (podsložky odděl lomítkem, např. `ANECT/Praha`); prázdné složky se pamatují.
- Editor serveru: výběr složky zobrazuje celé cesty, novou podsložku zadáš jako `A/B`.
- Kompatibilní s existujícími daty: dosavadní skupiny jsou složky nejvyšší úrovně.
