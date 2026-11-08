$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$root='C:\Windows\Temp\Domenia-FirstRun-20261020-delivery';$out=Join-Path $root 'delivery-proof';[void][IO.Directory]::CreateDirectory($out)
Expand-Archive (Join-Path $root 'Domenia_1.0_RC1.17.35_DEV.zip') (Join-Path $root 'candidate') -Force
Expand-Archive (Join-Path $root 'Domenia_1.0_RC1.17.35_PROD.zip') (Join-Path $root 'candidate') -Force
$dev=Join-Path $root 'candidate\dev';$prod=Join-Path $root 'candidate\prod'
[pscustomobject]@{DateUtc=[datetime]::UtcNow.ToString('o');PowerShell=$PSVersionTable.PSVersion.ToString();Edition=$PSVersionTable.PSEdition;OS=[Environment]::OSVersion.VersionString;Computer=$env:COMPUTERNAME;Is64Bit=[Environment]::Is64BitProcess;DEV=(Get-FileHash (Join-Path $root 'Domenia_1.0_RC1.17.35_DEV.zip')).Hash;PROD=(Get-FileHash (Join-Path $root 'Domenia_1.0_RC1.17.35_PROD.zip')).Hash}|ConvertTo-Json|Set-Content (Join-Path $out 'Environment.json') -Encoding UTF8
$rows=[Collections.Generic.List[object]]::new()
function Run-Test {param([string]$Name,[string]$Script,[string[]]$Extra=@(),[int]$Seconds=240)
    $args_= @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$Script)+$Extra
    $started=[datetime]::UtcNow
    $p=Start-Process -FilePath "$PSHOME\powershell.exe" -ArgumentList $args_ -WorkingDirectory $dev -PassThru -RedirectStandardOutput (Join-Path $out ($Name+'.stdout.txt')) -RedirectStandardError (Join-Path $out ($Name+'.stderr.txt'))
    $handle=$p.Handle
    $timedOut=-not $p.WaitForExit($Seconds*1000)
    if($timedOut){Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue}
    $p.Refresh();$exit=if($timedOut){-999}else{$p.ExitCode}
    $rows.Add([pscustomobject]@{Name=$Name;StartedUtc=$started.ToString('o');Seconds=([datetime]::UtcNow-$started).TotalSeconds;ExitCode=$exit;TimedOut=$timedOut})
    @($rows.ToArray())|ConvertTo-Json -Depth 6|Set-Content (Join-Path $out 'Runner.json') -Encoding UTF8
}

Run-Test 'NativeParser' (Join-Path $dev 'engineering\d120\Test-NativeParser.ps1') @('-SourceRoot',$dev,'-ContractsPath',(Join-Path $dev 'tools\operation-contracts.json'),'-RequireWindows51','-ReportPath',(Join-Path $out 'NativeParser.json')) -Seconds 300
$factory=Join-Path $root 'factory-proof';[void][IO.Directory]::CreateDirectory($factory)
Run-Test 'Factory' (Join-Path $dev 'engineering\d120\quick-ui-20261012\Test-DomeniaProdFactory.ps1') @('-DevRoot',$dev,'-ReportPath',(Join-Path $factory 'Factory.json'))
Get-ChildItem -LiteralPath $factory -File|Copy-Item -Destination $out
Run-Test 'PROD-CheckOnly' (Join-Path $prod 'wad\Domenia-Start.ps1') @('-CheckOnly')
$manifest=Get-Content (Join-Path $prod 'wad\package-manifest.json') -Raw|ConvertFrom-Json
$checks=@(foreach($file in $manifest.Files){$rel=[string]$file.Path;$expected=[string]$file.Sha256;$a=(Get-FileHash (Join-Path $prod $rel)).Hash;$b=(Get-FileHash (Join-Path $dev $rel)).Hash;[pscustomobject]@{Path=$rel;Expected=$expected;PROD=$a;DEV=$b;Passed=($expected -eq $a -and $a -eq $b)}})
[pscustomobject]@{Total=$checks.Count;Failed=@($checks|Where-Object{-not $_.Passed}).Count;Checks=$checks}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $out 'RuntimeIdentity.json') -Encoding UTF8
[pscustomobject]@{FinishedUtc=[datetime]::UtcNow.ToString('o');FailedProcesses=@($rows|Where-Object{$null -eq $_.ExitCode -or $_.ExitCode -ne 0 -or $_.TimedOut}).Count;RuntimeMismatches=@($checks|Where-Object{-not $_.Passed}).Count}|ConvertTo-Json|Set-Content (Join-Path $out 'Complete.json') -Encoding UTF8
