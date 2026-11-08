#requires -Version 5.1
$root='C:\Windows\Temp\Domenia-RC22-Final';$dev=Join-Path $root 'dev';$out=Join-Path $root 'gui-final';[void][IO.Directory]::CreateDirectory($out)
$ErrorActionPreference='Stop'
try{
 Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class LabKeepAwake {
 [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);
 [DllImport("user32.dll", SetLastError=true)] public static extern bool SystemParametersInfo(uint action, uint value, IntPtr parameter, uint flags);
}
'@
 [void][LabKeepAwake]::SetThreadExecutionState([uint32]2147483651)
 [void][LabKeepAwake]::SystemParametersInfo(17,0,[IntPtr]::Zero,2)
 Add-Type -AssemblyName System.Windows.Forms
 [pscustomobject]@{SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId;User=[Security.Principal.WindowsIdentity]::GetCurrent().Name;Screen=[Windows.Forms.Screen]::PrimaryScreen.Bounds.ToString();WorkingArea=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea.ToString();StartedUtc=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content (Join-Path $out 'environment.json') -Encoding UTF8
 & "$PSHOME\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $dev 'engineering\d120\lab\Invoke-DomeniaGuiJourney.ps1') -DevRoot $dev -OutDir $out -Target Preview *> (Join-Path $out 'journey.log')
 [pscustomobject]@{ExitCode=$LASTEXITCODE;EndedUtc=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content (Join-Path $out 'runner.json') -Encoding UTF8
}catch{[pscustomobject]@{Error=$_.Exception.Message;Trace=$_.ScriptStackTrace}|ConvertTo-Json|Set-Content (Join-Path $out 'error.json') -Encoding UTF8}
