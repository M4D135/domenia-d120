$ErrorActionPreference='Stop';$root='C:\DomeniaLab\RC35-qualification';$out=Join-Path $root 'startup38-pack';$wad=Join-Path $root 'RC38\prod\wad'
$r=[ordered]@{Passed=$false;PS=$PSVersionTable.PSVersion.ToString();Runs=@();SourceSHA256=(Get-FileHash (Join-Path $wad 'Domenia-Modules.ps1')).Hash;BaselineCommit='08545267fcbd6c512b3702f75a672286fccd7649'}
try{
 . (Join-Path $wad 'Domenia-Modules.ps1')
function Assert-BaselineRuntimeImports {
    [CmdletBinding()]
    param([string]$ModuleRoot = (Join-Path $PSScriptRoot 'modules'))
    foreach ($module in @(Get-DomeniaRuntimeModulePlan)) {
        $expected = [IO.Path]::GetFullPath((Join-Path $ModuleRoot $module.File))
        foreach ($name in @($module.Functions)) {
            # Function: avoids command auto-loading and aliases. Check origin too:
            # an older function in a parent scope must not mask an omitted import.
            $command = Get-Item -LiteralPath ('Function:\' + $name) -ErrorAction SilentlyContinue
            if ($null -eq $command -or -not $command.ScriptBlock.File) {
                throw [InvalidOperationException]::new(
                    "DOMENIA_MODULE_EXPORT : $($module.File) n'a pas fourni la fonction $name.")
            }
            $actual = [IO.Path]::GetFullPath([string]$command.ScriptBlock.File)
            if (-not [string]::Equals($actual,$expected,[StringComparison]::OrdinalIgnoreCase)) {
                throw [InvalidOperationException]::new(
                    "DOMENIA_MODULE_ORIGIN : la fonction $name ne provient pas de $($module.File).")
            }
        }
        [pscustomobject]@{File=[string]$module.File;Functions=@($module.Functions).Count;Validated=$true}
    }
}

 $expected=$null
 foreach($variant in @('Before','After','After','Before')){
  $sw=[Diagnostics.Stopwatch]::StartNew()
  $rows=if($variant -eq 'Before'){@(Assert-BaselineRuntimeImports (Join-Path $wad 'modules'))}else{@(Assert-DomeniaRuntimeImports (Join-Path $wad 'modules'))}
  $elapsed=$sw.ElapsedMilliseconds
  $value=$rows|ConvertTo-Json -Depth 4 -Compress
  if($null -eq $expected){$expected=$value}elseif($value -cne $expected){throw 'Validation output differs'}
  $r.Runs+=@([pscustomobject]@{Variant=$variant;Milliseconds=$elapsed;Modules=$rows.Count;Functions=($rows|Measure-Object Functions -Sum).Sum})
 }
 $r.IdenticalValidationOutput=$true;$r.Passed=$true
}catch{$r.Error=$_.Exception.Message}
finally{$r|ConvertTo-Json -Depth 5|Set-Content (Join-Path $out 'ImportBenchmark.json') -Encoding UTF8}
