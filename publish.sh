#!/bin/bash
# Publikace nové verze SSHTool na GitHub.
#
#   ./publish.sh                  – kontroly, souhrn, potvrzení, commit + push
#   ./publish.sh -m "popis"       – vlastní commit zpráva (výchozí „SSHTool <verze>“)
#   ./publish.sh --dry-run        – jen kontroly a souhrn, nic se necommituje ani nepushuje
#   ./publish.sh --no-build       – přeskočí zkušební sestavení
#   ./publish.sh --yes            – bez dotazu na potvrzení (citlivé soubory se blokují vždy)
#
# Push spustí GitHub Actions: sestavení, podpis a GitHub Release (viz .github/workflows/release.yml).
set -euo pipefail
cd "$(dirname "$0")"

MSG=""; DRY=0; BUILD=1; YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m) MSG="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --no-build) BUILD=0; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "Neznámý parametr: $1"; exit 2 ;;
  esac
done

red() { printf '\033[31m%s\033[0m\n' "$*"; }
yel() { printf '\033[33m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
die() { red "✗ $*"; exit 1; }

# ---------- 1. Git a repozitář
command -v git >/dev/null || die "Chybí git (xcode-select --install)"
git rev-parse --git-dir >/dev/null 2>&1 || die "Tady není git repozitář – nejdřív kroky z PUBLISHING.md"
REMOTE="$(git config --get remote.origin.url || true)"
[[ -n "$REMOTE" ]] || die "Chybí remote origin (gh repo create … --source=. --push)"
BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] || die "Jsi na větvi '$BRANCH' – vydání se dělá z main"
grn "✓ Repozitář: $REMOTE (větev main)"

# ---------- 2. Verze a CHANGELOG
VERSION="$(sed -nE 's/^VERSION="\$\{VERSION_OVERRIDE:-([0-9]+\.[0-9]+\.[0-9]+)\}"/\1/p' build-app.sh)"
[[ -n "$VERSION" ]] || die "Verzi se nepodařilo přečíst z build-app.sh"
if git ls-remote --exit-code --tags origin "refs/tags/v$VERSION" >/dev/null 2>&1; then
  die "Verze $VERSION už je vydaná (tag v$VERSION) – zvyš VERSION v build-app.sh"
fi
grn "✓ Nová verze: $VERSION"

NOTES="$(awk -v v="## $VERSION" 'index($0, v)==1 {f=1; next} /^## / && f {exit} f' CHANGELOG.md | sed '/^[[:space:]]*$/d')"
[[ -n "$NOTES" ]] || die "CHANGELOG.md nemá sekci '## $VERSION' s popisem změn"
grn "✓ CHANGELOG obsahuje sekci $VERSION"

if [[ -f update-public-key.txt ]]; then grn "✓ Veřejný klíč pro aktualizace: update-public-key.txt"
else yel "! Chybí update-public-key.txt – aplikace nebude moct aktualizace automaticky instalovat (swift scripts/generate-update-key.swift)"; fi

# ---------- 3. Citlivé soubory (blokuje vždy)
FILES="$(git add -A --dry-run 2>/dev/null | sed -E "s/^add '(.*)'$/\1/")"
BLOCKED="$(printf '%s\n' "$FILES" | grep -E '(^|/)(import|backup-[^/]*)/|\.(pcap|cap|zip|pem|p12|key|log)$|signing-key|(^|/)\.env$|sessions\.json$|settings\.json$|snippets\.json$' || true)"
if [[ -n "$BLOCKED" ]]; then
  red "✗ Tyto soubory nesmí do veřejného repozitáře:"; printf '   %s\n' $BLOCKED
  die "Přidej je do .gitignore nebo je odstraň z projektu"
fi
LEAK=""
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  if grep -IlqE 'BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}' "$f" 2>/dev/null; then LEAK+="$f"$'\n'; fi
done <<< "$FILES"
[[ -z "$LEAK" ]] || { red "✗ Soubory obsahují klíč nebo token:"; printf '   %s' "$LEAK"; die "Odstraň tajné údaje"; }

# privátní IP adresy – jen varování (dokumentační rozsahy jsou v pořádku)
PRIV="$(printf '%s\n' "$FILES" | while IFS= read -r f; do
  [[ -f "$f" ]] && grep -InHE '\b(10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]{1,3}\.[0-9]{1,3}\b' "$f" 2>/dev/null \
    | grep -vE '\b10\.0\.0\.[0-9]{1,3}\b|\b10\.0\.0\.0/' || true
done | head -20)"
grn "✓ Žádné citlivé soubory ani klíče"
if [[ -n "$PRIV" ]]; then
  yel "! Privátní IP adresy v souborech (zkontroluj, že nejde o skutečnou infrastrukturu):"
  printf '%s\n' "$PRIV" | sed 's/^/   /' | cut -c1-160
fi

# ---------- 4. Zkušební sestavení
if [[ $BUILD -eq 1 ]]; then
  echo "▶ Zkušební sestavení (swift build -c release)…"
  swift build -c release 2>&1 | tail -3 || die "Sestavení selhalo – oprav chyby před publikací"
  grn "✓ Sestavení prošlo"
fi

# ---------- 5. Souhrn a potvrzení
echo
echo "──────── Souhrn ────────"
echo "Verze:   $VERSION"
echo "Commit:  ${MSG:-SSHTool $VERSION}"
echo "Změny:"
git status --short | sed 's/^/   /'
echo "Poznámky k vydání:"
printf '%s\n' "$NOTES" | sed 's/^/   /'
echo "────────────────────────"

if [[ $DRY -eq 1 ]]; then yel "Dry-run: nic se necommitovalo ani nepushnulo."; exit 0; fi
if [[ $YES -eq 0 ]]; then
  read -r -p "Publikovat verzi $VERSION na GitHub? [a/N] " ans
  [[ "$ans" =~ ^[aAyY]$ ]] || { yel "Zrušeno."; exit 0; }
fi

# ---------- 6. Commit a push
git add -A
if git diff --cached --quiet; then
  yel "Žádné nové změny k commitu – pushnu jen existující commity."
else
  git commit -m "${MSG:-SSHTool $VERSION}"
fi
if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then git push
else git push -u origin main; fi

grn "✓ Pushnuto. GitHub Actions teď sestaví a vydá v$VERSION."
REPO="$(printf '%s' "$REMOTE" | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')"
echo "  Průběh: https://github.com/$REPO/actions"
echo "  Vydání: https://github.com/$REPO/releases/tag/v$VERSION"
if command -v gh >/dev/null; then echo "  Sledovat v terminálu: gh run watch"; fi
