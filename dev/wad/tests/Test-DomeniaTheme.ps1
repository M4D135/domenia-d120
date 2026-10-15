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
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
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
    # FO-22: stored choice (Light, Dark, Auto), Windows choice read in HKCU, explicit choice of the menu.
    'Get-DomeniaThemePreference','Get-DomeniaWindowsAppTheme','Set-DomeniaThemePreference',
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
# FO-22: the toggle texts come from Get-DomeniaThemeToggleIcon (Shell.Model).
. (Join-Path $packageRoot 'wad\modules\Domenia-Shell.Model.ps1')
foreach($uxName in @('Set-DomeniaUxPalette','Set-DomeniaWindowFrameTheme','Update-DomeniaUxThemeToggle','Get-DomeniaSystemColorTable','Get-DomeniaSystemColorSignature','Update-DomeniaAutoTheme')) {
    $uxPalette=@($uxAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $uxName},$true))
    if($uxPalette.Count -ne 1){throw ('Definition UI absente : '+$uxName)}
    . ([scriptblock]::Create($uxPalette[0].Extent.Text))
}
# DS-18: the title bar interop is compiled with the identity types, as Domenia-Modules.ps1 does at start-up.
if($null -eq ('Domenia.SelectionIdentity' -as [type])){Add-Type -Path (Join-Path $packageRoot 'wad\modules\Domenia-Identity.Types.cs')}
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
    $script:SettingsTimer=$null;$script:BootTheme='';$script:ThemePreference='';$script:Settings=$null;$script:CurrentTheme='Light'
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
    Test-ThemeCase 'FO-22 : choix de Windows lu dans HKCU, en lecture seule' {
        $windows=Get-DomeniaWindowsAppTheme
        Assert-Theme ($windows -in @('','Light','Dark')) ('Valeur inattendue : '+$windows)
        $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Themes\Personalize',$false)
        $expected=''
        if($null -ne $key){try{$raw=$key.GetValue('AppsUseLightTheme',$null);if($null -ne $raw){$expected=if([int]$raw -eq 0){'Dark'}else{'Light'}}}finally{$key.Close()}}
        Assert-Theme ($windows -ceq $expected) ('Lecture differente du registre : '+$windows+' / '+$expected)
    }
    foreach($case in @(
        @{Name='Auto suit Windows sombre';Json='{"Theme":"Auto"}';Windows='Dark';Expected='Dark'},
        @{Name='Auto suit Windows clair';Json='{"Theme":"Auto"}';Windows='Light';Expected='Light'},
        @{Name='Auto sans choix Windows lisible : Light';Json='{"Theme":" auto "}';Windows='';Expected='Light'},
        @{Name='Choix fixe ignore Windows';Json='{"Theme":"Light"}';Windows='Dark';Expected='Light'}
    )) {
        Test-ThemeCase ('FO-22 : '+$case.Name) {
            Reset-TestPreferences $case.Json 'Dark'
            $script:FakeWindowsTheme=$case.Windows
            function Get-DomeniaWindowsAppTheme { return [string]$script:FakeWindowsTheme }
            Assert-Theme ((Get-DomeniaStoredTheme) -ceq $case.Expected) 'Theme du login incorrect.'
            $settings=Load-DomeniaSettings
            Assert-Theme ($script:CurrentTheme -ceq $case.Expected) 'Theme de la principale incorrect.'
            $choice=ConvertTo-DomeniaThemePreference ([regex]::Match($case.Json,'"Theme":"([^"]*)"').Groups[1].Value)
            Assert-Theme ([string]$settings['Theme'] -ceq $choice) ('Choix perdu au chargement : '+[string]$settings['Theme'])
            Assert-Theme ((Load-DomeniaTheme) -ceq $case.Expected) 'Load-DomeniaTheme incoherent.'
        }
    }
    Test-ThemeCase 'FO-22 : Automatique enregistre tel quel, theme peint = choix de Windows' {
        Reset-TestPreferences '{"Theme":"Light","LogHeight":260}' 'Light'
        $script:FakeWindowsTheme='Dark'
        function Get-DomeniaWindowsAppTheme { return [string]$script:FakeWindowsTheme }
        [void](Load-DomeniaSettings);Save-DomeniaTheme -Theme Auto
        $stored=Get-Content -LiteralPath (Join-Path $script:DataDir 'Preferences\Domenia.settings.json') -Raw | ConvertFrom-Json
        Assert-Theme (($stored.Theme -eq 'Auto') -and ($stored.LogHeight -eq 260)) 'Choix Automatique non enregistre.'
        Assert-Theme (($script:CurrentTheme -eq 'Dark') -and ((Get-DomeniaStoredTheme) -eq 'Dark')) 'Theme peint different de Windows.'
        $script:BootTheme='';$script:ThemePreference='';$script:Settings=$null;$script:CurrentTheme='Light';$script:FakeWindowsTheme='Light'
        Assert-Theme ((Get-DomeniaStoredTheme) -eq 'Light') 'Relecture a froid : Windows clair non suivi.'
        Assert-Theme ((Get-DomeniaStoredTheme -Preference) -eq 'Auto') 'Relecture a froid : choix perdu.'
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
        $script:BootTheme='';$script:ThemePreference='';$script:Settings=$null;$script:CurrentTheme='Light'
        Assert-Theme ((Get-DomeniaStoredTheme) -eq 'Dark')
        [void](Load-DomeniaSettings);Assert-Theme ((Load-DomeniaTheme) -eq 'Dark')
    }
    Test-ThemeCase 'Retour Light avec ancien Dark : relecture a froid' {
        Reset-TestPreferences '{"Theme":"Dark"}' 'Dark'
        [void](Load-DomeniaSettings);Save-DomeniaTheme -Theme Light
        $script:BootTheme='';$script:ThemePreference='';$script:Settings=$null;$script:CurrentTheme='Dark'
        Assert-Theme ((Get-DomeniaStoredTheme) -eq 'Light')
        [void](Load-DomeniaSettings);Assert-Theme ((Load-DomeniaTheme) -eq 'Light')
    }
    Test-ThemeCase 'CD-05 : palette d amorcage = roles du contrat SupportSuite.UI.json, aucune copie' {
        $roles=@{Window='WindowBg';Surface='BgCard';Input='BgInput';Text='TextColor';Muted='MutedColor';Border='BorderColor';Button='BtnBg';ButtonText='BtnFg';Accent='AccentColor';AccentHover='AccentHover';AccentText='AccentText';OnAccent='OnAccent';Error='StatusError';Warning='StatusWarning';Success='StatusSuccess'}
        foreach($theme in @('Light','Dark')) {
            $boot=Get-DomeniaBootThemePalette -Theme $theme;$suite=Get-SuitePalette -Theme $theme
            Assert-Theme (@($boot.Keys).Count -eq $roles.Count) ($theme+' : nombre de roles')
            foreach($role in @($roles.Keys)) { Assert-Theme ([string]$boot[$role] -ceq [string]$suite[[string]$roles[$role]]) ($theme+' : role '+$role) }
        }
    }
    Test-ThemeCase 'FO-22 / CD-05 : demarrage refuse, theme et palette d amorcage lus par le coeur seul' {
        # The closed loader checks every module before it dot-sources one. When it refuses the start-up, the fatal report
        # (Show-ErrorBox, Show-DomeniaDialog) paints with the core alone: the stored choice, its resolution and the boot
        # palette run here in a runspace that holds no module, and must agree with the rule of Experience.Model.
        $coreOnly=(@('Get-DomeniaThemePreference','Get-DomeniaStoredTheme','Get-DomeniaBootThemePalette')|ForEach-Object{$name=$_;@($nodes|Where-Object{$_.Name -eq $name})[0].Extent.Text}) -join "`r`n"
        $probe=@'
param([string]$Definitions,[string]$Stored,[string]$Windows)
$ErrorActionPreference='Stop'
. ([scriptblock]::Create($Definitions))
function Read-DomeniaPreference {param([string]$FileName) if($FileName -eq 'Domenia.settings.json'){return ('{"Theme":"'+$Stored+'"}')};return ''}
function Get-DomeniaWindowsAppTheme {return $Windows}
$script:ThemePreference='';$script:BootTheme=''
$theme=Get-DomeniaStoredTheme
$modules=@(Get-Command -Name 'Resolve-DomeniaEffectiveTheme','ConvertTo-DomeniaThemePreference','Get-SuitePalette' -ErrorAction SilentlyContinue).Count
[pscustomobject]@{Theme=$theme;Preference=(Get-DomeniaStoredTheme -Preference);Palette=(Get-DomeniaBootThemePalette -Theme $theme);Modules=$modules}
'@
        $runspace=[runspacefactory]::CreateRunspace()
        $runspace.ApartmentState=[Threading.ApartmentState]::STA
        $runspace.ThreadOptions=[Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $runspace.Open()
        try {
            foreach($case in @(
                @{Stored='Dark';Windows='Light'},@{Stored=' auto ';Windows='Dark'},@{Stored='Auto';Windows=''},
                @{Stored='Auto';Windows='Light'},@{Stored='Sepia';Windows='Dark'}
            )) {
                $ps=[powershell]::Create();$ps.Runspace=$runspace
                try {
                    $out=@($ps.AddScript($probe).AddParameter('Definitions',$coreOnly).AddParameter('Stored',$case.Stored).AddParameter('Windows',$case.Windows).Invoke())
                    Assert-Theme (($ps.Streams.Error.Count -eq 0) -and ($out.Count -eq 1)) ('Coeur seul ('+$case.Stored+') : '+(@($ps.Streams.Error|ForEach-Object{[string]$_}) -join ' | '))
                    $result=$out[0]
                    Assert-Theme ([int]$result.Modules -eq 0) 'Le banc isole voit une fonction de module'
                    $rule=Resolve-DomeniaEffectiveTheme -Preference $case.Stored -WindowsTheme $case.Windows
                    Assert-Theme ([string]$result.Theme -ceq [string]$rule.Theme) ('Theme du coeur ('+$case.Stored+'/'+$case.Windows+') : '+[string]$result.Theme+' au lieu de '+[string]$rule.Theme)
                    Assert-Theme ([string]$result.Preference -ceq [string]$rule.Preference) ('Choix du coeur ('+$case.Stored+') : '+[string]$result.Preference)
                    $palette=$result.Palette
                    Assert-Theme ((@($palette.Keys).Count -eq 15) -and (@(@($palette.Values)|Where-Object{[string]$_ -notmatch '^#[0-9A-Fa-f]{6}$'}).Count -eq 0)) 'Palette d amorcage incomplete sans contrat'
                }
                finally { $ps.Dispose() }
            }
        }
        finally { $runspace.Close();$runspace.Dispose() }
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
        Test-ThemeCase 'DS-14 : parts categorielles en pastel du JSON, contour plus fonce en clair, aucun en sombre' {
            foreach($module in @('Domenia-HealthRules.Model.ps1','Domenia-Boards.Model.ps1','Domenia-Charts.UI.ps1')) { . (Join-Path $packageRoot ('wad\modules\'+$module)) }
            $script:DomeniaReduceMotion=$true
            $items=@([pscustomobject]@{Label='Adobe';Value=5},[pscustomobject]@{Label='Autre editeur';Value=3},[pscustomobject]@{Label='Libre';Value=2;Color=(Get-DomeniaBoardColor 'Ok')})
            foreach($theme in @('Light','Dark')) {
                $script:CurrentTheme=$theme;$script:DomeniaPaintedPalette=Get-SuitePalette -Theme $theme
                $series=@(Get-DomeniaChartSeries -Theme $theme)
                $donut=New-DomeniaDonutChart -Title 'Editeurs' -Items $items -Width 340 -Height 240
                $paths=New-Object 'System.Collections.Generic.List[object]'
                $queue=New-Object 'System.Collections.Generic.Queue[object]';$queue.Enqueue($donut)
                while($queue.Count){$node=$queue.Dequeue();if($node -is [Windows.Shapes.Path]){$paths.Add($node)};foreach($child in @([Windows.LogicalTreeHelper]::GetChildren($node))){if($child -is [Windows.DependencyObject]){$queue.Enqueue($child)}}}
                $segments=@($paths|Where-Object{$null -ne $_.Tag})
                $outlines=@($paths|Where-Object{($null -eq $_.Tag) -and $_.IsHitTestVisible -eq $false})
                Assert-Theme ($segments.Count -eq 3) ($theme+' : trois parts attendues')
                Assert-Theme ((Get-TestBrushHex $segments[0].Stroke) -eq $series[0].Fill) ($theme+' : premiere part hors serie')
                Assert-Theme ((Get-TestBrushHex $segments[2].Stroke) -eq (Get-DomeniaThemeColor -Key 'StateOk' -Theme $theme)) ($theme+' : couleur d etat perdue')
                if($theme -eq 'Light'){
                    Assert-Theme ($outlines.Count -eq 2) ('Clair : un contour par part categorielle, aucun pour l etat ('+$outlines.Count+')')
                    Assert-Theme ((Get-TestBrushHex $outlines[0].Stroke) -eq $series[0].Edge) 'Clair : contour de la premiere serie'
                } else {
                    Assert-Theme ($outlines.Count -eq 0) 'Sombre : les pastels atteignent 3:1 sans contour'
                }
            }
            $script:CurrentTheme='Light';$script:DomeniaPaintedPalette=$null
        }
        Test-ThemeCase 'DS-11 : bouton desactive lisible (4,5:1), plein ou neutre ; Arreter cache sans travail' {
            $script:Window=$null
            try {
                $script:Window=ConvertFrom-DomeniaXaml -XamlText (Get-MainXaml) -Context 'DS-11'
                $panel=$script:Window.FindName('UxHeaderTools')
                foreach($theme in @('Light','Dark')) {
                    Apply-DomeniaTheme -Theme $theme
                    $palette=Get-SuitePalette -Theme $theme
                    foreach($styleKey in @('RunButton','DangerButton','SecondaryButton','BaseButton','UxNavArrowButton')) {
                        $button=[Windows.Controls.Button]::new();$button.Content='Essai';$button.Style=$script:Window.Resources[$styleKey];$button.IsEnabled=$false
                        [void]$panel.Children.Add($button);[void]$button.ApplyTemplate()
                        $border=$button.Template.FindName('Bd',$button)
                        $fg=Get-TestBrushHex $button.Foreground;$bg=Get-TestBrushHex $border.Background
                        Assert-Theme ($fg -eq $palette.MutedColor) ($theme+' '+$styleKey+' : texte '+$fg)
                        Assert-Theme ($bg -eq $palette.BgReadonly) ($theme+' '+$styleKey+' : fond '+$bg)
                        $a=Get-TestLuminance $fg;$b=Get-TestLuminance $bg
                        Assert-Theme ((([Math]::Max($a,$b)+0.05)/([Math]::Min($a,$b)+0.05)) -ge 4.5) ($theme+' '+$styleKey+' : contraste')
                        $button.IsEnabled=$true
                        Assert-Theme ((Get-TestBrushHex $button.Foreground) -ne $palette.MutedColor) ($theme+' '+$styleKey+' : texte actif')
                        [void]$panel.Children.Remove($button)
                    }
                    foreach($name in @('BtnSearchRefreshStop','BtnFleetRefreshStop','BtnComputerParkStop')) {
                        $stop=$script:Window.FindName($name)
                        Assert-Theme ($stop.Visibility -eq [Windows.Visibility]::Hidden) ($theme+' : '+$name+' visible sans travail')
                        $stop.IsEnabled=$true
                        Assert-Theme ($stop.Visibility -eq [Windows.Visibility]::Visible) ($name+' cache pendant un travail')
                        $stop.IsEnabled=$false
                    }
                }
            }
            finally { if ($null -ne $script:Window) { $script:Window.Close();$script:Window=$null } }
        }
        Test-ThemeCase 'DS-18 : barre de titre sombre (DWM) et barres de defilement fines sans fleches' {
            Assert-Theme (-not [Domenia.WindowFrame]::SetDarkTitleBar([IntPtr]::Zero,$true)) 'Fenetre absente acceptee'
            $script:Window=$null
            try {
                $script:Window=ConvertFrom-DomeniaXaml -XamlText (Get-MainXaml) -Context 'DS-18'
                $script:Window.ShowInTaskbar=$false
                Apply-DomeniaTheme -Theme Dark
                Assert-Theme ([string]$script:Window.Resources['Domenia.FrameTheme'] -eq 'Dark') 'Theme de la barre non retenu avant la creation de la fenetre'
                Assert-Theme ([bool]$script:Window.Resources['Domenia.FrameHooked']) 'Application differee non branchee'
                $handle=[Windows.Interop.WindowInteropHelper]::new($script:Window).EnsureHandle()
                Assert-Theme ($handle -ne [IntPtr]::Zero) 'Fenetre sans handle'
                $build=[Environment]::OSVersion.Version.Build
                if($build -ge 17763){
                    Assert-Theme (Set-DomeniaWindowFrameTheme -Window $script:Window -Theme Dark) ('DWM refuse la barre sombre (build '+$build+')')
                    Assert-Theme (Set-DomeniaWindowFrameTheme -Window $script:Window -Theme Light) 'DWM refuse le retour a la barre claire'
                }
                $style=$script:Window.Resources[[Windows.Controls.Primitives.ScrollBar]]
                Assert-Theme ($null -ne $style) 'Style ScrollBar absent'
                $width=@($style.Setters|Where-Object{$_.Property.Name -eq 'Width'})[0].Value
                Assert-Theme ([double]$width -le 8) ('Barre verticale trop large : '+$width)
                $scroll=[Windows.Controls.ScrollViewer]::new();$scroll.Width=200;$scroll.Height=100;$scroll.VerticalScrollBarVisibility='Visible';$scroll.HorizontalScrollBarVisibility='Visible'
                $scroll.Content=[Windows.Controls.Border]::new();$scroll.Content.Width=600;$scroll.Content.Height=600
                $panel=$script:Window.FindName('UxHeaderTools');[void]$panel.Children.Add($scroll)
                $script:Window.Measure([Windows.Size]::new(1600,960));$script:Window.Arrange([Windows.Rect]::new(0,0,1600,960));$script:Window.UpdateLayout()
                [void]$scroll.ApplyTemplate()
                $bars=@($scroll.Template.FindName('PART_VerticalScrollBar',$scroll),$scroll.Template.FindName('PART_HorizontalScrollBar',$scroll))
                foreach($bar in $bars){
                    Assert-Theme ($null -ne $bar) 'Barre de defilement absente'
                    [void]$bar.ApplyTemplate()
                    $repeat=@($bar.Template.FindName('PART_Track',$bar).DecreaseRepeatButton)[0]
                    Assert-Theme (($repeat.Command -ne [Windows.Controls.Primitives.ScrollBar]::LineUpCommand) -and ($repeat.Command -ne [Windows.Controls.Primitives.ScrollBar]::LineLeftCommand)) 'Fleches de defilement presentes'
                }
                Assert-Theme ($bars[0].ActualWidth -le 8.5) ('Largeur reelle : '+$bars[0].ActualWidth)
                Assert-Theme ($bars[1].ActualHeight -le 8.5) ('Hauteur reelle : '+$bars[1].ActualHeight)
                [void]$panel.Children.Remove($scroll)
            }
            finally { if ($null -ne $script:Window) { $script:Window.Close();$script:Window=$null } }
        }
        Test-ThemeCase 'FO-22 : menu Automatique, retour sur la fenetre et bouton de theme' {
            Reset-TestPreferences '{"Theme":"Light"}' 'Light'
            $script:FakeWindowsTheme='Dark'
            function Get-DomeniaWindowsAppTheme { return [string]$script:FakeWindowsTheme }
            function Set-Status { param($Text,$Level) $script:LastStatus=[string]$Text }
            try {
                $script:Window=ConvertFrom-DomeniaXaml -XamlText (Get-MainXaml) -Context 'FO-22'
                [void](Load-DomeniaSettings);Apply-DomeniaTheme -Theme (Get-DomeniaStoredTheme)
                Set-DomeniaThemePreference -Preference Auto
                Assert-Theme ((Get-TestBrushHex $script:Window.Background) -eq (Get-SuitePalette Dark).WindowBg) 'Automatique ne suit pas Windows sombre'
                $toggle=$script:Window.FindName('BtnThemeToggle')
                Assert-Theme ([string]$toggle.ToolTip -match 'automatique') ('Infobulle : '+[string]$toggle.ToolTip)
                $script:FakeWindowsTheme='Light'
                Update-DomeniaAutoTheme
                Assert-Theme ((Get-TestBrushHex $script:Window.Background) -eq (Get-SuitePalette Light).WindowBg) 'Retour sur la fenetre : Windows clair non suivi'
                Assert-Theme ($script:ThemePreference -eq 'Auto') 'Le retour sur la fenetre a change le choix'
                Toggle-DomeniaTheme
                Assert-Theme (($script:ThemePreference -eq 'Dark') -and ($script:CurrentTheme -eq 'Dark')) 'Le clic ne fixe pas le theme oppose'
                $script:FakeWindowsTheme='Light';Update-DomeniaAutoTheme
                Assert-Theme ($script:CurrentTheme -eq 'Dark') 'Un choix fixe suit Windows'
            }
            finally { if ($null -ne $script:Window) { $script:Window.Close();$script:Window=$null } }
        }
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
                # CD-05: every token of the contract is painted, and only from it.
                foreach($token in @((Get-SuitePalette Dark).GetEnumerator())) {
                    Assert-Theme ((Get-TestBrushHex $script:Window.Resources[[string]$token.Key]) -eq [string]$token.Value) ('Jeton peint : '+$token.Key)
                }
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
