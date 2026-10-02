#!/usr/bin/env python3
"""Strict offline preflight for PowerShell sources when native PowerShell is unavailable.
This does NOT claim equivalence to the native parser. It rejects constructs that caused
RC1.10.x startup failures and checks lexical/delimiter integrity on every shipped PS1.
"""
from pathlib import Path
import re, sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'wad/tests'))
from powershell_lex import mask_ps
BAD_QUOTES={'\u2018','\u2019','\u201c','\u201d'}
PAIR={')':'(',']':'[','}':'{'}
OPEN=set(PAIR.values())

def validate(path:Path):
    text=path.read_text(encoding='utf-8-sig')
    masked,issues=mask_ps(text)
    errors=[]
    for issue,line in issues: errors.append(f'{path.relative_to(ROOT)}:{line}: {issue}')
    # Reject typographic quotes in executable code. mask_ps uses ASCII delimiters, so
    # inspect each original line after masking comments/ASCII literals approximately.
    for lineno,(orig,code) in enumerate(zip(text.splitlines(),masked.splitlines()),1):
        for idx,ch in enumerate(orig):
            if ch in BAD_QUOTES and idx < len(code) and code[idx] != ' ':
                errors.append(f'{path.relative_to(ROOT)}:{lineno}: typographic quote U+{ord(ch):04X} in executable PowerShell')
    stack=[]
    for pos,ch in enumerate(masked):
        if ch in OPEN: stack.append((ch,pos))
        elif ch in PAIR:
            if not stack or stack[-1][0] != PAIR[ch]:
                errors.append(f'{path.relative_to(ROOT)}:{text.count(chr(10),0,pos)+1}: unexpected delimiter {ch}')
                break
            stack.pop()
    for ch,pos in stack[-10:]: errors.append(f'{path.relative_to(ROOT)}:{text.count(chr(10),0,pos)+1}: unclosed delimiter {ch}')
    # In an expression, a command invocation cannot directly follow -or/-and.
    # Require parentheses/subexpression, e.g. -or (Test-X) or -or $(Test-X).
    for lineno,line in enumerate(masked.splitlines(),1):
        for m in re.finditer(r'\s-(?:or|and)\s+([A-Za-z][A-Za-z0-9_-]*)\b',line,re.I):
            errors.append(f'{path.relative_to(ROOT)}:{lineno}: bare command after boolean operator: {m.group(1)}; wrap command invocation in parentheses')
    return errors

def main():
    files=sorted(ROOT.rglob('*.ps1'))
    errors=[]
    for p in files: errors.extend(validate(p))
    if errors:
        print('\n'.join(errors)); print(f'FAIL: {len(errors)} issue(s) in {len(files)} PowerShell files'); return 1
    print(f'PASS: {len(files)} PowerShell files; lexical state, delimiters, typographic executable quotes and boolean-command hazards checked.')
    print('NOTE: native Windows PowerShell parser was not executed on this host.')
    return 0
if __name__=='__main__': raise SystemExit(main())
