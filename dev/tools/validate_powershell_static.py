#!/usr/bin/env python3
"""Strict offline preflight for PowerShell sources when native PowerShell is unavailable.
This does NOT claim equivalence to the native parser. It rejects constructs that caused
RC1.10.x startup failures and checks lexical/delimiter integrity on every shipped PS1.
"""
from pathlib import Path
import json, re, sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'wad/tests'))
from powershell_lex import mask_ps, functions
# PowerShell treats these characters as quote delimiters: a typographic single quote closes a single-quoted string
# and a typographic double quote closes a double-quoted string, exactly like their ASCII counterparts.
SINGLE_QUOTES={'\u2018','\u2019','\u201a','\u201b'}
DOUBLE_QUOTES={'\u201c','\u201d','\u201e'}
PAIR={')':'(',']':'[','}':'{'}
OPEN=set(PAIR.values())
HERE_STRING=re.compile(r"@'\n(.*?)\n^'@",re.M|re.S)

def literal_states(s):
    """Lexical state of every character with ASCII delimiters, mirroring mask_ps: code, comment, single, double, here."""
    states=['code']*len(s);i=0;n=len(s);state='code';depth=0
    while i<n:
        c=s[i];d=s[i:i+2]
        if state=='line':
            if c=='\n': state='code'
            else: states[i]='comment'
            i+=1;continue
        if state=='block':
            states[i]='comment'
            if d=='<#':depth+=1;states[i:i+2]=['comment']*len(d);i+=2;continue
            if d=='#>':
                depth-=1;states[i:i+2]=['comment']*len(d);i+=2
                if not depth:state='code'
                continue
            i+=1;continue
        if state in ('h_single','h_double'):
            end="'@" if state=='h_single' else '"@'
            if (i==0 or s[i-1]=='\n') and s.startswith(end,i):i+=2;state='code';continue
            states[i]='here';i+=1;continue
        if state in ('single','double'):
            q="'" if state=='single' else '"'
            if c=='`' and state=='double':
                states[i]=state;i+=1
                if i<n:states[i]=state
                i+=1;continue
            if c==q:
                if i+1<n and s[i+1]==q:states[i:i+2]=[state,state];i+=2;continue
                state='code';i+=1;continue
            states[i]=state;i+=1;continue
        if d=='<#':state='block';depth=1;states[i:i+2]=['comment']*len(d);i+=2;continue
        if c=='#':state='line';states[i]='comment';i+=1;continue
        if d in ("@'",'@"') and re.match(r'@[\'\"][ \t]*\r?\n',s[i:]):state='h_single' if d=="@'" else 'h_double';i+=2;continue
        if c in "'\"":state='single' if c=="'" else 'double';i+=1;continue
        if c=='`':i+=2;continue
        i+=1
    return states

def typographic_quotes(text,rel,first_line=1,where=''):
    """Typographic quotes that PowerShell would read as a delimiter: in code, or closing a literal of the same family."""
    errors=[];states=literal_states(text)
    for pos,ch in enumerate(text):
        if ch not in SINGLE_QUOTES and ch not in DOUBLE_QUOTES: continue
        state=states[pos];line=first_line+text.count('\n',0,pos)
        if state=='code':
            errors.append(f'{rel}:{line}: typographic quote U+{ord(ch):04X} in executable PowerShell{where}')
        elif (state=='single' and ch in SINGLE_QUOTES) or (state=='double' and ch in DOUBLE_QUOTES):
            kind='single' if state=='single' else 'double'
            errors.append(f'{rel}:{line}: typographic quote U+{ord(ch):04X} closes this {kind}-quoted string in PowerShell{where}; write U+02BC for an apostrophe')
    return errors

def pinned_worker_functions():
    """Worker factories whose single-quoted here-strings are compiled verbatim: pinned operations, *WorkerCode and the
    shared worker text composed in front of them (*WorkerCommon, P-CD-08)."""
    pinned={}
    contracts=ROOT/'tools/operation-contracts.json'
    if contracts.is_file():
        for item in json.loads(contracts.read_text(encoding='utf-8')):pinned.setdefault(item['File'],set()).add(item['Function'])
    return pinned
PINNED_WORKERS=pinned_worker_functions()

def worker_body_errors(path:Path,text:str):
    """Lexical checks of every worker body: [scriptblock]::Create parses it as code, not as a here-string."""
    rel=path.relative_to(ROOT);errors=[];names=PINNED_WORKERS.get(rel.as_posix(),set())
    for name,spans in functions(text).items():
        if name not in names and not name.endswith(('WorkerCode','WorkerCommon')): continue
        for a,b in spans:
            for m in HERE_STRING.finditer(text,a,b):
                body=m.group(1);first=text.count('\n',0,m.start(1))+1;where=f' (worker body of {name})'
                errors.extend(typographic_quotes(body,rel,first,where))
                for issue,line in mask_ps(body)[1]:errors.append(f'{rel}:{first+line-1}: {issue}{where}')
    return errors

def validate(path:Path):
    text=path.read_text(encoding='utf-8-sig')
    masked,issues=mask_ps(text)
    errors=[]
    rel=path.relative_to(ROOT)
    for issue,line in issues: errors.append(f'{rel}:{line}: {issue}')
    errors.extend(typographic_quotes(text,rel))
    errors.extend(worker_body_errors(path,text))
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
    print(f'PASS: {len(files)} PowerShell files; lexical state, delimiters, typographic quote delimiters (code, literals and worker bodies) and boolean-command hazards checked.')
    print('PASS: Dispatcher timers only from New-DomeniaTimer (FI-05); no Get-Command in timer ticks or heartbeat handlers (PF-10).')
    print('NOTE: native Windows PowerShell parser was not executed on this host.')
    return 0
if __name__=='__main__': raise SystemExit(main())
