#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet, [switch]$SkipWpf)
# Isolated tests. Imports definitions by AST only; never starts the application.
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw $errors[0].Message}
foreach($name in @('Get-MainXaml','Get-DomeniaControl','Set-DomeniaControlText','Get-DomeniaSearchMode','Set-DomeniaSearchMode','Get-DomeniaSearchText','Get-DomeniaSearchScope','Get-GlobalSelectedTypeFilter','Get-TypeLdapFilter','Test-DomeniaSearchStateCurrent','Invoke-GlobalSearch','Escape-LdapValue','Normalize-LinkComputer','Get-DomeniaEffectiveWorkerResult','Set-DomeniaItemsSource','Get-DomeniaGridDateSortKey','Get-DomeniaGridDateShortText','Add-DomeniaGridDateKeys')){
    $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
    if($nodes.Count -ne 1){throw ('Definition ambiguous: '+$name)}
    Invoke-Expression $nodes[0].Extent.Text
}
# D120: the global search uses the pure search rules (plan, contract check), as the closed loader provides them.
. (Join-Path $wad 'modules\Domenia-Common.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Search.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Live.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Experience.Model.ps1')
# D027: Live.UI builds its negative cache with the cache rules.
. (Join-Path $wad 'modules\Domenia-Cache.Model.ps1')
# FI-05 / PF-06: the progressive search takes its timer from the protected factory of the engine.
. (Join-Path $wad 'modules\Domenia-Engine.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Engine.UI.ps1')
. (Join-Path $wad 'modules\Domenia-Live.UI.ps1')
# Explicit dependencies; none can issue a network call, launch a process or read the real database.
function Get-CfgValue {param($Section,$Name,$Default);return $Default}
function Test-DomeniaAccessBusyWrite {return $script:WriteBlocked}
function Test-DomeniaDraftNavigation {param($DN);return (-not $script:DraftBlocked)}
function Invalidate-DomeniaSearchResults {$script:GlobalSearchGeneration++;$script:Invalidations++}
function Update-DomeniaSearchScopeUi {}
function Select-DomeniaWorkspace {param($Workspace);$script:Page=$Workspace}
function Stop-DomeniaSelectionOpenTimer {}
function Clear-DomeniaCurrentObjectRequest {param($RequestId)}
function Reset-DomeniaSelectionBoundViews {}
function Add-DomeniaUiLog {param($Area,$Level,$Text)}
function Set-Status {param($Text,$Level);$script:LastStatus=$Text}
function Write-AppLog {param($Text,$Level)}
function Show-DomeniaOperationError {param($Operation,$ErrorRecordOrException,[switch]$NoPopup);throw $ErrorRecordOrException}
function Begin-DomeniaLiveSearch {param($State,$Payload);$script:LastState=$State;$script:StreamStarts++}
function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$DisableControls,$TimeoutSeconds,$StatusText,$SuccessHandler,$ErrorHandler)
    if($OperationId -ne 'GlobalSearch'){throw 'Unexpected worker.'}
    $script:LastPayload=$Payload;$script:LastState=$CallbackState;$script:Tasks++
}
function New-Object {
    param([Parameter(Position=0)][string]$TypeName)
    if($TypeName -eq 'System.Collections.ArrayList'){return ,([Collections.ArrayList]::new())}
    if($TypeName -eq 'System.Text.StringBuilder'){return [Text.StringBuilder]::new()}
    if($TypeName -eq 'System.Collections.Generic.List[string]'){return ,([Collections.Generic.List[string]]::new())}
    if($TypeName -ne 'Net.NetworkInformation.Ping'){throw ('Unexpected native object: '+$TypeName)}
    $obj=[pscustomobject]@{}
    $obj|Add-Member -MemberType ScriptMethod -Name Send -Value {
        param($Target,$Timeout)
        $script:PingCalls++;$script:PingTarget=$Target;$script:PingTimeout=$Timeout
        if($script:PingThrows){throw [InvalidOperationException]::new('Simulated DNS failure')}
        return [pscustomobject]@{Status=$script:PingStatus;RoundtripTime=3}
    }
    $obj|Add-Member -MemberType ScriptMethod -Name Dispose -Value {$script:PingDisposed++}
    return $obj
}
function Get-WMachineCredential {param($Context);$script:CredentialCalls++;return $null}
function New-CimSessionOption {param($Protocol,$ErrorAction);if($Protocol -ne 'Dcom'){throw 'Unexpected transport'};return [pscustomobject]@{Protocol=$Protocol}}
function New-CimSession {param($ComputerName,$SessionOption,$OperationTimeoutSec,$Credential,$ErrorAction)
    $script:CimCalls++
    if($script:ProbeEvents.Count -ne 1){throw 'Ping event was not published before CIM.'}
    if($script:CimFails){throw [UnauthorizedAccessException]::new('Simulated access denied')}
    return [pscustomobject]@{Computer=$ComputerName}
}
function Get-CimInstance {param($CimSession,$ClassName,$Property,$OperationTimeoutSec,$ErrorAction)
    if($ClassName -ne 'Win32_ComputerSystem' -or $Property -ne 'UserName'){throw 'Unexpected CIM read'}
    return [pscustomobject]@{UserName=$script:CimUser}
}
function Remove-CimSession {param($CimSession,$ErrorAction);$script:CimDisposed++}
function New-WSearcher {throw 'No LDAP request is permitted in these probe fixtures.'}
function Reset-Fixture {
    $script:CurrentPresenceFilter='Sans réponse au ping';$script:SearchMode='OU';$script:WriteBlocked=$false;$script:DraftBlocked=$false
    $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid';Domain='example.invalid';Server='dc.example.invalid';Connected=$true}
    $script:SelectedBranchDn='OU=Postes,DC=example,DC=invalid';$script:GlobalSearchGeneration=9
    $script:SelectedObject=$null;$script:CurrentObjectRequestId='';$script:SelectionResetDn=''
    $script:Ctrl=@{
        SearchBrowserLayout=[pscustomobject]@{Tag='OU'}
        TxtGlobalSearch=[pscustomobject]@{Text='alex'}
        TxtBranchSearch=[pscustomobject]@{Text=''}
        TxtGlobalLimit=[pscustomobject]@{Text='100'}
        LblBranchCount=[pscustomobject]@{Text=''}
        LblLiveStatus=[pscustomobject]@{Text=''}
        TxtSuiteResultFilter=[pscustomobject]@{Text='PC-ONLY'}
        CmbGlobalType=[pscustomobject]@{SelectedItem=[pscustomobject]@{Content='Machines'}}
        CmbPresenceFilter=[pscustomobject]@{SelectedItem=[pscustomobject]@{Content='Sans réponse au ping'}}
        ChkSubtree=[pscustomobject]@{IsChecked=$false}
        DgObjects=[pscustomobject]@{SelectedItem=$null;SelectedIndex=-1;SelectedItems=@();IsEnabled=$true}
    }
    $script:Invalidations=0;$script:Tasks=0;$script:StreamStarts=0;$script:LastState=$null;$script:LastPayload=$null;$script:Page='';$script:LastStatus=''
    $script:PingCalls=0;$script:PingDisposed=0;$script:PingThrows=$false;$script:PingStatus='Success';$script:PingTarget='';$script:PingTimeout=0
    $script:CimCalls=0;$script:CimDisposed=0;$script:CimFails=$false;$script:CimUser='PC-TEST\alex';$script:CredentialCalls=0
    $script:ProbeEvents=[Collections.Concurrent.ConcurrentQueue[object]]::new();$script:Live=$null;$script:SessionEpoch=3L
}
function Probe {param([bool]$User=$true,[bool]$UseCim=$true,[string]$Target='PC-TEST')
    $Payload=[pscustomobject]@{Computer=$Target;Key='cn=pc-test,ou=postes,dc=example,dc=invalid';Guid='11111111-1111-1111-1111-111111111111';MethodSeconds=4;ProbeUser=$User;PresenceProgress=$script:ProbeEvents;PresenceState=[pscustomobject]@{Identity='reader';Epoch=3L}}
    $Context=[pscustomobject]@{UseCim=$UseCim;Netbios='EXAMPLE';Domain='example.invalid';BaseDn='DC=example,DC=invalid'}
    return (& ([scriptblock]::Create((Get-DomeniaLiveProbeCode))))
}
function Previous-Observation {
    return [pscustomobject]@{Key='pc';Guid='g';Computer='PC';Outcome='Observed';CurrentUser='DOMAIN\old';LastUser='DOMAIN\old';ObservedUtc='2026-09-01T10:00:00Z';CheckedUtc='2026-09-01T11:00:00Z';UserCheckedUtc='2026-09-01T11:00:00Z';Source='CIM';LastSource='CIM';Presence='En ligne';PresenceCheckedUtc='2026-09-01T11:00:00Z';PresenceDetail='Old';LinkUser='old';UserDn='CN=old,DC=example,DC=invalid';UserGuid='u'}
}
function Ping-Observation {param([string]$Presence='Sans réponse au ping',[string]$When='2026-10-01T10:00:00Z')
    return [pscustomobject]@{Key='pc';Guid='g';Computer='PC';Outcome='PresenceOnly';Presence=$Presence;PresenceCheckedUtc=$When;PresenceDetail='Test ICMP'}
}
$script:Checks=[Collections.Generic.List[object]]::new()
function Expect {param([bool]$Ok,[string]$Reason='Assertion failed');if(-not $Ok){throw $Reason}}
function Case {param([string]$Name,[scriptblock]$Body)
    try{Reset-Fixture;& $Body|Out-Null;$script:Checks.Add([pscustomobject]@{Name=$Name;Status='Passed';Error=''})}
    catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Status='Failed';Error=$_.Exception.Message})}
}
Case 'Global scope ignores selected OU' {Expect ((Get-DomeniaSearchScope -Mode Global).BaseDn -eq $script:Conn.BaseDn)}
Case 'Global scope always includes descendants' {Expect ((Get-DomeniaSearchScope -Mode Global).Scope -eq 'Subtree')}
Case 'OU scope retains selected branch' {Expect ((Get-DomeniaSearchScope -Mode OU).BaseDn -eq $script:SelectedBranchDn)}
Case 'OU children-only remains available' {Expect ((Get-DomeniaSearchScope -Mode OU).Scope -eq 'OneLevel')}
Case 'OU subtree remains available' {$script:Ctrl.ChkSubtree.IsChecked=$true;Expect ((Get-DomeniaSearchScope -Mode OU).Scope -eq 'Subtree')}
Case 'Global type includes users despite Machines selection' {Expect ((Get-GlobalSelectedTypeFilter -Mode Global) -like '*objectClass=user*')}
Case 'OU type remains restricted to machines' {Expect ((Get-GlobalSelectedTypeFilter -Mode OU) -eq (Get-TypeLdapFilter 'Machines'))}
Case 'Upper text and OU text are independent' {$script:Ctrl.TxtBranchSearch.Text='local';Expect ((Get-DomeniaSearchText -Mode Global) -eq 'alex' -and (Get-DomeniaSearchText -Mode OU) -eq 'local')}
Case 'Missing domain is refused without default domain' {$script:Conn.BaseDn='';$thrown=$false;try{Get-DomeniaSearchScope -Mode Global}catch{$thrown=$true};Expect $thrown}
Case 'Default entry point searches globally' {Invoke-GlobalSearch;Expect ($script:Tasks -eq 1 -and $script:LastState.SearchMode -eq 'Global' -and $script:LastPayload.BaseDn -eq $script:Conn.BaseDn)}
Case 'Global request preserves OU selection and depth' {$before=$script:SelectedBranchDn;Invoke-GlobalSearch;Expect ($script:SelectedBranchDn -eq $before -and -not $script:Ctrl.ChkSubtree.IsChecked)}
Case 'Global request keeps the OU type and starts with an empty filter of the list (CO-05)' {Invoke-GlobalSearch;Expect (($script:Ctrl.CmbGlobalType.SelectedItem.Content -eq 'Machines') -and ($script:Ctrl.TxtSuiteResultFilter.Text -eq ''))}
Case 'A refresh, a continuation or a favourite keep the filter of the list (CO-05)' {
    Invoke-GlobalSearch -SearchMode OU -PreserveSelection;Expect ($script:Ctrl.TxtSuiteResultFilter.Text -eq 'PC-ONLY') 'Actualiser a vide le filtre'
    Invoke-GlobalSearch -SearchMode OU -KeepLocalFilter;Expect ($script:Ctrl.TxtSuiteResultFilter.Text -eq 'PC-ONLY') 'Le favori a perdu son filtre'
    Invoke-GlobalSearch -SearchMode OU -LimitOverride 200;Expect ($script:Ctrl.TxtSuiteResultFilter.Text -eq 'PC-ONLY') 'La suite a vide le filtre'
    Invoke-GlobalSearch -SearchMode OU;Expect ($script:Ctrl.TxtSuiteResultFilter.Text -eq '') 'Une nouvelle recherche garde le filtre de la liste precedente'
}
Case 'A refused search keeps the filter of the list (CO-05)' {$script:Ctrl.TxtGlobalSearch.Text='a';Invoke-GlobalSearch;Expect (($script:Tasks -eq 0) -and ($script:Ctrl.TxtSuiteResultFilter.Text -eq 'PC-ONLY'))}
Case 'Global request tags layout to disable local filters' {Invoke-GlobalSearch;Expect ($script:Ctrl.SearchBrowserLayout.Tag -eq 'Global')}
Case 'OU request ignores header search and uses scope' {Invoke-GlobalSearch -SearchMode OU;Expect ($script:LastState.Search -eq '' -and $script:LastPayload.BaseDn -eq $script:SelectedBranchDn)}
Case 'OU request retains selected object type' {Invoke-GlobalSearch -SearchMode OU;Expect ($script:LastState.TypeFilter -eq (Get-TypeLdapFilter 'Machines'))}
Case 'OU saved term is honored without changing header' {$script:Ctrl.TxtBranchSearch.Text='PC';Invoke-GlobalSearch -SearchMode OU;Expect ($script:LastState.Search -eq 'PC' -and $script:Ctrl.TxtGlobalSearch.Text -eq 'alex')}
Case 'Display name and surname are in first global pass' {Invoke-GlobalSearch;Expect ($script:LastPayload.PrefixFilter.Contains('(displayName=alex*)') -and $script:LastPayload.PrefixFilter.Contains('(sn=alex*)'))}
Case 'Given name and mail are in first global pass' {Invoke-GlobalSearch;Expect ($script:LastPayload.PrefixFilter.Contains('(givenName=alex*)') -and $script:LastPayload.PrefixFilter.Contains('(mail=alex*)'))}
Case 'ANR is part of global first pass' {Invoke-GlobalSearch;Expect ($script:LastPayload.PrefixFilter.Contains('(anr=alex)'))}
Case 'Mail query uses mail and UPN in whole domain' {$script:Ctrl.TxtGlobalSearch.Text='alex@example.invalid';Invoke-GlobalSearch;Expect ($script:LastPayload.PrefixFilter.Contains('(mail=alex@example.invalid*)') -and $script:LastState.BaseDn -eq $script:Conn.BaseDn)}
Case 'LDAP metacharacters remain escaped' {$script:Ctrl.TxtGlobalSearch.Text='alex(x)';Invoke-GlobalSearch;Expect ($script:LastPayload.PrefixFilter.Contains('alex\28x\29'))}
Case 'Global limit remains capped' {
    $script:Ctrl.TxtGlobalLimit.Text='100000';Invoke-GlobalSearch
    Expect ($script:LastPayload.Limit -eq 20000 -and $script:Ctrl.TxtGlobalLimit.Text -eq '20000')
    $script:Ctrl.TxtGlobalLimit.Text='100';Invoke-GlobalSearch -LimitOverride 40000
    Expect ($script:LastPayload.Limit -eq 20000 -and $script:Ctrl.TxtGlobalLimit.Text -eq '100')
    $script:Ctrl.TxtGlobalLimit.Text='0';Invoke-GlobalSearch
    Expect ($script:LastPayload.Limit -eq 100 -and $script:Ctrl.TxtGlobalLimit.Text -eq '100')
}
Case 'Write lock blocks both search modes' {$script:WriteBlocked=$true;Invoke-GlobalSearch;Invoke-GlobalSearch -SearchMode OU;Expect ($script:Tasks -eq 0 -and $script:Invalidations -eq 0)}
Case 'Draft decision blocks a new search without changing mode' {$script:DraftBlocked=$true;Invoke-GlobalSearch;Expect ($script:Tasks -eq 0 -and (Get-DomeniaSearchMode) -eq 'OU')}
Case 'Cache key separates global from OU even at domain root' {$script:SelectedBranchDn=$script:Conn.BaseDn;$script:Ctrl.ChkSubtree.IsChecked=$true;$script:Ctrl.CmbGlobalType.SelectedItem.Content='Tous';$script:Ctrl.TxtBranchSearch.Text='alex';Invoke-GlobalSearch;$globalKey=$script:LastState.CacheKey;Invoke-GlobalSearch -SearchMode OU;Expect ($globalKey -cne $script:LastState.CacheKey)}
Case 'Global result remains valid despite an unchanged hidden OU setting' {Invoke-GlobalSearch;$script:SelectedBranchDn='OU=Other,DC=example,DC=invalid';$script:Ctrl.CmbGlobalType.SelectedItem.Content='Groupes';Expect (Test-DomeniaSearchStateCurrent $script:LastState)}
Case 'Old mode results are rejected' {Invoke-GlobalSearch;$state=$script:LastState;Set-DomeniaSearchMode OU;Expect (-not (Test-DomeniaSearchStateCurrent $state))}
Case 'Old generation results are rejected' {Invoke-GlobalSearch;$script:GlobalSearchGeneration++;Expect (-not (Test-DomeniaSearchStateCurrent $script:LastState))}
Case 'Changed global text rejects old results' {Invoke-GlobalSearch;$script:Ctrl.TxtGlobalSearch.Text='bob';Expect (-not (Test-DomeniaSearchStateCurrent $script:LastState))}
Case 'A search does not ping or read CIM' {Invoke-GlobalSearch;Expect ($script:PingCalls -eq 0 -and $script:CimCalls -eq 0)}
Case 'Ping-only sends exactly one echo to selected target' {$r=Probe -User $false;Expect ($script:PingCalls -eq 1 -and $script:PingTarget -eq 'PC-TEST' -and $script:PingTimeout -eq 900 -and $r.Presence -eq 'En ligne')}
Case 'Ping-only touches no credentials or CIM' {$r=Probe -User $false;Expect ($r.Outcome -eq 'PresenceOnly' -and $script:CredentialCalls -eq 0 -and $script:CimCalls -eq 0)}
Case 'Disabled CIM still allows single ping' {$r=Probe -UseCim $false;Expect ($r.Outcome -eq 'PresenceOnly' -and $script:PingCalls -eq 1 -and $script:CimCalls -eq 0)}
Case 'Combined probe publishes ping before CIM' {$r=Probe;Expect ($script:ProbeEvents.Count -eq 1 -and $script:CimCalls -eq 1 -and $r.Outcome -eq 'Observed')}
Case 'Ping and CIM resources are disposed' {$r=Probe;Expect ($script:PingDisposed -eq 1 -and $script:CimDisposed -eq 1)}
Case 'No ICMP reply is not declared powered off' {$script:PingStatus='TimedOut';$r=Probe -User $false;Expect ($r.Presence -eq 'Sans réponse au ping' -and $r.Presence -ne 'Hors ligne')}
Case 'Ping exception is a separate state and resource is disposed' {$script:PingThrows=$true;$r=Probe -User $false;Expect ($r.Presence -eq 'Erreur de ping' -and $script:PingDisposed -eq 1)}
Case 'Positive ping survives denied CIM' {$script:CimFails=$true;$r=Probe;Expect ($r.Outcome -eq 'Denied' -and $r.Presence -eq 'En ligne' -and $script:PingCalls -eq 1)}
Case 'Negative ping does not prevent requested CIM' {$script:PingStatus='TimedOut';$r=Probe;Expect ($r.Outcome -eq 'Observed' -and $r.Presence -eq 'En ligne' -and $r.PresenceDetail.Contains('CIM/DCOM'))}
Case 'Empty console is not a statement about RDP sessions' {$script:CimUser='';$r=Probe;Expect ($r.Outcome -eq 'NoConsole' -and $r.Detail.Contains('RDP'))}
Case 'Invalid target produces no network call' {$thrown=$false;try{Probe -Target 'PC;evil'}catch{$thrown=$true};Expect ($thrown -and $script:PingCalls -eq 0 -and $script:CimCalls -eq 0)}
Case 'Early event contains network fields only' {$r=Probe -User $false;$p=$null;[void]$script:ProbeEvents.TryDequeue([ref]$p);Expect ($p.Result.Outcome -eq 'PresenceOnly' -and $null -eq $p.Result.PSObject.Properties['Credential'] -and $null -eq $p.State.PSObject.Properties['Row'])}
Case 'No observation starts as Non verified' {$v=Get-DomeniaLivePresenceView $null;Expect ($v.State -eq 'Non vérifié' -and $v.Display -eq 'Non vérifié')}
Case 'Historic presence stays visibly cached' {$v=Get-DomeniaLivePresenceView (Previous-Observation) -Cached;Expect ($v.Display -eq 'En ligne (cache)' -and $v.Detail.Contains('2026-09-01'))}
Case 'Legacy offline wording becomes no ping response' {$o=Previous-Observation;$o.Presence='Hors ligne';Expect ((Get-DomeniaLivePresenceView $o -Cached).Display -eq 'Sans réponse au ping (cache)')}
Case 'Presence filtering accepts historical online' {Expect (Test-DomeniaPresenceMatch 'En ligne (cache)' 'En ligne')}
Case 'Presence filtering separates network error from no reply' {Expect (-not (Test-DomeniaPresenceMatch 'Erreur de ping' 'Sans réponse au ping'))}
Case 'Ping update does not erase known console user' {$v=ConvertTo-DomeniaLiveObservation (Ping-Observation) (Previous-Observation);Expect ($v.CurrentUser -eq 'DOMAIN\old' -and $v.LastUser -eq 'DOMAIN\old')}
Case 'Ping update does not rejuvenate user observation or attempt' {$o=Previous-Observation;$v=ConvertTo-DomeniaLiveObservation (Ping-Observation) $o;Expect ($v.ObservedUtc -eq $o.ObservedUtc -and $v.UserCheckedUtc -eq $o.UserCheckedUtc)}
Case 'Ping update retains confirmed AD identity' {$o=Previous-Observation;$v=ConvertTo-DomeniaLiveObservation (Ping-Observation) $o;Expect ($v.UserDn -eq $o.UserDn -and $v.LinkUser -eq $o.LinkUser)}
Case 'Ping updates its own timestamp and status' {$v=ConvertTo-DomeniaLiveObservation (Ping-Observation) (Previous-Observation);Expect ($v.Presence -eq 'Sans réponse au ping' -and $v.PresenceCheckedUtc -eq '2026-10-01T10:00:00Z')}
Case 'Ping without earlier user does not invent one' {$v=ConvertTo-DomeniaLiveObservation (Ping-Observation) $null;Expect ($v.Outcome -eq 'NotRequested' -and -not $v.CurrentUser -and -not $v.ObservedUtc)}
Case 'CIM timeout retains early positive ping' {$o=ConvertTo-DomeniaLiveObservation (Ping-Observation 'En ligne') (Previous-Observation);$v=ConvertTo-DomeniaLiveObservation ([pscustomobject]@{Key='pc';Guid='g';Computer='PC';Outcome='Timeout';User='';Presence='Inconnu';Detail='Timeout'}) $o;Expect ($v.Presence -eq 'En ligne' -and $v.PresenceCheckedUtc -eq $o.PresenceCheckedUtc -and $v.LastUser -eq $o.LastUser)}
Case 'Older network packet cannot overwrite newer status' {$o=ConvertTo-DomeniaLiveObservation (Ping-Observation 'En ligne') $null;$v=ConvertTo-DomeniaLiveObservation (Ping-Observation 'Sans réponse au ping' '2026-09-01T10:00:00Z') $o;Expect ($v.Presence -eq 'En ligne')}
Case 'Fractional UTC seconds are compared as dates, not strings' {$o=ConvertTo-DomeniaLiveObservation (Ping-Observation 'En ligne' '2026-10-01T10:00:00Z') $null;$v=ConvertTo-DomeniaLiveObservation (Ping-Observation 'Sans réponse au ping' '2026-10-01T10:00:00.5000000Z') $o;Expect ($v.Presence -eq 'Sans réponse au ping')}
Case 'Recreated object cannot inherit old user' {$p=Ping-Observation;$p.Guid='new-guid';$v=ConvertTo-DomeniaLiveObservation $p (Previous-Observation);Expect (-not $v.LastUser -and -not $v.UserDn)}
# CO-05: a non-progressive repaint (presence ping fallback, Show-ObjectRows) applies the filter of the list in every mode.
Case 'Global repaint applies the filter of the list too (CO-05)' {
    $script:Ctrl.DgObjects=[pscustomobject]@{ItemsSource=$null};$script:Ctrl.LblSuiteResultCount=[pscustomobject]@{Text=''}
    $a=[pscustomobject]@{Type='Utilisateur';Name='Alex';Login='alex';UPN='';Association='';Presence='Sans objet';SessionDisplay='';SessionState=''}
    $p=[pscustomobject]@{Type='Machine';Name='PC-ONLY';Login='pc';UPN='';Association='';Presence='';SessionDisplay='';SessionState=''}
    Set-DomeniaSearchMode Global;[void](Set-DomeniaItemsSource -Name DgObjects -Rows @($a,$p))
    Expect ((@($script:Ctrl.DgObjects.ItemsSource).Count -eq 1) -and (@($script:Ctrl.DgObjects.ItemsSource)[0].Name -eq 'PC-ONLY')) 'Global list not narrowed by the filter of the list'
    Expect ($script:Ctrl.LblSuiteResultCount.Text.Contains('filtre de la liste, sans requête AD')) 'Repaint label'
    Set-DomeniaSearchMode OU;[void](Set-DomeniaItemsSource -Name DgObjects -Rows @($a,$p))
    Expect (@($script:Ctrl.DgObjects.ItemsSource).Count -eq 1 -and @($script:Ctrl.DgObjects.ItemsSource)[0].Name -eq 'PC-ONLY') 'OU local filter must still apply'
}
Case 'Global contract refuses an inherited OU perimeter' {
    $real=${function:Get-DomeniaSearchScope}
    try{
        ${function:Get-DomeniaSearchScope}={param($Mode) [pscustomobject]@{BaseDn=$script:SelectedBranchDn;Scope='OneLevel';IsDomain=$false;Mode=$Mode}}
        $thrown=$false;try{Invoke-GlobalSearch}catch{$thrown=($_.Exception.Message -match 'Contrat de recherche globale')}
        Expect ($thrown -and $script:Tasks -eq 0 -and $script:StreamStarts -eq 0)
    }finally{${function:Get-DomeniaSearchScope}=$real}
}
Case 'Persistent observation round-trip retains separate times' {$v=ConvertTo-DomeniaLiveObservation (Ping-Observation) (Previous-Observation);$copy=$v|ConvertTo-Json -Depth 5|ConvertFrom-Json;Expect ($copy.UserCheckedUtc -eq $v.UserCheckedUtc -and $copy.PresenceCheckedUtc -eq $v.PresenceCheckedUtc)}

if($env:OS -eq 'Windows_NT' -and -not $SkipWpf){
    Case 'WPF global ancestor hides OU filters, keeps the filter of the list and the result grid (CO-05, FO-05)' {
        Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
        $reader=[Xml.XmlNodeReader]::new([xml](Get-MainXaml));$window=$null
        try{
            $window=[Windows.Markup.XamlReader]::Load($reader);$window.ShowActivated=$false;$window.ShowInTaskbar=$false;$window.Show()
            $window.FindName('WorkspaceTabs').SelectedItem=$window.FindName('WsSearch');$layout=$window.FindName('SearchBrowserLayout')
            $layout.Tag='Global';$window.UpdateLayout()
            # FO-05: hidden, not greyed: in a global search they say nothing about the list.
            foreach($name in @('CmbGlobalType','CmbPresenceFilter')){Expect (-not $window.FindName($name).IsVisible) ('Global filter still shown: '+$name)}
            Expect ($window.FindName('TxtSuiteResultFilter').IsEnabled) 'The filter of the list is greyed in global search'
            # L03 (DS-07): the OU is shown again by a click in the tree ('Afficher cette OU' is gone).
            Expect ($window.FindName('DgObjects').IsEnabled -and $window.FindName('TvDirectory').IsEnabled)
            $layout.Tag='OU';$window.UpdateLayout()
            foreach($name in @('CmbGlobalType','CmbPresenceFilter','TxtSuiteResultFilter')){Expect ($window.FindName($name).IsEnabled -and $window.FindName($name).IsVisible) ('OU filter still hidden or disabled: '+$name)}
            $presence=@($window.FindName('DgObjects').Columns|Where-Object{$_.SortMemberPath -eq 'Presence'})
            Expect ($presence.Count -eq 1 -and $presence[0].Header -eq 'Présence réseau' -and $window.FindName('DgObjects').Columns.Count -eq 18)
        }finally{$reader.Close();if($null -ne $window){$window.Close()}}
    }
    # DS-03: unwired if a filter shows a bare « Tous » or « 100 » again, or if the display changes the value read by the rules.
    Case 'DS-03 Les filtres disent leur sens : Tous les types, Toute presence, lignes max' {
        Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
        $reader=[Xml.XmlNodeReader]::new([xml](Get-MainXaml));$window=$null
        try{
            $window=[Windows.Markup.XamlReader]::Load($reader);$window.ShowActivated=$false;$window.ShowInTaskbar=$false;$window.Show()
            $window.FindName('WorkspaceTabs').SelectedItem=$window.FindName('WsSearch');$window.UpdateLayout()
            foreach($pair in @(@('CmbGlobalType','Tous les types'),@('CmbPresenceFilter','Toute présence'))){
                $combo=$window.FindName($pair[0]);$first=$combo.Items[0]
                Expect ([string]$first.Content -ceq 'Tous') ($pair[0]+' : la valeur lue par les regles a change')
                Expect ([string][Windows.Automation.AutomationProperties]::GetName($first) -ceq $pair[1]) ($pair[0]+' : nom accessible')
                $combo.SelectedIndex=0;$window.UpdateLayout()
                $shown=[Windows.Controls.TextBlock]$combo.SelectionBoxItemTemplate.LoadContent()
                Expect ($shown.Text -ceq $pair[1]) ($pair[0]+' affiche '+$shown.Text)
                $field=$combo.Parent;Expect (@($field.Children|Where-Object{$_ -is [Windows.Controls.TextBlock]}).Count -eq 0) ($pair[0]+' : intitule superflu')
            }
            $unit=$window.FindName('LblGlobalLimitUnit')
            Expect (($unit.Text -ceq 'lignes max') -and ($unit.IsVisible) -and ([Windows.Controls.DockPanel]::GetDock($unit) -eq 'Right')) 'Unite de la limite absente'
            Expect ([string][Windows.Automation.AutomationProperties]::GetName($window.FindName('TxtGlobalLimit')) -ceq 'Lignes max') 'Nom accessible de la limite'
            Expect (-not ([string](Get-MainXaml)).Contains('Saisissez ou consultez cette information')) 'Aide generique restante dans la page Rechercher'
        }finally{$reader.Close();if($null -ne $window){$window.Close()}}
    }
    Case 'CO-03 DgObjects : la grille recoit des cles de tri, pas seulement du texte affiche' {
        Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
        Set-DomeniaSearchMode 'OU';$script:Ctrl.TxtSuiteResultFilter.Text=''
        $rows=@(
            [pscustomobject]@{Type='Machine';Name='a';DN='CN=a';Presence='Inconnu';Changed='09/05/2026 08:00:00';LastLogon='Jamais'},
            [pscustomobject]@{Type='Machine';Name='b';DN='CN=b';Presence='Inconnu';Changed='10/01/2026 08:00:00';LastLogon='01/02/2026 08:00:00'},
            [pscustomobject]@{Type='Machine';Name='c';DN='CN=c';Presence='Inconnu';Changed='03/06/2025 08:00:00';LastLogon='03/03/2026 08:00:00'}
        )
        $grid=[Windows.Controls.DataGrid]::new();$grid.IsReadOnly=$true;$grid.CanUserAddRows=$false
        $script:Ctrl.DgObjects=$grid
        $affecte=Set-DomeniaItemsSource -Name 'DgObjects' -Rows $rows
        Expect ([bool]$affecte) ('Le coeur a refuse d afficher les lignes de DgObjects')
        $avecCle=@($grid.ItemsSource|Where-Object{$null -ne $_.PSObject.Properties['ChangedSort']}).Count
        Expect ($avecCle -eq 3) ('Cle de tri absente : '+$avecCle+' ligne(s) sur 3 portent ChangedSort')
        $parValeur=@($grid.ItemsSource|Sort-Object ChangedSort|ForEach-Object{[string]$_.Name}) -join ''
        Expect ($parValeur -eq 'cba') ('Tri Modifie par valeur : ordre '+$parValeur)
        $parTexte=@($grid.ItemsSource|Sort-Object Changed|ForEach-Object{[string]$_.Name}) -join ''
        Expect ($parTexte -eq 'cab') ('Le tri par texte affiche ne devrait plus etre faux : ordre '+$parTexte)
        $connexion=@($grid.ItemsSource|Sort-Object LastLogonSort|ForEach-Object{[string]$_.Name}) -join ''
        Expect ($connexion -eq 'abc') ('Tri Derniere connexion par valeur, Jamais en premier : ordre '+$connexion)
        $a=@($grid.ItemsSource|Where-Object{[string]$_.Name -eq 'a'})[0]
        # CO-03b : la ligne porte aussi ce que l'operateur voit, sans perdre la date complete.
        Expect ($a.ChangedShort -eq '09/05/2026') ('Modifie raccourci : '+[string]$a.ChangedShort)
        Expect ($a.Changed -eq '09/05/2026 08:00:00') ('Date complete perdue de la ligne : '+[string]$a.Changed)
        Expect ($a.LastLogonShort -eq 'Jamais') ('Derniere connexion raccourcie : '+[string]$a.LastLogonShort)
        Expect ($a.ChangedSort -eq [datetime]::new(2026,5,9,8,0,0)) 'La cle Modifie ne convertit pas l heure affichee'
        Expect ($a.LastLogonSort -eq [datetime]::MinValue) 'Jamais ne tombe pas au plus ancien'
    }
    Case 'Actual live filter ignores local controls in Global but applies them in OU' {
        Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
        $rows=[Collections.ObjectModel.ObservableCollection[object]]::new()
        foreach($d in @(@{Type='Utilisateur';Name='Alex';DN='CN=Alex';Presence='Sans objet';SessionDisplay='';SessionState='';Login='alex';UPN='alex@example.invalid';Association=''},@{Type='Machine';Name='PC-ONLY';DN='CN=PC';Presence='Sans réponse au ping (cache)';SessionDisplay='';SessionState='';Login='pc';UPN='pc.example.invalid';Association=''})){[void]$rows.Add([pscustomobject]$d)}
        # Fixture as the real DgObjects (IsReadOnly): a default DataGrid adds a NewItemPlaceholder to Items.Count.
        $grid=[Windows.Controls.DataGrid]::new();$grid.IsReadOnly=$true;$grid.CanUserAddRows=$false;$grid.ItemsSource=$rows;$script:Ctrl.DgObjects=$grid
        $state=[pscustomobject]@{Generation=9;BaseDn=$script:Conn.BaseDn;Scope='Subtree';TypeFilter=(Get-TypeLdapFilter 'Tous');Search='alex';SearchMode='Global';Limit=100}
        $script:Live=[pscustomobject]@{Identity='r';LastFilter=[datetime]::MinValue;Search=[pscustomobject]@{Identity='r';Stopped=$false;State=$state;Rows=$rows;View=[Windows.Data.CollectionViewSource]::GetDefaultView($rows);LdapDone=$true;Finalized=$true;RefreshNeeded=$false;FilterPending=$false;Fresh=@{};Map=@{}}}
        Set-DomeniaSearchMode Global;Update-DomeniaLiveFilter
        Expect (-not $script:Live.Search.FilterPending) 'The applied filter remained pending.'
        $names=@($grid.Items|Where-Object{$_ -ne [Windows.Data.CollectionView]::NewItemPlaceholder}|ForEach-Object{[string]$_.Name})
        Expect ($names -contains 'Alex' -and $names -contains 'PC-ONLY' -and $names.Count -eq 2) 'A global user was hidden by a local filter.'
        $state.SearchMode='OU';$state.BaseDn=$script:SelectedBranchDn;$state.Scope='OneLevel';$state.Search='';$state.TypeFilter=Get-TypeLdapFilter 'Machines';Set-DomeniaSearchMode OU
        Update-DomeniaLiveFilter
        $names=@($grid.Items|Where-Object{$_ -ne [Windows.Data.CollectionView]::NewItemPlaceholder}|ForEach-Object{[string]$_.Name})
        Expect ($names.Count -eq 1 -and $names[0] -eq 'PC-ONLY')
    }
}else{$script:Checks.Add([pscustomobject]@{Name='WPF search modes and live filter';Status='Skipped';Error='Windows WPF required.'})}
$passed=@($script:Checks|Where-Object{$_.Status -eq 'Passed'}).Count
$failed=@($script:Checks|Where-Object{$_.Status -eq 'Failed'}).Count
$skipped=@($script:Checks|Where-Object{$_.Status -eq 'Skipped'}).Count
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-search-presence-'+[guid]::NewGuid().ToString('N')+'.json')}
$report=[ordered]@{Build='2026.10.01-DOMENIA-1.0-RC1.4-SEARCH';HostVersion=$PSVersionTable.PSVersion.ToString();OS=[Environment]::OSVersion.VersionString;Passed=$passed;Failed=$failed;Skipped=$skipped;Complete=($failed -eq 0 -and $skipped -eq 0);LiveAD=$false;LiveCIM=$false;LivePing=$false;Tests=$script:Checks.ToArray()}
[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){Write-Host ("$passed passed ; $failed failed ; $skipped skipped. $ReportPath");$script:Checks|Where-Object{$_.Status -ne 'Passed'}|Format-Table -AutoSize}
if($failed -gt 0){exit 1};if($skipped -gt 0){exit 2};exit 0
