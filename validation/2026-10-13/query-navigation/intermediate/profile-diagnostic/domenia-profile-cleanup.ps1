$vbox=New-Object -ComObject VirtualBox.VirtualBox
$session=New-Object -ComObject VirtualBox.Session
$closed=[Collections.Generic.List[object]]::new()
try {
 $machine=$vbox.FindMachine('CNAMTS-W11-01');$machine.LockMachine($session,1)
 foreach($gs in @($session.Console.Guest.Sessions)){
  if($gs.Id -lt 20 -or $gs.Id -gt 28){continue}
  $ps=@($gs.Processes)
  if($ps.Count -ne 1 -or $ps[0].Status -ne 500){continue}
  $paths=@($ps[0].Arguments|Where-Object {$_ -match '^C:\\DomeniaLab\\query-navigation-20261013-r(?:4-diagnostic1[67]\\run|4\\(?:run|stop-after-quick)|5\\(?:run|health))\.ps1$'})
  if($paths.Count -ne 1){continue}
  $closed.Add([pscustomobject]@{SessionId=$gs.Id;ProcessId=$ps[0].PID;Status='Successfully terminated';Script=$paths[0]});$gs.Close()
 }
}finally{if($session.State -eq 1){$session.UnlockMachine()}}
[pscustomobject]@{UTC=[datetime]::UtcNow.ToString('o');Closed=$closed.ToArray();ActiveProcessTerminated=$false}|ConvertTo-Json -Depth 5
