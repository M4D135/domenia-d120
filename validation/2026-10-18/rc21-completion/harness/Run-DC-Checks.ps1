$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$root='C:\Windows\Temp\Domenia-RC21-Completion'
$zip=Join-Path $root 'Domenia_DEV.zip'
if((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne 'DD0386B01E0FD2FFB49D12AA699678682B9525C200B878346FF6BEC760F3D27B'){throw 'Wrong RC21 archive'}
Expand-Archive -LiteralPath $zip -DestinationPath $root -Force
$dev=Join-Path $root 'dev';$out=Join-Path $root 'out';[void][IO.Directory]::CreateDirectory($out)
$before=@(Get-ChildItem -LiteralPath $dev -Recurse -File | ForEach-Object{[pscustomobject]@{Path=$_.FullName;Hash=(Get-FileHash -LiteralPath $_.FullName).Hash}})
$results=@()
$cases=@(
 @{Name='CredentialGuard';Args=@()},
 @{Name='RelationsAlignment';Args=@()},
 @{Name='WiringAcces';Args=@()},
 @{Name='WiringRelations';Args=@()},
 @{Name='LapsQualification';Args=@('-Live','-Computer',$env:COMPUTERNAME)},
 @{Name='StorageMaintenance';Args=@('-CaseFilter','Point 37: link history compaction reads each observation once on a large park')}
)
foreach($c in $cases){
 $report=Join-Path $out ($c.Name+'.json');$log=Join-Path $out ($c.Name+'.log');$args=@('-NoLogo','-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-File',(Join-Path $dev ('wad\tests\Test-Domenia'+$c.Name+'.ps1')),'-ReportPath',$report)+$c.Args
 $sw=[Diagnostics.Stopwatch]::StartNew(); & "$PSHOME\powershell.exe" @args *> $log; $code=$LASTEXITCODE; $sw.Stop()
 $results+= [pscustomobject]@{Name=$c.Name;ExitCode=$code;ReportExists=(Test-Path -LiteralPath $report);Seconds=$sw.Elapsed.TotalSeconds}
 $results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'progress.json') -Encoding UTF8
}
$changed=@($before | Where-Object {(-not (Test-Path -LiteralPath $_.Path)) -or (Get-FileHash -LiteralPath $_.Path).Hash -ne $_.Hash})
[pscustomobject]@{Computer=$env:COMPUTERNAME;OS=[Environment]::OSVersion.VersionString;PowerShell=$PSVersionTable.PSVersion.ToString();ArchiveSha256=(Get-FileHash -LiteralPath $zip).Hash;SourceFileCount=$before.Count;SourceFilesUnchanged=($changed.Count -eq 0);Results=$results;DateUtc=[DateTime]::UtcNow.ToString('o');Scope='Isolated disposable files; synthetic/native tests plus read-only live LDAP schema/expiration; no AD writes'} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $out 'summary.json') -Encoding UTF8
