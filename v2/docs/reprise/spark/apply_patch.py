#!/usr/bin/env python3
"""Applies the === PATCH: path === blocks (<<<<<<< SEARCH / ======= / >>>>>>> REPLACE) of a Spark answer; dry run by default.
Each SEARCH text must occur exactly once in its file. Prints what it did; --apply writes the files."""
import re, sys
R = '/Users/david/Documents/Projets/Domenia-D120'
L = '/private/var/folders/xc/v6v5dly119l9sy64nyj2460m0000gn/T/opencode/spark'
t = sys.argv[1]
apply = '--apply' in sys.argv
text = open(f'{L}/{t}.out', encoding='utf-8').read()
patches = re.findall(r'^=== PATCH: (\S+) ===\n(.*?)^=== END PATCH ===', text, re.S | re.M)
ok = 0
for path, body in patches:
    blocks = re.findall(r'<<<<<<< SEARCH\n(.*?)\n=======\n(.*?)\n>>>>>>> REPLACE', body, re.S)
    try:
        src = open(f'{R}/{path}', encoding='utf-8').read()
    except FileNotFoundError:
        print(f'MISSING FILE {path}'); continue
    for old, new in blocks:
        n = src.count(old)
        if n != 1:
            print(f'{path}: SEARCH found {n} times: {old[:90]!r}'); continue
        src = src.replace(old, new, 1); ok += 1
    if apply:
        open(f'{R}/{path}', 'w', encoding='utf-8').write(src)
    print(f'{path}: {len(blocks)} block(s)')
print(f'{ok} block(s) applicable' + (' and applied' if apply else ' (dry run)'))
m = re.search(r'NOTES(.*)$', text, re.S)
if m: print('NOTES:', m.group(1).strip()[:2000])
