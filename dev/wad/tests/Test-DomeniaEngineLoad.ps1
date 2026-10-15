#requires -Version 5.1
# TE-05: load bench of the engine in demonstration (Demo.LatencyMs=200). The real engine runs: core functions
# extracted by AST, the modules of the closed loader, the real Initialize-AsyncEngine and its heartbeat, real worker
# runspaces answered by the DemoDirectory body. No domain, no network, no credential, no write to AD.
# Reported measures: total duration, maximum queue wait, p95 of the Dispatcher delay, p95 of RunspaceOpen, wake-ups
# at rest. Asserted: every read answered, the write refused cleanly, the engine at rest, fewer than 3 wake-ups per
# second at rest with the periodic timers declared in the code, no DispatcherTimer created outside New-DomeniaTimer.
# Windows PowerShell 5.1 x64 STA only.
[CmdletBinding()]
param([string]$ReportPath = '', [switch]$Quiet, [int]$Reads = 40, [int]$LatencyMs = 200)
$ErrorActionPreference = 'Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
$wad = Split-Path -Parent $PSScriptRoot
$modules = Join-Path $wad 'modules'
$checks = [Collections.Generic.List[object]]::new()
$measures = [ordered]@{}
$native = ($PSVersionTable.PSEdition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1 -and [Environment]::Is64BitProcess)
if (-not $native) { throw 'Windows PowerShell 5.1 x64 requis : une execution sous un autre moteur n est pas une preuve.' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Utiliser powershell.exe -STA.' }
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase

function Assert-True { param($Value,[string]$Why = 'Assertion fausse') if (-not [bool]$Value) { throw $Why } }
function Test-Case {
    param([string]$Name,[scriptblock]$Body)
    $script:CaseDetail = ''
    try { & $Body | Out-Null; $checks.Add([pscustomobject]@{Name=$Name;Status='Passed';Detail=[string]$script:CaseDetail}) }
    catch { $checks.Add([pscustomobject]@{Name=$Name;Status='Failed';Detail=($_.Exception.Message + ' @ ' + $_.ScriptStackTrace)}) }
}

# ---------------------------------------------------------------- real code
$t = $null; $e = $null
$script:CoreText = [IO.File]::ReadAllText((Join-Path $wad 'Domenia-Core.ps1'))
$script:CoreAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$t,[ref]$e)
if (@($e).Count) { throw ('Syntaxe du coeur : ' + $e[0].Message) }
function Get-CoreFunctionAst {
    param([string]$Name)
    $nodes = @($script:CoreAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name },$true))
    if ($nodes.Count -lt 1) { throw ('Fonction du coeur introuvable : ' + $Name) }
    return $nodes[0]
}
if ($null -eq ('Domenia.SelectionIdentity' -as [type])) { Add-Type -Path (Join-Path $modules 'Domenia-Identity.Types.cs') -ErrorAction Stop }
foreach ($file in @('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Search.Model.ps1','Domenia-Guard.Model.ps1','Domenia-Access.Model.ps1','Domenia-Safety.Model.ps1',
    'Domenia-Experience.Model.ps1','Domenia-Demo.Model.ps1','Domenia-Shell.Model.ps1','Domenia-Engine.UI.ps1','Domenia-Engine.Worker.ps1','Domenia-Demo.Worker.ps1',
    'Domenia-Isolation.Worker.ps1','Domenia-Receipts.Worker.ps1','Domenia-Release.Model.ps1','Domenia-Cache.Model.ps1')) {
    . (Join-Path $modules $file)
}
foreach ($name in @('Start-UiTask','Complete-UiTasks','Request-UiTaskStop','Stop-LatestUiTask','Detach-DomeniaReadUiTask','Complete-DomeniaDetachedReadJobs',
    'New-DomeniaWorkerRunspace','Assert-DomeniaWorkerOperationCode','Get-DomeniaWorkerCodeHash','ConvertTo-DomeniaCanonicalWorkerCode','Get-DomeniaWorkerOperationHashes',
    'Assert-DomeniaWorkerRegistry','Get-DomeniaWorkerEngineSelfTestCode','Initialize-AsyncEngine','Register-DomeniaAsyncEngineFault',
    'Invoke-DomeniaJobSuccessUi','Invoke-DomeniaJobErrorUi','Invoke-DomeniaUiHandler','Set-ControlsBusy','Get-NewTaskId','Update-TaskUi','Get-WorkerContext',
    'Dispose-AsyncEngine','Get-CfgValue','New-DefaultConfig','Get-DomeniaEffectiveWorkerResult','ConvertTo-DomeniaErrorInfo','Test-DomeniaInternalFault','Test-DomeniaOperatorMessage')) {
    . ([scriptblock]::Create((Get-CoreFunctionAst $name).Extent.Text))
}
$script:WorkerCommon = ''
foreach ($m in [regex]::Matches($script:CoreText,'(?ms)^\$script:WorkerCommon (?:=|\+=) @''\r?\n(.*?)\r?\n''@')) { $script:WorkerCommon += "`r`n" + $m.Groups[1].Value }
$script:WorkerCommon += "`r`n" + (Get-DomeniaReceiptsCommon)

# ---------------------------------------------------------------- doubles of the window and of the journal
function Initialize-DomeniaWorkerContextCache {
    if ($null -ne $script:WorkerContextStatic) { return }
    $script:WorkerContextStatic = [pscustomobject]@{AdModuleSources=@();AdRequiredCommands=@();AdTypeNames=@();AdManagementHash='';AdResourceHash='';MissingCriticalFunctions=@();MissingCriticalControls=@();CriticalFunctionCount=0;CriticalControlCount=0;PowerShellVersion='5.1';IsSta=$true}
}
function Get-DomeniaRetryCredential { param([string]$OperationId) return $null }
function Get-DomeniaAccessScope { param([string]$OperationId) return 'Directory' }
function Set-DomeniaRetryWorkerContext { param($Context,[string]$OperationId) return $Context }
function Set-DomeniaTargetCredentialContext { param($Context,$Payload) return $Context }
function Write-AppLog { param($Text,$Level) $script:Logs.Add([string]$Text) }
function Add-DomeniaUiLog { param($Area,$Text,$Level) $script:Logs.Add([string]$Text) }
function Set-Status { param($Text,$Level) $script:Statuses.Add([string]$Text) }
function Write-StartupTrace { param($Stage,$Status,$Detail,$DurationMs) }
function Get-DomeniaControl { param([string]$Name) return $null }
function Stop-DomeniaLiveJob { param($Job) }
function Stop-DomeniaComputerUserProbeUi { param($Job,$Reason) }
function Receive-DomeniaComputerUserProbeProgress { param($Job) }
function Test-DomeniaSelectionLoadCurrent { return $false }
function Update-DomeniaSelectionReadUi { param($Phase,$Message) }
function Clear-DomeniaCurrentObjectRequest { param($RequestId) }
function Clear-DomeniaComputerUserProbeState { param($ProbeId,$Computer) }
function Inspect-DomeniaAccessResult { param($Job,$Output) }
function Request-DomeniaAccessRecovery { param($Operation,$OperationId,$ErrorValue,$Interactive) return $false }
function Apply-CurrentPermissionUi { param([switch]$StartupFastPath) }
function Stop-DomeniaLive { param([switch]$Closing) }
function Stop-DomeniaSelectionOpenTimer { }
function Clear-DomeniaTreeRenderJobs { }
function Request-DomeniaDashboardRefresh { param([switch]$Immediate) }
function Show-ErrorBox { param($Message) $script:Statuses.Add('ERREUR ' + [string]$Message) }
function Complete-LoadUi { param($Result,$State) $script:Done.Add([pscustomobject]@{Index=[int]$State.Index;At=$script:Clock.Elapsed.TotalMilliseconds;Ok=$true;Text=''}) }
function Fail-LoadUi { param($Message,$State) $script:Done.Add([pscustomobject]@{Index=[int]$State.Index;At=$script:Clock.Elapsed.TotalMilliseconds;Ok=$false;Text=[string]$Message}) }

function Invoke-LoadPump {
    param([int]$Milliseconds = 30)
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds([Math]::Max(1,$Milliseconds))
    $timer.Tag = $frame
    $timer.Add_Tick({ param($sender,$eventArgs) $sender.Stop(); $sender.Tag.Continue = $false })
    $timer.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}
function Wait-LoadIdle {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (($script:AsyncJobs.Count -gt 0 -or @($script:DetachedReadJobs).Count -gt 0 -or [bool]$script:AsyncTimer.IsEnabled) -and $watch.Elapsed.TotalSeconds -lt 20) { Invoke-LoadPump 50 }
    return (-not [bool]$script:AsyncTimer.IsEnabled)
}
function Get-Percentile {
    param([double[]]$Values,[double]$Percent)
    if (-not $Values.Count) { return 0.0 }
    $sorted = @($Values | Sort-Object)
    return [Math]::Round([double]$sorted[[Math]::Min($sorted.Count - 1,[Math]::Max(0,[int][Math]::Ceiling($Percent / 100 * $sorted.Count) - 1))],1)
}

function Get-PinnedBody {
    # Same literal indexing as tools/update_worker_contracts.py: every here-string of the function, in order. A queued
    # entry checks its pinned body before it waits, even in demonstration: the bench passes the real body.
    param([string]$Operation)
    # ConvertFrom-Json of Windows PowerShell 5.1 writes a JSON array as ONE object: it is unrolled by @() afterwards.
    $parsed = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $wad) 'tools\operation-contracts.json')) | ConvertFrom-Json
    $contracts = @($parsed)
    $c = @($contracts | Where-Object { $_.Operation -eq $Operation })
    if ($c.Count -ne 1) { throw ('Contrat absent : ' + $Operation) }
    $ft = $null; $fe = $null
    $fileAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $wad) ([string]$c[0].File)),[ref]$ft,[ref]$fe)
    $fn = @($fileAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq [string]$c[0].Function },$true))[0]
    $here = @($fn.FindAll({ param($n) ($n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst]) -and $n.Extent.Text.StartsWith('@') },$true) | Sort-Object { $_.Extent.StartOffset })
    $raw = $here[[int]$c[0].LiteralIndex].Extent.Text -replace "`r`n","`n"
    $body = $raw.Substring(3,$raw.Length - 6)
    [void](Assert-DomeniaWorkerOperationCode -OperationId $Operation -Code $body)
    return $body
}

# ---------------------------------------------------------------- state
$script:Config = New-DefaultConfig
$script:Config.Async.MaxQueued = 64
$script:AsyncJobs = [ordered]@{}; $script:DetachedReadJobs = New-Object System.Collections.ArrayList
$script:AsyncSequence = 0; $script:ControlBusyRef = @{}; $script:LatestTaskId = ''; $script:SessionEpoch = [long]1
$script:AsyncEngineClosing = $false; $script:AsyncEngineReady = $false; $script:AsyncTimer = $null; $script:LiveWorkerPools = @{}
$script:DirectoryCredentialFaulted = $false; $script:AccessState = $null; $script:ReadOnlyMode = $true; $script:WriteState = 'Idle'; $script:ActiveWriteTaskId = ''
$script:ProcessIdentity = 'DEMO\poste-banc'; $script:Logs = New-Object 'System.Collections.Generic.List[string]'; $script:Statuses = New-Object 'System.Collections.Generic.List[string]'
$script:DemoMode = $true; $script:DemoModeFixed = $true
$script:DemoDirectory = New-DomeniaDemoDirectory -LatencyMs $LatencyMs
$script:Conn = [pscustomobject]@{Connected=$true;AuthMode='Demo';UseCredential=$false;Credential=$null;User='DEMO\demo.operateur';BindUser='DEMO\demo.operateur';Domain='demo.invalid';Netbios='DEMO';BaseDn='DC=demo,DC=invalid';Server='';RootPath='';LastError=''}
$script:Done = New-Object 'System.Collections.Generic.List[object]'
$script:Clock = [Diagnostics.Stopwatch]::StartNew()

# ---------------------------------------------------------------- cases
Test-Case 'Controle statique : aucune DispatcherTimer creee hors New-DomeniaTimer' {
    $allowed = @('New-DomeniaTimer','Get-DomeniaPulse','Ensure-LinkProbeTimer','Queue-LiveGlobalSearch','Initialize-DomeniaSupportUi')
    $offending = New-Object 'System.Collections.Generic.List[string]'
    foreach ($path in @((Join-Path $wad 'Domenia-Core.ps1')) + @(Get-ChildItem -LiteralPath $modules -Filter '*.ps1' -File | ForEach-Object { $_.FullName })) {
        $ft = $null; $fe = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path,[ref]$ft,[ref]$fe)
        $creations = @($ast.FindAll({ param($n)
            (($n -is [Management.Automation.Language.CommandAst]) -and ([string]$n.GetCommandName() -eq 'New-Object') -and ($n.Extent.Text -match 'Threading\.DispatcherTimer\b')) -or
            (($n -is [Management.Automation.Language.InvokeMemberExpressionAst]) -and ($n.Static) -and ([string]$n.Member.Extent.Text -eq 'new') -and ($n.Expression.Extent.Text -match 'Threading\.DispatcherTimer\]'))
        },$true))
        foreach ($node in $creations) {
            $owner = $node.Parent
            while ($null -ne $owner -and $owner -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $owner = $owner.Parent }
            $ownerName = if ($null -ne $owner) { [string]$owner.Name } else { '' }
            if ($allowed -notcontains $ownerName) { $offending.Add((Split-Path -Leaf $path) + ':' + $node.Extent.StartLineNumber + ' (' + $ownerName + ')') }
        }
    }
    Assert-True ($offending.Count -eq 0) ('DispatcherTimer hors fabrique : ' + ($offending.ToArray() -join ', '))
}

Test-Case ('Banc de charge en demonstration : ' + $Reads + ' lectures, latence ' + $LatencyMs + ' ms, une ecriture refusee') {
    Initialize-AsyncEngine
    Assert-True ([bool]$script:AsyncTimer.IsEnabled) 'Moteur non demarre'
    $targets = @($script:DemoDirectory.Objects | Where-Object { @($_.DeniedFor).Count -eq 0 -and ((@($_.Attributes.objectClass) -contains 'user') -or (@($_.Attributes.objectClass) -contains 'computer')) } | ForEach-Object { [string]$_.DN })
    Assert-True ($targets.Count -ge 3) ('Annuaire de demonstration trop petit : ' + $targets.Count)
    # Dispatcher probe (test only): lateness of a 50 ms timer during the whole bench.
    $script:ProbeLate = New-Object 'System.Collections.Generic.List[double]'
    $script:ProbeLast = $script:Clock.Elapsed.TotalMilliseconds
    $probe = New-Object System.Windows.Threading.DispatcherTimer
    $probe.Interval = [TimeSpan]::FromMilliseconds(50)
    $probe.Add_Tick({ $now = $script:Clock.Elapsed.TotalMilliseconds; $script:ProbeLate.Add([Math]::Max(0,$now - $script:ProbeLast - 50)); $script:ProbeLast = $now })
    $openCode = Get-PinnedBody -Operation 'OpenAdObject'
    $wakeupsBefore = (Get-DomeniaPulseState).Wakeups
    $begin = $script:Clock.Elapsed.TotalMilliseconds
    try {
        # The submission loop holds the Dispatcher by construction (the bench sends 40 requests at once): it is
        # measured apart, the Dispatcher probe covers the processing that follows.
        for ($i = 0; $i -lt $Reads; $i++) {
            $payload = [pscustomobject]@{DN=$targets[$i % $targets.Count];Type='Utilisateur';Properties=@('name','objectGUID');Nonce=$i}
            [void](Start-UiTask -Name ('Lecture ' + $i) -OperationId 'OpenAdObject' -Code $openCode -Payload $payload -CallbackState ([pscustomobject]@{Index=$i}) -SuccessHandler 'Complete-LoadUi' -ErrorHandler 'Fail-LoadUi')
        }
        $submitted = $script:Clock.Elapsed.TotalMilliseconds
        $script:ProbeLast = $submitted
        $probe.Start()
        $queuedAtStart = @($script:AsyncJobs.Values | Where-Object { [string]$_.State -eq 'Queued' }).Count
        $refused = ''
        try { [void](Start-UiTask -Name 'Ecriture du banc' -OperationId 'WriteAttributes' -Code 'unused-in-demo' -Payload ([pscustomobject]@{DN=$targets[0]}) -IsWrite -SuccessHandler 'Complete-LoadUi' -ErrorHandler 'Fail-LoadUi') } catch { $refused = $_.Exception.Message }
        Assert-True ($refused -match 'DOMENIA_DEMO_WRITE') ('Ecriture non refusee proprement : ' + $refused)
        Assert-True (@($script:AsyncJobs.Values | Where-Object { [bool]$_.IsWrite }).Count -eq 0) 'Une ecriture est entree dans le moteur'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while ($script:Done.Count -lt $Reads -and $watch.Elapsed.TotalSeconds -lt 180) { Invoke-LoadPump 30 }
    } finally { $probe.Stop() }
    $end = $script:Clock.Elapsed.TotalMilliseconds
    Assert-True ($script:Done.Count -eq $Reads) ('Lectures repondues : ' + $script:Done.Count + ' / ' + $Reads)
    $failed = @($script:Done | Where-Object { -not $_.Ok })
    Assert-True ($failed.Count -eq 0) ('Lectures en echec : ' + $failed.Count + ' ; ' + (@($failed | Select-Object -First 1 | ForEach-Object { $_.Text }) -join ''))
    Assert-True ($queuedAtStart -gt 0) 'Banc sans file d attente : la charge ne sature pas le moteur'
    $wait = Get-DomeniaRuntimeMetricSummary -Provenance 'Queue' -Prefix 'Wait:'
    $open = Get-DomeniaRuntimeMetricSummary -Provenance 'Dispatcher' -Prefix 'RunspaceOpen:'
    Assert-True ([int]$wait.Count -ge $queuedAtStart) ('Attente en file non mesuree : ' + $wait.Count + ' mesure(s) pour ' + $queuedAtStart + ' demande(s) en file')
    $measures['Lectures'] = $Reads
    $measures['LatenceDemoMs'] = $LatencyMs
    $measures['DureeTotaleMs'] = [Math]::Round($end - $begin)
    $measures['SoumissionMs'] = [Math]::Round($submitted - $begin)
    $measures['EnFileAuDepart'] = $queuedAtStart
    $measures['AttenteMaxEnFileMs'] = $wait.Max
    $measures['AttenteP95EnFileMs'] = $wait.P95
    $measures['DispatcherRetardP95Ms'] = (Get-Percentile -Values $script:ProbeLate.ToArray() -Percent 95)
    $measures['DispatcherRetardMaxMs'] = (Get-Percentile -Values $script:ProbeLate.ToArray() -Percent 100)
    $measures['RunspaceOpenP95Ms'] = $open.P95
    $measures['RunspaceOpenMesures'] = $open.Count
    $measures['ReveilsPulsationPendantBanc'] = (Get-DomeniaPulseState).Wakeups - $wakeupsBefore
    $script:CaseDetail = (@($measures.Keys | ForEach-Object { $_ + '=' + [string]$measures[$_] }) -join ' ; ')
    # Engine at rest: the poll timer stops once the last task has left.
    [void](Wait-LoadIdle)
    Assert-True (-not [bool]$script:AsyncTimer.IsEnabled) 'Minuteur du moteur encore actif sans tache'
}

Test-Case 'Point 16 : sous une rafale continue d actions explicites, la lecture de fond demarre apres son attente et repond' {
    # Qualification of the visible priority under load: six places held by slow explicit reads (1.5 s each), a new
    # explicit read every 100 ms during 8 s, and one background read submitted after the first ones. Measured: the wait
    # of the background read, the p95 wait of the explicit reads and the number of aged promotions.
    $savedDirectory = $script:DemoDirectory
    # 5 s is the lower bound applied by Get-DomeniaEngineLimits.
    $script:Config.Async['BackgroundAgingSeconds'] = 5
    $script:DomeniaAgedPromotions = 0
    $script:DomeniaRuntimeMetrics = @{}
    $script:DemoDirectory = New-DomeniaDemoDirectory -LatencyMs 1500
    $openCode = Get-PinnedBody -Operation 'OpenAdObject'
    $targets = @($script:DemoDirectory.Objects | Where-Object { @($_.DeniedFor).Count -eq 0 -and ((@($_.Attributes.objectClass) -contains 'user') -or (@($_.Attributes.objectClass) -contains 'computer')) } | ForEach-Object { [string]$_.DN })
    $script:Done.Clear()
    $refusedCount = 0
    try {
        Initialize-AsyncEngine
        for ($i = 0; $i -lt 6; $i++) { [void](Start-UiTask -Name ('Explicite ' + $i) -OperationId 'OpenAdObject' -Code $openCode -Payload ([pscustomobject]@{DN=$targets[$i % $targets.Count];Type='Utilisateur';Properties=@('name');Nonce=('x' + $i)}) -CallbackState ([pscustomobject]@{Index=$i}) -SuccessHandler 'Complete-LoadUi' -ErrorHandler 'Fail-LoadUi') }
        $backgroundAt = $script:Clock.Elapsed.TotalMilliseconds
        [void](Start-UiTask -Name 'Campagne de fond' -OperationId 'OpenAdObject' -Code $openCode -Payload ([pscustomobject]@{DN=$targets[0];Type='Utilisateur';Properties=@('name');Nonce='fond'}) -CallbackState ([pscustomobject]@{Index=-1}) -SuccessHandler 'Complete-LoadUi' -ErrorHandler 'Fail-LoadUi' -TaskClass 'Background')
        $watch = [Diagnostics.Stopwatch]::StartNew(); $n = 6
        while ($watch.Elapsed.TotalSeconds -lt 8) {
            try { [void](Start-UiTask -Name ('Explicite ' + $n) -OperationId 'OpenAdObject' -Code $openCode -Payload ([pscustomobject]@{DN=$targets[$n % $targets.Count];Type='Utilisateur';Properties=@('name');Nonce=('x' + $n)}) -CallbackState ([pscustomobject]@{Index=$n}) -SuccessHandler 'Complete-LoadUi' -ErrorHandler 'Fail-LoadUi') } catch { $refusedCount++ }
            $n++
            Invoke-LoadPump 100
        }
        $wait = [Diagnostics.Stopwatch]::StartNew()
        while (@($script:Done | Where-Object { [int]$_.Index -eq -1 }).Count -eq 0 -and $wait.Elapsed.TotalSeconds -lt 30) { Invoke-LoadPump 50 }
        $background = @($script:Done | Where-Object { [int]$_.Index -eq -1 })
        Assert-True ($background.Count -eq 1 -and [bool]$background[0].Ok) 'La lecture de fond n a pas repondu sous charge'
        $backgroundWait = Get-DomeniaRuntimeMetricSummary -Provenance 'Queue' -Prefix 'Wait:Background'
        $explicitWait = Get-DomeniaRuntimeMetricSummary -Provenance 'Queue' -Prefix 'Wait:Explicit'
        $measures['P16FondAttenteMs'] = $backgroundWait.Max
        $measures['P16FondReponduApresMs'] = [Math]::Round($background[0].At - $backgroundAt)
        $measures['P16ExplicitesAttenteP95Ms'] = $explicitWait.P95
        $measures['P16ExplicitesRefuseesFilePleine'] = $refusedCount
        $measures['P16PromotionsApresAttente'] = [int]$script:DomeniaAgedPromotions
        $script:CaseDetail = ('fond attendu {0} ms, repondu apres {1} ms ; explicites p95 {2} ms ; {3} refus file pleine ; {4} promotion(s) apres attente.' -f $backgroundWait.Max,$measures['P16FondReponduApresMs'],$explicitWait.P95,$refusedCount,$script:DomeniaAgedPromotions)
        Assert-True ([int]$script:DomeniaAgedPromotions -ge 1) 'La charge n a pas exige de place reservee : banc non probant'
        Assert-True ([double]$backgroundWait.Max -le 15000) ('Attente du fond trop longue : ' + $backgroundWait.Max + ' ms')
    }
    finally {
        foreach ($id in @($script:AsyncJobs.Keys)) { try { Request-UiTaskStop -Id $id -Silent -Force } catch { } }
        [void](Wait-LoadIdle)
        $script:DemoDirectory = $savedDirectory
        $script:Config.Async.Remove('BackgroundAgingSeconds')
    }
}

Test-Case 'Repos : moins de 3 reveils par seconde avec les minuteries periodiques declarees dans le code' {
    # The periodic heartbeat subscribers are those declared with a rest pace (-IdleIntervalMs) in the application
    # sources. The others are one-shot or armed on demand (saves, journal, debounces) and do not run at rest.
    $declared = New-Object 'System.Collections.Generic.List[object]'
    foreach ($path in @((Join-Path $wad 'Domenia-Core.ps1')) + @(Get-ChildItem -LiteralPath $modules -Filter '*.ps1' -File | ForEach-Object { $_.FullName })) {
        foreach ($m in [regex]::Matches([IO.File]::ReadAllText($path),"New-DomeniaTimer -Owner '([^']+)' -IntervalMs (\d+) -IdleIntervalMs (\d+)")) {
            $declared.Add([pscustomobject]@{Owner=$m.Groups[1].Value;Interval=[int]$m.Groups[2].Value;Idle=[int]$m.Groups[3].Value})
        }
    }
    Assert-True ($declared.Count -ge 5) ('Minuteries periodiques declarees : ' + $declared.Count)
    Assert-True (-not [bool]$script:AsyncTimer.IsEnabled) 'Moteur non au repos'
    $timers = New-Object 'System.Collections.Generic.List[object]'
    foreach ($d in $declared) {
        $timer = New-DomeniaTimer -Owner ('Banc:' + $d.Owner) -IntervalMs $d.Interval -IdleIntervalMs $d.Idle -Busy { $false } -Tick { $script:RestTicks++ }
        $timer.Start(); $timers.Add($timer)
    }
    try {
        # Settle on the rest pace (the first tick of each subscriber runs at its normal interval).
        Invoke-LoadPump 2500
        $script:RestTicks = 0
        $before = Get-DomeniaPulseState
        $watch = [Diagnostics.Stopwatch]::StartNew()
        Invoke-LoadPump 6000
        $seconds = $watch.Elapsed.TotalSeconds
        $after = Get-DomeniaPulseState
        $wakeups = ([long]$after.Wakeups - [long]$before.Wakeups) + ([long]$after.Standalone - [long]$before.Standalone)
        $rate = [Math]::Round($wakeups / $seconds,2)
        $measures['MinuteriesPeriodiques'] = $declared.Count
        $measures['ReveilsParSecondeAuRepos'] = $rate
        $script:CaseDetail = ('{0} minuteries periodiques ({1}) ; {2} reveils en {3} s, soit {4} par seconde ; {5} ticks d abonnes.' -f $declared.Count,((@($declared | ForEach-Object { $_.Owner })) -join ', '),$wakeups,[Math]::Round($seconds,1),$rate,$script:RestTicks)
        Assert-True ($rate -lt 3) ('Reveils au repos : ' + $rate + ' par seconde')
        Assert-True ($script:RestTicks -gt 0) 'Aucun abonne n a tourne pendant la mesure'
    } finally { foreach ($timer in $timers) { try { $timer.Stop() } catch { } } }
}

try { Dispose-AsyncEngine } catch { }

# ---------------------------------------------------------------- report
$passed = @($checks | Where-Object { $_.Status -eq 'Passed' }).Count
$failedCount = @($checks | Where-Object { $_.Status -eq 'Failed' }).Count
if (-not $ReportPath) { $ReportPath = Join-Path ([IO.Path]::GetTempPath()) ('Domenia-engine-load-' + [guid]::NewGuid().ToString('N') + '.json') }
$report = [ordered]@{
    Kind='EngineLoad';Host=$PSVersionTable.PSVersion.ToString();NativeWindowsPowerShell51=$native;Demo=$true;LiveAD=$false
    Points=@('TE-05','PF-04','PF-05','PF-06','FI-03','FI-05','P16')
    Passed=$passed;Failed=$failedCount;Complete=($failedCount -eq 0 -and $passed -gt 0);Measures=$measures;Tests=$checks.ToArray()
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report | ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
if (-not $Quiet) {
    Write-Host ("$passed reussis, $failedCount en echec. Rapport : " + $ReportPath)
    foreach ($key in $measures.Keys) { Write-Host ('  ' + $key + ' = ' + [string]$measures[$key]) }
    $checks | Where-Object { $_.Status -eq 'Failed' } | ForEach-Object { Write-Host ('  ECHEC ' + $_.Name + ' : ' + $_.Detail) }
}
if ($failedCount -gt 0) { exit 1 }
exit 0
