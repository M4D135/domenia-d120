# Loaded only by Preview-DomeniaUi -Progressive. No network, disk cache or credential.
. (Join-Path $wad 'modules\Domenia-Live.Model.ps1')
# Live.UI needs the cache rules (New-DomeniaNegativeCache) and the shared save state (Get-DomeniaPersistenceState, D028):
# both files only declare functions; with the disk cache disabled below, the Live line shows the storage as unavailable.
. (Join-Path $wad 'modules\Domenia-Cache.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Storage.UI.ps1')
. (Join-Path $wad 'modules\Domenia-Live.UI.ps1')
function Initialize-DomeniaWinSqliteNative {throw 'Cache disque désactivé dans cet aperçu.'}
function Start-DomeniaLiveBackgroundWork { }
function Test-DomeniaAccessBusyWrite {return $false}
function Request-UiTaskStop {param($Id,[switch]$Silent,$Reason)}
function Get-CfgValue {param($Section,$Name,$Default) return $Default}
function Set-RowAssociationMetadata {param($Rows) return $Rows}
function Get-DomeniaSelectedGridRow {return (Get-DomeniaControl 'DgObjects').SelectedItem}
function Get-CurrentSelectedComputerName {return ''}
function Get-ExistingLinkForComputer {param($Computer) return $null}
function Get-DomeniaRunningComputerUserProbe {param($Computer) return $null}
function Merge-DomeniaLiveLinkMemory {param($Observation)}
function Apply-DomeniaPresenceFilter {Update-DomeniaLiveFilter}
$script:ProcessIdentity='DEMO\lecture';$script:MachineCredential=$null;$script:RemoteAdminCredential=$null
$script:AsyncEngineClosing=$false;$script:DirectoryCredentialFaulted=$false;$script:ActiveWriteTaskId=''
$script:CurrentPresenceFilter='Tous';$script:GlobalSearchGeneration=0;$script:ProgressFeeder=$null
$demoRows=[Collections.Generic.List[object]]::new()
foreach($n in 1..40){
    $name='PC-DEMO-'+$n.ToString('00');$site=if($n -le 28){'Marseille'}else{'Lyon'}
    [void]$demoRows.Add([pscustomobject]@{Type='Machine';Name=$name;Login=$name;UPN=($name.ToLowerInvariant()+'.example.invalid');DN=('CN='+$name+',OU='+$site+',DC=example,DC=invalid');Guid=('00000000-0000-0000-0000-'+$n.ToString('000000000000'));Description='Machine fictive : aucun poste contacté.'})
}
foreach($row in $script:PreviewRows){if($row.Type -ne 'Machine'){[void]$demoRows.Add($row)}}
$script:PreviewRows=$demoRows.ToArray()
function Start-DomeniaProgressDemo {
    param($Rows)
    if($null -ne $script:ProgressFeeder){$script:ProgressFeeder.Stop()}
    $script:GlobalSearchGeneration++
    $scope=Get-DomeniaSearchScope
    $state=[pscustomobject]@{SearchMode=(Get-DomeniaSearchMode);BaseDn=$scope.BaseDn;Scope=$scope.Scope;TypeFilter=Get-GlobalSelectedTypeFilter;Search=(Get-DomeniaSearchText);Limit=100;Generation=$script:GlobalSearchGeneration;PreserveSelectionDn=''}
    $payload=[pscustomobject]@{};[void](Begin-DomeniaLiveSearch $state $payload)
    $queue=[Collections.Generic.Queue[object]]::new();foreach($row in $Rows){$queue.Enqueue($row)}
    $script:ProgressDemo=[pscustomobject]@{State=$state;Payload=$payload;Rows=$queue;Finished=$false;Number=0;FailureAlternate=$false}
    $timer=[Windows.Threading.DispatcherTimer]::new([Windows.Threading.DispatcherPriority]::Background)
    $timer.Interval=[TimeSpan]::FromMilliseconds(240)
    $timer.Add_Tick({
        $demo=$script:ProgressDemo
        if($null -eq $demo -or -not (Test-DomeniaLiveSearchActive)){return}
        for($i=0;$i -lt 4 -and $demo.Rows.Count -gt 0;$i++){
            $demo.Payload.Progress.Enqueue([pscustomobject]@{Kind='Row';Row=$demo.Rows.Dequeue();ObservedUtc=[datetime]::UtcNow.ToString('o')})
        }
        if($demo.Rows.Count -eq 0 -and -not $demo.Finished){
            Complete-DomeniaLiveSearch ([pscustomobject]@{Rows=@();BaseDn=$demo.State.BaseDn;Scope=$demo.State.Scope;Partial=$false;LimitReached=$false}) $demo.State
            $demo.Finished=$true
        }
        if($null -ne $script:Live.ProbeSelection){
            for($i=0;$i -lt 2 -and $script:Live.Pending.Count -gt 0;$i++){
                $item=$script:Live.Pending.Dequeue()
                if(-not $script:Live.PendingKeys.ContainsKey([string]$item.Key)){continue}
                if(-not (Test-DomeniaLiveProbeIntent $item.Row)){continue}
                $script:Live.ProbeSelection.Requested=$true
                [void]$script:Live.PendingKeys.Remove([string]$item.Key)
                $demo.Number++
                $outcome=if(($demo.Number%7) -eq 0){'Denied'}elseif(($demo.Number%5) -eq 0){'NoConsole'}else{'Observed'}
                $outcome=if(-not $script:Live.AutoDetect -and -not $script:Live.ProbeSelection.Manual){'PresenceOnly'}else{$outcome}
                $response=[pscustomobject]@{PresenceCheckedUtc=[datetime]::UtcNow.ToString('o');PresenceDetail='Ping fictif, aucun accès réseau.';Key=$item.Key;Computer=$item.Computer;Guid=$item.Guid;Outcome=$outcome;User=$(if($outcome -eq 'Observed'){'DEMO\utilisateur-'+$demo.Number}else{''});Source='Simulation locale';Presence='En ligne';Detail='DONNÉE FICTIVE. Aucun accès distant, LDAP ou CIM.'}
                Complete-DomeniaLiveProbe $response $item
            }
        }
    })
    $script:ProgressFeeder=$timer;$timer.Start()
}
(Get-DomeniaControl 'BtnLiveRecheck').IsEnabled=$true
$script:Window.Add_Closed({if($null -ne $script:ProgressFeeder){$script:ProgressFeeder.Stop()}})
