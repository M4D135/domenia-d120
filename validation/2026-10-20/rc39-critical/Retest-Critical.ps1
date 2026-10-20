$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\RC35-qualification';$dev=Join-Path $root 'RC39-critical\dev';$out=Join-Path $root 'rc39-critical-retest'
[void][IO.Directory]::CreateDirectory($out)
$rows=@()
foreach($name in @('LocalPreview','LiveSearchView','WiringCache')){
 $target=Join-Path $dev ('wad\tests\Test-Domenia'+$name+'.ps1')
 Copy-Item -LiteralPath (Join-Path $root ('Test-Domenia'+$name+'.ps1')) -Destination $target -Force
 $args=@('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$target,'-ReportPath',(Join-Path $out ($name+'.json')))
 if($name -eq 'WiringCache'){$args+=@('-Filter','D024.*Show-AdObjectResult')}
 & "$PSHOME\powershell.exe" @args *> (Join-Path $out ($name+'.log'))
 $rows+=@([pscustomobject]@{Test=$name;ExitCode=$LASTEXITCODE;FixtureSha256=(Get-FileHash $target -Algorithm SHA256).Hash})
}
[IO.File]::WriteAllText((Join-Path $out 'Done.json'),($rows|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
