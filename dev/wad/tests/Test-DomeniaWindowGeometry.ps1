#requires -Version 5.1
param([string]$ReportPath='',[string]$CorePath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'Domenia-Core.ps1'))
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Windows PowerShell 5.1 STA required'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($CorePath,[ref]$t,[ref]$e);if($e.Count){throw 'Core parse failed'}
foreach($name in @('Restore-DomeniaWindowGeometry','Save-DomeniaWindowGeometry')){$fn=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true));if($fn.Count -ne 1){throw $name};. ([scriptblock]::Create($fn[0].Extent.Text))}
$script:Settings=@{};$script:RestoringSettings=$false;$script:Errors=[Collections.Generic.List[string]]::new();$results=[Collections.Generic.List[object]]::new()
function Get-DomeniaSetting($Name,$Default){if($script:Settings.ContainsKey($Name)){return $script:Settings[$Name]};return $Default}
function Set-DomeniaSetting($Name,$Value){$script:Settings[$Name]=$Value}
function Write-DomeniaSwallowed($Category,$Operation,$ErrorRecord){$script:Errors.Add($ErrorRecord.Exception.Message)}
function Pump{[void][Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)}
function New-TestWindow{ $w=[Windows.Window]::new();$w.Width=900;$w.Height=620;$w.MinWidth=320;$w.MinHeight=240;$w.Left=65;$w.Top=50;$w.WindowStartupLocation='Manual';$w.ShowInTaskbar=$false
 # Exercise the same production event handlers, not only explicit function calls.
 $script:Window=$w
 foreach($event in @('Add_LocationChanged','Add_SizeChanged','Add_StateChanged')) {
  $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq $event -and $n.Extent.Text -match 'Save-DomeniaWindowGeometry'},$true))
  if($nodes.Count -ne 1){throw ('Geometry event binding missing: '+$event)}
  . ([scriptblock]::Create($nodes[0].Extent.Text))
 }
 $w.Add_Closed({Save-DomeniaWindowGeometry})
 return $w }
function Expect($condition,$message){if(-not $condition){throw $message}}
function Case($name,$code){$script:Errors.Clear();try{& $code;Expect ($script:Errors.Count -eq 0) ($script:Errors -join '; ');$results.Add([pscustomobject]@{Name=$name;Passed=$true})}catch{$results.Add([pscustomobject]@{Name=$name;Passed=$false;Error=$_.Exception.Message})}}
try {
 $script:Window=New-TestWindow;$script:Window.Show();Pump
 Case 'Normal size and position roundtrip through JSON preferences' {
  Save-DomeniaWindowGeometry;$json=$script:Settings|ConvertTo-Json;$stored=$json|ConvertFrom-Json
  Expect (-not $stored.WindowMaximized -and $stored.WindowWidth -eq 900 -and $stored.WindowHeight -eq 620 -and $stored.WindowLeft -eq 65 -and $stored.WindowTop -eq 50) 'Normal bounds not saved'
 }
 Case 'Maximized save retains the latest normal rectangle' {
  $script:Window.Width=1040;$script:Window.Height=700;$script:Window.Left=90;$script:Window.Top=70;Pump
  $script:Window.WindowState='Maximized';Pump;Save-DomeniaWindowGeometry
  Expect ($script:Settings.WindowMaximized -and $script:Settings.WindowWidth -eq 1040 -and $script:Settings.WindowHeight -eq 700 -and $script:Settings.WindowLeft -eq 90 -and $script:Settings.WindowTop -eq 70) 'Maximization lost normal bounds'
 }
 Case 'Restore Down after reopening maximized uses the saved rectangle' {
  $script:Window.Close();$script:Window=New-TestWindow;Restore-DomeniaWindowGeometry;$script:Window.Show();Pump
  Expect ($script:Window.WindowState -eq 'Maximized') 'Maximized state not restored'
  $script:Window.WindowState='Normal';Pump
  Expect ([math]::Abs($script:Window.ActualWidth-1040) -lt 2 -and [math]::Abs($script:Window.ActualHeight-700) -lt 2 -and [math]::Abs($script:Window.Left-90) -lt 2 -and [math]::Abs($script:Window.Top-70) -lt 2) 'Restore Down geometry differs'
 }
 Case 'Minimized close preserves the previous maximized choice' {
  $script:Window.WindowState='Maximized';Pump;Save-DomeniaWindowGeometry
  $script:Window.WindowState='Minimized';Pump;Save-DomeniaWindowGeometry
  Expect ($script:Settings.WindowMaximized -and $script:Settings.WindowWidth -eq 1040 -and $script:Settings.WindowHeight -eq 700) 'Minimize overwrote geometry'
  $script:Window.Close()
  Expect ($script:Settings.WindowMaximized -and $script:Settings.WindowWidth -eq 1040 -and $script:Settings.WindowHeight -eq 700) 'Minimized close overwrote geometry'
 }
 Case 'Missing display returns the window to the current work area' {
  $script:Settings=@{WindowMaximized=$false;WindowLeft=30000;WindowTop=30000;WindowWidth=900;WindowHeight=620};$script:Window=New-TestWindow;Restore-DomeniaWindowGeometry
  $a=[Windows.SystemParameters]::WorkArea
  Expect ($script:Window.Left -ge $a.Left -and $script:Window.Top -ge $a.Top -and $script:Window.Left+120 -le $a.Right -and $script:Window.Top+60 -le $a.Bottom) 'Title bar remains offscreen'
 }
 Case 'Uninitialized size leaves first-launch defaults unchanged' {
  $script:Settings=@{WindowWidth=0;WindowHeight=0;WindowLeft=-1;WindowTop=-1};$script:Window=New-TestWindow;Restore-DomeniaWindowGeometry
  Expect ($script:Window.Width -eq 900 -and $script:Window.Height -eq 620 -and $script:Window.Left -eq 65) 'Defaults changed by missing saved size'
 }
 Case 'Settings restoration cannot overwrite saved geometry' {
  $script:Settings=@{WindowWidth=777};$script:RestoringSettings=$true;Save-DomeniaWindowGeometry;$script:RestoringSettings=$false
  Expect ($script:Settings.WindowWidth -eq 777 -and -not $script:Settings.ContainsKey('WindowMaximized')) 'Restore guard ignored'
 }
}finally{if($script:Window){$script:Window.Close()}}
$failed=@($results|Where-Object{-not $_.Passed}).Count
$report=[ordered]@{Suite='WindowGeometry';PowerShell=$PSVersionTable.PSVersion.ToString();Wpf=$true;NoNetwork=$true;ProductionPreferencesTouched=$false;CoreSha256=(Get-FileHash $CorePath -Algorithm SHA256).Hash;Passed=$results.Count-$failed;Failed=$failed;Results=$results.ToArray()}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))}
$report|ConvertTo-Json -Depth 5
if($failed){exit 1}
