param([switch]$Run)
$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\d120-rc11720-qualification';$out=Join-Path $root 'out\disposable-profile';$name='DomeniaRC20Test'
[void][IO.Directory]::CreateDirectory($out)
if(-not $Run){
 $user=(Get-CimInstance Win32_ComputerSystem).UserName
 $saved=Join-Path $root 'Test-DisposableProfile.ps1';Copy-Item $PSCommandPath $saved -Force
 $a=New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument ('-NoProfile -ExecutionPolicy Bypass -File "'+$saved+'" -Run')
 Register-ScheduledTask Domenia-RC20-DisposableProfile -Action $a -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest) -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 6)) -Force|Out-Null
 Start-ScheduledTask Domenia-RC20-DisposableProfile;'Disposable-profile qualification dispatched';exit
}
if(Test-Path (Join-Path $out 'Result.json')){Move-Item (Join-Path $out 'Result.json') (Join-Path $out ('Attempt-'+[guid]::NewGuid().ToString('N')+'.json'))}
foreach($f in @(Get-ChildItem $out -File|Where-Object {$_.Name -eq 'Child.json' -or $_.Name -match '^(install|reinstall|uninstall-).*\.txt$'})){Move-Item $f.FullName (Join-Path $out ('Prior-'+[guid]::NewGuid().ToString('N')+'-'+$f.Name))}
$r=[ordered]@{Build='RC1.17.20';StartedUtc=[datetime]::UtcNow.ToString('o');Passed=$false;UserRemoved=$false;ProfileRemoved=$false};$created=$false;$sid='';$p=$null
try{
 if(Get-LocalUser $name -ErrorAction SilentlyContinue){throw 'Disposable account already exists; refusing to reuse'}
 $zip='C:\DomeniaLab\d120-rc11720-final\Domenia_PROD.zip'
 if((Get-FileHash $zip -Algorithm SHA256).Hash -cne '71E4DB913EE613E68F167A9F384F99C2623922401678458DFA9B957F7E3CB609'){throw 'Unexpected PROD archive'}
 $source=Join-Path $root 'disposable-source';if(-not(Test-Path $source)){Expand-Archive $zip $source}
 $plain='A!7'+[guid]::NewGuid().ToString('N')+[guid]::NewGuid().ToString('N');$secret=ConvertTo-SecureString $plain -AsPlainText -Force;$plain=$null
 $user=New-LocalUser $name -Password $secret -Description 'Temporary Domenia RC20 qualification';$created=$true;$sid=$user.SID.Value;$r.UserSid=$sid
 Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $user
 $cred=[pscredential]::new(([Environment]::MachineName+'\'+$name),$secret)
 $acl=Get-Acl $out;$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'Modify','ContainerInherit,ObjectInherit','None','Allow'));Set-Acl $out $acl
 $child=Join-Path $root 'Profile-Child.ps1'
 @'
$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\d120-rc11720-qualification';$out=Join-Path $root 'out\disposable-profile'
$r=[ordered]@{Passed=$false;Checks=@()}
function Check($ok,$name){$r.Checks+=,[pscustomobject]@{Name=$name;Passed=[bool]$ok};if(-not $ok){throw $name}}
try{
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$principal=[Security.Principal.WindowsPrincipal]::new($identity)
 Check ($identity.Name -like '*\DomeniaRC20Test') 'Dedicated disposable identity'
 Check (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Standard non-administrator token'
 $profile=[Environment]::GetFolderPath('LocalApplicationData');Check ($profile -like 'C:\Users\DomeniaRC20Test*\AppData\Local') 'Real disposable Windows profile'
 $r.Identity=$identity.Name;$r.Profile=$profile
 $dest=Join-Path $profile 'DomeniaQualification\Installed';$installer=Join-Path $root 'disposable-source\prod\wad\Support\INSTALLER-MISE-A-JOUR.ps1'
 $shell=Join-Path $PSHOME 'powershell.exe'
 function Installer($phase,[string]$options){
   $cmd='& "'+$installer+'" -Destination "'+$dest+'" '+$options+' -Confirm:$false'
   $enc=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
   $p=Start-Process $shell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$enc) -Wait -PassThru -RedirectStandardOutput (Join-Path $out ($phase+'.stdout.txt')) -RedirectStandardError (Join-Path $out ($phase+'.stderr.txt'))
   Check ($p.ExitCode -eq 0) ($phase+' exit 0')
 }
 Installer install '-Install -Shortcuts Non'
 Check (Test-Path (Join-Path $dest 'Domenia.exe')) 'Installed launcher exists'
 $domainData=Join-Path $profile 'Domenia\Data';$receipts=Join-Path $profile 'Domenia\Receipts';$logs=Join-Path $domainData 'Logs';$local=Join-Path $dest 'wad\data'
 foreach($d in @($domainData,$receipts,$logs,$local)){[void][IO.Directory]::CreateDirectory($d)}
 [IO.File]::WriteAllText((Join-Path $domainData 'fixture.txt'),'disposable-only');[IO.File]::WriteAllText((Join-Path $local 'fixture.txt'),'disposable-only')
 [IO.File]::WriteAllText((Join-Path $receipts 'closed.json'),'{"Format":"1","Stage":"Verified"}')
 $sentinel=Join-Path $profile 'OutsideDomenia.txt';[IO.File]::WriteAllText($sentinel,'preserve')
 Installer uninstall-keep '-Uninstall -LocalData Conserver -ProfileData Conserver'
 Check ((Test-Path (Join-Path $domainData 'fixture.txt')) -and (Test-Path (Join-Path $local 'fixture.txt'))) 'Explicit preservation retains both data locations'
 $dest=Join-Path $profile 'DomeniaQualification\Installed2'
 Installer reinstall '-Install -Shortcuts Non'
 $local=Join-Path $dest 'wad\data';[void][IO.Directory]::CreateDirectory($local);[IO.File]::WriteAllText((Join-Path $local 'fixture.txt'),'disposable-only')
 Installer uninstall-delete '-Uninstall -LocalData Supprimer -ProfileData Supprimer'
 Check (-not(Test-Path $domainData) -and -not(Test-Path $receipts) -and -not(Test-Path $logs)) 'Explicit profile deletion removes Domenia data logs receipts'
 Check (-not(Test-Path $local) -and -not(Test-Path (Join-Path $dest 'Domenia.exe'))) 'Explicit local deletion removes installed code and local data'
 Check ((Get-Content $sentinel -Raw) -ceq 'preserve') 'Unrelated profile sentinel retained'
 $r.Passed=$true
}catch{$r.Error=$_.Exception.Message;$r.Stack=$_.ScriptStackTrace}
finally{[IO.File]::WriteAllText((Join-Path $out 'Child.json'),($r|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
if(-not $r.Passed){exit 1}
'@ | Set-Content -LiteralPath $child -Encoding UTF8
 $p=Start-Process (Join-Path $PSHOME 'powershell.exe') -Credential $cred -LoadUserProfile -WorkingDirectory $root -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$child) -PassThru
 $null=$p.Handle;if(-not $p.WaitForExit(240000)){Stop-Process -Id $p.Id -Force;throw 'Disposable test budget exceeded'};$p.WaitForExit();$r.ExitCode=$p.ExitCode
 $r.Child=Get-Content (Join-Path $out 'Child.json') -Raw -Encoding UTF8|ConvertFrom-Json
 if($r.ExitCode -ne 0 -or -not $r.Child.Passed){throw 'Disposable child failed'};$r.Passed=$true
}catch{$r.Error=$_.Exception.Message;$r.Stack=$_.ScriptStackTrace}
finally{
 if($created){
  try{$profile=Get-CimInstance Win32_UserProfile|Where-Object SID -eq $sid;if($profile -and $profile.Loaded){throw 'Disposable profile remains loaded'};if($profile){$profile|Remove-CimInstance};$r.ProfileRemoved=$true;Remove-LocalUser -SID $sid;$r.UserRemoved=$true}catch{$r.CleanupError=$_.Exception.Message;$r.Passed=$false}
 }
 $r.FinishedUtc=[datetime]::UtcNow.ToString('o');[IO.File]::WriteAllText((Join-Path $out 'Result.json'),($r|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
