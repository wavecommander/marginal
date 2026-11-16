#!/usr/bin/env python3 -I
"""Builds the F6 Office fixtures in Tests/Fixtures (run on a Mac; uses /usr/bin/textutil).

    /usr/bin/python3 -I Tests/Fixtures/f6-make-fixtures.py Tests/Fixtures

- f6-sample.docx, .doc, .rtf, .webarchive: one source HTML (headings, a list, a table, a picture,
  a link) converted by textutil. Sentinel words (F6WORD-…) let tests search the output.
- f6-slides.pptx: a 5-slide 16:9 deck, built by hand (title + body placeholders, one slide with
  a picture, one with only a body).
- f6-deck-40.pptx: the same builder with 40 slides, for the main-thread measurement.

The text fixtures (.txt, .md, .html) are built in the test code instead.
"""
import base64, os, struct, subprocess, sys, tempfile, zipfile, zlib

out = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__)))
os.makedirs(out, exist_ok=True)


def png(width, height, rgb):
    """A solid-colour PNG."""
    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


# ---- Word family ----------------------------------------------------------------------------

def word_source(directory):
    picture = os.path.join(directory, "f6-picture.png")
    with open(picture, "wb") as f:
        f.write(png(240, 120, (40, 120, 200)))
    filler = ("The quick brown fox jumps over the lazy dog. Sphinx of black quartz, judge my vow. "
              "Pack my box with five dozen liquor jugs. ") * 3
    parts = ["<h1>F6 Sample Document</h1>",
             "<p>F6WORD-intro opens the document with <b>bold</b>, <i>italic</i> and "
             "<a href=\"https://example.com/f6-word\">an external link</a>.</p>"]
    for chapter in range(1, 4):
        parts.append(f"<h2>Section {chapter}: Harbour Notes</h2>")
        for paragraph in range(1, 9):
            parts.append(f"<p>F6WORD-{chapter}-{paragraph}. {filler}</p>")
        if chapter == 2:
            parts.append("<ul><li>F6WORD-list-one</li><li>F6WORD-list-two</li></ul>")
            parts.append("<table border=\"1\"><tr><th>Tide</th><th>Height</th></tr>"
                         "<tr><td>F6WORD-high</td><td>4.2 m</td></tr><tr><td>F6WORD-low</td><td>0.6 m</td></tr></table>")
            parts.append(f"<p><img src=\"{os.path.basename(picture)}\" width=\"240\" height=\"120\"></p>")
    parts.append("<p>F6WORD-closing ends the document.</p>")
    html = ("<!doctype html><html><head><meta charset=\"utf-8\"><title>F6 Sample Title</title></head><body>"
            + "\n".join(parts) + "</body></html>")
    source = os.path.join(directory, "f6-sample.html")
    with open(source, "w") as f:
        f.write(html)
    return source


STYLES = (X_DECL := '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n') + (
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
    '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>'
    '<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>'
    '<w:pPr><w:keepNext/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="40"/></w:rPr></w:style>'
    '<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/>'
    '<w:pPr><w:keepNext/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>'
    '</w:styles>')


def finish_docx(path):
    """textutil writes no styles, no page size and no pictures. Give the document Word's heading
    styles, an A4 page with 1 in margins and the picture, as a real Word file would have."""
    with zipfile.ZipFile(path) as z:
        parts = {name: z.read(name) for name in z.namelist()}
    document = parts["word/document.xml"].decode()

    def style(text, style_id):
        nonlocal document
        at = document.index(text)
        start = document.rindex("<w:p>", 0, at)
        document = document[:start] + f'<w:p><w:pPr><w:pStyle w:val="{style_id}"/>' + document[start + len("<w:p><w:pPr>"):]

    style(">F6 Sample Document<", "Heading1")
    for chapter in range(1, 4):
        style(f">Section {chapter}: Harbour Notes<", "Heading2")
    drawing = ('<w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">'
               '<wp:extent cx="2286000" cy="1143000"/><wp:docPr id="1" name="Picture 1"/>'
               '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
               '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
               '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">'
               '<pic:nvPicPr><pic:cNvPr id="1" name="f6-picture.png"/><pic:cNvPicPr/></pic:nvPicPr>'
               '<pic:blipFill><a:blip r:embed="rIdF6Picture"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
               '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="2286000" cy="1143000"/></a:xfrm>'
               '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic>'
               '</wp:inline></w:drawing></w:r></w:p>')
    # textutil flattens tables to paragraphs; add a real Word table (with a grid and borders).
    def cell(text, bold=False):
        run = f'<w:rPr><w:b/></w:rPr>' if bold else ''
        return f'<w:tc><w:tcPr><w:tcW w:w="2400" w:type="dxa"/></w:tcPr><w:p><w:r>{run}<w:t>{text}</w:t></w:r></w:p></w:tc>'
    border = ''.join(f'<w:{side} w:val="single" w:sz="4" w:space="0" w:color="000000"/>'
                     for side in ("top", "left", "bottom", "right", "insideH", "insideV"))
    table = ('<w:tbl><w:tblPr><w:tblW w:w="4800" w:type="dxa"/><w:tblBorders>' + border + '</w:tblBorders></w:tblPr>'
             '<w:tblGrid><w:gridCol w:w="2400"/><w:gridCol w:w="2400"/></w:tblGrid>'
             '<w:tr>' + cell("Harbour", True) + cell("Depth", True) + '</w:tr>'
             '<w:tr>' + cell("F6TABLE-north") + cell("7 m") + '</w:tr>'
             '<w:tr>' + cell("F6TABLE-south") + cell("3 m") + '</w:tr></w:tbl>')
    closing = document.index(">F6WORD-closing")
    document = document[:document.rindex("<w:p>", 0, closing)] + drawing + table + document[document.rindex("<w:p>", 0, closing):]
    document = document.replace("<w:sectPr></w:sectPr>",
                                '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
                                '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>')
    parts["word/document.xml"] = document.encode()
    parts["word/styles.xml"] = STYLES.encode()
    parts["word/media/image1.png"] = png(240, 120, (40, 120, 200))
    rels_xml = parts["word/_rels/document.xml.rels"].decode().replace(
        "</Relationships>",
        f'<Relationship Id="rIdF6Styles" Type="{REL}/styles" Target="styles.xml"/>'
        f'<Relationship Id="rIdF6Picture" Type="{REL}/image" Target="media/image1.png"/></Relationships>')
    parts["word/_rels/document.xml.rels"] = rels_xml.encode()
    types = parts["[Content_Types].xml"].decode().replace(
        "</Types>",
        '<Default Extension="png" ContentType="image/png"/>'
        '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
        "</Types>")
    parts["[Content_Types].xml"] = types.encode()
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name in ["[Content_Types].xml"] + sorted(n for n in parts if n != "[Content_Types].xml"):
            z.writestr(zipfile.ZipInfo(name, date_time=(2026, 11, 15, 0, 0, 0)), parts[name], compress_type=zipfile.ZIP_DEFLATED)


REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

with tempfile.TemporaryDirectory() as scratch:
    source = word_source(scratch)
    for fmt in ("docx", "doc", "rtf", "webarchive"):
        target = os.path.join(out, f"f6-sample.{fmt}")
        subprocess.run(["/usr/bin/textutil", "-convert", fmt, "-title", "F6 Sample Title", "-output", target, source],
                       check=True, cwd=scratch)
    finish_docx(os.path.join(out, "f6-sample.docx"))

# ---- PowerPoint -----------------------------------------------------------------------------

NS = ('xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
      'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"')
X = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
TREE_HEAD = ('<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
             '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>')


def rels(items):
    body = "".join(f'<Relationship Id="{i}" Type="{REL}/{t}" Target="{tg}"/>' for i, t, tg in items)
    return X + f'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">{body}</Relationships>'


def sp(idn, name, phtype, x, y, cx, cy, lines, size):
    paragraphs = "".join(f'<a:p><a:r><a:rPr lang="en-US" sz="{size}"/><a:t>{line}</a:t></a:r></a:p>' for line in lines)
    idx = "" if phtype == "title" else ' idx="1"'
    return (f'<p:sp><p:nvSpPr><p:cNvPr id="{idn}" name="{name}"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>'
            f'<p:nvPr><p:ph type="{phtype}"{idx}/></p:nvPr></p:nvSpPr>'
            f'<p:spPr><a:xfrm><a:off x="{x}" y="{y}"/><a:ext cx="{cx}" cy="{cy}"/></a:xfrm>'
            f'<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>'
            f'<p:txBody><a:bodyPr/><a:lstStyle/>{paragraphs}</p:txBody></p:sp>')


def picture(idn, rid, x, y, cx, cy):
    return (f'<p:pic><p:nvPicPr><p:cNvPr id="{idn}" name="Picture {idn}"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>'
            f'<p:blipFill><a:blip r:embed="{rid}"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>'
            f'<p:spPr><a:xfrm><a:off x="{x}" y="{y}"/><a:ext cx="{cx}" cy="{cy}"/></a:xfrm>'
            f'<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>')


def deck_slide(n, count):
    """Slide n of count. Slide 3 has a picture; the last has no title (its body's first line is the entry)."""
    shapes = ""
    if n != count:
        shapes += sp(2, "Title", "title", 838200, 365125, 10515600, 1325563, [f"Slide {n} Title F6TITLE-{n}"], 4400)
    body = [f"Body of slide {n} F6BODY-{n}", f"Second point of slide {n}"]
    if n == count:
        body = [f"Closing words F6CLOSING-{n}", "Thank you"]
    width = 5000000 if n == 3 else 10515600
    shapes += sp(3, "Body", "body", 838200, 1825625, width, 4351338, body, 2800)
    if n == 3:
        shapes += picture(4, "rId2", 6400000, 1825625, 4800000, 2400000)
    return (X + f'<p:sld {NS}><p:cSld><p:spTree>{TREE_HEAD}{shapes}</p:spTree></p:cSld>'
            '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>')


def build_pptx(path, count):
    layout = (X + f'<p:sldLayout {NS} type="obj" preserve="1"><p:cSld name="Title and Content"><p:spTree>{TREE_HEAD}'
              + sp(2, "Title", "title", 838200, 365125, 10515600, 1325563, ["Title"], 4400)
              + sp(3, "Body", "body", 838200, 1825625, 10515600, 4351338, ["Body"], 2800)
              + '</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>')
    master = (X + f'<p:sldMaster {NS}><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg><p:spTree>{TREE_HEAD}'
              + sp(2, "Title", "title", 838200, 365125, 10515600, 1325563, ["Title"], 4400)
              + sp(3, "Body", "body", 838200, 1825625, 10515600, 4351338, ["Body"], 2800)
              + '</p:spTree></p:cSld>'
              '<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" '
              'accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>'
              '<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>'
              '<p:txStyles><p:titleStyle><a:lvl1pPr><a:defRPr sz="4400"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>'
              '<a:latin typeface="+mj-lt"/></a:defRPr></a:lvl1pPr></p:titleStyle>'
              '<p:bodyStyle><a:lvl1pPr><a:defRPr sz="2800"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>'
              '<a:latin typeface="+mn-lt"/></a:defRPr></a:lvl1pPr></p:bodyStyle><p:otherStyle/></p:txStyles></p:sldMaster>')

    def clr(name, val):
        return f'<a:{name}><a:srgbClr val="{val}"/></a:{name}>'

    fill3 = '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>' * 3
    ln3 = '<a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>' * 3
    eff3 = '<a:effectStyle><a:effectLst/></a:effectStyle>' * 3
    theme = (X + '<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="F6"><a:themeElements>'
             '<a:clrScheme name="F6">'
             '<a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>'
             + clr("dk2", "44546A") + clr("lt2", "E7E6E6") + clr("accent1", "4472C4") + clr("accent2", "ED7D31")
             + clr("accent3", "A5A5A5") + clr("accent4", "FFC000") + clr("accent5", "5B9BD5") + clr("accent6", "70AD47")
             + clr("hlink", "0563C1") + clr("folHlink", "954F72") + '</a:clrScheme>'
             '<a:fontScheme name="F6"><a:majorFont><a:latin typeface="Helvetica"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>'
             '<a:minorFont><a:latin typeface="Helvetica"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>'
             f'<a:fmtScheme name="F6"><a:fillStyleLst>{fill3}</a:fillStyleLst><a:lnStyleLst>{ln3}</a:lnStyleLst>'
             f'<a:effectStyleLst>{eff3}</a:effectStyleLst><a:bgFillStyleLst>{fill3}</a:bgFillStyleLst></a:fmtScheme>'
             '</a:themeElements></a:theme>')
    sld_ids = "".join(f'<p:sldId id="{255 + i}" r:id="rId{i + 1}"/>' for i in range(1, count + 1))
    presentation = (X + f'<p:presentation {NS}><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>'
                    f'<p:sldIdLst>{sld_ids}</p:sldIdLst><p:sldSz cx="12192000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>')
    overrides = ('<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>'
                 '<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>'
                 '<Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>'
                 '<Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>'
                 '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
                 + "".join(f'<Override PartName="/ppt/slides/slide{i}.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>'
                           for i in range(1, count + 1)))
    content_types = (X + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
                     '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
                     '<Default Extension="xml" ContentType="application/xml"/>'
                     '<Default Extension="png" ContentType="image/png"/>' + overrides + '</Types>')
    core = (X + '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
            'xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>F6 Deck Title</dc:title></cp:coreProperties>')
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        info = zipfile.ZipInfo("[Content_Types].xml", date_time=(2026, 11, 15, 0, 0, 0))
        z.writestr(info, content_types)
        def put(name, data):
            z.writestr(zipfile.ZipInfo(name, date_time=(2026, 11, 15, 0, 0, 0)), data, compress_type=zipfile.ZIP_DEFLATED)
        put("_rels/.rels", rels([("rId1", "officeDocument", "ppt/presentation.xml"),
                                 ("rId2", "metadata/core-properties", "docProps/core.xml")]))
        put("docProps/core.xml", core)
        put("ppt/presentation.xml", presentation)
        put("ppt/_rels/presentation.xml.rels",
            rels([("rId1", "slideMaster", "slideMasters/slideMaster1.xml")]
                 + [(f"rId{i + 1}", "slide", f"slides/slide{i}.xml") for i in range(1, count + 1)]
                 + [(f"rId{count + 2}", "theme", "theme/theme1.xml")]))
        put("ppt/slideMasters/slideMaster1.xml", master)
        put("ppt/slideMasters/_rels/slideMaster1.xml.rels",
            rels([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("rId2", "theme", "../theme/theme1.xml")]))
        put("ppt/slideLayouts/slideLayout1.xml", layout)
        put("ppt/slideLayouts/_rels/slideLayout1.xml.rels", rels([("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")]))
        put("ppt/theme/theme1.xml", theme)
        put("ppt/media/image1.png", png(320, 160, (200, 80, 40)))
        for i in range(1, count + 1):
            put(f"ppt/slides/slide{i}.xml", deck_slide(i, count))
            items = [("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml")]
            if i == 3:
                items.append(("rId2", "image", "../media/image1.png"))
            put(f"ppt/slides/_rels/slide{i}.xml.rels", rels(items))


build_pptx(os.path.join(out, "f6-slides.pptx"), 5)
build_pptx(os.path.join(out, "f6-deck-40.pptx"), 40)
print(sorted(name for name in os.listdir(out) if name.startswith("f6-")))
