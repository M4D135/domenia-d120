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
 foreach($definition in @(Import-Definitions (Join-Path $wad 'Domenia-Core.ps1') @('Assert-DomeniaXamlPreflight','ConvertFrom-DomeniaXaml','Load-XamlWindow','Get-DomeniaXamlControlNames'))){. $definition}
 function Set-AppWindowIcon {param($Window)}
 function Write-StartupTrace {param($Stage,$Status,$Detail)}
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
}finally{Remove-Item $temp -Recurse -Force}
$failed=@($results|Where-Object{-not $_.Passed}).Count
$report=[pscustomobject]@{Suite='StartupWork';PowerShell=$PSVersionTable.PSVersion.ToString();Passed=$results.Count-$failed;Failed=$failed;Cases=$results.ToArray()}
$json=$report|ConvertTo-Json -Depth 5
if($ReportPath){[IO.File]::WriteAllText($ReportPath,$json,[Text.UTF8Encoding]::new($false))}
Write-Output $json
if($failed){exit 1}
