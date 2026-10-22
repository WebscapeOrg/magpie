#!/usr/bin/env python3
"""The source tripwire must reject unsafe text bindings in every UI module."""
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("text_guard", Path(__file__).with_name("test_qml_text_format.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class TextGuardTests(unittest.TestCase):
    def check_source(self, source, directory="components"):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / directory / "Example.qml"
            path.parent.mkdir(parents=True)
            path.write_text(source)
            with patch.object(guard, "ROOT", root), redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                return guard.main()

    def test_only_a_direct_plain_text_binding_passes(self):
        for binding in ("", "textFormat: Text.RichText", "textFormat: Text.AutoText",
                        "// textFormat: Text.PlainText", 'property string note: "textFormat: Text.PlainText"',
                        "Item { property int textFormat: Text.PlainText }"):
            with self.subTest(binding=binding):
                self.assertEqual(self.check_source("Text {\n text: root.subject\n" + binding + "\n}"), 1)
        for source in ("Text {\ntext: root.subject\ntextFormat: Text.PlainText\n}",
                       "Text { text: root.subject; textFormat: Text.PlainText }",
                       "Label { textFormat: Text.PlainText; text: root.subject }",
                       "Text { text: root.subject; textFormat: Text.PlainText\nItem {} }"):
            with self.subTest(source=source):
                self.assertEqual(self.check_source(source), 0)

    def test_all_production_modules_are_checked_and_test_fixtures_are_excluded(self):
        source = "Text {\n text: root.subject\n}"
        for directory in ("agent", "calendar", "controls", "new-module/nested"):
            with self.subTest(directory=directory):
                self.assertEqual(self.check_source(source, directory), 1)
        self.assertEqual(self.check_source(source, "tests/qml"), 0)


if __name__ == "__main__":
    unittest.main()
