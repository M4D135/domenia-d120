$ErrorActionPreference='Stop'
$out='C:\DomeniaLab\RC35-qualification\final-qualification';[void][IO.Directory]::CreateDirectory($out)
$dev='C:\DomeniaLab\RC1.17.35\dev'
& (Join-Path $dev 'wad\tests\Test-DomeniaParkPhases.ps1') -ReportPath (Join-Path $out 'ParkPhases.json') *> (Join-Path $out 'ParkPhases.stdout.txt')
& (Join-Path $dev 'wad\tests\Test-DomeniaWiringCache.ps1') -ReportPath (Join-Path $out 'WiringCache.json') *> (Join-Path $out 'WiringCache.stdout.txt')
