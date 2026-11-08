$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\RC35-qualification';$dev=Join-Path $root 'perf37\baseline';$out=Join-Path $root 'perf37-results'
[void][IO.Directory]::CreateDirectory($out)
Expand-Archive (Join-Path $root 'candidate.zip') $dev -Force
# Remove diagnostic timing edits: all production modules below match the candidate.
Copy-Item (Join-Path $root 'RC36-reopen\dev\wad\modules\Domenia-BoardFleet.Model.ps1') (Join-Path $dev 'wad\modules\Domenia-BoardFleet.Model.ps1') -Force
$ps=Join-Path $PSHOME 'powershell.exe';$results=[Collections.Generic.List[object]]::new()
foreach($case in @(
    @{Name='Common';Script='wad\tests\Test-DomeniaRules.ps1';Args=@('-TestFileFilter','Common.Tests.ps1')},
    @{Name='Health';Script='wad\tests\Test-DomeniaHealthRules.ps1';Args=@()},
    @{Name='HealthAdvanced';Script='wad\tests\Test-DomeniaHealthAdvanced.ps1';Args=@()},
    @{Name='HealthPolicies';Script='wad\tests\Test-DomeniaRules.ps1';Args=@('-TestFileFilter','HealthRules.Tests.ps1')},
    @{Name='Projections';Script='wad\tests\Test-DomeniaObservationProjections.ps1';Args=@()},
    @{Name='Wiring';Script='wad\tests\Test-DomeniaWiringCache.ps1';Args=@('-Filter','L01 : (FleetStats|observations canoniques|releves d un poste)')},
    @{Name='WorkerBench';Script='wad\tests\Measure-Fleet37.ps1';Args=@('-Filter','vue du parc sur 5 000')}
)){
    $case.Name|Set-Content (Join-Path $out 'progress.txt')
    $extra=$case.Args
    & $ps -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $dev $case.Script) -ReportPath (Join-Path $out ($case.Name+'.json')) @extra *> (Join-Path $out ($case.Name+'.log'))
    $results.Add([pscustomobject]@{Name=$case.Name;ExitCode=$LASTEXITCODE})
    $results|ConvertTo-Json|Set-Content (Join-Path $out 'Summary.json') -Encoding UTF8
}
