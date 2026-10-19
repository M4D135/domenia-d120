#requires -Version 5.1
# Tableaux de bord en widgets (decision David 2026-10-07) : recette Windows dans la fenetre principale reelle.
# Donnees fictives (example.invalid), aucun reseau, aucune lecture ni ecriture AD. Couvre l affichage, le retrait
# et l annulation, la representation, la taille, le deplacement, le glisser-deposer, la personnalisation, l editeur
# (ajout, recherche, modification), la garde du perimetre des requetes et l animation d entree ; lot Z03 : grille
# fluide, carte Sante, poste allege, copie pour un ticket, disposition d equipe, export et import, editeur sans jargon.
[CmdletBinding()]
param([string]$ReportPath='',[switch]$Quiet,[string]$Filter='')
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
$wad=Split-Path -Parent $PSScriptRoot
$script:RenderTimings=[Collections.Generic.List[object]]::new()
$script:Results=[Collections.Generic.List[object]]::new();$script:Finished=$false;$script:Window=$null
$script:ExpectedCases=64
function Expect {param([bool]$Value,[string]$Why='Assertion non verifiee');if(-not $Value){throw $Why}}
function Case {param([string]$Name,[scriptblock]$Body)
    if($Filter -and $Name -notmatch $Filter -and $Name -ne 'Suite interrompue'){return}
    if(-not $Quiet){Write-Host ('START '+$Name)}
    try {& $Body|Out-Null;$script:Results.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}
    catch {$script:Results.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=($_.Exception.ToString()+[Environment]::NewLine+$_.ScriptStackTrace)})}
    if(-not $Quiet){$last=$script:Results[$script:Results.Count-1];Write-Host ($(if($last.Passed){'PASS '}else{'FAIL '})+$Name);if(-not $last.Passed){Write-Host $last.Error}}
}
function Parse-Text {param([string]$Text)
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    Expect (@($errors).Count -eq 0) ($errors|Out-String);return $ast
}
function Import-Function {param($Ast,[string]$Name)
    $found=@($Ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
    Expect ($found.Count -eq 1) ('Fonction absente/ambigue : '+$Name)
    . ([scriptblock]::Create(($found[0].Extent.Text -replace ('^function\s+'+[regex]::Escape($Name)+'\b'),('function script:'+$Name))))
}
# Host functions replaced by fixtures.
$script:TestSettings=@{};$script:Trace=[Collections.Generic.List[string]]::new();$script:ParkCalls=[Collections.Generic.List[object]]::new()
function Get-DomeniaControl {param($Name);if($null -ne $script:Ctrl -and $script:Ctrl.ContainsKey($Name)){return $script:Ctrl[$Name]};if($null -ne $script:Window){return $script:Window.FindName($Name)}}
function Set-DomeniaControlText {param($Name,$Text);$c=Get-DomeniaControl $Name;if($null -eq $c){return $false};$c.Text=[string]$Text;return $true}
function Get-DomeniaSetting {param([string]$Name,$Default=$null);if($script:TestSettings.ContainsKey($Name)){return $script:TestSettings[$Name]};return $Default}
function Set-DomeniaSetting {param([string]$Name,$Value);$script:TestSettings[$Name]=$Value}
function Save-DomeniaSettings {param([switch]$Immediate)}
function Set-Status {param($Text,$Level);$script:Trace.Add([string]$Text)}
function Write-AppLog {param($Text,$Level);$script:Trace.Add([string]$Text)}
function Add-DomeniaUiLog {param($Area,$Level,$Text);$script:Trace.Add([string]$Text)}
function Get-DomeniaStoredTheme {return 'Light'}
function Get-CfgValue {param($Section,$Key,$Default);return $Default}
function Set-AppWindowIcon {param($Window)}
function Start-DomeniaOnlinePark {param([switch]$DisplayedResults,[switch]$PingOnly,[switch]$WmiOnly,[switch]$PingBeforeWmi,[switch]$Inventory,$ScopeTargets,$ScopeLabel,$Probes,[switch]$ForceRefresh,[switch]$NoConsole,[int]$ReuseMaxAgeDays=0,[switch]$Preapproved,[string]$WidgetBoard='',[string[]]$WidgetIds=@(),[string]$Slot='',[switch]$PassThru)
    $script:ParkCalls.Add([pscustomobject]@{Targets=@($ScopeTargets);Label=$ScopeLabel;Probes=@($Probes);ProbesBound=$PSBoundParameters.ContainsKey('Probes');Displayed=[bool]$DisplayedResults;Inventory=[bool]$Inventory;PingOnly=[bool]$PingOnly;WmiOnly=[bool]$WmiOnly;PingBeforeWmi=[bool]$PingBeforeWmi;NoConsole=[bool]$NoConsole;Force=[bool]$ForceRefresh;Reuse=$ReuseMaxAgeDays;Preapproved=[bool]$Preapproved;WidgetBoard=$WidgetBoard;WidgetIds=@($WidgetIds);Slot=$Slot})
    # A widget collection follows its run: the fixture stands for an approved run that has not read anything yet, in
    # the survey scope it was started in (FI-18).
    if($PassThru){$id='park-'+$script:ParkCalls.Count;$slotName=$(if($Slot){$Slot}else{'List'});$runs=Get-DomeniaParkRuns;$runs[$slotName]=[pscustomobject]@{Id=$id;Slot=$slotName;Completed=$false;Loading=$false;Approved=$true;Done=0;Targets=@($ScopeTargets);Failed=0;AlreadyFresh=0;WidgetBoard=$WidgetBoard;WidgetIds=@($WidgetIds)};return $id}
}
$script:ParkStops=[Collections.Generic.List[string]]::new()
function Stop-DomeniaOnlinePark {param([string]$RunId='',[string]$Slot='List');$script:ParkStops.Add($RunId);$run=$(if($RunId){Get-DomeniaParkRunById $RunId}else{Get-DomeniaParkRun -Slot $Slot});if($null -ne $run){$run.Completed=$true}}
# The end of a run goes through the real Update-DomeniaParkRunStatus (Park.UI): nothing pending in the local store.
function Get-DomeniaPersistenceState {return [pscustomobject]@{Pending=0;Suspended=$false;Conflicts=0}}
# Point 20: the resume area of the collection settings (Collection.UI) is not part of the boards.
function Update-DomeniaCampaignResumeUi {}
function Clear-DomeniaParkTargetBuffers {param([object[]]$Targets)}
# Overview calculation (FleetStats worker): recorded, never run.
$script:StartCalls=[Collections.Generic.List[object]]::new();$script:AsyncJobs=@{}
function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$SuccessHandler,$ErrorHandler,$TimeoutSeconds,$TaskClass);$script:StartCalls.Add([pscustomobject]@{OperationId=$OperationId;Code=$Code;Payload=$Payload;State=$CallbackState;ReplaceKey=$ReplaceKey;TaskClass=$TaskClass});return ('job-'+$script:StartCalls.Count)}
# Tasks are recorded by this fixture, so cancellation records the matching request without a live engine.
$script:StopCalls=[Collections.Generic.List[string]]::new()
function Request-UiTaskStop {param($Id,[switch]$Silent,[switch]$Force,[switch]$Superseded,$Reason);$script:StopCalls.Add([string]$Id)}
function Initialize-DomeniaWinSqliteNative {return $true}
$script:StoreReadCalls=[Collections.Generic.List[object]]::new();$script:StoreSnapshotRevision=0L;$script:SelectedObjectGeneration=1L
function Test-DomeniaGuidText([string]$Text){$guid=[guid]::Empty;return [guid]::TryParse($Text,[ref]$guid)}
function New-DomeniaStoreContext($RequestId,$Generation){return [pscustomobject]@{StoreId='boards-fixture';Path=$script:DatabaseScopedPath;Generation=$Generation}}
function Request-DomeniaStoreRead($Context,$Query,$CallbackState,$SuccessHandler,$ErrorHandler){$script:StoreReadCalls.Add([pscustomobject]@{Context=$Context;Query=$Query;State=$CallbackState;SuccessHandler=$SuccessHandler});return 'store-read-fixture'}

# Le journal d'interface vient de Domenia-Core.ps1, que ce banc ne charge pas. Cette fixture enregistre
# ce qui est journalise: le cas « fonction absente » verifie que la cause est nommee dans le journal.
$script:UiLogLines=[Collections.Generic.List[string]]::new()
function Add-DomeniaUiLog {param($Text,$Level='INFO',$Area='Application')$script:UiLogLines.Add([string]$Level+'|'+[string]$Area+'|'+[string]$Text)}
# Complete-DomeniaFleetDashboard passe (Get-DomeniaIndexPartialText) dans Get-DomeniaFleetBoardData
# (Domenia-Dashboard.UI.ps1). La fonction vit dans Domenia-Core.ps1, que ce banc ne charge pas: sans
# fixture elle leve une CommandNotFoundException avalee par le catch, qui efface FleetComputedKey et
# laisse les 7 widgets du tableau de bord flotteur vides. Texte vide = index partiel non renseigne.
function Get-DomeniaIndexPartialText {return ''}
function Get-DomeniaLocalIndexReadWorkerCode {return '# fixture'}
function Get-DomeniaBitLockerPresenceWorkerCode {return '# fixture'}
function Queue-DomeniaMetadata {param($Kind,$Row,$Key='');$script:Queued.Add([pscustomobject]@{Kind=$Kind;Row=$Row;Key=$Key});return $true}
function Select-DomeniaWorkspace {param($Workspace,$Inner,$Tab);$script:Workspaces.Add([string]$Workspace+'/'+[string]$Tab);$tabs=Get-DomeniaControl 'WorkspaceTabs';$target=Get-DomeniaControl $Workspace;if($null -ne $tabs -and $null -ne $target -and $target -is [Windows.Controls.TabItem]){$tabs.SelectedItem=$target};if($Inner -and $Tab){$innerControl=Get-DomeniaControl $Inner;$tabControl=Get-DomeniaControl $Tab;if($null -ne $innerControl -and $null -ne $tabControl){$innerControl.SelectedItem=$tabControl}}}
function Invoke-DomeniaUxRoute {param($Route);$script:Workspaces.Add('route:'+[string]$Route)}
$script:Queued=[Collections.Generic.List[object]]::new();$script:Workspaces=[Collections.Generic.List[string]]::new()
# Dashboard scope is independent of Search; empty means the current domain root.
$script:FleetScopeDn=''
$script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid'}
function Invoke-Pump {param([int]$Ms=250)
    $frame=[Windows.Threading.DispatcherFrame]::new();$timer=[Windows.Threading.DispatcherTimer]::new()
    $timer.Interval=[timespan]::FromMilliseconds($Ms);$timer.Tag=$frame
    $timer.Add_Tick({param($s,$e)$s.Stop();$s.Tag.Continue=$false});$timer.Start();[Windows.Threading.Dispatcher]::PushFrame($frame)
}
function Get-Holders {param($Node)
    if($Node -isnot [Windows.Controls.Panel]){return}
    foreach($child in @($Node.Children)){
        if($child -is [Windows.FrameworkElement] -and $child.Tag -is [hashtable] -and $child.Tag.ContainsKey('Chrome')){Write-Output -NoEnumerate $child}
        else{Get-Holders $child}
    }
}
function Get-Layout {param([string]$Board);return @(Get-DomeniaBoardLayout -Board $Board)}
function Find-Named {param($Controls,[string]$Name);return @($Controls|Where-Object{[Windows.Automation.AutomationProperties]::GetName($_) -eq $Name})[0]}
function Step-EditorTrial {param($Trial)
    $Trial.Ticks++
    if($Trial.Ticks -gt 60){$Trial.Error='Editeur non termine.';$Trial.Timer.Stop();if($null -ne $script:DomeniaSurfaceState){$script:DomeniaSurfaceState.Window.Close()};return}
    $active=$script:DomeniaSurfaceState;if($null -eq $active -or $Trial.Done){return}
    try{$controls=@(Get-DomeniaLogicalControls $script:Window.FindName('DomeniaDialogLayer'));& $Trial.Act $controls $Trial;$Trial.Done=$true;$Trial.Timer.Stop()}
    catch{$Trial.Error=$_.Exception.ToString();$Trial.Timer.Stop();$active.Window.Close()}
}
function Invoke-EditorTrial {param([scriptblock]$Open,[scriptblock]$Act)
    $trial=[pscustomobject]@{Ticks=0;Error='';Done=$false;Act=$Act;Timer=[Windows.Threading.DispatcherTimer]::new();Seen=@{}}
    $trial.Timer.Interval=[timespan]::FromMilliseconds(150)
    # Capture the function scriptblock so the event closure does not lose the test script scope in Windows 5.1.
    $step=${function:Step-EditorTrial};$tick={& $step $trial}.GetNewClosure();$trial.Timer.Add_Tick($tick);$trial.Timer.Start()
    $accepted=$false
    try{$accepted=& $Open}finally{$trial.Timer.Stop();$trial.Timer.Remove_Tick($tick)}
    Expect (-not $trial.Error) $trial.Error
    return [pscustomobject]@{Accepted=[bool]$accepted;Trial=$trial}
}
function Complete-TestLocalQuery {
    Start-DomeniaQueryEvaluation
    $call=$script:StartCalls[$script:StartCalls.Count-1]
    Expect ($call.OperationId -eq 'LocalQuery') 'Expected the pure local query worker'
    $Payload=$call.Payload;$result=& ([scriptblock]::Create([string]$call.Code))
    Complete-DomeniaQueryEvaluation -Result $result -State $call.State
    if($null -ne $script:DomeniaQueryState.Timer){$script:DomeniaQueryState.Timer.Stop()}
}
function New-SoftwareRows {
    $rows=@(
        @('Navigateur A','Editeur Un','120.0','64 bits','Machine',420000),@('Navigateur A','Editeur Un','119.0','64 bits','Utilisateur',410000),
        @('Suite B','Editeur Deux','16.0','64 bits','Machine',2500000),@('Outil C','Editeur Deux','2.1','32 bits','Machine',12000),
        @('Lecteur D','Editeur Trois','5.0','32 bits','Machine',90000),@('Pilote E','','1.0','64 bits','Machine',3000),
        @('Agent F','Editeur Un','7.2','64 bits','Machine',56000),@('Utilitaire G','Editeur Quatre','3.3','64 bits','Machine',0))
    return @($rows|ForEach-Object{[pscustomobject]@{Name=$_[0];Publisher=$_[1];Version=$_[2];Architecture=$_[3];Scope=$_[4];SizeKb=[double]$_[5]}})
}
function New-InventoryResult {
    $rows=@(
        @('Systeme d exploitation','Nom','Microsoft Windows 11 Entreprise'),@('Systeme d exploitation','Build','26100'),
        @('Systeme d exploitation','Duree de fonctionnement','3 j 4 h 12 min'),@('Systeme d exploitation','Dernier demarrage','04/10/2026 08:00:00'),
        @('Systeme','Modele','Latitude 7450'),@('Systeme','Fabricant','Constructeur fictif'),@('Systeme','Utilisateur connecte','Aucun'),
        @('Systeme','Domaine','example.invalid'),@('Systeme','Role dans le domaine','1'),@('Memoire','Total installe','16 Go'),
        @('Redemarrage en attente','Etat','Aucun redemarrage en attente'))
    $metrics=[pscustomobject]@{MemoryTotal=[double]16GB;MemoryFree=[double]6GB;LastBoot='';CpuLoad=35.0;Battery=-1.0;ClockSkewSeconds=0
        Disks=@([pscustomobject]@{Name='C:';Size=[double]256GB;Free=[double]20GB});Hotfixes=@('2026-09-15');Processes=@([pscustomobject]@{Name='navigateur';Mb=900.0},[pscustomobject]@{Name='agent';Mb=120.0})
        Services=@{'En cours'=120;'Arretes (automatiques)'=2;'Arretes (manuels)'=80;'Desactives'=10}}
    return [pscustomobject]@{Rows=@($rows|ForEach-Object{[pscustomobject]@{Category=$_[0];Item=$_[1];Value=$_[2];Source='fixture'}});Metrics=$metrics}
}
function New-FleetResult {
    # Shaped like the FleetStats worker (lot L01): the workstations of the OU already filtered, grouped by their
    # system, version, activity and facts; observations attached by GUID.
    param([string]$Scope='',[object[]]$Presence=@())
    $all=@(
        [pscustomobject]@{name='PC-1';object_guid='00000000-0000-4000-8000-000000000001';distinguished_name='CN=PC-1,OU=Postes,DC=example,DC=invalid';st='A';os='Windows 11 Entreprise';ver='10.0 (26100)';lb=0;cr='O';pw='R';lk='O';bk='U';logon='2026-10-01'}
        [pscustomobject]@{name='PC-2';object_guid='00000000-0000-4000-8000-000000000002';distinguished_name='CN=PC-2,OU=Postes,DC=example,DC=invalid';st='A';os='Windows 10 Entreprise';ver='10.0 (19045)';lb=3;cr='O';pw='O';lk='O';bk='U';logon='2026-05-01'}
        [pscustomobject]@{name='SRV-1';object_guid='00000000-0000-4000-8000-000000000003';distinguished_name='CN=SRV-1,OU=Serveurs,DC=example,DC=invalid';st='A';os='Windows Server 2025 Datacenter';ver='10.0 (26100)';lb=5;cr='O';pw='R';lk='O';bk='U';logon=''}
        [pscustomobject]@{name='PC-OFF';object_guid='00000000-0000-4000-8000-000000000004';distinguished_name='CN=PC-OFF,OU=Postes,DC=example,DC=invalid';st='D';os='Windows 10 Entreprise';ver='10.0 (19045)';lb=4;cr='O';pw='O';lk='O';bk='U';logon='2025-01-01'}
    )
    $kept=@($all|Where-Object{(-not $Scope) -or ([string]$_.distinguished_name).EndsWith(','+$Scope,[StringComparison]::OrdinalIgnoreCase)})
    $groups=@();$machines=@();$parents=@{};$i=0
    foreach($m in $kept){$i++;$groups+=[pscustomobject]@{gid=[string]$i;st=$m.st;os=$m.os;ver=$m.ver;lb=$m.lb;cr=$m.cr;pw=$m.pw;lk=$m.lk;bk=$m.bk;n=1};$machines+=[pscustomobject]@{name=$m.name;distinguished_name=$m.distinguished_name;object_guid=$m.object_guid;gid=[string]$i;st=$m.st;logon=$m.logon};$p=([string]$m.distinguished_name).Substring(([string]$m.distinguished_name).IndexOf(',')+1);$parents[$p]=1+[int]$parents[$p]}
    $result=[pscustomobject]@{Busy=$false;Links=2;LinkSources=@();MachineCount=$machines.Count
        Types=@([pscustomobject]@{t='Machine';s='Actif';n=@($kept|Where-Object{$_.st -eq 'A'}).Count},[pscustomobject]@{t='Machine';s='Desactive';n=@($kept|Where-Object{$_.st -eq 'D'}).Count},[pscustomobject]@{t='Utilisateur';s='Actif';n=12})
        Groups=$groups;Machines=$machines;Parents=@(foreach($k in $parents.Keys){[pscustomobject]@{p=$k;n=$parents[$k]}})
        Coverage=[pscustomobject]@{BitLockerRead=0;BitLockerAt='';FactsFresh=$machines.Count;FactsStale=0;FactsAt=''}
        Presence=@($Presence);History=@()}
    $board=Get-DomeniaFleetBoardData -Result $result -Scope $Scope -Subtree $true -Lifecycle (Get-DomeniaWindowsLifecycleTable) -ObservationMaxAgeDays (Get-DomeniaObservationMaxAgeDays)
    Add-Member -InputObject $result -MemberType NoteProperty -Name Board -Value $board
    return $result
}
try{
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    foreach($library in @('M4D.Admin.Common.Query.dll','Domenia.Native.dll')){[void][Reflection.Assembly]::LoadFrom((Join-Path $wad ('modules\'+$library)))}
    $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid';Server='dc.example.invalid';Domain='example.invalid';Netbios='EXAMPLE'}
    $script:SessionEpoch=1L;$script:SelectedObject=$null
    $coreText=[IO.File]::ReadAllText((Join-Path $wad 'Domenia-Core.ps1'));$ast=Parse-Text $coreText
    foreach($n in @('Get-MainXaml','Get-DomeniaEffectiveWorkerResult','Get-DomeniaDefaultSettings')){Import-Function $ast $n}
    $parkAst=Parse-Text ([IO.File]::ReadAllText((Join-Path $wad 'modules\Domenia-Park.UI.ps1')));foreach($n in @('Get-DomeniaParkRuns','Get-DomeniaParkRun','Get-DomeniaParkRunById','Test-DomeniaParkRunActive','Clear-DomeniaParkPendingRow','Clear-DomeniaParkPendingRows','Sync-DomeniaParkGrid','Start-DomeniaParkAnalysis','Update-DomeniaParkRunStatus','Update-DomeniaParkControls','Get-DomeniaParkRunDetailText','Get-DomeniaParkInFlightCount','Get-DomeniaParkListCount')){Import-Function $parkAst $n}
    # FI-18: the survey scopes of Park.UI and the texts of a survey (Park.Model); the buffers of the targets stay a fixture.
    $parkModelAst=Parse-Text ([IO.File]::ReadAllText((Join-Path $wad 'modules\Domenia-Park.Model.ps1')));foreach($n in @('Get-DomeniaParkPlural','Get-DomeniaParkProgressText')){Import-Function $parkModelAst $n}
    $script:FleetScopeDn=''
    # FI-05 / PF-06: Engine.UI holds the protected timer factory (banners, counters, park run).
    foreach($m in @('Domenia-Common.Model.ps1','Domenia-Search.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Collection.Model.ps1','Domenia-Engine.UI.ps1','Domenia-Embedded.UI.ps1','Domenia-Workstation.Model.ps1','Domenia-HealthRules.Model.ps1','Domenia-HealthRules.UI.ps1','Domenia-Access.Model.ps1','Domenia-Dossier.Model.ps1','Domenia-Boards.Model.ps1','Domenia-WidgetCollect.Model.ps1','Domenia-Charts.UI.ps1','Domenia-Probes.Model.ps1','Domenia-ProbeContract.Model.ps1','Domenia-Readings.Model.ps1','Domenia-BoardFleet.Model.ps1','Domenia-BoardSoftware.Model.ps1','Domenia-BoardComputer.UI.ps1','Domenia-Widgets.UI.ps1','Domenia-FirstRun.Model.ps1','Domenia-Dashboard.UI.ps1','Domenia-Query.Model.ps1','Domenia-Query.Worker.ps1','Domenia-Query.UI.ps1','Domenia-QueryDetails.UI.ps1','Domenia-QueryTargets.UI.ps1','Domenia-QueryLibrary.Model.ps1','Domenia-QueryLibrary.Store.UI.ps1','Domenia-QuerySchema.Model.ps1','Domenia-QuerySchema.UI.ps1','Domenia-QueryTransfer.UI.ps1')){. (Join-Path $wad ('modules\'+$m))}
    $reader=[Xml.XmlNodeReader]::new([xml](Get-MainXaml -WadRoot (Split-Path -Parent $PSScriptRoot)));try{$w=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    $w.Width=1400;$w.Height=900;$w.ShowInTaskbar=$false
    $palette=(Get-Content -LiteralPath (Join-Path $wad 'modules\SupportSuite.UI.json') -Raw|ConvertFrom-Json).Palettes.Light
    $convert=[Windows.Media.BrushConverter]::new();foreach($p in $palette.PSObject.Properties){$w.Resources[$p.Name]=$convert.ConvertFromInvariantString([string]$p.Value)}
    $script:Window=$w;$w.Show();$w.UpdateLayout()
    $script:DomeniaReduceMotion=$true
    $script:Ctrl=@{};Initialize-DomeniaQueryWorkshop

    Case 'Les dispositions des tableaux survivent au filtre des reglages' {
        $defaults=Get-DomeniaDefaultSettings
        foreach($key in @('Dashboard.Computer.Layout','Dashboard.Fleet.Layout','Dashboard.Software.Layout','Widgets.Computer','Widgets.Fleet')){Expect ($defaults.Contains($key)) ('Reglage absent de la liste blanche : '+$key)}
        # The independent dashboard scope is session-local, not persisted into user settings.
        Expect (-not $defaults.Contains('FleetScopeDn')) 'Un perimetre de session est persiste entre connexions'
    }
    Case 'Logiciels : chaque information devient un widget sous sa section' {
        Update-DomeniaSoftwareDashboard -Rows (New-SoftwareRows)
        $panel=Get-DomeniaControl 'PnlSoftwareDashboard'
        $holders=@(Get-Holders $panel)
        Expect ($holders.Count -eq @(Get-DomeniaBoardCatalog -Board Software).Count) ('Widgets : '+$holders.Count)
        Expect (@(Get-DomeniaLogicalControls $panel.Children[0]|Where-Object{$_ -is [Windows.Controls.Button] -and $_.Tag -is [hashtable] -and $_.Tag['Action'] -eq 'Customize'}).Count -eq 1) 'Barre d outils absente'
        Expect (-not (Get-DomeniaSetting 'Dashboard.Software.Layout' '')) 'Un simple affichage ne doit rien enregistrer'
    }
    $script:SoftIds=@(Get-Layout Software|ForEach-Object{[string]$_.Id})
    Case 'Retirer un widget puis Annuler le remet a sa place' {
        $before=@(Get-Layout Software).Count
        Invoke-DomeniaBoardAction -Tag @{Board='Software';Id=$script:SoftIds[1];Action='Remove'}
        Expect (@(Get-Layout Software).Count -eq $before-1) 'Widget non retire'
        Expect (@(Get-Holders (Get-DomeniaControl 'PnlSoftwareDashboard')).Count -eq $before-1) 'Affichage non mis a jour'
        Expect ([string](Get-DomeniaBoardState 'Software').UndoText -eq 'Widget retire') 'Annulation non proposee'
        Invoke-DomeniaBoardAction -Tag @{Board='Software';Action='Undo'}
        Expect ((@(Get-Layout Software|ForEach-Object{[string]$_.Id}) -join ',') -eq ($script:SoftIds -join ',')) 'Ordre non restaure'
        Expect (-not (Get-DomeniaBoardState 'Software').UndoText) 'Annulation encore proposee'
    }
    Case 'Representation et taille changent par le menu et restent permises' {
        $pie=@(Get-Layout Software|Where-Object{$_.Key -eq 'software.publishers'})[0]
        Invoke-DomeniaBoardAction -Tag @{Board='Software';Id=[string]$pie.Id;Action='Visual';Value='Bar'}
        Invoke-DomeniaBoardAction -Tag @{Board='Software';Id=[string]$pie.Id;Action='Size';Value='L'}
        $now=@(Get-Layout Software|Where-Object{$_.Id -eq $pie.Id})[0]
        Expect ([string]$now.Visual -eq 'Bar' -and [string]$now.Size -eq 'L') ('Obtenu '+$now.Visual+'/'+$now.Size)
        Invoke-DomeniaBoardAction -Tag @{Board='Software';Id=[string]$pie.Id;Action='Visual';Value='Gauge'}
        Expect ([string]@(Get-Layout Software|Where-Object{$_.Id -eq $pie.Id})[0].Visual -eq 'Pie') 'Une jauge ne represente pas une repartition'
        $menu=@(Get-Holders (Get-DomeniaControl 'PnlSoftwareDashboard')|Where-Object{$_.Tag.Id -eq $pie.Id})[0].ContextMenu
        $represent=@($menu.Items|Where-Object{$_ -is [Windows.Controls.MenuItem] -and [string]$_.Header -eq 'Représentation'})[0]
        Expect (@($represent.Items|ForEach-Object{[string]$_.Header}) -notcontains 'Jauge') 'Menu : jauge proposee'
    }
    Case 'Deplacer dans la section et par glisser-deposer' {
        $ids=@(Get-Layout Software|Where-Object{$_.Group -eq 'Synthese'}|ForEach-Object{[string]$_.Id})
        Invoke-DomeniaBoardAction -Tag @{Board='Software';Id=$ids[1];Action='Move';Value='First'}
        Expect ([string]@(Get-Layout Software|Where-Object{$_.Group -eq 'Synthese'})[0].Id -eq $ids[1]) 'Debut de section'
        $target=@(Get-Layout Software|Where-Object{$_.Key -eq 'software.largest'})[0]
        Request-DomeniaBoardDrop -Board Software -Id $ids[0] -Before ([string]$target.Id)
        Invoke-Pump 300
        $moved=@(Get-Layout Software|Where-Object{$_.Id -eq $ids[0]})[0]
        Expect ([string]$moved.Group -eq [string]$target.Group) 'Section de la cible non prise'
        $order=@(Get-Layout Software|ForEach-Object{[string]$_.Id})
        Expect ([Array]::IndexOf($order,$ids[0]) -eq [Array]::IndexOf($order,[string]$target.Id)-1) 'Place non prise'
        Expect ([string](Get-DomeniaBoardState 'Software').UndoText -eq 'Widget deplace') 'Annulation du deplacement absente'
    }
    Case 'Personnaliser montre les commandes, les emplacements libres et les widgets sans donnees' {
        Invoke-DomeniaBoardAction -Tag @{Board='Software';Action='Customize'}
        $panel=Get-DomeniaControl 'PnlSoftwareDashboard'
        $holders=@(Get-Holders $panel)
        Expect (@($holders|Where-Object{$_.Tag.Editing -and $_.Tag.Chrome.Opacity -eq 1}).Count -eq $holders.Count) 'Commandes masquees'
        $adds=@(Get-DomeniaLogicalControls $panel|Where-Object{$_ -is [Windows.Controls.Button] -and [Windows.Automation.AutomationProperties]::GetName($_) -like 'Ajouter un widget dans *'})
        $groups=@(Get-DomeniaBoardGroups -Layout (Get-Layout Software))
        Invoke-DomeniaBoardAction -Tag @{Board='Software';Action='Customize'}
        Expect ($adds.Count -eq $groups.Count) ('Emplacements : '+$adds.Count)
        Expect ([Windows.Automation.AutomationProperties]::GetName($adds[0]) -eq ('Ajouter un widget dans '+$groups[0])) 'Nom accessible de l emplacement'
        Expect (-not (Get-DomeniaBoardState 'Software').Editing) 'Mode non quitte'
    }
    Case 'Retablir revient a la disposition livree et reste annulable' {
        $custom=(ConvertTo-DomeniaBoardLayoutJson -Layout (Get-Layout Software))
        Invoke-DomeniaBoardAction -Tag @{Board='Software';Action='Reset'}
        Expect ((@(Get-Layout Software|ForEach-Object{$_.Key}) -join ',') -eq (@(Get-DomeniaBoardCatalog -Board Software|ForEach-Object{$_.Key}) -join ',')) 'Disposition livree'
        Invoke-DomeniaBoardAction -Tag @{Board='Software';Action='Undo'}
        Expect ((ConvertTo-DomeniaBoardLayoutJson -Layout (Get-Layout Software)) -eq $custom) 'Annulation du retablissement'
    }
    Case 'Un tableau vide volontairement reste vide et le dit' {
        $saved=ConvertTo-DomeniaBoardLayoutJson -Layout (Get-Layout Software)
        foreach($item in @(Get-Layout Software)){Invoke-DomeniaBoardAction -Tag @{Board='Software';Id=[string]$item.Id;Action='Remove'}}
        Expect (@(Get-Layout Software).Count -eq 0) 'Disposition livree revenue apres le dernier retrait'
        $panel=Get-DomeniaControl 'PnlSoftwareDashboard'
        Expect (@(Get-DomeniaLogicalControls $panel|Where-Object{$_ -is [Windows.Controls.TextBlock] -and [string]$_.Text -eq 'Aucun widget'}).Count -eq 1) 'Etat vide absent'
        Set-DomeniaBoardLayout -Board Software -Layout @(ConvertTo-DomeniaBoardLayout -Board Software -Json $saved)
        Expect (@(Get-Layout Software).Count -gt 0) 'Disposition non restauree'
    }
    Case 'Editeur : la recherche filtre et Ajouter enregistre le widget choisi' {
        $largest=@(Get-Layout Software|Where-Object{$_.Key -eq 'software.largest'})[0]
        Invoke-DomeniaBoardAction -Tag @{Board='Software';Id=[string]$largest.Id;Action='Remove'}
        $run=Invoke-EditorTrial {Show-DomeniaBoardEditor -Board Software} {
            param($c,$t)
            $search=Find-Named $c 'Rechercher une information';$list=Find-Named $c 'Informations disponibles'
            $all=@($list.ItemsSource).Count;$search.Text='editeur';$t.Seen['Filtered']=@($list.ItemsSource).Count;$t.Seen['All']=$all
            $search.Text=''
            $row=@($list.ItemsSource|Where-Object{$_.Key -eq 'software.largest'})[0];$list.SelectedItem=$row
            $t.Seen['Visuals']=@((Find-Named $c 'Représentation').Items|ForEach-Object{[string]$_}) -join ','
            (Find-Named $c 'Représentation').SelectedItem='Histogramme'
            (Find-Named $c 'Titre du widget').Text='Les plus lourds'
            $t.Seen['Preview']=@($c|Where-Object{$_ -is [Windows.Controls.Viewbox]}).Count
            $save=@($c|Where-Object{$_ -is [Windows.Controls.Button] -and [string]$_.Content -eq 'Ajouter'})[0]
            $save.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        }
        Expect $run.Accepted 'Editeur non accepte'
        Expect ($run.Trial.Seen['Filtered'] -gt 0 -and $run.Trial.Seen['Filtered'] -lt $run.Trial.Seen['All']) ('Filtre : '+$run.Trial.Seen['Filtered']+'/'+$run.Trial.Seen['All'])
        Expect ([string]$run.Trial.Seen['Visuals'] -notlike '*Jauge*') ('Representations : '+$run.Trial.Seen['Visuals'])
        $added=@(Get-Layout Software|Where-Object{$_.Key -eq 'software.largest'})
        Expect ($added.Count -eq 1 -and [string]$added[0].Visual -eq 'Column' -and [string]$added[0].Title -eq 'Les plus lourds') 'Widget ajoute incorrect'
        Expect ([string]$added[0].Group -eq 'Repartition') ('Section du widget ajoute : '+[string]$added[0].Group)
    }
    Case 'Editeur : Modifier change le titre, et un titre remis par defaut redevient vide' {
        $item=@(Get-Layout Software|Where-Object{$_.Key -eq 'software.largest'})[0]
        $run=Invoke-EditorTrial {Show-DomeniaBoardEditor -Board Software -Id ([string]$item.Id)} {
            param($c,$t)
            (Find-Named $c 'Titre du widget').Text='Plus gros logiciels'
            (Find-Named $c 'Taille').SelectedItem='Compacte'
            $t.Seen['Section']=[string](Find-Named $c 'Section').SelectedItem
            (Find-Named $c 'Section').SelectedItem='+ Nouvelle section...'
            $t.Seen['NewVisible']=[string](Find-Named $c 'Nom de la nouvelle section').Visibility
            (Find-Named $c 'Nom de la nouvelle section').Text='Logiciels lourds'
            $save=@($c|Where-Object{$_ -is [Windows.Controls.Button] -and [string]$_.Content -eq 'Enregistrer'})[0]
            $save.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        }
        $now=@(Get-Layout Software|Where-Object{$_.Id -eq $item.Id})[0]
        Expect ($run.Accepted -and [string]$now.Title -eq '' -and [string]$now.Size -eq 'S') ('Obtenu titre='+$now.Title+' taille='+$now.Size)
        Expect ($run.Trial.Seen['Section'] -eq 'Repartition') ('Section affichee : '+$run.Trial.Seen['Section'])
        Expect ($run.Trial.Seen['NewVisible'] -eq 'Visible') 'Champ de nouvelle section non affiche'
        Expect ([string]$now.Group -eq 'Logiciels lourds') ('Nouvelle section : '+[string]$now.Group)
    }
    Case 'Editeur : Annuler ne change rien' {
        $before=ConvertTo-DomeniaBoardLayoutJson -Layout (Get-Layout Software)
        $run=Invoke-EditorTrial {Show-DomeniaBoardEditor -Board Software} {param($c,$t);$script:DomeniaSurfaceState.Window.Close()}
        Expect ((-not $run.Accepted) -and (ConvertTo-DomeniaBoardLayoutJson -Layout (Get-Layout Software)) -eq $before) 'Disposition modifiee'
    }
    Case 'Poste sans inventaire : etat vide explicite, aucun widget invente' {
        Clear-DomeniaDashboards
        $panel=Get-DomeniaControl 'PnlComputerDashboard'
        Expect (@(Get-Holders $panel).Count -eq 0) 'Widgets sans donnees affiches'
        Expect (@(Get-DomeniaLogicalControls $panel|Where-Object{$_ -is [Windows.Controls.TextBlock] -and [string]$_.Text -eq 'Pas encore de donnees'}).Count -eq 1) 'Etat vide absent'
    }
    Case 'Poste avec inventaire : sante, ressources et sections remplies' {
        Update-DomeniaComputerDashboard -Result (New-InventoryResult)
        $panel=Get-DomeniaControl 'PnlComputerDashboard'
        $data=(Get-DomeniaBoardState 'Computer').Data
        foreach($key in @('computer.health','computer.attention','computer.os','computer.memory.usage','computer.disk.system','computer.services')){Expect ($data.Entries.ContainsKey($key)) ('Entree absente : '+$key)}
        Expect ([string]$data.Entries['computer.os'].Value -eq 'Windows 11 24H2') ('Systeme : '+$data.Entries['computer.os'].Value)
        Expect ([string]$data.Entries['computer.user'].Value -eq 'Aucun') 'Utilisateur vide en mots'
        Expect (@(Get-Holders $panel).Count -ge 10) ('Widgets : '+@(Get-Holders $panel).Count)
        Expect ([string](Get-DomeniaControl 'LblComputerDashboard').Text -ne '') 'Resume absent'
    }
    Case 'Un widget sans donnee reste masque hors personnalisation' {
        $panel=Get-DomeniaControl 'PnlComputerDashboard'
        $shown=@(Get-Holders $panel).Count
        Invoke-DomeniaBoardAction -Tag @{Board='Computer';Action='Customize'}
        Expect (@(Get-Holders $panel).Count -eq @(Get-Layout Computer).Count) 'Tous les widgets visibles en personnalisation'
        Invoke-DomeniaBoardAction -Tag @{Board='Computer';Action='Customize'}
        Expect (@(Get-Holders $panel).Count -eq $shown) 'Retour a l affichage normal'
    }
    Case 'Accueil : périmètre local indépendant de Rechercher' {
        foreach($name in @('BtnFleetPing','BtnFleetDetect','BtnFleetAnalyze','BtnFleetStop','TxtFleetScope','LblFleetRun')){Expect ($null -eq (Get-DomeniaControl $name)) ('Controle encore present : '+$name)}
        Expect ($null -ne (Get-DomeniaControl 'LblFleetScope') -and $null -ne (Get-DomeniaControl 'BtnFleetScope')) 'Perimetre de l accueil absent'
        $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid'
        $scope=Get-DomeniaFleetScope
        Expect ([string]$scope.Dn -eq 'OU=Postes,DC=example,DC=invalid' -and $scope.Subtree -and [string]$scope.Name -eq 'Postes') ('Perimetre : '+[string]$scope.Key)
        $script:FleetScopeDn='OU=Lyon,OU=Postes,DC=example,DC=invalid'
        Expect ((Get-DomeniaFleetScope).Subtree) 'Le périmètre du tableau de bord inclut les sous-OU'
        $script:FleetScopeDn=''
        $whole=Get-DomeniaFleetScope
        Expect ([string]$whole.Dn -eq '' -and [string]$whole.Key -eq '*') 'Racine du domaine non reconnue'
        Update-DomeniaFleetScopeText $whole
        Expect ([string](Get-DomeniaControl 'LblFleetScope').Text -like 'Tout le domaine*') 'Libelle du perimetre'
    }
    Case 'Parc : tableau calcule sur le perimetre et serveurs reconnus' {
        $script:FleetScopeDn=''
        $script:TestSettings['Home.DashboardSeen']=''
        # Point 148: an overview computed while the workshop (Outils, Atelier) is shown does not complete the step.
        (Get-DomeniaControl 'WorkspaceTabs').SelectedItem=Get-DomeniaControl 'TabApplicationTools';(Get-DomeniaControl 'ApplicationToolTabs').SelectedItem=Get-DomeniaControl 'WsQueryWorkshop';$w.UpdateLayout()
        Complete-DomeniaFleetDashboard -Result (New-FleetResult) -State $null
        Expect ([string]$script:TestSettings['Home.DashboardSeen'] -eq '') 'Decouverte du tableau de bord enregistree depuis l atelier'
        (Get-DomeniaControl 'WorkspaceTabs').SelectedItem=Get-DomeniaControl 'TabDashboard';$w.UpdateLayout()
        Complete-DomeniaFleetDashboard -Result (New-FleetResult) -State $null
        # Point 148: an overview with workstations computed while Accueil is shown completes the dashboard step.
        Expect ([string]$script:TestSettings['Home.DashboardSeen'] -match '^\d{4}-\d{2}-\d{2}T') 'Decouverte du tableau de bord non enregistree'
        $script:TestSettings.Remove('Home.DashboardSeen')
        $data=(Get-DomeniaBoardState 'Fleet').Data
        Expect ($data.Entries.ContainsKey('fleet.os') -and $data.Entries.ContainsKey('fleet.health')) 'Entrees du parc'
        Expect (@($script:FleetLast.Targets).Count -eq 3) 'Cibles du perimetre'
        Expect (@($script:FleetLast.Machines).Count -eq 4) 'Recensement complet : le poste desactive manque'
        Expect (@($script:FleetLast.Targets|Where-Object{$_.name -eq 'PC-OFF'}).Count -eq 0) 'Un poste desactive est cible de collecte'
        Update-DomeniaFleetMachineList;Complete-TestLocalQuery
        Expect (@((Get-DomeniaControl 'DgFleetMachines').ItemsSource).Count -eq 4) 'La liste locale doit montrer aussi les postes désactivés'
        (Get-DomeniaControl 'TxtFleetMachineFilter').Text='PC-1';Update-DomeniaFleetMachineList;Complete-TestLocalQuery
        Expect (@((Get-DomeniaControl 'DgFleetMachines').ItemsSource).Count -eq 1) 'Le filtre local par nom ne fonctionne pas'
        (Get-DomeniaControl 'TxtFleetMachineFilter').Text=''
        (Get-DomeniaControl 'CmbFleetMachineState').SelectedIndex=2;Update-DomeniaFleetMachineList;Complete-TestLocalQuery
        Expect (@((Get-DomeniaControl 'DgFleetMachines').ItemsSource).Count -eq 1) 'Le filtre des comptes désactivés ne fonctionne pas'
        (Get-DomeniaControl 'CmbFleetMachineState').SelectedIndex=0;Update-DomeniaFleetMachineList;Complete-TestLocalQuery
        Expect (@($data.Entries['fleet.attention'].Items|Where-Object{[string]$_.Text -like '*Windows 10 22H2*fin de service*'}).Count -eq 1) 'Windows 10 signale par la table des fins de service'
        Expect (@($data.Entries['fleet.versions'].Items|Where-Object{[string]$_.Label -eq 'Windows Server 2025'}).Count -eq 1) 'Serveur reconnu a son build'
        Expect (@(Get-Holders (Get-DomeniaControl 'PnlFleetDashboard')).Count -ge 6) 'Widgets du parc'
    }
    Case 'CD-05 / DS-14 : un changement de theme redessine le tableau affiche sans relecture, un tableau cache a son affichage' {
        # Chart colours are resolved from the painted theme when a widget is drawn: the light theme adds the darker
        # contour of each categorical part, the dark theme draws none (its pastels reach 3:1 alone).
        $tabs=Get-DomeniaControl 'WorkspaceTabs';$oldTab=$tabs.SelectedItem;$oldTheme=$script:CurrentTheme
        $hadLayout=$script:TestSettings.ContainsKey('Dashboard.Fleet.Layout');$savedLayout=$script:TestSettings['Dashboard.Fleet.Layout']
        $pending=@{};foreach($b in @('Computer','Software')){$pending[$b]=[bool](Get-DomeniaBoardState $b).RenderPending}
        $lightEdges=@(Get-DomeniaChartSeries -Theme Light|ForEach-Object{[string]$_.Edge})
        $countEdges={param($Panel)@(Get-DomeniaLogicalControls $Panel|Where-Object{($_ -is [Windows.Shapes.Path]) -and (-not $_.IsHitTestVisible) -and ($null -eq $_.Tag) -and ($_.Stroke -is [Windows.Media.SolidColorBrush]) -and (('#{0:X2}{1:X2}{2:X2}' -f $_.Stroke.Color.R,$_.Stroke.Color.G,$_.Stroke.Color.B) -in $lightEdges)}).Count}
        try{
            $script:TestSettings.Remove('Dashboard.Fleet.Layout')
            $tabs.SelectedItem=Get-DomeniaControl 'TabDashboard';$w.UpdateLayout()
            $panel=Get-DomeniaControl 'PnlFleetDashboard'
            $script:CurrentTheme='Dark'
            Show-DomeniaBoard -Board Fleet -Quiet;$w.UpdateLayout()
            Expect ((& $countEdges $panel) -eq 0) 'Sombre : un contour du theme clair est dessine'
            $starts=$script:StartCalls.Count;$reads=$script:StoreReadCalls.Count;$parks=$script:ParkCalls.Count
            # Like a new width of the page (DS-04), the redraw gives the keyboard focus back to the widget that held it;
            # checked when this session can give the window the keyboard focus.
            $focusHolder=@(Get-Holders $panel)[0];$focusId=[string]$focusHolder.Tag.Id;$focusTaken=[bool]$focusHolder.Focus()
            $script:CurrentTheme='Light';Update-DomeniaBoardsTheme;$w.UpdateLayout()
            if($focusTaken){$now=[Windows.Input.Keyboard]::FocusedElement;Expect (($now -is [Windows.FrameworkElement]) -and $panel.IsAncestorOf($now) -and ($now.Tag -is [hashtable]) -and ([string]$now.Tag['Id'] -eq $focusId)) 'Focus clavier perdu au changement de theme'}
            $light=& $countEdges $panel
            Expect ($light -gt 0) 'Tableau affiche non redessine aux couleurs du theme clair'
            # A hidden board keeps its drawing and is drawn again when it is shown.
            $tabs.SelectedItem=Get-DomeniaControl 'WsSearch';$w.UpdateLayout()
            $script:CurrentTheme='Dark';Update-DomeniaBoardsTheme
            Expect ([bool](Get-DomeniaBoardState 'Fleet').RenderPending) 'Tableau cache non retenu pour son affichage'
            Expect ((& $countEdges $panel) -eq $light) 'Tableau cache redessine avant son affichage'
            $tabs.SelectedItem=Get-DomeniaControl 'TabDashboard';$w.UpdateLayout()
            Expect ((-not [bool](Get-DomeniaBoardState 'Fleet').RenderPending) -and ((& $countEdges $panel) -eq 0)) 'Tableau cache non redessine aux couleurs du theme sombre a son affichage'
            Expect (($script:StartCalls.Count -eq $starts) -and ($script:StoreReadCalls.Count -eq $reads) -and ($script:ParkCalls.Count -eq $parks)) 'Le changement de theme a lance une lecture'
        }finally{
            $script:CurrentTheme=$oldTheme
            if($hadLayout){$script:TestSettings['Dashboard.Fleet.Layout']=$savedLayout}else{$script:TestSettings.Remove('Dashboard.Fleet.Layout')}
            $tabs.SelectedItem=Get-DomeniaControl 'TabDashboard';$w.UpdateLayout();Show-DomeniaBoard -Board Fleet -Quiet
            foreach($b in @('Computer','Software')){(Get-DomeniaBoardState $b).RenderPending=$pending[$b]}
            $tabs.SelectedItem=$oldTab;$w.UpdateLayout()
        }
    }
    Case 'Accueil : disposition livree sans widget d observation ni requete WMI' {
        $script:TestSettings.Remove('Dashboard.Fleet.Layout')
        $layout=@(Get-Layout Fleet)
        Expect (@($layout|Where-Object{[string]$_.Source -eq 'Probe'}).Count -eq 0) 'Requete WMI livree'
        $observation=@('fleet.presence','fleet.users','fleet.lastcheck','fleet.models','fleet.releases','fleet.ram','fleet.diskfree','fleet.lowdisk','fleet.uptime')
        Expect (@($layout|Where-Object{[string]$_.Key -in $observation}).Count -eq 0) 'Widget d observation livre'
        foreach($key in @('fleet.machines','fleet.stale','fleet.versions','fleet.eos','fleet.disabled','fleet.created','fleet.pwdold','fleet.laps','fleet.bitlocker')){Expect (@($layout|Where-Object{[string]$_.Key -eq $key}).Count -eq 1) ('Widget livre absent : '+$key)}
        $before=$script:StartCalls.Count;$parks=$script:ParkCalls.Count
        Complete-DomeniaFleetDashboard -Result (New-FleetResult) -State $null
        Expect ($script:StartCalls.Count -eq $before -and $script:ParkCalls.Count -eq $parks) 'Affichage de l accueil a lance une lecture'
        $bitlocker=@(Get-DomeniaLogicalControls (Get-DomeniaControl 'PnlFleetDashboard')|Where-Object{$_ -is [Windows.Controls.Button] -and $_.Tag -is [hashtable] -and [string]$_.Tag['Action'] -eq 'EntryAction'})
        Expect ($bitlocker.Count -eq 0) 'Bouton BitLocker a la racine du domaine'
    }
    Case 'Presence BitLocker : refusee a la racine du domaine, limitee a l OU affichee, sur geste' {
        $script:FleetScopeDn=''
        $before=$script:StartCalls.Count
        Expect (-not (Start-DomeniaFleetBitLockerPresence)) 'Lecture acceptee a la racine du domaine'
        Expect ($script:StartCalls.Count -eq $before) 'Tache lancee a la racine du domaine'
        Expect (@($script:Trace|Where-Object{$_ -like '*racine du domaine*'}).Count -ge 1) 'Refus non explique'
        $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid';$script:FleetStale=$false;$script:FleetJobId=''
        Complete-DomeniaFleetDashboard -Result (New-FleetResult -Scope 'OU=Postes,DC=example,DC=invalid') -State $null
        $button=@(Get-DomeniaLogicalControls (Get-DomeniaControl 'PnlFleetDashboard')|Where-Object{$_ -is [Windows.Controls.Button] -and $_.Tag -is [hashtable] -and [string]$_.Tag['Action'] -eq 'EntryAction'})
        Expect ($button.Count -eq 1) 'Bouton de lecture absent du widget BitLocker'
        $button[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        $call=$script:StartCalls[$script:StartCalls.Count-1]
        Expect ($script:StartCalls.Count -eq $before+1 -and [string]$call.OperationId -eq 'BitLockerPresence') 'Lecture BitLocker non lancee par le bouton'
        Expect ([string]$call.Payload.DN -eq 'OU=Postes,DC=example,DC=invalid') ('Perimetre de lecture : '+[string]$call.Payload.DN)
        Expect ([string]$call.TaskClass -eq 'Explicit') 'Lecture BitLocker non explicite'
        $script:Queued.Clear()
        Complete-DomeniaFleetBitLockerPresence -Result ([pscustomobject]@{Mode='BitLockerPresence';Success=$true;DN='OU=Postes,DC=example,DC=invalid';ClassPresent=$true;RecoveryObjectsFound=0;Truncated=$false;Computers=@();ErrorKind='';ErrorMessage='';ReadAtUtc=[datetime]::UtcNow.ToString('o')}) -State $call.State
        Expect ($script:Queued.Count -eq 1 -and [string]$script:Queued[0].Kind -eq 'SecretMeta' -and @($script:Queued[0].Row.Rows).Count -eq 2) 'Presence non enregistree pour les postes de l OU'
        Expect (@($script:Queued[0].Row.Rows|Where-Object{[string]$_.Verdict -eq 'aucune cle visible avec ce compte'}).Count -eq 2) 'Verdict sans cle visible'
        # Nothing visible in the OU: the zero never replaces a key count already read for the workstation (KeepKnown).
        Expect (@($script:Queued[0].Row.Rows|Where-Object{[bool]$_.KeepKnown}).Count -eq 2) 'Zero d une lecture sans objet visible non marque KeepKnown'
        Expect ($null -ne $call.State.PSObject.Properties['Generation']) 'Garde de selection des lectures de secrets absente'
        $script:Queued.Clear()
        Complete-DomeniaFleetBitLockerPresence -Result ([pscustomobject]@{Mode='BitLockerPresence';Success=$true;DN='OU=Postes,DC=example,DC=invalid';ClassPresent=$true;RecoveryObjectsFound=1;Truncated=$false;Computers=@([pscustomobject]@{DN='CN=PC-1,OU=Postes,DC=example,DC=invalid';Keys=1;Last='2026-09-01T00:00:00Z'});ErrorKind='';ErrorMessage='';ReadAtUtc=[datetime]::UtcNow.ToString('o')}) -State $call.State
        Expect (@($script:Queued[0].Row.Rows|Where-Object{[bool]$_.KeepKnown}).Count -eq 0) 'Lecture qui voit des cles : un poste sans cle est bien sans cle'
        Expect (@($script:Trace|Where-Object{$_ -like 'Aucune clé visible avec ce compte*'}).Count -ge 1) 'Message non lisible avec ce compte absent'
        $script:FleetScopeDn=''
    }
    Case 'Points d attention : un clic deplie les postes concernes sans lancer de tache' {
        $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid';$script:FleetStale=$false;$script:FleetJobId=''
        Complete-DomeniaFleetDashboard -Result (New-FleetResult -Scope 'OU=Postes,DC=example,DC=invalid') -State $null
        $rows=@(Get-DomeniaLogicalControls (Get-DomeniaControl 'PnlFleetDashboard')|Where-Object{$_ -is [Windows.Controls.Button] -and $_.Tag -is [hashtable] -and $_.Tag.ContainsKey('Details')})
        Expect ($rows.Count -ge 2) ('Lignes cliquables : '+$rows.Count)
        $stale=@($rows|Where-Object{[string]$_.Tag['Item'].Point -eq 'stale'})[0]
        Expect ($null -ne $stale) 'Point des postes inactifs absent'
        $before=$script:StartCalls.Count;$parks=$script:ParkCalls.Count
        $stale.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        $details=$stale.Tag['Details']
        Expect ($details.Visibility -eq [Windows.Visibility]::Visible) 'Postes non deplies'
        $texts=@(Get-DomeniaLogicalControls $details|Where-Object{$_ -is [Windows.Controls.TextBlock]}|ForEach-Object{[string]$_.Text})
        Expect (@($texts|Where-Object{$_ -like 'PC-2 · Postes · connexion 01/05/2026'}).Count -eq 1) ('Ligne du poste : '+($texts -join ' | '))
        Expect (@(Get-DomeniaLogicalControls $details|Where-Object{$_ -is [Windows.Controls.Button] -and [string]$_.Tag['Action'] -in @('CopyTargets','QueryTargets')}).Count -eq 2) 'Copier et Detailler les postes absents'
        Expect ($script:StartCalls.Count -eq $before -and $script:ParkCalls.Count -eq $parks) 'Tache lancee par le clic'
        $stale.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Expect ($details.Visibility -eq [Windows.Visibility]::Collapsed) 'Second clic ne replie pas'
        $script:FleetScopeDn=''
    }
    Case 'Points du poste : le lien ouvre la vue de l action utile (Intervenir, Secrets) sans rien lancer' {
        $data=New-DomeniaBoardData -Board Computer
        Add-DomeniaBoardAttention -Data $data -Level Warn -Text 'Pas de redemarrage depuis 40 jours.' -Point 'restart' -Route 'ComputerActions' -RouteText 'Redémarrer : vue Intervenir'
        Add-DomeniaBoardAttention -Data $data -Level Alert -Text 'Disque C: presque plein : 4 % libre.' -Point 'disk.c' -Route 'ComputerActions' -RouteText 'Ouvrir le disque C : vue Intervenir'
        Add-DomeniaBoardAttention -Data $data -Level Warn -Text 'BitLocker : Protection Desactive.' -Point 'secrets' -Route 'ComputerSecrets' -RouteText 'Vue Secrets du poste'
        $card=New-DomeniaAttentionCard -Items @($data.Attention) -Board 'Computer'
        $links=@(Get-DomeniaLogicalControls $card|Where-Object{$_ -is [Windows.Documents.Hyperlink]})
        Expect ($links.Count -eq 3) ('Liens des points : '+$links.Count)
        $inner=Get-DomeniaControl 'ComputerTabs'
        $inner.SelectedItem=Get-DomeniaControl 'TabComputer'
        $before=$script:StartCalls.Count;$parks=$script:ParkCalls.Count;$script:Workspaces.Clear()
        $disk=@($links|Where-Object{(New-Object Windows.Documents.TextRange($_.ContentStart,$_.ContentEnd)).Text -eq 'Ouvrir le disque C : vue Intervenir'})[0]
        Expect ($null -ne $disk) 'Lien Ouvrir le disque C absent'
        $disk.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Documents.Hyperlink]::ClickEvent))
        Expect ([string]$inner.SelectedItem.Name -eq 'TabComputerAdmin') ('Onglet ouvert : '+[string]$inner.SelectedItem.Name)
        Expect ([string](Get-DomeniaControl 'WorkspaceTabs').SelectedItem.Name -eq 'WsComputer') 'Assistance poste non ouverte'
        $secret=@($links|Where-Object{[string]$_.Tag -eq 'ComputerSecrets'})[0]
        $secret.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Documents.Hyperlink]::ClickEvent))
        Expect ([string]$inner.SelectedItem.Name -eq 'TabSecurity') ('Onglet Secrets non ouvert : '+[string]$inner.SelectedItem.Name)
        Expect (($script:Workspaces -join ',') -eq 'WsComputer/TabComputerAdmin,WsComputer/TabSecurity') ('Ecrans ouverts : '+($script:Workspaces -join ','))
        Expect ($script:StartCalls.Count -eq $before -and $script:ParkCalls.Count -eq $parks) 'Un lien a lance une tache'
        $inner.SelectedItem=Get-DomeniaControl 'TabComputer';(Get-DomeniaControl 'WorkspaceTabs').SelectedItem=Get-DomeniaControl 'WsSearch'
    }
    Case 'Poste hors de l OU : lecture canonique coalescée, invalidée après nouvelle vue' {
        $script:DatabaseScopedPath='C:\fictif\domenia.db';$script:FleetObservations=@{};$script:FleetSelectedReads=@{};$script:FleetScopeDn='';$script:StoreSnapshotRevision=10L
        $script:SelectedObject=[pscustomobject]@{DN='CN=PC-9,OU=Lyon,DC=example,DC=invalid';Type='Machine';Name='PC-9';Guid='00000000-0000-4000-8000-000000000009';Safety=[pscustomobject]@{Guid='00000000-0000-4000-8000-000000000009'}}
        $before=$script:StoreReadCalls.Count;$parks=$script:ParkCalls.Count
        Show-DomeniaBoard -Board Computer -Quiet
        Expect ($script:StoreReadCalls.Count -eq $before+1) 'Relevés du poste non demandés dans la base canonique'
        $call=$script:StoreReadCalls[$before]
        Expect ($call.Query.Kind -eq 'Observation' -and $call.Query.Limit -eq 1 -and @($call.Query.Guids)[0] -eq $script:SelectedObject.Guid -and $call.State.Path -ceq $script:DatabaseScopedPath) 'Lecture canonique mal paramétrée'
        Show-DomeniaBoard -Board Computer -Quiet
        Expect ($script:StoreReadCalls.Count -eq $before+1) 'Lecture répétée sans changement de sélection ni de révision'
        $recent=[datetime]::UtcNow.AddHours(-3).ToString('o')
        $obs=[pscustomobject]@{Guid=$script:SelectedObject.Guid;Revision=10L;CheckedUtc=$recent;Probes=[pscustomobject]@{'os.release'=[pscustomobject]@{Rows=@(,@('26100','1'));Count=1;Error='';CheckedUtc=$recent}}}
        $canonical=[pscustomobject]@{ObservationRows=@($obs);SnapshotRevision=10L;Busy=$false;Missing=$false;DataSource='SQLite';StoreId='boards-fixture';Path=$script:DatabaseScopedPath}
        Complete-DomeniaSelectedObservation -Result $canonical -State $call.State
        Expect (@(Get-DomeniaWidgetResults -Board Computer -ProbeId 'os.release').Count -eq 1) 'Relevé canonique absent du tableau du poste'
        Complete-DomeniaFleetDashboard -Result (New-FleetResult) -State $null
        Expect ($script:StoreReadCalls.Count -eq $before+2) 'Nouvelle vue nʼa pas invalidé le marqueur de lecture sélectionnée'
        Complete-DomeniaSelectedObservation -Result $canonical -State $script:StoreReadCalls[$before+1].State
        Expect (@(Get-DomeniaWidgetResults -Board Computer -ProbeId 'os.release').Count -eq 1) 'Relecture canonique non publiée'
        Expect ($script:ParkCalls.Count -eq $parks) 'La consultation a relancé une collecte réseau'
        $script:SelectedObject=$null;$script:DatabaseScopedPath='';$script:FleetObservations=$null;$script:StoreSnapshotRevision=0L
    }
    Case 'En-tete de l accueil : fil local et périmètre indépendant de Rechercher' {
        $script:FleetScopeDn='OU=Lyon,OU=Postes,DC=example,DC=invalid'
        Update-DomeniaFleetScopeText (Get-DomeniaFleetScope) -Count 2
        Expect ([string](Get-DomeniaControl 'LblFleetScope').Text -like '*2 postes recensé(s) dans la base*') 'Le nombre recensé en base est mal libelle'
        Expect ([string](Get-DomeniaControl 'LblFleetScope').ToolTip -like '*postes actifs et désactivés*') 'L infobulle doit préciser la population active'
        $links=@(Get-DomeniaLogicalControls (Get-DomeniaControl 'PnlFleetCrumbs')|Where-Object{$_ -is [Windows.Documents.Hyperlink]})
        Expect (($links.Count -eq 2) -and ([string]$links[0].Tag -eq 'OU=Postes,DC=example,DC=invalid') -and ([string]$links[1].Tag -eq 'OU=Lyon,OU=Postes,DC=example,DC=invalid')) ('Fil d OU : '+(@($links|ForEach-Object{[string]$_.Tag}) -join '|'))
        $script:SelectedBranchDn='OU=Recherche,DC=example,DC=invalid'
        $searchBefore=$script:SelectedBranchDn
        $tabs=Get-DomeniaControl 'WorkspaceTabs';$tabs.SelectedItem=Get-DomeniaControl 'TabDashboard'
        $before=$script:StartCalls.Count;$parks=$script:ParkCalls.Count;$script:Trace.Clear()
        $links[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Documents.Hyperlink]::ClickEvent))
        Expect ($script:FleetScopeDn -eq 'OU=Postes,DC=example,DC=invalid') 'OU parente non choisie dans le dashboard'
        Expect ($script:SelectedBranchDn -eq $searchBefore -and [string]$tabs.SelectedItem.Name -eq 'TabDashboard') 'Le fil local a modifie ou ouvert Rechercher'
        $links[1].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Documents.Hyperlink]::ClickEvent))
        Expect ($script:FleetScopeDn -eq 'OU=Lyon,OU=Postes,DC=example,DC=invalid') 'OU enfant non choisie dans le dashboard'
        Expect ($script:SelectedBranchDn -eq $searchBefore) 'La navigation locale a modifie le filtre Rechercher'
        $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid';$script:FleetStale=$false;$script:FleetJobId=''
        Complete-DomeniaFleetDashboard -Result (New-FleetResult -Scope 'OU=Postes,DC=example,DC=invalid') -State $null
        $script:ShownRows=$null
        function script:Show-ObjectRows {param($Rows,$Label,[switch]$SkipPresenceScan,[switch]$NoAutoOpen);$script:ShownRows=@($Rows)}
        function script:Stop-DomeniaLiveSearch {}
        function script:Invalidate-DomeniaSearchResults {$script:GlobalSearchGeneration=[int]$script:GlobalSearchGeneration+1;$script:ShownRows=$null}
        Show-DomeniaFleetAnalyzeSource
        Expect ((@($script:ShownRows).Count -eq 3) -and ((@($script:ShownRows|ForEach-Object{[string]$_.Name}|Sort-Object) -join ',') -eq 'PC-1,PC-2,PC-OFF')) ('Postes affiches : '+(@($script:ShownRows|ForEach-Object{[string]$_.Name}) -join ','))
        Expect (@($script:Trace|Where-Object{$_ -like '3 poste(s) de Postes dans Rechercher*'}).Count -ge 1) 'Consigne de Rechercher absente'
        # Whole domain: never listed this way.
        $script:FleetScopeDn='';$script:ShownRows=$null
        Complete-DomeniaFleetDashboard -Result (New-FleetResult) -State $null
        Show-DomeniaFleetAnalyzeSource
        Expect ($null -eq $script:ShownRows) 'Tout le domaine liste dans Rechercher'
        Expect ($script:StartCalls.Count -eq $before -and $script:ParkCalls.Count -eq $parks) 'Une tache a ete lancee par l en-tete'
        (Get-DomeniaControl 'WorkspaceTabs').SelectedItem=Get-DomeniaControl 'WsSearch'
    }
    Case 'Annuler une disposition survit a un recalcul de fond, pile d annulation et Ctrl+Z' {
        $script:FleetScopeDn=''
        Complete-DomeniaFleetDashboard -Result (New-FleetResult) -State $null
        $before=(ConvertTo-DomeniaBoardLayoutJson -Layout (Get-Layout Fleet))
        $target=@(Get-Layout Fleet|Where-Object{$_.Key -eq 'fleet.os'})[0]
        Invoke-DomeniaBoardAction -Tag @{Board='Fleet';Id=[string]$target.Id;Action='Remove'}
        Invoke-DomeniaBoardAction -Tag @{Board='Fleet';Id=[string]@(Get-Layout Fleet|Where-Object{$_.Key -eq 'fleet.ou'})[0].Id;Action='Size';Value='L'}
        Expect ([string](Get-DomeniaBoardState 'Fleet').UndoText -eq 'Taille changee') 'Annulation non proposee'
        Complete-DomeniaFleetDashboard -Result (New-FleetResult) -State $null
        Expect ([string](Get-DomeniaBoardState 'Fleet').UndoText -eq 'Taille changee') 'Annulation retiree par un recalcul de fond'
        Expect ((Get-DomeniaBoardState 'Fleet').UndoStack.Count -eq 2) 'Pile d annulation incomplete'
        $panel=Get-DomeniaControl 'PnlFleetDashboard'
        Expect ($panel.Tag -is [hashtable] -and [bool]$panel.Tag['UndoKey']) 'Ctrl+Z non branche sur le tableau'
        Invoke-DomeniaBoardAction -Tag @{Board='Fleet';Action='Undo'}
        Invoke-DomeniaBoardAction -Tag @{Board='Fleet';Action='Undo'}
        Expect ((ConvertTo-DomeniaBoardLayoutJson -Layout (Get-Layout Fleet)) -eq $before) 'Deux annulations ne retablissent pas la disposition'
        Expect ((Get-DomeniaBoardState 'Fleet').UndoStack.Count -eq 0) 'Pile non videe'
        Clear-DomeniaDashboards
        Expect ((Get-DomeniaBoardState 'Fleet').UndoStack.Count -eq 0) 'Pile du parc touchee par le changement d objet'
    }
    Case 'Actions explicites du parc depuis les vues locales' {
        $layout=@(Get-Layout Fleet)
        Set-DomeniaBoardLayout -Board Fleet -Layout @(Add-DomeniaBoardItem -Layout $layout -Item (New-DomeniaBoardItem -Source Probe -Key 'os.release' -Visual 'Pie' -Group 'Systeme'))
        $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid';$script:FleetStale=$false;$script:FleetJobId=''
        Complete-DomeniaFleetDashboard -Result (New-FleetResult -Scope $script:FleetScopeDn) -State $null
        $script:ParkCalls.Clear();Start-DomeniaWidgetProbe -Board Fleet
        Expect ($script:ParkCalls.Count -eq 1) 'La collecte explicite du tableau ne part pas'
        Expect (-not $script:ParkCalls[0].Displayed -and @($script:ParkCalls[0].Targets).Count -eq 2) 'La collecte ne cible pas les deux postes actifs locaux'
        Expect ((@($script:ParkCalls[0].Targets|ForEach-Object{$_.name}|Sort-Object) -join ',') -eq 'PC-1,PC-2') 'Identites de collecte incorrectes'
        Expect (@($script:ParkCalls[0].Probes|Where-Object{$_.Id -eq 'os.release'}).Count -eq 1) 'La sonde du widget manque'
        $script:ParkCalls.Clear();Start-DomeniaParkAnalysis
        Expect ($script:ParkCalls.Count -eq 1 -and $script:ParkCalls[0].Displayed -and $script:ParkCalls[0].Inventory) 'Analyser la liste : mauvais mode'
        Expect (@($script:ParkCalls[0].Probes|Where-Object{[string]$_.Id -eq 'os.release'}).Count -eq 1) 'Requete du widget absente de l analyse'
        # A result computed for another OU is not shown.
        $script:FleetPendingKey='ou=autre,dc=example,dc=invalid|Subtree'
        $before=$script:FleetLast
        Complete-DomeniaFleetDashboard -Result (New-FleetResult) -State ([pscustomobject]@{Epoch=1L;Key='*';Scope='';Subtree=$true})
        Expect ([object]::ReferenceEquals($before,$script:FleetLast)) 'Resultat d une autre OU affiche'
        $script:FleetPendingKey=''
    }
    Case 'Accueil : calcul seulement a l affichage, un a la fois, repris si les donnees changent ou si le calcul est perdu' {
        $script:DatabaseScopedPath='C:\fictif\domenia.db';$script:StartCalls.Clear();$script:AsyncJobs=@{}
        $script:FleetComputedKey='';$script:FleetPendingKey='';$script:FleetJobId='';$script:FleetStale=$false
        $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid'
        $tabs=Get-DomeniaControl 'WorkspaceTabs'
        $tabs.SelectedItem=Get-DomeniaControl 'WsSearch'
        Request-DomeniaFleetRefresh -Force
        Expect ($script:StartCalls.Count -eq 0) 'Calcul lance alors que l accueil est masque'
        $tabs.SelectedItem=Get-DomeniaControl 'TabDashboard'
        Request-DomeniaFleetRefresh
        Expect ($script:StartCalls.Count -eq 1) ('Calculs : '+$script:StartCalls.Count)
        $call=$script:StartCalls[0]
        Expect ([string]$call.Payload.Scope -eq 'OU=Postes,DC=example,DC=invalid' -and [bool]$call.Payload.Subtree -and [string]$call.ReplaceKey -eq 'fleet:stats' -and [string]$call.TaskClass -eq 'Background') 'Calcul automatique mal parametre'
        $script:AsyncJobs['job-1']=$true
        Request-DomeniaFleetRefresh;Request-DomeniaFleetRefresh -Force
        Expect ($script:StartCalls.Count -eq 1) 'Calcul relance pendant le calcul de la meme OU'
        $previousFleet=$script:FleetLast;$previousScopeText=[string](Get-DomeniaControl 'LblFleetScope').Text
        Complete-DomeniaFleetDashboard -Result (New-FleetResult -Scope 'OU=Postes,DC=example,DC=invalid') -State $call.State
        $script:AsyncJobs.Remove('job-1')
        Expect ([string]$script:FleetComputedKey -eq '' -and [object]::ReferenceEquals($previousFleet,$script:FleetLast) -and [string](Get-DomeniaControl 'LblFleetScope').Text -eq $previousScopeText) 'Un resultat anterieur au commit a remplace les dates ou les chiffres affiches'
        Expect ($script:StartCalls.Count -eq 2) 'Donnees changees pendant le calcul non recalculees'
        Complete-DomeniaFleetDashboard -Result (New-FleetResult -Scope 'OU=Postes,DC=example,DC=invalid') -State $script:StartCalls[1].State
        Expect ([string]$script:FleetComputedKey -eq 'ou=postes,dc=example,dc=invalid|Subtree') ('Cle calculee : '+$script:FleetComputedKey)
        Request-DomeniaFleetRefresh
        Expect ($script:StartCalls.Count -eq 2) 'Recalcul sans changement'
        # Dashboard-local scope line and clickable OU path.
        Expect ([string](Get-DomeniaControl 'LblFleetScope').Text -like ' · et ses sous-OU · 3 postes recensé(s)*') ('Perimetre affiche : '+[string](Get-DomeniaControl 'LblFleetScope').Text)
        $crumbs=@(Get-DomeniaLogicalControls (Get-DomeniaControl 'PnlFleetCrumbs')|Where-Object{$_ -is [Windows.Controls.TextBlock]}|ForEach-Object{(New-Object Windows.Documents.TextRange($_.ContentStart,$_.ContentEnd)).Text})
        Expect ($crumbs -contains 'Postes') ('Fil d OU : '+($crumbs -join '|'))
        # Another OU: computed; a lost calculation (cancelled, never answered) is tried again at the next display.
        $script:FleetScopeDn='OU=Serveurs,DC=example,DC=invalid'
        Request-DomeniaFleetRefresh
        Expect ($script:StartCalls.Count -eq 3 -and [bool]$script:StartCalls[2].Payload.Subtree) 'Le périmètre local doit inclure les sous-OU'
        Request-DomeniaFleetRefresh
        Expect ($script:StartCalls.Count -eq 4) 'Calcul perdu jamais repris'
        $observations=@{'cn=pc-1,ou=postes,dc=example,dc=invalid'=[pscustomobject]@{CheckedUtc='2026-10-08T10:00:00.0000000Z';Presence='En ligne'}}
        $merged=Merge-DomeniaFleetObservations -Stored @{'cn=pc-1,ou=postes,dc=example,dc=invalid'=[pscustomobject]@{CheckedUtc='2026-10-08T09:00:00.0000000Z';Presence='Sans reponse'}} -Current $observations
        Expect ([string]$merged['cn=pc-1,ou=postes,dc=example,dc=invalid'].Presence -eq 'En ligne') 'Observation recente remplacee par la base'
        $tabs.SelectedItem=Get-DomeniaControl 'WsSearch'
        $script:DatabaseScopedPath='';$script:FleetPendingKey='';$script:FleetJobId=''
    }
    Case 'P-CD-09 : Accueil non recalculable, la vue le dit et ne se presente pas comme a jour' {
        $script:DatabaseScopedPath='C:\fictif\domenia.db';$script:StartCalls.Clear();$script:AsyncJobs=@{}
        $script:FleetComputedKey='';$script:FleetPendingKey='';$script:FleetJobId='';$script:FleetStale=$true
        $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid'
        $tabs=Get-DomeniaControl 'WorkspaceTabs'
        $tabs.SelectedItem=Get-DomeniaControl 'TabDashboard'
        # Preparation of the request in failure (local doubles of this case only).
        function Get-DomeniaFleetQueryPlan { throw 'plan de lecture impossible (simulation)' }
        # The automatic request does not rethrow: its failure must still reach the technical trace.
        $traces=New-Object 'System.Collections.Generic.List[object]'
        function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) $traces.Add([pscustomobject]@{Category=[string]$Category;Operation=[string]$Operation;Error=$ErrorRecord}) }
        Request-DomeniaFleetRefresh
        $label=[string](Get-DomeniaControl 'LblFleetDashboard').Text
        Expect ($script:StartCalls.Count -eq 0) 'Calcul lance malgre une preparation en echec'
        Expect ($label -like 'Vue dʼensemble non calculée : plan de lecture impossible*') ('Libelle : '+$label)
        $startTraces=@($traces|Where-Object{($_.Category -eq 'Dashboard') -and ($_.Operation -eq 'Start-DomeniaFleetDashboard')})
        Expect ($startTraces.Count -eq 1) ('Echec automatique non trace : '+$traces.Count+' trace(s)')
        Expect ([string]$startTraces[0].Error.Exception.Message -match 'plan de lecture impossible') 'La trace ne porte pas l erreur de preparation'
        # Failure before the calculation is chosen: the caller still receives the error, the view says it is not current.
        function Get-DomeniaFleetScope { throw 'perimetre illisible (simulation)' }
        $raised='';try{Request-DomeniaFleetRefresh -Force}catch{$raised=$_.Exception.Message}
        $label=[string](Get-DomeniaControl 'LblFleetDashboard').Text
        Expect ($raised -match 'perimetre illisible') 'L erreur n est plus rendue a l appelant'
        Expect ($label -like 'Vue dʼensemble non actualisée : perimetre illisible*') ('Libelle : '+$label)
        Expect ([bool]$script:FleetStale) 'La vue n est pas marquee a recalculer'
        $tabs.SelectedItem=Get-DomeniaControl 'WsSearch'
        $script:DatabaseScopedPath='';$script:FleetPendingKey='';$script:FleetJobId=''
    }
    Case 'Widget de requete en attente : etat explicite, puis rempli par un resultat' {
        $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid';$script:FleetStale=$false;$script:FleetJobId=''
        Complete-DomeniaFleetDashboard -Result (New-FleetResult -Scope $script:FleetScopeDn) -State $null
        $item=New-DomeniaBoardItem -Source Probe -Key 'os.release' -Visual Bar -Size M
        $oldQueryState=$script:DomeniaQueryState
        try{
            $script:DomeniaQueryState=[pscustomobject]@{SnapshotKey=[string]$script:FleetQuerySnapshotKey;ProbeWidgets=@{};Busy=$true;Bound=$false;Saved=@()}
            $pending=Resolve-DomeniaBoardEntry -Board Fleet -Item $item -State (Get-DomeniaBoardState 'Fleet')
            Expect ([string]$pending.Entry.State -eq 'Off' -and [string]$pending.Entry.Detail -like '*en arrière-plan*') 'Attente du calcul local non explicite'
            $script:DomeniaQueryState.ProbeWidgets=Measure-DomeniaFleetProbeEntries -Fleet $script:FleetLast -Observations @{} -Requests @($item)
            $pending=Resolve-DomeniaBoardEntry -Board Fleet -Item $item -State (Get-DomeniaBoardState 'Fleet')
            Expect ([string]$pending.Entry.State -eq 'Off' -and [string]$pending.Entry.Detail -like '*Relever*tableau de bord*') 'Mesure manquante non expliquee apres calcul'
            $recent=[datetime]::UtcNow.AddHours(-2).ToString('o')
            $script:FleetObservations=@{
                'cn=pc-1,ou=postes,dc=example,dc=invalid'=[pscustomobject]@{Guid='00000000-0000-4000-8000-000000000001';CheckedUtc=$recent;Probes=[pscustomobject]@{'os.release'=[pscustomobject]@{Rows=@(,@('26100','1'));Count=1;Error='';CheckedUtc=$recent}}}
                'cn=pc-2,ou=postes,dc=example,dc=invalid'=[pscustomobject]@{Guid='00000000-0000-4000-8000-000000000002';CheckedUtc=$recent;Probes=[pscustomobject]@{'os.release'=[pscustomobject]@{Rows=@(,@('19045','1'));Count=1;Error='';CheckedUtc=$recent}}}
            }
            $script:DomeniaQueryState.ProbeWidgets=Measure-DomeniaFleetProbeEntries -Fleet $script:FleetLast -Observations $script:FleetObservations -Requests @($item)
            $filled=Resolve-DomeniaBoardEntry -Board Fleet -Item $item -State (Get-DomeniaBoardState 'Fleet')
            Expect ([string]$filled.Entry.Kind -eq 'Distribution' -and @($filled.Entry.Items).Count -eq 2) ('Repartition : '+$filled.Entry.Kind+' '+@($filled.Entry.Items).Count)
            Expect ([string]$filled.Entry.Detail -like '*2 postes analysés sur 2*') ('Couverture : '+[string]$filled.Entry.Detail)
            $script:FleetObservations['cn=pc-2,ou=postes,dc=example,dc=invalid'].Guid='00000000-0000-4000-8000-000000000099'
            Expect (@(Get-DomeniaWidgetResults -Board Fleet -ProbeId 'os.release').Count -eq 1) 'Observation d un poste recree comptee'
            $script:FleetObservations['cn=pc-1,ou=postes,dc=example,dc=invalid'].Probes.'os.release'.CheckedUtc=[datetime]::UtcNow.AddDays(-40).ToString('o')
            Expect (@(Get-DomeniaWidgetResults -Board Fleet -ProbeId 'os.release').Count -eq 0) 'Observation de sonde de plus de 30 jours comptee'
            $script:FleetObservations['cn=pc-1,ou=postes,dc=example,dc=invalid'].Probes.'os.release'.CheckedUtc=[datetime]::UtcNow.AddDays(-10).ToString('o')
            $script:DomeniaQueryState.ProbeWidgets=Measure-DomeniaFleetProbeEntries -Fleet $script:FleetLast -Observations $script:FleetObservations -Requests @($item)
            $grey=Resolve-DomeniaBoardEntry -Board Fleet -Item $item -State (Get-DomeniaBoardState 'Fleet')
            Expect ([string]$grey.Entry.State -eq 'Off') 'Observation de plus de 7 jours non grisee'
        }finally{$script:DomeniaQueryState=$oldQueryState}
    }
    Case 'Details de la session : non recalcules expander ferme, a jour a l ouverture' {
        $coreAst=Parse-Text ([IO.File]::ReadAllText((Join-Path $wad 'Domenia-Core.ps1')))
        foreach($n in @('Update-Dashboard')){Import-Function $coreAst $n}
        $updateTask=@($coreAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Update-TaskUi'},$true))[0].Extent.Text
        Expect ($updateTask -match "UxSessionDetails'\]\.IsExpanded" -and $updateTask -match 'if \(\$sessionDetailsOpen\) \{ Request-DomeniaDashboardRefresh \} else \{ \$script:DashboardDirty = \$true \}') 'Update-TaskUi recalcule toujours les details masques'
        $savedControls=$script:Ctrl;$script:Ctrl=@{};foreach($n in @('UxSessionDetails','TxtDashDomain','TxtDashServer','TxtDashUser','TxtDashMode','TxtDashBaseDn','TxtDashBranch','TxtDashRows','TxtDashModule','TxtDashStats','TxtDashSelected','TxtDashRights','TxtDashTasks','TxtDashCache','TxtDashSelfCheck','TxtDashLinks')){$script:Ctrl[$n]=Get-DomeniaControl $n}
        function script:Get-ObjectsStatsText {param($Rows);$script:StatsCalls++;return 'stats fictives'}
        function script:Test-DomeniaAdCommandsAvailable {return $false}
        function script:Get-AssociationStatsText {return ''}
        $script:StatsCalls=0;$script:BranchObjects=@();$script:CurrentCapabilities=@{};$script:VisitCache=@{};$script:DashboardAdModuleCheckedAt=$null
        $expander=$script:Ctrl['UxSessionDetails'];$expander.IsExpanded=$false
        $script:Ctrl['TxtDashStats'].Text='avant'
        Update-Dashboard
        Expect ($script:StatsCalls -eq 0 -and [string]$script:Ctrl['TxtDashStats'].Text -eq 'avant') 'Details recalcules expander ferme'
        Expect ([bool]$script:SessionDetailsDirty) 'Details non marques a refaire'
        $expander.IsExpanded=$true
        Update-Dashboard -Force
        Expect ($script:StatsCalls -eq 1 -and [string]$script:Ctrl['TxtDashStats'].Text -eq 'stats fictives') 'Details non mis a jour a l ouverture'
        $expander.IsExpanded=$false;$script:Ctrl=$savedControls
    }
    Case 'RC11711 : dates des sources, jamais celles du dessin ou de la tentative en echec' {
        $at=[datetime]::UtcNow.AddDays(-2);$later=$at.AddHours(3)
        $rows=@([pscustomobject]@{Source='AD';OldestUtc=$at;NewestUtc=$at;LastAttemptUtc=[datetime]::UtcNow;Error='Timeout'},[pscustomobject]@{Source='WMI';OldestUtc=$at;NewestUtc=$later;Missing=2})
        $dates=Format-DomeniaWidgetDataDates -Rows $rows
        Expect ($dates.Text.Contains($at.ToLocalTime().ToString('dd/MM/yyyy HH:mm'))) 'Date de succes perdue'
        Expect ($dates.Text.Contains($later.ToLocalTime().ToString('dd/MM/yyyy HH:mm')) -and $dates.Text.Contains('WMI') -and $dates.Text.Contains('AD') -and $dates.Text.Contains('2 non lu')) 'Plage ou source perdue'
        $unknown=Format-DomeniaWidgetDataDates -Rows @([pscustomobject]@{Source='Ping';OldestUtc=[datetime]::UtcNow.AddDays(1);NewestUtc=[datetime]::UtcNow.AddDays(1)})
        Expect ($unknown.Text -like '*non dat*') 'Date future acceptee'
        $state=@{DataAtUtc=[datetime]::UtcNow;Data=[pscustomobject]@{Freshness=[pscustomobject]@{Index=[pscustomobject]@{At=$at}}}}
        $item=New-DomeniaBoardItem -Source Builtin -Key fleet.machines -Visual Kpi -Size S
        $stamp=Get-DomeniaWidgetDataDates -Board Fleet -Item $item -State $state -Entry $null
        Expect ($stamp.Text -eq ('AD '+[char]0x00B7+' '+$at.ToLocalTime().ToString('dd/MM/yyyy HH:mm'))) 'Date de dessin utilisee a la place de AD'
    }
    Case 'RC11711 : bouton permanent du widget, accessible et relie a la collecte' {
        $item=New-DomeniaBoardItem -Source Builtin -Key fleet.machines -Visual Kpi -Size S
        $state=Get-DomeniaBoardState Fleet;$state.Editing=$false
        $holder=New-DomeniaBoardWidget -Board Fleet -Item $item -State $state -Width 250 -Placeholder
        $footer=@($holder.Children|Where-Object{[Windows.Controls.Grid]::GetRow($_) -eq 3})[0]
        $button=$footer.Children[0];$label=$footer.Children[1]
        Expect ($button.Visibility -eq 'Visible' -and $button.Opacity -eq 1 -and $button.IsEnabled) 'Bouton masque hors survol'
        Expect ([Windows.Automation.AutomationProperties]::GetName($button) -like 'Relire les donn*') 'Nom accessible absent'
        Expect ($label.Text -like 'AD*') 'Source absente'
        $script:WidgetClicked=''
        function Start-DomeniaWidgetRefresh {param($Board,$Id,$Reason) $script:WidgetClicked=$Board+'|'+$Id+'|'+$Reason;return $true}
        $button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Expect ($script:WidgetClicked -eq ('Fleet|'+$item.Id+'|Refresh')) 'Le bouton ne relit pas la source'
        $holder.Measure([Windows.Size]::new(250,1000));$holder.Arrange([Windows.Rect]::new(0,0,250,$holder.DesiredSize.Height));$holder.UpdateLayout()
        Expect ($footer.ActualWidth -le 250) 'Provenance hors de la largeur compacte'
    }
    Case 'RC11711 : synthese du parc relit AD puis ses mesures, sans collection etrangere' {
        $item=New-DomeniaBoardItem -Source Builtin -Key fleet.health -Visual Health -Size M
        $script:TestSettings['Dashboard.Fleet.Layout']=ConvertTo-DomeniaBoardLayoutJson @($item)
        $old=$script:DomeniaOuRefresh
        try {
            $script:DomeniaOuRefresh=$null;$script:WidgetRefreshNeed=$null
            function Invoke-DomeniaOuRefresh {param($Source,$Mode,$WidgetId,$WidgetNeed) $script:WidgetRefreshNeed=$WidgetNeed;$script:WidgetRefreshMode=$Mode;$script:DomeniaOuRefresh=[pscustomobject]@{Id='widget-health';Completed=$false;WidgetId=$WidgetId}}
            Expect (Start-DomeniaWidgetRefresh -Board Fleet -Id $item.Id -Reason Refresh) 'Synthese non relue'
            Expect ($script:WidgetRefreshMode -eq 'Both' -and $script:WidgetRefreshNeed.Directory -and $script:WidgetRefreshNeed.Inventory -and $script:WidgetRefreshNeed.Ping) 'Simple recalcul au lieu des sources'
            Expect (@($script:WidgetRefreshNeed.ProbeIds).Count -eq 0) 'Sondes etrangeres ajoutees'
        } finally {$script:DomeniaOuRefresh=$old;[void]$script:TestSettings.Remove('Dashboard.Fleet.Layout')}
    }
    Case 'RC11711 : apres AD le lot relit uniquement les mesures du widget avec ForceRefresh' {
        $refreshAst=Parse-Text ([IO.File]::ReadAllText((Join-Path $wad 'modules\Domenia-Refresh.UI.ps1')))
        Import-Function $refreshAst 'Complete-DomeniaOuRefreshTargets'
        $old=$script:DomeniaOuRefresh
        try {
            function Test-DomeniaOuRefreshCurrent {param($Id) return $true}
            function Update-DomeniaOuRefreshUi {}
            function Fail-DomeniaOuRefresh {param($OperationId,$Message) throw $Message}
            $script:DomeniaOuRefresh=[pscustomobject]@{Id='widget-plan';Epoch=1L;Path='fixture';Dn='OU=A,DC=example,DC=invalid';Phase='Resolving';Status='';Label='A';Mode='Both';WidgetId='w-date';WidgetNeed=[pscustomobject]@{Ping=$false;Inventory=$true;Console=$false};Probes=@();ParkRunId=''}
            $result=[pscustomobject]@{Targets=@([pscustomobject]@{name='PC-A';object_guid='00000000-0000-4000-8000-000000000001';distinguished_name='CN=PC-A,OU=A,DC=example,DC=invalid'});Busy=$false;Missing=$false;Scope=$script:DomeniaOuRefresh.Dn;Subtree=$true}
            $state=[pscustomobject]@{OperationId='widget-plan';Epoch=1L;Path='fixture';Dn=$script:DomeniaOuRefresh.Dn}
            $script:ParkCalls.Clear()
            Complete-DomeniaOuRefreshTargets -Result $result -State $state
            Expect ($script:ParkCalls.Count -eq 1) 'Lot non lance apres AD'
            $call=$script:ParkCalls[0]
            Expect ($call.Force -and $call.WmiOnly -and $call.Inventory -and $call.NoConsole -and @($call.Probes|Where-Object{$null -ne $_}).Count -eq 0 -and $call.WidgetIds[0] -eq 'w-date') 'Lot non cible ou cache reutilise'
        } finally {$script:DomeniaOuRefresh=$old;foreach($run in (Get-DomeniaParkRuns).Values){$run.Completed=$true}}
    }
    Case 'Premiers pas : le calcul de la vue part au clic, echec et OU vide recuperables sans scan' {
        $script:FleetScopeDn='';$script:IndexDbCount=0;$script:RemoteAdminCredential=$null
        $script:DatabaseScopedPath='';$script:FleetJobId='';$script:FleetPendingKey='';$script:FleetStale=$false
        if($null -ne $script:DomeniaQueryState.Timer){$script:DomeniaQueryState.Timer.Stop()}
        $savedConn=$script:Conn
        $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid';Server='dc.example.invalid';Domain='example.invalid';Netbios='EXAMPLE';Connected=$true;BindUser='EXAMPLE\agent'}
        $script:TestSettings['Home.FirstStepsDone']=$false;$script:TestSettings['Home.DashboardSeen']=''
        Update-DomeniaFirstSteps
        $card=Get-DomeniaControl 'CardFirstSteps'
        Expect ($card.Visibility -eq [Windows.Visibility]::Visible) 'Carte Premiers pas masquee au premier lancement'
        Expect ($card.Parent.Children.IndexOf($card) -lt $card.Parent.Children.IndexOf((Get-DomeniaControl 'PnlFleetDashboard'))) 'Assistant de premiere configuration apres les widgets'
        Expect ([string](Get-DomeniaControl 'LblFirstStepConnectionMark').Text -eq [string][char]0x2713) 'Connexion de la session non reconnue'
        Expect ([string](Get-DomeniaControl 'LblFirstStepConnection').Text -ceq ('Connecté à example.invalid avec EXAMPLE\agent.')) ([string](Get-DomeniaControl 'LblFirstStepConnection').Text)
        Expect (-not (Get-DomeniaControl 'BtnFirstStepDashboard').IsEnabled) 'Tableau de bord propose avant la premiere lecture'
        Expect ([string](Get-DomeniaControl 'LblFirstStepsDeferred').Text -like 'Plus tard*Comptes et accès*Stockage*') 'Options rares non reportees a leur usage'
        foreach($gone in @('BtnFirstStepAccount','BtnFirstStepBackup')){Expect ($null -eq (Get-DomeniaControl $gone)) ('Etape rare encore dans la carte : '+$gone)}
        $before=$script:StartCalls.Count;$parks=$script:ParkCalls.Count;$script:Workspaces.Clear()
        $script:SelectedBranchDn='OU=Recherche,DC=example,DC=invalid';$searchBefore=$script:SelectedBranchDn
        $trial=Invoke-EditorTrial -Open {Open-DomeniaFirstStep -Step 'Ou'} -Act {
            param($controls,$trial)
            $search=@($controls|Where-Object{$_.Name -eq 'EmbeddedObjectSearch'})[0]
            Expect ($null -ne $search) 'Vrai selecteur OU absent'
            $lookup=$script:StartCalls[$script:StartCalls.Count-1]
            Expect ($lookup.OperationId -eq 'EmbeddedDirectoryLookup' -and $lookup.Payload.Mode -eq 'Children' -and -not $lookup.Payload.Verify) 'Recherche OU non explicite'
            $row=[pscustomobject]@{Type='OU';Name='Postes';Second='';Description='Fixture';DN='OU=Postes,DC=example,DC=invalid';Guid='00000000-0000-4000-8000-000000000100'}
            Complete-DomeniaEmbeddedLookup -Result ([pscustomobject]@{Rows=@($row);RequestId=$lookup.State.RequestId;Verified=$false;Capped=$false}) -State $lookup.State
            $grid=@($controls|Where-Object{$_.Name -eq 'EmbeddedObjectResults'})[0];$grid.Items[0].Items[0].IsSelected=$true
            $accept=@($controls|Where-Object{$_.Name -eq 'EmbeddedObjectAccept'})[0]
            Expect $accept.IsEnabled 'Choisir reste desactive'
            $accept.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            $verify=$script:StartCalls[$script:StartCalls.Count-1]
            Expect ($verify.OperationId -eq 'EmbeddedDirectoryLookup' -and $verify.Payload.Verify) 'OU choisie sans verification d identite'
            Complete-DomeniaEmbeddedLookup -Result ([pscustomobject]@{Rows=@($row);RequestId=$verify.State.RequestId;Verified=$true;Capped=$false}) -State $verify.State
        }
        Expect $trial.Trial.Done 'Selecteur non termine'
        $rootChoice=Get-DomeniaRootOuChoice
        Expect (($null -ne $rootChoice) -and ($rootChoice.Dn -eq 'OU=Postes,DC=example,DC=invalid') -and ((Get-DomeniaFleetScope).Dn -eq 'OU=Postes,DC=example,DC=invalid') -and ($script:SelectedBranchDn -eq $searchBefore)) 'OU racine non enregistree, ou Rechercher ecrase'
        foreach($step in @('Base','Connection')){Open-DomeniaFirstStep -Step $step}
        Expect ($script:StartCalls.Count -eq $before+2 -and $script:ParkCalls.Count -eq $parks) ('Une etape a lance une tache autre que la selection OU explicite : '+(@($script:StartCalls|Select-Object -Skip $before|ForEach-Object{$_.OperationId}) -join ','))
        Expect (($script:Workspaces -join ',') -eq 'TabApplicationTools/TabIndex,route:TabAccounts') ('Ecrans ouverts : '+($script:Workspaces -join ','))
        $script:DatabaseScopedPath='C:\fictif\domenia.db';$script:IndexDbCount=12;$script:DomeniaFirstDashboard=$null
        Update-DomeniaFirstSteps
        Expect ((Get-DomeniaControl 'BtnFirstStepDashboard').IsEnabled) 'Le clic du tableau de bord est indisponible apres la premiere lecture'
        Expect ($script:StartCalls.Count -eq $before+2) 'La carte lance encore le calcul'
        Open-DomeniaFirstStep Dashboard
        Expect ($script:StartCalls.Count -eq $before+3 -and $script:StartCalls[$script:StartCalls.Count-1].OperationId -eq 'LocalIndexRead') 'Le clic ne lance pas le calcul local'
        Update-DomeniaFirstSteps
        Expect ($script:StartCalls.Count -eq $before+3) 'Le calcul est relance sans clic'
        Fail-DomeniaFleetDashboard -Message 'Erreur de calcul fixture' -State $script:StartCalls[$script:StartCalls.Count-1].State
        Expect ($script:DomeniaFirstDashboard.Phase -eq 'Error' -and (Get-DomeniaControl 'BtnFirstStepDashboard').Content -eq 'Réessayer lʼactualisation') 'Erreur masquee ou aucun reessai'
        Expect (-not [bool]$script:TestSettings['Home.FirstStepsDone']) 'Assistant termine en echec'
        Open-DomeniaFirstStep Dashboard
        Expect ($script:StartCalls.Count -eq $before+4 -and $script:DomeniaFirstDashboard.Phase -eq 'Loading') 'Reessai non lance'
        Complete-DomeniaFirstDashboard -ScopeKey 'autre-ou' -Count 12
        Expect ($script:DomeniaFirstDashboard.Phase -eq 'Loading') 'Autre OU acceptée'
        Complete-DomeniaFirstDashboard -ScopeKey ([string](Get-DomeniaFleetScope).Key) -Count 0
        Update-DomeniaFirstSteps
        Expect ($script:DomeniaFirstDashboard.Phase -eq 'Error' -and (Get-DomeniaControl 'LblFirstStepDashboard').Text -match 'Aucun poste') 'OU vide proposee comme prete'
        $script:FleetJobId='';$script:FleetPendingKey=''
        Open-DomeniaFirstStep Dashboard
        Expect ($script:StartCalls.Count -eq $before+5) 'OU vide : reessai non lance'
        Complete-DomeniaFirstDashboard -ScopeKey ([string](Get-DomeniaFleetScope).Key) -Count 12
        Update-DomeniaFirstSteps
        Expect ((Get-DomeniaControl 'BtnFirstStepDashboard').IsEnabled) 'Tableau de bord non propose apres son calcul'
        Expect ([string](Get-DomeniaControl 'LblFirstStepBase').Text -like 'Première lecture faite : 12 objet(s)*') ([string](Get-DomeniaControl 'LblFirstStepBase').Text)
        Expect ($card.Visibility -eq [Windows.Visibility]::Visible) 'Carte masquee avant la decouverte du tableau de bord'
        Open-DomeniaFirstStep Dashboard
        Expect (($script:Workspaces -join ',') -eq 'TabApplicationTools/TabIndex,route:TabAccounts,route:TabDashboard') 'Navigation absente apres preparation'
        Expect ($script:ParkCalls.Count -eq $parks) 'Scan reseau lance pendant le calcul local'
        Update-DomeniaFirstSteps
        Expect ($card.Visibility -eq [Windows.Visibility]::Collapsed) 'Carte encore affichee apres les quatre etapes'
        Expect ([bool]$script:TestSettings['Home.FirstStepsDone']) 'Preference locale non enregistree'
        $script:FleetScopeDn='';$script:IndexDbCount=0;$script:Conn=$savedConn;$script:TestSettings.Remove('Home.DashboardSeen')
    }
    Case 'Anciens widgets repris une fois dans la disposition' {
        $script:TestSettings.Remove('Dashboard.Computer.Layout')
        $script:TestSettings['Widgets.Computer']='[{"Id":"c1","ProbeId":"net.dns","Visual":"Text","Title":"Serveur DNS"}]'
        $layout=@(Get-Layout Computer)
        Expect (@($layout|Where-Object{$_.Source -eq 'Probe' -and $_.Key -eq 'net.dns' -and $_.Group -eq 'Reseau'}).Count -eq 1) 'Ancien widget non repris'
        Set-DomeniaBoardLayout -Board Computer -Layout $layout
        Expect (-not (Get-DomeniaSetting 'Widgets.Computer' '')) 'Ancien reglage non vide apres reprise'
        Expect (@(Get-Layout Computer|Where-Object{$_.Source -eq 'Probe'}).Count -eq 1) 'Doublon apres reprise'
    }
    # Lot L06: gauge, tiles, bars and columns drawn in a window of their own (same palette), then the workstation board.
    function Show-InTestWindow {param($Element)
        $tw=[Windows.Window]::new();$tw.Width=900;$tw.Height=600;$tw.ShowInTaskbar=$false
        foreach($k in @('BgCard','BorderColor','TextColor','MutedColor','AccentColor','AccentSoft','WindowBg','StatusWarning','StatusError','StatusSuccess')){$tw.Resources[$k]=$w.Resources[$k]}
        $host_=[Windows.Controls.WrapPanel]::new();$tw.Content=$host_;[void]$host_.Children.Add($Element);$tw.Show();$tw.UpdateLayout();return $tw
    }
    function Get-Texts {param($Root);return @(Get-DomeniaLogicalControls $Root|Where-Object{$_ -is [Windows.Controls.TextBlock]})}
    Case 'Jauge : legende bornee dans l anneau sur deux lignes, couleur tiree de l etat (CO-14, CO-15)' {
        $caption='Au moment de l'+[char]0x02BC+'inventaire, mesure tres longue a couper'
        $gauge=New-DomeniaGauge -Title 'Charge du processeur' -Value 85 -Maximum 100 -Unit '%' -Width 230 -Height 250 -Caption $caption
        $tw=Show-InTestWindow $gauge
        try{
            $small=@(Get-Texts $gauge|Where-Object{[string]$_.Text -eq $caption})[0]
            Expect ($null -ne $small) 'Legende absente'
            $ring=$small.Parent.Parent
            $size=[double]$ring.Width;$thickness=[Math]::Round($size*0.1);$inner=($size-$thickness-6)/2.0-$thickness/2.0
            Expect ($small.MaxWidth -le (1.5*$inner+1)) ('Largeur maximale '+$small.MaxWidth+' pour un rayon interieur de '+$inner)
            Expect ($small.ActualWidth -le ($small.MaxWidth+0.5)) ('Legende plus large que sa borne : '+$small.ActualWidth)
            Expect ($small.ActualHeight -le 28.5) ('Plus de deux lignes : '+$small.ActualHeight)
            $origin=$small.TransformToAncestor($ring).Transform([Windows.Point]::new(0,0))
            Expect (($origin.X -ge ($size/2-$inner-0.5)) -and (($origin.X+$small.ActualWidth) -le ($size/2+$inner+0.5))) ('Legende hors de l anneau : '+$origin.X)
            $arc=@($ring.Children[0].Children)[1]
            Expect ($arc.Stroke.Color -eq [Windows.Media.ColorConverter]::ConvertFromString((Get-DomeniaThemeColor -Key (Get-DomeniaBoardColor 'Info')))) '85 % sans point a surveiller : couleur neutre'
        }finally{$tw.Close()}
        $warn=New-DomeniaGauge -Title 'Memoire' -Value 95 -Maximum 100 -Unit '%' -Width 230 -Height 250 -State Warn
        $arcWarn=@(@(Get-DomeniaLogicalControls $warn|Where-Object{$_ -is [Windows.Controls.Canvas]})[0].Children)[1]
        Expect ($arcWarn.Stroke.Color -eq [Windows.Media.ColorConverter]::ConvertFromString((Get-DomeniaThemeColor -Key (Get-DomeniaBoardColor 'Warn')))) 'Etat a surveiller : couleur de l etat'
    }
    Case 'Tuile : 27 px pour un chiffre, 18 px sur deux lignes au plus pour un texte (DS-13)' {
        $figure=New-DomeniaKpiTile -Title 'Memoire' -Value '16 Go' -Detail 'x'
        Expect (@(Get-Texts $figure|Where-Object{[string]$_.Text -eq '16 Go' -and $_.FontSize -eq 27}).Count -eq 1) 'Chiffre en 27 px'
        $long='Intel(R) Core i5-1345U vPro avec un nom de modele vraiment tres long'
        $text=New-DomeniaKpiTile -Title 'Processeur' -Value $long -Detail 'x'
        $tw=Show-InTestWindow $text
        try{
            $value=@(Get-Texts $text|Where-Object{[string]$_.Text -eq $long})[0]
            Expect ($value.FontSize -eq 18 -and $value.TextWrapping -eq [Windows.TextWrapping]::Wrap) ('Texte : '+$value.FontSize)
            Expect ($value.ActualHeight -le 44.5) ('Plus de deux lignes : '+$value.ActualHeight)
            Expect ($value.TextTrimming -ne [Windows.TextTrimming]::None -and [string]$value.ToolTip -eq $long) 'Points de suspension et infobulle'
        }finally{$tw.Close()}
        $short=New-DomeniaKpiTile -Title 'Service' -Value 'Service informatique' -Detail 'x'
        Expect (@(Get-Texts $short|Where-Object{[string]$_.Text -eq 'Service informatique' -and $_.FontSize -eq 18}).Count -eq 1) 'Taille independante de la longueur'
    }
    Case 'Barres et histogramme : libelles larges, tailles lisibles, graduations entieres, sans axe si etiquete (CO-16)' {
        $bars=New-DomeniaBarChart -Title 'Plus gros logiciels' -Items @([pscustomobject]@{Label='Suite bureautique de demonstration';Value=2354;Display='2,3 Go'},[pscustomobject]@{Label='Outil';Value=12;Display='12 Mo'}) -Width 600 -Height 250 -Unit ' Mo'
        $row=@(Get-DomeniaLogicalControls $bars|Where-Object{$_ -is [Windows.Controls.Grid] -and $_.ColumnDefinitions.Count -eq 3})[0]
        Expect ([double]$row.ColumnDefinitions[0].Width.Value -eq [Math]::Floor([Math]::Min(260,600*0.42))) ('Largeur des libelles : '+$row.ColumnDefinitions[0].Width.Value)
        Expect (@(Get-Texts $bars|Where-Object{[string]$_.Text -eq '2,3 Go'}).Count -eq 1) 'Taille lisible, jamais 2354 Mo'
        $few=New-DomeniaColumnChart -Title 'Postes' -Items @([pscustomobject]@{Label='A';Value=1},[pscustomobject]@{Label='B';Value=2},[pscustomobject]@{Label='C';Value=1}) -Width 440 -Height 250 -Subtitle '19 postes'
        $fewTexts=@(Get-Texts $few|ForEach-Object{[string]$_.Text})
        Expect (-not ($fewTexts -contains '0')) ('Axe dessine alors que chaque colonne a sa valeur : '+($fewTexts -join ','))
        Expect ($fewTexts -contains '19 postes') 'Sous-titre absent'
        $many=New-DomeniaColumnChart -Title 'Postes' -Items @(0..13|ForEach-Object{[pscustomobject]@{Label=('L'+$_);Value=[double]$_}}) -Width 600 -Height 250
        $numbers=@(Get-Texts $many|ForEach-Object{[string]$_.Text}|Where-Object{$_ -match '^[\d,\s]+$'})
        Expect (($numbers -join '|') -eq '0|5|10|15') ('Graduations : '+($numbers -join '|'))
    }
    Case 'Score partiel : badge et bouton Inventaire complet dans la carte, lance seulement au clic (UX-23)' {
        $script:SelectedObject=$null
        $deep=Get-DomeniaControl 'BtnDashboardInventoryDeep';$deep.IsEnabled=$true
        $script:DeepClicks=0;$deep.Add_Click({$script:DeepClicks++})
        Update-DomeniaComputerDashboard -Result (New-InventoryResult)
        $panel=Get-DomeniaControl 'PnlComputerDashboard'
        # UX-23 au 14/10 (896368c) : l omission de l une des trois lectures suffit, la condition exige les trois.
        $badge='Partiel : antivirus, pare-feu ou BitLocker non lu'
        Expect (@(Get-Texts $panel|Where-Object{[string]$_.Text -eq $badge}).Count -eq 1) 'Badge Partiel absent'
        $button=@(Get-DomeniaLogicalControls $panel|Where-Object{$_ -is [Windows.Controls.Button] -and $_.Tag -is [hashtable] -and [string]$_.Tag['Value'] -eq 'InventoryFull' -and [string]$_.Content -eq 'Inventaire complet'})
        Expect ($button.Count -ge 1) 'Bouton Inventaire complet absent de la carte'
        Expect ($script:DeepClicks -eq 0) 'Inventaire lance sans clic'
        $button[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Expect ($script:DeepClicks -eq 1) ('Clic non transmis au bouton existant : '+$script:DeepClicks)
        $deep.IsEnabled=$false;$script:Trace.Clear()
        $button[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Expect ($script:DeepClicks -eq 1 -and @($script:Trace|Where-Object{$_ -like 'Action indisponible*'}).Count -eq 1) 'Bouton indisponible contourne'
        $deep.IsEnabled=$true
    }
    Case 'Section vide : action existante et collecte locale seulement au clic (SP-17)' {
        # A valid current OU snapshot, while the workshop deliberately has an AD-only recipe.
        $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid';$script:FleetStale=$false;$script:FleetJobId=''
        Complete-DomeniaFleetDashboard -Result (New-FleetResult -Scope $script:FleetScopeDn) -State $null
        Initialize-DomeniaQueryWorkshop;Set-DomeniaQueryDraft (New-DomeniaQueryRecipe -Id 'template.all')
        if($null -ne $script:DomeniaQueryState.Timer){$script:DomeniaQueryState.Timer.Stop()}
        $panel=Get-DomeniaControl 'PnlComputerDashboard'
        $open=@(Get-DomeniaLogicalControls $panel|Where-Object{$_ -is [Windows.Controls.Button] -and $_.Tag -is [hashtable] -and [string]$_.Tag['Value'] -eq 'OpenCard'})
        Expect ($open.Count -eq 1) 'Bouton Ouvrir la fiche absent sous la section du compte machine'
        $script:Workspaces.Clear();$before=$script:StartCalls.Count;$parks=$script:ParkCalls.Count
        $open[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Expect (($script:Workspaces -join ',') -eq 'route:WsObject') ('Ecran ouvert : '+($script:Workspaces -join ','))
        $state=Get-DomeniaBoardState 'Fleet';$previous=$state.Data
        $data=New-DomeniaBoardData -Board Fleet
        $data.Hints['Répartition']='Aucun poste actif indexé dans ce périmètre.'
        $data.HintActions['Répartition']=[pscustomobject]@{Id='CollectFleet';Text='Relever ce périmètre';Tip='Collecte explicite du perimetre local.';Link=$true}
        try{
            Show-DomeniaBoard -Board Fleet -Data $data -Quiet
            $links=@(Get-DomeniaLogicalControls (Get-DomeniaControl 'PnlFleetDashboard')|Where-Object{$_ -is [Windows.Documents.Hyperlink] -and $_.Tag -is [hashtable] -and [string]$_.Tag['Id'] -eq 'CollectFleet'})
            Expect ($links.Count -eq 1) ('Lien de collecte locale : '+$links.Count)
            Expect (@(Get-DomeniaLogicalControls (Get-DomeniaControl 'PnlFleetDashboard')|Where-Object{$_ -is [Windows.Controls.Button] -and $_.Tag -is [hashtable] -and [string]$_.Tag['Action'] -eq 'EntryAction'}).Count -eq 0) 'Bouton d action sur l accueil'
            $script:Workspaces.Clear()
            $links[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Documents.Hyperlink]::ClickEvent))
            Expect ($script:Workspaces.Count -eq 0) 'La collecte locale a ouvert Rechercher'
            Expect ($script:StartCalls.Count -eq $before -and $script:ParkCalls.Count -eq $parks+1) 'La collecte ne part pas uniquement au clic'
            Expect (-not $script:ParkCalls[$parks].Displayed -and $script:ParkCalls[$parks].Inventory) 'La collecte ne cible pas le perimetre local explicite'
            Expect (@($script:ParkCalls[$parks].Targets).Count -eq 2 -and -not $script:ParkCalls[$parks].ProbesBound) 'CollectFleet depend encore de la recette ou des sondes de l atelier'
            $operators=Get-DomeniaControl 'CmbQueryOperator';$value=Get-DomeniaControl 'TxtQueryValue'
            Expect ($operators.Items.Count -gt 0 -and $null -ne $operators.SelectedItem) 'Premier atelier : aucun operateur selectionne'
            Expect ($value.IsEnabled -eq ([string]$operators.SelectedItem.Id -notin @('IsMissing','IsPresent'))) 'Premier atelier : etat du champ valeur incoherent'
            foreach($name in @('LblQuerySegment','BtnQueryClearSegment')){Expect ((Get-DomeniaControl $name).Visibility -eq [Windows.Visibility]::Collapsed) ('Segment vide affiche : '+$name)}

        }finally{if($null -ne $previous){Show-DomeniaBoard -Board Fleet -Data $previous -Quiet}}
    }
    Case 'Collection rejects domain, mismatched or stale snapshots before dispatch' {
        $savedDn=$script:FleetScopeDn;$savedLast=$script:FleetLast;$savedStale=$script:FleetStale;$savedJob=$script:FleetJobId
        try{
            $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid';$script:FleetStale=$false;$script:FleetJobId=''
            Complete-DomeniaFleetDashboard -Result (New-FleetResult -Scope $script:FleetScopeDn) -State $null
            if($null -ne $script:DomeniaQueryState.Timer){$script:DomeniaQueryState.Timer.Stop()}
            $current=$script:FleetLast;$before=$script:ParkCalls.Count;$jobs=$script:StartCalls.Count
            $valid=Get-DomeniaFleetCollectionContext;Expect (@($valid.Targets).Count -eq 2) 'Valid OU rejected or inactive accounts included'
            foreach($scenario in @('Domain','Scope','Epoch','MissingEpoch','Stale','Busy','Subtree','Empty')){
                $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid';$script:FleetLast=$current.PSObject.Copy();$script:FleetStale=$false;$script:FleetJobId=''
                switch($scenario){
                    Domain {$script:FleetScopeDn='';$script:FleetLast.Scope=''}
                    Scope {$script:FleetLast.Scope='OU=Other,DC=example,DC=invalid'}
                    Epoch {$script:FleetLast.Epoch=0L}
                    MissingEpoch {$script:FleetLast.PSObject.Properties.Remove('Epoch')}
                    Stale {$script:FleetStale=$true}
                    Busy {$script:FleetJobId='fixture-pending'}
                    Subtree {$script:FleetLast.Subtree=$false}
                    Empty {$script:FleetLast.Targets=@()}
                }
                $refused=($null -eq (Get-DomeniaFleetCollectionContext))
                Expect $refused ('Unsafe collection context accepted: '+$scenario)
            }
            Expect ($script:ParkCalls.Count -eq $before -and $script:StartCalls.Count -eq $jobs) 'Context validation dispatched a worker'
        }finally{$script:FleetScopeDn=$savedDn;$script:FleetLast=$savedLast;$script:FleetStale=$savedStale;$script:FleetJobId=$savedJob}
    }
    Case 'Widget sans chiffre : place compacte qui dit pourquoi et propose sa collecte, plus de Non lu par cet inventaire (SP-18, demande David)' {
        # Inventory placeholders are independent from custom probes installed by earlier editor cases.
        $savedComputerLayout=[string](Get-DomeniaSetting 'Dashboard.Computer.Layout' '')
        try{
        Set-DomeniaSetting 'Dashboard.Computer.Layout' (ConvertTo-DomeniaBoardLayoutJson -Layout @(Get-Layout Computer|Where-Object Source -eq 'Builtin'))
        Update-DomeniaComputerDashboard -Result (New-InventoryResult)
        $panel=Get-DomeniaControl 'PnlComputerDashboard'
        Expect (@(Get-Texts $panel|Where-Object{[string]$_.Text -eq 'Non lu par cet inventaire'}).Count -eq 0) 'Ancien emplacement Non lu par cet inventaire'
        $battery=@(Get-Holders $panel|Where-Object{[string]$_.Tag.Item.Key -eq 'computer.battery'})
        Expect ($battery.Count -eq 1) 'Widget Batterie sans place une fois le tableau rempli'
        $texts=@(Get-Texts $battery[0]|ForEach-Object{[string]$_.Text})
        Expect (@($texts|Where-Object{$_ -like 'Absent du dernier relevé du * : information non renvoyée pour ce poste.'}).Count -eq 1) ('Etat du widget : '+($texts -join ' | '))
        Expect (@(Get-DomeniaLogicalControls $battery[0]|Where-Object{$_ -is [Windows.Controls.Button] -and $_.Tag -is [hashtable] -and [string]$_.Tag['Action'] -eq 'Refresh'}).Count -ge 1) 'Bouton de relecture absent'
        # The inventory read the disks and found only C: : an answer in words, not a missing value.
        $volumes=@(Get-Holders $panel|Where-Object{[string]$_.Tag.Item.Key -eq 'computer.disk.volumes'})
        Expect ($volumes.Count -eq 1 -and @(Get-Texts $volumes[0]|Where-Object{[string]$_.Text -eq 'Aucun autre volume'}).Count -eq 1) 'Un seul disque non dit en mots'
        Clear-DomeniaDashboards
        Expect (@(Get-Holders $panel).Count -eq 0) 'Emplacement avant toute lecture'
        }finally{Set-DomeniaSetting 'Dashboard.Computer.Layout' $savedComputerLayout;Show-DomeniaBoard -Board Computer -Quiet}
    }
    Case 'Animation d entree : cartes, anneaux et compteurs vont au bout puis s arretent' {
        # Windows animations off (accessibility, some remote sessions): the board stays static by design.
        if(-not [Windows.SystemParameters]::ClientAreaAnimation){return}
        $script:DomeniaReduceMotion=$false
        $mw=[Windows.Window]::new();$mw.Width=900;$mw.Height=500;$mw.ShowInTaskbar=$false
        foreach($k in @('BgCard','BorderColor','TextColor','MutedColor','AccentColor','WindowBg')){$mw.Resources[$k]=$w.Resources[$k]}
        $panel=[Windows.Controls.WrapPanel]::new();$panel.Name='PnlMotionTest';$mw.Content=$panel;$mw.Show()
        [void]$panel.Children.Add((New-DomeniaKpiTile -Title 'Postes' -Value '128 postes' -Detail 'fictif'))
        [void]$panel.Children.Add((New-DomeniaDonutChart -Title 'Systemes' -Items @([pscustomobject]@{Label='A';Value=3},[pscustomobject]@{Label='B';Value=1})))
        [void]$panel.Children.Add((New-DomeniaBarChart -Title 'Barres' -Items @([pscustomobject]@{Label='A';Value=3},[pscustomobject]@{Label='B';Value=1})))
        $mw.UpdateLayout()
        Invoke-DomeniaDashboardEntrance -Panel $panel
        Expect ($script:DomeniaCounting.Count -ge 1) 'Compteur non lance'
        Invoke-Pump 2600
        Expect ($script:DomeniaCounting.Count -eq 0) ('Compteurs restants : '+$script:DomeniaCounting.Count)
        $texts=@(Get-DomeniaLogicalControls $panel|Where-Object{$_ -is [Windows.Controls.TextBlock] -and [string]$_.Text -eq '128 postes'})
        Expect ($texts.Count -eq 1) 'Valeur finale du compteur'
        Expect (@($panel.Children|Where-Object{$_.Opacity -lt 0.999}).Count -eq 0) 'Carte restee transparente'
        $mw.Close();$script:DomeniaReduceMotion=$true
    }
    Case 'Tableau flotteur : une fonction absente est nommee, pas noyee dans un echec metier' {
        # Le defaut qui a couté deux heures: Complete-DomeniaFleetDashboard doit nommer la fonction
        # absente dans le journal et dans le libelle, au lieu d'afficher un echec metier muet.
        $script:DatabaseScopedPath=''
        $state=[pscustomobject]@{Epoch=[long]$script:SessionEpoch;Key='fleet-wiring';Scope='';Subtree=$true;Name='Tous les postes';ScopePath=''}
        $script:FleetPendingKey='fleet-wiring';$script:FleetJobId='';$script:FleetComputedKey=''
        $script:UiLogLines.Clear()
        $result=New-FleetResult
        $d=$null
        try{
            $d=(Get-Item Function:\Get-DomeniaMemberValue).Definition
            Set-Item Function:\Get-DomeniaMemberValue {Get-DomeniaFonctionSupprimeePourLeBanc}
            Complete-DomeniaFleetDashboard -Result $result -State $state
        }finally{
            if($null -ne $d){Set-Item Function:\Get-DomeniaMemberValue ([scriptblock]::Create([string]$d))}
        }
        $journal=@($script:UiLogLines|Where-Object{$_ -like '*Get-DomeniaFonctionSupprimeePourLeBanc*'})
        Expect (@($journal).Count -ge 1) ('Fonction absente jamais nommee dans le journal : '+($script:UiLogLines -join ' // '))
        Expect (@($journal|Where-Object{$_ -like 'ERROR|*'}).Count -ge 1) 'Fonction absente journalisee sans niveau ERROR'
        Expect ([string](Get-DomeniaControl 'LblFleetDashboard').Text -like '*fonction absente*') ('Libelle : '+[string](Get-DomeniaControl 'LblFleetDashboard').Text)
        Expect ([string]$script:FleetComputedKey -eq '') 'Cle calculee conservee sur un echec de chargement'
    }
    Case 'Clic sur une part ou une barre : le critere remonte au tableau de bord, une part sans critere ne fait rien (FO-09)' {
        $script:Fo09Calls=[Collections.Generic.List[object]]::new()
        $handler={param($Select);$script:Fo09Calls.Add($Select)}
        $donut=New-DomeniaDonutChart -Title 'Editeurs' -Items @([pscustomobject]@{Label='Adobe';Value=3;Select=[pscustomobject]@{Field='Publisher';Value='Adobe'}},[pscustomobject]@{Label='Autres';Value=1}) -Width 340 -Height 240 -OnSelect $handler
        $paths=@(Get-DomeniaLogicalControls $donut|Where-Object{$_ -is [Windows.Shapes.Path] -and $null -ne $_.Tag})
        Expect ($paths.Count -eq 2) ('Segments trouves : '+$paths.Count)
        $parts=@($paths|Where-Object{$_.Tag -is [System.Collections.IDictionary] -and $null -ne $_.Tag['Select']})
        Expect ($parts.Count -eq 1) ('Parts avec critere : '+$parts.Count)
        Expect ([string]$parts[0].Tag['Select'].Field -eq 'Publisher') 'Champ du critere perdu'
        Invoke-DomeniaChartSelect -Tag $parts[0].Tag
        Expect ($script:Fo09Calls.Count -eq 1) ('Clic sur une part non transmis : '+$script:Fo09Calls.Count)
        Expect ([string]$script:Fo09Calls[0].Value -eq 'Adobe') 'Critere altere pendant la transmission'
        $sans=@($paths|Where-Object{$_.Tag -is [System.Collections.IDictionary] -and $null -eq $_.Tag['Select']})
        Expect ($sans.Count -eq 1) 'La part sans critere a recu un critere'
        Invoke-DomeniaChartSelect -Tag $sans[0].Tag
        Expect ($script:Fo09Calls.Count -eq 1) 'Une part sans critere filtre la liste'
        Invoke-DomeniaChartSelect -Tag $null
        Invoke-DomeniaChartSelect -Tag @{}
        Expect ($script:Fo09Calls.Count -eq 1) 'Un Tag sans gestionnaire leve une erreur'
        $bars=New-DomeniaBarChart -Title 'Plus gros logiciels' -Items @([pscustomobject]@{Label='Acme';Value=120;Select=[pscustomobject]@{Field='Name';Value='Acme'}},[pscustomobject]@{Label='Sans critere';Value=60}) -Width 420 -Height 200 -OnSelect $handler
        $rowsBar=@(Get-DomeniaLogicalControls $bars|Where-Object{$_ -is [Windows.Controls.Grid] -and $_.Tag -is [System.Collections.IDictionary] -and $null -ne $_.Tag['Select']})
        Expect ($rowsBar.Count -eq 1) ('Barres avec critere : '+$rowsBar.Count)
        Expect ($rowsBar[0].Cursor -eq [Windows.Input.Cursors]::Hand) 'La barre qui filtre ne prend pas le curseur main'
        Invoke-DomeniaChartSelect -Tag $rowsBar[0].Tag
        Expect ($script:Fo09Calls.Count -eq 2) 'Clic sur une barre non transmis'
        $plain=New-DomeniaDonutChart -Title 'Systemes' -Items @([pscustomobject]@{Label='A';Value=3})
        $plainPath=@(Get-DomeniaLogicalControls $plain|Where-Object{$_ -is [Windows.Shapes.Path] -and $null -ne $_.Tag})[0]
        Expect ($null -eq $plainPath.Tag['OnSelect']) 'Un graphique sans gestionnaire reste decoratif'
        # Earlier cases save a root OU. An empty fleet DN would follow it and refuse this whole-domain detail.
        $savedExplicit=[bool]$script:FleetScopeExplicitDomain
        try {
        foreach($scopeKey in @($script:TestSettings.Keys | Where-Object { $_ -like 'Directory.RootOu.*' -or $_ -like 'Fleet.Scope.*' })) { [void]$script:TestSettings.Remove($scopeKey) }
        $script:FleetScopeExplicitDomain=$true;$script:FleetScopeRestored=$true;$script:FleetScopeSubtree=$true
        $script:FleetScopeDn='';$script:DatabaseScopedPath='';$script:FleetPendingKey='';$script:FleetJobId='';$script:FleetStale=$false
        $script:SelectedBranchDn='OU=Recherche,DC=example,DC=invalid';$searchBefore=$script:SelectedBranchDn
        (Get-DomeniaControl 'WorkspaceTabs').SelectedItem=Get-DomeniaControl 'TabDashboard'
        # A hidden Accueil defers the draw. The click must hit the widgets of this calculation, not the previous one.
        $w.UpdateLayout();Invoke-Pump 150;$w.UpdateLayout()
        Complete-DomeniaFleetDashboard -Result (New-FleetResult) -State $null
        $w.UpdateLayout();Invoke-Pump 150
        if(-not (Get-DomeniaControl 'PnlFleetDashboard').IsVisible){Show-DomeniaBoard -Board Fleet -Quiet}
        $holder=@(Get-Holders (Get-DomeniaControl 'PnlFleetDashboard')|Where-Object{$_.Tag.Item.Key -eq 'fleet.machines'})[0]
        Expect ($null -ne $holder -and -not $holder.Tag.Editing) 'Widget Postes non cliquable'
        $parks=$script:ParkCalls.Count;$callsBefore=$script:StartCalls.Count
        $mouse=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,0,[Windows.Input.MouseButton]::Left)
        $mouse.RoutedEvent=[Windows.UIElement]::MouseLeftButtonUpEvent;$mouse.Source=$holder;$holder.RaiseEvent($mouse)
        Expect ($script:StartCalls.Count -eq $callsBefore -and (Get-DomeniaControl 'WorkspaceTabs').SelectedItem.Name -eq 'TabDashboard') 'Un clic de carte ouvre encore l atelier'
        Expect ($null -eq (Get-DomeniaBoardSelectHandler Fleet $holder.Tag.Item)) 'Le clic de segment est encore actif'
        $details=@($holder.Tag.Chrome.Children|Where-Object{$_.Tag.Action -eq 'Details'})
        Expect ($details.Count -eq 1) 'Icone atelier absente'
        $details[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        $call=$script:StartCalls[$script:StartCalls.Count-1]
        $liveScope=Get-DomeniaFleetScope
        Expect ($script:StartCalls.Count -gt $callsBefore -and $call.OperationId -eq 'LocalQuery') ('Le widget ne lance pas le moteur local : op='+[string]$call.OperationId+' ajoutes='+($script:StartCalls.Count-$callsBefore)+' scope='+[string]$script:FleetLast.Scope+' dn='+[string]$liveScope.Dn+' stale='+[bool]$script:FleetStale+' job='+[string]$script:FleetJobId+' statut='+[string](Get-DomeniaControl 'LblQueryStatus').Text)
        $Payload=$call.Payload;$result=& ([scriptblock]::Create([string]$call.Code))
        Complete-DomeniaQueryEvaluation -Result $result -State $call.State
        $q=$script:DomeniaQueryState
        Expect ($null -ne $q.Result -and $q.Result.Matched -eq 4 -and @((Get-DomeniaControl 'DgFleetMachines').ItemsSource).Count -eq 4) 'Le detail du widget omet un des quatre postes, dont le desactive'
        Expect ($script:SelectedBranchDn -eq $searchBefore -and [string](Get-DomeniaControl 'WorkspaceTabs').SelectedItem.Name -eq 'TabApplicationTools' -and [string](Get-DomeniaControl 'ApplicationToolTabs').SelectedItem.Name -eq 'WsQueryWorkshop') 'Le detail local modifie Rechercher ou n ouvre pas l atelier'
        Expect ($script:ParkCalls.Count -eq $parks) 'Le detail lance une collecte distante'
        $targets=@($script:FleetLast.Machines|Where-Object{$_.name -eq 'PC-2'})
        Invoke-DomeniaBoardAction -Tag @{Board='Fleet';Action='QueryTargets';Targets=$targets;Label='Point fixture'}
        $call=$script:StartCalls[$script:StartCalls.Count-1];Expect ($call.OperationId -eq 'LocalQuery') 'Le detail d alerte ne lance pas le moteur local'
        $Payload=$call.Payload;$result=& ([scriptblock]::Create([string]$call.Code))
        Complete-DomeniaQueryEvaluation -Result $result -State $call.State
        $rows=@((Get-DomeniaControl 'DgFleetMachines').ItemsSource)
        Expect ($rows.Count -eq 1 -and $rows[0].name -eq 'PC-2' -and $rows[0].Id -eq '00000000-0000-4000-8000-000000000002') 'La selection figee ne preserve pas le GUID attendu'
        Expect ([string](Get-DomeniaControl 'LblQuerySegment').Text -like 'Sélection figée : 1 GUID*') 'La selection figee est invisible'
        foreach($name in @('LblQuerySegment','BtnQueryClearSegment')){Expect ((Get-DomeniaControl $name).Visibility -eq [Windows.Visibility]::Visible) ('Segment fige masque : '+$name)}
        Expect ($script:SelectedBranchDn -eq $searchBefore -and $script:ParkCalls.Count -eq $parks) 'Le detail d alerte a modifie Rechercher ou lance le reseau'
        (Get-DomeniaControl 'BtnQueryBack').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Expect ((Get-DomeniaControl 'WorkspaceTabs').SelectedItem.Name -eq 'TabDashboard') 'Retour atelier incorrect'
        if($null -ne $q.Timer){$q.Timer.Stop()}
        } finally { $script:FleetScopeExplicitDomain=$savedExplicit }

    }
    Case 'Base locale : le detail long garde une largeur et une hauteur lisibles dans la vraie grille WPF' {
        $grid=Get-DomeniaControl 'DgIndex'
        $workspaces=Get-DomeniaControl 'WorkspaceTabs';$tools=Get-DomeniaControl 'ApplicationToolTabs'
        $oldWorkspace=$workspaces.SelectedItem;$oldTool=$tools.SelectedItem;$oldRows=$grid.ItemsSource;$indexTabs=Get-DomeniaControl 'IndexWorkspaceTabs';$oldIndex=$indexTabs.SelectedItem
        $oldWidth=$w.Width;$oldHeight=$w.Height;$oldVirtual=$grid.EnableColumnVirtualization
        try {
            $w.Width=1920;$w.Height=1080
            $workspaces.SelectedItem=Get-DomeniaControl 'TabApplicationTools';$tools.SelectedItem=Get-DomeniaControl 'TabIndex';$indexTabs.SelectedItem=Get-DomeniaControl 'TabIndexData'
            $longDn='CN=PC-FIXTURE-LONG,OU=Comptabilite et administration territoriale,OU=Postes bureautiques et mobiles,OU=Direction des services regionaux,OU=Lyon,DC=example,DC=invalid'
            $grid.ItemsSource=[object[]]@([pscustomobject]@{Type='Machine';Name='PC-FIXTURE-LONG';Login='PC-FIXTURE-LONG$';Upn='pc-fixture-long.example.invalid';State='Actif';Association='';Score='';Description=$longDn;DN=$longDn;LastLogon='';Changed=''})
            $grid.EnableColumnVirtualization=$false;$grid.Items.Refresh();$grid.BringIntoView()
            $w.UpdateLayout();Invoke-Pump 200;$grid.ScrollIntoView($grid.Items[0]);$grid.UpdateLayout()
            $column=@($grid.Columns|Where-Object{[string]$_.SortMemberPath -eq 'Description'})[0]
            Expect ($null -ne $column -and $column.MinWidth -ge 260) 'La colonne Detail peut se reduire sous 260 pixels'
            Expect ($column.ActualWidth -ge 260) ('Largeur reelle Detail : '+$column.ActualWidth)
            $cell=$column.GetCellContent($grid.Items[0])
            Expect ($null -ne $cell) 'Cellule Detail non materialisee dans la grille visible'
            # A DataTemplate child belongs to the visual tree of the ContentPresenter.
            # LogicalTreeHelper only returns that presenter, so inspect the rendered text.
            $text=$null;$visuals=[Collections.Queue]::new();$visuals.Enqueue($cell)
            while($visuals.Count -gt 0 -and $null -eq $text){
                $visual=$visuals.Dequeue()
                if($visual -is [Windows.Controls.TextBlock] -and [string]$visual.Text -eq $longDn){$text=$visual;break}
                for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($visual);$i++){$visuals.Enqueue([Windows.Media.VisualTreeHelper]::GetChild($visual,$i))}
            }
            Expect ($null -ne $text -and $text.MaxHeight -le 48 -and $text.ActualHeight -le 48) 'Le DN long etire la hauteur du detail'
            Expect ($text.TextTrimming -eq [Windows.TextTrimming]::CharacterEllipsis) 'Le detail ne signale plus son texte tronque'
            $row=$grid.ItemContainerGenerator.ContainerFromIndex(0)
            Expect ($null -ne $row -and $row.ActualHeight -gt 0 -and $row.ActualHeight -le 80) ('Hauteur de ligne anormale : '+$(if($null -ne $row){$row.ActualHeight}else{'non materialisee'}))
        } finally {
            $grid.ItemsSource=$oldRows;$grid.EnableColumnVirtualization=$oldVirtual
            $tools.SelectedItem=$oldTool;$indexTabs.SelectedItem=$oldIndex;$workspaces.SelectedItem=$oldWorkspace;$w.Width=$oldWidth;$w.Height=$oldHeight;$w.UpdateLayout()
        }
    }
    Case 'Atelier : le vrai clic Ajouter accepte une condition numerique et conserve sa valeur decimale' {
        Initialize-DomeniaQueryWorkshop
        $q=$script:DomeniaQueryState
        $field=Get-DomeniaControl 'CmbQueryField';$operator=Get-DomeniaControl 'CmbQueryOperator';$value=Get-DomeniaControl 'TxtQueryValue'
        $oldRecipe=$q.Recipe;$oldField=$field.SelectedItem;$oldOperatorId=[string]$operator.SelectedItem.Id;$oldValue=$value.Text
        $callsBefore=$script:StartCalls.Count
        try {
            Set-DomeniaQueryDraft (New-DomeniaQueryRecipe -Name 'Fixture ajout numerique')
            $field.SelectedItem=@($field.ItemsSource|Where-Object{$_.Id -eq 'diskFreePercent'})[0]
            $operator.SelectedItem=@($operator.ItemsSource|Where-Object{$_.Id -eq 'Less'})[0]
            Expect ($null -ne $field.SelectedItem -and $null -ne $operator.SelectedItem -and $value.IsEnabled) 'Les controles numeriques ne sont pas utilisables'
            $value.Text='20'
            (Get-DomeniaControl 'BtnQueryAddCondition').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            $clauses=@($q.Recipe.Clauses)
            Expect ($clauses.Count -eq 1) ('Le clic Ajouter ne cree pas une seule condition : '+$clauses.Count+' ; '+[string](Get-DomeniaControl 'LblQueryStatus').Text)
            Expect ($clauses[0].Field -eq 'diskFreePercent' -and $clauses[0].Operator -eq 'Less') 'Champ ou operateur numerique perdu'
            Expect ($clauses[0].Value -is [decimal] -and $clauses[0].Value -eq [decimal]20) 'La valeur numerique 20 n est pas conservee comme decimal'
            # The grid shows the unit; the recipe above keeps its numeric decimal value.
            $rows=@((Get-DomeniaControl 'DgQueryConditions').ItemsSource)
            Expect ($rows.Count -eq 1 -and $rows[0].FieldLabel -eq $field.SelectedItem.Name -and $rows[0].OperatorLabel -eq $operator.SelectedItem.Name -and $rows[0].Value -ceq '20 %') 'La condition ajoutee ne se voit pas dans le tableau'
            Expect ($script:StartCalls.Count -eq $callsBefore) 'Ajouter une condition lance une tache avant Executer'
        } finally {
            Set-DomeniaQueryDraft $oldRecipe
            $field.SelectedItem=$oldField
            $operator.SelectedItem=@($operator.ItemsSource|Where-Object{$_.Id -eq $oldOperatorId})[0]
            $value.Text=$oldValue
            if($null -ne $q.Timer){$q.Timer.Stop()}
        }
    }
    Case 'Un dashboard masque conserve le dernier resultat puis le rend une seule fois a sa reouverture' {
        $tabs=Get-DomeniaControl 'WorkspaceTabs';$oldTab=$tabs.SelectedItem
        $panel=Get-DomeniaControl 'PnlFleetDashboard';$state=Get-DomeniaBoardState Fleet
        $oldData=$state.Data;$oldScope=$script:FleetScopeDn;$oldEditing=$state.Editing
        try{
            $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid';$state.Editing=$false
            $tabs.SelectedItem=Get-DomeniaControl 'TabDashboard';$w.UpdateLayout();Invoke-Pump 50
            $first=(New-FleetResult -Scope $script:FleetScopeDn).Board
            Show-DomeniaBoard -Board Fleet -Data $first -Quiet
            $oldChild=$panel.Children[0]
            $tabs.SelectedItem=Get-DomeniaControl 'WsSearch';$w.UpdateLayout();Invoke-Pump 50
            Expect (-not $panel.IsVisible) 'Le dashboard fixture doit etre masque'
            # Same warmed code/data: isolate avoided hidden work, not network/AD throughput or
            # total navigation latency. The deferred board is still drawn when it becomes visible.
            foreach($sample in 1..3){
                $watch=[Diagnostics.Stopwatch]::StartNew();Show-DomeniaBoard -Board Fleet -Data $first -Quiet;$watch.Stop()
                $direct=$watch.Elapsed.TotalMilliseconds
                $watch.Restart();Show-DomeniaBoard -Board Fleet -Data $first -Quiet -DeferIfHidden;$watch.Stop()
                $script:RenderTimings.Add([pscustomobject]@{Sample=$sample;FullHiddenRenderMs=$direct;DeferredHiddenUpdateMs=$watch.Elapsed.TotalMilliseconds;WidgetCount=@(Get-Holders $panel).Count})
            }
            $oldChild=$panel.Children[0]
            $latest=(New-FleetResult -Scope $script:FleetScopeDn).Board
            Show-DomeniaBoard -Board Fleet -Data $first -DeferIfHidden
            Show-DomeniaBoard -Board Fleet -Data $latest -DeferIfHidden
            Expect ($state.RenderPending -and [object]::ReferenceEquals($state.Data,$latest)) 'Le dernier resultat masque est perdu'
            Expect ([object]::ReferenceEquals($oldChild,$panel.Children[0])) 'Le panneau masque a ete reconstruit'
            $tabs.SelectedItem=Get-DomeniaControl 'TabDashboard';$w.UpdateLayout();Invoke-Pump 100
            Expect ($panel.IsVisible -and -not $state.RenderPending) 'Le rendu differe ne reprend pas a la reouverture'
            Expect (-not [object]::ReferenceEquals($oldChild,$panel.Children[0])) 'Le panneau visible conserve ses anciens controles'
            Expect (@(Get-Holders $panel).Count -gt 0) 'Aucun widget visible apres reprise'
            $rendered=$panel.Children[0];Resume-DomeniaBoardRender Fleet $panel
            Expect ([object]::ReferenceEquals($rendered,$panel.Children[0])) 'Un deuxieme signal reconstruit inutilement le panneau'
        }finally{
            $state.Editing=$oldEditing;$script:FleetScopeDn=$oldScope
            $state.Data=$oldData;Show-DomeniaBoard -Board Fleet -Quiet
            $tabs.SelectedItem=$oldTab;$w.UpdateLayout()
        }
    }
    Case 'Widget ajoute : collecte immediate des seules donnees manquantes de l OU, progression sur le widget, file d attente (demande David)' {
        $tabs=Get-DomeniaControl 'WorkspaceTabs';$oldTab=$tabs.SelectedItem;$saved=[string](Get-DomeniaSetting 'Dashboard.Fleet.Layout' '')
        try{
            $tabs.SelectedItem=Get-DomeniaControl 'TabDashboard';$w.UpdateLayout()
            $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid';$script:FleetStale=$false;$script:FleetJobId=''
            Complete-DomeniaFleetDashboard -Result (New-FleetResult -Scope $script:FleetScopeDn) -State $null
            if($null -ne $script:DomeniaQueryState.Timer){$script:DomeniaQueryState.Timer.Stop()}
            $script:ParkRuns=$null;$script:ParkCalls.Clear()
            $item=New-DomeniaBoardItem -Source Probe -Key 'disk.cfree' -Visual Column -Group 'Mesures' -Id 'w-add'
            Set-DomeniaBoardLayout -Board Fleet -Layout @(Add-DomeniaBoardItem -Layout @(Get-Layout Fleet) -Item $item) -Undo 'Widget ajoute' -Highlight 'w-add'
            Expect (Start-DomeniaWidgetRefresh -Board Fleet -Id 'w-add' -Reason Add) 'Ajout sans collecte'
            Expect ($script:ParkCalls.Count -eq 1) ('Collectes : '+$script:ParkCalls.Count)
            $call=$script:ParkCalls[0]
            # The active workstations of the OU only; the run sets aside, before any read, those whose stored
            # measurement already answers (Reuse, checked in Test-DomeniaParkDetection), not the interface thread.
            Expect ((@($call.Targets|ForEach-Object{$_.name}) -join ',') -eq 'PC-1,PC-2') ('Postes collectes : '+(@($call.Targets|ForEach-Object{$_.name}) -join ','))
            Expect ((@($call.Probes|ForEach-Object{$_.Id}) -join ',') -eq 'disk.cfree') 'Requete du widget seule'
            Expect ($call.PingBeforeWmi -and (-not $call.WmiOnly) -and $call.NoConsole -and (-not $call.Inventory) -and (-not $call.PingOnly)) 'Mode de lecture du widget'
            Expect ($call.Preapproved -and ($call.Reuse -eq 30) -and (-not $call.Force)) 'Ajout : manquant seulement, sans confirmation sous la limite'
            # FI-18: the OU shown on Accueil is read in the scope of the lists, with the perimeter surveys of the boards.
            Expect (($call.WidgetBoard -eq 'Fleet') -and ((@($call.WidgetIds) -join ',') -eq 'w-add') -and ($call.Slot -eq 'List')) 'Widget ou portee de la collecte'
            (Get-DomeniaParkRun -Slot 'List').Done=1;Show-DomeniaBoard -Board Fleet -Quiet
            $holder=Find-DomeniaBoardHolder (Get-DomeniaControl 'PnlFleetDashboard') 'w-add'
            Expect ($null -ne $holder) 'Widget ajoute absent du tableau'
            Expect ([string]$holder.Tag['Progress'].Text -eq ('Collecte en cours '+[char]0x00B7+' 1/2 poste(s)')) ('Progression : '+[string]$holder.Tag['Progress'].Text)
            Expect (@(Get-Texts $holder|Where-Object{[string]$_.Text -eq 'Non lu par cet inventaire'}).Count -eq 0) 'Ancien emplacement'
            (Get-DomeniaParkRun -Slot 'List').Completed=$true;Update-DomeniaWidgetCollectProgress
            $holder=Find-DomeniaBoardHolder (Get-DomeniaControl 'PnlFleetDashboard') 'w-add'
            Expect ($null -eq $holder.Tag['Progress']) 'Progression encore affichee apres la fin'
            # While another survey of the scope of the lists runs, the refresh of this widget waits and starts at its end.
            $script:ParkRuns=@{List=[pscustomobject]@{Id='autre';Slot='List';Completed=$false;Loading=$false;Approved=$true;Done=0;Targets=@();Failed=0}};$script:ParkCalls.Clear()
            Expect (Start-DomeniaWidgetRefresh -Board Fleet -Id 'w-add' -Reason Refresh) 'Actualisation non mise en file'
            Expect (($script:ParkCalls.Count -eq 0) -and ($script:DomeniaWidgetCollectQueue.Count -eq 1)) 'File d attente du widget'
            Expect ((Get-DomeniaWidgetCollectProgress -Board Fleet -Id 'w-add') -like 'En file*') 'Etat en file non affiche'
            (Get-DomeniaParkRun -Slot 'List').Completed=$true;Update-DomeniaWidgetCollectProgress
            Expect (($script:ParkCalls.Count -eq 1) -and ($script:ParkCalls[0].Force) -and (@($script:ParkCalls[0].Targets).Count -eq 2)) 'Actualisation : relecture forcee des postes actifs de l OU'
            # Only adding a widget is the gesture that skips the confirmation (decision David 2026-10-14).
            Expect ((-not $script:ParkCalls[0].Preapproved) -and ($script:ParkCalls[0].Slot -eq 'List')) 'Actualisation lancee sans confirmation du nombre'
            Expect ($script:DomeniaWidgetCollectQueue.Count -eq 0) 'File non videe'
            (Get-DomeniaParkRun -Slot 'List').Completed=$true
            # Never the whole domain.
            foreach($rootKey in @($script:TestSettings.Keys | Where-Object { $_ -like 'Directory.RootOu.*' })) { [void]$script:TestSettings.Remove($rootKey) }
            $script:FleetScopeExplicitDomain=$true;$script:FleetScopeDn='';$script:ParkCalls.Clear()
            Expect (-not (Start-DomeniaWidgetRefresh -Board Fleet -Id 'w-add' -Reason Refresh)) 'Collecte acceptee a la racine du domaine'
            Expect ($script:ParkCalls.Count -eq 0) 'Collecte de tout le domaine'
        }finally{$script:ParkRuns=$null;$script:DomeniaWidgetCollectQueue.Clear();$script:DomeniaWidgetCollects.Clear();if($null -ne $script:DomeniaWidgetCollectTimer){$script:DomeniaWidgetCollectTimer.Stop()};$script:FleetObservations=@{};$script:FleetScopeDn='';Set-DomeniaSetting 'Dashboard.Fleet.Layout' $saved;$tabs.SelectedItem=$oldTab}
    }
    Case 'Suspendre la mesure : place gardee, aucune collecte nulle part, reprise qui collecte le manquant (demande David)' {
        $tabs=Get-DomeniaControl 'WorkspaceTabs';$oldTab=$tabs.SelectedItem;$saved=[string](Get-DomeniaSetting 'Dashboard.Fleet.Layout' '')
        try{
            $tabs.SelectedItem=Get-DomeniaControl 'TabDashboard';$w.UpdateLayout()
            $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid';$script:FleetStale=$false;$script:FleetJobId=''
            Complete-DomeniaFleetDashboard -Result (New-FleetResult -Scope $script:FleetScopeDn) -State $null
            if($null -ne $script:DomeniaQueryState.Timer){$script:DomeniaQueryState.Timer.Stop()}
            $script:ParkRuns=$null;$script:FleetObservations=@{}
            Set-DomeniaBoardLayout -Board Fleet -Layout @(Add-DomeniaBoardItem -Layout @(Get-Layout Fleet) -Item (New-DomeniaBoardItem -Source Probe -Key 'disk.cfree' -Visual Column -Group 'Mesures' -Id 'w-pause'))
            Expect (@(Get-DomeniaBoardProbeIds) -contains 'disk.cfree') 'Requete du widget actif absente'
            $before=@(Get-Layout Fleet|ForEach-Object{[string]$_.Id}) -join ','
            Invoke-DomeniaBoardAction -Tag @{Board='Fleet';Id='w-pause';Action='Pause'}
            Expect ((@(Get-Layout Fleet|ForEach-Object{[string]$_.Id}) -join ',') -eq $before) 'Place du widget changee par la pause'
            Expect ([string](Get-DomeniaSetting 'Dashboard.Fleet.Layout' '') -like '*"Id":"w-pause"*"Paused":true*') 'Pause non enregistree avec la disposition'
            Expect ([string](Get-DomeniaBoardState 'Fleet').UndoText -eq 'Mesure suspendue') 'Pause non annulable'
            Expect (@(Get-DomeniaBoardProbeIds) -notcontains 'disk.cfree') 'Requete suspendue encore dans Analyser la liste et l actualisation de l OU'
            $script:ParkCalls.Clear()
            Start-DomeniaWidgetProbe -Board Fleet
            Start-DomeniaParkAnalysis
            Expect (@($script:ParkCalls|Where-Object{@($_.Probes|Where-Object{($null -ne $_) -and ([string]$_.Id -eq 'disk.cfree')}).Count}).Count -eq 0) 'Requete suspendue lancee par une collecte de liste'
            $parks=$script:ParkCalls.Count
            Expect (-not (Start-DomeniaWidgetRefresh -Board Fleet -Id 'w-pause' -Reason Refresh)) 'Widget suspendu actualise'
            Expect ($script:ParkCalls.Count -eq $parks) 'Collecte du widget suspendu'
            $holder=Find-DomeniaBoardHolder (Get-DomeniaControl 'PnlFleetDashboard') 'w-pause'
            Expect (($null -ne $holder) -and [bool]$holder.Tag['Paused']) 'Widget suspendu retire du tableau'
            $texts=@(Get-Texts $holder|ForEach-Object{[string]$_.Text})
            Expect (@($texts|Where-Object{$_ -like 'Mesure suspendue*'}).Count -eq 1) ('Etat suspendu non dit : '+($texts -join ' | '))
            Expect (@($texts|Where-Object{$_ -like 'Espace libre sur C:*'}).Count -ge 1) ('Titre du widget suspendu : '+($texts -join ' | '))
            $resume=@(Get-DomeniaLogicalControls $holder|Where-Object{$_ -is [Windows.Controls.Button] -and $_.Tag -is [hashtable] -and [string]$_.Tag['Action'] -eq 'Resume'})
            Expect ($resume.Count -ge 1) 'Bouton Reprendre la mesure absent'
            $script:ParkCalls.Clear()
            $resume[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            Expect (-not (Test-DomeniaBoardItemPaused -Item @(Get-Layout Fleet|Where-Object{$_.Id -eq 'w-pause'})[0])) 'Mesure non reprise'
            Expect (($script:ParkCalls.Count -eq 1) -and ($script:ParkCalls[0].Reuse -eq 30) -and (-not $script:ParkCalls[0].Force) -and (@($script:ParkCalls[0].Targets).Count -eq 2)) 'La reprise ne collecte pas ce qui manque'
            Expect (-not $script:ParkCalls[0].Preapproved) 'Reprise lancee sans confirmation du nombre'
            # Pausing again stops the run started only for this widget.
            $script:ParkStops.Clear()
            Invoke-DomeniaBoardAction -Tag @{Board='Fleet';Id='w-pause';Action='Pause'}
            Expect (($script:ParkStops.Count -eq 1) -and (Get-DomeniaParkRun -Slot 'List').Completed) 'Releve du seul widget suspendu non arrete'
        }finally{$script:ParkRuns=$null;$script:DomeniaWidgetCollectQueue.Clear();$script:DomeniaWidgetCollects.Clear();if($null -ne $script:DomeniaWidgetCollectTimer){$script:DomeniaWidgetCollectTimer.Stop()};$script:FleetScopeDn='';Set-DomeniaSetting 'Dashboard.Fleet.Layout' $saved;$tabs.SelectedItem=$oldTab}
    }
    Case 'Clavier : un widget prend le focus, F5 l actualise, Suppr le retire en personnalisation, taille pas a pas (point 80)' {
        Update-DomeniaSoftwareDashboard -Rows (New-SoftwareRows)
        $panel=Get-DomeniaControl 'PnlSoftwareDashboard'
        $holder=@(Get-Holders $panel)[0];$id=[string]$holder.Tag.Id
        Expect $holder.Focusable 'Widget hors du parcours clavier'
        Expect ([Windows.Automation.AutomationProperties]::GetHelpText($holder) -like '*Maj+F10*F5*Alt+fl*') 'Raccourcis non annonces'
        $source=[Windows.PresentationSource]::FromVisual($w)
        $press={param($Target,[Windows.Input.Key]$Key) $keyArgs=[Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice,$source,0,$Key);$keyArgs.RoutedEvent=[Windows.Input.Keyboard]::PreviewKeyDownEvent;$Target.RaiseEvent($keyArgs);return [bool]$keyArgs.Handled}
        $load=Get-DomeniaControl 'BtnLoadSoftware';$load.IsEnabled=$true;$script:LoadClicks=0;$load.Add_Click({$script:LoadClicks++})
        Expect (& $press $holder ([Windows.Input.Key]::F5)) 'F5 non pris par le widget'
        Expect ($script:LoadClicks -eq 1) ('F5 : liste des logiciels relue '+$script:LoadClicks+' fois')
        Expect (-not (& $press $holder ([Windows.Input.Key]::Delete))) 'Suppr retire un widget hors personnalisation'
        Invoke-DomeniaBoardAction -Tag @{Board='Software';Action='Customize'}
        try{
            $holder=Find-DomeniaBoardHolder $panel $id
            $size=[string]@(Get-Layout Software|Where-Object{$_.Id -eq $id})[0].Size
            Invoke-DomeniaBoardAction -Tag @{Board='Software';Id=$id;Action='Size';Value='Grow'}
            Expect ([string]@(Get-Layout Software|Where-Object{$_.Id -eq $id})[0].Size -eq (Get-DomeniaBoardNextSize -Size $size -Step 1)) 'Taille non agrandie d un pas'
            $holder=Find-DomeniaBoardHolder $panel $id
            Expect (& $press $holder ([Windows.Input.Key]::Delete)) 'Suppr non pris en personnalisation'
            Expect (@(Get-Layout Software|Where-Object{$_.Id -eq $id}).Count -eq 0) 'Widget non retire par Suppr'
            Invoke-DomeniaBoardAction -Tag @{Board='Software';Action='Undo'}
            Invoke-DomeniaBoardAction -Tag @{Board='Software';Action='Undo'}
            Expect ([string]@(Get-Layout Software|Where-Object{$_.Id -eq $id})[0].Size -eq $size) 'Annulation du retrait et de la taille'
        }finally{if((Get-DomeniaBoardState 'Software').Editing){Invoke-DomeniaBoardAction -Tag @{Board='Software';Action='Customize'}}}
    }
    Case 'Comprendre ce chiffre : panneau dans la page, formule, perimetre, criteres, exclusions, couverture, dates et postes (point 6)' {
        $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid';$script:FleetStale=$false;$script:FleetJobId=''
        try{
            Complete-DomeniaFleetDashboard -Result (New-FleetResult -Scope $script:FleetScopeDn) -State $null
            if($null -ne $script:DomeniaQueryState.Timer){$script:DomeniaQueryState.Timer.Stop()}
            $item=@(Get-Layout Fleet|Where-Object{$_.Key -eq 'fleet.stale'})[0]
            $before=$script:StartCalls.Count;$parks=$script:ParkCalls.Count
            $run=Invoke-EditorTrial {Show-DomeniaWidgetExplanation -Board Fleet -Id ([string]$item.Id);$true} {
                param($c,$t)
                $grid=Find-Named $c 'Explication du chiffre'
                $t.Seen['Aspects']=@($grid.ItemsSource|ForEach-Object{[string]$_.Aspect}) -join ','
                $t.Seen['Formula']=[string]@($grid.ItemsSource)[1].Text
                $t.Seen['Scope']=[string]@($grid.ItemsSource)[2].Text
                $t.Seen['Members']=[string]@($grid.ItemsSource)[7].Text
                $t.Seen['Buttons']=@($c|Where-Object{$_ -is [Windows.Controls.Button]}|ForEach-Object{[string]$_.Content}) -join ','
                $close=@($c|Where-Object{$_ -is [Windows.Controls.Button] -and [string]$_.Content -eq 'Fermer'})[0]
                $close.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            }
            Expect ($run.Trial.Seen['Aspects'] -ceq 'Valeur affichée,Formule,Périmètre,Critères,Exclusions,Couverture,Dates,Postes du total,Actualiser ce widget') ('Lignes : '+$run.Trial.Seen['Aspects'])
            Expect ($run.Trial.Seen['Formula'] -ceq [string](Get-DomeniaWidgetSource -Key 'fleet.stale').Formula) 'Formule'
            Expect ($run.Trial.Seen['Scope'] -like 'OU=Postes,DC=example,DC=invalid et ses sous-OU · 2 compte(s) activ*') ('Perimetre : '+$run.Trial.Seen['Scope'])
            $count=@($script:FleetLast.WidgetTargets['fleet.stale']).Count
            Expect ($run.Trial.Seen['Members'] -like ([string]$count+' poste(s) : liste exacte des GUID*')) ('Postes : '+$run.Trial.Seen['Members'])
            Expect ($run.Trial.Seen['Buttons'] -like '*Afficher les postes*Actualiser ce widget*Fermer*') ('Boutons : '+$run.Trial.Seen['Buttons'])
            Expect (($script:StartCalls.Count -eq $before) -and ($script:ParkCalls.Count -eq $parks)) 'L explication a lance une lecture'
            # A calculation replaced while the panel is open (timers keep running): its list button is refused.
            $script:Trace.Clear();$draft=[string](Get-DomeniaQueryDraft).Name
            $replaced=Invoke-EditorTrial {Show-DomeniaWidgetExplanation -Board Fleet -Id ([string]$item.Id);$true} {
                param($c,$t)
                $script:FleetQuerySnapshotKey='calcul-suivant'
                $list=@($c|Where-Object{($_ -is [Windows.Controls.Button]) -and ([string]$_.Content -eq 'Afficher les postes')})[0]
                $list.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            }
            if($null -ne $script:DomeniaQueryState.Timer){$script:DomeniaQueryState.Timer.Stop()}
            Expect (@($script:Trace|Where-Object{$_ -like ('Ce chiffre vient d'+[char]0x02BC+'un calcul remplac*')}).Count -eq 1) 'Liste d un calcul remplace ouverte depuis l explication'
            Expect ([string](Get-DomeniaQueryDraft).Name -ceq $draft) 'Selection ouverte malgre le refus'
        }finally{$script:FleetScopeDn=''}
    }
    Case 'Detail d un chiffre : liste exacte du calcul affiche, avec son compte et sa date ; un calcul remplace est refuse (point 73)' {
        $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid';$script:FleetStale=$false;$script:FleetJobId=''
        $tabs=Get-DomeniaControl 'WorkspaceTabs';$oldTab=$tabs.SelectedItem
        try{
            $tabs.SelectedItem=Get-DomeniaControl 'TabDashboard';$w.UpdateLayout()
            Complete-DomeniaFleetDashboard -Result (New-FleetResult -Scope $script:FleetScopeDn) -State $null
            if($null -ne $script:DomeniaQueryState.Timer){$script:DomeniaQueryState.Timer.Stop()}
            $item=@(Get-Layout Fleet|Where-Object{$_.Key -eq 'fleet.stale'})[0]
            $holder=Find-DomeniaBoardHolder (Get-DomeniaControl 'PnlFleetDashboard') ([string]$item.Id)
            $details=@(Get-DomeniaLogicalControls $holder.Tag.Chrome|Where-Object{$_ -is [Windows.Controls.Button] -and $_.Tag -is [hashtable] -and [string]$_.Tag['Action'] -eq 'Details'})[0]
            Expect ([string]$details.Tag['Snapshot'] -ceq [string]$script:FleetQuerySnapshotKey) 'Le chiffre ne porte pas son calcul'
            $script:Trace.Clear();$tag=$details.Tag.Clone();$tag['Snapshot']='calcul-remplace'
            Invoke-DomeniaBoardAction -Tag $tag
            Expect (@($script:Trace|Where-Object{$_ -like ('Ce chiffre vient d'+[char]0x02BC+'un calcul remplac*')}).Count -eq 1) 'Calcul remplace accepte'
            $details.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            if($null -ne $script:DomeniaQueryState.Timer){$script:DomeniaQueryState.Timer.Stop()}
            $draft=Get-DomeniaQueryDraft;$count=@($script:FleetLast.WidgetTargets['fleet.stale']).Count
            Expect ([string]$draft.Name -like ('S*lection : *'+[char]0x00B7+' '+$count+' poste*calcul du *')) ('Nom de la selection : '+[string]$draft.Name)
            Expect ((Get-DomeniaQueryIdentitySelection $draft).Count -eq $count) 'GUID de la selection differents du chiffre'
        }finally{$script:FleetScopeDn='';$tabs.SelectedItem=$oldTab}
    }
    Case 'Largeurs de 1920 a 960 points (100 a 200 %) : chaque widget tient dans la page avec ses boutons (point 80, qualification)' {
        $tabs=Get-DomeniaControl 'WorkspaceTabs';$oldTab=$tabs.SelectedItem;$oldWidth=$w.Width;$saved=[string](Get-DomeniaSetting 'Dashboard.Fleet.Layout' '')
        try{
            $tabs.SelectedItem=Get-DomeniaControl 'TabDashboard'
            $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid';$script:FleetStale=$false;$script:FleetJobId=''
            # The widest representations of the catalog in their large size.
            $wide=@(Get-Layout Fleet|ForEach-Object{if($_.Key -in @('fleet.attention','fleet.ou','fleet.versions')){Update-DomeniaBoardItem -Layout @($_) -Id $_.Id -Changes @{Size='L'}}else{$_}})
            Set-DomeniaBoardLayout -Board Fleet -Layout $wide
            Complete-DomeniaFleetDashboard -Result (New-FleetResult -Scope $script:FleetScopeDn) -State $null
            if($null -ne $script:DomeniaQueryState.Timer){$script:DomeniaQueryState.Timer.Stop()}
            foreach($width in @(1920,1280,960)){
                $w.Width=$width;$w.UpdateLayout();Invoke-Pump 80;$w.UpdateLayout()
                $panel=Get-DomeniaControl 'PnlFleetDashboard';$limit=$panel.ActualWidth+1
                $holders=@(Get-Holders $panel)
                Expect ($holders.Count -gt 0) ('Aucun widget a '+$width)
                foreach($holder in $holders){
                    $right=$holder.TranslatePoint([Windows.Point]::new($holder.ActualWidth,0),$panel).X
                    Expect ($right -le $limit) ('Widget coupe a '+$width+' : '+[Windows.Automation.AutomationProperties]::GetName($holder)+' '+[int]$right+'/'+[int]$limit)
                    # The round buttons overhang the holder by 4 points by design, inside the card margin.
                    $chromeRight=$holder.Tag.Chrome.TranslatePoint([Windows.Point]::new($holder.Tag.Chrome.ActualWidth,0),$panel).X
                    Expect ($chromeRight -le ($limit+4)) ('Boutons du widget hors de la page a '+$width)
                }
            }
        }finally{$w.Width=$oldWidth;$w.UpdateLayout();$script:FleetScopeDn='';Set-DomeniaSetting 'Dashboard.Fleet.Layout' $saved;$tabs.SelectedItem=$oldTab}
    }
    Case 'Widget en file : apres un releve, attend le recalcul de l OU puis collecte ; une autre OU l abandonne et le dit (demande David)' {
        $tabs=Get-DomeniaControl 'WorkspaceTabs';$oldTab=$tabs.SelectedItem;$saved=[string](Get-DomeniaSetting 'Dashboard.Fleet.Layout' '');$oldPath=$script:DatabaseScopedPath;$oldSelected=$script:SelectedObject
        $running={param([string]$Id) [pscustomobject]@{Id=$Id;Slot='List';ScopeKind='Results';Epoch=1L;Completed=$false;Loading=$false;Approved=$true;Done=0;Targets=@('PC-1','PC-2');Failed=0;Online=0;NoReply=0;Errors=0;Unchecked=0;Reused=0;Changed=0;CachedMeasurements=0;Pending=@{};Concurrency=4;Stopping=$false;PingOnly=$false;WmiOnly=$false;Scope='Results';StatusText='';ShortText='';FailureMessage='';Logged=$false;FleetRefresh=$true}}
        try{
            $tabs.SelectedItem=Get-DomeniaControl 'TabDashboard';$w.UpdateLayout()
            $script:SelectedObject=$null;$script:DatabaseScopedPath='C:\fictif\domenia.db'
            $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid';$script:FleetStale=$false;$script:FleetJobId='';$script:FleetPendingKey=''
            Complete-DomeniaFleetDashboard -Result (New-FleetResult -Scope $script:FleetScopeDn) -State $null
            if($null -ne $script:DomeniaQueryState.Timer){$script:DomeniaQueryState.Timer.Stop()}
            Set-DomeniaBoardLayout -Board Fleet -Layout @(Add-DomeniaBoardItem -Layout @(Get-Layout Fleet) -Item (New-DomeniaBoardItem -Source Probe -Key 'disk.cfree' -Visual Column -Group 'Mesures' -Id 'w-queue'))
            # Analyser la liste holds the engine: the refresh of the widget waits.
            $script:ParkRuns=@{List=(& $running 'liste')};$script:ParkCalls.Clear()
            Expect (Start-DomeniaWidgetRefresh -Board Fleet -Id 'w-queue' -Reason Refresh) 'Actualisation non mise en file'
            Expect ($script:DomeniaWidgetCollectQueue.Count -eq 1) 'File d attente du widget'
            # The run ends through the real path: its stored observations ask the recalculation of the OU shown.
            $jobs=$script:StartCalls.Count
            (Get-DomeniaParkRun -Slot 'List').Done=2;(Get-DomeniaParkRun -Slot 'List').Completed=$true
            Update-DomeniaParkRunStatus
            Expect (($script:StartCalls.Count -eq ($jobs+1)) -and ([bool][string]$script:FleetJobId)) 'Recalcul de l OU non demande a la fin du releve'
            Update-DomeniaWidgetCollectProgress
            Expect (($script:ParkCalls.Count -eq 0) -and ($script:DomeniaWidgetCollectQueue.Count -eq 1)) 'Collecte partie pendant le recalcul, ou widget perdu'
            Expect ((Get-DomeniaWidgetCollectProgress -Board Fleet -Id 'w-queue') -ceq ('En file : en attente du recalcul de l'+[char]0x02BC+'OU.')) ('Etat : '+(Get-DomeniaWidgetCollectProgress -Board Fleet -Id 'w-queue'))
            # A click during the recalculation waits too, never refused with Actualisez le tableau de bord; nothing is
            # computed twice.
            $script:Trace.Clear();$jobs=$script:StartCalls.Count
            Expect (Start-DomeniaWidgetRefresh -Board Fleet -Id 'w-queue' -Reason Refresh) 'Clic pendant le recalcul refuse'
            Expect (($script:ParkCalls.Count -eq 0) -and ($script:DomeniaWidgetCollectQueue.Count -eq 1) -and ($script:StartCalls.Count -eq $jobs)) 'Clic pendant le recalcul : collecte lancee, widget en double ou recalcul relance'
            Expect (@($script:Trace|Where-Object{$_ -like 'Actualisez le tableau de bord*'}).Count -eq 0) 'Clic refuse pendant le recalcul'
            # The recalculation is drawn: the next watch tick starts the queued widget on the OU of its gesture.
            Complete-DomeniaFleetDashboard -Result (New-FleetResult -Scope $script:FleetScopeDn) -State ($script:StartCalls[$script:StartCalls.Count-1].State)
            if($null -ne $script:DomeniaQueryState.Timer){$script:DomeniaQueryState.Timer.Stop()}
            Expect ((-not [string]$script:FleetJobId) -and (-not $script:FleetStale)) 'Recalcul de l OU non termine'
            Update-DomeniaWidgetCollectProgress
            Expect (($script:ParkCalls.Count -eq 1) -and ($script:ParkCalls[0].Force) -and (@($script:ParkCalls[0].Targets).Count -eq 2) -and ($script:DomeniaWidgetCollectQueue.Count -eq 0)) 'Widget en file jamais collecte apres le recalcul'
            # Another OU shown before the end of the run: the queued collection never moves to it.
            $script:ParkRuns=@{List=(& $running 'liste-2')};$script:ParkCalls.Clear();$script:Trace.Clear()
            Expect (Start-DomeniaWidgetRefresh -Board Fleet -Id 'w-queue' -Reason Refresh) 'Deuxieme mise en file'
            $script:FleetScopeDn='OU=Serveurs,DC=example,DC=invalid'
            (Get-DomeniaParkRun -Slot 'List').Completed=$true;Update-DomeniaWidgetCollectProgress
            Expect (($script:ParkCalls.Count -eq 0) -and ($script:DomeniaWidgetCollectQueue.Count -eq 0)) 'Collecte partie sur une OU non demandee'
            Expect (@($script:Trace|Where-Object{$_ -like ('Collecte en file abandonn*l'+[char]0x02BC+'OU affich*a chang*')}).Count -eq 1) 'Abandon de la collecte non dit'
        }finally{$script:ParkRuns=$null;$script:DomeniaWidgetCollectQueue.Clear();$script:DomeniaWidgetCollects.Clear();if($null -ne $script:DomeniaWidgetCollectTimer){$script:DomeniaWidgetCollectTimer.Stop()};if($null -ne $script:DomeniaQueryState.Timer){$script:DomeniaQueryState.Timer.Stop()};$script:FleetScopeDn='';$script:FleetJobId='';$script:FleetPendingKey='';$script:FleetStale=$false;$script:DatabaseScopedPath=$oldPath;$script:SelectedObject=$oldSelected;Set-DomeniaSetting 'Dashboard.Fleet.Layout' $saved;$tabs.SelectedItem=$oldTab}
    }
    Case 'Widget du poste : la collecte demandee pour un poste ne s affiche ni ne part sur un autre poste (demande David)' {
        $saved=[string](Get-DomeniaSetting 'Dashboard.Computer.Layout' '');$oldSelected=$script:SelectedObject
        $pcA=[pscustomobject]@{DN='CN=PC-A,OU=Postes,DC=example,DC=invalid';Type='Machine';Name='PC-A';Safety=[pscustomobject]@{Guid='00000000-0000-4000-8000-00000000000a'}}
        $pcB=[pscustomobject]@{DN='CN=PC-B,OU=Postes,DC=example,DC=invalid';Type='Machine';Name='PC-B';Safety=[pscustomobject]@{Guid='00000000-0000-4000-8000-00000000000b'}}
        try{
            # FI-18: a survey of the list runs; the widget of the open workstation reads in its own scope beside it.
            $script:SelectedObject=$pcA;$script:ParkRuns=@{List=[pscustomobject]@{Id='liste';Slot='List';Completed=$false;Loading=$false;Approved=$true;Done=0;Targets=@();Failed=0}};$script:ParkCalls.Clear()
            $group=[string]@(Get-Layout Computer)[0].Group
            Set-DomeniaBoardLayout -Board Computer -Layout @(Add-DomeniaBoardItem -Layout @(Get-Layout Computer) -Item (New-DomeniaBoardItem -Source Probe -Key 'disk.cfree' -Visual Kpi -Group $group -Id 'c-probe'))
            Expect (Start-DomeniaWidgetRefresh -Board Computer -Id 'c-probe' -Reason Refresh) 'Collecte du poste non lancee'
            Expect (($script:ParkCalls.Count -eq 1) -and ($script:ParkCalls[0].Slot -eq 'Computer') -and ($script:DomeniaWidgetCollectQueue.Count -eq 0)) 'Widget du poste bloque par le releve de la liste'
            Expect ((@($script:ParkCalls[0].Targets|ForEach-Object{$_.name}) -join ',') -eq 'PC-A') 'Poste de la collecte'
            Expect ((Get-DomeniaWidgetCollectProgress -Board Computer -Id 'c-probe') -like 'Collecte en cours*') 'Progression absente sur le poste de la collecte'
            $script:SelectedObject=$pcB
            Expect ((Get-DomeniaWidgetCollectProgress -Board Computer -Id 'c-probe') -eq '') 'Progression de PC-A affichee sur PC-B'
            $script:SelectedObject=$pcA
            Expect ((Get-DomeniaWidgetCollectProgress -Board Computer -Id 'c-probe') -like 'Collecte en cours*') 'Progression perdue au retour sur PC-A'
            # Queued for PC-A while the run holds the engine, PC-B selected before its end: nothing starts on PC-B.
            $script:ParkCalls.Clear();$script:Trace.Clear()
            Expect (Start-DomeniaWidgetRefresh -Board Computer -Id 'c-probe' -Reason Add) 'Mise en file pour PC-A'
            Expect ($script:DomeniaWidgetCollectQueue.Count -eq 1) 'File d attente du widget du poste'
            $script:SelectedObject=$pcB
            (Get-DomeniaParkRun -Slot 'Computer').Completed=$true;Update-DomeniaWidgetCollectProgress
            Expect (($script:ParkCalls.Count -eq 0) -and ($script:DomeniaWidgetCollectQueue.Count -eq 0)) 'Collecte partie sur un poste non demande'
            Expect (@($script:Trace|Where-Object{$_ -like 'Collecte en file abandonn*le poste s*lectionn*a chang*'}).Count -eq 1) 'Abandon de la collecte non dit'
        }finally{$script:ParkRuns=$null;$script:DomeniaWidgetCollectQueue.Clear();$script:DomeniaWidgetCollects.Clear();if($null -ne $script:DomeniaWidgetCollectTimer){$script:DomeniaWidgetCollectTimer.Stop()};$script:SelectedObject=$oldSelected;Set-DomeniaSetting 'Dashboard.Computer.Layout' $saved;Clear-DomeniaDashboards}
    }
    Case 'Widget AD de l OU : seule une lecture lancee par le clic est suivie, jamais une actualisation deja en cours (demande David)' {
        $oldRefresh=$script:DomeniaOuRefresh
        $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid';$script:FleetStale=$false;$script:FleetJobId='';$script:DomeniaWidgetCollects.Clear()
        try{
            Complete-DomeniaFleetDashboard -Result (New-FleetResult -Scope $script:FleetScopeDn) -State $null
            if($null -ne $script:DomeniaQueryState.Timer){$script:DomeniaQueryState.Timer.Stop()}
            $item=@(Get-Layout Fleet|Where-Object{$_.Key -eq 'fleet.stale'})[0]
            # A ping refresh of the OU is running: the AD read of the widget is refused (Refresh.UI is not loaded).
            $script:OuRefreshCalls=0
            function Invoke-DomeniaOuRefresh {param($Source,$Mode) $script:OuRefreshCalls++;if(-not $script:OuRefreshAccept){Set-Status 'Une actualisation est déjà en cours.' 'WARN';return};$script:DomeniaOuRefresh=[pscustomobject]@{Id='ad-widget';Completed=$false;Mode=$Mode}}
            $script:DomeniaOuRefresh=[pscustomobject]@{Id='ping-en-cours';Completed=$false;Mode='Ping'};$script:OuRefreshAccept=$false
            Expect (-not (Start-DomeniaWidgetRefresh -Board Fleet -Id ([string]$item.Id) -Reason Refresh)) 'Actualisation refusee annoncee comme lancee'
            Expect (($script:OuRefreshCalls -eq 1) -and (-not $script:DomeniaWidgetCollects.ContainsKey('Fleet|'+[string]$item.Id))) 'Widget rattache a une actualisation qu il n a pas lancee'
            $script:DomeniaOuRefresh=$null;$script:OuRefreshAccept=$true
            Expect (Start-DomeniaWidgetRefresh -Board Fleet -Id ([string]$item.Id) -Reason Refresh) 'Lecture AD du widget non suivie'
            Expect ([string]$script:DomeniaWidgetCollects['Fleet|'+[string]$item.Id].RunId -ceq 'ad-widget') 'Mauvaise lecture suivie'
            Expect ((Get-DomeniaWidgetCollectProgress -Board Fleet -Id ([string]$item.Id)) -eq ('Lecture AD de l'+[char]0x02BC+'OU en cours'+[char]0x2026)) 'Progression de la lecture AD'
        }finally{$script:DomeniaOuRefresh=$oldRefresh;$script:DomeniaWidgetCollects.Clear();if($null -ne $script:DomeniaWidgetCollectTimer){$script:DomeniaWidgetCollectTimer.Stop()};$script:FleetScopeDn=''}
    }
    Case 'Requetes des widgets : bibliotheque indexee une fois par version, jamais reanalysee a chaque dessin' {
        $q=$script:DomeniaQueryState;$oldSaved=$q.Saved;$oldLibrary=$script:TestSettings['Query.Library'];$hadLibrary=$script:TestSettings.ContainsKey('Query.Library')
        try{
            # Workshop list: the index follows the list itself, rebuilt only when the workshop assigns a new one.
            $first=Get-DomeniaWidgetRecipeIndex
            Expect ([object]::ReferenceEquals($first,(Get-DomeniaWidgetRecipeIndex))) 'Index reconstruit sans changement de bibliotheque'
            $one=[pscustomobject]@{Id='r-un';Name='Une'}
            $q.Saved=@($one,[pscustomobject]@{Id='r-double';Name='A'},[pscustomobject]@{Id='r-double';Name='B'})
            Expect ([object]::ReferenceEquals((Get-DomeniaWidgetRecipe -Id 'r-un'),$one)) 'Nouvelle liste de l atelier ignoree'
            Expect ($null -eq (Get-DomeniaWidgetRecipe -Id 'r-double')) 'Requete ambigue resolue'
            Expect ($null -eq (Get-DomeniaWidgetRecipe -Id 'R-UN')) 'Identifiant compare sans la casse'
            # Workshop never opened: the saved library text is parsed once per text, not once per widget and redraw.
            $script:DomeniaQueryState=$null;$script:LibraryParses=0
            function ConvertFrom-DomeniaQueryLibrary {param($Text) $script:LibraryParses++;return @([pscustomobject]@{Id='t-un';Name='Texte'})}
            Set-DomeniaSetting 'Query.Library' '[{"fixture":1}]'
            Expect ([string](Get-DomeniaWidgetRecipe -Id 't-un').Name -eq 'Texte') 'Requete de la bibliotheque enregistree'
            [void](Get-DomeniaWidgetRecipe -Id 't-un');[void](Get-DomeniaWidgetRecipe -Id 'absente')
            Expect ($script:LibraryParses -eq 1) ('Bibliotheque analysee '+$script:LibraryParses+' fois')
            Set-DomeniaSetting 'Query.Library' '[{"fixture":2}]'
            [void](Get-DomeniaWidgetRecipe -Id 't-un')
            Expect ($script:LibraryParses -eq 2) 'Bibliotheque modifiee non relue'
        }finally{$script:DomeniaQueryState=$q;$q.Saved=$oldSaved;if($hadLibrary){$script:TestSettings['Query.Library']=$oldLibrary}else{[void]$script:TestSettings.Remove('Query.Library')};$script:DomeniaWidgetRecipeCache=$null}
    }
    # Lot Z03 (15/10/2026): grille fluide (DS-04), carte Sante (DS-05), poste allege (UX-11), copie pour un ticket
    # (FO-13), disposition d equipe (FO-17), editeur sans jargon, filtres et synonymes (UI-14, SP-07, SP-19).
    function script:Get-DomeniaEntryFirstString {param($Entry,[string]$Name) if(($Entry -is [hashtable]) -and $Entry.ContainsKey($Name)){return [string]$Entry[$Name]};return ''}
    function Get-Z03Object {return [pscustomobject]@{Type='Machine';Name='PC-A';DN='CN=PC-A,OU=Postes,DC=example,DC=invalid';Entry=@{userAccountControl='4096';whenCreated='2020-01-15T10:00:00Z'};Safety=[pscustomobject]@{Guid='00000000-0000-4000-8000-0000000000aa'}}}
    Case 'Grille fluide : 4, 3 ou 2 colonnes selon la largeur, tailles fixes et hauteurs alignees (DS-04)' {
        $tabs=Get-DomeniaControl 'WorkspaceTabs';$oldTab=$tabs.SelectedItem;$oldWidth=$w.Width;$saved=[string](Get-DomeniaSetting 'Dashboard.Fleet.Layout' '')
        try{
            $tabs.SelectedItem=Get-DomeniaControl 'TabDashboard'
            [void]$script:TestSettings.Remove('Dashboard.Fleet.Layout')
            $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid';$script:FleetStale=$false;$script:FleetJobId=''
            Complete-DomeniaFleetDashboard -Result (New-FleetResult -Scope $script:FleetScopeDn) -State $null
            if($null -ne $script:DomeniaQueryState.Timer){$script:DomeniaQueryState.Timer.Stop()}
            $panel=Get-DomeniaControl 'PnlFleetDashboard';$state=Get-DomeniaBoardState 'Fleet';$seen=@{};$stackedAt=@{};$page=@{}
            # The guest desktop can be narrower than 1100 px, so the window width never reaches the page.
            # The grid follows the page width: when the window is clamped, give that page the requested width.
            $scroll=$null;$node=$panel
            while($null -ne $node){$node=[Windows.Media.VisualTreeHelper]::GetParent($node);if($node -is [Windows.Controls.ScrollViewer]){$scroll=$node;break}}
            $savedScroll=$(if($null -ne $scroll){$scroll.HorizontalScrollBarVisibility}else{$null})
            $hostPanel=$panel.Parent
            foreach($width in @(1920,1280,960)){
                $w.WindowState=[Windows.WindowState]::Normal
                $w.SizeToContent=[Windows.SizeToContent]::Manual
                $w.MaxWidth=4096;$w.Left=0;$w.Top=0
                $w.Width=$width;$w.Height=900;$w.UpdateLayout()
                # A clamped desktop never shrinks a page we widened earlier. Drive the page only while the window cannot.
                if(($w.ActualWidth -lt ($width-48)) -and ($null -ne $scroll) -and ($hostPanel -is [Windows.FrameworkElement])){
                    $scroll.HorizontalScrollBarVisibility=[Windows.Controls.ScrollBarVisibility]::Auto
                    $hostPanel.HorizontalAlignment=[Windows.HorizontalAlignment]::Left
                    $hostPanel.Width=[double]$width
                    $w.UpdateLayout()
                }elseif($hostPanel -is [Windows.FrameworkElement]){
                    $hostPanel.ClearValue([Windows.FrameworkElement]::WidthProperty)
                    $hostPanel.ClearValue([Windows.FrameworkElement]::HorizontalAlignmentProperty)
                    if($null -ne $scroll -and $null -ne $savedScroll){$scroll.HorizontalScrollBarVisibility=$savedScroll}
                    $w.UpdateLayout()
                }
                # Update-DomeniaBoardGrid redraws the cards 300 ms after the last width. Read them only after that.
                Invoke-Pump 800;$w.UpdateLayout()
                $stacked=0
                $columns=[int]$state.GridColumns;$seen[$width]=$columns;$page[$width]=[int]$panel.ActualWidth
                Expect ($columns -eq (Get-DomeniaBoardColumnCount -Width $panel.ActualWidth -Current $columns)) ('Colonnes incoherentes avec la largeur a '+$width)
                Expect (-not (Test-DomeniaBoardRedrawNeeded -Columns $columns -BuiltColumns ([int]$state.GridBuiltColumns) -Cell ([double]$state.GridCell) -BuiltCell ([double]$state.GridBuiltCell))) ('Widgets non redessines a la nouvelle largeur : '+$width)
                $grids=@(Get-DomeniaBoardSectionGrids $panel)
                Expect ($grids.Count -ge 4) ('Sections en grille a '+$width+' : '+$grids.Count)
                $cell=$panel.ActualWidth/$columns
                foreach($grid in $grids){
                    Expect ($grid.ColumnDefinitions.Count -eq $columns -and [int]$grid.Tag['Columns'] -eq $columns) ('Grille de '+$grid.ColumnDefinitions.Count+' colonnes au lieu de '+$columns)
                    foreach($row in @($grid.Children|Group-Object {[Windows.Controls.Grid]::GetRow($_)})){
                        $span=0;foreach($child in $row.Group){$span+=[Windows.Controls.Grid]::GetColumnSpan($child)}
                        # DS-04 (decision RC1.17.11): les tailles S/M/L sont fixes, la derniere rangee d'une section
                        # peut rester incomplete ; seule une rangee vide ou plus large que la grille reste un defaut.
                        Expect ($span -gt 0 -and $span -le $columns) ('Rangee hors grille a '+$width+' : '+$span+' sur '+$columns)
                        # Two stacked compact tiles end on the bottom of their row, like the tall card beside them.
                        $bottoms=@(foreach($child in $row.Group){
                            $last=if(($child.Tag -is [hashtable]) -and ($child.Tag.ContainsKey('Chrome'))){$child}else{@(Get-Holders $child)|Select-Object -Last 1}
                            if($null -ne $last){$last.TranslatePoint([Windows.Point]::new(0,$last.ActualHeight),$grid).Y}
                        })
                        if($bottoms.Count -gt 1){
                            $sorted=@($bottoms|Sort-Object)
                            Expect (($sorted[$sorted.Count-1]-$sorted[0]) -le 1.5) ('Bas des cartes non alignes a '+$width+' : '+($sorted -join ','))
                        }
                        foreach($stack in @($row.Group|Where-Object{($_.Tag -is [hashtable]) -and ($_.Tag.ContainsKey('Stacked'))})){
                            $pair=@(Get-Holders $stack)
                            Expect ($pair.Count -eq 2) ('Pile de '+$pair.Count+' tuiles a '+$width)
                            $stacked++
                            $expected=Get-DomeniaBoardCardWidth -Span ([Windows.Controls.Grid]::GetColumnSpan($stack)) -CellWidth $cell
                            foreach($tile in $pair){Expect ([Math]::Abs([double]$tile.Children[0].Width-$expected) -le 1) ('Tuile empilee non etiree sur sa colonne : '+[Windows.Automation.AutomationProperties]::GetName($tile))}
                        }
                        $holders=@($row.Group|Where-Object{($_.Tag -is [hashtable]) -and ($_.Tag.ContainsKey('Chrome'))})
                        if($holders.Count -gt 1){
                            $heights=@($holders|ForEach-Object{[double]$_.ActualHeight}|Sort-Object)
                            Expect (($heights[$heights.Count-1]-$heights[0]) -le 1.5) ('Hauteurs non alignees a '+$width+' : '+($heights -join ','))
                        }
                        foreach($holder in $holders){
                            $expected=Get-DomeniaBoardCardWidth -Span ([Windows.Controls.Grid]::GetColumnSpan($holder)) -CellWidth $cell
                            Expect ([Math]::Abs([double]$holder.Children[0].Width-$expected) -le 1) ('Carte non etiree sur ses colonnes : '+[Windows.Automation.AutomationProperties]::GetName($holder))
                            $right=$holder.TranslatePoint([Windows.Point]::new($holder.ActualWidth,0),$panel).X
                            Expect ($right -le $panel.ActualWidth+1) ('Widget hors de la page a '+$width)
                        }
                    }
                }
                $stackedAt[$width]=$stacked
            }
            Expect ([int]$seen[1920] -gt [int]$seen[960]) ('Colonnes : '+[int]$seen[1920]+' a 1920 (page '+[int]$page[1920]+'), '+[int]$seen[960]+' a 960 (page '+[int]$page[960]+'), fenetre '+[int]$w.ActualWidth)
            Expect ([int]$stackedAt[1920] -gt 0) 'Aucune paire de tuiles empilees a 1920 : alignement des piles non verifie'
        }finally{
            if($null -ne $scroll -and $null -ne $savedScroll){$scroll.HorizontalScrollBarVisibility=$savedScroll}
            if($hostPanel -is [Windows.FrameworkElement]){$hostPanel.ClearValue([Windows.FrameworkElement]::WidthProperty);$hostPanel.ClearValue([Windows.FrameworkElement]::HorizontalAlignmentProperty)}
            $w.Width=$oldWidth;$w.UpdateLayout();Invoke-Pump 450;$script:FleetScopeDn='';Set-DomeniaSetting 'Dashboard.Fleet.Layout' $saved;$tabs.SelectedItem=$oldTab
        }
    }
    Case 'Carte Sante : score et points a verifier dans une seule carte, ligne verte sans point (DS-05)' {
        $oldSelected=$script:SelectedObject
        try{
            $script:SelectedObject=$null
            Update-DomeniaComputerDashboard -Result (New-InventoryResult)
            $panel=Get-DomeniaControl 'PnlComputerDashboard'
            $holder=@(Get-Holders $panel|Where-Object{[string]$_.Tag.Item.Key -eq 'computer.health'})
            Expect ($holder.Count -eq 1) 'Carte Sante absente'
            Expect (@(Get-Holders $panel|Where-Object{[string]$_.Tag.Item.Key -eq 'computer.attention'}).Count -eq 0) 'Liste des points en double'
            $entry=(Get-DomeniaBoardState 'Computer').Data.Entries['computer.health']
            Expect (@($entry.Points).Count -ge 1) 'Points absents de l entree de sante'
            $texts=@(Get-Texts $holder[0]|ForEach-Object{[string]$_.Text})
            Expect ($texts -contains [string]$entry.PointsTitle) ('Titre des points : '+($texts -join ' | '))
            Expect ($texts -contains [string]$entry.Value) 'Verdict absent de la carte'
            foreach($point in @($entry.Points)){Expect ($texts -contains [string]$point.Text) ('Point absent de la carte : '+[string]$point.Text)}
            Expect (@(Get-DomeniaLogicalControls $holder[0].Tag.Chrome|Where-Object{($_ -is [Windows.Controls.Button]) -and ($_.Tag -is [hashtable]) -and ([string]$_.Tag['Action'] -eq 'HealthExplanation')}).Count -eq 1) 'Comprendre le score absent'
            # Nothing to check and an established score: one green line; a withheld score: no reassuring line.
            $calm=New-DomeniaBoardData -Board Computer;[void](Complete-DomeniaBoardData -Data $calm)
            $card=New-DomeniaWidgetVisual -Entry $calm.Entries['computer.health'] -Visual HealthSummary -Title 'Santé du poste' -Size (Get-DomeniaBoardSize -Visual HealthSummary -Size L) -Board Computer
            $tw=Show-InTestWindow $card
            try{
                $green=@(Get-Texts $card|Where-Object{[string]$_.Text -eq 'Rien à signaler'})
                Expect ($green.Count -eq 1) 'Ligne verte absente'
                Expect ($green[0].Foreground.Color -eq $w.Resources['StatusSuccess'].Color) 'Ligne sans point non verte'
                Expect ([double]::IsNaN([double]$card.Height)) ('Hauteur fixe au lieu du contenu : '+$card.Height)
            }finally{$tw.Close()}
            $thin=New-DomeniaBoardData -Board Fleet
            Add-Member -InputObject $thin -MemberType NoteProperty -Name 'Population' -Value ([pscustomobject]@{Total=40;Healthy=3;Unassessed=36})
            [void](Complete-DomeniaBoardData -Data $thin)
            $withheld=New-DomeniaWidgetVisual -Entry $thin.Entries['fleet.health'] -Visual HealthSummary -Title 'Santé du parc' -Size (Get-DomeniaBoardSize -Visual HealthSummary -Size L) -Board Fleet
            $withheldTexts=@(Get-Texts $withheld|ForEach-Object{[string]$_.Text})
            Expect (($withheldTexts -contains 'Aucun problème établi') -and -not ($withheldTexts -contains 'Rien à signaler')) ('Score retenu presente comme rassurant : '+($withheldTexts -join ' | '))
            Expect (@($withheldTexts|Where-Object{$_ -like '*couverture*'}).Count -ge 1) 'Couverture absente a cote de la sante'
        }finally{$script:SelectedObject=$oldSelected}
    }
    Case 'Poste allege : 14 widgets livres, fiches Identite et Compte machine, liste d etat (UX-11)' {
        $saved=[string](Get-DomeniaSetting 'Dashboard.Computer.Layout' '');$oldSelected=$script:SelectedObject
        try{
            [void]$script:TestSettings.Remove('Dashboard.Computer.Layout');[void]$script:TestSettings.Remove('Widgets.Computer')
            Expect (@(Get-Layout Computer).Count -eq 14) ('Widgets livres : '+@(Get-Layout Computer).Count)
            # The layout delivered before (the whole catalog, before and after the W11 tiles), saved unchanged, becomes the light one.
            foreach($legacyText in @([string]$script:DomeniaComputerLegacyLayoutText,[string]$script:DomeniaComputerW11LayoutText)){
                $old=@(foreach($line in ($legacyText -split "`n")){$value=$line.Trim();if($value){$c=$value -split '\|';[pscustomobject]@{Id=('b-'+$c[0]);Source='Builtin';Key=$c[0];Visual=$c[2];Title='';Size=$c[3];Group=$c[1]}}})
                Set-DomeniaSetting 'Dashboard.Computer.Layout' (ConvertTo-Json -InputObject $old -Depth 3 -Compress)
                Expect ((@(Get-Layout Computer|ForEach-Object{$_.Key}) -join ',') -eq (@(Get-DomeniaBoardDefaultLayout -Board Computer|ForEach-Object{$_.Key}) -join ',')) ('Ancienne disposition livree non allegee : '+$old.Count+' widgets')
            }
            [void]$script:TestSettings.Remove('Dashboard.Computer.Layout')
            $script:SelectedObject=Get-Z03Object
            $data=Get-DomeniaComputerBoardData -Result (New-InventoryResult) -Object $script:SelectedObject
            Show-DomeniaBoard -Board Computer -Data $data -Quiet
            $panel=Get-DomeniaControl 'PnlComputerDashboard'
            $find={param([string]$Key) @(Get-Holders $panel|Where-Object{[string]$_.Tag.Item.Key -eq $Key})}
            $identity=@(& $find 'computer.identity');$account=@(& $find 'computer.adaccount');$status=@(& $find 'computer.status')
            Expect (($identity.Count -eq 1) -and ($account.Count -eq 1) -and ($status.Count -eq 1)) 'Fiches ou liste d etat absentes'
            $identityTexts=@(Get-Texts $identity[0]|ForEach-Object{[string]$_.Text})
            Expect (($identityTexts -contains 'Système') -and ($identityTexts -contains 'Windows 11 24H2') -and ($identityTexts -contains 'Latitude 7450')) ('Fiche Identite : '+($identityTexts -join ' | '))
            Expect ((@(Get-Texts $account[0]|ForEach-Object{[string]$_.Text}) -contains 'Activé')) 'Fiche Compte machine sans l etat du compte'
            $statusTexts=@(Get-Texts $status[0]|ForEach-Object{[string]$_.Text})
            Expect (($statusTexts -contains 'Redémarrage en attente') -and ($statusTexts -contains 'Non lu') -and ($statusTexts -contains 'BitLocker') -and ($statusTexts -contains 'Démarrage sécurisé')) ('Liste d etat : '+($statusTexts -join ' | '))
            foreach($key in @('computer.os','computer.model','computer.ad.account','computer.antivirus','computer.secureboot','computer.updates')){Expect (@(& $find $key).Count -eq 0) ('Tuile dessinee en plus de sa fiche : '+$key)}
        }finally{$script:SelectedObject=$oldSelected;Set-DomeniaSetting 'Dashboard.Computer.Layout' $saved;Clear-DomeniaDashboards}
    }
    Case 'Copier un widget et le resume du tableau pour un ticket : texte brut, secret masque (FO-13)' {
        $oldSelected=$script:SelectedObject;$oldInventory=$script:InventoryCompletedAt;$oldComputer=$script:InventoryComputer
        try{
            $script:Clipboard=$null
            function script:Set-ClipboardSafe {param([string]$Text) $script:Clipboard=$Text}
            $script:SelectedObject=Get-Z03Object;$script:InventoryComputer='PC-A';$script:InventoryCompletedAt=[datetime]::new(2026,10,15,8,0,0,[DateTimeKind]::Utc)
            $data=Get-DomeniaComputerBoardData -Result (New-InventoryResult) -Object $script:SelectedObject
            @($data.Entries['computer.identity'].Items)[0].Detail='mot de passe : Fictif-Secret-42'
            Show-DomeniaBoard -Board Computer -Data $data -Quiet
            $panel=Get-DomeniaControl 'PnlComputerDashboard'
            $summary=@(Get-DomeniaLogicalControls $panel.Children[0]|Where-Object{($_ -is [Windows.Controls.Button]) -and ($_.Tag -is [hashtable]) -and ([string]$_.Tag['Action'] -eq 'CopySummary')})
            Expect ($summary.Count -eq 1) 'Copier le resume absent de la barre'
            $script:Trace.Clear()
            $summary[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            $text=[string]$script:Clipboard
            Expect ($text -like ('Poste PC-A · inventaire du '+$script:InventoryCompletedAt.ToLocalTime().ToString('dd/MM/yyyy HH:mm',[Globalization.CultureInfo]::InvariantCulture)+"`r`n*")) ('Entete du resume : '+$text)
            foreach($part in @('Santé : *','Identité du poste','Compte machine','État de protection','- Système : Windows 11 24H2*')){Expect (@($text -split "`r`n"|Where-Object{$_ -like $part}).Count -ge 1) ('Resume sans '+$part)}
            Expect ($text -notlike '*Fictif-Secret-42*') 'Secret copie en clair'
            Expect (@($script:Trace|Where-Object{$_ -like 'Résumé du tableau copié*'}).Count -eq 1) 'Copie non confirmee'
            $disk=@(Get-Holders $panel|Where-Object{[string]$_.Tag.Item.Key -eq 'computer.disk.system'})[0]
            Expect (@($disk.ContextMenu.Items|Where-Object{($_ -is [Windows.Controls.MenuItem]) -and ([string]$_.Header -eq 'Copier')}).Count -eq 1) 'Copier absent du menu du widget'
            Expect ([Windows.Automation.AutomationProperties]::GetHelpText($disk) -like '*Ctrl+C*') 'Raccourci de copie non annonce'
            Invoke-DomeniaBoardAction -Tag @{Board='Computer';Id=[string]$disk.Tag.Id;Action='Copy'}
            Expect ([string]$script:Clipboard -like 'Disque C: (256 Go) : 8 % libre*Libre 20 Go (8 %)*') ('Widget copie : '+[string]$script:Clipboard)
            $paused=New-DomeniaBoardMenu -Board Computer -Item ([pscustomobject]@{Id='p';Visual='Kpi';Size='S'}) -Kind Value -HasMaximum $false -Paused $true
            Expect (@($paused.Items|Where-Object{($_ -is [Windows.Controls.MenuItem]) -and ([string]$_.Header -eq 'Copier')}).Count -eq 0) 'Copier propose sur un widget suspendu'
            # The overview names the OU of the figures on screen, not the OU chosen since (calculation still running).
            $oldFleet=$script:FleetLast;$oldScope=$script:FleetScopeDn
            try{
                $script:FleetLast=[pscustomobject]@{Scope='OU=Postes,DC=example,DC=invalid';Freshness=$null};$script:FleetScopeDn='OU=Autre,DC=example,DC=invalid'
                Expect ([string](Get-DomeniaBoardDataMoment -Board Fleet).Subject -eq 'Postes') ('Objet du resume pris dans l OU choisie : '+[string](Get-DomeniaBoardDataMoment -Board Fleet).Subject)
                $script:FleetLast=[pscustomobject]@{Scope='';Freshness=$null}
                Expect ([string](Get-DomeniaBoardDataMoment -Board Fleet).Subject -eq 'Tout le domaine') 'Domaine entier non nomme'
            }finally{$script:FleetLast=$oldFleet;$script:FleetScopeDn=$oldScope}
        }finally{$script:SelectedObject=$oldSelected;$script:InventoryCompletedAt=$oldInventory;$script:InventoryComputer=$oldComputer;Clear-DomeniaDashboards}
    }
    Case 'Disposition d equipe de l administrateur, export et import JSON sans boite Windows (FO-17)' {
        $savedLayout=[string](Get-DomeniaSetting 'Dashboard.Software.Layout' '');$oldCfg=${function:Get-CfgValue};$oldPicker=${function:Show-DomeniaInlineFilePicker}
        $script:ExportFolder=Join-Path ([IO.Path]::GetTempPath()) ('domenia-z03-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($script:ExportFolder)
        $script:Banners=[Collections.Generic.List[object]]::new()
        function script:Get-DomeniaExportDirectory {return $script:ExportFolder}
        function script:Show-DomeniaPageBanner {param($Kind,$Message,$Details,$ActionText,$ActionPath);$script:Banners.Add([pscustomobject]@{Kind=$Kind;Message=$Message;ActionText=$ActionText;ActionPath=$ActionPath});return $true}
        function script:Show-DomeniaInlineFilePicker {param($Request);$script:PickerRequest=$Request;$Request.FileName=$script:PickedPath;return $true}
        try{
            $script:TeamLayout='[{"Id":"t1","Source":"Builtin","Key":"software.largest","Visual":"Bar","Size":"L","Group":"Equipe"},{"Id":"t2","Source":"Builtin","Key":"software.count","Visual":"Kpi","Size":"S","Group":"Equipe"}]'
            function script:Get-CfgValue {param($Section,$Key,$Default);if(($Section -eq 'Dashboard') -and ($Key -eq 'DefaultLayoutSoftware')){return $script:TeamLayout};return $Default}
            [void]$script:TestSettings.Remove('Dashboard.Software.Layout')
            Expect ((@(Get-Layout Software|ForEach-Object{$_.Key}) -join ',') -eq 'software.largest,software.count') 'Disposition d equipe non appliquee a un tableau jamais personnalise'
            Update-DomeniaSoftwareDashboard -Rows (New-SoftwareRows)
            Invoke-DomeniaBoardAction -Tag @{Board='Software';Action='Customize'}
            # A team layout written by hand, without identifiers: the same identifiers on every reading, so Retirer and
            # Copier find the widget that is drawn.
            $withIds=$script:TeamLayout
            $script:TeamLayout='[{"Source":"Builtin","Key":"software.largest","Visual":"Bar","Size":"L","Group":"Equipe"},{"Source":"Builtin","Key":"software.count","Visual":"Kpi","Size":"S","Group":"Equipe"}]'
            $first=[string]@(Get-Layout Software)[0].Id
            Expect (($first -ne '') -and ($first -eq [string]@(Get-Layout Software)[0].Id)) ('Identifiants de la disposition d equipe instables : '+$first)
            Invoke-DomeniaBoardAction -Tag @{Board='Software';Id=$first;Action='Remove'}
            Expect ((@(Get-Layout Software|ForEach-Object{$_.Key}) -join ',') -eq 'software.count') 'Retirer sans effet sur une disposition d equipe sans identifiants'
            [void]$script:TestSettings.Remove('Dashboard.Software.Layout');$script:TeamLayout=$withIds
            Invoke-DomeniaBoardAction -Tag @{Board='Software';Id=[string]@(Get-Layout Software)[0].Id;Action='Remove'}
            Invoke-DomeniaBoardAction -Tag @{Board='Software';Action='Reset'}
            Expect ((@(Get-Layout Software|ForEach-Object{$_.Key}) -join ',') -eq 'software.largest,software.count') 'Par defaut ne revient pas a la disposition d equipe'
            Expect ([string](Get-DomeniaBoardState 'Software').UndoText -eq 'Disposition par défaut appliquée') 'Par defaut non annulable'
            $script:TeamLayout='{ pas du json'
            Invoke-DomeniaBoardAction -Tag @{Board='Software';Action='Reset'}
            Expect ((@(Get-Layout Software|ForEach-Object{$_.Key}) -join ',') -eq (@(Get-DomeniaBoardCatalog -Board Software|ForEach-Object{$_.Key}) -join ',')) 'Valeur illisible : disposition du catalogue attendue'
            # Export: the pinned DocumentStore worker writes the JSON in the export folder; the confirmation stays in the page.
            $before=$script:StartCalls.Count
            $export=@(Get-DomeniaLogicalControls (Get-DomeniaControl 'PnlSoftwareDashboard')|Where-Object{($_ -is [Windows.Controls.Button]) -and ($_.Tag -is [hashtable]) -and ([string]$_.Tag['Action'] -eq 'Export')})
            Expect ($export.Count -eq 1) 'Exporter absent en personnalisation'
            $export[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            $call=$script:StartCalls[$script:StartCalls.Count-1]
            Expect (($script:StartCalls.Count -eq $before+1) -and ($call.OperationId -eq 'DocumentStore') -and ([string]$call.Payload.Action -eq 'Write')) 'Export non confie au worker DocumentStore'
            Expect (([IO.Path]::GetDirectoryName([string]$call.Payload.Path) -eq $script:ExportFolder) -and ([IO.Path]::GetFileName([string]$call.Payload.Path) -like 'Domenia-disposition-logiciels-*.json')) ('Fichier exporte : '+[string]$call.Payload.Path)
            $exported=ConvertTo-DomeniaBoardLayoutJson -Layout (Get-Layout Software)
            $Payload=$call.Payload;$written=& ([scriptblock]::Create([string]$call.Code))
            Complete-DomeniaBoardDocument -Result $written -State $call.State
            Expect ([IO.File]::Exists([string]$call.Payload.Path)) 'Fichier non ecrit'
            Expect (($script:Banners.Count -eq 1) -and ([string]$script:Banners[0].Kind -eq 'Success') -and ([string]$script:Banners[0].ActionPath -eq [string]$call.Payload.Path) -and ([string]$script:Banners[0].Message -like '*Dashboard.DefaultLayoutSoftware*')) 'Confirmation de l export absente de la page'
            # Import after a change: integrated picker, DocumentStore read, one undoable change.
            Invoke-DomeniaBoardAction -Tag @{Board='Software';Id=[string]@(Get-Layout Software)[0].Id;Action='Remove'}
            $script:PickedPath=[string]$call.Payload.Path;$script:PickerRequest=$null
            Invoke-DomeniaBoardAction -Tag @{Board='Software';Action='Import'}
            Expect (($null -ne $script:PickerRequest) -and ([string]$script:PickerRequest.Mode -eq 'Open') -and ([string]$script:PickerRequest.Filter -like '*.json*') -and ([string]$script:PickerRequest.InitialDirectory -eq $script:ExportFolder)) 'Selecteur integre non utilise'
            $read=$script:StartCalls[$script:StartCalls.Count-1]
            Expect (($read.OperationId -eq 'DocumentStore') -and ([string]$read.Payload.Action -eq 'Read') -and ([string]$read.Payload.Path -eq $script:PickedPath)) 'Lecture non confiee au worker'
            $Payload=$read.Payload;$content=& ([scriptblock]::Create([string]$read.Code))
            Complete-DomeniaBoardDocument -Result $content -State $read.State
            Expect ((ConvertTo-DomeniaBoardLayoutJson -Layout (Get-Layout Software)) -eq $exported) 'Disposition importee differente de l export'
            Expect ([string](Get-DomeniaBoardState 'Software').UndoText -eq 'Disposition importée') 'Import non annulable'
            # A layout of another board is refused and said so; nothing changes.
            $now=ConvertTo-DomeniaBoardLayoutJson -Layout (Get-Layout Software);$script:Trace.Clear()
            Complete-DomeniaBoardDocument -Result ([pscustomobject]@{Saved=$false;Path='C:\fictif\accueil.json';Content=(ConvertTo-DomeniaBoardLayoutDocument -Board Fleet -Layout @(Get-DomeniaBoardDefaultLayout -Board Fleet))}) -State $read.State
            Expect ((ConvertTo-DomeniaBoardLayoutJson -Layout (Get-Layout Software)) -eq $now) 'Disposition d un autre tableau appliquee'
            Expect (@($script:Trace|Where-Object{$_ -like 'Disposition non importée : Disposition du tableau de lʼaccueil*'}).Count -ge 1) 'Refus non dit'
        }finally{
            Set-Item function:script:Get-CfgValue $oldCfg;Set-Item function:script:Show-DomeniaInlineFilePicker $oldPicker
            if((Get-DomeniaBoardState 'Software').Editing){Invoke-DomeniaBoardAction -Tag @{Board='Software';Action='Customize'}}
            Set-DomeniaSetting 'Dashboard.Software.Layout' $savedLayout
            Remove-Item -LiteralPath $script:ExportFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Case 'Editeur sans jargon WMI : Lu sur le poste, badges, vignettes, Annuler et Ajouter seulement, filtres et synonymes (UI-14, SP-07, SP-19)' {
        $run=Invoke-EditorTrial {Show-DomeniaBoardEditor -Board Computer} {
            param($c,$t)
            $list=Find-Named $c 'Informations disponibles';$search=Find-Named $c 'Rechercher une information'
            $rows=@($list.ItemsSource);$t.Seen['All']=$rows.Count
            $t.Seen['Sections']=(@($rows|ForEach-Object{[string]$_.Section}|Select-Object -Unique) -join '|')
            $probe=@($rows|Where-Object{[string]$_.Source -eq 'Probe'})[0]
            $t.Seen['Reads']=[string]$probe.Reads;$t.Seen['Tip']=[string]$probe.Tip
            $t.Seen['Badges']=(@($rows|ForEach-Object{[string]$_.Badge}|Where-Object{$_}|Select-Object -Unique) -join '|')
            $t.Seen['Close']=[string]@($c|Where-Object{($_ -is [Windows.Controls.Button]) -and ($_.Name -eq 'EmbeddedClose')})[0].Visibility
            $t.Seen['Buttons']=(@($c|Where-Object{($_ -is [Windows.Controls.Button]) -and ($_.IsVisible)}|ForEach-Object{[string]$_.Content}) -join '|')
            $visual=Find-Named $c 'Représentation';$t.Seen['VisualType']=$visual.GetType().Name
            $search.Text='RAM'
            $t.Seen['Ram']=(@($list.ItemsSource|ForEach-Object{[string]$_.Name}) -join '|');$t.Seen['RamCount']=@($list.ItemsSource).Count
            $search.Text=''
            @($c|Where-Object{($_ -is [Windows.Controls.RadioButton]) -and ([string]$_.GroupName -eq 'BoardEditorOrigin') -and ([string]$_.Tag -eq 'Probe')})[0].IsChecked=$true
            $t.Seen['ProbeOthers']=@(@($list.ItemsSource)|Where-Object{[string]$_.Source -ne 'Probe'}).Count;$t.Seen['ProbeCount']=@($list.ItemsSource).Count
            $now=@(Get-DomeniaLogicalControls $script:Window.FindName('DomeniaDialogLayer'))
            $chips=@($now|Where-Object{($_ -is [Windows.Controls.RadioButton]) -and ([string]$_.GroupName -eq 'BoardEditorCategory')})
            $t.Seen['Chips']=(@($chips|ForEach-Object{[string]$_.Content}) -join '|')
            @($chips|Where-Object{(ConvertTo-DomeniaSearchText ([string]$_.Tag)) -eq 'disques'})[0].IsChecked=$true
            $t.Seen['DiskOthers']=@(@($list.ItemsSource)|Where-Object{(ConvertTo-DomeniaSearchText ([string]$_.Category)) -ne 'disques'}).Count;$t.Seen['DiskCount']=@($list.ItemsSource).Count
            $script:DomeniaSurfaceState.Window.Close()
        }
        Expect (-not $run.Accepted) 'Editeur accepte sans Ajouter'
        Expect (($run.Trial.Seen['Sections'] -like '*Lu sur le poste, à la demande · *') -and ($run.Trial.Seen['Sections'] -like '*Informations du tableau · *') -and ($run.Trial.Seen['Sections'] -notlike '*WMI*')) ('Sections : '+$run.Trial.Seen['Sections'])
        Expect (($run.Trial.Seen['Reads'] -eq 'Interroge le poste') -and ($run.Trial.Seen['Tip'] -like '*Classe WMI : *')) ('Requete : '+$run.Trial.Seen['Reads']+' / '+$run.Trial.Seen['Tip'])
        Expect ($run.Trial.Seen['Badges'] -eq 'Déjà affiché') ('Badges : '+$run.Trial.Seen['Badges'])
        Expect (($run.Trial.Seen['Close'] -eq 'Collapsed') -and ($run.Trial.Seen['Buttons'] -like '*Annuler*') -and ($run.Trial.Seen['Buttons'] -like '*Ajouter*') -and ($run.Trial.Seen['Buttons'] -notlike '*Fermer*')) ('Boutons : '+$run.Trial.Seen['Buttons'])
        Expect ($run.Trial.Seen['VisualType'] -eq 'ListBox') 'Representations non presentees en vignettes'
        Expect (($run.Trial.Seen['Ram'] -like '*Memoire installee*') -and ([int]$run.Trial.Seen['RamCount'] -lt [int]$run.Trial.Seen['All'])) ('RAM : '+$run.Trial.Seen['Ram'])
        Expect (([int]$run.Trial.Seen['ProbeOthers'] -eq 0) -and ([int]$run.Trial.Seen['ProbeCount'] -gt 0)) 'Filtre Lu sur le poste'
        Expect (($run.Trial.Seen['Chips'] -like 'Toutes|*') -and ($run.Trial.Seen['Chips'] -like '*Matériel*')) ('Categories : '+$run.Trial.Seen['Chips'])
        Expect (([int]$run.Trial.Seen['DiskOthers'] -eq 0) -and ([int]$run.Trial.Seen['DiskCount'] -gt 0)) 'Filtre de categorie'
    }
    $script:Finished=$true
}catch{Case 'Suite interrompue' {throw $_}}
finally{
    if($null -ne $script:Window){$script:Window.Close()}
    $fail=@($script:Results|Where-Object{-not $_.Passed}).Count
    $report=[ordered]@{Suite='Tableaux de bord en widgets';Host=$PSVersionTable.PSVersion.ToString();Passed=($script:Results.Count-$fail);Failed=$fail;Filter=$Filter;Complete=($script:Finished -and $script:Results.Count -gt 0 -and ($Filter -or $script:Results.Count -eq $script:ExpectedCases));LiveADExecuted=$false;NetworkAccessed=$false;RenderTimings=$script:RenderTimings.ToArray();RenderTimingScope='Same warmed synthetic board; synchronous full hidden render vs deferred hidden update; visible render still required and excluded';Results=@($script:Results)}
    if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($true))}
    if(-not $Quiet){$report|ConvertTo-Json -Depth 6}
}
if(-not $script:Finished -or $fail -gt 0 -or -not $report.Complete){exit 1};exit 0
