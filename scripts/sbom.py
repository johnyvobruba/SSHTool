#!/usr/bin/env python3
"""SBOM pro release: verze aplikace, commit, Swift, balíčky SwiftPM a přibalené knihovny z Homebrew.

Použití (GitHub Actions):  python3 scripts/sbom.py <App> <verze> [homebrew-formula …] > <App>-<verze>.sbom.json
Chyby nástrojů nevadí – pole zůstane prázdné (SBOM nesmí shodit release)."""
import datetime, json, os, platform, subprocess, sys


def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=120).stdout
    except Exception:
        return ""


def brew(formulae):
    if not formulae:
        return []
    names = list(formulae)
    for f in formulae:
        names += run(["brew", "deps", "--installed", f]).split()
    names = sorted(set(names))
    try:
        data = json.loads(run(["brew", "info", "--json=v2"] + names) or "{}")
    except ValueError:
        return []
    out = []
    for f in data.get("formulae", []):
        inst = f.get("installed") or [{}]
        files = (f.get("bottle", {}).get("stable", {}) or {}).get("files", {}) or {}
        out.append({
            "name": f.get("name"),
            "version": inst[0].get("version"),
            "license": f.get("license"),
            "homepage": f.get("homepage"),
            "bottle_sha256": {k: v.get("sha256") for k, v in files.items() if k.startswith("arm64")},
        })
    return out


def swiftpm():
    try:
        with open("Package.resolved") as fh:
            pins = json.load(fh).get("pins", [])
        return [{"identity": p.get("identity"), "location": p.get("location"),
                 "version": p.get("state", {}).get("version"), "revision": p.get("state", {}).get("revision")} for p in pins]
    except (OSError, ValueError):
        return []


app, version, formulae = sys.argv[1], sys.argv[2], sys.argv[3:]
print(json.dumps({
    "app": app,
    "version": version,
    "commit": os.environ.get("GITHUB_SHA", ""),
    "built": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "macos": platform.mac_ver()[0],
    "swift": run(["swift", "--version"]).splitlines()[:1],
    "swiftpm": swiftpm(),
    "homebrew": brew(formulae),
}, indent=2, ensure_ascii=False))
