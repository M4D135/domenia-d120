$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$v='C:\Program Files\Oracle\VirtualBox\VBoxManage.exe';$target='d978ecc6-96ba-4e16-92e1-ed0b6746484e';$name='DOMENIA-RC21-FINAL';$root='C:\ADCC-Lab\VirtualBox\DOMENIA-Qualification\DOMENIA-RC21-FINAL';$receipt='C:\Users\degun\domenia-lab\vmstage\RC21-FinalCleanup.json'
function Snapshot {
 $rows=@();$vms=@(& $v list vms);if($LASTEXITCODE -ne 0){throw 'Cannot list VMs'}
 foreach($line in $vms){if($line -notmatch '^"(.*)" \{([a-fA-F0-9-]+)\}$'){throw ('Unexpected VM list: '+$line)};$n=$matches[1];$id=$matches[2];$info=@(& $v showvminfo $id --machinereadable);if($LASTEXITCODE -ne 0){throw ('Cannot inspect '+$n)};$kv=@{};foreach($row in $info){if($row -match '^([^=]+)="(.*)"$'){$kv[$matches[1]]=$matches[2].Replace('\\','\')}};$config=$kv['CfgFile'];$rows+= [pscustomobject]@{Name=$n;UUID=$id;State=$kv['VMState'];Config=$config;ConfigExists=(Test-Path -LiteralPath $config);ConfigSHA256=(Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash;Info=$info}}
 return $rows
}
$before=@(Snapshot);$vm=@($before|Where-Object {$_.UUID -eq $target});if($vm.Count -ne 1 -or $vm[0].Name -ne $name){throw 'Temporary VM identity mismatch'}
if($vm[0].Config -ne (Join-Path $root ($name+'.vbox'))){throw ('Unexpected config '+$vm[0].Config)}
$diskLines=@($vm[0].Info|Where-Object {$_ -match '^"?[^=]+"?=".*\.(vdi|vmdk|vhd)"$'})
if($diskLines.Count -ne 1){throw ('Unexpected disk count '+$diskLines.Count)}
foreach($line in $diskLines){$disk=($line -split '=',2)[1].Trim('"').Replace('\\','\');if(-not $disk.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw ('Non-disposable attached disk '+$disk)}}
if($vm[0].State -eq 'running'){& $v controlvm $target poweroff;if($LASTEXITCODE -ne 0){throw 'Cannot stop temporary VM'}}elseif($vm[0].State -ne 'poweroff'){throw ('Unexpected temporary VM state '+$vm[0].State)}
& $v unregistervm $target --delete;if($LASTEXITCODE -ne 0){throw 'VM deletion failed'}
if((Test-Path -LiteralPath $root) -and @(Get-ChildItem -LiteralPath $root -Force).Count -eq 0){Remove-Item -LiteralPath $root -Force}
$after=@(Snapshot);$kept=@($before|Where-Object {$_.UUID -ne $target});$checks=@()
foreach($old in $kept){$now=@($after|Where-Object {$_.UUID -eq $old.UUID});$ok=$now.Count -eq 1 -and $now[0].Name -eq $old.Name -and $now[0].State -eq $old.State -and $now[0].Config -eq $old.Config -and $now[0].ConfigExists;$checks += [pscustomobject]@{Name=$old.Name;UUID=$old.UUID;Preserved=$ok;StateBefore=$old.State;StateAfter=if($now.Count){$now[0].State}else{'Missing'};ConfigUnchanged=($now.Count -eq 1 -and $now[0].ConfigSHA256 -eq $old.ConfigSHA256)}}
$removed=(@($after|Where-Object {$_.UUID -eq $target -or $_.Name -eq $name}).Count -eq 0) -and (-not (Test-Path -LiteralPath $root));$ad=@($after|Where-Object {$_.UUID -eq '7625c944-b4fc-4f8b-ac23-c796cc1be791'});$ok=$removed -and @($checks|Where-Object {-not $_.Preserved}).Count -eq 0 -and $ad.Count -eq 1 -and $ad[0].State -eq 'running'
[pscustomobject]@{DateUtc=[datetime]::UtcNow.ToString('o');Success=$ok;DeletedVM=$name;DeletedUUID=$target;TemporaryFilesRemoved=$removed;ADServerPreservedRunning=($ad.Count -eq 1 -and $ad[0].State -eq 'running');Others=$checks;Before=$before;After=$after}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $receipt -Encoding UTF8
if(-not $ok){throw 'Cleanup verification incomplete; inspect receipt'}
Write-Output ('CLEANUP_OK '+$receipt)
