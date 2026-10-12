#requires -Version 5.1
# Build a throwaway ordinary PROD from the frozen DEV; never bootstrap its UI or access AD.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$DevRoot,[Parameter(Mandatory=$true)][string]$ReportPath)
$ErrorActionPreference='Stop'
$dev=[IO.Path]::GetFullPath($DevRoot);$proof=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ReportPath))
[void][IO.Directory]::CreateDirectory($proof)
$prod=Join-Path $proof ('factory-prod-'+[guid]::NewGuid().ToString('N'))
$checks=[Collections.Generic.List[object]]::new();$failure='';$guardExit=$null
try {
 $built=& (Join-Path $dev 'tools\Fabriquer-Prod.ps1') -SourceWad (Join-Path $dev 'wad') -LauncherPath (Join-Path $dev 'Domenia.exe') -OutputDirectory $prod
 $top=@(Get-ChildItem -LiteralPath $prod -Force)
 $ordinary=($top.Count -eq 2 -and @( $top | Where-Object {$_.Name -cnotin @('Domenia.exe','wad')}).Count -eq 0)
 $checks.Add([pscustomobject]@{Name='Ordinary PROD: executable and wad directory';Passed=$ordinary})
 if(-not $ordinary){throw 'Unexpected PROD layout.'}
 $manifest=Get-Content -LiteralPath (Join-Path $prod 'wad\package-manifest.json') -Raw|ConvertFrom-Json
 $different=@(foreach($entry in $manifest.Files){
  # The factory intentionally regenerates release metadata with its local-build status.
  if([string]$entry.Path -eq 'wad/Domenia.release.json'){continue}
  $relative=([string]$entry.Path).Replace('/',[IO.Path]::DirectorySeparatorChar)
  $target=Join-Path $prod $relative;$source=Join-Path $dev $relative
  if(-not (Test-Path -LiteralPath $source) -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash){$relative}
 })
 $checks.Add([pscustomobject]@{Name='All executable, module and asset files match frozen DEV';Passed=($different.Count -eq 0);Files=@($manifest.Files).Count;Different=$different})
 if($different.Count){throw ('Runtime mismatch: '+($different -join ', '))}
 $release=Get-Content -LiteralPath (Join-Path $prod 'wad\Domenia.release.json') -Raw|ConvertFrom-Json
 $originalRelease=Get-Content -LiteralPath (Join-Path $dev 'wad\Domenia.release.json') -Raw|ConvertFrom-Json
 $releaseOk=($release.Version -eq $originalRelease.Version -and $release.Build -eq $originalRelease.Build -and $release.ReleaseStatus -eq 'LocalBuildRequiresValidation')
 $checks.Add([pscustomobject]@{Name='Regenerated release metadata preserves version and build';Passed=$releaseOk})
 if(-not $releaseOk){throw 'Unexpected release metadata.'}
 $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $prod 'wad\Domenia-Start.ps1')+'"'),'-CheckOnly')
 $guard=Start-Process -FilePath $shell -ArgumentList $arguments -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $proof 'factory-startup.stdout.txt') -RedirectStandardError (Join-Path $proof 'factory-startup.stderr.txt');$null=$guard.Handle
 if(-not $guard.WaitForExit(60000)){try{$guard.Kill()}catch{};throw 'PROD CheckOnly timed out.'}
 $guard.WaitForExit();$guardExit=$guard.ExitCode
 $checks.Add([pscustomobject]@{Name='Generated PROD startup integrity CheckOnly';Passed=($guardExit -eq 0);ExitCode=$guardExit})
 if($guardExit -ne 0){throw ('PROD CheckOnly exit '+$guardExit)}
} catch {$failure=$_.Exception.Message}
$report=[pscustomobject]@{Suite='Windows ordinary PROD factory';PowerShell=$PSVersionTable.PSVersion.ToString();Session=[Diagnostics.Process]::GetCurrentProcess().SessionId;Source=$dev;Output=$prod;Synthetic=$true;ADAccessed=$false;Checks=$checks.ToArray();Failure=$failure;Passed=(-not $failure)}
[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
if($failure){throw $failure};'PASS: Windows PROD factory, runtime equality and generated startup guard.'
