#requires -Version 5.1
# Short Windows/WPF verification in the existing test VM. Synthetic data only; no AD writes.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$DevRoot,[Parameter(Mandatory=$true)][string]$OutDir,[string]$CaptureScript='', [int]$SuiteTimeoutSeconds=90,[switch]$Extended,[string[]]$Suites=@())
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1 -or -not [Environment]::Is64BitProcess){throw 'Windows PowerShell 5.1 x64 required.'}
$dev=[IO.Path]::GetFullPath($DevRoot);$out=[IO.Path]::GetFullPath($OutDir)
[void][IO.Directory]::CreateDirectory($out)
$shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$source=@(Get-ChildItem -LiteralPath (Join-Path $dev 'wad') -Recurse -File | Where-Object {$_.Extension -in @('.ps1','.dll','.xaml','.cs','.json') -and $_.FullName -notlike '*\tests\*'} | Sort-Object FullName | ForEach-Object {[pscustomobject]@{File=$_.FullName.Substring($dev.Length+1);SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}})
[IO.File]::WriteAllText((Join-Path $out 'runtime-source.json'),($source|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
$results=[Collections.Generic.List[object]]::new()
$plans=@(
 @{Name='Ps51Compat';RelativePath='tools\Test-DomeniaPs51Compat.ps1';Report=$true;Arguments=@('-Root',('"'+$dev+'"'))},
 @{Name='ProdFactory';RelativePath='engineering\d120\quick-ui-20261012\Test-DomeniaProdFactory.ps1';Report=$true;Arguments=@('-DevRoot',('"'+$dev+'"'))},
 @{Name='NativeParser';RelativePath='engineering\d120\Test-NativeParser.ps1';Report=$true;Arguments=@('-SourceRoot',('"'+$dev+'"'),'-RequireWindows51')},
 @{Name='StartupCheckOnly';RelativePath='wad\Domenia-Start.ps1';Report=$false;Arguments=@('-CheckOnly')},
 @{Name='Test-DomeniaModules';Report=$true;Arguments=@()},
 @{Name='Test-Domenia';Report=$true;Arguments=@('-WpfSmoke')},
 @{Name='Test-DomeniaLiveSearchView';Report=$true;Arguments=@()},
 @{Name='Test-DomeniaUxRefinements';Report=$true;Arguments=@()},
 @{Name='Test-DomeniaBoards';Report=$true;Arguments=@()},
 @{Name='Test-DomeniaLoginForeground';Report=$true;Arguments=@()},
 @{Name='Test-DomeniaWiringInterface';Report=$true;Arguments=@()},
 @{Name='Test-DomeniaParkDetection';Report=$true;Arguments=@()},
 @{Name='Test-DomeniaEngineResilience';Report=$true;Arguments=@()},
 @{Name='Test-DomeniaQuery';Report=$false;Arguments=@()},
 @{Name='Test-DomeniaIndexSorting';Report=$false;Arguments=@()},
 @{Name='Test-DomeniaIndexActions';Report=$false;Arguments=@()},
 @{Name='Test-DomeniaDnScopes';Report=$false;Arguments=@()}
)
if($Extended){$plans+=@(@{Name='Test-DomeniaQueryTemplates';Report=$true;Arguments=@()},@{Name='Test-DomeniaQueryTargets';Report=$true;Arguments=@()},@{Name='Test-DomeniaStreaming';Report=$true;Arguments=@()},@{Name='Test-DomeniaRules';Report=$true;Arguments=@()},@{Name='Test-DomeniaNative';Report=$false;Arguments=@()},@{Name='Test-DomeniaIndexPersistence';Report=$false;Arguments=@()})}
if($Suites.Count){foreach($name in $Suites){if($name -notin @($plans|ForEach-Object{$_.Name})){throw ('Unknown suite: '+$name)}};$plans=@($plans|Where-Object{$_.Name -in $Suites})}
foreach($plan in $plans){
 $name=$plan.Name;$relativePath=if($plan.RelativePath){$plan.RelativePath}else{'wad\tests\'+$name+'.ps1'};$script=Join-Path $dev $relativePath;$report=Join-Path $out ($name+'.json')
 $args=@('-NoLogo','-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-File',('"'+$script+'"'))
 if($plan.Report){$args+=@('-ReportPath',('"'+$report+'"'))};$args+=@($plan.Arguments)
 $watch=[Diagnostics.Stopwatch]::StartNew();$process=Start-Process -FilePath $shell -ArgumentList $args -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $out ($name+'.stdout.txt')) -RedirectStandardError (Join-Path $out ($name+'.stderr.txt'));$null=$process.Handle
 # The integrated WPF self-test has its own 90-second guard after the portable assertions.
 $timeoutMs=if($name -eq 'Test-Domenia'){[Math]::Max(150,$SuiteTimeoutSeconds)*1000}else{$SuiteTimeoutSeconds*1000}
 $timedOut=-not $process.WaitForExit($timeoutMs)
 if($timedOut){try{$process.Kill()}catch{};$code=$null}else{$process.WaitForExit();$code=$process.ExitCode}
 $watch.Stop();$results.Add([pscustomobject]@{Suite=$name;ExitCode=$code;TimedOut=$timedOut;Milliseconds=$watch.ElapsedMilliseconds;ReportWritten=[IO.File]::Exists($report)})
 Write-Output ($name+': exit='+$code+', ms='+$watch.ElapsedMilliseconds+', timeout='+$timedOut)
}
if($CaptureScript){
 $captureOut=Join-Path $out 'captures';$args=@('-NoLogo','-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-File',('"'+$CaptureScript+'"'),'-Dev',('"'+$dev+'"'),'-Out',('"'+$captureOut+'"'),'-Width','1920','-Height','1080')
 $watch=[Diagnostics.Stopwatch]::StartNew();$process=Start-Process -FilePath $shell -ArgumentList $args -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $out 'captures.stdout.txt') -RedirectStandardError (Join-Path $out 'captures.stderr.txt');$null=$process.Handle
 $timedOut=-not $process.WaitForExit(180000)
 if($timedOut){try{$process.Kill()}catch{};$code=$null}else{$process.WaitForExit();$code=$process.ExitCode}
 $watch.Stop();$results.Add([pscustomobject]@{Suite='GuideCaptures';ExitCode=$code;TimedOut=$timedOut;Milliseconds=$watch.ElapsedMilliseconds;ReportWritten=$false})
}
$changed=@(foreach($entry in $source){$path=Join-Path $dev $entry.File;if(-not [IO.File]::Exists($path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $entry.SHA256){$entry.File}})
$summary=[ordered]@{Kind='QuickWindowsUi';UTC=[datetime]::UtcNow.ToString('o');VM=$env:COMPUTERNAME;PowerShell=$PSVersionTable.PSVersion.ToString();Apartment=[Threading.Thread]::CurrentThread.ApartmentState.ToString();Is64Bit=[Environment]::Is64BitProcess;Session=[Diagnostics.Process]::GetCurrentProcess().SessionId;Data='Synthetic fixtures';ADAccessed=$false;RuntimeChanged=$changed;Suites=$results.ToArray();CaptureProvenance='Real WPF layout rendered in Windows from current source with fictitious fixture values; no live AD inventory.'}
[IO.File]::WriteAllText((Join-Path $out '_quick-ui.json'),($summary|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
$failed=@($results|Where-Object {$_.TimedOut -or $_.ExitCode -ne 0}).Count
Write-Output ('Completed: '+$results.Count+' steps, '+$failed+' failed, '+$changed.Count+' runtime files changed.')
if($failed -or $changed.Count){exit 1};exit 0
