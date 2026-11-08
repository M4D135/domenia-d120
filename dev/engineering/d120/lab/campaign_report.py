#!/usr/bin/env python3
"""Verify and summarize a D120 integration campaign fetched from the test VM (Invoke-D120Campaign.ps1 output).
   Usage: campaign_report.py RUN_DIR [--base-run BASE_SUITES_DIR] [--baseline-txt FILE] [--dev DEV_ROOT] [--out FILE.json]
   - binds the run to the local working tree (same fingerprint as Get-DomeniaTreeFingerprint in the VM);
   - checks the host really was Windows PowerShell 5.1 Desktop x64;
   - compares suites test by test with BASE_SUITES_DIR (Invoke-LabRun output of the reference commit), or else
     suite by suite with the recorded reference counts (baseline-5.1-vm.txt), which is coarser.
   Exit: 0 bound + 5.1 + every step PASS + no regression; 1 otherwise; 2 when the run is unreadable or unbound.
   An integration campaign never sets acceptance_passed: only release_guard.py --require-windows on the ZIP does."""
import argparse,hashlib,json,os,re,subprocess,sys
from pathlib import Path
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
import compare_runs

def tree_fingerprint(dev:Path):
    """Files the VM receives: lab.sh sync sends tracked + untracked-not-ignored files, minus __pycache__."""
    names=set()
    for args in (['ls-files','-z'],['ls-files','-z','--others','--exclude-standard']):
        out=subprocess.run(['git','-C',str(dev)]+args,check=True,capture_output=True).stdout
        names.update(n.decode('utf-8') for n in out.split(b'\0') if n)
    rows=[]
    for name in names:
        if re.search(r'(^|/)__pycache__/',name):continue
        p=dev/name
        if not p.is_file():continue
        rows.append(name+'\t'+hashlib.sha256(p.read_bytes()).hexdigest().upper())
    rows.sort()
    text='\n'.join(rows)+'\n'
    return hashlib.sha256(text.encode('utf-8')).hexdigest().upper(),len(rows)

def find_summary(run:Path):
    for cand in (run/'_campaign.json',run/'campaign'/'_campaign.json'):
        if cand.is_file():return cand
    hits=sorted(run.rglob('_campaign.json'))
    return hits[0] if hits else None

def read_baseline_txt(path:Path):
    counts={}
    for line in path.read_text(encoding='utf-8').splitlines():
        m=re.match(r'^(Test-[A-Za-z0-9]+): pass=(\d+) fail=(\d+)',line)
        if m:counts[m.group(1)]=(int(m.group(2)),int(m.group(3)))
    return counts

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('run',type=Path)
    ap.add_argument('--base-run',type=Path)
    ap.add_argument('--baseline-txt',type=Path,default=HERE/'baseline-5.1-vm.txt')
    ap.add_argument('--dev',type=Path,default=HERE.parents[2])
    ap.add_argument('--out',type=Path)
    a=ap.parse_args()
    summary_path=find_summary(a.run)
    if not summary_path:
        print('ILLISIBLE: _campaign.json introuvable sous '+str(a.run));return 2
    s=json.loads(summary_path.read_text(encoding='utf-8-sig'))
    run_dir=summary_path.parent
    verdict={'Kind':'D120IntegrationVerdict','Run':str(run_dir),'Qualifying':False,'Problems':[]}
    host=s.get('Host') or {}
    verdict['Host']=host
    if not (host.get('PSEdition')=='Desktop' and str(host.get('PSVersion','')).startswith('5.1.') and host.get('Is64BitProcess') is True):
        verdict['Problems'].append('Hote non Windows PowerShell 5.1 x64')
    src=s.get('Source') or {}
    local,count=tree_fingerprint(a.dev)
    verdict['Source']={'RunFingerprint':src.get('Fingerprint'),'RunFiles':src.get('Files'),'LocalFingerprint':local,'LocalFiles':count,'Commit':src.get('Commit'),'Dirty':src.get('Dirty')}
    bound=bool(src.get('Fingerprint')) and src.get('Fingerprint')==local
    verdict['Bound']=bound
    if not bound:verdict['Problems'].append('Campagne non liee a l arbre local (empreinte differente ou absente)')
    steps=s.get('Steps') or []
    verdict['Steps']=[{k:x.get(k) for k in ('Name','Status','ExitCode','TimedOut','DurationMs','Note')} for x in steps]
    for x in steps:
        if x.get('Status')!='PASS' and x.get('Name')!='suites':verdict['Problems'].append('Etape en echec: '+str(x.get('Name')))
    print(f"Hote: {host.get('Computer')} PS {host.get('PSVersion')} {host.get('PSEdition')} x64={host.get('Is64BitProcess')} session={host.get('SessionId')}")
    print(f"Source: commit={src.get('Commit') or '?'} dirty={src.get('Dirty')} lie={'OUI' if bound else 'NON'} ({count} fichiers locaux, {src.get('Files')} dans la VM)")
    for x in verdict['Steps']:print(f"  {x['Name']:<11} {x['Status']:<5} exit={x['ExitCode']} timeout={x['TimedOut']} {x.get('Note') or ''}")
    suites=run_dir/'suites'
    if suites.is_dir():
        cur=compare_runs.load(str(suites))
        tp=tf=0;per={}
        for name,v in cur.items():
            if '__error__' in v:verdict['Problems'].append('Rapport illisible: '+name);continue
            p=sum(1 for t in v['tests'].values() if t=='PASS');f=sum(1 for t in v['tests'].values() if t=='FAIL')
            per[name]={'pass':p,'fail':f,'exit':v['exit']};tp+=p;tf+=f
        verdict['Suites']=per;verdict['Totals']={'pass':tp,'fail':tf,'suites':len(per)}
        print(f'Suites: {tp} reussis, {tf} en echec, {len(per)} rapports')
        if a.base_run:
            base=compare_runs.load(str(a.base_run))
            regress=[];fixed=0
            for name in sorted(set(base)|set(cur)):
                ta=base.get(name,{}).get('tests',{});tb=cur.get(name,{}).get('tests',{})
                for t in sorted(set(ta)|set(tb)):
                    x=ta.get(t);y=tb.get(t)
                    if x=='PASS' and y!='PASS':regress.append(f'{name} :: {t} ({x} -> {y})')
                    elif x not in (None,'PASS') and y=='PASS':fixed+=1
            verdict['Comparison']={'Mode':'test-par-test','Base':str(a.base_run),'Regressions':regress,'Fixed':fixed}
            print(f'Comparaison test par test avec {a.base_run}: {len(regress)} regression(s), {fixed} corrige(s)')
            for r in regress:print('  REGRESSION '+r)
            if regress:verdict['Problems'].append(f'{len(regress)} regression(s) test par test (a trier : un test renomme apparait comme regression)')
        elif a.baseline_txt.is_file():
            ref=read_baseline_txt(a.baseline_txt);drops=[];missing=[]
            for name,(p,f) in sorted(ref.items()):
                if name not in per:missing.append(name);continue
                if per[name]['pass']<p:drops.append(f"{name}: {p} -> {per[name]['pass']} reussis")
            verdict['Comparison']={'Mode':'par-suite (grossier)','Base':str(a.baseline_txt),'Drops':drops,'Missing':missing,'New':sorted(set(per)-set(ref))}
            print(f'Comparaison par suite avec {a.baseline_txt.name}: {len(drops)} baisse(s), {len(missing)} suite(s) absente(s)')
            for d in drops:print('  BAISSE '+d)
            for m in missing:print('  ABSENTE '+m)
            if drops or missing:verdict['Problems'].append('Baisse ou absence par rapport a la reference par suite')
    else:
        verdict['Problems'].append('Suites non executees')
    verdict['Status']='OK' if not verdict['Problems'] else 'A_TRIER'
    print('Verdict: '+verdict['Status']+('' if not verdict['Problems'] else ' - '+' ; '.join(verdict['Problems'])))
    print('Rappel: campagne d integration, non qualifiante pour la livraison (release_guard.py --require-windows).')
    if a.out:a.out.write_text(json.dumps(verdict,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
    if not bound:return 2
    return 0 if not verdict['Problems'] else 1

if __name__=='__main__':sys.exit(main())
