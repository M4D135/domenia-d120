#requires -Version 5.1
$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\RC35-qualification';$dev=Join-Path $root 'RC39-final\dev';$out=Join-Path $root 'rc39-final-delta'
[void][IO.Directory]::CreateDirectory($out)
$script:Rows=@();$bindings=@{}
foreach($file in @('wad/Domenia-Core.ps1','wad/Domenia-Modules.ps1','wad/Domenia.release.json','wad/package-manifest.json','wad/modules/Domenia-DirectoryTree.Types.cs','wad/modules/Domenia-DirectoryTree.UI.ps1','wad/modules/Domenia-LocalPreview.UI.ps1','wad/modules/Domenia-Widgets.UI.ps1')){$bindings[$file]=(Get-FileHash (Join-Path $dev $file) -Algorithm SHA256).Hash}
[IO.File]::WriteAllText((Join-Path $out 'Environment.json'),(@{PowerShell=$PSVersionTable.PSVersion.ToString();Apartment=[Threading.Thread]::CurrentThread.ApartmentState.ToString();SourceBindings=$bindings}|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
function Run-Check {
 param([string]$Name,[string]$File,[string[]]$Extra=@(),[int]$Seconds=240)
 $argv=@('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$File)+$Extra
 # The paths are fixed lab paths; each argument is quoted for Windows CreateProcess.
 $quoted=@($argv|ForEach-Object {'"'+$_.Replace('"','\"')+'"'}) -join ' '
 $watch=[Diagnostics.Stopwatch]::StartNew()
 $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName="$PSHOME\powershell.exe";$info.Arguments=$quoted;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
 $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
 $p=[Diagnostics.Process]::new();$p.StartInfo=$info;[void]$p.Start()
 $stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
 $timedOut=-not $p.WaitForExit($Seconds*1000)
 if($timedOut){$p.Kill();$p.WaitForExit()}
 $exit=$p.ExitCode
 [IO.File]::WriteAllText((Join-Path $out ($Name+'.log')),$stdout.Result,[Text.UTF8Encoding]::new($false))
 [IO.File]::WriteAllText((Join-Path $out ($Name+'-stderr.log')),$stderr.Result,[Text.UTF8Encoding]::new($false))
 $p.Dispose()
 $script:Rows+=@([pscustomobject]@{Test=$Name;ExitCode=$exit;TimedOut=$timedOut;ElapsedMs=$watch.ElapsedMilliseconds;SourceSha256=(Get-FileHash $File -Algorithm SHA256).Hash;Arguments=$Extra})
 [IO.File]::WriteAllText((Join-Path $out 'Progress.json'),($script:Rows|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
}
foreach($name in @('TreeRendering','TreeVirtualization','FavouriteReveal','AssociationRows','DiagnosticExport','LocalPreview','Modules','QueryTargets')){
 Run-Check $name (Join-Path $dev ('wad\tests\Test-Domenia'+$name+'.ps1')) @('-ReportPath',(Join-Path $out ($name+'.json')))
}
foreach($entry in @(@('Boards','Programme 38'),@('WiringCache','D024.*Show-AdObjectResult'),@('Navigation','Programme 8'),@('WiringRecherche','FO-04|UI-16|DS-07|CO-21|D032|D039'))){
 $name=$entry[0]
 Run-Check $name (Join-Path $dev ('wad\tests\Test-Domenia'+$name+'.ps1')) @('-Filter',$entry[1],'-ReportPath',(Join-Path $out ($name+'.json')))
}
foreach($name in @('BoardFleet','Collection','DirectorySync','Observability','Park')){
 Run-Check ('Rules-'+$name) (Join-Path $dev 'wad\tests\Test-DomeniaRules.ps1') @('-TestFileFilter',($name+'.Tests.ps1'),'-ReportPath',(Join-Path $out ('Rules-'+$name+'.json')))
}
Run-Check 'FinalStartupIntegrity' (Join-Path $dev 'wad\Domenia-Start.ps1') @('-CheckOnly')
[IO.File]::WriteAllText((Join-Path $out 'Done.json'),($script:Rows|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
if(@($script:Rows|Where-Object {$_.TimedOut -or $_.ExitCode -ne 0}).Count){exit 1}
