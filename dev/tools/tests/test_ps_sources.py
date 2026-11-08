"""Offline checks of the shared PowerShell views used by the clean-up audits (tools/ps_sources.py and the segments of
wad/tests/powershell_lex.py). Fictitious scripts only; nothing is executed."""
from pathlib import Path
import sys
import unittest

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
import ps_sources  # noqa: E402
from powershell_lex import mask_ps, segments  # noqa: E402


class SegmentsTests(unittest.TestCase):
    def test_kinds_and_spans_cover_delimiters(self):
        text = "$a = 'x''y' # note\n<# bloc\n suite #>\n$b = \"q`\"r\"\n$c = @'\nbody\n'@\n"
        found = [(kind, text[a:b]) for kind, a, b in segments(text)]
        self.assertEqual(found, [
            ('single', "'x''y'"), ('line', '# note'), ('block', '<# bloc\n suite #>'),
            ('double', '"q`"r"'), ('h_single', "@'\nbody\n'@")])

    def test_masking_is_unchanged_by_segments(self):
        text = "function F { 'a' } # c\n$x = @\"\nY\n\"@\n"
        masked, issues = mask_ps(text)
        self.assertEqual(len(masked), len(text))
        self.assertEqual(issues, [])
        self.assertNotIn("'a'", masked)
        self.assertNotIn('# c', masked)

    def test_unclosed_string_runs_to_the_end(self):
        text = "$a = 'open\n"
        self.assertEqual(segments(text), [('single', 5, len(text))])


class ViewsTests(unittest.TestCase):
    def test_strip_comments_keeps_strings_and_lexes_here_strings(self):
        text = "Call-A # Call-B\n$w = @'\nCall-C # Call-D\n'@\n$s = '# Call-E'\n"
        view = ps_sources.strip_comments(text)
        self.assertEqual(len(view), len(text))
        for kept in ('Call-A', 'Call-C', "'# Call-E'"):
            self.assertIn(kept, view)
        for removed in ('Call-B', 'Call-D'):
            self.assertNotIn(removed, view)

    def test_here_string_body_bounds(self):
        text = "x\n@'\nline1\nline2\n'@\n"
        start = text.index("@'")
        end = text.index("'@") + 2
        a, b = ps_sources.here_string_body(text, start, end)
        self.assertEqual(text[a:b], 'line1\nline2\n')

    def test_top_level_functions_skip_nested_and_worker_definitions(self):
        text = (
            "function Get-One { function Get-Nested { } }\n"
            "function Get-Two($a) {\n  if ($a) { '}' }\n}\n"
            "$code = @'\nfunction Get-Worker { }\n'@\n"
            "if ($true) {\nfunction Get-Conditional { }\n}\n"
            "filter Get-Three { $_ }\n")
        spans = ps_sources.top_level_functions(text)
        self.assertEqual([s[0] for s in spans], ['Get-One', 'Get-Two', 'Get-Three'])
        two = [s for s in spans if s[0] == 'Get-Two'][0]
        self.assertTrue(text[two[1]:two[2]].endswith('}'))
        self.assertIn("'}'", text[two[1]:two[2]])

    def test_enclosing_and_line_index(self):
        text = "function A {\n  x\n}\ny\n"
        enclosing = ps_sources.Enclosing(ps_sources.top_level_functions(text))
        self.assertEqual(enclosing.at(text.index('x')), 'A')
        self.assertIsNone(enclosing.at(text.index('y')))
        index = ps_sources.LineIndex(text)
        self.assertEqual(index.line(0), 1)
        self.assertEqual(index.line(text.index('y')), 4)


if __name__ == '__main__':
    unittest.main()
