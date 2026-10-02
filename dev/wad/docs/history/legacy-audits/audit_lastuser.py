#!/usr/bin/env python3
"""R1.3 source-level checks only. Does not execute PowerShell or WPF.
The behavioural tests in Test-DomeniaLastUser.ps1 must run under PowerShell.
"""
from pathlib import Path
import argparse, hashlib, json, re
from powershell_lex import functions, mask_ps

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2])
    parser.add_argument('--report',type=Path,default=Path('/tmp/domenia-lastuser-audit.json'))
    args=parser.parse_args();root=args.root.resolve()
    source=(root/'wad/Domenia-Core.ps1').read_text(encoding='utf-8-sig');spans=functions(source)
    def fn(name):
        assert len(spans[name])==1
        a,b=spans[name][0];return source[a:b]
    checks=[]
    def check(name,value):
        status='PASS' if value else 'FAIL';checks.append({'Name':name,'Kind':'StaticSourceAssertion','Status':status});print(status,name)
    start=fn('Start-ComputerUserLinkProbe');stop=fn('Request-UiTaskStop');running=fn('Get-DomeniaRunningComputerUserProbe')
    queue=fn('Queue-DomeniaSelectedObjectOpen');clear=fn('Clear-DomeniaComputerUserProbeState');receive=fn('Receive-DomeniaComputerUserProbeProgress')
    check('Coalescence fondee sur le registre de taches avant le cache',start.index('Get-DomeniaRunningComputerUserProbe')<start.index('Get-ExistingLinkForComputer'))
    coalesce=start[start.index('if ($null -ne $runningProbe)'):start.index('# LOCAL-FIRST')]
    check('Force ne remplace pas le probe actif','return' in coalesce and 'Request-UiTaskStop' not in coalesce)
    check('Jobs annules, remplaces et anciennes sessions exclus',all(x in running for x in ('$job.CancelRequested','$job.Superseded','$job.SessionEpoch -ne [long]$script:SessionEpoch')))
    check('Callback termine en attente conserve','Handle.IsCompleted' not in running)
    check('Le drapeau orphelin est efface avant une nouvelle sonde','Clear-DomeniaComputerUserProbeState' in start[:start.index('# LOCAL-FIRST')])
    check('Arret libere le marqueur avant BeginStop',stop.index('Stop-DomeniaComputerUserProbeUi')<stop.index('.BeginStop('))
    check('Nettoyage protege le nouvel identifiant et la machine', '$script:ActiveLinkProbeId -ne $ProbeId' in clear and '$script:ActiveLinkProbeComputer -ine $normalized' in clear)
    check('Detachement nettoie avant de retirer le CallbackState',fn('Detach-DomeniaReadUiTask').index('Clear-DomeniaComputerUserProbeState')<fn('Detach-DomeniaReadUiTask').index('$job.CallbackState = $null'))
    check('Double clic meme DN ne purge plus la selection','if ($Force -or [string]$script:SelectionResetDn' not in queue and 'if ([string]$script:SelectionResetDn -ine $dn)' in queue)
    check('Nouvelle selection continue d annuler les anciens probes',"$replaceKey -like \"lastuser:*\"" in fn('Reset-DomeniaSelectionBoundViews') and "-Reason 'Changement de selection'" in fn('Reset-DomeniaSelectionBoundViews'))
    check('Erreurs obsoletes rejetees meme marqueur vide',"-and -not [string]::IsNullOrWhiteSpace([string]$script:ActiveLinkProbeId)" not in fn('Fail-DomeniaComputerUserProbeUi'))
    check('Succes verifies et gardes machine conserves','[bool]$effective.VerifiedInAD' in fn('Complete-DomeniaComputerUserProbeUi') and '$currentComputer -ine $computer' in fn('Complete-DomeniaComputerUserProbeUi'))
    check('File de progression partagee','ConcurrentQueue[object]' in start and 'Progress=$probeProgress' in start and start.count('Progress=$probeProgress')==2)
    check('Progression drainaige borne et session controlee','TryDequeue([ref]$item)' in receive and '$i -lt 32' in receive and '$Job.SessionEpoch -ne [long]$script:SessionEpoch' in receive)
    check('Progression consultee pendant le travail','Receive-DomeniaComputerUserProbeProgress -Job $job' in fn('Complete-UiTasks'))
    check('Motif annulation et temps persistants','Association interrompue' in fn('Stop-DomeniaComputerUserProbeUi') and 'Write-AppLog' in fn('Stop-DomeniaComputerUserProbeUi'))
    check('Etapes emises avant appels bloquants',start.index("Set-ProbeStep 'CIM utilisateur courant'") < start.index("$cs=Get-CimInstance") and "Set-ProbeStep 'Secours PsExec / tache planifiee'" in start)
    check('Timeout explicite console, registre CIM et profils',start.count('-OperationTimeoutSec ([Math]::Max(1,')==3)
    check('Lecture LogonUI CIM conditionnelle et read-only',"if ([bool]$Payload.UseRemoteRegistry)" in start and "-MethodName 'GetStringValue'" in start and "-Namespace 'root\\default'" in start and "'SetStringValue'" not in start)
    check('Code de retour registre verifie avant candidat',start.index('if ([uint32]$reg.ReturnValue -ne 0)')<start.index("Return-Candidate 'CIM dernier utilisateur LogonUI'"))
    check('Finalisation session CIM conservee','finally { Remove-WDomeniaCimSession $cimSession; $sw.Stop() }' in start)
    check('Champ utilisateur jamais vide sans association',"'Detection en cours...'" in fn('Refresh-AssociationContext') and "'Non determine'" in fn('Refresh-AssociationContext'))
    body=re.search(r"(?ms)        \$code = @'\n(.*?)\n'@",start)[1]
    pinned=re.search(r'ComputerLastUser\s*=\s*"([A-F0-9]{64})"',fn('Get-DomeniaWorkerOperationHashes'))[1]
    check('Empreinte du worker exact',hashlib.sha256(body.encode()).hexdigest().upper()==pinned)
    tests=(root/'wad/tests/Test-DomeniaLastUser.ps1').read_text(encoding='utf-8-sig')
    check('Tests natifs extraient les vraies definitions sans lancer DOMENIA','Language.Parser]::ParseInput' in tests and '. ([scriptblock]::Create(($definitions.ToArray()' in tests and '& $corePath' not in tests)
    check('Fixtures anonymes, pas de poste du parc',not re.search(r'cnamts|MARCIANTE|P111301',tests,re.I))
    installer=(root/'INSTALLER-MISE-A-JOUR.ps1').read_text(encoding='utf-8-sig')
    check('Deux suites natives avant premiere copie',installer.index('& $lastUserTests -ReportPath')<installer.index('$backupParent=') and installer.index('& $remoteTests -ReportPath')<installer.index('$backupParent='))
    report={'Build':re.search(r'\$script:MasterBuild\s*=\s*[\'"]([^\'"]+)', source)[1],'Environment':'Linux/Python; source assertions only','PowerShellExecuted':False,'WpfExecuted':False,'LiveDirectoryExecuted':False,'CoreSha256':hashlib.sha256((root/'wad/Domenia-Core.ps1').read_bytes()).hexdigest().upper(),'Passed':sum(t['Status']=='PASS' for t in checks),'Failed':sum(t['Status']=='FAIL' for t in checks),'Checks':checks}
    args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    return int(report['Failed']>0)
if __name__=='__main__':raise SystemExit(main())
