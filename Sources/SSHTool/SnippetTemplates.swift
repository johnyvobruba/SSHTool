import Foundation

/// Šablony snippetů podle technologie. Obsahují jen diagnostické (čtecí) příkazy –
/// nic, co mění konfiguraci. Snippety se navíc ve výchozím stavu jen vkládají, nespouštějí.
/// Syntaxi ověř proti verzi zařízení (příkazy se mezi verzemi liší).
struct SnippetPack: Identifiable {
    let id: String          // název šablony = kategorie snippetů
    let note: String
    let items: [(String, String)]   // (název, příkaz)

    func snippets(group: String) -> [Snippet] {
        items.map { Snippet(name: $0.0, command: $0.1, group: group, category: id) }
    }

    static let all: [SnippetPack] = [
        SnippetPack(id: "Check Point Gaia", note: "R80.x / R81.x / R82, expert i clish", items: [
            ("Stav clusteru", "cphaprob state"),
            ("Rozhraní clusteru", "cphaprob -a if"),
            ("Kritická zařízení (pnote)", "cphaprob list"),
            ("Stav policy", "fw stat"),
            ("Stav FW (cpstat)", "cpstat fw"),
            ("SecureXL stav", "fwaccel stat"),
            ("SecureXL statistiky", "fwaccel stats -s"),
            ("CoreXL instance", "fw ctl multik stat"),
            ("Počet spojení", "fw tab -t connections -s"),
            ("Procesy CP (cpwd)", "cpwd_admin list"),
            ("Zapnuté blady", "enabled_blades"),
            ("Licence", "cplic print"),
            ("Verze a hotfixy", "cpinfo -y all"),
            ("cpview", "cpview"),
            ("Rozhraní (clish)", "show interfaces all"),
            ("Routy (clish)", "show route"),
        ]),
        SnippetPack(id: "Check Point Maestro (MHO)", note: "Scalable Platforms – gclish / expert na SG", items: [
            ("Stav Security Group", "asg stat -v"),
            ("Monitor SG", "asg monitor"),
            ("Diagnostika SG", "asg diag verify"),
            ("Výkon SG", "asg perf -v"),
            ("Security Groups (MHO)", "show maestro security-groups"),
            ("Konfigurace Maestro (MHO)", "show maestro configuration"),
            ("Stav clusteru", "cphaprob state"),
            ("Verze", "cpinfo -y all"),
        ]),
        SnippetPack(id: "Palo Alto Networks", note: "PAN-OS CLI (operational mode)", items: [
            ("Systémové info", "show system info"),
            ("HA stav", "show high-availability state"),
            ("Prostředky", "show system resources"),
            ("Session info", "show session info"),
            ("Rozhraní", "show interface all"),
            ("Routy", "show routing route"),
            ("Drop countery", "show counter global filter delta yes severity drop"),
            ("Joby", "show jobs all"),
            ("Resource monitor", "show running resource-monitor"),
            ("Licence", "request license info"),
        ]),
        SnippetPack(id: "Cisco FTD (Firepower)", note: "FTD CLI (clish), spravované z FMC", items: [
            ("Verze", "show version"),
            ("Failover", "show failover"),
            ("Správce (FMC)", "show managers"),
            ("Rozhraní", "show interface ip brief"),
            ("Routy", "show route"),
            ("Počet spojení", "show conn count"),
            ("ASP drop", "show asp drop"),
            ("CPU", "show cpu usage"),
            ("Paměť", "show memory"),
            ("Running config", "show running-config"),
        ]),
        SnippetPack(id: "Cisco ASA 9.x", note: "ASA 9.0+ (privilegovaný režim)", items: [
            ("Bez stránkování", "terminal pager 0"),
            ("Verze", "show version"),
            ("Failover", "show failover"),
            ("Rozhraní", "show interface ip brief"),
            ("Routy", "show route"),
            ("Počet spojení", "show conn count"),
            ("Počet NAT překladů", "show xlate count"),
            ("ASP drop", "show asp drop"),
            ("CPU", "show cpu usage"),
            ("VPN souhrn", "show vpn-sessiondb summary"),
            ("IKEv2 SA", "show crypto ikev2 sa"),
            ("Packet tracer (uprav)", "packet-tracer input inside tcp 10.0.0.10 40000 192.0.2.10 443 detailed"),
        ]),
        SnippetPack(id: "Cisco IOS 15.x", note: "IOS 15 – směrovače a přepínače", items: [
            ("Bez stránkování", "terminal length 0"),
            ("Verze", "show version"),
            ("Rozhraní (IP)", "show ip interface brief"),
            ("Stav portů", "show interfaces status"),
            ("Routy", "show ip route"),
            ("VLAN", "show vlan brief"),
            ("Spanning tree", "show spanning-tree summary"),
            ("CDP sousedé", "show cdp neighbors"),
            ("CPU", "show processes cpu sorted"),
            ("Inventář", "show inventory"),
            ("Log", "show logging"),
            ("Running config", "show running-config"),
        ]),
        SnippetPack(id: "F5 BIG-IP", note: "tmsh (z bash) – TMOS 13+", items: [
            ("Verze", "tmsh show sys version"),
            ("Failover", "tmsh show sys failover"),
            ("Sync stav", "tmsh show cm sync-status"),
            ("Virtual servery", "tmsh show ltm virtual"),
            ("Pooly", "tmsh show ltm pool"),
            ("Rozhraní", "tmsh show net interface"),
            ("Self IP", "tmsh list net self"),
            ("Výkon", "tmsh show sys performance"),
            ("Hardware", "tmsh show sys hardware"),
        ]),
        SnippetPack(id: "Fortinet FortiGate", note: "FortiOS 6.x / 7.x", items: [
            ("Stav systému", "get system status"),
            ("Výkon", "get system performance status"),
            ("HA stav", "get system ha status"),
            ("Routy", "get router info routing-table all"),
            ("Session statistiky", "diagnose sys session stat"),
            ("Rozhraní", "get system interface physical"),
        ]),
        SnippetPack(id: "Juniper Junos", note: "SRX / EX / MX (operational mode)", items: [
            ("Verze", "show version"),
            ("Hardware", "show chassis hardware"),
            ("Alarmy", "show system alarms"),
            ("Rozhraní", "show interfaces terse"),
            ("Routy (souhrn)", "show route summary"),
            ("Cluster (SRX)", "show chassis cluster status"),
            ("Session souhrn (SRX)", "show security flow session summary"),
        ]),
        SnippetPack(id: "Linux", note: "Obecný Linux server", items: [
            ("Uptime / load", "uptime"),
            ("Disky", "df -h"),
            ("Paměť", "free -m"),
            ("Adresy", "ip -br address"),
            ("Naslouchající porty", "ss -tulpn"),
            ("Chyby v journalu", "journalctl -p err -n 50 --no-pager"),
        ]),
    ]
}
