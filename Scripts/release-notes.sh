#!/bin/bash
# Emit an HTML release-notes fragment for a given version, extracted from CHANGELOG.md.
#
# The Sparkle release pipeline drops the output next to the DMG as
# `ModernPAR-<version>.html`; generate_appcast then picks up any .html/.md/.txt file that
# shares an archive's basename and — because this fragment carries no DOCTYPE or <body> —
# embeds it as the appcast item's CDATA <description>, which Sparkle renders as the
# "What's New" notes in the update dialog.
#
# CHANGELOG.md is the single source of truth: this reads the "## [<version>] …" section and
# converts its small Markdown subset (### headings, - bullets, paragraphs, `code`, [links])
# to escaped HTML. It FAILS if the version has no section, so every release documents itself.
#
# Usage: Scripts/release-notes.sh <version> [CHANGELOG.md]
set -euo pipefail

VERSION="${1:?usage: release-notes.sh <version> [changelog]}"
CHANGELOG="${2:-CHANGELOG.md}"
[ -f "$CHANGELOG" ] || { echo "release-notes: no $CHANGELOG" >&2; exit 1; }

/usr/bin/python3 - "$VERSION" "$CHANGELOG" <<'PY'
import sys, re, html

version, path = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().splitlines()

# Collect the body of the "## [<version>] …" section (up to the next "## " header).
body, in_section = [], False
for ln in lines:
    if ln.startswith("## "):
        if in_section:
            break
        in_section = ("[%s]" % version) in ln
        continue
    if in_section:
        # The footer's link-reference definitions ("[0.1.2]: https://…") end the notes
        # — relevant when the released version is the last section in the file.
        if re.match(r"^\[[^\]]+\]:\s*\S", ln):
            break
        body.append(ln)

while body and not body[0].strip():
    body.pop(0)
while body and not body[-1].strip():
    body.pop()

if not body:
    sys.stderr.write("release-notes: no CHANGELOG section for %s\n" % version)
    sys.exit(1)


def inline(text):
    # Escape first, then re-introduce the structural inline tags we support.
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", lambda m: "<code>%s</code>" % m.group(1), text)
    text = re.sub(
        r"\[([^\]]+)\]\((https?://[^)\s]+)\)",
        lambda m: '<a href="%s">%s</a>' % (html.escape(m.group(2), quote=True), m.group(1)),
        text,
    )
    return text


out, i, n = [], 0, len(body)
while i < n:
    stripped = body[i].strip()
    if not stripped:
        i += 1
        continue
    if stripped.startswith("### "):
        out.append("<h3>%s</h3>" % inline(stripped[4:].strip()))
        i += 1
    elif stripped[:2] in ("- ", "* "):
        items = []
        while i < n and body[i].strip()[:2] in ("- ", "* "):
            text = body[i].strip()[2:].strip()
            i += 1
            # Absorb wrapped continuation lines (indented, not a new bullet/heading).
            while i < n:
                cont = body[i].strip()
                if not cont or cont[:2] in ("- ", "* ") or cont[:4] == "### ":
                    break
                text += " " + cont
                i += 1
            items.append("<li>%s</li>" % inline(text))
        out.append("<ul>%s</ul>" % "".join(items))
    else:
        para = []
        while i < n and body[i].strip() and body[i].strip()[:4] != "### " and body[i].strip()[:2] not in ("- ", "* "):
            para.append(body[i].strip())
            i += 1
        out.append("<p>%s</p>" % inline(" ".join(para)))

sys.stdout.write("\n".join(out) + "\n")
PY
