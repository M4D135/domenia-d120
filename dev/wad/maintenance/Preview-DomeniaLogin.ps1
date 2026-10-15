#requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Light','Dark')][string]$Theme='Light',[switch]$Verify,[string]$ReportPath='',[string]$CaptureDirectory='',[switch]$Quiet)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Utilisez Windows PowerShell 5.1.'}
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Lancez avec powershell.exe -STA.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$wad=Split-Path -Parent $PSScriptRoot
$core=Join-Path $wad 'Domenia-Core.ps1'
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($core,[ref]$t,[ref]$e)
if(@($e).Count){throw $e[0].Message}
# Only markup, palette and XML validation are loaded. Never call application startup or auth.
foreach($name in @('Get-DomeniaStandardLoginXaml','Get-DomeniaBootThemePalette','Get-DomeniaBootThemeResources','Convert-DomeniaXamlToBootTheme','Assert-DomeniaXamlPreflight','Set-DomeniaFastLoginBusy')){
    $fn=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
    if($fn.Count -ne 1){throw ('Fonction absente : '+$name)}
    Invoke-Expression $fn[0].Extent.Text
}
. (Join-Path $wad 'modules\Domenia-Embedded.UI.ps1')
    . (Join-Path $wad 'modules\Domenia-UX.UI.ps1')
$script:PreviewLoginTheme=$Theme
function Get-DomeniaStoredTheme {return $script:PreviewLoginTheme}
function Save-DomeniaTheme {param($Theme) $script:PreviewLoginTheme=$Theme}
function Get-CfgValue {param($Section,$Key,$Default);return $Default}
function Get-DomeniaProcessWindowsIdentity {return 'EXAMPLE\compte.demo'}
$script:Results=New-Object 'System.Collections.Generic.List[object]'
function Test-LoginView {param($Name,[scriptblock]$Code)
    try{if(-not (& $Code)){throw 'Condition non verifiee'};$script:Results.Add([pscustomobject]@{Name=$Name;Passed=$true;Detail=''})}
    catch{$script:Results.Add([pscustomobject]@{Name=$Name;Passed=$false;Detail=$_.Exception.Message})}
}
function Update-LoginLayout {param($Window) $Window.UpdateLayout();$Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)}
$themes=if($Verify -or $CaptureDirectory){@('Light','Dark')}else{@($Theme)}
foreach($current in $themes){
    $script:PreviewLoginTheme=$current;$window=$null
    try{
        $xaml=Get-DomeniaStandardLoginXaml
        Assert-DomeniaXamlPreflight -XamlText $xaml -Context 'Login hors ligne'
        $r=[Xml.XmlNodeReader]::new([xml]$xaml)
        try{$window=[Windows.Markup.XamlReader]::Load($r)}finally{$r.Close()}
        Initialize-DomeniaUxLoginPresentation -Window $window
        $window.Title='DOMENIA · APERÇU LOCAL · Sans connexion AD'
        $window.FindName('TxtLogin').Text='EXAMPLE\compte.demo'
        $window.FindName('TxtLoginTechnical').Text='APERÇU LOCAL. Aucune validation de compte. Aucun mot de passe réel à saisir.'
        $window.FindName('ChkRemember').IsChecked=$true
        $window.FindName('BtnLogin').IsEnabled=$false;$window.FindName('BtnWindowsLogin').IsEnabled=$false
        $window.FindName('BtnLoginLog').IsEnabled=$false;$window.FindName('BtnCopyLoginDiag').IsEnabled=$false
        if(-not $Verify -and -not $CaptureDirectory){
            # Interactive demonstration of the real presentation controls, no authentication.
            $script:FastLoginUi=@{Window=$window}
            foreach($pair in @(@('Login','TxtLogin'),@('Password','PwdLogin'),@('PasswordPeek','LoginPasswordPeek'),@('PasswordPeekText','LblLoginPasswordPeek'),@('Reveal','BtnRevealLogin'),@('Remember','ChkRemember'),@('Connect','BtnLogin'),@('Windows','BtnWindowsLogin'),@('Cancel','BtnCancel'),@('Progress','PbLogin'),@('Technical','TxtLoginTechnical'))){$script:FastLoginUi[$pair[0]]=$window.FindName($pair[1])}
            $window.FindName('BtnLogin').Content='Simuler une connexion';$window.FindName('BtnLogin').IsEnabled=$true
            $window.FindName('BtnLogin').Add_Click({
                $script:FastLoginUi.Window.FindName('LblLoginError').Text='';Set-DomeniaFastLoginBusy $true
                $script:PreviewWaitTimer=[Windows.Threading.DispatcherTimer]::new();$script:PreviewWaitTimer.Interval=[TimeSpan]::FromSeconds(3)
                $script:PreviewWaitTimer.Add_Tick({
                    $script:PreviewWaitTimer.Stop();$script:FastLoginUi.Window.FindName('LblLoginError').Text='Fin de simulation : aucun compte vérifié. Le journal reste masqué.'
                    Set-DomeniaFastLoginBusy $false;$script:FastLoginUi.Windows.IsEnabled=$false
                });$script:PreviewWaitTimer.Start()
            })
            $window.FindName('BtnCancel').IsCancel=$false
            $window.FindName('BtnCancel').Add_Click({
                if($script:FastLoginUi.Window.FindName('PanelSplash').IsVisible){
                    if($null -ne $script:PreviewWaitTimer){$script:PreviewWaitTimer.Stop()};Set-DomeniaFastLoginBusy $false;$script:FastLoginUi.Windows.IsEnabled=$false
                }else{$script:FastLoginUi.Window.Close()}
            })
            $window.Add_Closed({if($null -ne $script:PreviewWaitTimer){$script:PreviewWaitTimer.Stop()};$script:FastLoginUi=$null})
        }

        if($Verify -or $CaptureDirectory){$window.Show();Update-LoginLayout $window}
        if($Verify){
            Test-LoginView ($current+' : bouton theme sans authentification') {
                $saved=$script:PreviewLoginTheme
                Switch-DomeniaExperienceLoginTheme -Window $window
                $ok=$script:PreviewLoginTheme -ne $saved -and $window.FindName('TxtLogin').Text -eq 'EXAMPLE\compte.demo'
                Switch-DomeniaExperienceLoginTheme -Window $window;$ok
            }
            Test-LoginView ($current+' : avertissement Verr Maj present') {$null -ne $window.FindName('LblSuiteCapsLock')}
            Test-LoginView ($current+' : standard sans maximisation') {$window.ResizeMode -eq [Windows.ResizeMode]::NoResize}
            Test-LoginView ($current+' : deux champs lisibles et hauts') {$window.FindName('TxtLogin').ActualHeight -ge 40 -and $window.FindName('PwdLogin').ActualHeight -ge 40}
            Test-LoginView ($current+' : parties de saisie presentes') {
                foreach($n in @('TxtLogin','PwdLogin')){$c=$window.FindName($n);$c.ApplyTemplate()|Out-Null;if($null -eq $c.Template.FindName('PART_ContentHost',$c)){return $false}};$true
            }
            Test-LoginView ($current+' : diagnostic absent du formulaire') {-not $window.FindName('TxtLoginTechnical').IsVisible -and -not $window.FindName('UxLoginDiagnostics').IsVisible}
            Test-LoginView ($current+' : aucun bloc erreur vide au depart') {$window.FindName('UxLoginFeedback').Visibility -eq [Windows.Visibility]::Collapsed}
            Test-LoginView ($current+' : hauteur sobre') {$window.ActualHeight -le 590}
            Test-LoginView ($current+' : style de saisie suit le theme') {$window.FindName('TxtLogin').Foreground.ToString() -eq $window.Resources['DomeniaBootText'].ToString()}
            Test-LoginView ($current+' : message long lisible sans ligne fixe') {
                $window.FindName('LblLoginError').Text=('Erreur fictive sans authentification. '*24)
                $window.FindName('LblLoginStage').Text='Ouvrez le journal pour consulter le diagnostic.'
                Update-LoginLayout $window
                $window.FindName('UxLoginFeedback').IsVisible -and $window.FindName('BtnCancel').ActualHeight -ge 40
            }
            Test-LoginView ($current+' : diagnostic externe sur demande') {Update-LoginLayout $window;$window.FindName('BtnLoginLog').IsVisible -and $window.FindName('BtnCopyLoginDiag').IsVisible -and -not $window.FindName('TxtLoginTechnical').IsVisible}
            $window.FindName('LblLoginError').Text='';$window.FindName('LblLoginStage').Text='';Update-LoginLayout $window
        }
        if($CaptureDirectory){
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($CaptureDirectory))
            $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int][Math]::Ceiling($window.ActualWidth),[int][Math]::Ceiling($window.ActualHeight),96,96,[Windows.Media.PixelFormats]::Pbgra32)
            $bitmap.Render($window);$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
            $file=Join-Path $CaptureDirectory ('DOMENIA_RC1.6_LOGIN_DEMO_'+$current+'.png');$stream=[IO.File]::Create($file);try{$encoder.Save($stream)}finally{$stream.Dispose()}
            Write-Host ('Capture WPF locale, demonstration sans AD : '+$file)
        }
        if(-not $Verify -and -not $CaptureDirectory){[void]$window.ShowDialog()}
    }finally{if($null -ne $window){$window.Close()}}
}
if($Verify){
    $bad=@($script:Results|Where-Object{-not $_.Passed})
    $report=[ordered]@{Build='2026.10.01-DOMENIA-1.0-RC1.6-STABLEUI';Environment='Windows PowerShell 5.1 / WPF';Passed=$script:Results.Count-$bad.Count;Failed=$bad.Count;NoADAccess=$true;Tests=$script:Results.ToArray()}
    if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-login-view-'+[guid]::NewGuid().ToString('N')+'.json')}
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    if(-not $Quiet){$script:Results|Format-Table Name,Passed -AutoSize;Write-Host ('Rapport : '+$ReportPath)}
    if($bad.Count){throw ('Tests WPF login en echec : '+$bad.Count)}
}
