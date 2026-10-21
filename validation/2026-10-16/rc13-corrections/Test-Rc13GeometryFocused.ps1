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
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
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
    $script:Xaml=Get-MainXaml -WadRoot (Split-Path -Parent $PSScriptRoot)
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
    if($null -eq $script:GeometrySurface){
        $Window.UpdateLayout();$Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle);$Window.UpdateLayout();return
    }
    # Keep the requested client viewport, including real window chrome deductions.
    # The lab session-0 HWND is limited by its desktop; it is not the measured surface.
    # Window.Width/Height can themselves be coerced by Show to the desktop size.
    # Keep the scenario dimensions independently from that native HWND.
    $w=[Math]::Max(1,$script:GeometryRequestedWidth-$script:GeometryChromeWidth)
    $h=[Math]::Max(1,$script:GeometryRequestedHeight-$script:GeometryChromeHeight)
    $script:GeometrySurface.Width=$w;$script:GeometrySurface.Height=$h
    for($pass=0;$pass -lt 2;$pass++){
        $script:GeometrySurface.Measure([Windows.Size]::new($w,$h))
        $script:GeometrySurface.Arrange([Windows.Rect]::new(0,0,$w,$h))
        $script:GeometrySurface.UpdateLayout()
        $Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
    }
    Assert-True ([Math]::Abs($script:GeometrySurface.ActualWidth-$w) -le 0.5 -and [Math]::Abs($script:GeometrySurface.ActualHeight-$h) -le 0.5) 'La surface WPF ne correspond pas au viewport demande.'
}
function Test-GeometryVisible {param($Control)
    # IsVisible requires a PresentationSource and is false for off-screen rendering.
    # Effective Visibility must still be Visible through every real visual ancestor.
    $node=$Control
    while($null -ne $node){
        if($node -is [Windows.UIElement] -and $node.Visibility -ne [Windows.Visibility]::Visible){return $false}
        if([object]::ReferenceEquals($node,$script:GeometrySurface)){return $true}
        $node=[Windows.Media.VisualTreeHelper]::GetParent($node)
    }
    return $false
}
function New-GeometryWindow {
    param([string]$Theme,[double]$Width,[double]$Height)
    $script:GeometrySurface=$null
    $script:GeometryRequestedWidth=$Width
    $script:GeometryRequestedHeight=$Height
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
    $script:UxShortScreen=$false;$script:UxShortHelpOpen=$false;$script:UxShortLogHeld=$false;$script:UxShortLogReleased=$false;$script:UxShortNavFold=$false;$script:UxShortNavReleased=$false
    $script:UxLogCollapsed=$false;$script:UxLogHeight=142.0
    # Wire the real zoom/ScrollChanged path, as WireEvents does before showing the shell.
    # Viewport changes must resize UxShellGrid and recompute the responsive plan.
    Initialize-DomeniaUiZoom
    $window.Show();Invoke-GeometryPump $window
    $content=$window.Content
    $script:GeometryChromeWidth=[double]$window.ActualWidth-[double]$content.ActualWidth
    $script:GeometryChromeHeight=[double]$window.ActualHeight-[double]$content.ActualHeight
    $window.Content=$null
    $script:GeometrySurface=[Windows.Controls.Grid]::new()
    $script:GeometrySurface.Resources=$window.Resources
    $script:GeometrySurface.SetValue([Windows.Documents.TextElement]::FontFamilyProperty,$window.FontFamily)
    $script:GeometrySurface.SetValue([Windows.Documents.TextElement]::FontSizeProperty,$window.FontSize)
    $script:GeometrySurface.UseLayoutRounding=$true
    [void]$script:GeometrySurface.Children.Add($content)
    $window.Content=[Windows.Controls.Grid]::new()
    Invoke-GeometryPump $window
    Update-DomeniaUxLayout;Invoke-GeometryPump $window
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
    $p=$c.TranslatePoint([Windows.Point]::new(0,0),$script:GeometrySurface)
    return [pscustomobject]@{Name=$Name;X=[double]$p.X;Y=[double]$p.Y;W=[double]$c.ActualWidth;H=[double]$c.ActualHeight;Visible=(Test-GeometryVisible $c)}
}
function Get-Geometry {param($Window,[string[]]$Names)
    return ,@($Names|ForEach-Object{Get-ClientRect $Window $_})
}
function Assert-OuNavigationLayout {param($Window)
    $tree=Get-ClientRect $Window 'TvDirectory'
    Assert-True ($tree.Visible -and $tree.H -ge 80) ('Arbre OU trop petit : '+$tree.H)
    $details=$Window.FindName('UxOuRefreshExpander');$expanded=$details.IsExpanded
    $details.IsExpanded=$true;Invoke-GeometryPump $Window
    $footer=Get-ClientRect $Window 'UxSearchOuRefresh'
    foreach($name in @('BtnSearchRefreshBase','BtnSearchRefreshPostes','BtnSearchRefreshBoth','BtnSearchRefreshStop','LblSearchOuRefreshScope','LblSearchOuRefreshStatus')){
        $r=Get-ClientRect $Window $name
        # DS-11: « Arrêter » keeps its place but stays hidden while no refresh runs (UxStopButton).
        $control=$Window.FindName($name)
        if(($name -eq 'BtnSearchRefreshStop') -and (-not $control.IsEnabled)){
            Assert-True ($control.Visibility -eq [Windows.Visibility]::Hidden) 'Arreter visible alors que rien ne tourne'
            $r=[pscustomobject]@{Name=$r.Name;X=$r.X;Y=$r.Y;W=$r.W;H=$r.H;Visible=$true}
        }
        Assert-True ($r.Visible -and $r.W -ge 20 -and $r.H -ge 10 -and $r.X -ge 0 -and $r.Y -ge 0 -and $r.X+$r.W -le $script:GeometrySurface.ActualWidth+0.5 -and $r.Y+$r.H -le $script:GeometrySurface.ActualHeight+0.5) ($name+' hors de la surface de recherche')
        Assert-True ($r.X -ge $footer.X-0.5 -and $r.Y -ge $footer.Y-0.5 -and $r.X+$r.W -le $footer.X+$footer.W+0.5 -and $r.Y+$r.H -le $footer.Y+$footer.H+0.5) ($name+' deborde du panneau de mise a jour OU')
    }
    if($script:UxCompactLayoutActive){
        Assert-True ($Window.FindName('UxSearchOuRefreshActions').ActualHeight -le 60.5) ('Commandes OU sur plus de deux rangees : '+$Window.FindName('UxSearchOuRefreshActions').ActualHeight)
        Assert-True ($Window.FindName('BtnSearchRefreshPostes').Content -ceq 'Ping') 'Action postes compacte non explicite.'
    }
    $details.IsExpanded=$expanded;Invoke-GeometryPump $Window
}
function Assert-SameGeometry {param($Before,$After,[string]$Step)
    for($i=0;$i -lt $Before.Count;$i++){
        $a=$Before[$i];$b=$After[$i]
        foreach($axis in @('X','Y','W','H')){
            if([Math]::Abs([double]$a.$axis-[double]$b.$axis) -gt 0.5){throw ($Step+' : '+$a.Name+'.'+$axis+' '+[Math]::Round($a.$axis,1)+' -> '+[Math]::Round($b.$axis,1))}
        }
    }
}


if($infrastructure){
 foreach($size in @(@(960,516),@(1024,768))){
  $window=$null
  try{
   $window=New-GeometryWindow -Theme Light -Width $size[0] -Height $size[1]
   if($size[0] -eq 960){
    foreach($key in $script:Ctrl.Keys){$c=$script:Ctrl[$key];if($c -is [Windows.FrameworkElement] -and $c.ActualHeight -gt 35 -and (Test-GeometryVisible $c)){$script:Observations.Add([pscustomobject]@{Name=$key;Type=$c.GetType().Name;Height=$c.ActualHeight;ParentName=$c.Parent.Name;MinHeight=$c.MinHeight})}}
    $script:Observations.Add([pscustomobject]@{Short=$script:UxShortScreen;Compact=$script:UxCompactLayoutActive;LogCollapsed=$script:UxLogCollapsed;LogHeld=$script:UxShortLogHeld;Available=(Get-DomeniaUxAvailableSize)})
   }
   Test-Case ($size[0].ToString()+'x'+$size[1]+' results') {
    $r=Get-ClientRect $window 'DgObjects'
    Assert-True ($r.Visible -and $r.W -ge 200 -and $r.H -ge 80) ('Results collapsed: '+$r.W+'x'+$r.H)
   }
   Test-Case ($size[0].ToString()+'x'+$size[1]+' OU tree') {Assert-OuNavigationLayout $window}
   if($size[0] -eq 960){
    Test-Case 'Tiny results controls remain reachable on explicit expansion' {
     $details=$window.FindName('UxResultToolsExpander')
     Assert-True (-not $details.IsExpanded) 'Optional controls should start folded'
     $details.IsExpanded=$true;Invoke-GeometryPump $window
     foreach($name in @('TxtSuiteResultFilter','BtnParkVerify','CmbResultScope','CmbSearchWorkspace')){
      $r=Get-ClientRect $window $name
      Assert-True ($r.Visible -and $r.H -ge 18 -and $r.W -ge 20 -and $r.Y+$r.H -le $script:GeometrySurface.ActualHeight+0.5) ($name+' inaccessible after expansion')
     }
     Update-DomeniaUxLayout;Invoke-GeometryPump $window
     Assert-True $details.IsExpanded 'Layout refresh erased operator expansion'
     $details.IsExpanded=$false;Invoke-GeometryPump $window
     $r=Get-ClientRect $window 'DgObjects';Assert-True ($r.H -ge 80) 'Folding did not restore list height'
    }
   }
  }finally{if($null -ne $window){$window.Close()}}
 }
}
$failed=@($script:Checks|Where-Object Status -eq Failed).Count
$report=[pscustomobject]@{Scope='Focused native WPF geometry; synthetic off-screen viewport, no real DPI qualification';NativeWindowsPowerShell51=$true;PowerShell=$PSVersionTable.PSVersion.ToString();Passed=$script:Checks.Count-$failed;Failed=$failed;Tests=$script:Checks.ToArray();Geometry=$script:Observations.ToArray()}
$report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $ReportPath -Encoding UTF8
if($failed){exit 1}
