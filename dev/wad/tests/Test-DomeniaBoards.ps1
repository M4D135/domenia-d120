#requires -Version 5.1
# Tableaux de bord en widgets (decision David 2026-10-07) : recette Windows dans la fenetre principale reelle.
# Donnees fictives (example.invalid), aucun reseau, aucune lecture ni ecriture AD. Couvre l affichage, le retrait
# et l annulation, la representation, la taille, le deplacement, le glisser-deposer, la personnalisation, l editeur
# (ajout, recherche, modification), la garde du perimetre des requetes et l animation d entree.
[CmdletBinding()]
param([string]$ReportPath='',[switch]$Quiet)
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot
$script:Results=[Collections.Generic.List[object]]::new();$script:Finished=$false;$script:Window=$null
$script:ExpectedCases=40
function Expect {param([bool]$Value,[string]$Why='Assertion non verifiee');if(-not $Value){throw $Why}}
function Case {param([string]$Name,[scriptblock]$Body)
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
function Get-DomeniaControl {param($Name);if($null -ne $script:Window){return $script:Window.FindName($Name)}}
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
function Start-DomeniaOnlinePark {param([switch]$DisplayedResults,[switch]$PingOnly,[switch]$Inventory,$ScopeTargets,$ScopeLabel,$Probes);$script:ParkCalls.Add([pscustomobject]@{Targets=@($ScopeTargets);Label=$ScopeLabel;Probes=@($Probes);Displayed=[bool]$DisplayedResults;Inventory=[bool]$Inventory})}
# Overview calculation (FleetStats worker): recorded, never run.
$script:StartCalls=[Collections.Generic.List[object]]::new();$script:AsyncJobs=@{}
function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$SuccessHandler,$ErrorHandler,$TimeoutSeconds,$TaskClass);$script:StartCalls.Add([pscustomobject]@{OperationId=$OperationId;Code=$Code;Payload=$Payload;State=$CallbackState;ReplaceKey=$ReplaceKey;TaskClass=$TaskClass});return ('job-'+$script:StartCalls.Count)}
function Initialize-DomeniaWinSqliteNative {return $true}
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
    $tick={Step-EditorTrial $trial}.GetNewClosure();$trial.Timer.Add_Tick($tick);$trial.Timer.Start()
    $accepted=$false
    try{$accepted=& $Open}finally{$trial.Timer.Stop();$trial.Timer.Remove_Tick($tick)}
    Expect (-not $trial.Error) $trial.Error
    return [pscustomobject]@{Accepted=[bool]$accepted;Trial=$trial}
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
    $parkAst=Parse-Text ([IO.File]::ReadAllText((Join-Path $wad 'modules\Domenia-Park.UI.ps1')));Import-Function $parkAst 'Start-DomeniaParkAnalysis'
    $script:FleetScopeDn=''
    # FI-05 / PF-06: Engine.UI holds the protected timer factory (banners, counters, park run).
    foreach($m in @('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Engine.UI.ps1','Domenia-Embedded.UI.ps1','Domenia-Workstation.Model.ps1','Domenia-Boards.Model.ps1','Domenia-Charts.UI.ps1','Domenia-Probes.Model.ps1','Domenia-BoardFleet.Model.ps1','Domenia-BoardSoftware.Model.ps1','Domenia-BoardComputer.UI.ps1','Domenia-Widgets.UI.ps1','Domenia-Dashboard.UI.ps1','Domenia-Query.Model.ps1','Domenia-Query.Worker.ps1','Domenia-Query.UI.ps1')){. (Join-Path $wad ('modules\'+$m))}
    $reader=[Xml.XmlNodeReader]::new([xml](Get-MainXaml));try{$w=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    $w.Width=1400;$w.Height=900;$w.ShowInTaskbar=$false
    $palette=(Get-Content -LiteralPath (Join-Path $wad 'modules\SupportSuite.UI.json') -Raw|ConvertFrom-Json).Palettes.Light
    $convert=[Windows.Media.BrushConverter]::new();foreach($p in $palette.PSObject.Properties){$w.Resources[$p.Name]=$convert.ConvertFromInvariantString([string]$p.Value)}
    $script:Window=$w;$w.Show();$w.UpdateLayout()
    $script:DomeniaReduceMotion=$true

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
        Complete-DomeniaFleetDashboard -Result (New-FleetResult) -State $null
        $data=(Get-DomeniaBoardState 'Fleet').Data
        Expect ($data.Entries.ContainsKey('fleet.os') -and $data.Entries.ContainsKey('fleet.health')) 'Entrees du parc'
        Expect (@($script:FleetLast.Targets).Count -eq 3) 'Cibles du perimetre'
        Expect (@($script:FleetLast.Machines).Count -eq 4) 'Recensement complet : le poste desactive manque'
        Expect (@($script:FleetLast.Targets|Where-Object{$_.name -eq 'PC-OFF'}).Count -eq 0) 'Un poste desactive est cible de collecte'
        Update-DomeniaFleetMachineList
        Expect (@((Get-DomeniaControl 'DgFleetMachines').ItemsSource).Count -eq 4) 'La liste locale doit montrer aussi les postes désactivés'
        (Get-DomeniaControl 'TxtFleetMachineFilter').Text='PC-1';Update-DomeniaFleetMachineList
        Expect (@((Get-DomeniaControl 'DgFleetMachines').ItemsSource).Count -eq 1) 'Le filtre local par nom ne fonctionne pas'
        (Get-DomeniaControl 'TxtFleetMachineFilter').Text=''
        (Get-DomeniaControl 'CmbFleetMachineState').SelectedIndex=2;Update-DomeniaFleetMachineList
        Expect (@((Get-DomeniaControl 'DgFleetMachines').ItemsSource).Count -eq 1) 'Le filtre des comptes désactivés ne fonctionne pas'
        (Get-DomeniaControl 'CmbFleetMachineState').SelectedIndex=0;Update-DomeniaFleetMachineList
        Expect (@($data.Entries['fleet.attention'].Items|Where-Object{[string]$_.Text -like '*Windows 10 22H2*fin de service*'}).Count -eq 1) 'Windows 10 signale par la table des fins de service'
        Expect (@($data.Entries['fleet.versions'].Items|Where-Object{[string]$_.Label -eq 'Windows Server 2025'}).Count -eq 1) 'Serveur reconnu a son build'
        Expect (@(Get-Holders (Get-DomeniaControl 'PnlFleetDashboard')).Count -ge 6) 'Widgets du parc'
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
        $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid'
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
        $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid'
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
    Case 'Points du poste : le lien ouvre l onglet de l action utile (Actions, Secrets) sans rien lancer' {
        $data=New-DomeniaBoardData -Board Computer
        Add-DomeniaBoardAttention -Data $data -Level Warn -Text 'Pas de redemarrage depuis 40 jours.' -Point 'restart' -Route 'ComputerActions' -RouteText 'Redémarrer : onglet Actions'
        Add-DomeniaBoardAttention -Data $data -Level Alert -Text 'Disque C: presque plein : 4 % libre.' -Point 'disk.c' -Route 'ComputerActions' -RouteText 'Ouvrir C$ : onglet Actions'
        Add-DomeniaBoardAttention -Data $data -Level Warn -Text 'BitLocker : Protection Desactive.' -Point 'secrets' -Route 'ComputerSecrets' -RouteText 'Onglet Secrets du poste'
        $card=New-DomeniaAttentionCard -Items @($data.Attention) -Board 'Computer'
        $links=@(Get-DomeniaLogicalControls $card|Where-Object{$_ -is [Windows.Documents.Hyperlink]})
        Expect ($links.Count -eq 3) ('Liens des points : '+$links.Count)
        $inner=Get-DomeniaControl 'ComputerTabs'
        $inner.SelectedItem=Get-DomeniaControl 'TabComputerDashboard'
        $before=$script:StartCalls.Count;$parks=$script:ParkCalls.Count;$script:Workspaces.Clear()
        $disk=@($links|Where-Object{(New-Object Windows.Documents.TextRange($_.ContentStart,$_.ContentEnd)).Text -eq 'Ouvrir C$ : onglet Actions'})[0]
        Expect ($null -ne $disk) 'Lien Ouvrir C$ absent'
        $disk.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Documents.Hyperlink]::ClickEvent))
        Expect ([string]$inner.SelectedItem.Name -eq 'TabComputerAdmin') ('Onglet ouvert : '+[string]$inner.SelectedItem.Name)
        Expect ([string](Get-DomeniaControl 'WorkspaceTabs').SelectedItem.Name -eq 'WsComputer') 'Assistance poste non ouverte'
        $secret=@($links|Where-Object{[string]$_.Tag -eq 'ComputerSecrets'})[0]
        $secret.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Documents.Hyperlink]::ClickEvent))
        Expect ([string]$inner.SelectedItem.Name -eq 'TabSecurity') ('Onglet Secrets non ouvert : '+[string]$inner.SelectedItem.Name)
        Expect (($script:Workspaces -join ',') -eq 'WsComputer/TabComputerAdmin,WsComputer/TabSecurity') ('Ecrans ouverts : '+($script:Workspaces -join ','))
        Expect ($script:StartCalls.Count -eq $before -and $script:ParkCalls.Count -eq $parks) 'Un lien a lance une tache'
        $inner.SelectedItem=Get-DomeniaControl 'TabComputerDashboard';(Get-DomeniaControl 'WorkspaceTabs').SelectedItem=Get-DomeniaControl 'WsSearch'
    }
    Case 'Poste hors de l OU de l accueil : ses releves lus une fois dans la base locale et gardes' {
        $script:DatabaseScopedPath='C:\fictif\domenia.db';$script:FleetObservations=@{};$script:FleetSelectedReads=@{};$script:FleetScopeDn=''
        $script:SelectedObject=[pscustomobject]@{DN='CN=PC-9,OU=Lyon,DC=example,DC=invalid';Type='Machine';Name='PC-9';Safety=[pscustomobject]@{Guid='00000000-0000-4000-8000-000000000009'}}
        $before=$script:StartCalls.Count;$parks=$script:ParkCalls.Count
        Show-DomeniaBoard -Board Computer -Quiet
        Expect ($script:StartCalls.Count -eq $before+1) 'Releves du poste selectionne non demandes'
        $call=$script:StartCalls[$script:StartCalls.Count-1]
        Expect ([string]$call.OperationId -eq 'LocalIndexRead' -and [string]$call.Payload.Action -eq 'FleetStats' -and [bool]$call.Payload.ObservationsOnly -and (@($call.Payload.Keys) -contains 'cn=pc-9,ou=lyon,dc=example,dc=invalid') -and [string]$call.TaskClass -eq 'Background' -and [string]$call.ReplaceKey -eq 'fleet:selected') 'Lecture du poste mal parametree'
        Show-DomeniaBoard -Board Computer -Quiet
        Expect ($script:StartCalls.Count -eq $before+1) 'Lecture repetee pour le meme poste'
        $recent=[datetime]::UtcNow.AddHours(-3).ToString('o')
        $obs=[pscustomobject]@{Guid='00000000-0000-4000-8000-000000000009';CheckedUtc=$recent;Probes=[pscustomobject]@{'os.release'=[pscustomobject]@{Rows=@(,@('26100','1'));Count=1;Error='';CheckedUtc=$recent}}}
        Complete-DomeniaSelectedObservation -Result ([pscustomobject]@{Rows=@();Busy=$false;Missing=$false;MachineCount=0;Presence=@([pscustomobject]@{object_key='cn=pc-9,ou=lyon,dc=example,dc=invalid';checked_utc=$recent;observation=$obs;in_scope=$false})}) -State $call.State
        Expect (@(Get-DomeniaWidgetResults -Board Computer -ProbeId 'os.release').Count -eq 1) 'Releve du poste hors OU absent de son tableau'
        Complete-DomeniaFleetDashboard -Result (New-FleetResult) -State $null
        Expect (@(Get-DomeniaWidgetResults -Board Computer -ProbeId 'os.release').Count -eq 1) 'Releve perdu apres un recalcul de l accueil'
        Expect ($script:StartCalls.Count -eq $before+1 -and $script:ParkCalls.Count -eq $parks) 'Lecture ou analyse relancee'
        $script:SelectedObject=$null;$script:DatabaseScopedPath='';$script:FleetObservations=$null
    }
    Case 'En-tete de l accueil : fil local et périmètre indépendant de Rechercher' {
        $script:FleetScopeDn='OU=Lyon,OU=Postes,DC=example,DC=invalid'
        Update-DomeniaFleetScopeText (Get-DomeniaFleetScope) -Count 2
        Expect ([string](Get-DomeniaControl 'LblFleetScope').Text -like '*2 postes actifs dans la base*') 'Le nombre actif en base est mal libelle'
        Expect ([string](Get-DomeniaControl 'LblFleetScope').ToolTip -like '*postes actifs*') 'L infobulle doit préciser la population active'
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
        $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid'
        Complete-DomeniaFleetDashboard -Result (New-FleetResult -Scope 'OU=Postes,DC=example,DC=invalid') -State $null
        $script:ShownRows=$null
        function script:Show-ObjectRows {param($Rows,$Label,[switch]$SkipPresenceScan,[switch]$NoAutoOpen);$script:ShownRows=@($Rows)}
        function script:Stop-DomeniaLiveSearch {}
        Show-DomeniaFleetAnalyzeSource
        Expect ((@($script:ShownRows).Count -eq 2) -and ((@($script:ShownRows|ForEach-Object{[string]$_.Name}|Sort-Object) -join ',') -eq 'PC-1,PC-2')) ('Postes affiches : '+(@($script:ShownRows|ForEach-Object{[string]$_.Name}) -join ','))
        Expect (@($script:Trace|Where-Object{$_ -like '2 poste(s) de Postes dans Rechercher*'}).Count -ge 1) 'Consigne de Rechercher absente'
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
        $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid'
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
        Complete-DomeniaFleetDashboard -Result (New-FleetResult -Scope 'OU=Postes,DC=example,DC=invalid') -State $call.State
        $script:AsyncJobs.Remove('job-1')
        Expect ([string]$script:FleetComputedKey -eq 'ou=postes,dc=example,dc=invalid|Subtree') ('Cle calculee : '+$script:FleetComputedKey)
        Expect ($script:StartCalls.Count -eq 2) 'Donnees changees pendant le calcul non recalculees'
        Complete-DomeniaFleetDashboard -Result (New-FleetResult -Scope 'OU=Postes,DC=example,DC=invalid') -State $script:StartCalls[1].State
        Request-DomeniaFleetRefresh
        Expect ($script:StartCalls.Count -eq 2) 'Recalcul sans changement'
        # Dashboard-local scope line and clickable OU path.
        Expect ([string](Get-DomeniaControl 'LblFleetScope').Text -like ' · et ses sous-OU · 2 postes actifs*') ('Perimetre affiche : '+[string](Get-DomeniaControl 'LblFleetScope').Text)
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
    Case 'Widget de requete en attente : etat explicite, puis rempli par un resultat' {
        $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid'
        Complete-DomeniaFleetDashboard -Result (New-FleetResult -Scope $script:FleetScopeDn) -State $null
        $item=@(Get-Layout Fleet|Where-Object{$_.Source -eq 'Probe'})[0]
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
        $script:Ctrl=@{};foreach($n in @('UxSessionDetails','TxtDashDomain','TxtDashServer','TxtDashUser','TxtDashMode','TxtDashBaseDn','TxtDashBranch','TxtDashRows','TxtDashModule','TxtDashStats','TxtDashSelected','TxtDashRights','TxtDashTasks','TxtDashCache','TxtDashSelfCheck','TxtDashLinks')){$script:Ctrl[$n]=Get-DomeniaControl $n}
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
        $expander.IsExpanded=$false;$script:Ctrl=$null
    }
    Case 'Premiers pas : quatre etapes qui ouvrent un ecran sans rien lancer, carte masquee une fois faites' {
        $script:FleetScopeDn='';$script:IndexDbCount=0;$script:RemoteAdminCredential=$null
        $script:TestSettings['Home.FirstStepsDone']=$false
        $db=Join-Path ([IO.Path]::GetTempPath()) ('domenia-firststeps-'+[guid]::NewGuid().ToString('N')+'\Domenia.db')
        Set-Item function:script:Get-DomeniaDatabasePath ([scriptblock]::Create("return '"+$db+"'"))
        Update-DomeniaFirstSteps
        $card=Get-DomeniaControl 'CardFirstSteps'
        Expect ($card.Visibility -eq [Windows.Visibility]::Visible) 'Carte Premiers pas masquee au premier lancement'
        $before=$script:StartCalls.Count;$parks=$script:ParkCalls.Count;$script:Workspaces.Clear()
        $script:SelectedBranchDn='OU=Recherche,DC=example,DC=invalid';$searchBefore=$script:SelectedBranchDn
        $trial=Invoke-EditorTrial -Open {Open-DomeniaFirstStep -Step 'Ou'} -Act {
            param($controls,$trial)
            $search=@($controls|Where-Object{$_.Name -eq 'EmbeddedObjectSearch'})[0]
            Expect ($null -ne $search) 'Vrai selecteur OU absent'
            $search.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            $lookup=$script:StartCalls[$script:StartCalls.Count-1]
            Expect ($lookup.OperationId -eq 'EmbeddedDirectoryLookup' -and -not $lookup.Payload.Verify) 'Recherche OU non explicite'
            $row=[pscustomobject]@{Name='Postes';Second='';Description='Fixture';DN='OU=Postes,DC=example,DC=invalid';Guid='00000000-0000-4000-8000-000000000100'}
            Complete-DomeniaEmbeddedLookup -Result ([pscustomobject]@{Rows=@($row);RequestId=$lookup.State.RequestId;Verified=$false;Capped=$false}) -State $lookup.State
            $grid=@($controls|Where-Object{$_.Name -eq 'EmbeddedObjectResults'})[0];$grid.SelectedItem=$grid.Items[0]
            $accept=@($controls|Where-Object{$_.Name -eq 'EmbeddedObjectAccept'})[0]
            Expect $accept.IsEnabled 'Choisir reste desactive'
            $accept.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            $verify=$script:StartCalls[$script:StartCalls.Count-1]
            Expect ($verify.OperationId -eq 'EmbeddedDirectoryLookup' -and $verify.Payload.Verify) 'OU choisie sans verification d identite'
            Complete-DomeniaEmbeddedLookup -Result ([pscustomobject]@{Rows=@($row);RequestId=$verify.State.RequestId;Verified=$true;Capped=$false}) -State $verify.State
        }
        Expect $trial.Trial.Done 'Selecteur non termine'
        Expect ($script:FleetScopeDn -eq 'OU=Postes,DC=example,DC=invalid' -and $script:SelectedBranchDn -eq $searchBefore) 'La selection OU modifie Rechercher'
        foreach($step in @('Base','Account','Backup')){Open-DomeniaFirstStep -Step $step}
        Expect ($script:StartCalls.Count -eq $before+2 -and $script:ParkCalls.Count -eq $parks) 'Une etape a lance une tache autre que la selection OU explicite'
        Expect (($script:Workspaces -join ',') -eq 'TabApplicationTools/TabIndex,route:TabAccounts,TabApplicationTools/TabIndex') ('Ecrans ouverts : '+($script:Workspaces -join ','))
        $script:FleetScopeDn='OU=Postes,DC=example,DC=invalid';$script:IndexDbCount=12;$script:TestSettings['RemoteCredentialUser']='EXAMPLE\poste'
        $folder=Join-Path ([IO.Path]::GetDirectoryName($db)) 'Backups';[void][IO.Directory]::CreateDirectory($folder);[IO.File]::WriteAllText((Join-Path $folder 'Domenia-20261008.db'),'x')
        Update-DomeniaFirstSteps
        Expect ($card.Visibility -eq [Windows.Visibility]::Collapsed) 'Carte encore affichee apres les quatre etapes'
        Expect ([bool]$script:TestSettings['Home.FirstStepsDone']) 'Preference locale non enregistree'
        Remove-Item -LiteralPath ([IO.Path]::GetDirectoryName($db)) -Recurse -Force -ErrorAction SilentlyContinue
        $script:FleetScopeDn='';$script:TestSettings.Remove('RemoteCredentialUser')
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
            Expect ($arc.Stroke.Color -eq [Windows.Media.ColorConverter]::ConvertFromString((Get-DomeniaBoardColor 'Info'))) '85 % sans point a surveiller : couleur neutre'
        }finally{$tw.Close()}
        $warn=New-DomeniaGauge -Title 'Memoire' -Value 95 -Maximum 100 -Unit '%' -Width 230 -Height 250 -State Warn
        $arcWarn=@(@(Get-DomeniaLogicalControls $warn|Where-Object{$_ -is [Windows.Controls.Canvas]})[0].Children)[1]
        Expect ($arcWarn.Stroke.Color -eq [Windows.Media.ColorConverter]::ConvertFromString((Get-DomeniaBoardColor 'Warn'))) 'Etat a surveiller : couleur de l etat'
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
        $badge='Partiel : s'+[char]0x00E9+'curit'+[char]0x00E9+' non v'+[char]0x00E9+'rifi'+[char]0x00E9+'e'
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
            $operators=Get-DomeniaControl 'CmbQueryOperator';$value=Get-DomeniaControl 'TxtQueryValue'
            Expect ($operators.Items.Count -gt 0 -and $null -ne $operators.SelectedItem) 'Premier atelier : aucun operateur selectionne'
            Expect ($value.IsEnabled -eq ([string]$operators.SelectedItem.Id -notin @('IsMissing','IsPresent'))) 'Premier atelier : etat du champ valeur incoherent'
            foreach($name in @('LblQuerySegment','BtnQueryClearSegment')){Expect ((Get-DomeniaControl $name).Visibility -eq [Windows.Visibility]::Collapsed) ('Segment vide affiche : '+$name)}

        }finally{if($null -ne $previous){Show-DomeniaBoard -Board Fleet -Data $previous -Quiet}}
    }
    Case 'Widget non lu : emplacement Non lu par cet inventaire une fois le tableau rempli, masque avant (SP-18)' {
        $panel=Get-DomeniaControl 'PnlComputerDashboard'
        $places=@(Get-Texts $panel|Where-Object{[string]$_.Text -eq 'Non lu par cet inventaire'})
        Expect ($places.Count -ge 2) ('Emplacements : '+$places.Count)
        $titles=@($places|ForEach-Object{@(Get-Texts $_.Parent|ForEach-Object{[string]$_.Text})}|Where-Object{$_ -ne 'Non lu par cet inventaire'})
        Expect (($titles -contains 'Batterie') -and ($titles -contains 'Autres volumes')) ('Widgets non lus : '+($titles -join ', '))
        Clear-DomeniaDashboards
        Expect (@(Get-Texts $panel|Where-Object{[string]$_.Text -eq 'Non lu par cet inventaire'}).Count -eq 0) 'Emplacement avant toute lecture'
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
        $script:FleetScopeDn='';$script:DatabaseScopedPath='';$script:FleetPendingKey='';$script:FleetJobId=''
        $script:SelectedBranchDn='OU=Recherche,DC=example,DC=invalid';$searchBefore=$script:SelectedBranchDn
        (Get-DomeniaControl 'WorkspaceTabs').SelectedItem=Get-DomeniaControl 'TabDashboard'
        Complete-DomeniaFleetDashboard -Result (New-FleetResult) -State $null
        $holder=@(Get-Holders (Get-DomeniaControl 'PnlFleetDashboard')|Where-Object{$_.Tag.Item.Key -eq 'fleet.machines'})[0]
        Expect ($null -ne $holder -and -not $holder.Tag.Editing) 'Widget Postes non cliquable'
        $parks=$script:ParkCalls.Count
        $mouse=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,0,[Windows.Input.MouseButton]::Left)
        $mouse.RoutedEvent=[Windows.UIElement]::MouseLeftButtonUpEvent;$mouse.Source=$holder;$holder.RaiseEvent($mouse)
        $call=$script:StartCalls[$script:StartCalls.Count-1]
        Expect ($call.OperationId -eq 'LocalQuery') 'Le widget ne lance pas le moteur local'
        $Payload=$call.Payload;$result=& ([scriptblock]::Create([string]$call.Code))
        Complete-DomeniaQueryEvaluation -Result $result -State $call.State
        $q=$script:DomeniaQueryState
        Expect ($null -ne $q.Result -and $q.Result.Matched -eq 4 -and @((Get-DomeniaControl 'DgFleetMachines').ItemsSource).Count -eq 4) 'Le detail du widget omet un des quatre postes, dont le desactive'
        Expect ($script:SelectedBranchDn -eq $searchBefore -and [string](Get-DomeniaControl 'WorkspaceTabs').SelectedItem.Name -eq 'TabDashboard') 'Le detail local modifie Rechercher'
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
        if($null -ne $q.Timer){$q.Timer.Stop()}

    }
    Case 'Base locale : le detail long garde une largeur et une hauteur lisibles dans la vraie grille WPF' {
        $grid=Get-DomeniaControl 'DgIndex'
        $workspaces=Get-DomeniaControl 'WorkspaceTabs';$tools=Get-DomeniaControl 'ApplicationToolTabs'
        $oldWorkspace=$workspaces.SelectedItem;$oldTool=$tools.SelectedItem;$oldRows=$grid.ItemsSource
        $oldWidth=$w.Width;$oldHeight=$w.Height;$oldVirtual=$grid.EnableColumnVirtualization
        try {
            $w.Width=1920;$w.Height=1080
            $workspaces.SelectedItem=Get-DomeniaControl 'TabApplicationTools';$tools.SelectedItem=Get-DomeniaControl 'TabIndex'
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
            $tools.SelectedItem=$oldTool;$workspaces.SelectedItem=$oldWorkspace;$w.Width=$oldWidth;$w.Height=$oldHeight;$w.UpdateLayout()
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
            $rows=@((Get-DomeniaControl 'DgQueryConditions').ItemsSource)
            Expect ($rows.Count -eq 1 -and $rows[0].FieldLabel -eq $field.SelectedItem.Name -and $rows[0].OperatorLabel -eq $operator.SelectedItem.Name -and $rows[0].Value -eq 20) 'La condition ajoutee ne se voit pas dans le tableau'
            Expect ($script:StartCalls.Count -eq $callsBefore) 'Ajouter une condition lance une tache avant Executer'
        } finally {
            Set-DomeniaQueryDraft $oldRecipe
            $field.SelectedItem=$oldField
            $operator.SelectedItem=@($operator.ItemsSource|Where-Object{$_.Id -eq $oldOperatorId})[0]
            $value.Text=$oldValue
            if($null -ne $q.Timer){$q.Timer.Stop()}
        }
    }
    $script:Finished=$true
}catch{Case 'Suite interrompue' {throw $_}}
finally{
    if($null -ne $script:Window){$script:Window.Close()}
    $fail=@($script:Results|Where-Object{-not $_.Passed}).Count
    $report=[ordered]@{Suite='Tableaux de bord en widgets';Host=$PSVersionTable.PSVersion.ToString();Passed=($script:Results.Count-$fail);Failed=$fail;Complete=($script:Finished -and $script:Results.Count -eq $script:ExpectedCases);LiveADExecuted=$false;NetworkAccessed=$false;Results=@($script:Results)}
    if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($true))}
    if(-not $Quiet){$report|ConvertTo-Json -Depth 6}
}
if(-not $script:Finished -or $fail -gt 0 -or -not $report.Complete){exit 1};exit 0
