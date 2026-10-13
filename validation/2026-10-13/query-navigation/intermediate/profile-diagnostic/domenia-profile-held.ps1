$vbox=New-Object -ComObject VirtualBox.VirtualBox
$session=New-Object -ComObject VirtualBox.Session
$guestSession=$null;$r=[ordered]@{Kind='ControlledGuestControlSessionLifetime';NoRegistryOrSecurityChanges=$true;StartUtc=[datetime]::UtcNow.ToString('o')}
try{
 $machine=$vbox.FindMachine('CNAMTS-W11-01');$machine.LockMachine($session,1)
 $account=[string]$c.Account;$user=$account;$domain=''
 if($account -match '^([^\\]+)\\(.+)$'){$user=$Matches[2];$domain=$Matches[1]}
 $secret=[IO.File]::ReadAllText([string]$c.PasswordFile).TrimEnd("`r","`n")
 $guestSession=$session.Console.Guest.CreateSession($user,$secret,$domain,'Domenia isolated profile diagnostic')
 $secret=$null
 $r.SessionId=$guestSession.Id;$r.WaitResult=$guestSession.WaitFor(1,10000);$r.OpenedUtc=[datetime]::UtcNow.ToString('o');$r.Status=$guestSession.Status
 Start-Sleep -Seconds 8
 $guestSession.Close();$guestSession=$null;$r.ClosedUtc=[datetime]::UtcNow.ToString('o')
}catch{$r.Error=$_.Exception.Message}finally{if($null-ne$guestSession){$guestSession.Close()};if($session.State -eq 1){$session.UnlockMachine()}}
[pscustomobject]$r|ConvertTo-Json
