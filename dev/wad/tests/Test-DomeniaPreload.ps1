#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet, [switch]$SkipWpf)
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
$wad=Split-Path -Parent $PSScriptRoot
$root=Split-Path -Parent $wad
$checks=[Collections.Generic.List[object]]::new()
function Assert-True {param([bool]$Value,[string]$Why='Assertion failed');if(-not $Value){throw $Why}}
function Test-Case {param([string]$Name,[scriptblock]$Body)
    try { Reset-Fixture; & $Body | Out-Null; $checks.Add([pscustomobject]@{Name=$Name;Status='Passed';Detail=''}) }
    catch { $checks.Add([pscustomobject]@{Name=$Name;Status='Failed';Detail=$_.Exception.ToString()}) }
}
function Reset-Fixture {}
$native=($PSVersionTable.PSEdition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and [Environment]::Is64BitProcess)
if(-not $native){throw 'Run in Windows PowerShell 5.1 x64; a PowerShell 7 run is not Windows validation.'}
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Use powershell.exe -STA.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$script:RuntimeAst=@{}
foreach($file in @(Get-ChildItem -LiteralPath $wad -File -Recurse -Filter '*.ps1' | Where-Object { $_.FullName -notmatch '[\\/](tests|maintenance|docs)[\\/]' })) {
    Test-Case ('Native parser: '+$file.Name) {
        $tokens=$null;$errors=$null
        $node=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        Assert-True (@($errors).Count -eq 0) (@($errors|ForEach-Object{$_.Message}) -join '; ')
        $script:RuntimeAst[$file.FullName]=$node
    }
}
$corePath=Join-Path $wad 'Domenia-Core.ps1'
$tokens=$null;$errors=$null;$script:CoreAst=[Management.Automation.Language.Parser]::ParseFile($corePath,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw $errors[0].Message}
function Import-Function {param([string]$Name)
    $nodes=@($script:CoreAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
    if($nodes.Count -ne 1){throw ('Missing/ambiguous function '+$Name)}
    # Dot-source in script scope so imported functions remain available after this helper.
    $script:ImportBody=$nodes[0].Extent.Text
}
foreach($name in @('Get-MainXaml','Get-DomeniaControl','Set-DomeniaControlText','Get-DomeniaSelectedGridRow','Test-DomeniaGridSelectionMatches','Queue-DomeniaSelectedObjectOpen','Get-DomeniaLandingView','Invoke-DomeniaPendingSelectionOpen','Open-SelectedObject','Stop-DomeniaSelectionOpenTimer','Clear-DomeniaCurrentObjectRequest','Test-DomeniaObjectCallbackIsCurrent','Open-AdObject','Complete-DomeniaOpenObjectTaskUi','Fail-DomeniaOpenObjectTaskUi','ConvertTo-DomeniaCanonicalWorkerCode','Get-DomeniaWorkerCodeHash','Get-DomeniaWorkerOperationHashes','Assert-DomeniaWorkerRegistry')) {
    Import-Function $name
    . ([scriptblock]::Create($script:ImportBody))
}
. (Join-Path $wad 'modules\Domenia-Common.Model.ps1')
# D025: the object cache key is built by the cache-v3 rule.
. (Join-Path $wad 'modules\Domenia-Cache.Model.ps1')
# D082/D085: counters and selection preview come from the shell rules (and their dependencies).
. (Join-Path $wad 'modules\Domenia-Relations.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Access.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Shell.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Selection.UI.ps1')
. (Join-Path $wad 'modules\Domenia-Experience.Model.ps1')
# FI-05 / PF-06: every Dispatcher timer comes from the protected factory of the engine (Domenia-Engine.UI.ps1).
. (Join-Path $wad 'modules\Domenia-Engine.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Engine.UI.ps1')
# The fixture never imports the bootstrap, loads a user cache or invokes a real worker.
function Get-DomeniaRetryCredential {param($OperationId);return $null}
function Get-CfgValue {param($Section,$Name,$Default);return $Default}
function Test-DomeniaAccessBusyWrite {return [bool]$script:BusyWrite}
function Get-DomeniaSelectedGridRows {return @($script:Ctrl.DgObjects.SelectedItems)}
function Test-DomeniaDraftNavigation {param($DN,[switch]$Refresh);return $script:DraftApproved}
function Restore-DomeniaRefusedSelection {param($DN);$script:RestoredDN=$DN}
function Clear-Secrets {$script:SecretsCleared++}
# D085: the views bound to the previous object are purged on a new selection (core function, counted here).
function Reset-DomeniaSelectionBoundViews {param($Dn,$Type,$Name) $script:BoundViewsReset++}
function Clear-DomeniaLiveProbeIntent {$script:RemoteIntent=''}
function Update-DomeniaSearchActionStates { }
function Select-DomeniaLiveResult {param([switch]$Force,[switch]$Manual,[switch]$Explicit)
    $r=Get-DomeniaSelectedGridRow
    if($null -ne $r -and $r.Type -eq 'Machine'){$script:RemoteIntent=[string]$r.DN}else{$script:RemoteIntent=''}
}
function Set-DomeniaRelationsGridSelection {$script:RelationDN=[string](Get-DomeniaSelectedGridRow).DN}
function Request-UiTaskStop {param($Id,[switch]$Silent,[switch]$Force,[switch]$Superseded,$Reason);$script:Stops.Add([string]$Id)}
function Set-VisibleTabsForType {param($Type,[switch]$PreserveWorkspace)
    $script:Ctrl.WsObject.Visibility=if($Type){'Visible'}else{'Collapsed'}
    $script:Ctrl.WsComputer.Visibility=if($Type -eq 'Machine'){'Visible'}else{'Collapsed'}
    if(-not $PreserveWorkspace){$script:Page='WsObject'}
}
function Select-DomeniaWorkspace {param($Workspace,$Inner,$Tab);$script:Page=$Workspace;$script:Routes.Add([string]$Workspace)}
function Set-Status {param($Text,$Level)}
function Write-AppLog {param($Text,$Level)}
function Get-DomeniaSafeObjectPropertyNames {return @('name','objectGUID','distinguishedName','objectClass')}
function Get-VisitCacheValue {param($Key);return $script:Cache[$Key]}
function Get-DomeniaEffectiveWorkerResult {param($Result,$RequiredProperties);return $Result}
function Show-AdObjectResult {param($Result,$Dn,$Type,[switch]$NoNavigate,[switch]$SuppressRemoteProbes)
    $script:SelectedObject=[pscustomobject]@{DN=$Dn;Type=$Type;Name=$Result.Properties.name[0];Guid=(Get-DomeniaObjectResultGuid $Result);Entry=$Result}
    [void](Set-DomeniaObservationTime $script:SelectedObject 'Attributes' ([datetime]::UtcNow) -Succeeded:(-not [bool]$script:ShowingCachedObject))
    $script:Renders.Add([pscustomobject]@{DN=$Dn;NoNavigate=[bool]$NoNavigate;NoProbes=[bool]$SuppressRemoteProbes})
    if(-not $NoNavigate){$script:Page='WsObject'}
}
function Complete-DomeniaOpenObjectUi {param($Result,$CacheKey,$Dn,$Type,[switch]$NoNavigate,[switch]$SuppressRemoteProbes)
    $script:Cache[$CacheKey]=$Result
    Show-AdObjectResult -Result $Result -Dn $Dn -Type $Type -NoNavigate:$NoNavigate -SuppressRemoteProbes:$SuppressRemoteProbes
}
function Fail-DomeniaOpenObjectUi {param($Message,$Dn);$script:Failure=[string]$Message}
function Show-DomeniaOperationError {param($Operation,$ErrorRecordOrException);$script:Popups++}
function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$DisableControls,$TimeoutSeconds,$StatusText,$SuccessHandler,$ErrorHandler)
    if($OperationId -ne 'OpenAdObject'){throw ('Unexpected operation: '+$OperationId)}
    $job=[pscustomobject]@{Id=[guid]::NewGuid().ToString('N');State=$CallbackState;Payload=$Payload;Code=$Code;ReplaceKey=$ReplaceKey;IsWrite=$false}
    $script:Requests.Add($job);$script:AsyncJobs[$job.Id]=$job;return $job.Id
}
function Reset-Fixture {
    if($null -ne $script:SelectionOpenTimer){$script:SelectionOpenTimer.Stop()}
    $script:SelectionOpenTimer=$null;$script:SelectionLoad=$null;$script:PendingObjectSelection=$null
    $script:CurrentObjectRequestId='';$script:CurrentObjectRequestDn='';$script:CurrentObjectRequestState=$null
    $script:DirectoryReachability=$null;$script:WriteState='Idle';$script:ShowingCachedObject=$false
    $script:SelectedObject=$null;$script:LastLoadedEntry=$null;$script:SelectionResetDn='';$script:DraftState=$null
    $script:SessionEpoch=12L;$script:GlobalSearchGeneration=21;$script:SelectedObjectGeneration=0L
    $script:Conn=[pscustomobject]@{Connected=$true;BaseDn='DC=example,DC=invalid';Server='dc1.example.invalid';BindUser='EXAMPLE\reader';Credential=$null}
    $script:BusyWrite=$false;$script:DraftApproved=$true;$script:SuppressGridSelectionEvents=$false;$script:AsyncEngineClosing=$false
    $script:AsyncJobs=@{};$script:Cache=@{};$script:Page='WsSearch';$script:RemoteIntent='';$script:RelationDN='';$script:RestoredDN=''
    $script:SecretsCleared=0;$script:Popups=0;$script:Failure=''
    $script:Requests=[Collections.Generic.List[object]]::new();$script:Renders=[Collections.Generic.List[object]]::new()
    $script:Routes=[Collections.Generic.List[string]]::new();$script:Stops=[Collections.Generic.List[string]]::new()
    $script:Ctrl=@{
        DgObjects=[pscustomobject]@{IsEnabled=$true;SelectedItem=$null;SelectedItems=@();Items=@()}
        WsObject=[pscustomobject]@{Visibility='Collapsed'};WsComputer=[pscustomobject]@{Visibility='Collapsed'}
        LblSelectionReadState=[pscustomobject]@{Text='';ToolTip=$null}
    }
    foreach($kind in @('Object','Computer')){
        $script:Ctrl[$kind+'ReadContent']=[pscustomobject]@{Visibility='Collapsed';IsEnabled=$false}
        $script:Ctrl[$kind+'ReadPlaceholder']=[pscustomobject]@{Visibility='Visible'}
        $script:Ctrl['Lbl'+$kind+'ReadStatus']=[pscustomobject]@{Text='';ToolTip=''}
        $script:Ctrl['Btn'+$kind+'ReadRetry']=[pscustomobject]@{Visibility='Hidden';IsEnabled=$false}
    }
}
function Row {param([string]$Name='A',[string]$Type='Utilisateur')
    $g=if($Name -eq 'A'){'11111111-1111-1111-1111-111111111111'}else{'22222222-2222-2222-2222-222222222222'}
    return [pscustomobject]@{DN=('CN='+$Name+',DC=example,DC=invalid');Name=$Name;Type=$Type;Guid=$g;Login=$Name}
}
function Pick {param($Row,[switch]$Immediate)
    $script:Ctrl.DgObjects.SelectedItem=$Row;$script:Ctrl.DgObjects.SelectedItems=if($null -ne $Row){@($Row)}else{@()}
    Queue-DomeniaSelectedObjectOpen -Immediate:$Immediate
}
function Send-Pending {Stop-DomeniaSelectionOpenTimer;Invoke-DomeniaPendingSelectionOpen}
function Result-For {param($Row)
    return [pscustomobject]@{DN=$Row.DN;Type=$Row.Type;Live=$true;Properties=@{name=@($Row.Name);objectGUID=@($Row.Guid);distinguishedName=@($Row.DN)}}
}
Test-Case 'Real selection event calls preload, not only the console probe' {
    $wire=@($script:CoreAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Wire-Events'},$true))[0]
    $calls=@($wire.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'Add_SelectionChanged' -and $n.Expression.Extent.Text -match 'DgObjects'},$true))
    Assert-True ($calls.Count -eq 1)
    $handler=$calls[0].Arguments[0].ScriptBlock.GetScriptBlock()
    $grid=[Windows.Controls.DataGrid]::new();$script:Ctrl.DgObjects=$grid
    $a=Row;[void]$grid.Items.Add($a);$grid.Add_SelectionChanged($handler);$grid.SelectedItem=$a
    Assert-True ($null -ne $script:PendingObjectSelection -and $script:Ctrl.WsObject.Visibility -eq 'Visible')
}
Test-Case 'User single-click queues an AD read without navigation' {$a=Row;Pick $a;Assert-True ($script:Page -eq 'WsSearch' -and $script:Requests.Count -eq 0 -and $script:PendingObjectSelection.Dn -eq $a.DN)}
Test-Case 'Fiche immediately available for a user' {Pick (Row);Assert-True ($script:Ctrl.WsObject.Visibility -eq 'Visible' -and $script:Ctrl.WsComputer.Visibility -eq 'Collapsed')}
Test-Case 'Machine immediately enables Fiche and Assistance poste' {Pick (Row 'A' 'Machine');Assert-True ($script:Ctrl.WsObject.Visibility -eq 'Visible' -and $script:Ctrl.WsComputer.Visibility -eq 'Visible')}
Test-Case 'The selected user has no remote intent' {Pick (Row);Assert-True (-not $script:RemoteIntent)}
Test-Case 'The selected machine owns the single remote intent' {$r=Row 'A' 'Machine';Pick $r;Assert-True ($script:RemoteIntent -eq $r.DN)}
Test-Case 'Relations immediately receives the same selection' {$r=Row;Pick $r;Assert-True ($script:RelationDN -eq $r.DN)}
Test-Case 'AD preload is dispatched once after debounce' {Pick (Row);Send-Pending;Send-Pending;Assert-True ($script:Requests.Count -eq 1)}
Test-Case 'Preload requests no navigation and no remote probes in rendering' {Pick (Row);Send-Pending;$s=$script:Requests[0].State;Assert-True ($s.NoNavigate -and $s.SuppressRemoteProbes -and $s.SelectionBound)}
Test-Case 'The same selection event does not duplicate the read' {$r=Row;Pick $r;Send-Pending;Pick $r;Send-Pending;Assert-True ($script:Requests.Count -eq 1)}
Test-Case 'Double-click starts a pending read without a second request' {$r=Row;Pick $r;Open-SelectedObject;Send-Pending;Assert-True ($script:Requests.Count -eq 1 -and $script:Page -eq 'WsObject')}
Test-Case 'Double-click shares an already running read' {Pick (Row);Send-Pending;Open-SelectedObject;Assert-True ($script:Requests.Count -eq 1 -and $script:Page -eq 'WsObject')}
Test-Case 'AD completion stays on the search page' {$r=Row;Pick $r;Send-Pending;Complete-DomeniaOpenObjectTaskUi (Result-For $r) $script:Requests[0].State;Assert-True ($script:Page -eq 'WsSearch' -and $script:SelectionLoad.Phase -eq 'Ready')}
Test-Case 'Completion does not steal another page visited while loading' {$r=Row;Pick $r;Send-Pending;$script:Page='TabRelations';Complete-DomeniaOpenObjectTaskUi (Result-For $r) $script:Requests[0].State;Assert-True ($script:Page -eq 'TabRelations')}
Test-Case 'Double-click after load uses the data already loaded' {$r=Row;Pick $r;Send-Pending;Complete-DomeniaOpenObjectTaskUi (Result-For $r) $script:Requests[0].State;Open-SelectedObject;Assert-True ($script:Requests.Count -eq 1 -and $script:Page -eq 'WsObject')}
Test-Case 'Loaded machine data enables its content host' {$r=Row 'A' 'Machine';Pick $r;Send-Pending;Complete-DomeniaOpenObjectTaskUi (Result-For $r) $script:Requests[0].State;Assert-True $script:Ctrl.ComputerReadContent.IsEnabled}
Test-Case 'The former object is not exposed while a new object is pending' {$script:SelectedObject=[pscustomobject]@{DN='old'};Pick (Row);Assert-True ($null -eq $script:SelectedObject -and -not $script:Ctrl.ObjectReadContent.IsEnabled)}
Test-Case 'Rapid A/B selects only B before dispatch' {Pick (Row);$b=Row 'B';Pick $b;Send-Pending;Assert-True ($script:Requests.Count -eq 1 -and $script:Requests[0].Payload.DN -eq $b.DN)}
Test-Case 'Late A cannot fill B' {$a=Row;Pick $a;Send-Pending;$old=$script:Requests[0].State;Pick (Row 'B');Send-Pending;Complete-DomeniaOpenObjectTaskUi (Result-For $a) $old;Assert-True ($script:Renders.Count -eq 0 -and $script:CurrentObjectRequestDn -eq (Row 'B').DN)}
Test-Case 'An old failure cannot fail B' {$a=Row;Pick $a;Send-Pending;$old=$script:Requests[0].State;Pick (Row 'B');Send-Pending;Fail-DomeniaOpenObjectTaskUi 'late' $old;Assert-True ($script:SelectionLoad.Phase -eq 'Loading' -and -not $script:Failure)}
Test-Case 'A recreated object is not accepted under the same DN' {$r=Row;Pick $r;Send-Pending;$result=Result-For $r;$result.Properties.objectGUID=@((Row 'B').Guid);Complete-DomeniaOpenObjectTaskUi $result $script:Requests[0].State;Assert-True ($script:Renders.Count -eq 0 -and $script:SelectionLoad.Phase -eq 'Failed')}
Test-Case 'Missing GUID cannot unlock the fiche' {$r=Row;Pick $r;Send-Pending;$result=Result-For $r;$result.Properties.Remove('objectGUID');Complete-DomeniaOpenObjectTaskUi $result $script:Requests[0].State;Assert-True ($script:Renders.Count -eq 0)}
Test-Case 'Binary GUID is read without pipeline expansion' {$r=Result-For (Row);$r.Properties.objectGUID=([guid]((Row).Guid)).ToByteArray();Assert-True ((Get-DomeniaObjectResultGuid $r) -eq (Row).Guid)}
Test-Case 'Session epoch invalidates a callback' {$r=Row;Pick $r;Send-Pending;$script:SessionEpoch++;Complete-DomeniaOpenObjectTaskUi (Result-For $r) $script:Requests[0].State;Assert-True ($script:Renders.Count -eq 0)}
Test-Case 'Different AD server invalidates a callback' {$r=Row;Pick $r;Send-Pending;$script:Conn.Server='dc2.example.invalid';Complete-DomeniaOpenObjectTaskUi (Result-For $r) $script:Requests[0].State;Assert-True ($script:Renders.Count -eq 0)}
Test-Case 'Different query generation invalidates a callback' {$r=Row;Pick $r;Send-Pending;$script:GlobalSearchGeneration++;Complete-DomeniaOpenObjectTaskUi (Result-For $r) $script:Requests[0].State;Assert-True ($script:Renders.Count -eq 0)}
Test-Case 'An old cleanup does not clear a newer request' {Pick (Row);Send-Pending;$id=$script:CurrentObjectRequestId;Clear-DomeniaCurrentObjectRequest 'wrong';Assert-True ($script:CurrentObjectRequestId -eq $id)}
Test-Case 'A failed read stays inline with retry available' {Pick (Row);Send-Pending;Fail-DomeniaOpenObjectTaskUi 'Access denied' $script:Requests[0].State;Assert-True ($script:Ctrl.BtnObjectReadRetry.IsEnabled -and $script:Popups -eq 0 -and $script:Page -eq 'WsSearch')}
Test-Case 'Repeated click after failure is not an automatic retry' {$r=Row;Pick $r;Send-Pending;Fail-DomeniaOpenObjectTaskUi 'Access denied' $script:Requests[0].State;Pick $r;Send-Pending;Assert-True ($script:Requests.Count -eq 1)}
Test-Case 'Explicit retry repeats only the AD read' {Pick (Row 'A' 'Machine');Send-Pending;Fail-DomeniaOpenObjectTaskUi 'error' $script:Requests[0].State;$script:RemoteIntent='sentinel';Retry-DomeniaSelectedObjectRead;Assert-True ($script:Requests.Count -eq 2 -and $script:RemoteIntent -eq 'sentinel')}
Test-Case 'Multiple selection does not dispatch individual reads' {$g=$script:Ctrl.DgObjects;$g.SelectedItem=Row;$g.SelectedItems=@((Row),(Row 'B'));Queue-DomeniaSelectedObjectOpen;Assert-True ($script:Requests.Count -eq 0 -and $null -eq $script:SelectionLoad)}
Test-Case 'No selection does not dispatch a read' {Pick $null;Assert-True ($script:Requests.Count -eq 0 -and $script:Ctrl.WsObject.Visibility -eq 'Collapsed')}
Test-Case 'Programmatic suppressed events do not dispatch' {$script:SuppressGridSelectionEvents=$true;Pick (Row);Assert-True ($null -eq $script:SelectionLoad -and -not $script:RemoteIntent)}
Test-Case 'A disabled grid cannot create a selection request' {$script:Ctrl.DgObjects.IsEnabled=$false;Pick (Row);Assert-True ($script:Requests.Count -eq 0)}
Test-Case 'Busy AD write blocks selection/preload' {$script:BusyWrite=$true;Pick (Row);Assert-True ($null -eq $script:PendingObjectSelection -and $script:Requests.Count -eq 0)}
Test-Case 'A pending read pauses during a write' {Pick (Row);$script:BusyWrite=$true;Send-Pending;Assert-True ($script:Requests.Count -eq 0 -and $script:SelectionLoad.Phase -eq 'Paused');$script:BusyWrite=$false;Send-Pending;Assert-True ($script:Requests.Count -eq 1)}
Test-Case 'Pending preload survives the disabled-grid phase of a write' {Pick (Row);$script:BusyWrite=$true;$script:Ctrl.DgObjects.IsEnabled=$false;Send-Pending;Assert-True ($null -ne $script:PendingObjectSelection -and $script:Requests.Count -eq 0);$script:BusyWrite=$false;$script:Ctrl.DgObjects.IsEnabled=$true;Send-Pending;Assert-True ($script:Requests.Count -eq 1)}
Test-Case 'Invalid cache is ignored, fresh AD request is still sent' {$r=Row;Pick $r;$key=Get-DomeniaObjectCacheKey $r.DN $r.Guid (Get-DomeniaObjectReadIdentity);$bad=Result-For $r;$bad.Properties.Remove('objectGUID');$script:Cache[$key]=$bad;Send-Pending;Assert-True ($script:Renders.Count -eq 0 -and $script:Requests.Count -eq 1)}
Test-Case 'Draft refusal precedes context and probe changes' {$script:DraftState=[pscustomobject]@{DN='keep'};$script:DraftApproved=$false;Pick (Row);Assert-True ($script:RestoredDN -eq 'keep' -and -not $script:RemoteIntent -and -not $script:RelationDN -and $null -eq $script:SelectionLoad)}
Test-Case 'Cache keys distinguish AD identities' {$g='11111111-1111-1111-1111-111111111111';Assert-True ((Get-DomeniaObjectCacheKey 'dn' $g 'reader1') -cne (Get-DomeniaObjectCacheKey 'dn' $g 'reader2'))}
Test-Case 'Cache keys distinguish GUIDs' {Assert-True ((Get-DomeniaObjectCacheKey 'dn' '11111111-1111-1111-1111-111111111111' 'reader') -cne (Get-DomeniaObjectCacheKey 'dn' '22222222-2222-2222-2222-222222222222' 'reader'))}
Test-Case 'D025 : without a real GUID the object is not cached (empty key)' {Assert-True ((Get-DomeniaObjectCacheKey 'dn' 'not-a-guid' 'reader') -ceq '')}
Test-Case 'A matching cache is shown while a fresh read still starts' {$r=Row;Pick $r;$id=Get-DomeniaObjectReadIdentity;$key=Get-DomeniaObjectCacheKey $r.DN $r.Guid $id;$script:Cache[$key]=Result-For $r;Send-Pending;Assert-True ($script:Renders.Count -eq 1 -and $script:Requests.Count -eq 1 -and $script:SelectionLoad.Phase -eq 'Cached' -and -not $script:Ctrl.ObjectReadContent.IsEnabled)}
Test-Case 'D030 : cache hors ligne grise, reessai explicite puis fiche relue modifiable' {
    $r=Row;Pick $r
    $key=Get-DomeniaObjectCacheKey $r.DN $r.Guid (Get-DomeniaObjectReadIdentity)
    $script:Cache[$key]=Result-For $r
    $script:DirectoryReachability=[pscustomobject]@{Epoch=$script:SessionEpoch;Offline=$true;LastOutageUtc=[datetime]::UtcNow.AddMinutes(-1).ToString('o')}
    Send-Pending
    Fail-DomeniaOpenObjectTaskUi 'Serveur indisponible' $script:Requests[0].State
    Assert-True ($script:Ctrl.ObjectReadContent.Visibility -eq 'Visible' -and -not $script:Ctrl.ObjectReadContent.IsEnabled)
    Assert-True ($script:Ctrl.BtnObjectReadRetry.IsEnabled -and -not (Get-DomeniaSelectionCachePolicy).CanEdit)
    $script:DirectoryReachability.Offline=$false
    Retry-DomeniaSelectedObjectRead
    Assert-True ($script:Requests.Count -eq 2)
    Complete-DomeniaOpenObjectTaskUi (Result-For $r) $script:Requests[1].State
    Assert-True ($script:Ctrl.ObjectReadContent.IsEnabled -and (Get-DomeniaSelectionCachePolicy).CanEdit)
}
Test-Case 'Bootstrap registry verifies all entries without a hardcoded count' {$registry=Get-DomeniaWorkerOperationHashes;Assert-True ((Assert-DomeniaWorkerRegistry -Registry $registry) -eq $registry.Count)}
Test-Case 'All runtime modules import in a clean runspace and export their real functions' {
    $ps=[PowerShell]::Create()
    try {
        [void]$ps.AddScript('param($path) $ErrorActionPreference="Stop"; . $path; @($script:DomeniaRuntimeImports).Count').AddArgument((Join-Path $wad 'Domenia-Modules.ps1'))
        $r=@($ps.Invoke())
        Assert-True (-not $ps.HadErrors) (($ps.Streams.Error|ForEach-Object{$_.ToString()}) -join '; ')
        Assert-True ($r.Count -ge 1 -and [int]$r[-1] -ge 20)
    } finally { $ps.Dispose() }
}
Test-Case 'Every worker literal passes the native parser, without executing the worker' {
    $contracts=[IO.File]::ReadAllText((Join-Path $root 'tools\operation-contracts.json'))|ConvertFrom-Json
    foreach($contract in @($contracts)){
        $path=Join-Path $root ([string]$contract.File)
        $tokens=$null;$errors=$null;$a=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
        Assert-True (@($errors).Count -eq 0)
        $f=@($a.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $contract.Function},$true))
        Assert-True ($f.Count -eq 1)
        $l=@($f[0].FindAll({param($n) ($n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst]) -and [string]$n.StringConstantType -match 'HereString$'},$true)|Sort-Object {$_.Extent.StartOffset})
        Assert-True ($l.Count -gt [int]$contract.LiteralIndex)
        $code=[string]$l[[int]$contract.LiteralIndex].Value
        $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseInput($code,[ref]$tokens,[ref]$errors)
        Assert-True (@($errors).Count -eq 0) ($contract.Operation+': '+(@($errors|ForEach-Object{$_.Message}) -join '; '))
    }
}
# Full application XAML, without the application's initialization/authentication.
if(-not $SkipWpf){
    foreach($theme in @('Light','Dark')) {
        Test-Case ('WPF: both content hosts and nonmodal loading placeholders, '+$theme) {
            $xml=Get-MainXaml;$reader=[Xml.XmlNodeReader]::new([xml]$xml);$window=$null
            try {
                $window=[Windows.Markup.XamlReader]::Load($reader)
                foreach($kind in @('Object','Computer')){
                    $contentHost=$window.FindName($kind+'ReadContent');$placeholder=$window.FindName($kind+'ReadPlaceholder')
                    Assert-True ($null -ne $contentHost -and $null -ne $placeholder -and -not $contentHost.IsEnabled)
                    Assert-True ($window.FindName('Btn'+$kind+'ReadRetry').Visibility -eq 'Hidden')
                }
                $palette=Get-SuitePalette -Theme $theme
                $bc=[Windows.Media.BrushConverter]::new()
                foreach($k in $palette.Keys){$window.Resources[$k]=$bc.ConvertFromInvariantString($palette[$k])}
                $window.Measure([Windows.Size]::new(1280,800));$window.Arrange([Windows.Rect]::new(0,0,1280,800));$window.UpdateLayout()
                Assert-True ($window.FindName('DgObjects').Columns.Count -ge 16)
                # Exercise the real presentation helpers against real controls.
                $savedControls=$script:Ctrl;$script:Ctrl=@{}
                foreach($match in [regex]::Matches($xml,'x:Name="([^"]+)"')){
                    $control=$window.FindName($match.Groups[1].Value)
                    if($null -ne $control){$script:Ctrl[$match.Groups[1].Value]=$control}
                }
                $row=Row 'A' 'Machine';$grid=$script:Ctrl.DgObjects
                [void]$grid.Items.Add($row);$grid.SelectedItem=$row
                Queue-DomeniaSelectedObjectOpen
                Assert-True ($script:Ctrl.WsObject.Visibility -eq 'Visible' -and $script:Ctrl.WsComputer.Visibility -eq 'Visible')
                Assert-True ($script:Ctrl.ObjectReadPlaceholder.Visibility -eq 'Visible' -and -not $script:Ctrl.ObjectReadContent.IsEnabled)
                Send-Pending
                Complete-DomeniaOpenObjectTaskUi (Result-For $row) $script:Requests[0].State
                Assert-True ($script:Ctrl.ComputerReadContent.IsEnabled -and $script:Ctrl.ComputerReadPlaceholder.Visibility -eq 'Collapsed')
                $script:Ctrl=$savedControls
            } finally { $reader.Close();if($null -ne $window){$window.Close()} }
        }
    }
}else{$checks.Add([pscustomobject]@{Name='WPF materialization';Status='Skipped';Detail='Explicit SkipWpf; not a complete release test.'})}
if($null -ne $script:SelectionOpenTimer){$script:SelectionOpenTimer.Stop()}
$passed=@($checks|Where-Object{$_.Status -eq 'Passed'}).Count;$failed=@($checks|Where-Object{$_.Status -eq 'Failed'}).Count;$skipped=@($checks|Where-Object{$_.Status -eq 'Skipped'}).Count
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-preload-'+[guid]::NewGuid().ToString('N')+'.json')}
$report=[ordered]@{Build='2026.10.01-DOMENIA-1.0-RC1.10.7-SELECTION';Host=$PSVersionTable.PSVersion.ToString();NativeWindowsPowerShell=$native;Wpf=(-not [bool]$SkipWpf);MockedNetwork=$true;LiveAD=$false;LiveCIM=$false;Passed=$passed;Failed=$failed;Skipped=$skipped;Complete=($failed -eq 0 -and $skipped -eq 0 -and $passed -ge 40);Tests=$checks.ToArray()}
[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){Write-Host ("$passed passed, $failed failed, $skipped skipped. Rapport: "+$ReportPath);$checks|Where-Object{$_.Status -eq 'Failed'}|Format-Table -AutoSize}
if(-not $report.Complete){exit 1}
