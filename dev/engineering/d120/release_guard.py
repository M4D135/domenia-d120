"""Offline archive integrity and Windows evidence gate. No executable is launched.
A matching hash is not an Authenticode signature or a proof of publisher identity.

Fail closed: any malformed archive, manifest or report gives a JSON refusal on stderr and exit code 2, never a
Python trace. A report is accepted only when it is bound to the exact archive bytes (SHA-256) and, for a campaign
covering both editions, to the DEV and the PROD archive (Archives list), with every required scenario executed and
PASS on the archive it names.

D111 decision (lot distribution, 2026-10-02): the demonstration provider is part of the product so that PROD can be
qualified without a domain. It ships in files named wad/modules/Domenia-Demo.* and is enabled only by
Auth.DemoProvider in a local configuration. In PROD the gate therefore refuses only real development tools
(tests, test, tools, docs, engineering and maintenance folders; TESTER-, APERCU- and QUALIFIER- launchers), and
both editions refuse a shipped configuration that enables Auth.DemoProvider.
"""
from __future__ import annotations
import argparse, hashlib, io, json, re, stat, sys, zipfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

class GateError(ValueError): pass
REQUIRED = ('parser.ps51','runtime.modules','worker.contracts','startup.exe_login_main',
            'ui.actual_events','ui.layout_profiles','data.sqlite','security.secret_markers',
            'race.selection','prod.standalone')
STATUSES = ('PASS','FAIL','SKIP','NOT_EXECUTED')
MAX_FILE=64*1024*1024
MAX_TOTAL=256*1024*1024
MAX_REPORT=16*1024*1024
HEX64=re.compile(r'[0-9a-fA-F]{64}')
UTC_TEXT=re.compile(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,7}))?(Z|[+-]\d{2}:\d{2})$')
PROD_DEV_DIRS={'tests','test','tools','docs','engineering','maintenance'}
PROD_DEV_LAUNCHER=re.compile(r'(^|/)(TESTER|APERCU|QUALIFIER)[-_]',re.I)

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

def dev_tool_path(rel:str)->bool:
    """True for a real development tool. A Domenia-Demo.* provider module is not one (D111 decision)."""
    if any(s.lower() in PROD_DEV_DIRS for s in rel.split('/')[:-1]): return True
    return bool(PROD_DEV_LAUNCHER.search(rel))

def demo_enabled(config:bytes)->bool:
    """Auth.DemoProvider read from a shipped configuration. An unreadable configuration is refused."""
    try: data=json.loads(config.decode('utf-8-sig'))
    except (UnicodeDecodeError,ValueError) as e: raise GateError('Configuration livree illisible: '+str(e))
    if not isinstance(data,dict): raise GateError('Configuration livree illisible: objet attendu')
    auth=data.get('Auth')
    if auth is None: return False
    if not isinstance(auth,dict): raise GateError('Configuration livree illisible: section Auth')
    value=auth.get('DemoProvider',False)
    if isinstance(value,str): return value.strip().lower() in ('true','1','yes','oui','on')
    return value is True or (isinstance(value,(int,float)) and not isinstance(value,bool) and value!=0)

def inspect_archive(path:Path)->dict:
    if not path.is_file(): raise GateError('Archive absente: '+str(path))
    # Hash the exact bytes that are inspected (no second read of the file).
    raw=path.read_bytes();digest=sha(raw)
    with zipfile.ZipFile(io.BytesIO(raw)) as z:
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
        try: manifest=json.loads(data[mn].decode('utf-8-sig'))
        except (UnicodeDecodeError,ValueError) as e: raise GateError('Manifeste illisible: '+str(e))
        if not isinstance(manifest,dict): raise GateError('Manifeste illisible: objet attendu')
        fs=manifest.get('Files')
        if not isinstance(fs,list) or not fs: raise GateError('Liste de fichiers absente')
        declared=set();runtime={};mutable=[]
        for item in fs:
            if not isinstance(item,dict): raise GateError('Entree de manifeste invalide')
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
        if prefix=='prod/':
            tools=sorted(n[len(prefix):] for n in data if dev_tool_path(n[len(prefix):]))
            if tools:raise GateError('Un outil de developpement est livre ou requis par PROD: '+tools[0])
        config=prefix+'wad/Domenia.config.json'
        if config in data and demo_enabled(data[config]):
            raise GateError('Configuration livree en mode demonstration (Auth.DemoProvider): refusee')
    build=manifest.get('Build')
    return {'Archive':path.name,'SHA256':digest,'Edition':prefix.rstrip('/'),'Build':build if isinstance(build,str) else '',
            'Files':len(fs),'Runtime':runtime,'MutableFiles':mutable,'Integrity':'PASS',
            'Authenticity':'NOT_VERIFIED','WindowsQualification':'NOT_EVALUATED'}

def _obj(value,what:str)->dict:
    if not isinstance(value,dict): raise GateError(what+' : objet attendu')
    return value
def _text(value,what:str)->str:
    if not isinstance(value,str) or not value: raise GateError(what+' : texte attendu')
    return value
def _hex(value,what:str)->str:
    if not isinstance(value,str) or not HEX64.fullmatch(value): raise GateError(what+' : empreinte SHA-256 attendue')
    return value.lower()
def _utc(value,what:str)->datetime:
    m=UTC_TEXT.match(value) if isinstance(value,str) else None
    if not m: raise GateError('Horodatage de test absent ou illisible: '+what)
    fraction=(m.group(2) or '0')[:6].ljust(6,'0');zone=m.group(3)
    if zone=='Z': zone='+00:00'
    try: return datetime.fromisoformat(m.group(1)+'.'+fraction+zone).astimezone(timezone.utc)
    except ValueError: raise GateError('Horodatage de test illisible: '+what)

def verify_evidence(directory:Path,sid:str,expected:str)->int:
    """Recomputes EvidenceSHA256 from <dir>/<Id>/evidence.sha256 and every file it lists."""
    base=directory/sid
    listing=base/'evidence.sha256'
    if not listing.is_file(): raise GateError('Preuve absente: '+sid)
    raw=listing.read_bytes()
    if sha(raw)!=expected: raise GateError('Preuve modifiee (evidence.sha256): '+sid)
    lines=[l for l in raw.decode('utf-8').split('\n') if l]
    names=[]
    for line in lines:
        m=re.fullmatch(r'([0-9a-f]{64})  (.+)',line)
        if not m: raise GateError('Ligne de preuve illisible: '+sid)
        rel=canonical(m.group(2))
        if rel=='evidence.sha256': raise GateError('La preuve ne peut pas se lister elle-meme: '+sid)
        target=base/rel
        if not target.is_file() or sha(target.read_bytes())!=m.group(1): raise GateError('Fichier de preuve modifie ou absent: '+sid+'/'+rel)
        names.append(rel)
    if names!=sorted(names): raise GateError('Liste de preuve non triee: '+sid)
    if not names: raise GateError('Preuve vide: '+sid)
    return len(names)

def require_evidence(info:dict,report,evidence_dir:Path|None=None)->dict:
    report=_obj(report,'Rapport')
    digest=info['SHA256'];edition=info['Edition']
    archives=report.get('Archives')
    bound={}
    if archives is None:
        top=report.get('ArchiveSHA256')
        if not isinstance(top,str) or top.lower()!=digest:raise GateError('Rapport non lie au ZIP final')
        bound[digest]=edition
    else:
        if not isinstance(archives,list) or not archives:raise GateError('Archives : liste attendue')
        for item in archives:
            item=_obj(item,'Archives[]')
            ed=_text(item.get('Edition'),'Archives[].Edition')
            if ed not in ('dev','prod'):raise GateError('Edition inconnue dans le rapport: '+ed)
            h=_hex(item.get('SHA256'),'Archives[].SHA256')
            if h in bound or ed in bound.values():raise GateError('Archive declaree deux fois dans le rapport')
            end=item.get('SHA256End')
            if end is not None and _hex(end,'Archives[].SHA256End')!=h:raise GateError('Archive modifiee pendant la campagne: '+ed)
            bound[h]=ed
        if set(bound.values())!={'dev','prod'}:raise GateError('Campagne liee aux archives DEV et PROD requise')
        if digest not in bound:raise GateError('Rapport non lie au ZIP final')
        if bound[digest]!=edition:raise GateError('Edition du rapport differente de l archive')
        top=report.get('ArchiveSHA256')
        if top is not None and _hex(top,'ArchiveSHA256') not in bound:raise GateError('ArchiveSHA256 hors des archives du rapport')
    if info.get('Build'):
        if report.get('Build')!=info['Build']:raise GateError('Build du rapport different du manifeste de l archive')
    host=_obj(report.get('Host'),'Host')
    if host.get('Platform')!='Windows' or host.get('PSEdition')!='Desktop' or not str(host.get('PSVersion','')).startswith('5.1.'):
        raise GateError('Preuve Windows PowerShell 5.1 requise')
    if report.get('OverallStatus')!='PASS':raise GateError('Campagne inachevee ou en echec')
    records=report.get('Scenarios')
    if not isinstance(records,list):raise GateError('Scenarios : liste attendue')
    by={}
    for r in records:
        r=_obj(r,'Scenarios[]')
        sid=_text(r.get('Id'),'Scenarios[].Id')
        if sid in by:raise GateError('Scenario de preuve duplique')
        if r.get('Status') not in STATUSES:raise GateError('Statut de scenario inconnu: '+sid)
        by[sid]=r
    verified=0
    for sid in REQUIRED:
        r=by.get(sid)
        if not r or r.get('Status')!='PASS' or r.get('Executed') is not True:
            raise GateError('Scenario requis absent/non execute/en echec: '+sid)
        started=_utc(r.get('StartedUtc'),sid);ended=_utc(r.get('EndedUtc'),sid)
        if ended<started:raise GateError('Horodatage incoherent: '+sid)
        evidence=_hex(r.get('EvidenceSHA256'),'Empreinte de preuve absente: '+sid)
        target=r.get('ArchiveSHA256')
        if archives is not None:
            if target is None:raise GateError('Scenario non lie a une archive: '+sid)
            target=_hex(target,sid+'.ArchiveSHA256')
            if target not in bound:raise GateError('Scenario lie a une archive hors rapport: '+sid)
            if sid=='prod.standalone' and bound[target]!='prod':raise GateError('prod.standalone doit viser l archive PROD')
            declared=r.get('Edition')
            if declared is not None and declared!=bound[target]:raise GateError('Edition du scenario incoherente: '+sid)
        elif target is not None and _hex(target,sid+'.ArchiveSHA256')!=digest:
            raise GateError('Scenario lie a une autre archive: '+sid)
        if evidence_dir is not None:verified+=verify_evidence(evidence_dir,sid,evidence)
    info=dict(info);info['WindowsQualification']='PASS_REPORTED';info['TrustNote']='Rapport local non signe: ne prouve ni origine ni authenticite.'
    info['EvidenceVerified']=evidence_dir is not None
    if evidence_dir is not None:info['EvidenceFiles']=verified
    return info

def main(argv=None)->int:
    p=argparse.ArgumentParser();p.add_argument('archive',type=Path);p.add_argument('--windows-report',type=Path);p.add_argument('--require-windows',action='store_true');p.add_argument('--out',type=Path)
    p.add_argument('--evidence-dir',type=Path,help='Dossier de preuves de la campagne : recalcule EvidenceSHA256 de chaque scenario requis.')
    a=p.parse_args(argv)
    try:
        r=inspect_archive(a.archive)
        if a.require_windows and not a.windows_report:raise GateError('Publication refusee: preuve Windows manquante')
        if a.evidence_dir and not a.windows_report:raise GateError('--evidence-dir exige --windows-report')
        if a.windows_report:
            if a.windows_report.stat().st_size>MAX_REPORT:raise GateError('Rapport trop volumineux')
            r=require_evidence(r,json.loads(a.windows_report.read_text(encoding='utf-8-sig')),a.evidence_dir)
        r.pop('Runtime',None)
        text=json.dumps(r,ensure_ascii=False,indent=2)
        if a.out:a.out.write_text(text+'\n',encoding='utf-8')
        print(text);return 0
    except (GateError,OSError,ValueError,zipfile.BadZipFile,KeyError) as e:
        print(json.dumps({'Status':'FAIL','Reason':str(e)},ensure_ascii=False),file=sys.stderr);return 2
    except Exception as e:  # fail closed on anything unexpected, still as structured JSON
        print(json.dumps({'Status':'FAIL','Reason':'Erreur interne du garde: '+type(e).__name__+': '+str(e)},ensure_ascii=False),file=sys.stderr);return 2
if __name__=='__main__':raise SystemExit(main())
