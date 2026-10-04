#requires -Version 5.1
<# D006 : tests visuels et geometriques de la fenetre principale reelle.
   Themes clair et sombre (palettes de SupportSuite.UI.json), petit ecran, session RDP 1024x768 et mise a
   l'echelle 100 a 200 % simulee en unites WPF : la zone de travail d'un ecran W x H physiques a l'echelle s vaut
   W/s x (H-48)/s unites WPF (barre des taches de 48 pixels). Aucun changement de DPI systeme n'est fait.
   Critere : une operation ne deplace pas la recherche, les resultats ni leurs boutons ; aucun champ essentiel
   n'est inaccessible. XAML principal reel (Get-MainXaml), mise en page reelle (Update-DomeniaUxLayout),
   indicateurs reels (Update-TaskUi, Update-DomeniaWriteModeVisual). Aucune donnee reelle, aucun acces AD.
#>
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet)
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot
$script:Checks=[Collections.Generic.List[object]]::new()
$script:Observations=[Collections.Generic.List[object]]::new()
$script:PresentationErrors=[Collections.Generic.List[string]]::new()
function Assert-True {param([bool]$Value,[string]$Why='Assertion fausse');if(-not $Value){throw $Why}}
function Test-Case {param([string]$CaseLabel,[scriptblock]$Body)
    try { & $Body | Out-Null; $script:Checks.Add([pscustomobject]@{Name=$CaseLabel;Status='Passed';Detail=''}) }
    catch { $script:Checks.Add([pscustomobject]@{Name=$CaseLabel;Status='Failed';Detail=($_.Exception.Message+' @ '+$_.ScriptStackTrace)}) }
}
function Read-SourceAst {param([string]$Path)
    $t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e)
    if(@($e).Count){throw ($Path+' : '+$e[0].Message)}
    return $a
}

$infrastructure=$true
try {
    if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or -not [Environment]::Is64BitProcess -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){
        throw 'Windows PowerShell 5.1 x64 -STA requis ; une execution sous PowerShell 7 ne vaut pas preuve.'
    }
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    . (Join-Path $wad 'Domenia-Modules.ps1')
    $coreAst=Read-SourceAst (Join-Path $wad 'Domenia-Core.ps1')
    foreach($name in @('Get-MainXaml','Get-DomeniaXamlControlNames','Get-DomeniaControl','Set-DomeniaControlText','Update-TaskUi','Update-DomeniaWriteModeVisual')){
        $nodes=@($coreAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
        if($nodes.Count -ne 1){throw ('Fonction absente ou ambigue : '+$name)}
        . ([scriptblock]::Create($nodes[0].Extent.Text))
    }
    $script:Xaml=Get-MainXaml
    $script:Design=Get-Content -LiteralPath (Join-Path $wad 'modules\SupportSuite.UI.json') -Raw -Encoding UTF8|ConvertFrom-Json
}
catch {
    $infrastructure=$false
    $script:Checks.Add([pscustomobject]@{Name='Infrastructure : Windows PowerShell 5.1, plan ferme, XAML principal';Status='Failed';Detail=$_.Exception.ToString()})
}

# Boundaries: no configuration file, no dashboard refresh, presentation errors are collected (and fail the case).
function Get-CfgValue {param($Section,$Name,$Default);return $Default}
function Request-DomeniaDashboardRefresh {param([switch]$Immediate)}
function Write-AppLog {param($Text,$Level) if([string]$Level -in @('WARN','ERROR')){$script:PresentationErrors.Add([string]$Text)}}
function Set-DomeniaSetting {param($Name,$Value)}
function Get-DomeniaSetting {param($Name,$Default);return $Default}
function Invoke-GeometryPump {param($Window)
    $Window.UpdateLayout()
    $Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
    $Window.UpdateLayout()
}
function New-GeometryWindow {
    param([string]$Theme,[double]$Width,[double]$Height)
    $reader=[Xml.XmlNodeReader]::new([xml]$script:Xaml)
    try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    $window.ShowActivated=$false;$window.ShowInTaskbar=$false
    $window.WindowStartupLocation='Manual';$window.Left=0;$window.Top=0
    $window.Width=$Width;$window.Height=$Height
    $window.Title='DOMENIA | TEST GEOMETRIE | donnees fictives, sans AD'
    $converter=[Windows.Media.BrushConverter]::new()
    foreach($property in $script:Design.Palettes.$Theme.PSObject.Properties){$window.Resources[$property.Name]=$converter.ConvertFromInvariantString([string]$property.Value)}
    $script:Ctrl=@{}
    foreach($name in @(Get-DomeniaXamlControlNames -XamlText $script:Xaml)){$c=$window.FindName($name);if($null -ne $c){$script:Ctrl[$name]=$c}}
    # The operation detail page is outside this test, as in Test-DomeniaActivityLayout.
    $script:Ctrl.Remove('TabExperience')
    $window.FindName('WorkspaceTabs').SelectedItem=$window.FindName('WsSearch')
    $rows=[Collections.ObjectModel.ObservableCollection[object]]::new()
    for($i=1;$i -le 20;$i++){$rows.Add([pscustomobject]@{Type='Machine';Name=('PC-DEMO-{0:d2}' -f $i);Login=('PC-DEMO-{0:d2}' -f $i);UPN='example.invalid';Presence='Non vérifié';DN=('CN=PC-DEMO-'+$i+',DC=example,DC=invalid')})}
    $window.FindName('DgObjects').ItemsSource=$rows
    $script:AsyncJobs=@{};$script:DetachedReadJobs=@();$script:LatestTaskId='';$script:LastTaskUiCount=-1
    $script:LastTaskUiRefresh=[datetime]::MinValue;$script:ExperienceInitialized=$true;$script:WriteState='Idle'
    $script:ReadOnlyMode=$true;$script:BaseWindowTitle=$window.Title;$script:Window=$window
    # Real responsive layout of the UX module (navigation column, help panel), first-run defaults.
    $script:UxNavCollapsed=$false;$script:UxHelpVisible=$true;$script:UxHelpCompactOpen=$false;$script:UxLayoutSignature='';$script:UxNavLayoutSignature=''
    $window.Show();Invoke-GeometryPump $window
    Update-DomeniaUxLayout;Invoke-GeometryPump $window
    return $window
}
function Set-FakeActivity {param([int]$Count,[string]$Name='Lecture fictive',[int]$Seconds=1)
    $script:AsyncJobs=@{}
    for($i=0;$i -lt $Count;$i++){$script:AsyncJobs['demo'+$i]=[pscustomobject]@{Id='demo'+$i;Name=$Name;Started=(Get-Date).AddSeconds(-$Seconds);IsWrite=$false}}
    $script:LatestTaskId=if($Count){'demo0'}else{''}
    Update-TaskUi -Force
}
function Get-ClientRect {param($Window,[string]$Name)
    $c=$Window.FindName($Name);if($null -eq $c){throw ('Controle absent : '+$Name)}
    $p=$c.TranslatePoint([Windows.Point]::new(0,0),$Window.Content)
    return [pscustomobject]@{Name=$Name;X=[double]$p.X;Y=[double]$p.Y;W=[double]$c.ActualWidth;H=[double]$c.ActualHeight;Visible=[bool]$c.IsVisible}
}
function Get-Geometry {param($Window,[string[]]$Names)
    return ,@($Names|ForEach-Object{Get-ClientRect $Window $_})
}
function Assert-SameGeometry {param($Before,$After,[string]$Step)
    for($i=0;$i -lt $Before.Count;$i++){
        $a=$Before[$i];$b=$After[$i]
        foreach($axis in @('X','Y','W','H')){
            if([Math]::Abs([double]$a.$axis-[double]$b.$axis) -gt 0.5){throw ($Step+' : '+$a.Name+'.'+$axis+' '+[Math]::Round($a.$axis,1)+' -> '+[Math]::Round($b.$axis,1))}
        }
    }
}

$configurations=@(
    @{Name='Bureau 1920x1080 100 %';W=1920;H=1080;Scale=1.0},
    @{Name='Ecran 1920x1080 125 %';W=1920;H=1080;Scale=1.25},
    @{Name='Ecran 1920x1080 150 %';W=1920;H=1080;Scale=1.5},
    @{Name='Ecran 1920x1080 175 %';W=1920;H=1080;Scale=1.75},
    @{Name='Ecran 2560x1440 200 %';W=2560;H=1440;Scale=2.0},
    @{Name='Ecran 1920x1080 200 %';W=1920;H=1080;Scale=2.0},
    @{Name='Portable 1366x768 100 %';W=1366;H=768;Scale=1.0},
    @{Name='Portable 1366x768 125 %';W=1366;H=768;Scale=1.25},
    @{Name='Session RDP 1024x768';W=1024;H=768;Scale=1.0}
)
$essentials=@('TxtGlobalSearch','BtnGlobalSearch','DgObjects','BtnAccessRecovery','TxtSuiteResultFilter','BtnGlobalClear','BtnExportResults')
$resultButtons=@('BtnLoadBranch','BtnGlobalClear','BtnExportResults','BtnSuiteResultClear','BtnLiveRecheck','TxtSuiteResultFilter','CmbGlobalType','CmbPresenceFilter','ChkLiveUsers')

if($infrastructure){
    foreach($configuration in $configurations){
        $workW=[Math]::Floor($configuration.W/$configuration.Scale)
        $workH=[Math]::Floor(($configuration.H-48)/$configuration.Scale)
        foreach($theme in @('Light','Dark')){
            $prefix=$configuration.Name+' '+$(if($theme -eq 'Light'){'clair'}else{'sombre'})
            $window=$null
            try {
                $script:PresentationErrors.Clear()
                $window=New-GeometryWindow -Theme $theme -Width $workW -Height $workH
                $fits=($window.ActualWidth -le $workW+0.5 -and $window.ActualHeight -le $workH+0.5)
                $chromeW=[double]$window.ActualWidth-[double]$window.Content.ActualWidth
                $chromeH=[double]$window.ActualHeight-[double]$window.Content.ActualHeight
                $visibleW=$workW-$chromeW;$visibleH=$workH-$chromeH
                if(-not $fits){
                    # Reported, not hidden: the minimum window size exceeds the work area of this screen.
                    $script:Observations.Add([pscustomobject]@{Configuration=$prefix;WorkArea=($workW.ToString()+'x'+$workH);Window=([string][Math]::Round($window.ActualWidth)+'x'+[Math]::Round($window.ActualHeight));Detail='Fenetre minimale plus grande que la zone de travail : le bas de la fenetre sort de l ecran.'})
                }
                Test-Case ($prefix+' : champs essentiels visibles et atteignables') {
                    Set-FakeActivity 1;Invoke-GeometryPump $window
                    foreach($name in @($essentials+'BtnCancelTask')){
                        $r=Get-ClientRect $window $name
                        Assert-True ($r.Visible -and $r.W -ge 8 -and $r.H -ge 8) ($name+' invisible ou ecrase ('+[Math]::Round($r.W)+'x'+[Math]::Round($r.H)+').')
                        $bottom=if($name -eq 'DgObjects'){$r.Y+[Math]::Min(120,$r.H)}else{$r.Y+$r.H}
                        $right=if($name -eq 'DgObjects'){$r.X+[Math]::Min(320,$r.W)}else{$r.X+$r.W}
                        Assert-True ($r.X -ge -0.5 -and $r.Y -ge -0.5 -and $right -le $visibleW+0.5 -and $bottom -le $visibleH+0.5) ($name+' hors de la zone visible ('+[Math]::Round($right)+','+[Math]::Round($bottom)+' pour '+[Math]::Round($visibleW)+'x'+[Math]::Round($visibleH)+').')
                    }
                    Set-FakeActivity 0;Invoke-GeometryPump $window
                    Assert-True ($script:PresentationErrors.Count -eq 0) ('Erreur de presentation : '+($script:PresentationErrors -join ' | '))
                }
                Test-Case ($prefix+' : une operation ne deplace ni la recherche, ni les resultats, ni leurs boutons') {
                    Set-FakeActivity 0;Invoke-GeometryPump $window
                    $measured=@(@('TxtGlobalSearch','BtnGlobalSearch','DgObjects')+@($resultButtons|Where-Object{$window.FindName($_).IsVisible}))
                    Assert-True ($measured.Count -ge 6) ('Trop peu de boutons de resultats visibles : '+($measured -join ', '))
                    $stable=Get-Geometry $window $measured
                    foreach($count in @(1,10,100,0)){
                        $label=if($count -ge 10){'Lecture fictive avec un intitule long pour verifier que la bande d activite reste dans sa hauteur reservee'}else{'Lecture fictive'}
                        Set-FakeActivity $count $label (7*$count);Invoke-GeometryPump $window
                        Assert-SameGeometry $stable (Get-Geometry $window $measured) ('Activite '+$count)
                    }
                    # Results arrive and counters change while the operation runs.
                    Set-FakeActivity 1;$grid=$window.FindName('DgObjects');$more=[Collections.ObjectModel.ObservableCollection[object]]::new()
                    for($i=1;$i -le 200;$i++){$more.Add([pscustomobject]@{Type='Utilisateur';Name=('Utilisateur fictif numero '+$i);Login=('u'+$i);UPN=('u'+$i+'@example.invalid');Presence='Non vérifié';DN=('CN=U'+$i+',DC=example,DC=invalid')})}
                    $grid.ItemsSource=$more;$grid.SelectedIndex=3
                    # Texts produced by the application during a search (Live.UI, Search.Model counter wording).
                    [void](Set-DomeniaControlText 'LblBranchCount' '200 objets · liste limitee a 200 : affinez ou chargez la suite')
                    [void](Set-DomeniaControlText 'LblSuiteResultCount' '37 / 200 lignes visibles · recherche globale sans filtre local')
                    # D028: the longest save state of the rule (Get-DomeniaPersistenceLabel, conflict case) at the end of the Live line.
                    [void](Set-DomeniaControlText 'LblLiveState' 'Vérification du poste sélectionné ; les observations précédentes restent datées en cache. · En memoire : 12 association(s) modifiee(s) ailleurs, non enregistree(s). Rechargez les associations : Comptes > Changer de compte, ou redemarrage.')
                    [void](Set-DomeniaControlText 'LblSelectionReadState' 'Utilisateur : Utilisateur fictif numero 4 | Lecture AD en arriere-plan...')
                    Invoke-GeometryPump $window
                    Assert-SameGeometry $stable (Get-Geometry $window $measured) 'Arrivee des resultats'
                    foreach($readOnly in @($false,$true)){$script:ReadOnlyMode=$readOnly;Update-DomeniaWriteModeVisual;Invoke-GeometryPump $window;Assert-SameGeometry $stable (Get-Geometry $window $measured) ('Mode ecriture '+(-not $readOnly))}
                    Set-FakeActivity 0;Invoke-GeometryPump $window
                    Assert-SameGeometry $stable (Get-Geometry $window $measured) 'Fin de l operation'
                    Assert-True ($script:PresentationErrors.Count -eq 0) ('Erreur de presentation : '+($script:PresentationErrors -join ' | '))
                }
            }
            catch {$script:Checks.Add([pscustomobject]@{Name=($prefix+' : fenetre de test');Status='Failed';Detail=$_.Exception.ToString()})}
            finally {if($null -ne $window){$window.Close()};$script:Window=$null;$script:Ctrl=@{}}
        }
    }
}

$failed=@($script:Checks|Where-Object{$_.Status -eq 'Failed'}).Count
$passed=@($script:Checks|Where-Object{$_.Status -eq 'Passed'}).Count
$report=[ordered]@{
    Kind='Geometry';Point='D006';Rule='Une operation ne deplace pas la recherche, les resultats ni leurs boutons ; aucun champ essentiel n est inaccessible.'
    Method='Fenetre WPF reelle a la taille de la zone de travail en unites WPF ; echelle simulee, DPI systeme inchange.'
    Host=@{PSEdition=[string]$PSVersionTable.PSEdition;PSVersion=$PSVersionTable.PSVersion.ToString();SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId;Interactive=[Environment]::UserInteractive}
    NoADAccess=$true;Passed=$passed;Failed=$failed;Complete=($failed -eq 0 -and $passed -gt 0)
    Observations=$script:Observations.ToArray();Tests=$script:Checks.ToArray()
}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-geometry-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){$script:Checks|Format-Table Name,Status -AutoSize|Out-String|Write-Host;$script:Observations|Format-Table -AutoSize|Out-String|Write-Host;Write-Host ('Rapport : '+$ReportPath)}
if($failed -gt 0 -or $passed -eq 0){exit 1}
exit 0
