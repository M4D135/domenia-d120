$root='C:\DomeniaLab\d120-rc11721-validation'
$exe=Join-Path $PSHOME 'powershell.exe'
$results=[Collections.Generic.List[object]]::new()
foreach($name in @('Workstation','ProbeContract','Query')){
 & $exe -NoProfile -STA -ExecutionPolicy Bypass -File ($root+'\dev\wad\tests\Test-DomeniaRules.ps1') -TestFileFilter ($name+'.Tests.ps1') -ReportPath ($root+'\out\Rules-'+$name+'.json') *> ($root+'\out\Rules-'+$name+'.log')
 $results.Add([pscustomobject]@{Name=('Rules-'+$name);ExitCode=$LASTEXITCODE})
}
& $exe -NoProfile -STA -ExecutionPolicy Bypass -File ($root+'\dev\wad\tests\Test-DomeniaInstaller.ps1') -ReportPath ($root+'\out\Installer-targeted.json') -CaseFilter 'choix.explicite.-LocalData|choix.saisis.en.minuscules|retour.verifie|restauration.complete.disponible' *> ($root+'\out\Installer.log')
$results.Add([pscustomobject]@{Name='Installer';ExitCode=$LASTEXITCODE})
& $exe -NoProfile -STA -ExecutionPolicy Bypass -File ($root+'\dev\wad\Domenia-Start.ps1') -CheckOnly *> ($root+'\out\Startup.log')
$results.Add([pscustomobject]@{Name='Startup';ExitCode=$LASTEXITCODE})
$manifest=Get-Content ($root+'\dev\tools\prod-manifest.json') -Raw|ConvertFrom-Json
$files=@(foreach($e in $manifest.Files){$p=Join-Path ($root+'\dev') $e.Path;[pscustomobject]@{Path=$e.Path;Sha256=(Get-FileHash $p -Algorithm SHA256).Hash;Bytes=(Get-Item $p).Length}})
[IO.File]::WriteAllText(($root+'\out\LastChecks.json'),([ordered]@{UTC=[datetime]::UtcNow.ToString('o');Build=$manifest.Build;Session=[Diagnostics.Process]::GetCurrentProcess().SessionId;Results=$results.ToArray();RuntimeFiles=$files;Passed=(@($results|Where-Object ExitCode -ne 0).Count -eq 0)}|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
