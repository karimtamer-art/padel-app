"""Builds the Ranking Lab user guide as a real .docx.

No third-party packages: a .docx is a zip of WordprocessingML, so it is written
directly. Word, Google Docs and LibreOffice all open the result and it stays
fully editable.

    python tools/ranking_simulation/ui/make_guide.py

Edit CONTENT at the bottom and re-run. Inline markup: **bold**, `code`.
"""
import os
import re
import zipfile

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "Ranking Lab - how to use it.docx")

# ─────────────────────────────────────────────────────────────────────────────
# WordprocessingML plumbing
# ─────────────────────────────────────────────────────────────────────────────

NS = ('xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"')

ACCENT = "0E5C58"   # teal - headings
TRUTH = "A96C22"    # ochre - "ground truth" callouts
INK = "1B211F"
MUTED = "5A6663"
RULE = "D2DACF"
SUNK = "F2F5F1"


def esc(t):
    return (t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def runs(text):
    """Turns **bold** and `code` into runs."""
    out = []
    for part in re.split(r"(\*\*.+?\*\*|`[^`]+`)", text):
        if not part:
            continue
        if part.startswith("**") and part.endswith("**"):
            out.append('<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">%s</w:t></w:r>'
                       % esc(part[2:-2]))
        elif part.startswith("`") and part.endswith("`"):
            out.append('<w:r><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/>'
                       '<w:sz w:val="19"/><w:shd w:val="clear" w:fill="%s"/></w:rPr>'
                       '<w:t xml:space="preserve">%s</w:t></w:r>' % (SUNK, esc(part[1:-1])))
        else:
            out.append('<w:r><w:t xml:space="preserve">%s</w:t></w:r>' % esc(part))
    return "".join(out)


# WordprocessingML is order-sensitive: the children of <w:pPr> must appear in
# schema order or Word refuses the file as "unreadable content". The order used
# throughout here is pStyle -> keepNext -> pBdr -> spacing -> ind.
def _ppr(style="Body", keep_next=False, border=None, space_before=None,
         space_after=140, indent=0, hanging=0):
    out = ['<w:pStyle w:val="%s"/>' % style]
    if keep_next:
        out.append("<w:keepNext/>")
    if border:
        out.append('<w:pBdr><w:left w:val="single" w:sz="18" w:space="8" '
                   'w:color="%s"/></w:pBdr>' % border)
    sp = ""
    if space_before is not None:
        sp += ' w:before="%d"' % space_before
    sp += ' w:after="%d"' % space_after
    out.append("<w:spacing%s/>" % sp)
    if indent or hanging:
        out.append('<w:ind w:left="%d"%s/>'
                   % (indent, ' w:hanging="%d"' % hanging if hanging else ""))
    return "<w:pPr>%s</w:pPr>" % "".join(out)


def para(text="", style="Body", indent=0, space_after=140, keep_next=False):
    return ("<w:p>%s%s</w:p>"
            % (_ppr(style=style, keep_next=keep_next, indent=indent,
                    space_after=space_after), runs(text)))


def heading(text, level=1):
    return ("<w:p>%s%s</w:p>"
            % (_ppr(style="Heading%d" % level, keep_next=True,
                    space_before=[420, 340, 240][level - 1],
                    space_after=[160, 120, 100][level - 1]), runs(text)))


def bullet(text, indent=360):
    return ("<w:p>%s%s%s</w:p>"
            % (_ppr(space_after=80, indent=indent + 200, hanging=200), runs("•  "), runs(text)))


def step(n, text):
    return ("<w:p>" + _ppr(space_after=80, indent=560, hanging=360) + '%s%s</w:p>'
            % (runs("**%d.**  " % n), runs(text)))


def note(text, color=ACCENT):
    """A left-ruled callout."""
    return ("<w:p>%s%s</w:p>"
            % (_ppr(border=color, space_before=80, space_after=180, indent=200),
               runs(text)))


def table(headers, rows, widths=None):
    n = len(headers)
    widths = widths or [int(9360 / n)] * n
    grid = "".join('<w:gridCol w:w="%d"/>' % w for w in widths)

    def cell(text, w, head=False, first=False):
        shade = ('<w:shd w:val="clear" w:fill="%s"/>' % SUNK) if head else ""
        style = ("<w:b/>" if (head or first) else "")
        color = ('<w:color w:val="%s"/>' % MUTED) if head else ""
        sz = '<w:sz w:val="19"/>'
        return ('<w:tc><w:tcPr><w:tcW w:w="%d" w:type="dxa"/>%s'
                '<w:tcMar><w:top w:w="70" w:type="dxa"/><w:bottom w:w="70" w:type="dxa"/>'
                '<w:left w:w="110" w:type="dxa"/><w:right w:w="110" w:type="dxa"/></w:tcMar>'
                '</w:tcPr>'
                '<w:p><w:pPr><w:pStyle w:val="Body"/><w:spacing w:after="0"/>'
                '<w:rPr>%s%s%s</w:rPr></w:pPr>%s</w:p></w:tc>'
                % (w, shade, style, color, sz,
                   _styled_runs(text, bold=head or first, muted=head)))

    def row(cells, head=False):
        tr = "<w:trPr><w:tblHeader/></w:trPr>" if head else ""
        return "<w:tr>%s%s</w:tr>" % (
            tr, "".join(cell(c, widths[i], head, first=(not head and i == 0))
                        for i, c in enumerate(cells)))

    borders = ("<w:tblBorders>"
               + "".join('<w:%s w:val="single" w:sz="4" w:space="0" w:color="%s"/>' % (b, RULE)
                         for b in ("top", "left", "bottom", "right", "insideH", "insideV"))
               + "</w:tblBorders>")
    return ('<w:tbl><w:tblPr><w:tblW w:w="9360" w:type="dxa"/>%s<w:tblLayout w:type="fixed"/>'
            '</w:tblPr><w:tblGrid>%s</w:tblGrid>%s%s</w:tbl>'
            '<w:p><w:pPr><w:spacing w:after="200"/></w:pPr></w:p>'
            % (borders, grid, row(headers, head=True),
               "".join(row(r) for r in rows)))


def _styled_runs(text, bold=False, muted=False):
    base = runs(text)
    if not (bold or muted):
        return base
    extra = ("<w:b/>" if bold else "") + ('<w:color w:val="%s"/>' % MUTED if muted else "")
    # inject the extra properties into every run that has no rPr of its own
    return base.replace("<w:r><w:t", "<w:r><w:rPr>%s</w:rPr><w:t" % extra)


STYLES = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles %s>
  <w:docDefaults><w:rPrDefault><w:rPr>
    <w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:sz w:val="21"/>
    <w:color w:val="%s"/></w:rPr></w:rPrDefault></w:docDefaults>
  <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/>
    <w:pPr><w:spacing w:line="276" w:lineRule="auto"/></w:pPr></w:style>
  <w:style w:type="paragraph" w:styleId="Body"><w:name w:val="Body"/>
    <w:basedOn w:val="Normal"/></w:style>
  <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/>
    <w:basedOn w:val="Normal"/>
    <w:rPr><w:b/><w:sz w:val="52"/><w:color w:val="%s"/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/>
    <w:basedOn w:val="Normal"/><w:rPr><w:sz w:val="24"/><w:color w:val="%s"/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/>
    <w:basedOn w:val="Normal"/><w:rPr><w:b/><w:sz w:val="34"/><w:color w:val="%s"/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/>
    <w:basedOn w:val="Normal"/><w:rPr><w:b/><w:sz w:val="27"/><w:color w:val="%s"/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/>
    <w:basedOn w:val="Normal"/><w:rPr><w:b/><w:sz w:val="23"/><w:color w:val="%s"/></w:rPr></w:style>
</w:styles>""" % (NS, INK, ACCENT, MUTED, ACCENT, ACCENT, INK)

CONTENT_TYPES = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
  <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
</Types>"""

RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
</Relationships>"""

DOC_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>"""

CORE = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
  xmlns:dc="http://purl.org/dc/elements/1.1/">
  <dc:title>Ranking Lab - how to use it</dc:title>
  <dc:subject>Padel Rivals rating engine bench</dc:subject>
</cp:coreProperties>"""


def main():
    # imported late: guide_content imports the helpers from this module
    from guide_content import content
    path = build(content())
    print("wrote %s (%.0f KB)" % (path, os.path.getsize(path) / 1024))


def build(body):
    doc = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
           '<w:document %s><w:body>%s'
           '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
           '<w:pgMar w:top="1180" w:right="1180" w:bottom="1180" w:left="1180"/>'
           '</w:sectPr></w:body></w:document>' % (NS, body))
    path = os.path.abspath(OUT)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", CONTENT_TYPES)
        z.writestr("_rels/.rels", RELS)
        z.writestr("word/document.xml", doc)
        z.writestr("word/styles.xml", STYLES)
        z.writestr("word/_rels/document.xml.rels", DOC_RELS)
        z.writestr("docProps/core.xml", CORE)
    return path


if __name__ == "__main__":
    main()
