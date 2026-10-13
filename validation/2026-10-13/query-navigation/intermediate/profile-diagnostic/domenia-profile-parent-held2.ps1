$ErrorActionPreference='Stop'
$r='C:\DomeniaLab\query-navigation-20261013-r5';$out="$r\profile-diagnostic"
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
Start-Sleep -Seconds 5
$w=[Diagnostics.Stopwatch]::StartNew();$seen=$false
while($w.Elapsed.TotalSeconds -lt 45){
 $k=[Microsoft.Win32.Registry]::Users.OpenSubKey($sid)
 if($null -ne $k){$k.Dispose();$seen=$true;break}
 Start-Sleep -Milliseconds 5
}
$st=[datetime]::UtcNow.ToString('o')
if($seen){
 $p=Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',"$r\profile-child.ps1",'-Case','spawned-held-session2','-WaitSeconds','12') -PassThru -NoNewWindow -RedirectStandardOutput "$out\spawned.stdout.txt" -RedirectStandardError "$out\spawned.stderr.txt"
 $null=$p.Handle;$null=$p.WaitForExit(90000);$p.WaitForExit();$ec=$p.ExitCode
}else{$ec=$null}
[IO.File]::WriteAllText("$out\parent-held2.json",(@{StartedChildUTC=$st;ObservedLoadedHive=$seen;ChildExitCode=$ec}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
