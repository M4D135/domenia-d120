#!/usr/bin/env python3
"""Development only: review changed operations, then explicitly refresh their source hashes.
The running application NEVER calls this tool. It is not a bypass for a bad downloaded pack.
"""
from pathlib import Path
import argparse, functools, hashlib, json, re, sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'wad/tests'))
from powershell_lex import functions as raw_functions
functions=functools.lru_cache(64)(raw_functions)
def function(source,name):
    spans=functions(source).get(name,[])
    if len(spans)!=1:raise ValueError('Ambiguous/missing function '+name)
    a,b=spans[0];return source[a:b]
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--apply',action='store_true',help='Write reviewed hashes; otherwise show differences only');a=p.parse_args()
    meta_path=ROOT/'tools/operation-contracts.json';items=json.loads(meta_path.read_text());core_path=ROOT/'wad/Domenia-Core.ps1';core=core_path.read_text('utf-8-sig');getter=function(core,'Get-DomeniaWorkerOperationHashes');old=getter;changes=[]
    registered=dict(re.findall(r'(\w+)\s*=\s*"([0-9A-F]{64})"',getter))
    if set(registered)!={i['Operation'] for i in items}:raise ValueError('Operation list differs: audit contract metadata manually first.')
    for item in items:
        path=ROOT/item['File'];source=path.read_text('utf-8-sig');fn=function(source,item['Function'])
        literals=[m[2] for m in re.finditer(r'@([\'"])\n(.*?)\n^\1@',fn,re.M|re.S)];body=literals[item['LiteralIndex']]
        h=hashlib.sha256(body.encode('utf-8')).hexdigest().upper()
        if h!=registered[item['Operation']]:changes.append(item['Operation'])
        getter=re.sub(r'(\b'+re.escape(item['Operation'])+r'\s*=\s*")[A-F0-9]{64}(\")',lambda m:m[1]+h+m[2],getter)
        item['Sha256']=h
    fingerprint=hashlib.sha256('\n'.join(i['Operation']+'='+i['Sha256'] for i in sorted(items,key=lambda x:x['Operation'])).encode()).hexdigest().upper()
    validation=function(core,'Assert-DomeniaWorkerRegistry')
    updated_validation=re.sub(r'(\$expectedFingerprint\s*=\s*")[A-F0-9]{64}(")',lambda m:m[1]+fingerprint+m[2],validation)
    if validation!=updated_validation:changes.append('RegistryFingerprint')
    if a.apply:
        core_path.write_text(core.replace(old,getter,1).replace(validation,updated_validation,1),encoding='utf-8-sig')
        meta_path.write_text(json.dumps(items,indent=2)+'\n')
    print(json.dumps({'ReviewedChangesRequired':changes,'Applied':a.apply,'Count':len(items)},indent=2))
    return 0 if a.apply or not changes else 1
if __name__=='__main__':sys.exit(main())
