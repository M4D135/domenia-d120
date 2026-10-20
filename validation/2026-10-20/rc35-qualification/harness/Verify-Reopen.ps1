$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\RC35-qualification';$dest=Join-Path $root 'RC36-reopen';$out=Join-Path $root 'rc36-reopen-native'
[void][IO.Directory]::CreateDirectory($out)
[IO.File]::WriteAllText((Join-Path $out 'progress.txt'),'Extraction '+[datetime]::UtcNow.ToString('o'))
foreach($edition in @('DEV','PROD')){Expand-Archive (Join-Path $root ('Domenia_1.0_RC1.17.36_'+$edition+'.zip')) -DestinationPath $dest -Force}
[IO.File]::AppendAllText((Join-Path $out 'progress.txt'),"`nExtraction complete "+[datetime]::UtcNow.ToString('o'))
$dev=Join-Path $dest 'dev';$prod=Join-Path $dest 'prod'
& (Join-Path $dev 'tools\Test-DomeniaPs51Compat.ps1') -Root $dev -ReportPath (Join-Path $out 'Compat.json') *> (Join-Path $out 'Compat.stdout.txt')
& (Join-Path $dev 'engineering\d120\Test-NativeParser.ps1') -SourceRoot $dev -ReportPath (Join-Path $out 'Parser.json') -RequireWindows51 *> (Join-Path $out 'Parser.stdout.txt')
& (Join-Path $dev 'wad\tests\Test-DomeniaStoragePreferences.ps1') -ReportPath (Join-Path $out 'StoragePreferences.json') *> (Join-Path $out 'Preferences.stdout.txt')
& (Join-Path $prod 'wad\Domenia-Start.ps1') -CheckOnly *> (Join-Path $out 'CheckOnly.stdout.txt')
[pscustomobject]@{Utc=[datetime]::UtcNow.ToString('o');Build='RC1.17.36';CheckOnlyExit=$LASTEXITCODE;Packs=@(Get-ChildItem (Join-Path $root '*RC1.17.36*.zip')|Get-FileHash -Algorithm SHA256|Select-Object Path,Hash);PS=$PSVersionTable.PSVersion.ToString()}|ConvertTo-Json -Depth 4|Set-Content (Join-Path $out 'Summary.json') -Encoding UTF8
