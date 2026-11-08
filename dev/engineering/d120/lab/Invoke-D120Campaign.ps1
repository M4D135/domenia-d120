#requires -Version 5.1
# D120 integration campaign, run INSIDE the test VM from <LAB_DIR>\dev (lab.sh ps '& .\engineering\d120\lab\Invoke-D120Campaign.ps1 ...').
# Each check runs in its own Windows PowerShell 5.1 process with a timeout. No AD write and no network probe is started
# here: the suites state their own scope and Domenia-Start.ps1 is only used with -CheckOnly (no window, no AD access).
# The result is an INTEGRATION report. It is not the qualifying report bound to the delivery ZIP
# (release_guard.py --require-windows) and must never be presented as one.
[CmdletBinding()]
param(
    [string]$DevRoot='',
    [string]$OutDir='',
    [ValidateSet('env','compat','parser','startcheck','suites')][string[]]$Steps=@('env','compat','parser','startcheck','suites'),
    [string]$SuiteFilter='',
    [ValidatePattern('^([0-9a-f]{40})?$')][string]$SourceCommit='',
    [switch]$SourceDirty,
    [ValidateRange(30,3600)][int]$SuiteTimeoutSeconds=600,
    [ValidateRange(30,3600)][int]$StepTimeoutSeconds=900
)
$ErrorActionPreference='Stop'
# Relative paths follow the PowerShell location (Set-Location by vmctl), not the process directory that
# [IO.Path]::GetFullPath would use: the two differ for a process started by VBoxManage guestcontrol.
if(-not $DevRoot){$DevRoot=(Get-Location).ProviderPath}
$dev=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DevRoot).TrimEnd('\')
if(-not [IO.File]::Exists((Join-Path $dev 'wad\Domenia-Modules.ps1'))){throw ('Racine dev introuvable : '+$dev)}
if(-not $OutDir){$OutDir=Join-Path (Split-Path -Parent $dev) 'out\campaign'}
$out=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir).TrimEnd('\')
# Reports written under dev\ would change the tree that the fingerprint binds.
if(($out+'\').StartsWith($dev+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Le dossier de sortie doit etre hors de dev\.'}
if($env:COMPUTERNAME -ieq 'DESKTOP-285EKHU'){throw 'Campagne refusee sur l hote du labo : les tests s executent dans la VM.'}
$desktop51=($PSVersionTable.PSEdition -eq 'Desktop') -and ($PSVersionTable.PSVersion.Major -eq 5) -and ($PSVersionTable.PSVersion.Minor -eq 1)
if((-not $desktop51) -or (-not [Environment]::Is64BitProcess) -or ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT)){throw 'Windows PowerShell 5.1 x64 requis.'}
if(-not [IO.Directory]::Exists($out)){[void][IO.Directory]::CreateDirectory($out)}
$shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$summaryPath=Join-Path $out '_campaign.json'
$utf8=New-Object Text.UTF8Encoding($false)

function Get-DomeniaTreeFingerprint {
    # Same algorithm as campaign_report.py: sorted "relative/path<TAB>SHA256" lines, LF-terminated, hashed as UTF-8.
    param([string]$Root)
    $rows=New-Object 'System.Collections.Generic.List[string]'
    $prefix=$Root.Length+1
    foreach($file in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File)){
        $relative=$file.FullName.Substring($prefix).Replace('\','/')
        if($relative -match '(^|/)__pycache__/'){continue}
        $rows.Add($relative+"`t"+(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToUpperInvariant())
    }
    $sorted=$rows.ToArray()
    [Array]::Sort($sorted,[StringComparer]::Ordinal)
    $text=[string]::Join("`n",$sorted)+"`n"
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$digest=$sha.ComputeHash($utf8.GetBytes($text))}finally{$sha.Dispose()}
    return [pscustomobject]@{Sha256=([BitConverter]::ToString($digest).Replace('-',''));Files=$sorted.Length}
}

function Invoke-DomeniaCampaignProcess {
    param([string]$Name,[string[]]$Arguments,[int]$TimeoutSeconds)
    $stdout=Join-Path $out ($Name+'.stdout.txt');$stderr=Join-Path $out ($Name+'.stderr.txt')
    $started=[DateTime]::UtcNow;$watch=[Diagnostics.Stopwatch]::StartNew();$timedOut=$false;$code=$null
    $process=Start-Process -FilePath $shell -ArgumentList $Arguments -WorkingDirectory $dev -PassThru -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    # Windows PowerShell 5.1 only exposes ExitCode when the process handle was read before the exit.
    $null=$process.Handle
    if(-not $process.WaitForExit($TimeoutSeconds*1000)){$timedOut=$true;try{$process.Kill()}catch{}}else{$process.WaitForExit();$code=$process.ExitCode}
    $watch.Stop()
    $status='FAIL'
    if((-not $timedOut) -and ($code -eq 0)){$status='PASS'}
    return [pscustomobject]@{Name=$Name;Status=$status;ExitCode=$code;TimedOut=$timedOut;DurationMs=$watch.ElapsedMilliseconds;StartedUtc=$started.ToString('o');EndedUtc=[DateTime]::UtcNow.ToString('o');Output=[IO.Path]::GetFileName($stdout)}
}

function Get-DomeniaScriptArguments {
    param([string]$Path,[string[]]$Extra)
    return ,(@('-NoLogo','-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+$Path+'"'))+@($Extra))
}

$previous=$null
if([IO.File]::Exists($summaryPath)){$previous=[IO.File]::ReadAllText($summaryPath)|ConvertFrom-Json}
$results=New-Object 'System.Collections.Generic.List[object]'
$source=$null
if($null -ne $previous){$source=$previous.Source}

foreach($step in $Steps){
    Write-Host ('== '+$step)
    switch($step){
        'env' {
            # Taken before any suite runs: suites may write under dev\ afterwards.
            $fingerprint=Get-DomeniaTreeFingerprint -Root $dev
            $keyFiles=[ordered]@{}
            foreach($relative in @('Domenia.exe','wad\Domenia-Start.ps1','wad\Domenia-Modules.ps1','wad\Domenia-Core.ps1','wad\package-manifest.json')){
                $path=Join-Path $dev $relative
                $hash='ABSENT'
                if([IO.File]::Exists($path)){$hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
                $keyFiles[$relative.Replace('\','/')]=$hash
            }
            $source=[ordered]@{Commit=$SourceCommit;Dirty=[bool]$SourceDirty;Fingerprint=$fingerprint.Sha256;Files=$fingerprint.Files;FingerprintUtc=[DateTime]::UtcNow.ToString('o');KeyFiles=$keyFiles}
            $results.Add([pscustomobject]@{Name='env';Status='PASS';ExitCode=0;TimedOut=$false;DurationMs=0;StartedUtc=[DateTime]::UtcNow.ToString('o');EndedUtc=[DateTime]::UtcNow.ToString('o');Output=''})
        }
        'compat' {
            $results.Add((Invoke-DomeniaCampaignProcess -Name 'compat' -TimeoutSeconds $StepTimeoutSeconds -Arguments (Get-DomeniaScriptArguments -Path (Join-Path $dev 'tools\Test-DomeniaPs51Compat.ps1') -Extra @('-Root',('"'+$dev+'"')))))
        }
        'parser' {
            $results.Add((Invoke-DomeniaCampaignProcess -Name 'parser' -TimeoutSeconds $StepTimeoutSeconds -Arguments (Get-DomeniaScriptArguments -Path (Join-Path $dev 'engineering\d120\Test-NativeParser.ps1') -Extra @('-SourceRoot',('"'+$dev+'"'),'-ReportPath',('"'+(Join-Path $out 'parser.json')+'"'),'-RequireWindows51'))))
        }
        'startcheck' {
            # Manifest, hashes, parse and closed module plan; on failure Domenia-Start shows a message box, hence the short timeout.
            $results.Add((Invoke-DomeniaCampaignProcess -Name 'startcheck' -TimeoutSeconds 180 -Arguments (Get-DomeniaScriptArguments -Path (Join-Path $dev 'wad\Domenia-Start.ps1') -Extra @('-CheckOnly'))))
        }
        'suites' {
            $suitesOut=Join-Path $out 'suites'
            $started=[DateTime]::UtcNow;$watch=[Diagnostics.Stopwatch]::StartNew();$status='FAIL';$note=''
            try{
                & (Join-Path $dev 'engineering\d120\lab\Invoke-LabRun.ps1') -DevRoot $dev -OutDir $suitesOut -Filter $SuiteFilter -TimeoutSeconds $SuiteTimeoutSeconds
                $lab=[IO.File]::ReadAllText((Join-Path $suitesOut '_summary.json'))|ConvertFrom-Json
                $rows=@($lab.Suites)
                $bad=@($rows|Where-Object{($_.TimedOut -eq $true) -or ($_.ExitCode -ne 0) -or ($_.ReportWritten -ne $true)})
                $note=([string]$rows.Count+' suites, '+[string]$bad.Count+' en echec, hors delai ou sans rapport')
                if(($rows.Count -gt 0) -and ($bad.Count -eq 0)){$status='PASS'}
            }catch{$note=('Interrompu : '+$_.Exception.Message)}
            $watch.Stop()
            $results.Add([pscustomobject]@{Name='suites';Status=$status;ExitCode=$null;TimedOut=$false;DurationMs=$watch.ElapsedMilliseconds;StartedUtc=$started.ToString('o');EndedUtc=[DateTime]::UtcNow.ToString('o');Output='suites';Note=$note})
        }
    }
    Write-Host ('   '+$results[$results.Count-1].Status)
}

$merged=New-Object 'System.Collections.Generic.List[object]'
$current=@{}
foreach($r in $results){$current[[string]$r.Name]=$true}
if($null -ne $previous){foreach($r in @($previous.Steps)){if(-not $current.ContainsKey([string]$r.Name)){$merged.Add($r)}}}
foreach($r in $results){$merged.Add($r)}
$summary=[ordered]@{
    Kind='D120IntegrationCampaign'
    Qualifying=$false
    Note='Campagne d integration dans la VM. Ne remplace pas le rapport de qualification lie au ZIP (release_guard.py --require-windows).'
    Host=[ordered]@{Platform='Windows';Computer=[string]$env:COMPUTERNAME;PSEdition=[string]$PSVersionTable.PSEdition;PSVersion=$PSVersionTable.PSVersion.ToString();OS=[Environment]::OSVersion.VersionString;Is64BitProcess=[Environment]::Is64BitProcess;Interactive=[Environment]::UserInteractive;SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId}
    Source=$source
    # Point 130: facts only, read locally (no network). tools/validation_matrix.py --classify-report decides whether
    # this run is a laboratory one or a run on the real domain; the campaign never classifies itself.
    Environment=[ordered]@{Computer=[string]$env:COMPUTERNAME;Domain=$(try{[string][Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName}catch{''});UserDomain=[string]$env:USERDOMAIN;UserDnsDomain=[string]$env:USERDNSDOMAIN}
    Steps=$merged.ToArray()
}
[IO.File]::WriteAllText($summaryPath,($summary|ConvertTo-Json -Depth 6),$utf8)
$merged|Format-Table Name,Status,ExitCode,TimedOut,DurationMs -AutoSize|Out-String|Write-Host
$failed=@($results|Where-Object{$_.Status -ne 'PASS'})
if($failed.Count){exit 1}
exit 0
