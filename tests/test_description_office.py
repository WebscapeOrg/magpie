import io
import json
from pathlib import Path
import subprocess
import unittest
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / 'src/inbox/office.py'

class OfficeContext(unittest.TestCase):
    def run_doc(self, entries):
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for name, content in entries.items(): archive.writestr(name, content)
        return subprocess.run(['/usr/bin/python3', '-I', str(SCRIPT)], input=data.getvalue(), capture_output=True, timeout=10)

    def test_word_text_images_and_paths_are_data(self):
        result = self.run_doc({'word/document.xml': '<document><p><t>Receipt R643</t></p></document>', 'word/media/image.png': b'\x89PNGfixture', '../../never-created': 'untouched'})
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertIn('Receipt R643', value['text'])
        self.assertEqual(len(value['images']), 1)
        self.assertFalse(Path('../../never-created').exists())

    def test_excel_shared_and_inline_cells(self):
        result = self.run_doc({'xl/workbook.xml': '<workbook><sheet name="Invoices"/></workbook>', 'xl/sharedStrings.xml': '<sst><si><t>Paid</t></si></sst>', 'xl/worksheets/sheet1.xml': '<worksheet><row><c r="A1" t="s"><v>0</v></c><c r="B1"><v>643</v></c><c r="C1" t="inlineStr"><is><t>ZEBRA-82</t></is></c></row></worksheet>'})
        self.assertEqual(result.returncode, 0, result.stderr)
        text = json.loads(result.stdout)['text']
        for expected in ['Invoices', 'Paid', '643', 'ZEBRA-82']: self.assertIn(expected, text)

    def test_entities_and_zip_bombs_are_refused(self):
        for xml in ['<!DOCTYPE doc [<!ENTITY ext SYSTEM "file:///etc/passwd">]><doc>&ext;</doc>', '<doc>' + 'x' * (2 * 1024 * 1024) + '</doc>']:
            result = self.run_doc({'word/document.xml': xml})
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(b'root:', result.stdout)
            self.assertEqual(result.stdout, b'')

if __name__ == '__main__': unittest.main()
