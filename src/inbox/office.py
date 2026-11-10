import base64
import io
import json
import sys
import zipfile
from xml.etree import ElementTree as ET

data = sys.stdin.buffer.read(4 * 1024 * 1024 + 1)
if len(data) > 4 * 1024 * 1024:
    raise ValueError("large input")
archive = zipfile.ZipFile(io.BytesIO(data))
if len(archive.infolist()) > 2048:
    raise ValueError("too many members")
total = 0


def xml(name):
    global total
    info = archive.getinfo(name)
    total += info.file_size
    if info.file_size > 2 * 1024 * 1024 or total > 8 * 1024 * 1024:
        raise ValueError("large document")
    content = archive.read(info).decode("utf-8-sig")
    if "<!DOCTYPE" in content or "<!ENTITY" in content:
        raise ValueError("entities refused")
    return ET.fromstring(content)


def local(node):
    return node.tag.rsplit("}", 1)[-1]


def words(root):
    return " ".join(node.text or "" for node in root.iter() if local(node) in ("t", "p", "h"))


lines = []
names = archive.namelist()
if "word/document.xml" in names:
    for name in names:
        if name == "word/document.xml" or name.startswith(("word/header", "word/footer", "word/footnotes", "word/endnotes")) and name.endswith(".xml"):
            lines.append(words(xml(name)))
elif "xl/workbook.xml" in names:
    shared = []
    if "xl/sharedStrings.xml" in names:
        shared = [words(node) for node in xml("xl/sharedStrings.xml") if local(node) == "si"]
    lines.append("Workbook: " + " ".join(node.attrib.get("name", "") for node in xml("xl/workbook.xml").iter() if local(node) == "sheet"))
    for name in sorted(names):
        if not name.startswith("xl/worksheets/sheet") or not name.endswith(".xml"):
            continue
        lines.append(name)
        for row in xml(name).iter():
            if local(row) != "row":
                continue
            cells = []
            for cell in row:
                value = next((node.text or "" for node in cell if local(node) == "v"), "")
                if cell.attrib.get("t") == "s":
                    value = shared[int(value)]
                elif cell.attrib.get("t") == "inlineStr":
                    value = words(cell)
                cells.append(cell.attrib.get("r", "") + ": " + value)
            lines.append(" | ".join(cells))
elif "ppt/presentation.xml" in names:
    for name in sorted(names):
        if name.startswith(("ppt/slides/slide", "ppt/notesSlides/notesSlide")) and name.endswith(".xml"):
            lines.append(name + ": " + words(xml(name)))
elif "content.xml" in names:
    lines.append(" ".join(xml("content.xml").itertext()))
else:
    raise ValueError("unknown document")
text = "\n".join(lines)
if len(text) > 48000:
    text = text[:35980] + "\n[Middle omitted]\n" + text[-12000:]
images = []
image_bytes = 0
omitted = False
for info in archive.infolist():
    name = info.filename
    if not name.startswith(("word/media/", "xl/media/", "ppt/media/", "Pictures/")):
        continue
    if not name.lower().endswith((".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp")) or len(images) >= 8 or info.file_size + image_bytes > 2 * 1024 * 1024:
        omitted = True
        continue
    image_bytes += info.file_size
    images.append(base64.b64encode(archive.read(info)).decode("ascii"))
text += "\n[Office text, tables and supplied embedded images; layout and external links are not included."
if omitted:
    text += " Some embedded images omitted at the format or size limit."
text += "]"
print(json.dumps({"text": text, "images": images}))
