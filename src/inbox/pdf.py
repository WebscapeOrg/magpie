import base64
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    data = sys.stdin.buffer.read(2 * 1024 * 1024 + 1)
    if len(data) > 2 * 1024 * 1024 or not data.startswith(b'%PDF-'):
        raise ValueError('invalid PDF')
    source = root / 'source.pdf'
    source.write_bytes(data)
    info = subprocess.run(['/usr/bin/pdfinfo', str(source)], capture_output=True, check=True, timeout=3).stdout.decode('utf-8', 'replace')
    if re.search(r'^Encrypted:\s+yes', info, re.M):
        raise ValueError('encrypted PDF')
    pages = int(re.search(r'^Pages:\s+(\d+)', info, re.M)[1])
    text_file = root / 'text.txt'
    result = subprocess.run(['/usr/bin/pdftotext', '-f', '1', '-l', str(min(pages,100)), '-layout', str(source), str(text_file)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=4)
    text = text_file.read_bytes()[:196000].decode('utf-8', 'replace') if text_file.exists() else ''
    if len(text) > 48000:
        text = text[:35980] + '\n[Middle omitted]\n' + text[-12000:]
    selected = sorted(set(page for page in [1,2,pages-1,pages] if 1 <= page <= pages))
    images = []
    supplied = []
    for page in selected:
        output = root / ('page-' + str(page))
        rendered = subprocess.run(['/usr/bin/pdftoppm', '-f', str(page), '-l', str(page), '-singlefile', '-scale-to', '1568', '-jpeg', '-jpegopt', 'quality=75', str(source), str(output)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=4)
        picture = output.with_suffix('.jpg')
        if rendered.returncode == 0 and picture.exists() and picture.stat().st_size <= 1024 * 1024:
            supplied.append(page)
            images.append(base64.b64encode(picture.read_bytes()).decode('ascii'))
    text += '\n[PDF has ' + str(pages) + ' pages; text from at most the first 100 pages; pictures from pages ' + (', '.join(map(str,supplied)) or 'none') + '. Other page pictures, interactive content and external links are omitted.]'
    if result.returncode != 0:
        text += '\n[PDF text extraction was incomplete.]'
    print(json.dumps({'text':text,'images':images}))
