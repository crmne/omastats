#!/usr/bin/env python3
"""Keep the shell's Color singleton reachable from every QML file.

Qt 6.12 added a `Color` singleton to QtQuick. It shadows qs.Commons' Color
even when qs.Commons is imported later, so a bare `Color.popups.text`
evaluates to undefined and text falls back to black. Reach the shell's
singleton through the `Commons` namespace instead.
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parent.parent
BARE_COLOR = re.compile(r"(?<![\w.])Color\s*(?:\.|$)", re.MULTILINE)


def code_lines(path):
    for number, line in enumerate(path.read_text().splitlines(), 1):
        code = line.split("//", 1)[0]
        if code.strip():
            yield number, code


class QmlImportTests(unittest.TestCase):
    def test_shell_color_is_namespaced(self):
        offenders = []
        for path in sorted(ROOT.glob("**/*.qml")):
            for number, code in code_lines(path):
                if BARE_COLOR.search(code):
                    offenders.append(f"{path.relative_to(ROOT)}:{number}: {code.strip()}")
        self.assertEqual(offenders, [], "use Commons.Color, not Color")

    def test_commons_namespace_is_imported(self):
        missing = []
        for path in sorted(ROOT.glob("**/*.qml")):
            text = path.read_text()
            if "Commons.Color" in text and "import qs.Commons as Commons" not in text:
                missing.append(str(path.relative_to(ROOT)))
        self.assertEqual(missing, [])


if __name__ == "__main__":
    unittest.main()
