$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\RC35-qualification';$dest=Join-Path $root 'RC37';$out=Join-Path $root 'perf37-pack'
[void][IO.Directory]::CreateDirectory($out)
$report=[ordered]@{PS=$PSVersionTable.PSVersion.ToString();Build='RC1.17.37';Passed=$false;Files=@();Archives=@()}
try{
    if($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1){throw 'PS5.1 required'}
    foreach($edition in @('DEV','PROD')){
        $zip=Join-Path $root ('Domenia_1.0_RC1.17.37_'+$edition+'.zip')
        $report.Archives+=@([pscustomobject]@{Edition=$edition;SHA256=(Get-FileHash $zip -Algorithm SHA256).Hash})
        Expand-Archive $zip $dest -Force
    }
    $dev=Join-Path $dest 'dev';$prod=Join-Path $dest 'prod'
    foreach($file in @('wad\Domenia-Core.ps1','wad\modules\Domenia-Common.Model.ps1','wad\modules\Domenia-Engine.Worker.ps1','wad\tests\rules\Common.Tests.ps1','wad\tests\Test-DomeniaWiringCache.ps1')){
        $path=Join-Path $dev $file;$t=$null;$errors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$t,[ref]$errors)
        $report.Files+=@([pscustomobject]@{File=$file;SHA256=(Get-FileHash $path -Algorithm SHA256).Hash;Errors=@($errors|ForEach-Object{$_.Message})})
        if($errors.Count){throw ('Parse: '+$file)}
    }
    $ps=Join-Path $PSHOME 'powershell.exe'
    & $ps -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $dev 'wad\tests\Test-DomeniaRules.ps1') -TestFileFilter 'Common.Tests.ps1' -ReportPath (Join-Path $out 'Common.json') *> (Join-Path $out 'Common.log')
    if($LASTEXITCODE -ne 0){throw 'Common regression'}
    & $ps -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $dev 'tools\Test-DomeniaPs51Compat.ps1') -Root $dev *> (Join-Path $out 'Compatibility.log')
    if($LASTEXITCODE -ne 0){throw 'PS5.1 compatibility'}
    & $ps -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $prod 'wad\Domenia-Start.ps1') -CheckOnly *> (Join-Path $out 'CheckOnly.log')
    $report.CheckOnlyExit=$LASTEXITCODE
    if($LASTEXITCODE -ne 0){throw 'Pack integrity'}
    $report.Passed=$true
}catch{$report.Error=$_.Exception.Message;$report.Stack=$_.ScriptStackTrace}
finally{$report.Utc=[datetime]::UtcNow.ToString('o');$report|ConvertTo-Json -Depth 7|Set-Content (Join-Path $out 'Summary.json') -Encoding UTF8}
