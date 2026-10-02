#!/usr/bin/env python3
"""R1.4 source assertions. Does not execute PowerShell, ADSI, WPF or an AD bind.
The complementary Test-DomeniaAccounts.ps1 runs the real extracted functions with
mocked authentication/UI boundaries on Windows PowerShell 5.1.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
from powershell_lex import functions, mask_ps

LOGIN_BASELINE_SHA256 = 'FA6702EB6F60DB2593779A423E0F7DA030781FEC27787888182E40BEDDC05398'

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--report', type=Path, default=Path('/tmp/domenia-accounts-audit.json'))
    args = parser.parse_args()
    root = args.root.resolve()
    path = root / 'wad/Domenia-Core.ps1'
    source = path.read_text(encoding='utf-8-sig')
    spans = functions(source)
    checks = []

    def fn(name):
        assert len(spans[name]) == 1, name
        start, end = spans[name][0]
        return source[start:end]

    def check(name, condition):
        status = 'PASS' if condition else 'FAIL'
        checks.append({'Name': name, 'Kind': 'StaticSourceAssertion', 'Status': status})
        print(status, name)

    request = fn('New-DomeniaAccountAuthRequest')
    test = fn('Test-DomeniaCredentialBind')
    active = fn('Test-DomeniaActiveDirectoryCredential')
    save = fn('Save-DomeniaSecondaryCredential')
    wire = fn('Wire-Events')
    login = fn('Invoke-DomeniaInProcessAuthProbe')
    worker = fn('Get-WorkerContext')
    test_masked, issues = mask_ps(test)
    native_tests = (root/'wad/tests/Test-DomeniaAccounts.ps1').read_text(encoding='utf-8-sig')
    installer = (root/'INSTALLER-MISE-A-JOUR.ps1').read_text(encoding='utf-8-sig')
    change = json.loads((root/'wad/docs/CHANGES-ACCOUNTS-R1.4.json').read_text(encoding='utf-8'))

    check('Moteur de login strictement identique a R1.3 (empreinte du texte normalise)',
          hashlib.sha256(login.encode()).hexdigest().upper() == LOGIN_BASELINE_SHA256)
    check('Login explicite conserve ADSI et AuthenticationTypes.Secure',
          'System.DirectoryServices.DirectoryEntry' in login and '[System.DirectoryServices.AuthenticationTypes]::Secure' in login)
    check('Test de compte utilise le meme demarrage et lecteur que le login',
          test.count('Start-DomeniaLoginAuthRunspace -Request $request') == 1 and
          test.count('Read-DomeniaAuthRunspaceResult -Session $session') == 1 and
          'Invoke-DomeniaInProcessAuthProbe' in fn('Start-DomeniaLoginAuthRunspace'))
    check('Ancien LdapConnection/NetworkCredential direct absent du code executable du test',
          not issues and not re.search(r'\bLdapConnection\b|\bNetworkCredential\b|\.Bind\s*\(', test_masked))
    check('Requete fige le controleur et la base de la session active',
          all(x in request for x in ('$script:Conn.Server', '$script:Conn.BaseDn', 'ConfiguredServer=$server; ConfiguredBase=$baseDn', "throw 'Contexte AD incomplet")))
    check('Aucune variante de compte ni repli Windows implicite',
          'MaxServers=1' in request and 'UseCurrentCredentials=$false' in request and '$user.Replace(' not in request)
    check('Mot de passe conserve en SecureString, copie privee en lecture seule',
          '[System.Security.SecureString]$Password' in request and '$Password.Copy()' in request and '$passwordCopy.MakeReadOnly()' in request and
          not re.search(r'\$Password\s*\.\s*Trim', request, re.I))
    check('Nom UPN ou qualifie transmis tel quel au moteur du login',
          '$user = ([string]$UserName).Trim()' in request and 'Login=$user; Credential=$credential' in request and
          'PSCredential]::new($user,$passwordCopy)' in request)
    check('Un appel precedent non termine bloque avant une nouvelle requete',
          test.index('if (-not [bool]$pending.Cleaned') < test.index('New-DomeniaAccountAuthRequest') and
          'Aucun nouvel essai envoye.' in test)
    check('Attente bornee et pas de resultat lu apres depassement du delai',
          'AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))' in test and
          test.index('throw [System.TimeoutException]') < test.index('Read-DomeniaAuthRunspaceResult'))
    check('Nettoyage sur toutes les sorties et arret a la fermeture du logiciel',
          'finally {' in test and 'Stop-DomeniaLoginAuthRunspace -Session $session -Terminate' in test and
          'Stop-DomeniaLoginAuthRunspace -Session $script:AccountCredentialTestSession -Terminate' in fn('Dispose-AsyncEngine'))
    check('Resultat explicite ADSI obligatoire, succes et identite non vide',
          all(x in test for x in ('-not [bool]$result.Success', '[string]::IsNullOrWhiteSpace($bindUser)',
                                 "$result.AuthMode -ne 'Explicit'", "$result.AuthMethod -ne 'ADSI.DirectoryEntry+ContextDiscovery'")))
    check('Aucun compte modifie par la seule fonction de test',
          not re.search(r'\$script:(?:Conn|RemoteAdminCredential|SecretsCredential)\s*=', test) and
          'Set-DomeniaSetting' not in test)
    check('Activation memorise exactement l identite validee',
          save.index('$user = [string]$test.User') < save.index('PSCredential]::new($user,$secure)') < save.index('$script:RemoteAdminCredential = $cred'))
    check('Activation n ecrase pas un ancien compte avant validation',
          save.index('$test = Test-DomeniaCredentialBind') < save.index('Set-DomeniaSetting') and
          'if (-not $committed) { $secure.Dispose() }' in save)
    check('Seuls les noms sont envoyes aux preferences',
          re.findall(r"Set-DomeniaSetting -Name '([^']+)' -Value (\$\w+)", save) == [('RemoteCredentialUser', '$user'), ('SecretsCredentialUser', '$user')])
    check('Champs WPF activation utilisent SecurePassword pour les deux comptes',
          'Save-DomeniaSecondaryCredential -Scope Remote -UserName ([string]$script:Ctrl["TxtAccountRemoteUser"].Text) -Password ($script:Ctrl["PwdAccountRemote"].SecurePassword)' in wire and
          'Save-DomeniaSecondaryCredential -Scope Secrets -UserName ([string]$script:Ctrl["TxtAccountSecretsUser"].Text) -Password ($script:Ctrl["PwdAccountSecrets"].SecurePassword)' in wire)
    check('Test AD refuse un nom different avant reutilisation du mot de passe actif',
          active.index('if (-not $sameIdentity)') < active.index('Test-DomeniaCredentialBind') and
          'Test-DomeniaCredentialBind -UserName $activeUser -Password $credential.Password' in active and
          'Test-DomeniaActiveDirectoryCredential -UserName $u' in wire)
    check('Nom court accepte seulement si meme compte et meme Netbios',
          '"$netbios\\$requestedUser" -ieq $activeUser' in active)
    check('Workers Secrets conservent le nom associe a leur propre credential',
          'BindUser = if ($null -ne $workerDirectoryCredential) { [string]$workerDirectoryCredential.UserName }' in worker)
    check('Validation AD et autorisations WMI/SMB sont explicitement distinguees',
          'Droits WMI/SMB et droits de lecture des secrets non testes.' in test)
    check('Pas de journalisation brute de requete ou de mot de passe dans les nouveaux chemins',
          all(not re.search(r'(?:Add-DomeniaUiLog|Write-AppLog).*\$(?:Password|plain|secure|request|credential)\b', text, re.I)
              for text in (test, request, save, active)))
    check('Suite native importe seulement les fonctions reellement testees',
          "$names=@('New-DomeniaAccountAuthRequest','Test-DomeniaCredentialBind','Test-DomeniaActiveDirectoryCredential','Save-DomeniaSecondaryCredential','Get-WorkerContext')" in native_tests and
          '. ([scriptblock]::Create(($definitions.ToArray()' in native_tests and '& $corePath' not in native_tests)
    check('Demarrage, lecture et nettoyage du worker sont mocks dans la suite native',
          all(('function '+n+' {') in native_tests for n in ('Start-DomeniaLoginAuthRunspace','Read-DomeniaAuthRunspaceResult','Stop-DomeniaLoginAuthRunspace')) and
          '.BeginInvoke(' not in native_tests and '.Bind(' not in native_tests)
    count = len(re.findall(r"^Test-Case '", native_tests, re.M))
    check('25 scenarios Windows declares, uniquement fixtures synthetiques',
          count == 25 and not re.search(r'cnamts|marciante|p111301', native_tests, re.I))
    check('Tests comptes obligatoires avant toute sauvegarde/copie du code',
          installer.index('if(-not $PSCmdlet.ShouldProcess($targetRoot,') < installer.index('& $accountTests -ReportPath') < installer.index('$backupParent='))
    check('Anciennes suites distantes et detection toujours executees par installateur',
          installer.index('& $remoteTests -ReportPath') < installer.index('& $accountTests -ReportPath') and
          installer.index('& $lastUserTests -ReportPath') < installer.index('& $accountTests -ReportPath'))
    check('Aucune fonction supprimee, modification limitee aux comptes/contexte/nettoyage',
          change['RemovedFunctions'] == [] and set(change['ChangedFunctions']) == {
              'Test-DomeniaCredentialBind','Save-DomeniaSecondaryCredential','Wire-Events','Dispose-AsyncEngine','Get-WorkerContext'})

    build = re.search(r'\$script:MasterBuild\s*=\s*[\'"]([^\'"]+)', source)[1]
    report = {
        'Build': build, 'Environment': 'Linux/Python, source assertions only',
        'PowerShellExecuted': False, 'WpfExecuted': False, 'LiveDirectoryExecuted': False,
        'CoreSha256': hashlib.sha256(path.read_bytes()).hexdigest().upper(),
        'NativeScenariosProvidedNotExecuted': count,
        'Passed': sum(t['Status'] == 'PASS' for t in checks),
        'Failed': sum(t['Status'] == 'FAIL' for t in checks), 'Checks': checks,
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(json.dumps({k:report[k] for k in ('Passed','Failed','NativeScenariosProvidedNotExecuted')}))
    return int(report['Failed'] > 0)

if __name__ == '__main__':
    raise SystemExit(main())
