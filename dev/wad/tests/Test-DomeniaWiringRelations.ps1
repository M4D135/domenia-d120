#requires -Version 5.1
# D120 lot relations (D041-D050): integration proofs that the pure rules of Domenia-Relations.Model.ps1 are
# really called by the application. The real functions of the core (extracted by AST) and of the modules run
# against real WPF controls of the main XAML; network, AD, CIM and storage are inert doubles.
# Each case fails when the wiring is removed (the RC1.10.7 behaviour is asserted against).
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet)
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot
$script:Tests=[Collections.Generic.List[object]]::new();$script:WindowsExecuted=$false;$script:Window=$null
function Expect {param([bool]$Value,[string]$Message='Assertion non verifiee');if(-not $Value){throw $Message}}
function Case {param([string]$Name,[scriptblock]$Body)
    try{& $Body|Out-Null;$script:Tests.Add([pscustomobject]@{Name=$Name;Status='Passed';Detail=''})}
    catch{$script:Tests.Add([pscustomobject]@{Name=$Name;Status='Failed';Detail=$_.Exception.ToString()})}
}
function Parse-Source {param([string]$Path)
    $t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e)
    Expect (@($e).Count -eq 0) ($Path+' : '+($e|Out-String));return $a
}
function Get-SourceFunctionText {param($Ast,[string]$Name)
    $nodes=@($Ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
    Expect ($nodes.Count -eq 1) ('Fonction introuvable ou ambigue : '+$Name)
    return ($nodes[0].Extent.Text -replace ('^function\s+'+[regex]::Escape($Name)+'\b'),('function script:'+$Name))
}
# ---------------------------------------------------------------- inert doubles (no bootstrap, AD, CIM or disk store)
function Get-DomeniaControl {param([string]$Name);if($null -eq $script:Ctrl){return $null};return $script:Ctrl[$Name]}
function Set-DomeniaControlText {param([string]$Name,[string]$Text);$script:Messages[$Name]=$Text;$c=Get-DomeniaControl $Name;if($null -ne $c){$c.Text=$Text};return $true}
function Set-DomeniaItemsSource {param([string]$Name,$Rows);$c=Get-DomeniaControl $Name;if($null -ne $c){$list=[Collections.ArrayList]::new();foreach($r in @($Rows)){if($null -ne $r){[void]$list.Add($r)}};$c.ItemsSource=$list};return $true}
function Get-DomeniaRetryCredential {param($OperationId);return $script:Retry[$OperationId]}
function Test-DomeniaAccessBusyWrite {return [bool]$script:Locked}
function Get-DomeniaEntryFirstString {param($Entry,$Name);return [string]$Entry[$Name]}
function Write-AppLog {param($Text,$Level);$script:Log.Add([string]$Text)}
function Set-Status {param($Text,$Level);$script:Messages['Status']=[string]$Text}
function Show-ErrorBox {param($Text);$script:Messages['Error']=[string]$Text}
function Add-DomeniaUiLog {param($Area,$Text,$Level)}
function Refresh-AssociationContext {param([switch]$SkipResultRefresh)}
function Refresh-LinkGrid {param([switch]$All)}
# D028: background observations ask the single writer through a deferred request (counted here, no real timer).
function Request-DomeniaLinkPersistence {$script:LinkPersistenceRequests++}
function Save-UserMachineLinks {$script:SaveCount++;if($script:UseRealQueue){return (Queue-DomeniaLinkChanges)};return [bool]$script:SaveAccepted}
function Request-DomeniaAccessRecovery {param($Operation,$OperationId,$ErrorValue,$DN,$Target);return $true}
function Get-DomeniaEffectiveWorkerResult {param($Result,$RequiredProperties);return @($Result)[-1]}
function Request-UiTaskStop {param($Id,[switch]$Silent,[switch]$Force,[switch]$Superseded,$Reason);$script:Stops.Add([string]$Id)}
function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$DisableControls,$TimeoutSeconds,$StatusText,$SuccessHandler,$ErrorHandler)
    $id='job-'+($script:Submissions.Count+1)
    $script:Submission=[pscustomobject]@{Id=$id;Payload=$Payload;State=$CallbackState;Operation=$OperationId;Success=$SuccessHandler;Error=$ErrorHandler;Code=$Code}
    $script:Submissions.Add($script:Submission);$script:AsyncJobs[$id]=[pscustomobject]@{CancelRequested=$false;OperationId=$OperationId};return $id
}
function Confirm-Action {param($Message,$Title);$script:ConfirmCount++;return [bool]$script:ConfirmAccepted}
function Get-CfgValue {param($Section,$Key,$Default);if($Section -eq 'Features' -and $null -ne $script:Features -and $script:Features.ContainsKey([string]$Key)){return $script:Features[[string]$Key]};return $Default}
function Open-AdObject {param($Dn,$Type,[switch]$Force);$script:Opened=[string]$Dn}
function Get-CurrentSelectedComputerName {return [string]$script:CurrentComputer}
function Register-DomeniaOperationSample {param($Operation,$Mode,$ItemCount,$DurationMs,$BytesEstimated,$RemoteAttempts,$FallbackTasks,$SuccessCount)}
function Fail-DomeniaComputerUserProbeUi {param($Message,$State);$script:ProbeFailures.Add([string]$Message)}
function Get-DomeniaRunningComputerUserProbe {param($Computer);return $null}
function Clear-DomeniaComputerUserProbeState {param($ProbeId,$Computer);$script:ActiveLinkProbeId='';$script:ActiveLinkProbeComputer=''}
function Pump {param($Window);$Window.UpdateLayout();$Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle);$Window.UpdateLayout()}
function Reset-Fixture {
    $script:Messages=@{};$script:Retry=@{};$script:Log=[Collections.Generic.List[string]]::new();$script:Stops=[Collections.Generic.List[string]]::new()
    $script:Submissions=[Collections.Generic.List[object]]::new();$script:Submission=$null;$script:ProbeFailures=[Collections.Generic.List[string]]::new()
    $script:Relations=$null;$script:SessionEpoch=7L;$script:SelectedObject=$null;$script:SuppressGridSelectionEvents=$false;$script:Locked=$false;$script:Persistence=$null
    $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid';Server='dc.example.invalid';Domain='example.invalid';Netbios='EXAMPLE';BindUser='EXAMPLE\reader';Credential=$null}
    $script:MachineCredential=$null;$script:RemoteAdminCredential=$null;$script:AsyncJobs=@{};$script:AsyncEngineClosing=$false
    $script:SaveCount=0;$script:SaveAccepted=$true;$script:UseRealQueue=$false;$script:ConfirmCount=0;$script:ConfirmAccepted=$true;$script:Opened=''
    $script:Features=@{};$script:DomeniaLinkStoreMultiRelation=$false;$script:LinkBaseline=@{}
    $script:SelectedBranchDn='OU=Test,DC=example,DC=invalid';$script:BranchObjects=@()
    $script:LinkByComputer=$null;$script:LinksByUser=$null;$script:LinkIndexCount=0;$script:LinkIndexGeneration=0
    $script:IndexUsersByGuid=@{};$script:IndexUsersByLogin=@{};$script:IndexComputersByGuid=@{};$script:IndexComputersByName=@{}
    $script:ActiveLinkProbeId='';$script:ActiveLinkProbeComputer='';$script:LinkProbeDone=@{};$script:Live=$null;$script:MasterBuild='TEST-WIRING';$script:CurrentComputer=''
    $script:DatabaseScopedPath=Join-Path $script:TempRoot ('Domenia-'+[guid]::NewGuid().ToString('N')+'.db')
    $script:UserMachineLinks=@(
        [pscustomobject]@{UserLogin='alice';Computer='PC-A';Source='Console CIM/DCOM';Confidence=97;VerifiedInAD=$true;When='2026-01-01 08:00:00';Details='Historique';UserGuid='11111111-1111-1111-1111-111111111111';ComputerGuid='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';UserDn='CN=Alice,DC=example,DC=invalid';ComputerDn='CN=PC-A,DC=example,DC=invalid'},
        [pscustomobject]@{UserLogin='bob';Computer='PC-B';Source='Saisie manuelle';Confidence=100;VerifiedInAD=$true;When='2026-01-02 08:00:00';Details='Declaration';UserGuid='22222222-2222-2222-2222-222222222222';ComputerGuid='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';UserDn='CN=Bob,DC=example,DC=invalid';ComputerDn='CN=PC-B,DC=example,DC=invalid'}
    )
    $script:Alice=[pscustomobject]@{Type='Utilisateur';Login='alice';Name='Alice';DN='CN=Alice,DC=example,DC=invalid';Guid='11111111-1111-1111-1111-111111111111'}
    $script:Bob=[pscustomobject]@{Type='Utilisateur';Login='bob';Name='Bob';DN='CN=Bob,DC=example,DC=invalid';Guid='22222222-2222-2222-2222-222222222222'}
    $script:PcA=[pscustomobject]@{Type='Machine';Login='PC-A$';Name='PC-A';DN='CN=PC-A,DC=example,DC=invalid';Guid='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'}
    $script:PcC=[pscustomobject]@{Type='Machine';Login='PC-C$';Name='PC-C';DN='CN=PC-C,DC=example,DC=invalid';Guid='cccccccc-cccc-cccc-cccc-cccccccccccc'}
    Initialize-DomeniaRelationsState
    if($null -ne $script:Window){
        $script:Window.FindName('RelationTabs').SelectedItem=$script:Window.FindName('TabLinksSelected')
        $script:Window.FindName('TxtRelationComputerSearch').Text='';$script:Window.FindName('TxtRelationScanLimit').Text='20'
        $script:Window.FindName('CmbRelationScanScope').SelectedIndex=0;$script:Window.FindName('ChkRelationEvents').IsChecked=$false
        $script:Relations.Bound=$true
    }
}
function Get-Machine {param([string]$Name,[string]$Guid,[string]$Ou='OU=Test,DC=example,DC=invalid');return [pscustomobject]@{Type='Machine';Name=$Name;DN=('CN='+$Name+','+$Ou);Guid=$Guid;Login=($Name+'$')}}
function Find-Relations {param([string]$Computer);return @(@(Get-DomeniaRelationsAllRelations)|Where-Object{(Normalize-LinkComputer ([string]$_.Computer)) -eq (Normalize-LinkComputer $Computer)})}
function Start-ManualSearchFor {
    # Real in-page manual search: Start (Searching), worker result (Candidate).
    param([string]$Term,[object[]]$Rows)
    $script:Window.FindName('TxtRelationComputerSearch').Text=$Term
    Start-DomeniaRelationComputerSearch
    $sub=$script:Submission
    Complete-DomeniaRelationComputerSearch ([pscustomobject]@{Rows=@($Rows);RequestId=$sub.Payload.RequestId;Verified=$false;Capped=$false}) $sub.State
    return $sub
}
function Begin-FakeQuery {
    param($Subject=$script:Alice,[string]$Phase='',$Plan=$null,[int]$Planned=0)
    Set-DomeniaRelationsSelection -Row $Subject
    $state=[pscustomobject]@{Epoch=$script:SessionEpoch;BaseDn=$script:Conn.BaseDn;Generation=$script:Relations.Generation;DN=$Subject.DN;Guid=$Subject.Guid;Login=$Subject.Login;RequestId='request-1';Identity=(Get-DomeniaRelationsIdentity);Phase=$Phase;Limit=20}
    $counters=if($Planned){New-DomeniaDetectionCounters $Planned}else{$null}
    $script:Relations.Query=[pscustomobject]@{State=$state;RequestId=$state.RequestId;Progress=[Collections.Concurrent.ConcurrentQueue[object]]::new();Candidates=@{};Hints=[Collections.ArrayList]::new();Attempts=[Collections.ArrayList]::new();Ended=$false;AcceptResults=$true;Job='mock-job';Phase=$Phase;Plan=$Plan;Counters=$counters}
    $script:AsyncJobs['mock-job']=[pscustomobject]@{CancelRequested=$false};return $state
}
function New-WorkerResult {
    param([object[]]$Candidates=@(),[object[]]$Hints=@(),[object[]]$Attempts=@(),[string[]]$Probed=@(),$Subject=$script:Alice,[string]$RequestId='request-1')
    return [pscustomobject]@{Login=$Subject.Login;RequestId=$RequestId;UserDn=$Subject.DN;UserGuid=$Subject.Guid;Success=$true;Partial=$false;Scanned=$true;ScanStats=[pscustomobject]@{Probed=@($Probed).Count};Hints=@($Hints);Attempts=@($Attempts);Candidates=@($Candidates);ProbedGuids=@($Probed)}
}
function New-ProbeResult {param([string]$Raw,[string]$Source='CIM utilisateur courant',[string]$Login='alice',[string]$Computer='PC-A')
    return [pscustomobject]@{Computer=$Computer;UserLogin=$Login;RawAccount=$Raw;Source=$Source;Confidence=97;VerifiedInAD=$true;Details='Test';Attempts=@();Success=$true}
}
# Fake LDAP collections really implement IEnumerable/IDisposable; no DirectoryEntry is constructed.
$fixtureTypes=@'
using System;
using System.Collections;
namespace Domenia.WiringRelationsFixture {
 public class Resource : IDisposable { public bool Disposed; public void Dispose(){Disposed=true;} }
 public class Results : Resource, IEnumerable { readonly object[] rows; public Results(object[] values){rows=values;} public IEnumerator GetEnumerator(){return rows.GetEnumerator();} }
}
'@
function Invoke-RelationsWorkerFixture {
    # The real UserComputerProbe worker, Loaded perimeter with confirmed GUIDs; LDAP and CIM are doubles.
    param([string[]]$Targets=@())
    $script:WiringTrace=[pscustomobject]@{Probes=[Collections.ArrayList]::new()}
    $Context=[pscustomobject]@{BaseDn='DC=example,DC=invalid';Server='dc.example.invalid';Domain='example.invalid';Netbios='EXAMPLE';Credential=$null;MachineCredential=$null;UseCim=$true;RelationRemoteBlocked=$false}
    $sid=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1001');$sidBytes=[byte[]]::new($sid.BinaryLength);$sid.GetBinaryForm($sidBytes,0)
    $script:WiringUser=[pscustomobject]@{Properties=@{samaccountname=@('alice');userprincipalname=@('alice@example.invalid');objectguid=@(,([guid]'11111111-1111-1111-1111-111111111111').ToByteArray());objectsid=@(,$sidBytes)}}
    $script:WiringPcB=[pscustomobject]@{Properties=@{name=@('PC-B');dnshostname=@('pc-b.example.invalid');distinguishedname=@('CN=PC-B,DC=example,DC=invalid');objectguid=@(,([guid]'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb').ToByteArray());description=@('Materiel');managedby=@('')}}
    $Payload=[pscustomobject]@{Login='alice';UserDn='CN=Alice,DC=example,DC=invalid';UserGuid='11111111-1111-1111-1111-111111111111';RequestId='fixture';BudgetMs=120000;MaxProbes=5;KnownLinks=@();ScanPark=$true;ScanScope='Loaded';ScanBaseDn='OU=Test,DC=example,DC=invalid';ScanDepth='Subtree';LoadedComputers=@('PC-B');LoadedTargets=@($Targets);UseSecurityLog=$false;Progress=[Collections.Concurrent.ConcurrentQueue[object]]::new()}
    . ([scriptblock]::Create($script:GuidHelpers))
    function Escape-WLdap {param($Value);return ([string]$Value).Replace('\','\5c').Replace('*','\2a').Replace('(','\28').Replace(')','\29')}
    function Get-WMachineCredential {param($Context);return $null}
    function Get-WAdCredential {param($Context);return $null}
    function New-WSearcher {
        param($Context,$Root,$Filter,$Properties,$SearchScope,$Maximum)
        $found=@()
        if($SearchScope -eq 'Base'){$found=@($script:WiringUser)}elseif($Filter.Contains('PC-B')){$found=@($script:WiringPcB)}
        $results=[Domenia.WiringRelationsFixture.Results]::new([object[]]$found);$owned=[Domenia.WiringRelationsFixture.Resource]::new()
        $searcher=[pscustomobject]@{Rows=$results;SearchRoot=$owned;PageSize=0;CacheResults=$true;ServerTimeLimit=[timespan]::Zero;ClientTimeout=[timespan]::Zero}
        $searcher|Add-Member ScriptMethod FindAll {return ,$this.Rows};$searcher|Add-Member ScriptMethod Dispose {};return $searcher
    }
    function New-CimSessionOption {param($Protocol,$ErrorAction);return 'DCOM-fictif'}
    function New-CimSession {param($ComputerName,$SessionOption,$OperationTimeoutSec,$ErrorAction,$Credential);[void]$script:WiringTrace.Probes.Add([string]$ComputerName);return [pscustomobject]@{Name=$ComputerName}}
    function Get-CimInstance {param($CimSession,$ClassName,$Property,$OperationTimeoutSec,$ErrorAction);return [pscustomobject]@{Name=(([string]$CimSession.Name) -split '\.')[0];UserName='EXAMPLE\alice'}}
    function Remove-CimSession {param($CimSession,$ErrorAction)}
    function Get-WinEvent {throw 'Aucun journal lu dans ce test'}
    $out=@(& ([scriptblock]::Create($script:RelationsWorker)))
    $r=@($out|Where-Object{$null -ne $_ -and $null -ne $_.PSObject.Properties['RequestId'] -and $null -ne $_.PSObject.Properties['Candidates']})
    Expect ($r.Count -eq 1) ('Resultat worker unique requis : '+$out.Count)
    return [pscustomobject]@{Result=$r[0];Trace=$script:WiringTrace}
}
function Invoke-LastUserWorkerFixture {
    # The real ComputerLastUser worker with the real Normalize-WUser and Test-WUserInAd; CIM, LDAP and fallbacks are doubles.
    param([string]$Current,[string]$LogonUi)
    $script:FixtureCurrent=$Current;$script:FixtureLogonUi=$LogonUi
    $Context=[pscustomobject]@{BaseDn='DC=example,DC=invalid';Netbios='EXAMPLE';Domain='example.invalid';UseWinRM=$false;UseCredential=$false;BindUser='';ProcessIdentity='EXAMPLE\windows-user';TaskFallbackTimeoutSeconds=30;MachineCredential=$null}
    $Payload=[pscustomobject]@{Computer='PC-A';ClassicTimeoutMs=7000;TaskFallbackTimeoutSeconds=18;MethodTimeoutMs=2500;AllowUnboundedFallbacks=$false;UseRemoteRegistry=$true;UseSecurityLog=$false;UseProfilesShare=$false;Progress=$null}
    . ([scriptblock]::Create($script:WorkerHelpers))
    function Escape-WLdap {param($Value);return [string]$Value}
    function Get-WMachineCredential {param($Context);return $null}
    function New-WSearcher {
        param($Context,$Root,$Filter,$Properties,$SearchScope,$Maximum)
        $owned=[pscustomobject]@{};$owned|Add-Member ScriptMethod Dispose {}
        $searcher=[pscustomobject]@{SearchRoot=$owned};$searcher|Add-Member ScriptMethod FindOne {return [pscustomobject]@{Name='alice'}};$searcher|Add-Member ScriptMethod Dispose {};return $searcher
    }
    function New-WDomeniaCimSession {param($Context,$Computer,$Credential,$TimeoutSeconds);return [pscustomobject]@{TestOnly=$true}}
    function Remove-WDomeniaCimSession {param($Session)}
    function Get-CimInstance {[CmdletBinding()]param($CimSession,$ClassName,$Property,[int]$OperationTimeoutSec);if($ClassName -eq 'Win32_UserProfile'){return @()};return [pscustomobject]@{UserName=$script:FixtureCurrent}}
    function Invoke-CimMethod {[CmdletBinding()]param($CimSession,$Namespace,$ClassName,$MethodName,$Arguments,[int]$OperationTimeoutSec);return [pscustomobject]@{ReturnValue=[uint32]0;sValue=$script:FixtureLogonUi}}
    function Test-WTcpPort {param($Computer,$Port,$Timeout);return $false}
    function Get-WProbeAttemptSummary {param($Attempts);return ''}
    function Invoke-WRemoteTaskScript {param($Context,$Computer,$ScriptText,$InputObject,$TimeoutSeconds,$ClassicError);throw 'TEST : secours distant interdit'}
    $out=@(& ([scriptblock]::Create($script:LastUserWorker)))
    $r=@($out|Where-Object{$null -ne $_ -and $null -ne $_.PSObject.Properties['Success']})
    Expect ($r.Count -ge 1) 'Aucun resultat du worker ComputerLastUser.'
    return $r[-1]
}
try {
    Expect ($PSVersionTable.PSEdition -eq 'Desktop' -and [int]$PSVersionTable.PSVersion.Major -eq 5 -and [Environment]::Is64BitProcess -and [Threading.Thread]::CurrentThread.ApartmentState -eq 'STA') 'Windows PowerShell 5.1 x64 STA requis.'
    $script:WindowsExecuted=$true
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    $script:TempRoot=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-wiring-relations-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($script:TempRoot)
    $core=Parse-Source (Join-Path $wad 'Domenia-Core.ps1')
    $definitions=[Collections.Generic.List[string]]::new()
    foreach($name in @('Get-MainXaml','Normalize-LinkComputer','Normalize-LinkUser','Rebuild-UserMachineLinkIndex','Ensure-UserMachineLinkIndex','Get-LinksForComputer','Get-LinksForUser','Get-ExistingLinkForComputer','Find-DomeniaCachedUserRow','Find-DomeniaCachedComputerRow','Add-UserMachineLinkIfMissing','ConvertTo-DomeniaCanonicalLinks','Remove-SelectedLink','Start-ComputerUserLinkProbe')){$definitions.Add((Get-SourceFunctionText $core $name))}
    foreach($pair in @(@('modules\Domenia-Live.UI.ps1','Merge-DomeniaLiveLinkMemory'),@('modules\Domenia-Storage.UI.ps1','Queue-DomeniaLinkChanges'),@('modules\Domenia-Storage.UI.ps1','Reset-DomeniaLinkBaseline'),@('modules\Domenia-Guard.Model.ps1','ConvertTo-DomeniaLinkRecord'),@('modules\Domenia-Guard.Model.ps1','Get-DomeniaLinkFingerprint'),@('modules\Domenia-Live.Model.ps1','Get-DomeniaLiveHash'))){
        $definitions.Add((Get-SourceFunctionText (Parse-Source (Join-Path $wad $pair[0])) $pair[1]))
    }
    . ([scriptblock]::Create(($definitions.ToArray() -join "`n")))
    . (Join-Path $wad 'modules\Domenia-Common.Model.ps1')
    . (Join-Path $wad 'modules\Domenia-Relations.Model.ps1')
    . (Join-Path $wad 'modules\Domenia-Embedded.UI.ps1')
    . (Join-Path $wad 'modules\Domenia-Relations.UI.ps1')
    $coreText=[IO.File]::ReadAllText((Join-Path $wad 'Domenia-Core.ps1'))
    $commonMatch=[regex]::Match($coreText,"(?ms)^\`$script:WorkerCommon\s*=\s*@'\r?\n(.*?)\r?\n'@")
    Expect $commonMatch.Success 'WorkerCommon introuvable.'
    $ct=$null;$ce=$null;$commonAst=[Management.Automation.Language.Parser]::ParseInput($commonMatch.Groups[1].Value,[ref]$ct,[ref]$ce)
    Expect (@($ce).Count -eq 0) ($ce|Out-String)
    $script:WorkerHelpers=(@($commonAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Normalize-WUser','Test-WUserInAd')},$true))|ForEach-Object{$_.Extent.Text}) -join "`n"
    $script:GuidHelpers=(@($commonAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Get-WPropFirst','Convert-WGuid')},$true))|ForEach-Object{$_.Extent.Text}) -join "`n"
    Add-Type -TypeDefinition $fixtureTypes
    $probeFunction=@($core.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-ComputerUserLinkProbe'},$true))[0]
    $workerStrings=@($probeFunction.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.StartsWith('$attempts = New-Object')},$true))
    Expect ($workerStrings.Count -eq 1) 'Corps ComputerLastUser introuvable.'
    $script:LastUserWorker=[string]$workerStrings[0].Value
    $script:RelationsWorker=Get-DomeniaRelationsWorkerCode

    Case 'Chargeur ferme : modules Relations declares avec toutes leurs fonctions' {
        $ps=[PowerShell]::Create()
        try{
            $names=@()
            foreach($file in @('Domenia-Relations.Model.ps1','Domenia-Relations.UI.ps1')){$names+=@((Parse-Source (Join-Path $wad ('modules\'+$file))).EndBlock.Statements|Where-Object{$_ -is [Management.Automation.Language.FunctionDefinitionAst]}|ForEach-Object{$_.Name})}
            [void]$ps.AddScript('param($path,$names) $ErrorActionPreference="Stop"; . $path; @($names|Where-Object{$null -eq (Get-Command -Name $_ -CommandType Function -ErrorAction SilentlyContinue)})').AddArgument((Join-Path $wad 'Domenia-Modules.ps1')).AddArgument([string[]]$names)
            $missing=@($ps.Invoke())
            Expect (-not $ps.HadErrors) (($ps.Streams.Error|ForEach-Object{$_.ToString()}) -join '; ')
            Expect ($missing.Count -eq 0) ('Fonctions non chargees : '+($missing -join ', '))
        }finally{$ps.Dispose()}
    }

    # ------------------------------------------------------------ non-visual cases
    $script:Ctrl=@{}
    Case 'D042 Console d un autre compte : l affectation declaree reste, les deux relations restent visibles' {
        Reset-Fixture;$state=Begin-FakeQuery
        $r=New-WorkerResult -Candidates @([pscustomobject]@{Computer='PC-B';Guid='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';DN='CN=PC-B,DC=example,DC=invalid';Confirmed=$true;ObservedUtc='2026-03-01T08:00:00Z';Source='Console CIM/DCOM';Detail='Console observee'})
        Save-DomeniaRelationConfirmations $r $state
        $stored=@(Get-LinksForComputer 'PC-B');Expect ($stored.Count -eq 1 -and $stored[0].UserLogin -eq 'bob' -and $stored[0].Source -eq 'Saisie manuelle') 'Affectation declaree remplacee'
        $all=Find-Relations 'PC-B';Expect ($all.Count -eq 2) ('Relations sur PC-B : '+$all.Count)
        $alice=@($all|Where-Object{$_.UserLogin -eq 'alice'})[0];Expect ($alice.Kind -eq 'Console' -and [int]$alice.Confidence -eq 0) 'Observation sans nature ou avec un score fixe'
        Expect (@($script:Relations.History|Where-Object{$_.Action -eq 'Added' -and $_.Relation.UserLogin -eq 'alice'}).Count -eq 1) 'Ajout non journalise'
        Expect ($script:Messages['Status'] -match 'Contradictoire') 'Conflit non signale'
    }
    Case 'D042 Canonique : l affectation declaree n est pas evincee par une observation plus recente' {
        Reset-Fixture
        $links=@([pscustomobject]@{UserLogin='alice';Computer='PC-1';Source='Saisie manuelle';When='2026-01-01 08:00:00'},[pscustomobject]@{UserLogin='adm-x';Computer='PC-1';Source='Console CIM/DCOM';When='2026-02-01 08:00:00'})
        $single=@(ConvertTo-DomeniaCanonicalLinks -Links $links)
        Expect ($single.Count -eq 1 -and $single[0].UserLogin -eq 'alice' -and $single[0].Kind -eq 'Affectation' -and $single[0].StorageKey -eq 'PC-1') 'Stockage a une ligne : la ligne doit etre l affectation'
        $script:DomeniaLinkStoreMultiRelation=$true
        $multi=@(ConvertTo-DomeniaCanonicalLinks -Links $links)
        Expect ($multi.Count -eq 2 -and $multi[0].UserLogin -eq 'alice' -and $multi[0].StorageKey -eq 'PC-1' -and $multi[1].StorageKey.StartsWith('PC-1|')) 'Stockage par relation : deux lignes, affectation en premier'
        $again=@(ConvertTo-DomeniaCanonicalLinks -Links @($links+@([pscustomobject]@{UserLogin='ALICE';Computer='pc-1.example.invalid';Source='Manual';When='2025-12-01 08:00:00'})))
        Expect ($again.Count -eq 2) 'Meme relation dupliquee'
    }
    Case 'D042 File de stockage reelle : l affectation declaree devient la ligne enregistree du poste' {
        Reset-Fixture;$script:UseRealQueue=$true
        $script:Persistence=[pscustomobject]@{Pending=@{};Job='';Next=[datetime]::MinValue;Fault='';Failures=0;LinkBusy=$false;Timer=$null;LinkRequestTimer=$null;LinkPersistenceMore=$false}
        $script:UserMachineLinks=@([pscustomobject]@{UserLogin='adm-x';Computer='PC-1';Source='Console CIM/DCOM';Confidence=0;VerifiedInAD=$true;When='2026-01-01 08:00:00';Details='';UserGuid='';ComputerGuid='';UserDn='';ComputerDn=''})
        Reset-DomeniaLinkBaseline
        $added=Add-UserMachineLinkIfMissing -UserLogin 'alice' -Computer 'PC-1' -Source 'Saisie manuelle' -Details 'Declaration' -Declarant 'EXAMPLE\reader'
        Expect $added 'Affectation non enregistree'
        $items=@($script:Persistence.Pending.Values|Where-Object{$_.Kind -eq 'Link'})
        Expect ($items.Count -eq 1 -and $items[0].Key -eq 'PC-1' -and $items[0].Row.UserLogin -eq 'alice' -and $items[0].Row.Source -eq 'Saisie manuelle') 'La ligne PC-1 envoyee au stockage n est pas l affectation'
        Expect (@(Find-Relations 'PC-1').Count -eq 2) 'Observation precedente perdue en session'
        $script:Persistence.Pending=@{};$script:Persistence.LinkBusy=$false;Reset-DomeniaLinkBaseline
        [void](Add-UserMachineLinkIfMissing -UserLogin 'adm-y' -Computer 'PC-1' -Source 'Console CIM/DCOM' -Details 'Observation')
        Expect (@($script:Persistence.Pending.Values).Count -eq 0) 'Une observation a remplace l affectation dans le stockage'
    }
    Case 'D049 Postes partages : une seconde declaration n ecrase pas la premiere' {
        Reset-Fixture;$script:UserMachineLinks=@();Rebuild-UserMachineLinkIndex
        Expect (Add-UserMachineLinkIfMissing -UserLogin 'alice' -Computer 'PC-1' -Source 'Saisie manuelle')
        [void](Add-UserMachineLinkIfMissing -UserLogin 'bob' -Computer 'PC-1' -Source 'Saisie manuelle')
        $stored=@(Get-LinksForComputer 'PC-1');Expect ($stored.Count -eq 1 -and $stored[0].UserLogin -eq 'alice') 'Declaration d alice ecrasee'
        Expect (@(Find-Relations 'PC-1').Count -eq 2) 'Declaration de bob perdue'
        $script:DomeniaLinkStoreMultiRelation=$true
        [void](Add-UserMachineLinkIfMissing -UserLogin 'carol' -Computer 'PC-1' -Source 'Saisie manuelle')
        Expect (@(Get-LinksForComputer 'PC-1').Count -eq 2) 'Stockage par relation : la seconde declaration doit etre enregistree'
    }
    Case 'D042 Observation Live d un autre compte : ajoutee, sans ecraser ni score fixe' {
        Reset-Fixture
        $obs=[pscustomobject]@{Outcome='Observed';LinkUser='bob';UserDn='CN=Bob,DC=example,DC=invalid';Computer='PC-A';ObservedUtc='2026-03-01T08:00:00Z';UserGuid='22222222-2222-2222-2222-222222222222';Guid='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';Key='CN=PC-A,DC=example,DC=invalid'}
        Merge-DomeniaLiveLinkMemory $obs
        $all=Find-Relations 'PC-A';Expect ($all.Count -eq 2) ('Relations sur PC-A : '+$all.Count)
        Expect (@($all|Where-Object{$_.UserLogin -eq 'alice'}).Count -eq 1) 'Observation d alice ecrasee'
        Expect (@($all|Where-Object{$_.UserLogin -eq 'bob' -and [int]$_.Confidence -eq 0}).Count -eq 1) 'Observation de bob absente ou score fixe'
        Expect ($script:SaveCount -eq 0) 'Observation automatique enregistree par la file de liens'
    }
    Case 'D043 Aucun score fixe ecrit par les confirmations de console' {
        Reset-Fixture;$state=Begin-FakeQuery
        $r=New-WorkerResult -Candidates @([pscustomobject]@{Computer='PC-C';Guid='cccccccc-cccc-cccc-cccc-cccccccccccc';DN='CN=PC-C,DC=example,DC=invalid';Confirmed=$true;ObservedUtc='2026-02-01T00:00:00Z';Source='Console CIM/DCOM';Detail='Console observee'})
        Save-DomeniaRelationConfirmations $r $state
        $c=@(Get-LinksForComputer 'PC-C');Expect ($c.Count -eq 1 -and [int]$c[0].Confidence -eq 0 -and $script:SaveCount -eq 1) 'Score fixe ou lien absent'
        $b=Get-DomeniaEvidenceBadge $c[0];Expect ($b.Badge -eq 'Observe' -and -not (($b.Badge+$b.Rule+$b.Provenance) -match '97|%'))
    }
    Case 'D045 Confirmer sans cible : refus explicite, aucune tache' {
        Reset-Fixture;Set-DomeniaRelationsSelection -Row $script:Alice
        Confirm-DomeniaRelationAssociation
        Expect ($script:Relations.AssociationState -eq 'Idle' -and $script:Messages['LblRelationConfirm'] -match 'impossible' -and $script:Submissions.Count -eq 0) 'Refus non explique'
    }
    Case 'D045 Aucun ShowDialog, fenetre ni boite modale dans le parcours d association' {
        $ui=Parse-Source (Join-Path $wad 'modules\Domenia-Relations.UI.ps1');$embedded=Parse-Source (Join-Path $wad 'modules\Domenia-Embedded.UI.ps1')
        $names=@('Start-DomeniaRelationComputerSearch','Complete-DomeniaRelationComputerSearch','Set-DomeniaRelationPendingAssociation','Request-DomeniaRelationManualAssociation','Cancel-DomeniaRelationAssociation','Confirm-DomeniaRelationAssociation','Complete-DomeniaRelationAssociationVerify','Fail-DomeniaRelationAssociationVerify','Use-DomeniaRelationCandidate','Start-DomeniaRelationsSearch','Show-DomeniaRelationDetectionPlan','Confirm-DomeniaRelationDetectionPlan','Step-DomeniaRelationsAssociation')
        foreach($n in $names){$t=Get-SourceFunctionText $ui $n;Expect (-not ($t -match '(?i)ShowDialog|Show-DomeniaInlinePicker|Confirm-Action|Windows\.Window\b|System\.Windows\.Window\b|Show-DomeniaDialog')) ('Fenetre ou boite modale dans '+$n)}
        $t=Get-SourceFunctionText $embedded 'Select-DomeniaRelationsUser';Expect (-not ($t -match '(?i)ShowDialog|Show-DomeniaInlinePicker|Windows\.Window\b')) 'Select-DomeniaRelationsUser ouvre encore une fenetre'
    }
    Case 'D046 Un candidat explique pourquoi ; une IP ne suffit pas a associer' {
        Reset-Fixture;$state=Begin-FakeQuery
        $r=New-WorkerResult -Candidates @(
            [pscustomobject]@{Computer='PC-A';Dns='pc-a.example.invalid';DN='CN=PC-A,DC=example,DC=invalid';Guid='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';Source='Association mémorisée';Status='Historique connu';Detail='Observation anterieure';ObservedUtc='2026-01-01';CurrentUser='';Confirmed=$false;Known=$true},
            [pscustomobject]@{Computer='PC-B';Dns='pc-b.example.invalid';DN='CN=PC-B,DC=example,DC=invalid';Guid='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';Source='Responsable déclaré';Status='Responsable déclaré';Detail='managedBy';ObservedUtc='';CurrentUser='';Confirmed=$false;Known=$false}
        ) -Hints @([pscustomobject]@{Computer='192.0.2.42';Dns='';DN='';Guid='';Source='Événement Kerberos 4768';Status='Indice IP, pas un poste identifié';Detail='IP';ObservedUtc='2026-01-01';CurrentUser='alice';Confirmed=$false;Known=$false})
        Complete-DomeniaRelationsSearch $r $state
        $rows=@(@($script:Relations.Query.Candidates.Values)+@($script:Relations.Query.Hints))
        $a=@($rows|Where-Object{$_.Computer -eq 'PC-A'})[0];$ip=@($rows|Where-Object{$_.Computer -eq '192.0.2.42'})[0];$b=@($rows|Where-Object{$_.Computer -eq 'PC-B'})[0]
        Expect ($a.Why -match 'deja connu' -and $a.Origins -match 'memorisee' -and $a.Associable) 'Candidat connu sans motif'
        Expect ($b.Why -match 'Indice' -and $b.Badge -eq 'Indice') 'Indice managedBy sans motif ou presente comme affectation'
        Expect ($ip.Associable -eq $false -and $ip.Blocker -match 'ne suffit pas') 'Une IP peut etre associee'
    }
    Case 'D047 Sonde hors du plan confirme : aucun resultat enregistre' {
        Reset-Fixture;Set-DomeniaRelationsSelection -Row $script:Alice
        $plan=Get-DomeniaDetectionScopePlan -RequestedScope Loaded -Candidates @([pscustomobject]@{Guid='10000000-0000-0000-0000-000000000001';Computer='PC-1';Domain=$script:Conn.BaseDn}) -Limit 5
        $state=Begin-FakeQuery -Phase 'Probe' -Plan $plan -Planned 1
        $r=New-WorkerResult -Probed @('99999999-0000-0000-0000-000000000009') -Candidates @([pscustomobject]@{Computer='PC-9';Guid='99999999-0000-0000-0000-000000000009';DN='CN=PC-9,DC=example,DC=invalid';Confirmed=$true;ObservedUtc='2026-02-01T00:00:00Z';Source='Console CIM/DCOM';Detail='Console'})
        Complete-DomeniaRelationsSearch $r $state
        Expect ($script:SaveCount -eq 0 -and @(Find-Relations 'PC-9').Count -eq 0) 'Resultat hors plan enregistre'
        Expect ($script:Messages['LblLinkProbeStatus'] -match 'différente de la liste confirmée') 'Ecart de liste non signale'
    }
    Case 'D047 Worker : seul l objet AD confirme (GUID) est sonde' {
        $out=Invoke-RelationsWorkerFixture -Targets @('ffffffff-ffff-ffff-ffff-ffffffffffff')
        Expect ($out.Trace.Probes.Count -eq 0 -and @($out.Result.Attempts|Where-Object{$_.Status -eq 'A_REVOIR' -and $_.Detail -match 'confirm'}).Count -eq 1) 'Poste hors liste confirmee sonde'
        $out=Invoke-RelationsWorkerFixture -Targets @('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb')
        Expect ($out.Trace.Probes.Count -eq 1 -and @($out.Result.ProbedGuids).Count -eq 1 -and $out.Result.ProbedGuids[0] -eq 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') 'Poste confirme non sonde ou non declare'
    }
    Case 'D048 Une origine de liste ne declenche aucune sonde' {
        Reset-Fixture
        Start-ComputerUserLinkProbe -Computer 'PC-Z' -Origin 'ListRender'
        Expect ($script:Submissions.Count -eq 0) 'Sonde lancee par le rendu d une liste'
        Start-ComputerUserLinkProbe -Computer 'PC-Z' -Origin 'SelectedMachine'
        Expect ($script:Submissions.Count -eq 1 -and $script:Submission.Operation -eq 'ComputerLastUser') 'Sonde de la machine selectionnee absente'
    }
    Case 'D048 Compteurs interroges, refuses, confirmes et restants' {
        Reset-Fixture;Set-DomeniaRelationsSelection -Row $script:Alice
        $cands=@([pscustomobject]@{Guid='10000000-0000-0000-0000-000000000001';Computer='PC-1';Domain=$script:Conn.BaseDn},[pscustomobject]@{Guid='10000000-0000-0000-0000-000000000002';Computer='PC-2';Domain=$script:Conn.BaseDn})
        $plan=Get-DomeniaDetectionScopePlan -RequestedScope Loaded -Candidates $cands -Limit 5
        $state=Begin-FakeQuery -Phase 'Probe' -Plan $plan -Planned 2
        $attempt=[pscustomobject]@{Method='Console CIM/DCOM';Status='CONFIRME';User='PC-1';Detail='Console';Resource='Remote';Code=0}
        $script:Relations.Query.Progress.Enqueue([pscustomobject]@{RequestId='request-1';Kind='Attempt';Value=$attempt})
        Invoke-DomeniaRelationsTick
        Expect ($script:Messages['LblLinkProbeStatus'] -match '1 interroge\(s\) sur 2' -and $script:Messages['LblLinkProbeStatus'] -match '1 restant') ('Progression : '+$script:Messages['LblLinkProbeStatus'])
        $r=New-WorkerResult -Probed @($cands[0].Guid,$cands[1].Guid) -Attempts @($attempt,[pscustomobject]@{Method='Console CIM/DCOM';Status='REFUSE';User='PC-2';Detail='Refus';Resource='Remote';Code=0})
        Complete-DomeniaRelationsSearch $r $state
        Expect ($script:Messages['LblLinkProbeStatus'] -match '2 interroge\(s\) sur 2' -and $script:Messages['LblLinkProbeStatus'] -match '1 refuse' -and $script:Messages['LblLinkProbeStatus'] -match 'partiel') ('Fin : '+$script:Messages['LblLinkProbeStatus'])
    }
    Case 'D048 Arret : compteur et resultat partiel annonces' {
        Reset-Fixture;Set-DomeniaRelationsSelection -Row $script:Alice
        $plan=Get-DomeniaDetectionScopePlan -RequestedScope Loaded -Candidates @([pscustomobject]@{Guid='10000000-0000-0000-0000-000000000001';Computer='PC-1';Domain=$script:Conn.BaseDn}) -Limit 5
        [void](Begin-FakeQuery -Phase 'Probe' -Plan $plan -Planned 1)
        Stop-DomeniaRelationsSearch
        Expect ($script:Messages['LblLinkProbeStatus'] -match 'partiel') 'Arret sans resultat partiel'
    }
    Case 'D049 Compte local, autre domaine ou nom nu : aucun lien' {
        foreach($raw in @('PC-A\alice','AUTRE\alice','alice')){
            Reset-Fixture;$script:ActiveLinkProbeId='p1';$script:SelectedObject=[pscustomobject]@{Type='Machine';Name='PC-A'};$script:CurrentComputer='PC-A';$script:UserMachineLinks=@();Rebuild-UserMachineLinkIndex
            Complete-DomeniaRelationsComputerProbe (New-ProbeResult $raw) ([pscustomobject]@{Computer='PC-A';ProbeId='p1'})
            Expect (@(Get-DomeniaRelationsAllRelations).Count -eq 0) ('Lien cree pour '+$raw)
            Expect ($script:Messages['LblLinkProbeStatus'] -match 'Aucune association' -and $script:ActiveLinkProbeId -eq '') ('Refus non explique pour '+$raw)
        }
        Reset-Fixture;$script:ActiveLinkProbeId='p1';$script:SelectedObject=[pscustomobject]@{Type='Machine';Name='PC-A'};$script:CurrentComputer='PC-A';$script:UserMachineLinks=@();Rebuild-UserMachineLinkIndex
        Complete-DomeniaRelationsComputerProbe (New-ProbeResult 'EXAMPLE\alice') ([pscustomobject]@{Computer='PC-A';ProbeId='p1'})
        $l=@(Get-LinksForComputer 'PC-A');Expect ($l.Count -eq 1 -and $l[0].UserLogin -eq 'alice' -and $l[0].Kind -eq 'Console') 'Compte du domaine non associe'
    }
    Case 'D049 Historique LogonUI : indice affiche, aucun lien automatique' {
        Reset-Fixture;$script:ActiveLinkProbeId='p1';$script:SelectedObject=[pscustomobject]@{Type='Machine';Name='PC-A'};$script:CurrentComputer='PC-A';$script:UserMachineLinks=@();Rebuild-UserMachineLinkIndex
        Complete-DomeniaRelationsComputerProbe (New-ProbeResult 'EXAMPLE\alice' 'CIM dernier utilisateur LogonUI') ([pscustomobject]@{Computer='PC-A';ProbeId='p1'})
        Expect (@(Get-DomeniaRelationsAllRelations).Count -eq 0 -and $script:Messages['LblLinkProbeStatus'] -match 'Indice') 'Historique transforme en lien'
    }
    Case 'D049 Resultat rattache au sujet Relations meme si la fiche montre un autre poste' {
        Reset-Fixture;$script:UserMachineLinks=@();Rebuild-UserMachineLinkIndex;Set-DomeniaRelationsSelection -Row $script:PcA
        $script:ActiveLinkProbeId='p1';$script:SelectedObject=[pscustomobject]@{Type='Machine';Name='PC-B'};$script:CurrentComputer='PC-B'
        Complete-DomeniaRelationsComputerProbe (New-ProbeResult 'EXAMPLE\alice') ([pscustomobject]@{Computer='PC-A';ProbeId='p1';RelationsSubject=(Get-DomeniaRelationsSubjectIdentity)})
        Expect (@(Get-LinksForComputer 'PC-A').Count -eq 1) 'Resultat du sujet Relations rejete'
        Reset-Fixture;$script:UserMachineLinks=@();Rebuild-UserMachineLinkIndex;$script:ActiveLinkProbeId='p2';$script:SelectedObject=[pscustomobject]@{Type='Machine';Name='PC-B'};$script:CurrentComputer='PC-B'
        Complete-DomeniaRelationsComputerProbe (New-ProbeResult 'EXAMPLE\alice') ([pscustomobject]@{Computer='PC-A';ProbeId='p2'})
        Expect (@(Get-LinksForComputer 'PC-A').Count -eq 0) 'Resultat accepte sans sujet ni fiche correspondants'
    }
    Case 'D049 Worker : compte local ignore, source suivante du domaine retenue' {
        $out=Invoke-LastUserWorkerFixture -Current 'PC-A\alice' -LogonUi 'EXAMPLE\alice'
        Expect ($out.Success -and $out.Source -eq 'CIM dernier utilisateur LogonUI' -and $out.RawAccount -eq 'EXAMPLE\alice') ('Resultat : '+$out.Source+' '+$out.RawAccount)
        Expect (@($out.Attempts|Where-Object{$_.Status -eq 'COMPTE LOCAL'}).Count -eq 1) 'Compte local non signale'
        $out=Invoke-LastUserWorkerFixture -Current 'AUTRE\alice' -LogonUi 'AUTRE\alice'
        Expect (-not $out.Success -and @($out.Attempts|Where-Object{$_.Status -eq 'HORS DOMAINE'}).Count -ge 2) 'Homonyme d un autre domaine retenu'
    }
    Case 'D050 Suppression tracee, journalisee sur disque et restauree sans AD' {
        Reset-Fixture;Set-DomeniaRelationsSelection -Row $script:Alice
        $row=@(Get-LinksForComputer 'PC-A')[0]
        $script:Ctrl=@{RelationTabs=[pscustomobject]@{SelectedItem=[pscustomobject]@{Name='TabLinksSelected'}};DgLinks=[pscustomobject]@{SelectedItem=$row;ItemsSource=$null}}
        Remove-SelectedLink
        Expect ($script:ConfirmCount -eq 1 -and @(Get-LinksForComputer 'PC-A').Count -eq 0 -and $script:SaveCount -eq 1) 'Suppression non effectuee'
        $entry=@($script:Relations.History|Where-Object{$_.Action -eq 'Removed'})[0]
        Expect ($null -ne $entry -and $entry.Key -eq (Get-DomeniaRelationKey $row) -and $entry.Declarant -eq 'EXAMPLE\reader') 'Suppression non tracee'
        $journal=Get-DomeniaRelationsJournalPath;Expect ([IO.File]::Exists($journal) -and ([IO.File]::ReadAllText($journal) -match '"Action":"Removed"')) 'Journal disque absent'
        $before=$script:Submissions.Count
        Expect (Restore-DomeniaRemovedLink) 'Restauration refusee'
        Expect (@(Get-LinksForComputer 'PC-A').Count -eq 1 -and $script:Submissions.Count -eq $before) 'Restauration incomplete ou tache AD lancee'
        Expect (@($script:Relations.History|Where-Object{$_.Action -eq 'Restored'}).Count -eq 1)
        Expect (-not (Restore-DomeniaRemovedLink)) 'Double restauration'
        $script:Ctrl=@{}
    }
    Case 'D050 Restauration apres redemarrage depuis le journal' {
        Reset-Fixture;$path=$script:DatabaseScopedPath;Set-DomeniaRelationsSelection -Row $script:Alice
        Expect (Remove-DomeniaRelation -Relation (@(Get-LinksForComputer 'PC-A')[0]) -Declarant 'EXAMPLE\reader')
        $remaining=@($script:UserMachineLinks)
        Reset-Fixture;$script:DatabaseScopedPath=$path;$script:UserMachineLinks=$remaining;Rebuild-UserMachineLinkIndex
        Expect ($script:Relations.History.Count -eq 0) 'Memoire non reinitialisee'
        Expect (Test-DomeniaRelationsRestoreAvailable) 'Journal disque ignore'
        Expect (Restore-DomeniaRemovedLink) 'Restauration depuis le journal impossible'
        Expect (@(Get-LinksForComputer 'PC-A').Count -eq 1)
    }
    Case 'D050 Suppression confirmee dans la page quand la confirmation integree existe' {
        Reset-Fixture;Set-DomeniaRelationsSelection -Row $script:Alice
        $script:InlineRequests=[Collections.Generic.List[object]]::new()
        function script:Request-DomeniaInlineConfirmation {param([string]$Title,[string]$Message,[string]$Target,[string]$ConfirmText='Confirmer',[string]$CancelText='Annuler',[scriptblock]$OnConfirm,[scriptblock]$OnCancel,[string]$Risk='Normal');$r=[pscustomobject]@{Target=$Target;OnConfirm=$OnConfirm};$script:InlineRequests.Add($r);return $r}
        try{
            $row=@(Get-LinksForComputer 'PC-A')[0]
            $script:Ctrl=@{RelationTabs=[pscustomobject]@{SelectedItem=[pscustomobject]@{Name='TabLinksSelected'}};DgLinks=[pscustomobject]@{SelectedItem=$row;ItemsSource=$null}}
            Remove-SelectedLink
            Expect ($script:ConfirmCount -eq 0 -and $script:InlineRequests.Count -eq 1 -and @(Get-LinksForComputer 'PC-A').Count -eq 1) 'Boite modale utilisee ou suppression immediate'
            & $script:InlineRequests[0].OnConfirm
            Expect (@(Get-LinksForComputer 'PC-A').Count -eq 0) 'Continuation de suppression non executee'
        }finally{Remove-Item -LiteralPath 'Function:\Request-DomeniaInlineConfirmation' -ErrorAction SilentlyContinue;$script:Ctrl=@{}}
    }

    # ------------------------------------------------------------ real WPF controls of the main XAML
    $reader=[Xml.XmlNodeReader]::new([xml](Get-MainXaml))
    try{$w=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    $w.Title='DOMENIA | TEST DE RACCORDEMENT RELATIONS, DONNEES FICTIVES, SANS RESEAU';$w.ShowActivated=$false;$w.ShowInTaskbar=$false;$w.Width=1500;$w.Height=950
    $palette=(Get-Content (Join-Path $wad 'modules\SupportSuite.UI.json') -Raw|ConvertFrom-Json).Palettes.Dark
    $converter=[Windows.Media.BrushConverter]::new();foreach($p in $palette.PSObject.Properties){$w.Resources[$p.Name]=$converter.ConvertFromInvariantString([string]$p.Value)}
    $script:Ctrl=@{};foreach($m in [regex]::Matches((Get-MainXaml),'x:Name="([^"]+)"')){$c=$w.FindName($m.Groups[1].Value);if($null -ne $c){$script:Ctrl[$m.Groups[1].Value]=$c}}
    $script:Window=$w;$w.FindName('WorkspaceTabs').SelectedItem=$w.FindName('TabRelations');$w.Show();Pump $w
    try{
        Case 'D041 Onglet Associer utilisable depuis un poste, recherche d un utilisateur' {
            Reset-Fixture;Set-DomeniaRelationsSelection -Row $script:PcA;Pump $w
            Expect ($w.FindName('TabLinksAssociate').IsEnabled -and $w.FindName('BtnRelationComputerSearch').IsEnabled -and $w.FindName('TxtRelationComputerSearch').IsEnabled) 'Associer grise pour un poste'
            Expect ([string]$w.FindName('BtnDetectUserComputers').Content -eq 'Lire la session de ce poste' -and $w.FindName('BtnDetectUserComputers').IsEnabled) 'Detecter non adapte au poste'
            Expect ($w.FindName('LblRelationAssociateHint').Text -match 'utilisateur' -and [string]$w.FindName('DgRelationComputerSearch').Columns[0].Header -eq 'Utilisateur') 'Libelles non symetriques'
            Expect (-not $w.FindName('CmbRelationScanScope').IsEnabled) 'Perimetre utilisateur propose pour un poste'
            $w.FindName('TxtRelationComputerSearch').Text='al';Start-DomeniaRelationComputerSearch
            Expect ($null -ne $script:Submission -and $script:Submission.Payload.Kind -eq 'Utilisateur' -and $script:Submission.Operation -eq 'EmbeddedDirectoryLookup') 'Recherche d utilisateur non soumise'
        }
        Case 'D041 D045 Parcours poste vers utilisateur complet, dans la page' {
            Reset-Fixture;$script:UserMachineLinks=@();Rebuild-UserMachineLinkIndex;Set-DomeniaRelationsSelection -Row $script:PcA;Pump $w
            $user=[pscustomobject]@{Type='Utilisateur';Name='Alice';Login='alice';Second='alice';DN=$script:Alice.DN;Guid=$script:Alice.Guid;Description=''}
            [void](Start-ManualSearchFor 'ali' @($user))
            Expect ($script:Relations.AssociationState -eq 'Candidate') ('Etat apres resultats : '+$script:Relations.AssociationState)
            $grid=$w.FindName('DgRelationComputerSearch');Pump $w;$grid.SelectedItem=@($grid.Items)[0];Pump $w
            Request-DomeniaRelationManualAssociation
            $p=$script:Relations.PendingAssociation
            Expect ($null -ne $p -and $p.User -eq 'alice' -and $p.Computer -eq 'PC-A' -and $script:Relations.AssociationState -eq 'Pending' -and $w.FindName('RelationConfirmPanel').Visibility -eq 'Visible') 'Confirmation non preparee dans la page'
            Confirm-DomeniaRelationAssociation
            Expect ($script:Relations.AssociationState -eq 'Verifying' -and $script:Submission.Payload.Kind -eq 'Utilisateur' -and $script:Submission.Payload.DN -eq $script:Alice.DN) 'Verification de la cible absente'
            Complete-DomeniaRelationAssociationVerify ([pscustomobject]@{Rows=@($user);Verified=$true;RequestId=$script:Submission.Payload.RequestId}) $script:Submission.State
            $l=@(Get-LinksForComputer 'PC-A')
            Expect ($script:Relations.AssociationState -eq 'Saved' -and $l.Count -eq 1 -and $l[0].UserLogin -eq 'alice' -and $l[0].Kind -eq 'Affectation' -and $l[0].UserGuid -eq $script:Alice.Guid -and $l[0].ComputerGuid -eq $script:PcA.Guid) 'Association poste vers utilisateur non enregistree'
        }
        Case 'D041 Detecter depuis un poste lit sa session, rattachee au sujet' {
            Reset-Fixture;Set-DomeniaRelationsSelection -Row $script:PcA;Pump $w
            Start-DomeniaRelationsSearch
            $s=$script:Submission
            Expect ($null -ne $s -and $s.Operation -eq 'ComputerLastUser' -and $s.Success -eq 'Complete-DomeniaRelationsComputerProbe' -and [string]$s.State.Origin -eq 'ExplicitDetect') 'Lecture de session non lancee'
            Expect ([string]$s.State.RelationsSubject.Guid -eq $script:PcA.Guid) 'Sujet Relations non capture'
        }
        Case 'D044 Choisir un poste dans Rechercher ne remplace pas l utilisateur en attente' {
            Reset-Fixture;Set-DomeniaRelationsSelection -Row $script:Alice;Pump $w
            $pc=[pscustomobject]@{Type='Machine';Name='PC-C';Login='PC-C$';Second='pc-c.example.invalid';DN=$script:PcC.DN;Guid=$script:PcC.Guid;Description=''}
            [void](Start-ManualSearchFor 'pc' @($pc));Set-DomeniaRelationPendingAssociation -Computer 'PC-C' -DN $script:PcC.DN -Guid $script:PcC.Guid -Source 'Recherche AD manuelle'
            $generation=$script:Relations.Generation;$stops=$script:Stops.Count
            Set-DomeniaRelationsSelection -Row $script:PcC
            Expect ($script:Relations.Subject.Login -eq 'alice' -and $null -ne $script:Relations.PendingAssociation -and $script:Relations.Generation -eq $generation -and $script:Stops.Count -eq $stops) 'Sujet remplace avant confirmation'
            Expect ($w.FindName('LblRelationAssociateHint').Text -match 'conserv') 'Refus non explique'
            Cancel-DomeniaRelationAssociation;Set-DomeniaRelationsSelection -Row $script:PcC
            Expect ($script:Relations.Subject.Name -eq 'PC-C') 'Sujet bloque apres annulation'
        }
        Case 'D044 Recherche de cible en cours : un autre utilisateur ne remplace pas le sujet' {
            Reset-Fixture;Set-DomeniaRelationsSelection -Row $script:Alice;$script:Relations.ManualSearchJob='mock-search'
            # A running search is a job the engine still holds: an id unknown to the engine counts as ended.
            $script:AsyncJobs['mock-search']=[pscustomobject]@{Id='mock-search';CancelRequested=$false;OperationId='EmbeddedDirectoryLookup'}
            Set-DomeniaRelationsSelection -Row $script:Bob
            Expect ($script:Relations.Subject.Login -eq 'alice') 'Sujet remplace pendant la recherche'
            Reset-Fixture;Set-DomeniaRelationsSelection -Row $script:Alice;Pump $w
            $pc=[pscustomobject]@{Type='Machine';Name='PC-C';Login='PC-C$';Second='';DN=$script:PcC.DN;Guid=$script:PcC.Guid;Description=''}
            [void](Start-ManualSearchFor 'pc' @($pc))
            Set-DomeniaRelationsSelection -Row $script:PcC
            Expect ($script:Relations.Subject.Login -eq 'alice' -and $script:Relations.AssociationState -eq 'Candidate') 'Sujet remplace pendant le choix parmi les resultats'
            Clear-DomeniaRelationManualResults;Set-DomeniaRelationsSelection -Row $script:PcC
            Expect ($script:Relations.Subject.Name -eq 'PC-C') 'Sujet bloque apres avoir vide la recherche'
        }
        Case 'D044 Confirmation refusee si le compte de lecture a change' {
            Reset-Fixture;Set-DomeniaRelationsSelection -Row $script:Alice;Pump $w
            $pc=[pscustomobject]@{Type='Machine';Name='PC-C';Login='PC-C$';Second='';DN=$script:PcC.DN;Guid=$script:PcC.Guid;Description=''}
            [void](Start-ManualSearchFor 'pc' @($pc));Set-DomeniaRelationPendingAssociation -Computer 'PC-C' -DN $script:PcC.DN -Guid $script:PcC.Guid
            $before=$script:Submissions.Count
            $script:Retry['UserComputerProbe']=[Management.Automation.PSCredential]::new('EXAMPLE\autre',(ConvertTo-SecureString 'FAUX-TEST' -AsPlainText -Force))
            Confirm-DomeniaRelationAssociation
            Expect ($script:Submissions.Count -eq $before -and $null -eq $script:Relations.PendingAssociation -and $script:Messages['LblLinkProbeStatus'] -match 'chang') 'Confirmation acceptee apres changement de compte'
        }
        Case 'D047 Aucun poste connu : lecture AD seule, pas de bascule vers l OU' {
            Reset-Fixture;$script:UserMachineLinks=@();Rebuild-UserMachineLinkIndex;Set-DomeniaRelationsSelection -Row $script:Bob;Pump $w
            $script:BranchObjects=@((Get-Machine 'PC-1' '10000000-0000-0000-0000-000000000001'),(Get-Machine 'PC-2' '10000000-0000-0000-0000-000000000002'),(Get-Machine 'PC-3' '10000000-0000-0000-0000-000000000003'))
            Expect ([string]$w.FindName('CmbRelationScanScope').SelectedItem.Tag -eq 'Candidates') 'Perimetre par defaut different de Candidates'
            Start-DomeniaRelationsSearch
            Expect ($script:Submissions.Count -eq 1 -and -not [bool]$script:Submission.Payload.ScanPark -and $script:Submission.Payload.ScanScope -eq 'Candidates') 'Detection soumise avec sonde ou autre perimetre'
            $sub=$script:Submission;$empty=New-WorkerResult -Subject $script:Bob -RequestId $sub.Payload.RequestId;$empty.Scanned=$false
            Complete-DomeniaRelationsSearch $empty $sub.State
            Expect ($script:Submissions.Count -eq 1 -and $null -eq $script:Relations.PendingPlan) 'Seconde soumission sans confirmation'
            Expect ($script:Messages['LblLinkProbeStatus'] -match 'Aucun poste connu' -and $script:Messages['LblLinkProbeStatus'] -match 'aucune source') 'Zero candidat non explique'
        }
        Case 'D047 Liste chargee tronquee : apercu dans la page, puis liste confirmee seulement' {
            Reset-Fixture;Set-DomeniaRelationsSelection -Row $script:Alice;Pump $w
            $script:BranchObjects=@((Get-Machine 'PC-1' '10000000-0000-0000-0000-000000000001'),(Get-Machine 'PC-2' '10000000-0000-0000-0000-000000000002'),(Get-Machine 'PC-3' '10000000-0000-0000-0000-000000000003'))
            $w.FindName('CmbRelationScanScope').SelectedIndex=1;$w.FindName('TxtRelationScanLimit').Text='2'
            Start-DomeniaRelationsSearch;Pump $w
            Expect ($script:Submissions.Count -eq 0 -and $null -ne $script:Relations.PendingPlan -and [bool]$script:Relations.PendingPlan.Plan.Truncated) 'Sonde lancee sans apercu'
            Expect ($w.FindName('RelationPlanPanel').Visibility -eq 'Visible' -and $w.FindName('DgRelationCandidates').Items.Count -eq 2 -and $w.FindName('LblRelationPlan').Text -match 'tronqu') 'Apercu absent de la page'
            $planned=@($script:Relations.PendingPlan.Plan.Candidates|ForEach-Object{[string]$_.Guid}|Sort-Object)
            Confirm-DomeniaRelationDetectionPlan
            $s=$script:Submission
            Expect ($null -ne $s -and [bool]$s.Payload.ScanPark -and $s.Payload.ScanScope -eq 'Loaded' -and [int]$s.Payload.MaxProbes -eq 2) 'Soumission non conforme au plan'
            Expect ((@($s.Payload.LoadedTargets|Sort-Object) -join ',') -eq ($planned -join ',')) 'Liste interrogee differente de la liste confirmee'
        }
        Case 'D043 Grilles Relations : Qualification et regle, aucun pourcentage' {
            Reset-Fixture;Set-DomeniaRelationsSelection -Row $script:Alice;Pump $w
            foreach($g in @('DgLinks','DgAllLinks')){
                $headers=@($w.FindName($g).Columns|ForEach-Object{[string]$_.Header})
                Expect (($headers -contains 'Qualification') -and -not ($headers -contains 'Confiance')) ($g+' : '+($headers -join ','))
            }
            $row=@($w.FindName('DgLinks').Items)[0]
            Expect ($row.Badge -eq 'Observe' -and $row.BadgeRule.Length -gt 20 -and -not (($row.Badge+$row.BadgeRule+$row.Provenance) -match '97|%')) 'Badge absent ou pourcentage affiche'
            Expect (@($w.FindName('DgRelationCandidates').Columns|ForEach-Object{[string]$_.Header}) -contains 'Pourquoi') 'Colonne Pourquoi absente'
        }
        Case 'D050 Bouton Restaurer actif apres une suppression locale' {
            Reset-Fixture;Set-DomeniaRelationsSelection -Row $script:Alice;Pump $w
            Expect (-not $w.FindName('BtnRestoreLink').IsEnabled) 'Restaurer actif sans suppression'
            [void](Remove-DomeniaRelation -Relation (@(Get-LinksForComputer 'PC-A')[0]) -Declarant 'EXAMPLE\reader');Pump $w
            Expect ($w.FindName('BtnRestoreLink').IsEnabled) 'Restaurer inactif apres suppression'
        }
        Case 'Interrupteur RelationsSymmetry desactive : parcours RC1.10.7 restaure' {
            Reset-Fixture;$script:Features['RelationsSymmetry']=$false;Set-DomeniaRelationsSelection -Row $script:PcA;Pump $w
            Expect (-not $w.FindName('TabLinksAssociate').IsEnabled) 'Interrupteur sans effet'
        }
        Case 'Interrupteur DetectionPreview desactive : soumission directe comme avant' {
            Reset-Fixture;$script:Features['DetectionPreview']=$false;Set-DomeniaRelationsSelection -Row $script:Alice;Pump $w
            $script:BranchObjects=@((Get-Machine 'PC-1' '10000000-0000-0000-0000-000000000001'))
            $w.FindName('CmbRelationScanScope').SelectedIndex=1
            Start-DomeniaRelationsSearch
            Expect ($null -ne $script:Submission -and $script:Submission.Payload.ScanScope -eq 'Loaded' -and $null -eq $script:Relations.PendingPlan) 'Interrupteur sans effet'
        }
    }finally{$w.Close();$script:Window=$null}
}catch{$script:Tests.Add([pscustomobject]@{Name='Initialisation ou suite interrompue';Status='Failed';Detail=$_.Exception.ToString()})}
finally{
    if($null -ne $script:Window){$script:Window.Close()}
    if($script:TempRoot -and [IO.Directory]::Exists($script:TempRoot)){Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
$expected=34
$passed=@($script:Tests|Where-Object{$_.Status -eq 'Passed'}).Count;$failed=@($script:Tests|Where-Object{$_.Status -eq 'Failed'}).Count
$report=[ordered]@{Build='RC1.11.0-D120-relations';Suite='Raccordement relations D041-D050';Host=$PSVersionTable.PSVersion.ToString();NativeWindowsPowerShell=$script:WindowsExecuted;Wpf=$true;MockedNetwork=$true;LiveAD=$false;LiveCIM=$false;Expected=$expected;Passed=$passed;Failed=$failed;Skipped=0;Complete=($script:WindowsExecuted -and $failed -eq 0 -and $script:Tests.Count -eq $expected);Tests=$script:Tests.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-wiring-relations-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){Write-Host ("$passed passed, $failed failed. Rapport : "+$ReportPath);foreach($x in $script:Tests|Where-Object{$_.Status -eq 'Failed'}){Write-Host ($x.Name+': '+$x.Detail)}}
if($failed -or -not $report.Complete){exit 1};exit 0
