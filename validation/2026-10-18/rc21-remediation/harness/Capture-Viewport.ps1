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
    'Write-DomeniaSwallowed',
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
# Use the delivered closed, definition-only module plan so new presentation dependencies stay in sync.
# This bootstrap performs no window, timer, credential, database or network operation.
. (Join-Path $wad 'Domenia-Modules.ps1')
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
# Documentary in-memory store boundary only: real recipe/model/UI callbacks, no SQLite access.
# These screenshots do not qualify persistence; that is covered by separate native Windows tests.
$guideContext=[pscustomobject]@{Version=1;StoreId='guide-fixture';DomainDn=$script:Conn.BaseDn;Path=$script:DatabaseScopedPath;SessionEpoch=1L}
$script:DomeniaQueryLibraryStoreState=[pscustomobject]@{Context=$guideContext;Generation=1L;Loaded=$true;Loading=$false;Saving=$false;Error='';Rows=@{};Recipes=@();Categories=@{};ArchivedRows=@();Dependencies=@()}
function New-DomeniaStoreContext {param([string]$RequestId) return $script:DomeniaQueryLibraryStoreState.Context}
function Submit-DomeniaStoreBatch {
    param($Context,[string]$BatchId,[long]$Sequence=0,[object[]]$Changes,[string]$SuccessHandler,[string]$ErrorHandler,$CallbackState)
    $records=@($Changes|Where-Object{$_.Kind -eq 'QueryRecipe'}|ForEach-Object{$_.Record})
    if($records.Count -ne 1){throw 'Documentary fixture expects one recipe per save.'}
    $links=@($Changes|Where-Object{$_.Kind -eq 'QueryDependency' -and -not $_.Remove})
    & $SuccessHandler ([pscustomobject]@{Saved=$true;DataSource='SQLite';StoreId=$Context.StoreId;QueryRecipes=$records;QueryDependencies=$links}) $CallbackState
    return [pscustomobject]@{Accepted=$true;Reason=''}
}
function Set-DomeniaSetting { param([string]$Name,$Value) $script:GuideSettings[$Name] = $Value }
function Get-DomeniaSetting { param([string]$Name,$Default = $null) if ($script:GuideSettings.ContainsKey($Name)) { return $script:GuideSettings[$Name] }; return $Default }
function Save-DomeniaSettings { param([switch]$Immediate,[switch]$ThrowOnFailure) }
function Test-DomeniaLiveSearchActive { return $false }
# DS-08 / UI-17 (X04): the header and the association line of the workstation come from the real rules; the selected
# workstation and its association are fixture values, nothing is read.
function Get-CurrentSelectedComputerName { return 'PC-COMPTA-014' }
function Get-ExistingLinkForComputer { param([string]$Computer) return [pscustomobject]@{Computer='PC-COMPTA-014';UserLogin='cmartin';UserDn='CN=Camille Martin,OU=Utilisateurs,OU=Lyon,DC=example,DC=local';Source='Console observee';Kind='Console';When=$script:GuideLinkWhen} }
function Get-DomeniaRunningComputerUserProbe { param([string]$Computer) return $null }
function Invalidate-DomeniaSearchResults { $script:GlobalSearchGeneration++; $script:ShownRows=@() }
function Add-DomeniaUiLog { param([string]$Area,[string]$Text,[string]$Level = 'INFO') }
function Set-Status { param([string]$Text,[string]$Level = 'INFO') }
function Write-AppLog { param([string]$Text,[string]$Level = 'INFO') }
function Apply-DomeniaGuiElementPolicy { }
function Update-Dashboard { }
function Get-DomeniaCredentialUserName { param($Credential) return '' }
# The capture harness executes the pure local query/library workers synchronously on fictitious rows.
# All other worker calls are inert. The application scheduler is exercised by the separate UI test.
function Start-UiTask {
    param([string]$Name,[string]$OperationId,[string]$Code,$Payload,$CallbackState,[string]$ReplaceKey,[string]$SuccessHandler,[string]$ErrorHandler,[int]$TimeoutSeconds,[string]$TaskClass)
    if ($OperationId -eq 'QueryLibrary') {
        $result = & ([scriptblock]::Create($Code))
        & $SuccessHandler -Result $result -State $CallbackState
        return 'guide-query-library'
    }
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
    # Virtualized/recycled containers can be detached after a resize; they have no visible pixels.
    if(-not $script:GuideHost.IsAncestorOf($Element)){return [Windows.Rect]::Empty}
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
    $rectangles=@(foreach($id in @('CmbQueryField','BtnQueryAddCondition','CmbFleetQuery','BtnQueryWidget','CmbCollectionConcurrency','ExpQueryObject','DgFleetMachines','DgQueryCatalog','PnlQueryCatalogDetail','DgQueryLibrary','LblQueryLibraryDescription','DgIndex','LblIndexTileAccounts','LblIndexLocation','ExpStorageMaintenance','UxSearchQueryBar','TxtSearchQueryFilter','CmbWorkView','CmbSearchQueryResult','DgObjects','LblSearchQueryDetails','LblSearchQuery','LblOperationsHealth','TvDirectory','UxSearchOuRefresh','LblSearchOuRefreshScope','LblSearchOuRefreshStatus','BtnSearchRefreshBase','BtnSearchRefreshPostes','BtnSearchRefreshBoth','BtnSearchRefreshStop','LblFleetScope','LblFleetDashboard','LblFleetOuRefreshStatus','BtnFleetIndexScope','BtnFleetRefreshPostes','BtnFleetRefreshBoth','BtnFleetRefreshStop','BtnFleetDashboardRefresh','LblIndexFreshness')){
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
    Invoke-DomeniaUxRoute -Route $Route
    if ($Tab) {
        # UX-21 (X04): Assistance poste has five views; a workstation tab, a former name included (TabSoftware,
        # TabComputerDashboard...), resolves to its view and inner tab exactly as a menu or a widget link does.
        if ($Route -eq 'WsComputer') { Select-DomeniaWorkspace -Workspace 'WsComputer' -Inner 'ComputerTabs' -Tab $Tab }
        else { $page = Get-DomeniaControl $Tab; if ($null -eq $page) { throw ('Onglet introuvable : ' + $Tab) }; $page.IsSelected = $true }
    }
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
$xamlText = Get-MainXaml -WadRoot $wad
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
(Get-DomeniaControl 'TabQueryResults').IsSelected=$true;Update-GuideLayout
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

}
[IO.File]::WriteAllText((Join-Path $Out 'capture-checks.json'),([pscustomobject]@{Fixture='example.local, 226 comptes postes fictifs (223 actifs, 3 désactivés)';Session=[Diagnostics.Process]::GetCurrentProcess().SessionId;Rendering='Real WPF layout, off-screen RenderTargetBitmap';Checks=$script:GuideChecks.ToArray()}|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $Out 'capture-provenance.json'),([pscustomobject]@{UTC=[datetime]::UtcNow.ToString('o');PowerShell=$PSVersionTable.PSVersion.ToString();Session=[Diagnostics.Process]::GetCurrentProcess().SessionId;SourceManifestSHA256=(Get-FileHash -LiteralPath (Join-Path $wad 'package-manifest.json') -Algorithm SHA256).Hash;SourceRuntimeManifestSHA256=(Get-FileHash -LiteralPath (Join-Path $Dev 'tools\prod-manifest.json') -Algorithm SHA256).Hash;Build=([IO.File]::ReadAllText((Join-Path $wad 'Domenia.release.json'))|ConvertFrom-Json).Build;Rendering='Native WPF RenderTargetBitmap; off-screen host, no image upscaling';Fixture='example.local, synthetic directory and observations, no AD access';FreshnessFixture='AD 35 minutes old; ping 10 to 20 minutes old; WMI inventory 2 to 3 days old; local recalculation preserves measurement dates';ToolTipsEnabled=$false;Images=$script:GuideImages.ToArray()}|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $Out 'capture-layouts.json'),($script:GuideLayouts.ToArray()|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
if(@($script:GuideChecks|Where-Object{-not $_.Passed}).Count){throw 'Captures produites ; un contrôle de disposition reste en échec. Voir capture-checks.json.'}
' termine'
