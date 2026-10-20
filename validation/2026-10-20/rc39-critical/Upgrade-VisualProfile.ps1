$ErrorActionPreference='Stop';$root='C:\DomeniaLab\RC35-qualification';$target=Join-Path $root 'RC39-critical-ui\prod'
if(@(Get-CimInstance Win32_Process|Where-Object {$_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*RC39-critical-ui*'}).Count){throw 'Application still running'}
if(-not(Test-Path ($target+'\wad\data'))){throw 'Original test profile absent'}
$temp=Join-Path $root ('upgrade-'+[guid]::NewGuid().ToString('N'));Expand-Archive (Join-Path $root 'Domenia_1.0_RC1.17.39_PROD.zip') $temp
foreach($f in Get-ChildItem ($temp+'\prod') -Recurse -File){$rel=$f.FullName.Substring(($temp+'\prod\').Length);if($rel -like 'wad\data\*'){throw 'Archive contains data'};$dest=Join-Path $target $rel;[void][IO.Directory]::CreateDirectory((Split-Path $dest -Parent));Copy-Item -LiteralPath $f.FullName -Destination $dest -Force}
$expected=Get-Content (Join-Path $root 'UpgradeHashes.json') -Raw -Encoding UTF8|ConvertFrom-Json
foreach($e in $expected){if((Get-FileHash (Join-Path $target $e.Path) -Algorithm SHA256).Hash -cne $e.Sha256){throw ('Hash '+$e.Path)}}
[IO.File]::WriteAllText(($root+'\UpgradeVisualApplied.json'),(@{Files=$expected.Count;Target=$target;ProfilePathUnchanged=$true;Utc=[datetime]::UtcNow.ToString('o');ArchiveSha256=(Get-FileHash ($root+'\Domenia_1.0_RC1.17.39_PROD.zip') -Algorithm SHA256).Hash}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
