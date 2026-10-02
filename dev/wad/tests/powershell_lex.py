"""Approximate lexical checks only; NOT a replacement for PowerShell's native parser.
Used to inspect delimiters and literal worker bodies on non-Windows build hosts.
"""
from pathlib import Path
import re,sys
def mask_ps(s):
    out=list(s); i=0;n=len(s);state='code';depth=0;start=0;issues=[]
    while i<n:
        c=s[i];d=s[i:i+2]
        if state=='line':
            if c=='\n': state='code'
            else: out[i]=' '
            i+=1;continue
        if state=='block':
            if d=='<#':depth+=1;out[i:i+2]='  ';i+=2;continue
            if d=='#>':
                depth-=1;out[i:i+2]='  ';i+=2
                if not depth:state='code'
                continue
            if c!='\n':out[i]=' '
            i+=1;continue
        if state in ('h_single','h_double'):
            end="'@" if state=='h_single' else '"@'
            if (i==0 or s[i-1]=='\n') and s.startswith(end,i):
                out[i:i+2]='  ';i+=2;state='code';continue
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
                state='code';i+=1;continue
            if c!='\n':out[i]=' '
            i+=1;continue
        if d=='<#':state='block';depth=1;start=i;out[i:i+2]='  ';i+=2;continue
        if c=='#':state='line';out[i]=' ';i+=1;continue
        if d in ("@'",'@"') and re.match(r'@[\'\"][ \t]*\r?\n',s[i:]):
            state='h_single' if d=="@'" else 'h_double';start=i;out[i:i+2]='  ';i+=2;continue
        if c in "'\"":state='single' if c=="'" else 'double';start=i;out[i]=' ';i+=1;continue
        if c=='`':
            out[i]=' ';i+=1
            if i<n and s[i]!='\n':out[i]=' '
            i+=1;continue
        i+=1
    if state not in ('code','line'):issues.append(('unclosed '+state,s.count('\n',0,start)+1))
    return ''.join(out),issues

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

