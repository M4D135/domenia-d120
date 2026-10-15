#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet, [switch]$Preview)
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot
$script:Cases=[Collections.Generic.List[object]]::new();$script:WindowsExecuted=$false;$script:Window=$null
function Expect {param([bool]$Value,[string]$Message='Assertion non verifiee');if(-not $Value){throw $Message}}
function Case {param([string]$Name,[scriptblock]$Body)
    try{& $Body|Out-Null;$script:Cases.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}
    catch{$script:Cases.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.ToString()})}
}
function Import-SourceFunction {param($Ast,[string]$Name)
    $nodes=@($Ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
    Expect ($nodes.Count -eq 1) ('Fonction introuvable : '+$Name)
    . ([scriptblock]::Create(($nodes[0].Extent.Text -replace ('^function\s+'+[regex]::Escape($Name)+'\b'),('function script:'+$Name))))
}
function Parse-Source {param([string]$Path)
    $t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e)
    Expect (@($e).Count -eq 0) ($Path+' : '+($e|Out-String));return $a
}
# Inert doubles: no bootstrap, domain, login, real cache, ping, CIM or task submission.
function Get-DomeniaControl {param([string]$Name);return $script:Ctrl[$Name]}
function Set-DomeniaControlText {param([string]$Name,[string]$Text);$script:Messages[$Name]=$Text;$c=Get-DomeniaControl $Name;if($null -ne $c){$c.Text=$Text};return $true}
function Set-DomeniaItemsSource {param([string]$Name,$Rows);$c=Get-DomeniaControl $Name;if($null -ne $c){$list=[Collections.ArrayList]::new();foreach($r in @($Rows)){if($null -ne $r){[void]$list.Add($r)}};$c.ItemsSource=$list};return $true}
function Get-DomeniaRetryCredential {param($OperationId);return $script:Retry[$OperationId]}
function Test-DomeniaAccessBusyWrite {return $script:Locked}
function Get-DomeniaEntryFirstString {param($Entry,$Name);return [string]$Entry[$Name]}
function Get-LinksForUser {param($Login);@($script:UserMachineLinks|Where-Object{$_.UserLogin -ieq $Login})}
function Get-LinksForComputer {param($Name);@($script:UserMachineLinks|Where-Object{$_.Computer -ieq $Name})}
function Normalize-LinkComputer {param($Name);return ([string]$Name).ToUpperInvariant()}
function Write-AppLog {param($Text,$Level);$script:Log.Add([string]$Text)}
function Set-Status {param($Text,$Level);$script:Messages['Status']=$Text}
function Show-InfoBox {param($Text);$script:Messages['Info']=$Text}
function Show-DomeniaOperationError {param($Operation,$ErrorRecordOrException);throw $ErrorRecordOrException}
function Refresh-AssociationContext {param([switch]$SkipResultRefresh)}
function Rebuild-UserMachineLinkIndex {}
function Save-UserMachineLinks {$script:SaveCount++;return $script:SaveAccepted}
function Request-DomeniaAccessRecovery {param($Operation,$OperationId,$ErrorValue,$DN,$Target);$script:Recoveries.Add([pscustomobject]@{Operation=$OperationId;DN=$DN;Target=$Target});return $true}
function Get-DomeniaEffectiveWorkerResult {param($Result,$RequiredProperties);return @($Result)[-1]}
function Request-UiTaskStop {param($Id,[switch]$Silent,[switch]$Force,[switch]$Superseded,$Reason);$script:Stops.Add([string]$Id)}
function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$DisableControls,$TimeoutSeconds,$SuccessHandler,$ErrorHandler)
    $script:Submission=[pscustomobject]@{Payload=$Payload;State=$CallbackState;Operation=$OperationId};$script:AsyncJobs['mock-job']=[pscustomobject]@{CancelRequested=$false};return 'mock-job'
}
function Confirm-Action {param($Title,$Message);$script:ConfirmCount++;return $script:ConfirmAccepted}
function Get-CfgValue {param($Section,$Key,$Default);return $Default}
function Reset-Fixture {
    $script:Ctrl=@{};$script:Messages=@{};$script:Retry=@{};$script:Log=[Collections.Generic.List[string]]::new();$script:Recoveries=[Collections.Generic.List[object]]::new();$script:Stops=[Collections.Generic.List[string]]::new()
    $script:Relations=$null;$script:SessionEpoch=7L;$script:SelectedObject=$null;$script:SuppressGridSelectionEvents=$false;$script:Locked=$false;$script:Persistence=$null
    $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid';Server='dc.example.invalid';Domain='example.invalid';Netbios='EXAMPLE';BindUser='EXAMPLE\reader';Credential=$null}
    $script:MachineCredential=$null;$script:RemoteAdminCredential=$null;$script:AsyncJobs=@{};$script:AsyncEngineClosing=$false;$script:SaveCount=0;$script:SaveAccepted=$true
    $script:ConfirmCount=0;$script:ConfirmAccepted=$true;$script:Submission=$null;$script:SelectedBranchDn='OU=Test,DC=example,DC=invalid';$script:BranchObjects=@()
    $script:UserMachineLinks=@(
        [pscustomobject]@{UserLogin='alice';Computer='PC-A';Source='Console CIM/DCOM';When='2026-01-01';UserGuid='11111111-1111-1111-1111-111111111111';ComputerGuid='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';Details='Historique';Confidence=97},
        [pscustomobject]@{UserLogin='bob';Computer='PC-B';Source='Saisie manuelle';When='2026-01-02';UserGuid='22222222-2222-2222-2222-222222222222';ComputerGuid='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';Details='Declaration';Confidence=100}
    )
    $script:Alice=[pscustomobject]@{Type='Utilisateur';Login='alice';Name='Alice';DN='CN=Alice,DC=example,DC=invalid';Guid='11111111-1111-1111-1111-111111111111'}
    $script:Bob=[pscustomobject]@{Type='Utilisateur';Login='bob';Name='Bob';DN='CN=Bob,DC=example,DC=invalid';Guid='22222222-2222-2222-2222-222222222222'}
    Initialize-DomeniaRelationsState
}
function Begin-FakeQuery {
    Set-DomeniaRelationsSelection -Row $script:Alice
    $state=[pscustomobject]@{Epoch=$script:SessionEpoch;BaseDn=$script:Conn.BaseDn;Generation=$script:Relations.Generation;DN=$script:Alice.DN;Guid=$script:Alice.Guid;Login=$script:Alice.Login;RequestId='request-1';Identity=(Get-DomeniaRelationsIdentity)}
    $script:Relations.Query=[pscustomobject]@{State=$state;RequestId=$state.RequestId;Progress=[Collections.Concurrent.ConcurrentQueue[object]]::new();Candidates=@{};Hints=[Collections.ArrayList]::new();Attempts=[Collections.ArrayList]::new();Ended=$false;AcceptResults=$true;Job='mock-job'}
    $script:AsyncJobs['mock-job']=[pscustomobject]@{CancelRequested=$false};return $state
}
function New-ConfirmedResult {
    param([bool]$Confirmed=$true)
    return [pscustomobject]@{Login='alice';RequestId='request-1';UserDn=$script:Alice.DN;UserGuid=$script:Alice.Guid;Success=$true;Partial=$false;Scanned=$true;ScanStats=[pscustomobject]@{Probed=1};Hints=@();Attempts=@();Candidates=@([pscustomobject]@{Computer='PC-C';Guid='cccccccc-cccc-cccc-cccc-cccccccccccc';DN='CN=PC-C,DC=example,DC=invalid';Confirmed=$Confirmed;ObservedUtc='2026-02-01T00:00:00Z';Source='Console CIM/DCOM';Detail='Console observee'})}
}
# Fake LDAP collections really implement IEnumerable/IDisposable; no DirectoryEntry is constructed.
$fixtureTypes=@'
using System;
using System.Collections;
namespace Domenia.RelationsFixture {
 public class Resource : IDisposable { public bool Disposed; public void Dispose(){Disposed=true;} }
 public class Results : Resource, IEnumerable { readonly object[] rows; public Results(object[] values){rows=values;} public IEnumerator GetEnumerator(){return rows.GetEnumerator();} }
}
'@
function Invoke-WorkerFixture {
    param([string]$Mode='Match',[bool]$Scan=$false,[string]$Scope='Candidates',[int]$Limit=20,[bool]$Events=$false,[bool]$Known=$true,[bool]$Guard=$false)
    # The doubles below run while the worker is executing. PowerShell resolves variables dynamically and is
    # case-insensitive: the worker assigns its own $mode (= ScanScope), which used to shadow -Mode inside the
    # doubles. A name the worker never uses keeps each case on its own fixture mode (cases 31 to 40).
    $relationsFixtureMode=$Mode
    $trace=[pscustomobject]@{Probes=[Collections.ArrayList]::new();Ldap=[Collections.ArrayList]::new();Resources=[Collections.ArrayList]::new();Closed=0;Events=$null}
    $password=ConvertTo-SecureString 'FAUX-SECRET-TEST-SEULEMENT' -AsPlainText -Force
    $ad=[Management.Automation.PSCredential]::new('EXAMPLE\reader',$password)
    $remote=[Management.Automation.PSCredential]::new('EXAMPLE\postes',$password)
    # Point 41: with -Guard the context carries the real shared guard and the account keys of the dispatch.
    $guardMap=$null;if($Guard){$guardMap=[hashtable]::Synchronized(@{Epoch=1L;Faults=@{};Revision=0L;NotifiedRevision=0L})}
    $Context=[pscustomobject]@{BaseDn='DC=example,DC=invalid';Server='dc.example.invalid';Domain='example.invalid';Netbios='EXAMPLE';Credential=$ad;MachineCredential=$remote;UseCim=($Mode -ne 'CimDisabled');RelationRemoteBlocked=($Mode -eq 'RemoteBlocked');OperationId='UserComputerProbe';CredentialGuard=$guardMap;DirectoryAuthKey='reader@example.invalid';RemoteAuthKey='postes@example.invalid';RemoteAdminAuthKey='postes@example.invalid';ActiveRemoteAuthKey='postes@example.invalid';LastAuthChannel=''}
    $leaseHeld={$held=$false;if(($null -ne $Context.CredentialGuard) -and ($Context.CredentialGuard.ContainsKey('AttemptLocks'))){foreach($l in @($Context.CredentialGuard.AttemptLocks.Values)){if([Threading.Monitor]::IsEntered($l)){$held=$true}}};$held}
    $sid=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1001');$sidBytes=[byte[]]::new($sid.BinaryLength);$sid.GetBinaryForm($sidBytes,0)
    $user=[pscustomobject]@{Properties=@{samaccountname=@('alice');userprincipalname=@('alice@example.invalid');objectguid=@(,([guid]'11111111-1111-1111-1111-111111111111').ToByteArray());objectsid=@(,$sidBytes)}}
    $pcA=[pscustomobject]@{Properties=@{name=@('PC-A');dnshostname=@('pc-a.example.invalid');distinguishedname=@('CN=PC-A,DC=example,DC=invalid');objectguid=@(,([guid]'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa').ToByteArray());description=@('Materiel alice');managedby=@('CN=Alice,DC=example,DC=invalid')}}
    $pcB=[pscustomobject]@{Properties=@{name=@('PC-B');dnshostname=@('pc-b.example.invalid');distinguishedname=@('CN=PC-B,DC=example,DC=invalid');objectguid=@(,([guid]'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb').ToByteArray());description=@('Materiel');managedby=@('')}}
    $knownRows=if($Known){@([pscustomobject]@{Computer='PC-A';ComputerGuid=$(if($Mode -eq 'RecreatedPc'){'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'}else{'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'});When='2020-01-01';Source='Historique'})}else{@()}
    $Payload=[pscustomobject]@{Login='alice';UserDn='CN=Alice,DC=example,DC=invalid';UserGuid='11111111-1111-1111-1111-111111111111';RequestId='fixture';BudgetMs=120000;MaxProbes=$Limit;KnownLinks=$knownRows;ScanPark=$Scan;ScanScope=$Scope;ScanBaseDn='OU=Test,DC=example,DC=invalid';ScanDepth='Subtree';LoadedComputers=@('PC-B');UseSecurityLog=$Events;Progress=[Collections.Concurrent.ConcurrentQueue[object]]::new()}
    if($Mode -eq 'RecreatedUser'){$Payload.UserGuid='eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'}
    if($Mode -eq 'ForeignOu'){$Payload.ScanBaseDn='OU=Test,DC=other,DC=invalid'}
    if($Mode -eq 'QueueFull'){for($i=0;$i -lt 256;$i++){$Payload.Progress.Enqueue([pscustomobject]@{Kind='Fixture'})}}
    . ([scriptblock]::Create($script:GuidHelpers))
    function Escape-WLdap {param($Value);return ([string]$Value).Replace('\','\5c').Replace('*','\2a').Replace('(','\28').Replace(')','\29')}
    function Get-WMachineCredential {param($Context);return $Context.MachineCredential}
    function Get-WAdCredential {param($Context);return $Context.Credential}
    function New-WSearcher {
        param($Context,$Root,$Filter,$Properties,$SearchScope,$Maximum)
        [void]$trace.Ldap.Add([pscustomobject]@{Root=$Root;Filter=$Filter;Scope=$SearchScope;User=$Context.Credential.UserName})
        if($relationsFixtureMode -eq 'DirectoryDenied'){throw [UnauthorizedAccessException]::new('Access denied (fixture)')}
        $rows=@()
        if($SearchScope -eq 'Base'){$rows=@($user)}
        elseif($relationsFixtureMode -eq 'NoCandidates'){$rows=@()}
        elseif($relationsFixtureMode -eq 'RecreatedPc' -and ($Filter.Contains('managedBy=') -or $Filter.Contains('description='))){$rows=@()}
        elseif($Filter.Contains('managedBy=')){$rows=@($pcA,$pcB)}
        elseif($Filter.Contains('description=')){$rows=@()}
        elseif($Filter -eq '(objectCategory=computer)'){$rows=@($pcA,$pcB)}
        elseif($Filter.Contains('PC-A')){$rows=@($pcA)}
        elseif($Filter.Contains('PC-B')){$rows=@($pcB)}
        $results=[Domenia.RelationsFixture.Results]::new([object[]]$rows);$owned=[Domenia.RelationsFixture.Resource]::new()
        $s=[pscustomobject]@{Rows=$results;SearchRoot=$owned;PageSize=0;CacheResults=$true;ServerTimeLimit=[timespan]::Zero;ClientTimeout=[timespan]::Zero;Disposed=$false}
        $s|Add-Member ScriptMethod FindAll {return ,$this.Rows};$s|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
        [void]$trace.Resources.Add($s);return $s
    }
    function New-CimSessionOption {param($Protocol,$ErrorAction);Expect ($Protocol -eq 'Dcom');return 'DCOM-fictif'}
    function New-CimSession {
        param($ComputerName,$SessionOption,$OperationTimeoutSec,$ErrorAction,$Credential)
        [void]$trace.Probes.Add([pscustomobject]@{Computer=$ComputerName;User=$Credential.UserName;Timeout=$OperationTimeoutSec;Leased=(& $leaseHeld)})
        if($relationsFixtureMode -eq 'AuthRejected'){throw [Runtime.InteropServices.COMException]::new('Logon failure fixture',-2147023570)}
        if($relationsFixtureMode -eq 'RemoteDenied'){throw [UnauthorizedAccessException]::new('Access denied fixture')}
        if($relationsFixtureMode -eq 'Timeout'){throw [TimeoutException]::new('Timeout fixture')}
        return [pscustomobject]@{Name=$ComputerName}
    }
    function Get-CimInstance {
        param($CimSession,$ClassName,$Property,$OperationTimeoutSec,$ErrorAction)
        $current=switch($relationsFixtureMode){'Other'{'EXAMPLE\bob'}'Foreign'{'OTHER\alice'}'Local'{'PC-A\alice'}'Bare'{'alice'}'Empty'{''}'Upn'{'alice@example.invalid'}default{'EXAMPLE\alice'}}
        return [pscustomobject]@{Name=$(if($relationsFixtureMode -eq 'WrongTarget'){'PC-WRONG'}else{($CimSession.Name -split '\.')[0]});UserName=$current}
    }
    function Remove-CimSession {param($CimSession,$ErrorAction);$trace.Closed++}
    function Get-WinEvent {
        param($ComputerName,$LogName,$FilterXPath,$MaxEvents,$ErrorAction,$Credential)
        $trace.Events=[pscustomobject]@{Filter=$FilterXPath;User=$Credential.UserName;Server=$ComputerName;Max=$MaxEvents;Leased=(& $leaseHeld)}
        if($relationsFixtureMode -eq 'EventsRejected'){throw [ComponentModel.Win32Exception]::new(1326)}
        $e=[pscustomobject]@{TimeCreated=[datetime]'2026-01-01'}
        $e|Add-Member ScriptMethod ToXml {return '<Event><EventData><Data Name="TargetSid">S-1-5-21-1-2-3-1001</Data><Data Name="IpAddress">192.0.2.42</Data></EventData></Event>'};return $e
    }
    function Test-WPing {throw 'Aucun ping autorise dans ce worker'}
    function Invoke-WTaskPowerShell {throw 'Aucun depot de script autorise'}
    function Invoke-WPsExecJson {throw 'Aucun PsExec autorise'}
    $out=@(& ([scriptblock]::Create($script:WorkerCode)))
    $r=@($out|Where-Object{$null -ne $_.PSObject.Properties['RequestId'] -and $null -ne $_.PSObject.Properties['Candidates']})
    Expect ($r.Count -eq 1) ('Resultat worker unique requis : '+$out.Count)
    return [pscustomobject]@{Result=$r[0];Trace=$trace;Queue=$Payload.Progress;Context=$Context}
}
function Pump {param($Window);$Window.UpdateLayout();$Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle);$Window.UpdateLayout()}
function Open-TestWindow {
    param([string]$Theme='Dark')
    $reader=[Xml.XmlNodeReader]::new([xml](Get-MainXaml))
    try{$w=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    $w.Title='DOMENIA RC1.8 | APERCU LOCAL, DONNEES FICTIVES, SANS RESEAU';$w.ShowActivated=$false;$w.ShowInTaskbar=$false;$w.Width=1500;$w.Height=950
    $palette=(Get-Content (Join-Path $wad 'modules\SupportSuite.UI.json') -Raw|ConvertFrom-Json).Palettes.$Theme
    $converter=[Windows.Media.BrushConverter]::new();foreach($p in $palette.PSObject.Properties){$w.Resources[$p.Name]=$converter.ConvertFromInvariantString([string]$p.Value)}
    $script:Ctrl=@{};foreach($m in [regex]::Matches((Get-MainXaml),'x:Name="([^"]+)"')){$c=$w.FindName($m.Groups[1].Value);if($null -ne $c){$script:Ctrl[$m.Groups[1].Value]=$c}}
    $script:Window=$w;$w.FindName('WorkspaceTabs').SelectedItem=$w.FindName('TabRelations');$w.Show();Pump $w;return $w
}
try {
    Expect ($PSVersionTable.PSEdition -eq 'Desktop' -and [int]$PSVersionTable.PSVersion.Major -eq 5 -and [Environment]::Is64BitProcess -and [Threading.Thread]::CurrentThread.ApartmentState -eq 'STA') 'Windows PowerShell 5.1 x64 STA requis.'
    $script:WindowsExecuted=$true
    Add-Type -AssemblyName PresentationFramework;Add-Type -TypeDefinition $fixtureTypes
    $core=Parse-Source (Join-Path $wad 'Domenia-Core.ps1')
    $module=Parse-Source (Join-Path $wad 'modules\Domenia-Relations.UI.ps1')
    Import-SourceFunction $core 'Get-MainXaml'
    . (Join-Path $wad 'modules\Domenia-Common.Model.ps1')
    . (Join-Path $wad 'modules\Domenia-Engine.Model.ps1')
    # FI-05 / PF-06: every Dispatcher timer comes from the protected factory of the engine (Domenia-Engine.UI.ps1).
    . (Join-Path $wad 'modules\Domenia-Engine.UI.ps1')
    if($null -eq ('Domenia.SelectionIdentity' -as [type])){Add-Type -Path (Join-Path $wad 'modules\Domenia-Identity.Types.cs')}
    . (Join-Path $wad 'modules\Domenia-Selection.UI.ps1')
    . (Join-Path $wad 'modules\Domenia-Relations.Model.ps1')
    # Point 41: the real guard helpers that every worker receives with its error contract.
    . (Join-Path $wad 'modules\Domenia-Guard.Model.ps1')
    . (Join-Path $wad 'modules\Domenia-InventoryImport.Model.ps1')
    . (Join-Path $wad 'modules\Domenia-Embedded.UI.ps1')
    . (Join-Path $wad 'modules\Domenia-Relations.UI.ps1')
    $coreText=[IO.File]::ReadAllText((Join-Path $wad 'Domenia-Core.ps1'))
    $common=[regex]::Match($coreText,"(?ms)^\`$script:WorkerCommon\s*=\s*@'\r?\n(.*?)\r?\n'@")
    Expect $common.Success 'WorkerCommon introuvable.'
    $ct=$null;$ce=$null;$ca=[Management.Automation.Language.Parser]::ParseInput($common.Groups[1].Value,[ref]$ct,[ref]$ce)
    Expect (@($ce).Count -eq 0) ($ce|Out-String)
    $script:GuidHelpers=(@($ca.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Get-WPropFirst','Convert-WGuid')},$true))|ForEach-Object{$_.Extent.Text}) -join "`r`n"
    $script:WorkerCode=Get-DomeniaRelationsWorkerCode
    Case '01 Parseur du corps du worker inverse' {$t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseInput($script:WorkerCode,[ref]$t,[ref]$e);Expect (@($e).Count -eq 0) ($e|Out-String);Expect (-not ($script:WorkerCode -match '(?i)\$relationsFixtureMode\b')) 'Le worker ne doit pas utiliser la variable du fixture.'}
    Case '02 Selection seule : aucun travail soumis' {Reset-Fixture;Set-DomeniaRelationsSelection -Row $script:Alice;Expect ($null -eq $script:Submission -and $script:Relations.Subject.Login -eq 'alice')}
    Case '03 Filtre utilisateur connu, sans toutes les relations' {Reset-Fixture;Set-DomeniaRelationsSelection -Row $script:Alice;$l=@(Get-DomeniaRelationsSelectedLinks);Expect ($l.Count -eq 1 -and $l[0].Computer -eq 'PC-A')}
    Case '04 Changer utilisateur change le filtre' {Set-DomeniaRelationsSelection -Row $script:Bob;$l=@(Get-DomeniaRelationsSelectedLinks);Expect ($l.Count -eq 1 -and $l[0].UserLogin -eq 'bob')}
    Case '05 GUID recree exclut ancien lien homonyme' {Reset-Fixture;$script:Alice.Guid='eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';Set-DomeniaRelationsSelection -Row $script:Alice;Expect (@(Get-DomeniaRelationsSelectedLinks).Count -eq 0)}
    Case '06 Ancien lien sans GUID reste historique' {$script:UserMachineLinks[0].UserGuid='';Expect (@(Get-DomeniaRelationsSelectedLinks).Count -eq 1)}
    Case '07 Selection programmatique ignoree' {Reset-Fixture;$script:SuppressGridSelectionEvents=$true;Set-DomeniaRelationsSelection -Row $script:Alice;Expect ($null -eq $script:Relations.Subject)}
    Case '08 Meme objet ne redemarre pas une recherche' {Reset-Fixture;$script:CapturedState=Begin-FakeQuery;$g=$script:Relations.Generation;Set-DomeniaRelationsSelection -Row $script:Alice;Expect ($script:Relations.Generation -eq $g -and $script:Relations.Query.RequestId -eq $script:CapturedState.RequestId)}
    Case '09 Autre utilisateur invalide la requete precedente' {Set-DomeniaRelationsSelection -Row $script:Bob;Expect (-not (Test-DomeniaRelationsCurrent $script:CapturedState) -and $script:Stops.Count -eq 1)}
    Case '10 Etat capture valide' {Reset-Fixture;$script:CapturedState=Begin-FakeQuery;Expect (Test-DomeniaRelationsCurrent $script:CapturedState)}
    Case '11 Requete tardive rejetee' {$copy=$script:CapturedState.PSObject.Copy();$copy.RequestId='other';Expect (-not (Test-DomeniaRelationsCurrent $copy))}
    Case '12 GUID utilisateur different rejete' {$copy=$script:CapturedState.PSObject.Copy();$copy.Guid='other';Expect (-not (Test-DomeniaRelationsCurrent $copy))}
    Case '13 Session differente rejetee' {$copy=$script:CapturedState.PSObject.Copy();$copy.Epoch=2;Expect (-not (Test-DomeniaRelationsCurrent $copy))}
    Case '14 Controleur different invalide le retour' {$old=$script:Conn.Server;$script:Conn.Server='dc2.example.invalid';Expect (-not (Test-DomeniaRelationsCurrent $script:CapturedState));$script:Conn.Server=$old}
    Case '15 Nouveau credential meme nom invalide le retour' {$script:Retry['LiveConsole']=[Management.Automation.PSCredential]::new('EXAMPLE\postes',(ConvertTo-SecureString 'test' -AsPlainText -Force));Expect (-not (Test-DomeniaRelationsCurrent $script:CapturedState));$script:Retry.Clear()}
    Case '16 Annulation interdit tout enregistrement tardif' {Stop-DomeniaRelationsSearch;Save-DomeniaRelationConfirmations (New-ConfirmedResult) $script:CapturedState;Expect ($script:SaveCount -eq 0 -and -not $script:Relations.Query.AcceptResults)}
    Case '17 Indice AD non enregistre automatiquement' {Reset-Fixture;$script:CapturedState=Begin-FakeQuery;Save-DomeniaRelationConfirmations (New-ConfirmedResult $false) $script:CapturedState;Expect ($script:SaveCount -eq 0)}
    Case '18 Console confirmee enregistree en lot' {Save-DomeniaRelationConfirmations (New-ConfirmedResult) $script:CapturedState;Expect ($script:SaveCount -eq 1 -and @($script:UserMachineLinks|Where-Object{$_.Computer -eq 'PC-C'}).Count -eq 1)}
    Case '19 Lien manuel preserve meme pour le meme compte' {Reset-Fixture;$script:CapturedState=Begin-FakeQuery;$r=New-ConfirmedResult;$r.Candidates[0].Computer='PC-B';Save-DomeniaRelationConfirmations $r $script:CapturedState;Expect ($script:SaveCount -eq 0 -and $script:UserMachineLinks[1].UserLogin -eq 'bob')}
    Case '20 Refus file stockage conserve la vue precedente' {Reset-Fixture;$script:CapturedState=Begin-FakeQuery;$script:SaveAccepted=$false;Save-DomeniaRelationConfirmations (New-ConfirmedResult) $script:CapturedState;Expect ($script:UserMachineLinks.Count -eq 2 -and $script:Messages.Status -match 'non enregistr')}
    Case '21 Sauvegarde differee si ecrivain occupe' {Reset-Fixture;$script:CapturedState=Begin-FakeQuery;$script:Persistence=[pscustomobject]@{LinkBusy=$true};Save-DomeniaRelationConfirmations (New-ConfirmedResult) $script:CapturedState;Expect ($script:SaveCount -eq 0 -and $null -ne $script:Relations.PendingConfirmed)}
    Case '22 Ecriture AD bloque application des liens' {Reset-Fixture;$script:CapturedState=Begin-FakeQuery;$script:Locked=$true;Save-DomeniaRelationConfirmations (New-ConfirmedResult) $script:CapturedState;Expect ($script:SaveCount -eq 0)}
    Case '23 Worker sans scan : aucun CIM' {$script:FixtureOutput=Invoke-WorkerFixture;Expect ($script:FixtureOutput.Trace.Probes.Count -eq 0 -and $script:FixtureOutput.Result.Candidates.Count -ge 1)}
    Case '24 Worker reprend les associations et leur date' {Expect (@($script:FixtureOutput.Result.Candidates|Where-Object{$_.Known -and $_.ObservedUtc -eq '2020-01-01'}).Count -eq 1)}
    Case '25 Responsable declare ne devient pas session' {Expect (@($script:FixtureOutput.Result.Candidates|Where-Object{$_.Confirmed}).Count -eq 0)}
    Case '26 Lecture AD utilise le compte annuaire' {Expect (@($script:FixtureOutput.Trace.Ldap|Where-Object{$_.User -ne 'EXAMPLE\reader'}).Count -eq 0)}
    Case '27 Ressources LDAP toujours liberees' {foreach($script:CapturedState in $script:FixtureOutput.Trace.Resources){Expect ($script:CapturedState.Disposed -and $script:CapturedState.Rows.Disposed -and $script:CapturedState.SearchRoot.Disposed)}}
    Case '28 Console utilise le compte poste distinct' {$script:FixtureOutput=Invoke-WorkerFixture -Scan $true;Expect ($script:FixtureOutput.Trace.Probes.Count -eq 2 -and @($script:FixtureOutput.Trace.Probes|Where-Object{$_.User -ne 'EXAMPLE\postes'}).Count -eq 0)}
    Case '29 Console du bon domaine confirmee' {Expect ($script:FixtureOutput.Result.ScanStats.Matched -eq 2)}
    Case '30 Toutes les sessions CIM creees fermees' {Expect ($script:FixtureOutput.Trace.Closed -eq $script:FixtureOutput.Trace.Probes.Count)}
    Case '31 Compte console autre utilisateur non associe' {$script:FixtureOutput=Invoke-WorkerFixture -Mode Other -Scan $true;Expect ($script:FixtureOutput.Result.ScanStats.Matched -eq 0);Expect (@($script:FixtureOutput.Result.Candidates|Where-Object{$_.CurrentUser -eq 'EXAMPLE\bob'}).Count -eq 2) 'Console EXAMPLE\bob non lue'}
    Case '32 Meme nom autre domaine non associe' {$script:FixtureOutput=Invoke-WorkerFixture -Mode Foreign -Scan $true;Expect ($script:FixtureOutput.Result.ScanStats.Matched -eq 0);Expect (@($script:FixtureOutput.Result.Candidates|Where-Object{$_.CurrentUser -eq 'OTHER\alice'}).Count -eq 2) 'Console OTHER\alice non lue'}
    Case '33 Compte local homonyme non associe' {$script:FixtureOutput=Invoke-WorkerFixture -Mode Local -Scan $true;Expect ($script:FixtureOutput.Result.ScanStats.Matched -eq 0);Expect (@($script:FixtureOutput.Result.Candidates|Where-Object{$_.CurrentUser -eq 'PC-A\alice'}).Count -eq 2) 'Console PC-A\alice non lue'}
    Case '34 Nom non qualifie non devine' {$script:FixtureOutput=Invoke-WorkerFixture -Mode Bare -Scan $true;Expect ($script:FixtureOutput.Result.ScanStats.Matched -eq 0);Expect (@($script:FixtureOutput.Result.Candidates|Where-Object{$_.CurrentUser -eq 'alice'}).Count -eq 2) 'Console alice non qualifiee non lue'}
    Case '35 UPN exact accepte' {$script:FixtureOutput=Invoke-WorkerFixture -Mode Upn -Scan $true;Expect ($script:FixtureOutput.Result.ScanStats.Matched -eq 2);Expect (@($script:FixtureOutput.Result.Candidates|Where-Object{$_.CurrentUser -eq 'alice@example.invalid'}).Count -eq 2) 'Chemin UPN non parcouru'}
    Case '36 Console vide ne conclut pas aux sessions RDP' {$script:FixtureOutput=Invoke-WorkerFixture -Mode Empty -Scan $true;Expect ($script:FixtureOutput.Result.ScanStats.Matched -eq 0 -and $script:FixtureOutput.Result.Candidates[0].Detail -match 'RDP non recens');Expect ($script:FixtureOutput.Result.Candidates[0].Status -eq 'Aucun compte console') 'Console vide non lue'}
    Case '37 Machine recue differente non attribuee' {$script:FixtureOutput=Invoke-WorkerFixture -Mode WrongTarget -Scan $true;Expect ($script:FixtureOutput.Result.ScanStats.Matched -eq 0 -and $script:FixtureOutput.Result.Partial);Expect (@($script:FixtureOutput.Result.Attempts|Where-Object{$_.Detail -match 'Nom du poste re'}).Count -eq 2) 'Nom de poste different non detecte'}
    Case '38 Acces refuse visible dans tentatives' {$script:FixtureOutput=Invoke-WorkerFixture -Mode RemoteDenied -Scan $true;Expect (@($script:FixtureOutput.Result.Attempts|Where-Object{$_.Status -eq 'REFUSE' -and $_.Resource -eq 'Remote'}).Count -eq 2)}
    Case '39 Delai conserve observation historique' {$script:FixtureOutput=Invoke-WorkerFixture -Mode Timeout -Scan $true;Expect (@($script:FixtureOutput.Result.Candidates|Where-Object{$_.Known -and $_.ObservedUtc -eq '2020-01-01'}).Count -eq 1 -and $script:FixtureOutput.Result.Partial);Expect (@($script:FixtureOutput.Result.Attempts|Where-Object{$_.Status -eq 'DELAI'}).Count -ge 1) 'Delai non classe'}
    Case '40 Rejet identifiants arrete les sondes suivantes' {$script:FixtureOutput=Invoke-WorkerFixture -Mode AuthRejected -Scan $true;Expect ($script:FixtureOutput.Trace.Probes.Count -eq 1 -and $script:FixtureOutput.Result.Partial);Expect (@($script:FixtureOutput.Result.Attempts|Where-Object{$_.Status -eq 'AUTH_REJETEE'}).Count -eq 1) 'Rejet des identifiants non classe'}
    Case '41 Canal deja bloque : aucun nouvel essai' {$script:FixtureOutput=Invoke-WorkerFixture -Mode RemoteBlocked -Scan $true;Expect ($script:FixtureOutput.Trace.Probes.Count -eq 0 -and $script:FixtureOutput.Result.Partial)}
    Case '42 Configuration CIM desactivee respectee' {$script:FixtureOutput=Invoke-WorkerFixture -Mode CimDisabled -Scan $true;Expect ($script:FixtureOutput.Trace.Probes.Count -eq 0)}
    Case '43 Limite de sondes respectee' {$script:FixtureOutput=Invoke-WorkerFixture -Scan $true -Limit 1;Expect ($script:FixtureOutput.Trace.Probes.Count -eq 1 -and $script:FixtureOutput.Result.Partial)}
    Case '44 Aucun candidat : aucun balayage domaine implicite' {$script:FixtureOutput=Invoke-WorkerFixture -Mode NoCandidates -Scan $true -Known $false;Expect ($script:FixtureOutput.Trace.Probes.Count -eq 0 -and @($script:FixtureOutput.Trace.Ldap|Where-Object{$_.Filter -eq '(objectCategory=computer)'}).Count -eq 0)}
    Case '45 GUID ordinateur recree non sonde par ancien lien' {$script:FixtureOutput=Invoke-WorkerFixture -Mode RecreatedPc -Scan $true;Expect ($script:FixtureOutput.Trace.Probes.Count -eq 0 -and @($script:FixtureOutput.Result.Attempts|Where-Object{$_.Status -eq 'A_REVOIR'}).Count -gt 0)}
    Case '46 GUID utilisateur recree arrete la recherche' {$script:FixtureOutput=Invoke-WorkerFixture -Mode RecreatedUser -Scan $true;Expect (-not $script:FixtureOutput.Result.Success -and $script:FixtureOutput.Trace.Probes.Count -eq 0)}
    Case '47 Refus AD distinct et aucun CIM' {$script:FixtureOutput=Invoke-WorkerFixture -Mode DirectoryDenied -Scan $true;Expect (-not $script:FixtureOutput.Result.Success -and $script:FixtureOutput.Trace.Probes.Count -eq 0 -and $script:FixtureOutput.Result.Attempts[0].Resource -eq 'Directory')}
    Case '48 Journal du controleur desactive par defaut' {$script:FixtureOutput=Invoke-WorkerFixture;Expect ($null -eq $script:FixtureOutput.Trace.Events)}
    Case '49 Journal cible le SID et le compte AD' {$script:FixtureOutput=Invoke-WorkerFixture -Events $true;Expect ($script:FixtureOutput.Trace.Events.Filter -match 'TargetSid' -and $script:FixtureOutput.Trace.Events.Filter -match 'S-1-5-21-1-2-3-1001' -and $script:FixtureOutput.Trace.Events.User -eq 'EXAMPLE\reader')}
    Case '50 Adresse IP conservee entiere comme indice' {Expect ($script:FixtureOutput.Result.Hints.Count -eq 1 -and $script:FixtureOutput.Result.Hints[0].Computer -eq '192.0.2.42' -and -not $script:FixtureOutput.Result.Hints[0].DN -and -not $script:FixtureOutput.Result.Hints[0].Confirmed)}
    Case '51 Progression pleine ne bloque pas retour final' {$script:FixtureOutput=Invoke-WorkerFixture -Mode QueueFull;Expect ($script:FixtureOutput.Queue.Count -eq 256 -and $script:FixtureOutput.Result.Candidates.Count -eq 2)}
    Case '52 Perimetre OU explicitement transmis' {$script:FixtureOutput=Invoke-WorkerFixture -Scan $true -Scope OU;Expect (@($script:FixtureOutput.Trace.Ldap|Where-Object{$_.Root -eq 'OU=Test,DC=example,DC=invalid' -and $_.Filter -eq '(objectCategory=computer)'}).Count -eq 1)}
    Case '53 Perimetre liste exclut les candidats hors liste' {$script:FixtureOutput=Invoke-WorkerFixture -Scan $true -Scope Loaded;Expect ($script:FixtureOutput.Trace.Probes.Count -eq 1 -and $script:FixtureOutput.Trace.Probes[0].Computer -eq 'pc-b.example.invalid')}
    Case '54 Point 41 : journal et consoles envoyes sous le bail du compte' {$script:FixtureOutput=Invoke-WorkerFixture -Scan $true -Events $true -Guard $true;Expect ($script:FixtureOutput.Trace.Events.Leased) 'Journal lu hors bail';Expect ($script:FixtureOutput.Trace.Probes.Count -eq 2 -and @($script:FixtureOutput.Trace.Probes|Where-Object{-not $_.Leased}).Count -eq 0) 'Console ouverte hors bail'}
    Case '55 Point 41 : refus d une console partage avec les autres travaux, aucune autre console' {$script:FixtureOutput=Invoke-WorkerFixture -Mode AuthRejected -Scan $true -Guard $true;Expect ($script:FixtureOutput.Trace.Probes.Count -eq 1) 'Seconde console essayee';$g=$script:FixtureOutput.Context.CredentialGuard;Expect ($g.Faults.ContainsKey('postes@example.invalid')) 'Refus non partage';Expect (-not $g.Faults.ContainsKey('reader@example.invalid')) 'Compte annuaire declare refuse a tort'}
    Case '56 Point 41 : refus du journal attribue au compte annuaire, aucune lecture AD ensuite' {$script:FixtureOutput=Invoke-WorkerFixture -Mode EventsRejected -Scan $true -Events $true -Guard $true -Scope OU;$g=$script:FixtureOutput.Context.CredentialGuard;Expect ($g.Faults.ContainsKey('reader@example.invalid')) 'Refus non attribue au compte annuaire';Expect (-not $g.Faults.ContainsKey('postes@example.invalid')) 'Compte poste declare refuse a tort';Expect (@($script:FixtureOutput.Trace.Ldap|Where-Object{$_.Filter -eq '(objectCategory=computer)'}).Count -eq 0) 'Lecture AD apres refus'}
    foreach($theme in @('Light','Dark')){
        Reset-Fixture;$w=Open-TestWindow $theme
        try{
            Initialize-DomeniaRelationsUi;Set-DomeniaRelationsSelection -Row $script:Alice;Pump $w
            Case ($theme+' : onglet selection uniquement Alice') {Expect ($w.FindName('DgLinks').Items.Count -eq 1 -and $w.FindName('DgAllLinks').Items.Count -eq 2)}
            Case ($theme+' : changement de focus ne passe pas a Tous') {$w.FindName('DgLinks').Focus()|Out-Null;Pump $w;Expect ($w.FindName('RelationTabs').SelectedItem.Name -eq 'TabLinksSelected')}
            Case ($theme+' : grille active Toutes explicite') {$w.FindName('RelationTabs').SelectedItem=$w.FindName('TabLinksAll');Pump $w;Expect ((Get-DomeniaRelationsActiveGrid).Name -eq 'DgAllLinks')}
            Case ($theme+' : texte activite aligne au bord gauche') {$c=$w.FindName('LblTaskElapsed');$p=$c.TranslatePoint([Windows.Point]::new(0,0),$w.FindName('UxActivityStrip'));Expect ($p.X -le 1 -and $c.TextAlignment -eq 'Left')}
            Case ($theme+' : placeholder aligne sur le caractere saisi') {
                $box=$w.FindName('TxtGlobalSearch');$box.Text='I';Pump $w;$rect=$box.GetRectFromCharacterIndex(0)
                Expect (-not $rect.IsEmpty) 'Rectangle du texte indisponible.'
                $box.Text='';Pump $w;$ph=$box.Template.FindName('UxSearchPlaceholder',$box)
                $pos=$ph.TranslatePoint([Windows.Point]::new(0,0),$box)
                Expect ([Math]::Abs($pos.X-$rect.X) -le 1) ('Origines differentes : '+$pos.X+' / '+$rect.X)
            }
            Case ($theme+' : contenu stable pendant activite longue') {
                $content=$w.FindName('UxContentGrid');$y=$content.TranslatePoint([Windows.Point]::new(0,0),$w).Y
                $w.FindName('LblTaskElapsed').Text=('Operation longue '*30);$w.FindName('PbTop').Visibility='Visible';$w.FindName('BtnCancelTask').Visibility='Visible';$w.FindName('WriteModeBanner').Visibility='Visible';Pump $w
                Expect ([Math]::Abs($content.TranslatePoint([Windows.Point]::new(0,0),$w).Y-$y) -le 0.5)
                Expect ($w.FindName('UxActivityStrip').ActualHeight -eq 44)
            }
        }finally{$w.Close();$script:Window=$null}
    }
    if($Preview){
        Reset-Fixture;$w=Open-TestWindow Dark;Initialize-DomeniaRelationsUi;Set-DomeniaRelationsSelection -Row $script:Alice
        # Only navigation within Relations and its inert fixture controls are enabled.
        foreach($c in $script:Ctrl.Values){if($c -is [Windows.Controls.Button]){$c.IsEnabled=$false}}
        $w.FindName('LblUxPageTitle').Text='Relations : APERÇU LOCAL SANS RÉSEAU'
        $w.FindName('LblUxDomain').Text='EXEMPLE · données fictives'
        $script:Ctrl.Remove('BtnRelationOpenCandidate');$script:Ctrl.Remove('BtnRelationAdopt')
        $q=Begin-FakeQuery;$result=(Invoke-WorkerFixture -Mode RemoteDenied -Scan $true).Result;$result.RequestId=$q.RequestId
        Complete-DomeniaRelationsSearch $result $q
        $w.FindName('BtnDetectUserComputers').IsEnabled=$false;$w.FindName('BtnLinkSelected').IsEnabled=$false;$w.FindName('BtnRemoveLink').IsEnabled=$false
        $w.FindName('RelationTabs').SelectedItem=$w.FindName('TabLinksSelected')
        $w.Hide();[void]$w.ShowDialog();$w.Close()
    }
}catch{$script:Cases.Add([pscustomobject]@{Name='Initialisation ou suite interrompue';Passed=$false;Error=$_.Exception.ToString()})}
finally{if($null -ne $script:Window){$script:Window.Close()}}
$expected=68
$failed=@($script:Cases|Where-Object{-not $_.Passed}).Count
$report=[ordered]@{Build='RC1.8';Suite='Relations et alignements';Expected=$expected;Passed=@($script:Cases|Where-Object{$_.Passed}).Count;Failed=$failed;Skipped=0;Complete=($script:WindowsExecuted -and $script:Cases.Count -eq $expected);WindowsPowerShellExecuted=$script:WindowsExecuted;LiveNetworkExecuted=$false;Cases=$script:Cases.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-RC1.8-relations-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($true))
if(-not $Quiet){Write-Host ('Rapport : '+$ReportPath);Write-Host ('PASS='+$report.Passed+' FAIL='+$report.Failed+' Complete='+$report.Complete);foreach($x in $script:Cases|Where-Object{-not $_.Passed}){Write-Host ($x.Name+': '+$x.Error)}}
if($failed -or -not $report.Complete){exit 1};exit 0
