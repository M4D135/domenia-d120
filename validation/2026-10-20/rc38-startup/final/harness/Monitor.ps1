$ErrorActionPreference='Stop';$v='C:\Program Files\Oracle\VirtualBox\VBoxManage.exe';$vm='bc2f1ac0-9545-49bd-a0f5-cb89d352cf61';$stage='C:\Users\degun\domenia-lab\vmstage'
$b=New-Object -ComObject VirtualBox.VirtualBox;$m=$b.FindMachine($vm)
if($m.Name -cne 'DOMENIA-FIRSTRUN-20261020'){throw 'Unexpected VM'}
$sw=[Diagnostics.Stopwatch]::StartNew();$last='';$records=@();$wake=-30;$maxGap=0;$lastMs=0
while($sw.Elapsed.TotalMinutes -lt 30){
 $now=$sw.Elapsed.TotalMilliseconds;$maxGap=[math]::Max($maxGap,$now-$lastMs);$lastMs=$now
 $value=$m.GetGuestPropertyValue('/Domenia/RC38/Qualification')
 if($value -and $value -ne $last){
  $records+=@([pscustomobject]@{Value=$value;ElapsedMs=[math]::Round($sw.Elapsed.TotalMilliseconds,2);Utc=[datetime]::UtcNow.ToString('o');MaxPollingGapMs=[math]::Round($maxGap,2)})
  $records|ConvertTo-Json|Set-Content (Join-Path $stage 'RC38-HostTiming.json') -Encoding UTF8
  Write-Output $value;$last=$value;$maxGap=0
  if($value -eq 'Complete'){break}
 }
 if($sw.Elapsed.TotalSeconds-$wake -ge 25){& $v controlvm $vm keyboardputscancode 1d 9d;$wake=$sw.Elapsed.TotalSeconds}
 Start-Sleep -Milliseconds 100
}
