#!/usr/bin/env python3
"""Offline deterministic Domenia runtime/DEV packaging. No personal data or network access.

D112: the member list is sorted on the POSIX relative path (identical on Windows and macOS), host junk files and the
output folder are never packaged, manifests are written with LF, every integrity check raises (never an assert that
python -O would drop) and BUILD-REPORT records the environment (Python, zlib, commit) that a rebuild must match.
D009/D111: the offline release guard inspects the exact archives; with --windows-report the Windows PowerShell 5.1
qualification report must be bound to both archives (release_guard.require_evidence), otherwise nothing is publishable.
D111 decision: a shipped configuration that enables Auth.DemoProvider is refused.
D116: --signed-stage builds from a staged copy signed by tools/Signer-Distribution.ps1; each signed file must equal the
audited source once its Authenticode block is removed, and Domenia.exe is never taken from the stage (F8).
"""
from pathlib import Path
import argparse,hashlib,json,platform,re,struct,subprocess,sys,zipfile,zlib
ROOT=Path(__file__).resolve().parents[1]
# D010: the release identity is read from the single contract, never written here.
CONTRACT_PATH=ROOT/'tools/release-contract.json'
CONTRACT=json.loads(CONTRACT_PATH.read_text(encoding='utf-8-sig'))
BUILD=CONTRACT['Build'];RELEASE=CONTRACT['Release'];VERSION=CONTRACT['Version'];STATUS=CONTRACT['ReleaseStatus']
JUNK_NAMES={'.ds_store','thumbs.db','desktop.ini'}
SKIPPED_DIRS={'__pycache__','.git','backups'}
SIGNATURE_MARK=b'# SIG # Begin signature block'

def digest(data):return hashlib.sha256(data).hexdigest().upper()
def writejson(path,data):
    # newline='\n': a build under Windows must not write CRLF into the versioned manifests.
    path.parent.mkdir(parents=True,exist_ok=True)
    with open(path,'w',encoding='utf-8',newline='\n') as handle:handle.write(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
def require(condition,message):
    if not condition:raise ValueError(message)
def runtime_paths(root=ROOT):
    paths=['Domenia.exe']+['wad/'+n for n in ['Domenia-Start.ps1','Domenia-Modules.ps1','Domenia-Core.ps1','Domenia.ico','Domenia.config.json','Domenia.release.json','Domenia.login-mode.cfg','Domenia.theme.cfg','Domenia.ui-profile.cfg','Microsoft.ActiveDirectory.Management.dll','ActiveDirectoryPowerShellResources.dll','PsExec.exe']]
    paths+=['wad/Support/DEBLOQUER_TOUT.cmd','wad/Support/Debloquer-Paquet.ps1','wad/Support/.lifecycle.lock']
    paths+=[p.relative_to(root).as_posix() for p in (root/'wad/modules').iterdir() if p.is_file() and p.suffix in {'.ps1','.json','.cs','.xaml'} and p.name.lower() not in JUNK_NAMES]
    return sorted(paths)
def preserved(rel):return rel in ['wad/Domenia.config.json','wad/Domenia.login-mode.cfg','wad/Domenia.theme.cfg','wad/Domenia.ui-profile.cfg']

def check_output(out,root=ROOT):
    """An output folder inside the source tree would be packaged by the next build."""
    target=Path(out).resolve();base=Path(root).resolve()
    if target==base or base in target.parents:raise ValueError('Dossier de sortie refuse dans l arbre source : '+str(target)+'. Choisir un dossier hors de '+str(base)+'.')
    return target

def select_members(root=ROOT,exclude=()):
    """DEV members, sorted on the POSIX relative path (ordinal), without host junk, caches, data or excluded folders."""
    base=Path(root).resolve();skip=[Path(x).resolve() for x in exclude]
    members=[]
    for p in base.rglob('*'):
        if not p.is_file():continue
        if any(s==p or s in p.parents for s in skip):continue
        rel=p.relative_to(base).as_posix()
        parts=rel.split('/')
        if rel=='wad/package-manifest.json' or any(x in SKIPPED_DIRS for x in parts[:-1]) or rel.startswith('wad/data/'):continue
        if p.suffix in {'.pyc','.tmp'} or parts[-1].lower() in JUNK_NAMES:continue
        members.append(rel)
    return sorted(members)

def assert_config_not_demo(data):
    """D111 decision: the demonstration provider ships in PROD but is never enabled by the shipped configuration."""
    try:config=json.loads(data.decode('utf-8-sig'))
    except (UnicodeDecodeError,ValueError) as e:raise ValueError('wad/Domenia.config.json illisible : '+str(e))
    auth=config.get('Auth') if isinstance(config,dict) else None
    value=auth.get('DemoProvider',False) if isinstance(auth,dict) else False
    enabled=(value is True) or (isinstance(value,str) and value.strip().lower() in ('true','1','yes','oui','on'))
    if enabled:raise ValueError('wad/Domenia.config.json active Auth.DemoProvider : configuration de demonstration refusee dans une livraison.')

def strip_signature(data):
    """Bytes of a PowerShell file without its Authenticode block (appended by Set-AuthenticodeSignature)."""
    cut=data.rfind(SIGNATURE_MARK)
    if cut<0:return None
    head=data[:cut]
    if head.endswith(b'\r\n'):head=head[:-2]
    elif head.endswith(b'\n'):head=head[:-1]
    return head

def signed_source(rel,stage,root=ROOT):
    """D116: bytes for rel taken from the signed stage, accepted only when the stage file is the audited source plus a
    signature block. Domenia.exe and non-script files always come from the source tree."""
    source=(root/rel).read_bytes()
    if stage is None or rel=='Domenia.exe' or not rel.lower().endswith('.ps1'):return source
    staged=Path(stage)/rel
    if not staged.is_file():raise ValueError('Fichier signe absent de la preparation : '+rel)
    data=staged.read_bytes()
    bare=strip_signature(data)
    if bare is None:raise ValueError('Fichier non signe dans la preparation : '+rel)
    if bare!=source and bare!=source.rstrip(b'\r\n') and bare+b'\n'!=source:
        raise ValueError('Fichier signe different de la source auditee : '+rel)
    return data

def pe_file_version(data):
    """FileVersion from VS_FIXEDFILEINFO (signature 0xFEEF04BD), '' when absent. Pure parsing, nothing executed."""
    index=data.find(struct.pack('<I',0xFEEF04BD))
    if index<0 or index+16>len(data):return ''
    ms,ls=struct.unpack_from('<II',data,index+8)
    return '%d.%d.%d.%d'%(ms>>16,ms&0xFFFF,ls>>16,ls&0xFFFF)

def git_state(root=ROOT):
    try:
        commit=subprocess.run(['git','rev-parse','HEAD'],cwd=str(root),capture_output=True,text=True,timeout=20)
        dirty=subprocess.run(['git','status','--porcelain','--','.'],cwd=str(root),capture_output=True,text=True,timeout=60)
        value=commit.stdout.strip() if commit.returncode==0 else ''
        return {'Commit':value if re.fullmatch('[0-9a-f]{40}',value) else '','Dirty':bool(dirty.stdout.strip()) if dirty.returncode==0 else None}
    except (OSError,subprocess.SubprocessError):
        return {'Commit':'','Dirty':None}

def environment(root=ROOT):
    state=git_state(root)
    own=digest(Path(__file__).read_bytes())
    return {'Commit':state['Commit'],'Dirty':state['Dirty'],'ContractSHA256':digest(CONTRACT_PATH.read_bytes()),
            'Python':platform.python_version(),'PythonImplementation':platform.python_implementation(),'Zlib':zlib.ZLIB_RUNTIME_VERSION,'Platform':platform.platform(),
            'Tools':[{'Name':'python','Version':platform.python_version()},{'Name':'zlib','Version':zlib.ZLIB_RUNTIME_VERSION},{'Name':'build_packages.py','Version':own}],
            'Note':'Reconstruction identique attendue a environnement (Python, zlib) et commit egaux ; sinon qualifier puis garder le fichier exact.'}

def component_inventory(runtime,read):
    """D117: version read from each delivered binary, bound to its SHA-256; declared contract entry alongside."""
    declared={c.get('Path'):c for c in CONTRACT.get('Components',[]) if isinstance(c,dict)}
    rows=[]
    for rel in runtime:
        if not rel.lower().endswith(('.exe','.dll')):continue
        data=read(rel);item=declared.get(rel,{})
        rows.append({'Path':rel,'Sha256':digest(data),'FileVersion':pe_file_version(data),'DeclaredSha256':str(item.get('Sha256','')).upper(),'Name':item.get('Name',''),
                     'Bound':bool(item) and str(item.get('Sha256','')).upper()==digest(data)})
    return rows

def gate(script,label,*args):
    run=subprocess.run([sys.executable,str(ROOT/script),*args],capture_output=True,text=True)
    if run.returncode:raise ValueError(label+' failed:\n'+run.stdout+run.stderr)

def guard_archives(out,result,windows_report=None,require_windows=False,evidence_dir=None):
    """D009: offline integrity gate on the exact archives, then the Windows evidence when it is given."""
    sys.path.insert(0,str(ROOT/'engineering/d120'))
    import release_guard
    if require_windows and not windows_report:raise ValueError('Publication refusee : preuve Windows manquante (--windows-report).')
    report=None
    if windows_report:report=json.loads(Path(windows_report).read_text(encoding='utf-8-sig'))
    for edition in ('prod','dev'):
        info=release_guard.inspect_archive(out/result[edition]['Archive'])
        if info['SHA256']!=result[edition]['Sha256'].lower():raise ValueError('Release guard hash mismatch '+edition)
        if report is not None:
            # GateError is a ValueError: a report bound to another archive or with a missing scenario stops the build.
            info=release_guard.require_evidence(info,report,Path(evidence_dir) if evidence_dir else None)
        result[edition]['ReleaseGuard']=info['Integrity'];result[edition]['WindowsQualification']=info['WindowsQualification']
    result['Publishable']=all(result[e]['WindowsQualification']=='PASS_REPORTED' for e in ('prod','dev'))
    return result

def build(out,manifest_only=False,windows_report=None,require_windows=False,evidence_dir=None,signed_stage=None):
    out=check_output(out)
    stage=Path(signed_stage).resolve() if signed_stage else None
    if stage is not None:check_output(stage)
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
    gate('tools/update_migration_worker.py','Migration worker sources')
    # Verify every operation body AND the startup registry fingerprint before packaging.
    result=subprocess.run([sys.executable,str(ROOT/'tools/update_worker_contracts.py')],capture_output=True,text=True)
    if result.returncode:raise ValueError('Worker contracts not verified: '+result.stdout+result.stderr)
    assert_config_not_demo((ROOT/'wad/Domenia.config.json').read_bytes())
    runtime=runtime_paths();require(len(runtime)==len(set(runtime)),'Duplicate runtime path')
    for rel in runtime:
        if not (ROOT/rel).is_file():raise ValueError('Missing runtime '+rel)
        if any(x in rel.lower().split('/') for x in ['tests','data','history','backups']):raise ValueError('Private/development runtime path '+rel)
    cache={}
    def read(rel):
        if rel not in cache:cache[rel]=signed_source(rel,stage)
        return cache[rel]
    def entry(rel,isruntime):
        data=read(rel)
        return dict(Path=rel,Sha256=digest(data),Bytes=len(data),Runtime=isruntime,PreserveExisting=preserved(rel))
    prod=dict(Format=1,Version=VERSION,Build=BUILD,Edition='prod',ReleaseStatus=STATUS,Files=[entry(x,True) for x in runtime])
    writejson(ROOT/'tools/prod-manifest.json',prod)
    members=select_members(ROOT,exclude=[out]+([stage] if stage is not None else []))
    dev=dict(Format=1,Version=VERSION,Build=BUILD,Edition='dev',ReleaseStatus=STATUS,Files=[entry(x,x in runtime) for x in members])
    writejson(ROOT/'wad/package-manifest.json',dev)
    if manifest_only:return {'runtime':len(runtime),'dev':len(members)}
    out.mkdir(parents=True,exist_ok=True);result={}
    stamp=tuple(int(x) for x in CONTRACT['Date'].split('-'))+(0,0,0)
    for edition,paths,manifest in [('prod',runtime,prod),('dev',members,dev)]:
        target=out/('Domenia_'+VERSION+'_'+RELEASE+'_'+edition.upper()+'.zip')
        with zipfile.ZipFile(target,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
            def put(rel,data):
                info=zipfile.ZipInfo(edition+'/'+rel,stamp);info.compress_type=zipfile.ZIP_DEFLATED;info.external_attr=0o100644<<16;z.writestr(info,data)
            for rel in paths:put(rel,read(rel))
            put('wad/package-manifest.json',(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n').encode())
        with zipfile.ZipFile(target) as z:
            require(z.testzip() is None,'Corrupted archive '+target.name)
            m=json.loads(z.read(edition+'/wad/package-manifest.json'))
            actual={p[len(edition)+1:] for p in z.namelist()}
            require(actual=={e['Path'] for e in m['Files']}|{'wad/package-manifest.json'},'Archive members differ from manifest: '+target.name)
            for e in m['Files']:require(digest(z.read(edition+'/'+e['Path']))==e['Sha256'],'Archive hash differs: '+e['Path'])
            if edition=='prod':require({n.split('/')[1] for n in z.namelist()}=={'Domenia.exe','wad'},'PROD root must be Domenia.exe and wad')
        result[edition]={'Archive':target.name,'Bytes':target.stat().st_size,'Sha256':digest(target.read_bytes()),'Files':len(manifest['Files']),'ZipIntegrity':True,'ManifestValid':True}
    with zipfile.ZipFile(out/result['prod']['Archive']) as a,zipfile.ZipFile(out/result['dev']['Archive']) as b:
        for rel in runtime:require(a.read('prod/'+rel)==b.read('dev/'+rel),'PROD and DEV runtime differ: '+rel)
    result['IdenticalRuntimeFiles']=len(runtime)
    # D009: offline integrity gate on the exact archives. Publication still requires the Windows report
    # linked to the archive hash (release_guard.py --require-windows --windows-report ...).
    guard_archives(out,result,windows_report,require_windows,evidence_dir)
    result['Build']=BUILD
    result['Environment']=environment()
    result['Components']=component_inventory(runtime,read)
    result['SignedStage']=str(stage) if stage is not None else ''
    result['PublicationRule']='Publiable uniquement avec un rapport Windows PowerShell 5.1 lie au SHA-256 des deux ZIP (release_guard.py --require-windows).'
    writejson(out/'build-report.json',result)
    return result

if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--output',type=Path,required=True);ap.add_argument('--manifest-only',action='store_true')
    ap.add_argument('--windows-report',type=Path,help='Rapport de qualification Windows PowerShell 5.1 (qualification-report.json).')
    ap.add_argument('--require-windows',action='store_true',help='Refuser la construction sans rapport Windows lie aux deux archives.')
    ap.add_argument('--evidence-dir',type=Path,help='Dossier des preuves de la campagne, recalculees par le garde.')
    ap.add_argument('--signed-stage',type=Path,help='Copie signee par tools/Signer-Distribution.ps1 (D116).')
    a=ap.parse_args()
    if a.require_windows and not a.windows_report:ap.error('--require-windows exige --windows-report')
    print(json.dumps(build(a.output,a.manifest_only,a.windows_report,a.require_windows,a.evidence_dir,a.signed_stage),indent=2))
