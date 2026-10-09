#!/usr/bin/env python3
"""Strict offline preflight for PowerShell sources when native PowerShell is unavailable.
This does NOT claim equivalence to the native parser. It rejects constructs that caused
RC1.10.x startup failures and checks lexical/delimiter integrity on every shipped PS1.
"""
from pathlib import Path
import re, sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'wad/tests'))
from powershell_lex import mask_ps, functions
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

# FI-05 / PF-06: every Dispatcher timer of the application comes from the protected factory of the engine. Only the
# factory itself and three dead functions left to their removal lot (L21) still construct a DispatcherTimer.
TIMER_FACTORY={'New-DomeniaTimer','Get-DomeniaPulse'}
TIMER_LEGACY={'Ensure-LinkProbeTimer','Queue-LiveGlobalSearch','Initialize-DomeniaSupportUi'}
TIMER_NEW=re.compile(r'New-Object\s+(?:System\.)?Windows\.Threading\.DispatcherTimer\b|\[(?:System\.)?Windows\.Threading\.DispatcherTimer\]::new\s*\(',re.I)
# PF-10: no command lookup in a timer tick nor in the handlers run by the engine heartbeat.
TIMER_HANDLERS={'Complete-UiTasks','Update-TaskUi','Invoke-DomeniaPulse','Invoke-DomeniaTimerTick','Update-DomeniaPulseSchedule',
    'Invoke-DomeniaQueuedTaskPromotion','Request-DomeniaDashboardRefresh','Invoke-DomeniaLiveTick','Test-DomeniaLiveTickNeeded',
    'Reset-DomeniaLiveIdentity','Get-DomeniaLiveIdentitySignal','Get-DomeniaLiveIdentityKey','Start-DomeniaLiveBackgroundWork',
    'Test-DomeniaLiveBackgroundAllowed','Invoke-DomeniaReconcileTick','Invoke-DomeniaObjectChanges','Test-DomeniaContinuityTickNeeded',
    'Start-DomeniaStorageWork','Test-DomeniaStorageWorkPending','Invoke-DomeniaRelationsTick','Invoke-DomeniaParkRunTick',
    'Complete-DomeniaAccountValidation','Update-DomeniaExperienceActivity','Get-DomeniaFeatureFlag','Flush-DomeniaAppLog',
    'Test-DomeniaBackgroundWorkAllowed','Update-DomeniaIdlePolicy'}

def enclosing(spans,pos):
    best=None
    for name,ranges in spans.items():
        for a,b in ranges:
            if a<=pos<b and (best is None or a>best[1]): best=(name,a)
    return best[0] if best else ''

def check_timers():
    errors=[]
    files=[ROOT/'wad/Domenia-Core.ps1']+sorted((ROOT/'wad/modules').glob('*.ps1'))
    for path in files:
        text=path.read_text(encoding='utf-8-sig')
        masked,_=mask_ps(text)
        spans=functions(text)
        rel=path.relative_to(ROOT)
        for m in TIMER_NEW.finditer(masked):
            owner=enclosing(spans,m.start())
            if owner in TIMER_FACTORY or owner in TIMER_LEGACY: continue
            errors.append(f'{rel}:{text.count(chr(10),0,m.start())+1}: DispatcherTimer created outside New-DomeniaTimer ({owner or "script level"})')
        for m in re.finditer(r'New-DomeniaTimer\b',masked):
            line_end=masked.find('\n',m.end())
            if line_end<0: line_end=len(masked)
            # The tick block opens on the line of the call (style of every call site).
            tick=masked.find('-Tick',m.end(),line_end)
            if tick<0: continue
            brace=masked.find('{',tick,line_end)
            if brace<0: continue
            depth=0;end=brace
            for k in range(brace,len(masked)):
                if masked[k]=='{': depth+=1
                elif masked[k]=='}':
                    depth-=1
                    if depth==0: end=k;break
            if re.search(r'Get-Command\b',masked[brace:end],re.I):
                errors.append(f'{rel}:{text.count(chr(10),0,brace)+1}: Get-Command in a timer tick (PF-10)')
        for name in TIMER_HANDLERS:
            for a,b in spans.get(name,[]):
                hit=re.search(r'Get-Command\b',masked[a:b],re.I)
                if hit: errors.append(f'{rel}:{text.count(chr(10),0,a+hit.start())+1}: Get-Command in timer handler {name} (PF-10)')
    return errors

def main():
    files=sorted(ROOT.rglob('*.ps1'))
    errors=[]
    for p in files: errors.extend(validate(p))
    errors.extend(check_timers())
    if errors:
        print('\n'.join(errors)); print(f'FAIL: {len(errors)} issue(s) in {len(files)} PowerShell files'); return 1
    print(f'PASS: {len(files)} PowerShell files; lexical state, delimiters, typographic executable quotes and boolean-command hazards checked.')
    print('PASS: Dispatcher timers only from New-DomeniaTimer (FI-05); no Get-Command in timer ticks or heartbeat handlers (PF-10).')
    print('NOTE: native Windows PowerShell parser was not executed on this host.')
    return 0
if __name__=='__main__': raise SystemExit(main())
