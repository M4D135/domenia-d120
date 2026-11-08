$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\d120-rc11711-delivery'
$zip=Join-Path $root 'candidate-dev.zip'
$hash=(Get-FileHash $zip -Algorithm SHA256).Hash
if($hash -cne '39AE44650715EF9A3CDFBD7EEEE50EECB51E78E5AB457AE1595B1EEB15524E9F'){throw 'Archive mismatch'}
Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $root 'expanded')
$dev=Join-Path $root 'expanded\dev';$out=Join-Path $root 'out'
[void][IO.Directory]::CreateDirectory($out)
$shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$results=New-Object 'Collections.Generic.List[object]'
foreach($suite in @('Boards')){
 $report=Join-Path $out ($suite+'.json')
 $arguments=@('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',(Join-Path $dev ('wad\tests\Test-Domenia'+$suite+'.ps1')),'-ReportPath',$report)
 if($suite -eq 'Boards'){$arguments+=@('-Filter','RC11711|Premiers.pas|Widget.AD|Widget.ajoute|Widget.du.poste|Widget.de.requete.en.attente','-Quiet')}
 $watch=[Diagnostics.Stopwatch]::StartNew()
 & $shell @arguments *> (Join-Path $out ($suite+'.txt'))
 $code=$LASTEXITCODE;$watch.Stop()
 $d=Get-Content $report -Raw|ConvertFrom-Json
 $results.Add([pscustomobject]@{Suite=$suite;ExitCode=$code;Passed=$d.Passed;Failed=$d.Failed;DurationMs=$watch.ElapsedMilliseconds})
}
# Tiny query regression: actual compiled engine, two mixed source clocks, no network.
$modules=Join-Path $dev 'wad\modules'
Add-Type -Path (Join-Path $modules 'M4D.Admin.Common.Query.dll')
Add-Type -Path (Join-Path $modules 'Domenia.Native.dll')
foreach($name in @('Common.Model','HealthRules.Model','Boards.Model','Probes.Model','Workstation.Model','QuerySchema.Model','Query.Model')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$old=[datetime]::UtcNow.AddDays(-3);$recent=$old.AddDays(1)
$records=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
foreach($i in 1..2){
 $v=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
 $v['name']='PC-'+$i;$v['os']='Windows 11';$v['ramGB']=8.0;$v['active']=$true
 $v[(Get-DomeniaQueryTimestampKey 'os')]=$old.ToString('o')
 $v[(Get-DomeniaQueryTimestampKey 'ramGB')]=$recent.ToString('o')
 $records.Add([M4D.Admin.Common.Query.QueryRecord]::new(('00000000-0000-4000-8000-00000000000'+$i),$v))
}
$recipe=New-DomeniaQueryRecipe -Name 'Dates des sources' -GroupBy 'os' -Clauses @([pscustomobject]@{Field='ramGB';Operator='Less';Value=16})
$counts=Measure-DomeniaQueryWidget -Records $records -Recipe $recipe
if($counts.Matched -ne 2 -or @($counts.DataSources).Count -ne 2){throw ('Query source dates: invalid counts '+($counts|ConvertTo-Json -Depth 5 -Compress))}
$clocks=@($counts.DataSources|ForEach-Object{$_.OldestUtc.ToUniversalTime().ToString('o')})
if($clocks -notcontains $old.ToString('o') -or $clocks -notcontains $recent.ToString('o')){throw 'Source timestamps lost or rejuvenated'}
$coverage=Measure-DomeniaQueryCoverage -Records $records -Recipe $recipe
if($coverage.Total -ne 2 -or $coverage.SourceCount -ne 2){throw 'Full coverage regression'}
[IO.File]::WriteAllText((Join-Path $out 'query-source-dates.json'),([pscustomobject]@{Passed=1;Failed=0;Host=$PSVersionTable.PSVersion.ToString();ArchiveSha256=$hash;Sources=$counts.DataSources}|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
$results.Add([pscustomobject]@{Suite='Query source dates';ExitCode=0;Passed=1;Failed=0})
& $shell -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $dev 'engineering\d120\Test-NativeParser.ps1') -SourceRoot $dev -ReportPath (Join-Path $out 'native-parser.json') -RequireWindows51 *> (Join-Path $out 'native-parser.txt')
$parserExit=$LASTEXITCODE
$report=[pscustomobject]@{Scope='Targeted native checks of DEV archive; no AD/transport/full-release qualification';ArchiveSha256=$hash;PowerShell=$PSVersionTable.PSVersion.ToString();PSEdition=$PSVersionTable.PSEdition;Is64BitProcess=[Environment]::Is64BitProcess;ApartmentState=[Threading.Thread]::CurrentThread.ApartmentState.ToString();Suites=$results.ToArray();ParserExitCode=$parserExit}
[IO.File]::WriteAllText((Join-Path $out 'targeted-summary.json'),($report|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
$report|ConvertTo-Json -Depth 5
if($parserExit -ne 0 -or @($results|Where-Object{$_.ExitCode -ne 0 -or $_.Failed -ne 0}).Count){exit 1}
