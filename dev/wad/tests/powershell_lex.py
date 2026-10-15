"""Approximate lexical checks only; NOT a replacement for PowerShell's native parser.
Used to inspect delimiters and literal worker bodies on non-Windows build hosts.
"""
from pathlib import Path
import re,sys
def _scan(s):
    out=list(s); i=0;n=len(s);state='code';depth=0;start=0;issues=[];spans=[]
    while i<n:
        c=s[i];d=s[i:i+2]
        if state=='line':
            if c=='\n': spans.append(('line',start,i));state='code'
            else: out[i]=' '
            i+=1;continue
        if state=='block':
            if d=='<#':depth+=1;out[i:i+2]='  ';i+=2;continue
            if d=='#>':
                depth-=1;out[i:i+2]='  ';i+=2
                if not depth:state='code';spans.append(('block',start,i))
                continue
            if c!='\n':out[i]=' '
            i+=1;continue
        if state in ('h_single','h_double'):
            end="'@" if state=='h_single' else '"@'
            if (i==0 or s[i-1]=='\n') and s.startswith(end,i):
                out[i:i+2]='  ';i+=2;spans.append((state,start,i));state='code';continue
            if c!='\n':out[i]=' '
            i+=1;continue
        if state in ('single','double'):
            q="'" if state=='single' else '"'
            if c=='`' and state=='double':
                out[i]=' ';i+=1
                if i<n and s[i]!='\n':out[i]=' '
                i+=1;continue
            if c==q:
                out[i]=' '
                if i+1<n and s[i+1]==q:out[i+1]=' ';i+=2;continue
                spans.append((state,start,i+1));state='code';i+=1;continue
            if c!='\n':out[i]=' '
            i+=1;continue
        if d=='<#':state='block';depth=1;start=i;out[i:i+2]='  ';i+=2;continue
        if c=='#':state='line';start=i;out[i]=' ';i+=1;continue
        if d in ("@'",'@"') and re.match(r'@[\'\"][ \t]*\r?\n',s[i:]):
            state='h_single' if d=="@'" else 'h_double';start=i;out[i:i+2]='  ';i+=2;continue
        if c in "'\"":state='single' if c=="'" else 'double';start=i;out[i]=' ';i+=1;continue
        if c=='`':
            out[i]=' ';i+=1
            if i<n and s[i]!='\n':out[i]=' '
            i+=1;continue
        i+=1
    if state not in ('code','line'):issues.append(('unclosed '+state,s.count('\n',0,start)+1))
    if state!='code':spans.append((state,start,n))
    return ''.join(out),issues,spans

def mask_ps(s):
    out,issues,_=_scan(s)
    return out,issues

def segments(s):
    """(kind, start, end) of every comment ('line', 'block') and string ('single', 'double', 'h_single', 'h_double')
    in source order; end is exclusive and delimiters are included. A line comment stops before its newline."""
    return _scan(s)[2]

def functions(s):
    masked,issues=mask_ps(s);found={}
    for m in re.finditer(r'^function\s+([\w-]+)\s*\{',masked,re.M|re.I):
        start=m.start();cur=m.end();depth=1
        while cur<len(masked) and depth:
            if masked[cur]=='{':depth+=1
            elif masked[cur]=='}':depth-=1
            cur+=1
        found.setdefault(m.group(1),[]).append((start,cur))
    return found

def getfunc(s,name):
    pos=functions(s).get(name,[])
    if len(pos)!=1:raise ValueError((name,'count',len(pos)))
    a,b=pos[0];return s[a:b]

def replacefunc(s,name,body):
    pos=functions(s).get(name,[])
    if len(pos)!=1:raise ValueError((name,'count',len(pos)))
    a,b=pos[0];return s[:a]+body.rstrip()+s[b:]



def top_level_functions(source):
    """Closed model-module subset: direct function statements, matching EndBlock.Statements.
    Nested functions, script blocks and functions quoted in workers are excluded. Reject malformed delimiters;
    Microsoft's AST remains the authority (Test-DomeniaWorkerComposition compares both parsers).
    """
    masked, issues = mask_ps(source)
    if issues:
        raise ValueError('Malformed model source: '+str(issues))
    starts = {m.start(1): m for m in re.finditer(r'^[ \t]*(function\s+([\w-]+)\s*\{)', masked, re.M | re.I)}
    stack = []
    found = {}
    active = None
    pairs = {'}': '{', ')': '(', ']': '['}
    for i, char in enumerate(masked):
        if i in starts and not stack:
            active = (starts[i].group(2), i)
        if char in '{([':
            stack.append(char)
        elif char in '})]':
            if not stack or stack.pop() != pairs[char]:
                raise ValueError('Malformed model delimiter at '+str(i))
            if not stack and active is not None:
                name, start = active
                found.setdefault(name, []).append((start, i+1))
                active = None
    if stack or active is not None:
        raise ValueError('Unclosed model delimiter')
    return found
