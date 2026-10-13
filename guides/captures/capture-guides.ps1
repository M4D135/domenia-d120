#requires -Version 5.1
# Captures des guides Domenia 1.0. Vraie fenetre WPF du depot, valeurs fictives coherentes
# (domaine example.local), rendue hors ecran a 1920 x 1080. Aucun annuaire ni poste distant n est contacte.
# Ces illustrations ne constituent pas un test de connexion AD ni une qualification des transports.
# A lancer dans la VM de test (powershell.exe -STA), jamais sur un poste de production.
param([string]$Dev = 'C:\DomeniaLab\d120\dev',[string]$Out = 'C:\DomeniaLab\d120\guide-captures',[int]$Width = 1920,[int]$Height = 1080,[ValidateSet('All','Base')][string]$CaptureSet='All')
$script:GuideWidth=$Width
$script:GuideHeight=$Height
$ErrorActionPreference = 'Stop'
$script:GuideChecks = [Collections.Generic.List[object]]::new()
$script:GuideImages = [Collections.Generic.List[object]]::new()
$script:GuideLayouts = [Collections.Generic.List[object]]::new()
function Assert-Guide { param([bool]$Condition,[string]$Name) $script:GuideChecks.Add([pscustomobject]@{Name=$Name;Passed=$Condition}); if(-not $Condition){throw ('Capture fixture: '+$Name)} }
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
# The test VM desktop is 1024 x 768: the maximum window size is raised so the layout is the one of a usual screen.
Add-Type -ReferencedAssemblies PresentationFramework,PresentationCore,WindowsBase,System.Xaml -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Windows; using System.Windows.Interop;
public static class GuideCaptureHook {
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    // SWP_NOSENDCHANGING: the size is applied without the screen-size clamp of WM_WINDOWPOSCHANGING.
    public static void Resize(Window w, int width, int height) {
        SetWindowPos(new WindowInteropHelper(w).Handle, IntPtr.Zero, 0, 0, width, height, 0x0004 | 0x0010 | 0x0400);
    }
    public static void Allow(Window w, int width, int height) {
        HwndSource src = HwndSource.FromHwnd(new WindowInteropHelper(w).EnsureHandle());
        src.AddHook((IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled) => {
            if (msg == 0x0024) {
                Marshal.WriteInt32(lParam, 8, width); Marshal.WriteInt32(lParam, 12, height);
                Marshal.WriteInt32(lParam, 32, width); Marshal.WriteInt32(lParam, 36, height);
                handled = true;
            }
            return IntPtr.Zero;
        });
    }
}
'@
[void][IO.Directory]::CreateDirectory($Out)
$wad = Join-Path $Dev 'wad'
foreach ($library in @('M4D.Admin.Common.Query.dll','Domenia.Native.dll')) {
    [void][Reflection.Assembly]::LoadFrom((Join-Path $wad ('modules\' + $library)))
}
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$tokens,[ref]$parseErrors)
if (@($parseErrors).Count) { throw ('Coeur illisible : ' + $parseErrors[0].Message) }
$coreNames = @(
    'Set-DomeniaControlText','Get-MainXaml','Assert-DomeniaXamlPreflight','Get-DomeniaXamlControlNames',
    'Get-CfgValue','Get-DomeniaControl','Set-DomeniaContextHint','Get-DomeniaFriendlyControlLabel',
    'Get-DomeniaDefaultToolTip','Save-DomeniaUiProfile','Apply-DomeniaUiProfile',
    'Get-DomeniaDefaultSettings','Apply-DomeniaPresenceFilter','Get-DomeniaLandingView','Set-TabVisibility','Set-VisibleTabsForType','Assert-DomeniaWorkspaceSelection',
    'Select-DomeniaWorkspace','Get-DomeniaSearchMode','Get-DomeniaSearchText','Set-DomeniaSearchMode','Get-DomeniaSearchScope','Update-DomeniaSearchScopeUi',
    'Set-SelectedBranch','Reset-DomeniaSearchScope','Update-DomeniaNewOuParentUi','Set-DomeniaComboByContent',
    'Get-DomeniaGridDateSortKey','Get-DomeniaGridDateShortText','Add-DomeniaGridDateKeys','Set-DomeniaItemsSource','Set-DomeniaGridRows','Test-DomeniaSearchStateCurrent','Get-GlobalSelectedTypeFilter','Get-TypeLdapFilter','Get-DomeniaEffectiveWorkerResult','Normalize-LinkComputer',
    'Update-DomeniaSoftwareSyntheseVisibility','Set-DomeniaIndexProgress','Get-DomeniaStandardLoginXaml','Convert-DomeniaXamlToBootTheme','Get-DomeniaBootThemePalette','Get-DomeniaBootThemeResources','Get-WriteControlMap'
)
foreach ($name in $coreNames) {
    $nodes = @($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
    if ($nodes.Count -ne 1) { throw ('Fonction introuvable : ' + $name) }
    Invoke-Expression $nodes[0].Extent.Text
}
foreach ($module in @('Domenia-Common.Model.ps1','Domenia-Relations.Model.ps1','Domenia-Access.Model.ps1','Domenia-Shell.Model.ps1','Domenia-Embedded.UI.ps1','Domenia-UX.UI.ps1',
    'Domenia-Workstation.Model.ps1','Domenia-Boards.Model.ps1','Domenia-Charts.UI.ps1','Domenia-Probes.Model.ps1','Domenia-BoardFleet.Model.ps1','Domenia-BoardSoftware.Model.ps1','Domenia-BoardComputer.UI.ps1','Domenia-Widgets.UI.ps1','Domenia-Dashboard.UI.ps1','Domenia-Query.Model.ps1','Domenia-Query.Worker.ps1','Domenia-Query.UI.ps1','Domenia-QueryTargets.UI.ps1','Domenia-Search.Model.ps1','Domenia-Search.UI.ps1','Domenia-Refresh.UI.ps1')) {
    . (Join-Path $wad ('modules\' + $module))
}
# Local replacements: no settings, log, directory or workstation is touched.
$script:GuideSettings = @{}; $script:Ctrl = @{}; $script:SelectedObject = $null; $script:CurrentUiProfile = 'Tech'; $script:ReadOnlyMode = $true
# Some transactional saves deliberately write Settings directly before calling Save-DomeniaSettings.
# The fixture getter/setter and those writes must share the same in-memory dictionary.
$script:Settings=$script:GuideSettings
$script:Config=@{} # No configuration file is read; the real getter uses documented defaults.
$script:DatabaseScopedPath='C:\DomeniaGuideFixture\Domenia.db' # Context identity only; no file is created or opened.
$script:DemoMode=$false; $script:DomeniaOuRefresh=$null
$script:RootDir=$wad
$script:Conn = [pscustomobject]@{ Connected = $true; BaseDn = 'DC=example,DC=local'; Domain = 'example.local'; Netbios = 'EXAMPLE' }
$script:SelectedBranchDn = $script:Conn.BaseDn; $script:SearchMode = 'OU'; $script:SuppressBranchAutoLoad = $true; $script:RestoringSettings = $false
$script:AsyncJobs = @{}; $script:DetachedReadJobs = @(); $script:SessionEpoch = 1; $script:WriteState = 'Idle'; $script:DomeniaReduceMotion = $true
function Set-DomeniaSetting { param([string]$Name,$Value) $script:GuideSettings[$Name] = $Value }
function Get-DomeniaSetting { param([string]$Name,$Default = $null) if ($script:GuideSettings.ContainsKey($Name)) { return $script:GuideSettings[$Name] }; return $Default }
function Save-DomeniaSettings { param([switch]$Immediate,[switch]$ThrowOnFailure) }
function Test-DomeniaLiveSearchActive { return $false }
function Invalidate-DomeniaSearchResults { $script:GlobalSearchGeneration++; $script:ShownRows=@() }
function Add-DomeniaUiLog { param([string]$Area,[string]$Text,[string]$Level = 'INFO') }
function Set-Status { param([string]$Text,[string]$Level = 'INFO') }
function Write-AppLog { param([string]$Text,[string]$Level = 'INFO') }
function Apply-DomeniaGuiElementPolicy { }
function Update-Dashboard { }
function Get-DomeniaCredentialUserName { param($Credential) return '' }
# The capture harness only executes the pure local query worker, synchronously, on its fictitious rows.
# All other worker calls are inert. The application scheduler is exercised by the separate UI test.
function Start-UiTask {
    param([string]$Name,[string]$OperationId,[string]$Code,$Payload,$CallbackState,[string]$ReplaceKey,[string]$SuccessHandler,[string]$ErrorHandler,[int]$TimeoutSeconds,[string]$TaskClass)
    if ($OperationId -ne 'LocalQuery') { return 'guide-disabled' }
    $result = & ([scriptblock]::Create($Code))
    $script:GuideQueryCompletion = [pscustomobject]@{Result=$result;State=$CallbackState}
    return 'guide-local-query'
}
# Layout-only timer contract; no timer callbacks execute in documentary captures.
function New-DomeniaTimer {
    param(
        [Parameter(Mandatory=$true)][string]$Owner,
        [Parameter(Mandatory=$true)][int]$IntervalMs,
        [scriptblock]$Tick=$null,
        [switch]$Standalone,
        [ValidateSet('Background','Normal','Input','Loaded','Render','ContextIdle','ApplicationIdle')][string]$Priority='Background',
        [int]$IdleIntervalMs=0,
        [scriptblock]$Busy=$null,
        [switch]$SessionBound,
        [switch]$RunWhenHidden,
        [switch]$Transient,
        [int]$MaxFailures=3,
        [switch]$Start,
        $Tag=$null
    )
    $timer = [pscustomobject]@{ Owner=$Owner; IntervalMs=[Math]::Max(1,$IntervalMs); Tag=$Tag; Enabled=$false; Tick=$Tick }
    Add-Member -InputObject $timer -MemberType ScriptMethod -Name Start -Value { $this.Enabled=$true }
    Add-Member -InputObject $timer -MemberType ScriptMethod -Name Stop -Value { $this.Enabled=$false }
    Add-Member -InputObject $timer -MemberType ScriptProperty -Name IsEnabled -Value { [bool]$this.Enabled }
    Add-Member -InputObject $timer -MemberType ScriptProperty -Name Interval -Value { [TimeSpan]::FromMilliseconds([double]$this.IntervalMs) }
    return $timer
}

function Request-DomeniaQueryEvaluation { }
function Save-DomeniaFleetSnapshot { param($Scope,$Board) return $false }
function Complete-GuideQuery {
    param([switch]$FinishOnly)
    if (-not $FinishOnly) { Start-DomeniaQueryEvaluation }
    $pending = $script:GuideQueryCompletion
    if ($null -eq $pending) { throw ('Le calcul local de la capture ne s est pas termine : '+[string](Get-DomeniaControl 'LblQueryStatus').Text) }
    $script:GuideQueryCompletion = $null
    Complete-DomeniaQueryEvaluation -Result $pending.Result -State $pending.State
    if ($null -eq $script:DomeniaQueryState.Result) { throw 'Le resultat de capture a ete refuse.' }
}
function Move-GuideScrollTo {
    param($Element)
    Update-GuideLayout
    $scroll = $Element
    while ($null -ne $scroll -and $scroll -isnot [Windows.Controls.ScrollViewer]) { $scroll = [Windows.Media.VisualTreeHelper]::GetParent($scroll) }
    if ($null -ne $scroll) { $top = $Element.TranslatePoint([Windows.Point]::new(0,0),$scroll).Y; $scroll.ScrollToVerticalOffset($scroll.VerticalOffset + $top - 8) }
    Update-GuideLayout
}
function Start-DomeniaOnlinePark { }
function Request-UiTaskStop {param($Id,[switch]$Silent,[switch]$Force,[switch]$Superseded,$Reason)}
function Get-DeProp { param($Entry,[string]$Name,$Default = $null) if ($Entry -is [hashtable] -and $Entry.ContainsKey($Name)) { return $Entry[$Name] }; return $Default }
function Get-DomeniaEntryFirstString { param($Entry,[string]$Name) $v = Get-DeProp $Entry $Name ''; return [string]$v }
function Get-DomeniaStoredTheme { return 'Light' }

function Invoke-GuideMeasure {
    # The window content lives in an off-screen host of the target size (the desktop of the test VM is 1024 x 768).
    $h = [double]$script:GuideHost.Height
    $script:GuideHost.Measure([Windows.Size]::new($script:GuideWidth,$h)); $script:GuideHost.Arrange([Windows.Rect]::new(0,0,$script:GuideWidth,$h)); $script:GuideHost.UpdateLayout()
    $script:Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
}
function Update-GuideLayout {
    Invoke-GuideMeasure
    # RootScroll has just been arranged to the documentary viewport. The production layout now uses
    # that viewport and its zoom; preserve the real Window identity so transient compact state can restore.
    Update-DomeniaUxLayout
    Sync-DomeniaUxNavigation
    (Get-DomeniaControl 'LblUxDomain').Text = 'Connecté à example.local'
    Invoke-GuideMeasure
    Invoke-GuideMeasure
}
function Disable-GuideToolTips {
    param($Root)
    foreach($control in @(@($Root)+@(Get-DomeniaLogicalControls $Root))){
        if($control -is [Windows.DependencyObject]){
            $tip=[Windows.Controls.ToolTipService]::GetToolTip($control)
            if($tip -is [Windows.Controls.ToolTip]){$tip.IsOpen=$false}
            [Windows.Controls.ToolTipService]::SetIsEnabled($control,$false)
        }
    }
}
function Save-GuideBitmap {
    param($Visual,[int]$W,[int]$H,[string]$Name)
    Disable-GuideToolTips $Visual
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new($W,$H,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($Visual)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new(); $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $path = Join-Path $Out ($Name + '.png'); $stream = [IO.File]::Create($path); try { $encoder.Save($stream) } finally { $stream.Dispose() }
    $script:GuideImages.Add([pscustomobject]@{File=($Name+'.png');Width=$W;Height=$H;SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash})
    'capture ' + $Name + ' ' + $W + 'x' + $H
}
function Set-GuideHeight {
    param([int]$Value)
    $script:CaptureHeight = $Value; $script:GuideHost.Height = $Value
}
# WPF can arrange a control beyond the visible area of a clipping ancestor.
# Count rendered rows against every visual clip, not just DataGrid.ActualHeight.
function Get-GuideVisibleBounds {
    param([Windows.FrameworkElement]$Element)
    $visible=$Element.TransformToAncestor($script:GuideHost).TransformBounds([Windows.Rect]::new(0,0,$Element.ActualWidth,$Element.ActualHeight))
    $parent=$Element
    while($null -ne $parent){
        $transform=$parent.TransformToAncestor($script:GuideHost)
        $clip=[Windows.Media.VisualTreeHelper]::GetClip($parent)
        if($null -ne $clip){$visible.Intersect($transform.TransformBounds($clip.Bounds))}
        if($parent -is [Windows.FrameworkElement] -and $parent.ClipToBounds){$visible.Intersect($transform.TransformBounds([Windows.Rect]::new(0,0,$parent.ActualWidth,$parent.ActualHeight)))}
        if($parent -eq $script:GuideHost){break}
        $parent=[Windows.Media.VisualTreeHelper]::GetParent($parent)
    }
    $visible.Intersect([Windows.Rect]::new(0,0,$script:GuideHost.ActualWidth,$script:GuideHost.ActualHeight))
    return $visible
}
function Get-GuideGridViewport {
    param([Windows.Controls.DataGrid]$Grid)
    $bounds=Get-GuideVisibleBounds $Grid
    $rows=@(for($i=0;$i -lt $Grid.Items.Count;$i++){
        $row=$Grid.ItemContainerGenerator.ContainerFromIndex($i)
        if($null -ne $row -and $row.ActualHeight -gt 0){
            $visible=Get-GuideVisibleBounds $row
            [pscustomobject]@{Index=$i;Height=$row.ActualHeight;VisibleHeight=$(if($visible.IsEmpty){0}else{$visible.Height});FullyVisible=(-not $visible.IsEmpty -and $visible.Height -ge ($row.ActualHeight-0.5))}
        }
    })
    [pscustomobject]@{Width=[int]$script:GuideHost.ActualWidth;Height=[int]$script:GuideHost.ActualHeight;GridHeight=$Grid.ActualHeight;VisibleGridHeight=$(if($bounds.IsEmpty){0}else{$bounds.Height});GridTop=$(if($bounds.IsEmpty){-1}else{$bounds.Top});GridBottom=$(if($bounds.IsEmpty){-1}else{$bounds.Bottom});BoundRows=$Grid.Items.Count;FullyVisibleRows=@($rows|Where-Object{$_.FullyVisible}).Count;PartlyVisibleRows=@($rows|Where-Object{$_.VisibleHeight -gt 0 -and -not $_.FullyVisible}).Count;MaterializedRows=$rows}
}
function Assert-GuideControlVisible {
    param([string]$Name,[string]$Context)
    $control=Get-DomeniaControl $Name
    $visible=Get-GuideVisibleBounds $control
    Assert-Guide ($null -ne $control -and $control.ActualWidth -gt 0 -and $control.ActualHeight -gt 0 -and -not $visible.IsEmpty -and $visible.Width -ge $control.ActualWidth-0.5 -and $visible.Height -ge $control.ActualHeight-0.5) ($Context+' : '+$Name+' entièrement visible')
}
function Save-GuideWindow {
    param([string]$Name,[int]$Tall = 0)
    if ($Tall -gt 0) { Set-GuideHeight $Tall }
    Update-GuideLayout
    $logRow = Get-DomeniaControl 'UxLogRow'; $reduced = $false
    if ($null -ne $logRow -and $logRow.Height.Value -gt 60) { Switch-DomeniaUxLog; $reduced = $true }
    Update-GuideLayout
    $rectangles=@(foreach($id in @('CmbQueryField','BtnQueryAddCondition','CmbFleetQuery','BtnQueryWidget','CmbCollectionConcurrency','ExpQueryObject','DgFleetMachines','DgQueryCatalog','PnlQueryCatalogDetail','DgQueryLibrary','LblQueryLibraryDescription','DgIndex','LblIndexOverview','ExpStorageMaintenance','UxSearchQueryBar','TxtSearchQueryFilter','CmbWorkView','CmbSearchQueryResult','DgObjects','LblSearchQueryDetails','LblSearchQuery','LblOperationsHealth','TvDirectory','UxSearchOuRefresh','LblSearchOuRefreshScope','LblSearchOuRefreshStatus','BtnSearchRefreshBase','BtnSearchRefreshPostes','BtnSearchRefreshBoth','BtnSearchRefreshStop','LblFleetScope','LblFleetDashboard','LblFleetOuRefreshStatus','BtnFleetIndexScope','BtnFleetRefreshPostes','BtnFleetRefreshBoth','BtnFleetRefreshStop','BtnFleetDashboardRefresh','LblIndexFreshness')){
        $control=Get-DomeniaControl $id
        if($null -ne $control -and $control.ActualWidth -gt 0){try{$point=$control.TranslatePoint([Windows.Point]::new(0,0),$script:GuideHost);[pscustomobject]@{Name=$id;X=$point.X;Y=$point.Y;Width=$control.ActualWidth;Height=$control.ActualHeight;Visible=$control.IsVisible}}catch{}}
    })
    if($Name -eq 'accueil-sonde-requete' -and $null -ne $queryHolder){$point=$queryHolder.TranslatePoint([Windows.Point]::new(0,0),$script:GuideHost);$rectangles+=@([pscustomobject]@{Name='queryHolder';X=$point.X;Y=$point.Y;Width=$queryHolder.ActualWidth;Height=$queryHolder.ActualHeight;Visible=$queryHolder.IsVisible})}
    $script:GuideLayouts.Add([pscustomobject]@{File=($Name+'.png');Width=$script:GuideWidth;Height=[int]$script:GuideHost.Height;Controls=$rectangles})
    Save-GuideBitmap $script:GuideHost $script:GuideWidth ([int]$script:GuideHost.Height) $Name
    if ($reduced) { Switch-DomeniaUxLog }
    if ($Tall -gt 0) { Set-GuideHeight $script:GuideHeight; Update-GuideLayout }
}
# Documentary helpers for capture-guides.ps1. Dot-source after its functions.
# Invoke Save-GuideOuPicker on Accueil; invoke Save-GuideBaseDetails on TabIndex.
# All directory values are explicit fixtures; no AD worker is executed.
function Save-GuideOuPicker {
    $script:GuideOuOriginalStart = ${function:Start-UiTask}
    $script:GuideOuShot = @{ Ticks=0; Phase=0; Done=$false; Failure=''; Lookup=$null }
    function script:Start-UiTask {
        param([string]$Name,[string]$OperationId,[string]$Code,$Payload,$CallbackState,[string]$ReplaceKey,[string]$SuccessHandler,[string]$ErrorHandler,[int]$TimeoutSeconds,[string]$TaskClass)
        if ($OperationId -eq 'EmbeddedDirectoryLookup') {
            $script:GuideOuShot.Lookup = [pscustomobject]@{ State=$CallbackState; Payload=$Payload }
            return 'guide-ou-lookup'
        }
        return (& $script:GuideOuOriginalStart @PSBoundParameters)
    }
    $script:GuideOuTimer = [Windows.Threading.DispatcherTimer]::new()
    $script:GuideOuTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:GuideOuTimer.Add_Tick({
        $shot=$script:GuideOuShot; $shot.Ticks++
        $surface=$script:DomeniaSurfaceState
        try {
            if ($shot.Ticks -gt 40) { throw 'Le sélecteur OU n a pas atteint son état de capture.' }
            if ($null -eq $surface -or $shot.Done -or $shot.Ticks -lt 3) { return }
            $controls=@(Get-DomeniaLogicalControls $script:Window.FindName('DomeniaDialogLayer'))
            $term=@($controls|Where-Object{$_.Name -eq 'EmbeddedObjectTerm'})[0]
            if ($null -eq $term) { return }
            if ($shot.Phase -eq 0) {
                $term.Text='Postes'
                $search=@($controls|Where-Object{$_.Name -eq 'EmbeddedObjectSearch'})[0]
                $search.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                $lookup=$shot.Lookup
                if ($null -eq $lookup) { throw 'Le bouton Rechercher n a pas déclenché la lecture OU.' }
                $rows=@(
                    [pscustomobject]@{Type='OU';Name='Postes';Second='';Description='Postes administrés du site de Lyon';DN='OU=Postes,OU=Lyon,DC=example,DC=local';Guid='00000000-0000-4000-8000-000000000201'},
                    [pscustomobject]@{Type='OU';Name='Postes';Second='';Description='Postes administrés du site de Paris';DN='OU=Postes,OU=Paris,DC=example,DC=local';Guid='00000000-0000-4000-8000-000000000202'},
                    [pscustomobject]@{Type='OU';Name='Postes';Second='';Description='Postes de démonstration du laboratoire';DN='OU=Postes,OU=Laboratoire,DC=example,DC=local';Guid='00000000-0000-4000-8000-000000000203'}
                )
                Complete-DomeniaEmbeddedLookup -Result ([pscustomobject]@{Rows=$rows;RequestId=$lookup.State.RequestId;Verified=$false;Capped=$false}) -State $lookup.State
                $grid=@($controls|Where-Object{$_.Name -eq 'EmbeddedObjectResults'})[0]
                $node=@(Get-DomeniaLogicalControls $grid|Where-Object{$_ -is [Windows.Controls.TreeViewItem] -and $null -ne $_.Tag.Row -and $_.Tag.DN -eq 'OU=Postes,OU=Lyon,DC=example,DC=local'})[0];$node.IsSelected=$true
                $shot.Phase=1; return
            }
            if ($shot.Phase -eq 1) {
                $grid=@($controls|Where-Object{$_.Name -eq 'EmbeddedObjectResults'})[0]
                $accept=@($controls|Where-Object{$_.Name -eq 'EmbeddedObjectAccept'})[0]
                Assert-Guide (@(Get-DomeniaLogicalControls $grid|Where-Object{$_ -is [Windows.Controls.TreeViewItem] -and $null -ne $_.Tag.Row -and $_.Tag.Row.Type -eq 'OU'}).Count -eq 3 -and $accept.IsEnabled) 'Sélecteur OU : trois résultats fictifs et choix disponible'
                Save-GuideWindow 'selecteur-ou'
                $shot.Done=$true; $script:GuideOuTimer.Stop(); $surface.Window.Close()
            }
        } catch {
            $shot.Failure=$_.Exception.Message; $script:GuideOuTimer.Stop()
            if($null -ne $shot.Lookup){$shot.Lookup.State.Owner.Job=''}
            if($null -ne $surface){$surface.Window.Close()}
        }
    })
    try {
        $script:GuideOuTimer.Start()
        [void](Show-DomeniaInlinePicker -Kind OU -Title 'Choisir le périmètre du tableau de bord' -Prompt 'Recherchez une unité organisationnelle, sélectionnez-la, puis choisissez le périmètre.' -InitialTerm 'Postes')
        if ($script:GuideOuShot.Failure) { throw $script:GuideOuShot.Failure }
        Assert-Guide $script:GuideOuShot.Done 'Sélecteur OU : capture réelle et fermeture sans modification du périmètre'
    } finally {
        $script:GuideOuTimer.Stop()
        Set-Item -Path Function:script:Start-UiTask -Value $script:GuideOuOriginalStart
    }
}
function Save-GuideBaseDetails {
    (Get-DomeniaControl 'TabIndexUpdate').IsSelected=$true;Update-GuideLayout
    $expander=@(Get-DomeniaLogicalControls $script:GuideHost | Where-Object {$_ -is [Windows.Controls.Expander] -and [string]$_.Header -eq 'Détails du stockage et de la synchronisation'})[0]
    if($null -eq $expander){throw 'Expander des détails de la base introuvable.'}
    $wasExpanded=$expander.IsExpanded
    try {
        $expander.IsExpanded=$true
        Set-GuideHeight 1080;Update-GuideLayout;Move-GuideScrollTo $expander
        Save-GuideWindow 'base-details' 1080
        Assert-Guide ($expander.IsExpanded -and (Get-DomeniaControl 'LblIndexStats').ActualHeight -gt 0) 'Base : détails du stockage dépliés et lisibles'
    } finally {$expander.IsExpanded=$wasExpanded; Update-GuideLayout}
}

function Save-GuideElement {
    # One part of the window, on the page background, with a small margin.
    param($Element,[string]$Name,[int]$Pad = 10)
    Update-GuideLayout
    $w = [int][Math]::Ceiling($Element.ActualWidth) + 2 * $Pad; $h = [int][Math]::Ceiling($Element.ActualHeight) + 2 * $Pad
    $drawing = [Windows.Media.DrawingVisual]::new(); $context = $drawing.RenderOpen()
    $context.DrawRectangle($script:Window.Resources['WindowBg'],$null,[Windows.Rect]::new(0,0,$w,$h))
    $brush = [Windows.Media.VisualBrush]::new($Element); $brush.Stretch = [Windows.Media.Stretch]::None
    $context.DrawRectangle($brush,$null,[Windows.Rect]::new($Pad,$Pad,$Element.ActualWidth,$Element.ActualHeight))
    $context.Close()
    Save-GuideBitmap $drawing $w $h $Name
}
function Show-GuideTab {
    param([string]$Route,[string]$Tab = '')
    Invoke-DomeniaUxRoute -Route $Route; if ($Tab) { (Get-DomeniaControl $Tab).IsSelected = $true }
    # Header of a loaded card, as after a real reading of the object.
    if ($null -ne $script:SelectedObject) { foreach ($label in @('LblComputerReadStatus','LblObjectReadStatus')) { $c = Get-DomeniaControl $label; if ($null -ne $c) { $c.Text = [string]$script:SelectedObject.Type + ' : ' + [string]$script:SelectedObject.Name + ' | Fiche AD chargee.' } } }
    Update-DomeniaOuRefreshUi
    Update-GuideLayout
}
function Set-GuideText { param([hashtable]$Values) foreach ($k in $Values.Keys) { $c = Get-DomeniaControl $k; if ($null -ne $c) { $c.Text = [string]$Values[$k] } } }
function Save-GuideSearchQuery {
    param([ValidateSet('Match','Unknown')][string]$Selection='Match')
    # Use the real local worker on the same synthetic snapshot, without reading SQLite or contacting AD.
    Initialize-DomeniaSearchQuerySelector
    (Get-DomeniaControl 'TxtGlobalSearch').Text=''
    (Get-DomeniaControl 'TxtSearchQueryFilter').Text='disque'
    $recipe=$script:DomeniaQueryState.Saved[0]
    $entry=@($script:SearchQueryCatalog|Where-Object{$_.Id -ceq ('local:'+$recipe.Id)})[0]
    Assert-Guide ($null -ne $entry) 'Recherche : la requête enregistrée figure dans le catalogue partagé'
    (Get-DomeniaControl 'CmbWorkView').SelectedItem=$entry
    if(-not $entry.Favorite){Switch-DomeniaSearchQueryFavorite}
    (Get-DomeniaControl 'ChkSearchQueryFavorites').IsChecked=$true
    (Get-DomeniaControl 'CmbWorkView').SelectedIndex=0
    $resultChoice=Get-DomeniaControl 'CmbSearchQueryResult'
    $resultChoice.Visibility='Visible';$resultChoice.SelectedIndex=$(if($Selection -eq 'Unknown'){1}else{0})
    $Payload=[pscustomobject]@{ModuleRoot=(Join-Path $wad 'modules');Lifecycle=(Get-DomeniaWindowsLifecycleTable);Fleet=$script:FleetLast;Observations=@{};Records=$script:DomeniaQueryState.Records;Recipe=$recipe;Saved=@();SortField='name';Descending=$false;Offset=0;Selection=$Selection;MaxAgeDays=(Get-DomeniaObservationMaxAgeDays);TextFilter='';StateFilter='';SearchOutput=$true;Limit=200}
    $data=& ([scriptblock]::Create((Get-DomeniaQueryWorkerCode)))
    Assert-Guide (@($data.Rows).Count -gt 0) ('Recherche : résultats locaux '+$Selection+' calculés sur les données fictives')
    [void](Set-DomeniaItemsSource 'DgObjects' @($data.Rows))
    (Get-DomeniaControl 'LblBranchCount').Text=('{0} affichés · {1} correspondants, {2} inconnus, {3} non correspondants' -f @($data.Rows).Count,$data.Matched,$data.Unknown,$data.NotMatched)
    (Get-DomeniaControl 'LblSearchQuery').Text=($recipe.Name+' · calcul local du '+$data.AtUtc.ToLocalTime().ToString('dd/MM/yyyy HH:mm')+'. '+(Get-DomeniaSearchQueryCoverageText $script:SelectedBranchDn))
    (Get-DomeniaControl 'LblSearchHint').Text='Résultats locaux : aucune lecture AD, aucun ping ni relevé lancé. Les informations manquantes restent inconnues.'
    Update-DomeniaSearchQueryDetails
    Show-GuideTab 'WsSearch'
    Save-GuideWindow $(if($Selection -eq 'Unknown'){'recherche-inconnus'}else{'recherche-requetes'}) 1080
}

# ------------------------------------------------------------------ fictitious directory
$now = Get-Date
$script:GuideScopeDn='OU=Postes,OU=Lyon,DC=example,DC=local'
$script:IndexScopeDn=$script:GuideScopeDn
$script:IndexInfo = [pscustomobject]@{Date=$now.AddMinutes(-35).ToUniversalTime().ToString('o');Server='dc01.example.local';Usn=184522}
$script:IndexSyncStates=@{ou=[pscustomobject]@{scope=('ou:'+$script:GuideScopeDn);base_dn=$script:GuideScopeDn;last_sync=$script:IndexInfo.Date;details='complete;depth=Subtree'}}
$osList = @('Windows 11 Entreprise / 10.0 (26100)','Windows 11 Entreprise / 10.0 (26100)','Windows 11 Entreprise / 10.0 (26200)','Windows 10 Entreprise / 10.0 (19045)')
$services = @('Compta','RH','Accueil','Direction')
$machines = New-Object Collections.ArrayList; $presence = New-Object Collections.ArrayList; $groups = New-Object Collections.ArrayList
for ($i = 1; $i -le 226; $i++) {
    $service = $services[$i % 4]; $name = 'PC-' + $service.ToUpperInvariant() + '-' + ('{0:000}' -f (10 + $i))
    $dn = 'CN=' + $name + ',OU=' + $service + ',OU=Postes,OU=Lyon,DC=example,DC=local'
    $guid = '00000000-0000-4000-8000-' + ('{0:000000000000}' -f $i)
    $days = @(1,2,3,5,8,12,20,35,2,1,4,6,95,3,1,2,9,15,1,3,40,2,1,7,200,3)[($i - 1) % 26]
    $os = if ($i % 13 -eq 0) { $osList[3] } else { $osList[$i % 3] }
    $state = if ($i -in @(11,22,33)) { 'D' } else { 'A' }
    $bucket = if ($days -lt 7) {0} elseif ($days -lt 30) {1} elseif ($days -lt 90) {2} elseif ($days -lt 180) {3} else {4}
    $version = if ($os -like '*19045*') {'10.0 (19045)'} elseif ($os -like '*26200*') {'10.0 (26200)'} else {'10.0 (26100)'}
    [void]$groups.Add([pscustomobject]@{gid=('group-'+$i);st=$state;n=1;os=($os -split ' / ')[0];ver=$version;lb=$bucket;cr='O';pw=$(if($i % 23 -eq 0){'O'}else{'R'});lk=$(if($i % 17 -eq 0){'N'}else{'O'});bk='U'})
    [void]$machines.Add([pscustomobject]@{name=$name;object_guid=$guid;distinguished_name=$dn;gid=('group-'+$i);st=$state;logon=$now.AddDays(-$days).ToString('yyyy-MM-dd');extra=$os})
    if ($i -le 200 -and $state -eq 'A') {
        $online = ($i % 6 -ne 0); $checked = $now.AddMinutes(-10-($i % 11)).ToUniversalTime().ToString('o')
        $inventoryChecked=$now.AddDays(-2).AddHours(-($i % 25)).ToUniversalTime().ToString('o')
        $inventory = if ($online) { [pscustomobject]@{CheckedUtc=$inventoryChecked;OsCaption=$(if($os -like 'Windows 10*'){'Microsoft Windows 10 Entreprise'}else{'Microsoft Windows 11 Entreprise'});Build=$(if($os -like '*19045*'){'19045'}elseif($os -like '*26200*'){'26200'}else{'26100'});LastBootUtc=$now.AddDays($(if($i % 19 -eq 0){40}else{2})).ToUniversalTime().ToString('o');Manufacturer='Constructeur';Model=@('Latitude 5440','OptiPlex 7010','EliteBook 840 G10')[$i % 3];RamBytes=[double](@(8,16,16,32)[$i % 4])*1GB;DiskSize=476.0*1GB;DiskFree=$(if($i % 21 -eq 0){31.0}else{180.0})*1GB} } else {$null}
        if ($null -ne $inventory) { $inventory.LastBootUtc=$now.AddDays(-$(if($i % 19 -eq 0){40}else{2})).ToUniversalTime().ToString('o') }
        $observation = [pscustomobject]@{Key=$dn.ToLowerInvariant();Guid=$guid;CheckedUtc=$checked;PresenceCheckedUtc=$checked;ObservedUtc=$checked;Presence=$(if($online){'En ligne'}else{'Sans reponse au ping'});LinkUser=$(if($online -and $i % 3 -ne 0){'EXAMPLE\user'+$i}else{''});Inventory=$inventory}
        [void]$presence.Add([pscustomobject]@{object_key=$dn.ToLowerInvariant();object_guid=$guid;name=$name;distinguished_name=$dn;gid=('group-'+$i);in_scope=$true;checked_utc=$checked;observation=$observation})
    }
}
$fleet = [pscustomobject]@{Busy=$false;DomainDn=$script:Conn.BaseDn;SnapshotAtUtc=$now.ToUniversalTime().ToString('o');SyncStates=$script:IndexSyncStates;Links=34;LinkSources=@();Types=@([pscustomobject]@{t='Machine';s='Actif';n=223},[pscustomobject]@{t='Machine';s='Desactive';n=3},[pscustomobject]@{t='Utilisateur';s='Actif';n=212});Machines=@($machines);Groups=@($groups);Presence=@($presence);Coverage=[pscustomobject]@{FactsFresh=226;FactsStale=0;BitLockerRead=0;BitLockerAt=''}}

$inventoryRows = @(
    @('Systeme d exploitation','Nom','Microsoft Windows 11 Entreprise'),@('Systeme d exploitation','Build','26100'),@('Systeme d exploitation','Version','10.0.26100'),
    @('Systeme d exploitation','Duree de fonctionnement','34 j 5 h 14 min'),@('Systeme d exploitation','Dernier demarrage',$now.AddDays(-34).AddHours(-5).AddMinutes(-14).ToString('dd/MM/yyyy HH:mm:ss')),
    @('Systeme','Modele','Latitude 5440'),@('Systeme','Fabricant','Constructeur'),@('Systeme','Numero de serie chassis','5CD3104XKZ'),@('Systeme','Utilisateur connecte','EXAMPLE\cmartin'),
    @('Systeme','Domaine','example.local'),@('Systeme','Role dans le domaine','1'),@('Memoire','Total installe','16 Go'),@('Memoire','Barrette 1','8 Go a 5600 MHz, emplacement DIMM A'),@('Memoire','Barrette 2','8 Go a 5600 MHz, emplacement DIMM B'),
    @('Processeur','Processeur 1 modele','Intel(R) Core(TM) i5-1345U'),@('Processeur','Processeur 1 coeurs','10'),@('Processeur','Processeur 1 processeurs logiques','12'),
    @('Reseau','Carte 1 adresses IP','192.0.2.41, fe80::1c2:3aff:fe4b:91'),@('Reseau','Carte 1 passerelle','192.0.2.1'),
    @('Antivirus','Microsoft Defender Antivirus','Actif, signatures a jour'),@('Pare-feu','Profil domaine','Active'),@('Pare-feu','Profil prive','Active'),@('Pare-feu','Profil public','Active'),
    @('BitLocker','Volume C:','Protection Active'),@('BitLocker','Volume C: methode','XTS-AES 128'),@('Windows Update','Serveur WSUS','https://wsus.example.local:8531'),
    @('Redemarrage en attente','Etat','Aucun redemarrage en attente'),@('Services en defaut','Etat','Aucun service automatique arrete'),@('Peripheriques en erreur','Etat','Aucun peripherique en erreur'),
    @('Pilotes non signes','Etat','Tous les pilotes remontes sont signes'),@('Administrateurs locaux','Membre','EXAMPLE\Admins postes'),@('Administrateurs locaux','Membre','PC-COMPTA-014\Administrateur'),
    @('Demarrage automatique','OneDrive','C:\Program Files\Microsoft OneDrive\OneDrive.exe /background'),@('Imprimantes','Imprimante Compta 2e','Pilote universel, port IP'),
    @('Affichage','Intel Iris Xe Graphics','pilote 31.0.101.4502, resolution 1920 x 1080'),@('Disques physiques','SSD NVMe 512 Go','476,9 Go, interface NVMe')
)
$inventory = [pscustomobject]@{ Rows = @($inventoryRows | ForEach-Object { [pscustomobject]@{ Category = $_[0]; Item = $_[1]; Value = $_[2]; Source = 'CIM' } }); Metrics = [pscustomobject]@{
    MemoryTotal = [double]16GB; MemoryFree = [double]6.4GB; LastBoot = ''; CpuLoad = 18.0; Battery = 86.0; ClockSkewSeconds = 1
    Disks = @([pscustomobject]@{ Name = 'C:'; Size = [double]476GB; Free = [double]61GB }); Hotfixes = @('2026-09-24','2026-09-10','2026-08-13')
    Processes = @(@('Teams',612),@('msedge',488),@('Outlook',356),@('MsMpEng',241),@('explorer',138),@('OneDrive',96)) | ForEach-Object { [pscustomobject]@{ Name = $_[0]; Mb = [double]$_[1] } }
    Services = @{ 'En cours' = 118; 'Arretes (automatiques)' = 0; 'Arretes (manuels)' = 96; 'Desactives' = 14 } } }
$entry = @{ pwdLastSet = [string]($now.AddDays(-12).ToFileTimeUtc()); lastLogonTimestamp = [string]($now.AddDays(-1).ToFileTimeUtc()); userAccountControl = '4096'; whenCreated = '2024-03-18 09:12:00'; 'msLAPS-PasswordExpirationTime' = [string]($now.AddDays(18).ToFileTimeUtc()); managedBy = 'CN=Service informatique,OU=Groupes,DC=example,DC=local' }
$computer = [pscustomobject]@{ Type = 'Machine'; Name = 'PC-COMPTA-014'; DN = 'CN=PC-COMPTA-014,OU=Compta,OU=Postes,OU=Lyon,DC=example,DC=local'; Entry = $entry; Safety = [pscustomobject]@{ Guid = '00000000-0000-4000-8000-000000000004' } }

# ------------------------------------------------------------------ window
$xamlText = Get-MainXaml
$reader = [Xml.XmlNodeReader]::new([xml]$xamlText); try { $script:Window = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
foreach ($name in @(Get-DomeniaXamlControlNames -XamlText $xamlText)) { $c = $script:Window.FindName($name); if ($null -ne $c) { $script:Ctrl[$name] = $c } }
[Windows.Controls.ToolTipService]::SetIsEnabled($script:Window,$false)
$script:Window.ShowInTaskbar = $false; $script:Window.WindowStartupLocation = 'Manual'; $script:Window.Left = 0; $script:Window.Top = 0
# A borderless, fixed-size window is not clamped to the 1024 x 768 desktop of the test VM (client area unchanged).
$script:Window.WindowStyle = 'None'; $script:Window.ResizeMode = 'NoResize'
[GuideCaptureHook]::Allow($script:Window,$script:GuideWidth + 40,$script:GuideHeight + 40)
$script:Window.Width = $script:GuideWidth; $script:Window.Height = $script:GuideHeight
(Get-DomeniaControl 'ChkReadOnlyMode').IsChecked = $true
$writeMap = Get-WriteControlMap
foreach ($cap in $writeMap.Keys) { foreach ($n in @($writeMap[$cap])) { $c = Get-DomeniaControl $n; if ($null -ne $c) { $c.IsEnabled = $false; $c.ToolTip = 'Desactive : mode lecture seule actif.' } } }
(Get-DomeniaControl 'TxtDashDomain').Text = 'example.local'
(Get-DomeniaControl 'TxtUiLog').Text = '08:12:41.204 [INFO] [Statut] Pret. Connexion validee, mode lecture seule actif.'
Set-VisibleTabsForType -Type ''
Initialize-DomeniaUxShell
Initialize-DomeniaUiZoom
Set-DomeniaUxPalette -Window $script:Window -Theme 'Light'
$script:Window.WindowState = 'Normal'
$script:Window.Show()
$content = $script:Window.Content; $script:Window.Content = $null
$script:GuideHost = [Windows.Controls.Grid]::new(); $script:GuideHost.Width = $script:GuideWidth; $script:GuideHost.Height = $script:GuideHeight
$script:GuideHost.Resources = $script:Window.Resources
$script:GuideHost.SetResourceReference([Windows.Controls.Panel]::BackgroundProperty,'WindowBg')
$script:GuideHost.SetValue([Windows.Documents.TextElement]::FontFamilyProperty,$script:Window.FontFamily)
$script:GuideHost.SetValue([Windows.Documents.TextElement]::FontSizeProperty,$script:Window.FontSize)
$script:GuideHost.SetResourceReference([Windows.Documents.TextElement]::ForegroundProperty,'TextColor')
$script:GuideHost.UseLayoutRounding = $true
[void]$script:GuideHost.Children.Add($content)
# The window keeps an empty grid: side sheets still find the real layer by name (window name scope).
$script:Window.Content = [Windows.Controls.Grid]::new()
$script:UxHelpVisible = $false; $script:UxNavCollapsed = $false; $script:UxLayoutSignature = ''; $script:UxNavLayoutSignature = ''
Update-GuideLayout
'surface ' + $script:GuideHost.ActualWidth + 'x' + $script:GuideHost.ActualHeight

if($CaptureSet -eq 'All'){
# 1. Accueil: independent OU, real aggregation rules on fictitious directory and observations.
$script:SelectedBranchDn = $script:GuideScopeDn
$script:FleetScopeDn = $script:SelectedBranchDn
$tree = Get-DomeniaControl 'TvDirectory'
$root = [Windows.Controls.TreeViewItem]::new(); $root.Header = 'example.local'; $root.IsExpanded = $true
foreach ($ou in @('Groupes','Lyon','Marseille','Utilisateurs')) {
    $item = [Windows.Controls.TreeViewItem]::new(); $item.Header = $ou
    if ($ou -eq 'Lyon') { $item.IsExpanded = $true; $sub = [Windows.Controls.TreeViewItem]::new(); $sub.Header = 'Postes'; $sub.Tag=[pscustomobject]@{DN=$script:SelectedBranchDn}; $sub.IsSelected=$true; [void]$item.Items.Add($sub) }
    [void]$root.Items.Add($item)
}
[void]$tree.Items.Add($root)
# Both evaluations use the same immutable synthetic data. A newer calculation must not make
# the AD coverage, ping dates or older WMI inventory look newer.
$previousBoard=Get-DomeniaFleetBoardData -Result $fleet -Scope $script:FleetScopeDn -Subtree $true -Now $now.AddMinutes(-2) -Lifecycle (Get-DomeniaWindowsLifecycleTable)
$board=Get-DomeniaFleetBoardData -Result $fleet -Scope $script:FleetScopeDn -Subtree $true -Now $now -Lifecycle (Get-DomeniaWindowsLifecycleTable)
Assert-Guide ($previousBoard.Freshness.Index.At -eq $board.Freshness.Index.At -and $previousBoard.Freshness.Observations.Ping.OldestUtc -eq $board.Freshness.Observations.Ping.OldestUtc -and $previousBoard.Freshness.Observations.Inventory.NewestUtc -eq $board.Freshness.Observations.Inventory.NewestUtc -and $previousBoard.Freshness.ComputedAtUtc -lt $board.Freshness.ComputedAtUtc) 'Recalcul : les dates AD, ping et WMI restent inchangées ; seule la date de vue avance'
Assert-Guide ($board.Freshness.Index.At -gt $board.Freshness.Observations.Inventory.NewestUtc -and $board.Freshness.Observations.Ping.OldestUtc -gt $board.Freshness.Index.At -and $board.Freshness.Observations.Total -eq 223) 'Fraîcheur : AD récente, ping récent et inventaire WMI plus ancien sont distincts sur 223 postes actifs'
$fleet | Add-Member -NotePropertyName Board -NotePropertyValue $board
try { Update-DomeniaSearchScopeUi } catch { }
Complete-DomeniaFleetDashboard -Result $fleet -State $null
Update-DomeniaFleetScopeText (Get-DomeniaFleetScope) -Count 226 -Freshness $board.Freshness
Update-DomeniaOuRefreshUi
Assert-Guide ((Get-DomeniaControl 'LblFleetScope').Text -like '*Base locale (AD) : lecture complète*' -and (Get-DomeniaControl 'LblFleetDashboard').Text -like '*inventaire WMI*Vue recalculée*') 'Accueil : les trois horloges sont présentées par le formateur réel'
Show-GuideTab 'TabDashboard'
Set-GuideHeight 1240; Update-GuideLayout
# The off-screen host cannot trigger IsVisibleChanged: render the computed board explicitly.
Show-DomeniaBoard -Board Fleet -Quiet
Update-GuideLayout
$fleetPanel=Get-DomeniaControl 'PnlFleetDashboard'
Assert-Guide ($null -ne $fleetPanel -and $fleetPanel.Children.Count -gt 0 -and $fleetPanel.ActualHeight -gt 0) 'Accueil : les widgets du parc sont réellement dessinés depuis les données fictives'
$logRow = Get-DomeniaControl 'UxLogRow'; if ($null -ne $logRow -and $logRow.Height.Value -gt 60) { Switch-DomeniaUxLog; Update-GuideLayout }
$fleetCard = (Get-DomeniaControl 'BtnFleetDashboardRefresh').Parent.Parent.Parent
$scroller = $fleetCard; while ($null -ne $scroller -and $scroller -isnot [Windows.Controls.ScrollViewer]) { $scroller = [Windows.Media.VisualTreeHelper]::GetParent($scroller) }
if ($null -ne $scroller) { $top = $fleetCard.TranslatePoint([Windows.Point]::new(0,0),$scroller).Y; $scroller.ScrollToVerticalOffset($scroller.VerticalOffset + $top - 8) }
Save-GuideWindow 'accueil' 1240
# Native 1080p view dedicated to the compact actions and three clocks, ready for a documented crop.
Set-GuideHeight 1080;Update-GuideLayout;Move-GuideScrollTo $fleetCard
foreach($id in @('BtnFleetIndexScope','BtnFleetRefreshPostes','BtnFleetRefreshBoth','BtnFleetRefreshStop','BtnFleetDashboardRefresh')){Assert-GuideControlVisible $id 'Accueil 1080p'}
Assert-Guide ((Get-DomeniaControl 'BtnFleetIndexScope').IsEnabled -and (Get-DomeniaControl 'BtnFleetRefreshPostes').IsEnabled -and (Get-DomeniaControl 'BtnFleetRefreshBoth').IsEnabled -and -not (Get-DomeniaControl 'BtnFleetRefreshStop').IsEnabled) 'Accueil : actions disponibles pour lʼOU choisie, arrêt inactif au repos'
Save-GuideWindow 'actualisation-ou' 1080
Save-GuideOuPicker

# 1b. Query workshop: real local query engine, 226 known accounts, including three disabled accounts.
Initialize-DomeniaQueryWorkshop
Assert-Guide ($null -ne (Get-DomeniaControl 'CmbQueryOperator').SelectedItem) 'Opérateur initial renseigné'
Show-DomeniaQueryWorkshop
Assert-Guide ((Get-DomeniaControl 'WorkspaceTabs').SelectedItem.Name -eq 'TabApplicationTools' -and (Get-DomeniaControl 'ApplicationToolTabs').SelectedItem.Name -eq 'WsQueryWorkshop') 'Atelier ouvert dans Outils'
Set-DomeniaQueryDraft (New-DomeniaQueryRecipe -Id 'template.all')
Complete-GuideQuery
Assert-Guide ($script:DomeniaQueryState.Result.ScopeTotal -eq 226 -and $script:DomeniaQueryState.Result.Matched -eq 226) 'Tous les postes recensés : 226, actifs et désactivés'
Assert-Guide (@($script:DomeniaQueryState.Result.Rows).Count -eq 200 -and (Get-DomeniaControl 'BtnQueryNext').IsEnabled) 'Première page : 200 lignes et page suivante active'
Move-GuideScrollTo (Get-DomeniaControl 'BtnQueryBack')
Save-GuideWindow 'atelier-requetes' 1240
$querySavedWidth=$script:GuideWidth;$querySavedHeight=[int]$script:GuideHost.Height
$queryViewports=@(foreach($size in @(@(1920,1080),@(1280,720))){
    $script:GuideWidth=$size[0];$script:GuideHost.Width=$script:GuideWidth;Set-GuideHeight $size[1];Update-GuideLayout
    $measure=Get-GuideGridViewport (Get-DomeniaControl 'DgFleetMachines')
    [IO.File]::WriteAllText((Join-Path $Out ('atelier-viewport-'+$size[0]+'x'+$size[1]+'.json')),($measure|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
    $minimum=if($size[1] -ge 1080){6}else{2}
    Save-GuideBitmap $script:GuideHost $script:GuideWidth $size[1] ('atelier-viewport-'+$size[0]+'x'+$size[1])
    $script:GuideChecks.Add([pscustomobject]@{Name=('Atelier : au moins '+$minimum+' lignes entièrement visibles à '+$size[0]+'×'+$size[1]);Passed=($measure.FullyVisibleRows -ge $minimum)})
    $measure
})
$script:GuideWidth=$querySavedWidth;$script:GuideHost.Width=$script:GuideWidth;Set-GuideHeight $querySavedHeight;Update-GuideLayout
(Get-DomeniaControl 'TabQueryCatalog').IsSelected=$true
(Get-DomeniaControl 'TxtQueryCatalogSearch').Text='espace libre'
$catalogGrid=Get-DomeniaControl 'DgQueryCatalog';$catalogGrid.SelectedItem=@($catalogGrid.ItemsSource|Where-Object{$_.Id -eq 'diskFreePercent'})[0]
Update-GuideLayout
Assert-Guide ($catalogGrid.Items.Count -gt 0 -and $catalogGrid.SelectedItem.Id -eq 'diskFreePercent') 'Catalogue local : champ disque sélectionné et décrit'
Save-GuideWindow 'atelier-catalogue' 1080
(Get-DomeniaControl 'TxtQueryCatalogSearch').Text='';(Get-DomeniaControl 'TabQueryResults').IsSelected=$true
(Get-DomeniaControl 'TabQueryLibrary').IsSelected=$true
(Get-DomeniaControl 'TxtQueryLibrarySearch').Text='disque'
(Get-DomeniaControl 'CmbQueryLibrarySource').SelectedIndex=1
(Get-DomeniaControl 'DgQueryLibrary').SelectedIndex=0;Update-GuideLayout
Assert-Guide ((Get-DomeniaControl 'DgQueryLibrary').Items.Count -gt 0 -and (Get-DomeniaControl 'BtnQueryLibraryUse').IsEnabled) 'Modèles de requêtes : filtre local et détail du modèle sélectionné'
Save-GuideWindow 'atelier-modeles' 1080
(Get-DomeniaControl 'TxtQueryLibrarySearch').Text='';(Get-DomeniaControl 'CmbQueryLibrarySource').SelectedIndex=0;(Get-DomeniaControl 'TabQueryResults').IsSelected=$true
# 1c. The same route as the attention button: a frozen, GUID-bound list of stale active accounts.
$staleIds = @($groups | Where-Object {$_.st -eq 'A' -and $_.lb -in @(3,4)} | ForEach-Object {$_.gid})
$alertTargets = @($machines | Where-Object {$_.gid -in $staleIds})
Show-DomeniaAttentionInWorkshop -Targets $alertTargets -Label 'Sans connexion depuis 90 jours'
Complete-GuideQuery -FinishOnly
Assert-Guide ($script:DomeniaQueryState.Result.Matched -eq $alertTargets.Count) "Le détail de l’alerte garde tous les GUID sélectionnés"
Assert-Guide ([string](Get-DomeniaControl 'LblQuerySegment').Text -like '*Sélection figée*') 'Le segment sélectionné est explicite'
Move-GuideScrollTo (Get-DomeniaControl 'BtnQueryBack')
Save-GuideWindow 'alerte-selection' 1240
Show-GuideTab 'TabDashboard'

# Additional tutorials use actual workshop actions; only persistence and transports are replaced above.
Show-DomeniaQueryWorkshop
Set-DomeniaQueryDraft (New-DomeniaQueryRecipe -Name 'Disques libres sous 20 %')
$fields=Get-DomeniaControl 'CmbQueryField'; $fields.SelectedItem=@($fields.ItemsSource|Where-Object{$_.Id -eq 'diskFreePercent'})[0]
$operators=Get-DomeniaControl 'CmbQueryOperator'; $operators.SelectedItem=@($operators.ItemsSource|Where-Object{$_.Id -eq 'Less'})[0]
(Get-DomeniaControl 'TxtQueryValue').Text='20'
Invoke-DomeniaQueryAction 'Add'
Assert-Guide ($script:DomeniaQueryState.Recipe.Clauses.Count -eq 1) ('Condition ajoutée : '+[string](Get-DomeniaControl 'LblQueryStatus').Text)
Complete-GuideQuery
[IO.File]::WriteAllText((Join-Path $Out 'condition-diagnostic.json'),([pscustomobject]@{Recipe=$script:DomeniaQueryState.Recipe;Matched=$script:DomeniaQueryState.Result.Matched;Unknown=$script:DomeniaQueryState.Result.Unknown;Sample=$script:DomeniaQueryState.Records[0].Values;WithDisk=@($script:DomeniaQueryState.Records|Where-Object{$_.Values.ContainsKey('diskFreePercent')}).Count;Status=[string](Get-DomeniaControl 'LblQueryStatus').Text}|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
Assert-Guide ($script:DomeniaQueryState.Recipe.Clauses.Count -eq 1 -and $script:DomeniaQueryState.Result.Matched -gt 0) 'Condition numérique : le moteur trouve les disques sous 20 %'
(Get-DomeniaControl 'TabQueryCompose').IsSelected=$true;Update-GuideLayout
Move-GuideScrollTo (Get-DomeniaControl 'BtnQueryBack'); Save-GuideWindow 'atelier-condition' 1240
$collect=(Get-DomeniaControl 'CmbCollectionConcurrency').Parent.Parent
$collect.IsExpanded=$true; Save-GuideWindow 'atelier-collecte' 1240; $collect.IsExpanded=$false
(Get-DomeniaControl 'TabQueryResults').IsSelected=$true;Update-GuideLayout
(Get-DomeniaControl 'DgFleetMachines').SelectedIndex=0
(Get-DomeniaControl 'ExpQueryObject').IsExpanded=$true; Show-DomeniaQueryObjectDetails
Move-GuideScrollTo (Get-DomeniaControl 'ExpQueryObject'); Save-GuideWindow 'atelier-fiche-locale' 1240
(Get-DomeniaControl 'ExpQueryObject').IsExpanded=$false
Invoke-DomeniaQueryAction 'Save'
Assert-Guide ($script:DomeniaQueryState.Saved.Count -eq 1) 'Requête nommée enregistrée dans les préférences fictives'
(Get-DomeniaControl 'CmbFleetQuery').SelectedItem=$script:DomeniaQueryState.Saved[0]
Complete-GuideQuery
(Get-DomeniaControl 'TabQueryLibrary').IsSelected=$true;(Get-DomeniaControl 'CmbQueryLibrarySource').SelectedIndex=2;(Get-DomeniaControl 'DgQueryLibrary').SelectedIndex=0;Update-GuideLayout
Move-GuideScrollTo (Get-DomeniaControl 'BtnQueryBack'); Save-GuideWindow 'atelier-bibliotheque' 1080
(Get-DomeniaControl 'CmbQueryLibrarySource').SelectedIndex=0
Invoke-DomeniaQueryAction 'Widget'; Complete-GuideQuery -FinishOnly
Assert-Guide (@(Get-DomeniaBoardLayout Fleet|Where-Object{$_.Source -eq 'Query'}).Count -eq 1) 'La requête crée un widget de tableau de bord'
Show-GuideTab 'TabDashboard'
$queryItem=@(Get-DomeniaBoardLayout Fleet|Where-Object{$_.Source -eq 'Query'})[0]
$entry=Get-DomeniaQueryBoardEntry ([string]$queryItem.Key)
Assert-Guide ([string]$entry.Value -eq '5') 'La sonde enregistrée affiche vraiment cinq postes correspondants'
# The off-screen host has no PresentationSource: draw the pending, already computed local board explicitly.
Show-DomeniaBoard -Board Fleet -Quiet
$queryHolder=@(Get-DomeniaLogicalControls (Get-DomeniaControl 'PnlFleetDashboard')|Where-Object{$_ -is [Windows.FrameworkElement] -and $_.Tag -is [hashtable] -and $_.Tag.ContainsKey('Id') -and [string]$_.Tag.Id -eq [string]$queryItem.Id})[0]
if($null -ne $queryHolder){Move-GuideScrollTo $queryHolder;$hover=[Windows.Input.MouseEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,0);$hover.RoutedEvent=[Windows.UIElement]::MouseEnterEvent;$queryHolder.RaiseEvent($hover);Update-GuideLayout}
Save-GuideWindow 'accueil-sonde-requete' 1240
# Filter the known fixture rows through the same immutable GUID selection used by Search.
$script:BranchObjects=@(foreach($m in $machines){[pscustomobject]@{Type='Machine';Name=$m.name;DN=$m.distinguished_name;Guid=$m.object_guid;State=$(if($m.st -eq 'D'){'Désactivé'}else{'Actif'});OS=$m.extra;Presence='Non vérifié';Login=($m.name+'$');UPN=($m.name.ToLowerInvariant()+'.example.local');LastLogon='';Changed=''}})
$script:CurrentPresenceFilter='Tous';$script:BranchCountLabel='226 postes fictifs recensés avant application du filtre'
Complete-GuideQuery; Invoke-DomeniaQueryAction 'ApplySearch'
Assert-Guide ((Get-DomeniaControl 'DgObjects').Items.Count -eq $script:DomeniaQueryState.Result.Matched) 'Le filtre appliqué à Recherche garde les mêmes identités'
Show-GuideTab 'WsSearch'; Save-GuideWindow 'recherche-requete'
Invoke-DomeniaQueryAction 'ClearSearch'
Save-GuideSearchQuery -Selection Match
Save-GuideSearchQuery -Selection Unknown
(Get-DomeniaControl 'ChkSearchQueryFavorites').IsChecked=$false
(Get-DomeniaControl 'TxtSearchQueryFilter').Text=''
(Get-DomeniaControl 'CmbWorkView').SelectedIndex=-1
(Get-DomeniaControl 'CmbSearchQueryResult').Visibility='Collapsed'
Reset-DomeniaSearchQueryFilters
$script:ActiveSearchViewId='';$script:SearchQueryRun=$null
Show-GuideTab 'TabDashboard'
Show-DomeniaQueryWorkshop
$allRecipe=@((Get-DomeniaControl 'CmbFleetQuery').Items|Where-Object{$_.Id -eq 'template.all'})[0]
Assert-Guide ($null -ne $allRecipe) 'Comptes désactivés : le modèle Tous les postes recensés est disponible'
(Get-DomeniaControl 'CmbFleetQuery').SelectedItem=$allRecipe
Set-DomeniaQueryDraft $allRecipe
(Get-DomeniaControl 'TabQueryResults').IsSelected=$true;Update-GuideLayout
(Get-DomeniaControl 'CmbFleetMachineState').SelectedIndex=2;Complete-GuideQuery
Assert-Guide ($script:DomeniaQueryState.Result.Matched -eq 3) 'Les trois postes désactivés restent consultables'
Move-GuideScrollTo (Get-DomeniaControl 'BtnQueryBack');Save-GuideWindow 'atelier-desactives' 1240
(Get-DomeniaControl 'CmbFleetMachineState').SelectedIndex=0
Show-GuideTab 'TabDashboard'

# 2. Rechercher: results of a search; the OU fixture tree was prepared before the query captures.
$rows = @(
    [pscustomobject]@{ Type = 'Machine'; Name = 'PC-COMPTA-014'; Login = 'PC-COMPTA-014$'; UPN = 'pc-compta-014.example.local'; Presence = 'En ligne'; PresenceDetail = 'Ping 3 ms'; SessionDisplay = 'cmartin'; SessionState = 'Console lue'; DirectoryState = 'A jour'; Association = 'Camille Martin'; LinkSource = 'Console observee'; LinkConfidence = 'Observe'; State = 'Actif'; OS = 'Windows 11 Entreprise'; LastLogon = '07/10/2026'; DN = $computer.DN; Admin = '' }
    [pscustomobject]@{ Type = 'Machine'; Name = 'PC-COMPTA-015'; Login = 'PC-COMPTA-015$'; UPN = 'pc-compta-015.example.local'; Presence = 'En ligne'; PresenceDetail = 'Ping 4 ms'; SessionDisplay = 'Aucun'; SessionState = 'Console lue'; DirectoryState = 'A jour'; Association = 'Louis Bernard'; LinkSource = 'Console observee'; LinkConfidence = 'Observe'; State = 'Actif'; OS = 'Windows 11 Entreprise'; LastLogon = '08/10/2026'; DN = 'CN=PC-COMPTA-015,OU=Compta,OU=Postes,OU=Lyon,DC=example,DC=local'; Admin = '' }
    [pscustomobject]@{ Type = 'Machine'; Name = 'PC-COMPTA-016'; Login = 'PC-COMPTA-016$'; UPN = 'pc-compta-016.example.local'; Presence = 'Sans reponse'; PresenceDetail = 'Pas de reponse au ping'; SessionDisplay = ''; SessionState = 'Non verifie'; DirectoryState = 'A jour'; Association = 'Sarah Petit'; LinkSource = 'Import'; LinkConfidence = 'Importe'; State = 'Actif'; OS = 'Windows 10 Entreprise'; LastLogon = '22/09/2026'; DN = 'CN=PC-COMPTA-016,OU=Compta,OU=Postes,OU=Lyon,DC=example,DC=local'; Admin = '' }
    [pscustomobject]@{ Type = 'Machine'; Name = 'PC-COMPTA-021'; Login = 'PC-COMPTA-021$'; UPN = 'pc-compta-021.example.local'; Presence = 'En ligne'; PresenceDetail = 'Ping 2 ms'; SessionDisplay = 'jdurand'; SessionState = 'Console lue'; DirectoryState = 'A jour'; Association = 'Julie Durand'; LinkSource = 'Console observee'; LinkConfidence = 'Observe'; State = 'Actif'; OS = 'Windows 11 Entreprise'; LastLogon = '08/10/2026'; DN = 'CN=PC-COMPTA-021,OU=Compta,OU=Postes,OU=Lyon,DC=example,DC=local'; Admin = '' }
    [pscustomobject]@{ Type = 'Utilisateur'; Name = 'Camille Martin'; Login = 'cmartin'; UPN = 'cmartin@example.local'; Presence = ''; PresenceDetail = ''; SessionDisplay = ''; SessionState = ''; DirectoryState = 'A jour'; Association = 'PC-COMPTA-014'; LinkSource = 'Console observee'; LinkConfidence = 'Observe'; State = 'Actif'; OS = ''; LastLogon = '08/10/2026'; DN = 'CN=Camille Martin,OU=Compta,OU=Utilisateurs,DC=example,DC=local'; Admin = '' }
    [pscustomobject]@{ Type = 'Utilisateur'; Name = 'Compta Lyon (partage)'; Login = 'compta.lyon'; UPN = 'compta.lyon@example.local'; Presence = ''; PresenceDetail = ''; SessionDisplay = ''; SessionState = ''; DirectoryState = 'A jour'; Association = ''; LinkSource = ''; LinkConfidence = ''; State = 'Desactive'; OS = ''; LastLogon = '14/03/2026'; DN = 'CN=Compta Lyon,OU=Comptes de service,DC=example,DC=local'; Admin = '' }
    [pscustomobject]@{ Type = 'Groupe'; Name = 'GG-Compta-Lyon'; Login = 'GG-Compta-Lyon'; UPN = ''; Presence = ''; PresenceDetail = ''; SessionDisplay = ''; SessionState = ''; DirectoryState = 'A jour'; Association = ''; LinkSource = ''; LinkConfidence = ''; State = ''; OS = ''; LastLogon = ''; DN = 'CN=GG-Compta-Lyon,OU=Groupes,DC=example,DC=local'; Admin = '' }
)
# This is an ordinary global-name search fixture. Clear the preceding local-query context
# before installing its synthetic rows; use the production scope/hint presentation functions.
Reset-DomeniaSearchQueryFilters
$script:ActiveSearchViewId='';$script:SearchQueryRun=$null
Set-DomeniaSearchMode -Mode Global
(Get-DomeniaControl 'TxtGlobalSearch').Text='compta'
Update-DomeniaSearchScopeUi
Update-DomeniaSearchHint
$script:BranchObjects = $rows;$script:BranchCountLabel='7 résultat(s) · liste complète'
Assert-Guide ((Get-DomeniaControl 'LblSearchQuery').Text -eq 'Aucun filtre de requête supplémentaire.' -and (Get-DomeniaControl 'LblSearchHint').Text -notmatch 'Résultats locaux' -and (Get-DomeniaSearchMode) -eq 'Global') 'Recherche ordinaire : aucun ancien filtre local, périmètre global et aide cohérente'
Assert-Guide (Set-DomeniaItemsSource 'DgObjects' $rows) 'Recherche : les lignes de démonstration sont liées'
Assert-Guide ((Get-DomeniaControl 'DgObjects').Items.Count -eq 7) 'Recherche : 7 résultats réellement présents'
(Get-DomeniaControl 'TxtGlobalSearch').Text = 'compta'
(Get-DomeniaControl 'LblBranchCount').Text = '7 résultat(s) · liste complète'
foreach ($b in @('BtnParkPing','BtnParkResults','BtnParkAnalyze','BtnLiveRecheck','BtnExportResults')) { $c = Get-DomeniaControl $b; if ($null -ne $c) { $c.IsEnabled = $true } }
$grid = Get-DomeniaControl 'DgObjects'
$order = @('Type','Nom','Utilisateur connecté (console)','Association mémorisée','Présence réseau')
for ($k = 0; $k -lt $order.Count; $k++) { $col = @($grid.Columns | Where-Object { [string]$_.Header -eq $order[$k] })[0]; if ($null -ne $col) { $col.DisplayIndex = $k } }
foreach ($pair in @(@('Utilisateur connecté (console)',190),@('Association mémorisée',170),@('Nom',150))) { $col = @($grid.Columns | Where-Object { [string]$_.Header -eq $pair[0] })[0]; if ($null -ne $col) { $col.Width = [Windows.Controls.DataGridLength]::new([double]$pair[1]) } }
Show-GuideTab 'WsSearch'
$grid.SelectedIndex = 0
Save-GuideWindow 'recherche'
Save-GuideWindow 'recherche-actions'
# The name search remains global while data refresh always uses the explicitly selected OU.
# A deep, long OU exercises wrapping without replacing the displayed global-name results.
$longDn='OU=Postes administratifs du site de Lyon,OU=Services administratifs,OU=Lyon,DC=example,DC=local'
$lyon=@($root.Items|Where-Object{[string]$_.Header -eq 'Lyon'})[0]
$longParent=[Windows.Controls.TreeViewItem]::new();$longParent.Header='Services administratifs';$longParent.IsExpanded=$true
$longOu=[Windows.Controls.TreeViewItem]::new();$longOu.Header='Postes administratifs du site de Lyon';$longOu.Tag=[pscustomobject]@{DN=$longDn}
[void]$longParent.Items.Add($longOu);[void]$lyon.Items.Add($longParent);$longOu.IsSelected=$true
$script:SelectedBranchDn=$longDn;Update-DomeniaSearchScopeUi;Update-DomeniaOuRefreshUi;Update-GuideLayout
foreach($id in @('BtnSearchRefreshBase','BtnSearchRefreshPostes','BtnSearchRefreshBoth','BtnSearchRefreshStop')){Assert-GuideControlVisible $id 'Recherche 1080p avec OU longue'}
$treeBounds=Get-GuideVisibleBounds (Get-DomeniaControl 'TvDirectory')
Assert-Guide (-not $treeBounds.IsEmpty -and $treeBounds.Height -ge 80) 'Recherche avec OU longue : au moins 80 pixels de hauteur dʼarbre réellement visibles'
$refreshContext=Get-DomeniaOuRefreshContext Search
Assert-Guide ($refreshContext.Dn -ceq $longDn -and $refreshContext.Subtree -and (Get-DomeniaSearchMode) -eq 'Global' -and $grid.Items.Count -eq 7) 'Recherche : les actions gardent lʼOU explicite et ses sous-OU, indépendamment des sept résultats globaux'
Assert-Guide ((Get-DomeniaControl 'BtnSearchRefreshBase').IsEnabled -and (Get-DomeniaControl 'BtnSearchRefreshPostes').IsEnabled -and (Get-DomeniaControl 'BtnSearchRefreshBoth').IsEnabled) 'Recherche : les trois actions sont disponibles sur lʼOU longue'
Save-GuideWindow 'recherche-actualisation-ou' 1080
$script:SelectedBranchDn=$script:GuideScopeDn;$sub.IsSelected=$true;[void]$lyon.Items.Remove($longParent)
Update-DomeniaSearchScopeUi;Update-DomeniaOuRefreshUi;Update-GuideLayout

# 3. Fiche of a workstation, its actions, dashboard and customise mode.
$script:SelectedObject = $computer
Set-VisibleTabsForType -Type 'Machine'
foreach ($k in @('Object','Computer')) { $h = Get-DomeniaControl ($k + 'ReadContent'); $e = Get-DomeniaControl ($k + 'ReadPlaceholder'); if ($null -ne $h) { $h.Visibility = 'Visible'; $h.IsEnabled = $true }; if ($null -ne $e) { $e.Visibility = 'Collapsed' } }
Set-GuideText @{ TxtObjName = 'PC-COMPTA-014'; TxtObjType = 'Machine'; TxtObjDn = $computer.DN; TxtCompName = 'PC-COMPTA-014'; TxtCompDns = 'pc-compta-014.example.local'; TxtCompOs = 'Windows 11 Entreprise'; TxtCompOsVersion = '10.0 (26100)'
    TxtCompDescription = 'Poste comptabilite, 2e etage'; TxtCompLocation = 'Lyon, batiment B'; TxtCompManagedBy = 'Service informatique'; TxtCompLastLogon = '07/10/2026 08:12'; TxtCompState = 'Actif'; TxtCompUac = 'Compte ordinateur standard'
    TxtCompPresence = 'En ligne (ping 3 ms)'; TxtCompLinkedUser = 'Camille Martin (cmartin)'; TxtCompLinkSource = 'Console observee'; TxtCompLinkConfidence = 'Observe'; TxtCompLinkWhen = '08/10/2026 08:15' }
Set-GuideText @{ LblComputerReadStatus = 'Machine : PC-COMPTA-014 | Fiche AD chargee.'; LblObjectReadStatus = 'Machine : PC-COMPTA-014 | Fiche AD chargee.' }
Show-GuideTab 'WsComputer' 'TabComputer'
Save-GuideWindow 'fiche-poste'
Show-GuideTab 'WsComputer' 'TabComputerAdmin'
Save-GuideWindow 'actions-poste'
Update-DomeniaComputerDashboard -Result $inventory
Show-GuideTab 'WsComputer' 'TabComputerDashboard'
Save-GuideWindow 'tableau-poste' 1840
(Get-DomeniaBoardState 'Computer').Editing = $true; Show-DomeniaBoard -Board Computer -Quiet
Save-GuideWindow 'personnaliser' 1100
(Get-DomeniaBoardState 'Computer').Editing = $false; Show-DomeniaBoard -Board Computer -Quiet

# The same saved query can be previewed and displayed on the selected computer, without collecting.
Show-DomeniaComputerQueryWorkshop -RecipeId ([string]$script:DomeniaQueryState.Saved[0].Id)
(Get-DomeniaControl 'BtnQueryPreviewComputer').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
Assert-Guide ([string](Get-DomeniaControl 'LblQueryComputerPreview').Text -like 'PC-COMPTA-014 : *') 'Aperçu local de la même requête sur le poste sélectionné'
Save-GuideWindow 'atelier-poste' 1240
Invoke-DomeniaQueryAction 'Widget'
Assert-Guide (@(Get-DomeniaBoardLayout Computer|Where-Object{$_.Source -eq 'Query'}).Count -eq 1) 'Widget de requête partagé sur le tableau du poste'
Show-GuideTab 'WsComputer' 'TabComputerDashboard'
Show-DomeniaBoard -Board Computer -Quiet
$computerQueryItem=@(Get-DomeniaBoardLayout Computer|Where-Object{$_.Source -eq 'Query'})[0]
$computerQueryHolder=Find-DomeniaBoardHolder (Get-DomeniaControl 'PnlComputerDashboard') ([string]$computerQueryItem.Id)
if($null -ne $computerQueryHolder){Move-GuideScrollTo $computerQueryHolder}
Save-GuideWindow 'poste-sonde-requete' 1080

# 4. Widget editor (side sheet), captured while it is open.
$script:EditorShot = @{ Done = $false; Ticks = 0 }
$timer = [Windows.Threading.DispatcherTimer]::new(); $timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({
    $script:EditorShot.Ticks++
    $state = $script:DomeniaSurfaceState
    if ($null -eq $state -or $script:EditorShot.Done) { if ($script:EditorShot.Ticks -gt 40) { $timer.Stop() }; return }
    if ($script:EditorShot.Ticks -lt 4) { return }
    if ($script:EditorShot.Ticks -eq 6) { return }
    $controls = @(Get-DomeniaLogicalControls $script:Window.FindName('DomeniaDialogLayer'))
    $list = @($controls | Where-Object { [Windows.Automation.AutomationProperties]::GetName($_) -eq 'Informations disponibles' })[0]
    if ($script:EditorShot.Ticks -eq 4) { $search = @($controls | Where-Object { [Windows.Automation.AutomationProperties]::GetName($_) -eq 'Rechercher une information' })[0]; $search.Text = 'disque'; return }
    if ($script:EditorShot.Ticks -eq 5) { $row = @($list.ItemsSource | Where-Object { $_.Key -eq 'computer.disk.system' })[0]; if ($null -ne $row) { $list.SelectedItem = $row; $list.ScrollIntoView($row) }; return }
    $out = Save-GuideWindow 'editeur-widget'; Write-Host $out
    $script:EditorShot.Done = $true; $timer.Stop(); $state.Window.Close()
})
$timer.Start()
[void](Show-DomeniaBoardEditor -Board Computer)
$timer.Stop()

# 5. Software list and its synthesis.
$software = @(
    @('Microsoft Edge','129.0.2792.79','Microsoft Corporation','02/10/2026',612000,'Machine','64 bits'),@('Microsoft Teams','24.231.101','Microsoft Corporation','27/09/2026',405000,'Machine','64 bits'),
    @('Microsoft 365 Apps entreprise','16.0.18025','Microsoft Corporation','15/09/2026',2410000,'Machine','64 bits'),@('Adobe Acrobat Reader','24.003.20112','Adobe','11/09/2026',712000,'Machine','64 bits'),
    @('7-Zip 24.08','24.08','Igor Pavlov','03/06/2026',5800,'Machine','64 bits'),@('Logiciel comptable Compta Pro','12.4.1','Editeur Compta','20/08/2026',1830000,'Machine','32 bits'),
    @('Client VPN entreprise','5.2.0','Editeur Reseau','12/05/2026',96000,'Machine','64 bits'),@('Pilote imprimante universel','7.1','Constructeur','02/04/2026',48000,'Machine','64 bits'),
    @('Notepad++ (64-bit x64)','8.6.9','Notepad++ Team','18/07/2026',15200,'Machine','64 bits'),@('Visionneuse de documents','3.2','','01/02/2026',22000,'Utilisateur','32 bits'),
    @('Microsoft OneDrive','24.186.0915','Microsoft Corporation','25/09/2026',305000,'Utilisateur','64 bits'),@('Agent d inventaire','2.8.3','Editeur Inventaire','09/09/2026',38000,'Machine','64 bits')
)
$softRows = @($software | ForEach-Object { [pscustomobject]@{ Name = $_[0]; Version = $_[1]; Publisher = $_[2]; InstallDate = $_[3]; Size = $(if ($_[4] -gt 0) { '{0:0.#} Mo' -f ($_[4] / 1024) } else { '' }); SizeKb = [double]$_[4]; Scope = $_[5]; Architecture = $_[6]; Kind = 'Application'; Location = ''; UninstallString = ''; Source = 'Registre'; Category = $_[5] } })
[void](Set-DomeniaItemsSource 'DgSoftware' $softRows)
Update-DomeniaSoftwareDashboard -Rows $softRows
Show-GuideTab 'WsComputer' 'TabSoftware'
(Get-DomeniaControl 'CmbSoftwareView').SelectedIndex=1; Update-DomeniaSoftwareSyntheseVisibility
$exp = Get-DomeniaControl 'ExpSoftwareDashboard'; if ($null -ne $exp) { $exp.IsExpanded = $true; $exp.BringIntoView() }
Save-GuideWindow 'logiciels' 1560

}
# 6. Base autonome: displayed values are fictitious, no SQLite file is created or read.
$baseFreshness=Get-DomeniaFleetFreshness -ScopeDn $script:GuideScopeDn -DomainDn $script:Conn.BaseDn -SyncStates $script:IndexSyncStates -Subtree $true
$baseSummary=Format-DomeniaOuFreshnessSummary -IndexFreshness $baseFreshness
Set-GuideText @{
    TxtIndexLocation='C:\Users\tech.support\AppData\Local\Domenia\Data\Domains\exemple\Domenia.db'
    LblIndexBackupStatus=('Sauvegardes : dossier Backups · derniere le '+$now.AddMinutes(-15).ToString('dd/MM/yyyy HH:mm'))
    LblIndexScopeChoice='OU=Postes,OU=Lyon,DC=example,DC=local et ses sous-OU'
    LblIndexOverview='438 objets · 212 utilisateurs · 226 postes (223 actifs, 3 désactivés)'
    LblIndexFreshness=$baseSummary.BaseText
    LblIndexStats='Fichier local Domenia.db. Contrôleur : dc01.example.local. Repère : 184522. Associations utilisateur-poste : 34.'
    LblIndexStatus='200 objets affichés sur 226 · page 1 · périmètre choisi ci-dessus'
    LblParkStatus=('{0} observations mémorisées, dont {1} avec inventaire · données fictives' -f $presence.Count,@($presence | Where-Object { $null -ne $_.observation.Inventory }).Count)
}
$indexRows = @(foreach($m in @($machines | Select-Object -First 200)){[pscustomobject]@{Type='Machine';Name=$m.name;Login=($m.name+'$');Upn=($m.name.ToLowerInvariant()+'.example.local');State=$(if($m.st -eq 'D'){'Désactivé'}else{'Actif'});Association='';Score='';Reason='Périmètre local';Description=$m.distinguished_name;DN=$m.distinguished_name}})
[void](Set-DomeniaItemsSource 'DgIndex' $indexRows)
(Get-DomeniaControl 'BtnIndexNext').IsEnabled=$true
Set-DomeniaIndexProgress -Mode Complete -Message 'Synchronisation terminée : 438 objets enregistrés. Date complète conservée.'
Show-GuideTab 'TabApplicationTools' 'TabIndex'
(Get-DomeniaControl 'TabIndexData').IsSelected=$true;Update-GuideLayout
# Column virtualization needs an on-screen viewport; materialize the same bound columns for the off-screen bitmap.
$indexGrid=Get-DomeniaControl 'DgIndex'; $indexGrid.EnableColumnVirtualization=$false; $indexGrid.Items.Refresh(); $indexGrid.ScrollIntoView($indexGrid.Items[0]); $indexGrid.UpdateLayout()
Assert-Guide ($indexGrid.Items.Count -eq 200 -and [string]$indexGrid.Items[0].Name -ne '') 'Base : 200 objets liés à la grille'
Save-GuideWindow 'base-autonome' 1080
Save-GuideBaseDetails
(Get-DomeniaControl 'TabIndexData').IsSelected=$true;Update-GuideLayout
$detailColumn=@($indexGrid.Columns|Where-Object{[string]$_.SortMemberPath -eq 'Description'})[0]; $detailCell=$detailColumn.GetCellContent($indexGrid.Items[0]); $firstIndexRow=$indexGrid.ItemContainerGenerator.ContainerFromIndex(0)
Assert-Guide ($detailColumn.ActualWidth -ge 260 -and $detailCell.ActualHeight -le 48) 'Base : détail lisible et hauteur bornée'
Assert-Guide ($null -ne $firstIndexRow -and $firstIndexRow.ActualHeight -le 80) 'Base : la première ligne reste visible dans le tableau'
$boundCells=@(foreach($column in $indexGrid.Columns){$cell=$column.GetCellContent($indexGrid.Items[0]);[pscustomobject]@{Header=[string]$column.Header;Text=$(if($null -ne $cell -and $null -ne $cell.PSObject.Properties['Text']){[string]$cell.Text}else{''});CellType=$(if($null -ne $cell){$cell.GetType().FullName}else{'null'});Visibility=$(if($null -ne $cell){[string]$cell.Visibility}else{''});Opacity=$(if($null -ne $cell){$cell.Opacity}else{-1});Width=$(if($null -ne $cell){$cell.ActualWidth}else{-1});Height=$(if($null -ne $cell){$cell.ActualHeight}else{-1})}})
[IO.File]::WriteAllText((Join-Path $Out 'base-grid-diagnostic.json'),([pscustomobject]@{Items=$indexGrid.Items.Count;Visible=$indexGrid.IsVisible;Loaded=$indexGrid.IsLoaded;FirstName=$indexGrid.Items[0].Name;Cells=$boundCells}|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
# Measure the actual application layout at common desktop resolutions, without upscaling a bitmap.
$savedWidth=$script:GuideWidth;$savedHeight=[int]$script:GuideHost.Height
$viewportMeasurements=@(foreach($size in @(@(1920,1080),@(1280,720))){
    $script:GuideWidth=$size[0];$script:GuideHost.Width=$script:GuideWidth;Set-GuideHeight $size[1];Update-GuideLayout
    $measurement=Get-GuideGridViewport $indexGrid
    [IO.File]::WriteAllText((Join-Path $Out ('viewport-'+$size[0]+'x'+$size[1]+'.json')),($measurement|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
    if($CaptureSet -eq 'Base'){Save-GuideBitmap $script:GuideHost $script:GuideWidth $size[1] ('base-viewport-'+$size[0]+'x'+$size[1])}
    $minimumRows=if($size[1] -ge 1080){6}else{2}
    Assert-Guide ($measurement.FullyVisibleRows -ge $minimumRows) ('Base : au moins '+$minimumRows+' lignes entièrement visibles à '+$size[0]+'×'+$size[1])
    $measurement
})
$script:GuideWidth=$savedWidth;$script:GuideHost.Width=$script:GuideWidth;Set-GuideHeight $savedHeight;Update-GuideLayout
[IO.File]::WriteAllText((Join-Path $Out 'viewport-checks.json'),($viewportMeasurements|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
(Get-DomeniaControl 'TabIndexUpdate').IsSelected=$true;Update-GuideLayout
Save-GuideWindow 'base-mise-a-jour' 1080
Set-DomeniaIndexProgress -Mode Busy -Message 'OU choisie et ses sous-OU · 328 objets reçus, 256 enregistrés ; lecture et stockage en cours. Données fictives de démonstration.'
Set-GuideHeight 1080;Update-GuideLayout;Move-GuideScrollTo (Get-DomeniaControl 'LblIndexOverview')
Save-GuideWindow 'base-progression' 1080
Set-DomeniaIndexProgress -Mode Complete -Message 'Synchronisation terminée.'
(Get-DomeniaControl 'TabIndexStorage').IsSelected=$true;Update-GuideLayout
Save-GuideWindow 'base-stockage' 1080
Set-DomeniaUiZoom -Percent 120;Update-GuideLayout;Save-GuideWindow 'zoom-clair' 1080
Set-DomeniaUxPalette -Window $script:Window -Theme 'Dark';Update-GuideLayout;Save-GuideWindow 'zoom-sombre' 1080
Set-DomeniaUiZoom -Percent 100;Set-DomeniaUxPalette -Window $script:Window -Theme 'Light';Update-GuideLayout

# Operations health uses illustrative session measurements, clearly part of the fictitious fixture.
if($CaptureSet -eq 'All'){
    function Get-DomeniaRuntimeMetricSummary {
        param([string]$Provenance,[string]$Prefix)
        if($Prefix -eq 'Pulse'){return [pscustomobject]@{Count=120;P50=3;P95=14;Max=29}}
        if($Prefix -eq 'Callback:'){return [pscustomobject]@{Count=48;P50=12;P95=39;Max=83}}
        return $null
    }
    Assert-Guide ([bool](Show-DomeniaOperationsPanel)) 'Le panneau existant État du moteur est ouvert'
    [void](Set-DomeniaControlText 'LblOperationsHealth' (Get-DomeniaOperationsHealthText))
    Update-GuideLayout;Save-GuideWindow 'etat-moteur' 1080
    Hide-DomeniaOperationsPanel
}

# 7. Login window.
$login = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new([xml](Get-DomeniaStandardLoginXaml)))
$login.ShowInTaskbar = $false; $login.WindowStartupLocation = 'Manual'; $login.Left = 0; $login.Top = 0
$box = $login.FindName('TxtLogin'); if ($null -ne $box) { $box.Text = 'EXAMPLE\tech.support' }
$pwd = $login.FindName('PwdLogin'); if ($null -ne $pwd) { $pwd.Password = 'exemple-sans-valeur' }
$login.Show(); $login.UpdateLayout(); $login.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
$panel = $login.FindName('PanelLogin'); if ($null -eq $panel) { $panel = $login.Content }
$panel.UpdateLayout()
$w = $script:GuideWidth; $h = [Math]::Max(1080,$script:GuideHeight)
Disable-GuideToolTips $login
$drawing = [Windows.Media.DrawingVisual]::new(); $ctx = $drawing.RenderOpen()
$ctx.DrawRectangle([Windows.Media.Brushes]::White,$null,[Windows.Rect]::new(0,0,$w,$h))
$vb = [Windows.Media.VisualBrush]::new($panel); $vb.Stretch = [Windows.Media.Stretch]::None
$ctx.DrawRectangle($vb,$null,[Windows.Rect]::new([Math]::Floor(($w-$panel.ActualWidth)/2),[Math]::Floor(($h-$panel.ActualHeight)/2),$panel.ActualWidth,$panel.ActualHeight)); $ctx.Close()
Save-GuideBitmap $drawing $w $h 'connexion'
$login.Close()
$script:Window.Close()
[IO.File]::WriteAllText((Join-Path $Out 'capture-checks.json'),([pscustomobject]@{Fixture='example.local, 226 comptes postes fictifs (223 actifs, 3 désactivés)';Session=[Diagnostics.Process]::GetCurrentProcess().SessionId;Rendering='Real WPF layout, off-screen RenderTargetBitmap';Checks=$script:GuideChecks.ToArray()}|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $Out 'capture-provenance.json'),([pscustomobject]@{UTC=[datetime]::UtcNow.ToString('o');PowerShell=$PSVersionTable.PSVersion.ToString();Session=[Diagnostics.Process]::GetCurrentProcess().SessionId;SourceManifestSHA256=(Get-FileHash -LiteralPath (Join-Path $wad 'package-manifest.json') -Algorithm SHA256).Hash;Rendering='Native WPF RenderTargetBitmap; off-screen host, no image upscaling';Fixture='example.local, synthetic directory and observations, no AD access';FreshnessFixture='AD 35 minutes old; ping 10 to 20 minutes old; WMI inventory 2 to 3 days old; local recalculation preserves measurement dates';ToolTipsEnabled=$false;Images=$script:GuideImages.ToArray()}|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $Out 'capture-layouts.json'),($script:GuideLayouts.ToArray()|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
if(@($script:GuideChecks|Where-Object{-not $_.Passed}).Count){throw 'Captures produites ; un contrôle de disposition reste en échec. Voir capture-checks.json.'}
' termine'
