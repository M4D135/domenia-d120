#!/usr/bin/env python3
"""Summarize Domenia lab-run reports (Invoke-LabRun.ps1 output) and compare two runs test by test.
   Usage: compare_runs.py RUN_DIR  |  compare_runs.py OLD_RUN_DIR NEW_RUN_DIR  (exit 1 on any regression)."""
import json,glob,os,sys
def load(d):
    out={}
    for p in sorted(glob.glob(os.path.join(d,'*.json'))):
        suite=os.path.basename(p).replace('.ps1.json','')
        try: r=json.load(open(p,encoding='utf-8-sig'))
        except Exception as e: out[suite]={'__error__':str(e)};continue
        tests=None
        for k,v in r.items():
            if isinstance(v,list) and v and isinstance(v[0],dict) and ('Name' in v[0]): tests=v;break
        res={}
        for t in tests or []:
            st=t.get('Status',t.get('Passed',t.get('Result',t.get('Success',''))))
            ok = st in (True,'Passed','PASS','True','OK','Pass','Success')
            res[str(t.get('Name'))]=('PASS' if ok else 'SKIP' if str(st) in('Skipped','SKIP') else 'FAIL')
        ex=None
        ep=p+'.exit'
        if os.path.exists(ep): ex=open(ep).read().strip()
        out[suite]={'tests':res,'exit':ex}
    return out
def main():
    a=load(sys.argv[1])
    if len(sys.argv)==2:
        tp=tf=0
        for s,v in a.items():
            if '__error__' in v: print(f'{s}: UNREADABLE {v["__error__"]}');continue
            p=sum(1 for x in v['tests'].values() if x=='PASS');f=sum(1 for x in v['tests'].values() if x=='FAIL')
            tp+=p;tf+=f
            print(f'{s}: pass={p} fail={f} exit={v["exit"]}')
        print(f'TOTAL pass={tp} fail={tf} suites={len(a)}')
        return
    b=load(sys.argv[2]);regress=0;fixed=0;new=0
    for s in sorted(set(a)|set(b)):
        ta=a.get(s,{}).get('tests',{});tb=b.get(s,{}).get('tests',{})
        if s not in b: print(f'SUITE MISSING in new run: {s}');regress+=1;continue
        for n in sorted(set(ta)|set(tb)):
            x=ta.get(n);y=tb.get(n)
            if x=='PASS' and y!='PASS': print(f'REGRESSION {s} :: {n} ({x} -> {y})');regress+=1
            elif x not in(None,'PASS') and y=='PASS': fixed+=1
            elif x is None and y is not None:
                new+=1
                if y!='PASS': print(f'NEW-FAIL {s} :: {n}')
    print(f'regressions={regress} fixed={fixed} new_tests={new}')
    sys.exit(1 if regress else 0)
if __name__=='__main__': main()
