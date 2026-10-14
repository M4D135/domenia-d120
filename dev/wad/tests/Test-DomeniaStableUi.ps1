#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet)
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot
# D082/D085: counters and selection preview come from the shell rules (and their dependencies).
. (Join-Path $wad 'modules\Domenia-Common.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Relations.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Access.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Shell.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Embedded.UI.ps1')
$script:Checks=[Collections.Generic.List[object]]::new()
$script:Traces=[Collections.Generic.List[object]]::new()
$script:TestControls=@{}
$script:TestTheme='Light'
function Expect {param([bool]$Value,[string]$Why='Condition non verifiee');if(-not $Value){throw $Why}}
function Case {param([string]$Name,[scriptblock]$Body)
    try{& $Body|Out-Null;$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$true;Detail=''})}
    catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Detail=$_.Exception.Message})}
}
function Parse-Source {param([string]$Path)
    $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e)
    if(@($e).Count){throw ($Path+': '+$e[0].Message)}
    return $ast
}
function Import-TestFunction {param($Ast,[string]$Name)
    $matches=@($Ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
    if($matches.Count -ne 1){throw ('Fonction absente/ambigue : '+$Name)}
    $source=$matches[0].Extent.Text -replace ('^function\s+'+[regex]::Escape($Name)+'\b'),('function script:'+$Name)
    . ([scriptblock]::Create($source))
}
# Fixed doubles. None authenticates, reads AD, opens the real cache or saves preferences.
function Get-DomeniaStoredTheme {return $script:TestTheme}
function Get-DomeniaControl {param([string]$Name);return $script:TestControls[$Name]}
function Write-StartupTrace {param($Stage,$Status,$Detail,$DurationMs);$script:Traces.Add([pscustomobject]@{Stage=$Stage;Detail=$Detail;Status=$Status})}
function Get-CfgValue {param($Section,$Key,$Default);return $Default}
function Get-DomeniaProcessWindowsIdentity {return 'EXAMPLE\demo'}
function Initialize-DomeniaExperienceLogin {param($Window)}
function Set-AppWindowIcon {param($Window)}
function Set-DomeniaGridRows {param($Name,$Rows,$KeyProperty);throw 'La page Operations ne doit pas etre reconstruite depuis le compteur.'}
function Pump-Layout {param($Window)
    $Window.UpdateLayout()
    $Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
    $Window.UpdateLayout()
}
function Load-TestWindow {param([string]$Xaml)
    $reader=[Xml.XmlNodeReader]::new([xml]$Xaml)
    try{return [Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
}
function Get-HeaderGeometry {param($Window)
    $values=[Collections.Generic.List[double]]::new()
    foreach($name in @('TxtGlobalSearch','BtnGlobalSearch','BtnAccessRecovery','BtnSuiteActivity','BtnCommandPalette','BtnThemeToggle','BtnUxHelpToggle')){
        $control=$Window.FindName($name);$point=$control.TranslatePoint([Windows.Point]::new(0,0),$Window)
        $values.Add($point.X);$values.Add($point.Y);$values.Add($control.ActualWidth);$values.Add($control.ActualHeight)
    }
    return ,$values.ToArray()
}
function Expect-SameGeometry {param($Before,$After)
    Expect ($Before.Count -eq $After.Count)
    for($i=0;$i -lt $Before.Count;$i++){Expect ([Math]::Abs($Before[$i]-$After[$i]) -le 0.5) ('Disposition deplacee : valeur '+$i)}
}
try {
    Case 'Hote Windows PowerShell 5.1 x64 STA' {
        Expect ($PSVersionTable.PSEdition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and [Environment]::Is64BitProcess -and [Threading.Thread]::CurrentThread.ApartmentState -eq 'STA')
    }
    if(-not $script:Checks[0].Passed){throw 'Hote Windows requis.'}
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
    Case 'Analyse native du runtime et extraction sans bootstrap' {
        foreach($p in @((Join-Path $wad 'Domenia-Core.ps1'),(Join-Path $wad 'Domenia-Modules.ps1'),(Join-Path $wad 'Domenia-Start.ps1'))+@(Get-ChildItem -LiteralPath (Join-Path $wad 'modules') -Filter '*.ps1' -File|ForEach-Object{$_.FullName})){
            $null=Parse-Source $p
        }
        $ast=Parse-Source (Join-Path $wad 'Domenia-Core.ps1')
        foreach($name in @('Get-MainXaml','Get-DomeniaStandardLoginXaml','Get-DomeniaBootThemePalette','Get-DomeniaBootThemeResources','Convert-DomeniaXamlToBootTheme','Get-DomeniaFastLoginVaultIdentity','Update-DomeniaFastLoginVaultUi','Set-DomeniaFastLoginBusy','Add-DomeniaFastLoginDetail')){Import-TestFunction $ast $name}
        $ast=Parse-Source (Join-Path $wad 'modules\Domenia-UX.UI.ps1')
        Import-TestFunction $ast 'Initialize-DomeniaUxLoginPresentation'
        $ast=Parse-Source (Join-Path $wad 'modules\Domenia-Experience.UI.ps1')
        Import-TestFunction $ast 'Update-DomeniaExperienceActivity'
        $ast=Parse-Source (Join-Path $wad 'modules\Domenia-Access.UI.ps1')
        Import-TestFunction $ast 'Update-DomeniaAccessButton'
        # Theme helpers only; definition-only model, no functions invoked to mutate settings.
        . (Join-Path $wad 'modules\Domenia-Experience.Model.ps1')
    }
    if(-not $script:Checks[1].Passed){throw 'Extraction du code en echec.'}
    # Functions in this model have script scope only when imported from here.
    . (Join-Path $wad 'modules\Domenia-Experience.Model.ps1')
    foreach($theme in @('Light','Dark')) {
        $script:TestTheme=$theme;$w=$null
        try {
            $w=Load-TestWindow (Get-DomeniaStandardLoginXaml);$w.Title='DOMENIA TEST LOCAL : LOGIN SANS AD'
            Initialize-DomeniaUxLoginPresentation $w
            $script:TestCancels=0;$script:TestDiagnosticClicks=0
            $script:FastLoginUi=@{Window=$w}
            foreach($pair in @(@('Login','TxtLogin'),@('Password','PwdLogin'),@('PasswordVisible','TxtLoginPasswordVisible'),@('Reveal','BtnRevealLogin'),@('Remember','ChkRemember'),@('Connect','BtnLogin'),@('Windows','BtnWindowsLogin'),@('Cancel','BtnCancel'),@('Progress','PbLogin'),@('Technical','TxtLoginTechnical'))){$script:FastLoginUi[$pair[0]]=$w.FindName($pair[1])}
            $w.FindName('BtnCancel').Add_Click({$script:TestCancels++;Set-DomeniaFastLoginBusy $false})
            $w.FindName('BtnCopyLoginDiag').Add_Click({$script:TestDiagnosticClicks++})
            $w.Show();Pump-Layout $w
            $size=@($w.ActualWidth,$w.ActualHeight)
            Case ($theme+' : formulaire FILPRO sans mini-journal au repos') {
                Expect ($w.Width -eq 480 -and $w.FindName('TxtLogin').ActualHeight -ge 40 -and $w.FindName('PwdLogin').ActualHeight -ge 40)
                Expect (-not $w.FindName('UxLoginFeedback').IsVisible -and -not $w.FindName('TxtLoginTechnical').IsVisible -and -not $w.FindName('PanelSplash').IsVisible)
            }
            Case ($theme+' : journal en memoire invisible avant validation') {
                Add-DomeniaFastLoginDetail ('TRACE_TEST_INIT_'+('x'*1500));Pump-Layout $w
                Expect ($w.FindName('TxtLoginTechnical').Text.Contains('TRACE_TEST_INIT_'))
                Expect (-not $w.FindName('TxtLoginTechnical').IsVisible -and -not $w.FindName('LblLoginStage').IsVisible)
                Expect-SameGeometry $size @($w.ActualWidth,$w.ActualHeight)
            }
            Case ($theme+' : attente dans la meme fenetre sans agrandissement') {
                $w.FindName('LblLoginError').Text='Verification du compte administrateur.'
                Set-DomeniaFastLoginBusy $true;Pump-Layout $w
                Expect ($w.FindName('PanelSplash').IsVisible -and -not $w.FindName('PanelLogin').IsVisible -and $w.FindName('PbLogin').IsVisible)
                Expect ($w.FindName('PbLogin').IsIndeterminate -and -not $w.FindName('UxLoginFeedback').IsVisible)
                Expect-SameGeometry $size @($w.ActualWidth,$w.ActualHeight)
            }
            Case ($theme+' : cent changements internes sans log visible ni saut') {
                for($i=0;$i -lt 100;$i++){
                    $w.FindName('LblLoginStage').Text=('ETAPE_INTERNE_'+$i+('d'*800))
                    Add-DomeniaFastLoginDetail ('TRACE_TEST_'+$i+('x'*1000))
                    Pump-Layout $w
                    Expect-SameGeometry $size @($w.ActualWidth,$w.ActualHeight)
                    Expect (-not $w.FindName('TxtLoginTechnical').IsVisible -and -not $w.FindName('LblLoginStage').IsVisible)
                }
                Expect ($w.FindName('LblLoginWait').Text -eq 'Vérification du compte…')
            }
            Case ($theme+' : erreur lisible, commandes de diagnostic disponibles') {
                $w.FindName('LblLoginError').Text='Refus fictif. Aucun compte valide.'
                Set-DomeniaFastLoginBusy $false;Pump-Layout $w
                Expect ($w.FindName('PanelLogin').IsVisible -and $w.FindName('LblLoginError').IsVisible -and $w.FindName('BtnLoginLog').IsVisible -and $w.FindName('BtnCopyLoginDiag').IsVisible)
                Expect (-not $w.FindName('PanelSplash').IsVisible -and -not $w.FindName('TxtLoginTechnical').IsVisible)
            }
            Case ($theme+' : diagnostic seulement sur action volontaire') {
                Expect ($script:TestDiagnosticClicks -eq 0)
                $w.FindName('BtnCopyLoginDiag').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                Expect ($script:TestDiagnosticClicks -eq 1 -and -not $w.FindName('TxtLoginTechnical').IsVisible)
            }
            Case ($theme+' : nouvel essai masque aussi les erreurs precedentes') {
                $script:RetrySize=@($w.ActualWidth,$w.ActualHeight)
                Set-DomeniaFastLoginBusy $true;Pump-Layout $w
                Expect (-not $w.FindName('UxLoginFeedback').IsVisible -and -not $w.FindName('UxLoginDiagnostics').IsVisible -and -not $w.FindName('TxtLoginTechnical').IsVisible)
                Expect-SameGeometry $script:RetrySize @($w.ActualWidth,$w.ActualHeight)
            }
            Case ($theme+' : confirmation de succes ne revele pas de mini-log') {
                $w.FindName('LblLoginError').Text='Compte valide.';$w.FindName('LblLoginStage').Text='Connexion terminee en 1.5 s.'
                Add-DomeniaFastLoginDetail 'COMPTE_TEST_VALIDE';Pump-Layout $w
                Expect ($w.FindName('PanelSplash').IsVisible -and -not $w.FindName('LblLoginError').IsVisible -and -not $w.FindName('TxtLoginTechnical').IsVisible)
                Expect-SameGeometry $script:RetrySize @($w.ActualWidth,$w.ActualHeight)
            }
            Case ($theme+' : annuler attente rejoint le gestionnaire existant') {
                $before=$script:TestCancels
                $w.FindName('BtnLoginWaitCancel').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));Pump-Layout $w
                Expect ($script:TestCancels -eq $before+1 -and $w.FindName('PanelLogin').IsVisible -and $w.FindName('BtnLogin').IsEnabled)
            }
            Case ($theme+' : Echap rejoint aussi une seule annulation') {
                Set-DomeniaFastLoginBusy $true;Pump-Layout $w;$before=$script:TestCancels
                $key=[Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice,[Windows.PresentationSource]::FromVisual($w),0,[Windows.Input.Key]::Escape)
                $key.RoutedEvent=[Windows.Input.Keyboard]::PreviewKeyDownEvent;$w.RaiseEvent($key);Pump-Layout $w
                Expect ($key.Handled -and $script:TestCancels -eq $before+1 -and $w.FindName('PanelLogin').IsVisible)
            }
            Case ($theme+' : petite hauteur et erreur longue sans cacher les boutons') {
                $w.FindName('LblLoginError').Text=('Erreur fictive. '*100);$w.MaxHeight=480;$w.Height=480;$w.SizeToContent='Manual';Pump-Layout $w
                foreach($n in @('BtnCancel','BtnLogin','BtnWindowsLogin')){$b=$w.FindName($n);$point=$b.TranslatePoint([Windows.Point]::new(0,0),$w);Expect ($b.IsVisible -and $point.Y -ge 0 -and $point.Y+$b.ActualHeight -le $w.ActualHeight+1)}
                Expect (-not $w.FindName('TxtLoginTechnical').IsVisible)
            }
            Case ($theme+' : branchement de l attente non duplique') {
                Initialize-DomeniaUxLoginPresentation $w;Set-DomeniaFastLoginBusy $true;Pump-Layout $w;$before=$script:TestCancels
                $w.FindName('BtnLoginWaitCancel').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                Expect ($script:TestCancels -eq $before+1)
            }
        } finally {if($null -ne $w){$w.Close()};$script:FastLoginUi=$null}
        try {
            $w=Load-TestWindow (Get-MainXaml);$w.Title='DOMENIA TEST LOCAL : COMPTEURS SANS AD'
            $w.Width=if($theme -eq 'Light'){1560.0}else{1120.0};$w.Height=860
            $palette=Get-SuitePalette -Theme $theme
            $bc=[Windows.Media.BrushConverter]::new()
            foreach($key in $palette.Keys){$w.Resources[$key]=$bc.ConvertFromInvariantString([string]$palette[$key])}
            $script:TestControls=@{}
            foreach($n in @('BtnSuiteActivity','LblSuiteActivityCount','BadgeSuiteActivity','TabExperience','BtnAccessRecovery','LblAccessRecoveryCount','BadgeAccessRecovery')){$script:TestControls[$n]=$w.FindName($n)}
            $script:ExperienceInitialized=$true;$script:AsyncJobs=@{};$script:DetachedReadJobs=@();$script:AccessState=[pscustomobject]@{Pending=@{}}
            $w.Show();Pump-Layout $w
            $geometry=Get-HeaderGeometry $w;$opsContent=$w.FindName('BtnSuiteActivity').Content;$accessContent=$w.FindName('BtnAccessRecovery').Content
            foreach($count in @(0,1,9,10,99,100,0)) {
                Case ($theme+' : operations '+$count+' sans deplacement') {
                    $script:AsyncJobs=@{};for($j=0;$j -lt $count;$j++){$script:AsyncJobs['job'+$j]=@{}}
                    $script:DetachedReadJobs=@();if($count -gt 0){$script:AsyncJobs.Remove('job0');$script:DetachedReadJobs=@(@{Id='detached'})}
                    Update-DomeniaExperienceActivity;Pump-Layout $w
                    Expect-SameGeometry $geometry (Get-HeaderGeometry $w)
                    Expect ([object]::ReferenceEquals($opsContent,$w.FindName('BtnSuiteActivity').Content))
                    $expected=if($count -gt 99){'99+'}else{[string]$count}
                    Expect ($w.FindName('LblSuiteActivityCount').Text -ceq $expected)
                    Expect ([string]$w.FindName('BadgeSuiteActivity').Visibility -eq $(if($count){'Visible'}else{'Hidden'}))
                    if($count){Expect (([string]$w.FindName('BtnSuiteActivity').ToolTip).StartsWith([string]$count+' '))}
                }
            }
            foreach($count in @(0,1,9,16,100,0)) {
                Case ($theme+' : acces '+$count+' sans deplacement') {
                    $script:AccessState.Pending=@{};for($j=0;$j -lt $count;$j++){$script:AccessState.Pending['access'+$j]=@{}}
                    Update-DomeniaAccessButton;Pump-Layout $w
                    Expect-SameGeometry $geometry (Get-HeaderGeometry $w)
                    Expect ([object]::ReferenceEquals($accessContent,$w.FindName('BtnAccessRecovery').Content))
                    $expected=if($count -gt 99){'99+'}else{[string]$count}
                    Expect ($w.FindName('LblAccessRecoveryCount').Text -ceq $expected)
                    Expect ([string]$w.FindName('BadgeAccessRecovery').Visibility -eq $(if($count){'Visible'}else{'Hidden'}))
                }
            }
        } finally {if($null -ne $w){$w.Close()};$script:ExperienceInitialized=$false;$script:TestControls=@{};$w=$null}
    }
} catch {$script:Checks.Add([pscustomobject]@{Name='Infrastructure native';Passed=$false;Detail=$_.Exception.ToString()})}
$failed=@($script:Checks|Where-Object{-not $_.Passed});$expected=52
$report=[ordered]@{Build='2026.10.01-DOMENIA-1.0-RC1.6-STABLEUI';Environment='Windows PowerShell 5.1 x64 STA / WPF';Passed=$script:Checks.Count-$failed.Count;Failed=$failed.Count;Expected=$expected;Skipped=0;Complete=($script:Checks.Count -eq $expected -and $failed.Count -eq 0);NoADAccess=$true;NoProductionData=$true;Tests=$script:Checks.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-StableUI-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){$script:Checks|Format-Table Name,Passed -AutoSize;Write-Host ('Rapport : '+$ReportPath)}
if(-not $report.Complete){throw ('Test WPF incomplet ou en echec : '+$ReportPath)}
