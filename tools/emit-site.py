#!/usr/bin/env python3
"""Turns the emitted legal Markdown into the pages GitHub Pages serves.

Deliberately not Jekyll. The privacy policy URL goes into Google's OAuth
console, and a page that 404s because a build step changed its mind about
where to put things is worse than an ugly page. This writes plain, complete
HTML files whose URLs cannot move.

    ./.build/debug/Cadenza                      # with CADENZA_EMIT_LEGAL=<dir>
    python3 tools/emit-site.py <dir> <out>
"""
import html
import re
import sys
from pathlib import Path

PAGES = [
    ("privacidade.md", "privacidade.html", "Política de Privacidade"),
    ("termos.md", "termos.html", "Termos de Uso"),
    ("licencas.md", "licencas.html", "Licenças e créditos"),
]

STYLE = """
:root { color-scheme: light dark; --ink:#1c1c1e; --dim:#6b6b70; --rule:#e3e3e6;
        --bg:#fff; --link:#b3261e; }
@media (prefers-color-scheme: dark) {
  :root { --ink:#ececf0; --dim:#9a9aa0; --rule:#2c2c2e; --bg:#161618; --link:#ff6b60; }
}
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--ink);
       font:16px/1.65 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
       -webkit-font-smoothing:antialiased; }
main { max-width:44rem; margin:0 auto; padding:3.5rem 1.5rem 5rem; }
h1 { font-size:2rem; line-height:1.2; margin:0 0 .4rem; letter-spacing:-.02em; }
h2 { font-size:1.25rem; margin:2.4rem 0 .6rem; letter-spacing:-.01em; }
h3 { font-size:1.02rem; margin:1.6rem 0 .4rem; }
p, li { margin:0 0 .85rem; }
ul { padding-left:1.2rem; }
a { color:var(--link); text-decoration:none; }
a:hover { text-decoration:underline; }
hr { border:0; border-top:1px solid var(--rule); margin:2.2rem 0; }
code { font-size:.9em; background:color-mix(in srgb, var(--ink) 8%, transparent);
       padding:.12em .35em; border-radius:4px; }
nav { display:flex; gap:1.1rem; flex-wrap:wrap; padding-bottom:1.6rem;
      margin-bottom:2rem; border-bottom:1px solid var(--rule); font-size:.92rem; }
nav a { color:var(--dim); }
nav a[aria-current] { color:var(--ink); font-weight:600; }
footer { margin-top:3.5rem; padding-top:1.4rem; border-top:1px solid var(--rule);
         color:var(--dim); font-size:.86rem; }
"""


def inline(text):
    """Markdown spans, applied to already-escaped text."""
    text = html.escape(text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    return text


def render(markdown):
    out, paragraph, in_list = [], [], False

    def flush():
        nonlocal paragraph
        if paragraph:
            out.append(f"<p>{inline(' '.join(paragraph))}</p>")
            paragraph = []

    def close_list():
        nonlocal in_list
        if in_list:
            out.append("</ul>")
            in_list = False

    for raw in markdown.splitlines():
        line = raw.strip()
        if not line:
            flush(); close_list()
        elif line.startswith("### "):
            flush(); close_list(); out.append(f"<h3>{inline(line[4:])}</h3>")
        elif line.startswith("## "):
            flush(); close_list(); out.append(f"<h2>{inline(line[3:])}</h2>")
        elif line.startswith("# "):
            flush(); close_list(); out.append(f"<h1>{inline(line[2:])}</h1>")
        elif line in ("---", "***"):
            flush(); close_list(); out.append("<hr>")
        elif line.startswith(("- ", "* ")):
            flush()
            if not in_list:
                out.append("<ul>"); in_list = True
            out.append(f"<li>{inline(line[2:])}</li>")
        else:
            close_list(); paragraph.append(line)

    flush(); close_list()
    return "\n".join(out)


def page(title, body, current):
    def link(href, label):
        mark = ' aria-current="page"' if href == current else ""
        return f'<a href="{href}"{mark}>{label}</a>'

    nav = "\n".join(link(href, label) for _, href, label in PAGES)
    return f"""<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)} — Cadenza</title>
<style>{STYLE}</style>
</head>
<body>
<main>
<nav>{nav}</nav>
{body}
<footer>
Cadenza é um projeto independente, sem vínculo com a Apple Inc. ou a Google LLC.
<a href="https://github.com/NspxMiguel/Cadenza">Código-fonte no GitHub</a>.
</footer>
</main>
</body>
</html>
"""


source, target = Path(sys.argv[1]), Path(sys.argv[2])
target.mkdir(parents=True, exist_ok=True)

for name, href, title in PAGES:
    markdown = (source / name).read_text(encoding="utf-8")
    (target / href).write_text(page(title, render(markdown), href), encoding="utf-8")
    print(f"  {href}")

# The privacy policy is the page Google is sent to, so it is also the landing
# page — a visitor who lands on the root should not have to guess.
(target / "index.html").write_text(
    (target / "privacidade.html").read_text(encoding="utf-8"), encoding="utf-8")
# Without this, Pages hands the whole directory to Jekyll, which would ignore
# anything it decided looked like a draft.
(target / ".nojekyll").write_text("", encoding="utf-8")
print("  index.html\n  .nojekyll")
