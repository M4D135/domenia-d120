#requires -Version 5.1
# Remaining Windows suites: offline UI, security boundaries, startup and disposable packaging fixtures.
# Synthetic fixtures only; no live AD or endpoint network. Keep separate from the 27 base and 12 supplementary suites.
# ACL changes are confined to TEMP. Installer preserves an existing desktop shortcut; Release uses no certificate store.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$DevRoot,[Parameter(Mandatory=$true)][string]$OutDir,[int]$SuiteTimeoutSeconds=300,[string[]]$Suites=@())
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1 -or -not [Environment]::Is64BitProcess){throw 'Windows PowerShell 5.1 x64 required.'}
$dev=[IO.Path]::GetFullPath($DevRoot);$out=[IO.Path]::GetFullPath($OutDir)
[void][IO.Directory]::CreateDirectory($out)
$shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$source=@(Get-ChildItem -LiteralPath (Join-Path $dev 'wad') -Recurse -File | Where-Object {$_.Extension -in @('.ps1','.dll','.xaml','.cs','.json') -and $_.FullName -notlike '*\tests\*'} | Sort-Object FullName | ForEach-Object {[pscustomobject]@{File=$_.FullName.Substring($dev.Length+1);SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}})
[IO.File]::WriteAllText((Join-Path $out 'all-offline-runtime-source.json'),($source|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
$results=[Collections.Generic.List[object]]::new()
$plans=@(
 @{Name='Test-DomeniaAccounts';Report=$true;Arguments=@();TimeoutSeconds=300},
 @{Name='Test-DomeniaLastUser';Report=$true;Arguments=@();TimeoutSeconds=300},
 @{Name='Test-DomeniaLogin';Report=$true;Arguments=@();TimeoutSeconds=300},
 @{Name='Test-DomeniaPreload';Report=$true;Arguments=@();TimeoutSeconds=300},
 @{Name='Test-DomeniaSelection';Report=$true;Arguments=@();TimeoutSeconds=300},
 @{Name='Test-DomeniaStartupLogin';Report=$true;Arguments=@();TimeoutSeconds=300},
 @{Name='Test-DomeniaRemote';Report=$true;Arguments=@();TimeoutSeconds=300},
 @{Name='Test-DomeniaRegressions';Report=$true;Arguments=@();TimeoutSeconds=300},
 @{Name='Test-DomeniaFaults';Report=$true;Arguments=@();TimeoutSeconds=300},
 @{Name='Test-DomeniaAcl';Report=$true;Arguments=@();TimeoutSeconds=300},
 @{Name='Test-DomeniaCandidate';Report=$true;Arguments=@('-Wpf');TimeoutSeconds=300},
 @{Name='Test-DomeniaSupport';Report=$true;Arguments=@('-Wpf');TimeoutSeconds=300},
 @{Name='Test-DomeniaTheme';Report=$true;Arguments=@('-Wpf');TimeoutSeconds=300},
 @{Name='Test-DomeniaActivityLayout';Report=$true;Arguments=@();TimeoutSeconds=600},
 @{Name='Test-DomeniaRelationsAlignment';Report=$true;Arguments=@();TimeoutSeconds=600},
 @{Name='Test-DomeniaInterface';Report=$true;Arguments=@();TimeoutSeconds=600},
 @{Name='Test-DomeniaWiringAcces';Report=$true;Arguments=@();TimeoutSeconds=600},
 @{Name='Test-DomeniaWiringInline';Report=$true;Arguments=@();TimeoutSeconds=600},
 @{Name='Test-DomeniaWiringRelations';Report=$true;Arguments=@();TimeoutSeconds=600},
 @{Name='Test-DomeniaWiringSuites';Report=$true;Arguments=@();TimeoutSeconds=600},
 @{Name='Test-DomeniaWiringEcritures';Report=$true;Arguments=@();TimeoutSeconds=600},
 @{Name='Test-DomeniaInstaller';Report=$true;Arguments=@();TimeoutSeconds=900},
 @{Name='Test-DomeniaRelease';Report=$true;Arguments=@();TimeoutSeconds=900}
)
if($Suites.Count){foreach($name in $Suites){if($name -notin @($plans|ForEach-Object{$_.Name})){throw ('Unknown suite: '+$name)}};$plans=@($plans|Where-Object{$_.Name -in $Suites})}
foreach($plan in $plans){
 $name=$plan.Name;$relativePath=if($plan.RelativePath){$plan.RelativePath}else{'wad\tests\'+$name+'.ps1'};$script=Join-Path $dev $relativePath;$report=Join-Path $out ($name+'.json')
 $args=@('-NoLogo','-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-File',('"'+$script+'"'))
 if($plan.Report){$args+=@('-ReportPath',('"'+$report+'"'))};$args+=@($plan.Arguments)
 $watch=[Diagnostics.Stopwatch]::StartNew();$process=Start-Process -FilePath $shell -ArgumentList $args -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $out ($name+'.stdout.txt')) -RedirectStandardError (Join-Path $out ($name+'.stderr.txt'));$null=$process.Handle
 # Cross-layer UI and disposable package/installer fixtures may take longer on the shared three-core VM.
 $timeoutMs=[Math]::Max($SuiteTimeoutSeconds,[int]$plan.TimeoutSeconds)*1000
 $timedOut=-not $process.WaitForExit($timeoutMs)
 if($timedOut){try{$process.Kill()}catch{};$code=$null}else{$process.WaitForExit();$code=$process.ExitCode}
 $watch.Stop();$results.Add([pscustomobject]@{Suite=$name;ExitCode=$code;TimedOut=$timedOut;Milliseconds=$watch.ElapsedMilliseconds;ReportWritten=[IO.File]::Exists($report)})
 Write-Output ($name+': exit='+$code+', ms='+$watch.ElapsedMilliseconds+', timeout='+$timedOut)
}
$changed=@(foreach($entry in $source){$path=Join-Path $dev $entry.File;if(-not [IO.File]::Exists($path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $entry.SHA256){$entry.File}})
$summary=[ordered]@{Kind='RemainingOfflineWindowsUi';UTC=[datetime]::UtcNow.ToString('o');VM=$env:COMPUTERNAME;PowerShell=$PSVersionTable.PSVersion.ToString();Apartment=[Threading.Thread]::CurrentThread.ApartmentState.ToString();Is64Bit=[Environment]::Is64BitProcess;Session=[Diagnostics.Process]::GetCurrentProcess().SessionId;Data='Synthetic fixtures';ADAccessed=$false;RuntimeChanged=$changed;Suites=$results.ToArray();Scope='Synthetic offline fixtures; actual WPF, TEMP ACL/installer/package operations; existing desktop shortcut preserved; no live directory, remote endpoint or certificate-store mutation'}
[IO.File]::WriteAllText((Join-Path $out '_all-offline-ui.json'),($summary|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
$failed=@($results|Where-Object {$_.TimedOut -or $_.ExitCode -ne 0}).Count
Write-Output ('Completed: '+$results.Count+' steps, '+$failed+' failed, '+$changed.Count+' runtime files changed.')
if($failed -or $changed.Count){exit 1};exit 0
