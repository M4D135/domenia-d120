$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\d120-rc11717-live'
$out=Join-Path $root 'verification';[void][IO.Directory]::CreateDirectory($out)
$expected=@{PROD='0393C1B7FD23E732209D3F96C4C91196AFCB57BA26F02E86D79BBBC7EB4E908A';DEV='001AE72DB21059BDA3AD5AC72E810D8C69E20B948E2FC18C224F5B070A2EB04B'}
$packs=@()
foreach($ed in @('PROD','DEV')){
 $zip=Join-Path $root ('Domenia_'+$ed+'.zip');$hash=(Get-FileHash $zip -Algorithm SHA256).Hash
 if($hash -ine $expected[$ed]){throw 'Wrong RC17 archive'}
 Expand-Archive -LiteralPath $zip -DestinationPath $root -Force
 $base=Join-Path $root $ed.ToLowerInvariant();$m=Get-Content "$base\wad\package-manifest.json" -Raw|ConvertFrom-Json
 foreach($f in $m.Files){if((Get-FileHash (Join-Path $base $f.Path) -Algorithm SHA256).Hash -ne $f.Sha256){throw ('Manifest mismatch '+$f.Path)}}
 $packs+=@([pscustomobject]@{Edition=$ed;Sha256=$hash;Files=@($m.Files).Count;Build=$m.Build})
}
$packs|ConvertTo-Json -Depth 4|Set-Content -Encoding UTF8 "$out\Archives.json"
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "$root\prod\wad\Domenia-Start.ps1" -CheckOnly > "$out\Startup.log" 2>&1
if($LASTEXITCODE -ne 0){throw 'RC17 startup verification failed'}
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "$root\dev\wad\tests\Test-DomeniaParkDetection.ps1" -Filter 'RC11711|RC11717' -ReportPath "$out\ParkTimeoutRegression.json" -Quiet > "$out\ParkTimeoutRegression.log" 2>&1
if($LASTEXITCODE -ne 0){throw 'Timeout regression failed'}
Get-Content "$out\ParkTimeoutRegression.json" -Raw
