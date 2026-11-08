$ErrorActionPreference='Stop';$root='C:\DomeniaLab\RC35-qualification';$dest=Join-Path $root 'RC36-reopen';$dev=Join-Path $dest 'dev';$prod=Join-Path $dest 'prod';$out=Join-Path $root 'rc36-reopen-targeted'
[void][IO.Directory]::CreateDirectory($out)
[IO.File]::WriteAllText((Join-Path $out 'progress.txt'),'Started '+[datetime]::UtcNow.ToString('o'))
$r=[ordered]@{Build='RC1.17.36';PS=$PSVersionTable.PSVersion.ToString();Passed=$false;Files=@();CheckOnlyExit=$null;Packs=@()}
try{
 if($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1){throw 'Native PS5.1 required'}
 foreach($path in @((Join-Path $prod 'wad\Domenia-Core.ps1'),(Join-Path $dev 'wad\tests\Test-DomeniaStoragePreferences.ps1'))){
  $t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$t,[ref]$e)
  $r.Files+=@([pscustomobject]@{Path=$path;Sha256=(Get-FileHash $path -Algorithm SHA256).Hash;Errors=@($e|ForEach-Object {$_.Message})});if($e.Count){throw 'Native parser failed'}
 }
 & (Join-Path $dev 'wad\tests\Test-DomeniaStoragePreferences.ps1') -ReportPath (Join-Path $out 'StoragePreferences.json') *> (Join-Path $out 'Preferences.stdout.txt')
 $prefs=Get-Content (Join-Path $out 'StoragePreferences.json') -Raw|ConvertFrom-Json
 if($prefs.Failed -ne 0 -or $prefs.Passed -ne 7){throw 'Storage preferences regression failed'}
 & (Join-Path $prod 'wad\Domenia-Start.ps1') -CheckOnly *> (Join-Path $out 'CheckOnly.stdout.txt');$r.CheckOnlyExit=$LASTEXITCODE
 if($LASTEXITCODE -ne 0){throw 'Pack CheckOnly failed'}
 $r.Packs=@(Get-ChildItem (Join-Path $root '*RC1.17.36*.zip')|Get-FileHash -Algorithm SHA256|Select-Object Path,Hash)
 $r.Passed=$true
}catch{$r.Error=$_.Exception.Message;$r.Stack=$_.ScriptStackTrace}
finally{$r.Utc=[datetime]::UtcNow.ToString('o');$r|ConvertTo-Json -Depth 7|Set-Content (Join-Path $out 'Summary.json') -Encoding UTF8}
