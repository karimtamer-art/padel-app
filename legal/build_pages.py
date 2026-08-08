# Builds docs/privacy.html and docs/terms.html from the two .docx files in
# legal/. Run again after editing either document — the pages are generated,
# not hand-maintained, so the published text can never drift from the source.
import zipfile, re, io, os, sys, html

ROOT = sys.argv[1]
OLD_EMAIL = "Padelrivals@gmail.com"
NEW_EMAIL = "help@padel-rivals.com"

# ── Corrections applied to the source text ──────────────────────────────────
# Both .docx files were written on 1 Aug 2026, before match tickets shipped.
# They state that a phone number is never public, which is no longer true: the
# match thread shows it to the other players in that match, on purpose, so they
# can arrange the game. Publishing the old wording would be a false privacy
# statement — the kind App Review checks and the PDPL cares about.
#
# THE .docx FILES STILL SAY THE OLD THING. Update them to match, or the next
# person to read the Word document will believe the wrong text.
#
# Each entry replaces one exact paragraph with one or more new paragraphs.
PATCHES = {
    "privacy": [(
        "Not public: your email address, phone number, date of birth, delivery "
        "addresses, payment receipts, notifications, and your direct messages "
        "— visible only to you and the person you are messaging.",
        ["Not public: your email address, date of birth, delivery addresses, "
         "payment receipts, notifications, and your direct messages — "
         "visible only to you and the person you are messaging.",
         "Shared with the players in your matches. When you join a match, the "
         "app opens a group thread for that match. Everyone playing in it can "
         "see your name, your level and your phone number, so you can arrange "
         "the game between you. That thread — and the phone numbers on it "
         "— stays open until 24 hours after the match’s scheduled "
         "start time, and then closes. Anything you post in it is visible to "
         "every player in that match. If the match is cancelled, the thread "
         "closes immediately."],
    )],
    "terms": [(
        "•  your display name, profile picture, level, match history and "
        "leaderboard position are publicly visible to other Users to enable "
        "matchmaking and leaderboards, and you consent to this display. Your "
        "email, phone, date of birth, and address are not public.",
        ["•  your display name, profile picture, level, match history and "
         "leaderboard position are publicly visible to other Users to enable "
         "matchmaking and leaderboards, and you consent to this display. Your "
         "email, date of birth, and address are not public;",
         "•  your phone number is shown to the other players in a match "
         "you have joined, for as long as that match’s thread is open, so "
         "that you can arrange the game between you. It is not shown to anyone "
         "else."],
    )],
}


def patch(paras, key):
    """Apply PATCHES[key], failing loudly if the source text has moved on."""
    for old, new in PATCHES.get(key, []):
        for i, (style, text) in enumerate(paras):
            if text == old:
                paras[i:i + 1] = [(style, n) for n in new]
                break
        else:
            raise SystemExit(
                f"PATCH MISS in {key}: the source paragraph changed, so the "
                f"correction was NOT applied. Re-check it before publishing.\n"
                f"  looked for: {old[:90]}...")
    return paras


def paragraphs(path):
    xml = zipfile.ZipFile(path).read("word/document.xml").decode("utf-8")
    out = []
    for p in re.split(r"</w:p>", xml):
        st = re.search(r'w:pStyle w:val="([^"]+)"', p)
        txt = "".join(re.findall(r"<w:t[^>]*>([^<]*)</w:t>", p))
        for a, b in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                     ("&quot;", '"'), ("&#39;", "'")]:
            txt = txt.replace(a, b)
        txt = txt.strip()
        if txt:
            out.append((st.group(1) if st else "Normal", txt))
    return out


def inline(text):
    """Escape, then re-add the only markup we want: mail/tel links."""
    t = html.escape(text)
    t = t.replace(OLD_EMAIL, NEW_EMAIL)
    t = re.sub(r"([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})",
               r'<a href="mailto:\1">\1</a>', t)
    t = re.sub(r"(?<![\d>])(01\d{9})(?![\d<])", r'<a href="tel:+2\1">\1</a>', t)
    return t


def slug(heading):
    m = re.match(r"^(\d+)\.", heading)
    return "s" + m.group(1) if m else re.sub(r"[^a-z0-9]+", "-", heading.lower()).strip("-")


def build(paras):
    """-> (title, stamp, toc entries, body html)"""
    title = stamp = ""
    toc, body = [], []
    bullets = []

    def flush():
        if bullets:
            body.append("<ul>\n" + "\n".join(
                f"  <li>{inline(b)}</li>" for b in bullets) + "\n</ul>")
            bullets.clear()

    for style, text in paras:
        if style == "Title":
            title = text
            continue
        if style == "Sub":
            stamp = text
            continue
        if style == "Bullet":
            bullets.append(re.sub(r"^[••]\s*", "", text))
            continue
        flush()
        if style == "Heading1":
            sid = slug(text)
            toc.append((sid, text))
            body.append(f'<h2 id="{sid}">{inline(text)}</h2>')
        elif style == "Heading2":
            body.append(f"<h3>{inline(text)}</h3>")
        else:
            body.append(f"<p>{inline(text)}</p>")
    flush()
    return title, stamp, toc, "\n".join(body)


PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} &middot; Padel Rivals</title>
<meta name="description" content="{desc}">
<meta name="color-scheme" content="light dark">
<meta property="og:title" content="{title} &middot; Padel Rivals">
<meta property="og:description" content="{desc}">
<meta property="og:type" content="website">
<link rel="stylesheet" href="style.css">
</head>
<body>

<header class="masthead">
  <div class="inner">
    <a class="brand" href="index.html">
      <span class="mark">P</span>
      <span class="name">Padel Rivals</span>
    </a>
    <nav>
      <a href="privacy.html"{p_cur}>Privacy</a>
      <a href="terms.html"{t_cur}>Terms</a>
      <a href="delete-account.html">Delete account</a>
    </nav>
  </div>
</header>

<main class="page">
  <div class="doc">
    <div class="doc-head">
      <h1>{h1}</h1>
      <div class="stamp">{stamp}</div>
    </div>

    <details class="toc-mobile" open>
      <summary>Contents</summary>
      <nav class="toc" aria-label="Contents">
        <h2>Contents</h2>
        <ol>
{toc}
        </ol>
      </nav>
    </details>

    <article class="prose">
{body}
    </article>
  </div>
</main>

<footer class="foot">
  <nav>
    <a href="index.html">Home</a> &nbsp;&middot;&nbsp;
    <a href="privacy.html">Privacy Policy</a> &nbsp;&middot;&nbsp;
    <a href="terms.html">Terms of Agreement</a> &nbsp;&middot;&nbsp;
    <a href="delete-account.html">Delete your account</a>
  </nav>
  <p>Padel Rivals &middot; Cairo, Egypt &middot;
     <a href="mailto:{email}">{email}</a></p>
</footer>

</body>
</html>
"""


def render(kind, docx, h1, desc):
    title, stamp, toc, body = build(
        patch(paragraphs(os.path.join(ROOT, docx)), kind))
    toc_html = "\n".join(
        f'          <li><a href="#{sid}">{html.escape(t)}</a></li>' for sid, t in toc)
    stamp_html = " &middot; ".join(
        html.escape(s.strip()) for s in re.split(r"\s+[·•]\s+|\s{3,}", stamp) if s.strip())
    out = PAGE.format(
        title=html.escape(h1), desc=html.escape(desc), h1=html.escape(h1),
        stamp=stamp_html, toc=toc_html, body=body, email=NEW_EMAIL,
        p_cur=' aria-current="page"' if kind == "privacy" else "",
        t_cur=' aria-current="page"' if kind == "terms" else "")
    path = os.path.join(ROOT, "docs", f"{kind}.html")
    io.open(path, "w", encoding="utf-8", newline="\n").write(out)
    print(f"{path}  ({len(toc)} sections, {len(out)} bytes)")


render("privacy", "legal/Padel Rivals - Privacy Policy.docx",
       "Privacy Policy",
       "How Padel Rivals collects, uses and protects your personal data, "
       "under Egyptian Personal Data Protection Law No. 151 of 2020.")

render("terms", "legal/Padel Rivals - Terms of Agreement.docx",
       "Terms of Agreement",
       "The terms governing your use of the Padel Rivals app, marketplace "
       "and tournaments.")
