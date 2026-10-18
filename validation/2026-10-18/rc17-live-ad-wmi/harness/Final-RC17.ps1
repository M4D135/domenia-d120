$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\d120-rc11717-live'
$checks=@()
foreach($ed in @('prod','dev')){
 $base=Join-Path $root $ed
 $m=Get-Content "$base\wad\package-manifest.json" -Raw|ConvertFrom-Json
 foreach($f in $m.Files){if((Get-FileHash (Join-Path $base $f.Path) -Algorithm SHA256).Hash -ne $f.Sha256){throw ('Manifest mismatch '+$f.Path)}}
 if(@(Get-ChildItem "$base\wad" -Filter '_qualification*').Count -ne 0){throw 'Harness cleanup incomplete'}
 $checks+=@([pscustomobject]@{Edition=$ed;Files=@($m.Files).Count;Build=$m.Build;ZipSha256=(Get-FileHash (Join-Path $root ('Domenia_'+$ed.ToUpperInvariant()+'.zip')) -Algorithm SHA256).Hash})
}
$r=Get-Content "$root\live-timeout-out\LiveBatch.json" -Raw|ConvertFrom-Json
if(-not $r.Passed -or $r.Run.Done -ne 2 -or $r.Run.Stopping -or $r.Run.Pending -ne 0 -or $r.Run.StorePending -ne 0){throw 'Batch failed'}
[pscustomobject]@{Passed=$true;Utc=[DateTime]::UtcNow.ToString('o');Machine=$env:COMPUTERNAME;PowerShell=$PSVersionTable.PSVersion.ToString();X64=[Environment]::Is64BitProcess;Apartment=[Threading.Thread]::CurrentThread.ApartmentState.ToString();Archives=$checks;HarnessRemoved=$true;BatchDone=$r.Run.Done;FailedTarget=$r.Run.Failed}|ConvertTo-Json -Depth 5|Set-Content -Encoding UTF8 "$root\verification\FinalIntegrity.json"
Get-Content "$root\verification\FinalIntegrity.json" -Raw
