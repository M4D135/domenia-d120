from pathlib import Path
import zipfile

repo = Path("work/opencode-supervision-rc14/isolated-checkout")
out = Path("work/rc37-dashboard")
out.mkdir(exist_ok=True)
model = (repo / "dev/wad/modules/Domenia-BoardFleet.Model.ps1").read_text(encoding="utf-8-sig")
model = model.replace("    $invariant = [Globalization.CultureInfo]::InvariantCulture\n    $nowUtc", "    $perfWatch=[Diagnostics.Stopwatch]::StartNew();$perfMarks=[ordered]@{}\n    $invariant = [Globalization.CultureInfo]::InvariantCulture\n    $nowUtc", 1)
for name, anchor in [
    ("Setup", "    foreach ($group in $active) {"),
    ("Groups", "    # Activity is independent"),
    ("Observations", "    $observedOld = "),
    ("Entries", "    # The worker rows are kept"),
    ("Membership", "    $ouMembers=@{};$siteCache=@{}"),
    ("OuBuckets", "    $widgetTargets['fleet.ou']=@($targets);"),
    ("Eligibility", "    if($null -ne $HealthPolicyBook"),
    ("Completion", "    Set-DomeniaHealthSnapshotMetadata -Data $data"),
    ("Snapshot", "    $data|Add-Member -NotePropertyName Pivots"),
]:
    assert anchor in model
    model = model.replace(anchor, "    $perfMarks['"+name+"']=$perfWatch.ElapsedMilliseconds\n"+anchor, 1)
model = model.replace("    return $data\n}", "    $perfMarks['Pivots']=$perfWatch.ElapsedMilliseconds\n    $perfMarks|ConvertTo-Json|Set-Content 'C:\\DomeniaLab\\RC35-qualification\\perf37\\Profile.json' -Encoding UTF8\n    return $data\n}", 1)
test = (repo / "dev/wad/tests/Test-DomeniaWiringCache.ps1").read_text(encoding="utf-8-sig")
test = test.replace("$result = Invoke-L01Fleet -Scope 'OU=Parc,DC=example,DC=invalid' -ComputeBoard", "$result = Invoke-L01Fleet -Scope 'OU=Parc,DC=example,DC=invalid' -Now ([datetime]'2026-10-20T12:00:00Z') -ComputeBoard", 1)
test = test.replace("        $board=$result.Board\n", """        $board=$result.Board
        $result.PSObject.Properties.Remove('Board')
        $result|Export-Clixml 'C:\\DomeniaLab\\RC35-qualification\\perf37\\Fleet.xml' -Depth 12
""", 1)
with zipfile.ZipFile(out / "profile.zip", "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("wad/modules/Domenia-BoardFleet.Model.ps1", b"\xef\xbb\xbf"+model.encode())
    z.writestr("wad/tests/Test-DomeniaWiringCache.ps1", b"\xef\xbb\xbf"+test.encode())
(out / "Profile.ps1").write_text(r"""$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\RC35-qualification';$out=Join-Path $root 'perf37'
[void][IO.Directory]::CreateDirectory($out)
$dev=Join-Path $out 'baseline'
if(-not (Test-Path $dev)){Copy-Item (Join-Path $root 'RC36-reopen\dev') $dev -Recurse}
Expand-Archive (Join-Path $root 'profile.zip') $dev -Force
& (Join-Path $dev 'wad\tests\Test-DomeniaWiringCache.ps1') -Filter 'vue du parc sur 5 000' -ReportPath (Join-Path $out 'Wiring.json') *> (Join-Path $out 'Wiring.log')
""", encoding="utf-8-sig")
(out / "Copy-Profile.ps1").write_text(r"""$ErrorActionPreference='Stop'
$v='C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
$a=@('--username','Administrateur','--domain','CNAMTS','--passwordfile','C:\ADCC-Lab\private\CNAMTS-W11-01-admin.txt')
& $v guestcontrol bc2f1ac0-9545-49bd-a0f5-cb89d352cf61 copyto @a 'C:\Users\degun\domenia-lab\vmstage\profile.zip' --target-directory 'C:\DomeniaLab\RC35-qualification\'
if($LASTEXITCODE -ne 0){throw 'Copy failed'}
""", encoding="utf-8-sig")
