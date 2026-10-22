#!/usr/bin/env python3
"""Extracts the === FILE: path === blocks of a Spark answer into <task>/files/<path>; prints the list and the NOTES."""
import os, re, sys
L = '/private/var/folders/xc/v6v5dly119l9sy64nyj2460m0000gn/T/opencode/spark'
t = sys.argv[1]
text = open(f'{L}/{t}.out', encoding='utf-8').read()
blocks = re.findall(r'^=== FILE: (\S+) ===\n(.*?)^=== END FILE ===', text, re.S | re.M)
for path, body in blocks:
    out = f'{L}/{t}/files/{path}'
    os.makedirs(os.path.dirname(out), exist_ok=True)
    open(out, 'w', encoding='utf-8').write(body)
    print(f'{path} ({body.count(chr(10))} lignes)')
m = re.search(r'NOTES(.*)$', text, re.S)
if m: print('NOTES:', m.group(1).strip()[:1500])
if not blocks: print('AUCUN FICHIER ; début de la réponse :', text[:800])
