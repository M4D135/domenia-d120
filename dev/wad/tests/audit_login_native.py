#!/usr/bin/env python3
"""R1.7.2: source / XML / hash checks only. Does not run PowerShell, WPF or AD.
The 47 actual PowerShell scenarios are supplied in Test-DomeniaLogin.ps1.
Historical audit_login.py validates R1.7.1 and is not a current-version audit.
"""
from pathlib import Path
import argparse, hashlib, json, re, xml.etree.ElementTree as ET
from powershell_lex import functions, mask_ps


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2])
    ap.add_argument('--report',type=Path,default=Path('/tmp/Domenia-login-native-audit.json'))
    args=ap.parse_args(); root=args.root.resolve()
    source=(root/'wad/Domenia-Core.ps1').read_text(encoding='utf-8-sig')
    spans=functions(source)
    changes=json.loads((root/'wad/docs/CHANGEMENTS-CONNEXION-R1.7.2.json').read_text(encoding='utf-8'))
    checks=[]
    def check(name,condition,detail=''):
        checks.append(dict(Name=name,Status='PASS' if condition else 'FAIL',Kind='StaticSourceXmlOrHash',Detail=detail))
        if not condition: print('FAIL',name,detail)
    def body(name):
        assert len(spans.get(name,[]))==1, name
        return source[slice(*spans[name][0])]
    probe=body('Invoke-DomeniaInProcessAuthProbe')
    native=(root/'wad/tests/Test-DomeniaLogin.ps1').read_text(encoding='utf-8-sig')
    installer=(root/'INSTALLER-MISE-A-JOUR.ps1').read_text(encoding='utf-8-sig')
    check('Expected build markers', '2026.09.22-R1.7.2-NATIVE' in source and 'DOMENIA 1.0 R1.7.2 CONNEXION' in source)
    check('Unique top-level definitions',all(len(v)==1 for v in spans.values()))
    check('All original functions retained',sorted(spans)==changes['OriginalFunctions'])
    check('Precisely four top-level functions intended to change',changes['ChangedFunctions']==sorted([
        'Invoke-DomeniaInProcessAuthProbe','Convert-DomeniaLoginFailureMessage','Get-DomeniaLoginFailureHint','Update-DomeniaFastLoginAttempt']))
    for path in sorted(root.rglob('*.ps1')):
        masked,issues=mask_ps(path.read_text(encoding='utf-8-sig'))
        stack=[]; bad=[]; pairs={')':'(',']':'[','}':'{'}
        for idx,c in enumerate(masked):
            if c in '([{': stack.append(c)
            elif c in pairs:
                if not stack or stack[-1]!=pairs[c]: bad.append(idx)
                else: stack.pop()
        check('Lexical delimiters, not native parsing: '+str(path.relative_to(root)),not issues and not stack and not bad)
    check('Explicit bind uses getter method exactly once',probe.count('$nativeBase = $baseAdsi.psbase.get_NativeObject()')==1)
    check('Discovery uses getter method',probe.count('$nativeRoot = $discoveryRoot.psbase.get_NativeObject()')==1)
    check('No swallowing property syntax for NativeObject',not re.search(r'\.psbase\.NativeObject\b',probe))
    check('Properties getter called as method','$properties = $Entry.psbase.get_Properties()' in probe and '.psbase.Properties' not in probe)
    check('Indexer called as method','$values = $properties.get_Item($Name)' in probe)
    check('Null entry, collection, native and missing-DN guards retained',all(x in probe for x in (
        'DOMENIA_AUTH_ENTRY_NULL','DOMENIA_AUTH_PROPERTIES_NULL','DOMENIA_AUTH_NATIVE_NULL','DOMENIA_AUTH_METADATA_MISSING')))
    check('Success requires a subsequent base read',probe.index('[void](Read-AuthAdsiBase -Entry $baseAdsi)') < probe.index('return New-AuthResult -Success $true -BindUser $bindLogin'))
    check('No second property read in RefreshCache error handler','catch { $null = $baseAdsi.Properties' not in probe)
    check('Only one explicit DirectoryEntry factory',probe.count('$baseAdsi = New-Object System.DirectoryServices.DirectoryEntry')==1)
    check('One-attempt guard retained',"if ($explicitBindAttempted -or $category -eq 'Internal')" in probe and '-Attempts ([int]$explicitBindAttempted)' in probe)
    check('Success after explicit path returns canonical identity','-BindUser $bindLogin -AuthMode "Explicit"' in probe)
    check('No identity or password transformation added',all(x in probe for x in (
        '$plainPassword = [string]$Request.Credential.GetNetworkCredential().Password',
        '$bindLogin = "$detectedNetbios\u005c$rawLogin"'.replace('\u005c','\\'))))
    check('DirectoryEntry Secure and Windows Negotiate retained',all(x in probe for x in (
        '[System.DirectoryServices.AuthenticationTypes]::Secure','[System.DirectoryServices.Protocols.AuthType]::Negotiate')))
    check('Windows signing and sealing retained','SessionOptions.Signing = $true' in probe and 'SessionOptions.Sealing = $true' in probe)
    check('Cleanup preserved','finally {\n                        $plainPassword = ""' in probe and '$baseAdsi.psbase.Dispose()' in probe and '$discoveryRoot.psbase.Dispose()' in probe)
    check('Unknown explicit-bind error has no fabricated network verdict',"if ($Stage -eq 'Explicit.NativeBind') { return 'Authentication' }" in probe)
    check('Native HRESULT categories independent of message wording',all(x in probe for x in (
        "'0x8007052E' { $category='Credentials'", "'0x80070531' { $category='AccountRestriction'",
        "'0x80070775' { $category='AccountRestriction'", "'0x80070005' { $category='AccessDenied'",
        "'0x8007203A' { $category='DomainUnavailable'")))
    check('A real LDAP code is preserved only from LdapException',"$ldapCode=[string]$cursor.ErrorCode" in probe and "LdapCode=$native.LdapCode" in probe)
    check('Extended native error scalars kept','ExtendedErrorMessage' in probe and 'ExtendedCode=$native.ExtendedCode' in probe)
    check('Canonical bind identity and selected DC both reported','BindIdentity=$BindIdentity' in probe and '-Server $failureServer -Attempts ([int]$explicitBindAttempted)' in probe)
    check('New diagnostics scrub the exact submitted secret',all(x in probe for x in (
        "$safe=$safe.Replace($Secret,'[SECRET MASQUE]')",'NativeMessage=(Protect-AuthDiagnosticText',
        'ExtendedMessage=(Protect-AuthDiagnosticText','-ServerName $failureServer -Secret $plainPassword')))
    check('New diagnostic helper does not serialize objects','ConvertTo-Json' not in probe and 'InvocationInfo.Line' not in probe)
    check('Monitor keeps native error fields',all(x in body('Update-DomeniaFastLoginAttempt') for x in ('NativeMessage={10}','ExtendedCode={11}','ExtendedMessage={12}','LdapCode={13}','BindIdentity={9}')))
    check('Unknown bind hint requests diagnostics, not credential cycling','diagnostic natif' in body('Get-DomeniaLoginFailureHint'))
    check('No erroneous password-only verdict for LDAP 52e','"52e" { return "Mot de passe incorrect.' not in probe)
    check('No assurance that locked account password is valid','Le mot de passe n est pas en cause' not in probe)
    check('Unbounded numeric UI matches removed','(775|' not in body('Convert-DomeniaLoginFailureMessage') and '(533|' not in body('Convert-DomeniaLoginFailureMessage'))
    count=len(re.findall(r'^Test-LoginCase ',native,re.M))
    check('47 provided runtime cases present, NOT executed',count==47)
    check('Native tests include R1.7.1 differential fixture','AuthProbe-R1.7.1.ps1' in native and 'R1.7.1 : getter COM refusant masque' in native)
    check('Runtime tests compare property and method access','$v=$e.psbase.NativeObject' in native and 'Assert-LoginThrows { $e.psbase.get_NativeObject() }' in native)
    check('Runtime tests include no-secret result and selected DC case','SecretInNativeError' in native and 'SelectedDcFailure' in native)
    check('Tests block OS domain discovery',"$staticBoundary='[System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()'" in native and "throw 'TEST ONLY: OS domain discovery disabled.'" in native)
    check('Tests block all other DS New-Object constructors',"if ($TypeName -like 'System.DirectoryServices.*')" in native)
    check('Installer requires all 47 cases before any code copy',installer.index('-File $loginTests')<installer.index('$backupParent=') and '[int]$loginResult.Passed -lt 47' in installer)
    check('Installer still protects data paths',r'wad[/\\](data|maintenance[/\\]backups)' in installer)
    check('Installer still enforces preserve-existing policy','PreserveExisting' in installer)
    # Actual normalized function hashes, not a declared-count assertion alone.
    mismatches=[n for n,h in changes['UnchangedFunctionDigests'].items() if hashlib.sha256(body(n).encode('utf-8')).hexdigest()!=h]
    check('563 unmodified functions still match original source',not mismatches and len(changes['UnchangedFunctionDigests'])==563,','.join(mismatches))
    for rel,digest in changes['PreservedFiles'].items():
        path=root/rel
        check('Preserved file bytes: '+rel,path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest()==digest)
    previous=(root/'wad/tests/fixtures/AuthProbe-R1.7.1.ps1').read_text(encoding='utf-8-sig').strip()
    check('R1.7.1 baseline fixture exact normalized source',hashlib.sha256(previous.encode('utf-8')).hexdigest()==changes['OriginalProbeTextSha256'])
    # Four actual literal Window templates, unchanged by this revision.
    windows=[]
    for name in spans:
        if 'Xaml' not in name: continue
        for match in re.finditer(r'@([\'"])\n(.*?)\n\1@',body(name),re.S):
            text=match.group(2).strip()
            if not text.startswith('<Window'): continue
            try: ET.fromstring(text); valid=True; detail=''
            except ET.ParseError as exc: valid=False; detail=str(exc)
            windows.append(name)
            check('Literal Window XML only: '+name,valid,detail)
    for path in sorted((root/'wad/modules').glob('*.xaml')):
        try: ET.parse(path); valid=True; detail=''
        except ET.ParseError as exc: valid=False; detail=str(exc)
        check('Module XML only: '+path.name,valid,detail)
    report=dict(Build='2026.09.22-R1.7.2-NATIVE',PowerShellExecuted=False,WpfExecuted=False,LiveDirectoryExecuted=False,
        NativeScenariosProvidedNotExecuted=count,LiteralWindowXmlChecked=windows,
        CoreSha256=hashlib.sha256((root/'wad/Domenia-Core.ps1').read_bytes()).hexdigest(),
        Passed=sum(x['Status']=='PASS' for x in checks),Failed=sum(x['Status']=='FAIL' for x in checks),Checks=checks)
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:report[k] for k in ('Passed','Failed','NativeScenariosProvidedNotExecuted')}))
    return int(report['Failed']>0)

if __name__=='__main__': raise SystemExit(main())
