#requires -Version 5.1
[CmdletBinding()]
param()
# Fixed RC1.17.6 candidate. Local synthetic suites only; never starts Domenia interactively,
# contacts a domain/endpoint, authenticates remotely or modifies a deployed installation.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root='C:\DomeniaLab\search-progress-20261013-r2'
$build='2026.10.13-DOMENIA-1.0-RC1.17.6-D120'
$archives=@(
    [pscustomobject]@{Edition='dev';Path=(Join-Path $root 'dev.zip');Sha256='fcb09dfc3fca21c7dd626db826050d625a8ca08c77fa83b539b4943d33369481';Bytes=4403845L;Files=397;Destination=(Join-Path $root 'source')},
    [pscustomobject]@{Edition='prod';Path=(Join-Path $root 'prod.zip');Sha256='9cc5dfc58614456cfcb328e139ee4d5e01d0b214bb31dad31f89629e20bc4517';Bytes=2100479L;Files=95;Destination=(Join-Path $root 'prod-source')}
)
if($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1 -or -not [Environment]::Is64BitProcess -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){
    throw 'Use Windows PowerShell 5.1 x64 -STA; another runtime cannot qualify this campaign.'
}
if(-not [IO.Directory]::Exists($root)){throw 'Guest staging directory is missing.'}
for($cursor=[IO.DirectoryInfo]::new($root);$null -ne $cursor;$cursor=$cursor.Parent){
    if($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'A redirected staging directory is refused.'}
}
$proof=Join-Path $root 'proof'
if(Test-Path -LiteralPath $proof){throw 'Proof directory exists. Preserve this attempt and prepare a new revision; never overwrite evidence.'}
foreach($archive in $archives){if(Test-Path -LiteralPath $archive.Destination){throw ('Extraction already exists: '+$archive.Destination)}}
[void][IO.Directory]::CreateDirectory($proof)
$receipts=[Collections.Generic.List[object]]::new()
$campaignWatch=[Diagnostics.Stopwatch]::StartNew()
$exitCode=1;$fatal='';$sourceBefore=@();$sourceAfter=@();$changed=@();$stopped=$false
$shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$dev=Join-Path $root 'source\dev'
$prod=Join-Path $root 'prod-source\prod'
function Save-Json {
    param([string]$Name,$Value)
    $path=Join-Path $proof $Name
    $temporary=$path+'.writing'
    [IO.File]::WriteAllText($temporary,($Value|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
    if([IO.File]::Exists($path)){[IO.File]::Replace($temporary,$path,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temporary,$path)}
}
function Get-Inventory {
    $rows=[Collections.Generic.List[object]]::new()
    foreach($location in @([pscustomobject]@{Edition='dev';Root=$dev},[pscustomobject]@{Edition='prod';Root=$prod})){
        foreach($file in @(Get-ChildItem -LiteralPath $location.Root -Recurse -File -Force|Sort-Object FullName)){
            if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Redirected source file: '+$file.FullName)}
            $relative=$file.FullName.Substring($location.Root.Length+1).Replace('\','/')
            $rows.Add([pscustomobject]@{Edition=$location.Edition;Path=$relative;Bytes=$file.Length;Sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()})
        }
    }
    return $rows.ToArray()
}
function Test-SuiteReport {
    param([string]$Name,[string]$Path)
    if(-not [IO.File]::Exists($Path)){return [pscustomobject]@{Valid=$false;Reason='JSON report missing';Cases=0}}
    try{
        $report=[IO.File]::ReadAllText($Path)|ConvertFrom-Json -ErrorAction Stop
        $count=0;$failed=0
        if($Name -eq 'Test-DomeniaOuRefresh'){
            if($null -eq $report.PSObject.Properties['Fail'] -or $null -eq $report.PSObject.Properties['Pass']){throw 'Missing Pass/Fail verdict'}
            $failed=[int]$report.Fail;$count=[int]$report.Pass+$failed
        }else{
            if($null -eq $report.PSObject.Properties['Failed']){throw 'Missing Failed verdict'}
            $failed=[int]$report.Failed
            if($null -ne $report.PSObject.Properties['Total']){$count=[int]$report.Total}
            elseif($null -ne $report.PSObject.Properties['Cases'] -and $report.Cases -is [ValueType]){$count=[int]$report.Cases}
            elseif($null -ne $report.PSObject.Properties['Passed'] -and $report.Passed -isnot [bool]){$count=[int]$report.Passed+$failed}
            if($null -ne $report.PSObject.Properties['Passed'] -and $report.Passed -is [bool] -and -not $report.Passed){throw 'Passed is false'}
            if($null -ne $report.PSObject.Properties['Status'] -and [string]$report.Status -ne 'PASS'){throw 'Status is not PASS'}
            if($null -ne $report.PSObject.Properties['Complete'] -and -not [bool]$report.Complete){throw 'Report is incomplete'}
        }
        if($count -le 0 -or $failed -ne 0){throw ('No successful non-empty suite: cases='+$count+', failed='+$failed)}
        if($Name -eq 'Test-DomeniaFreshness' -and -not [bool]$report.StorageExecuted){throw 'Native SQLite storage case was skipped'}
        if($Name -eq 'Test-DomeniaWiringRecherche' -and (-not [bool]$report.NativeWindowsPowerShell51 -or -not [bool]$report.Wpf)){throw 'Native WPF proof missing'}
        if($Name -eq 'Test-DomeniaLiveSearchView' -and (-not [bool]$report.RealDispatcher -or [string]$report.Sta -ne 'STA')){throw 'Real STA Dispatcher proof missing'}
        if($Name -eq 'Test-DomeniaGeometry' -and ([string]$report.Host.PSEdition -ne 'Desktop' -or [string]$report.Host.PSVersion -notlike '5.1.*')){throw 'Geometry was not executed under native Windows PowerShell 5.1'}
        return [pscustomobject]@{Valid=$true;Reason='JSON verdict passed';Cases=$count;Sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
    }catch{return [pscustomobject]@{Valid=$false;Reason=$_.Exception.Message;Cases=0}}
}
function Invoke-Suite {
    param($Plan)
    if(Test-Path -LiteralPath (Join-Path $root 'stop-after-current')){$script:stopped=$true;return $false}
    $name=[string]$Plan.Name
    $scriptPath=Join-Path $(if($Plan.Edition -eq 'prod'){$prod}else{$dev}) ([string]$Plan.RelativePath)
    $report=Join-Path $proof ($name+'.json')
    $stdout=Join-Path $proof ($name+'.stdout.txt');$stderr=Join-Path $proof ($name+'.stderr.txt')
    $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-STA','-File',$scriptPath)
    if($Plan.Report){$arguments+=@('-ReportPath',$report)}
    $arguments+=@($Plan.Arguments)
    # The fixed staging path and filenames have no whitespace or shell metacharacters.
    # Use a direct PowerShell child, preserving the machine's execution policy.
    foreach($argument in $arguments){if([string]$argument -match '[\s"]'){throw 'Unexpected quoting requirement in fixed test arguments'}}
    $watch=[Diagnostics.Stopwatch]::StartNew();$started=[datetime]::UtcNow.ToString('o');$child=$null;$processExit=$null;$timedOut=$false;$killAttempted=$false;$terminated=$false;$processError=''
    $scriptHash=(Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Save-Json 'runner-status.json' ([pscustomobject]@{State='Running';Current=$name;Completed=$receipts.Count;UTC=$started;RunnerPID=$PID})
    try{
        $child=Start-Process -FilePath $shell -ArgumentList $arguments -WorkingDirectory $(if($Plan.Edition -eq 'prod'){$prod}else{$dev}) -PassThru -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $null=$child.Handle
        Save-Json ($name+'-started.json') ([pscustomobject]@{Name=$name;PID=$child.Id;RunnerPID=$PID;StartedUTC=$started;Executable=$shell;Arguments=$arguments;ScriptSha256=$scriptHash;TimeoutSeconds=$Plan.TimeoutSeconds})
        $timedOut=-not $child.WaitForExit([int]$Plan.TimeoutSeconds*1000)
        if($timedOut){
            # Only the Process instance started above is terminated; no process-name or session sweep.
            $killAttempted=$true
            try{$child.Kill()}catch{$processError='Owned child termination: '+$_.Exception.Message}
            $terminated=$child.WaitForExit(5000)
            if(-not $terminated){$processError+=' Owned child still running; no following suite will be started.'}
        }else{$terminated=$true;$child.Refresh();$processExit=$child.ExitCode}
    }catch{
        $processError=$_.Exception.ToString()
        if($null -ne $child){
            try{
                if(-not $child.HasExited){$killAttempted=$true;$child.Kill()}
                $terminated=$child.WaitForExit(5000)
            }catch{$processError+=' Owned child cleanup: '+$_.Exception.Message}
        }
    }
    finally{
        $watch.Stop()
        $verdict=if($Plan.Report){Test-SuiteReport $name $report}else{[pscustomobject]@{Valid=($terminated -and -not $timedOut -and $processExit -eq 0 -and -not $processError);Reason='PROD -CheckOnly exit code';Cases=0}}
        $receipt=[pscustomobject]@{
            Name=$name;Edition=$Plan.Edition;RelativeScript=$Plan.RelativePath;ScriptSha256=$scriptHash;Arguments=$arguments
            StartedUTC=$started;EndedUTC=[datetime]::UtcNow.ToString('o');Milliseconds=$watch.ElapsedMilliseconds;TimeoutSeconds=$Plan.TimeoutSeconds
            RunnerPID=$PID;ChildPID=$(if($null -ne $child){$child.Id}else{$null});ExitCode=$processExit;TimedOut=$timedOut;KillAttempted=$killAttempted;ChildTerminated=$terminated;Error=$processError
            Stdout=[IO.Path]::GetFileName($stdout);Stderr=[IO.Path]::GetFileName($stderr);JsonReport=$(if($Plan.Report){[IO.Path]::GetFileName($report)}else{$null});ReportVerdict=$verdict
            Passed=($terminated -and -not $timedOut -and $processExit -eq 0 -and -not $processError -and $verdict.Valid)
        }
        $receipts.Add($receipt);Save-Json ($name+'-process.json') $receipt
        if($null -ne $child){$child.Dispose()}
        Write-Output ($name+': exit='+$processExit+', timeout='+$timedOut+', report='+$verdict.Valid+', ms='+$watch.ElapsedMilliseconds)
    }
    if(-not $terminated -and $null -ne $child){throw ('Unfinished owned child for '+$name+'; campaign halted.')}
    return $true
}
$plans=@(
    [pscustomobject]@{Name='Test-DomeniaFreshness';Edition='dev';RelativePath='wad\tests\Test-DomeniaFreshness.ps1';Report=$true;Arguments=@();TimeoutSeconds=240},
    [pscustomobject]@{Name='Test-DomeniaSearchTimeout';Edition='dev';RelativePath='wad\tests\Test-DomeniaSearchTimeout.ps1';Report=$true;Arguments=@();TimeoutSeconds=120},
    [pscustomobject]@{Name='Test-DomeniaSearchProgressWiring';Edition='dev';RelativePath='wad\tests\Test-DomeniaSearchProgressWiring.ps1';Report=$true;Arguments=@();TimeoutSeconds=240},
    [pscustomobject]@{Name='Test-DomeniaSearchScope';Edition='dev';RelativePath='wad\tests\Test-DomeniaSearchScope.ps1';Report=$true;Arguments=@();TimeoutSeconds=180},
    [pscustomobject]@{Name='Test-DomeniaOuRefresh';Edition='dev';RelativePath='wad\tests\Test-DomeniaOuRefresh.ps1';Report=$true;Arguments=@();TimeoutSeconds=180},
    [pscustomobject]@{Name='Test-DomeniaSearchCounter';Edition='dev';RelativePath='wad\tests\Test-DomeniaSearchCounter.ps1';Report=$true;Arguments=@();TimeoutSeconds=120},
    [pscustomobject]@{Name='Test-DomeniaDirectoryStatus';Edition='dev';RelativePath='wad\tests\Test-DomeniaDirectoryStatus.ps1';Report=$true;Arguments=@();TimeoutSeconds=120},
    [pscustomobject]@{Name='Test-DomeniaWiringRecherche';Edition='dev';RelativePath='wad\tests\Test-DomeniaWiringRecherche.ps1';Report=$true;Arguments=@();TimeoutSeconds=300},
    [pscustomobject]@{Name='Test-DomeniaLiveSearchView';Edition='dev';RelativePath='wad\tests\Test-DomeniaLiveSearchView.ps1';Report=$true;Arguments=@();TimeoutSeconds=300},
    [pscustomobject]@{Name='Test-DomeniaGeometry';Edition='dev';RelativePath='wad\tests\Test-DomeniaGeometry.ps1';Report=$true;Arguments=@();TimeoutSeconds=600},
    [pscustomobject]@{Name='PROD-CheckOnly';Edition='prod';RelativePath='wad\Domenia-Start.ps1';Report=$false;Arguments=@('-CheckOnly');TimeoutSeconds=240}
)
Save-Json 'runner-start.json' ([pscustomobject]@{Build=$build;StartedUTC=[datetime]::UtcNow.ToString('o');PID=$PID;Computer=$env:COMPUTERNAME;OS=[Environment]::OSVersion.VersionString;PowerShell=$PSVersionTable.PSVersion.ToString();PSEdition=$PSVersionTable.PSEdition;Is64Bit=[Environment]::Is64BitProcess;Apartment=[Threading.Thread]::CurrentThread.ApartmentState.ToString();SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId;UserInteractive=[Environment]::UserInteractive;RunnerSha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant();ExecutionPolicy=@(Get-ExecutionPolicy -List|ForEach-Object{[pscustomobject]@{Scope=[string]$_.Scope;Policy=[string]$_.ExecutionPolicy}});DomainAccessed=$false;EndpointNetworkAccessed=$false;InteractiveApplicationStarted=$false;CaptureRequested=$false})
Save-Json 'plan.json' ([pscustomobject]@{Build=$build;Archives=$archives;Steps=$plans;StepCount=$plans.Count;FixtureBoundary='Synthetic directory/UI ports; genuine local WPF and disposable native SQLite only. PROD startup is CheckOnly. No AD writes, endpoint probes or live application launch.'})
try{
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    foreach($archive in $archives){
        $zipFile=Get-Item -LiteralPath $archive.Path -ErrorAction Stop
        if($zipFile.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Redirected archive refused'}
        if($zipFile.Length -ne $archive.Bytes -or (Get-FileHash -LiteralPath $archive.Path -Algorithm SHA256).Hash -ine $archive.Sha256){throw ('Archive bytes/SHA256 mismatch: '+$archive.Edition)}
        $zip=[IO.Compression.ZipFile]::OpenRead($archive.Path)
        try{
            $files=@($zip.Entries|Where-Object{-not $_.FullName.EndsWith('/')})
            if($files.Count -ne $archive.Files){throw 'Archive file count differs from the frozen delivery'}
            $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach($entry in $zip.Entries){
                $name=$entry.FullName.Replace('\','/')
                if(-not $name.StartsWith($archive.Edition+'/',[StringComparison]::Ordinal) -or $name -match '(^|/)\.\.(/|$)|:' -or -not $seen.Add($name)){throw ('Unexpected/duplicate archive entry: '+$name)}
            }
        }finally{$zip.Dispose()}
        Expand-Archive -LiteralPath $archive.Path -DestinationPath $archive.Destination
        $manifestPath=Join-Path (Join-Path $archive.Destination $archive.Edition) 'wad\package-manifest.json'
        $manifest=[IO.File]::ReadAllText($manifestPath)|ConvertFrom-Json
        if([string]$manifest.Build -cne $build -or [string]$manifest.Edition -cne $archive.Edition){throw ('Archive release identity mismatch: '+$archive.Edition)}
    }
    $sourceBefore=@(Get-Inventory)
    Save-Json 'source-before.json' $sourceBefore
    if(@($sourceBefore|Where-Object{$_.Edition -eq 'dev'}).Count -ne 397 -or @($sourceBefore|Where-Object{$_.Edition -eq 'prod'}).Count -ne 95){throw 'Extracted inventory differs from the frozen archive count'}
    foreach($plan in $plans){
        $path=Join-Path $(if($plan.Edition -eq 'prod'){$prod}else{$dev}) $plan.RelativePath
        $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
        if(@($errors).Count){throw ('Windows PowerShell 5.1 parse failure: '+$plan.Name+': '+$errors[0].Message)}
    }
    Save-Json 'executed-source-plan.json' @(foreach($plan in $plans){$path=Join-Path $(if($plan.Edition -eq 'prod'){$prod}else{$dev}) $plan.RelativePath;[pscustomobject]@{Name=$plan.Name;Edition=$plan.Edition;Path=$plan.RelativePath;Sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();ParsedBy=$PSVersionTable.PSVersion.ToString();TimeoutSeconds=$plan.TimeoutSeconds}})
    foreach($plan in $plans){[void](Invoke-Suite $plan);if($script:stopped){break}}
    $sourceAfter=@(Get-Inventory);Save-Json 'source-after.json' $sourceAfter
    $beforeMap=@{};foreach($file in $sourceBefore){$beforeMap[$file.Edition+'/'+$file.Path]=$file}
    $afterMap=@{};foreach($file in $sourceAfter){$afterMap[$file.Edition+'/'+$file.Path]=$file}
    $changed=@(foreach($key in @(@($beforeMap.Keys)+@($afterMap.Keys)|Sort-Object -Unique)){
        if(-not $beforeMap.ContainsKey($key) -or -not $afterMap.ContainsKey($key) -or $beforeMap[$key].Sha256 -cne $afterMap[$key].Sha256){$key}
    })
    if(-not $stopped -and $receipts.Count -eq $plans.Count -and @($receipts|Where-Object{-not $_.Passed}).Count -eq 0 -and $changed.Count -eq 0){$exitCode=0}
}catch{$fatal=$_.Exception.ToString();Write-Error -Message $fatal -ErrorAction Continue}
finally{
    $campaignWatch.Stop()
    $status=if($exitCode -eq 0){'PASS'}elseif($stopped){'STOPPED'}else{'FAIL'}
    $summary=[pscustomobject]@{
        Build=$build;Status=$status;StartedEvidence='runner-start.json';EndedUTC=[datetime]::UtcNow.ToString('o');Milliseconds=$campaignWatch.ElapsedMilliseconds;RunnerPID=$PID
        ExpectedSteps=$plans.Count;ExecutedSteps=$receipts.Count;FailedSteps=@($receipts|Where-Object{-not $_.Passed}).Count;Processes=$receipts.ToArray();ChangedFiles=$changed;FatalError=$fatal
        SourceBefore='source-before.json';SourceAfter='source-after.json';SourceInventoryComplete=($sourceBefore.Count -eq 492 -and $sourceAfter.Count -eq 492)
        WindowsPowerShell51=$true;WpfSyntheticOnly=$true;DomainAccessed=$false;EndpointNetworkAccessed=$false;ADWrites=$false;InteractiveGuiValidated=$false;FormalPublishable=$false
        Limitations=@('Targeted offline Windows campaign only; not a complete release qualification.','No live AD search duration/completeness, remote ping/WMI or interactive user journey is proved.','Geometry uses a real off-screen WPF layout with simulated scale; no system DPI changes.','No screenshots are generated by this runner.')
    }
    Save-Json 'runner-complete.json' $summary
    Save-Json 'runner-status.json' ([pscustomobject]@{State=$status;Current='';Completed=$receipts.Count;UTC=[datetime]::UtcNow.ToString('o');RunnerPID=$PID})
    $evidence=@(Get-ChildItem -LiteralPath $proof -File|Where-Object{$_.Name -ne 'evidence-sha256.json'}|Sort-Object Name|ForEach-Object{[pscustomobject]@{File=$_.Name;Bytes=$_.Length;Sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}})
    Save-Json 'evidence-sha256.json' $evidence
    Write-Output ('Campaign '+$status+': '+$receipts.Count+'/'+$plans.Count+' steps, '+$changed.Count+' changed source files.')
}
exit $exitCode
