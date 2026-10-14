#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='',[string]$CorePath='')
$ErrorActionPreference='Stop'
# Windows PowerShell 5.1 initializes PSScriptRoot after parameter default expressions.
if([string]::IsNullOrWhiteSpace($CorePath)){$CorePath=Join-Path (Split-Path $PSScriptRoot -Parent) 'Domenia-Core.ps1'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$script:Results=[Collections.Generic.List[object]]::new();$script:Assertions=0
function Expect {param([bool]$Condition,[string]$Message)$script:Assertions++;if(-not $Condition){throw $Message}}
$tokens=$null;$errors=$null;$script:CoreAst=[Management.Automation.Language.Parser]::ParseFile($CorePath,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw 'Core parse error'}
function Import-CoreFunction {param([string]$Name)
 $nodes=@($script:CoreAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
 if($nodes.Count -ne 1){throw ('Missing or ambiguous core function: '+$Name)}
 . ([scriptblock]::Create(($nodes[0].Extent.Text -replace ('^function\s+'+[regex]::Escape($Name)+'\b'),('function script:'+$Name))))
}
foreach($name in @('Get-DomeniaBootThemePalette','Get-DomeniaBootThemeResources','Convert-DomeniaXamlToBootTheme','Get-DomeniaStandardLoginXaml','Assert-DomeniaXamlPreflight','ConvertFrom-DomeniaXaml','Test-DomeniaMainHostAvailable','Invoke-DomeniaHostWindow','Get-DomeniaFastLoginVaultIdentity','Update-DomeniaFastLoginVaultUi','Show-LoginWindow')){Import-CoreFunction $name}
$modules=Join-Path (Split-Path $CorePath -Parent) 'modules'
. (Join-Path $modules 'Domenia-Common.Model.ps1')
. (Join-Path $modules 'Domenia-Shell.Model.ps1')
. (Join-Path $modules 'Domenia-Startup.UI.ps1')
. (Join-Path $modules 'Domenia-Embedded.UI.ps1')
# CD-10 / SE-16 (lot X03): diagnostic panel of the Debug mode and read-only password reveal of the sign-in window.
. (Join-Path $modules 'Domenia-Accounts.UI.ps1')
# Authentication, preferences, logs and artwork are inert. The real login function, WPF windows,
# activation policy, ShowDialog, embedded host and cancellation handler are exercised.
function Get-DomeniaLoginWindowMode {return $script:Trial.Mode}
function Get-DomeniaStoredTheme {return 'Light'}
function Get-CfgValue {param($Section,$Key,$Default)return $Default}
function Get-DomeniaProcessWindowsIdentity {return ''}
function Test-DomeniaComputerAccountIdentity {param($Identity)return $false}
function Set-AppWindowIcon {param($Window)}
function Apply-DomeniaGuiElementPolicy {param($Window,$ControlMap)}
function Write-DomeniaFastLoginLog {param($Stage,$Status,$Detail)if($Stage -eq 'WINDOW_READY'){$script:Trial.Ready=$true}}
function Write-AppLog {param($Text,$Level)}
function Add-DomeniaFastLoginDetail {param($Text)}
function Get-DomeniaFastLoginLogPath {return 'fixture-no-file'}
function Save-DomeniaXamlDiagnostic {param($Context,$XamlText)return ''}
function Start-DomeniaFastLoginAttempt {throw 'No authentication allowed in this fixture'}
function Reset-DomeniaFastLoginAttempt {throw 'No authentication session exists in this fixture'}
function Get-DomeniaEmbeddedContext {return [pscustomobject]@{Closing=$false;Epoch=1;BaseDn='DC=example,DC=invalid'}}
function New-DomeniaTimer {
 param($Owner,$IntervalMs,[switch]$RunWhenHidden)
 $t=[pscustomobject]@{Tick=$null};$t|Add-Member -MemberType ScriptMethod -Name Start -Value {};$t|Add-Member -MemberType ScriptMethod -Name Stop -Value {};return $t
}
function New-FixtureMain {
 $w=[Windows.Window]::new();$w.Title='Domenia fixture main';$w.Width=900;$w.Height=650
 $root=[Windows.Controls.Grid]::new();$layer=[Windows.Controls.Grid]::new();$layer.Name='DomeniaDialogLayer';$layer.Visibility='Collapsed';[void]$root.Children.Add($layer);$w.Content=$root
 [Windows.NameScope]::SetNameScope($w,[Windows.NameScope]::new());$w.RegisterName('DomeniaDialogLayer',$layer);$w.Show();return $w
}
function Inspect-FixtureLogin {
 $t=$script:Trial;$t.Ticks++
 if($t.Ticks -gt 50){$t.Error='Login did not become ready';$t.Timer.Stop();if($null -ne $script:FastLoginUi){$script:FastLoginUi.Window.Close()};return}
 if(-not $t.Ready -or $null -eq $script:FastLoginUi){return}
 $t.Timer.Stop();$w=$script:FastLoginUi.Window
 try {
  $handle=[Windows.Interop.WindowInteropHelper]::new($w).Handle
  $t.Seen=[pscustomobject]@{Topmost=$w.Topmost;ShowActivated=$w.ShowActivated;IsVisible=$w.IsVisible;NativeHandleCreated=($handle -ne [IntPtr]::Zero);MainTopmost=$(if($null -ne $script:Window){$script:Window.Topmost}else{$false});MonitorTopmost=$script:StartupWindow.Topmost;ActivationAttempts=$(if((Get-DomeniaActivationState).Attempts.ContainsKey('Launch')){(Get-DomeniaActivationState).Attempts['Launch']}else{0})}
  if($t.Embedded){
   Expect (-not $w.Topmost -and -not $script:Window.Topmost) 'Embedded login promotes the main or temporary window'
   Expect (-not $w.IsVisible -and $script:Window.IsVisible) 'Embedded login creates a second native window'
   Expect ($null -ne $script:DomeniaSurfaceState -and $script:DomeniaSurfaceState.Embedded) 'Real embedded host was bypassed'
   Expect ($t.Seen.ActivationAttempts -eq 0) 'Embedded relogin requests Launch activation'
  }else{
   Expect ($w.Topmost -and $w.ShowActivated) 'Standalone login lost foreground properties after activation'
   Expect ($w.IsVisible -and $handle -ne [IntPtr]::Zero) 'Real native standalone login was not displayed'
   Expect ($t.Seen.ActivationAttempts -eq 1) 'Launch activation was skipped or repeated'
  }
  Expect (-not $script:StartupWindow.Topmost) 'Startup monitor was promoted'
  # CD-10: one template; only the Debug mode shows the diagnostic panel, and no editable reveal field exists.
  $diagnostic=$w.FindName('LoginDiagnosticBuffer')
  Expect ($null -ne $diagnostic -and (($diagnostic.Visibility -eq [Windows.Visibility]::Visible) -eq ($t.Mode -eq 'Debug'))) ('Diagnostic panel visibility wrong for mode '+$t.Mode)
  Expect ($null -eq $w.FindName('TxtLoginPasswordVisible') -and $null -ne $w.FindName('LblLoginPasswordPeek')) 'Editable password reveal field still present'
  if($t.Action -eq 'Success'){$script:FastLoginState.LoginOk=$true;Set-DomeniaSurfaceResult $w $true}
  else{$script:FastLoginUi.Cancel.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
 }catch{$t.Error=$_.Exception.ToString();$w.Close()}
}
$script:DemoMode=$false;$script:DomeniaBuild='fixture';$script:SessionEpoch=1;$script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid'}
$script:StartupWindow=[Windows.Window]::new();$script:StartupWindow.Title='Fixture startup monitor';$script:StartupWindow.Width=220;$script:StartupWindow.Height=120;$script:StartupWindow.Show()
try {
 foreach($mode in @('Standard','Debug')){
  foreach($action in @('Cancel','Success','HostError','EmbeddedCancel')){
   $script:Window=$null;$script:FastLoginUi=$null;$script:DomeniaActivationState=$null;$script:DomeniaActivationClosing=$false
   $script:Trial=[pscustomobject]@{Mode=$mode;Action=$action;Embedded=($action -eq 'EmbeddedCancel');Ready=$false;Ticks=0;Error='';Seen=$null;Timer=[Windows.Threading.DispatcherTimer]::new()}
   $name=$mode+' / '+$action;$failure=''
   try {
    Import-CoreFunction 'Invoke-DomeniaHostWindow'
    if($script:Trial.Embedded){$script:Window=New-FixtureMain}
    if($action -eq 'HostError'){
     function script:Invoke-DomeniaHostWindow {param($Window,[switch]$ManagedCancel,[switch]$PreserveTheme)
      Expect ($Window.Topmost -and $Window.ShowActivated) 'Foreground properties absent before host call';throw 'FixtureHostFault'
     }
    }else{$script:Trial.Timer.Interval=[timespan]::FromMilliseconds(100);$script:Trial.Timer.Add_Tick({Inspect-FixtureLogin});$script:Trial.Timer.Start()}
    $caught='';$accepted=$false
    try{$accepted=Show-LoginWindow}catch{$caught=$_.Exception.Message}
    if($action -eq 'HostError'){Expect ($caught -eq 'FixtureHostFault') ('Unexpected host failure: '+$caught)}else{Expect (-not $caught) $caught;Expect (-not $script:Trial.Error) $script:Trial.Error;Expect ($null -ne $script:Trial.Seen) 'Window lifecycle not observed';Expect ($accepted -eq ($action -eq 'Success')) 'Wrong dialog outcome'}
    Expect ($null -ne $script:FastLoginUi -and -not $script:FastLoginUi.Window.Topmost) 'Topmost was not cleared at exit'
    Expect (-not $script:StartupWindow.Topmost) 'Monitor Topmost changed at exit'
    if($script:Trial.Embedded){Expect (-not $script:Window.Topmost -and $script:Window.IsVisible) 'Main window changed after embedded relogin';Expect ($script:Window.FindName('DomeniaDialogLayer').Visibility -eq 'Collapsed') 'Embedded surface not cleaned up'}
   }catch{$failure=$_.Exception.ToString()+[Environment]::NewLine+$_.ScriptStackTrace}
   finally{$script:Trial.Timer.Stop();if($null -ne $script:FastLoginUi){try{$script:FastLoginUi.Window.Close()}catch{}};if($null -ne $script:Window){$script:Window.Close()}}
   $script:Results.Add([pscustomobject]@{Name=$name;Passed=(-not $failure);Error=$failure;Observed=$script:Trial.Seen})
   Write-Output ($(if($failure){'FAIL '}else{'PASS '})+$name);if($failure){Write-Output $failure}
  }
 }
}finally{$script:StartupWindow.Close()}
$failed=@($script:Results|Where-Object{-not $_.Passed}).Count
$report=[pscustomobject]@{Suite='Login foreground lifecycle';PowerShell=$PSVersionTable.PSVersion.ToString();Session=[Diagnostics.Process]::GetCurrentProcess().SessionId;Passed=($script:Results.Count-$failed);Failed=$failed;Assertions=$script:Assertions;Complete=($script:Results.Count -eq 8);ADAccessed=$false;InteractiveForegroundValidated=$false;Scope='Real native WPF standalone and embedded login; foreground properties/lifecycle only, no interactive cross-application Alt-Tab claim';CoreSHA256=(Get-FileHash -LiteralPath $CorePath -Algorithm SHA256).Hash;Results=$script:Results.ToArray()}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))}
if($failed -or -not $report.Complete){exit 1};exit 0
