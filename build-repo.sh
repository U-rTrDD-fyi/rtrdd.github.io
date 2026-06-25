#!/usr/bin/env bash
# build-repo.sh — regenerate a GitHub Pages jailbreak repo from the debs present.
#
# Drop a .deb into debs/ and run this. It will, for every package found:
#   - generate depictions/<pkg>.json (Sileo native) and .html (Zebra/Cydia)
#   - inject Depiction / SileoDepiction / Icon fields into Packages
#   - refresh the package rows in index.html (between PKGS markers)
#   - rebuild Packages(.bz2/.gz/.xz/.zst) and Release, optionally signing.
#
# Single source of truth = each deb's own control fields. Optional richer text:
#   meta/<pkg>.md            -> long description (markdown) for the depiction
#   meta/<pkg>.changelog.md  -> changelog (markdown)
# If those files are absent, the deb's Description / Version are used.
#
# Requires: dpkg-scanpackages, dpkg-deb, python3, bzip2, gzip; optional xz, zstd, gpg.
#   macOS:  brew install dpkg xz zstd

set -euo pipefail
[[ -f .repoenv ]] && source .repoenv
SIGN_KEY="${SIGN_KEY:-}"

# ---- repo identity / layout (edit these) ----------------------------------
BASE_URL="https://rtrdd.github.io"
ORIGIN="rTrDD Repo"
LABEL="rTrDD Repo"
REPO_DESC="https://rtrdd.github.io/"
ARCHS="iphoneos-arm64"
TINT="#58a6ff"

DEB_DIR="debs"
DEPICT_DIR="depictions"
ICON_DIR="icons"
META_DIR="meta"
INDEX="index.html"
EXTRA_OVERRIDE=".extra-override"   # generated; safe to gitignore
# ---------------------------------------------------------------------------

[[ -d "$DEB_DIR" ]] || { echo "no $DEB_DIR/ directory here" >&2; exit 1; }
command -v dpkg-scanpackages >/dev/null || { echo "dpkg-scanpackages missing (brew install dpkg)" >&2; exit 1; }

mkdir -p "$DEPICT_DIR"

# portable hashers (GNU coreutils vs macOS built-ins)
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
           else shasum -a 256 "$1" | awk '{print $1}'; fi; }
md5h()   { if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | awk '{print $1}'
           else md5 -q "$1"; fi; }

# ---------------------------------------------------------------------------
# 1. Per-package generation: depictions, extra-override, index rows.
#    All driven from each deb's control fields, done in python for safe
#    JSON/HTML escaping.
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
    echo "==> generating depictions + index rows"
    BASE_URL="$BASE_URL" TINT="$TINT" DEB_DIR="$DEB_DIR" DEPICT_DIR="$DEPICT_DIR" \
    ICON_DIR="$ICON_DIR" META_DIR="$META_DIR" INDEX="$INDEX" EXTRA_OVERRIDE="$EXTRA_OVERRIDE" \
    python3 - <<'PY'
import os, glob, json, html, subprocess, re

base   = os.environ["BASE_URL"].rstrip("/")
tint   = os.environ["TINT"]
debdir = os.environ["DEB_DIR"]
depdir = os.environ["DEPICT_DIR"]
icodir = os.environ["ICON_DIR"]
metadir= os.environ["META_DIR"]
index  = os.environ["INDEX"]
extra  = os.environ["EXTRA_OVERRIDE"]

def field(deb, name):
    try:
        return subprocess.check_output(["dpkg-deb", "-f", deb, name],
                                       stderr=subprocess.DEVNULL).decode("utf-8", "replace").strip()
    except Exception:
        return ""

def desc_to_md(name, desc):
    """Turn a control Description (synopsis + extended) into markdown."""
    lines = desc.split("\n")
    syn = lines[0].strip()
    paras, cur = [], []
    for l in lines[1:]:
        s = l.strip()
        if s in ("", "."):
            if cur: paras.append(" ".join(cur)); cur = []
        else:
            cur.append(s)
    if cur: paras.append(" ".join(cur))
    head = f"**{name}** — {syn}" if syn else f"**{name}**"
    return "\n\n".join([head] + paras)

# --- tiny markdown -> HTML (paragraphs, bold, inline code, fenced code, lists, links)
def md_to_html(md):
    out, i, lines = [], 0, md.split("\n")
    def inline(t):
        t = html.escape(t)
        t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
        t = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", t)
        t = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', t)
        return t
    while i < len(lines):
        line = lines[i]
        if line.strip().startswith("```"):
            i += 1; buf = []
            while i < len(lines) and not lines[i].strip().startswith("```"):
                buf.append(html.escape(lines[i])); i += 1
            i += 1
            out.append("<pre><code>" + "\n".join(buf) + "</code></pre>")
        elif line.strip().startswith("- "):
            items = []
            while i < len(lines) and lines[i].strip().startswith("- "):
                items.append("<li>" + inline(lines[i].strip()[2:]) + "</li>"); i += 1
            out.append("<ul>" + "".join(items) + "</ul>")
        elif line.strip() == "":
            i += 1
        else:
            buf = []
            while i < len(lines) and lines[i].strip() != "" \
                  and not lines[i].strip().startswith(("```", "- ")):
                buf.append(lines[i].strip()); i += 1
            out.append("<p>" + inline(" ".join(buf)) + "</p>")
    return "\n".join(out)

debs = sorted(glob.glob(os.path.join(debdir, "*.deb")))
extra_lines, rows = [], []

for deb in debs:
    pkg  = field(deb, "Package")
    if not pkg:  # not a real deb
        continue
    name = field(deb, "Name") or pkg
    ver  = field(deb, "Version")
    arch = field(deb, "Architecture")
    sect = field(deb, "Section") or "Utilities"
    dev  = field(deb, "Author") or field(deb, "Maintainer")
    dev  = re.sub(r"\s*<[^>]+>", "", dev).strip()  # drop email for display
    src  = field(deb, "Homepage")
    fn   = os.path.basename(deb)

    # description body: prefer meta/<pkg>.md, else build from control Description
    mp = os.path.join(metadir, f"{pkg}.md")
    if os.path.isfile(mp):
        body_md = open(mp, encoding="utf-8").read().strip()
    else:
        body_md = desc_to_md(name, field(deb, "Description"))

    # changelog: prefer meta/<pkg>.changelog.md, else a default entry
    cp = os.path.join(metadir, f"{pkg}.changelog.md")
    if os.path.isfile(cp):
        clog_md = open(cp, encoding="utf-8").read().strip()
    else:
        clog_md = f"**{ver}**\n\n- Released."

    # ---- Sileo native depiction (JSON) ----
    info_rows = [
        {"class": "DepictionTableTextView", "title": "Version",      "text": ver},
        {"class": "DepictionTableTextView", "title": "Architecture", "text": arch},
        {"class": "DepictionTableTextView", "title": "Section",      "text": sect},
    ]
    if dev:
        info_rows.append({"class": "DepictionTableTextView", "title": "Developer", "text": dev})
    if src:
        info_rows.append({"class": "DepictionTableButtonView", "title": "Source Code",
                          "action": src, "openExternal": "true"})

    depiction = {
        "minVersion": "0.1",
        "class": "DepictionTabView",
        "tintColor": tint,
        "tabs": [
            {"tabname": "Details", "class": "DepictionStackView", "views": [
                {"class": "DepictionSubheaderView", "title": "Description"},
                {"class": "DepictionMarkdownView", "markdown": body_md},
                {"class": "DepictionSeparatorView"},
                {"class": "DepictionSubheaderView", "title": "Information"},
                *info_rows,
            ]},
            {"tabname": "Changelog", "class": "DepictionStackView", "views": [
                {"class": "DepictionMarkdownView", "markdown": clog_md},
            ]},
        ],
    }
    with open(os.path.join(depdir, f"{pkg}.json"), "w", encoding="utf-8") as f:
        json.dump(depiction, f, indent=2, ensure_ascii=False)

    # ---- HTML depiction (Zebra/Cydia) ----
    info_html = "".join(
        f'<tr><td class="k">{html.escape(t)}</td><td class="v">{v}</td></tr>'
        for t, v in [("Version", html.escape(ver)), ("Architecture", html.escape(arch)),
                     ("Section", html.escape(sect))]
        + ([("Developer", html.escape(dev))] if dev else [])
        + ([("Source", f'<a href="{html.escape(src)}">link</a>')] if src else [])
    )
    html_doc = f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{html.escape(name)}</title>
<style>
:root{{--text:#e6edf3;--muted:#8b949e;--accent:{tint};--border:#30363d;--code:rgba(110,118,129,.15);
--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}}
@media(prefers-color-scheme:light){{:root{{--text:#1f2328;--muted:#656d76;--border:#d0d7de;--code:rgba(175,184,193,.2)}}}}
*{{box-sizing:border-box}}body{{margin:0;padding:16px;color:var(--text);background:transparent;
font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;font-size:16px;line-height:1.55;-webkit-text-size-adjust:100%}}
h2{{font-size:.8rem;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);font-weight:600;margin:24px 0 8px}}
h2:first-child{{margin-top:0}}p{{margin:0 0 12px}}ul{{margin:0 0 12px;padding-left:20px}}li{{margin-bottom:4px}}
code{{font-family:var(--mono);font-size:.88em;background:var(--code);padding:1px 5px;border-radius:5px}}
pre{{background:var(--code);padding:12px 14px;border-radius:8px;overflow-x:auto;margin:0 0 12px}}
pre code{{background:none;padding:0;font-size:.85rem}}a{{color:var(--accent);text-decoration:none}}
hr{{border:none;border-top:1px solid var(--border);margin:20px 0}}table{{width:100%;border-collapse:collapse}}
td{{padding:8px 0;border-bottom:1px solid var(--border);vertical-align:top}}td.k{{color:var(--muted);width:38%}}
td.v{{font-family:var(--mono);font-size:.9rem}}table tr:last-child td{{border-bottom:none}}
</style></head><body>
<h2>Description</h2>
{md_to_html(body_md)}
<hr>
<h2>Information</h2>
<table>{info_html}</table>
<h2>Changelog</h2>
{md_to_html(clog_md)}
</body></html>
"""
    with open(os.path.join(depdir, f"{pkg}.html"), "w", encoding="utf-8") as f:
        f.write(html_doc)

    # ---- extra-override lines (inject fields into Packages w/o touching deb) ----
    extra_lines.append(f"{pkg} SileoDepiction {base}/{depdir}/{pkg}.json")
    extra_lines.append(f"{pkg} Depiction {base}/{depdir}/{pkg}.html")
    if os.path.isfile(os.path.join(icodir, f"{pkg}.png")):
        extra_lines.append(f"{pkg} Icon {base}/{icodir}/{pkg}.png")

    # ---- index.html row ----
    syn = field(deb, "Description").split("\n")[0].strip()
    rows.append(
        '    <div class="pkg">\n'
        '      <div>\n'
        f'        <div class="pkg-name"><code>{html.escape(name)}</code></div>\n'
        f'        <div class="pkg-desc">{html.escape(syn)}</div>\n'
        '      </div>\n'
        '      <div style="display:flex; align-items:center; gap:12px;">\n'
        f'        <a class="dl" href="{debdir}/{html.escape(fn)}">.deb</a>\n'
        f'        <span class="pkg-ver">{html.escape(ver)}</span>\n'
        '      </div>\n'
        '    </div>'
    )

# write extra-override
with open(extra, "w", encoding="utf-8") as f:
    f.write("\n".join(extra_lines) + ("\n" if extra_lines else ""))

# splice rows into index.html between markers (if present)
if os.path.isfile(index):
    txt = open(index, encoding="utf-8").read()
    block = "\n".join(rows)
    pat = re.compile(r"(<!-- PKGS:START -->).*?(<!-- PKGS:END -->)", re.DOTALL)
    if pat.search(txt):
        new = pat.sub(lambda m: m.group(1) + "\n" + block + "\n    " + m.group(2), txt)
        open(index, "w", encoding="utf-8").write(new)
    else:
        print("    (index.html has no PKGS markers; skipped row update)")

print(f"    {len(debs)} package(s) processed")
PY
else
    echo "==> python3 not found; skipping depictions + index (Packages/Release still build)"
    : > "$EXTRA_OVERRIDE"
fi

# ---------------------------------------------------------------------------
# 2. Packages index (with depiction/icon fields injected via extra-override)
# ---------------------------------------------------------------------------
echo "==> scanning $DEB_DIR/ for packages"
if [[ -s "$EXTRA_OVERRIDE" ]]; then
    dpkg-scanpackages -m -e "$EXTRA_OVERRIDE" "$DEB_DIR" /dev/null > Packages 2>/dev/null
else
    dpkg-scanpackages -m "$DEB_DIR" /dev/null > Packages 2>/dev/null
fi
# dpkg-scanpackages lowercases extra-override field names; Sileo's parser is
# case-sensitive, so restore the canonical casing of the depiction field.
sed -i.bak 's/^Sileodepiction:/SileoDepiction:/' Packages && rm -f Packages.bak

echo "==> compressing Packages"
rm -f Packages.bz2 Packages.gz Packages.xz Packages.zst
bzip2 -kf9 Packages
gzip  -kf9 Packages
command -v xz   >/dev/null 2>&1 && xz   -kf9    Packages
command -v zstd >/dev/null 2>&1 && zstd -kf19 -q Packages

# ---------------------------------------------------------------------------
# 3. Release (+ optional signing)
# ---------------------------------------------------------------------------
echo "==> writing Release"
emit_hashes() {  # $1 = section header, $2 = hasher fn name
    echo "$1:"
    for f in Packages Packages.bz2 Packages.gz Packages.xz Packages.zst; do
        [[ -f "$f" ]] || continue
        printf ' %s %s %s\n' "$("$2" "$f")" "$(wc -c < "$f" | tr -d ' ')" "$f"
    done
}
{
    echo "Origin: $ORIGIN"
    echo "Label: $LABEL"
    echo "Suite: stable"
    echo "Version: 1.0"
    echo "Codename: ios"
    echo "Architectures: $ARCHS"
    echo "Components: main"
    echo "Description: $REPO_DESC"
    emit_hashes "MD5Sum" md5h
    emit_hashes "SHA256" sha256
} > Release

if [[ -n "$SIGN_KEY" ]]; then
    echo "==> signing Release with $SIGN_KEY"
    rm -f InRelease Release.gpg
    gpg --default-key "$SIGN_KEY" --clearsign -o InRelease Release
    gpg --default-key "$SIGN_KEY" -abs        -o Release.gpg Release
else
    echo "==> SIGN_KEY not set, leaving repo unsigned"
fi

echo "==> done"
ls -la Packages* Release 2>/dev/null
