$ErrorActionPreference='Stop';$root='C:\DomeniaLab\RC35-qualification';$dev=Join-Path $root 'RC39-critical\dev';$out=Join-Path $root 'rc39-critical-tests'
[void][IO.Directory]::CreateDirectory($out)
function Save($name,$value){[IO.File]::WriteAllText((Join-Path $out $name),($value|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
$rows=[Collections.Generic.List[object]]::new()
try {
 $bindings=@{};foreach($file in @('wad/Domenia-Core.ps1','wad/Domenia-Modules.ps1','wad/Domenia.release.json','wad/package-manifest.json')){$bindings[$file]=(Get-FileHash (Join-Path $dev $file) -Algorithm SHA256).Hash}
 Save 'Environment.json' @{PSVersion=$PSVersionTable.PSVersion.ToString();Is64Bit=[Environment]::Is64BitProcess;Apartment=[Threading.Thread]::CurrentThread.ApartmentState.ToString();SourceBindings=$bindings;StartedUtc=[datetime]::UtcNow.ToString('o')}
 & "$PSHOME\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $dev 'wad\Domenia-Start.ps1') -CheckOnly *> (Join-Path $out 'StartupIntegrity.log')
 Save 'StartupIntegrity.json' @{Passed=($LASTEXITCODE -eq 0);ExitCode=$LASTEXITCODE}
 & "$PSHOME\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $dev 'tools\Test-DomeniaPs51Compat.ps1') -Root $dev -ReportPath (Join-Path $out 'Ps51Compat.json') *> (Join-Path $out 'Ps51Compat.log')
 foreach($name in @('LocalPreview','LiveSearchView','StoragePreferences','WiringCache','StorageMaintenance','StorageFaults','RemoteStore','CollectCircuit','HealthRules','StartupLogin')){
  $file=Join-Path $dev ('wad\tests\Test-Domenia'+$name+'.ps1');if(-not(Test-Path -LiteralPath $file)){throw ('Missing test '+$name)}
  $start=[datetime]::UtcNow;Save 'Running.json' @{Running=$name;Start=$start.ToString('o')}
  $p=Start-Process "$PSHOME\powershell.exe" -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$file,'-ReportPath',(Join-Path $out ($name+'.json'))) -PassThru -RedirectStandardOutput (Join-Path $out ($name+'.log')) -RedirectStandardError (Join-Path $out ($name+'-error.log'))
  $handle=$p.Handle;$timeout=-not $p.WaitForExit(480000);if($timeout){Stop-Process -Id $p.Id -Force}
  $rows.Add([pscustomobject]@{Test=$name;ExitCode=$(if($timeout){-999}else{$p.ExitCode});TimedOut=$timeout;ReportPresent=(Test-Path (Join-Path $out ($name+'.json')));WallSeconds=([datetime]::UtcNow-$start).TotalSeconds})
  Save 'Progress.json' $rows.ToArray()
 }
 Save 'Done.json' @{Finished=$true;FinishedUtc=[datetime]::UtcNow.ToString('o');Failed=@($rows|Where-Object { $_.TimedOut -or $_.ExitCode -ne 0 -or -not $_.ReportPresent}).Count}
} catch {Save 'Fatal.json' @{Error=$_.Exception.Message;Stack=$_.ScriptStackTrace};exit 1}
