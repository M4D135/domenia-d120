#requires -Version 5.1
<# Tests isoles R1.1 : aucun login, aucune requete AD, aucune base de production.
   Les fonctions reelles sont extraites avec le parseur natif PowerShell.
   Les preferences de test vivent exclusivement dans un dossier temporaire.
   -Wpf construit les quatre fenetres d amorcage et la principale sans afficher
   de fenetre, puis controle les couleurs effectives et les bascules.
#>
[CmdletBinding()]
param([switch]$Wpf,[string]$ReportPath='')
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\Domenia-Experience.Model.ps1')
if ($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) {
    throw 'Utiliser Windows PowerShell 5.1 64 bits : TESTER-THEMES.cmd.'
}
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Lancer powershell.exe avec -STA.' }
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$packageRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$core=Join-Path $packageRoot 'wad\Domenia-Core.ps1'
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($core,[ref]$tokens,[ref]$parseErrors)
if (@($parseErrors).Count -gt 0) {
    throw (($parseErrors | ForEach-Object { 'L'+$_.Extent.StartLineNumber+': '+$_.Message }) -join "`r`n")
}
$wanted=@(
    'Get-DomeniaDefaultSettings','Load-DomeniaSettings','Save-DomeniaSettings','Get-DomeniaSetting','Set-DomeniaSetting',
    'Get-DomeniaPreferencePath','Read-DomeniaPreference','Write-DomeniaPreference','Write-DomeniaAtomicText',
    'Get-DomeniaStoredTheme','Load-DomeniaTheme','Save-DomeniaTheme','Get-DomeniaBootThemePalette',
    'Get-DomeniaBootThemeResources','Get-DomeniaBootStatusColor','Convert-DomeniaXamlToBootTheme',
    # TE-04 (lot X03): one sign-in template since CD-10; the legacy and Debug templates no longer exist.
    'Get-DomeniaStandardLoginXaml','Get-DomeniaStartupXaml',
    'Apply-DomeniaTheme','Toggle-DomeniaTheme','Get-MainXaml','Assert-DomeniaXamlPreflight','ConvertFrom-DomeniaXaml'
)
$nodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
$definitions=foreach($name in $wanted) {
    $found=@($nodes | Where-Object {$_.Name -eq $name})
    if ($found.Count -ne 1) { throw "Definition unique requise : $name." }
    $found[0].Extent.Text
}
# Definitions uniquement : le chemin de demarrage de l application ne tourne jamais.
. ([scriptblock]::Create(($definitions -join "`r`n")))
# The real presentation palette overrides the historic core palette in the application.
# Extract that same function in this isolated test rather than asserting obsolete colors.
$uxTokens=$null;$uxErrors=$null
$uxAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $packageRoot 'wad\modules\Domenia-UX.UI.ps1'),[ref]$uxTokens,[ref]$uxErrors)
if(@($uxErrors).Count){throw $uxErrors[0].Message}
$uxPalette=@($uxAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-DomeniaUxPalette'},$true))
if($uxPalette.Count -ne 1){throw 'Definition de palette UI absente.'}
. ([scriptblock]::Create($uxPalette[0].Extent.Text))
$script:Results=New-Object 'System.Collections.Generic.List[object]'
$script:ThemeLogs=New-Object 'System.Collections.Generic.List[string]'
$script:CaseNumber=0
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-theme-tests-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
function Write-AppLog { param($Text,$Level);[void]$script:ThemeLogs.Add([string]$Text) }
function Add-DomeniaUiLog { param($Text,$Level,$Area) }
function Save-DomeniaXamlDiagnostic { param($XamlText,$Context);return '' }
function Get-DomeniaControl {
    param($Name)
    if ($null -eq $script:Window) { return $null }
    return $script:Window.FindName([string]$Name)
}
function Assert-Theme {param([bool]$Condition,[string]$Message='Assertion fausse');if(-not $Condition){throw $Message}}
function Test-ThemeCase {
    param([string]$Name,[scriptblock]$Action)
    try { & $Action | Out-Null;$status='PASS';$detail='' }
    catch { $status='FAIL';$detail=$_.Exception.Message }
    [void]$script:Results.Add([pscustomobject]@{Name=$Name;Status=$status;Detail=$detail})
    Write-Host ("$status  $Name  $detail")
}
function Reset-TestPreferences {
    param([AllowNull()][string]$Json,[AllowNull()][string]$Legacy)
    if ($null -ne $script:SettingsTimer) { $script:SettingsTimer.Stop() }
    $script:SettingsTimer=$null;$script:BootTheme='';$script:Settings=$null;$script:CurrentTheme='Light'
    $script:Window=$null;$script:CaseNumber++
    $script:RootDir=Join-Path $testRoot ('case-'+$script:CaseNumber)
    $script:DataDir=Join-Path $script:RootDir 'data'
    [void][IO.Directory]::CreateDirectory($script:DataDir)
    if (-not [string]::IsNullOrEmpty($Json)) { [IO.File]::WriteAllText((Join-Path $script:DataDir 'Domenia.settings.json'),$Json) }
    if (-not [string]::IsNullOrEmpty($Legacy)) { [IO.File]::WriteAllText((Join-Path $script:RootDir 'Domenia.theme.cfg'),$Legacy) }
}
function Get-TestBrushHex {
    param($Brush)
    if ($Brush -isnot [Windows.Media.SolidColorBrush]) { throw 'Pinceau opaque SolidColorBrush attendu.' }
    $c=$Brush.Color
    if ($c.A -ne 255) { throw 'Pinceau opaque attendu.' }
    return ('#{0:X2}{1:X2}{2:X2}' -f $c.R,$c.G,$c.B)
}
function Get-TestLuminance {
    param([string]$Hex)
    $channels=@(1,3,5 | ForEach-Object {
        $v=[Convert]::ToInt32($Hex.Substring($_,2),16)/255.0
        if ($v -le 0.04045) { $v/12.92 } else { [Math]::Pow(($v+0.055)/1.055,2.4) }
    })
    return 0.2126*$channels[0]+0.7152*$channels[1]+0.0722*$channels[2]
}
function Assert-TestContrast {
    param($Control,$FallbackBackground,[string]$Name)
    $fg=Get-TestBrushHex $Control.Foreground
    $brush=$null
    # A CheckBox or RadioButton Background fills the small glyph box; its label is drawn on the surface behind it.
    if ($null -ne $Control.PSObject.Properties['Background'] -and -not ($Control -is [Windows.Controls.CheckBox] -or $Control -is [Windows.Controls.RadioButton])) { $brush=$Control.Background }
    if ($brush -isnot [Windows.Media.SolidColorBrush] -or $brush.Color.A -ne 255) { $brush=$FallbackBackground }
    $bg=Get-TestBrushHex $brush
    $a=Get-TestLuminance $fg;$b=Get-TestLuminance $bg
    $ratio=([Math]::Max($a,$b)+0.05)/([Math]::Min($a,$b)+0.05)
    Assert-Theme ($ratio -ge 4.5) ("$Name : $fg/$bg, contraste $ratio inferieur a 4.5:1.")
}
try {
    foreach($case in @(
        @{Name='JSON Dark prioritaire sur ancien Light';Json='{"Theme":"Dark"}';Legacy='Light';Expected='Dark'},
        @{Name='JSON Light prioritaire sur ancien Dark';Json='{"Theme":"Light"}';Legacy='Dark';Expected='Light'},
        @{Name='Migration sans JSON';Json='';Legacy='Dark';Expected='Dark'},
        @{Name='Theme invalide : repli historique';Json='{"Theme":"Sepia"}';Legacy='Dark';Expected='Dark'},
        @{Name='JSON illisible : repli historique';Json='{invalide';Legacy='Dark';Expected='Dark'},
        @{Name='Aucun reglage : Light';Json='';Legacy='';Expected='Light'},
        @{Name='Theme avec espaces et casse : canonicalise';Json='{"Theme":" dark "}';Legacy='Light';Expected='Dark'}
    )) {
        Test-ThemeCase $case.Name {
            Reset-TestPreferences $case.Json $case.Legacy
            Assert-Theme ((Get-DomeniaStoredTheme) -ceq $case.Expected) 'Choix du login incorrect.'
            [void](Load-DomeniaSettings)
            Assert-Theme ((Load-DomeniaTheme) -ceq $case.Expected) 'Choix principal different du login.'
        }
    }
    Test-ThemeCase 'JSON casse avec copie .bak valide' {
        Reset-TestPreferences '{invalide' 'Light'
        [IO.File]::WriteAllText((Join-Path $script:DataDir 'Domenia.settings.json.bak'),'{"Theme":"Dark"}')
        Assert-Theme ((Get-DomeniaStoredTheme) -eq 'Dark')
        [void](Load-DomeniaSettings);Assert-Theme ($script:CurrentTheme -eq 'Dark')
    }
    Test-ThemeCase 'Sauvegarde immediate Dark, cache de session et relecture a froid' {
        Reset-TestPreferences '{"Theme":"Light","LogHeight":260}' 'Light'
        [void](Load-DomeniaSettings);Save-DomeniaTheme -Theme Dark
        $stored=Get-Content -LiteralPath (Join-Path $script:DataDir 'Preferences\Domenia.settings.json') -Raw | ConvertFrom-Json
        Assert-Theme ($stored.Theme -eq 'Dark' -and $stored.LogHeight -eq 260) 'Sauvegarde immediate incorrecte.'
        Assert-Theme ((Get-DomeniaStoredTheme) -eq 'Dark') 'Cache de theme obsolete.'
        $script:BootTheme='';$script:Settings=$null;$script:CurrentTheme='Light'
        Assert-Theme ((Get-DomeniaStoredTheme) -eq 'Dark')
        [void](Load-DomeniaSettings);Assert-Theme ((Load-DomeniaTheme) -eq 'Dark')
    }
    Test-ThemeCase 'Retour Light avec ancien Dark : relecture a froid' {
        Reset-TestPreferences '{"Theme":"Dark"}' 'Dark'
        [void](Load-DomeniaSettings);Save-DomeniaTheme -Theme Light
        $script:BootTheme='';$script:Settings=$null;$script:CurrentTheme='Dark'
        Assert-Theme ((Get-DomeniaStoredTheme) -eq 'Light')
        [void](Load-DomeniaSettings);Assert-Theme ((Load-DomeniaTheme) -eq 'Light')
    }
    Test-ThemeCase 'Sauvegarde isolee conserve les autres reglages' {
        Reset-TestPreferences '{"Theme":"Light","LogHeight":275,"WindowWidth":1500}' 'Light'
        Save-DomeniaTheme -Theme Dark
        $stored=Get-Content -LiteralPath (Join-Path $script:DataDir 'Preferences\Domenia.settings.json') -Raw | ConvertFrom-Json
        Assert-Theme ($stored.Theme -eq 'Dark' -and $stored.LogHeight -eq 275 -and $stored.WindowWidth -eq 1500)
    }
    foreach($theme in @('Light','Dark')) {
        foreach($factory in @('Get-DomeniaStandardLoginXaml','Get-DomeniaStartupXaml')) {
            Test-ThemeCase ("XML reel PowerShell : $theme / $factory") {
                $script:BootTheme=$theme
                $text=& $factory
                Assert-DomeniaXamlPreflight -XamlText $text -Context $factory
                [xml]$document=$text
                Assert-Theme ($document.DocumentElement.LocalName -eq 'Window')
            }
            if (-not $Wpf) { continue }
            Test-ThemeCase ("WPF reel : $theme / $factory") {
                $script:BootTheme=$theme;$window=$null
                try {
                    $window=ConvertFrom-DomeniaXaml -XamlText (& $factory) -Context $factory
                    [void]$window.ApplyTemplate();$window.UpdateLayout()
                    $palette=Get-DomeniaBootThemePalette -Theme $theme
                    Assert-Theme ((Get-TestBrushHex $window.Background) -eq $palette.Window)
                    Assert-Theme ((Get-TestBrushHex $window.Foreground) -eq $palette.Text)
                    foreach($name in @('TxtLogin','PwdLogin','TxtLoginTechnical','LblLoginError','LblLoginStage','ChkRemember',
                        'BtnLogin','BtnCancel','BtnWindowsLogin','LblStartupStage','TxtStartupDetail','LblStartupElapsed','BtnStartupLog','BtnStartupCancel')) {
                        $control=$window.FindName($name)
                        if ($null -eq $control) { continue }
                        [void]$control.ApplyTemplate()
                        Assert-TestContrast $control $window.Resources['DomeniaBootSurface'] $name
                    }
                    $errorLabel=$window.FindName('LblLoginError')
                    if ($null -ne $errorLabel) {
                        foreach($kind in @('Muted','Error','Warning','Success')) {
                            $errorLabel.Foreground=Get-DomeniaBootStatusColor -Kind $kind
                            Assert-TestContrast $errorLabel $window.Resources['DomeniaBootSurface'] $kind
                        }
                    }
                }
                finally { if ($null -ne $window) { $window.Close() } }
            }
        }
    }
    if ($Wpf) {
        Test-ThemeCase 'Principale : Dark restaure sans modifier le fichier de preferences' {
            Reset-TestPreferences '{"Theme":"Dark"}' 'Light'
            [void][IO.Directory]::CreateDirectory((Join-Path $script:DataDir 'Preferences'))
            $path=Join-Path $script:DataDir 'Preferences\Domenia.settings.json'
            [IO.File]::Copy((Join-Path $script:DataDir 'Domenia.settings.json'),$path)
            $before=[IO.File]::ReadAllText($path)
            try {
                $script:Window=ConvertFrom-DomeniaXaml -XamlText (Get-MainXaml) -Context 'Principale themes'
                Apply-DomeniaTheme -Theme (Get-DomeniaStoredTheme)
                [void](Load-DomeniaSettings);[void](Load-DomeniaTheme)
                Apply-DomeniaTheme -Theme $script:CurrentTheme
                Assert-Theme ((Get-TestBrushHex $script:Window.Background) -eq (Get-SuitePalette Dark).WindowBg)
                Assert-Theme ((Get-TestBrushHex $script:Window.Foreground) -eq (Get-SuitePalette Dark).TextColor)
                Assert-Theme ([IO.File]::ReadAllText($path) -ceq $before) 'La restauration a reecrit les preferences.'
                Toggle-DomeniaTheme
                Assert-Theme ((Get-TestBrushHex $script:Window.Background) -eq (Get-SuitePalette Light).WindowBg)
                Assert-Theme ((Get-DomeniaStoredTheme) -eq 'Light')
                Assert-Theme ((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).Theme -eq 'Light')
                Toggle-DomeniaTheme
                Assert-Theme ((Get-TestBrushHex $script:Window.Background) -eq (Get-SuitePalette Dark).WindowBg)
                Assert-Theme ((Get-DomeniaStoredTheme) -eq 'Dark')
                Assert-Theme ((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).Theme -eq 'Dark')
            }
            finally { if ($null -ne $script:Window) { $script:Window.Close();$script:Window=$null } }
        }
    }
}
finally {
    if ($null -ne $script:SettingsTimer) { $script:SettingsTimer.Stop() }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
$passed=@($script:Results | Where-Object {$_.Status -eq 'PASS'}).Count
$failed=@($script:Results | Where-Object {$_.Status -eq 'FAIL'}).Count
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-themes-'+(Get-Date).ToString('yyyyMMdd-HHmmss')+'.json')
}
$report=[ordered]@{Build='2026.09.30-R1.11-SUITE';PowerShell=[string]$PSVersionTable.PSVersion;WpfRequested=[bool]$Wpf;ActiveDirectoryExecuted=$false;Passed=$passed;Failed=$failed;Results=$script:Results.ToArray();Logs=$script:ThemeLogs.ToArray()}
$fullReport=[IO.Path]::GetFullPath($ReportPath)
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullReport))
[IO.File]::WriteAllText($fullReport,($report | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
Write-Host "`r`n$passed PASS / $failed FAIL. Rapport : $fullReport"
if ($failed -gt 0) { exit 1 }
exit 0
