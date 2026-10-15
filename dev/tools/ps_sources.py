"""Shared offline views of the PowerShell sources for the clean-up audits (P-CD-02, P-CD-09).

Approximate lexing only (wad/tests/powershell_lex.py), never a replacement for the native parser. Three views of a
script are used:
  - the masked code (comments and strings blanked): structure, braces and keywords;
  - the commented-out view (comments blanked, strings kept): references written by name inside strings, and the body
    of every here-string lexed again as PowerShell (worker code), so that its own comments are blanked too;
  - the here-string bodies, lexed again as PowerShell to find the code that workers run.
Every view keeps the length and the newlines of the source, so an offset means the same thing in each of them.
"""
from bisect import bisect_right
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'wad/tests'))
from powershell_lex import mask_ps, segments  # noqa: E402

COMMENTS = ('line', 'block')
HERE_STRINGS = ('h_single', 'h_double')
FUNCTION_RX = re.compile(r'(?im)^[ \t]*(?:function|filter)[ \t]+([A-Za-z_][\w-]*)')


def read_ps(path):
    """Text of a script with LF line endings (the repository convention); the BOM is dropped."""
    return Path(path).read_text(encoding='utf-8-sig').replace('\r\n', '\n')


class LineIndex:
    """Offset to 1-based line number."""

    def __init__(self, text):
        self.starts = [0] + [m.end() for m in re.finditer('\n', text)]

    def line(self, offset):
        return bisect_right(self.starts, offset)


def blank(chars, start, end):
    for i in range(start, end):
        if chars[i] != '\n':
            chars[i] = ' '


def here_string_body(text, start, end):
    """(body_start, body_end) of the here-string span [start, end): the lines between the opener and the closing line.
    An unclosed here-string runs to the end of the text."""
    newline = text.find('\n', start, end)
    if newline < 0:
        return end, end
    body_end = end - 2 if text[max(start, end - 2):end] in ("'@", '"@') else end
    return newline + 1, max(newline + 1, body_end)


def strip_comments(text):
    """Comments blanked, strings kept verbatim; the body of each here-string is lexed again as PowerShell."""
    chars = list(text)
    for kind, start, end in segments(text):
        if kind in COMMENTS:
            blank(chars, start, end)
        elif kind in HERE_STRINGS:
            body_start, body_end = here_string_body(text, start, end)
            if body_end > body_start:
                chars[body_start:body_end] = strip_comments(text[body_start:body_end])
    return ''.join(chars)


def matching_brace(masked, open_index):
    """Offset just after the brace that closes masked[open_index] ('{'), or len(masked) when unbalanced."""
    depth = 0
    for i in range(open_index, len(masked)):
        c = masked[i]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i + 1
    return len(masked)


def brace_depths(masked):
    """Brace depth before each offset of the masked code."""
    depths = [0] * (len(masked) + 1)
    depth = 0
    for i, c in enumerate(masked):
        depths[i] = depth
        if c == '{':
            depth += 1
        elif c == '}':
            depth = max(0, depth - 1)
    depths[len(masked)] = depth
    return depths


def top_level_functions(text, masked=None):
    """[(name, start, end)] of the functions defined at brace depth 0, in source order. start is the offset of the
    keyword, end the offset after the closing brace. Definitions inside strings and here-strings (worker code) are
    masked, so they are never top-level; neither is a function nested in another block."""
    if masked is None:
        masked = mask_ps(text)[0]
    depths = brace_depths(masked)
    found = []
    for m in FUNCTION_RX.finditer(masked):
        keyword = m.start() + len(m.group(0)) - len(m.group(0).lstrip())
        if depths[keyword] != 0:
            continue
        cur = m.end()
        while cur < len(masked) and masked[cur] in ' \t\r\n':
            cur += 1
        if cur < len(masked) and masked[cur] == '(':
            level = 0
            while cur < len(masked):
                if masked[cur] == '(':
                    level += 1
                elif masked[cur] == ')':
                    level -= 1
                    if level == 0:
                        cur += 1
                        break
                cur += 1
            while cur < len(masked) and masked[cur] in ' \t\r\n':
                cur += 1
        if cur >= len(masked) or masked[cur] != '{':
            continue
        found.append((m.group(1), keyword, matching_brace(masked, cur)))
    return found


class Enclosing:
    """Finds the top-level function that contains an offset (None for script code outside every function)."""

    def __init__(self, spans):
        self.spans = sorted(spans, key=lambda s: s[1])
        self.starts = [s[1] for s in self.spans]

    def at(self, offset):
        i = bisect_right(self.starts, offset) - 1
        if i >= 0:
            name, start, end = self.spans[i]
            if start <= offset < end:
                return name
        return None
