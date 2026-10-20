$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$root='C:\Windows\Temp\Domenia-FirstRun-20261020';$out=Join-Path $root 'red-proof';[void][IO.Directory]::CreateDirectory($out)
Expand-Archive (Join-Path $root 'baseline-red.zip') (Join-Path $root 'baseline') -Force
$dev=Join-Path $root 'baseline\dev'
[pscustomobject]@{DateUtc=[datetime]::UtcNow.ToString('o');PowerShell=$PSVersionTable.PSVersion.ToString();Edition=$PSVersionTable.PSEdition;OS=[Environment]::OSVersion.VersionString;Computer=$env:COMPUTERNAME;Is64Bit=[Environment]::Is64BitProcess;ArchiveSHA256=(Get-FileHash (Join-Path $root 'baseline-red.zip')).Hash}|ConvertTo-Json|Set-Content (Join-Path $out 'Environment.json') -Encoding UTF8
& "$PSHOME\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $dev 'wad\tests\Test-DomeniaBoards.ps1') -Filter 'Premiers pas : l OU acceptee' -ReportPath (Join-Path $out 'Boards-red.json') *> (Join-Path $out 'Boards-red.log')
[pscustomobject]@{ExitCode=$LASTEXITCODE;FinishedUtc=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content (Join-Path $out 'Runner.json') -Encoding UTF8
