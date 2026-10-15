#!/usr/bin/env python3
"""Development only: review changed operations, then explicitly refresh their source hashes.
The running application NEVER calls this tool. It is not a bypass for a bad downloaded pack.

CD-14: --add OP FUNCTION [--file wad/...] [--literal-index N] declares a new pinned operation and --remove OP withdraws
one. Both update the three places together (tools/operation-contracts.json, Get-DomeniaWorkerOperationHashes and the
registry fingerprint of Assert-DomeniaWorkerRegistry), print the diff, and write nothing without --apply.
P-CD-07: every pinned operation is also classified on one line of Get-DomeniaOperationTable (Domenia-Engine.Model.ps1,
Worker column Pinned), and only those: the report lists any difference under OperationTable and the exit code is 1.
"""
from pathlib import Path
import argparse, difflib, functools, hashlib, json, re, sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'wad/tests'))
from powershell_lex import functions as raw_functions
functions=functools.lru_cache(64)(raw_functions)
OPERATION=re.compile(r'[A-Za-z][A-Za-z0-9]{2,63}')
def function(source,name):
    spans=functions(source).get(name,[])
    if len(spans)!=1:raise ValueError('Ambiguous/missing function '+name)
    a,b=spans[0];return source[a:b]
def literal_bodies(fn):
    return [m[2] for m in re.finditer(r'@([\'"])\n(.*?)\n^\1@',fn,re.M|re.S)]
# P-CD-08: operations whose generator composes the shared SQLite layer of the workers (Get-DomeniaSqliteWorkerCommon,
# Domenia-Storage.Worker.ps1), with the lease code in front of it when they write.
SQLITE_WITH_LEASE=('StorageUsage','StoragePurge','StorageBackup','StorageMaintenance','LiveCache','LegacyMigration')
SQLITE_READ_ONLY=('LocalIndexRead','RelationHistoryRead')
def sqlite_common():
    storage=(ROOT/'wad/modules/Domenia-Storage.Worker.ps1').read_text('utf-8-sig')
    return literal_bodies(function(storage,'Get-DomeniaSqliteWorkerCommon'))[0]
def composed_body(item):
    """Mirror the closed generators from reviewed source; never run application code or user data."""
    source=(ROOT/item['File']).read_text('utf-8-sig')
    fn=function(source,item['Function'])
    literal=literal_bodies(fn)[item['LiteralIndex']]
    operation=item['Operation']
    lease=(ROOT/'wad/modules/Domenia-StorageLease.Model.ps1').read_text('utf-8-sig')
    sqlite=sqlite_common()
    if operation=='LocalStore':
        definitions=[]
        for name in ['Common.Model','HealthRules.Model','Boards.Model','Probes.Model','Query.Model','QueryLibrary.Model']:
            text=(ROOT/('wad/modules/Domenia-'+name+'.ps1')).read_text('utf-8-sig')
            spans=sorted(span for group in functions(text).values() for span in group)
            definitions.extend(text[a:b] for a,b in spans)
        model=(ROOT/'wad/modules/Domenia-QueryLibrary.Model.ps1').read_text('utf-8-sig')
        definitions.append(literal_bodies(function(model,'Get-DomeniaQueryLibraryDefinitionValidationCode'))[0])
        return lease+'\n'+sqlite+'\n'+'\n'.join(definitions)+'\n'+literal
    if operation in SQLITE_WITH_LEASE:
        return lease+'\n'+sqlite+'\n'+literal
    if operation in SQLITE_READ_ONLY:
        return sqlite+'\n'+literal
    # W06: two storage operations reuse the pinned helpers of another storage worker, exactly as their generators do.
    if operation=='StorageRetention':
        purge=function((ROOT/'wad/modules/Domenia-Storage.Worker.ps1').read_text('utf-8-sig'),'Get-DomeniaStoragePurgeWorkerCode')
        body=lease+'\n'+sqlite+'\n'+literal_bodies(purge)[0]
        marker='# Validate all input before opening the existing database. No payload identifier becomes SQL.'
        return body[:body.index(marker)]+literal
    if operation=='StorageIntegrity':
        usage=function((ROOT/'wad/modules/Domenia-Storage.Worker.ps1').read_text('utf-8-sig'),'Get-DomeniaStorageUsageWorkerCode')
        body=lease+'\n'+sqlite+'\n'+literal_bodies(usage)[0]
        marker='$path=Test-DomeniaStorageMeasurePath ([string]$Payload.Path)'
        return body[:body.index(marker)]+literal
    if item['Function']=='Get-DomeniaLiveProbeCode':
        model=(ROOT/'wad/modules/Domenia-ProbeDetails.Model.ps1').read_text('utf-8-sig')
        definitions=[]
        for name in ['ConvertTo-DomeniaProbeDetailValue','ConvertTo-DomeniaProbeDetailInstance','New-DomeniaProbeDetailProjection']:
            body=function(model,name)
            definition=body[body.index('{')+1:body.rfind('}')]
            definitions.append('function '+name+' {\n'+definition+'\n}')
        return '\n'.join(definitions)+'\n'+literal
    return literal

def locate(name,file=None):
    """Repository-relative file that defines the function exactly once (core or a module)."""
    candidates=[ROOT/file] if file else [ROOT/'wad/Domenia-Core.ps1']+sorted((ROOT/'wad/modules').glob('*.ps1'))
    found=[p for p in candidates if p.is_file() and len(functions(p.read_text('utf-8-sig')).get(name,[]))==1]
    if len(found)!=1:raise ValueError('Fonction introuvable ou definie dans plusieurs fichiers : '+name)
    return found[0].relative_to(ROOT).as_posix()
def add_operation(items,getter,name,fn_name,file,index):
    if not OPERATION.fullmatch(name):raise ValueError('Nom d operation invalide : '+name)
    if name in {i['Operation'] for i in items} or re.search(r'(?m)^\s*'+re.escape(name)+r'\s*=',getter):
        raise ValueError('Operation deja declaree : '+name)
    rel=locate(fn_name,file)
    bodies=literal_bodies(function((ROOT/rel).read_text('utf-8-sig'),fn_name))
    if not 0<=index<len(bodies):raise ValueError('Here-string %d absente de %s' % (index,fn_name))
    items.append({'Operation':name,'File':rel,'Function':fn_name,'LiteralIndex':index,'Sha256':'0'*64})
    lines=list(re.finditer(r'(?m)^([ \t]+)\w+\s*=\s*"[0-9A-F]{64}"[ \t]*$',getter))
    if not lines:raise ValueError('Registre Get-DomeniaWorkerOperationHashes illisible.')
    last=lines[-1];indent=lines[0].group(1)
    return getter[:last.end()]+'\n'+indent+'%-21s = "%s"' % (name,'0'*64)+getter[last.end():]
def remove_operation(items,getter,name):
    kept=[i for i in items if i['Operation']!=name]
    if len(kept)==len(items):raise ValueError('Operation inconnue du contrat : '+name)
    updated,count=re.subn(r'(?m)^[ \t]+'+re.escape(name)+r'\s*=\s*"[0-9A-F]{64}"[ \t]*\n','',getter)
    if count!=1:raise ValueError('Operation absente du registre ou dupliquee : '+name)
    items[:]=kept
    return updated
def operation_table_problems(items):
    """P-CD-07: the Pinned lines of the operation table and the contract name the same operations, once each."""
    model=(ROOT/'wad/modules/Domenia-Engine.Model.ps1').read_text('utf-8-sig')
    table=literal_bodies(function(model,'Get-DomeniaOperationTable'))[0]
    rows=[[c.strip() for c in line.split('#',1)[0].split('|')] for line in table.split('\n') if line.split('#',1)[0].strip()]
    problems=['Ligne illisible : '+'|'.join(r) for r in rows if len(r)!=8]
    pinned=[r[0] for r in rows if len(r)==8 and r[1]=='Pinned']
    unpinned=[r[0] for r in rows if len(r)==8 and r[1]!='Pinned']
    contract=[i['Operation'] for i in items]
    problems+=['Declaree deux fois : '+n for n in sorted({n for n in pinned+unpinned if (pinned+unpinned).count(n)>1})]
    problems+=['Operation epinglee sans ligne Pinned : '+n for n in sorted(set(contract)-set(pinned))]
    problems+=['Ligne Pinned sans operation epinglee : '+n for n in sorted(set(pinned)-set(contract))]
    return problems
def unified(before,after,label):
    return ''.join(difflib.unified_diff(before.splitlines(True),after.splitlines(True),'a/'+label,'b/'+label,n=1))
def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--apply',action='store_true',help='Write reviewed hashes; otherwise show differences only')
    p.add_argument('--add',nargs=2,metavar=('OP','FUNCTION'),help='Declare a new pinned operation (CD-14).')
    p.add_argument('--file',help='With --add: repository-relative file of FUNCTION when the search is ambiguous.')
    p.add_argument('--literal-index',type=int,default=0,help='With --add: index of the pinned here-string in FUNCTION.')
    p.add_argument('--remove',metavar='OP',help='Withdraw a pinned operation (CD-14).')
    a=p.parse_args(argv)
    if a.add and a.remove:p.error('--add et --remove sont exclusifs.')
    if (a.file or a.literal_index) and not a.add:p.error('--file et --literal-index accompagnent --add.')
    meta_path=ROOT/'tools/operation-contracts.json';meta_text=meta_path.read_text();items=json.loads(meta_text)
    core_path=ROOT/'wad/Domenia-Core.ps1';core=core_path.read_text('utf-8-sig');getter=function(core,'Get-DomeniaWorkerOperationHashes');old=getter;changes=[]
    if a.add:
        getter=add_operation(items,getter,a.add[0],a.add[1],a.file,a.literal_index);changes.append('Added:'+a.add[0])
    if a.remove:
        getter=remove_operation(items,getter,a.remove);changes.append('Removed:'+a.remove)
    registered=dict(re.findall(r'(\w+)\s*=\s*"([0-9A-F]{64})"',getter))
    if set(registered)!={i['Operation'] for i in items}:raise ValueError('Operation list differs: audit contract metadata manually first (or use --add / --remove).')
    for item in items:
        path=ROOT/item['File'];source=path.read_text('utf-8-sig');fn=function(source,item['Function'])
        body=composed_body(item)
        h=hashlib.sha256(body.encode('utf-8')).hexdigest().upper()
        if h!=registered[item['Operation']] and item['Operation'] not in (a.add or [])[:1]:changes.append(item['Operation'])
        getter=re.sub(r'(\b'+re.escape(item['Operation'])+r'\s*=\s*")[A-F0-9]{64}(\")',lambda m:m[1]+h+m[2],getter)
        item['Sha256']=h
    fingerprint=hashlib.sha256('\n'.join(i['Operation']+'='+i['Sha256'] for i in sorted(items,key=lambda x:x['Operation'])).encode()).hexdigest().upper()
    validation=function(core,'Assert-DomeniaWorkerRegistry')
    updated_validation=re.sub(r'(\$expectedFingerprint\s*=\s*")[A-F0-9]{64}(")',lambda m:m[1]+fingerprint+m[2],validation)
    if validation!=updated_validation:changes.append('RegistryFingerprint')
    new_core=core.replace(old,getter,1).replace(validation,updated_validation,1)
    new_meta=json.dumps(items,indent=2)+'\n'
    if a.add or a.remove:
        # CD-14: the reviewer sees the three places before anything is written.
        sys.stderr.write(unified(meta_text,new_meta,'tools/operation-contracts.json')+unified(core,new_core,'wad/Domenia-Core.ps1'))
    if a.apply:
        core_path.write_text(new_core,encoding='utf-8-sig')
        meta_path.write_text(new_meta)
    table=operation_table_problems(items)
    report={'ReviewedChangesRequired':changes,'Applied':a.apply,'Count':len(items)}
    if table:report['OperationTable']=table
    print(json.dumps(report,indent=2))
    if table:return 1
    return 0 if a.apply or not changes else 1
if __name__=='__main__':
    try:sys.exit(main())
    except ValueError as error:
        sys.stderr.write('Refus : '+str(error)+'\n');sys.exit(2)
