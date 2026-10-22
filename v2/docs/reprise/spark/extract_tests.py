#!/usr/bin/env python3
"""Prints the head of a C# test file (up to its first [Test]) and the named test methods, for a Spark prompt."""
import re, sys
path, names = sys.argv[1], sys.argv[2:]
lines = open(path, encoding='utf-8').read().split('\n')
first = next((i for i, l in enumerate(lines) if l.strip() == '[Test]'), len(lines))
out = lines[:first]
for name in names:
    start = next(i for i, l in enumerate(lines) if re.search(r'\b' + re.escape(name) + r'\(', l) and ('Task ' in l or 'void ' in l))
    if start > 0 and lines[start - 1].strip() == '[Test]':
        start -= 1
    end = next(i for i in range(start + 2, len(lines)) if lines[i] == '    }')
    out += ['', '    // ...'] + lines[start:end + 1]
# private helpers of the class (static methods after the tests) are kept: they are short and often used.
helpers = [i for i, l in enumerate(lines) if re.match(r'    (private|internal) static ', l) and i > first]
for h in helpers:
    end = h if lines[h].rstrip().endswith(';') else next((i for i in range(h + 1, len(lines)) if lines[i] == '    }'), h)
    out += [''] + lines[h:end + 1]
out += ['}']
print('\n'.join(out))
