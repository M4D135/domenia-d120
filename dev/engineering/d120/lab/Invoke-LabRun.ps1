#requires -Version 5.1
# Development helper: runs the Domenia test suites, each in its own Windows PowerShell 5.1 -STA process,
# and gathers their reports. No domain access is started by this script; each suite states its own scope.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DevRoot,
    [Parameter(Mandatory=$true)][string]$OutDir,
    [string]$Filter='',
    [ValidateRange(30,3600)][int]$TimeoutSeconds=600
)
$ErrorActionPreference='Stop'
# Relative paths follow the PowerShell location, not the process directory (they differ under VBoxManage guestcontrol).
$dev=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DevRoot);$out=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)
if(-not [IO.Directory]::Exists($out)){[void][IO.Directory]::CreateDirectory($out)}
$shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$extra=@{'Test-Domenia.ps1'=@('-WpfSmoke');'Test-DomeniaCandidate.ps1'=@('-Wpf','-Quiet');'Test-DomeniaSupport.ps1'=@('-Wpf','-Quiet');'Test-DomeniaTheme.ps1'=@('-Wpf')}
# Long benches get their own limit (point 125: 10 000 generated computers, repeated cycles, cold starts).
$longSuites=@{'Test-DomeniaLoadStability.ps1'=3600;'Test-DomeniaStorageFaults.ps1'=1200}
$rows=New-Object 'System.Collections.Generic.List[object]'
$suites=@(Get-ChildItem -LiteralPath (Join-Path $dev 'wad\tests') -Filter 'Test-*.ps1' -File | Sort-Object Name)
if($Filter){$suites=@($suites|Where-Object{$_.Name -like ('*'+$Filter+'*')})}
foreach($suite in $suites){
    $report=Join-Path $out ($suite.Name+'.json');$stdout=Join-Path $out ($suite.Name+'.stdout.txt');$stderr=Join-Path $out ($suite.Name+'.stderr.txt')
    $header=[IO.File]::ReadAllText($suite.FullName)
    if($header.Length -gt 4000){$header=$header.Substring(0,4000)}
    $bindsReport=$header -match '\$ReportPath'
    $arguments=@('-NoLogo','-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+$suite.FullName+'"'))
    if($bindsReport){$arguments+=@('-ReportPath',('"'+$report+'"'))}
    if($extra.ContainsKey($suite.Name)){$arguments+=$extra[$suite.Name]}
    elseif($header -match '\[switch\]\s*\$Quiet'){$arguments+='-Quiet'}
    $watch=[Diagnostics.Stopwatch]::StartNew();$timedOut=$false;$code=$null
    $process=Start-Process -FilePath $shell -ArgumentList $arguments -PassThru -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    # Windows PowerShell 5.1 only exposes ExitCode when the process handle was read before the exit.
    $null=$process.Handle
    $limit=$TimeoutSeconds;if($longSuites.ContainsKey($suite.Name)){$limit=[Math]::Max($TimeoutSeconds,[int]$longSuites[$suite.Name])}
    if(-not $process.WaitForExit($limit*1000)){$timedOut=$true;try{$process.Kill()}catch{}}else{$process.WaitForExit();$code=$process.ExitCode}
    $watch.Stop()
    $wrote=(-not $bindsReport) -or [IO.File]::Exists($report)
    $rows.Add([pscustomobject]@{Suite=$suite.Name;ExitCode=$code;TimedOut=$timedOut;DurationMs=$watch.ElapsedMilliseconds;ReportWritten=$wrote})
    [IO.File]::WriteAllText(($report+'.exit'),[string]$code)
}
$summary=[ordered]@{
    Kind='LabRun';StartedFrom=$dev
    Host=@{Platform='Windows';PSEdition=[string]$PSVersionTable.PSEdition;PSVersion=$PSVersionTable.PSVersion.ToString();OS=[Environment]::OSVersion.VersionString;Is64BitProcess=[Environment]::Is64BitProcess;Interactive=[Environment]::UserInteractive;SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId}
    Suites=$rows.ToArray()
}
[IO.File]::WriteAllText((Join-Path $out '_summary.json'),($summary|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
$rows|Format-Table Suite,ExitCode,TimedOut,DurationMs,ReportWritten -AutoSize|Out-String|Write-Host
