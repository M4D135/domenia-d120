#requires -Version 5.1
# Wiring of the collection lot (roadmap points 11, 12, 15, 16, 17, 20, 21, 159 and 160) in the real modules: engine
# admission, dispatch clock and outcomes, background gate of the collection window, settings of the usage profile in
# the workshop view, durable campaign offer, and the core call sites read from the real Domenia-Core.ps1. No domain,
# no network, no disk: settings and preference files live in memory; the dispatch case runs an inert local runspace.
# Windows PowerShell 5.1 x64 STA only.
[CmdletBinding()]param([string]$ReportPath='',[switch]$Quiet)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Minor -ne 1 -or -not [Environment]::Is64BitProcess -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Windows PowerShell 5.1 x64 STA requis.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$wad=Split-Path -Parent $PSScriptRoot
. (Join-Path $wad 'Domenia-Modules.ps1')
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$t,[ref]$e)
if(@($e).Count){throw ('Syntaxe du coeur : '+$e[0].Message)}
function Get-CoreFunctionText {param([string]$Name)$node=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))[0];if($null -eq $node){throw ('Fonction du coeur absente : '+$Name)};return $node.Extent.Text}
foreach($name in @('Get-DomeniaControl','Set-DomeniaControlText')){. ([scriptblock]::Create((Get-CoreFunctionText $name)))}
function Assert {param($Value,[string]$Why='Assertion fausse')if(-not $Value){throw $Why}}
$checks=[Collections.Generic.List[object]]::new()
function Case {param($Name,[scriptblock]$Body)try{Reset-Fixture;& $Body|Out-Null;$status='Passed';$detail=''}catch{$status='Failed';$detail=$_.Exception.Message+' '+$_.ScriptStackTrace};$checks.Add([pscustomobject]@{Name=$Name;Status=$status;Detail=$detail});if($status -eq 'Failed' -and -not $Quiet){Write-Host ($Name+': '+$detail)}}

# ---------------------------------------------------------------- doubles of the core (settings, preferences, log)
function Get-DomeniaSetting {param($Name,$Default)if($script:SettingValues.ContainsKey([string]$Name)){return $script:SettingValues[[string]$Name]};return $Default}
function Set-DomeniaSetting {param($Name,$Value)$script:SettingValues[[string]$Name]=$Value}
function Write-DomeniaPreference {param([string]$FileName,[string]$Value)$script:Prefs[$FileName]=$Value;return $true}
function Read-DomeniaPreference {param([string]$FileName)if($script:Prefs.ContainsKey($FileName)){return [string]$script:Prefs[$FileName]};return ''}
function Get-CfgValue {param($Section,$Key,$Default)return $Default}
function Set-Status {param($Text,$Level)$script:Status=[string]$Text}
function Write-AppLog {param($Text,$Level)}
function Write-DomeniaAppLogFile {param($Text,$Level,$Source)}
function Protect-DomeniaLogText {param($Text)return [string]$Text}
function Set-ControlsBusy {param($Names,$Busy)}
function Reset-Fixture {
 $script:SettingValues=@{};$script:Prefs=@{};$script:Status='';$script:Ctrl=@{}
 $script:DomeniaFreshnessCache=$null;$script:DomeniaCollectionWindowCache=$null;$script:DomeniaCollectionSettingsWired=$false
 $script:DomeniaIdlePolicy=$null;$script:DomeniaSchedulerEnabled=$true;$script:AsyncEngineClosing=$false;$script:SessionEpoch=5L;$script:DemoMode=$false
 $script:DomeniaProviderState=@{};$script:DomeniaAgedPromotions=0;$script:AsyncJobs=[ordered]@{};$script:DetachedReadJobs=@();$script:LatestTaskId=''
 $script:DatabaseScopedPath='C:\fixture\domain.db';$script:Conn=[pscustomobject]@{Domain='example.test';BaseDn='DC=example,DC=test';Server='dc01.example.test'}
 $script:ParkRuns=$null;$script:DomeniaCampaignResumeOfferKey='';$script:DomeniaTargetAddresses=$null;$script:DomeniaParkRunningShown=$false
}

Case 'Point 159 : le fond réseau attend la fenêtre du profil ; la sélection et le tableau de bord non' {
 $script:SettingValues['Collection.WindowsJson']='{"Standard":"jamais"}'
 Assert (-not (Test-DomeniaBackgroundWorkAllowed -Source 'Reconcile')) 'Réconciliation hors fenêtre'
 Assert (-not (Test-DomeniaBackgroundWorkAllowed -Source 'ObjectChanges')) 'Revérification hors fenêtre'
 Assert (Test-DomeniaBackgroundWorkAllowed -Source 'Live') 'Sélection bloquée'
 Assert (Test-DomeniaBackgroundWorkAllowed -Source 'Dashboard') 'Tableau de bord bloqué'
 $script:SettingValues.Remove('Collection.WindowsJson');$script:DomeniaCollectionWindowCache=$null
 Assert (Test-DomeniaBackgroundWorkAllowed -Source 'Reconcile') 'Profil Standard : à tout moment'
 $script:SettingValues['Collection.Profile']='SlowNetwork'
 $expected=[bool](Test-DomeniaCollectionWindowOpen (ConvertFrom-DomeniaCollectionWindowText ([string](Get-DomeniaCollectionProfile 'SlowNetwork').Windows)) (Get-Date)).Open
 Assert ((Test-DomeniaBackgroundWorkAllowed -Source 'Reconcile') -eq $expected) 'Fenêtre par défaut du profil non appliquée'
}
Case 'Point 11 et 159 : durées et fenêtre enregistrées par profil, valeurs invalides refusées' {
 $script:SettingValues['Collection.Profile']='SlowNetwork'
 Set-DomeniaFreshnessOverride -Family 'Inventory' -Seconds 600
 Assert ((Get-DomeniaActiveFreshnessTable).Seconds['Inventory'] -eq 600)
 Assert ([string]$script:SettingValues['Collection.FreshnessJson'] -match '"SlowNetwork"')
 $script:SettingValues['Collection.Profile']='Standard'
 Assert ((Get-DomeniaActiveFreshnessTable).Seconds['Inventory'] -eq 300) 'Durée dʼun autre profil appliquée'
 $failed=$false;try{Set-DomeniaFreshnessOverride -Family 'Presence' -Seconds 700000}catch{$failed=$true};Assert $failed 'Durée hors bornes acceptée'
 $failed=$false;try{Set-DomeniaFreshnessOverride -Family 'Identity' -Seconds 600}catch{$failed=$true};Assert $failed 'Famille sans lecteur acceptée'
 Assert ((Get-DomeniaCollectionWindowText) -eq '')
 $failed=$false;try{Set-DomeniaCollectionWindowText 'lun 25:00-26:00'}catch{$failed=$true};Assert $failed 'Fenêtre invalide acceptée'
 $script:SettingValues['Collection.Profile']='SlowNetwork'
 Assert ((Get-DomeniaCollectionWindowText) -match 'sam-dim') 'Fenêtre par défaut du profil absente'
 Set-DomeniaCollectionWindowText ''
 Assert ((Get-DomeniaCollectionWindowText) -eq '') 'Champ vidé : à tout moment'
 Assert ([string]$script:SettingValues['Collection.WindowsJson'] -match 'toujours')
 Assert ((Get-DomeniaActiveFreshnessTable).Seconds['Inventory'] -eq 600) 'Durée personnalisée du profil perdue'
}
Case 'Point 11 : chaque famille proposée a un lecteur qui applique la durée du profil' {
 # Presence: presence cache of the core and live grid; Console: live grid and selected workstation; Attributes: object
 # card and selection panel; Inventory and probes: collection plan of the campaigns.
 $core=Get-CoreFunctionText 'Get-DomeniaCachedPresenceState'
 Assert ($core.Contains("Get-DomeniaFreshness -Nature 'Presence'") -and $core.Contains('-Table $table')) 'Cache de présence sans durée du profil'
 Assert ((Get-CoreFunctionText 'Show-AdObjectResult').Contains("'Attributes' -Table `$freshnessTable")) 'Fiche objet sans durée du profil'
 $live=[IO.File]::ReadAllText((Join-Path $wad 'modules\Domenia-Live.UI.ps1'))
 foreach($nature in @('Console','Presence')){Assert ($live.Contains("Get-DomeniaRecordFreshness `$Observation '"+$nature+"' -Table `$freshnessTable")) ('Liste sans durée du profil : '+$nature)}
 Assert ($live.Contains("Get-DomeniaRecordFreshness `$observation 'Console' -Table `$freshnessTable")) 'Poste sélectionné sans durée du profil'
 $selection=[IO.File]::ReadAllText((Join-Path $wad 'modules\Domenia-Selection.UI.ps1'))
 Assert ($selection.Contains("Get-DomeniaRecordFreshness `$record 'Attributes' -Table `$freshnessTable")) 'Panneau de sélection sans durée du profil'
 $park=[IO.File]::ReadAllText((Join-Path $wad 'modules\Domenia-Park.UI.ps1'))
 Assert ($park.Contains('-Freshness $r.Freshness')) 'Plan de collecte sans durée du profil'
 $script:SettingValues['Collection.Profile']='Troubleshooting'
 $observation=[pscustomobject]@{Times=@{Presence=[pscustomobject]@{ObservedUtc=[datetime]::UtcNow.AddSeconds(-60).ToString('o');LastAttemptUtc=$null}}}
 Assert ([string](Get-DomeniaRecordFreshness $observation 'Presence' -Table (Get-DomeniaActiveFreshnessTable)).State -eq 'Stale') 'Profil Dépannage : ping de 60 s encore récent'
 $script:SettingValues['Collection.Profile']='Standard'
 Assert ([string](Get-DomeniaRecordFreshness $observation 'Presence' -Table (Get-DomeniaActiveFreshnessTable)).State -eq 'Fresh') 'Profil Standard : ping de 60 s déjà à relire'
}
Case 'Point 11 : la vue des réglages de collecte affiche, modifie et rétablit les durées du profil' {
 foreach($name in @('CmbCollectionProfile','CmbCollectionFreshnessValue')){$script:Ctrl[$name]=[Windows.Controls.ComboBox]::new()}
 $script:Ctrl['DgCollectionFreshness']=[Windows.Controls.DataGrid]::new()
 foreach($name in @('BtnCollectionFreshnessReset','BtnCollectionWindowApply','BtnCollectionResume','BtnCollectionResumeDiscard')){$script:Ctrl[$name]=[Windows.Controls.Button]::new()}
 $script:Ctrl['TxtCollectionWindow']=[Windows.Controls.TextBox]::new()
 foreach($name in @('LblCollectionWindow','LblCollectionProfile','LblCollectionResume')){$script:Ctrl[$name]=[Windows.Controls.TextBlock]::new()}
 Initialize-DomeniaCollectionSettingsUi
 Assert (@($script:Ctrl.DgCollectionFreshness.ItemsSource).Count -eq 6) 'Familles absentes'
 $script:Ctrl.CmbCollectionProfile.SelectedIndex=1
 Assert ($script:SettingValues['Collection.Profile'] -eq 'SlowNetwork' -and $script:Ctrl.TxtCollectionWindow.Text -match 'sam-dim') 'Profil non appliqué'
 $script:Ctrl.DgCollectionFreshness.SelectedItem=@($script:Ctrl.DgCollectionFreshness.ItemsSource|Where-Object{$_.Family -eq 'Inventory'})[0]
 Assert ($script:Ctrl.CmbCollectionFreshnessValue.IsEnabled -and @($script:Ctrl.CmbCollectionFreshnessValue.ItemsSource).Count -ge 5) 'Éditeur de durée non rempli'
 $script:Ctrl.CmbCollectionFreshnessValue.SelectedItem=@($script:Ctrl.CmbCollectionFreshnessValue.ItemsSource|Where-Object{$_.Seconds -eq 60})[0]
 Assert ((Get-DomeniaActiveFreshnessTable).Seconds['Inventory'] -eq 60) 'Durée choisie non enregistrée'
 $script:Ctrl.BtnCollectionFreshnessReset.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
 Assert ((Get-DomeniaActiveFreshnessTable).Seconds['Inventory'] -eq 3600) 'Durées du profil non rétablies'
 $script:Ctrl.TxtCollectionWindow.Text='lun 25:00-26:00'
 $script:Ctrl.BtnCollectionWindowApply.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
 Assert ($script:Ctrl.LblCollectionWindow.Text -match 'non enregistrée' -and -not $script:SettingValues.ContainsKey('Collection.WindowsJson')) 'Fenêtre invalide enregistrée'
 Assert (-not $script:Ctrl.BtnCollectionResume.IsEnabled) 'Reprise proposée sans plan'
}
Case 'Points 15 et 16 : charge par source et travaux de fond comptés par le moteur' {
 $script:AsyncJobs['a']=[pscustomobject]@{State='Running';CancelRequested=$false;Class='Background';Provider='Cim';ProviderTarget='PC1';ProviderGroup='10.1.2.0/24'}
 $script:AsyncJobs['b']=[pscustomobject]@{State='Running';CancelRequested=$false;Class='Explicit';Provider='Cim';ProviderTarget='PC2';ProviderGroup='10.1.2.0/24'}
 $script:AsyncJobs['c']=[pscustomobject]@{State='Queued';CancelRequested=$false;Class='Background';Provider='Cim';ProviderTarget='PC3';ProviderGroup='10.1.2.0/24'}
 $load=Get-DomeniaEngineLoad
 Assert ($load.BackgroundRunning -eq 1 -and $load.QueuedCount -eq 1) 'Classes mal comptées'
 Assert ([int]$load.SourceLoad[(Get-DomeniaProviderStateKey 'Cim' 'group:10.1.2.0/24')] -eq 2 -and [int]$load.SourceLoad[(Get-DomeniaProviderStateKey 'Cim' 'PC1')] -eq 1) 'Charge par source fausse'
}
Case 'Point 16 : un travail de fond en longue attente sort de la file sur une place réservée, et cʼest compté' {
 foreach($i in 1..5){$script:AsyncJobs['e'+$i]=[pscustomobject]@{Id=('e'+$i);State='Running';CancelRequested=$false;Class='Explicit';Provider='Directory';ProviderTarget='';ProviderGroup='';SessionEpoch=5L}}
 $script:AsyncJobs['bg']=[pscustomobject]@{Id='bg';Name='Fond';State='Queued';CancelRequested=$false;Class='Background';Provider='Local';ProviderTarget='';ProviderGroup='';Sequence=1;QueuedAt=(Get-Date).AddSeconds(-60);SessionEpoch=5L;Foreground=$false;BusyApplied=$false;DisableControls=@()}
 $script:Dispatched=[Collections.Generic.List[string]]::new()
 function Invoke-DomeniaUiTaskDispatch {param($Job)$script:Dispatched.Add([string]$Job.Id);$Job.State='Running';return $Job}
 [void](Invoke-DomeniaQueuedTaskPromotion -BudgetMs 200)
 Assert ($script:Dispatched -contains 'bg') 'Travail de fond bloqué malgré son attente'
 Assert ([int]$script:DomeniaAgedPromotions -eq 1) 'Démarrage après attente non compté'
 Assert (@(Get-DomeniaCollectionHealthLines) -match 'longue attente').Count 'Panneau sans la mesure'
}
Case 'Points 15 et 160 : des délais répétés sur un site suspendent son fond, nommé dans le panneau' {
 foreach($i in 1..3){[void](Register-DomeniaTaskOutcome -Job ([pscustomobject]@{Provider='Cim';ProviderTarget=('pc'+$i);ProviderGroup='10.1.2.0/24';SchedulerManaged=$true;Demo=$false;CredentialIdentity='';OperationId='ComputerQuickDiag';Name='Diagnostic';SessionEpoch=5L}) -TimedOut)}
 $site=$script:DomeniaProviderState[(Get-DomeniaProviderStateKey 'Cim' 'group:10.1.2.0/24')]
 Assert ($null -ne $site -and [datetime]$site.BackoffUntilUtc -gt [datetime]::UtcNow) 'Site non suspendu'
 Assert (@(Get-DomeniaCollectionHealthLines|Where-Object{$_ -match 'site 10\.1\.2\.0/24'}).Count -eq 1) 'Site absent du panneau'
 Assert (-not ((@(Get-DomeniaCollectionHealthLines) -join ' ') -match '(?i)annuaire.{0,20}inaccessible')) 'Annuaire déclaré inaccessible'
}
Case 'Point 12 : une lecture identique rejointe est comptée, sans second appel' {
 $script:AsyncJobs['j']=[pscustomobject]@{Id='j';IsWrite=$false;CancelRequested=$false;DedupKey='k1';ReplaceKey='';SessionEpoch=5L;Subscribers=$null;DisableControls=@();Name='Lecture';OperationId='OpenAdObject'}
 $before=[int]$script:DomeniaSharedReadCount
 Assert ((Add-DomeniaTaskSubscriber -DedupKey 'k1' -ReplaceKey '') -eq 'j') 'Lecture non rejointe'
 Assert ((Add-DomeniaTaskSubscriber -DedupKey 'k2' -ReplaceKey '') -eq '') 'Lecture différente rejointe'
 Assert ([int]$script:DomeniaSharedReadCount -eq ($before+1)) 'Partage non compté'
}
Case 'Points 12 et 15 : Start-UiTask partage selon compte, contexte et exigences, et transmet la source du budget' {
 $text=Get-CoreFunctionText 'Start-UiTask'
 foreach($needle in @('Get-DomeniaTaskReaderIdentity','Get-DomeniaTaskRequirements','-Requirements $requirements','Get-DomeniaKnownTargetGroup','ProviderGroup=$providerGroup','AccountGeneration ([long]$script:DomeniaAccountGeneration)')){Assert ($text.Contains($needle)) ('Start-UiTask sans '+$needle)}
 Assert ((Get-DomeniaKnownTargetGroup -Provider 'Directory') -eq 'dc01.example.test') 'Contrôleur de la session absent'
 [void](Register-DomeniaTargetAddress -Computer 'PC-7' -Text 'Réponse ICMP · 3 ms · 10.4.5.6')
 Assert ((Get-DomeniaKnownTargetGroup -Provider 'Cim' -Target 'pc-7') -eq '10.4.5.0/24') 'Sous-réseau présumé absent'
 Assert ((Get-DomeniaKnownTargetGroup -Provider 'Cim' -Target 'PC-INCONNU') -eq '') 'Adresse inventée'
}
Case 'Point 21 : repère vérifié avant la synchronisation incrémentale, USN jamais au-delà de lʼinstance' {
 $refresh=Get-CoreFunctionText 'Start-DomeniaIndexRefresh'
 Assert ($refresh.Contains('Test-DomeniaSyncCheckpoint') -and $refresh.Contains('$lastUsn = [long]0; $lastInvocationId = ''''; $since = ''''')) 'Repère non vérifié avant envoi'
 . ([scriptblock]::Create((Get-CoreFunctionText 'Get-DomeniaIndexWorkerCode')))
 $code=Get-DomeniaIndexWorkerCode
 Assert ($code.Contains('($lastUsn -gt $highestUsn)') -and $code.Contains("`$checkpointRejected = 'UsnAhead'") -and $code.Contains('CheckpointRejected = $checkpointRejected')) 'Garde USN absente du worker'
 $complete=Get-CoreFunctionText 'Complete-DomeniaIndexRefreshUi'
 Assert ($complete.Contains("'CheckpointRejected'")) 'Motif du worker non journalisé'
}
Case 'Point 21 : un repère refusé est estimé et confirmé comme une relecture complète du domaine' {
 . ([scriptblock]::Create((Get-CoreFunctionText 'Start-DomeniaIndexRefresh')))
 function Test-DomeniaIndexWriteReady {return $true}
 function Get-DomeniaDatabaseObjectCount {return 200000}
 function Add-DomeniaUiLog {param($Area,$Text,$Level)$script:IndexLog.Add([string]$Text)}
 function Get-DomeniaOperationImpactEstimate {param($Operation,[int]$ItemCount)return [pscustomobject]@{Operation=$Operation;ItemCount=$ItemCount}}
 function Request-DomeniaOperationImpact {param($Estimate,$Title,$OnConfirm,$OnCancel,$Target)$script:Impact=[pscustomobject]@{Estimate=$Estimate;Title=[string]$Title}}
 function Start-UiTask {throw 'Lecture envoyée sans confirmation.'}
 $script:IndexLog=[Collections.Generic.List[string]]::new();$script:Impact=$null
 # Checkpoint taken on another controller: the pass would read the whole domain again.
 $script:IndexInfo=[pscustomobject]@{Usn=50000L;Server='dc02.example.test';Date=[datetime]::UtcNow.AddHours(-2).ToString('o');InvocationId='11111111-2222-3333-4444-555555555555';BaseDn='DC=example,DC=test';Count=199000}
 Start-DomeniaIndexRefresh
 Assert ($null -ne $script:Impact -and $script:Impact.Estimate.ItemCount -eq 200000 -and $script:Impact.Title -match '^Relecture complète du domaine : Repère pris sur dc02\.example\.test') ('Estimation : '+$script:Impact.Estimate.ItemCount+' · '+$script:Impact.Title)
 Assert ($script:IndexLog.Count -eq 0) 'Motif journalisé avant la confirmation'
 $script:IndexInfo.Server='dc01.example.test';$script:Impact=$null
 Start-DomeniaIndexRefresh
 Assert ($null -ne $script:Impact -and $script:Impact.Estimate.ItemCount -eq 10000 -and $script:Impact.Title -eq 'Mettre à jour les changements') 'Repère valide : estimation incrémentale attendue'
}
Case 'Point 17 : le moteur donne son horloge au canal de progression dʼune lecture de relevé, à son départ' {
 # The production dispatcher runs against a short-lived local runspace; only the submitted command is inert.
 function Set-DomeniaTargetCredentialContext {param($Context,$Payload)return $Context}
 function Get-WorkerContext {param($OperationId,$Payload)return [pscustomobject]@{OperationId=$OperationId;CredentialGuard=$null;DirectoryAuthKey='';RemoteAuthKey='';RemoteAdminAuthKey='';ActiveRemoteAuthKey=''}}
 function Set-DomeniaCredentialGuardContext {param($Context,$OperationId)return $Context}
 function Assert-WCredentialAllowed {param($Context,$Channel)}
 function Get-DomeniaContextCredentialIdentity {param($Context,$Provider)return 'fixture'}
 function Get-DomeniaDispatchIsolation {param($Job,$Context)return [pscustomobject]@{Isolate=$false}}
 function Register-DomeniaJobResources {param($Job)}
 function New-DomeniaWorkerRunspace {
  param($OperationId,$Code,[switch]$IsWrite)
  $initial=[Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
  $initial.Commands.Add([Management.Automation.Runspaces.SessionStateFunctionEntry]::new('Invoke-InertCampaignRead',@'
param($Context,$Payload)
$p=$Payload.ReadProgress
$root=([Collections.ICollection]$p).SyncRoot
[Threading.Monitor]::Enter($root)
try{
    if([long]$p['StartedTimestamp'] -le 1 -or [long]$p['RowsRead'] -ne 0 -or [long]$p['LastRowTimestamp'] -ne 0){throw 'Canal non remis à zéro au départ.'}
    $p['RowsRead']=2L;$p['LastRowTimestamp']=[Diagnostics.Stopwatch]::GetTimestamp()
}finally{[Threading.Monitor]::Exit($root)}
'@))
  $runspace=[Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($initial);$runspace.Open()
  return [pscustomobject]@{Runspace=$runspace;CommandName='Invoke-InertCampaignRead';CodeHash='inert-fixture'}
 }
 # Values left by the queue: the dispatch alone starts the clock and clears the steps.
 $progress=[hashtable]::Synchronized(@{StartedTimestamp=1L;LastRowTimestamp=1L;RowsRead=99L})
 $job=[pscustomobject]@{Id='campagne';Name='Console du parc : PC-1';OperationId='LiveConsole';IsWrite=$false;Payload=[pscustomobject]@{Computer='PC-1';ReadProgress=$progress};Provider='Cim';ProviderTarget='PC-1';ProviderGroup='';CredentialIdentity=''
  SchedulerManaged=$false;Code='inert';TimeoutSeconds=25;HardTimeoutSeconds=90;Class='Explicit';CancelRequested=$false;Superseded=$false;BusyApplied=$false;DisableControls=@();StatusText=''
  PowerShell=$null;Runspace=$null;Handle=$null;CodeHash='';ExecutedOperationId='';Demo=$false;Isolated=$false;State='Queued';Started=(Get-Date).AddMinutes(-5)}
 Assert (-not (Get-DomeniaReadTimeoutState -Job $job -ElapsedSeconds 300).Expired) 'Délai compté pendant lʼattente en file'
 $before=[Diagnostics.Stopwatch]::GetTimestamp()
 try{
  [void](Invoke-DomeniaUiTaskDispatch $job)
  if(-not $job.Handle.AsyncWaitHandle.WaitOne(5000)){throw 'Runspace inerte non terminé en cinq secondes.'}
  [void]$job.PowerShell.EndInvoke($job.Handle)
  Assert ($job.PowerShell.Streams.Error.Count -eq 0) 'Le canal nʼa pas été remis à zéro au départ'
  Assert ([object]::ReferenceEquals($job.ReadProgress,$progress) -and $null -eq $job.Payload) 'Canal non conservé sur le travail'
  Assert ([long]$progress['StartedTimestamp'] -ge $before -and [long]$progress['RowsRead'] -eq 2) 'Horloge de départ absente ou canal copié'
  # Started five minutes ago in the queue: the engine judges the read on its own progress, not on the 25 s rule.
  $deadline=Get-DomeniaReadTimeoutState -Job $job -ElapsedSeconds 300
  Assert ((-not $deadline.Expired) -and [long]$deadline.RowsRead -eq 2) ('Règle historique appliquée : '+$deadline.Reason)
 }finally{
  if($null -ne $job.PowerShell){$job.PowerShell.Dispose()}
  if($null -ne $job.Runspace){$job.Runspace.Dispose()}
 }
}
Case 'Point 20 : la zone de reprise suit les relevés : fermée pendant, proposée à lʼarrêt, retirée une fois terminé' {
 foreach($name in @('BtnCollectionResume','BtnCollectionResumeDiscard')){$script:Ctrl[$name]=[Windows.Controls.Button]::new()}
 $script:Ctrl['LblCollectionResume']=[Windows.Controls.TextBlock]::new()
 $targets=@(for($i=1;$i -le 2;$i++){[pscustomobject]@{Computer=('PC-'+$i);Key=('CN=PC-'+$i+',DC=example,DC=test');Guid=('00000000-0000-0000-0000-'+$i.ToString('d12'))}})
 $run=[pscustomobject]@{Id=[guid]::NewGuid().ToString('N');Targets=$targets;Path=$script:DatabaseScopedPath;PingOnly=$true;WmiOnly=$false;Inventory=$false;Probes=@();ScopeLabel='OU=Postes';Completed=$false;Stopping=$false;FailureMessage='';StopReason=''}
 $script:ParkRuns=@{List=$run};Update-DomeniaParkControls
 Assert ($script:Ctrl.LblCollectionResume.Text -match 'Relevé en cours' -and -not $script:Ctrl.BtnCollectionResume.IsEnabled) 'Reprise proposée pendant le relevé'
 Assert (Save-DomeniaCampaignPlan -Run $run) 'Plan non enregistré'
 Assert (-not $script:Ctrl.BtnCollectionResume.IsEnabled) 'Plan du relevé en cours proposé à la reprise'
 $run.Stopping=$true;$run.Completed=$true;Complete-DomeniaCampaignPlan $run
 Assert ($script:Ctrl.BtnCollectionResume.IsEnabled -and $script:Ctrl.BtnCollectionResumeDiscard.IsEnabled -and $script:Ctrl.LblCollectionResume.Text -match '2 poste') ('Reprise non proposée à lʼarrêt : '+$script:Ctrl.LblCollectionResume.Text)
 # The same plan once every workstation is validated: nothing is offered any more.
 foreach($i in 0..1){[void](Set-DomeniaCampaignTargetDone $run.CampaignProgress $i)}
 Complete-DomeniaCampaignPlan $run
 Assert (-not $script:Ctrl.BtnCollectionResume.IsEnabled -and -not $script:Ctrl.BtnCollectionResumeDiscard.IsEnabled) 'Reprise encore proposée après un relevé terminé'
}
Case 'Point 20 : la reprise est proposée une fois par session et base, jamais par-dessus une autre demande' {
 $targets=@(for($i=1;$i -le 3;$i++){[pscustomobject]@{Computer=('PC-'+$i);Key=('CN=PC-'+$i+',DC=example,DC=test');Guid=('00000000-0000-0000-0000-'+$i.ToString('d12'))}})
 $plan=New-DomeniaCampaignPlan -Kind 'Ping' -Targets $targets -DomainDn $script:Conn.BaseDn -DatabasePath $script:DatabaseScopedPath
 $progress=New-DomeniaCampaignProgress $plan;[void](Set-DomeniaCampaignTargetDone $progress 0);$progress.State='Closed'
 $script:Prefs['Domenia.campaign-plan.json']=ConvertTo-DomeniaCampaignPlanText $plan
 $script:Prefs['Domenia.campaign-progress.json']=ConvertTo-DomeniaCampaignProgressText $progress
 $script:Offers=[Collections.Generic.List[string]]::new();$script:PendingRequest=[pscustomobject]@{Id='autre'}
 function Get-DomeniaInlinePendingRequest {return $script:PendingRequest}
 function Request-DomeniaInlineConfirmation {param($Title,$Target,$Message,$ConfirmText,$CancelText,$OnConfirm,$OnCancel)$script:Offers.Add([string]$Message);$script:OfferConfirm=$OnConfirm}
 Request-DomeniaCampaignResumeOffer;Assert ($script:Offers.Count -eq 0) 'Proposée par-dessus une autre demande'
 $script:PendingRequest=$null;Request-DomeniaCampaignResumeOffer
 Assert ($script:Offers.Count -eq 1 -and $script:Offers[0] -match '2 poste' -and $script:Offers[0] -match 'fermeture') ('Offre : '+($script:Offers -join ' | '))
 Request-DomeniaCampaignResumeOffer;Assert ($script:Offers.Count -eq 1) 'Proposée deux fois'
 $script:Resumed=$null
 # The answer runs through the closure of the inline request: the double replaces the module function itself.
 function script:Start-DomeniaOnlinePark {param([object[]]$ScopeTargets,[string]$ScopeLabel,[switch]$PingOnly,[switch]$WmiOnly,[switch]$Inventory,$Probes,[string]$Slot='')$script:Resumed=[pscustomobject]@{Count=@($ScopeTargets).Count;PingOnly=[bool]$PingOnly;Slot=$Slot}}
 & $script:OfferConfirm
 Assert ($null -ne $script:Resumed -and $script:Resumed.Count -eq 2 -and $script:Resumed.PingOnly -and $script:Resumed.Slot -eq 'List') 'Reprise sans les seuls postes restants, sans son mode ou hors de la portée des listes'
}
Case 'Point 20 : le relevé du poste ouvert et la collecte dʼun widget nʼécrivent aucun plan, la reprise attend leur fin' {
 foreach($name in @('BtnCollectionResume','BtnCollectionResumeDiscard')){$script:Ctrl[$name]=[Windows.Controls.Button]::new()}
 $script:Ctrl['LblCollectionResume']=[Windows.Controls.TextBlock]::new()
 $targets=@([pscustomobject]@{Computer='PC-1';Key='CN=PC-1,DC=example,DC=test';Guid='00000000-0000-0000-0000-000000000001'})
 $computer=[pscustomobject]@{Id='c';Slot='Computer';Targets=$targets;Path=$script:DatabaseScopedPath;PingOnly=$false;WmiOnly=$false;Inventory=$true;Probes=@();ScopeLabel='PC-1';Completed=$false;Stopping=$false;FailureMessage='';StopReason=''}
 $widget=[pscustomobject]@{Id='w';Slot='List';WidgetBoard='Fleet';Targets=$targets;Path=$script:DatabaseScopedPath;PingOnly=$false;WmiOnly=$true;Inventory=$false;Probes=@();ScopeLabel='Postes';Completed=$false;Stopping=$false;FailureMessage='';StopReason=''}
 Assert (-not (Save-DomeniaCampaignPlan -Run $computer) -and -not (Save-DomeniaCampaignPlan -Run $widget) -and $script:Prefs.Count -eq 0) 'Plan écrit hors dʼune campagne de la liste'
 # An interrupted campaign waits for its resume while the widget collects; it is offered again at the end.
 $plan=New-DomeniaCampaignPlan -Kind 'Console' -Targets $targets -DomainDn $script:Conn.BaseDn -DatabasePath $script:DatabaseScopedPath
 $progress=New-DomeniaCampaignProgress $plan;$progress.State='Paused'
 $script:Prefs['Domenia.campaign-plan.json']=ConvertTo-DomeniaCampaignPlanText $plan
 $script:Prefs['Domenia.campaign-progress.json']=ConvertTo-DomeniaCampaignProgressText $progress
 $script:ParkRuns=@{List=$widget;Computer=$computer};Update-DomeniaParkControls
 Assert ($script:Ctrl.LblCollectionResume.Text -match 'widget' -and -not $script:Ctrl.BtnCollectionResume.IsEnabled) ('Pendant la collecte : '+$script:Ctrl.LblCollectionResume.Text)
 $widget.Completed=$true;Update-DomeniaParkControls
 Assert ($script:Ctrl.BtnCollectionResume.IsEnabled -and $script:Prefs['Domenia.campaign-plan.json'] -ne '{}') 'Campagne interrompue remplacée ou non proposée après la collecte du widget'
}
Case 'Opérations : la santé du moteur inclut les mesures de la collecte' {
 $script:DomeniaSharedReadCount=3;$script:DomeniaCimQueriesAvoided=5;$script:DomeniaCimQueriesExecuted=4
 $lines=@(Get-DomeniaCollectionHealthLines)
 Assert (@($lines|Where-Object{$_ -match 'Lectures identiques partagées : 3'}).Count -eq 1)
 Assert (@($lines|Where-Object{$_ -match 'Requêtes WMI évitées par regroupement : 5 sur 9'}).Count -eq 1)
 Assert (@($lines|Where-Object{$_ -match '^Profil de collecte : Standard'}).Count -eq 1)
 $health=[IO.File]::ReadAllText((Join-Path $wad 'modules\Domenia-Experience.UI.ps1'))
 Assert ($health.Contains('Get-DomeniaCollectionHealthLines')) 'Panneau non raccordé'
}
$failed=@($checks|Where-Object Status -eq 'Failed').Count
$report=[ordered]@{Kind='CollectionWiring';Expected=16;Complete=($checks.Count -eq 16 -and $failed -eq 0);NativeWindowsPowerShell51=$true;LiveAD=$false;MockedNetwork=$true;Passed=$checks.Count-$failed;Failed=$failed;Tests=$checks.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path $env:TEMP 'domenia-collection-wiring-tests.json'}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
Write-Host ($report.Passed.ToString()+' reussis, '+$failed+' echecs. '+$ReportPath)
if($failed -or -not $report.Complete){exit 1};exit 0
