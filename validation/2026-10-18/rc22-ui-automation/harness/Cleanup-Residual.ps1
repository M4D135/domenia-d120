$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$v='C:\Program Files\Oracle\VirtualBox\VBoxManage.exe';$target='d978ecc6-96ba-4e16-92e1-ed0b6746484e';$name='DOMENIA-RC21-FINAL';$root='C:\ADCC-Lab\VirtualBox\DOMENIA-Qualification\DOMENIA-RC21-FINAL';$receipt='C:\Users\degun\domenia-lab\vmstage\RC21-FinalCleanup.json'
function Snapshot {
 $rows=@();$vms=@(& $v list vms);if($LASTEXITCODE -ne 0){throw 'Cannot list VMs'}
 foreach($line in $vms){if($line -notmatch '^"(.*)" \{([a-fA-F0-9-]+)\}$'){throw ('Unexpected VM list: '+$line)};$n=$matches[1];$id=$matches[2];$info=@(& $v showvminfo $id --machinereadable);if($LASTEXITCODE -ne 0){throw ('Cannot inspect '+$n)};$kv=@{};foreach($row in $info){if($row -match '^([^=]+)="(.*)"$'){$kv[$matches[1]]=$matches[2].Replace('\\','\')}};$config=$kv['CfgFile'];$rows+= [pscustomobject]@{Name=$n;UUID=$id;State=$kv['VMState'];Config=$config;ConfigExists=(Test-Path -LiteralPath $config);ConfigSHA256=(Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash;Info=$info}}
 return $rows
}

$original=Get-Content -LiteralPath $receipt -Raw|ConvertFrom-Json
$originalHash=(Get-FileHash -LiteralPath $receipt -Algorithm SHA256).Hash
if($original.DeletedUUID -ne $target -or -not $original.ADServerPreservedRunning -or @($original.Others|Where-Object {-not $_.Preserved}).Count){throw 'Unexpected initial cleanup receipt'}
$before=@(Snapshot)
if(@($before|Where-Object {$_.UUID -eq $target -or $_.Name -eq $name}).Count){throw 'Target still registered'}
$children=@(Get-ChildItem -LiteralPath $root -Force -Recurse)
$allowed=@((Join-Path $root 'Logs'),(Join-Path $root 'Logs\VBox.log'),(Join-Path $root 'Logs\VBoxHardening.log'),(Join-Path $root 'Logs\VBoxUI.log'))
foreach($item in $children){if($item.FullName -notin $allowed -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw ('Unexpected residual '+$item.FullName)}}
Remove-Item -LiteralPath (Join-Path $root 'Logs') -Recurse -Force
Remove-Item -LiteralPath $root -Force
$after=@(Snapshot);$checks=@()
foreach($old in $before){$now=@($after|Where-Object {$_.UUID -eq $old.UUID});$checks+=[pscustomobject]@{Name=$old.Name;UUID=$old.UUID;Preserved=($now.Count -eq 1 -and $now[0].State -eq $old.State -and $now[0].ConfigSHA256 -eq $old.ConfigSHA256);StateBefore=$old.State;StateAfter=if($now.Count){$now[0].State}else{'Missing'};ConfigUnchanged=($now.Count -eq 1 -and $now[0].ConfigSHA256 -eq $old.ConfigSHA256)}}
$ad=@($after|Where-Object {$_.UUID -eq '7625c944-b4fc-4f8b-ac23-c796cc1be791'})
$ok=(-not (Test-Path -LiteralPath $root)) -and @($checks|Where-Object {-not $_.Preserved}).Count -eq 0 -and $ad.Count -eq 1 -and $ad[0].State -eq 'running'
[pscustomobject]@{DateUtc=[datetime]::UtcNow.ToString('o');Success=$ok;DeletedVM=$name;DeletedUUID=$target;TemporaryFilesRemoved=(-not (Test-Path -LiteralPath $root));ADServerPreservedRunning=($ad.Count -eq 1 -and $ad[0].State -eq 'running');Others=$checks;Before=$before;After=$after;Recovery='VM and disk already removed; only three VirtualBox log files remained. Exact files checked, then residual folder removed.';InitialReceiptSHA256=$originalHash;RemovedResiduals=@($children|Select-Object FullName,Length)}|ConvertTo-Json -Depth 8|Set-Content 'C:\Users\degun\domenia-lab\vmstage\RC21-FinalCleanup-Verified.json' -Encoding UTF8
if(-not $ok){throw 'Residual cleanup verification failed'}
Write-Output 'FINAL_CLEANUP_VERIFIED'
