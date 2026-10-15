#!/usr/bin/env python3
"""R1.7.1 targeted source/XML/hash audit. Does NOT execute PowerShell or LDAP.
Use Test-DomeniaLogin.ps1 for native mocked runtime tests.
Historical R1.4/R1.7 freeze-of-authentication hashes are superseded for this fix;
their historical reports are kept intact and are not claimed as current passes.
"""
from pathlib import Path
import argparse,hashlib,json,re,xml.etree.ElementTree as ET
from powershell_lex import functions,mask_ps

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2])
    ap.add_argument('--baseline',type=Path)
    ap.add_argument('--report',type=Path,default=Path('/tmp/Domenia-login-audit.json'))
    a=ap.parse_args();root=a.root
    source=(root/'wad/Domenia-Core.ps1').read_text(encoding='utf-8-sig'); spans=functions(source)
    def f(name):
        assert len(spans.get(name,[]))==1,name
        start,end=spans[name][0];return source[start:end]
    rows=[]
    def test(name,ok,detail=''):
        rows.append({'Name':name,'Status':'PASS' if ok else 'FAIL','Kind':'StaticSourceOrXml','Detail':detail})
        print(rows[-1]['Status'],name,detail if not ok else '')
    probe=f('Invoke-DomeniaInProcessAuthProbe'); monitor=f('Update-DomeniaFastLoginAttempt')
    install=(root/'INSTALLER-MISE-A-JOUR.ps1').read_text(encoding='utf-8-sig')
    native=(root/'wad/tests/Test-DomeniaLogin.ps1').read_text(encoding='utf-8-sig')
    changes=json.loads((root/'wad/docs/CHANGEMENTS-CONNEXION-R1.7.1.json').read_text())
    test('Only four existing functions declared modified',set(changes['ChangedFunctions'])=={
        'Invoke-DomeniaInProcessAuthProbe','Convert-DomeniaLoginFailureMessage','Update-DomeniaFastLoginAttempt','Get-DomeniaStandardLoginXaml'})
    test('No original function removed',changes['RemovedFunctions']==[])
    test('One UI hint helper added',changes['AddedFunctions']==['Get-DomeniaLoginFailureHint'])
    test('Unique top-level functions',all(len(x)==1 for x in spans.values()))
    for p in sorted(root.rglob('*.ps1')):
        masked,issues=mask_ps(p.read_text(encoding='utf-8-sig'))
        stack=[];bad=[]; pairs={')':'(',']':'[','}':'{'}
        for i,c in enumerate(masked):
            if c in '([{':stack.append((c,i))
            elif c in pairs:
                if not stack or stack[-1][0]!=pairs[c]:bad.append(i)
                else:stack.pop()
        test('Lexical delimiters (not native parsing): '+p.relative_to(root).as_posix(),not issues and not stack and not bad)
    test('Null-indexing fallback removed','catch { $null = $baseAdsi.Properties' not in probe)
    test('ADSI discovery and native bind use PSBase','$discoveryRoot.psbase.NativeObject' in probe and '$baseAdsi.psbase.NativeObject' in probe)
    test('ADSI attributes use guarded collection',all(x in probe for x in (
        '$properties = $Entry.psbase.Properties','if ($null -eq $properties)',
        '$values = $properties[$Name]','if ($null -eq $values -or $values.Count -eq 0)')))
    test('No unguarded discovery double-index','discoveryRoot.Properties[' not in probe)
    test('RefreshCache has no fallback that hides its failure',
        "$Entry.psbase.RefreshCache([string[]]@('distinguishedName'))" in probe and 'DOMENIA_AUTH_METADATA_MISSING' in probe)
    test('One explicit DirectoryEntry constructor and native bind',probe.count('$baseAdsi = New-Object')==1 and probe.count('$nativeBase = $baseAdsi.psbase.NativeObject')==1)
    test('Native bind remains required and null cannot mean success',"DOMENIA_AUTH_NATIVE_NULL : authentification ADSI non confirmee." in probe)
    test('No alternate credential retries after explicit attempt',"if ($explicitBindAttempted -or $category -eq 'Internal')" in probe and '-Attempts ([int]$explicitBindAttempted)' in probe)
    test('DirectoryEntry Secure and Windows Negotiate retained',
        '[System.DirectoryServices.AuthenticationTypes]::Secure' in probe and '[System.DirectoryServices.Protocols.AuthType]::Negotiate' in probe)
    test('PSObject optional flag not indexed unsafely','Request.PSObject.Properties["SelfTestOnly"]' not in probe)
    test('Internal and metadata failures are distinguished',"return 'Internal'" in probe and "return 'Metadata'" in probe)
    test('ErrorId, stage and worker line are preserved',all(x in probe for x in ('ErrorId=$errorId','WorkerLine=$line','Stage=$Stage','CredentialAttempted=$CredentialAttempted')))
    test('Technical log receives diagnostic and original error','LOGIN_DIAGNOSTIC' in monitor and '-Detail $rawMessage' in monitor)
    test('AD access denial is distinct from credentials and network',"return 'AccessDenied'" in probe and "$c -eq 'AccessDenied'" in f('Convert-DomeniaLoginFailureMessage') and 'droits du compte' in f('Get-DomeniaLoginFailureHint'))
    test('Diagnostics refer to the selected DC after explicit bind',"$failureServer = if ($explicitBindAttempted) { [string]$selectedServer }" in probe)
    test('Wrong-credential hint is no longer generic','Corrige les informations ou utilise l autre mode' not in monitor)
    test('Internal-error hint explicitly avoids password verdict','ne prouve pas un mauvais mot de passe' in f('Get-DomeniaLoginFailureHint'))
    test('Negative LDAP code not presented as real LDAP response',
        'if ($code -lt 0) { return "$messageText (ADSI/PowerShell, serveur=$ServerName)" }' in probe)
    xml=re.search(r'@"\n(.*?)\n"@',f('Get-DomeniaStandardLoginXaml'),re.S)[1]
    x=ET.fromstring(xml); ns='{http://schemas.microsoft.com/winfx/2006/xaml}'
    named={e.get(ns+'Name'):e for e in x.iter() if e.get(ns+'Name')}
    parent={c:p for p in x.iter() for c in p}
    def visible_ancestry(e):
        while e is not None:
            if e.get('Visibility') in ('Collapsed','Hidden') or e.get('Height')=='0':return False
            e=parent.get(e)
        return True
    test('Standard login XML parses',x.tag.endswith('Window'))
    test('Open log and copy diagnostics buttons visible',all(visible_ancestry(named[n]) for n in ('BtnLoginLog','BtnCopyLoginDiag')))
    test('Secret reveal overlay hidden until requested',not visible_ancestry(named['LoginPasswordPeek']) and 'TxtLoginPasswordVisible' not in named)
    test('Error and stage wrap instead of being truncated',all(named[n].get('TextWrapping')=='Wrap' and not named[n].get('TextTrimming') for n in ('LblLoginError','LblLoginStage')))
    test('Native tests run before copying code',install.index('-File $loginTests')<install.index('$backupParent='))
    test('Installer stops if native tests fail',"if($LASTEXITCODE -ne 0){throw ('Tests du login en echec." in install)
    test('Native fixture blocks OS domain discovery',"$staticBoundary='[System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()'" in native and "throw 'TEST ONLY: OS domain discovery disabled.'" in native)
    test('Native fixture blocks unmocked DS constructors',"if ($TypeName -like 'System.DirectoryServices.*')" in native)
    test('Native scenarios include old masking, new preservation, bad credentials and MTA',all(x in native for x in ('R1.7 simulee : erreur de refresh masquee','R1.7.1 simulee : vraie erreur de refresh conservee','Refus reel du mot de passe','Transport MTA reel')))
    for path,digest in changes['PreservedFiles'].items():
        test('Unchanged bytes: '+path,hashlib.sha256((root/path).read_bytes()).hexdigest()==digest)
    baseline_checked=False
    if a.baseline:
        old=(a.baseline/'wad/Domenia-Core.ps1').read_text(encoding='utf-8-sig'); oldsp=functions(old)
        dif=[];removed=[]
        for n,pos in oldsp.items():
            if n not in spans:removed.append(n);continue
            aa,bb=pos[0]
            if old[aa:bb]!=f(n):dif.append(n)
        test('Actual diff limited to approved functions',set(dif)==set(changes['ChangedFunctions']) and not removed,str(dif))
        test('All 562 other original core functions exact match',len(oldsp)-len(dif)==562)
        baseline_checked=True
    count=len(re.findall(r'^Test-LoginCase ',native,re.M))
    report=dict(Build='2026.09.22-R1.7.1-LOGIN',PowerShellExecuted=False,WpfExecuted=False,LiveDirectoryExecuted=False,
        NativeScenariosProvidedNotExecuted=count,BaselineCompared=baseline_checked,
        CoreSha256=hashlib.sha256((root/'wad/Domenia-Core.ps1').read_bytes()).hexdigest(),
        Passed=sum(t['Status']=='PASS' for t in rows),Failed=sum(t['Status']=='FAIL' for t in rows),Checks=rows)
    a.report.parent.mkdir(parents=True,exist_ok=True)
    a.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:report[k] for k in ('Passed','Failed','NativeScenariosProvidedNotExecuted')}))
    return int(report['Failed']>0)
if __name__=='__main__':raise SystemExit(main())
