#requires -Version 5.1
# Real SQLite scopes/parent aggregates versus query and dashboard drilldowns. No AD/WPF/network.
[CmdletBinding()]param([string]$ReportPath='')
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
$wad=Split-Path -Parent $PSScriptRoot;$modules=Join-Path $wad 'modules';$script:checks=0
function Expect {param([bool]$Good,[string]$Name);$script:checks++;if(-not $Good){throw $Name}}
$tokens=$null;$errors=$null;$core=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Core parse error'}
function Import-Core {param([string]$Name,[switch]$Native)
 $f=@($core.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true));if($f.Count -ne 1){throw $Name}
 $text=$f[0].Extent.Text
 if($Native -and $PSVersionTable.PSEdition -eq 'Core'){
  $text=$text.Replace('[AppDomain]::CurrentDomain.DefineDynamicAssembly','[Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly')
  if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)){$text=$text.Replace('winsqlite3.dll','/usr/lib/libsqlite3.dylib')}elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){$text=$text.Replace('winsqlite3.dll','libsqlite3.so.0')}
 }
 . ([scriptblock]::Create(($text -replace ('^function '+[regex]::Escape($Name)),('function script:'+$Name))))
}
Import-Core Initialize-DomeniaWinSqliteNative -Native;[void](Initialize-DomeniaWinSqliteNative)
. (Join-Path $modules 'Domenia-Storage.Worker.ps1');. (Join-Path $modules 'Domenia-Engine.Worker.ps1')
$storageAst=[Management.Automation.Language.Parser]::ParseInput((Get-DomeniaStorageWorkerCode),[ref]$tokens,[ref]$errors)
foreach($f in $storageAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){. ([scriptblock]::Create($f.Extent.Text))}
$worker=Get-DomeniaLocalIndexReadWorkerCode
$folder=Join-Path ([Environment]::GetFolderPath('UserProfile')) ('.domenia-dn-test-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($folder)
$path=Join-Path $folder 'dn.sqlite'

Add-Type -Path (Join-Path $modules 'M4D.Admin.Common.Query.dll')
Add-Type -Path (Join-Path $modules 'Domenia.Native.dll')
foreach($name in @('Common.Model','Search.Model','Boards.Model','BoardFleet.Model','Probes.Model','Query.Model')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$now=[datetime]::Parse('2026-10-12T14:00:00Z').ToUniversalTime()
# Parent and labels are literal expectations, not calculated by the production parser.
$fixture=@(
 @('plain','CN=Plain,OU=A,DC=test','OU=A,DC=test','A','A'),
 @('comma','CN=PC\,Extra,OU=A,DC=test','OU=A,DC=test','A','A'),
 @('even2','CN=Slash\\,OU=A,DC=test','OU=A,DC=test','A','A'),
 @('odd3','CN=Slash\\\,Extra,OU=A,DC=test','OU=A,DC=test','A','A'),
 @('even4','CN=Slash\\\\,OU=A,DC=test','OU=A,DC=test','A','A'),
 @('trap','CN=Trap\,OU=A,DC=test','DC=test','Hors OU','(directement dans l OU)'),
 @('trap3','CN=Trap\\\,OU=A,DC=test','DC=test','Hors OU','(directement dans l OU)'),
 @('child','CN=Child,OU=Child,OU=A,DC=test','OU=Child,OU=A,DC=test','Child','A'),
 @('container','CN=Container,CN=Computers,DC=test','CN=Computers,DC=test','Hors OU','(directement dans l OU)'),
 @('rack','CN=RackPC,CN=Rack,OU=A,DC=test','CN=Rack,OU=A,DC=test','A','A'),
 @('unicode','CN=Unicode,OU=Étage💻,DC=test','OU=Étage💻,DC=test','Étage💻','Étage💻'),
 @('hexunicode','CN=HexUnicode,OU=\C3\89tage\F0\9F\92\BB,DC=test','OU=\C3\89tage\F0\9F\92\BB,DC=test','Étage💻','Étage💻'),
 @('oucomma','CN=OuComma,OU=Paris\,Est,DC=test','OU=Paris\,Est,DC=test','Paris,Est','Paris,Est'),
 @('ouhex','CN=OuHex,OU=Paris\2CEst,DC=test','OU=Paris\2CEst,DC=test','Paris,Est','Paris,Est'),
 @('slashou','CN=SlashOu,OU=Lab\\,DC=test','OU=Lab\\,DC=test','Lab\','Lab\'),
 @('root','CN=Root,DC=test','DC=test','Hors OU','(directement dans l OU)'),
 @('disabled','CN=Disabled,OU=A,DC=test','OU=A,DC=test','A','A')
)
try{
 $schema=@($core.FindAll({param($n)($n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst]) -and $n.Value -match '^PRAGMA journal_mode=WAL;' -and $n.Value -match 'CREATE TABLE IF NOT EXISTS schema_info'},$true))[0].Value
 $db=Open-DomeniaDatabase $path
 try{
  [void](Invoke-DomeniaDbExec $schema $db);$sql=[Text.StringBuilder]::new();[void]$sql.Append('BEGIN;');$i=0
  foreach($f in $fixture){
   $i++;$guid='00000000-0000-0000-0000-'+$i.ToString('000000000000')
   $values=@($guid,$guid,'Machine',$f[0],$f[1],$(if($f[0] -eq 'disabled'){'Desactive'}else{'Actif'}),'Windows 11',$f[0])
   [void]$sql.Append(('INSERT INTO ad_objects(object_key,object_guid,object_type,name,distinguished_name,state,extra,search_key) VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');'))
   Expect ((Get-DomeniaRawDnParent $f[1]) -ceq $f[2]) ('literal parent '+$f[0])
   Expect ((Get-DomeniaDnSite $f[2]) -ceq $f[3]) ('literal nearest OU label '+$f[0])
   Expect ((Get-DomeniaDnSite $f[2] 'DC=test') -ceq $f[4]) ('literal root scope label '+$f[0])
  }
  [void]$sql.Append('COMMIT;');[void](Invoke-DomeniaDbExec $sql.ToString() $db)
 }finally{Close-DomeniaDatabase $db}
 Expect (@(Split-DomeniaDn 'CN="PC, West",OU="Paris, Est",DC=test').Count -eq 3) 'legacy quoted Search path parsing preserved separately'
 Expect ((Get-DomeniaDnParent 'CN="PC, West",OU="Paris, Est",DC=test') -ceq 'OU="Paris, Est",DC=test') 'legacy quoted Search parent preserved separately'
 Expect ((ConvertFrom-DomeniaDnLabel '\C3\28') -ceq '\C3\28') 'invalid UTF8 bytes remain visible'
 Expect ((ConvertFrom-DomeniaDnLabel 'A\ B\,C\\D\2CE') -ceq 'A B,C\D,E') 'mixed escaped characters and hex comma decoded only in label'
 Expect ((Get-DomeniaDnSite 'OU=A\,OU=B,DC=test' 'OU=B,DC=test') -ceq 'A,OU=B') 'escaped suffix cannot act as scope boundary in label helper'
 $allNames=@($fixture|ForEach-Object{$_[0]})
 $cases=@(
  @('domain','',$true,$allNames),
  @('domain-root','DC=test',$true,$allNames),
  @('domain-direct','DC=test',$false,@('trap','trap3','root')),
  @('ou-subtree','OU=A,DC=test',$true,@('plain','comma','even2','odd3','even4','child','rack','disabled')),
  @('ou-direct','OU=A,DC=test',$false,@('plain','comma','even2','odd3','even4','disabled')),
  @('child','OU=Child,OU=A,DC=test',$true,@('child')),
  @('container','CN=Computers,DC=test',$true,@('container')),
  @('container-direct','CN=Rack,OU=A,DC=test',$false,@('rack')),
  @('unicode','OU=Étage💻,DC=test',$true,@('unicode')),
  @('unicode-direct','OU=Étage💻,DC=test',$false,@('unicode')),
  @('hex-unicode','OU=\C3\89tage\F0\9F\92\BB,DC=test',$true,@('hexunicode')),
  @('escaped-ou','OU=Paris\,Est,DC=test',$true,@('oucomma')),
  @('hex-ou','OU=Paris\2CEst,DC=test',$true,@('ouhex')),
  @('slash-ou','OU=Lab\\,DC=test',$true,@('slashou')),
  @('absent','OU=Absent,DC=test',$true,@())
 )
 foreach($case in $cases){
  $label=[string]$case[0];$scope=[string]$case[1];$subtree=[bool]$case[2];$expected=@($case[3]);$active=@($expected|Where-Object{$_ -ne 'disabled'})
  $Payload=[pscustomobject]@{Action='FleetStats';Path=$path;ModuleRoot=$modules;BusyTimeoutMs=50;Scope=$scope;Subtree=$subtree;Plan=(Get-DomeniaFleetQueryPlan -Now $now);Keys=@();ScopeKey='';ComputeBoard=$true;Lifecycle=$null;ObservationMaxAgeDays=30;IndexPartial=''}
  $fleet=& ([scriptblock]::Create($worker))
  Expect (-not $fleet.Busy -and -not $fleet.Missing) ($label+' actual SQLite snapshot')
  Expect ((@($fleet.Machines.name|Sort-Object) -join '|') -ceq (@($expected|Sort-Object) -join '|')) ($label+' exact fleet scope identities')
  Expect ($fleet.MachineCount -eq $active.Count) ($label+' active count excludes disabled')
  $parentCounts=@{};foreach($f in $fixture){if($active -contains $f[0]){$parentCounts[$f[2]]=1+[int]$parentCounts[$f[2]]}}
  Expect (@($fleet.Parents).Count -eq $parentCounts.Count) ($label+' SQL parent bucket count')
  foreach($p in @($fleet.Parents)){Expect ($parentCounts.ContainsKey([string]$p.p) -and $parentCounts[[string]$p.p] -eq $p.n) ($label+' SQL raw parent '+$p.p)}
  $records=ConvertTo-DomeniaQueryRecords -Fleet $fleet -NowUtc $now
  Expect ($records.Count -eq $expected.Count) ($label+' query keeps all scoped identities')
  foreach($f in $fixture){
   if($expected -notcontains $f[0]){continue}
   $r=@($records|Where-Object{$_.Values['name'] -eq $f[0]})[0]
   $expectedSite=if(-not $scope){$f[3]}elseif($scope -eq 'DC=test'){$f[4]}elseif($scope -eq 'OU=A,DC=test' -and $f[0] -eq 'child'){'Child'}else{'(directement dans l OU)'}
   Expect ($r.Values['site'] -ceq $expectedSite) ($label+' exact query label '+$f[0])
  }
  $board=$fleet.Board
  foreach($item in @($board.Entries['fleet.ou'].Items|Where-Object{$null -ne $_})){
   $recipe=New-DomeniaQueryRecipe -Clauses @([pscustomobject]@{Field='active';Operator='Equal';Value=$true},[pscustomobject]@{Field='site';Operator='Equal';Value=[string]$item.Label})
   $detail=(ConvertTo-DomeniaCompiledQuery $recipe).Execute($records,$null)
   Expect ($detail.Matched -eq [int]$item.Value) ($label+' exact widget to query count '+$item.Label)
   Expect (@($detail.Rows|Where-Object{-not $_.Values['active']}).Count -eq 0) ($label+' no disabled identity in active OU widget')
  }
  if($subtree){
   $Payload=[pscustomobject]@{Action='Search';Path=$path;BusyTimeoutMs=50;Term='';Scope=$scope;Browse=$true;Limit=200;Offset=0;SortField='Name';Descending=$false}
   $page=& ([scriptblock]::Create($worker))
   Expect ((@($page.Rows.Name|Sort-Object) -join '|') -ceq (@($expected|Sort-Object) -join '|')) ($label+' Base scope exactly matches dashboard')
  }
 }
 $report=[ordered]@{Kind='DnScopes';Passed=$script:checks;Failed=0;Objects=$fixture.Count;Scopes=$cases.Count;RealSQLite=$true;NativeWindowsPowerShell51=($env:OS -eq 'Windows_NT' -and $PSVersionTable.PSVersion.Major -eq 5);WpfExecuted=$false;NetworkAccessed=$false;Summary='Actual SQLite parent/scope aggregation, common raw DN parser, escaped/hex/Unicode labels and compiled-query widget details. Escapes never broaden scope; disabled identities excluded from active OU widget.'}
 if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
 Write-Output ('PASS DN scopes: '+$script:checks+' assertions; real SQLite + compiled Query + fleet widgets, no WPF/AD')
}finally{if([IO.Directory]::Exists($folder)){Remove-Item -LiteralPath $folder -Recurse -Force}}
