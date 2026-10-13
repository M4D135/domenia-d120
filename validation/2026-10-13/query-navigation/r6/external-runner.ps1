param([Parameter(Mandatory=$true)][string]$ExpectedZip,[Parameter(Mandatory=$true)][string]$ExpectedCapture)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$r='C:\DomeniaLab\query-navigation-20261013-r6'
if((Get-FileHash "$r\dev.zip" -Algorithm SHA256).Hash -ine $ExpectedZip){throw 'Archive hash mismatch'}
if((Get-FileHash "$r\capture-guides.ps1" -Algorithm SHA256).Hash -ine $ExpectedCapture){throw 'Capture harness hash mismatch'}
if(Test-Path "$r\source"){throw 'Preserve existing staging; use a fresh revision directory'}
Expand-Archive -LiteralPath "$r\dev.zip" -DestinationPath "$r\source"
[void][IO.Directory]::CreateDirectory("$r\proof");[void][IO.Directory]::CreateDirectory("$r\captures")
$proof="$r\proof";$dev="$r\source\dev";$exe="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
[IO.File]::WriteAllText("$proof\package.json",([pscustomobject]@{DEV=$ExpectedZip;CaptureScriptSHA256=$ExpectedCapture;Data='Synthetic fixtures; no Active Directory, endpoint WMI or ping';Machine=$env:COMPUTERNAME;UTC=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText("$proof\text-encodings.json",([pscustomobject]@{ConsoleOutputCodePage=[Console]::OutputEncoding.CodePage;AnsiCodePage=[Text.Encoding]::Default.CodePage}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
function Save-ProfileSnapshot([string]$Stage) {
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 $s=[ordered]@{UTC=[datetime]::UtcNow.ToString('o');Stage=$Stage;PID=$PID;SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId;SID=$sid;GuestControlProfileOptionRequested=$false;ConcurrentGuestAuthenticatedOperations='Forbidden for this campaign; host COM process status only'}
 try{$s.HKCU=[Microsoft.Win32.Registry]::CurrentUser.SubKeyCount}catch{$s.HKCUError=$_.Exception.ToString()}
 try{$k=[Microsoft.Win32.Registry]::Users.OpenSubKey($sid);$s.HkuSidPresent=($null-ne$k);if($k){$s.HkuSidSubKeys=$k.SubKeyCount;$k.Dispose()}}catch{$s.HkuError=$_.Exception.ToString()}
 try{$s.Profile=@(Get-CimInstance Win32_UserProfile -Filter "SID='$sid'"|Select-Object SID,Loaded,Status,Special)}catch{$s.ProfileError=$_.Exception.ToString()}
 [IO.File]::WriteAllText("$proof\profile-$Stage.json",($s|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
}
Save-ProfileSnapshot 'start'
$receipts=[Collections.Generic.List[object]]::new()
function Invoke-RecordedProcess {
 param([string]$Name,[string[]]$Arguments,[int]$TimeoutSeconds)
 if(Test-Path -LiteralPath "$r\stop-after-current"){
  [IO.File]::WriteAllText("$proof\stopped-by-request.json",([pscustomobject]@{UTC=[datetime]::UtcNow.ToString('o');Before=$Name;Qualified=$false;ChildTerminated=$false}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
  exit 99
 }
 $watch=[Diagnostics.Stopwatch]::StartNew();$start=[datetime]::UtcNow.ToString('o')
 $p=Start-Process -FilePath $exe -ArgumentList (@('-NoLogo','-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass')+$Arguments) -PassThru -NoNewWindow -RedirectStandardOutput "$proof\$Name.stdout.txt" -RedirectStandardError "$proof\$Name.stderr.txt"
 $null=$p.Handle;$timeout=-not $p.WaitForExit($TimeoutSeconds*1000)
 if($timeout){try{$p.Kill()}catch{};$p.WaitForExit();$code=$null}else{$p.WaitForExit();$code=$p.ExitCode}
 $watch.Stop();$receipt=[pscustomobject]@{Name=$Name;StartUTC=$start;EndUTC=[datetime]::UtcNow.ToString('o');ExitCode=$code;TimedOut=$timeout;Milliseconds=$watch.ElapsedMilliseconds}
 $receipts.Add($receipt);[IO.File]::WriteAllText("$proof\$Name-process.json",($receipt|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
}
# R5 captures are reused only after immutable package and image SHA checks in export.
Invoke-RecordedProcess -Name 'PRODArchiveCheck' -TimeoutSeconds 180 -Arguments @('-File',"$r\prod-check.ps1")
Invoke-RecordedProcess -Name 'Test-DomeniaWiringRecherche' -TimeoutSeconds 180 -Arguments @('-File',"$dev\wad\tests\Test-DomeniaWiringRecherche.ps1",'-ReportPath',"$proof\Test-DomeniaWiringRecherche.json")
Invoke-RecordedProcess -Name 'ExtendedRunner' -TimeoutSeconds 10800 -Arguments @('-File',"$dev\engineering\d120\quick-ui-20261012\Invoke-DomeniaQuickUi.ps1",'-DevRoot',$dev,'-OutDir',$proof,'-SuiteTimeoutSeconds','300','-Extended')
Invoke-RecordedProcess -Name 'AdditionalRunner' -TimeoutSeconds 10800 -Arguments @('-File',"$dev\engineering\d120\quick-ui-20261012\Invoke-DomeniaAdditionalUi.ps1",'-DevRoot',$dev,'-OutDir',$proof,'-SuiteTimeoutSeconds','300')
Invoke-RecordedProcess -Name 'AllOfflineRunner' -TimeoutSeconds 14400 -Arguments @('-File',"$dev\engineering\d120\quick-ui-20261012\Invoke-DomeniaAllOffline.ps1",'-DevRoot',$dev,'-OutDir',$proof,'-SuiteTimeoutSeconds','300')
[IO.File]::WriteAllText("$proof\run-complete.json",([pscustomobject]@{UTC=[datetime]::UtcNow.ToString('o');Processes=$receipts.ToArray();AllProcessesPassed=(@($receipts|Where-Object{$_.TimedOut -or $_.ExitCode -ne 0}).Count -eq 0)}|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))

Save-ProfileSnapshot 'end'
