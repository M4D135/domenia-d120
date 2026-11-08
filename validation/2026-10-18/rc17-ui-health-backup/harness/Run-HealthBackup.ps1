$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\d120-rc11717-live'
$out=Join-Path $root 'critical-out'
[void][IO.Directory]::CreateDirectory($out)
function Save-Json($Name,$Value){[IO.File]::WriteAllText((Join-Path $out $Name),($Value|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}
if($env:COMPUTERNAME -ne 'W11-01' -or $PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Wrong test environment'}
$expected=@{prod='0393c1b7fd23e732209d3f96c4c91196afcb57ba26f02e86d79bbbc7eb4e908a';dev='001ae72db21059bda3ad5ac72e810d8c69e20b948e2fc18c224f5b070a2eb04b'}
$packs=@()
foreach($edition in @('prod','dev')){
 $zip=Join-Path $root ('Domenia_'+$edition.ToUpper()+'.zip');$hash=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
 if($hash -ne $expected[$edition]){throw ('Wrong archive '+$edition)}
 if(-not (Test-Path (Join-Path $root ($edition+'\wad\package-manifest.json')))){Expand-Archive -LiteralPath $zip -DestinationPath $root -Force}
 $base=Join-Path $root $edition;$m=Get-Content (Join-Path $base 'wad\package-manifest.json') -Raw|ConvertFrom-Json
 foreach($f in $m.Files){$path=Join-Path $base $f.Path;if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $f.Sha256){throw ('Manifest mismatch '+$f.Path)}}
 $packs+=@([pscustomobject]@{Edition=$edition;Build=$m.Build;ArchiveSha256=$hash;ManifestFilesVerified=@($m.Files).Count;RuntimeFiles=@($m.Files|Where-Object Runtime).Count})
}
$prod=Get-Content (Join-Path $root 'prod\wad\package-manifest.json') -Raw|ConvertFrom-Json
foreach($f in $prod.Files|Where-Object Runtime){if((Get-FileHash (Join-Path $root ('dev\'+$f.Path)) -Algorithm SHA256).Hash -ne $f.Sha256){throw ('Runtime differs between PROD and DEV: '+$f.Path)}}
Save-Json 'Environment.json' ([ordered]@{DateUtc=[datetime]::UtcNow.ToString('o');Computer=$env:COMPUTERNAME;PSVersion=$PSVersionTable.PSVersion.ToString();PSEdition=$PSVersionTable.PSEdition;Is64Bit=[Environment]::Is64BitProcess;Apartment=[Threading.Thread]::CurrentThread.ApartmentState.ToString();SessionId=(Get-Process -Id $PID).SessionId;FreeGB=[math]::Round((Get-PSDrive C).Free/1GB,1);SourceCommit='f7a3ee73461588f29b094f9a4810c09eeac6406a';Packs=$packs;IdenticalRuntime=$true;LiveAD=$false;Scope='Health and backup targeted checks; native SQLite with isolated test data. Not full acceptance.'})
$results=[Collections.Generic.List[object]]::new()
function Run-Test([string]$Name,[string]$Code,[int]$Seconds=90){
 $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code));$watch=[Diagnostics.Stopwatch]::StartNew()
 $p=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-STA','-EncodedCommand',$encoded) -RedirectStandardOutput (Join-Path $out ($Name+'.stdout.log')) -RedirectStandardError (Join-Path $out ($Name+'.stderr.log')) -PassThru
 $null=$p.Handle
 $finished=$p.WaitForExit($Seconds*1000)
 if(-not $finished){Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue}else{$p.WaitForExit();$p.Refresh()}
 $exit=$null;if($finished){$exit=$p.ExitCode}
 $r=[pscustomobject]@{Name=$Name;Passed=($finished -and $exit -eq 0);ExitCode=$exit;TimedOut=(-not $finished);DurationMs=$watch.ElapsedMilliseconds;Code=$Code};$results.Add($r)
 Save-Json 'Runs.json' $results.ToArray()
 Write-Output ($Name+': '+$r.Passed+' ('+$r.DurationMs+' ms)')
}
$tests=Join-Path $root 'dev\wad\tests'
Run-Test 'HealthRules' "& '$tests\Test-DomeniaHealthRules.ps1' -ReportPath '$out\HealthRules.json'"
Run-Test 'HealthAdvanced' "& '$tests\Test-DomeniaHealthAdvanced.ps1' -ReportPath '$out\HealthAdvanced.json'"
Run-Test 'StorageMaintenance' "& '$tests\Test-DomeniaStorageMaintenance.ps1' -CaseFilter 'Policy defaults|Backup scheduling|Backup is standalone|Restore uses|Point 34:|Point 36: integrity check|RC13: asynchronous switch' -ReportPath '$out\StorageMaintenance.json'"
$failed=@($results|Where-Object{-not $_.Passed}).Count
Write-Output ('Critical checks: '+($results.Count-$failed)+' passed; '+$failed+' failed')
if($failed){exit 1}
exit 0
