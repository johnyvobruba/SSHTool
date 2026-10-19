# Publikace na GitHub a podepisování aktualizací

Jednorázové nastavení (na Macu v adresáři projektu). Potřebuješ `git` a [GitHub CLI](https://cli.github.com) (`brew install gh`, `gh auth login`).

## 1. Klíč pro podpis aktualizací

```bash
swift scripts/generate-update-key.swift
```

- `update-public-key.txt` – veřejný klíč, **patří do repozitáře** (aplikace jím ověřuje aktualizace).
- `~/.sshtool-update-signing-key` – soukromý klíč (práva 600), **nikdy do repozitáře**. Zálohuj ho (např. Bitwarden).
  Bez něj nepůjde vydat aktualizaci, kterou stávající instalace přijmou.

## 2. Repozitář

```bash
git init -b main
git add .
git status                      # zkontroluj: žádné import/, backup-*, *.zip, klíče
git commit -m "SSHTool 0.23.0"
gh repo create SSHTool --public --source=. --push \
  --description "Nativní macOS SSH klient pro správu síťové a bezpečnostní infrastruktury"
gh secret set UPDATE_SIGNING_KEY < ~/.sshtool-update-signing-key
```

Pak v GitHubu: **Actions → Build & Release → Run workflow** (první vydání), nebo stačí další push.

## 3. Nová verze

1. Změň `VERSION` v `build-app.sh` (např. `0.23.1`).
2. Přidej do `CHANGELOG.md` sekci `## 0.23.1` se změnami.
3. Spusť `./publish.sh` – zkontroluje verzi (není už vydaná), CHANGELOG, citlivé soubory
   (`import/`, zálohy, odchyty, klíče, tokeny), privátní IP adresy, zkušebně sestaví, ukáže souhrn
   a po potvrzení udělá commit + push.

   ```bash
   ./publish.sh --dry-run        # jen kontroly a souhrn
   ./publish.sh -m "Oprava X"    # vlastní commit zpráva
   ./publish.sh --no-build       # bez zkušebního sestavení
   ```

GitHub Actions sestaví aplikaci, podepíše `SSHTool-0.23.1.zip` a vytvoří release `v0.23.1`.
Nainstalované aplikace novou verzi nabídnou při dalším spuštění.

## Poznámky

- Lokální `./build-app.sh` zjistí repozitář z `git remote origin` a vloží ho do aplikace (jinak jsou aktualizace vypnuté).
- Aplikace je podepsaná ad-hoc. Pro distribuci bez varování Gatekeeperu je potřeba Apple Developer ID + notarizace
  (`SIGN_IDENTITY="Developer ID Application: …" ./build-app.sh` + `xcrun notarytool`).
- Workflow používá jen vestavěný `GITHUB_TOKEN` (oprávnění `contents: write`) a secret `UPDATE_SIGNING_KEY`.
