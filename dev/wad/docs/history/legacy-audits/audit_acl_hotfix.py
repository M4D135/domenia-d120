#!/usr/bin/env python3
"""RC1.1: source, contract and packaging regression checks. No Windows execution."""
from pathlib import Path
import argparse, difflib, functools, hashlib, json, re, sys, zipfile
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from audit_candidate import balanced, getfunc, functions, literals

def sha(x): return hashlib.sha256(x.encode('utf-8') if isinstance(x,str) else x).hexdigest().upper()
def read(rel): return (ROOT/rel).read_text('utf-8-sig')
def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--baseline-dev',type=Path,required=True)
    ap.add_argument('--report',type=Path,required=True)
    a=ap.parse_args();checks=[]
    def ck(name,condition):
        try:
            ok=condition() if callable(condition) else condition
            assert ok is None or bool(ok),name
            checks.append(dict(Name=name,Passed=True))
        except Exception as exc:checks.append(dict(Name=name,Passed=False,Error=str(exc)))
    with zipfile.ZipFile(a.baseline_dev) as z:
        ck('Original DEV archive CRC',z.testzip() is None)
        baseline={n[4:]:z.read(n) for n in z.namelist() if n.startswith('dev/') and not n.endswith('/')}
    oldcore=baseline['wad/Domenia-Core.ps1'].decode('utf-8-sig').replace('\r\n','\n')
    core=read('wad/Domenia-Core.ps1')
    oldreceipt=baseline['wad/modules/Domenia-Receipts.Worker.ps1'].decode('utf-8-sig').replace('\r\n','\n')
    receipt=read('wad/modules/Domenia-Receipts.Worker.ps1')
    common=lambda s:'\n'.join(re.findall(r"(?ms)^\$script:WorkerCommon (?:=|\+=) @'\n(.*?)\n'@",s))
    sites={
      'DataStore':getfunc(core,'Initialize-DomeniaDataStore'),
      'Receipts':getfunc(literals(getfunc(receipt,'Get-DomeniaReceiptsCommon'))[0],'Get-WReceiptRoot'),
      'Remote':getfunc(common(core),'Invoke-WRemoteScheduledTaskScript')}
    oldsites={
      'DataStore':getfunc(oldcore,'Initialize-DomeniaDataStore'),
      'Receipts':getfunc(literals(getfunc(oldreceipt,'Get-DomeniaReceiptsCommon'))[0],'Get-WReceiptRoot'),
      'Remote':getfunc(common(oldcore),'Invoke-WRemoteScheduledTaskScript')}
    for site,text in sites.items():
        ck(site+': one SDDL call',text.count('.SetSecurityDescriptorSddlForm(')==1)
        expr=re.search(r'\$acl\.SetSecurityDescriptorSddlForm\(\n(.*?)\n\s*\)',text,re.S)
        ck(site+': explicit Access-only overload',expr is not None and re.search(r',\s*\[Security.AccessControl.AccessControlSections\]::Access\s*$',expr[1]) is not None)
        call=expr[1] if expr else ''
        ck(site+': no Owner Group or Audit in SDDL',"'D:P(" in call and not re.search(r"'[OGS]:|AccessControlSections\]::(?:Audit|All|Owner|Group)",call))
        expected="D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)" if site=='Remote' else "D:P(A;OICI;FA;;;'+$sid+')(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
        ck(site+': original restrictive DACL retained',expected in call and expected in oldsites[site])
        ck(site+': persistence kept',('Set-Acl -LiteralPath $privateFolder' if site=='Remote' else '[IO.Directory]::SetAccessControl') in text)
        ck(site+': no token privilege adjustment','AdjustTokenPrivileges' not in text and 'SeTakeOwnershipPrivilege' not in text)
    ck('Only three runtime SDDL initializations',sum(s.count('SetSecurityDescriptorSddlForm(') for s in [core,receipt])==3)
    ck('Store failure remains fatal with native inner exception',"DOMENIA_STORE_DACL" in sites['DataStore'] and 'throw [InvalidOperationException]::new(' in sites['DataStore'] and '$_.Exception\n' in sites['DataStore'])
    ck('Receipts failure remains fatal with native inner exception',"DOMENIA_RECEIPT_DACL" in sites['Receipts'] and 'throw [InvalidOperationException]::new(' in sites['Receipts'])
    ck('Store validated only after protection',sites['DataStore'].index('SetAccessControl')<sites['DataStore'].index('$script:DataStoreValidated=$true'))
    ck('Store reparse checks retained','[IO.FileAttributes]::ReparsePoint' in sites['DataStore'])
    ck('Receipts reparse checks retained','[IO.FileAttributes]::ReparsePoint' in sites['Receipts'])
    ck('Network data store guard retained','[IO.DriveType]::Network' in sites['DataStore'])
    ck('Remote consent retained','Assert-WRemoteArtifactPermission' in sites['Remote'])
    oldfunc=functions(oldcore);newfunc=functions(core)
    ck('Same top-level function names',set(oldfunc)==set(newfunc))
    changed=[n for n in oldfunc if getfunc(oldcore,n)!=getfunc(core,n)]
    ck('Only startup-storage and display-build functions changed',set(changed)<={'Initialize-DomeniaDataStore','Initialize-DomeniaPresentation'})
    sensitive=['Invoke-DomeniaInProcessAuthProbe','Start-DomeniaFastLoginAttempt','Start-DomeniaLoginAuthRunspace','Invoke-GlobalSearch','Assert-DomeniaCapability','Get-DomeniaWorkerOperationHashes','Show-AdObjectResult']
    for n in sensitive:ck('Preserved function: '+n,getfunc(oldcore,n)==getfunc(core,n))
    oldcommon=common(oldcore);newcommon=common(core)
    wchanged=[n for n in functions(oldcommon) if getfunc(oldcommon,n)!=getfunc(newcommon,n)]
    ck('Only remote-staging helper changed in WorkerCommon',wchanged==['Invoke-WRemoteScheduledTaskScript'])
    contracts=json.loads(read('tools/operation-contracts.json'))
    ck('54 operation definitions preserved',len(contracts)==54 and (ROOT/'tools/operation-contracts.json').read_bytes()==baseline['tools/operation-contracts.json'])
    runtime=json.loads(baseline['wad/package-manifest.json'])['Files']
    changedruntime=[]
    for e in runtime:
        if not e.get('Runtime'):continue
        rel=e['Path']
        if (ROOT/rel).read_bytes()!=baseline[rel]:changedruntime.append(rel)
    ck('Only two runtime source files changed',set(changedruntime)=={'wad/Domenia-Core.ps1','wad/modules/Domenia-Receipts.Worker.ps1'})
    ck('Compiled launcher unchanged',(ROOT/'Domenia.exe').read_bytes()==baseline['Domenia.exe'])
    ck('Support unblock script unchanged',(ROOT/'wad/Support/DEBLOQUER_TOUT.cmd').read_bytes()==baseline['wad/Support/DEBLOQUER_TOUT.cmd'])
    for rel in ['wad/Domenia-Core.ps1','wad/modules/Domenia-Receipts.Worker.ps1','wad/tests/Test-DomeniaAcl.ps1','INSTALLER-MISE-A-JOUR.ps1']:
        ck('Lexical check (not native parser): '+rel,lambda rel=rel:balanced(read(rel)))
    ck('WorkerCommon lexical check (not native parser)',lambda:balanced(newcommon))
    test=read('wad/tests/Test-DomeniaAcl.ps1')
    for token in ['ParseInput','Find-AclCall','_saclModified','_ownerModified','_groupModified','SetAccessControl','Get-WReceiptRoot','AclFixtureOwned','LiveSaclReadOrWrite=$false']:
        ck('Windows regression suite contains: '+token,token in test)
    ck('New Windows suite invoked before installer copies code',"@('Test-DomeniaCandidate.ps1','Test-DomeniaAcl.ps1')" in read('INSTALLER-MISE-A-JOUR.ps1'))
    ck('PROD includes no test dependency',read('wad/Domenia-Start.ps1')==baseline['wad/Domenia-Start.ps1'].decode('utf-8-sig').replace('\r\n','\n'))
    (ROOT/'wad/docs/RC1.1-ACL.patch').write_text(''.join(difflib.unified_diff(oldcore.splitlines(True),core.splitlines(True),fromfile='RC1/wad/Domenia-Core.ps1',tofile='RC1.1/wad/Domenia-Core.ps1'))+''.join(difflib.unified_diff(oldreceipt.splitlines(True),receipt.splitlines(True),fromfile='RC1/wad/modules/Domenia-Receipts.Worker.ps1',tofile='RC1.1/wad/modules/Domenia-Receipts.Worker.ps1')),encoding='utf-8')
    result=dict(Build='2026.10.01-DOMENIA-1.0-RC1.1-ACL',Passed=sum(c['Passed'] for c in checks),Failed=sum(not c['Passed'] for c in checks),Source='RC1 original DEV ZIP',BaselineSha256=sha(a.baseline_dev.read_bytes()),ChangedRuntime=changedruntime,ChangedCoreFunctions=changed,ChangedWorkerHelpers=wchanged,WindowsPowerShellExecuted=False,WpfExecuted=False,NativeACLExecuted=False,Checks=checks)
    a.report.parent.mkdir(parents=True,exist_ok=True);a.report.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in result.items() if k!='Checks'},indent=2))
    for c in checks:
        if not c['Passed']:print('FAIL',c['Name'],c.get('Error',''))
    return 1 if result['Failed'] else 0
if __name__=='__main__':sys.exit(main())
