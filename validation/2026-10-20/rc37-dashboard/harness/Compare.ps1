$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\RC35-qualification';$out=Join-Path $root 'perf37'
$modules=Join-Path $root 'RC36-reopen\dev\wad\modules'
$candidate=Join-Path $root 'Common37.ps1'
$rows=[Collections.Generic.List[object]]::new()
$report=[ordered]@{PS=$PSVersionTable.PSVersion.ToString();Passed=$false;Runs=@()}
try{
    if($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1){throw 'PS5.1 required'}
    foreach($name in @('Common','Collection','HealthRules','Boards','BoardFleet')){. (Join-Path $modules ('Domenia-'+$name+'.Model.ps1'))}
    $fleet=Import-Clixml (Join-Path $out 'Fleet.xml')
    $life=Get-Content (Join-Path $modules 'Domenia-WindowsLifecycle.json') -Raw|ConvertFrom-Json
    foreach($variant in @('Before','After','After','Before')){
        if($variant -eq 'Before'){. (Join-Path $modules 'Domenia-Common.Model.ps1')}else{. $candidate}
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $board=Get-DomeniaFleetBoardData -Result $fleet -Scope 'OU=Parc,DC=example,DC=invalid' -Now ([datetime]'2026-10-20T12:00:00Z') -Lifecycle $life
        $elapsed=$watch.ElapsedMilliseconds
        $rows.Add([pscustomobject]@{Variant=$variant;Milliseconds=$elapsed;Machines=$board.Entries['fleet.machines'].Value})
        $rows|ConvertTo-Json|Set-Content (Join-Path $out 'Compare-progress.json') -Encoding UTF8
        if($rows.Count -le 2){$board|ConvertTo-Json -Depth 30 -Compress|Set-Content (Join-Path $out ($variant+'.json')) -Encoding UTF8}
    }
    $report.Passed=$true
}catch{$report.Error=$_.Exception.Message;$report.Stack=$_.ScriptStackTrace}
finally{$report.Runs=$rows.ToArray();$report.Utc=[datetime]::UtcNow.ToString('o');$report|ConvertTo-Json -Depth 6|Set-Content (Join-Path $out 'Compare.json') -Encoding UTF8}
