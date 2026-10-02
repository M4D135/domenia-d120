"""Offline archive integrity and Windows evidence gate. No executable is launched.
A matching hash is not an Authenticode signature or a proof of publisher identity.
"""
from __future__ import annotations
import argparse, hashlib, json, re, stat, sys, zipfile
from pathlib import Path, PurePosixPath

class GateError(ValueError): pass
REQUIRED = ('parser.ps51','runtime.modules','worker.contracts','startup.exe_login_main',
            'ui.actual_events','ui.layout_profiles','data.sqlite','security.secret_markers',
            'race.selection','prod.standalone')
MAX_FILE=64*1024*1024
MAX_TOTAL=256*1024*1024

def sha(data:bytes)->str: return hashlib.sha256(data).hexdigest()
def canonical(name:str)->str:
    if not isinstance(name,str) or not name or '\\' in name or '\x00' in name:
        raise GateError('Nom de fichier invalide')
    p=PurePosixPath(name)
    if p.is_absolute() or any(s in ('','..','.') for s in name.rstrip('/').split('/')):
        raise GateError('Chemin absolu ou relatif ambigu interdit: '+name)
    for s in p.parts:
        stem=s.split('.')[0].upper()
        if ':' in s or s.endswith((' ','.')) or stem in {'CON','PRN','AUX','NUL',*(f'COM{i}' for i in range(1,10)),*(f'LPT{i}' for i in range(1,10))}:
            raise GateError('Chemin Windows non sur: '+name)
    return name.rstrip('/')

def inspect_archive(path:Path)->dict:
    if not path.is_file(): raise GateError('Archive absente: '+str(path))
    with zipfile.ZipFile(path) as z:
        entries=z.infolist()
        if not entries or len(entries)>5000: raise GateError('Nombre de fichiers hors limites')
        if sum(e.file_size for e in entries)>MAX_TOTAL: raise GateError('Archive trop volumineuse')
        seen=set(); data={}
        for e in entries:
            n=canonical(e.filename)
            if n.casefold() in seen: raise GateError('Chemins Windows dupliques: '+n)
            seen.add(n.casefold())
            if stat.S_ISLNK(e.external_attr>>16): raise GateError('Lien archive interdit')
            if e.flag_bits&1: raise GateError('Archive chiffree non prise en charge')
            if e.file_size>MAX_FILE: raise GateError('Fichier trop volumineux')
            if not e.is_dir(): data[n]=z.read(e)
        ms=[n for n in data if n.endswith('/wad/package-manifest.json')]
        if len(ms)!=1: raise GateError('Un manifeste unique est requis')
        mn=ms[0];prefix=mn[:-len('wad/package-manifest.json')]
        if prefix not in ('prod/','dev/'): raise GateError('Racine prod ou dev requise')
        if any(not n.startswith(prefix) for n in data): raise GateError('Fichier hors racine')
        if len(data[mn])>2*1024*1024: raise GateError('Manifeste trop volumineux')
        manifest=json.loads(data[mn].decode('utf-8-sig'))
        fs=manifest.get('Files')
        if not isinstance(fs,list) or not fs: raise GateError('Liste de fichiers absente')
        declared=set();runtime={};mutable=[]
        for item in fs:
            rel=canonical(item.get('Path',''));n=prefix+rel
            if rel.casefold() in declared: raise GateError('Entree dupliquee du manifeste')
            declared.add(rel.casefold())
            if n not in data: raise GateError('Fichier absent: '+rel)
            h=str(item.get('Sha256','')).lower()
            if not re.fullmatch('[0-9a-f]{64}',h) or sha(data[n])!=h: raise GateError('Empreinte differente: '+rel)
            if type(item.get('Bytes')) is not int or item['Bytes']!=len(data[n]): raise GateError('Taille differente: '+rel)
            if item.get('Runtime') is True:runtime[rel]=h
            if item.get('PreserveExisting') is True:mutable.append(rel)
        actual={n[len(prefix):].casefold() for n in data if n!=mn}
        if actual!=declared: raise GateError('Fichiers non declares ou manquants')
        root={n[len(prefix):].split('/')[0] for n in data}
        if prefix=='prod/' and root!={'Domenia.exe','wad'}:raise GateError('PROD doit contenir uniquement Domenia.exe et wad')
        if prefix+'wad/Support/DEBLOQUER_TOUT.cmd' not in data:raise GateError('Deblocage absent de wad/Support')
        if not runtime:raise GateError('Liste runtime absente')
        if prefix=='prod/' and any(re.search(r'(^|/)(tests|test|tools|docs|demo)(/|$)',n,re.I) or re.search(r'(^|/)(TESTER|APERCU|DEMO)[-_]',n,re.I) for n in runtime):
            raise GateError('Un outil de developpement est requis par PROD')
    return {'Archive':path.name,'SHA256':sha(path.read_bytes()),'Edition':prefix.rstrip('/'),
            'Files':len(fs),'Runtime':runtime,'MutableFiles':mutable,'Integrity':'PASS',
            'Authenticity':'NOT_VERIFIED','WindowsQualification':'NOT_EVALUATED'}

def require_evidence(info:dict,report:dict)->dict:
    if report.get('ArchiveSHA256','').lower()!=info['SHA256']:raise GateError('Rapport non lie au ZIP final')
    host=report.get('Host',{})
    if host.get('Platform')!='Windows' or host.get('PSEdition')!='Desktop' or not str(host.get('PSVersion','')).startswith('5.1.'):
        raise GateError('Preuve Windows PowerShell 5.1 requise')
    if report.get('OverallStatus')!='PASS':raise GateError('Campagne inachevee ou en echec')
    records=report.get('Scenarios',[])
    ids=[r.get('Id') for r in records]
    if len(ids)!=len(set(ids)):raise GateError('Scenario de preuve duplique')
    by={r.get('Id'):r for r in records}
    for sid in REQUIRED:
        r=by.get(sid)
        if not r or r.get('Status')!='PASS' or r.get('Executed') is not True:
            raise GateError('Scenario requis absent/non execute/en echec: '+sid)
        if not r.get('StartedUtc') or not r.get('EndedUtc'):raise GateError('Horodatage de test absent: '+sid)
        if not r.get('EvidenceSHA256') or not re.fullmatch('[0-9a-fA-F]{64}',str(r['EvidenceSHA256'])):
            raise GateError('Empreinte de preuve absente: '+sid)
    info=dict(info);info['WindowsQualification']='PASS_REPORTED';info['TrustNote']='Rapport local non signe: ne prouve ni origine ni authenticite.'
    return info

def main()->int:
    p=argparse.ArgumentParser();p.add_argument('archive',type=Path);p.add_argument('--windows-report',type=Path);p.add_argument('--require-windows',action='store_true');p.add_argument('--out',type=Path)
    a=p.parse_args()
    try:
        r=inspect_archive(a.archive)
        if a.require_windows and not a.windows_report:raise GateError('Publication refusee: preuve Windows manquante')
        if a.windows_report:r=require_evidence(r,json.loads(a.windows_report.read_text(encoding='utf-8-sig')))
        r.pop('Runtime',None)
        text=json.dumps(r,ensure_ascii=False,indent=2)
        if a.out:a.out.write_text(text+'\n',encoding='utf-8')
        print(text);return 0
    except (GateError,OSError,ValueError,zipfile.BadZipFile,KeyError) as e:
        print(json.dumps({'Status':'FAIL','Reason':str(e)},ensure_ascii=False),file=sys.stderr);return 2
if __name__=='__main__':raise SystemExit(main())
