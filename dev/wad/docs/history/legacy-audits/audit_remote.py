#!/usr/bin/env python3
"""R1.2 offline SOURCE checks. Does NOT execute PowerShell, WPF, AD or SMB.
Native runtime/mocked regression cases are in Test-DomeniaRemote.ps1.
"""
from pathlib import Path
import argparse, re, json, hashlib
from powershell_lex import functions, mask_ps

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2])
    p.add_argument('--report',type=Path,default=Path('/tmp/domenia-remote-static.json'))
    a=p.parse_args();root=a.root.resolve()
    core=(root/'wad/Domenia-Core.ps1').read_text(encoding='utf-8-sig')
    common=re.search(r"(?ms)^\$script:WorkerCommon = @'\n(.*?)\n'@",core)[1]
    cf, mf=functions(common), functions(core)
    def fn(name):
        source,table=(common,cf) if name in cf else (core,mf)
        spans=table[name];assert len(spans)==1
        x,y=spans[0];return source[x:y]
    results=[]
    def check(name,condition,detail=''):
        status='PASS' if condition else 'FAIL'
        results.append({'Name':name,'Kind':'StaticSourceAssertion','Status':status,'Detail':detail})
        print(status,name)
    px=fn('Invoke-WRemotePsExecScript')
    check('PsExec: cible calculee avant la liste',"$target='\\\\'+$Computer" in px and '[string[]]$processArguments=@($target,' in px)
    check('PsExec: options distinctes et garde avant lancement',"$processArguments[1] -cne '-accepteula'" in px and "$processArguments[2] -cne '-nobanner'" in px)
    check('PsExec: variable automatique args non reutilisee',not re.search(r'\$args\b',mask_ps(px)[0],re.I))
    check('PsExec: appel nomme, pas de shell intermediaire', '-FilePath $exe -Arguments $processArguments -TimeoutSeconds $TimeoutSeconds' in px and 'UseShellExecute=$false' in fn('Invoke-WQuietProcess'))
    check('PsExec: credential efface de la liste locale en finally','finally { $watch.Stop(); $processArguments=$null; $remoteCred=$null }' in px)
    check('PsExec: exitcode non nul refuse meme avec un resultat',"if ([int]$r.ExitCode -ne 0)" in px)
    check('Detail licence remplace par explication ciblee','SYSINTERNALS SOFTWARE LICENSE TERMS' in fn('Format-WRemoteFailureDetail') and 'ne prouve pas un refus de droits' in fn('Format-WRemoteFailureDetail'))
    check('Meme selection de credential pour les trois transports',all('Get-WMachineCredential $Context' in fn(n) for n in ('Invoke-WRemotePsExecScript','Invoke-WSchtasksRemote','New-WAdminShareDrive')))
    check('Aucune substitution apres refus ADMIN$',fn('New-WAdminShareDrive').count('New-PSDrive @parameters')==1 and 'Aucun autre compte' in fn('New-WAdminShareDrive'))
    staging=fn('Invoke-WRemoteScheduledTaskScript')
    check('Staging: chemin PSDrive authentifie',"$drivePrefix=([string]$drive.Name)+':\\Temp\\'+$base" in staging)
    check('Staging: pas d IO .NET sur les chemins distants',not re.search(r'\[IO\.File\]::\w+\([^\n]*(?:drivePrefix|uncPrefix|outPath)',staging))
    check('Staging: lecture et ecriture via fournisseur PowerShell','Set-Content -LiteralPath ($drivePrefix' in staging and 'Get-Content -LiteralPath $outPath' in staging)
    check('Staging: publication JSON temporaire avant renommage',staging.count("Move-Item -LiteralPath '$remoteOut.tmp' -Destination '$remoteOut'")==2)
    check('Staging: nettoyage sur succes et echec',"foreach($suffix in @('.ps1','.json','.out.json','.out.json.tmp'))" in staging and 'Remove-WAdminShareDrive $drive' in staging)
    check('LastUser conserve le credential LDAP',"$OperationId -eq 'ComputerLastUser' -or" in fn('Get-WorkerContext'))
    check('Erreur LDAP distincte utilisateur absent','[switch]$Detailed' in fn('Test-WUserInAd') and "LookupSucceeded=$false" in fn('Test-WUserInAd') and "'VALIDATION AD KO'" in fn('Start-ComputerUserLinkProbe'))
    check('Exceptions Dispose ne remplacent pas un resultat LDAP', 'try { $searcher.Dispose() } catch {}' in fn('Test-WUserInAd') and 'try { $root.Dispose() } catch {}' in fn('Test-WUserInAd'))
    check('Erreurs DCOM et Wsman conservees',"$failures.Add(($protocol+' : '" in fn('New-WDomeniaCimSession'))
    resolver=fn('Start-ComputerUserLinkProbe')
    check('Plus de message classique generique sans detail','Toutes les methodes classiques de detection ont echoue ou sont restees vides.' not in resolver and 'Get-WProbeAttemptSummary -Attempts @($attempts)' in resolver)
    check('WinRM desactive respecte et HTTPS choisi si seul 5986 ouvert',"if ([bool]$Context.UseWinRM) {" in resolver and "if (-not $open5985 -and $open5986) { $params['UseSSL']=$true }" in resolver)
    check('Compte effectif journalise sans mot de passe',"Add-Attempt 'Comptes effectifs'" in resolver and 'GetNetworkCredential().Password' not in resolver)
    ui=fn('Complete-DomeniaComputerUserProbeUi')
    check('UI: anciennes associations conservees si distant KO','Utilisateur conserve depuis le cache' in ui and 'Remove-UserMachineLink' not in ui)
    check('UI: pas de double log de la licence complete','Write-AppLog $message "WARN"' not in ui and "-Area 'Association'" in ui)
    inst=(root/'INSTALLER-MISE-A-JOUR.ps1').read_text(encoding='utf-8-sig')
    check('Installateur: tests natifs avant remplacement du code',inst.index('& $remoteTests -ReportPath') < inst.index('$backupParent=') and inst.index('& $remoteTests -ReportPath') > inst.index("if(-not $PSCmdlet.ShouldProcess($targetRoot,"))
    test=(root/'wad/tests/Test-DomeniaRemote.ps1').read_text(encoding='utf-8-sig')
    check('Tests Windows: fonctions reelles extraites, pas de demarrage application','Language.Parser]::ParseInput' in test and '. ([scriptblock]::Create(($definitions.ToArray()' in test and '& $corePath' not in test)
    check('Tests Windows: mock processus obligatoire, vrai lanceur non importe',"'Invoke-WQuietProcess'" not in test[test.index('$commonNames='):test.index('$commonNodes=')] and 'function Invoke-WQuietProcess {' in test)
    check('Tests Windows: pas de cible de production',not re.search(r'cnamts|P111301|MARCIANTE',test,re.I))
    check('Tests Windows: dependence du hash importee',"'ConvertTo-DomeniaCanonicalWorkerCode'" in test)
    # Ensure the tracked worker has exactly the correct normalized body hash.
    body=re.search(r"(?ms)        \$code = @'\n(.*?)\n'@",resolver)[1]
    expected=re.search(r'ComputerLastUser\s*=\s*"([A-F0-9]{64})"',fn('Get-DomeniaWorkerOperationHashes'))[1]
    check('Empreinte exacte du nouveau worker',hashlib.sha256(body.encode()).hexdigest().upper()==expected)
    report={'Build':re.search(r'\$script:MasterBuild\s*=\s*[\'"]([^\'"]+)', core)[1],'Environment':'Linux, Python','PowerShellExecuted':False,'WindowsWpfExecuted':False,'LiveAdSmbExecuted':False,'CoreSha256':hashlib.sha256((root/'wad/Domenia-Core.ps1').read_bytes()).hexdigest().upper(),'Passed':sum(x['Status']=='PASS' for x in results),'Failed':sum(x['Status']=='FAIL' for x in results),'Tests':results}
    a.report.parent.mkdir(parents=True,exist_ok=True);a.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    return int(report['Failed']>0)
if __name__=='__main__':raise SystemExit(main())
