#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='')
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Windows PowerShell 5.1 x64 STA required'}
$wad=Split-Path -Parent $PSScriptRoot
$results=[Collections.Generic.List[object]]::new()
function Case($name,[scriptblock]$body){try{& $body|Out-Null;$results.Add([pscustomobject]@{Name=$name;Passed=$true})}catch{$results.Add([pscustomobject]@{Name=$name;Passed=$false;Error=$_.Exception.Message})}}
function Expect($value,$message){if(-not $value){throw $message}}
function Reject([scriptblock]$body,$pattern){$message='';try{& $body|Out-Null}catch{$message=$_.Exception.Message};Expect ($message -match $pattern) ('Expected rejection '+$pattern+', got '+$message)}
function Import-Definitions($path,$names){
 $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$t,[ref]$e)
 if($e.Count){throw ('Parser: '+$path)}
 foreach($name in $names){$f=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq $name});if($f.Count -ne 1){throw ('Function '+$name)};[scriptblock]::Create($f[0].Extent.Text)}
}
foreach($definition in @(Import-Definitions (Join-Path $wad 'Domenia-Modules.ps1') @('Assert-DomeniaRuntimeImports'))){. $definition}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-startup-work-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try{
 [IO.File]::WriteAllText((Join-Path $temp 'Expected.ps1'),'function DomeniaStartupFixture { return 7 }')
 [IO.File]::WriteAllText((Join-Path $temp 'Wrong.ps1'),'function DomeniaStartupFixture { return 9 }')
 function Get-DomeniaRuntimeModulePlan {[pscustomobject]@{File='Expected.ps1';Functions=@('DomeniaStartupFixture')}}
 . (Join-Path $temp 'Expected.ps1')
 Case 'Declared export from exact file accepted' {$r=@(Assert-DomeniaRuntimeImports $temp);Expect ($r.Count -eq 1 -and $r[0].Validated -and $r[0].Functions -eq 1) 'Valid export rejected'}
 Set-Alias DomeniaStartupFixture Get-Date
 Case 'Alias cannot mask visible function origin' {Expect (@(Assert-DomeniaRuntimeImports $temp)[0].Validated) 'Alias changed function lookup'}
 Remove-Item Alias:\DomeniaStartupFixture
 . (Join-Path $temp 'Wrong.ps1')
 Case 'Shadowing function from another file rejected' {Reject {Assert-DomeniaRuntimeImports $temp} 'DOMENIA_MODULE_ORIGIN'}
 Remove-Item Function:\DomeniaStartupFixture
 Case 'Missing function rejected after previous successful validation' {Reject {Assert-DomeniaRuntimeImports $temp} 'DOMENIA_MODULE_EXPORT'}
 Set-Alias DomeniaStartupFixture Get-Date
 Case 'Alias alone does not provide an export' {Reject {Assert-DomeniaRuntimeImports $temp} 'DOMENIA_MODULE_EXPORT'}
 Remove-Item Alias:\DomeniaStartupFixture
 & { . (Join-Path $temp 'Expected.ps1') }
 Case 'Child scope import does not satisfy caller scope' {Reject {Assert-DomeniaRuntimeImports $temp} 'DOMENIA_MODULE_EXPORT'}
 Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
 # R40 (startup time): the timing helpers, deferred steps and connection milestones of the core are imported too.
 $r40Functions=@('Get-DomeniaLaunchElapsedMs','Format-DomeniaLaunchElapsed','Add-DomeniaStartupMark','Write-DomeniaStartupMarks','Get-DomeniaStartupMilestoneGap','Write-DomeniaStartupMilestone','Write-DomeniaStartupTimings','Register-DomeniaDeferredStartupStep','Invoke-DomeniaNextDeferredStartupStep','Start-DomeniaDeferredStartup','Complete-DomeniaStartupAvailability','Write-DomeniaFastLoginLog')
 foreach($definition in @(Import-Definitions (Join-Path $wad 'Domenia-Core.ps1') (@('Assert-DomeniaXamlPreflight','ConvertFrom-DomeniaXaml','Load-XamlWindow','Get-DomeniaXamlControlNames')+$r40Functions))){. $definition}
 function Set-AppWindowIcon {param($Window)}
 $script:TraceLines=[Collections.Generic.List[object]]::new()
 function Write-StartupTrace {param($Stage,$Status,$Detail,$DurationMs) $script:TraceLines.Add([pscustomobject]@{Stage=[string]$Stage;Status=[string]$Status;Detail=[string]$Detail;DurationMs=[long]$DurationMs})}
 function Pump-Dispatcher {param([int]$Milliseconds=300)
  $frame=[Windows.Threading.DispatcherFrame]::new();$timer=[Windows.Threading.DispatcherTimer]::new()
  $timer.Interval=[TimeSpan]::FromMilliseconds($Milliseconds);$timer.Tag=$frame
  $timer.Add_Tick({param($sender,$eventArgs)$sender.Stop();$sender.Tag.Continue=$false});$timer.Start();[Windows.Threading.Dispatcher]::PushFrame($frame)
 }
 function New-HiddenWindow {
  $window=[Windows.Window]::new();$window.Width=160;$window.Height=90;$window.ShowInTaskbar=$false;$window.ShowActivated=$false;$window.Opacity=0
  $window.Show();return $window
 }
 function Get-StageName {param($Command)
  # Stage of a startup call: the value of -Stage, otherwise its first positional string.
  $elements=@($Command.CommandElements)
  for($i=1;$i -lt ($elements.Count-1);$i++){
   if(($elements[$i] -is [Management.Automation.Language.CommandParameterAst]) -and ($elements[$i].ParameterName -eq 'Stage')){return [string]$elements[$i+1].Value}
  }
  if(($elements.Count -gt 1) -and ($elements[1] -is [Management.Automation.Language.StringConstantExpressionAst])){return [string]$elements[1].Value}
  return ''
 }
 function Write-DomeniaSwallowed {param($Category,$Operation,$ErrorRecord)}
 function Get-DomeniaCriticalControlNames {'Action'}
 function Apply-DomeniaTheme {param($Theme)}
 function Get-DomeniaStoredTheme {'Light'}
 function Update-DomeniaWriteModeVisual {}
 function Apply-DomeniaGuiElementPolicy {}
 function Save-DomeniaXamlDiagnostic {param($Context,$XamlText);return ''}
 function Get-MainXaml {return $script:FixtureXaml}
 $prefix='<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">'
 $script:FixtureXaml=$prefix+'<Button x:Name="Action" Content="Ready"/></Window>'
 Case 'Real main loader constructs and resolves checked WPF controls' {Load-XamlWindow;Expect ($script:Window -is [Windows.Window] -and $script:Ctrl['Action'].Content -eq 'Ready') 'WPF construction failed';$script:Window.Close()}
 $script:FixtureXaml=$prefix+'<Button x:Name="Action" Content="Duplicate"><TextBlock Text="Second"/></Button></Window>'
 Case 'Real main loader still rejects duplicate button content' {Reject {Load-XamlWindow} 'contenu Button'}
 $script:FixtureXaml=$prefix+'<Button x:Name="Action" InvalidMember="x"/></Window>'
 Case 'Real main loader still rejects unsupported WPF members' {Reject {Load-XamlWindow} 'chargement impossible'}
 $script:FixtureXaml=$prefix+'<Button Content="No critical name"/></Window>'
 Case 'Real main loader still rejects missing critical controls' {Reject {Load-XamlWindow} 'critique'}
 Case 'R40 main loader times each step of the main window' {
  $script:TraceLines.Clear();$script:FixtureXaml=$prefix+'<Button x:Name="Action" Content="Timed"/></Window>'
  Load-XamlWindow
  try{
   $steps=@($script:TraceLines|Where-Object{$_.Stage -like 'Detail/Interface/*'}|ForEach-Object{$_.Stage.Substring('Detail/Interface/'.Length)})
   Expect (($steps -join '|') -ceq 'Lecture du XAML|Controle du XAML|Construction WPF|Aides du catalogue|Barre de titre|Controles nommes|Theme|Mode et politique des controles') ('Etapes : '+($steps -join ', '))
   Expect (@($script:TraceLines|Where-Object{($_.Stage -like 'Detail/Interface/*') -and (($_.Status -cne 'OK') -or ($_.DurationMs -lt 0))}).Count -eq 0) 'Etape sans duree valide'
   Expect ($script:Ctrl['Action'].Content -eq 'Timed') 'Fenetre construite'
  }finally{$script:Window.Close()}
 }
 Case 'R40 the XAML conversion without a timing table is unchanged' {
  $window=ConvertFrom-DomeniaXaml -XamlText ($prefix+'<Button x:Name="Plain" Content="Plain"/></Window>') -Context 'R40'
  try{Expect ($window.FindName('Plain').Content -eq 'Plain') 'Conversion sans chronometrage'}finally{$window.Close()}
 }
 Case 'R40 an accepted XAML text is remembered, a refused one never' {
  $valid=$prefix+'<Button x:Name="Memo" Content="Ok"/></Window>'
  $invalid=$prefix+'<Button x:Name="Memo" Content="Twice"><TextBlock Text="Second"/></Button></Window>'
  Assert-DomeniaXamlPreflight -XamlText $valid -Context 'R40'
  Expect ($script:DomeniaXamlPreflightAccepted.Contains($valid)) 'Texte accepte non retenu'
  Reject {Assert-DomeniaXamlPreflight -XamlText $invalid -Context 'R40'} 'contenu Button'
  Reject {Assert-DomeniaXamlPreflight -XamlText $invalid -Context 'R40'} 'contenu Button'
  Expect (-not $script:DomeniaXamlPreflightAccepted.Contains($invalid)) 'Texte refuse retenu'
  Assert-DomeniaXamlPreflight -XamlText $valid -Context 'R40 second'
  Reject {Assert-DomeniaXamlPreflight -XamlText ' ' -Context 'R40'} 'vide'
 }
 Case 'R40 launch clock counts on the process stopwatch' {
  $script:DomeniaLaunchClock=$null
  Expect ((Get-DomeniaLaunchElapsedMs) -eq -1) 'Horloge inconnue'
  Expect ((Format-DomeniaLaunchElapsed -ElapsedMs -1) -ceq 'horloge du lancement indisponible') 'Texte de l horloge inconnue'
  $script:DomeniaLaunchClock=[pscustomobject]@{Timestamp=[Diagnostics.Stopwatch]::GetTimestamp();ProcessAgeMs=1500L;Source='test'}
  Start-Sleep -Milliseconds 120
  $elapsed=Get-DomeniaLaunchElapsedMs
  Expect (($elapsed -ge 1600) -and ($elapsed -lt 61500)) ('Ecart : '+$elapsed)
  $later=[Diagnostics.Stopwatch]::GetTimestamp()+([Diagnostics.Stopwatch]::Frequency*2)
  Expect ([Math]::Abs((Get-DomeniaLaunchElapsedMs -Timestamp $later)-$elapsed-2000) -lt 1000) 'Conversion du chronometre'
  Expect ((Format-DomeniaLaunchElapsed -ElapsedMs 12345) -ceq 'T+12.3 s depuis le demarrage de PowerShell') 'Format invariant'
 }
 Case 'R40 milestones written once, Repeat for each attempt, Since gives the gap, nothing on the pipeline' {
  $script:TraceLines.Clear();$script:DomeniaStartupMilestones=$null
  $script:DomeniaLaunchClock=[pscustomobject]@{Timestamp=[Diagnostics.Stopwatch]::GetTimestamp();ProcessAgeMs=10000L;Source='test'}
  $out=@(Write-DomeniaStartupMilestone -Name 'Connexion affichee')
  Write-DomeniaStartupMilestone -Name 'Connexion affichee'
  Write-DomeniaStartupMilestone -Name 'Clic de connexion' -Since @('Connexion affichee') -Repeat
  Write-DomeniaStartupMilestone -Name 'Clic de connexion' -Since @('Connexion affichee') -Repeat
  Write-DomeniaStartupMilestone -Name 'Accueil affiche' -Since @('Clic de connexion','Inconnu') -Detail 'fixture'
  Expect ($out.Count -eq 0) 'Le jalon ecrit dans le pipeline'
  $lines=@($script:TraceLines|Where-Object{$_.Stage -like 'Jalon/*'})
  $names=@($lines|ForEach-Object{$_.Stage})
  Expect (($names -join '|') -ceq 'Jalon/Connexion affichee|Jalon/Clic de connexion|Jalon/Clic de connexion|Jalon/Accueil affiche') ('Jalons : '+($names -join ', '))
  Expect (@($lines|Where-Object{($_.DurationMs -lt 10000) -or ($_.Status -cne 'OK')}).Count -eq 0) 'Duree depuis le lancement'
  Expect ($lines[1].Detail -match '^T\+\d+\.\d s depuis le demarrage de PowerShell ; \d+\.\d s apres Connexion affichee$') ('Ecart : '+$lines[1].Detail)
  Expect (($lines[3].Detail -match 's apres Clic de connexion ; fixture$') -and ($lines[3].Detail -notmatch 'Inconnu')) ('Detail : '+$lines[3].Detail)
 }
 Case 'R40 steps measured before the trace are written once, in order' {
  $script:TraceLines.Clear();$script:DomeniaStartupMarks=$null
  Add-DomeniaStartupMark -Name 'Analyse du coeur' -DurationMs -1 -Detail 'fixture'
  Add-DomeniaStartupMark -Name 'Modules' -DurationMs 2500
  Write-DomeniaStartupMarks
  Expect ($script:TraceLines.Count -eq 2) ('Lignes : '+$script:TraceLines.Count)
  Expect (($script:TraceLines[0].Stage -ceq 'Detail/Demarrage/Analyse du coeur') -and ($script:TraceLines[0].Status -ceq 'INFO') -and ($script:TraceLines[0].DurationMs -eq 0) -and ($script:TraceLines[0].Detail -ceq 'non mesure ; fixture')) 'Duree inconnue'
  Expect (($script:TraceLines[1].Stage -ceq 'Detail/Demarrage/Modules') -and ($script:TraceLines[1].Status -ceq 'OK') -and ($script:TraceLines[1].DurationMs -eq 2500)) 'Duree mesuree'
  Write-DomeniaStartupMarks
  Expect ($script:TraceLines.Count -eq 2) 'Les etapes ne sont ecrites qu une fois'
  $script:TraceLines.Clear();$timings=[ordered]@{'Premiere'=7L;'Seconde'=0L}
  Write-DomeniaStartupTimings -Prefix 'Essai' -Timings $timings
  Expect ((@($script:TraceLines|ForEach-Object{$_.Stage+'='+$_.DurationMs}) -join '|') -ceq 'Detail/Essai/Premiere=7|Detail/Essai/Seconde=0') 'Table de durees'
 }
 Case 'R40 deferred startup steps run after the first frame, in order, before input' {
  $script:TraceLines.Clear();$script:DomeniaDeferredStartup=$null;$script:AsyncEngineClosing=$false
  $script:Order=[Collections.Generic.List[string]]::new()
  $script:Window=New-HiddenWindow
  try{
   Register-DomeniaDeferredStartupStep -Stage 'Premiere' -Action {$script:Order.Add('Premiere')}
   Register-DomeniaDeferredStartupStep -Stage 'Seconde' -Action {$script:Order.Add('Seconde')}
   Expect ($script:Order.Count -eq 0) 'Etape executee a son enregistrement'
   Expect (@($script:TraceLines|Where-Object{($_.Stage -ceq 'Premiere') -and ($_.Status -ceq 'INFO')}).Count -eq 1) 'Report non annonce dans la trace'
   # An operation of input priority, queued before the start, still runs after the deferred steps.
   [void]$script:Window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Input,[Action]{$script:Order.Add('Saisie')})
   Start-DomeniaDeferredStartup
   Pump-Dispatcher 300
   Expect (($script:Order.ToArray() -join '|') -ceq 'Premiere|Seconde|Saisie') ('Ordre : '+($script:Order.ToArray() -join ', '))
   $done=@($script:TraceLines|Where-Object{$_.Status -ceq 'OK'}|ForEach-Object{$_.Stage})
   Expect (($done -join '|') -ceq 'Apres affichage/Premiere|Apres affichage/Seconde') ('Traces : '+($done -join ', '))
   Expect ($script:DomeniaDeferredStartup.Count -eq 0) 'File des etapes non videe'
  }finally{$script:Window.Close()}
 }
 Case 'R40 a failed deferred step is traced and announced, the next one still runs' {
  $script:TraceLines.Clear();$script:DomeniaDeferredStartup=$null;$script:AsyncEngineClosing=$false
  $script:Order=[Collections.Generic.List[string]]::new();$script:Faults=[Collections.Generic.List[object]]::new();$script:AppLogs=[Collections.Generic.List[string]]::new()
  function Invoke-DomeniaDispatcherFault {param($Exception) $script:Faults.Add($Exception)}
  function Write-AppLog {param($Text,$Level) $script:AppLogs.Add([string]$Level+' '+[string]$Text)}
  $script:Window=New-HiddenWindow
  try{
   Register-DomeniaDeferredStartupStep -Stage 'Echec' -Action {throw 'panne simulee'}
   Register-DomeniaDeferredStartupStep -Stage 'Suite' -Action {$script:Order.Add('Suite')}
   Start-DomeniaDeferredStartup;Pump-Dispatcher 300
   Expect (($script:Order.ToArray() -join '|') -ceq 'Suite') 'Etape suivante non executee'
   $failure=@($script:TraceLines|Where-Object{($_.Stage -ceq 'Apres affichage/Echec') -and ($_.Status -ceq 'ERROR')})
   Expect (($failure.Count -eq 1) -and ($failure[0].Detail -match 'panne simulee')) 'Echec non trace'
   Expect (($script:Faults.Count -eq 1) -and ([string]$script:Faults[0].Message -match 'panne simulee')) 'Echec non annonce'
   Expect (@($script:AppLogs|Where-Object{$_ -like 'ERROR *(Echec)*panne simulee*'}).Count -eq 1) ('Journal : '+($script:AppLogs -join ' | '))
  }finally{$script:Window.Close()}
 }
 Case 'R40 deferred steps are skipped once the main window is closing' {
  $script:TraceLines.Clear();$script:DomeniaDeferredStartup=$null;$script:AsyncEngineClosing=$true
  $script:Order=[Collections.Generic.List[string]]::new()
  $script:Window=New-HiddenWindow
  try{
   Register-DomeniaDeferredStartupStep -Stage 'Fermeture' -Action {$script:Order.Add('Fermeture')}
   Start-DomeniaDeferredStartup;Pump-Dispatcher 200
   Expect ($script:Order.Count -eq 0) 'Etape executee pendant la fermeture'
   Expect (@($script:TraceLines|Where-Object{($_.Stage -ceq 'Apres affichage/Fermeture') -and ($_.Status -ceq 'CANCEL')}).Count -eq 1) 'Abandon non trace'
  }finally{$script:AsyncEngineClosing=$false;$script:Window.Close()}
 }
 Case 'R40 Initialize-Window defers Stockage and the tree, keeps the maintenance warning in place' {
  $t=$null;$e=$null;$coreAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$t,[ref]$e)
  Expect (@($e).Count -eq 0) 'Analyse du coeur'
  $window=@($coreAst.EndBlock.Statements|Where-Object{($_ -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($_.Name -eq 'Initialize-Window')})
  Expect ($window.Count -eq 1) 'Initialize-Window absent'
  $calls=@($window[0].Body.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true))
  $deferred=@($calls|Where-Object{$_.GetCommandName() -eq 'Register-DomeniaDeferredStartupStep'}|ForEach-Object{Get-StageName $_})
  Expect (($deferred -join '|') -ceq 'Réglages du stockage local|Preparation arbre AD') ('Etapes differees : '+($deferred -join ', '))
  $blocking=@($calls|Where-Object{$_.GetCommandName() -eq 'Invoke-DomeniaStartupStage'}|ForEach-Object{Get-StageName $_})
  Expect ($blocking -notcontains 'Réglages du stockage local') 'Stockage encore avant l affichage'
  foreach($stage in @('Préférences persistantes','Chargement interface WPF','Branchement des evenements','Etat initial de securite','Barriere de disponibilite')){Expect ($blocking -contains $stage) ('Etape retiree : '+$stage)}
  # The tree is loaded by the deferred step only; the maintenance branch keeps its synchronous warning.
  $tree=@($calls|Where-Object{$_.GetCommandName() -eq 'Load-TreeRoot'})
  Expect ($tree.Count -eq 1) 'Chargement de l arbre'
  $owner=$tree[0].Parent;while(($null -ne $owner) -and -not (($owner -is [Management.Automation.Language.CommandAst]) -and ($owner.GetCommandName() -eq 'Register-DomeniaDeferredStartupStep'))){$owner=$owner.Parent}
  Expect ($null -ne $owner) 'Arbre charge avant l affichage'
  $maintenance=@($calls|Where-Object{($_.GetCommandName() -eq 'Invoke-DomeniaStartupStage') -and ((Get-StageName $_) -ceq 'Preparation arbre AD')})
  Expect (($maintenance.Count -eq 1) -and ($maintenance[0].Extent.Text -match 'recovery-unreadable')) 'Avertissement de maintenance deplace'
  $events=@($window[0].Body.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst]},$true))
  $rendered=@($events|Where-Object{$_.Member.Extent.Text -eq 'Add_ContentRendered'})
  Expect (($rendered.Count -eq 1) -and ($rendered[0].Extent.Text -match "Accueil affiche") -and ($rendered[0].Extent.Text -match 'Start-DomeniaDeferredStartup') -and ($rendered[0].Extent.Text -match 'Complete-DomeniaStartupAvailability')) 'Premier affichage non raccorde'
  Expect ($rendered[0].Extent.Text.IndexOf('Start-DomeniaDeferredStartup') -lt $rendered[0].Extent.Text.IndexOf('Show-DomeniaFleetOverviewIdle')) 'Etapes differees apres les travaux d inactivite'
  $loaded=@($events|Where-Object{$_.Member.Extent.Text -eq 'Add_Loaded'})
  Expect (($loaded.Count -eq 1) -and ($loaded[0].Extent.Text -match 'Fenetre principale chargee')) 'Jalon de mise en page'
 }
 Case 'R40 connection moments are milestones of the launch clock' {
  $script:TraceLines.Clear();$script:DomeniaStartupMilestones=$null;$script:DomeniaBuild='R40-test'
  $script:DomeniaLaunchClock=[pscustomobject]@{Timestamp=[Diagnostics.Stopwatch]::GetTimestamp();ProcessAgeMs=5000L;Source='test'}
  $loginLog=Join-Path $temp 'r40-login.log'
  function Get-DomeniaFastLoginLogPath {return $loginLog}
  function Protect-DomeniaLogText {param($Text) return [string]$Text}
  foreach($stage in @('WINDOW_READY','CLICK','PROGRESS','CLICK','LOGIN_OK')){Write-DomeniaFastLoginLog -Stage $stage -Detail 'fixture'}
  $milestones=@($script:TraceLines|Where-Object{$_.Stage -like 'Jalon/*'}|ForEach-Object{$_.Stage})
  Expect (($milestones -join '|') -ceq 'Jalon/Connexion affichee|Jalon/Clic de connexion|Jalon/Clic de connexion|Jalon/Connexion validee') ('Jalons : '+($milestones -join ', '))
  Expect (@($script:TraceLines|Where-Object{$_.Stage -like 'Login/*'}).Count -eq 5) 'Traces de connexion modifiees'
  Expect (@(Get-Content -LiteralPath $loginLog).Count -eq 5) 'Journal de connexion modifie'
  $validated=@($script:TraceLines|Where-Object{$_.Stage -ceq 'Jalon/Connexion validee'})[0]
  Expect ($validated.Detail -match 's apres Clic de connexion$') ('Ecart depuis le dernier clic : '+$validated.Detail)
 }
 Case 'R40 catalogued help handlers are converted once and keep per-control behaviour' {
  . (Join-Path $wad 'modules\Domenia-Shell.Model.ps1')
  . (Join-Path $wad 'modules\Domenia-UX.UI.ps1')
  $script:UxHelpHandlers=$null;$script:HelpShown=[Collections.Generic.List[string]]::new()
  function Show-DomeniaUxControlHelp {param($Control) $script:HelpShown.Add([string]$Control.Name)}
  $first=[Windows.Controls.Button]::new();$first.Name='BtnGlobalSearch';$first.Content='Rechercher'
  $second=[Windows.Controls.Button]::new();$second.Name='BtnTreeRefresh';$second.Content='Actualiser'
  $grid=[Windows.Controls.DataGrid]::new();$grid.Name='DgObjects'
  foreach($control in @($first,$second,$grid)){Initialize-DomeniaUxControlHelp -Control $control}
  $handlers=$script:UxHelpHandlers
  Expect (($null -ne $handlers) -and ($handlers.MouseEnter -is [Windows.Input.MouseEventHandler]) -and ($handlers.ToolTipOpening -is [Windows.Controls.ToolTipEventHandler]) -and ($handlers.GotKeyboardFocus -is [Windows.Input.KeyboardFocusChangedEventHandler])) 'Gestionnaires partages absents'
  $box=[Windows.Controls.TextBox]::new();$box.Name='TxtGlobalSearch';Initialize-DomeniaUxControlHelp -Control $box
  Expect ([object]::ReferenceEquals($handlers,$script:UxHelpHandlers)) 'Gestionnaires recrees pour un autre controle'
  foreach($element in @($second,$grid,$first)){$hover=[Windows.Input.MouseEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,0);$hover.RoutedEvent=[Windows.UIElement]::MouseEnterEvent;$element.RaiseEvent($hover)}
  Expect (($script:HelpShown.ToArray() -join '|') -ceq 'BtnTreeRefresh|BtnGlobalSearch') ('Survol : '+($script:HelpShown.ToArray() -join ', '))
  $script:HelpShown.Clear()
  $focus=[Windows.Input.KeyboardFocusChangedEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice,0,$null,$grid);$focus.RoutedEvent=[Windows.UIElement]::GotKeyboardFocusEvent;$grid.RaiseEvent($focus)
  Expect (($script:HelpShown.ToArray() -join '|') -ceq 'DgObjects') ('Focus clavier : '+($script:HelpShown.ToArray() -join ', '))
  Expect ((([string]$first.ToolTip).Length -gt 0) -and ($null -eq $grid.ToolTip)) 'Infobulles du catalogue'
  Expect ($first.Resources.Contains('Domenia.UxHelpAttached')) 'Marqueur d idempotence'
  $script:HelpShown.Clear();Initialize-DomeniaUxControlHelp -Control $first
  $hover=[Windows.Input.MouseEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,0);$hover.RoutedEvent=[Windows.UIElement]::MouseEnterEvent;$first.RaiseEvent($hover)
  Expect ($script:HelpShown.Count -eq 1) 'Gestionnaire ajoute deux fois'
 }
}finally{Remove-Item $temp -Recurse -Force}
$failed=@($results|Where-Object{-not $_.Passed}).Count
$report=[pscustomobject]@{Suite='StartupWork';PowerShell=$PSVersionTable.PSVersion.ToString();Passed=$results.Count-$failed;Failed=$failed;Cases=$results.ToArray()}
$json=$report|ConvertTo-Json -Depth 5
if($ReportPath){[IO.File]::WriteAllText($ReportPath,$json,[Text.UTF8Encoding]::new($false))}
Write-Output $json
if($failed){exit 1}
