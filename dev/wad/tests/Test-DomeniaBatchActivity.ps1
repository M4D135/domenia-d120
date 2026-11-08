#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath='')
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Minor -ne 1 -or -not [Environment]::Is64BitProcess -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Windows PowerShell 5.1 x64 STA requis.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$wad=Split-Path -Parent $PSScriptRoot
. (Join-Path $wad 'Domenia-Modules.ps1')
Add-Type -Path (Join-Path $wad 'modules\Domenia-Live.Types.cs')
function Write-DomeniaSwallowed {param($Category,$Operation,$ErrorRecord,$Now)}
function Get-DomeniaControl {param($Name)return $script:Ctrl[$Name]}
function Set-DomeniaControlText {param($Name,$Text)$c=Get-DomeniaControl $Name;if($null -ne $c){$c.Text=$Text};return $true}
function Get-DomeniaOperationsHealthText {return 'fixture'}
function Sync-DomeniaOperationsRecent {}
function Send-DomeniaUxLiveChange {param($Control)}
function Stop-DomeniaOnlinePark {param($RunId)$script:Stopped=$RunId}
function Stop-DomeniaOuRefresh {param($OperationId)$script:Stopped=$OperationId}
function Assert {param($Value,$Why)if(-not $Value){throw $Why}}
$checks=[Collections.Generic.List[object]]::new()
function Case {param($Name,[scriptblock]$Body)try{& $Body|Out-Null;$checks.Add([pscustomobject]@{Name=$Name;Passed=$true})}catch{$checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Detail=($_.Exception.Message+' '+$_.ScriptStackTrace)})}}
function New-Run {param($Id='run-1')return [pscustomobject]@{Id=$Id;Epoch=1L;Path='fixture.db';AccountGeneration=1L;Completed=$false;Stopping=$false;Loading=$false;Approved=$true;PingOnly=$false;WmiOnly=$true;RefreshOperationId='';ScopeLabel='OU exemple';Targets=@(1,2,3,4,5);Done=2;Failed=1;Errors=0;Pending=@{};StorePending=@{};StatusText='En attente du moteur'}}
$script:SessionEpoch=1L;$script:DatabaseScopedPath='fixture.db';$script:DomeniaAccountGeneration=1L;$script:DomeniaOuRefresh=$null
$script:ParkRuns=@{List=(New-Run)};$script:AsyncJobs=[ordered]@{};$script:DetachedReadJobs=@();$script:ReceiptPending=0;$script:WriteState='Idle'
$script:Ctrl=@{BtnSuiteActivity=[Windows.Controls.Button]::new();LblSuiteActivityCount=[Windows.Controls.TextBlock]::new();BadgeSuiteActivity=[Windows.Controls.Border]::new();LblSuiteBatchProgress=[Windows.Controls.TextBlock]::new();LblSuiteActivityState=[Windows.Controls.TextBlock]::new()}
$script:ExperienceInitialized=$true;$script:OperationsPanel=$null
Case 'Le lot reste visible entre deux postes même sans aucun worker actif' {
 Update-DomeniaExperienceActivity
 Assert ($script:Ctrl.LblSuiteBatchProgress.Text -eq 'WMI · 2/5' -and $script:Ctrl.LblSuiteBatchProgress.Visibility -eq 'Visible') 'Progression absente'
 Assert ($script:Ctrl.BadgeSuiteActivity.Visibility -eq 'Visible' -and $script:Ctrl.LblSuiteActivityCount.Text -eq '1') 'Lot absent du compteur'
 Assert ($script:Ctrl.BtnSuiteActivity.ToolTip -match '1 lecture.s. non confirmée' -and $script:Ctrl.BtnSuiteActivity.ToolTip -match 'OU exemple') 'Erreurs ou périmètre absents'
}
Case 'Le lot précède les workers ; progression et identité des lignes conservées jusquʼau dernier enregistrement' {
 $parent=[Windows.Controls.Grid]::new();$view=[Windows.Controls.Grid]::new();[void]$parent.Children.Add($view)
 $script:OperationsPanel=[pscustomobject]@{Open=$true;View=$view;Rows=[Collections.ObjectModel.ObservableCollection[object]]::new();Map=@{};Signature='';Typed=$true}
 # A worker row was already visible before the batch started.
 Sync-DomeniaOperationRows @([pscustomobject]@{Id='worker';Name='PC-3';State='En cours';CanCancel=$false})
 $worker=$script:OperationsPanel.Rows[0]
 $script:AsyncJobs['worker']=[pscustomobject]@{Id='worker';Name='PC-3';OperationId='LiveConsole';State='Running';Started=(Get-Date);IsWrite=$false;SessionEpoch=1L;NonCancellable=$false;CancelRequested=$false}
 Update-DomeniaExperienceActivity
 $batch=$script:OperationsPanel.Rows[0]
 Assert ($batch.Id -eq 'batch:run-1' -and [object]::ReferenceEquals($worker,$script:OperationsPanel.Rows[1])) 'Lot non placé avant les workers ou worker recréé'
 $script:AsyncJobs.Clear();$script:ParkRuns.List.Done=5;$script:ParkRuns.List.StorePending['save']=$true
 Update-DomeniaExperienceActivity
 Assert ([object]::ReferenceEquals($batch,$script:OperationsPanel.Rows[0]) -and $batch.State -eq 'Enregistrement' -and $batch.Detail -match '5/5 postes traités') 'Progression ou enregistrement perdus'
 $script:ParkRuns.List.StorePending.Clear();$script:ParkRuns.List.Completed=$true;Update-DomeniaExperienceActivity
 Assert ($script:OperationsPanel.Rows.Count -eq 0 -and $script:Ctrl.LblSuiteBatchProgress.Visibility -eq 'Collapsed') 'Lot terminé encore actif'
}
Case 'Un lot OU apparaît pendant sa préparation puis une seule fois avec son relevé' {
 $script:DomeniaOuRefresh=[pscustomobject]@{Id='refresh-1';Epoch=1L;Path='fixture.db';Completed=$false;Cancelled=$false;Mode='Wmi';Label='OU exemple';Phase='Resolving';Status='Préparation des postes'}
 $script:ParkRuns=@{};Update-DomeniaExperienceActivity
 Assert ($script:OperationsPanel.Rows.Count -eq 1 -and $script:OperationsPanel.Rows[0].Id -eq 'refresh:refresh-1') 'Préparation absente'
 $run=New-Run;$run.RefreshOperationId='refresh-1';$script:ParkRuns.List=$run;Update-DomeniaExperienceActivity
 Assert ($script:OperationsPanel.Rows.Count -eq 1 -and $script:OperationsPanel.Rows[0].Id -eq 'batch:run-1') 'Lot compté deux fois'
 $script:Stopped='';Stop-DomeniaOperationRow 'batch:run-1';Assert ($script:Stopped -eq 'refresh-1') 'Arrêt non routé vers le lot OU'
}
Case 'Les lots obsolètes sont exclus et ne peuvent plus être arrêtés depuis une ancienne ligne' {
 $script:DomeniaOuRefresh=$null;$run=New-Run;$run.Epoch=0;$script:ParkRuns.List=$run;$script:Stopped=''
 Update-DomeniaExperienceActivity;Stop-DomeniaOperationRow 'batch:run-1'
 Assert ($script:OperationsPanel.Rows.Count -eq 0 -and $script:Stopped -eq '') 'Lot obsolète affiché ou arrêté'
 $run.Epoch=1;$run.AccountGeneration=2;Update-DomeniaExperienceActivity
 Assert ($script:OperationsPanel.Rows.Count -eq 0) 'Ancien compte affiché'
}
Case 'Deux lots simultanés ont un résumé et un arrêt indépendant' {
 $a=New-Run 'a';$b=New-Run 'b';$b.PingOnly=$true;$b.WmiOnly=$false;$script:ParkRuns=@{List=$a;Computer=$b}
 Update-DomeniaExperienceActivity
 Assert ($script:Ctrl.LblSuiteActivityCount.Text -eq '2' -and $script:Ctrl.LblSuiteBatchProgress.Text -match '\+1 lot' -and $script:OperationsPanel.Rows.Count -eq 2) 'Second lot invisible'
 $script:Stopped='';Stop-DomeniaOperationRow 'batch:b';Assert ($script:Stopped -eq 'b') 'Mauvais lot arrêté'
}
$failed=@($checks|Where-Object{-not $_.Passed}).Count
$report=[ordered]@{NativeWindowsPowerShell51=$true;LiveAD=$false;Passed=$checks.Count-$failed;Failed=$failed;Tests=$checks.ToArray()}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
$report|ConvertTo-Json -Depth 8
if($failed){exit 1};exit 0
