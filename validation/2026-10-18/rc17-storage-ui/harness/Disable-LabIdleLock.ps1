$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -ne 'W11-01'){throw 'Lab W11-01 only'}
$out='C:\DomeniaLab\d120-rc11717-live\storage-ui-out'
$desktop='HKCU:\Control Panel\Desktop';$system='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$before=[ordered]@{DateUtc=[datetime]::UtcNow.ToString('o');Computer=$env:COMPUTERNAME;User=[Security.Principal.WindowsIdentity]::GetCurrent().Name;Desktop=(Get-ItemProperty $desktop|Select-Object ScreenSaveActive,ScreenSaverIsSecure,ScreenSaveTimeOut);InactivityTimeoutSecs=(Get-ItemProperty $system -Name InactivityTimeoutSecs -ErrorAction SilentlyContinue).InactivityTimeoutSecs;Power=(powercfg /query SCHEME_CURRENT SUB_SLEEP);Display=(powercfg /query SCHEME_CURRENT SUB_VIDEO)}
$path=Join-Path $out 'IdleLockBefore.json';if(-not(Test-Path $path)){[IO.File]::WriteAllText($path,($before|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))}
Set-ItemProperty $desktop -Name ScreenSaveActive -Value '0'
Set-ItemProperty $desktop -Name ScreenSaverIsSecure -Value '0'
New-ItemProperty $system -Name InactivityTimeoutSecs -PropertyType DWord -Value 0 -Force|Out-Null
powercfg /change monitor-timeout-ac 0
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
$r=[ordered]@{Computer=$env:COMPUTERNAME;Desktop=(Get-ItemProperty $desktop|Select-Object ScreenSaveActive,ScreenSaverIsSecure);InactivityTimeoutSecs=(Get-ItemProperty $system -Name InactivityTimeoutSecs).InactivityTimeoutSecs;AcDisplaySleepHibernateDisabled=$true}
[IO.File]::WriteAllText((Join-Path $out 'IdleLockAfter.json'),($r|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false));$r|ConvertTo-Json -Depth 4
