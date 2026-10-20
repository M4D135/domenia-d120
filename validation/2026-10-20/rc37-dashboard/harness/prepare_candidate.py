from pathlib import Path
import zipfile

repo=Path("work/opencode-supervision-rc14/isolated-checkout")
out=Path("work/rc37-dashboard")
files=[
    "wad/modules/Domenia-Common.Model.ps1", "wad/modules/Domenia-Engine.Worker.ps1",
    "wad/tests/rules/Common.Tests.ps1", "wad/tests/Test-DomeniaWiringCache.ps1",
]
with zipfile.ZipFile(out/"candidate.zip","w",zipfile.ZIP_DEFLATED) as z:
    for name in files:z.write(repo/"dev"/name,name)
    test=(repo/"dev/wad/tests/Test-DomeniaWiringCache.ps1").read_text(encoding="utf-8-sig")
    old="return & ([scriptblock]::Create((Get-DomeniaLocalIndexReadWorkerCode)))\n}\nfunction Save-L01Observation"
    assert test.count(old)==1
    test=test.replace(old,"$code=Get-DomeniaLocalIndexReadWorkerCode\n    if($script:BenchFullRead){$code=$code.Replace('SkipDirectoryRows=$true','SkipDirectoryRows=$false')}\n    return & ([scriptblock]::Create($code))\n}\nfunction Save-L01Observation")
    anchor="        $watch = [Diagnostics.Stopwatch]::StartNew()\n        $result = Invoke-L01Fleet -Scope 'OU=Parc,DC=example,DC=invalid' -ComputeBoard"
    assert anchor in test
    test=test.replace(anchor,r"""        $measurements=[Collections.Generic.List[object]]::new()
        foreach($variant in @('Before','After','After','Before')){
            $script:BenchFullRead=($variant -eq 'Before')
            $watch=[Diagnostics.Stopwatch]::StartNew()
            $result=Invoke-L01Fleet -Scope 'OU=Parc,DC=example,DC=invalid' -Now ([datetime]'2026-10-20T12:00:00Z') -ComputeBoard
            $measurements.Add([pscustomobject]@{Variant=$variant;Milliseconds=$watch.ElapsedMilliseconds;Sql=$result.SqlStats;Machines=$result.Board.Entries['fleet.machines'].Value;Healthy=$result.Board.Population.Healthy;Unassessed=$result.Board.Population.Unassessed;Problems=$result.Board.Last.ProblemTargets.Count})
            $measurements|ConvertTo-Json -Depth 5|Set-Content 'C:\DomeniaLab\RC35-qualification\perf37-results\WorkerCompare.json' -Encoding UTF8
        }
        $script:BenchFullRead=$false""")
    z.writestr("wad/tests/Measure-Fleet37.ps1",b"\xef\xbb\xbf"+test.encode())
(out/"Copy-Candidate.ps1").write_text((out/"Copy-Profile.ps1").read_text(encoding="utf-8-sig").replace("profile.zip","candidate.zip"),encoding="utf-8-sig")
(out/"Verify-Candidate.ps1").write_text(r"""$ErrorActionPreference='Stop'
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
""",encoding="utf-8-sig")
