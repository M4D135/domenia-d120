$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$r='C:\DomeniaLab\ou-refresh-20261013-r1';$sha='8ca88099a10c8c5f02cf2d7bb99be131a1ff9b70002cc1737dabd2dc1a7888be'
if((Get-FileHash "$r\prod.zip" -Algorithm SHA256).Hash -ine $sha){throw 'PROD archive SHA mismatch'}
if(Test-Path "$r\prod-source"){throw 'PROD staging already exists'}
Expand-Archive -LiteralPath "$r\prod.zip" -DestinationPath "$r\prod-source"
$watch=[Diagnostics.Stopwatch]::StartNew();$exe="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$p=Start-Process -FilePath $exe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-File',"$r\prod-source\prod\wad\Domenia-Start.ps1",'-CheckOnly') -PassThru -NoNewWindow -RedirectStandardOutput "$r\proof\PROD-CheckOnly.stdout.txt" -RedirectStandardError "$r\proof\PROD-CheckOnly.stderr.txt"
$null=$p.Handle;$timeout=-not $p.WaitForExit(120000)
if($timeout){try{$p.Kill()}catch{};$p.WaitForExit();$code=$null}else{$p.WaitForExit();$code=$p.ExitCode}
$watch.Stop();$report=[pscustomobject]@{PROD_SHA256=$sha;ExitCode=$code;TimedOut=$timeout;Milliseconds=$watch.ElapsedMilliseconds;Command='Domenia-Start.ps1 -CheckOnly';EXEStarted=$false;ADAccessed=$false}
[IO.File]::WriteAllText("$r\proof\PROD-CheckOnly-process.json",($report|ConvertTo-Json),[Text.UTF8Encoding]::new($false))

if($timeout -or $code -ne 0){exit 1};exit 0
