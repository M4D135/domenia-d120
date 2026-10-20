$ErrorActionPreference='Stop';$root='C:\DomeniaLab\RC35-qualification';$dest=Join-Path $root 'RC38';$out=Join-Path $root 'startup38-pack'
[void][IO.Directory]::CreateDirectory($out)
$r=[ordered]@{Passed=$false;PS=$PSVersionTable.PSVersion.ToString();Archives=@();Cases=@()}
function Case($name,[scriptblock]$body){try{& $body|Out-Null;$r.Cases+=@(@{Name=$name;Passed=$true})}catch{$r.Cases+=@(@{Name=$name;Passed=$false;Error=$_.Exception.Message})}}
try{
 foreach($edition in @('DEV','PROD')){$zip=Join-Path $root ('Domenia_1.0_RC1.17.38_'+$edition+'.zip');$r.Archives+=@(@{Edition=$edition;SHA256=(Get-FileHash $zip).Hash});Expand-Archive $zip $dest -Force}
 $dev=Join-Path $dest 'dev';$prod=Join-Path $dest 'prod';$ps=Join-Path $PSHOME 'powershell.exe'
 & $ps -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $dev 'wad\tests\Test-DomeniaStartupWork.ps1') -ReportPath (Join-Path $out 'StartupWork.json') *> (Join-Path $out 'StartupWork.log')
 if($LASTEXITCODE -ne 0){throw 'Startup regression'}
 $changed=Join-Path $out 'changed';[void][IO.Directory]::CreateDirectory($changed)
 foreach($file in @('Domenia-Core.ps1','Domenia-Modules.ps1')){Copy-Item (Join-Path $dev ('wad\'+$file)) $changed}
 Copy-Item (Join-Path $dev 'wad\tests\Test-DomeniaStartupWork.ps1') $changed
 & $ps -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $dev 'tools\Test-DomeniaPs51Compat.ps1') -Root $changed -ReportPath (Join-Path $out 'Compatibility.json') *> (Join-Path $out 'Compatibility.log')
 if($LASTEXITCODE -ne 0){throw 'Changed-source compatibility'}
 & $ps -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $prod 'wad\Domenia-Start.ps1') -CheckOnly *> (Join-Path $out 'CheckOnly.log')
 if($LASTEXITCODE -ne 0){throw 'Pack check failed'}
 # Replace only the runtime in the isolated measurement install. The same saved profile is restored by the driver.
 Copy-Item (Join-Path $prod '*') (Join-Path $root 'startup38\prod') -Recurse -Force
 $r.Passed=$true
}catch{$r.Error=$_.Exception.Message;$r.Stack=$_.ScriptStackTrace}
finally{$r|ConvertTo-Json -Depth 7|Set-Content (Join-Path $out 'Summary.json') -Encoding UTF8}
