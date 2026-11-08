param([string]$Label='Before1',[switch]$Prepare)
$ErrorActionPreference='Stop';$root='C:\DomeniaLab\RC35-qualification';$install=Join-Path $root 'startup38\prod';$out=Join-Path $root 'startup38-results'
[void][IO.Directory]::CreateDirectory($out)
function Save($name,$data){[IO.File]::WriteAllText((Join-Path $out $name),($data|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))}
$r=[ordered]@{Label=$Label;Passed=$false;Utc=[datetime]::UtcNow.ToString('o');PS=$PSVersionTable.PSVersion.ToString();Idle=@();Timings=@{}}
try{
 if($Prepare){
  if(Test-Path $install){throw 'Measurement install already exists'}
  Expand-Archive (Join-Path $root 'Domenia_1.0_RC1.17.37_PROD.zip') (Split-Path $install)
  [void][IO.Directory]::CreateDirectory((Join-Path $install 'wad\data'))
  'Isolated startup measurement'|Set-Content (Join-Path $install 'wad\data\qualification-only.txt')
 }
 [void][IO.Directory]::CreateDirectory((Join-Path $install 'wad\data'))
 'Isolated startup measurement'|Set-Content (Join-Path $install 'wad\data\qualification-only.txt')
 $seed=Join-Path $root 'startup38-seed'
 if(Test-Path $seed){Remove-Item (Join-Path $install 'wad\data') -Recurse -Force;Copy-Item $seed (Join-Path $install 'wad\data') -Recurse}
 $r.CoreSHA256=(Get-FileHash (Join-Path $install 'wad\Domenia-Core.ps1')).Hash
 Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
 Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class StartupMetrics {
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
 [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetSystemTimes(out long idle,out long kernel,out long user);
 [StructLayout(LayoutKind.Sequential)] public class Memory {public uint length=64; public uint load; public ulong total,available,pageTotal,pageAvailable,virtualTotal,virtualAvailable,extended;}
 [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GlobalMemoryStatusEx(Memory status);
 public static double Busy(int ms){long i,k,u,ii,kk,uu;if(!GetSystemTimes(out i,out k,out u))throw new Exception("GetSystemTimes");System.Threading.Thread.Sleep(ms);if(!GetSystemTimes(out ii,out kk,out uu))throw new Exception("GetSystemTimes");long total=kk-k+uu-u;return total>0?100.0*(total-(ii-i))/total:100;}
}
'@
 $quiet=$false
 for($attempt=0;$attempt -lt 12;$attempt++){
  $samples=@(1..3|ForEach-Object {[math]::Round([StartupMetrics]::Busy(2000),2)})
  $mem=[StartupMetrics+Memory]::new();if(-not [StartupMetrics]::GlobalMemoryStatusEx($mem)){throw 'Memory sampling failed'}
  $r.Idle+=@(@{Utc=[datetime]::UtcNow.ToString('o');CpuPercent=$samples;FreeMB=[math]::Round($mem.available/1MB)})
  if(($samples|Measure-Object -Average).Average -lt 25 -and ($samples|Measure-Object -Maximum).Maximum -lt 35 -and $mem.available -gt 600MB){$quiet=$true;break}
 }
 if(-not $quiet){throw 'VM did not reach idle CPU (<25% mean, <35% peak) and 600MB free'}
 $logs=Join-Path $install 'wad\data\Logs\Domenia-startup.log';$offset=0;if(Test-Path $logs){$offset=@(Get-Content $logs -Encoding UTF8).Count}
 $sw=[Diagnostics.Stopwatch]::StartNew();$launcher=Start-Process (Join-Path $install 'Domenia.exe') -WorkingDirectory $install -PassThru
 $r.LaunchUtc=[datetime]::UtcNow.ToString('o');$r.LauncherId=$launcher.Id;Save ($Label+'-progress.json') $r
 $loginInvoked=$false;$main=$false;$app=$null;$script:currentTrace=@()
 while($sw.Elapsed.TotalSeconds -lt 180){
  if(Test-Path $logs){$script:currentTrace=@(Get-Content $logs -Encoding UTF8|Select-Object -Skip $offset)}
  if(-not $app){foreach($line in $script:currentTrace){if($line -match 'Login/APPLICATION_START.*PID=(\d+)'){$r.AppId=[int]$Matches[1];$app=Get-Process -Id $r.AppId;break}}}
  if($app){
   $app.Refresh();if($app.HasExited){throw 'App exited during startup'}
   if(-not $loginInvoked -and ($script:currentTrace -match "`tLogin/WINDOW_READY`t") -and $app.MainWindowHandle -ne 0){
    $r.Timings.LoginVisibleMs=$sw.ElapsedMilliseconds
    $w=[Windows.Automation.AutomationElement]::FromHandle($app.MainWindowHandle)
    $btn=$w.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty,'BtnWindowsLogin'))
    if(-not $btn -or -not $btn.Current.IsEnabled){throw 'Windows login action unavailable'}
    ([Windows.Automation.InvokePattern]$btn.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)).Invoke();$loginInvoked=$true
    Save ($Label+'-progress.json') $r
   }
   if($loginInvoked -and ($script:currentTrace -match "`tApres login`tOK`t") -and $app.MainWindowTitle -match 'Accueil.*Domenia' -and [StartupMetrics]::IsWindowVisible($app.MainWindowHandle)){$main=$true;break}
  }
  Start-Sleep -Milliseconds 500
 }
 if(-not $main){throw 'Main window not reached in 180 seconds'}
 $r.Timings.MainVisibleMs=$sw.ElapsedMilliseconds;$r.MainTitle=$app.MainWindowTitle;$r.AppCpuSeconds=$app.TotalProcessorTime.TotalSeconds
 $r.Endpoint='Application initialization OK and native main window visible; dashboard UI Automation traversal excluded'
 $r.SessionLocked=[bool](Get-Process LogonUI -ErrorAction SilentlyContinue)
 $r.LoggedSeconds=@{}
 foreach($line in $script:currentTrace){$fields=$line -split "`t";if($fields.Count -ge 5 -and (($fields[3] -eq 'Login/WINDOW_READY') -or ($fields[3] -eq 'Apres login' -and $fields[4] -eq 'OK'))){$time=[datetime]::ParseExact($fields[0],'yyyy-MM-dd HH:mm:ss.fff',[Globalization.CultureInfo]::InvariantCulture);$r.LoggedSeconds[$fields[3]]=[math]::Round(($time.ToUniversalTime()-[datetime]::Parse($r.LaunchUtc).ToUniversalTime()).TotalSeconds,3)}}
 $log=@(Get-Content $logs -Encoding UTF8|Select-Object -Skip $offset)
 $log|Set-Content (Join-Path $out ($Label+'-startup.log')) -Encoding UTF8
 if(-not ($log -match "`tApres login`tOK`t")){throw 'Main startup completion trace missing'}
 if($log -match "`tERROR`t"){throw 'Startup reported an error'}
 if(-not $app.CloseMainWindow()){throw 'Normal application close rejected'}
 if(-not $app.WaitForExit(20000)){throw 'Application did not close normally'}
 $r.ClosedNormally=$true;$r.Passed=$true
}catch{$r.Error=$_.Exception.Message;$r.Stack=$_.ScriptStackTrace}
finally{Save ($Label+'.json') $r}
if(-not $r.Passed){exit 1}
