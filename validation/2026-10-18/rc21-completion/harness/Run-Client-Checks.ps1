$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$root='C:\Windows\Temp\Domenia-RC21-Completion'
$zip=Join-Path $root 'Domenia_DEV.zip'
if((Get-FileHash $zip).Hash -ne 'DD0386B01E0FD2FFB49D12AA699678682B9525C200B878346FF6BEC760F3D27B'){throw 'Wrong archive'}
Expand-Archive $zip $root -Force
$dev=Join-Path $root 'dev';$out=Join-Path $root 'out';[void][IO.Directory]::CreateDirectory($out)
$patches=@('Test-DomeniaCredentialGuard.ps1','Test-DomeniaLapsQualification.ps1')
$harnesses=@();foreach($p in $patches){Copy-Item (Join-Path $root $p) (Join-Path $dev ('wad\tests\'+$p)) -Force;$harnesses += [pscustomobject]@{Name=$p;SHA256=(Get-FileHash (Join-Path $root $p)).Hash}}
$results=@();$cases=@(@{Name='CredentialGuard';Args=@()},@{Name='LapsQualification';Args=@('-Live','-Computer','DC01')},@{Name='LoadStability';Args=@('-Computers','20000','-Cycles','5')})
foreach($c in $cases){
 $report=Join-Path $out ($c.Name+'.json');$log=Join-Path $out ($c.Name+'.log');$a=@('-NoLogo','-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-File',(Join-Path $dev ('wad\tests\Test-Domenia'+$c.Name+'.ps1')),'-ReportPath',$report)+$c.Args
 $sw=[Diagnostics.Stopwatch]::StartNew();& "$PSHOME\powershell.exe" @a *> $log;$code=$LASTEXITCODE;$sw.Stop()
 $results += [pscustomobject]@{Name=$c.Name;ExitCode=$code;ReportExists=(Test-Path $report);Seconds=$sw.Elapsed.TotalSeconds}
 $results | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $out 'progress.json') -Encoding UTF8
}
[pscustomobject]@{DateUtc=[datetime]::UtcNow.ToString('o');Computer=$env:COMPUTERNAME;OS=[Environment]::OSVersion.VersionString;PowerShell=$PSVersionTable.PSVersion.ToString();ArchiveSHA256=(Get-FileHash $zip).Hash;SupplementalHarnesses=$harnesses;Results=$results;Scope='Personal laboratory; isolated generated fixtures; read-only LDAP; no AD writes'} | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $out 'summary.json') -Encoding UTF8
