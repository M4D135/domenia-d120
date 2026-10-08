#requires -Version 5.1
# Captures des guides Domenia 1.0 (edition du 8 octobre 2026). Vraie fenetre WPF du depot, valeurs fictives coherentes
# (domaine example.local), rendue hors ecran a 1440 x 900. Aucun annuaire ni poste distant n est contacte.
# A lancer dans la VM de test (powershell.exe -STA), jamais sur un poste de production.
param([string]$Dev = 'C:\DomeniaLab\d120\dev',[string]$Out = 'C:\DomeniaLab\d120\guide-captures',[int]$Width = 1440,[int]$Height = 900)
$ErrorActionPreference = 'Stop'
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
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$tokens,[ref]$parseErrors)
if (@($parseErrors).Count) { throw ('Coeur illisible : ' + $parseErrors[0].Message) }
$coreNames = @(
    'Set-DomeniaControlText','Get-MainXaml','Assert-DomeniaXamlPreflight','Get-DomeniaXamlControlNames',
    'Get-DomeniaControl','Set-DomeniaContextHint','Get-DomeniaFriendlyControlLabel',
    'Get-DomeniaDefaultToolTip','Save-DomeniaUiProfile','Apply-DomeniaUiProfile',
    'Set-TabVisibility','Set-VisibleTabsForType','Assert-DomeniaWorkspaceSelection',
    'Select-DomeniaWorkspace','Get-DomeniaSearchMode','Get-DomeniaSearchText','Set-DomeniaSearchMode','Get-DomeniaSearchScope','Update-DomeniaSearchScopeUi',
    'Set-SelectedBranch','Reset-DomeniaSearchScope','Set-DomeniaComboByContent',
    'Set-DomeniaItemsSource','Set-DomeniaGridRows','Test-DomeniaSearchStateCurrent','Get-GlobalSelectedTypeFilter','Get-TypeLdapFilter','Get-DomeniaEffectiveWorkerResult','Normalize-LinkComputer',
    'Get-DomeniaStandardLoginXaml','Convert-DomeniaXamlToBootTheme','Get-DomeniaBootThemePalette','Get-DomeniaBootThemeResources','Get-WriteControlMap'
)
foreach ($name in $coreNames) {
    $nodes = @($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
    if ($nodes.Count -ne 1) { throw ('Fonction introuvable : ' + $name) }
    Invoke-Expression $nodes[0].Extent.Text
}
foreach ($module in @('Domenia-Common.Model.ps1','Domenia-Relations.Model.ps1','Domenia-Access.Model.ps1','Domenia-Shell.Model.ps1','Domenia-Embedded.UI.ps1','Domenia-UX.UI.ps1',
    'Domenia-Boards.Model.ps1','Domenia-Charts.UI.ps1','Domenia-Probes.Model.ps1','Domenia-BoardFleet.Model.ps1','Domenia-BoardSoftware.Model.ps1','Domenia-BoardComputer.UI.ps1','Domenia-Widgets.UI.ps1','Domenia-Dashboard.UI.ps1')) {
    . (Join-Path $wad ('modules\' + $module))
}
# Local replacements: no settings, log, directory or workstation is touched.
$script:GuideSettings = @{}; $script:Ctrl = @{}; $script:SelectedObject = $null; $script:CurrentUiProfile = 'Tech'; $script:ReadOnlyMode = $true
$script:Conn = [pscustomobject]@{ Connected = $true; BaseDn = 'DC=example,DC=local'; Domain = 'example.local'; Netbios = 'EXAMPLE' }
$script:SelectedBranchDn = $script:Conn.BaseDn; $script:SearchMode = 'OU'; $script:SuppressBranchAutoLoad = $true; $script:RestoringSettings = $false
$script:AsyncJobs = @{}; $script:DetachedReadJobs = @(); $script:SessionEpoch = 1; $script:WriteState = 'Idle'; $script:DomeniaReduceMotion = $true
function Set-DomeniaSetting { param([string]$Name,$Value) $script:GuideSettings[$Name] = $Value }
function Get-DomeniaSetting { param([string]$Name,$Default = $null) if ($script:GuideSettings.ContainsKey($Name)) { return $script:GuideSettings[$Name] }; return $Default }
function Save-DomeniaSettings { param([switch]$Immediate) }
function Add-DomeniaUiLog { param([string]$Area,[string]$Text,[string]$Level = 'INFO') }
function Set-Status { param([string]$Text,[string]$Level = 'INFO') }
function Write-AppLog { param([string]$Text,[string]$Level = 'INFO') }
function Apply-DomeniaGuiElementPolicy { }
function Update-Dashboard { }
function Get-DomeniaCredentialUserName { param($Credential) return '' }
function Start-UiTask { return 'guide' }
function Start-DomeniaOnlinePark { }
function Get-DeProp { param($Entry,[string]$Name,$Default = $null) if ($Entry -is [hashtable] -and $Entry.ContainsKey($Name)) { return $Entry[$Name] }; return $Default }
function Get-DomeniaEntryFirstString { param($Entry,[string]$Name) $v = Get-DeProp $Entry $Name ''; return [string]$v }
function Get-DomeniaStoredTheme { return 'Light' }

function Invoke-GuideMeasure {
    # The window content lives in an off-screen host of the target size (the desktop of the test VM is 1024 x 768).
    $h = [double]$script:GuideHost.Height
    $script:GuideHost.Measure([Windows.Size]::new($Width,$h)); $script:GuideHost.Arrange([Windows.Rect]::new(0,0,$Width,$h)); $script:GuideHost.UpdateLayout()
    $script:Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
}
function Update-GuideLayout {
    Invoke-GuideMeasure
    # The layout rules read only the window size: they see the target size.
    $real = $script:Window
    $h = [double]$script:GuideHost.Height
    $script:Window = [pscustomobject]@{ ActualWidth = [double]$Width; ActualHeight = $h; Width = [double]$Width; Height = $h }
    try { Update-DomeniaUxLayout } finally { $script:Window = $real }
    Sync-DomeniaUxNavigation
    (Get-DomeniaControl 'LblUxDomain').Text = 'Session AD · example.local'
    Invoke-GuideMeasure
    Invoke-GuideMeasure
}
function Save-GuideBitmap {
    param($Visual,[int]$W,[int]$H,[string]$Name)
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new($W,$H,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($Visual)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new(); $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $path = Join-Path $Out ($Name + '.png'); $stream = [IO.File]::Create($path); try { $encoder.Save($stream) } finally { $stream.Dispose() }
    'capture ' + $Name + ' ' + $W + 'x' + $H
}
function Set-GuideHeight {
    param([int]$Value)
    $script:CaptureHeight = $Value; $script:GuideHost.Height = $Value
}
function Save-GuideWindow {
    param([string]$Name,[int]$Tall = 0)
    if ($Tall -gt 0) { Set-GuideHeight $Tall }
    Update-GuideLayout
    $logRow = Get-DomeniaControl 'UxLogRow'; $reduced = $false
    if ($null -ne $logRow -and $logRow.Height.Value -gt 60) { Switch-DomeniaUxLog; $reduced = $true }
    Update-GuideLayout
    Save-GuideBitmap $script:GuideHost $Width ([int]$script:GuideHost.Height) $Name
    if ($reduced) { Switch-DomeniaUxLog }
    if ($Tall -gt 0) { Set-GuideHeight $Height; Update-GuideLayout }
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
    Update-GuideLayout
}
function Set-GuideText { param([hashtable]$Values) foreach ($k in $Values.Keys) { $c = Get-DomeniaControl $k; if ($null -ne $c) { $c.Text = [string]$Values[$k] } } }

# ------------------------------------------------------------------ fictitious directory
$now = Get-Date
$osList = @('Windows 11 Entreprise / 10.0 (26100)','Windows 11 Entreprise / 10.0 (26100)','Windows 11 Entreprise / 10.0 (26200)','Windows 10 Entreprise / 10.0 (19045)')
$services = @('Compta','RH','Accueil','Direction')
$machines = New-Object Collections.ArrayList; $presence = New-Object Collections.ArrayList
for ($i = 1; $i -le 26; $i++) {
    $service = $services[$i % 4]; $name = 'PC-' + $service.ToUpperInvariant() + '-' + ('{0:000}' -f (10 + $i))
    $dn = 'CN=' + $name + ',OU=' + $service + ',OU=Postes,OU=Lyon,DC=example,DC=local'
    $days = @(1,2,3,5,8,12,20,35,2,1,4,6,95,3,1,2,9,15,1,3,40,2,1,7,200,3)[$i - 1]
    $os = if ($i -in @(7,19)) { $osList[3] } else { $osList[$i % 3] }
    [void]$machines.Add([pscustomobject]@{ name = $name; object_guid = ('g-' + $i); extra = $os; last_logon = $now.AddDays(-$days).ToString('dd/MM/yyyy HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture); distinguished_name = $dn })
    if ($i -le 22) {
        $online = ($i % 6 -ne 0)
        $inventory = if ($online) { [pscustomobject]@{ OsCaption = $(if ($os -like 'Windows 10*') { 'Microsoft Windows 10 Entreprise' } else { 'Microsoft Windows 11 Entreprise' }); Build = $(if ($os -like '*19045*') { '19045' } elseif ($os -like '*26200*') { '26200' } else { '26100' }); LastBootUtc = $now.AddDays(-@(1,2,3,40,4,1,2,6,33,1,2,5,1,3,2,8,1,2,4,1,2,3)[$i - 1]).ToUniversalTime().ToString('o'); Manufacturer = 'Constructeur'; Model = @('Latitude 5440','OptiPlex 7010','EliteBook 840 G10')[$i % 3]; RamBytes = [double](@(8,16,16,32)[$i % 4]) * 1GB; DiskSize = 476.0 * 1GB; DiskFree = $(if ($i -eq 9) { 31.0 } else { 120.0 + 9 * $i }) * 1GB } } else { $null }
        $observation = [pscustomobject]@{ Key = $dn.ToLowerInvariant(); Presence = $(if ($online) { 'En ligne' } else { 'Sans reponse au ping' }); LinkUser = $(if ($online -and $i % 3 -ne 0) { 'EXAMPLE\user' + $i } else { '' }); Inventory = $inventory }
        [void]$presence.Add([pscustomobject]@{ object_key = $dn.ToLowerInvariant(); checked_utc = $now.AddMinutes(-20).ToUniversalTime().ToString('o'); payload = ($observation | ConvertTo-Json -Depth 5 -Compress) })
    }
}
$fleet = [pscustomobject]@{ Busy = $false; Links = 34; LinkSources = @(); Types = @([pscustomobject]@{ t = 'Machine'; s = 'Actif'; n = 26 },[pscustomobject]@{ t = 'Utilisateur'; s = 'Actif'; n = 212 }); Machines = @($machines); Presence = @($presence) }

$inventoryRows = @(
    @('Systeme d exploitation','Nom','Microsoft Windows 11 Entreprise'),@('Systeme d exploitation','Build','26100'),@('Systeme d exploitation','Version','10.0.26100'),
    @('Systeme d exploitation','Duree de fonctionnement','34 j 5 h 14 min'),@('Systeme d exploitation','Dernier demarrage','04/09/2026 07:58:12'),
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
$computer = [pscustomobject]@{ Type = 'Machine'; Name = 'PC-COMPTA-014'; DN = 'CN=PC-COMPTA-014,OU=Compta,OU=Postes,OU=Lyon,DC=example,DC=local'; Entry = $entry; Safety = [pscustomobject]@{ Guid = 'g-14' } }

# ------------------------------------------------------------------ window
$xamlText = Get-MainXaml
$reader = [Xml.XmlNodeReader]::new([xml]$xamlText); try { $script:Window = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
foreach ($name in @(Get-DomeniaXamlControlNames -XamlText $xamlText)) { $c = $script:Window.FindName($name); if ($null -ne $c) { $script:Ctrl[$name] = $c } }
$script:Window.ShowInTaskbar = $false; $script:Window.WindowStartupLocation = 'Manual'; $script:Window.Left = 0; $script:Window.Top = 0
# A borderless, fixed-size window is not clamped to the 1024 x 768 desktop of the test VM (client area unchanged).
$script:Window.WindowStyle = 'None'; $script:Window.ResizeMode = 'NoResize'
[GuideCaptureHook]::Allow($script:Window,$Width + 40,$Height + 40)
$script:Window.Width = $Width; $script:Window.Height = $Height
(Get-DomeniaControl 'ChkReadOnlyMode').IsChecked = $true
$writeMap = Get-WriteControlMap
foreach ($cap in $writeMap.Keys) { foreach ($n in @($writeMap[$cap])) { $c = Get-DomeniaControl $n; if ($null -ne $c) { $c.IsEnabled = $false; $c.ToolTip = 'Desactive : mode lecture seule actif.' } } }
(Get-DomeniaControl 'TxtDashDomain').Text = 'example.local'
(Get-DomeniaControl 'TxtUiLog').Text = '08:12:41.204 [INFO] [Statut] Pret. Connexion validee, mode lecture seule actif.'
Set-VisibleTabsForType -Type ''
Initialize-DomeniaUxShell
Set-DomeniaUxPalette -Window $script:Window -Theme 'Light'
$script:Window.WindowState = 'Normal'
$script:Window.Show()
$content = $script:Window.Content; $script:Window.Content = $null
$script:GuideHost = [Windows.Controls.Grid]::new(); $script:GuideHost.Width = $Width; $script:GuideHost.Height = $Height
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

# 1. Accueil: fleet overview of an OU.
$script:GuideSettings['FleetScopeDn'] = 'OU=Postes,OU=Lyon,DC=example,DC=local'
Complete-DomeniaFleetDashboard -Result $fleet -State $null
(Get-DomeniaControl 'LblFleetRun').Text = 'Releve termine : 22/22 postes verifies, 18 joignables, 15 identites en cache, 2 associations actualisees, 4 lectures non confirmees.'
Show-GuideTab 'TabDashboard'
Set-GuideHeight 1240; Update-GuideLayout
$logRow = Get-DomeniaControl 'UxLogRow'; if ($null -ne $logRow -and $logRow.Height.Value -gt 60) { Switch-DomeniaUxLog; Update-GuideLayout }
$fleetCard = (Get-DomeniaControl 'BtnFleetDashboardRefresh').Parent.Parent.Parent
$scroller = $fleetCard; while ($null -ne $scroller -and $scroller -isnot [Windows.Controls.ScrollViewer]) { $scroller = [Windows.Media.VisualTreeHelper]::GetParent($scroller) }
if ($null -ne $scroller) { $top = $fleetCard.TranslatePoint([Windows.Point]::new(0,0),$scroller).Y; $scroller.ScrollToVerticalOffset($scroller.VerticalOffset + $top - 8) }
Save-GuideWindow 'accueil' 1240

# 2. Rechercher: results of a search.
$tree = Get-DomeniaControl 'TvDirectory'
$root = [Windows.Controls.TreeViewItem]::new(); $root.Header = 'example.local'; $root.IsExpanded = $true
foreach ($ou in @('Groupes','Lyon','Marseille','Utilisateurs')) { $item = [Windows.Controls.TreeViewItem]::new(); $item.Header = $ou; if ($ou -eq 'Lyon') { $item.IsExpanded = $true; $sub = [Windows.Controls.TreeViewItem]::new(); $sub.Header = 'Postes'; [void]$item.Items.Add($sub) }; [void]$root.Items.Add($item) }
[void]$tree.Items.Add($root)
$rows = @(
    [pscustomobject]@{ Type = 'Machine'; Name = 'PC-COMPTA-014'; Login = 'PC-COMPTA-014$'; UPN = 'pc-compta-014.example.local'; Presence = 'En ligne'; PresenceDetail = 'Ping 3 ms'; SessionDisplay = 'cmartin'; SessionState = 'Console lue'; DirectoryState = 'A jour'; Association = 'Camille Martin'; LinkSource = 'Console observee'; LinkConfidence = 'Observe'; State = 'Actif'; OS = 'Windows 11 Entreprise'; LastLogon = '07/10/2026'; DN = $computer.DN; Admin = '' }
    [pscustomobject]@{ Type = 'Machine'; Name = 'PC-COMPTA-015'; Login = 'PC-COMPTA-015$'; UPN = 'pc-compta-015.example.local'; Presence = 'En ligne'; PresenceDetail = 'Ping 4 ms'; SessionDisplay = 'Aucun'; SessionState = 'Console lue'; DirectoryState = 'A jour'; Association = 'Louis Bernard'; LinkSource = 'Console observee'; LinkConfidence = 'Observe'; State = 'Actif'; OS = 'Windows 11 Entreprise'; LastLogon = '08/10/2026'; DN = 'CN=PC-COMPTA-015,OU=Compta,OU=Postes,OU=Lyon,DC=example,DC=local'; Admin = '' }
    [pscustomobject]@{ Type = 'Machine'; Name = 'PC-COMPTA-016'; Login = 'PC-COMPTA-016$'; UPN = 'pc-compta-016.example.local'; Presence = 'Sans reponse'; PresenceDetail = 'Pas de reponse au ping'; SessionDisplay = ''; SessionState = 'Non verifie'; DirectoryState = 'A jour'; Association = 'Sarah Petit'; LinkSource = 'Import'; LinkConfidence = 'Importe'; State = 'Actif'; OS = 'Windows 10 Entreprise'; LastLogon = '22/09/2026'; DN = 'CN=PC-COMPTA-016,OU=Compta,OU=Postes,OU=Lyon,DC=example,DC=local'; Admin = '' }
    [pscustomobject]@{ Type = 'Machine'; Name = 'PC-COMPTA-021'; Login = 'PC-COMPTA-021$'; UPN = 'pc-compta-021.example.local'; Presence = 'En ligne'; PresenceDetail = 'Ping 2 ms'; SessionDisplay = 'jdurand'; SessionState = 'Console lue'; DirectoryState = 'A jour'; Association = 'Julie Durand'; LinkSource = 'Console observee'; LinkConfidence = 'Observe'; State = 'Actif'; OS = 'Windows 11 Entreprise'; LastLogon = '08/10/2026'; DN = 'CN=PC-COMPTA-021,OU=Compta,OU=Postes,OU=Lyon,DC=example,DC=local'; Admin = '' }
    [pscustomobject]@{ Type = 'Utilisateur'; Name = 'Camille Martin'; Login = 'cmartin'; UPN = 'cmartin@example.local'; Presence = ''; PresenceDetail = ''; SessionDisplay = ''; SessionState = ''; DirectoryState = 'A jour'; Association = 'PC-COMPTA-014'; LinkSource = 'Console observee'; LinkConfidence = 'Observe'; State = 'Actif'; OS = ''; LastLogon = '08/10/2026'; DN = 'CN=Camille Martin,OU=Compta,OU=Utilisateurs,DC=example,DC=local'; Admin = '' }
    [pscustomobject]@{ Type = 'Utilisateur'; Name = 'Compta Lyon (partage)'; Login = 'compta.lyon'; UPN = 'compta.lyon@example.local'; Presence = ''; PresenceDetail = ''; SessionDisplay = ''; SessionState = ''; DirectoryState = 'A jour'; Association = ''; LinkSource = ''; LinkConfidence = ''; State = 'Desactive'; OS = ''; LastLogon = '14/03/2026'; DN = 'CN=Compta Lyon,OU=Comptes de service,DC=example,DC=local'; Admin = '' }
    [pscustomobject]@{ Type = 'Groupe'; Name = 'GG-Compta-Lyon'; Login = 'GG-Compta-Lyon'; UPN = ''; Presence = ''; PresenceDetail = ''; SessionDisplay = ''; SessionState = ''; DirectoryState = 'A jour'; Association = ''; LinkSource = ''; LinkConfidence = ''; State = ''; OS = ''; LastLogon = ''; DN = 'CN=GG-Compta-Lyon,OU=Groupes,DC=example,DC=local'; Admin = '' }
)
$script:BranchObjects = $rows
[void](Set-DomeniaItemsSource 'DgObjects' $rows)
(Get-DomeniaControl 'TxtGlobalSearch').Text = 'compta'
(Get-DomeniaControl 'LblBranchCount').Text = '7 résultat(s) · liste complète'
foreach ($b in @('BtnParkPing','BtnParkResults','BtnLiveRecheck','BtnExportResults')) { $c = Get-DomeniaControl $b; if ($null -ne $c) { $c.IsEnabled = $true } }
$grid = Get-DomeniaControl 'DgObjects'
$order = @('Type','Nom','Utilisateur connecté (console)','Association mémorisée','Présence réseau')
for ($k = 0; $k -lt $order.Count; $k++) { $col = @($grid.Columns | Where-Object { [string]$_.Header -eq $order[$k] })[0]; if ($null -ne $col) { $col.DisplayIndex = $k } }
foreach ($pair in @(@('Utilisateur connecté (console)',190),@('Association mémorisée',170),@('Nom',150))) { $col = @($grid.Columns | Where-Object { [string]$_.Header -eq $pair[0] })[0]; if ($null -ne $col) { $col.Width = [Windows.Controls.DataGridLength]::new([double]$pair[1]) } }
Show-GuideTab 'WsSearch'
$grid.SelectedIndex = 0
Save-GuideWindow 'recherche'
Save-GuideElement (Get-DomeniaControl 'BtnParkPing').Parent 'recherche-actions'

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
$exp = Get-DomeniaControl 'ExpSoftwareDashboard'; if ($null -ne $exp) { $exp.IsExpanded = $true; $exp.BringIntoView() }
Save-GuideWindow 'logiciels' 1560

# 6. Base autonome.
Set-GuideText @{ TxtIndexLocation = 'C:\Users\tech.support\AppData\Local\Domenia\Data\Domains\716ab6f3adb11ba326cf5c8b0f24c2a3\Domenia.db'; LblIndexBackupStatus = 'Sauvegardes : C:\Users\tech.support\AppData\Local\Domenia\Data\Domains\716ab6f3adb11ba326cf5c8b0f24c2a3\Backups · derniere le 08/10/2026 08:15'
    LblIndexStats = 'Base autonome Domenia.db : 238 objet(s), 212 compte(s), 26 poste(s), 34 association(s) user-machine (29 verifiee(s)). Derniere passe le 08/10/2026 07:30, soit 1 heure(s) depuis dc01.example.local, repere de suivi 184522. Chargement complet RAM desactive.' }
Show-GuideTab 'TabApplicationTools' 'TabIndex'
Save-GuideWindow 'base-autonome'

# 7. Login window.
$login = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new([xml](Get-DomeniaStandardLoginXaml)))
$login.ShowInTaskbar = $false; $login.WindowStartupLocation = 'Manual'; $login.Left = 0; $login.Top = 0
$box = $login.FindName('TxtLogin'); if ($null -ne $box) { $box.Text = 'EXAMPLE\tech.support' }
$pwd = $login.FindName('PwdLogin'); if ($null -ne $pwd) { $pwd.Password = 'exemple-sans-valeur' }
$login.Show(); $login.UpdateLayout(); $login.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
$panel = $login.FindName('PanelLogin'); if ($null -eq $panel) { $panel = $login.Content }
$panel.UpdateLayout()
$w = [int][Math]::Ceiling($panel.ActualWidth) + 24; $h = [int][Math]::Ceiling($panel.ActualHeight) + 24
$drawing = [Windows.Media.DrawingVisual]::new(); $ctx = $drawing.RenderOpen()
$ctx.DrawRectangle([Windows.Media.Brushes]::White,$null,[Windows.Rect]::new(0,0,$w,$h))
$vb = [Windows.Media.VisualBrush]::new($panel); $vb.Stretch = [Windows.Media.Stretch]::None
$ctx.DrawRectangle($vb,$null,[Windows.Rect]::new(12,12,$panel.ActualWidth,$panel.ActualHeight)); $ctx.Close()
Save-GuideBitmap $drawing $w $h 'connexion'
$login.Close()
$script:Window.Close()
'termine'
