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
$script:ExpectedCases=27
function Expect {param([bool]$Value,[string]$Why='Assertion non verifiee');if(-not $Value){throw $Why}}
function Case {param([string]$Name,[scriptblock]$Body)
    try {& $Body|Out-Null;$script:Results.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}
    catch {$script:Results.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.ToString()})}
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
function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$SuccessHandler,$ErrorHandler,$TimeoutSeconds,$TaskClass);$script:StartCalls.Add([pscustomobject]@{OperationId=$OperationId;Payload=$Payload;State=$CallbackState;ReplaceKey=$ReplaceKey;TaskClass=$TaskClass});return ('job-'+$script:StartCalls.Count)}
function Initialize-DomeniaWinSqliteNative {return $true}
function Get-DomeniaLocalIndexReadWorkerCode {return '# fixture'}
function Get-DomeniaBitLockerPresenceWorkerCode {return '# fixture'}
function Queue-DomeniaMetadata {param($Kind,$Row,$Key='');$script:Queued.Add([pscustomobject]@{Kind=$Kind;Row=$Row;Key=$Key});return $true}
function Select-DomeniaWorkspace {param($Workspace,$Inner,$Tab);$script:Workspaces.Add([string]$Workspace+'/'+[string]$Tab);$tabs=Get-DomeniaControl 'WorkspaceTabs';$target=Get-DomeniaControl $Workspace;if($null -ne $tabs -and $null -ne $target -and $target -is [Windows.Controls.TabItem]){$tabs.SelectedItem=$target}}
function Invoke-DomeniaUxRoute {param($Route);$script:Workspaces.Add('route:'+[string]$Route)}
$script:Queued=[Collections.Generic.List[object]]::new();$script:Workspaces=[Collections.Generic.List[string]]::new()
# The OU of Rechercher (decision David 2026-10-08): $script:TestScopeDn empty = domain root.
function Get-DomeniaSearchScope {param($Mode);$dn=if($script:TestScopeDn){$script:TestScopeDn}else{[string]$script:Conn.BaseDn};return [pscustomobject]@{BaseDn=$dn;Scope=$(if($script:TestScopeOneLevel){'OneLevel'}else{'Subtree'});IsDomain=($dn -ieq [string]$script:Conn.BaseDn);Mode='OU'}}
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
        [pscustomobject]@{name='PC-1';object_guid='g-PC-1';distinguished_name='CN=PC-1,OU=Postes,DC=example,DC=invalid';st='A';os='Windows 11 Entreprise';ver='10.0 (26100)';lb=0;cr='O';pw='R';lk='O';bk='U';logon='2026-10-01'}
        [pscustomobject]@{name='PC-2';object_guid='g-PC-2';distinguished_name='CN=PC-2,OU=Postes,DC=example,DC=invalid';st='A';os='Windows 10 Entreprise';ver='10.0 (19045)';lb=3;cr='O';pw='O';lk='O';bk='U';logon='2026-05-01'}
        [pscustomobject]@{name='SRV-1';object_guid='g-SRV-1';distinguished_name='CN=SRV-1,OU=Serveurs,DC=example,DC=invalid';st='A';os='Windows Server 2025 Datacenter';ver='10.0 (26100)';lb=5;cr='O';pw='R';lk='O';bk='U';logon=''}
    )
    $kept=@($all|Where-Object{(-not $Scope) -or ([string]$_.distinguished_name).EndsWith(','+$Scope,[StringComparison]::OrdinalIgnoreCase)})
    $groups=@();$machines=@();$parents=@{};$i=0
    foreach($m in $kept){$i++;$groups+=[pscustomobject]@{gid=[string]$i;st=$m.st;os=$m.os;ver=$m.ver;lb=$m.lb;cr=$m.cr;pw=$m.pw;lk=$m.lk;bk=$m.bk;n=1};$machines+=[pscustomobject]@{name=$m.name;distinguished_name=$m.distinguished_name;object_guid=$m.object_guid;gid=[string]$i;st=$m.st;logon=$m.logon};$p=([string]$m.distinguished_name).Substring(([string]$m.distinguished_name).IndexOf(',')+1);$parents[$p]=1+[int]$parents[$p]}
    return [pscustomobject]@{Busy=$false;Links=2;LinkSources=@();MachineCount=$machines.Count
        Types=@([pscustomobject]@{t='Machine';s='Actif';n=3},[pscustomobject]@{t='Utilisateur';s='Actif';n=12})
        Groups=$groups;Machines=$machines;Parents=@(foreach($k in $parents.Keys){[pscustomobject]@{p=$k;n=$parents[$k]}})
        Coverage=[pscustomobject]@{BitLockerRead=0;BitLockerAt='';FactsFresh=$machines.Count;FactsStale=0;FactsAt=''}
        Presence=@($Presence);History=@()}
}
try{
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid';Server='dc.example.invalid';Domain='example.invalid';Netbios='EXAMPLE'}
    $script:SessionEpoch=1L;$script:SelectedObject=$null
    $coreText=[IO.File]::ReadAllText((Join-Path $wad 'Domenia-Core.ps1'));$ast=Parse-Text $coreText
    foreach($n in @('Get-MainXaml','Get-DomeniaEffectiveWorkerResult','Get-DomeniaDefaultSettings')){Import-Function $ast $n}
    $parkAst=Parse-Text ([IO.File]::ReadAllText((Join-Path $wad 'modules\Domenia-Park.UI.ps1')));Import-Function $parkAst 'Start-DomeniaParkAnalysis'
    $script:TestScopeDn='';$script:TestScopeOneLevel=$false
    foreach($m in @('Domenia-Embedded.UI.ps1','Domenia-Boards.Model.ps1','Domenia-Charts.UI.ps1','Domenia-Probes.Model.ps1','Domenia-BoardFleet.Model.ps1','Domenia-BoardSoftware.Model.ps1','Domenia-BoardComputer.UI.ps1','Domenia-Widgets.UI.ps1','Domenia-Dashboard.UI.ps1')){. (Join-Path $wad ('modules\'+$m))}
    $reader=[Xml.XmlNodeReader]::new([xml](Get-MainXaml));try{$w=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    $w.Width=1400;$w.Height=900;$w.ShowInTaskbar=$false
    $palette=(Get-Content -LiteralPath (Join-Path $wad 'modules\SupportSuite.UI.json') -Raw|ConvertFrom-Json).Palettes.Light
    $convert=[Windows.Media.BrushConverter]::new();foreach($p in $palette.PSObject.Properties){$w.Resources[$p.Name]=$convert.ConvertFromInvariantString([string]$p.Value)}
    $script:Window=$w;$w.Show();$w.UpdateLayout()
    $script:DomeniaReduceMotion=$true

    Case 'Les dispositions des tableaux survivent au filtre des reglages' {
        $defaults=Get-DomeniaDefaultSettings
        foreach($key in @('Dashboard.Computer.Layout','Dashboard.Fleet.Layout','Dashboard.Software.Layout','Widgets.Computer','Widgets.Fleet')){Expect ($defaults.Contains($key)) ('Reglage absent de la liste blanche : '+$key)}
        # The home overview follows the OU of Rechercher: no OU of its own is remembered any more.
        Expect (-not $defaults.Contains('FleetScopeDn')) 'Perimetre propre a l accueil encore memorise'
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
        $represent=@($menu.Items|Where-Object{$_ -is [Windows.Controls.MenuItem] -and [string]$_.Header -eq 'Representation'})[0]
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
            $t.Seen['Visuals']=@((Find-Named $c 'Representation').Items|ForEach-Object{[string]$_}) -join ','
            (Find-Named $c 'Representation').SelectedItem='Histogramme'
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
    Case 'Accueil : un seul filtre OU, celui de Rechercher, et aucune analyse lancee depuis l accueil' {
        foreach($name in @('BtnFleetPing','BtnFleetDetect','BtnFleetAnalyze','BtnFleetStop','BtnFleetScopeReset','TxtFleetScope','LblFleetRun')){Expect ($null -eq (Get-DomeniaControl $name)) ('Controle encore present : '+$name)}
        Expect ($null -ne (Get-DomeniaControl 'LblFleetScope') -and $null -ne (Get-DomeniaControl 'BtnFleetScope')) 'Perimetre de l accueil absent'
        $script:TestScopeDn='OU=Postes,DC=example,DC=invalid'
        $scope=Get-DomeniaFleetScope
        Expect ([string]$scope.Dn -eq 'OU=Postes,DC=example,DC=invalid' -and $scope.Subtree -and [string]$scope.Name -eq 'Postes') ('Perimetre : '+[string]$scope.Key)
        $script:TestScopeOneLevel=$true
        Expect (-not (Get-DomeniaFleetScope).Subtree) 'Sans les sous-OU ignore'
        $script:TestScopeOneLevel=$false;$script:TestScopeDn=''
        $whole=Get-DomeniaFleetScope
        Expect ([string]$whole.Dn -eq '' -and [string]$whole.Key -eq '*') 'Racine du domaine non reconnue'
        Update-DomeniaFleetScopeText $whole
        Expect ([string](Get-DomeniaControl 'LblFleetScope').Text -like 'Tout le domaine*') 'Libelle du perimetre'
    }
    Case 'Parc : tableau calcule sur le perimetre et serveurs reconnus' {
        $script:TestScopeDn=''
        Complete-DomeniaFleetDashboard -Result (New-FleetResult) -State $null
        $data=(Get-DomeniaBoardState 'Fleet').Data
        Expect ($data.Entries.ContainsKey('fleet.os') -and $data.Entries.ContainsKey('fleet.health')) 'Entrees du parc'
        Expect (@($script:FleetLast.Targets).Count -eq 3) 'Cibles du perimetre'
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
        $script:TestScopeDn=''
        $before=$script:StartCalls.Count
        Expect (-not (Start-DomeniaFleetBitLockerPresence)) 'Lecture acceptee a la racine du domaine'
        Expect ($script:StartCalls.Count -eq $before) 'Tache lancee a la racine du domaine'
        Expect (@($script:Trace|Where-Object{$_ -like '*racine du domaine*'}).Count -ge 1) 'Refus non explique'
        $script:TestScopeDn='OU=Postes,DC=example,DC=invalid'
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
        Expect (@($script:Trace|Where-Object{$_ -like 'Aucune clé visible avec ce compte*'}).Count -ge 1) 'Message non lisible avec ce compte absent'
        $script:TestScopeDn=''
    }
    Case 'Points d attention : un clic deplie les postes concernes sans lancer de tache' {
        $script:TestScopeDn='OU=Postes,DC=example,DC=invalid'
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
        Expect (@(Get-DomeniaLogicalControls $details|Where-Object{$_ -is [Windows.Controls.Button] -and [string]$_.Tag['Action'] -in @('CopyTargets','SearchTargets')}).Count -eq 2) 'Copier et Afficher dans Rechercher absents'
        Expect ($script:StartCalls.Count -eq $before -and $script:ParkCalls.Count -eq $parks) 'Tache lancee par le clic'
        $stale.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Expect ($details.Visibility -eq [Windows.Visibility]::Collapsed) 'Second clic ne replie pas'
        $script:TestScopeDn=''
    }
    Case 'Annuler une disposition survit a un recalcul de fond, pile d annulation et Ctrl+Z' {
        $script:TestScopeDn=''
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
    Case 'Requetes du parc : lancees depuis Rechercher sur la liste affichee, jamais depuis l accueil' {
        $layout=@(Get-Layout Fleet)
        Set-DomeniaBoardLayout -Board Fleet -Layout @(Add-DomeniaBoardItem -Layout $layout -Item (New-DomeniaBoardItem -Source Probe -Key 'os.release' -Visual 'Pie' -Group 'Systeme'))
        $script:ParkCalls.Clear();Start-DomeniaWidgetProbe -Board Fleet
        Expect ($script:ParkCalls.Count -eq 0) 'Requete lancee depuis l accueil'
        Expect (@($script:Trace|Where-Object{$_ -like '*Analyser la liste*'}).Count -ge 1) 'Renvoi vers Rechercher non explique'
        $fleetButtons=@(Get-DomeniaLogicalControls (Get-DomeniaControl 'PnlFleetDashboard')|Where-Object{$_ -is [Windows.Controls.Button] -and $_.Tag -is [hashtable] -and [string]$_.Tag['Action'] -eq 'Probe'})
        Expect ($fleetButtons.Count -eq 0) 'Bouton de requete sur l accueil'
        $script:TestScopeDn='OU=Postes,DC=example,DC=invalid'
        Complete-DomeniaFleetDashboard -Result (New-FleetResult -Scope 'OU=Postes,DC=example,DC=invalid') -State $null
        Expect (@($script:FleetLast.Targets).Count -eq 2 -and [string]$script:FleetLast.Scope -eq 'OU=Postes,DC=example,DC=invalid') 'Perimetre de Rechercher non applique'
        Start-DomeniaParkAnalysis
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
        $script:TestScopeDn='OU=Postes,DC=example,DC=invalid';$script:TestScopeOneLevel=$false
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
        # UI-03: one status line, clickable OU path then 'et ses sous-OU · N postes · base ...'.
        Expect ([string](Get-DomeniaControl 'LblFleetScope').Text -like ' · et ses sous-OU · 2 postes*') ('Perimetre affiche : '+[string](Get-DomeniaControl 'LblFleetScope').Text)
        $crumbs=@(Get-DomeniaLogicalControls (Get-DomeniaControl 'PnlFleetCrumbs')|Where-Object{$_ -is [Windows.Controls.TextBlock]}|ForEach-Object{(New-Object Windows.Documents.TextRange($_.ContentStart,$_.ContentEnd)).Text})
        Expect ($crumbs -contains 'Postes') ('Fil d OU : '+($crumbs -join '|'))
        # Another OU: computed; a lost calculation (cancelled, never answered) is tried again at the next display.
        $script:TestScopeOneLevel=$true
        Request-DomeniaFleetRefresh
        Expect ($script:StartCalls.Count -eq 3 -and -not [bool]$script:StartCalls[2].Payload.Subtree) 'Profondeur de Rechercher ignoree'
        Request-DomeniaFleetRefresh
        Expect ($script:StartCalls.Count -eq 4) 'Calcul perdu jamais repris'
        $observations=@{'cn=pc-1,ou=postes,dc=example,dc=invalid'=[pscustomobject]@{CheckedUtc='2026-10-08T10:00:00.0000000Z';Presence='En ligne'}}
        $merged=Merge-DomeniaFleetObservations -Stored @{'cn=pc-1,ou=postes,dc=example,dc=invalid'=[pscustomobject]@{CheckedUtc='2026-10-08T09:00:00.0000000Z';Presence='Sans reponse'}} -Current $observations
        Expect ([string]$merged['cn=pc-1,ou=postes,dc=example,dc=invalid'].Presence -eq 'En ligne') 'Observation recente remplacee par la base'
        $tabs.SelectedItem=Get-DomeniaControl 'WsSearch'
        $script:TestScopeOneLevel=$false;$script:DatabaseScopedPath='';$script:FleetPendingKey='';$script:FleetJobId=''
    }
    Case 'Widget de requete en attente : etat explicite, puis rempli par un resultat' {
        $data=(Get-DomeniaBoardState 'Fleet').Data
        $item=@(Get-Layout Fleet|Where-Object{$_.Source -eq 'Probe'})[0]
        $pending=Resolve-DomeniaBoardEntry -Board Fleet -Item $item -State (Get-DomeniaBoardState 'Fleet')
        Expect ([string]$pending.Entry.State -eq 'Off') 'Etat en attente'
        Expect ([string]$pending.Entry.Detail -like '*Rechercher*Analyser la liste*') ('Consigne : '+[string]$pending.Entry.Detail)
        # FI-04: query results attached by GUID to the active workstations of the overview, recent ones only.
        $recent=[datetime]::UtcNow.AddHours(-2).ToString('o')
        $script:FleetObservations=@{'cn=pc-1,ou=postes,dc=example,dc=invalid'=[pscustomobject]@{Guid='g-PC-1';CheckedUtc=$recent;Probes=[pscustomobject]@{'os.release'=[pscustomobject]@{Rows=@(,@('26100','1'));Count=1;Error=''}}};'cn=pc-2,ou=postes,dc=example,dc=invalid'=[pscustomobject]@{Guid='g-PC-2';CheckedUtc=$recent;Probes=[pscustomobject]@{'os.release'=[pscustomobject]@{Rows=@(,@('19045','1'));Count=1;Error=''}}}}
        $filled=Resolve-DomeniaBoardEntry -Board Fleet -Item $item -State (Get-DomeniaBoardState 'Fleet')
        Expect ([string]$filled.Entry.Kind -eq 'Distribution' -and @($filled.Entry.Items).Count -eq 2) ('Repartition : '+$filled.Entry.Kind+' '+@($filled.Entry.Items).Count)
        Expect ([string]$filled.Entry.Detail -like '*2 postes analysés sur 2*') ('Couverture : '+[string]$filled.Entry.Detail)
        # A recreated workstation (other GUID) and an observation older than 30 days are left out; past 7 days greyed.
        $script:FleetObservations['cn=pc-2,ou=postes,dc=example,dc=invalid'].Guid='g-recree'
        Expect (@(Get-DomeniaWidgetResults -Board Fleet -ProbeId 'os.release').Count -eq 1) 'Observation d un poste recree comptee'
        $script:FleetObservations['cn=pc-1,ou=postes,dc=example,dc=invalid'].CheckedUtc=[datetime]::UtcNow.AddDays(-40).ToString('o')
        Expect (@(Get-DomeniaWidgetResults -Board Fleet -ProbeId 'os.release').Count -eq 0) 'Observation de plus de 30 jours comptee'
        $script:FleetObservations['cn=pc-1,ou=postes,dc=example,dc=invalid'].CheckedUtc=[datetime]::UtcNow.AddDays(-10).ToString('o')
        $grey=Resolve-DomeniaBoardEntry -Board Fleet -Item $item -State (Get-DomeniaBoardState 'Fleet')
        Expect ([string]$grey.Entry.State -eq 'Off') 'Observation de plus de 7 jours non grisee'
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
        $script:TestScopeDn='';$script:IndexDbCount=0;$script:RemoteAdminCredential=$null
        $script:TestSettings['Home.FirstStepsDone']=$false
        $db=Join-Path ([IO.Path]::GetTempPath()) ('domenia-firststeps-'+[guid]::NewGuid().ToString('N')+'\Domenia.db')
        Set-Item function:script:Get-DomeniaDatabasePath ([scriptblock]::Create("return '"+$db+"'"))
        Update-DomeniaFirstSteps
        $card=Get-DomeniaControl 'CardFirstSteps'
        Expect ($card.Visibility -eq [Windows.Visibility]::Visible) 'Carte Premiers pas masquee au premier lancement'
        $before=$script:StartCalls.Count;$parks=$script:ParkCalls.Count;$script:Workspaces.Clear()
        foreach($step in @('Ou','Base','Account','Backup')){Open-DomeniaFirstStep -Step $step}
        Expect ($script:StartCalls.Count -eq $before -and $script:ParkCalls.Count -eq $parks) 'Une etape a lance une tache'
        Expect (($script:Workspaces -join ',') -eq 'WsSearch/,TabApplicationTools/TabIndex,route:TabAccounts,TabApplicationTools/TabIndex') ('Ecrans ouverts : '+($script:Workspaces -join ','))
        $script:TestScopeDn='OU=Postes,DC=example,DC=invalid';$script:IndexDbCount=12;$script:TestSettings['RemoteCredentialUser']='EXAMPLE\poste'
        $folder=Join-Path ([IO.Path]::GetDirectoryName($db)) 'Backups';[void][IO.Directory]::CreateDirectory($folder);[IO.File]::WriteAllText((Join-Path $folder 'Domenia-20261008.db'),'x')
        Update-DomeniaFirstSteps
        Expect ($card.Visibility -eq [Windows.Visibility]::Collapsed) 'Carte encore affichee apres les quatre etapes'
        Expect ([bool]$script:TestSettings['Home.FirstStepsDone']) 'Preference locale non enregistree'
        Remove-Item -LiteralPath ([IO.Path]::GetDirectoryName($db)) -Recurse -Force -ErrorAction SilentlyContinue
        $script:TestScopeDn='';$script:TestSettings.Remove('RemoteCredentialUser')
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
