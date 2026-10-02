#!/usr/bin/env python3
"""Offline deterministic Domenia runtime/DEV packaging. No personal data or network access."""
from pathlib import Path
import argparse,hashlib,json,zipfile,subprocess,sys
ROOT=Path(__file__).resolve().parents[1]
# D010: the release identity is read from the single contract, never written here.
CONTRACT=json.loads((ROOT/'tools/release-contract.json').read_text(encoding='utf-8-sig'))
BUILD=CONTRACT['Build'];RELEASE=CONTRACT['Release'];VERSION=CONTRACT['Version'];STATUS=CONTRACT['ReleaseStatus']

def digest(data):return hashlib.sha256(data).hexdigest().upper()
def writejson(path,data):path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
def runtime_paths():
    paths=['Domenia.exe']+['wad/'+n for n in ['Domenia-Start.ps1','Domenia-Modules.ps1','Domenia-Core.ps1','Domenia.ico','Domenia.config.json','Domenia.release.json','Domenia.login-mode.cfg','Domenia.theme.cfg','Domenia.ui-profile.cfg','Microsoft.ActiveDirectory.Management.dll','ActiveDirectoryPowerShellResources.dll','PsExec.exe']]
    paths+=['wad/Support/DEBLOQUER_TOUT.cmd','wad/Support/Debloquer-Paquet.ps1','wad/Support/.lifecycle.lock']
    paths += [p.relative_to(ROOT).as_posix() for p in (ROOT/'wad/modules').iterdir() if p.is_file() and p.suffix in {'.ps1','.json','.cs','.xaml'}]
    return sorted(paths)
def preserved(rel):return rel in ['wad/Domenia.config.json','wad/Domenia.login-mode.cfg','wad/Domenia.theme.cfg','wad/Domenia.ui-profile.cfg']
def entry(rel,isruntime):
    p=ROOT/rel;data=p.read_bytes()
    return dict(Path=rel,Sha256=digest(data),Bytes=len(data),Runtime=isruntime,PreserveExisting=preserved(rel))
def gate(script,label,*args):
    run=subprocess.run([sys.executable,str(ROOT/script),*args],capture_output=True,text=True)
    if run.returncode:raise ValueError(label+' failed:\n'+run.stdout+run.stderr)
def build(out,manifest_only=False):
    # D010/D117: version sites and pinned components must agree with the release contract.
    gate('tools/release_contract.py','Release contract','--check')
    # D011: one definition per function name and a complete closed loader list.
    gate('tools/audit_function_names.py','Closed loader function names')
    # Mandatory static preflight over every PowerShell source shipped in DEV.
    preflight=subprocess.run([sys.executable,str(ROOT/'tools/validate_powershell_static.py')],capture_output=True,text=True)
    if preflight.returncode: raise ValueError('PowerShell static preflight failed:\n'+preflight.stdout+preflight.stderr)
    # PowerShell 5.1 treats typographic quotation marks as quote delimiters.
    # Reject them outside here-strings so a UI sentence cannot break a module at startup.
    bad_quotes = {chr(0x2018),chr(0x2019),chr(0x201C),chr(0x201D)}
    for ps in [ROOT/'wad/Domenia-Start.ps1',ROOT/'wad/Domenia-Modules.ps1'] + sorted((ROOT/'wad/modules').glob('*.ps1')):
        text=ps.read_text(encoding='utf-8-sig')
        in_here=None
        for lineno,line in enumerate(text.splitlines(),1):
            stripped=line.strip()
            if in_here:
                if stripped == in_here+'@': in_here=None
                continue
            # A here-string opener is syntactic only when @" or @' ends the command line.
            if stripped.endswith('@"'): in_here='"'; continue
            if stripped.endswith("@'"): in_here="'"; continue
            if any(ch in line for ch in bad_quotes):
                raise ValueError(f'Typographic quote forbidden in PowerShell code: {ps.relative_to(ROOT)}:{lineno}')
    # Check the real UI event wiring, callback guards and all module exports.
    # A helper existing on disk is not enough if the grid never calls it.
    selection_check=subprocess.run([sys.executable,str(ROOT/'tools/audit_preload.py')],capture_output=True,text=True)
    if selection_check.returncode:raise ValueError('Selection integration audit failed:\n'+selection_check.stdout+selection_check.stderr)
    # Verify every operation body AND the startup registry fingerprint before packaging.
    result=subprocess.run([sys.executable,str(ROOT/'tools/update_worker_contracts.py')],capture_output=True,text=True)
    if result.returncode:raise ValueError('Worker contracts not verified: '+result.stdout+result.stderr)
    runtime=runtime_paths();assert len(runtime)==len(set(runtime))
    for rel in runtime:
        if not (ROOT/rel).is_file():raise ValueError('Missing runtime '+rel)
        if any(x in rel.lower().split('/') for x in ['tests','data','history','backups']):raise ValueError('Private/development runtime path '+rel)
    prod=dict(Format=1,Version=VERSION,Build=BUILD,Edition='prod',ReleaseStatus=STATUS,Files=[entry(x,True) for x in runtime])
    writejson(ROOT/'tools/prod-manifest.json',prod)
    members=[]
    for p in sorted(ROOT.rglob('*')):
        if not p.is_file():continue
        rel=p.relative_to(ROOT).as_posix()
        if rel=='wad/package-manifest.json' or any(x in p.parts for x in ['__pycache__','.git','backups']) or rel.startswith('wad/data/') or p.suffix in {'.pyc','.tmp'}:continue
        members.append(rel)
    dev=dict(Format=1,Version=VERSION,Build=BUILD,Edition='dev',ReleaseStatus=STATUS,Files=[entry(x,x in runtime) for x in members])
    writejson(ROOT/'wad/package-manifest.json',dev)
    if manifest_only:return {'runtime':len(runtime),'dev':len(members)}
    out.mkdir(parents=True,exist_ok=True);result={}
    for edition,paths,manifest in [('prod',runtime,prod),('dev',members,dev)]:
        target=out/('Domenia_'+VERSION+'_'+RELEASE+'_'+edition.upper()+'.zip')
        with zipfile.ZipFile(target,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
            def put(rel,data):
                info=zipfile.ZipInfo(edition+'/'+rel,tuple(int(x) for x in CONTRACT['Date'].split('-'))+(0,0,0));info.compress_type=zipfile.ZIP_DEFLATED;info.external_attr=0o100644<<16;z.writestr(info,data)
            for rel in paths:put(rel,(ROOT/rel).read_bytes())
            put('wad/package-manifest.json',(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n').encode())
        with zipfile.ZipFile(target) as z:
            assert z.testzip() is None
            m=json.loads(z.read(edition+'/wad/package-manifest.json'))
            actual={p[len(edition)+1:] for p in z.namelist()}
            assert actual=={e['Path'] for e in m['Files']}|{'wad/package-manifest.json'}
            for e in m['Files']:assert digest(z.read(edition+'/'+e['Path']))==e['Sha256'],e['Path']
            if edition=='prod':assert {n.split('/')[1] for n in z.namelist()}=={'Domenia.exe','wad'}
        result[edition]={'Archive':target.name,'Bytes':target.stat().st_size,'Sha256':digest(target.read_bytes()),'Files':len(manifest['Files']),'ZipIntegrity':True,'ManifestValid':True}
    with zipfile.ZipFile(out/result['prod']['Archive']) as a,zipfile.ZipFile(out/result['dev']['Archive']) as b:
        for rel in runtime:assert a.read('prod/'+rel)==b.read('dev/'+rel),rel
    result['IdenticalRuntimeFiles']=len(runtime)
    # D009: offline integrity gate on the exact archives. Publication still requires the Windows report
    # linked to the archive hash (release_guard.py --require-windows --windows-report ...).
    sys.path.insert(0,str(ROOT/'engineering/d120'))
    import release_guard
    for edition in ('prod','dev'):
        info=release_guard.inspect_archive(out/result[edition]['Archive'])
        if info['SHA256']!=result[edition]['Sha256'].lower():raise ValueError('Release guard hash mismatch '+edition)
        result[edition]['ReleaseGuard']=info['Integrity'];result[edition]['WindowsQualification']=info['WindowsQualification']
    result['Build']=BUILD;result['Publishable']=False
    result['PublicationRule']='Publiable uniquement avec un rapport Windows PowerShell 5.1 lie au SHA-256 du ZIP (release_guard.py --require-windows).'
    (out/'build-report.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    return result
if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--output',type=Path,required=True);ap.add_argument('--manifest-only',action='store_true');a=ap.parse_args();print(json.dumps(build(a.output,a.manifest_only),indent=2))
