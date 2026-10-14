#requires -Version 5.1
# Wiring tests of the engine lot (D002, D003, D011, D014, D015, D016, D017, D018, D019, D020, D089), plus the single
# local writer of the cache lot (D028: real queue, real LocalStore body, real schema in a temporary file).
# Method of Test-DomeniaPreload: the real core functions are extracted by AST, the real rule and engine modules
# are dot-sourced, WPF controls are real (main XAML, login XAML). The network is replaced by registered test
# operations whose bodies run in real worker runspaces. No domain, no credential, no write to AD.
# Every case targets one wiring: removing it makes the case fail. Windows PowerShell 5.1 x64 STA only.
[CmdletBinding()]
param([string]$ReportPath = '', [switch]$Quiet)
$ErrorActionPreference = 'Stop'
$wad = Split-Path -Parent $PSScriptRoot
$dev = Split-Path -Parent $wad
$modules = Join-Path $wad 'modules'
$checks = [Collections.Generic.List[object]]::new()
$script:UiBlockingAudit = $null
$native = ($PSVersionTable.PSEdition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1 -and [Environment]::Is64BitProcess)
if (-not $native) { throw 'Windows PowerShell 5.1 x64 requis : une execution sous un autre moteur n est pas une preuve.' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Utiliser powershell.exe -STA.' }
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms

function Assert-True { param($Value,[string]$Why = 'Assertion fausse') if (-not [bool]$Value) { throw $Why } }
function Test-Case {
    param([string]$Name,[scriptblock]$Body)
    try { Reset-WiringState; & $Body | Out-Null; $checks.Add([pscustomobject]@{Name=$Name;Status='Passed';Detail=[string]$script:CaseDetail}) }
    catch { $checks.Add([pscustomobject]@{Name=$Name;Status='Failed';Detail=($_.Exception.Message + ' @ ' + $_.ScriptStackTrace)}) }
    finally { try { Stop-WiringJobs } catch { } }
}

# ---------------------------------------------------------------- real code: modules, then core functions
$t = $null; $e = $null
$script:CoreText = [IO.File]::ReadAllText((Join-Path $wad 'Domenia-Core.ps1'))
$script:CoreAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$t,[ref]$e)
if (@($e).Count) { throw ('Syntaxe du coeur : ' + $e[0].Message) }
function Get-CoreFunctionAst {
    param([string]$Name)
    $nodes = @($script:CoreAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name -and $null -eq $n.Parent.Parent.Parent },$true))
    if ($nodes.Count -ne 1) { $nodes = @($script:CoreAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name },$true)) | Select-Object -First 1 }
    if (@($nodes).Count -lt 1) { throw ('Fonction du coeur introuvable : ' + $Name) }
    return @($nodes)[0]
}
if ($null -eq ('Domenia.SelectionIdentity' -as [type])) { Add-Type -Path (Join-Path $modules 'Domenia-Identity.Types.cs') -ErrorAction Stop }
foreach ($file in @('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Search.Model.ps1','Domenia-Guard.Model.ps1','Domenia-Access.Model.ps1','Domenia-Safety.Model.ps1','Domenia-Experience.Model.ps1','Domenia-Demo.Model.ps1','Domenia-Shell.Model.ps1',
    'Domenia-Selection.UI.ps1','Domenia-Experience.UI.ps1','Domenia-Engine.UI.ps1','Domenia-Engine.Worker.ps1','Domenia-Demo.Worker.ps1','Domenia-Demo.UI.ps1',
    'Domenia-Startup.UI.ps1','Domenia-Isolation.Worker.ps1','Domenia-Receipts.Worker.ps1',
    'Domenia-Cache.Model.ps1','Domenia-Live.Model.ps1','Domenia-Release.Model.ps1','Domenia-Storage.Worker.ps1','Domenia-Storage.UI.ps1')) {
    $path = Join-Path $modules $file
    if (-not [IO.File]::Exists($path)) { throw ('Module absent : ' + $file) }
    . $path
}
$script:CoreFunctions = @('Start-UiTask','Complete-UiTasks','Request-UiTaskStop','Stop-LatestUiTask','Detach-DomeniaReadUiTask','Complete-DomeniaDetachedReadJobs',
    'New-DomeniaWorkerRunspace','Assert-DomeniaWorkerOperationCode','Get-DomeniaWorkerCodeHash','ConvertTo-DomeniaCanonicalWorkerCode','Get-DomeniaWorkerOperationHashes',
    'Invoke-DomeniaJobSuccessUi','Invoke-DomeniaJobErrorUi','Invoke-DomeniaUiHandler','Set-ControlsBusy','Get-NewTaskId','Update-TaskUi','Get-WorkerContext',
    'Dispose-AsyncEngine','Request-DomeniaDashboardRefresh','Get-MainXaml','Get-DomeniaControl','Set-DomeniaControlText','New-DefaultConfig','Load-AppConfig','Get-CfgValue',
    'Get-DomeniaEffectiveWorkerResult','Get-DomeniaIndexScope','Search-DomeniaIndexUi','Get-DomeniaFastLoginVaultIdentity','Update-DomeniaFastLoginVaultUi','Set-DomeniaFastLoginBusy','Complete-DomeniaFastLoginSuccess','Start-DomeniaFastLoginAttempt',
    'New-DomeniaFastLoginSession','Start-DomeniaFastLoginWorker','Update-DomeniaFastLoginAttempt','Reset-DomeniaFastLoginAttempt','Stop-DomeniaFastLoginWorker',
    'Invoke-DomeniaInProcessAuthProbe','Start-DomeniaLoginAuthRunspace','Read-DomeniaAuthRunspaceResult','Complete-DomeniaLoginAuthRunspaceCleanup',
    'Stop-DomeniaLoginAuthRunspace','Queue-DomeniaLoginAuthRunspaceCleanup','Ensure-DomeniaAuthCleanupTimer','Add-DomeniaFastLoginDetail',
    'Convert-DomeniaLoginFailureMessage','Get-DomeniaLoginFailureHint','Assert-WriteAllowed','Assert-DomeniaRemoteWriteAllowed','New-DomeniaAccountAuthRequest',
    'Load-TreeChildren','Complete-DomeniaTreeChildrenUi','Fail-DomeniaTreeChildrenUi','Queue-DomeniaTreeRowsToNode','Initialize-DomeniaTreeRenderTimer',
    'Stop-DomeniaTreeRenderForNode','New-TreeItem','New-DomeniaTreeRowItem','New-DomeniaTreeSystemGroup','Get-DomeniaTreeRenderRows','Get-DomeniaTreeHeaderTemplate','New-DomeniaTreeLoadingItem','Get-DomeniaParkSharedPath','Merge-DomeniaParkState','Complete-DomeniaParkSweepUi','Sync-DomeniaParkShared',
    'Get-DomeniaSafeObjectPropertyNames','Initialize-DomeniaWinSqliteNative','New-DomeniaUtf8Ptr','ConvertFrom-DomeniaUtf8Ptr','Open-DomeniaDatabase',
    'Close-DomeniaDatabase','Invoke-DomeniaDbExec','Get-DomeniaStartupXaml','Convert-DomeniaXamlToBootTheme','Get-DomeniaBootThemeResources',
    'Get-DomeniaBootThemePalette','Get-DomeniaStandardLoginXaml','Get-DomeniaBootStatusColor','Test-DomeniaMainHostAvailable',
    'Invoke-DomeniaDbQuery','ConvertTo-DomeniaSqlLiteral','Initialize-DomeniaDatabase','Backup-DomeniaDatabase','Get-DomeniaStoreBackupDirectory',
    'Normalize-LinkComputer','Normalize-LinkUser','ConvertTo-DomeniaCanonicalLinks','Load-UserMachineLinks',
    # CD-12: the error of a task is analysed once by the real ConvertTo-DomeniaErrorInfo.
    'ConvertTo-DomeniaErrorInfo','Test-DomeniaInternalFault','Test-DomeniaOperatorMessage')
$coreSource = New-Object 'System.Collections.Generic.List[string]'
foreach ($name in $script:CoreFunctions) { $coreSource.Add((Get-CoreFunctionAst $name).Extent.Text) }
. ([scriptblock]::Create(($coreSource.ToArray() -join "`n")))
# Worker helpers injected in every runspace: the three top-level here-strings of the core plus the receipts part.
$script:WorkerCommon = ''
foreach ($m in [regex]::Matches($script:CoreText,'(?ms)^\$script:WorkerCommon (?:=|\+=) @''\r?\n(.*?)\r?\n''@')) { $script:WorkerCommon += "`r`n" + $m.Groups[1].Value }
$script:WorkerCommon += "`r`n" + (Get-DomeniaReceiptsCommon)
$script:RealRegistry = Get-DomeniaWorkerOperationHashes

# ---------------------------------------------------------------- doubles (defined after the real code: they win)
$script:TestBody = @'
$calls=[AppDomain]::CurrentDomain.GetData('DomeniaWiringCalls')
if($null -ne $calls){$calls.Enqueue([string]$Context.OperationId+'|'+[string]$Payload.Name+'|'+[string]$Payload.Computer)}
if([string]$Payload.Gate){$g=[Threading.EventWaitHandle]::OpenExisting([string]$Payload.Gate);try{[void]$g.WaitOne(30000)}finally{$g.Dispose()}}
if([int]$Payload.SleepMs -gt 0){Start-Sleep -Milliseconds ([int]$Payload.SleepMs)}
if([string]$Payload.Fail){throw [string]$Payload.Fail}
[pscustomobject]@{Echo=[string]$Payload.Name;Operation=[string]$Context.OperationId;Rows=@()}
'@
function Get-DomeniaWorkerOperationHashes {
    $registry = [ordered]@{}
    foreach ($key in @($script:RealRegistry.Keys)) { $registry[$key] = $script:RealRegistry[$key] }
    foreach ($key in @($script:TestOverrides.Keys)) { $registry[$key] = Get-DomeniaWorkerCodeHash -Code ([string]$script:TestOverrides[$key]) }
    return $registry
}
function Initialize-AsyncEngine {
    # Double of the pinned initializer: same state, but its timer never ticks during a case (Complete-UiTasks is pumped).
    if ($script:AsyncEngineReady) { return }
    $script:AsyncEngineReady = $true; $script:AsyncEngineClosing = $false
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromHours(1)
    $script:AsyncTimer = $timer
    $timer.Start()
}
function Initialize-DomeniaWorkerContextCache {
    if ($null -ne $script:WorkerContextStatic) { return }
    $script:WorkerContextStatic = [pscustomobject]@{AdModuleSources=@();AdRequiredCommands=@();AdTypeNames=@();AdManagementHash='';AdResourceHash='';MissingCriticalFunctions=@();MissingCriticalControls=@();CriticalFunctionCount=0;CriticalControlCount=0;PowerShellVersion='5.1';IsSta=$true}
}
function Get-DomeniaRetryCredential { param([string]$OperationId) return $script:RetryCredential }
function Get-DomeniaAccessScope { param([string]$OperationId) return 'Directory' }
function Set-DomeniaRetryWorkerContext { param($Context,[string]$OperationId) return $Context }
function Set-DomeniaTargetCredentialContext { param($Context,$Payload) return $Context }
function Write-AppLog { param($Text,$Level) $script:Logs.Add([string]$Text) }
function Add-DomeniaUiLog { param($Area,$Text,$Level) $script:Logs.Add([string]$Text) }
function Set-Status { param($Text,$Level) $script:Statuses.Add([string]$Text) }
function Write-StartupTrace { param($Stage,$Status,$Detail,$DurationMs) }
function Write-DomeniaFastLoginLog { param($Stage,$Status,$Detail,$DurationMs) $script:LoginLog.Add(([string]$Stage + ' ' + [string]$Detail)) }
function Stop-DomeniaLiveJob { param($Job) }
function Stop-DomeniaComputerUserProbeUi { param($Job,$Reason) }
function Receive-DomeniaComputerUserProbeProgress { param($Job) }
function Test-DomeniaSelectionLoadCurrent { return $false }
function Update-DomeniaSelectionReadUi { param($Phase,$Message) }
function Clear-DomeniaCurrentObjectRequest { param($RequestId) }
function Clear-DomeniaComputerUserProbeState { param($ProbeId,$Computer) }
function Inspect-DomeniaAccessResult { param($Job,$Output) }
function Request-DomeniaAccessRecovery { param($Operation,$OperationId,$ErrorValue,$Interactive) return $false }
function Apply-CurrentPermissionUi { }
function Stop-DomeniaLive { param([switch]$Closing) }
function Stop-DomeniaSelectionOpenTimer { }
function Clear-DomeniaTreeRenderJobs { }
function Update-Dashboard { $script:DashboardCalls++ }
function Set-DomeniaItemsSource { param($Name,$Rows) $script:ItemsSources[[string]$Name] = @($Rows); return $true }
function Get-DomeniaIndexAssociationText { param($Row) return '' }
function Save-AppConfig { $script:SaveConfigCalls++ }
function Set-DomeniaSurfaceResult { param($Window,[bool]$Result) $script:SurfaceResults.Add($Result) }
function Get-DomeniaProcessWindowsIdentity { return '' }
function Test-DomeniaComputerAccountIdentity { param($Identity) return $false }
function Get-DomeniaParkCoverageText { return 'couverture' }
function Save-DomeniaParkState { $script:ParkSaves++; return $true }
function Add-UserMachineLinkIfMissing { param($UserLogin,$Computer,$Source,$Details,$Confidence) return $false }
function Register-DomeniaOperationSample { }
function Refresh-LinkGrid { }
function Set-SelectedBranch { param($Node) }
function Get-DomeniaStoredTheme { return 'Light' }
function Set-AppWindowIcon { param($Window) }
function Initialize-DomeniaDataStore { }
function Get-DomeniaDatabasePath { return [string]$script:DatabaseScopedPath }
function Confirm-WarningAction { param($Message,$Title) $script:Confirmations++; return $true }
function Update-DomeniaWriteModeVisual { }
function Complete-WiringTestUi { param($Result,$State) $script:Callbacks.Add([pscustomobject]@{Kind='Success';Tag=[string]$State.Tag;Result=$Result}) }
function Fail-WiringTestUi { param($Message,$State) $script:Callbacks.Add([pscustomobject]@{Kind='Error';Tag=[string]$State.Tag;Result=[string]$Message}) }

# ---------------------------------------------------------------- harness
function Invoke-WiringPump {
    param([int]$Milliseconds = 30)
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds([Math]::Max(1,$Milliseconds))
    $timer.Tag = $frame
    $timer.Add_Tick({ param($sender,$eventArgs) $sender.Stop(); $sender.Tag.Continue = $false })
    $timer.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}
function Wait-WiringCondition {
    param([scriptblock]$Condition,[int]$TimeoutMs = 10000,[switch]$Complete)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMs) {
        if ($Complete) { Complete-UiTasks }
        if (& $Condition) { return $true }
        Invoke-WiringPump 30
    }
    if ($Complete) { Complete-UiTasks }
    return [bool](& $Condition)
}
function New-WiringGate {
    $name = 'Local\Domenia-Wiring-' + [guid]::NewGuid().ToString('N')
    $handle = New-Object System.Threading.EventWaitHandle($false,[System.Threading.EventResetMode]::ManualReset,$name)
    $script:Gates.Add($handle)
    return [pscustomobject]@{Name=$name;Handle=$handle}
}
function Start-WiringTask {
    param([string]$OperationId = 'TreeChildren',[string]$Name = 'T',[string]$Gate = '',[int]$SleepMs = 0,[string]$Fail = '',[string]$Computer = '',[string]$TaskClass = '',
        [string]$Tag = '',[string[]]$DisableControls = @(),[switch]$IsWrite,[int]$TimeoutSeconds = 60,[string]$ReplaceKey = '')
    $script:TestOverrides[$OperationId] = $script:TestBody
    $payload = [pscustomobject]@{Name=$Name;Gate=$Gate;SleepMs=$SleepMs;Fail=$Fail;Computer=$Computer}
    return (Start-UiTask -Name $Name -OperationId $OperationId -Code $script:TestBody -Payload $payload -CallbackState ([pscustomobject]@{Tag=$Tag}) -SuccessHandler 'Complete-WiringTestUi' -ErrorHandler 'Fail-WiringTestUi' -TaskClass $TaskClass -DisableControls $DisableControls -IsWrite:$IsWrite -TimeoutSeconds $TimeoutSeconds -ReplaceKey $ReplaceKey)
}
function Get-WiringCalls { return @($script:Calls.ToArray()) }
function Stop-WiringJobs {
    foreach ($gate in @($script:Gates)) { try { [void]$gate.Set() } catch { } }
    [void](Wait-WiringCondition -Complete -TimeoutMs 8000 -Condition { (@($script:AsyncJobs.Keys).Count -eq 0) -and (@($script:DetachedReadJobs).Count -eq 0) })
    foreach ($gate in @($script:Gates)) { try { $gate.Dispose() } catch { } }
    $script:Gates.Clear()
    try { if ($null -ne $script:DomeniaIndexSearchTimer) { $script:DomeniaIndexSearchTimer.Stop() } } catch { }
    try { if ($null -ne $script:DashboardRefreshTimer) { $script:DashboardRefreshTimer.Stop() } } catch { }
}
function New-WiringMainWindow {
    $reader = [Xml.XmlNodeReader]::new([xml](Get-MainXaml))
    try { $window = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    $controls = @{}
    foreach ($match in [regex]::Matches((Get-MainXaml),'x:Name="([^"]+)"')) {
        $control = $window.FindName($match.Groups[1].Value)
        if ($null -ne $control) { $controls[$match.Groups[1].Value] = $control }
    }
    return [pscustomobject]@{Window=$window;Controls=$controls}
}
$script:Main = New-WiringMainWindow
$script:Gates = New-Object 'System.Collections.Generic.List[object]'
function Reset-WiringState {
    $script:CaseDetail = ''
    $script:AsyncJobs = [ordered]@{}; $script:DetachedReadJobs = New-Object System.Collections.ArrayList
    $script:AsyncSequence = 0; $script:ControlBusyRef = @{}; $script:LatestTaskId = ''; $script:SessionEpoch = [long]1
    $script:AsyncEngineClosing = $false; $script:AsyncEngineReady = $false; $script:AsyncTimer = $null; $script:LiveWorkerPools = @{}
    $script:DirectoryCredentialFaulted = $false; $script:DirectoryCredentialFaultMessage = ''; $script:AccessState = $null; $script:RetryCredential = $null
    $script:DomeniaProviderState = $null; $script:DomeniaResources = $null; $script:DomeniaTaskSequence = $null; $script:DomeniaSchedulerEnabled = $null; $script:DomeniaRegisteredAsyncTimer = $null
    $script:DomeniaIdlePolicy = $null; $script:DomeniaIdlePolicyEnabled = $null; $script:DomeniaIdlePolicyWired = $false; $script:DashboardDirty = $false; $script:DashboardRefreshTimer = $null
    $script:DomeniaIndexSearchTimer = $null; $script:DomeniaIndexSearchGeneration = 0; $script:DomeniaIndexSearchRetry = $null; $script:IndexScopeDn = ''
    $script:DomeniaParkSharedJob = $null; $script:DomeniaParkSharedPending = $false; $script:DomeniaParkDeferred = $null; $script:DomeniaParkStateReloadJob = $null
    $script:DomeniaActivationState = $null; $script:DomeniaActivationClosing = $false
    $script:DemoMode = $false; $script:DemoModeFixed = $false; $script:DemoDirectory = $null
    $script:Config = New-DefaultConfig
    $script:WorkerContextStatic = $null; $script:ProcessIdentity = 'EXAMPLE\poste-test'; $script:ProcessIdentityDisplay = 'poste-test'
    $script:Conn = [pscustomobject]@{Connected=$true;AuthMode='Explicit';UseCredential=$false;Credential=$null;User='EXAMPLE\lecteur';BindUser='EXAMPLE\lecteur';Domain='example.invalid';Netbios='EXAMPLE';BaseDn='DC=example,DC=invalid';Server='dc1.example.invalid';RootPath='';LastError=''}
    $script:MachineCredential = $null; $script:RemoteAdminCredential = $null; $script:SecretsCredential = $null
    $script:Statuses = New-Object 'System.Collections.Generic.List[string]'; $script:Logs = New-Object 'System.Collections.Generic.List[string]'
    $script:LoginLog = New-Object 'System.Collections.Generic.List[string]'; $script:Callbacks = New-Object 'System.Collections.Generic.List[object]'
    $script:SurfaceResults = New-Object 'System.Collections.Generic.List[object]'; $script:ItemsSources = @{}
    $script:TestOverrides = @{}; $script:DashboardCalls = 0; $script:SaveConfigCalls = 0; $script:ParkSaves = 0; $script:Confirmations = 0
    $script:ParkState = @{}; $script:IndexRows = @(); $script:TreeRenderJobs = @{}; $script:TreeRenderTimer = $null
    $script:ReadOnlyMode = $true; $script:ReceiptReady = $true; $script:ReceiptPending = 0; $script:ActiveWriteTaskId = ''; $script:WriteState = 'Idle'
    $script:Calls = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    [AppDomain]::CurrentDomain.SetData('DomeniaWiringCalls',$script:Calls)
    $script:Window = $script:Main.Window
    $script:Ctrl = $script:Main.Controls
    $script:LastTaskUiCount = -1; $script:LastTaskUiSignature = ''; $script:LastTaskUiRefresh = [datetime]::MinValue
    # PF-06: every heartbeat subscriber of a previous case is stopped; the window is not suspended.
    if ($null -ne $script:DomeniaPulse) { foreach ($timer in @($script:DomeniaPulse.Active.Values)) { try { $timer.Stop() } catch { } } }
    $script:DomeniaWindowSuspended = $false; $script:AsyncEngineFaultStopped = $false
    $script:WorkerContextConfig = $null; $script:DomeniaFeatureFlagCache = $null; $script:DomeniaRuntimeMetrics = $null
}

# ---------------------------------------------------------------- D011
Test-Case 'D011 : aucune fonction de module appelee au niveau script du coeur' {
    $moduleFunctions = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $modules -Filter '*.ps1' -File)) {
        $ft = $null; $fe = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$ft,[ref]$fe)
        foreach ($fn in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] },$false))) { $moduleFunctions[$fn.Name.ToLowerInvariant()] = $file.Name }
    }
    $offending = New-Object 'System.Collections.Generic.List[string]'
    foreach ($statement in @($script:CoreAst.EndBlock.Statements)) {
        if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) { continue }
        # The authoritative main block starts with the closed loader; everything after the loader is phase Interface.
        if ($statement.Extent.Text -match "Join-Path \`$PSScriptRoot 'Domenia-Modules\.ps1'") { break }
        foreach ($command in @($statement.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] },$true))) {
            $name = [string]$command.GetCommandName()
            if ($name -and $moduleFunctions.ContainsKey($name.ToLowerInvariant())) { $offending.Add($name + ' (' + $moduleFunctions[$name.ToLowerInvariant()] + ', ligne ' + $command.Extent.StartLineNumber + ')') }
        }
        Assert-True ($statement.Extent.Text -notmatch 'DomeniaProviderState|DomeniaResources\s*=|DomeniaIdlePolicy\s*=') ('Etat moteur cree au niveau script : ligne ' + $statement.Extent.StartLineNumber)
    }
    Assert-True ($offending.Count -eq 0) ('Appel avant le chargeur : ' + ($offending.ToArray() -join ', '))
}
Test-Case 'D011 : etat du moteur cree paresseusement au premier Start-UiTask' {
    Assert-True ($null -eq $script:DomeniaProviderState -and $null -eq $script:DomeniaResources) 'Etat present avant toute tache'
    [void](Start-WiringTask -Name 'lazy')
    Assert-True ($null -ne $script:DomeniaProviderState -and $null -ne $script:DomeniaResources) 'Start-UiTask n a pas initialise l etat du moteur'
    Assert-True (@($script:DomeniaResources.Items | Where-Object { $_.Owner -eq 'Timer:Async' }).Count -eq 1) 'Minuteur du moteur non enregistre'
}
Test-Case 'D011 : le self-test exige le plan, les regles du moteur et la demonstration' {
    $selfTest = (Get-CoreFunctionAst 'Invoke-DomeniaSelfTest').Extent.Text
    foreach ($needle in @("'Test-DomeniaStartupPlan'","'Test-DomeniaTaskAdmission'","'Get-DomeniaTaskStateSummary'","'Plan de demarrage'","'Annuaire de demonstration MTA'","'Authentification demonstration'","'Registre demonstration'")) {
        Assert-True ($selfTest.Contains($needle)) ('Self-test sans ' + $needle)
    }
}
Test-Case 'D011 : plan reel du chargeur valide par la regle de demarrage' {
    $lt = $null; $le = $null
    $loader = [Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Modules.ps1'),[ref]$lt,[ref]$le)
    $planFn = @($loader.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-DomeniaRuntimeModulePlan' },$true))[0]
    $plan = & ([scriptblock]::Create($planFn.Body.Extent.Text.Trim().TrimStart('{').TrimEnd('}')))
    $result = Test-DomeniaStartupPlan -Modules @($plan)
    Assert-True ([bool]$result.Valid) ('Plan invalide : ' + (@($result.Errors) -join ' | '))
    Assert-True ([Array]::IndexOf(@($result.Order),'Domenia-Common.Model.ps1') -lt [Array]::IndexOf(@($result.Order),'Domenia-Engine.Model.ps1')) 'Ordre Common > Engine non respecte'
}

# ---------------------------------------------------------------- D015
Test-Case 'D015 : saturation => demande en file, aucune exception ni second appel' {
    $script:Config.Async.MaxThreads = 1
    $gate = New-WiringGate
    $a = Start-WiringTask -Name 'A' -Gate $gate.Name
    Assert-True (Wait-WiringCondition { (Get-WiringCalls).Count -eq 1 }) 'A n a pas demarre'
    $b = Start-WiringTask -Name 'B'
    Assert-True ($script:AsyncJobs.Contains($b) -and [string]$script:AsyncJobs[$b].State -eq 'Queued') 'B n est pas en file'
    Invoke-WiringPump 200
    Assert-True ((Get-WiringCalls).Count -eq 1) 'B a ete envoye malgre la saturation'
    [void]$gate.Handle.Set()
    Assert-True (Wait-WiringCondition -Complete { (@(Get-WiringCalls) -match '\|B\|').Count -eq 1 }) 'B n a pas ete promu a la liberation'
}
Test-Case 'D015 : a la liberation, l action explicite part avant le travail de fond' {
    $script:Config.Async.MaxThreads = 1
    $gate = New-WiringGate
    [void](Start-WiringTask -Name 'A' -Gate $gate.Name)
    Assert-True (Wait-WiringCondition { (Get-WiringCalls).Count -eq 1 }) 'A n a pas demarre'
    $gateC = New-WiringGate; $gateD = New-WiringGate
    $c = Start-WiringTask -Name 'C' -TaskClass 'Background' -Gate $gateC.Name
    $d = Start-WiringTask -Name 'D' -TaskClass 'Explicit' -Gate $gateD.Name
    Assert-True ([string]$script:AsyncJobs[$c].State -eq 'Queued' -and [string]$script:AsyncJobs[$d].State -eq 'Queued') 'C et D doivent attendre'
    [void]$gate.Handle.Set()
    Assert-True (Wait-WiringCondition -Complete { $script:AsyncJobs.Contains($d) -and [string]$script:AsyncJobs[$d].State -eq 'Running' }) 'D n a pas demarre'
    Assert-True ([string]$script:AsyncJobs[$c].State -eq 'Queued') 'Le travail de fond est passe avant l action explicite'
}
Test-Case 'D015 : une ecriture saturee est refusee, jamais mise en file' {
    # FI-03: a write has its own physical place above the read cap; saturation means that place is taken as well
    # (here by two detached reads beside the running one): the write is refused, never queued.
    $script:Config.Async.MaxThreads = 1; $script:Config.Async.MaxOutstandingWorkers = 1
    $gate = New-WiringGate
    [void](Start-WiringTask -Name 'A' -Gate $gate.Name)
    foreach ($i in 1..2) { [void]$script:DetachedReadJobs.Add([pscustomobject]@{Id=('detache' + $i);Name='Detache';OperationId='TreeChildren';Handle=[pscustomobject]@{IsCompleted=$false};StopHandle=$null;PowerShell=$null;Runspace=$null;IsWrite=$false;Started=(Get-Date)}) }
    try {
        $refused = $false
        try { [void](Start-WiringTask -OperationId 'WriteAttributes' -Name 'W' -IsWrite) } catch { $refused = $true }
        Assert-True $refused 'Ecriture acceptee en saturation'
        Assert-True (@($script:AsyncJobs.Values | Where-Object { [bool]$_.IsWrite }).Count -eq 0) 'Ecriture placee en file'
    } finally { $script:DetachedReadJobs.Clear() }
}
Test-Case 'D015 : deux lectures identiques partagent un seul appel et deux rappels' {
    $gate = New-WiringGate
    $script:TestOverrides['OpenAdObject'] = $script:TestBody
    $payload = [pscustomobject]@{Name='Objet';Gate=$gate.Name;SleepMs=0;Fail='';Computer=''}
    $first = Start-UiTask -Name 'Lecture 1' -OperationId 'OpenAdObject' -Code $script:TestBody -Payload $payload -CallbackState ([pscustomobject]@{Tag='un'}) -ReplaceKey 'object' -SuccessHandler 'Complete-WiringTestUi' -ErrorHandler 'Fail-WiringTestUi'
    $payload2 = [pscustomobject]@{Name='Objet';Gate=$gate.Name;SleepMs=0;Fail='';Computer=''}
    $second = Start-UiTask -Name 'Lecture 2' -OperationId 'OpenAdObject' -Code $script:TestBody -Payload $payload2 -CallbackState ([pscustomobject]@{Tag='deux'}) -ReplaceKey 'object' -SuccessHandler 'Complete-WiringTestUi' -ErrorHandler 'Fail-WiringTestUi'
    Assert-True ($first -ceq $second) 'Deuxieme lecture AD creee'
    [void]$gate.Handle.Set()
    Assert-True (Wait-WiringCondition -Complete { $script:Callbacks.Count -eq 2 }) 'Les deux abonnes n ont pas recu leur rappel'
    Assert-True ((Get-WiringCalls).Count -eq 1) 'Plus d un appel au worker'
    Assert-True ((@($script:Callbacks | ForEach-Object { $_.Tag }) -join ',') -match 'un' -and (@($script:Callbacks | ForEach-Object { $_.Tag }) -join ',') -match 'deux') 'Etat de rappel perdu'
}

# ---------------------------------------------------------------- D017
Test-Case 'D017 : un arret demande est annonce comme encore actif' {
    $gate = New-WiringGate
    $a = Start-WiringTask -Name 'Lecture lente' -Gate $gate.Name
    Assert-True (Wait-WiringCondition { (Get-WiringCalls).Count -eq 1 }) 'A n a pas demarre'
    Request-UiTaskStop -Id $a -Reason 'Annulation utilisateur'
    $text = $script:Statuses[$script:Statuses.Count - 1]
    Assert-True ($text -match 'Arret demande' -and $text -match 'encore active') ('Texte d arret inexact : ' + $text)
    Assert-True ($text -notmatch '(?i)annul[ee]e\b') 'Arret presente comme termine'
}
Test-Case 'D017 : lecture detachee comptee et barre visible pendant le nettoyage' {
    $script:Config.Async.CancelGraceSeconds = 1
    $gate = New-WiringGate
    $a = Start-WiringTask -Name 'Appel natif' -Gate $gate.Name
    Assert-True (Wait-WiringCondition { (Get-WiringCalls).Count -eq 1 }) 'A n a pas demarre'
    Request-UiTaskStop -Id $a -Reason 'Annulation utilisateur'
    Assert-True (Wait-WiringCondition -Complete -TimeoutMs 6000 { @($script:DetachedReadJobs).Count -eq 1 }) 'Lecture non detachee'
    Update-TaskUi -Force
    Assert-True ($script:Ctrl.PbTop.Visibility -eq 'Visible') 'Barre masquee alors que l appel natif tourne'
    Assert-True ([string]$script:Ctrl.LblTaskElapsed.Text -match 'nettoyage') ('Etat de nettoyage absent : ' + $script:Ctrl.LblTaskElapsed.Text)
    Assert-True ((@($script:Statuses) -join ' ') -match 'reste compte') 'Le detachement n est pas annonce'
    [void]$gate.Handle.Set()
    Assert-True (Wait-WiringCondition -Complete { @($script:DetachedReadJobs).Count -eq 0 }) 'Nettoyage non constate'
    Update-TaskUi
    Assert-True ($script:Ctrl.PbTop.Visibility -ne 'Visible') 'Barre visible apres la fin reelle'
}
Test-Case 'D017 : une entree en file est affichee en attente puis retiree sans appel' {
    $script:Config.Async.MaxThreads = 1
    $gate = New-WiringGate
    [void](Start-WiringTask -Name 'A' -Gate $gate.Name)
    Assert-True (Wait-WiringCondition { (Get-WiringCalls).Count -eq 1 }) 'A n a pas demarre'
    $b = Start-WiringTask -Name 'B'
    Update-TaskUi -Force
    Assert-True ([string]$script:Ctrl.LblTaskElapsed.Text -match 'en attente') ('File non affichee : ' + $script:Ctrl.LblTaskElapsed.Text)
    Request-UiTaskStop -Id $b -Reason 'Annulation utilisateur'
    Assert-True (-not $script:AsyncJobs.Contains($b)) 'Entree en file non retiree'
    Assert-True ((@($script:Statuses) -join ' ') -match 'retiree de la file') 'Retrait non annonce'
    [void]$gate.Handle.Set()
    [void](Wait-WiringCondition -Complete { $script:AsyncJobs.Count -eq 0 })
    Assert-True ((@(Get-WiringCalls) -match '\|B\|').Count -eq 0) 'Une entree retiree a ete envoyee'
}
Test-Case 'D017 : un echec de preparation ne reactive pas un controle tenu par une autre tache' {
    Set-ControlsBusy -Names @('BtnGlobalSearch') -Busy $true
    $script:DirectoryCredentialFaulted = $true; $script:DirectoryCredentialFaultMessage = 'test'
    $failed = $false
    try { [void](Start-WiringTask -OperationId 'TreeChildren' -Name 'Refusee' -DisableControls @('BtnGlobalSearch')) } catch { $failed = $true }
    Assert-True $failed 'La preparation devait echouer (canal AD suspendu)'
    Assert-True ([int]$script:ControlBusyRef['BtnGlobalSearch'] -eq 1 -and -not $script:Ctrl.BtnGlobalSearch.IsEnabled) 'Controle reactive trop tot'
}

# ---------------------------------------------------------------- D018
Test-Case 'D018 : refus d identifiants poste => aucun nouvel essai sur la cible, autre cible et canal AD intacts' {
    $fail = '[DOMENIA:LogonFailure;1326;0x8007052E] Le nom d utilisateur ou le mot de passe est incorrect.'
    [void](Start-WiringTask -OperationId 'ComputerInventory' -Name 'Inventaire' -Computer 'PC1' -Fail $fail)
    Assert-True (Wait-WiringCondition -Complete { $script:Callbacks.Count -eq 1 }) 'Erreur non remontee'
    $before = (Get-WiringCalls).Count
    $blocked = ''
    try { [void](Start-WiringTask -OperationId 'ComputerInventory' -Name 'Inventaire 2' -Computer 'PC1') } catch { $blocked = $_.Exception.Message }
    Assert-True ($blocked -match 'Identifiants rejetes') ('Nouvel essai autorise sur PC1 : ' + $blocked)
    Invoke-WiringPump 200
    Assert-True ((Get-WiringCalls).Count -eq $before) 'Un second appel est parti'
    [void](Start-WiringTask -OperationId 'ComputerInventory' -Name 'Inventaire PC2' -Computer 'PC2')
    Assert-True (Wait-WiringCondition -Complete { (@(Get-WiringCalls) -match 'PC2').Count -eq 1 }) 'PC2 bloque a tort'
    Assert-True (-not [bool]$script:DirectoryCredentialFaulted) 'Canal AD suspendu par un refus poste'
}
Test-Case 'D018 : un refus WTS (SessionsList) ne suspend pas le canal AD' {
    $fail = '[DOMENIA:LogonFailure;1326;0x8007052E] Le nom d utilisateur ou le mot de passe est incorrect.'
    [void](Start-WiringTask -OperationId 'SessionsList' -Name 'Sessions' -Computer 'PC1' -Fail $fail)
    Assert-True (Wait-WiringCondition -Complete { $script:Callbacks.Count -eq 1 }) 'Erreur non remontee'
    Assert-True (-not [bool]$script:DirectoryCredentialFaulted) 'Le refus WTS a suspendu toutes les lectures AD'
}
Test-Case 'D018 : pannes repetees => fond suspendu, action explicite autorisee' {
    foreach ($i in 1..3) {
        [void](Start-WiringTask -OperationId 'LiveDirectoryCheck' -Name ('Fond ' + $i) -Fail 'panne de lecture')
        Assert-True (Wait-WiringCondition -Complete { $script:Callbacks.Count -eq $i }) ('Echec ' + $i + ' non remonte')
    }
    $refused = ''
    try { [void](Start-WiringTask -OperationId 'LiveDirectoryCheck' -Name 'Fond 4') } catch { $refused = $_.Exception.Message }
    Assert-True ($refused -match 'Pannes repetees') ('Fond non suspendu : ' + $refused)
    [void](Start-WiringTask -OperationId 'TreeChildren' -Name 'Explicite')
    Assert-True (Wait-WiringCondition -Complete { (@(Get-WiringCalls) -match 'Explicite').Count -eq 1 }) 'Action explicite bloquee'
}

# ---------------------------------------------------------------- D019
Test-Case 'D019 : 50 cycles demarrage, annulation et fin : registre revenu a son niveau' {
    [void](Start-WiringTask -Name 'amorce')
    Assert-True (Wait-WiringCondition -Complete { $script:AsyncJobs.Count -eq 0 }) 'Amorce non terminee'
    $initial = (Get-DomeniaResourceSummary $script:DomeniaResources).Total
    $handles = [Diagnostics.Process]::GetCurrentProcess().HandleCount
    $peak = 0
    foreach ($i in 1..50) {
        $id = Start-WiringTask -Name ('cycle ' + $i) -SleepMs 400
        $peak = [Math]::Max($peak,(Get-DomeniaResourceSummary $script:DomeniaResources).Total)
        if (($i % 2) -eq 0) { Request-UiTaskStop -Id $id -Reason 'Annulation utilisateur' }
        Assert-True (Wait-WiringCondition -Complete -TimeoutMs 8000 { $script:AsyncJobs.Count -eq 0 -and @($script:DetachedReadJobs).Count -eq 0 }) ('Cycle ' + $i + ' non termine')
    }
    $final = (Get-DomeniaResourceSummary $script:DomeniaResources).Total
    Assert-True ($peak -gt $initial) 'Les ressources des taches ne sont pas enregistrees'
    Assert-True ($final -eq $initial) ('Registre non stable : ' + $initial + ' -> ' + $final)
    $script:CaseDetail = 'Ressources ' + $initial + ' -> ' + $final + ' (pic ' + $peak + ') ; handles du processus ' + $handles + ' -> ' + [Diagnostics.Process]::GetCurrentProcess().HandleCount + ' (mesure, sans seuil).'
}
Test-Case 'D019 : la fermeture arrete tous les minuteurs enregistres' {
    Initialize-AsyncEngine; Initialize-DomeniaEngineState
    $extra = New-Object System.Windows.Threading.DispatcherTimer
    $extra.Interval = [TimeSpan]::FromHours(1); $extra.Start()
    [void](Register-DomeniaOwnedTimer -Owner 'Timer:Test' -Timer $extra)
    $script:DomeniaIdlePolicy = $null
    Request-DomeniaDashboardRefresh
    $dashboard = $script:DashboardRefreshTimer
    Dispose-AsyncEngine
    Assert-True (-not $extra.IsEnabled) 'Minuteur enregistre encore actif'
    Assert-True ($null -eq $dashboard -or -not $dashboard.IsEnabled) 'Minuteur du tableau de bord encore actif'
    Assert-True (@($script:DomeniaResources.Items | Where-Object { $_.Kind -eq 'Timer' }).Count -eq 0) 'Le registre detient encore des minuteurs'
}

# ---------------------------------------------------------------- D020
Test-Case 'D020 : sans politique initialisee, repli ouvert (C1)' {
    foreach ($source in @('Live','Reconcile','ObjectChanges','Dashboard','Index','Park')) { Assert-True (Test-DomeniaBackgroundWorkAllowed -Source $source) ('Repli ferme pour ' + $source) }
}
Test-Case 'D020 : fenetre desactivee ou reduite => aucun travail de fond' {
    Assert-True ((Get-CoreFunctionAst 'Initialize-Window').Extent.Text -match 'Initialize-DomeniaIdlePolicy -Window \$script:Window') 'Initialize-Window ne branche pas la politique de repos'
    $window = $script:Main.Window
    $script:DomeniaIdlePolicyWired = $false
    Initialize-DomeniaIdlePolicy -Window $window
    $flags = [Reflection.BindingFlags]'NonPublic,Instance'
    $script:DomeniaIdlePolicy = $null
    [Windows.Window].GetMethod('OnDeactivated',$flags).Invoke($window,@([EventArgs]::Empty))
    Assert-True ($null -ne $script:DomeniaIdlePolicy) 'Gestionnaire Deactivated non branche'
    Assert-True (-not [bool]$script:DomeniaIdlePolicy.AllowBackgroundRefresh) 'Rafraichissement de fond autorise fenetre inactive'
    foreach ($source in @('Live','Reconcile','ObjectChanges','Index','Park')) { Assert-True (-not (Test-DomeniaBackgroundWorkAllowed -Source $source)) ('Travail de fond autorise : ' + $source) }
    $script:DomeniaIdlePolicy = $null
    [Windows.Window].GetMethod('OnActivated',$flags).Invoke($window,@([EventArgs]::Empty))
    Assert-True ($null -ne $script:DomeniaIdlePolicy) 'Gestionnaire Activated non branche'
    $script:DomeniaIdlePolicy = $null
    $window.WindowState = 'Minimized'
    [Windows.Window].GetMethod('OnStateChanged',$flags).Invoke($window,@([EventArgs]::Empty))
    Assert-True ($null -ne $script:DomeniaIdlePolicy -and -not [bool]$script:DomeniaIdlePolicy.Visible) 'Gestionnaire StateChanged non branche ou fenetre reduite consideree visible'
    $window.WindowState = 'Normal'
    Assert-True ([bool](Test-DomeniaIdleAllows -Policy $script:DomeniaIdlePolicy -Activity 'Storage') -and [bool](Test-DomeniaIdleAllows -Policy $script:DomeniaIdlePolicy -Activity 'Receipts')) 'Sauvegardes ou recus suspendus'
}
Test-Case 'D020 : accueil cache non reconstruit, reconstruit une fois quand il redevient visible' {
    $script:DomeniaIdlePolicy = Get-DomeniaIdlePolicy -WindowActive $true -VisiblePage 'WsSearch'
    foreach ($i in 1..20) { Update-TaskUi -Force; Invoke-WiringPump 5 }
    Invoke-WiringPump 300
    Assert-True ($script:DashboardCalls -eq 0) ('Accueil cache reconstruit ' + $script:DashboardCalls + ' fois')
    Assert-True ([bool]$script:DashboardDirty) 'Accueil non marque a reconstruire'
    $script:DomeniaIdlePolicy = Get-DomeniaIdlePolicy -WindowActive $true -VisiblePage 'TabDashboard'
    Request-DomeniaDashboardRefresh
    Invoke-WiringPump 400
    Assert-True ($script:DashboardCalls -eq 1) ('Reconstruction attendue une fois, obtenue ' + $script:DashboardCalls)
}

# ---------------------------------------------------------------- D014
function New-WiringIndexDatabase {
    [void](Initialize-DomeniaWinSqliteNative)
    $path = Join-Path ([IO.Path]::GetTempPath()) ('domenia-wiring-' + [guid]::NewGuid().ToString('N') + '.db')
    $db = Open-DomeniaDatabase -Path $path
    try {
        [void](Invoke-DomeniaDbExec 'CREATE TABLE ad_objects(object_key TEXT PRIMARY KEY,object_guid TEXT,object_type TEXT,name TEXT,login TEXT,upn TEXT,display_name TEXT,description TEXT,extra TEXT,state TEXT,distinguished_name TEXT,when_changed TEXT,usn_changed INTEGER,last_logon TEXT,search_key TEXT,source_dc TEXT,synced_at TEXT);' $db)
        [void](Invoke-DomeniaDbExec "INSERT INTO ad_objects VALUES('k1','11111111-1111-1111-1111-111111111111','Utilisateur','Jean Dupont','jdupont','jdupont@example.invalid','Jean Dupont','','','Actif','CN=Jean Dupont,DC=example,DC=invalid','',1,'','jean dupont jdupont','','');" $db)
        [void](Invoke-DomeniaDbExec 'CREATE TABLE park_state(computer_key TEXT PRIMARY KEY,computer TEXT,last_probe TEXT,status TEXT,user_login TEXT,attempts INTEGER);' $db)
    } finally { Close-DomeniaDatabase $db }
    return $path
}
function Get-WiringIndexHandler {
    $wire = (Get-CoreFunctionAst 'Wire-Events').Extent.Text
    $match = [regex]::Match($wire,'\$script:Ctrl\["TxtIndexSearch"\]\.Add_TextChanged\((\{.*?\})\)')
    if (-not $match.Success) { throw 'Gestionnaire TxtIndexSearch introuvable dans Wire-Events' }
    return [scriptblock]::Create($match.Groups[1].Value.Trim().TrimStart('{').TrimEnd('}'))
}
Test-Case 'D014 : frappe dans l index local sans SQLite sur le Dispatcher, base verrouillee comprise' {
    $script:DatabaseScopedPath = New-WiringIndexDatabase
    $box = New-Object System.Windows.Controls.TextBox
    $script:Ctrl['TxtIndexSearch'] = $box
    $label = New-Object System.Windows.Controls.TextBlock
    $script:Ctrl['LblIndexStatus'] = $label
    $handler = Get-WiringIndexHandler
    $box.Add_TextChanged($handler)
    $sequence = [int]$script:AsyncSequence
    # TE-03: a structural proof replaces the former 50 ms threshold: the keystroke only re-arms the debounce timer;
    # no worker starts and no SQLite connection opens on the Dispatcher. The durations are reported (median of 5).
    $opens = @{N=0}
    $realOpen = ${function:Open-DomeniaDatabase}
    Set-Item function:script:Open-DomeniaDatabase -Value { $opens.N++; & $realOpen @args }.GetNewClosure()
    $durations = New-Object 'System.Collections.Generic.List[double]'
    try {
        foreach ($text in @('j','jd','jdu','jdup','jdupo')) { $watch = [Diagnostics.Stopwatch]::StartNew(); $box.Text = $text; $watch.Stop(); $durations.Add($watch.Elapsed.TotalMilliseconds) }
        Assert-True ([int]$script:AsyncSequence -eq $sequence) ('Une lecture est partie pendant la frappe : ' + ([int]$script:AsyncSequence - $sequence))
        Assert-True ($opens.N -eq 0) ('Connexion SQLite ouverte sur le Dispatcher pendant la frappe : ' + $opens.N)
        Assert-True ([bool]$script:DomeniaIndexSearchTimer.IsEnabled) 'Anti-rebond non arme'
    } finally { Set-Item function:script:Open-DomeniaDatabase -Value $realOpen }
    $sorted = $durations.ToArray(); [Array]::Sort($sorted)
    $script:CaseDetail = 'Frappe : mediane de 5 essais ' + [Math]::Round($sorted[2],1) + ' ms (mesure, sans seuil).'
    Assert-True (Wait-WiringCondition -Complete { $script:ItemsSources.ContainsKey('DgIndex') }) ('Aucun resultat : ' + $label.Text)
    Assert-True ([int]$script:AsyncSequence -eq $sequence + 1) ('Une seule lecture attendue apres anti-rebond, obtenue ' + ([int]$script:AsyncSequence - $sequence))
    Assert-True (@($script:ItemsSources['DgIndex']).Count -eq 1 -and [string]@($script:ItemsSources['DgIndex'])[0].Login -eq 'jdupont') 'Ligne de l index absente'
    # A second connection holds an exclusive lock: the keyboard stays free, the answer says busy, never empty.
    $lock = Open-DomeniaDatabase -Path $script:DatabaseScopedPath
    try {
        [void](Invoke-DomeniaDbExec 'BEGIN EXCLUSIVE;' $lock)
        $script:ItemsSources = @{}
        # TE-03: with the base locked, the keystroke still starts nothing on the Dispatcher (structural proof).
        $before = [int]$script:AsyncSequence
        $watch = [Diagnostics.Stopwatch]::StartNew(); $box.Text = 'jean'; $watch.Stop()
        Assert-True ([int]$script:AsyncSequence -eq $before -and [bool]$script:DomeniaIndexSearchTimer.IsEnabled) 'La frappe a lance une lecture sur le Dispatcher malgre le verrou'
        $script:CaseDetail += ' Frappe pendant le verrou : ' + [Math]::Round($watch.Elapsed.TotalMilliseconds,1) + ' ms (mesure).'
        Assert-True (Wait-WiringCondition -Complete -TimeoutMs 15000 { [string]$label.Text -match 'occupee : recherche non effectuee' }) ('Etat occupe non affiche : ' + $label.Text)
        Assert-True (-not $script:ItemsSources.ContainsKey('DgIndex')) 'Base verrouillee presentee comme resultat vide'
    } finally { try { [void](Invoke-DomeniaDbExec 'ROLLBACK;' $lock) } catch { }; Close-DomeniaDatabase $lock }
}
Test-Case 'D014 : synchronisation du releve partage hors Dispatcher (fichier verrouille)' {
    $folder = Join-Path ([IO.Path]::GetTempPath()) ('domenia-park-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($folder)
    $shared = Join-Path $folder 'releve.tsv'
    [IO.File]::WriteAllText($shared,("PC-B`t2026-09-01T10:00:00`tSession`tbob`t1`tautre" + [Environment]::NewLine))
    [IO.File]::WriteAllText($shared + '.lock','verrou')
    if (-not $script:Config.Contains('ParkSweep')) { $script:Config['ParkSweep'] = [ordered]@{} }
    $script:Config.ParkSweep['SharedPath'] = $shared
    $script:Ctrl['LblParkStatus'] = New-Object System.Windows.Controls.TextBlock
    $script:ParkState = @{}
    $result = [pscustomobject]@{Results=@([pscustomobject]@{Computer='PC-A';Status='Session';User='alice';Detail=''});Requested=1;Reachable=1;Probed=1;Found=1;DurationMs=5}
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Complete-DomeniaParkSweepUi -Result $result -State ([pscustomobject]@{Silent=$true})
    $watch.Stop()
    # TE-03: the historical path waited up to 12 x 250 ms for the lock on the Dispatcher. Structural proof instead of a
    # threshold: the callback returned while the worker still held the shared file wait (its job is not finished).
    Assert-True ($null -ne $script:DomeniaParkSharedJob) 'Synchronisation non confiee au worker'
    $sharedJob = $script:AsyncJobs[[string]$script:DomeniaParkSharedJob]
    Assert-True ($null -ne $sharedJob -and -not [bool]$sharedJob.Handle.IsCompleted) 'Le rappel a attendu la fin de la synchronisation sur le Dispatcher'
    $script:CaseDetail = 'Rappel du releve : ' + [Math]::Round($watch.Elapsed.TotalMilliseconds) + ' ms (mesure, sans seuil).'
    Assert-True (Wait-WiringCondition -Complete -TimeoutMs 15000 { $null -eq $script:DomeniaParkSharedJob }) 'Synchronisation non terminee'
    Assert-True ($script:ParkState.ContainsKey('PC-B') -and $script:ParkState.ContainsKey('PC-A')) 'Releve distant non fusionne'
    Assert-True ((@($script:Logs) -join ' ') -match 'verrouille') 'Verrou de l autre console non signale'
    Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
}
Test-Case 'D014 : audit statique des attentes atteignables depuis le Dispatcher' {
    $tool = Join-Path $dev 'tools\Test-DomeniaUiBlocking.ps1'
    $report = Join-Path ([IO.Path]::GetTempPath()) ('domenia-uib-' + [guid]::NewGuid().ToString('N') + '.json')
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool -Root $dev -ReportPath $report -Quiet
    $auditExit=$LASTEXITCODE;$script:UiBlockingAudit=Get-Content -LiteralPath $report -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($auditExit -eq 0) ('Attente nouvelle atteignable depuis le Dispatcher : ' + (@($script:UiBlockingAudit.New|ForEach-Object{$_.Function+' '+$_.Pattern+' : '+$_.Chain}) -join ' | '))
    # Mutation: a sleep injected in Search-DomeniaIndexUi of a copy of the core must be found.
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('domenia-core-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $mutated = $script:CoreText.Replace("function Search-DomeniaIndexUi {`n    try {","function Search-DomeniaIndexUi {`n    try { Start-Sleep -Milliseconds 1")
    Assert-True ($mutated -ne $script:CoreText) 'Mutation non appliquee'
    [IO.File]::WriteAllText($fixture,$mutated,(New-Object Text.UTF8Encoding($true)))
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool -Root $dev -CorePath $fixture -ReportPath $report -Quiet
    $code = $LASTEXITCODE
    $parsed = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    Remove-Item -LiteralPath $fixture,$report -Force -ErrorAction SilentlyContinue
    Assert-True ($code -eq 1) 'La mutation n a pas fait echouer l audit'
    Assert-True (@($parsed.New | ForEach-Object { $_ } | Where-Object { $_.Function -eq 'Search-DomeniaIndexUi' -and $_.Pattern -eq 'Start-Sleep' }).Count -eq 1) 'Chaine de la mutation non rapportee'
}

# ---------------------------------------------------------------- D016
Test-Case 'D016 : desactive par defaut, la lecture reste dans le moteur' {
    [void](Start-WiringTask -OperationId 'ComputerPing' -Name 'Ping' -Computer 'PC1' -Gate (New-WiringGate).Name)
    $job = @($script:AsyncJobs.Values)[0]
    Assert-True ([string]$job.ExecutedOperationId -eq 'ComputerPing' -and -not [bool]$job.Isolated) 'Isolement actif sans Features.IsolatedReads'
}
Test-Case 'D016 : processus auxiliaire arrete sans toucher l interface, sans donnee en argument' {
    $script:Config.Features.IsolatedReads = $true
    # PF-10: the flags are kept per configuration object; a configuration changed in place starts a new generation.
    $script:DomeniaFeatureFlagCache = $null
    $marker = 'MARQUEUR-' + [guid]::NewGuid().ToString('N')
    $id = Start-WiringTask -OperationId 'TreeChildren' -Name $marker -SleepMs 30000
    $job = $script:AsyncJobs[$id]
    Assert-True ([string]$job.ExecutedOperationId -eq 'IsolatedRead' -and [bool]$job.Isolated) 'Lecture non confiee a l auxiliaire'
    $child = $null
    [void](Wait-WiringCondition -TimeoutMs 15000 {
        $script:IsolationChild = @(Get-CimInstance -ClassName Win32_Process -Filter ("ParentProcessId=" + $PID) | Where-Object { $_.Name -eq 'powershell.exe' } | Select-Object -First 1)
        $script:IsolationChild.Count -eq 1
    })
    Assert-True (@($script:IsolationChild).Count -eq 1) 'Processus auxiliaire introuvable'
    $child = $script:IsolationChild[0]
    Assert-True ([string]$child.CommandLine -notmatch [regex]::Escape($marker)) 'La requete est passee en argument de processus'
    Request-UiTaskStop -Id $id -Reason 'Annulation utilisateur'
    Assert-True (Wait-WiringCondition -Complete -TimeoutMs 15000 { $null -eq (Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue) }) 'Auxiliaire non arrete'
    Assert-True (Wait-WiringCondition -Complete -TimeoutMs 8000 { $script:AsyncJobs.Count -eq 0 -and @($script:DetachedReadJobs).Count -eq 0 }) 'Tache non terminee apres l arret'
    Invoke-WiringPump 50
    Assert-True ($script:Main.Window.Dispatcher.CheckAccess()) 'Interface indisponible'
}

# ---------------------------------------------------------------- D002 / D003 (demonstration)
function Enable-WiringDemo {
    $script:DemoMode = $true; $script:DemoModeFixed = $true
    $script:DemoDirectory = New-DomeniaDemoDirectory -LatencyMs 0
    $script:Conn = [pscustomobject]@{Connected=$true;AuthMode='Demo';UseCredential=$false;Credential=$null;User='DEMO\demo.operateur';BindUser='DEMO\demo.operateur';Domain='demo.invalid';Netbios='DEMO';BaseDn='DC=demo,DC=invalid';Server='';RootPath='';LastError=''}
}
Test-Case 'D002 : commutateur strict et fixe une fois apres la configuration' {
    $script:RegPath = 'HKCU:\Software\DOMENIA-Wiring-' + [guid]::NewGuid().ToString('N')
    $script:CfgPath = Join-Path ([IO.Path]::GetTempPath()) ('domenia-cfg-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($script:CfgPath,'{"Auth":{"DemoProvider":"true"},"Features":{"Scheduler":false}}')
    [void](Load-AppConfig)
    Assert-True (-not (Initialize-DomeniaDemoMode)) 'Le texte "true" a active la demonstration'
    Assert-True (-not (Get-DomeniaFeatureFlag 'Scheduler' $true)) 'Features.Scheduler du fichier ignore'
    $script:DemoModeFixed = $false
    [IO.File]::WriteAllText($script:CfgPath,'{"Auth":{"DemoProvider":true}}')
    [void](Load-AppConfig)
    Assert-True (Initialize-DomeniaDemoMode) 'Le booleen true n active pas la demonstration'
    [IO.File]::WriteAllText($script:CfgPath,'{"Auth":{"DemoProvider":false}}')
    [void](Load-AppConfig)
    Assert-True (Initialize-DomeniaDemoMode) 'Le mode a change pendant la session'
    Assert-True ($null -ne $script:DemoDirectory -and [string]$script:DemoDirectory.Format -eq 'DomeniaDemoDirectory/1') 'Annuaire de demonstration absent'
    Remove-Item -LiteralPath $script:CfgPath -Force -ErrorAction SilentlyContinue
}
Test-Case 'D002 : arbre reel (Load-TreeChildren) servi par DemoDirectory' {
    Enable-WiringDemo
    $tree = New-Object System.Windows.Controls.TreeView
    $root = New-TreeItem -Name 'demo.invalid' -Dn 'DC=demo,DC=invalid' -Kind 'domainDNS'
    [void]$tree.Items.Add($root)
    Load-TreeChildren -Node $root
    $job = $script:AsyncJobs[$script:LatestTaskId]
    Assert-True ([string]$job.OperationId -eq 'TreeChildren' -and [string]$job.ExecutedOperationId -eq 'DemoDirectory') 'Arbre non substitue par DemoDirectory'
    Assert-True (Wait-WiringCondition -Complete { [bool]$root.Tag.Loaded }) 'Sous-branches non chargees'
    $headers = @($root.Items | ForEach-Object { [string]$_.Header })
    Assert-True ($headers -contains 'OU  Siege' -and $headers -contains 'CN  Users') ('Sous-branches inattendues : ' + ($headers -join ', '))
}
Test-Case 'D002 : recherche globale par evenements Row et fiche a GUID texte' {
    Enable-WiringDemo
    $progress = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $stop = New-Object System.Threading.CancellationTokenSource
    $filter = '(&(|(&(objectCategory=person)(objectClass=user))(objectCategory=computer)(objectCategory=group)(objectClass=organizationalUnit)(objectClass=container))(|(name=Jean*)(displayName=Jean*)(sAMAccountName=Jean*)(anr=Jean)))'
    $payload = [pscustomobject]@{BaseDn='DC=demo,DC=invalid';Scope='Subtree';PrefixFilter=$filter;FastFilter='';ExactFilter='';AnrFilter='';BroadFilter='';Limit=50;Properties=@('name');Progress=$progress;StopToken=$stop.Token;StreamPageSize=25}
    [void](Start-UiTask -Name 'Recherche' -OperationId 'GlobalSearch' -Code 'unused-in-demo' -Payload $payload -CallbackState ([pscustomobject]@{Tag='search'}) -SuccessHandler 'Complete-WiringTestUi' -ErrorHandler 'Fail-WiringTestUi')
    Assert-True (Wait-WiringCondition -Complete { $script:Callbacks.Count -eq 1 }) 'Recherche sans retour'
    $callback = $script:Callbacks[0]
    Assert-True ($callback.Kind -eq 'Success') ('Recherche en echec : ' + [string]$callback.Result)
    $search = Get-DomeniaEffectiveWorkerResult -Result $callback.Result -RequiredProperties @('Rows','BaseDn','Scope','FilterUsed')
    $events = 0; $item = $null
    while ($progress.TryDequeue([ref]$item)) { if ([string]$item.Kind -eq 'Row') { $events++ } }
    Assert-True (@($search.Rows).Count -ge 1 -and $events -eq @($search.Rows).Count) ('Evenements Row incoherents : ' + $events + ' / ' + @($search.Rows).Count)
    $jean = @($search.Rows | Where-Object { $_.Name -eq 'Jean Dupont' })[0]
    Assert-True (Test-DomeniaGuidText ([string]$jean.Guid)) 'GUID de ligne absent'
    $script:Callbacks.Clear()
    [void](Start-UiTask -Name 'Fiche' -OperationId 'OpenAdObject' -Code 'unused-in-demo' -Payload ([pscustomobject]@{DN=$jean.DN;Type='Utilisateur';Properties=@(Get-DomeniaSafeObjectPropertyNames)}) -CallbackState ([pscustomobject]@{Tag='fiche'}) -SuccessHandler 'Complete-WiringTestUi' -ErrorHandler 'Fail-WiringTestUi')
    Assert-True (Wait-WiringCondition -Complete { $script:Callbacks.Count -eq 1 }) 'Fiche sans retour'
    $object = Get-DomeniaEffectiveWorkerResult -Result $script:Callbacks[0].Result -RequiredProperties @('Properties')
    Assert-DomeniaObjectResultIdentity -Result $object -State ([pscustomobject]@{Dn=[string]$jean.DN;ExpectedGuid=[string]$jean.Guid})
    Assert-True (@($object.Properties.objectGUID)[0] -is [string]) 'objectGUID non converti en texte'
    Assert-True (@($object.Properties.memberOf).Count -eq 2 -and [bool]@($object.Properties['__memberOfComplete'])[0]) 'Appartenances incoherentes'
}
Test-Case 'D002 : ecritures et outils refuses, operation non disponible sans proposition de compte' {
    Enable-WiringDemo
    $refused = ''
    try { [void](Start-WiringTask -OperationId 'WriteAttributes' -Name 'Ecriture' -IsWrite) } catch { $refused = $_.Exception.Message }
    Assert-True ($refused -match 'DOMENIA_DEMO_WRITE' -and $script:AsyncJobs.Count -eq 0) 'Ecriture non refusee en demonstration'
    $writeGuard = ''; try { Assert-WriteAllowed } catch { $writeGuard = $_.Exception.Message }
    Assert-True ($writeGuard -match 'demonstration') 'Assert-WriteAllowed laisse passer'
    $remoteGuard = ''; try { Assert-DomeniaRemoteWriteAllowed -Operation 'GPUpdate' } catch { $remoteGuard = $_.Exception.Message }
    Assert-True ($remoteGuard -match 'demonstration') 'Action distante non refusee'
    [void](Start-UiTask -Name 'Ping' -OperationId 'ComputerPing' -Code 'unused-in-demo' -Payload ([pscustomobject]@{Computer='PC-DEMO-01'}) -CallbackState ([pscustomobject]@{Tag='ping'}) -SuccessHandler 'Complete-WiringTestUi' -ErrorHandler 'Fail-WiringTestUi')
    Assert-True (Wait-WiringCondition -Complete { $script:Callbacks.Count -eq 1 }) 'Operation sans retour'
    $message = [string]$script:Callbacks[0].Result
    Assert-True ($script:Callbacks[0].Kind -eq 'Error' -and $message -match 'non disponible en demonstration') ('Message inattendu : ' + $message)
    Assert-True (-not [bool](Get-DomeniaStructuredError $message).CanOfferCredential) 'Un autre compte serait propose'
}
Test-Case 'D003 : objet restreint refuse (0x80070005) puis autre compte de demonstration' {
    Enable-WiringDemo
    $dn = 'CN=Compte Restreint,OU=Restreint,DC=demo,DC=invalid'
    [void](Start-UiTask -Name 'Fiche restreinte' -OperationId 'OpenAdObject' -Code 'unused-in-demo' -Payload ([pscustomobject]@{DN=$dn;Type='Utilisateur';Properties=@('name','objectGUID')}) -CallbackState ([pscustomobject]@{Tag='refus'}) -SuccessHandler 'Complete-WiringTestUi' -ErrorHandler 'Fail-WiringTestUi')
    Assert-True (Wait-WiringCondition -Complete { $script:Callbacks.Count -eq 1 }) 'Lecture sans retour'
    Assert-True ([bool](Get-DomeniaStructuredError ([string]$script:Callbacks[0].Result)).CanOfferCredential) 'Le refus ne propose pas un autre compte'
    $request = New-DomeniaAccountAuthRequest -UserName 'DEMO\demo.admin' -Password (ConvertTo-SecureString 'x' -AsPlainText -Force)
    Assert-True ([bool]$request.DemoOnly -and $null -eq $request.Credential) 'Le mot de passe saisi a quitte le panneau'
    $bad = ''; try { [void](New-DomeniaAccountAuthRequest -UserName 'CORP\x' -Password (ConvertTo-SecureString 'x' -AsPlainText -Force)) } catch { $bad = $_.Exception.Message }
    Assert-True ($bad -match 'demonstration') 'Identite hors demonstration acceptee'
    $script:Callbacks.Clear()
    $script:Conn.BindUser = 'DEMO\demo.admin'
    [void](Start-UiTask -Name 'Fiche relue' -OperationId 'OpenAdObject' -Code 'unused-in-demo' -Payload ([pscustomobject]@{DN=$dn;Type='Utilisateur';Properties=@('name','objectGUID')}) -CallbackState ([pscustomobject]@{Tag='relue'}) -SuccessHandler 'Complete-WiringTestUi' -ErrorHandler 'Fail-WiringTestUi')
    Assert-True (Wait-WiringCondition -Complete { $script:Callbacks.Count -eq 1 }) 'Relecture sans retour'
    Assert-True ($script:Callbacks[0].Kind -eq 'Success') ('Relecture refusee : ' + [string]$script:Callbacks[0].Result)
}
function New-WiringLoginUi {
    $reader = [Xml.XmlNodeReader]::new([xml](Get-DomeniaStandardLoginXaml))
    try { $window = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    $ui = @{Window=$window}
    foreach ($pair in @(@('Login','TxtLogin'),@('Password','PwdLogin'),@('PasswordVisible','TxtLoginPasswordVisible'),@('Reveal','BtnRevealLogin'),@('Remember','ChkRemember'),@('Error','LblLoginError'),@('Stage','LblLoginStage'),@('Progress','PbLogin'),@('Technical','TxtLoginTechnical'),@('Connect','BtnLogin'),@('Windows','BtnWindowsLogin'),@('Cancel','BtnCancel'),@('OpenLog','BtnLoginLog'),@('CopyDiag','BtnCopyLoginDiag'))) {
        $ui[$pair[0]] = $window.FindName($pair[1])
        if ($null -eq $ui[$pair[0]]) { throw ('Controle de login absent : ' + $pair[1]) }
    }
    return $ui
}
Test-Case 'D002 : login de demonstration de bout en bout (vrai runspace d authentification, aucun mot de passe)' {
    Enable-WiringDemo
    $ui = New-WiringLoginUi
    $script:FastLoginUi = $ui
    $script:FastLoginState = [pscustomobject]@{LoginOk=$false;Reveal=$false;Session=$null;Login='';Password='';Mode='Standard';UseCurrentCredentials=$false}
    Initialize-DomeniaDemoLoginPresentation -Ui $ui
    Assert-True ([string]$ui.Window.Title -match 'DÉMONSTRATION') 'Bandeau absent du titre'
    Assert-True (-not $ui.Password.IsEnabled -and $ui.Windows.Visibility -eq 'Collapsed' -and [string]$ui.Login.Text -eq 'DEMO\demo.operateur') 'Presentation de demonstration incomplete'
    Set-DomeniaFastLoginBusy $true; Set-DomeniaFastLoginBusy $false
    Assert-True (-not $ui.Password.IsEnabled -and $ui.Connect.IsEnabled -and -not $ui.Windows.IsEnabled) 'Champ mot de passe reactive apres une tentative'
    $ui.Login.Text = 'jdupont'
    Start-DomeniaFastLoginAttempt
    Assert-True ($null -eq $script:FastLoginState.Session -and [string]$ui.Error.Text -match 'DEMO') 'Identite hors demonstration acceptee'
    $ui.Login.Text = 'DEMO\demo.operateur'
    Start-DomeniaFastLoginAttempt
    Assert-True ($null -ne $script:FastLoginState.Session -and [bool]$script:FastLoginState.Session.Request.DemoOnly -and $null -eq $script:FastLoginState.Session.Request.Credential) 'Session de demonstration non creee'
    Assert-True (Wait-WiringCondition -TimeoutMs 15000 { [bool]$script:FastLoginState.LoginOk }) ('Connexion de demonstration non aboutie : ' + $ui.Error.Text)
    Assert-True ([string]$script:Conn.AuthMode -eq 'Demo' -and $null -eq $script:Conn.Credential -and [string]$script:Conn.BaseDn -eq 'DC=demo,DC=invalid') 'Contexte de connexion inexact'
    Assert-True ($script:SaveConfigCalls -eq 0) 'Identite memorisee dans le registre'
    Assert-True ((@($script:LoginLog) -join ' ') -match 'Mode=Demo') 'Journal de connexion sans mode'
    $script:DemoMode = $false
    $incoherent = ''
    try { Complete-DomeniaFastLoginSuccess -Result ([pscustomobject]@{AuthMethod='Demo.InMemory';BindUser='DEMO\x';DurationMs=1}) -Credential $null } catch { $incoherent = $_.Exception.Message }
    Assert-True ($incoherent -match 'incoherent') 'Resultat de demonstration accepte hors demonstration'
}
Test-Case 'D002 : bandeau et verrou de lecture seule dans la fenetre principale' {
    Enable-WiringDemo
    Set-DomeniaDemoShellPresentation
    Assert-True ([string]$script:Main.Window.Title -match 'DÉMONSTRATION') 'Titre sans bandeau'
    Assert-True ([string]$script:Ctrl.LblUxDomain.Text -match 'DÉMONSTRATION') 'Pastille de session sans bandeau'
    Assert-True ([bool]$script:Ctrl.ChkReadOnlyMode.IsChecked -and -not $script:Ctrl.ChkReadOnlyMode.IsEnabled) 'Lecture seule non verrouillee'
    $wire = (Get-CoreFunctionAst 'Wire-Events').Extent.Text
    $match = [regex]::Match($wire,'(?s)\["ChkReadOnlyMode"\]\.Add_Unchecked\(\{(.*?)\n        \}\)')
    Assert-True $match.Success 'Gestionnaire ChkReadOnlyMode introuvable'
    $box = New-Object System.Windows.Controls.CheckBox
    $box.IsChecked = $true
    $script:Ctrl['ChkReadOnlyMode'] = $box
    $box.Add_Unchecked([scriptblock]::Create($match.Groups[1].Value))
    $box.IsChecked = $false
    Assert-True ([bool]$box.IsChecked -and [bool]$script:ReadOnlyMode -and $script:Confirmations -eq 0) 'Le mode ecriture peut etre active en demonstration'
    $script:Ctrl['ChkReadOnlyMode'] = $script:Main.Controls['ChkReadOnlyMode']
}

# ---------------------------------------------------------------- D089
Test-Case 'D089 : aucun Topmost sauf le login autonome temporaire, nettoye en finally' {
    Assert-True ((Get-DomeniaStartupXaml) -match 'Topmost="False"') 'Moniteur de demarrage encore Topmost'
    foreach ($file in @(Get-ChildItem -LiteralPath $wad -Recurse -File -Include '*.ps1','*.xaml' | Where-Object { $_.FullName -notmatch '[\\/](tests|docs|maintenance)[\\/]' })) {
        $text = [IO.File]::ReadAllText($file.FullName)
        # User-requested standalone login is the sole exception. Its lifecycle is exercised by
        # Test-DomeniaLoginForeground; every other function, monitor and XAML remains prohibited.
        if ($file.FullName -eq (Join-Path $wad 'Domenia-Core.ps1')) { $text=$text.Replace((Get-CoreFunctionAst 'Show-LoginWindow').Extent.Text,'') }
        Assert-True ($text -notmatch 'Topmost="True"' -and $text -notmatch '\.Topmost\s*=\s*\$true') ('Topmost force hors login autonome dans ' + $file.Name)
    }
    $monitor = (Get-CoreFunctionAst 'New-DomeniaStartupWindow').Extent.Text
    $render = (Get-CoreFunctionAst 'Initialize-Window').Extent.Text
    $login = (Get-CoreFunctionAst 'Show-LoginWindow').Extent.Text
    $loginAst=Get-CoreFunctionAst 'Show-LoginWindow'
    $promotions=@($loginAst.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Extent.Text -match '\.Topmost\s*=\s*\$true'},$true))
    Assert-True ($promotions.Count -eq 2) 'Exceptions Topmost du login inattendues'
    foreach($promotion in $promotions){
        $guarded=$false;$parent=$promotion.Parent
        while($null -ne $parent -and $parent -ne $loginAst){
            if($parent -is [Management.Automation.Language.IfStatementAst] -and $parent.Clauses[0].Item1.Extent.Text -match '-not\s*\(Test-DomeniaMainHostAvailable\)'){$guarded=$true;break}
            $parent=$parent.Parent
        }
        Assert-True $guarded 'Une promotion Topmost du login peut toucher la fenetre principale'
    }
    $cleanup=@($loginAst.FindAll({param($n) $n -is [Management.Automation.Language.TryStatementAst] -and $null -ne $n.Finally -and $n.Finally.Extent.Text -match '\$window\.Topmost\s*=\s*\$false'},$true))
    Assert-True ($cleanup.Count -eq 1) 'Le login ne libere pas Topmost dans son finally'
    Assert-True ($monitor -match "Trigger 'StartupMonitor'" -and $render -match "Trigger 'LoginToMain'" -and $login -match "Trigger 'Launch'") 'Moments d activation non branches'
    foreach ($name in @('Complete-UiTasks','Invoke-DomeniaJobSuccessUi','Invoke-DomeniaJobErrorUi','Update-TaskUi')) {
        Assert-True ((Get-CoreFunctionAst $name).Extent.Text -notmatch 'Request-DomeniaWindowActivation|\.Activate\(') ('Activation apres une tache dans ' + $name)
    }
}
Test-Case 'D089 : une seule demande par moment, refus respecte, Alt-Tab respecte' {
    Assert-True ($null -ne (Get-Command -Name Get-DomeniaActivationDecision -CommandType Function -ErrorAction SilentlyContinue)) 'Get-DomeniaActivationDecision absent (Domenia-Shell.Model.ps1 non integre)'
    $script:Logs.Clear()
    $window = New-Object System.Windows.Window
    $window.Width = 200; $window.Height = 100; $window.ShowActivated = $false
    try {
        $window.Show()
        $first = Request-DomeniaWindowActivation -Window $window -Trigger 'LoginToMain'
        $second = Request-DomeniaWindowActivation -Window $window -Trigger 'LoginToMain'
        Assert-True ([bool]$first.Requested -and -not [bool]$second.Requested) 'Activation repetee'
        Assert-True (-not $window.Topmost) 'Topmost pose'
        Assert-True ((@($script:Logs) -match 'ACTIVATION Trigger=LoginToMain Resultat=(Accordee|Refusee)').Count -eq 1) 'Journal d activation inexact'
        $task = Request-DomeniaWindowActivation -Window $window -Trigger 'TaskCompleted'
        Assert-True (-not [bool]$task.Requested) 'Activation en fin de tache'
        $script:DomeniaActivationState = $null
        (Get-DomeniaActivationState).UserSwitchedAway = $true
        $away = Request-DomeniaWindowActivation -Window $window -Trigger 'StartupMonitor'
        Assert-True (-not [bool]$away.Requested) 'Alt-Tab de l operateur ignore'
        $script:CaseDetail = 'Premiere demande : ' + $(if ($first.Activated) { 'accordee' } else { 'refusee par Windows (session sans premier plan), sans nouvel essai' })
    } finally { $window.Close() }
}

# ---------------------------------------------------------------- D028 (lot cache F1/F2): single local writer
# Real queue (Queue-DomeniaLinkChanges), real admission and callbacks (Start/Complete/Fail-DomeniaStorageWork), real
# Resume-DomeniaStorage, real pinned LocalStore body in a real worker runspace (real Start-UiTask/Complete-UiTasks),
# real schema (Initialize-DomeniaDatabase) in a temporary local file, real Get-DomeniaLinkFingerprint and real loader
# Load-UserMachineLinks. No directory, no share, no AD write. Removing the optimistic check of the worker, its single
# transaction (BEGIN IMMEDIATE), the conflict state, the writer's own suspension or the off-Dispatcher writer makes a
# case fail.
function Get-WiringModuleFunctionText {
    param([string]$File,[string]$Name)
    $mt = $null; $me = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $modules $File),[ref]$mt,[ref]$me)
    if (@($me).Count) { throw ('Syntaxe ' + $File + ' : ' + $me[0].Message) }
    $nodes = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name },$true))
    if ($nodes.Count -ne 1) { throw ('Fonction absente ou ambigue : ' + $Name + ' dans ' + $File) }
    return $nodes[0].Extent.Text
}
. ([scriptblock]::Create((Get-WiringModuleFunctionText 'Domenia-Guard.UI.ps1' 'Resume-DomeniaStorage')))
function Rebuild-UserMachineLinkIndex { }
function Refresh-AssociationContext { param([switch]$SkipResultRefresh) }
function Recover-DomeniaDatabase { param($Reason) throw 'Restauration interdite dans ce test.' }
# Spy: the real callback runs unchanged; the effective worker result is kept for the assertions.
$script:StorageCompleteReal = (Get-Command Complete-DomeniaStorageWork -CommandType Function).ScriptBlock
function Complete-DomeniaStorageWork {
    param($Result,$State)
    $script:StorageResults.Add((Get-DomeniaEffectiveWorkerResult $Result @('Saved','Conflicts')))
    & $script:StorageCompleteReal $Result $State
}
$script:StoreRoots = New-Object 'System.Collections.Generic.List[string]'
function Reset-WiringStore {
    $script:Persistence = $null; $script:LinkBaseline = @{}; $script:UserMachineLinks = @(); $script:Live = $null
    $script:StorageResults = New-Object 'System.Collections.Generic.List[object]'
    $script:DomeniaDatabaseReady = $false; $script:DomeniaDatabaseRecoveryAttempted = $false
}
function New-WiringStoreDatabase {
    [void](Initialize-DomeniaWinSqliteNative)
    $root = Join-Path ([IO.Path]::GetTempPath()) ('domenia-store-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    $script:StoreRoots.Add($root)
    $script:DatabaseScopedPath = Join-Path $root 'Domenia.db'
    $script:DomeniaDatabaseReady = $false; $script:DomeniaDatabaseRecoveryAttempted = $false
    Assert-True (Initialize-DomeniaDatabase) 'Schema reel non cree'
    return [string]$script:DatabaseScopedPath
}
function New-WiringLink {
    param([string]$User,[string]$Computer,[string]$When = '2026-10-04 09:00:00')
    return [pscustomobject]@{UserLogin=$User;Computer=$Computer;Source='Saisie manuelle';Confidence=100;VerifiedInAD=$true;When=$When;Details='Lot cache F1';UserGuid='';ComputerGuid='';UserDn='';ComputerDn=''}
}
function Get-WiringStoredLinks {
    $db = Open-DomeniaDatabase -Path $script:DatabaseScopedPath -ReadOnly
    try { $rows = @(Invoke-DomeniaDbQuery 'SELECT computer_key,user_login FROM user_machine_links;' $db) } finally { Close-DomeniaDatabase $db }
    $map = @{}
    foreach ($r in $rows) { $map[[string]$r.computer_key] = [string]$r.user_login }
    return $map
}
function Start-WiringStorage {
    # Real persistence state. MO-03: its timer is armed when an item is queued; it is set aside here (and given back by
    # Resume-WiringStorageTimer) so that the case decides when the writer is admitted.
    $script:Persistence = $null
    Initialize-DomeniaPersistence
    $script:Persistence.Timer.Stop()
    $script:WiringStorageTimer = $script:Persistence.Timer
    $script:Persistence.Timer = $null
}
function Resume-WiringStorageTimer {
    $script:Persistence.Timer = $script:WiringStorageTimer
    $script:Persistence.Timer.Start()
}
function Stop-WiringStorage {
    if ($null -eq $script:Persistence) { return }
    try { $script:Persistence.Timer.Stop() } catch { }
    try { if ($null -ne $script:WiringStorageTimer) { $script:WiringStorageTimer.Stop() } } catch { }
    if ($null -ne $script:Persistence.LinkRequestTimer) { try { $script:Persistence.LinkRequestTimer.Stop() } catch { } }
}
function Wait-WiringStoreIdle {
    return (Wait-WiringCondition -Complete -TimeoutMs 15000 { @($script:AsyncJobs.Values | Where-Object { $null -ne $_ -and $_.OperationId -eq 'LocalStore' }).Count -eq 0 })
}
function Invoke-WiringStorageBatch {
    param([string]$Why = 'Lot')
    Assert-True (Wait-WiringStoreIdle) ($Why + ' : ecrivain precedent encore actif')
    $script:Persistence.Next = [datetime]::MinValue
    Start-DomeniaStorageWork
    Assert-True ([string]$script:Persistence.Job) ($Why + ' : aucun lot demarre. ' + [string]$script:Persistence.Fault)
    Assert-True (Wait-WiringCondition -Complete -TimeoutMs 30000 { -not [string]$script:Persistence.Job }) ($Why + ' : aucun rappel du stockage')
}

Test-Case 'D028 : deux mises a jour independantes ne s ecrasent pas' {
    try {
        Reset-WiringStore
        $path = New-WiringStoreDatabase
        Start-WiringStorage
        # Console A saves PC1=alice and PC2=bob (nothing on disk yet, Expected is empty).
        $script:UserMachineLinks = @((New-WiringLink 'alice' 'PC1'),(New-WiringLink 'bob' 'PC2'))
        Assert-True (Queue-DomeniaLinkChanges) 'Console A : mise en file refusee'
        Assert-True ($script:Persistence.Pending.Count -eq 2) ('Console A : ' + $script:Persistence.Pending.Count + ' element(s) en file')
        Invoke-WiringStorageBatch 'Console A, premier lot'
        $first = $script:StorageResults[$script:StorageResults.Count - 1]
        Assert-True ([bool]$first.Saved -and @($first.Conflicts).Count -eq 0) ('Premier lot : conflits ' + (@($first.Conflicts) -join ','))
        $disk = Get-WiringStoredLinks
        Assert-True ($disk['PC1'] -eq 'alice' -and $disk['PC2'] -eq 'bob') 'Premier lot absent du disque'
        Assert-True ([string]$script:LinkBaseline['PC1'].UserLogin -eq 'alice' -and [string]$script:LinkBaseline['PC2'].UserLogin -eq 'bob') 'Reference de A non mise a jour'
        # Console B reads the same base with the real loader, then changes PC1 to carol in its own LocalStore run.
        $consoleA = [pscustomobject]@{Links=$script:UserMachineLinks;Baseline=$script:LinkBaseline}
        Load-UserMachineLinks
        $readByB = $script:LinkBaseline['PC1']
        $script:UserMachineLinks = $consoleA.Links; $script:LinkBaseline = $consoleA.Baseline
        Assert-True ($null -ne $readByB -and [string]$readByB.UserLogin -eq 'alice') 'Console B : PC1 non relu sur le disque'
        $expectedB = Get-DomeniaLinkFingerprint $readByB
        Assert-True ($expectedB -ceq (Get-DomeniaLinkFingerprint $script:LinkBaseline['PC1'])) 'Empreinte relue sur disque differente de la reference de A'
        $itemB = [pscustomobject]@{QueueKey=('Link|' + $path + '|PC1');Kind='Link';Key='PC1';Path=$path;Expected=$expectedB;Row=(ConvertTo-DomeniaLinkRecord (New-WiringLink 'carol' 'PC1' '2026-10-04 09:05:00'));Remove=$false;Epoch=[long]$script:SessionEpoch}
        Assert-True (Wait-WiringStoreIdle) 'Console B : ecrivain de A encore actif'
        [void](Start-UiTask -Name 'Console B' -OperationId 'LocalStore' -Code (Get-DomeniaStorageWorkerCode) -Payload ([pscustomobject]@{Path=$path;Items=@($itemB)}) -CallbackState ([pscustomobject]@{Tag='B'}) -SuccessHandler 'Complete-WiringTestUi' -ErrorHandler 'Fail-WiringTestUi' -NonCancellable -TimeoutSeconds 120)
        Assert-True (Wait-WiringCondition -Complete -TimeoutMs 30000 { @($script:Callbacks | Where-Object { $_.Tag -eq 'B' }).Count -eq 1 }) 'Console B : aucun rappel'
        $b = @($script:Callbacks | Where-Object { $_.Tag -eq 'B' })[0]
        Assert-True ($b.Kind -eq 'Success') ('Console B en echec : ' + [string]$b.Result)
        $rb = Get-DomeniaEffectiveWorkerResult $b.Result @('Saved','Conflicts')
        Assert-True ($null -ne $rb -and [bool]$rb.Saved -and @($rb.Conflicts).Count -eq 0) ('Console B : faux conflit, parite Get-DomeniaLinkFingerprint / LinkHash rompue : ' + (@($rb.Conflicts) -join ','))
        Assert-True ((Get-WiringStoredLinks)['PC1'] -eq 'carol') 'Console B : PC1 non ecrit'
        # Console A, unaware of B, saves PC1=dave and PC2=erin in one batch.
        $script:UserMachineLinks = @((New-WiringLink 'dave' 'PC1' '2026-10-04 09:10:00'),(New-WiringLink 'erin' 'PC2' '2026-10-04 09:10:00'))
        Assert-True (Queue-DomeniaLinkChanges) 'Console A : deuxieme mise en file refusee'
        Assert-True ($script:Persistence.Pending.Count -eq 2) 'Console A : un lot de deux liens attendu'
        $script:Statuses.Clear()
        Invoke-WiringStorageBatch 'Console A, second lot'
        $second = $script:StorageResults[$script:StorageResults.Count - 1]
        Assert-True ((@($second.Conflicts) -join ',') -ceq 'PC1') ('Conflits attendus PC1, obtenus : ' + (@($second.Conflicts) -join ','))
        $disk = Get-WiringStoredLinks
        Assert-True ($disk['PC1'] -eq 'carol' -and $disk['PC2'] -eq 'erin') ('Disque : PC1=' + $disk['PC1'] + ' PC2=' + $disk['PC2'])
        Assert-True (@($script:Statuses | Where-Object { $_ -match 'Association modifiee ailleurs : PC1' }).Count -eq 1) 'Avertissement de conflit absent'
        Assert-True ([string]$script:LinkBaseline['PC1'].UserLogin -eq 'alice') ('Reference PC1 : ' + [string]$script:LinkBaseline['PC1'].UserLogin)
        Assert-True ([string]$script:LinkBaseline['PC2'].UserLogin -eq 'erin') ('Reference PC2 : ' + [string]$script:LinkBaseline['PC2'].UserLogin)
        # Decision D028 (a): visible conflict state, quiet path silent on PC1, explicit path resubmits and warns, reload ends it.
        Assert-True ($script:Persistence.Conflicts.Count -eq 1 -and $script:Persistence.Conflicts.ContainsKey('PC1')) 'Etat de conflit non garde'
        $label = (Get-DomeniaPersistenceState).Label
        Assert-True ($label -match '1 association\(s\) modifiee\(s\) ailleurs' -and $label -cne 'Enregistre.') ('Libelle apres conflit : ' + $label)
        Assert-True (Queue-DomeniaLinkChanges -Quiet -MaxItems 64) 'Chemin silencieux en erreur'
        Assert-True ($script:Persistence.Pending.Count -eq 0 -and -not $script:Persistence.LinkBusy) 'Le chemin silencieux renvoie la cle en conflit'
        $script:Statuses.Clear()
        Assert-True (Queue-DomeniaLinkChanges) 'Chemin explicite refuse'
        Assert-True ($script:Persistence.Pending.Count -eq 1) 'Le chemin explicite ne soumet pas la cle en conflit'
        Invoke-WiringStorageBatch 'Console A, nouvel essai explicite'
        Assert-True ((Get-WiringStoredLinks)['PC1'] -eq 'carol') 'Le nouvel essai explicite a ecrase la version de B'
        Assert-True (@($script:Statuses | Where-Object { $_ -match 'Association modifiee ailleurs : PC1' }).Count -eq 1) 'Le chemin explicite n avertit pas'
        Load-UserMachineLinks
        Assert-True ($script:Persistence.Conflicts.Count -eq 0) 'Le rechargement ne termine pas l etat de conflit'
        Assert-True (@($script:UserMachineLinks | Where-Object { [string]$_.Computer -eq 'PC1' -and [string]$_.UserLogin -eq 'carol' }).Count -eq 1) 'Rechargement : version du disque absente'
        $after = (Get-DomeniaPersistenceState).Label
        Assert-True ($after -ceq 'Enregistre.') ('Libelle apres rechargement : ' + $after)
    } finally { Stop-WiringStorage }
}
Test-Case 'D028 : un verrou SQLite ne bloque pas WPF' {
    $lock = [IntPtr]::Zero; $heart = $null
    try {
        Reset-WiringStore
        $path = New-WiringStoreDatabase
        Start-WiringStorage
        $script:UserMachineLinks = @(New-WiringLink 'alice' 'PC1')
        Assert-True (Queue-DomeniaLinkChanges) 'Mise en file refusee'
        # A second connection holds the write lock, as another console in the middle of its own transaction.
        $lock = Open-DomeniaDatabase -Path $path
        [void](Invoke-DomeniaDbExec 'BEGIN IMMEDIATE;' $lock)
        $script:HeartClock = [Diagnostics.Stopwatch]::StartNew()
        $script:HeartTicks = New-Object 'System.Collections.Generic.List[double]'
        $heart = New-Object System.Windows.Threading.DispatcherTimer
        $heart.Interval = [TimeSpan]::FromMilliseconds(20)
        $heart.Add_Tick({ $script:HeartTicks.Add($script:HeartClock.Elapsed.TotalMilliseconds) })
        $heart.Start()
        $starts = New-Object 'System.Collections.Generic.List[double]'; $gaps = New-Object 'System.Collections.Generic.List[double]'; $waits = New-Object 'System.Collections.Generic.List[double]'
        foreach ($attempt in 1..3) {
            Assert-True (Wait-WiringStoreIdle) ('Essai ' + $attempt + ' : ecrivain precedent encore actif')
            $script:Persistence.Next = [datetime]::MinValue
            $watch = [Diagnostics.Stopwatch]::StartNew(); Start-DomeniaStorageWork; $watch.Stop()
            $starts.Add([Math]::Round($watch.Elapsed.TotalMilliseconds,1))
            Assert-True ([string]$script:Persistence.Job) ('Essai ' + $attempt + ' : aucun lot demarre. ' + [string]$script:Persistence.Fault)
            # TE-03: structural proof instead of the former 250 ms threshold: Start-DomeniaStorageWork returned while
            # its worker is still waiting on the lock (busy_timeout 300 ms), so the SQLite wait never ran here.
            $started = $script:AsyncJobs[[string]$script:Persistence.Job]
            Assert-True ($null -ne $started -and -not [bool]$started.Handle.IsCompleted) ('Essai ' + $attempt + ' : Start-DomeniaStorageWork a attendu le verrou SQLite sur le Dispatcher')
            Assert-True ($script:Persistence.Pending.Count -eq 0 -and [int]$script:Persistence.InFlight -eq 1) 'Lot en cours non compte'
            # While the batch waits on the lock the label never says saved: pending first, then the previous failure.
            $during = (Get-DomeniaPersistenceState).Label
            if ($attempt -eq 1) { Assert-True ($during -ceq 'En memoire : 1 modification(s) a enregistrer.') ('Libelle pendant l attente du verrou : ' + $during) }
            else { Assert-True ($during -match 'en echec, nouvel essai prevu') ('Libelle pendant le nouvel essai : ' + $during) }
            $from = $script:HeartClock.Elapsed.TotalMilliseconds
            Assert-True (Wait-WiringCondition -Complete -TimeoutMs 30000 { -not [string]$script:Persistence.Job }) ('Essai ' + $attempt + ' : aucun rappel')
            $to = $script:HeartClock.Elapsed.TotalMilliseconds
            $window = @($script:HeartTicks | Where-Object { $_ -ge $from -and $_ -le $to })
            $largest = 0.0; $previous = $from
            foreach ($tick in $window) { $largest = [Math]::Max($largest,$tick - $previous); $previous = $tick }
            $largest = [Math]::Max($largest,$to - $previous)
            $gaps.Add([Math]::Round($largest,1)); $waits.Add([Math]::Round($to - $from,1))
            # The worker waits on busy_timeout (300 ms) after Start-DomeniaStorageWork has returned, and the Dispatcher keeps ticking.
            Assert-True (($to - $from) -ge 250) ('Essai ' + $attempt + ' : rappel en ' + [Math]::Round($to - $from) + ' ms, attente du verrou absente')
            Assert-True ($window.Count -ge 5) ('Essai ' + $attempt + ' : ' + $window.Count + ' tick(s) seulement pendant l attente')
            Assert-True ($largest -lt 150) ('Essai ' + $attempt + ' : Dispatcher bloque ' + [Math]::Round($largest) + ' ms pendant l attente du verrou')
            Assert-True ([int]$script:Persistence.Failures -eq $attempt) ('Echecs : ' + $script:Persistence.Failures)
            Assert-True ([string]$script:Persistence.Fault -match '(?i)code 5|locked|busy') ('Erreur SQLite perdue : ' + $script:Persistence.Fault)
            Assert-True ($script:Persistence.Pending.Count -eq 1 -and [int]$script:Persistence.InFlight -eq 0) 'Lien non remis en file apres l echec'
            $label = (Get-DomeniaPersistenceState).Label
            if ($attempt -lt 3) { Assert-True ($label -match 'en echec, nouvel essai prevu') ('Libelle apres echec : ' + $label) }
            else { Assert-True ($label -match 'suspendu') ('Libelle apres trois echecs : ' + $label) }
        }
        # Kept for the next case: (wait - 300 ms) bounds the time the worker needs to reach BEGIN IMMEDIATE.
        $script:D028LockWaits = $waits.ToArray()
        # Three failures suspend the writer: no job even when the delay has passed. The engine D018 breaker would also
        # refuse this Storage work inside Start-UiTask, so the case proves that Start-DomeniaStorageWork returns before
        # reaching the engine: the refusal branch (Next pushed 5 s later, Fault replaced) must not run, and the engine
        # does not record a refused admission.
        $script:Persistence.Next = [datetime]::MinValue
        $faultBefore = [string]$script:Persistence.Fault
        $script:StartUiTaskCalls = 0
        $startUiTaskReal = (Get-Command Start-UiTask -CommandType Function).ScriptBlock
        Set-Item function:script:Start-UiTask -Value { $script:StartUiTaskCalls++; throw 'Start-UiTask atteint malgre la suspension.' }
        try { Start-DomeniaStorageWork } finally { Set-Item function:script:Start-UiTask -Value $startUiTaskReal }
        Assert-True ($script:StartUiTaskCalls -eq 0) 'La suspension de l ecrivain laisse Start-DomeniaStorageWork atteindre le moteur'
        Assert-True ($script:Persistence.Next -eq [datetime]::MinValue -and [string]$script:Persistence.Fault -ceq $faultBefore) ('Suspension contournee : Next=' + $script:Persistence.Next.ToString('o') + ' Fault=' + [string]$script:Persistence.Fault)
        Assert-True (-not [string]$script:Persistence.Job) 'Un lot demarre malgre la suspension'
        Assert-True ($script:Persistence.Pending.Count -eq 1 -and [int]$script:Persistence.InFlight -eq 0) 'Suspension : lien perdu ou compte en cours'
        Assert-True ((Get-WiringStoredLinks).Count -eq 0) 'Ecriture malgre le verrou'
        $heart.Stop()
        [void](Invoke-DomeniaDbExec 'ROLLBACK;' $lock); Close-DomeniaDatabase $lock; $lock = [IntPtr]::Zero
        # Lock released: explicit resume (real Resume-DomeniaStorage of Fiabilite), then the same link reaches the disk.
        Resume-DomeniaStorage
        Assert-True ([int]$script:Persistence.Failures -eq 0) 'Reprise sans remise a zero'
        # The engine keeps its own D018 breaker: after three Storage failures, background Storage work waits for the
        # provider backoff (15 s at the first level). The writer is then refused by Start-UiTask, keeps its item and says so.
        Assert-True (Wait-WiringStoreIdle) 'Apres reprise : ecrivain precedent encore actif'
        $script:Persistence.Next = [datetime]::MinValue
        Start-DomeniaStorageWork
        $deferred = ''
        if (-not [string]$script:Persistence.Job) {
            $deferred = [string]$script:Persistence.Fault
            Assert-True ($deferred -match 'Pannes repetees') ('Apres reprise : refus inattendu : ' + $deferred)
            Assert-True ($script:Persistence.Pending.Count -eq 1) 'Apres reprise : lien perdu pendant le refus du moteur'
            $waiting = (Get-DomeniaPersistenceState).Label
            Assert-True ($waiting -ceq 'En memoire : 1 modification(s) a enregistrer.') ('Libelle pendant le delai du moteur : ' + $waiting)
            # The real persistence timer (MO-03: about 1 s, Next gate of 5 s after a refusal) retries on its own.
            Resume-WiringStorageTimer
        }
        Assert-True (Wait-WiringCondition -Complete -TimeoutMs 60000 { $script:StorageResults.Count -gt 0 -and -not [string]$script:Persistence.Job }) ('Apres reprise : aucun lot enregistre. ' + [string]$script:Persistence.Fault)
        if ($null -ne $script:Persistence.Timer) { $script:Persistence.Timer.Stop() }
        Assert-True ((Get-WiringStoredLinks)['PC1'] -eq 'alice') 'Lien absent du disque apres la reprise'
        Assert-True ([int]$script:Persistence.Failures -eq 0 -and $script:Persistence.Pending.Count -eq 0 -and [int]$script:Persistence.InFlight -eq 0) 'Etat apres reprise'
        $final = (Get-DomeniaPersistenceState).Label
        Assert-True ($final -ceq 'Enregistre.') ('Libelle apres reprise : ' + $final)
        $script:CaseDetail = 'Start-DomeniaStorageWork (ouverture du runspace incluse) : ' + ($starts -join ' / ') + ' ms ; attente du verrou : ' + ($waits -join ' / ') + ' ms ; plus grand ecart du Dispatcher pendant cette attente : ' + ($gaps -join ' / ') + ' ms' + $(if ($deferred) { ' ; apres reprise, premier essai differe par le moteur : ' + $deferred } else { '' })
    } finally {
        if ($null -ne $heart) { $heart.Stop() }
        if ($lock -ne [IntPtr]::Zero) { try { [void](Invoke-DomeniaDbExec 'ROLLBACK;' $lock) } catch { }; Close-DomeniaDatabase $lock }
        Stop-WiringStorage
    }
}

Test-Case 'D028 : consoles simultanees : verification et ecriture dans une seule transaction' {
    # Interleaved variant of the first case. Console B holds the write lock with PC1=carol written but not committed;
    # console A starts its batch (PC1=dave, Expected=alice), its worker reaches BEGIN IMMEDIATE and waits; B commits well
    # inside busy_timeout (300 ms). The check must then read carol and refuse: a worker whose read and write were
    # separate autocommit statements would read alice before B's commit and overwrite carol after it.
    $holder = [IntPtr]::Zero
    try {
        Reset-WiringStore
        $path = New-WiringStoreDatabase
        Start-WiringStorage
        $script:UserMachineLinks = @(New-WiringLink 'alice' 'PC1')
        Assert-True (Queue-DomeniaLinkChanges) 'Console A : mise en file refusee'
        Invoke-WiringStorageBatch 'Console A, premier lot'
        Assert-True ((Get-WiringStoredLinks)['PC1'] -eq 'alice') 'Premier lot absent du disque'
        $script:UserMachineLinks = @(New-WiringLink 'dave' 'PC1' '2026-10-04 09:10:00')
        Assert-True (Queue-DomeniaLinkChanges) 'Console A : deuxieme mise en file refusee'
        Assert-True ($script:Persistence.Pending.Count -eq 1) 'Console A : un lien en file attendu'
        Assert-True (Wait-WiringStoreIdle) 'Console A : ecrivain precedent encore actif'
        # Commit delay: after the worker of A reaches BEGIN IMMEDIATE (bounded by the lock case: wait - 300 ms), and
        # never more than 180 ms after Start returns, so that the worker (busy_timeout 300 ms) never gives up before B
        # commits even with the pump overshoot (a few ms, short pumps below).
        $bound = -1.0
        if (@($script:D028LockWaits).Count) { $bound = [double](@($script:D028LockWaits) | Measure-Object -Maximum).Maximum - 300 }
        $commitAfter = 120.0
        if ($bound -ge 0) { $commitAfter = [Math]::Min(180.0,[Math]::Max(80.0,$bound + 30)) }
        $holder = Open-DomeniaDatabase -Path $path
        [void](Invoke-DomeniaDbExec 'BEGIN IMMEDIATE;' $holder)
        [void](Invoke-DomeniaDbExec "UPDATE user_machine_links SET user_login='carol',observed_at='2026-10-04 09:05:00' WHERE computer_key='PC1';" $holder)
        $script:Persistence.Next = [datetime]::MinValue
        $clock = [Diagnostics.Stopwatch]::StartNew()
        Start-DomeniaStorageWork
        $started = $clock.Elapsed.TotalMilliseconds
        Assert-True ([string]$script:Persistence.Job) ('Console A : aucun lot demarre. ' + [string]$script:Persistence.Fault)
        while ($clock.Elapsed.TotalMilliseconds -lt ($started + $commitAfter)) { Invoke-WiringPump ([int][Math]::Max(1,[Math]::Min(10,($started + $commitAfter) - $clock.Elapsed.TotalMilliseconds))) }
        [void](Invoke-DomeniaDbExec 'COMMIT;' $holder)
        $committed = $clock.Elapsed.TotalMilliseconds - $started
        Close-DomeniaDatabase $holder; $holder = [IntPtr]::Zero
        Assert-True (Wait-WiringCondition -Complete -TimeoutMs 30000 { -not [string]$script:Persistence.Job }) 'Console A : aucun rappel'
        $called = $clock.Elapsed.TotalMilliseconds - $started
        Assert-True ([int]$script:Persistence.Failures -eq 0) ('Console A en echec, verrou leve trop tard (' + [Math]::Round($committed) + ' ms) : ' + [string]$script:Persistence.Fault)
        $r = $script:StorageResults[$script:StorageResults.Count - 1]
        Assert-True ([bool]$r.Saved -and (@($r.Conflicts) -join ',') -ceq 'PC1') ('Conflits attendus PC1, obtenus : ' + (@($r.Conflicts) -join ','))
        Assert-True ((Get-WiringStoredLinks)['PC1'] -eq 'carol') 'La version de B, validee pendant l attente de A, a ete ecrasee'
        Assert-True ($script:Persistence.Conflicts.ContainsKey('PC1') -and [string]$script:LinkBaseline['PC1'].UserLogin -eq 'alice') 'Etat de conflit ou reference de A incorrects'
        $established = ($bound -ge 0 -and $bound -lt $committed)
        $script:CaseDetail = 'Verrou de B leve a ' + [Math]::Round($committed) + ' ms apres le depart du lot de A ; rappel a ' + [Math]::Round($called) + ' ms ; arrivee du worker sur BEGIN IMMEDIATE bornee a ' + $(if ($bound -ge 0) { [string][Math]::Round($bound) + ' ms (cas verrou)' } else { 'inconnue (cas verrou absent)' }) + ' ; entrelacement etabli : ' + $(if ($established) { 'oui' } else { 'non garanti' })
    } finally {
        if ($holder -ne [IntPtr]::Zero) { try { [void](Invoke-DomeniaDbExec 'ROLLBACK;' $holder) } catch { }; Close-DomeniaDatabase $holder }
        Stop-WiringStorage
    }
}


# ---------------------------------------------------------------- L09 : admission, pulsation, minuteurs, inactivite
Test-Case 'FI-03 : ecriture admise malgre 12 lectures detachees, lectures de fond en file' {
    foreach ($i in 1..12) { [void]$script:DetachedReadJobs.Add([pscustomobject]@{Id=('detache' + $i);Name='Detache';OperationId='TreeChildren';Handle=[pscustomobject]@{IsCompleted=$false};StopHandle=$null;PowerShell=$null;Runspace=$null;IsWrite=$false;Started=(Get-Date)}) }
    try {
        Initialize-AsyncEngine; Initialize-DomeniaEngineState
        $write = Get-DomeniaUiTaskAdmission -Class 'Write'
        Assert-True ([string]$write.Decision -eq 'Start') ('Ecriture refusee : ' + [string]$write.Decision)
        Assert-True ([string]$write.Reason -match 'partira') ('Message de place reservee absent : ' + [string]$write.Reason)
        $explicit = Start-WiringTask -Name 'Explicite'
        Assert-True ([string]$script:AsyncJobs[$explicit].State -eq 'Running') 'L action explicite n a pas pris sa place reservee'
        $background = Start-WiringTask -Name 'Fond' -TaskClass 'Background'
        Assert-True ([string]$script:AsyncJobs[$background].State -eq 'Queued') 'Lecture de fond lancee au-dela du plafond physique'
        $selection = Start-WiringTask -Name 'Selection' -TaskClass 'Selection'
        Assert-True ([string]$script:AsyncJobs[$selection].State -eq 'Queued') 'Lecture de selection lancee au-dela du plafond physique'
        $refused = ''
        try { [void](Get-DomeniaUiTaskAdmission -Class 'Write') } catch { $refused = $_.Exception.Message }
        Assert-True ($refused -eq '') ('Deuxieme demande d ecriture refusee avec 13 workers : ' + $refused)
    } finally { $script:DetachedReadJobs.Clear() }
}
Test-Case 'CO-02 : Annuler vise la recherche, jamais l enregistrement local' {
    $gateStore = New-WiringGate; $gateRead = New-WiringGate
    $script:TestOverrides['LocalStore'] = $script:TestBody
    $store = Start-UiTask -Name 'Enregistrement cache et liens' -OperationId 'LocalStore' -Code $script:TestBody -Payload ([pscustomobject]@{Name='Store';Gate=$gateStore.Name;SleepMs=0;Fail='';Computer=''}) -CallbackState ([pscustomobject]@{Tag='store'}) -SuccessHandler 'Complete-WiringTestUi' -ErrorHandler 'Fail-WiringTestUi' -NonCancellable
    Assert-True ([string]$script:LatestTaskId -eq '') ('Un enregistrement local est devenu la cible d Annuler : ' + [string]$script:LatestTaskId)
    Update-TaskUi -Force
    Assert-True ($script:Ctrl.PbTop.Visibility -ne 'Visible' -and $script:Ctrl.BtnCancelTask.Visibility -ne 'Visible') 'La barre et Annuler suivent un enregistrement local'
    $script:Statuses.Clear()
    Stop-LatestUiTask
    Assert-True ((@($script:Statuses) -join ' ') -match 'Enregistrement local : il se termine seul') ('Message inattendu : ' + (@($script:Statuses) -join ' | '))
    Assert-True (-not [bool]$script:AsyncJobs[$store].CancelRequested) 'Enregistrement local arrete'
    $read = Start-WiringTask -Name 'Recherche' -Gate $gateRead.Name
    Assert-True ([string]$script:LatestTaskId -eq $read) 'La recherche n est pas la cible d Annuler'
    Update-TaskUi -Force
    Assert-True ([string]$script:Ctrl.LblTaskElapsed.Text -match 'Recherche') ('Libelle de progression : ' + [string]$script:Ctrl.LblTaskElapsed.Text)
    Stop-LatestUiTask
    Assert-True ([bool]$script:AsyncJobs[$read].CancelRequested) 'Annuler n a pas arrete la recherche'
    Assert-True (-not [bool]$script:AsyncJobs[$store].CancelRequested) 'Annuler a arrete l enregistrement local'
}
Test-Case 'FI-05 : minuteur protege arrete apres 3 erreurs, une ligne par erreur' {
    $script:FailingTicks = 0
    $timer = New-DomeniaTimer -Owner 'Timer:TestPanne' -IntervalMs 30 -Tick { $script:FailingTicks++; throw 'panne de minuteur (test)' }
    Assert-True (@($script:DomeniaResources.Items | Where-Object { $_.Owner -eq 'Timer:TestPanne' }).Count -eq 1) 'Minuteur non enregistre'
    $timer.Start()
    [void](Wait-WiringCondition -TimeoutMs 5000 { -not [bool]$timer.IsEnabled })
    Invoke-WiringPump 200
    Assert-True ($script:FailingTicks -eq 3) ('Ticks en echec avant arret : ' + $script:FailingTicks)
    Assert-True ((-not [bool]$timer.IsEnabled) -and [bool]$timer.FaultStopped) 'Minuteur toujours actif apres 3 echecs'
    $lines = @($script:Logs | Where-Object { $_ -match 'Timer:TestPanne' })
    Assert-True ($lines.Count -eq 4) ('Lignes de journal : ' + $lines.Count + ' (3 erreurs et l arret attendus)')
    $epoch = New-DomeniaTimer -Owner 'Timer:TestEpoque' -IntervalMs 30 -SessionBound -Tick { $script:FailingTicks = -100 }
    $epoch.Start(); $script:SessionEpoch = [long]$script:SessionEpoch + 1
    Invoke-WiringPump 200
    Assert-True ((-not [bool]$epoch.IsEnabled) -and $script:FailingTicks -eq 3) 'Minuteur de session encore actif apres le changement d epoque'
}
Test-Case 'MO-05 : candidat d un fournisseur sature saute et garde en file, sans erreur' {
    $script:Config.Async.MaxThreads = 2; $script:Config.Async.ReservedForeground = 0
    $gateStore = New-WiringGate; $gateBusy = New-WiringGate
    [void](Start-WiringTask -OperationId 'LocalStore' -Name 'Enregistrement' -Gate $gateStore.Name -Tag 'store')
    [void](Start-WiringTask -OperationId 'TreeChildren' -Name 'Occupant' -Gate $gateBusy.Name -Tag 'busy')
    $cache = Start-WiringTask -OperationId 'LiveCache' -Name 'Cache' -Tag 'cache'
    $ping = Start-WiringTask -OperationId 'ComputerPing' -Name 'Ping' -Computer 'PC1' -TaskClass 'Background' -Tag 'ping'
    Assert-True ([string]$script:AsyncJobs[$cache].State -eq 'Queued' -and [string]$script:AsyncJobs[$ping].State -eq 'Queued') 'Les deux demandes doivent attendre une place'
    [void]$gateBusy.Handle.Set()
    Assert-True (Wait-WiringCondition -Complete { ($script:AsyncJobs.Contains($ping) -and ([string]$script:AsyncJobs[$ping].State -eq 'Running')) -or ((@(Get-WiringCalls) -match '\|Ping\|').Count -eq 1) }) 'Le candidat d un autre fournisseur n est pas parti'
    Assert-True ($script:AsyncJobs.Contains($cache) -and [string]$script:AsyncJobs[$cache].State -eq 'Queued') 'Le candidat du fournisseur sature a quitte la file'
    Assert-True (@($script:Callbacks | Where-Object { $_.Tag -eq 'cache' }).Count -eq 0) 'Une erreur a ete signalee pour un fournisseur seulement occupe'
    [void]$gateStore.Handle.Set()
    Assert-True (Wait-WiringCondition -Complete { @($script:Callbacks | Where-Object { $_.Tag -eq 'cache' -and $_.Kind -eq 'Success' }).Count -eq 1 }) 'Le candidat garde en file n est pas parti a la liberation du fournisseur'
}
Test-Case 'CD-12 : erreur d une tache analysee une seule fois et transmise aux rappels' {
    $analyses = @{N=0}
    $realStructured = ${function:Get-DomeniaStructuredError}
    Set-Item function:script:Get-DomeniaStructuredError -Value { $analyses.N++; & $realStructured @args }.GetNewClosure()
    $script:SeenErrorInfo = $null
    Set-Item function:script:Fail-WiringTestUi -Value { param($Message,$State) $script:SeenErrorInfo = Get-DomeniaMember $script:AccessCurrentJob 'ErrorInfo' $null; $script:Callbacks.Add([pscustomobject]@{Kind='Error';Tag=[string]$State.Tag;Result=[string]$Message}) }
    try {
        [void](Start-WiringTask -OperationId 'TreeChildren' -Name 'Panne' -Fail '[DOMENIA:AccessDenied;5;0x80070005] Acces refuse (test).')
        Assert-True (Wait-WiringCondition -Complete { $script:Callbacks.Count -eq 1 }) 'Erreur non remontee'
        Assert-True ($analyses.N -eq 1) ('Analyses de l erreur : ' + $analyses.N)
        Assert-True ($null -ne $script:SeenErrorInfo -and [string]$script:SeenErrorInfo.Category -eq 'AccessDenied') 'Le rappel ne recoit pas l erreur analysee'
    } finally {
        Set-Item function:script:Get-DomeniaStructuredError -Value $realStructured
        Set-Item function:script:Fail-WiringTestUi -Value { param($Message,$State) $script:Callbacks.Add([pscustomobject]@{Kind='Error';Tag=[string]$State.Tag;Result=[string]$Message}) }
    }
}
Test-Case 'UX-30 : accueil recalcule fenetre inactive mais visible, suspendu fenetre reduite' {
    $window = $script:Main.Window
    $script:Ctrl['WorkspaceTabs'].SelectedItem = $script:Ctrl['TabDashboard']
    $script:DomeniaIdlePolicyWired = $false
    Initialize-DomeniaIdlePolicy -Window $window
    $flags = [Reflection.BindingFlags]'NonPublic,Instance'
    [Windows.Window].GetMethod('OnDeactivated',$flags).Invoke($window,@([EventArgs]::Empty))
    Assert-True ([bool]$script:DomeniaIdlePolicy.Visible -and -not [bool]$script:DomeniaIdlePolicy.AllowBackgroundRefresh) 'Politique inattendue fenetre inactive'
    $script:DashboardCalls = 0
    Request-DomeniaDashboardRefresh
    Assert-True (Wait-WiringCondition -TimeoutMs 3000 { $script:DashboardCalls -eq 1 }) ('Accueil non recalcule fenetre inactive mais visible : ' + $script:DashboardCalls)
    $window.WindowState = 'Minimized'
    try {
        [Windows.Window].GetMethod('OnStateChanged',$flags).Invoke($window,@([EventArgs]::Empty))
        Assert-True ([bool]$script:DomeniaWindowSuspended) 'Pulsation non suspendue fenetre reduite'
        $script:DashboardCalls = 0; $script:DashboardDirty = $false
        Request-DomeniaDashboardRefresh
        Invoke-WiringPump 400
        Assert-True ($script:DashboardCalls -eq 0 -and [bool]$script:DashboardDirty) 'Accueil recalcule fenetre reduite'
    } finally {
        $window.WindowState = 'Normal'
        [Windows.Window].GetMethod('OnStateChanged',$flags).Invoke($window,@([EventArgs]::Empty))
    }
    Assert-True (-not [bool]$script:DomeniaWindowSuspended) 'Pulsation encore suspendue apres restauration'
}
Test-Case 'PF-06 : moteur au repos, minuteur du moteur arrete puis relance par une tache' {
    [void](Start-WiringTask -Name 'Courte')
    Assert-True (Wait-WiringCondition -Complete { $script:AsyncJobs.Count -eq 0 }) 'Tache non terminee'
    Complete-UiTasks
    Assert-True (-not [bool]$script:AsyncTimer.IsEnabled) 'Minuteur du moteur actif sans tache'
    [void](Start-WiringTask -Name 'Relance' -Gate (New-WiringGate).Name)
    Assert-True ([bool]$script:AsyncTimer.IsEnabled) 'Une nouvelle tache ne relance pas le minuteur du moteur'
}
Test-Case 'PF-04 : plusieurs demandes en file partent dans le meme tick, par priorite' {
    $script:Config.Async.MaxThreads = 1
    $gate = New-WiringGate
    $first = Start-WiringTask -Name 'A' -Gate $gate.Name
    Assert-True (Wait-WiringCondition { (Get-WiringCalls).Count -eq 1 }) 'A n a pas demarre'
    $ids = @(); foreach ($i in 1..3) { $ids += Start-WiringTask -Name ('Fond' + $i) -TaskClass 'Background' -Gate $gate.Name }
    $explicit = Start-WiringTask -Name 'Explicite' -Gate $gate.Name
    Assert-True (@($script:AsyncJobs.Values | Where-Object { [string]$_.State -eq 'Queued' }).Count -eq 4) 'Quatre demandes attendues en file'
    # Two places freed and a budget large enough for the VM: the proof is structural. In ONE tick the explicit action
    # (queued last) and one background read start; the other background reads wait for a place.
    $script:Config.Async.MaxThreads = 2; $script:Config.Async.ReservedForeground = 0; $script:Config.Async.TickBudgetMs = 250
    [void]$gate.Handle.Reset()
    [void]$gate.Handle.Set()
    Assert-True (Wait-WiringCondition { [bool]$script:AsyncJobs[$first].Handle.IsCompleted }) 'A non termine'
    [void]$gate.Handle.Reset()
    Complete-UiTasks
    $states = @($explicit,$ids[0],$ids[1],$ids[2] | ForEach-Object { [string]$script:AsyncJobs[$_].State })
    Assert-True ($states[0] -eq 'Running' -and $states[1] -eq 'Running') ('Deux departs attendus dans le meme tick : ' + ($states -join ','))
    Assert-True ($states[2] -eq 'Queued' -and $states[3] -eq 'Queued') ('Ordre ou plafond non respectes : ' + ($states -join ','))
    [void]$gate.Handle.Set()
}
Test-Case 'PF-23 : partie statique du contexte en cache, operation locale sans secret' {
    $script:Conn.UseCredential = $true
    $script:Conn.Credential = New-Object System.Management.Automation.PSCredential -ArgumentList @('EXAMPLE\lecteur',(New-Object System.Security.SecureString))
    $first = Get-WorkerContext -OperationId 'TreeChildren'
    $cached = $script:WorkerContextConfig
    $local = Get-WorkerContext -OperationId 'LocalStore'
    Assert-True ($null -ne $cached -and [object]::ReferenceEquals($cached,$script:WorkerContextConfig)) 'Partie statique reconstruite pour chaque operation'
    Assert-True ($null -ne $first.Credential) 'Le compte AD manque a une lecture de l annuaire'
    Assert-True ($null -eq $local.Credential -and $null -eq $local.MachineCredential -and $null -eq $local.RemoteAdminCredential) 'Une operation locale recoit un secret'
    $script:Config = New-DefaultConfig
    [void](Get-WorkerContext -OperationId 'TreeChildren')
    Assert-True (-not [object]::ReferenceEquals($cached,$script:WorkerContextConfig)) 'Nouvelle configuration ignoree par le cache'
}
Test-Case 'PF-05 : lectures frequentes servies par un pool, RunspaceOpen mesure' {
    $script:LiveWorkerPools = @{}
    foreach ($i in 1..3) {
        [void](Start-WiringTask -OperationId 'OpenAdObject' -Name ('Objet ' + $i))
        Assert-True (Wait-WiringCondition -Complete { $script:AsyncJobs.Count -eq 0 }) ('Lecture ' + $i + ' non terminee')
    }
    Assert-True ($script:LiveWorkerPools.ContainsKey('OpenAdObject')) 'OpenAdObject sans pool'
    $summary = Get-DomeniaRuntimeMetricSummary -Provenance 'Dispatcher' -Prefix 'RunspaceOpen:OpenAdObject'
    Assert-True ([int]$summary.Count -eq 3) ('Mesures RunspaceOpen : ' + $summary.Count)
    $script:CaseDetail = 'RunspaceOpen OpenAdObject : p50 ' + $summary.P50 + ' ms, p95 ' + $summary.P95 + ' ms, max ' + $summary.Max + ' ms (premiere ouverture du pool comprise ; mesure).'
}
Test-Case 'MO-03 : minuterie de sauvegarde armee a la mise en file, arretee file vide, ordre conserve' {
    try {
        Reset-WiringStore
        $path = New-WiringStoreDatabase
        $script:Persistence = $null
        Initialize-DomeniaPersistence
        Assert-True (-not [bool]$script:Persistence.Timer.IsEnabled) 'Minuterie de sauvegarde active file vide'
        Assert-True ($script:Persistence.Pending -is [Collections.Specialized.OrderedDictionary]) 'File de sauvegarde non ordonnee'
        # First queued, first written: three rows keep their order in the queue (no tick runs inside this block).
        foreach ($n in @('c','a','b')) { Assert-True (Add-DomeniaIndexPersistence -Row ([pscustomobject]@{Guid=('guid-' + $n);DN=('CN=' + $n + ',DC=example,DC=invalid')})) ('Ligne ' + $n + ' refusee') }
        Assert-True ([bool]$script:Persistence.Timer.IsEnabled) 'Minuterie non armee a la mise en file'
        Assert-True (((@($script:Persistence.Pending.Values) | ForEach-Object { [string]$_.Row.Guid }) -join ',') -ceq 'guid-c,guid-a,guid-b') 'Ordre de la file perdu'
        $script:Persistence.Pending.Clear(); $script:Persistence.Timer.Stop()
        $script:UserMachineLinks = @((New-WiringLink 'alice' 'PC1'),(New-WiringLink 'bob' 'PC2'))
        Assert-True (Queue-DomeniaLinkChanges) 'Mise en file refusee'
        Assert-True ([bool]$script:Persistence.Timer.IsEnabled -and $script:Persistence.Pending.Count -eq 2) 'Minuterie non armee pour les liens'
        Assert-True (Wait-WiringCondition -Complete -TimeoutMs 30000 { $script:Persistence.Pending.Count -eq 0 -and -not [string]$script:Persistence.Job -and -not [bool]$script:Persistence.Timer.IsEnabled }) ('Minuterie encore active apres la sauvegarde. ' + [string]$script:Persistence.Fault)
        Assert-True ((Get-WiringStoredLinks)['PC2'] -eq 'bob') 'Lot non enregistre'
    } finally { Stop-WiringStorage }
}

Test-Case 'UX-32 / PF-12 : panneau Operations sous le bouton, lignes mises a jour sur place, Arreter par ligne' {
    if ($null -eq ('Domenia.Live.OperationRow' -as [type])) { Add-Type -Path (Join-Path $modules 'Domenia-Live.Types.cs') -ErrorAction Stop }
    $script:ExperienceInitialized = $true; $script:OperationsPanel = $null
    $layer = $script:Main.Window.FindName('DomeniaDialogLayer')
    try {
        $gate = New-WiringGate
        $id = Start-WiringTask -Name 'Lecture suivie' -Gate $gate.Name
        Assert-True (Show-DomeniaOperationsPanel) 'Panneau non ouvert'
        Assert-True ($layer.Visibility -eq 'Visible' -and $layer.Children.Contains($script:OperationsPanel.View)) 'Panneau absent de DomeniaDialogLayer'
        Assert-True ($null -eq $script:Main.Window.FindName('TabExperience')) 'TabExperience existe encore'
        $grid = Get-DomeniaControl 'DgSuiteActivity'
        $source = $grid.ItemsSource
        Assert-True (@($grid.Items).Count -eq 1) ('Lignes : ' + @($grid.Items).Count)
        $row = @($grid.Items)[0]
        Assert-True ($row -is [Domenia.Live.OperationRow] -and $row.Id -eq $id -and $row.CanCancel) 'Ligne non typee ou non annulable'
        $grid.SelectedItem = $row
        $script:AsyncJobs[$id].Started = (Get-Date).AddSeconds(-75)
        Update-DomeniaExperienceActivity
        Assert-True ([object]::ReferenceEquals($source,$grid.ItemsSource) -and [object]::ReferenceEquals($row,@($grid.Items)[0])) 'Grille remplacee au lieu d une mise a jour sur place'
        Assert-True ([string]$row.Duration -eq '01:15') ('Duree non mise a jour sur place : ' + [string]$row.Duration)
        Assert-True ([object]::ReferenceEquals($grid.SelectedItem,$row)) 'Selection perdue'
        Assert-True ([string](Get-DomeniaControl 'LblOperationsHealth').Text -match 'Mémoire') 'Zone Sante vide'
        Stop-DomeniaOperationRow -Id $id
        Assert-True ([bool]$script:AsyncJobs[$id].CancelRequested) 'Arreter n a pas demande l arret de la ligne'
        Assert-True ([string]$row.State -eq 'Arrêt demandé' -and -not $row.CanCancel) ('Etat de ligne : ' + [string]$row.State)
        Hide-DomeniaOperationsPanel
        Assert-True ($layer.Visibility -eq 'Collapsed' -and -not (Test-DomeniaOperationsPanelOpen)) 'Panneau non ferme'
    } finally {
        if ($null -ne $script:OperationsPanel) { try { Hide-DomeniaOperationsPanel } catch { }; try { $script:OperationsPanel.Timer.Stop() } catch { } }
        $script:OperationsPanel = $null; $script:ExperienceInitialized = $false
        $layer.Children.Clear(); $layer.Visibility = 'Collapsed'
    }
}
# ---------------------------------------------------------------- report
try { Stop-WiringJobs } catch { }
try { Stop-WiringStorage } catch { }
foreach ($root in @($script:StoreRoots)) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
$passed = @($checks | Where-Object { $_.Status -eq 'Passed' }).Count
$failed = @($checks | Where-Object { $_.Status -eq 'Failed' }).Count
if (-not $ReportPath) { $ReportPath = Join-Path ([IO.Path]::GetTempPath()) ('Domenia-wiring-moteur-' + [guid]::NewGuid().ToString('N') + '.json') }
$report = [ordered]@{
    UiBlockingAudit = $script:UiBlockingAudit
    Kind='WiringMoteur';Host=$PSVersionTable.PSVersion.ToString();NativeWindowsPowerShell51=$native;Wpf=$true;MockedNetwork=$true;LiveAD=$false
    Points=@('D002','D003','D011','D014','D015','D016','D017','D018','D019','D020','D028','D089')
    Passed=$passed;Failed=$failed;Complete=($failed -eq 0 -and $passed -gt 0);Tests=$checks.ToArray()
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report | ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
if (-not $Quiet) {
    Write-Host ("$passed reussis, $failed en echec. Rapport : " + $ReportPath)
    $checks | Where-Object { $_.Status -eq 'Failed' } | ForEach-Object { Write-Host ('  ECHEC ' + $_.Name + ' : ' + $_.Detail) }
}
if ($failed -gt 0) { exit 1 }
exit 0
