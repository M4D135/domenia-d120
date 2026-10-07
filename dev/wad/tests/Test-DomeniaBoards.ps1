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
$script:ExpectedCases=19
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
function Start-DomeniaOnlinePark {param($ScopeTargets,$ScopeLabel,$Probes);$script:ParkCalls.Add([pscustomobject]@{Targets=@($ScopeTargets);Label=$ScopeLabel;Probes=@($Probes)})}
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
    $machine={param($Name,$Container,$Os,$Logon)[pscustomobject]@{name=$Name;object_guid=('g-'+$Name);extra=$Os;last_logon=$Logon;distinguished_name=('CN='+$Name+','+$Container)}}
    return [pscustomobject]@{Busy=$false;Links=2;LinkSources=@()
        Types=@([pscustomobject]@{t='Machine';s='Actif';n=3},[pscustomobject]@{t='Utilisateur';s='Actif';n=12})
        Machines=@((& $machine 'PC-1' 'OU=Postes,DC=example,DC=invalid' 'Windows 11 Entreprise / 10.0 (26100)' '01/10/2026 10:00:00'),(& $machine 'PC-2' 'OU=Postes,DC=example,DC=invalid' 'Windows 10 Entreprise / 10.0 (19045)' '01/05/2026 10:00:00'),(& $machine 'SRV-1' 'OU=Serveurs,DC=example,DC=invalid' 'Windows Server 2025 Datacenter / 10.0 (26100)' ''))
        Presence=@()}
}
try{
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid';Server='dc.example.invalid';Domain='example.invalid';Netbios='EXAMPLE'}
    $script:SessionEpoch=1L;$script:SelectedObject=$null
    $coreText=[IO.File]::ReadAllText((Join-Path $wad 'Domenia-Core.ps1'));$ast=Parse-Text $coreText
    foreach($n in @('Get-MainXaml','Get-DomeniaEffectiveWorkerResult','Get-DomeniaDefaultSettings')){Import-Function $ast $n}
    foreach($m in @('Domenia-Embedded.UI.ps1','Domenia-Boards.Model.ps1','Domenia-Charts.UI.ps1','Domenia-Probes.Model.ps1','Domenia-BoardFleet.Model.ps1','Domenia-BoardSoftware.Model.ps1','Domenia-BoardComputer.UI.ps1','Domenia-Widgets.UI.ps1','Domenia-Dashboard.UI.ps1')){. (Join-Path $wad ('modules\'+$m))}
    $reader=[Xml.XmlNodeReader]::new([xml](Get-MainXaml));try{$w=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    $w.Width=1400;$w.Height=900;$w.ShowInTaskbar=$false
    $palette=(Get-Content -LiteralPath (Join-Path $wad 'modules\SupportSuite.UI.json') -Raw|ConvertFrom-Json).Palettes.Light
    $convert=[Windows.Media.BrushConverter]::new();foreach($p in $palette.PSObject.Properties){$w.Resources[$p.Name]=$convert.ConvertFromInvariantString([string]$p.Value)}
    $script:Window=$w;$w.Show();$w.UpdateLayout()
    $script:DomeniaReduceMotion=$true

    Case 'Les dispositions des tableaux survivent au filtre des reglages' {
        $defaults=Get-DomeniaDefaultSettings
        foreach($key in @('Dashboard.Computer.Layout','Dashboard.Fleet.Layout','Dashboard.Software.Layout','FleetScopeDn','Widgets.Computer','Widgets.Fleet')){Expect ($defaults.Contains($key)) ('Reglage absent de la liste blanche : '+$key)}
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
    }
    Case 'Editeur : Modifier change le titre, et un titre remis par defaut redevient vide' {
        $item=@(Get-Layout Software|Where-Object{$_.Key -eq 'software.largest'})[0]
        $run=Invoke-EditorTrial {Show-DomeniaBoardEditor -Board Software -Id ([string]$item.Id)} {
            param($c,$t)
            (Find-Named $c 'Titre du widget').Text='Plus gros logiciels'
            (Find-Named $c 'Taille').SelectedItem='Compacte'
            $save=@($c|Where-Object{$_ -is [Windows.Controls.Button] -and [string]$_.Content -eq 'Enregistrer'})[0]
            $save.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        }
        $now=@(Get-Layout Software|Where-Object{$_.Id -eq $item.Id})[0]
        Expect ($run.Accepted -and [string]$now.Title -eq '' -and [string]$now.Size -eq 'S') ('Obtenu titre='+$now.Title+' taille='+$now.Size)
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
    Case 'Parc : tableau calcule sur le perimetre et serveurs reconnus' {
        $script:TestSettings['FleetScopeDn']=''
        Complete-DomeniaFleetDashboard -Result (New-FleetResult) -State $null
        $data=(Get-DomeniaBoardState 'Fleet').Data
        Expect ($data.Entries.ContainsKey('fleet.os') -and $data.Entries.ContainsKey('fleet.health')) 'Entrees du parc'
        Expect (@($script:FleetLast.Targets).Count -eq 3) 'Cibles du perimetre'
        Expect (@($data.Entries['fleet.attention'].Items|Where-Object{[string]$_.Text -like '*Windows 10*'}).Count -eq 1) 'Windows 10 signale'
        Expect (@(Get-Holders (Get-DomeniaControl 'PnlFleetDashboard')).Count -ge 6) 'Widgets du parc'
    }
    Case 'Requetes : jamais le domaine entier, une OU choisie est acceptee' {
        $layout=@(Get-Layout Fleet)
        Set-DomeniaBoardLayout -Board Fleet -Layout @(Add-DomeniaBoardItem -Layout $layout -Item (New-DomeniaBoardItem -Source Probe -Key 'os.release' -Visual 'Pie' -Group 'Systeme'))
        $script:ParkCalls.Clear();Start-DomeniaWidgetProbe -Board Fleet
        Expect ($script:ParkCalls.Count -eq 0) 'Domaine entier sonde'
        Expect (@($script:Trace|Where-Object{$_ -like '*jamais le domaine entier*'}).Count -ge 1) 'Refus non explique'
        $script:TestSettings['FleetScopeDn']='OU=Postes,DC=example,DC=invalid'
        Complete-DomeniaFleetDashboard -Result (New-FleetResult) -State $null
        Start-DomeniaWidgetProbe -Board Fleet
        Expect ($script:ParkCalls.Count -eq 1 -and @($script:ParkCalls[0].Targets).Count -eq 2) 'OU non sondee ou mal ciblee'
        Expect (@($script:ParkCalls[0].Probes|Where-Object{[string]$_.Id -eq 'os.release'}).Count -eq 1) 'Requete absente'
    }
    Case 'Widget de requete en attente : etat explicite, puis rempli par un resultat' {
        $data=(Get-DomeniaBoardState 'Fleet').Data
        $item=@(Get-Layout Fleet|Where-Object{$_.Source -eq 'Probe'})[0]
        $pending=Resolve-DomeniaBoardEntry -Board Fleet -Item $item -State (Get-DomeniaBoardState 'Fleet')
        Expect ([string]$pending.Entry.State -eq 'Off') 'Etat en attente'
        $script:FleetObservations=@{'cn=pc-1,ou=postes,dc=example,dc=invalid'=[pscustomobject]@{Probes=[pscustomobject]@{'os.release'=[pscustomobject]@{Rows=@(,@('26100','1'));Count=1;Error=''}}};'cn=pc-2,ou=postes,dc=example,dc=invalid'=[pscustomobject]@{Probes=[pscustomobject]@{'os.release'=[pscustomobject]@{Rows=@(,@('19045','1'));Count=1;Error=''}}}}
        $filled=Resolve-DomeniaBoardEntry -Board Fleet -Item $item -State (Get-DomeniaBoardState 'Fleet')
        Expect ([string]$filled.Entry.Kind -eq 'Distribution' -and @($filled.Entry.Items).Count -eq 2) ('Repartition : '+$filled.Entry.Kind+' '+@($filled.Entry.Items).Count)
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
