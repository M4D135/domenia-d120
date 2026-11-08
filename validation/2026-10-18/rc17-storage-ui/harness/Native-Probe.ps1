param([string]$Stage='NativeProbe',[switch]$Interactive)
$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\d120-rc11717-live';$install=Join-Path $root 'storage-ui-prod';$out=Join-Path $root 'storage-ui-out';$task='Domenia-RC17-Storage-'+$Stage
[void][IO.Directory]::CreateDirectory($out)
function Save-Json($name,$data){[IO.File]::WriteAllText((Join-Path $out $name),($data|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}
if(-not $Interactive){
 $user=(Get-CimInstance Win32_ComputerSystem).UserName;if(-not $user){throw 'Interactive Windows session required'}
 $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoLogo -NoProfile -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Stage '+$Stage+' -Interactive')
 Register-ScheduledTask -TaskName $task -Action $action -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 8)) -Force|Out-Null
 Start-ScheduledTask -TaskName $task;Write-Output ('Dispatched '+$Stage);exit
}

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;using System.Text;using System.Runtime.InteropServices;using System.Collections.Generic;
public static class StorageDialogs {
 public delegate bool EnumProc(IntPtr h,IntPtr p);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p,IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h,EnumProc p,IntPtr l);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr h,uint m,IntPtr w,string l,uint flags,uint ms,out IntPtr r);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
 public static string Text(IntPtr h){var s=new StringBuilder(1024);GetWindowText(h,s,1024);return s.ToString();}
 public static string Class(IntPtr h){var s=new StringBuilder(256);GetClassName(h,s,256);return s.ToString();}
 public static IntPtr[] Windows(uint pid){var list=new List<IntPtr>();EnumWindows((h,p)=>{uint n;GetWindowThreadProcessId(h,out n);if(n==pid && IsWindowVisible(h))list.Add(h);return true;},IntPtr.Zero);return list.ToArray();}
 public static IntPtr[] Children(IntPtr root){var list=new List<IntPtr>();EnumChildWindows(root,(h,p)=>{list.Add(h);return true;},IntPtr.Zero);return list.ToArray();}
}
'@
$rows=@();foreach($h in [StorageDialogs]::Windows(5412)){
 $rows+=@([pscustomobject]@{Hwnd=$h.ToInt64();Parent=0;Id=[StorageDialogs]::GetDlgCtrlID($h);Class=[StorageDialogs]::Class($h);Text=[StorageDialogs]::Text($h)})
 foreach($c in [StorageDialogs]::Children($h)){if([StorageDialogs]::IsWindowVisible($c)){$rows+=@([pscustomobject]@{Hwnd=$c.ToInt64();Parent=$h.ToInt64();Id=[StorageDialogs]::GetDlgCtrlID($c);Class=[StorageDialogs]::Class($c);Text=$(if([StorageDialogs]::Class($c) -ne 'Edit'){[StorageDialogs]::Text($c)}else{'[edit]'})})}}
}
Save-Json 'NativeDialogs.json' $rows
$bmp=[Drawing.Bitmap]::new(1920,1200);$g=[Drawing.Graphics]::FromImage($bmp);try{$g.CopyFromScreen(0,0,0,0,$bmp.Size);$bmp.Save((Join-Path $out 'NativeDialogs.png'))}finally{$g.Dispose();$bmp.Dispose()}
