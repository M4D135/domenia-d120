#requires -Version 5.1
# Wiring tests for cache lot (D025, D028).
# Real rule modules are dot-sourced; real UI/core functions are extracted by AST; boundary doubles.
# Windows PowerShell 5.1 x64 STA only.
[CmdletBinding()]
param([string]$ReportPath = '', [switch]$Quiet)
$ErrorActionPreference = 'Stop'
$wad = Split-Path -Parent $PSScriptRoot
$dev = Split-Path -Parent $wad
$modules = Join-Path $wad 'modules'
$checks = [Collections.Generic.List[object]]::new()
$native = (($PSVersionTable.PSEdition -eq 'Desktop') -and ($PSVersionTable.PSVersion.Major -eq 5) -and ($PSVersionTable.PSVersion.Minor -eq 1) -and [Environment]::Is64BitProcess)
if (-not $native) { throw 'Windows PowerShell 5.1 x64 requis : une execution sous un autre moteur n est pas une preuve.' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Utiliser powershell.exe -STA.' }
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
# Production workers receive the pinned native reader through the closed loader. This AST-only harness must
# load the same assembly explicitly, rather than silently replacing its identity/observation implementation.
if($null -eq ('Domenia.Native.ObservationIdentityReader' -as [type])){Add-Type -Path (Join-Path $modules 'Domenia.Native.dll') -ErrorAction Stop}

function Assert-True { param($Value,[string]$Why = 'Assertion fausse') if (-not [bool]$Value) { throw $Why } }
function Assert-False { param($Value,[string]$Why = 'Assertion fausse') if ([bool]$Value) { throw $Why } }
function Assert-Equal { param($Expected,$Actual,[string]$Why = 'Valeur inattendue') if ([string]$Expected -cne [string]$Actual) { throw ($Why + ' attendu=' + [string]$Expected + ' obtenu=' + [string]$Actual) } }

function Get-FunctionTextFromFile {
    param([string]$Path,[string]$Name)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if (@($errors).Count) { throw ('Syntaxe ' + $Path + ' : ' + $errors[0].Message) }
    $nodes = @($ast.FindAll({ param($n) (($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq $Name)) },$true))
    if (@($nodes).Count -lt 1) { throw ('Fonction introuvable : ' + $Name + ' dans ' + $Path) }
    return $nodes[0].Extent.Text
}
function Import-FunctionFromFile {
    param([string]$Path,[string]$Name)
    . ([scriptblock]::Create((Get-FunctionTextFromFile $Path $Name)))
}

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
    param([scriptblock]$Condition,[int]$TimeoutMs = 5000)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMs) {
        if (& $Condition) { return $true }
        Invoke-WiringPump 30
    }
    return [bool](& $Condition)
}
function Stop-TestTimers {
    if ($null -ne $script:Persistence) {
        if ($null -ne $script:Persistence.Timer) { try { $script:Persistence.Timer.Stop() } catch { } }
        if ($null -ne $script:Persistence.LinkRequestTimer) { try { $script:Persistence.LinkRequestTimer.Stop() } catch { } }
    }
}

# Base doubles.
function Register-DomeniaOwnedTimer { param([Parameter(Mandatory=$true)][string]$Owner,$Timer) return 0 }
$script:Window = New-Object PSObject
$script:Window | Add-Member ScriptMethod Add_Closed { param($handler) }
function Start-DomeniaStorageWork { }
function Set-Status { param($Text,$Level) $script:Statuses.Add([string]$Text) }
function Write-AppLog { param($Text,$Level) $script:Logs.Add([string]$Text) }
function Add-DomeniaUiLog { param($Area,$Text,$Level) $script:Logs.Add([string]$Text) }
function Normalize-LinkComputer { param($Computer) return ([string]$Computer).Split('.')[0].ToUpperInvariant() }
function Normalize-LinkUser { param($User) return ([string]$User).ToLowerInvariant() }
function ConvertTo-DomeniaCanonicalLinks { param($Links) return @($Links) }
function ConvertTo-DomeniaLinkRecord { param($Link) return [pscustomobject]@{Computer=[string]$Link.Computer;UserLogin=[string]$Link.UserLogin;Source=[string]$Link.Source} }
function Get-DomeniaLinkFingerprint { param($Record) if ($null -eq $Record) { return '' }; return ([string]$Record.UserLogin).ToLowerInvariant() }
function Rebuild-UserMachineLinkIndex { }
function Refresh-LinkGrid { }
function Refresh-AssociationContext { param([switch]$SkipResultRefresh) }
function Get-DomeniaFeatureFlag { param([string]$Name,$Default=$true) return [bool]$script:FeatureFlagValue }
function Add-DomeniaRelation { param($Relation,[switch]$NoSave,[switch]$Quiet) $script:RelationCalls++; return $true }
function Get-ExistingLinkForComputer { param($Computer) return $script:ExistingLinkForComputer }
function Set-DomeniaLiveRowValue {
    param($Object,$Name,$Value)
    if ($null -eq $Object) { return }
    if ($Object -is [System.Collections.IDictionary]) { $Object[$Name] = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}

# Real rule modules.
# FI-05 / PF-06: Engine.UI holds the protected timer factory used by the persistence and the progressive search.
foreach ($file in @('Domenia-Common.Model.ps1','Domenia-Cache.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Engine.UI.ps1')) {
    $path = Join-Path $modules $file
    if (-not [IO.File]::Exists($path)) { throw ('Module absent : ' + $file) }
    . $path
}
# The real Common.Model defines Get-DomeniaFeatureFlag: the test double must win, so it is defined after the modules.
function Get-DomeniaFeatureFlag { param([string]$Name,$Default=$true) return [bool]$script:FeatureFlagValue }

$storageUi = Join-Path $modules 'Domenia-Storage.UI.ps1'
$liveUi = Join-Path $modules 'Domenia-Live.UI.ps1'
$liveModel = Join-Path $modules 'Domenia-Live.Model.ps1'
$selectionUi = Join-Path $modules 'Domenia-Selection.UI.ps1'
$continuityUi = Join-Path $modules 'Domenia-Continuity.UI.ps1'
$core = Join-Path $wad 'Domenia-Core.ps1'
$loader = Join-Path $wad 'Domenia-Modules.ps1'
if (-not [IO.File]::Exists($loader)) { $loader = Join-Path $modules 'Domenia-Modules.ps1' }
$audit = Join-Path $dev 'tools/audit_preload.py'
foreach ($path in @($storageUi,$liveUi,$liveModel,$selectionUi,$continuityUi,$core,$loader,$audit)) {
    if (-not [IO.File]::Exists($path)) { throw ('Fichier absent : ' + $path) }
}

. ([scriptblock]::Create((Get-FunctionTextFromFile $storageUi 'Initialize-DomeniaPersistence')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $storageUi 'Queue-DomeniaLinkChanges')))
# Queue-DomeniaLinkChanges reveille le minuteur de sauvegarde a chaque lot pose : la vraie fonction, pas un
# bouchon. Elle ne fait que demarrer Persistence.Timer (Domenia-Storage.UI.ps1) et ne touche aucun etat asserti.
. ([scriptblock]::Create((Get-FunctionTextFromFile $storageUi 'Request-DomeniaStorageWork')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $storageUi 'Request-DomeniaLinkPersistence')))
$script:QueueOriginal = (Get-Item function:Queue-DomeniaLinkChanges).ScriptBlock
$script:RequestOriginal = (Get-Item function:Request-DomeniaLinkPersistence).ScriptBlock
. ([scriptblock]::Create((Get-FunctionTextFromFile $liveUi 'Merge-DomeniaLiveLinkMemory')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $liveModel 'Get-DomeniaLiveCacheCode')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $selectionUi 'Get-DomeniaObjectCacheKey')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $continuityUi 'Invoke-DomeniaObjectChanges')))
# L03 (FI-21): the GUID invalidation is shared with 'Relire l objet' (Refresh-SelectedObject).
. ([scriptblock]::Create((Get-FunctionTextFromFile $continuityUi 'Clear-DomeniaVisitCacheForObject')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $core 'Get-VisitCacheValue')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $core 'Set-VisitCacheValue')))

function Reset-TestState {
    Stop-TestTimers
    $script:CaseDetail = ''
    $script:Statuses = New-Object 'System.Collections.Generic.List[string]'
    $script:Logs = New-Object 'System.Collections.Generic.List[string]'
    $script:Persistence = $null
    $script:LinkBaseline = @{}
    $script:UserMachineLinks = @()
    $script:LinkByComputer = @{}
    $script:LinksByUser = @{}
    $script:LinkIndexCount = 0
    $script:LinkIndexGeneration = 0
    $script:DatabaseScopedPath = 'test-scope.db'
    $script:SessionEpoch = [long]1
    $script:FeatureFlagValue = $true
    $script:ExistingLinkForComputer = $null
    $script:QueueCalls = 0
    $script:RelationCalls = 0
    $script:RequestCalls = 0
    $script:VisitCacheCalls = 0
    $script:StartUiCalls = 0
    $script:CompleteUiCacheKeys = New-Object 'System.Collections.Generic.List[string]'
    $script:VisitCache = @{}
    $script:Conn = [pscustomobject]@{Domain='example.invalid'}
    $script:CurrentObjectRequestId = ''
    $script:CurrentObjectRequestState = $null
    $script:SelectedObject = $null
    $script:SelectionLoad = $null
    $script:QueueSpyResult = $true
    $script:QueueSpyMore = $false
    $script:QueueSpyBusy = $false
    Set-Item function:script:Queue-DomeniaLinkChanges $script:QueueOriginal
    Set-Item function:script:Request-DomeniaLinkPersistence $script:RequestOriginal
    # Step C (D024, D026, D027)
    $script:PresenceCache=@{}
    $script:CacheStats=[pscustomobject]@{Hits=0;Misses=0;Writes=0;Evictions=0;Errors=0}
    $script:AsyncJobs=@{}
    $script:SelectedObjectGeneration=0
    $script:IndexRows=@()
    $script:IndexInfo=$null
    $script:IndexDbCount=0
    $script:SaveIndexCalls=0
    $script:UpdateIndexCalls=0
    $script:Reconcile=[pscustomobject]@{Job='';Events=[Collections.Generic.Queue[object]]::new();Checkpoint=$null}
    $script:Live=$null
    $script:StartUiCalls=0
    $script:StartUiOperations=[Collections.Generic.List[string]]::new()
    $script:QueueSpyRow=$null
    $script:TestGrid=$null
    $script:TestRow=$null
    $script:GlobalSearchGeneration=1
    $script:DemoMode=$false
    $script:AsyncEngineClosing=$false
    $script:ActiveWriteTaskId=''
    $script:WriteState='Known'
    $script:AccessState=$null
    $script:DirectoryCredentialFaulted=$false
    $script:ShowingCachedObject=$false
    $script:ShowingCachedObjectCreated=$null
    $script:RegisteredFailure=''
    $script:ObservedTimeCalls=0
    $script:FreshnessCalls=0
}
function Test-Case {
    param([string]$Name,[scriptblock]$Body)
    try {
        Reset-TestState
        & $Body | Out-Null
        $checks.Add([pscustomobject]@{Name=$Name;Status='Passed';Detail=[string]$script:CaseDetail})
    } catch {
        $checks.Add([pscustomobject]@{Name=$Name;Status='Failed';Detail=($_.Exception.Message + ' @ ' + $_.ScriptStackTrace)})
    } finally {
        Stop-TestTimers
    }
}

Test-Case 'D028 : LiveCache ne contient plus le second ecrivain user_machine_links' {
    $code = Get-DomeniaLiveCacheCode
    Assert-True ($code.IndexOf('INSERT OR REPLACE INTO user_machine_links',[StringComparison]::OrdinalIgnoreCase) -lt 0) 'Le worker LiveCache ecrit encore user_machine_links.'
    Assert-True ($code.IndexOf('adcc_live_observations',[StringComparison]::OrdinalIgnoreCase) -ge 0) 'Le worker LiveCache ne persiste plus les observations Live.'
}

Test-Case 'D028 : Merge-DomeniaLiveLinkMemory (RelationsSymmetry) demande la persistance et ne passe pas par l ancien chemin' {
    Set-Item function:script:Request-DomeniaLinkPersistence { $script:RequestCalls++ }
    $script:FeatureFlagValue = $true
    $obs = [pscustomobject]@{
        Outcome='Observed'; Computer='PC-1.example.invalid'; LinkUser='User1'; UserDn='CN=User1,OU=Users,DC=example,DC=invalid'
        Guid='11111111-1111-1111-1111-111111111111'; UserGuid='22222222-2222-2222-2222-222222222222'
        ObservedUtc='2026-01-01T10:00:00Z'
    }
    Merge-DomeniaLiveLinkMemory $obs
    Assert-Equal 1 $script:RequestCalls
    Assert-Equal 1 $script:RelationCalls
    Assert-Equal 0 @($script:UserMachineLinks).Count
}

Test-Case 'D028 / CD-06 : Merge-DomeniaLiveLinkMemory ignore l ancien interrupteur et passe toujours par la regle de relation' {
    # CD-06 (L04): the RC1.10.7 fallback (overwrite of the workstation row, fixed score) is removed; the switch is no longer read.
    Set-Item function:script:Request-DomeniaLinkPersistence { $script:RequestCalls++ }
    $script:FeatureFlagValue = $false
    $obs = [pscustomobject]@{
        Outcome='Observed'; Computer='PC-2.example.invalid'; LinkUser='User2'; UserDn='CN=User2,OU=Users,DC=example,DC=invalid'
        Guid='33333333-3333-3333-3333-333333333333'; UserGuid='44444444-4444-4444-4444-444444444444'
        ObservedUtc='2026-01-01T10:00:00Z'
    }
    Merge-DomeniaLiveLinkMemory $obs
    Assert-Equal 1 $script:RequestCalls
    Assert-Equal 1 $script:RelationCalls
    Assert-Equal 0 @($script:UserMachineLinks).Count
}

Test-Case 'D028 : parcours explicite sans parametre refuse toujours plus de 64 ecarts' {
    $links=@(); for($i=1;$i -le 70;$i++){$links += [pscustomobject]@{Computer=('PC-{0:d2}' -f $i);UserLogin=('user{0:d2}' -f $i);Source='Console'}}
    $script:UserMachineLinks=$links
    $script:LinkBaseline=@{}
    $ok=Queue-DomeniaLinkChanges
    Assert-False $ok
    Assert-Equal 0 $script:Persistence.Pending.Count
    Assert-Equal 1 $script:Statuses.Count
    Assert-True ($script:Statuses[0] -match 'Trop')
}

Test-Case 'D028 : Queue-DomeniaLinkChanges -Quiet est silencieux quand LinkBusy' {
    Initialize-DomeniaPersistence
    $script:Persistence.LinkBusy=$true
    $ok=Queue-DomeniaLinkChanges -Quiet
    Assert-False $ok
    Assert-Equal 0 $script:Statuses.Count
}

Test-Case 'D028 : 70 ecarts sont mis en file par lots de 64 puis 6' {
    $links=@(); for($i=1;$i -le 70;$i++){$links += [pscustomobject]@{Computer=('PC-{0:d2}' -f $i);UserLogin=('user{0:d2}' -f $i);Source='Console'}}
    $script:UserMachineLinks=$links
    $script:LinkBaseline=@{}
    $ok=Queue-DomeniaLinkChanges -Quiet -MaxItems 64
    Assert-True $ok
    Assert-Equal 64 $script:Persistence.Pending.Count
    Assert-True $script:Persistence.LinkBusy
    Assert-True $script:Persistence.LinkPersistenceMore
    Assert-Equal 0 $script:Statuses.Count
    foreach($item in @($script:Persistence.Pending.Values)){$script:LinkBaseline[$item.Key]=$item.Row}
    $script:Persistence.Pending.Clear()
    $script:Persistence.LinkBusy=$false
    $ok2=Queue-DomeniaLinkChanges -Quiet -MaxItems 64
    Assert-True $ok2
    Assert-Equal 6 $script:Persistence.Pending.Count
    Assert-False $script:Persistence.LinkPersistenceMore
}

Test-Case 'D028 : N observations produisent une seule mise en file apres l echeance' {
    Set-Item function:script:Queue-DomeniaLinkChanges { param([switch]$Quiet,[int]$MaxItems=0) $script:QueueCalls++; return $true }
    Request-DomeniaLinkPersistence
    Request-DomeniaLinkPersistence
    Request-DomeniaLinkPersistence
    Request-DomeniaLinkPersistence
    Request-DomeniaLinkPersistence
    Assert-Equal 0 $script:QueueCalls
    Assert-True (Wait-WiringCondition { $script:QueueCalls -gt 0 } 3000) 'Aucune mise en file apres l echeance.'
    Assert-Equal 1 $script:QueueCalls
}

Test-Case 'D028 : LinkBusy provoque un rearmement sans statut' {
    Set-Item function:script:Queue-DomeniaLinkChanges { param([switch]$Quiet,[int]$MaxItems=0) $script:QueueCalls++; return $true }
    Initialize-DomeniaPersistence
    $script:Persistence.LinkBusy=$true
    Request-DomeniaLinkPersistence
    Invoke-WiringPump 1700
    Assert-Equal 0 $script:QueueCalls
    Assert-Equal 0 $script:Statuses.Count
    Assert-True $script:Persistence.LinkRequestTimer.IsEnabled
}

Test-Case 'D028 : un lot partiel rearment le minuteur' {
    Set-Item function:script:Queue-DomeniaLinkChanges { param([switch]$Quiet,[int]$MaxItems=0) $script:QueueCalls++; $script:Persistence.LinkPersistenceMore=$true; return $true }
    Initialize-DomeniaPersistence
    $script:Persistence.LinkBusy=$false
    Request-DomeniaLinkPersistence
    Assert-True (Wait-WiringCondition { $script:QueueCalls -gt 0 } 3000)
    Assert-Equal 1 $script:QueueCalls
    Assert-True $script:Persistence.LinkRequestTimer.IsEnabled
}

Test-Case 'D025 : Get-DomeniaObjectCacheKey delegue a cache-v3 et refuse une cle sans GUID' {
    $guid='11111111-1111-1111-1111-111111111111'
    $key=Get-DomeniaObjectCacheKey -DN 'CN=PC1,OU=Workstations,DC=example,DC=invalid' -Guid $guid -Identity 'EXAMPLE\reader'
    Assert-True ($key.StartsWith('cache-v3|'))
    Assert-True ($key.IndexOf($guid.ToLowerInvariant(),[StringComparison]::OrdinalIgnoreCase) -ge 0)
    Assert-False ($key.IndexOf('cn=pc1',[StringComparison]::OrdinalIgnoreCase) -ge 0)
    Assert-False ($key.IndexOf('reader',[StringComparison]::OrdinalIgnoreCase) -ge 0)
    Assert-False ($key.IndexOf('object-v2|',[StringComparison]::OrdinalIgnoreCase) -ge 0)
    Assert-Equal '' (Get-DomeniaObjectCacheKey -DN 'CN=PC1,DC=example,DC=invalid' -Guid '' -Identity 'EXAMPLE\reader')
}

Test-Case 'D025 : une cle vide ne lit ni n ecrit le cache de visite (garde centrale)' {
    function Get-CfgValue { param($Section,$Key,$Default) return $Default }
    $script:CacheStats = [pscustomobject]@{Hits=0;Misses=0;Writes=0;Evictions=0;Errors=0}
    Set-VisitCacheValue -Key '' -Value 'objet'
    Set-VisitCacheValue -Key '   ' -Value 'objet'
    Assert-Equal 0 $script:VisitCache.Count 'Une cle vide a ete ecrite dans le cache.'
    Assert-Equal 0 $script:CacheStats.Writes
    Assert-True ($null -eq (Get-VisitCacheValue -Key '')) 'Une cle vide a renvoye une valeur.'
    $key = Get-DomeniaObjectCacheKey -DN 'CN=PC1,DC=example,DC=invalid' -Guid '11111111-1111-1111-1111-111111111111' -Identity 'EXAMPLE\reader'
    Set-VisitCacheValue -Key $key -Value 'objet'
    Assert-Equal 'objet' (Get-VisitCacheValue -Key $key) 'Une cle cache-v3 valide doit rester utilisable.'
}

Test-Case 'D025 : domaine de la cle repris de la base DN, sinon inconnu, jamais vide' {
    $g = '11111111-1111-1111-1111-111111111111'
    $script:Conn = [pscustomobject]@{Domain='';BaseDn='DC=Example,DC=Invalid'}
    Assert-True ((Get-DomeniaObjectCacheKey -DN 'CN=PC1,DC=example,DC=invalid' -Guid $g -Identity 'EXAMPLE\reader').StartsWith('cache-v3|example.invalid|')) 'Domaine non repris de la base DN.'
    $script:Conn = [pscustomobject]@{Domain=''}
    Assert-True ((Get-DomeniaObjectCacheKey -DN 'CN=PC1,DC=example,DC=invalid' -Guid $g -Identity 'EXAMPLE\reader').StartsWith('cache-v3|unknown|')) 'Repli inconnu absent.'
}

Test-Case 'D025 : Invoke-DomeniaObjectChanges invalide par GUID quand la ligne porte un GUID' {
    function Test-DomeniaLiveSearchActive { return $true }
    function Test-DomeniaAccessBusyWrite { return $false }
    function Get-DomeniaControl { param([string]$Name) return $script:TestGrid }
    function ConvertTo-DomeniaLiveSnapshot { param($Row) return [pscustomobject]@{DN=[string]$Row.DN;Guid=[string]$Row.Guid;Name='PC1'} }
    function Get-DomeniaLiveObjectKey { param($Row) return ([string]$Row.DN).ToLowerInvariant() }
    $guid='11111111-1111-1111-1111-111111111111'
    $dn='CN=PC1,OU=Workstations,DC=example,DC=invalid'
    $script:TestGrid=[pscustomobject]@{IsEnabled=$true;IsVisible=$true}
    $row=[pscustomobject]@{Guid=$guid;DN=$dn;DirectoryState='';DirectoryChecked=$null}
    $s=[pscustomobject]@{Finalized=$true;Error=$false;Map=@{};Rows=@($row);Fresh=@{};RefreshNeeded=$false;QueryKey='q1';State=[pscustomobject]@{SearchMode='Global';BaseDn='DC=example,DC=invalid';Scope='Subtree';TypeFilter='(objectClass=computer)';ViewId=''}}
    $s.Map[$dn.ToLowerInvariant()]=$row
    $script:Live=[pscustomobject]@{Search=$s;Identity='id';MemoryQueries=@{q1=[pscustomobject]@{ObservedUtc='2026-01-01T00:00:00Z'}};QueryToSave=$null}
    $c=[pscustomobject]@{ChangeSearch=$s;ChangeQueue=[Collections.Generic.Queue[object]]::new();ChangeEvents=[Collections.Generic.Queue[object]]::new();Stamps=@{};ChangeNext=[datetime]::UtcNow.AddSeconds(60);CacheDirty=$false;Mutation=1;ChangeJob=''}
    $script:Continuity=$c
    $r=[pscustomobject]@{OldDN=$dn;DN=$dn;Guid=$guid;Status='Changed';Row=[pscustomobject]@{DN=$dn;Guid=$guid;Name='PC1'};Stamp='s1'}
    $event=[pscustomobject]@{State=[pscustomobject]@{Search=$s;Identity='id';Mutation=1};Row=$r;At=[datetime]::UtcNow}
    $c.ChangeEvents.Enqueue($event)
    $script:VisitCache=@{}
    $script:VisitCache['cache-v3|example.invalid|'+$guid+'|hash|dc1||Object|object']='obj'
    $script:VisitCache['cache-v3|example.invalid|22222222-2222-2222-2222-222222222222|hash|dc1||Object|object']='other'
    $script:VisitCache['legacy|'+$dn]='legacy'
    Invoke-DomeniaObjectChanges
    Assert-False $script:VisitCache.ContainsKey('cache-v3|example.invalid|'+$guid+'|hash|dc1||Object|object')
    Assert-True $script:VisitCache.ContainsKey('cache-v3|example.invalid|22222222-2222-2222-2222-222222222222|hash|dc1||Object|object')
    Assert-True $script:VisitCache.ContainsKey('legacy|'+$dn)
}

Test-Case 'D025 : Invoke-DomeniaObjectChanges retombe sur DN quand la ligne n a pas de GUID' {
    function Test-DomeniaLiveSearchActive { return $true }
    function Test-DomeniaAccessBusyWrite { return $false }
    function Get-DomeniaControl { param([string]$Name) return $script:TestGrid }
    function ConvertTo-DomeniaLiveSnapshot { param($Row) return [pscustomobject]@{DN=[string]$Row.DN;Guid=[string]$Row.Guid;Name='PC1'} }
    function Get-DomeniaLiveObjectKey { param($Row) return ([string]$Row.DN).ToLowerInvariant() }
    $dn='CN=PC1,OU=Workstations,DC=example,DC=invalid'
    $script:TestGrid=[pscustomobject]@{IsEnabled=$true;IsVisible=$true}
    $row=[pscustomobject]@{Guid='';DN=$dn;DirectoryState='';DirectoryChecked=$null}
    $s=[pscustomobject]@{Finalized=$true;Error=$false;Map=@{};Rows=@($row);Fresh=@{};RefreshNeeded=$false;QueryKey='q1';State=[pscustomobject]@{SearchMode='Global';BaseDn='DC=example,DC=invalid';Scope='Subtree';TypeFilter='(objectClass=computer)';ViewId=''}}
    $s.Map[$dn.ToLowerInvariant()]=$row
    $script:Live=[pscustomobject]@{Search=$s;Identity='id';MemoryQueries=@{q1=[pscustomobject]@{ObservedUtc='2026-01-01T00:00:00Z'}};QueryToSave=$null}
    $c=[pscustomobject]@{ChangeSearch=$s;ChangeQueue=[Collections.Generic.Queue[object]]::new();ChangeEvents=[Collections.Generic.Queue[object]]::new();Stamps=@{};ChangeNext=[datetime]::UtcNow.AddSeconds(60);CacheDirty=$false;Mutation=1;ChangeJob=''}
    $script:Continuity=$c
    $r=[pscustomobject]@{OldDN=$dn;DN=$dn;Guid='';Status='Changed';Row=[pscustomobject]@{DN=$dn;Guid='';Name='PC1'};Stamp='s1'}
    $event=[pscustomobject]@{State=[pscustomobject]@{Search=$s;Identity='id';Mutation=1};Row=$r;At=[datetime]::UtcNow}
    $c.ChangeEvents.Enqueue($event)
    $script:VisitCache=@{}
    $script:VisitCache['legacy|'+$dn]='legacy'
    $script:VisitCache['other']='other'
    Invoke-DomeniaObjectChanges
    Assert-False $script:VisitCache.ContainsKey('legacy|'+$dn)
    Assert-True $script:VisitCache.ContainsKey('other')
}

Test-Case 'D025 : audit_preload exige Get-DomeniaCacheKey au lieu de object-v2' {
    $auditText = [IO.File]::ReadAllText($audit)
    $literalLine = [regex]::Match($auditText,'(?m)^\s*for g in \[[^\n]*GlobalSearchGeneration[^\n]*$').Value
    Assert-True ($literalLine.IndexOf("'Get-DomeniaCacheKey'",[StringComparison]::Ordinal) -ge 0)
    Assert-False ($literalLine.IndexOf("'object-v2|'",[StringComparison]::Ordinal) -ge 0)
}

Test-Case 'D028 : Request-DomeniaLinkPersistence est declaree dans le chargeur' {
    $loaderText = [IO.File]::ReadAllText($loader)
    Assert-True ($loaderText.IndexOf("'Request-DomeniaLinkPersistence'",[StringComparison]::Ordinal) -ge 0)
}


# ---------------------------------------------------------------- D115 / D113: schema of the local base (real SQLite)
. (Join-Path $modules 'Domenia-Release.Model.ps1')
foreach ($name in @('Initialize-DomeniaWinSqliteNative','New-DomeniaUtf8Ptr','ConvertFrom-DomeniaUtf8Ptr','Open-DomeniaDatabase','Close-DomeniaDatabase','Invoke-DomeniaDbExec','Invoke-DomeniaDbQuery','ConvertTo-DomeniaSqlLiteral','Initialize-DomeniaDatabase','Backup-DomeniaDatabase','Get-DomeniaStoreBackupDirectory')) {
    . ([scriptblock]::Create((Get-FunctionTextFromFile $core $name)))
}
function Get-CfgValue { param($Section,$Key,$Default) return $Default }
function Get-DomeniaDatabasePath { return $script:TestDbPath }
function Initialize-DomeniaDataStore { return $true }
function Recover-DomeniaDatabase { param($Reason) $script:RecoverCalls++; throw 'Restauration interdite dans ce test.' }
[void](Initialize-DomeniaWinSqliteNative)
function New-SchemaSandbox {
    param([string]$Version,[string]$Revision,[switch]$NoRevision)
    $root = Join-Path ([IO.Path]::GetTempPath()) ('domenia-cache-schema-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    $script:TestDbPath = Join-Path $root 'Domenia.db'
    $script:DomeniaDatabaseReady = $false; $script:DomeniaDatabaseRecoveryAttempted = $false; $script:RecoverCalls = 0
    if ($Version) {
        $db = Open-DomeniaDatabase -Path $script:TestDbPath
        try {
            [void](Invoke-DomeniaDbExec 'CREATE TABLE IF NOT EXISTS schema_info(key TEXT PRIMARY KEY,value TEXT NOT NULL);' $db)
            [void](Invoke-DomeniaDbExec ("INSERT OR REPLACE INTO schema_info(key,value) VALUES('schema_version'," + (ConvertTo-DomeniaSqlLiteral $Version) + ');') $db)
            if (-not $NoRevision) { [void](Invoke-DomeniaDbExec ("INSERT OR REPLACE INTO schema_info(key,value) VALUES('domenia_schema'," + (ConvertTo-DomeniaSqlLiteral $Revision) + ');') $db) }
        } finally { Close-DomeniaDatabase $db }
    }
    return $root
}
function Get-SchemaValue {
    param([string]$Key)
    $db = Open-DomeniaDatabase -Path $script:TestDbPath -ReadOnly
    try { $rows = @(Invoke-DomeniaDbQuery ("SELECT value FROM schema_info WHERE key=" + (ConvertTo-DomeniaSqlLiteral $Key) + ';') $db) } finally { Close-DomeniaDatabase $db }
    if ($rows.Count -eq 0) { return $null }
    return [string]$rows[0].value
}
function Get-TableCount {
    $db = Open-DomeniaDatabase -Path $script:TestDbPath -ReadOnly
    try { return @(Invoke-DomeniaDbQuery "SELECT name FROM sqlite_master WHERE type='table';" $db).Count } finally { Close-DomeniaDatabase $db }
}

Test-Case 'D115 : une base plus recente est refusee intacte, sans sauvegarde ni restauration' {
    $root = New-SchemaSandbox -Version '12' -Revision '1'
    $before = Get-TableCount
    $message = ''
    try { [void](Initialize-DomeniaDatabase) } catch { $message = $_.Exception.Message }
    Assert-True ($message -match 'plus recente') ('Refus non explicite : ' + $message)
    Assert-Equal '12' (Get-SchemaValue 'schema_version') 'La version de la base a ete modifiee.'
    Assert-Equal $before (Get-TableCount) 'Des tables ont ete creees dans une base plus recente.'
    Assert-False ([IO.Directory]::Exists((Join-Path $root 'Backups'))) 'Une sauvegarde a ete faite pour une base refusee.'
    Assert-Equal 0 $script:RecoverCalls 'Une restauration a ete tentee.'
}

Test-Case 'D115 : base ADCC (sans revision) sauvegardee hors rotation puis migree' {
    $root = New-SchemaSandbox -Version '11' -NoRevision
    Assert-True (Initialize-DomeniaDatabase) 'Migration refusee.'
    Assert-Equal '1' (Get-SchemaValue 'domenia_schema') 'Revision Domenia non ecrite.'
    $migrations = Join-Path $root 'Backups\migrations'
    Assert-Equal 1 @(Get-ChildItem -LiteralPath $migrations -Filter 'Domenia-migration-*.db' -File -ErrorAction SilentlyContinue).Count 'Sauvegarde de migration absente.'
    for ($i = 0; $i -lt 4; $i++) { [void](Backup-DomeniaDatabase) }
    $script:DomeniaDatabaseReady = $false
    Assert-True (Initialize-DomeniaDatabase) 'Deuxieme ouverture refusee.'
    Assert-Equal 1 @(Get-ChildItem -LiteralPath $migrations -Filter 'Domenia-migration-*.db' -File).Count 'La rotation ou une deuxieme ouverture a touche aux sauvegardes de migration.'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $root 'Backups') -Filter 'Domenia-*.db' -File).Count -ge 1) 'La sauvegarde ordinaire ne fonctionne plus.'
}

Test-Case 'D115 : le worker LiveCache n ecrit pas dans une base plus recente' {
    [void](New-SchemaSandbox -Version '12' -Revision '1')
    $code = Get-DomeniaLiveCacheCode
    $Payload = [pscustomobject]@{Mode='Write';Path=$script:TestDbPath;Scope=('a' * 64);Observations=@();Query=$null}
    $message = ''
    try { [void](& ([scriptblock]::Create($code))) } catch { $message = $_.Exception.Message }
    Assert-True ($message -match 'Cache refuse') ('Refus du worker absent : ' + $message)
    $db = Open-DomeniaDatabase -Path $script:TestDbPath -ReadOnly
    try { $tables = @(Invoke-DomeniaDbQuery "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'adcc_live_%';" $db) } finally { Close-DomeniaDatabase $db }
    Assert-Equal 0 $tables.Count 'Le worker a cree ses tables dans une base plus recente.'
}

# ---------------------------------------------------------------- Step C : D024, D026, D027
$cacheModel = Join-Path $modules 'Domenia-Cache.Model.ps1'
# Step C cases run inside an active Live search unless a case says otherwise (the probe path returns early otherwise).
function Test-DomeniaLiveSearchActive { return $true }
$reconcileUi = Join-Path $modules 'Domenia-Reconcile.UI.ps1'
if (-not [IO.File]::Exists($reconcileUi)) { throw ('Fichier absent : ' + $reconcileUi) }

. ([scriptblock]::Create((Get-FunctionTextFromFile $core 'Get-DomeniaCachedPresenceState')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $core 'Set-DomeniaResultRowPresence')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $core 'Open-AdObject')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $core 'Show-AdObjectResult')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $core 'Complete-DomeniaIndexRefreshUi')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $liveUi 'Initialize-DomeniaLive')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $liveUi 'Reset-DomeniaLiveIdentity')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $liveUi 'Start-DomeniaLiveBackgroundWork')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $liveUi 'Complete-DomeniaLiveProbe')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $reconcileUi 'Complete-DomeniaReconcile')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $liveModel 'Get-DomeniaLiveCacheCode')))

Test-Case 'D024 : presence cache utilise Get-DomeniaFreshness et pas 120s en dur' {
    . ([scriptblock]::Create((Get-Content -Raw $cacheModel)))

    function ConvertTo-DomeniaUtcDate {
        param($Value)
        if ($null -eq $Value) { return $null }
        if ($Value -is [datetime]) {
            if ($Value.Kind -eq [DateTimeKind]::Utc) { return $Value }
            return $Value.ToUniversalTime()
        }
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse([string]$Value, [ref]$parsed)) {
            if ($parsed.Kind -eq [DateTimeKind]::Utc) { return $parsed }
            return $parsed.ToUniversalTime()
        }
        return $null
    }

    function Get-DomeniaFreshnessPolicy {
        param([string]$Nature)
        return [pscustomobject]@{Nature=$Nature;FreshSeconds=10;Label='Presence reseau'}
    }

    $script:PresenceCache=@{}
    $key='cn=pc1,dc=example,dc=invalid'
    $script:PresenceCache[$key]=[pscustomobject]@{State='En ligne';Target='PC1';UpdatedUtc=[datetime]::UtcNow.AddSeconds(-30)}
    Assert-Equal '' (Get-DomeniaCachedPresenceState -Dn 'CN=PC1,DC=example,DC=invalid')

    $script:PresenceCache[$key]=[pscustomobject]@{State='En ligne';Target='PC1';UpdatedUtc=[datetime]::UtcNow.AddSeconds(-5)}
    Assert-Equal 'En ligne' (Get-DomeniaCachedPresenceState -Dn 'CN=PC1,DC=example,DC=invalid')
}

Test-Case 'D024 : Set-DomeniaResultRowPresence affiche une mesure committée sans réécrire sa date' {
    function Queue-DomeniaMetadata { param($Kind,$Row,$Key='') $script:QueueSpyRow=$Row; return $true }
    function ConvertTo-DomeniaGridPresenceState { param($State) return 'En ligne' }
    function Apply-DomeniaPresenceFilter { }
    function Get-DomeniaControl { return $null }
    function Set-DomeniaLiveRowValue { param($Row,$Name,$Value) }

    $script:BranchObjects=@([pscustomobject]@{DN='CN=PC1,DC=example,DC=invalid';Guid='00000000-0000-0000-0000-000000000001';Presence='Inconnu'})
    $script:QueueSpyRow=$null
    $at=[datetime]::UtcNow.AddMinutes(-10)
    $observation=[pscustomobject]@{Key='CN=PC1,DC=example,DC=invalid';Guid='00000000-0000-0000-0000-000000000001';Presence='En ligne';PresenceCheckedUtc=$at.ToString('o')}
    $script:CurrentPresenceFilter='Tous'
    $script:PresenceCache=@{}
    Set-DomeniaResultRowPresence -Dn 'CN=PC1,DC=example,DC=invalid' -State 'En ligne' -Target 'PC1' -Observation $observation
    $entry=$script:PresenceCache['cn=pc1,dc=example,dc=invalid']
    Assert-True ($null -ne $entry.PSObject.Properties['UpdatedUtc'])
    Assert-True ($entry.UpdatedUtc.Kind -eq [DateTimeKind]::Utc)
    Assert-Equal $at $entry.UpdatedUtc
    Assert-True ($null -eq $script:QueueSpyRow)
}

Test-Case 'D024 : Show-AdObjectResult conserve ObservedUtc SQLite independamment de Created' {
    function Keep-DomeniaDraftOnResult { param($Result,$DN,$Type) return $false }
    function Clear-ObjectDetails { }
    function Remove-DomeniaSensitiveProperties { param($Properties) return $Properties }
    function Get-DomeniaEntryFirstString { param($Entry,$Name) return 'PC1' }
    function Set-DomeniaRelationsSelection { param($Object) }
    function Sync-DomeniaIndexEntry { param($Entry,$Type) return '' }
    function Stop-DomeniaSecretReadTasks { }
    function Request-UiTaskStop { param($Id,[switch]$Silent,[switch]$Force,[switch]$Superseded,[string]$Reason='') }
    function Fill-GenericObject { param($Entry,$Type) }
    function Fill-UserObject { param($Entry) }
    function Fill-ComputerObject { param($Entry) }
    function Fill-GroupObject { param($Entry) }
    function Fill-ContainerObject { param($Entry) }
    function Refresh-AssociationContext { param([switch]$SkipResultRefresh) }
    function Set-DomeniaSupportObjectSource { param($Dn,[switch]$IsLive) }
    function Reset-DomeniaDeferredViews { param($Dn) }
    function Clear-Secrets { }
    function Set-VisibleTabsForType { param($Type,[switch]$PreserveWorkspace) }
    function Apply-CurrentPermissionUi { }
    function Set-Status { param($Text,$Level='') }
    function Get-DomeniaControl { return $null }
    function Set-DomeniaControlText { param($Name,$Text) return $true }
    function Update-Dashboard { }
    function Save-DomeniaDraftBaseline { param($DN) }
    function Set-DomeniaPresenceText { param($Name,$Text) }
    function Update-DomeniaObjectPresence { param($State,$Target) }
    function Get-DomeniaLiveObservationView { param($Observation) return [pscustomobject]@{State='';Display=''} }
    function Get-CurrentSelectedComputerName { return '' }
    function Normalize-LinkComputer { param($Computer) return $Computer }
    function Get-ExistingLinkForComputer { param($Computer) return $null }
    function Set-DomeniaObservationTime { param($Object,$Nature,$ObservedUtc,[switch]$Succeeded) $script:ObservedTimeCalls++ }
    function Get-DomeniaRecordFreshness { param($Object,$Nature) $script:FreshnessCalls++; return [pscustomobject]@{Nature=$Nature;State='Fresh';AgeSeconds=0;Label=''} }

    $createdUtc=[datetime]::UtcNow.AddMinutes(-2)
    $observedUtc=[datetime]::UtcNow.AddMinutes(-20)
    $script:ShowingCachedObject=$true
    $script:ShowingCachedObjectCreated=$createdUtc.ToLocalTime()
    $script:SelectedObject=$null
    $script:SelectedObjectGeneration=0
    $script:RenderingObjectWithoutProbes=$false
    $script:AsyncJobs=@{}
    $script:ObservedTimeCalls=0
    $script:FreshnessCalls=0
    $result=[pscustomobject]@{Properties=@{name='PC1'};Live=$false;DataSource='SQLite';ObservedUtc=$observedUtc.ToString('o')}
    Show-AdObjectResult -Result $result -Dn 'CN=PC1,DC=x' -Type 'Machine' -NoNavigate
    Assert-True ($null -ne $script:SelectedObject)
    Assert-True ($script:ObservedTimeCalls -gt 0)
    Assert-True ($script:FreshnessCalls -gt 0)
    $delta=[Math]::Abs((([datetime]$script:SelectedObject.LoadedAt) - $observedUtc.ToLocalTime()).TotalSeconds)
    Assert-True ($delta -lt 1) ('LoadedAt=' + [string]$script:SelectedObject.LoadedAt)
}

Test-Case 'D024 : LiveCache ecrit checked_utc depuis UserCheckedUtc' {
    $code = Get-DomeniaLiveCacheCode
    Assert-True ($code -match '\$checkedForRetention=\[string\]\$observation\.UserCheckedUtc')
    Assert-True ($code -match '\$checkedForRetention,\$json')
}

$script:FreshnessFixture=@'
. $cacheModel
. $liveModel
foreach($name in @('Complete-DomeniaLiveProbe','Complete-DomeniaLivePresence','Fail-DomeniaLiveProbe','Set-DomeniaLiveObservationOnRow')){
    . ([scriptblock]::Create((Get-FunctionTextFromFile $liveUi $name)))
}
function Reset-DomeniaLiveIdentity { }
function Get-DomeniaEffectiveWorkerResult { param($Result,$RequiredProperties) return $Result }
function Merge-DomeniaLiveLinkMemory { param($Observation) }
function Test-DomeniaLiveSearchActive { return $false }
function Get-CurrentSelectedComputerName { return '' }
function Normalize-LinkComputer { param($Computer) return $Computer }
$script:Live=[pscustomobject]@{NegativeCache=(New-DomeniaNegativeCache);Observations=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new();SaveQueue=@{};PresenceSeen=@{};Done=@{};RemoteFaulted=$false;Search=$null;Identity='id'}
$script:SessionEpoch=1L;$script:GlobalSearchGeneration=1;$script:ActiveWriteTaskId='';$script:WriteState='Known'
$script:DirectoryCredentialFaulted=$false
$now=[datetime]::UtcNow;$consoleAt=$now.AddDays(-3);$presenceAt=$now.AddHours(-2)
$previous=[pscustomobject]@{Key='k';Computer='PC1';Guid='g';Outcome='Observed';CurrentUser='alice';LastUser='alice';ObservedUtc=$consoleAt.ToString('o');UserCheckedUtc=$consoleAt.ToString('o');CheckedUtc=$consoleAt.ToString('o');Source='Console CIM/DCOM';LastSource='Console CIM/DCOM';Presence='En ligne';PresenceCheckedUtc=$presenceAt.ToString('o')}
[void](Set-DomeniaObservationTime $previous 'Console' $consoleAt)
[void](Set-DomeniaObservationTime $previous 'Presence' $presenceAt)
$script:Live.Observations['k']=$previous
$script:SelectedObject=[pscustomobject]@{Guid='g'}
[void](Set-DomeniaObservationTime $script:SelectedObject 'Attributes' $now.AddHours(-5))
$attributesBefore=$script:SelectedObject | ConvertTo-Json -Depth 5 -Compress
$state=[pscustomobject]@{Key='k';Computer='PC1';Guid='g';Identity='id';Epoch=1L;Generation=1;RequestId='r';ProbeUser=$false}
$result=[pscustomobject]@{Outcome='PresenceOnly';Key='k';Computer='PC1';Guid='g';Presence='En ligne';PresenceCheckedUtc=$now.ToString('o')}
'@
Test-Case 'D024 : un ping reel preserve les dates console et attributs' {
    . ([scriptblock]::Create($script:FreshnessFixture))
    Complete-DomeniaLiveProbe $result $state
    $observed=$script:Live.Observations['k']
    Assert-Equal 'Fresh' (Get-DomeniaRecordFreshness $observed 'Presence').State
    Assert-Equal 'Stale' (Get-DomeniaRecordFreshness $observed 'Console').State
    Assert-Equal $consoleAt.ToString('o') $observed.Times.Console.ObservedUtc
    Assert-Equal $previous.ObservedUtc $observed.ObservedUtc
    Assert-Equal 'alice' $observed.LastUser
    Assert-Equal $attributesBefore ($script:SelectedObject | ConvertTo-Json -Depth 5 -Compress)
    Assert-Equal $now.ToString('o') $observed.Times.Presence.ObservedUtc
}
Test-Case 'D024 : le paquet presence intermediaire preserve la console puis la lecture la renouvelle' {
    . ([scriptblock]::Create($script:FreshnessFixture))
    Complete-DomeniaLivePresence $result $state
    Assert-Equal $consoleAt.ToString('o') $script:Live.Observations['k'].Times.Console.ObservedUtc
    Assert-Equal $now.ToString('o') $script:Live.Observations['k'].Times.Presence.ObservedUtc
    $result.Outcome='Observed';$result | Add-Member User 'bob';$state.ProbeUser=$true
    Complete-DomeniaLiveProbe $result $state
    $observed=$script:Live.Observations['k']
    Assert-Equal 'Fresh' (Get-DomeniaRecordFreshness $observed 'Console').State
    Assert-Equal 'bob' $observed.LastUser
    Assert-Equal $now.ToString('o') $observed.Times.Presence.ObservedUtc 'La date est celle du worker'
    Assert-Equal $consoleAt.ToString('o') $previous.Times.Console.ObservedUtc 'L ancien enregistrement ne change pas'
    Assert-True ($null -eq $observed.PSObject.Properties['ConsoleFreshness']) 'Aucune fraicheur figee serialisee'
}
Test-Case 'D024 : erreur ping directe ou echec worker ne rajeunit aucune observation' {
    . ([scriptblock]::Create($script:FreshnessFixture))
    $result.Presence='Erreur de ping'
    Complete-DomeniaLiveProbe $result $state
    $observed=$script:Live.Observations['k']
    Assert-Equal $presenceAt.ToString('o') $observed.Times.Presence.ObservedUtc
    Assert-Equal $now.ToString('o') $observed.Times.Presence.LastAttemptUtc
    Assert-Equal 'Stale' (Get-DomeniaRecordFreshness $observed 'Presence').State
    Fail-DomeniaLiveProbe 'delai fictif' $state
    $observed=$script:Live.Observations['k']
    Assert-Equal $presenceAt.ToString('o') $observed.Times.Presence.ObservedUtc
    Assert-Equal $consoleAt.ToString('o') $observed.Times.Console.ObservedUtc
    Assert-True ((ConvertTo-DomeniaUtcDate $observed.Times.Presence.LastAttemptUtc) -ge $now)
}
Test-Case 'D024 : une lecture console refusee conserve son dernier succes' {
    . ([scriptblock]::Create($script:FreshnessFixture))
    $result.Outcome='Denied';$state.ProbeUser=$true
    Complete-DomeniaLiveProbe $result $state
    $observed=$script:Live.Observations['k']
    $freshness=Get-DomeniaRecordFreshness $observed 'Console'
    Assert-Equal 'Stale' $freshness.State
    Assert-Equal $consoleAt.ToString('o') $observed.Times.Console.ObservedUtc
    Assert-True ($freshness.Label -match 'derniere tentative')
}
Test-Case 'D024 : details recalcules apres rechargement JSON sans dates inventees' {
    . ([scriptblock]::Create($script:FreshnessFixture))
    $reloaded=$previous | ConvertTo-Json -Depth 3 -Compress | ConvertFrom-Json
    $row=New-DomeniaLiveResultRow;$row.Type='Machine';$row.Guid='g';$row.DN='k'
    Set-DomeniaLiveObservationOnRow $row $reloaded -Cached
    Assert-True ($row.SessionDetail -match 'Session console.+a relire')
    Assert-True ($row.PresenceDetail -match 'Presence reseau.+a relire')
    Assert-Equal 'alice (cache)' $row.SessionDisplay
    Assert-Equal 'En ligne (cache)' $row.Presence
    Complete-DomeniaLivePresence $result $state
    Set-DomeniaLiveObservationOnRow $row $script:Live.Observations['k'] -Cached
    Assert-True ($row.SessionDetail -match 'Session console.+a relire')
    Assert-False ($row.PresenceDetail -match 'Presence reseau.+a relire')
}
Test-Case 'D024 : identite remplacee et date de ping invalide ne recuperent pas une ancienne fraicheur' {
    . ([scriptblock]::Create($script:FreshnessFixture))
    $result.Guid='new-guid';$state.Guid='new-guid';$result.PresenceCheckedUtc='date-invalide'
    Complete-DomeniaLiveProbe $result $state
    $observed=$script:Live.Observations['k']
    Assert-Equal 'Unknown' (Get-DomeniaRecordFreshness $observed 'Console').State
    Assert-Equal 'Unknown' (Get-DomeniaRecordFreshness $observed 'Presence').State
    Assert-Equal '' $observed.LastUser
    Assert-False ((Get-Content -Raw $core).Contains('$script:PresenceCacheSeconds'))
}

Test-Case 'D024 : une console vide observee affiche sa fraicheur dans le statut selectionne' {
    . ([scriptblock]::Create($script:FreshnessFixture))
    function Get-CurrentSelectedComputerName { return 'PC1' }
    function Set-DomeniaControlText { param($Name,$Text) $script:FreshnessStatus[$Name]=$Text;return $true }
    $script:FreshnessStatus=@{}
    $result.Outcome='NoConsole';$state.ProbeUser=$true
    Complete-DomeniaLiveProbe $result $state
    Assert-Equal 'Fresh' (Get-DomeniaRecordFreshness $script:Live.Observations['k'] 'Console').State
    Assert-True ($script:FreshnessStatus.LblLinkProbeStatus -match 'Aucun compte console.+Session console :')
    Assert-Equal $consoleAt.ToString('o') $script:Live.Observations['k'].ObservedUtc 'Le dernier utilisateur reste historique'
}

Test-Case 'D026 : changement de DC sans instance identique ne marque pas Missing' {
    . ([scriptblock]::Create((Get-Content -Raw $cacheModel)))

    function Get-DomeniaMember {
        param($Object,$Name,$Default='')
        if ($null -eq $Object) { return $Default }
        if ($Object -is [Collections.IDictionary] -and $Object.ContainsKey($Name)) { return $Object[$Name] }
        $prop = $Object.PSObject.Properties[$Name]
        if ($null -ne $prop) { return $prop.Value }
        return $Default
    }

    function ConvertTo-DomeniaGuidText {
        param($Value)
        $s=[string]$Value
        if ($s -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return $s.ToLowerInvariant() }
        return ''
    }

    function Get-DomeniaEffectiveWorkerResult { param($Result,$RequiredProperties) return $Result }
    function Get-DomeniaLiveObjectKey { param($Row) return ([string]$Row.DN).ToLowerInvariant() }
    function Test-DomeniaLiveSearchActive { return $true }
    function Set-Status { param($Text) $script:TestStatus=$Text }

    $guidA='11111111-1111-1111-1111-111111111111'
    $guidB='22222222-2222-2222-2222-222222222222'
    $rowA=[pscustomobject]@{DN='CN=A,DC=x';Guid=$guidA}
    $rowB=[pscustomobject]@{DN='CN=B,DC=x';Guid=$guidB}
    $s=[pscustomobject]@{Rows=@($rowA,$rowB);Map=@{}}
    $script:Live=[pscustomobject]@{Search=$s;Identity='id'}
    $script:SessionEpoch=[long]1
    $script:Continuity=[pscustomobject]@{Mutation=1}
    $script:Reconcile=[pscustomobject]@{
        Job=''
        Events=[Collections.Generic.Queue[object]]::new()
        Checkpoint=[pscustomobject]@{Dc='dc1';InvocationId='i1';ScopeDn='DC=x|Subtree|(objectClass=computer)'}
    }
    $state=[pscustomobject]@{
        Epoch=[long]1
        Identity='id'
        Search=$s
        Mutation=1
        Filter='(objectClass=computer)'
    }
    $r=[pscustomobject]@{
        Rows=@($rowA)
        Capped=$false
        Filter='(objectClass=computer)'
        ObservedUtc=[datetime]::UtcNow
        Source='dc2|i2'
        Dc='dc2'
        InvocationId='i2'
        BaseDn='DC=x'
        Scope='Subtree'
    }
    Complete-DomeniaReconcile -Result $r -State $state
    $missing=@($script:Reconcile.Events | Where-Object { $_.Kind -eq 'Missing' })
    Assert-Equal 0 $missing.Count
    Assert-Equal 'i2' $script:Reconcile.Checkpoint.InvocationId
}

Test-Case 'D026 : meme instance complete marque Missing et Move' {
    . ([scriptblock]::Create((Get-Content -Raw $cacheModel)))

    function Get-DomeniaMember {
        param($Object,$Name,$Default='')
        if ($null -eq $Object) { return $Default }
        if ($Object -is [Collections.IDictionary] -and $Object.ContainsKey($Name)) { return $Object[$Name] }
        $prop = $Object.PSObject.Properties[$Name]
        if ($null -ne $prop) { return $prop.Value }
        return $Default
    }

    function ConvertTo-DomeniaGuidText {
        param($Value)
        $s=[string]$Value
        if ($s -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return $s.ToLowerInvariant() }
        return ''
    }

    function Get-DomeniaEffectiveWorkerResult { param($Result,$RequiredProperties) return $Result }
    function Get-DomeniaLiveObjectKey { param($Row) return ([string]$Row.DN).ToLowerInvariant() }
    function Test-DomeniaLiveSearchActive { return $true }
    function Set-Status { param($Text) $script:TestStatus=$Text }

    $guidA='11111111-1111-1111-1111-111111111111'
    $guidB='22222222-2222-2222-2222-222222222222'
    $rowA=[pscustomobject]@{DN='CN=A,DC=x';Guid=$guidA}
    $rowB=[pscustomobject]@{DN='CN=B,DC=x';Guid=$guidB}
    $rowAMoved=[pscustomobject]@{DN='CN=A,OU=Moved,DC=x';Guid=$guidA}
    $s=[pscustomobject]@{Rows=@($rowA,$rowB);Map=@{}}
    $script:Live=[pscustomobject]@{Search=$s;Identity='id'}
    $script:SessionEpoch=[long]1
    $script:Continuity=[pscustomobject]@{Mutation=1}
    $script:Reconcile=[pscustomobject]@{
        Job=''
        Events=[Collections.Generic.Queue[object]]::new()
        Checkpoint=[pscustomobject]@{Dc='dc1';InvocationId='i1';ScopeDn='DC=x|Subtree|(objectClass=computer)'}
    }
    $state=[pscustomobject]@{
        Epoch=[long]1
        Identity='id'
        Search=$s
        Mutation=1
        Filter='(objectClass=computer)'
    }
    $r=[pscustomobject]@{
        Rows=@($rowAMoved)
        Capped=$false
        Filter='(objectClass=computer)'
        ObservedUtc=[datetime]::UtcNow
        Source='dc1|i1'
        Dc='dc1'
        InvocationId='i1'
        BaseDn='DC=x'
        Scope='Subtree'
    }
    Complete-DomeniaReconcile -Result $r -State $state
    $missing=@($script:Reconcile.Events | Where-Object { $_.Kind -eq 'Missing' })
    $moves=@($script:Reconcile.Events | Where-Object { $_.Kind -eq 'Move' })
    Assert-Equal 1 $missing.Count
    Assert-Equal 1 $moves.Count
    Assert-Equal $guidB ([string]$missing[0].Row.Guid)
    Assert-Equal $guidA ([string]$moves[0].Guid)
}

Test-Case 'D026 : IndexBuild tronque ne remplace pas l index' {
    . ([scriptblock]::Create((Get-FunctionTextFromFile $core 'Set-DomeniaIndexProgress')))
    $script:IndexTransferProgress=$null;$script:IndexProgressTimer=$null
    $script:IndexProgressControls=@{PbIndexProgress=[Windows.Controls.ProgressBar]::new();LblIndexProgress=[Windows.Controls.TextBlock]::new()}
    function Get-DomeniaControl {param($Name);return $script:IndexProgressControls[$Name]}
    function Get-DomeniaEffectiveWorkerResult { param($Result,$RequiredProperties) return $Result }
    function Save-DomeniaIndex { param($Rows,$Server,$BaseDn,$HighestUsn,$TotalCount,$InvocationId) $script:SaveIndexCalls++; return $true }
    function Update-DomeniaIndexDatabaseRows { param($Rows,$Server,$BaseDn,$HighestUsn,$TotalCount,$InvocationId) $script:UpdateIndexCalls++; return $true }
    # FI-19: the figures are read again off the Dispatcher; the request is only counted here.
    function Request-DomeniaIndexMetadata { param([switch]$StartupChecks,[int]$Attempt=0) $script:MetadataRequests++ }
    function Merge-DomeniaIndexRows { param($Existing,$Changed) return [pscustomobject]@{Total=1;Updated=1;Added=0} }
    function Set-DomeniaControlText { param($Name,$Text) return $true }
    function Set-Status { param($Text) }
    function Add-DomeniaUiLog { param($Area,$Text) }
    function Register-DomeniaOperationSample { param($Operation,$Mode,$ItemCount,$DurationMs,$BytesEstimated,$AdQueries,$SuccessCount) }
    function Update-DomeniaIndexStats { }
    # Complete-DomeniaIndexRefreshUi marque la passe tronquee par Set-DomeniaIndexPartial (Domenia-Core.ps1) :
    # le banc ne charge que des fonctions choisies, ce bouchon enregistre l'appel sans ecrire de reglage.
    function Set-DomeniaIndexPartial { param($BaseDn,$Count,$Reason,$Limit,[switch]$Clear) $script:IndexPartialCalls++; $script:IndexPartialBaseDn=[string]$BaseDn; $script:IndexPartialCleared=[bool]$Clear }
    # Complete-DomeniaIndexRefreshUi classe la coupure par Get-DomeniaIndexCut : le banc charge le vrai
    # helper (pur, sans etat) plutot qu'un doublon local qui masquerait une regression de sa garde.
    . ([scriptblock]::Create((Get-FunctionTextFromFile $core 'Get-DomeniaIndexCut')))

    $script:SaveIndexCalls=0
    $script:UpdateIndexCalls=0
    $script:IndexPartialCalls=0
    $script:IndexPartialBaseDn=''
    $script:IndexPartialCleared=$false
    $script:IndexRows=@([pscustomobject]@{DN='CN=old';Guid='11111111-1111-1111-1111-111111111111'})
    $script:IndexInfo=[pscustomobject]@{Server='dc1';BaseDn='DC=x';Usn=100;InvocationId='i1'}
    $effective=[pscustomobject]@{
        Rows=@([pscustomobject]@{DN='CN=new';Guid='22222222-2222-2222-2222-222222222222'})
        Incremental=$false
        Truncated=$true
        Server='dc1'
        BaseDn='DC=x'
        HighestUsn=200
        DurationMs=10
        DeltaClause=''
        InvocationId='i2'
    }
    Complete-DomeniaIndexRefreshUi -Result $effective -State $null
    Assert-Equal 0 $script:SaveIndexCalls
    Assert-Equal 1 $script:UpdateIndexCalls
    Assert-Equal 1 $script:IndexPartialCalls
    Assert-Equal 'DC=x' ([string]$script:IndexPartialBaseDn)
    Assert-Equal $false $script:IndexPartialCleared
    Assert-True ($script:IndexProgressControls.PbIndexProgress.IsIndeterminate -and $script:IndexProgressControls.LblIndexProgress.Text -match 'Validation') 'Progression terminee avant confirmation SQLite.'
}

Test-Case 'D026 : lecture OU tronquee conserve l avertissement de base partielle' {
    . ([scriptblock]::Create((Get-FunctionTextFromFile $core 'Set-DomeniaIndexProgress')))
    $script:IndexTransferProgress=$null;$script:IndexProgressTimer=$null
    $script:IndexProgressControls=@{PbIndexProgress=[Windows.Controls.ProgressBar]::new();LblIndexProgress=[Windows.Controls.TextBlock]::new()}
    function Get-DomeniaControl {param($Name);return $script:IndexProgressControls[$Name]}
    function Get-DomeniaEffectiveWorkerResult { param($Result,$RequiredProperties) return $Result }
    function Update-DomeniaIndexDatabaseRows { param($Rows,$Server,$BaseDn,$HighestUsn,$TotalCount,$InvocationId) return $true }
    function Set-DomeniaIndexPartial { param($BaseDn,$Count,$Reason,$Limit,[switch]$Clear) $script:PartialMarker=[pscustomobject]@{BaseDn=$BaseDn;Count=$Count;Reason=$Reason;Limit=$Limit;Clear=[bool]$Clear} }
    function Set-DomeniaControlText { param($Name,$Text) return $true }
    function Set-Status { param($Text) }
    function Add-DomeniaUiLog { param($Area,$Text) }
    . ([scriptblock]::Create((Get-FunctionTextFromFile $core 'Get-DomeniaIndexCut')))
    . ([scriptblock]::Create((Get-FunctionTextFromFile $core 'Complete-DomeniaIndexScopeUi')))

    $script:SessionEpoch=[long]1
    $script:Conn=[pscustomobject]@{BaseDn='DC=x'}
    $script:IndexInfo=[pscustomobject]@{Server='dc1';Usn=100;InvocationId='i1'}
    $effective=[pscustomobject]@{
        Rows=@([pscustomobject]@{Type='Machine'})
        Truncated=$true
        Server='dc1'
        BaseDn='OU=Big,DC=x'
        SearchBase='OU=Big,DC=x'
        LimitReason='serveur'
        LimitServerSeconds=120
        DurationMs=120000
    }
    Complete-DomeniaIndexScopeUi -Result $effective -State ([pscustomobject]@{Epoch=[long]1;SearchBase='OU=Big,DC=x'})
    Assert-Equal 'DC=x' ([string]$script:PartialMarker.BaseDn)
    Assert-Equal 1 ([int]$script:PartialMarker.Count)
    Assert-Equal 'serveur' ([string]$script:PartialMarker.Reason)
    Assert-Equal 120 ([int]$script:PartialMarker.Limit)
    Assert-Equal $false ([bool]$script:PartialMarker.Clear)
    Assert-True ($script:IndexProgressControls.PbIndexProgress.IsIndeterminate -and $script:IndexProgressControls.LblIndexProgress.Text -match 'Validation') 'Progression OU terminee avant confirmation SQLite.'
}

Test-Case 'D027 : echec recent bloque sonde automatique mais pas manuelle' {
    . ([scriptblock]::Create((Get-Content -Raw $cacheModel)))

    function Test-DomeniaLiveBackgroundAllowed { param($Source) return $true }
    function Get-DomeniaLiveWorkerCount { param($OperationId='') return 0 }
    function Get-DomeniaControl {
        param($Name)
        if ($Name -eq 'DgObjects') { return $script:TestGrid }
        return $null
    }
    function Get-DomeniaSelectedGridRow { return $script:TestRow }
    function Test-DomeniaLiveProbeIntent { param($Row) return $true }
    function Clear-DomeniaLiveProbeIntent { }
    function Request-DomeniaLiveProbe { param($Row) }
    function Test-DomeniaLiveIdentity { param($Item,$Epoch,$Identity) return $true }
    function Get-DomeniaRunningComputerUserProbe { param($Computer) return $null }
    function Start-UiTask {
        param($Name,$OperationId,$Code,$Payload,$CallbackState,$TimeoutSeconds,$SuccessHandler,$ErrorHandler,[switch]$NonCancellable,[string]$TaskClass)
        $script:StartUiCalls++
        [void]$script:StartUiOperations.Add($OperationId)
        return 'test-task'
    }
    function Set-DomeniaLiveRowValue { param($Row,$Name,$Value) $Row.SessionState=$Value }
    function Get-CfgValue { param($Section,$Key,$Default) return $Default }
    function Get-DomeniaLiveProbeCode { return '' }

    $guid='11111111-1111-1111-1111-111111111111'
    $script:SessionEpoch=[long]1
    $script:GlobalSearchGeneration=1
    $script:DemoMode=$false
    $script:AsyncEngineClosing=$false
    $script:ActiveWriteTaskId=''
    $script:WriteState='Known'
    $script:AccessState=$null
    $script:DirectoryCredentialFaulted=$false
    $script:StartUiCalls=0
    $script:StartUiOperations.Clear()

    $row=[pscustomobject]@{DN='CN=PC1,DC=x';Guid=$guid;Computer='PC1';Presence='Inconnu';SessionState=''}
    $key=$row.DN.ToLowerInvariant()
    $s=[pscustomobject]@{
        Fresh=@{}
        Map=@{}
        Rows=@($row)
        Identity='id'
        Epoch=[long]1
        QueryKey='q1'
        State=[pscustomobject]@{Limit=10}
        CacheRequested=$true
    }
    $s.Fresh[$key]=$true
    $s.Map[$key]=$row

    $script:Live=[pscustomobject]@{
        Enabled=$true
        DatabasePath=''
        IdentityRows=[Collections.Generic.Queue[object]]::new()
        CacheReady=$false
        Notifying=$false
        Deferred=[Collections.Generic.Queue[object]]::new()
        Identity='id'
        Scope='scope'
        Epoch=[long]1
        Search=$s
        MemoryQueries=@{}
        Observations=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
        Pending=[Collections.Generic.Queue[object]]::new()
        PendingKeys=@{}
        Busy=@{}
        Done=@{}
        ObservationsLoaded=$false
        Refresh=[Collections.Generic.Queue[object]]::new()
        SaveQueue=@{}
        QueryToSave=$null
        SaveJob=''
        SaveAfter=[datetime]::MinValue
        SaveFault=''
        PresenceEvents=[Collections.Concurrent.ConcurrentQueue[object]]::new()
        PresenceSeen=@{}
        RemoteFaulted=$false
        NextStart=[datetime]::MinValue
        Timer=$null
        InTick=$false
        AutoDetect=$false
        ProbeSelection=$null
        LastFilter=[datetime]::MinValue
        NegativeCache=(New-DomeniaNegativeCache)
    }

    [void](Register-DomeniaFailure $script:Live.NegativeCache 'PC1' 'Cim' 'Unreachable')

    $script:TestGrid=[pscustomobject]@{IsEnabled=$true;SelectedItems=@($row)}
    $script:TestRow=$row

    $item=[pscustomobject]@{
        Key=$key
        Computer='PC1'
        Guid=$guid
        Identity='id'
        Epoch=[long]1
        Generation=1
        RequestId='r1'
        Row=$row
        ReadyAfter=[datetime]::UtcNow.AddSeconds(-1)
    }
    $script:Live.PendingKeys[$key]=$item
    $intent=[pscustomobject]@{Key=$key;RequestId='r1';Requested=$false;Manual=$false}
    $script:Live.ProbeSelection=$intent

    Start-DomeniaLiveBackgroundWork
    Assert-Equal 0 $script:StartUiCalls
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$row.SessionState)) 'La raison de la suspension n est pas affichee.'

    $intent2=[pscustomobject]@{Key=$key;RequestId='r2';Requested=$false;Manual=$true}
    $script:Live.ProbeSelection=$intent2
    $item2=[pscustomobject]@{
        Key=$key
        Computer='PC1'
        Guid=$guid
        Identity='id'
        Epoch=[long]1
        Generation=1
        RequestId='r2'
        Row=$row
        ReadyAfter=[datetime]::UtcNow.AddSeconds(-1)
    }
    $script:Live.PendingKeys[$key]=$item2
    $script:StartUiCalls=0
    $script:StartUiOperations.Clear()
    Start-DomeniaLiveBackgroundWork
    Assert-Equal 1 $script:StartUiCalls
    Assert-True ($script:StartUiOperations -contains 'LiveConsole')
    # After a credential refusal even a manual probe is held back: same account again would be a replay (D018).
    [void](Register-DomeniaFailure $script:Live.NegativeCache 'PC1' 'Cim' 'CredentialRejected')
    $script:Live.Busy=@{}
    $intent3=[pscustomobject]@{Key=$key;RequestId='r3';Requested=$false;Manual=$true}
    $script:Live.ProbeSelection=$intent3
    $script:Live.PendingKeys[$key]=[pscustomobject]@{Key=$key;Computer='PC1';Guid=$guid;Identity='id';Epoch=[long]1;Generation=1;RequestId='r3';Row=$row;ReadyAfter=[datetime]::UtcNow.AddSeconds(-1)}
    $script:StartUiCalls=0
    Start-DomeniaLiveBackgroundWork
    Assert-Equal 0 $script:StartUiCalls 'Une sonde manuelle a rejoue un compte refuse.'
}

Test-Case 'D027 : Complete-DomeniaLiveProbe enregistre Timeout' {
    . ([scriptblock]::Create((Get-Content -Raw $cacheModel)))

    function Reset-DomeniaLiveIdentity { }
    function Test-DomeniaLiveIdentity { param($State,$Epoch,$Identity) return $true }
    function Get-DomeniaEffectiveWorkerResult { param($Result,$RequiredProperties) return $Result }
    function ConvertTo-DomeniaLiveObservation {
        param($Result,$Previous)
        return [pscustomobject]@{
            Outcome=[string]$Result.Outcome
            Computer=[string]$Result.Computer
            Guid=[string]$Result.Guid
            DirectoryAuthRejected=$false
        }
    }
    function Get-DomeniaLiveField { param($Object,$Name,$Default='') return $Default }
    function Merge-DomeniaLiveLinkMemory { param($Observation) }
    function Test-DomeniaLiveSearchActive { return $false }
    function Get-CurrentSelectedComputerName { return '' }
    function Normalize-LinkComputer { param($Computer) return $Computer }
    function Get-ExistingLinkForComputer { param($Computer) return $null }
    function Set-DomeniaLiveObservationOnRow { param($Row,$Observation,[switch]$Cached) }
    function Set-DomeniaPresenceText { param($Name,$Text) }
    function Update-DomeniaObjectPresence { param($State,$Target) }
    function Set-RowAssociationMetadata { param($Rows) }
    function Set-DomeniaControlText { param($Name,$Text) return $true }
    function Get-DomeniaLiveObservationView { param($Observation) return [pscustomobject]@{State='';Display=''} }
    function Set-DomeniaObservationTime { param($Object,$Nature,$ObservedUtc,[switch]$Succeeded) }
    function Get-DomeniaRecordFreshness { param($Object,$Nature) return [pscustomobject]@{Nature=$Nature;State='Unknown';AgeSeconds=-1;Label=''} }

    $script:RegisteredFailure=''
    $script:Live=[pscustomobject]@{
        NegativeCache=(New-DomeniaNegativeCache)
        Observations=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
        SaveQueue=@{}
        PresenceSeen=@{}
        Done=@{}
        RemoteFaulted=$false
        Search=$null
        Identity='id'
    }
    $script:SessionEpoch=[long]1
    $script:ActiveWriteTaskId=''
    $script:WriteState='Known'
    $script:DirectoryCredentialFaulted=$false
    $result=[pscustomobject]@{Outcome='Timeout';Key='k';Computer='PC1';Guid='g'}
    $state=[pscustomobject]@{Key='k';Computer='PC1';Guid='g';Identity='id';Epoch=[long]1;Generation=1;RequestId='r'}
    Complete-DomeniaLiveProbe -Result $result -State $state
    $entry=$script:Live.NegativeCache['cim|pc1']
    Assert-True ($null -ne $entry)
    Assert-Equal 'Timeout' ([string]$entry.Kind)
}

Test-Case 'D024/D026/D027 : aucune garde Get-Command autour des regles Cache.Model' {
    $texts = @(
        (Get-FunctionTextFromFile $core 'Get-DomeniaCachedPresenceState'),
        (Get-FunctionTextFromFile $core 'Show-AdObjectResult'),
        (Get-FunctionTextFromFile $core 'Complete-DomeniaIndexRefreshUi'),
        (Get-FunctionTextFromFile $liveUi 'Start-DomeniaLiveBackgroundWork'),
        (Get-FunctionTextFromFile $liveUi 'Complete-DomeniaLiveProbe'),
        (Get-FunctionTextFromFile $reconcileUi 'Complete-DomeniaReconcile')
    )
    foreach ($text in $texts) {
        Assert-True ($text -notmatch 'Get-Command')
    }
}

# ---------------------------------------------------------------- Step E : D021, D022
$reconcileUi = Join-Path $modules 'Domenia-Reconcile.UI.ps1'
if (-not [IO.File]::Exists($reconcileUi)) { throw ('Fichier absent : ' + $reconcileUi) }

$liveTypes = Join-Path $wad 'modules\Domenia-Live.Types.cs'
if (-not [IO.File]::Exists($liveTypes)) { throw ('Fichier absent : ' + $liveTypes) }
Add-Type -Path $liveTypes -ErrorAction SilentlyContinue

. ([scriptblock]::Create((Get-FunctionTextFromFile $core 'Invoke-GlobalSearch')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $reconcileUi 'Complete-DomeniaReconcile')))

$script:SavedFunctions=@{}
function Set-TestFunction {
    param([string]$Name,[scriptblock]$Body)
    $path = "function:script:$Name"
    if (Test-Path $path) { $script:SavedFunctions[$Name] = (Get-Item $path).ScriptBlock }
    else { $script:SavedFunctions[$Name] = $null }
    Set-Item $path $Body
}
function Restore-TestFunctions {
    foreach ($name in @($script:SavedFunctions.Keys)) {
        $saved = $script:SavedFunctions[$name]
        if ($null -eq $saved) { Remove-Item "function:script:$name" -ErrorAction SilentlyContinue }
        else { Set-Item "function:script:$name" $saved }
    }
    $script:SavedFunctions=@{}
}

Test-Case 'D021 : Invoke-GlobalSearch passe par Get-DomeniaProjection List' {
    $script:SavedFunctions=@{}
    try {
        $script:ProjectionCalls=0
        $script:ProjectionCheckCalls=0
        $script:SentinelProps=@('objectGUID','name','uSNChanged')
        $script:CapturedPayload=$null

        Set-TestFunction 'Get-DomeniaProjection' {
            param($Kind)
            $script:ProjectionCalls++
            return $script:SentinelProps
        }
        Set-TestFunction 'Test-DomeniaProjectionMinimal' {
            param($Requested)
            $script:ProjectionCheckCalls++
            return [pscustomobject]@{Minimal=$true;Heavy=@()}
        }
        Set-TestFunction 'Start-UiTask' {
            param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$DisableControls,$TimeoutSeconds,$StatusText,$SuccessHandler,$ErrorHandler)
            $script:CapturedPayload=$Payload
            return 'test-task'
        }
        Set-TestFunction 'Begin-DomeniaLiveSearch' {
            param($State,$Payload)
            Add-Member -InputObject $State -NotePropertyName LiveState -NotePropertyValue ([pscustomobject]@{Rows=@()}) -Force
            return [pscustomobject]@{LiveState=$null}
        }
        Set-TestFunction 'Get-DomeniaControl' {
            param($Name)
            return [pscustomobject]@{Text='100';Items=@();SelectedIndex=-1;SelectedItem=$null;IsEnabled=$true}
        }
        Set-TestFunction 'Set-DomeniaControlText' { param($Name,$Text) }
        Set-TestFunction 'Get-DomeniaSearchText' { param($Mode) return '*' }
        Set-TestFunction 'Get-DomeniaSearchScope' {
            param($Mode)
            return [pscustomobject]@{BaseDn='DC=example,DC=invalid';Scope='Subtree'}
        }
        Set-TestFunction 'Get-CfgValue' { param($Section,$Name,$Default) return $Default }
        Set-TestFunction 'Get-GlobalSelectedTypeFilter' { param($Mode) return '(objectClass=*)' }
        Set-TestFunction 'Get-TypeLdapFilter' { param($Type) return '(objectClass=*)' }
        Set-TestFunction 'Escape-LdapValue' { param($Value,[switch]$KeepWildcard) return [string]$Value }
        Set-TestFunction 'Set-DomeniaSearchMode' { param($Mode) }
        Set-TestFunction 'Invalidate-DomeniaSearchResults' { }
        Set-TestFunction 'Update-DomeniaSearchScopeUi' { }
        Set-TestFunction 'Select-DomeniaWorkspace' { param($Workspace) }
        Set-TestFunction 'Stop-DomeniaSelectionOpenTimer' { }
        Set-TestFunction 'Clear-DomeniaCurrentObjectRequest' { param($RequestId) }
        Set-TestFunction 'Reset-DomeniaSelectionBoundViews' { }
        Set-TestFunction 'Show-DomeniaOperationError' { param($Operation,$ErrorRecordOrException,[switch]$NoPopup) }
        Set-TestFunction 'Test-DomeniaAccessBusyWrite' { return $false }
        Set-TestFunction 'Test-DomeniaDraftNavigation' { param($DN,[switch]$Refresh) return $true }
        Set-TestFunction 'Get-DomeniaWorkViews' { return @() }
        Set-TestFunction 'Get-DomeniaGlobalSearchPlan' {
            param($Text,$TypeFilter,$MinimumLength,$SyntaxEnabled)
            return [pscustomobject]@{Valid=$true;Kind='Browse';Filter='';Hint='';Reason='';MultiWordFilter=''}
        }
        Set-TestFunction 'Get-DomeniaFeatureFlag' { param($Name,$Default=$true) return $true }

        $script:GlobalSearchGeneration=1
        $script:ActiveSearchViewId=''
        $script:SelectedBranchDn=''
        $script:Conn=[pscustomobject]@{Domain='example.invalid';Server='dc1';BaseDn='DC=example,DC=invalid';BindUser='svc'}
        $script:DemoMode=$false
        $script:AsyncEngineClosing=$false
        $script:ActiveWriteTaskId=''
        $script:WriteState='Known'
        $script:AccessState=$null
        $script:DirectoryCredentialFaulted=$false
        $script:ShowingCachedObject=$false
        $script:CurrentObjectRequestId=''
        $script:CurrentObjectRequestState=$null
        $script:SelectedObject=$null
        $script:SelectionLoad=$null

        [void](Invoke-GlobalSearch -SearchMode 'OU' -SilentError)

        Assert-True ($script:ProjectionCalls -gt 0) 'Get-DomeniaProjection non appele.'
        Assert-True ($script:ProjectionCheckCalls -gt 0) 'Test-DomeniaProjectionMinimal non appele.'
        Assert-True ($null -ne $script:CapturedPayload) 'Start-UiTask n a pas recu de payload.'
        Assert-Equal ($script:SentinelProps -join '|') (@($script:CapturedPayload.Properties) -join '|') 'La charge utile ne vient pas de la projection.'
        Assert-True (@($script:CapturedPayload.Properties) -notcontains 'memberOf') 'La projection liste contient memberOf.'
    } finally {
        Restore-TestFunctions
    }
}

Test-Case 'D023 : le vrai XAML virtualise 100, 500 et 2000 lignes et recycle apres defilement' {
    . ([scriptblock]::Create((Get-FunctionTextFromFile $core 'Get-MainXaml')))
    . (Join-Path $modules 'Domenia-UX.UI.ps1')
    function Get-DomeniaControl { param($Name) return $window.FindName($Name) }
    function Get-CfgValue { param($Section,$Name,$Default) return $Default }
    function Set-DomeniaSetting { param($Name,$Value) throw 'Aucune preference ecrite par ce test' }
    $xaml=Get-MainXaml
    $reader=[Xml.XmlNodeReader]::new([xml]$xaml);$window=$null
    $oldWindow=$script:Window;$oldCtrl=$script:Ctrl;$cacheHost=$null
    function Settle-CacheLayout {
        for($pass=0;$pass -lt 2;$pass++){
            $cacheHost.Measure([Windows.Size]::new(1280,800))
            $cacheHost.Arrange([Windows.Rect]::new(0,0,1280,800));$cacheHost.UpdateLayout()
            $window.Dispatcher.Invoke([action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
        }
    }
    try {
        $window=[Windows.Markup.XamlReader]::Load($reader)
        $window.ShowActivated=$false;$window.ShowInTaskbar=$false;$window.WindowState='Normal';$window.Width=1280;$window.Height=800
        $grid=$window.FindName('DgObjects');$window.FindName('WorkspaceTabs').SelectedItem=$window.FindName('WsSearch')
        Assert-True $grid.EnableRowVirtualization;Assert-True $grid.EnableColumnVirtualization
        Assert-True ([Windows.Controls.VirtualizingPanel]::GetIsVirtualizing($grid))
        Assert-Equal 'Recycling' ([Windows.Controls.VirtualizingPanel]::GetVirtualizationMode($grid))
        Assert-True ([Windows.Controls.ScrollViewer]::GetCanContentScroll($grid))
        $script:Window=$window;$script:Ctrl=@{}
        foreach($match in [regex]::Matches($xaml,'x:Name="([^"]+)"')){
            $name=$match.Groups[1].Value;$control=$window.FindName($name)
            if($null -ne $control){$script:Ctrl[$name]=$control}
        }
        # Session-0 can cap the HWND below the requested window size. Arrange the same real XAML in a
        # native WPF client host: real ScrollViewer clips and recycling, no substituted geometry or scaling.
        $window.Show();$content=$window.Content;$window.Content=$null
        $cacheHost=[Windows.Controls.Grid]::new();$cacheHost.Width=1280;$cacheHost.Height=800
        $cacheHost.Resources=$window.Resources;$cacheHost.UseLayoutRounding=$true
        $cacheHost.SetValue([Windows.Documents.TextElement]::FontFamilyProperty,$window.FontFamily)
        $cacheHost.SetValue([Windows.Documents.TextElement]::FontSizeProperty,$window.FontSize)
        [void]$cacheHost.Children.Add($content);$window.Content=[Windows.Controls.Grid]::new()
        Settle-CacheLayout;Set-DomeniaUiZoom -Percent 100;Settle-CacheLayout
        Assert-True ($cacheHost.ActualWidth -eq 1280 -and $cacheHost.ActualHeight -eq 800) 'Le host WPF doit atteindre le viewport demande.'
        Assert-True ($grid.ActualHeight -ge 68) ('Grille sans viewport utilisable : '+$grid.ActualHeight)
        . ([scriptblock]::Create((Get-FunctionTextFromFile (Join-Path $modules 'Domenia-Search.UI.ps1') 'Get-DomeniaGridScrollViewer')))
        $actualViewer=Get-DomeniaGridScrollViewer $grid
        Assert-True ($null -ne $actualViewer) 'Barre de defilement native du DataGrid absente.'
        $counts=@{}
        foreach($n in @(100,500,2000)){
            $rows=[Collections.ObjectModel.ObservableCollection[object]]::new()
            for($i=0;$i -lt $n;$i++){[void]$rows.Add([pscustomobject]@{Type='Machine';Name=('PC-'+$i);DN=('CN=PC-'+$i+',DC=example,DC=invalid');Guid=[string]$i})}
            $grid.ItemsSource=$rows;$grid.ScrollIntoView($rows[0]);Settle-CacheLayout
            $realized=0;for($i=0;$i -lt $n;$i++){if($null -ne $grid.ItemContainerGenerator.ContainerFromIndex($i)){$realized++}}
            $counts[$n]=$realized
            Assert-True ($realized -gt 0 -and $realized -le (3*[Math]::Ceiling($grid.ActualHeight/34)+8)) ("Virtualisation absente : $realized/$n, hauteur=$($grid.ActualHeight)")
        }
        Assert-True (($counts[2000]-$counts[100]) -le 2) 'Le nombre de lignes realisees depend du total'
        # WPF retains the current cell's row even outside the viewport. Move the current cell
        # with the explicit selection before checking that the formerly current row is recycled.
        $grid.SelectedItem=$rows[1999]
        $grid.CurrentCell=[Windows.Controls.DataGridCellInfo]::new($rows[1999],$grid.Columns[0])
        # ScrollIntoView is ignored when this detached session-0 host is not loaded/visible.
        # Exercise the actual scrollbar instead; container recycling and the negative control stay strict.
        $actualViewer.ScrollToEnd();Settle-CacheLayout
        Assert-True ($actualViewer.VerticalOffset -gt 0) 'Le DataGrid n a pas reellement defile.'
        Assert-True ($null -eq $grid.ItemContainerGenerator.ContainerFromIndex(0)) 'La premiere ligne reste realisee apres defilement'
        Assert-True ($null -ne $grid.ItemContainerGenerator.ContainerFromIndex(1999)) 'La derniere ligne est inaccessible'
        # Negative control: an unbounded ancestor must make this test detect lost virtualization.
        $shell=$window.FindName('UxShellGrid')
        [Windows.Data.BindingOperations]::ClearBinding($shell,[Windows.FrameworkElement]::HeightProperty);$shell.Height=[double]::NaN
        $rows=[Collections.ObjectModel.ObservableCollection[object]]::new()
        for($i=0;$i -lt 300;$i++){[void]$rows.Add([pscustomobject]@{Type='Machine';Name=('NEG-'+$i)})}
        $grid.ItemsSource=$rows;Settle-CacheLayout
        $realized=0;for($i=0;$i -lt 300;$i++){if($null -ne $grid.ItemContainerGenerator.ContainerFromIndex($i)){$realized++}}
        Assert-Equal 300 $realized 'Le controle negatif ne detecte pas la perte de borne'
        $script:CaseDetail='Detached WPF client host1280x800; native ScrollViewer.ScrollToEnd; virtualization100/500/2000 and negative control300; HWND='+$window.ActualWidth+'x'+$window.ActualHeight
    } finally {$reader.Close();if($null -ne $cacheHost){$cacheHost.Children.Clear()};if($null -ne $window){$window.Close()};$script:Window=$oldWindow;$script:Ctrl=$oldCtrl}
}

Test-Case 'D022 : Complete-DomeniaReconcile n met en file que les lignes modifiees' {
    $script:SavedFunctions=@{}
    try {
        $script:Continuity=@{Mutation=0}
        $script:Reconcile=[pscustomobject]@{Job='';Events=[Collections.Generic.Queue[object]]::new();Checkpoint=$null}
        $script:Live=@{Identity='test';Search=$null}

        $rows=[Collections.ObjectModel.ObservableCollection[object]]::new()
        $guids=@()
        for($i=0;$i -lt 100;$i++){
            $row=New-Object Domenia.Live.ResultRow
            $g=[guid]::NewGuid().ToString()
            $row.Set('Guid',$g)
            $row.Set('DN','CN=obj'+$i+',DC=example,DC=invalid')
            $row.Set('Name','obj'+$i)
            $row.Set('Login','obj'+$i)
            $row.Set('UPN','obj'+$i+'@example.invalid')
            $row.Set('State','Actif')
            $row.Set('OS','')
            $row.Set('LastLogon','')
            $row.Set('Description','')
            $row.Set('Changed','')
            [void]$rows.Add($row)
            $guids+=$g
        }

        $grid=New-Object System.Windows.Controls.DataGrid
        $grid.AutoGenerateColumns=$false
        $grid.CanUserAddRows=$false
        $grid.EnableRowVirtualization=$true
        $grid.ItemsSource=$rows
        $grid.SelectedIndex=49
        $grid.UpdateLayout()
        $grid.ScrollIntoView($grid.SelectedItem)

        $selected=$grid.SelectedItem
        $selectedIndex=$grid.SelectedIndex

        $s=[pscustomobject]@{
            Rows=$rows
            Map=@{}
            Fresh=@{}
            FreshOrder=[Collections.Generic.List[object]]::new()
            CacheKeys=[Collections.Generic.Queue[string]]::new()
            State=[pscustomobject]@{SearchMode='OU';Search='';Limit=500;PreserveSelectionDn=''}
            Identity='test'
            Epoch=[long]1
            RefreshNeeded=$false
        }
        $script:Live.Search=$s

        $incoming=@()
        for($i=0;$i -lt 100;$i++){
            $state='Actif'
            if($i -eq 49){$state='Inactif'}
            $incoming += [pscustomobject]@{
                Guid=$guids[$i]
                DN='CN=obj'+$i+',DC=example,DC=invalid'
                Name='obj'+$i
                Login='obj'+$i
                UPN='obj'+$i+'@example.invalid'
                State=$state
                OS=''
                LastLogon=''
                Description=''
                Changed=''
            }
        }

        $result=[pscustomobject]@{
            Rows=$incoming
            Capped=$false
            Filter='test'
            ObservedUtc=[datetime]::UtcNow.ToString('o')
            Dc='dc1'
            InvocationId='inv1'
            HighestUsn='1'
            BaseDn='DC=example,DC=invalid'
            Scope='Subtree'
        }
        $state=[pscustomobject]@{
            Epoch=[long]1
            Identity='test'
            Filter='test'
            Search=$s
            Mutation=0
        }

        Set-TestFunction 'Test-DomeniaLiveSearchActive' { return $true }
        Set-TestFunction 'Get-DomeniaEffectiveWorkerResult' { param($Result,$RequiredProperties) return $Result }
        Set-TestFunction 'Get-DomeniaLiveObjectKey' {
            param($Row)
            return ([string](Get-DomeniaMember $Row 'Guid' '')).ToLowerInvariant()
        }
        Set-TestFunction 'Set-Status' { param($Text,$Level) $script:Statuses.Add([string]$Text) }

        [void](Complete-DomeniaReconcile -Result $result -State $state)

        Assert-Equal 1 $script:Reconcile.Events.Count 'Un seul evenement de ligne attendu.'
        Assert-False $s.RefreshNeeded 'RefreshNeeded pose pour une colonne non filtree.'
        Assert-True ([object]::ReferenceEquals($selected,$grid.SelectedItem)) 'La selection a change.'
        Assert-Equal $selectedIndex $grid.SelectedIndex 'L index selectionne a change.'
        Assert-True ([object]::ReferenceEquals($rows,$grid.ItemsSource)) 'La collection a ete remplacee.'
    } finally {
        Restore-TestFunctions
    }
}

# ---------------------------------------------------------------- Lot cache F2 : D028 save-state labels from the rule
# Real Get-DomeniaPersistenceState, Start/Complete/Fail-DomeniaStorageWork, Reset-DomeniaLinkBaseline (Storage.UI),
# real Initialize-DomeniaGuard tick (Guard.UI) and real rule Get-DomeniaPersistenceLabel (Cache.Model). Doubles only at
# the boundary (controls, engine). Removing the call to the rule, the in-flight count or the conflict state fails a case.
$guardUi = Join-Path $modules 'Domenia-Guard.UI.ps1'
$guardModel = Join-Path $modules 'Domenia-Guard.Model.ps1'
foreach ($path in @($guardUi,$guardModel)) { if (-not [IO.File]::Exists($path)) { throw ('Fichier absent : ' + $path) } }
foreach ($name in @('Get-DomeniaPersistenceState','Start-DomeniaStorageWork','Complete-DomeniaStorageWork','Fail-DomeniaStorageWork','Reset-DomeniaLinkBaseline')) {
    . ([scriptblock]::Create((Get-FunctionTextFromFile $storageUi $name)))
}
# The persistence timer of other cases must keep calling the empty double: the real writer is enabled per case only.
$script:StartStorageReal = (Get-Item function:Start-DomeniaStorageWork).ScriptBlock
function Start-DomeniaStorageWork { }
. ([scriptblock]::Create((Get-FunctionTextFromFile $guardUi 'Initialize-DomeniaGuard')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $guardModel 'Get-DomeniaPercentile')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $core 'Get-DomeniaEffectiveWorkerResult')))
function New-TestLinkItem {
    param([string]$Key,[string]$User)
    return [pscustomobject]@{QueueKey=('Link|test-scope.db|' + $Key);Kind='Link';Key=$Key;Path='test-scope.db';Expected='';Row=[pscustomobject]@{Computer=$Key;UserLogin=$User;Source='Console'};Remove=$false;Epoch=[long]1}
}

Test-Case 'D028 : Fiabilite affiche le libelle de la regle' {
    $script:SavedFunctions=@{}
    try {
        $script:GuardTexts = New-Object 'System.Collections.Generic.List[string]'
        $script:LabelCalls = 0
        $script:LabelReal = (Get-Command Get-DomeniaPersistenceLabel -CommandType Function).ScriptBlock
        # Doubles seen by the Guard timer: script scope.
        Set-TestFunction 'Get-DomeniaPersistenceLabel' { param([int]$Pending=0,[int]$Failed=0,[bool]$Suspended=$false,[bool]$Unavailable=$false,[int]$Conflicts=0) $script:LabelCalls++; & $script:LabelReal -Pending $Pending -Failed $Failed -Suspended $Suspended -Unavailable $Unavailable -Conflicts $Conflicts }
        Set-TestFunction 'Get-DomeniaControl' { param($Name) if ([string]$Name -eq 'TabGuard') { return [pscustomobject]@{IsSelected=$true} }; return $null }
        Set-TestFunction 'Set-DomeniaControlText' { param($Name,$Text) if ([string]$Name -eq 'LblGuardMetrics') { $script:GuardTexts.Add([string]$Text) }; return $true }
        Set-TestFunction 'Set-DomeniaItemsSource' { param($Name,$Rows) return $true }
        Set-TestFunction 'Get-DomeniaFavouriteSearches' { return @() }
        Set-TestFunction 'Start-DomeniaReceiptRefresh' { }
        $script:Guard = $null; $script:ReceiptReady = $true; $script:ReceiptRefreshNeeded = $false
        Initialize-DomeniaPersistence; Stop-TestTimers
        Initialize-DomeniaGuard
        $read = {
            param([string]$Why)
            $script:GuardTexts.Clear()
            Assert-True (Wait-WiringCondition { $script:GuardTexts.Count -gt 0 } 3000) ('Aucun tick Fiabilite : ' + $Why)
            return $script:GuardTexts[$script:GuardTexts.Count - 1]
        }
        $script:Persistence.Pending['a'] = [pscustomobject]@{QueueKey='a'}; $script:Persistence.Pending['b'] = [pscustomobject]@{QueueKey='b'}
        $pending = & $read 'attente'
        Assert-True ($pending -match 'Enregistrement local : En memoire : 2 modification\(s\) a enregistrer\.') ('Attente : ' + $pending)
        $script:Persistence.Pending.Clear(); $script:Persistence.Failures = 1
        $failed = & $read 'echec'
        Assert-True ($failed -match 'Enregistrement local : En memoire : 1 enregistrement\(s\) en echec, nouvel essai prevu\.') ('Echec : ' + $failed)
        $script:Persistence.Failures = 3
        $suspended = & $read 'suspendu'
        Assert-True ($suspended -match 'suspendu') ('Trois echecs : ' + $suspended)
        $script:Persistence.Failures = 0
        $saved = & $read 'enregistre'
        Assert-True ($saved -match 'Enregistrement local : Enregistre\. Mesure indicative') ('Enregistre : ' + $saved)
        foreach ($text in @($pending,$failed,$suspended,$saved)) {
            Assert-False ($text -match 'Cache en attente') ('Ancien libelle Fiabilite : ' + $text)
            Assert-True ($text -match '^Retard du Dispatcher \(local\) p50/p95 : ') ('Debut de phrase modifie : ' + $text)
        }
        Assert-True ($script:LabelCalls -ge 4) ('La regle Get-DomeniaPersistenceLabel n est pas appelee par le tick : ' + $script:LabelCalls)
    } finally {
        if ($null -ne $script:Guard -and $null -ne $script:Guard.Timer) { try { $script:Guard.Timer.Stop() } catch { } }
        $script:Guard = $null
        Restore-TestFunctions
    }
}

Test-Case 'D028 : un lot en cours d ecriture reste En memoire jusqu au rappel' {
    $script:SavedFunctions=@{}
    try {
        Set-TestFunction 'Start-DomeniaStorageWork' $script:StartStorageReal
        Set-TestFunction 'Get-DomeniaStorageWorkerCode' { return '' }
        Set-TestFunction 'Start-UiTask' {
            param($Name,$OperationId,$Code,$Payload,$CallbackState,$SuccessHandler,$ErrorHandler,[switch]$NonCancellable,$TimeoutSeconds)
            $script:StartUiCalls++; $script:StartUiOperations.Add([string]$OperationId)
            $id = 'store-' + $script:StartUiCalls
            $script:AsyncJobs[$id] = [pscustomobject]@{Id=$id;OperationId=[string]$OperationId}
            $script:LastStorageState = $CallbackState
            return $id
        }
        Initialize-DomeniaPersistence; Stop-TestTimers
        foreach ($k in @('PC1','PC2','PC3')) { $i = New-TestLinkItem $k ('u' + $k); $script:Persistence.Pending[$i.QueueKey] = $i }
        Start-DomeniaStorageWork
        Assert-Equal 1 $script:StartUiCalls 'Un seul lot attendu.'
        Assert-Equal 'LocalStore' $script:StartUiOperations[0]
        Assert-Equal 0 $script:Persistence.Pending.Count 'Les elements quittent la file au depart du lot.'
        Assert-Equal 3 $script:Persistence.InFlight 'Lot en cours non compte.'
        Assert-Equal 'En memoire : 3 modification(s) a enregistrer.' (Get-DomeniaPersistenceState).Label 'Libelle pendant l ecriture :'
        [void]$script:AsyncJobs.Remove([string]$script:Persistence.Job)
        Complete-DomeniaStorageWork ([pscustomobject]@{Saved=$true;Conflicts=@();Count=3}) $script:LastStorageState
        Assert-Equal 0 $script:Persistence.InFlight 'InFlight apres le rappel.'
        Assert-Equal 'Enregistre.' (Get-DomeniaPersistenceState).Label 'Libelle apres le rappel :'
        Assert-Equal 'uPC1' $script:LinkBaseline['PC1'].UserLogin 'Reference non mise a jour.'
        # Failure: the batch is requeued, a newer request for the same key is never overwritten.
        foreach ($k in @('PC1','PC2')) { $i = New-TestLinkItem $k ('v' + $k); $script:Persistence.Pending[$i.QueueKey] = $i }
        Start-DomeniaStorageWork
        Assert-Equal 2 $script:Persistence.InFlight 'Second lot non compte.'
        $newer = New-TestLinkItem 'PC1' 'plus-recent'
        $script:Persistence.Pending[$newer.QueueKey] = $newer
        [void]$script:AsyncJobs.Remove([string]$script:Persistence.Job)
        Fail-DomeniaStorageWork 'SQLite code 5 : database is locked' $script:LastStorageState
        Assert-Equal 0 $script:Persistence.InFlight 'InFlight apres l echec.'
        Assert-Equal 2 $script:Persistence.Pending.Count 'Remise en file.'
        Assert-True ([object]::ReferenceEquals($script:Persistence.Pending[$newer.QueueKey],$newer)) 'La demande plus recente a ete ecrasee par la remise en file.'
        Assert-Equal 'En memoire : 1 enregistrement(s) en echec, nouvel essai prevu.' (Get-DomeniaPersistenceState).Label 'Libelle apres echec :'
    } finally { Restore-TestFunctions }
}

Test-Case 'D028 : Live et Fiabilite affichent le meme etat' {
    Initialize-DomeniaPersistence; Stop-TestTimers
    $script:Persistence.Pending['x'] = [pscustomobject]@{QueueKey='x'}
    $script:Live = [pscustomobject]@{CacheReady=$true;SaveQueue=@{a=1;b=2};QueryToSave=$null;SaveInFlight=0;SaveFault=''}
    $s = Get-DomeniaPersistenceState
    Assert-Equal 3 $s.Pending 'Live.SaveQueue et Persistence additionnes.'
    Assert-Equal 'En memoire : 3 modification(s) a enregistrer.' $s.Label
    # A failed read with nothing waiting is not a save failure.
    $script:Persistence.Pending.Clear(); $script:Live.SaveQueue = @{}; $script:Live.SaveFault = 'Lecture du cache impossible'
    Assert-Equal 'Enregistre.' (Get-DomeniaPersistenceState).Label 'Echec de lecture presente comme echec d enregistrement :'
    # The same fault while Live work waits is one.
    $script:Live.QueryToSave = [pscustomobject]@{QueryKey='q'}
    Assert-True ((Get-DomeniaPersistenceState).Label -match 'en echec, nouvel essai prevu') 'Echec d ecriture Live non signale.'
    $script:Live.QueryToSave = $null; $script:Live.SaveFault = ''
    $script:Live.SaveInFlight = 2
    Assert-Equal 'En memoire : 2 modification(s) a enregistrer.' (Get-DomeniaPersistenceState).Label 'Ecriture Live en cours :'
    $script:Live.SaveInFlight = 0; $script:Live.CacheReady = $false
    $u = (Get-DomeniaPersistenceState).Label
    Assert-True ($u -match 'indisponible' -and $u -notmatch 'Fiabilite') ('Stockage indisponible : ' + $u)
    $script:Live.CacheReady = $true; $script:Persistence.Failures = 3
    Assert-True ((Get-DomeniaPersistenceState).Label -match 'suspendu') 'Suspension non signalee.'
    # Both views read the same function.
    Assert-True ((Get-FunctionTextFromFile $guardUi 'Initialize-DomeniaGuard').Contains("Enregistrement local : '+(Get-DomeniaPersistenceState).Label+")) 'Fiabilite ne lit pas Get-DomeniaPersistenceState.'
    Assert-True ((Get-FunctionTextFromFile $liveUi 'Invoke-DomeniaLiveTick').Contains('$save=(Get-DomeniaPersistenceState).Label')) 'La ligne Live ne lit pas Get-DomeniaPersistenceState.'
    # Pure read: nothing is initialized when the states are absent.
    $script:Persistence = $null; $script:Live = $null
    Assert-Equal 'Enregistre.' (Get-DomeniaPersistenceState).Label
    Assert-True ($null -eq $script:Persistence) 'La lecture a initialise la persistance.'
}

Test-Case 'D028 : conflit visible jusqu au rechargement' {
    Initialize-DomeniaPersistence; Stop-TestTimers
    $script:UserMachineLinks = @([pscustomobject]@{Computer='PC1';UserLogin='dave';Source='Console'},[pscustomobject]@{Computer='PC2';UserLogin='erin';Source='Console'})
    $script:LinkBaseline = @{PC1=[pscustomobject]@{Computer='PC1';UserLogin='alice';Source='Console'};PC2=[pscustomobject]@{Computer='PC2';UserLogin='bob';Source='Console'}}
    Assert-True (Queue-DomeniaLinkChanges) 'Mise en file refusee.'
    $items = @($script:Persistence.Pending.Values)
    Assert-Equal 2 $items.Count
    $script:Persistence.Pending.Clear()
    Complete-DomeniaStorageWork ([pscustomobject]@{Saved=$true;Conflicts=@('PC1');Count=2}) ([pscustomobject]@{Items=$items;Epoch=[long]1})
    Assert-True ($script:Persistence.Conflicts.ContainsKey('PC1') -and $script:Persistence.Conflicts.Count -eq 1) 'Conflit non garde.'
    Assert-Equal 'alice' $script:LinkBaseline['PC1'].UserLogin 'La reference PC1 a change malgre le conflit.'
    Assert-Equal 'erin' $script:LinkBaseline['PC2'].UserLogin 'La reference PC2 n a pas suivi l ecriture.'
    Assert-True (@($script:Statuses | Where-Object { $_ -match 'Association modifiee ailleurs : PC1' }).Count -eq 1) 'Avertissement absent.'
    $label = (Get-DomeniaPersistenceState).Label
    Assert-Equal 'En memoire : 1 association(s) modifiee(s) ailleurs, non enregistree(s). Rechargez les associations : Comptes > Changer de compte, ou redemarrage.' $label 'Libelle de conflit :'
    # Quiet path: PC1 is not resubmitted and stays silent.
    $script:Statuses.Clear()
    Assert-True (Queue-DomeniaLinkChanges -Quiet -MaxItems 64) 'Chemin silencieux en erreur.'
    Assert-Equal 0 $script:Persistence.Pending.Count 'Le chemin silencieux renvoie PC1.'
    Assert-False $script:Persistence.LinkBusy
    Assert-Equal 0 $script:Statuses.Count
    # Another key still goes through the quiet path.
    $script:UserMachineLinks = @($script:UserMachineLinks) + @([pscustomobject]@{Computer='PC3';UserLogin='fred';Source='Console'})
    Assert-True (Queue-DomeniaLinkChanges -Quiet -MaxItems 64)
    Assert-Equal 'PC3' ((@($script:Persistence.Pending.Values) | ForEach-Object { [string]$_.Key }) -join ',') 'Chemin silencieux :'
    $script:Persistence.Pending.Clear(); $script:Persistence.LinkBusy = $false
    # The explicit path still submits PC1 (the writer will warn again).
    Assert-True (Queue-DomeniaLinkChanges) 'Chemin explicite refuse.'
    Assert-True (@($script:Persistence.Pending.Values | Where-Object { $_.Key -eq 'PC1' }).Count -eq 1) 'Le chemin explicite ne soumet plus PC1.'
    # A reload of the associations ends the conflict state.
    $script:Persistence.Pending.Clear(); $script:Persistence.LinkBusy = $false
    Reset-DomeniaLinkBaseline
    Assert-Equal 0 $script:Persistence.Conflicts.Count 'Conflit garde apres rechargement.'
    Assert-Equal 'Enregistre.' (Get-DomeniaPersistenceState).Label
}

Test-Case 'D028 : le geste nomme par le libelle de conflit recharge les associations' {
    # The label and the warning name Comptes > Changer de compte: that button must reach Reset-DomeniaLinkBaseline, the
    # only place that ends the conflict state (the real reload is executed by Test-DomeniaWiringMoteur, D028 case 1).
    $gesture = 'Comptes > Changer de compte'
    Assert-True ((Get-DomeniaPersistenceLabel -Conflicts 1).Contains($gesture)) 'Le libelle de conflit ne nomme pas le geste de rechargement.'
    Assert-True ((Get-FunctionTextFromFile $storageUi 'Complete-DomeniaStorageWork').Contains($gesture)) 'L avertissement de conflit ne nomme pas le geste de rechargement.'
    $coreText = [IO.File]::ReadAllText($core)
    Assert-True ([regex]::IsMatch($coreText,'x:Name="TabAccounts" Header="Comptes"')) 'Onglet Comptes absent.'
    Assert-True ([regex]::IsMatch($coreText,'x:Name="BtnAccountAdRelogin" Content="Changer de compte"')) 'Bouton Changer de compte absent.'
    $ct = $null; $ce = $null
    $coreAst = [Management.Automation.Language.Parser]::ParseFile($core,[ref]$ct,[ref]$ce)
    $findCalls = {
        param([string]$FunctionName,[string]$Command)
        $fn = @($coreAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $FunctionName },$true))
        if ($fn.Count -ne 1) { throw ('Fonction du coeur absente ou ambigue : ' + $FunctionName) }
        return @($fn[0].FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Command },$true)).Count
    }
    $wire = Get-FunctionTextFromFile $core 'Wire-Events'
    Assert-True ([regex]::IsMatch($wire,'\$script:Ctrl\["BtnAccountAdRelogin"\]\.Add_Click\(\{\s*Start-DomeniaAccountRelogin\s*\}\)')) 'Changer de compte ne lance pas Start-DomeniaAccountRelogin.'
    Assert-True ((& $findCalls 'Start-DomeniaAccountRelogin' 'Request-DomeniaUserMachineLinks') -ge 1) 'Start-DomeniaAccountRelogin ne recharge pas les associations.'
    # FI-19: the associations are read by the LocalIndexRead worker; its callback is what ends the conflict state.
    $complete = Get-FunctionTextFromFile (Join-Path $modules 'Domenia-Engine.UI.ps1') 'Complete-DomeniaUserMachineLinksUi'
    Assert-True ($complete.Contains('Reset-DomeniaLinkBaseline')) 'Le rappel des associations ne termine pas l etat de conflit.'
    Assert-True ((Get-FunctionTextFromFile (Join-Path $modules 'Domenia-Engine.UI.ps1') 'Request-DomeniaUserMachineLinks').Contains("-Action 'UserMachineLinks'")) 'Les associations ne passent pas par LocalIndexRead.'
}

Test-Case 'D028 : anciens libelles retires de Fiabilite et de la ligne Live' {
    $guardText = [IO.File]::ReadAllText($guardUi)
    $liveText = [IO.File]::ReadAllText($liveUi)
    Assert-False ($guardText.Contains('Cache en attente')) 'Fiabilite garde Cache en attente.'
    $e = [string][char]0x00E9
    foreach ($old in @(('cache uniquement en m' + $e + 'moire'),('m' + $e + 'moire locale non enregistr' + $e + 'e'),'aucun enregistrement en attente',"'enregistrement en cours'")) {
        Assert-False ($liveText.Contains($old)) ('Ancien libelle Live : ' + $old)
    }
}

Test-Case 'D028 : demande differee de liens annoncee avant sa mise en file' {
    Reset-TestState;$script:Live=$null
    $script:Persistence=[pscustomobject]@{Pending=@{};InFlight=0;Failures=0;Conflicts=@{};LinkRequestTimer=[pscustomobject]@{IsEnabled=$true};LinkPersistenceMore=$false}
    Assert-Equal 1 (Get-DomeniaPersistenceState).Pending
    $script:Persistence.LinkRequestTimer.IsEnabled=$false;$script:Persistence.LinkPersistenceMore=$true
    Assert-Equal 1 (Get-DomeniaPersistenceState).Pending
    $script:Persistence.LinkPersistenceMore=$false
    Assert-Equal 0 (Get-DomeniaPersistenceState).Pending
}

Test-Case 'D028 : le chargeur declare l etat d enregistrement et ses dependances' {
    $lt = $null; $le = $null
    $loaderAst = [Management.Automation.Language.Parser]::ParseFile($loader,[ref]$lt,[ref]$le)
    $planFn = @($loaderAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-DomeniaRuntimeModulePlan' },$true))[0]
    $plan = @(& ([scriptblock]::Create($planFn.Body.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))))
    $byFile = @{}
    foreach ($m in $plan) { $byFile[[string]$m.File] = $m }
    $storage = $byFile['Domenia-Storage.UI.ps1']
    Assert-True (@($storage.Functions) -contains 'Get-DomeniaPersistenceState') 'Get-DomeniaPersistenceState non declaree pour Storage.UI.'
    Assert-True (@($storage.Requires) -contains 'Domenia-Cache.Model.ps1') 'Storage.UI ne requiert pas Cache.Model.'
    Assert-True (@($byFile['Domenia-Live.UI.ps1'].Requires) -contains 'Domenia-Storage.UI.ps1') 'Live.UI ne requiert pas Storage.UI.'
    $guard = $byFile['Domenia-Guard.UI.ps1']
    Assert-True ([string]$guard.Phase -eq 'Modules' -and @($guard.Requires) -contains 'Domenia-Storage.UI.ps1') 'Guard.UI sans Phase Modules ni Requires Storage.UI.'
    # The integration of this lot rebuilds the Selection.UI entry from lot-cache.json: its Shell.Model requirement
    # (lot interface, Get-DomeniaSelectionPreview) must survive it.
    Assert-True (@($byFile['Domenia-Selection.UI.ps1'].Requires) -contains 'Domenia-Shell.Model.ps1') 'Selection.UI a perdu Requires Shell.Model.'
}

try { Stop-TestTimers } catch { }
# ---------------------------------------------------------------- D113 : LegacyImport (G1)
$storageWorker = Join-Path $modules 'Domenia-Storage.Worker.ps1'
if (-not [IO.File]::Exists($storageWorker)) { throw ('Fichier absent : ' + $storageWorker) }
. ([scriptblock]::Create((Get-FunctionTextFromFile $storageWorker 'Get-DomeniaStorageWorkerCode')))
foreach ($name in @('Initialize-DomeniaPersistence','Queue-DomeniaMetadata','Start-DomeniaStorageWork','Complete-DomeniaStorageWork','Fail-DomeniaStorageWork')) {
    . ([scriptblock]::Create((Get-FunctionTextFromFile $storageUi $name)))
}
$script:StartStorageReal = (Get-Item function:Start-DomeniaStorageWork).ScriptBlock
function Start-DomeniaStorageWork { }

function Set-Status { param($Text,$Level) $script:Statuses.Add([string]$Text); if($Level){$script:StatusLevels.Add([string]$Level)} }
function Add-DomeniaUiLog { param($Area,$Text,$Level) $script:Logs.Add([string]$Text); if($Level){$script:LogLevels.Add([string]$Level)} }
function Rebuild-UserMachineLinkIndex { $script:RebuildCalls++ }
function Refresh-LinkGrid { $script:RefreshGridCalls++ }
function Refresh-AssociationContext { param([switch]$SkipResultRefresh) $script:RefreshAssocCalls++ }
function Request-DomeniaIndexMetadata { param([switch]$StartupChecks,[int]$Attempt=0) $script:LoadIndexCalls++ }
. ([scriptblock]::Create((Get-FunctionTextFromFile $core 'Normalize-LinkComputer')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $guardModel 'ConvertTo-DomeniaLinkRecord')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $guardModel 'Get-DomeniaLinkFingerprint')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $liveModel 'Get-DomeniaLiveHash')))
function Start-UiTask {
    param($Name,$OperationId,$Code,$Payload,$CallbackState,$SuccessHandler,$ErrorHandler,[switch]$NonCancellable,$TimeoutSeconds,$TaskClass)
    $script:StartUiCalls++
    $script:StartUiOperations.Add([string]$OperationId)
    $id = 'ui-' + $script:StartUiCalls
    $script:AsyncJobs[$id] = [pscustomobject]@{Id=$id;OperationId=[string]$OperationId}
    $script:LastStorageState = $CallbackState
    $script:LastStoragePayload = $Payload
    return $id
}
$script:StartUiTaskOriginal = (Get-Item function:Start-UiTask).ScriptBlock
$script:ResetTestOriginal = (Get-Item function:Reset-TestState).ScriptBlock
function Reset-TestState {
    & $script:ResetTestOriginal
    $script:LogLevels = New-Object 'System.Collections.Generic.List[string]'
    $script:StatusLevels = New-Object 'System.Collections.Generic.List[string]'
    $script:RebuildCalls = 0
    $script:RefreshGridCalls = 0
    $script:RefreshAssocCalls = 0
    $script:LoadIndexCalls = 0
    $script:DetachedReadJobs = @()
    Set-Item function:script:Start-DomeniaStorageWork { }
    Set-Item function:script:Start-UiTask $script:StartUiTaskOriginal
}
function Use-RealStorageWork { Set-Item function:script:Start-DomeniaStorageWork $script:StartStorageReal }

function New-LegacySandbox {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('domenia-legacy-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    $script:TestDbPath = Join-Path $root 'Domenia.db'
    $script:DomeniaDatabaseReady = $false
    $script:DomeniaDatabaseRecoveryAttempted = $false
    $script:RecoverCalls = 0
    [void](Initialize-DomeniaDatabase)
    return $root
}
function Get-LegacyCount {
    param([string]$Table)
    $db = Open-DomeniaDatabase -Path $script:TestDbPath -ReadOnly
    try { return [int](@(Invoke-DomeniaDbQuery ("SELECT count(*) AS n FROM $Table;") $db)[0].n) } finally { Close-DomeniaDatabase $db }
}
function Get-LegacySyncState {
    param([string]$Scope)
    $db = Open-DomeniaDatabase -Path $script:TestDbPath -ReadOnly
    try { $rows=@(Invoke-DomeniaDbQuery ('SELECT * FROM sync_state WHERE scope=' + (ConvertTo-DomeniaSqlLiteral $Scope) + ';') $db) } finally { Close-DomeniaDatabase $db }
    if($rows.Count -gt 0){return $rows[0]}
    return $null
}
function Invoke-LegacyWorker {
    param($Payload)
    $code = Get-DomeniaStorageWorkerCode
    return & ([scriptblock]::Create($code))
}
function New-LegacyPayload {
    param([string]$Marker='m1',[string]$BaseDn='DC=example,DC=invalid',[object[]]$Objects=@(),[object[]]$Park=@(),[object[]]$UserScans=@(),[object[]]$Secrets=@(),[object[]]$Links=@())
    $row=[pscustomobject]@{Marker=$Marker;BaseDn=$BaseDn;At='2026-01-01T00:00:00Z';Objects=$Objects;Park=$Park;UserScans=$UserScans;Secrets=$Secrets;Links=$Links}
    $item=[pscustomobject]@{QueueKey='LegacyImport|test';Kind='LegacyImport';Path=$script:TestDbPath;Row=$row;Epoch=[long]1}
    return [pscustomobject]@{Path=$script:TestDbPath;Items=@($item)}
}
function New-PresencePayload {
    param([string]$Key='pc1')
    $row=[pscustomobject]@{Key=$Key;State='En ligne';Target='PC1';At='2026-01-01T00:00:00Z'}
    $item=[pscustomobject]@{QueueKey='Presence|test';Kind='Presence';Path=$script:TestDbPath;Row=$row;Epoch=[long]1}
    return [pscustomobject]@{Path=$script:TestDbPath;Items=@($item)}
}

Test-Case 'D113 : LegacyImport succes complet' {
    [void](New-LegacySandbox)
    $objects=@([pscustomobject]@{Guid='11111111-1111-1111-1111-111111111111';Type='Utilisateur';Name='User1';Login='user1';Upn='user1@example.invalid';Display='User One';Description='';Extra='';State='Actif';DN='CN=User1,DC=example,DC=invalid';WhenChanged='2026-01-01';Usn=10;LastLogon=''})
    $park=@([pscustomobject]@{Key='PC1';Computer='PC1';LastProbe='';Status='Inconnu';User='';Attempts=0})
    $userScans=@([pscustomobject]@{Login='user1';At='2026-01-01';Scanned=$true;Candidates=1;Reachable=1;Probed=1;Found='PC1'})
    $secrets=@([pscustomobject]@{Computer='PC1';At='2026-01-01';BitLockerKeys=1;BitLockerLast='2026-01-01';LapsScheme='';LapsExpiry='';Verdict='OK'})
    $links=@([pscustomobject]@{UserLogin='user1';Computer='PC1';Source='Import CSV';Confidence=100;VerifiedInAD=$true;When='2026-01-01';Details='';UserGuid='';ComputerGuid='';UserDn='';ComputerDn=''})
    $payload=New-LegacyPayload -Objects $objects -Park $park -UserScans $userScans -Secrets $secrets -Links $links
    $r=Invoke-LegacyWorker $payload
    Assert-True $r.Saved
    Assert-Equal 0 ([int]$r.Already)
    Assert-Equal 1 ([int]$r.Imported.Objects)
    Assert-Equal 1 ([int]$r.Imported.Park)
    Assert-Equal 1 ([int]$r.Imported.UserScans)
    Assert-Equal 1 ([int]$r.Imported.Secrets)
    Assert-Equal 1 ([int]$r.Imported.Links)
    Assert-Equal 0 @($r.Conflicts).Count
    Assert-Equal 1 @($r.ImportedLinks).Count
    Assert-Equal 1 (Get-LegacyCount 'ad_objects')
    Assert-Equal 1 (Get-LegacyCount 'park_state')
    Assert-Equal 1 (Get-LegacyCount 'user_scan_history')
    Assert-Equal 1 (Get-LegacyCount 'secret_state')
    Assert-Equal 1 (Get-LegacyCount 'user_machine_history')
    $legacy=Get-LegacySyncState 'legacy_import'
    Assert-True ($null -ne $legacy)
    Assert-True ([string]$legacy.details -match 'marker=m1')
    $dir=Get-LegacySyncState 'directory'
    Assert-True ($null -ne $dir)
    Assert-Equal 'DC=example,DC=invalid' ([string]$dir.base_dn)
    Assert-Equal 0 ([long]$dir.highest_usn)
    Assert-Equal 1 ([int]$dir.item_count)
    $db=Open-DomeniaDatabase -Path $script:TestDbPath -ReadOnly
    try { $secretRow=@(Invoke-DomeniaDbQuery 'SELECT checked_at FROM secret_state;' $db)[0] } finally { Close-DomeniaDatabase $db }
    Assert-Equal '2026-01-01' ([string]$secretRow.checked_at) 'La migration ne rajeunit pas les metadonnees.'
}

Test-Case 'D113 : trigger ABORT secret_state provoque rollback entier' {
    [void](New-LegacySandbox)
    $db=Open-DomeniaDatabase -Path $script:TestDbPath
    try { [void](Invoke-DomeniaDbExec 'CREATE TRIGGER abort_secret BEFORE INSERT ON secret_state BEGIN SELECT RAISE(ABORT,''abort secret''); END;' $db) } finally { Close-DomeniaDatabase $db }
    $secrets=@([pscustomobject]@{Computer='PC1';At='2026-01-01';BitLockerKeys=1;BitLockerLast='';LapsScheme='';LapsExpiry='';Verdict='OK'})
    $payload=New-LegacyPayload -Secrets $secrets -Objects @([pscustomobject]@{Guid='rollback-object';DN='CN=Test,DC=example,DC=invalid';Usn=0}) -Park @([pscustomobject]@{Computer='PC1';Attempts=0}) -UserScans @([pscustomobject]@{Login='test';Candidates=0;Reachable=0;Probed=0})
    $message=''
    try { [void](Invoke-LegacyWorker $payload) } catch { $message=$_.Exception.Message }
    Assert-True ($message -match 'abort secret') ('Rollback non declenche : '+$message)
    Assert-Equal 0 (Get-LegacyCount 'secret_state')
    Assert-Equal 0 (Get-LegacyCount 'ad_objects')
    Assert-Equal 0 (Get-LegacyCount 'park_state')
    Assert-Equal 0 (Get-LegacyCount 'user_scan_history')
    Assert-Equal 0 (Get-LegacyCount 'user_machine_history')
    Assert-True ($null -eq (Get-LegacySyncState 'legacy_import'))
    Assert-True ($null -eq (Get-LegacySyncState 'directory'))
}

Test-Case 'D113 : chacune des 4 tables non vide est refusee' {
    $tables=@('ad_objects','park_state','user_scan_history','secret_state')
    foreach($table in $tables){
        [void](New-LegacySandbox)
        $db=Open-DomeniaDatabase -Path $script:TestDbPath
        try {
            switch($table){
                'ad_objects' { [void](Invoke-DomeniaDbExec "INSERT INTO ad_objects(object_key,object_type) VALUES('x','Utilisateur');" $db) }
                'park_state' { [void](Invoke-DomeniaDbExec "INSERT INTO park_state(computer_key) VALUES('PC1');" $db) }
                'user_scan_history' { [void](Invoke-DomeniaDbExec "INSERT INTO user_scan_history(login_key) VALUES('u1');" $db) }
                'secret_state' { [void](Invoke-DomeniaDbExec "INSERT INTO secret_state(computer_key) VALUES('PC1');" $db) }
            }
        } finally { Close-DomeniaDatabase $db }
        $message=''
        try { [void](Invoke-LegacyWorker (New-LegacyPayload -Marker ('m-'+$table))) } catch { $message=$_.Exception.Message }
        Assert-True ($message -match 'Tables legacy non vides') ('Refus absent pour '+$table+' : '+$message)
        Assert-True ($null -eq (Get-LegacySyncState 'legacy_import'))
    }
}

Test-Case 'D113 : idempotence marqueur identique sans ecriture ni retention' {
    [void](New-LegacySandbox)
    $links=@([pscustomobject]@{UserLogin='user1';Computer='PC1';Source='Import CSV';Confidence=100;VerifiedInAD=$true;When='2026-01-01';Details='';UserGuid='';ComputerGuid='';UserDn='';ComputerDn=''})
    $r1=Invoke-LegacyWorker (New-LegacyPayload -Marker 'm1' -Links $links)
    Assert-True $r1.Saved
    $db=Open-DomeniaDatabase -Path $script:TestDbPath
    try { [void](Invoke-DomeniaDbExec "INSERT INTO user_machine_history(user_login,computer_key,computer,source,confidence,verified_in_ad,observed_at,details,user_guid,computer_guid) VALUES('u','PC2','PC2','Console',0,0,'2026-01-01','',NULL,NULL);" $db) } finally { Close-DomeniaDatabase $db }
    $before=Get-LegacyCount 'user_machine_history'
    $beforeHash=(Get-FileHash -LiteralPath $script:TestDbPath -Algorithm SHA256).Hash
    $dirBefore=Get-LegacySyncState 'directory'
    $r2=Invoke-LegacyWorker (New-LegacyPayload -Marker 'm1' -Links @([pscustomobject]@{UserLogin='other';Computer='PC9';Source='Console';Confidence=0;VerifiedInAD=$false;When='';Details='';UserGuid='';ComputerGuid='';UserDn='';ComputerDn=''}))
    Assert-True $r2.Saved
    Assert-Equal 1 ([int]$r2.Already)
    Assert-Equal 0 @($r2.ImportedLinks).Count
    Assert-Equal $before (Get-LegacyCount 'user_machine_history')
    Assert-Equal $beforeHash (Get-FileHash -LiteralPath $script:TestDbPath -Algorithm SHA256).Hash 'Le rejeu a modifie les octets de la base.'
    $dirAfter=Get-LegacySyncState 'directory'
    Assert-Equal ([string]$dirBefore.last_sync) ([string]$dirAfter.last_sync)
}

Test-Case 'D113 : marqueur different refuse explicitement' {
    [void](New-LegacySandbox)
    [void](Invoke-LegacyWorker (New-LegacyPayload -Marker 'm1'))
    $message=''
    try { [void](Invoke-LegacyWorker (New-LegacyPayload -Marker 'm2')) } catch { $message=$_.Exception.Message }
    Assert-True ($message -match 'autre marqueur') ('Refus absent : '+$message)
    Assert-True ($null -ne (Get-LegacySyncState 'legacy_import'))
}

Test-Case 'D113 : marqueur identique est idempotent avant garde tables vides' {
    [void](New-LegacySandbox)
    [void](Invoke-LegacyWorker (New-LegacyPayload -Marker 'm1'))
    $db=Open-DomeniaDatabase -Path $script:TestDbPath
    try { [void](Invoke-DomeniaDbExec "INSERT INTO ad_objects(object_key,object_type) VALUES('x','Utilisateur');" $db) } finally { Close-DomeniaDatabase $db }
    $r=Invoke-LegacyWorker (New-LegacyPayload -Marker 'm1')
    Assert-True $r.Saved
    Assert-Equal 1 ([int]$r.Already)
}

Test-Case 'D113 : sync_state directory existant preserve et refuse domaine different' {
    [void](New-LegacySandbox)
    $db=Open-DomeniaDatabase -Path $script:TestDbPath
    try { [void](Invoke-DomeniaDbExec "INSERT INTO sync_state(scope,server,base_dn,highest_usn,last_sync,item_count,details) VALUES('directory','dc-old','DC=example,DC=invalid',99,'old',5,'keep');" $db) } finally { Close-DomeniaDatabase $db }
    [void](Invoke-LegacyWorker (New-LegacyPayload -Marker 'm1'))
    $dir=Get-LegacySyncState 'directory'
    Assert-Equal 'dc-old' ([string]$dir.server)
    Assert-Equal 99 ([long]$dir.highest_usn)
    Assert-Equal 'keep' ([string]$dir.details)
    [void](New-LegacySandbox)
    $db=Open-DomeniaDatabase -Path $script:TestDbPath
    try { [void](Invoke-DomeniaDbExec "INSERT INTO sync_state(scope,server,base_dn,highest_usn,last_sync,item_count,details) VALUES('directory','dc-old','DC=other,DC=invalid',99,'old',5,'keep');" $db) } finally { Close-DomeniaDatabase $db }
    $message=''
    try { [void](Invoke-LegacyWorker (New-LegacyPayload -Marker 'm1')) } catch { $message=$_.Exception.Message }
    Assert-True ($message -match 'Domaine different') ('Refus domaine absent : '+$message)
}

Test-Case 'D113 : conflit lien conserve et ImportedLinks uniquement ajoutes' {
    [void](New-LegacySandbox)
    $db=Open-DomeniaDatabase -Path $script:TestDbPath
    try { [void](Invoke-DomeniaDbExec "INSERT INTO user_machine_links(computer_key,user_login,computer,source,confidence,verified_in_ad,observed_at,details,user_guid,computer_guid,user_dn,computer_dn) VALUES('PC1','old','PC1','Console',0,0,'2026-01-01','',NULL,NULL,NULL,NULL);" $db) } finally { Close-DomeniaDatabase $db }
    $links=@(
        [pscustomobject]@{UserLogin='new';Computer='PC1';Source='Import CSV';Confidence=100;VerifiedInAD=$true;When='2026-01-01';Details='';UserGuid='';ComputerGuid='';UserDn='';ComputerDn=''},
        [pscustomobject]@{UserLogin='new';Computer='PC2';Source='Import CSV';Confidence=100;VerifiedInAD=$true;When='2026-01-01';Details='';UserGuid='';ComputerGuid='';UserDn='';ComputerDn=''}
    )
    $r=Invoke-LegacyWorker (New-LegacyPayload -Marker 'm1' -Links $links)
    Assert-True $r.Saved
    Assert-Equal 1 @($r.Conflicts).Count
    Assert-Equal 'PC1' ([string]@($r.Conflicts)[0])
    Assert-Equal 1 @($r.ImportedLinks).Count
    Assert-Equal 'PC2' ([string]@($r.ImportedLinks)[0].Computer)
    $db=Open-DomeniaDatabase -Path $script:TestDbPath -ReadOnly
    try { $old=@(Invoke-DomeniaDbQuery "SELECT user_login FROM user_machine_links WHERE computer_key='PC1';" $db); $new=@(Invoke-DomeniaDbQuery "SELECT user_login FROM user_machine_links WHERE computer_key='PC2';" $db) } finally { Close-DomeniaDatabase $db }
    Assert-Equal 'old' ([string]$old[0].user_login)
    Assert-Equal 'new' ([string]$new[0].user_login)
}

Test-Case 'D113 : payload LegacyImport melange refuse' {
    [void](New-LegacySandbox)
    $legacyItem=(New-LegacyPayload -Marker 'm1').Items[0]
    $presenceItem=(New-PresencePayload).Items[0]
    $payload=[pscustomobject]@{Path=$script:TestDbPath;Items=@($legacyItem,$presenceItem)}
    $message=''
    try { [void](Invoke-LegacyWorker $payload) } catch { $message=$_.Exception.Message }
    Assert-True ($message -match 'seul') ('Refus melange absent : '+$message)
    Assert-True ($null -eq (Get-LegacySyncState 'legacy_import'))
}

Test-Case 'D113 : gardes Marker BaseDn et plafond tableau' {
    [void](New-LegacySandbox)
    $message=''
    try { [void](Invoke-LegacyWorker (New-LegacyPayload -Marker '')) } catch { $message=$_.Exception.Message }
    Assert-True ($message -match 'Marqueur') ('Garde Marker absente : '+$message)
    try { [void](Invoke-LegacyWorker (New-LegacyPayload -BaseDn 'DC=')) } catch { $message=$_.Exception.Message }
    Assert-True ($message -match 'BaseDn') ('Garde BaseDn absente : '+$message)
    try { [void](Invoke-LegacyWorker (New-LegacyPayload -Marker 'm1' -Objects @(1..250001))) } catch { $message=$_.Exception.Message }
    Assert-True ($message -match 'trop grand') ('Garde plafond absente : '+$message)
    Assert-True ($null -eq (Get-LegacySyncState 'legacy_import'))
}

Test-Case 'D113 : import legacy ne borne pas user_machine_history' {
    [void](New-LegacySandbox)
    $db=Open-DomeniaDatabase -Path $script:TestDbPath
    try { [void](Invoke-DomeniaDbExec "WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM c WHERE n<20001) INSERT INTO user_machine_history(user_login,computer_key,computer,source,confidence,verified_in_ad,observed_at,details,user_guid,computer_guid) SELECT 'u'||n,'PC-UNPROT','PC-UNPROT','Console',0,0,'2026-01-01','',NULL,NULL FROM c;" $db) } finally { Close-DomeniaDatabase $db }
    [void](Invoke-LegacyWorker (New-LegacyPayload -Marker 'm1'))
    Assert-Equal 20001 (Get-LegacyCount 'user_machine_history')
}

Test-Case 'D029 : cap historique protege Manual Saisie manuelle Import CSV et association protegee' {
    [void](New-LegacySandbox)
    $db=Open-DomeniaDatabase -Path $script:TestDbPath
    try {
        [void](Invoke-DomeniaDbExec "INSERT INTO user_machine_history(user_login,computer_key,computer,source,confidence,verified_in_ad,observed_at,details,user_guid,computer_guid) VALUES('u-manual','PC-MANUAL','PC-MANUAL',' mAnUaL ',0,0,'2026-01-01','',NULL,NULL);" $db)
        [void](Invoke-DomeniaDbExec "INSERT INTO user_machine_links(computer_key,user_login,computer,source,confidence,verified_in_ad,observed_at,details,user_guid,computer_guid,user_dn,computer_dn) VALUES('PC-PROT','prot','PC-PROT',' mAnUaL ',0,0,'2026-01-01','',NULL,NULL,NULL,NULL);" $db)
        [void](Invoke-DomeniaDbExec "INSERT INTO user_machine_history(user_login,computer_key,computer,source,confidence,verified_in_ad,observed_at,details,user_guid,computer_guid) VALUES('u-prot','PC-PROT','PC-PROT','Console',0,0,'2026-01-01','',NULL,NULL);" $db)
        foreach($source in @('Saisie manuelle','Import CSV')) {
            $lit=ConvertTo-DomeniaSqlLiteral $source
            [void](Invoke-DomeniaDbExec ("INSERT INTO user_machine_history(user_login,computer_key,source) VALUES('protege','PC-CSV',"+$lit+");") $db)
        }
        [void](Invoke-DomeniaDbExec "WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM c WHERE n<20001) INSERT INTO user_machine_history(user_login,computer_key,computer,source,confidence,verified_in_ad,observed_at,details,user_guid,computer_guid) SELECT 'u'||n,'PC-UNPROT','PC-UNPROT','Console',0,0,'2026-01-01','',NULL,NULL FROM c;" $db)
    } finally { Close-DomeniaDatabase $db }
    [void](Invoke-LegacyWorker (New-PresencePayload))
    Assert-Equal 1 (Get-LegacyCount "user_machine_history WHERE lower(trim(COALESCE(source,'')))='manual'")
    Assert-Equal 1 (Get-LegacyCount "user_machine_history WHERE computer_key='PC-PROT'")
    Assert-Equal 2 (Get-LegacyCount "user_machine_history WHERE source IN ('Saisie manuelle','Import CSV')")
    Assert-Equal 20001 (Get-LegacyCount "user_machine_history WHERE lower(COALESCE(source,''))='console' AND computer_key='PC-UNPROT'")
}


Test-Case 'D113 : Queue LegacyImport refuse Marker ou BaseDn invalide' {
    Initialize-DomeniaPersistence
    $script:DatabaseScopedPath='test-scope.db'
    Assert-False (Queue-DomeniaMetadata -Kind 'LegacyImport' -Row ([pscustomobject]@{Marker='';BaseDn='DC=example,DC=invalid'}))
    Assert-False (Queue-DomeniaMetadata -Kind 'LegacyImport' -Row ([pscustomobject]@{Marker='m1';BaseDn='example.invalid'}))
    Assert-Equal 0 $script:Persistence.Pending.Count
}

Test-Case 'D113 : Queue LegacyImport refuse si lien en attente' {
    Initialize-DomeniaPersistence
    $script:DatabaseScopedPath='test-scope.db'
    $script:Persistence.Pending['link']=[pscustomobject]@{QueueKey='link';Kind='Link';Path='test-scope.db'}
    $row=[pscustomobject]@{Marker='m1';BaseDn='DC=example,DC=invalid';At='2026-01-01';Objects=@();Park=@();UserScans=@();Secrets=@();Links=@()}
    Assert-False (Queue-DomeniaMetadata -Kind 'LegacyImport' -Row $row)
    Assert-False $script:Persistence.LinkBusy
}

Test-Case 'D113 : Queue LegacyImport refuse si LinkBusy' {
    Initialize-DomeniaPersistence
    $script:DatabaseScopedPath='test-scope.db'
    $script:Persistence.LinkBusy=$true
    $row=[pscustomobject]@{Marker='m1';BaseDn='DC=example,DC=invalid';At='2026-01-01';Objects=@();Park=@();UserScans=@();Secrets=@();Links=@()}
    Assert-False (Queue-DomeniaMetadata -Kind 'LegacyImport' -Row $row)
    Assert-True $script:Persistence.LinkBusy
}

Test-Case 'D113 : Queue LegacyImport met LinkBusy et bloque liens' {
    Initialize-DomeniaPersistence
    $script:DatabaseScopedPath='test-scope.db'
    $script:SessionEpoch=[long]1
    $row=[pscustomobject]@{Marker='m1';BaseDn='DC=example,DC=invalid';At='2026-01-01';Objects=@();Park=@();UserScans=@();Secrets=@();Links=@()}
    Assert-True (Queue-DomeniaMetadata -Kind 'LegacyImport' -Row $row)
    Assert-True $script:Persistence.LinkBusy
    Assert-False (Queue-DomeniaMetadata -Kind 'LegacyImport' -Row $row)
    Assert-False (Queue-DomeniaLinkChanges)
}

Test-Case 'D113 : Start isole LegacyImport et exclut les lots ordinaires' {
    Initialize-DomeniaPersistence
    $script:DatabaseScopedPath='test-scope.db'
    $script:SessionEpoch=[long]1
    $row=[pscustomobject]@{Marker='m1';BaseDn='DC=example,DC=invalid';At='2026-01-01';Objects=@();Park=@();UserScans=@();Secrets=@();Links=@()}
    Assert-True (Queue-DomeniaMetadata -Kind 'LegacyImport' -Row $row)
    Assert-True (Queue-DomeniaMetadata -Kind 'Presence' -Row ([pscustomobject]@{Key='pc1';State='En ligne';Target='PC1';At='2026-01-01'}))
    Use-RealStorageWork
    Start-DomeniaStorageWork
    Assert-Equal 1 $script:StartUiCalls
    Assert-Equal 1 @($script:LastStoragePayload.Items).Count
    Assert-Equal 'LegacyImport' ([string]@($script:LastStoragePayload.Items)[0].Kind)
    Assert-Equal 1 $script:Persistence.Pending.Count
    Assert-Equal 'Presence' ([string]@($script:Persistence.Pending.Values)[0].Kind)
    Assert-True $script:Persistence.LinkBusy
}

Test-Case 'D113 : liveness attend un worker detache puis libere sans rejeu' {
    Initialize-DomeniaPersistence
    $script:DatabaseScopedPath='test-scope.db'
    $script:SessionEpoch=[long]1
    $row=[pscustomobject]@{Marker='m1';BaseDn='DC=example,DC=invalid';At='2026-01-01';Objects=@();Park=@();UserScans=@();Secrets=@();Links=@()}
    [void](Queue-DomeniaMetadata -Kind 'LegacyImport' -Row $row)
    Use-RealStorageWork
    Start-DomeniaStorageWork
    Assert-Equal 1 $script:StartUiCalls
    $id=$script:Persistence.Job
    $script:DetachedReadJobs=@($script:AsyncJobs[$id])
    [void]$script:AsyncJobs.Remove($id)
    Start-DomeniaStorageWork
    Assert-True $script:Persistence.LinkBusy
    Assert-Equal $id $script:Persistence.Job
    $script:DetachedReadJobs=@()
    Start-DomeniaStorageWork
    Assert-False $script:Persistence.LinkBusy
    Assert-Equal '' $script:Persistence.Job
    Assert-Equal '' $script:Persistence.LegacyImportJob
    Assert-Equal 0 $script:Persistence.Pending.Count
    Assert-Equal 1 $script:StartUiCalls
}

Test-Case 'D113 : echec import ne requeue pas et ne suspend pas le stockage normal' {
    Initialize-DomeniaPersistence
    $script:DatabaseScopedPath='test-scope.db'
    $script:SessionEpoch=[long]1
    $row=[pscustomobject]@{Marker='m1';BaseDn='DC=example,DC=invalid';At='2026-01-01';Objects=@();Park=@();UserScans=@();Secrets=@();Links=@()}
    [void](Queue-DomeniaMetadata -Kind 'LegacyImport' -Row $row)
    [void](Queue-DomeniaMetadata -Kind 'Presence' -Row ([pscustomobject]@{Key='pc1';State='En ligne';Target='PC1';At='2026-01-01'}))
    Use-RealStorageWork
    Start-DomeniaStorageWork
    Assert-Equal 1 $script:StartUiCalls
    [void]$script:AsyncJobs.Remove([string]$script:Persistence.Job)
    Fail-DomeniaStorageWork 'SQLite code 5 : database is locked' $script:LastStorageState
    Assert-Equal 0 $script:Persistence.Failures
    Assert-Equal '' $script:Persistence.Job
    Assert-Equal 0 $script:Persistence.InFlight
    Assert-Equal 1 $script:Persistence.Pending.Count
    Assert-Equal 'Presence' ([string]@($script:Persistence.Pending.Values)[0].Kind)
    Assert-False $script:Persistence.LinkBusy
    Assert-True (@($script:StatusLevels) -contains 'ERROR')
    Assert-True (@($script:LogLevels) -contains 'ERROR')
    Start-DomeniaStorageWork
    Assert-Equal 2 $script:StartUiCalls
    Assert-Equal 'Presence' ([string]@($script:LastStoragePayload.Items)[0].Kind)
}

Test-Case 'D113 : Start-UiTask qui leve avant depart ne reessaie pas import' {
    Initialize-DomeniaPersistence
    $script:DatabaseScopedPath='test-scope.db'
    $script:SessionEpoch=[long]1
    $row=[pscustomobject]@{Marker='m1';BaseDn='DC=example,DC=invalid';At='2026-01-01';Objects=@();Park=@();UserScans=@();Secrets=@();Links=@()}
    [void](Queue-DomeniaMetadata -Kind 'LegacyImport' -Row $row)
    [void](Queue-DomeniaMetadata -Kind 'Presence' -Row ([pscustomobject]@{Key='pc1';State='En ligne';Target='PC1';At='2026-01-01'}))
    Set-Item function:script:Start-UiTask { throw 'boom' }
    Use-RealStorageWork
    Start-DomeniaStorageWork
    Assert-Equal 0 $script:Persistence.Failures
    Assert-Equal '' $script:Persistence.Job
    Assert-Equal 0 $script:Persistence.InFlight
    Assert-Equal 1 $script:Persistence.Pending.Count
    Assert-Equal 'Presence' ([string]@($script:Persistence.Pending.Values)[0].Kind)
    Assert-False $script:Persistence.LinkBusy
    Assert-True (@($script:StatusLevels) -contains 'ERROR')
}

Test-Case 'D113 : import peut demarrer malgre Failures ou Next ordinaire' {
    Initialize-DomeniaPersistence
    $script:DatabaseScopedPath='test-scope.db'
    $script:SessionEpoch=[long]1
    $script:Persistence.Failures=3
    $script:Persistence.Next=[datetime]::UtcNow.AddSeconds(30)
    $row=[pscustomobject]@{Marker='m1';BaseDn='DC=example,DC=invalid';At='2026-01-01';Objects=@();Park=@();UserScans=@();Secrets=@();Links=@()}
    [void](Queue-DomeniaMetadata -Kind 'LegacyImport' -Row $row)
    Use-RealStorageWork
    Start-DomeniaStorageWork
    Assert-Equal 1 $script:StartUiCalls
}

Test-Case 'D113 : Complete ignore epoch ou chemin obsolette pour la memoire' {
    Initialize-DomeniaPersistence
    $script:DatabaseScopedPath='test-scope.db'
    $script:SessionEpoch=[long]1
    $script:UserMachineLinks=@()
    $script:LinkBaseline=@{}
    $links=@([pscustomobject]@{UserLogin='u1';Computer='PC1';Source='Import CSV';Confidence=100;VerifiedInAD=$true;When='2026-01-01';Details='';UserGuid='';ComputerGuid='';UserDn='';ComputerDn=''})
    $item=[pscustomobject]@{QueueKey='LegacyImport|test';Kind='LegacyImport';Path='other.db';Row=$null;Epoch=[long]1}
    $state=[pscustomobject]@{Items=@($item);Epoch=[long]2}
    $result=[pscustomobject]@{Saved=$true;Conflicts=@();Count=1;Already=0;Imported=0;ImportedLinks=$links}
    Complete-DomeniaStorageWork $result $state
    Assert-Equal 0 @($script:UserMachineLinks).Count
    Assert-Equal 0 $script:LinkBaseline.Count
    Assert-False $script:Persistence.LinkBusy
}

Test-Case 'D113 : plus de 64 liens importes ne produisent aucun ecart apres Complete' {
    Initialize-DomeniaPersistence
    [void](New-LegacySandbox)
    $script:DatabaseScopedPath=$script:TestDbPath
    $script:SessionEpoch=[long]1
    $script:UserMachineLinks=@()
    $script:LinkBaseline=@{}
    $links=@()
    for($i=1;$i -le 70;$i++){$links += [pscustomobject]@{UserLogin=('user{0:d2}' -f $i);Computer=('PC{0:d2}' -f $i);Source='Import CSV';Confidence=100;VerifiedInAD=$true;When='2026-01-01';Details='';UserGuid='';ComputerGuid='';UserDn='';ComputerDn=''}}
    $payload=New-LegacyPayload -Links $links
    $state=[pscustomobject]@{Items=$payload.Items;Epoch=[long]1}
    $result=Invoke-LegacyWorker $payload
    Complete-DomeniaStorageWork $result $state
    Assert-Equal 70 @($script:UserMachineLinks).Count
    Assert-Equal 70 $script:LinkBaseline.Count
    Assert-False $script:Persistence.LinkBusy
    Assert-True (Queue-DomeniaLinkChanges)
    Assert-Equal 0 $script:Persistence.Pending.Count
    $rec=ConvertTo-DomeniaLinkRecord $links[0]
    Assert-Equal (Get-DomeniaLinkFingerprint $rec) (Get-DomeniaLinkFingerprint $script:LinkBaseline['PC01'])
}

Test-Case 'D113 : succes import ne remet pas a zero Failures ordinaire' {
    Initialize-DomeniaPersistence
    $script:DatabaseScopedPath='test-scope.db'
    $script:SessionEpoch=[long]1
    $script:Persistence.Failures=2
    $item=[pscustomobject]@{QueueKey='LegacyImport|test';Kind='LegacyImport';Path='test-scope.db';Row=$null;Epoch=[long]1}
    $state=[pscustomobject]@{Items=@($item);Epoch=[long]1}
    Complete-DomeniaStorageWork ([pscustomobject]@{Saved=$true;Conflicts=@();Count=0;Already=0;Imported=0;ImportedLinks=@()}) $state
    Assert-Equal 2 $script:Persistence.Failures
}

Test-Case 'D113 : un rappel ordinaire conserve le verrou d un import en attente' {
    Initialize-DomeniaPersistence; Stop-TestTimers
    $row=[pscustomobject]@{Marker='pending';BaseDn='DC=example,DC=invalid'}
    Assert-True (Queue-DomeniaMetadata -Kind LegacyImport -Row $row)
    Complete-DomeniaStorageWork ([pscustomobject]@{Saved=$true;Conflicts=@();Count=1}) ([pscustomobject]@{Items=@([pscustomobject]@{Kind='Presence'});Epoch=[long]1})
    Assert-True $script:Persistence.LinkBusy
    Assert-Equal 1 $script:Persistence.Pending.Count
    $script:Persistence.Job='lost-ordinary'
    Use-RealStorageWork
    Start-DomeniaStorageWork
    Assert-True $script:Persistence.LinkBusy
    Assert-Equal 'LegacyImport' $script:LastStoragePayload.Items[0].Kind
}

Test-Case 'D113 : rappel Already ne fusionne rien dans la session' {
    Initialize-DomeniaPersistence; Stop-TestTimers
    $script:UserMachineLinks=@([pscustomobject]@{Computer='PC-LOCAL';UserLogin='local'})
    $state=[pscustomobject]@{Items=@([pscustomobject]@{Kind='LegacyImport';Epoch=[long]1;Path=$script:DatabaseScopedPath})}
    $result=[pscustomobject]@{Saved=$true;Conflicts=@();Already=$true;ImportedLinks=@([pscustomobject]@{Computer='PC-OTHER';UserLogin='other'})}
    Complete-DomeniaStorageWork $result $state
    Assert-Equal 1 @($script:UserMachineLinks).Count
    Assert-Equal 'PC-LOCAL' $script:UserMachineLinks[0].Computer
    Assert-Equal 0 $script:LinkBaseline.Count
    Assert-Equal 0 $script:LoadIndexCalls
    Assert-False $script:Persistence.LinkBusy
}

# ---------------------------------------------------------------- D113: file readers, plan and explicit gesture (G2/G3).
. (Join-Path $modules 'Domenia-Relations.Model.ps1')
. (Join-Path $modules 'Domenia-Migration.UI.ps1')
. (Join-Path $modules 'Domenia-Migration.Worker.ps1')
foreach ($name in @('Normalize-LinkUser','Import-DomeniaLegacyStoreIfNeeded','Invoke-DomeniaDatabaseMaintenance')) {
    . ([scriptblock]::Create((Get-FunctionTextFromFile $core $name)))
}
$script:G23LocalAppData=$env:LOCALAPPDATA
$script:G23Reset=(Get-Item function:Reset-TestState).ScriptBlock
function Reset-TestState {
    & $script:G23Reset
    $env:LOCALAPPDATA=$script:G23LocalAppData
    $script:LegacyImportPreview=$null;$script:LegacyImportWork=$null
    $script:InlineCalls=0;$script:InlineConfirm=$null;$script:InlineCancel=$null
}
function Request-DomeniaInlineConfirmation {
    param($Title,$Message,$Target,$ConfirmText,$CancelText,$OnConfirm,$OnCancel)
    $script:InlineCalls++;$script:InlineConfirm=$OnConfirm;$script:InlineCancel=$OnCancel
}
function Complete-TestMigrationWorker {
    $state=$script:LastStorageState;$Payload=$script:LastStoragePayload
    $result=& ([scriptblock]::Create((Get-DomeniaMigrationWorkerCode)))
    foreach ($key in @($script:AsyncJobs.Keys)) { if ($script:AsyncJobs[$key].OperationId -eq 'LegacyMigration') { [void]$script:AsyncJobs.Remove($key) } }
    Complete-DomeniaLegacyImportWork $result $state
}
function New-G23Fixture {
    $root=New-LegacySandbox
    $script:DatabaseScopedPath=$script:TestDbPath
    $script:DataDir=Join-Path $root 'data';$env:LOCALAPPDATA=Join-Path $root 'local'
    [void][IO.Directory]::CreateDirectory((Join-Path $script:DataDir 'Index'))
    $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid';Domain='example.invalid'}
    Initialize-DomeniaPersistence;Stop-TestTimers
    $tab=[string][char]9
    $objects=@(('Type','Name','Login','Upn','Display','Description','Extra','State','DN','WhenChanged','Usn','LastLogon','Guid') -join $tab)
    $objects+=('Computer','PC1','PC1$','','Poste','','','Enabled','CN=PC1,DC=example,DC=invalid','2026-01-01T10:00:00Z','12','','guid-pc1') -join $tab
    [IO.File]::WriteAllLines((Join-Path $script:DataDir 'Index\objets.tsv'),$objects,[Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $script:DataDir 'Index\parc.tsv'),(('PC1','2026-01-01T10:00:00Z','Observe','alice','2') -join $tab),[Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $script:DataDir 'Index\recherches.tsv'),(('alice','2026-01-01T10:00:00Z','1','3','2','1','PC1') -join $tab),[Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $script:DataDir 'Index\secrets-etat.tsv'),(('PC1','2026-01-01T10:00:00Z','2','','Windows LAPS','','Disponible','detail non repris') -join $tab),[Text.Encoding]::UTF8)
    $links=@(
        [pscustomobject]@{UserLogin='alice';Computer='PC1.example.invalid';Source='Saisie manuelle';Confidence=90;VerifiedInAD='False';When='2026-01-01T10:00:00Z';Details='declared'}
        [pscustomobject]@{UserLogin='bob';Computer='PC1$';Source='Console CIM/DCOM';Confidence=80;VerifiedInAD='True';When='2026-09-01T10:00:00Z';Details='observed'}
    )
    foreach ($n in 2..70) { $links+=[pscustomobject]@{UserLogin=('user'+$n);Computer=('PC'+$n);Source='Console CIM/DCOM';Confidence=60;VerifiedInAD='False';When='2026-01-01T10:00:00Z';Details=''} }
    $links | Export-Csv -LiteralPath (Join-Path $script:DataDir 'Domenia-user-machine-links.csv') -NoTypeInformation -Encoding UTF8
    return $root
}
Test-Case 'D113 G2 : simulation des fichiers sans aucune ecriture, choix Relations et origine preservee' {
    $root=New-G23Fixture
    $before=(Get-FileHash $script:TestDbPath -Algorithm SHA256).Hash
    $plan=Invoke-DomeniaDatabaseMaintenance -ImportLegacy -DryRun
    Assert-True $plan.Allowed ($plan.Blockers -join ' ')
    Assert-Equal 4 $plan.ImportCount;Assert-Equal 70 $plan.AddCount
    Assert-Equal 0 $plan.RejectedLines
    Assert-Equal $before (Get-FileHash $script:TestDbPath -Algorithm SHA256).Hash
    Assert-Equal 0 $script:Persistence.Pending.Count
    Assert-Equal 0 @(Get-ChildItem $root -Recurse -Filter 'Domenia-migration-*.db').Count
    $link=@($plan.Payload.Links | Where-Object { $_.Computer -eq 'PC1' })[0]
    Assert-Equal 'alice' $link.UserLogin 'Affectation declaree plus ancienne prioritaire'
    Assert-Equal 'Import CSV' $link.Source
    Assert-True ($link.Details -match 'Saisie manuelle')
    Assert-False $link.VerifiedInAD 'La chaine False ne devient pas True'
    Assert-Equal $plan.Fingerprint (Invoke-DomeniaDatabaseMaintenance -ImportLegacy -DryRun).Fingerprint 'Empreinte stable'
}
Test-Case 'D113 G2 : import reel par un seul lot, sauvegarde, baseline puis second passage sans effet' {
    $root=New-G23Fixture
    $preview=Invoke-DomeniaDatabaseMaintenance -ImportLegacy -DryRun
    $plan=Invoke-DomeniaDatabaseMaintenance -ImportLegacy -ExpectedFingerprint $preview.Fingerprint
    Assert-True $plan.Queued
    Assert-Equal 1 $script:Persistence.Pending.Count
    $item=@($script:Persistence.Pending.Values)[0]
    Assert-Equal 'LegacyImport' $item.Kind
    Assert-Equal 70 $item.Row.Links.Count
    Assert-Equal 1 @(Get-ChildItem $root -Recurse -Filter 'Domenia-migration-*.db').Count
    $result=Invoke-LegacyWorker ([pscustomobject]@{Path=$script:TestDbPath;Items=@($item)})
    $script:Persistence.Pending.Clear()
    Complete-DomeniaStorageWork $result ([pscustomobject]@{Items=@($item);Epoch=$script:SessionEpoch})
    Assert-Equal 70 (Get-LegacyCount 'user_machine_links');Assert-Equal 70 $script:LinkBaseline.Count
    Assert-Equal 1 (Get-LegacyCount 'ad_objects');Assert-Equal 1 (Get-LegacyCount 'park_state')
    Assert-Equal 1 (Get-LegacyCount 'user_scan_history');Assert-Equal 1 (Get-LegacyCount 'secret_state')
    Assert-Equal 'DC=example,DC=invalid' (Get-LegacySyncState 'directory').base_dn
    $sha=(Get-FileHash $script:TestDbPath -Algorithm SHA256).Hash
    $second=Invoke-DomeniaDatabaseMaintenance -ImportLegacy -DryRun
    Assert-True $second.Already;Assert-Equal 0 $second.WriteCount
    Assert-False (Invoke-DomeniaDatabaseMaintenance -ImportLegacy).Queued
    Assert-Equal $sha (Get-FileHash $script:TestDbPath -Algorithm SHA256).Hash
    Assert-Equal 0 $script:Persistence.Pending.Count
}
Test-Case 'D113 G2 : associations existantes preservees dans le plan et sur disque' {
    [void](New-G23Fixture)
    $db=Open-DomeniaDatabase -Path $script:TestDbPath
    try { [void](Invoke-DomeniaDbExec "INSERT INTO user_machine_links(computer_key,computer,user_login,source) VALUES('PC1','PC1','owner','Manual');" $db) } finally { Close-DomeniaDatabase $db }
    $plan=Invoke-DomeniaDatabaseMaintenance -ImportLegacy
    Assert-Equal 69 $plan.AddCount;Assert-Equal 1 $plan.KeepCount
    $item=@($script:Persistence.Pending.Values)[0]
    $result=Invoke-LegacyWorker ([pscustomobject]@{Path=$script:TestDbPath;Items=@($item)})
    Assert-Equal 'PC1' ($result.Conflicts -join ',')
    $db=Open-DomeniaDatabase -Path $script:TestDbPath -ReadOnly
    try { $row=@(Invoke-DomeniaDbQuery "SELECT user_login,source FROM user_machine_links WHERE computer_key='PC1';" $db)[0] } finally { Close-DomeniaDatabase $db }
    Assert-Equal 'owner' $row.user_login;Assert-Equal 'Manual' $row.source
}
Test-Case 'D113 G2 : domaine absent ou different refuse et base non remplie' {
    [void](New-G23Fixture)
    $objects=Join-Path $script:DataDir 'Index\objets.tsv'
    $original=[IO.File]::ReadAllText($objects)
    [IO.File]::WriteAllText($objects,$original.Replace('DC=example','DC=other'),[Text.Encoding]::UTF8)
    Assert-False (Invoke-DomeniaDatabaseMaintenance -ImportLegacy -DryRun).Allowed
    Remove-Item -LiteralPath $objects
    Assert-False (Invoke-DomeniaDatabaseMaintenance -ImportLegacy -DryRun).Allowed
    Assert-Equal 0 $script:Persistence.Pending.Count;Assert-Equal 0 (Get-LegacyCount 'park_state')
}
Test-Case 'D113 G2 : table deja peuplee refuse toute la reprise avant sauvegarde' {
    $root=New-G23Fixture
    $db=Open-DomeniaDatabase -Path $script:TestDbPath
    try { [void](Invoke-DomeniaDbExec "INSERT INTO park_state(computer_key,computer,status) VALUES('KEEP','KEEP','present');" $db) } finally { Close-DomeniaDatabase $db }
    $plan=Invoke-DomeniaDatabaseMaintenance -ImportLegacy -DryRun
    Assert-False $plan.Allowed;Assert-Equal 0 $plan.WriteCount
    $message='';try { [void](Invoke-DomeniaDatabaseMaintenance -ImportLegacy) } catch { $message=$_.Exception.Message }
    Assert-True ($message -match 'park_state')
    Assert-Equal 0 $script:Persistence.Pending.Count
    Assert-Equal 0 @(Get-ChildItem $root -Recurse -Filter 'Domenia-migration-*.db').Count
}
Test-Case 'D113 G2 : nombres dates et lignes invalides comptes, metadonnees sans detail libre' {
    [void](New-G23Fixture)
    $park=Join-Path $script:DataDir 'Index\parc.tsv'
    [IO.File]::AppendAllText($park,([Environment]::NewLine+(('PC2','2026-01-01','Observe','alice','pas-un-nombre') -join [char]9)+[Environment]::NewLine+'incomplete'),[Text.Encoding]::UTF8)
    $plan=Invoke-DomeniaDatabaseMaintenance -ImportLegacy -DryRun
    Assert-Equal 2 $plan.RejectedLines;Assert-Equal 1 $plan.Payload.Park.Count
    Assert-Equal '2026-01-01T10:00:00.0000000Z' $plan.Payload.Secrets[0].At
    Assert-False ($null -ne $plan.Payload.Secrets[0].PSObject.Properties['Detail'])
}
Test-Case 'D113 G3 : Non ne sauvegarde ni ne met en file, Oui importe une seule fois' {
    $root=New-G23Fixture
    Request-DomeniaLegacyImport
    Assert-Equal 0 $script:InlineCalls 'La simulation est asynchrone'
    Assert-Equal 'Preview' $script:LastStoragePayload.Mode
    Complete-TestMigrationWorker
    Assert-Equal 1 $script:InlineCalls
    & $script:InlineCancel
    Assert-Equal 0 $script:Persistence.Pending.Count
    Assert-Equal 0 @(Get-ChildItem $root -Recurse -Filter 'Domenia-migration-*.db').Count
    Request-DomeniaLegacyImport
    Complete-TestMigrationWorker
    & $script:InlineConfirm
    Complete-TestMigrationWorker
    Assert-Equal 1 $script:Persistence.Pending.Count
    $message='';try { & $script:InlineConfirm;Complete-TestMigrationWorker } catch { $message=$_.Exception.Message }
    Assert-True ($message -match 'Contexte');Assert-Equal 1 $script:Persistence.Pending.Count
}
Test-Case 'D113 G3 : source changee entre simulation et confirmation refusee avant sauvegarde' {
    $root=New-G23Fixture
    Request-DomeniaLegacyImport
    Complete-TestMigrationWorker
    [IO.File]::AppendAllText((Join-Path $script:DataDir 'Index\parc.tsv'),[Environment]::NewLine,[Text.Encoding]::UTF8)
    $message='';try { & $script:InlineConfirm;Complete-TestMigrationWorker } catch { $message=$_.Exception.Message }
    Assert-True ($message -match 'change')
    Assert-Equal 0 $script:Persistence.Pending.Count
    Assert-Equal 0 @(Get-ChildItem $root -Recurse -Filter 'Domenia-migration-*.db').Count
}
Test-Case 'D113 G3 : contexte change ou blocage ne propose aucune ecriture' {
    [void](New-G23Fixture)
    Request-DomeniaLegacyImport
    Complete-TestMigrationWorker
    $script:SessionEpoch++
    $message='';try { & $script:InlineConfirm;Complete-TestMigrationWorker } catch { $message=$_.Exception.Message }
    Assert-True ($message -match 'Contexte')
    $script:Conn.BaseDn='DC=other,DC=invalid'
    $script:InlineCalls=0
    Request-DomeniaLegacyImport
    Complete-TestMigrationWorker
    Assert-Equal 0 $script:InlineCalls;Assert-Equal 0 $script:Persistence.Pending.Count
}
Test-Case 'D113 G2 : base absente ou ecriture en attente interdit la reprise' {
    [void](New-G23Fixture)
    $script:Persistence.LinkBusy=$true
    $message='';try { [void](Invoke-DomeniaDatabaseMaintenance -ImportLegacy) } catch { $message=$_.Exception.Message }
    Assert-True ($message -match 'enregistrement')
    $script:DatabaseScopedPath=''
    $message='';try { [void](Invoke-DomeniaDatabaseMaintenance -ImportLegacy -DryRun) } catch { $message=$_.Exception.Message }
    Assert-True ($message -match 'Base du contexte')
    Assert-Equal 0 $script:Persistence.Pending.Count
}
Test-Case 'D113 G3 : geste declare et aucune reprise au demarrage ni SQL direct du lecteur' {
    $text=[IO.File]::ReadAllText($core)
    Assert-True ($text.Contains('x:Name="BtnGuardLegacyImport"'))
    Assert-True ($text.Contains('"BtnGuardLegacyImport" = "Default"'))
    $init=Get-FunctionTextFromFile $core 'Initialize-DomeniaDatabase'
    Assert-False ($init -match 'Import-DomeniaLegacyStoreIfNeeded|Invoke-DomeniaDatabaseMaintenance')
    $source=[IO.File]::ReadAllText((Join-Path $modules 'Domenia-Migration.UI.ps1'))
    Assert-False ($source -match 'Invoke-DomeniaDbExec|Save-DomeniaIndex|Save-UserMachineLinks|Show-DomeniaDialog')
    Assert-True ($source.Contains('Request-DomeniaInlineConfirmation'))
    Assert-True ([IO.File]::ReadAllText((Join-Path $modules 'Domenia-Guard.UI.ps1')).Contains('BtnGuardLegacyImport={Request-DomeniaLegacyImport}'))
}
Test-Case 'D113 G2 : DN avec espaces normalise et doublons de cache refuses avant sauvegarde' {
    $root=New-G23Fixture
    $path=Join-Path $script:DataDir 'Index\objets.tsv'
    $text=[IO.File]::ReadAllText($path).Replace('CN=PC1,DC=example,DC=invalid','CN=PC1, DC=example, DC=invalid')
    [IO.File]::WriteAllText($path,$text,[Text.Encoding]::UTF8)
    $plan=Invoke-DomeniaDatabaseMaintenance -ImportLegacy -DryRun
    Assert-Equal 'CN=PC1,DC=example,DC=invalid' $plan.Payload.Objects[0].DN
    $park=Join-Path $script:DataDir 'Index\parc.tsv'
    [IO.File]::AppendAllText($park,([Environment]::NewLine+[IO.File]::ReadAllText($park)),[Text.Encoding]::UTF8)
    $message='';try { [void](Invoke-DomeniaDatabaseMaintenance -ImportLegacy) } catch { $message=$_.Exception.Message }
    Assert-True ($message -match 'Doublon')
    Assert-Equal 0 $script:Persistence.Pending.Count
    Assert-Equal 0 @(Get-ChildItem $root -Recurse -Filter 'Domenia-migration-*.db').Count
}
Test-Case 'D113 G3 : lecteur reel en runspace, Dispatcher vivant et base intacte' {
    [void](New-G23Fixture)
    $sha=(Get-FileHash $script:TestDbPath -Algorithm SHA256).Hash
    $Payload=[pscustomobject]@{Mode='Preview';Path=$script:TestDbPath;DataDir=$script:DataDir;LocalAppData=$env:LOCALAPPDATA;BaseDn=$script:Conn.BaseDn;Epoch=$script:SessionEpoch;BackupTimeoutSeconds=30}
    $ps=[powershell]::Create();$timer=[Windows.Threading.DispatcherTimer]::new()
    $script:MigrationHeartbeat=0;$timer.Interval=[timespan]::FromMilliseconds(5);$timer.Add_Tick({$script:MigrationHeartbeat++})
    try {
        [void]$ps.AddScript(('param($Payload)'+[Environment]::NewLine+(Get-DomeniaMigrationWorkerCode))).AddArgument($Payload)
        $timer.Start();$async=$ps.BeginInvoke();$watch=[Diagnostics.Stopwatch]::StartNew()
        while (-not $async.IsCompleted -and $watch.ElapsedMilliseconds -lt 20000) { Invoke-WiringPump 10 }
        Assert-True $async.IsCompleted 'Lecteur trop lent ou bloque'
        $rows=@($ps.EndInvoke($async));Assert-Equal 0 $ps.Streams.Error.Count ($ps.Streams.Error -join ' ')
        Assert-Equal 1 $rows.Count;Assert-True $rows[0].Allowed;Assert-Equal 70 $rows[0].AddCount
        Assert-True ($script:MigrationHeartbeat -gt 0) 'Dispatcher bloque pendant la lecture'
        $Payload.Mode='Prepare';$Payload | Add-Member -NotePropertyName ExpectedFingerprint -NotePropertyValue $rows[0].Fingerprint
        $ps.Commands.Clear()
        [void]$ps.AddScript(('param($Payload)'+[Environment]::NewLine+(Get-DomeniaMigrationWorkerCode))).AddArgument($Payload)
        $async=$ps.BeginInvoke();$watch.Restart()
        while (-not $async.IsCompleted -and $watch.ElapsedMilliseconds -lt 20000) { Invoke-WiringPump 10 }
        Assert-True $async.IsCompleted 'Sauvegarde trop lente ou bloquee'
        $prepared=@($ps.EndInvoke($async));Assert-Equal 0 $ps.Streams.Error.Count ($ps.Streams.Error -join ' ')
        Assert-True ([IO.File]::Exists([string]$prepared[0].BackupPath)) 'Sauvegarde isolee absente'
        Assert-Equal $sha (Get-FileHash $script:TestDbPath -Algorithm SHA256).Hash
    } finally { $timer.Stop();$ps.Dispose() }
}
$env:LOCALAPPDATA=$script:G23LocalAppData


# Extract the unchanged production bodies once; each case still imports them in its own scope.
$script:OfflineCoreDefinitions=@(foreach($name in @('Apply-CurrentPermissionUi','Get-WriteControlMap','Get-DomeniaSafetyDescriptor','Get-DomeniaEntryFirstString','Get-DeProp','Assert-DomeniaCapability','Assert-DomeniaRemoteWriteAllowed')){Get-FunctionTextFromFile $core $name}) -join "`n"
$script:OfflineExplanationDefinition=Get-FunctionTextFromFile (Join-Path $modules 'Domenia-Access.UI.ps1') 'Get-DomeniaControlCapabilityExplanation'
$script:OfflineFixture=@'
foreach($file in @('Domenia-Common.Model.ps1','Domenia-Cache.Model.ps1','Domenia-Access.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Guard.Model.ps1','Domenia-Shell.Model.ps1','Domenia-Experience.Model.ps1','Domenia-Selection.UI.ps1','Domenia-Engine.UI.ps1')){. (Join-Path $modules $file)}
. ([scriptblock]::Create($script:OfflineCoreDefinitions))
. ([scriptblock]::Create($script:OfflineExplanationDefinition))
function Get-DomeniaControl {param($Name) return $script:Ctrl[$Name]}
function Set-DomeniaControlText {param($Name,$Text) if($null -ne $script:Ctrl[$Name]){$script:Ctrl[$Name].Text=$Text};return $true}
function Get-CfgValue {param($Section,$Name,$Default) if($Name -eq 'AllowRawAttributeWrite'){return $true};return $Default}
function Test-DomeniaActualCapabilityDenied {param($Dn,$Capability) return $false}
function Restore-DomeniaUxBaseToolTip {param($Name)}
function Update-DomeniaWriteModeVisual {}
function Update-DomeniaSecretActionUi {}
function Update-Dashboard {throw 'Aucune actualisation de tableau de bord pendant une transition reseau'}
function Apply-DomeniaGuiElementPolicy {throw 'Aucun parcours global pendant une transition reseau'}
function Set-VisibleTabsForType {param($Type,[switch]$PreserveWorkspace)}
function Test-DomeniaSelectionLoadCurrent {return ($null -ne $script:SelectionLoad -and $script:SelectionLoad.Context.Epoch -eq $script:SessionEpoch)}
function Test-DomeniaAccessBusyWrite {return ($script:WriteState -in @('Unknown','UnknownPending') -or [bool]$script:ActiveWriteTaskId)}
function Assert-WriteAllowed {}
function Start-UiTask {throw 'Aucun worker lance pendant une transition reseau'}
function Invoke-DomeniaDbQuery {throw 'Aucune lecture SQLite pendant une transition reseau'}
$script:SessionEpoch=5L;$script:SelectedObjectGeneration=1L;$script:AsyncTimer=$null
$script:DirectoryReachability=$null;$script:DomeniaSchedulerEnabled=$false;$script:DomeniaProviderState=$null
$script:Ctrl=@{};$script:CurrentCapabilities=@{};$script:ControlBusyRef=@{}
$script:WriteState='Idle';$script:ActiveWriteTaskId='';$script:ReadOnlyMode=$false;$script:DemoMode=$false;$script:ShowingCachedObject=$false
$guid='11111111-1111-1111-1111-111111111111';$dn='CN=PC,DC=example,DC=invalid'
$script:SelectedObject=[pscustomobject]@{DN=$dn;Type='Machine';Name='PC';LoadedAt=(Get-Date);Safety=[pscustomobject]@{Guid=$guid;AdminCount='0';Critical=$false};Entry=[pscustomobject]@{Properties=@{objectGUID=@($guid);uSNChanged=@('20');whenChanged=@('20260101000000.0Z');name=@('PC')}}}
[void](Set-DomeniaObservationTime $script:SelectedObject 'Attributes' ([datetime]::UtcNow.AddMinutes(-1)))
$script:SelectionLoad=[pscustomobject]@{Phase='Ready';Message='';VisibleType='Machine';Context=[pscustomobject]@{DN=$dn;Guid=$guid;Type='Machine';Name='PC';Epoch=5L}}
$map=Get-WriteControlMap
foreach($cap in $map.Keys){$script:CurrentCapabilities[$cap]='Autorise';foreach($name in $map[$cap]){$script:Ctrl[$name]=[Windows.Controls.Button]::new()}}
foreach($name in @('BtnCompGpUpdate','BtnCompRestart','BtnObjectReadRetry','BtnComputerReadRetry')){$script:Ctrl[$name]=[Windows.Controls.Button]::new()}
foreach($name in @('LblSelectionReadState','LblObjectReadStatus','LblComputerReadStatus','LblPrivilegeTop')){$script:Ctrl[$name]=[Windows.Controls.TextBlock]::new()}
foreach($name in @('ObjectReadContent','ComputerReadContent','ObjectReadPlaceholder','ComputerReadPlaceholder')){$script:Ctrl[$name]=[Windows.Controls.Border]::new()}
$script:Ctrl.ChkReadOnlyMode=[Windows.Controls.CheckBox]::new();$script:Ctrl.ChkReadOnlyMode.IsChecked=$false
$job=[pscustomobject]@{Provider='Directory';Demo=$false;SessionEpoch=5L;SchedulerManaged=$false;OperationId='GlobalSearch';ProviderTarget='dc.example.invalid'}
Initialize-DomeniaEngineState
Apply-CurrentPermissionUi -StartupFastPath
'@
Test-Case 'D030 : panne AD sur une fiche prete garde la lecture visible et verrouille toutes les ecritures' {
    . ([scriptblock]::Create($script:OfflineFixture))
    Assert-True $script:Ctrl.BtnUserSave.IsEnabled
    [void](Register-DomeniaTaskOutcome $job -ErrorMessage '[DOMENIA:Unavailable;0;0x8007203A] Serveur indisponible')
    Assert-True $script:DirectoryReachability.Offline
    Assert-True $script:Ctrl.ObjectReadContent.IsEnabled 'Une fiche deja prete reste consultable'
    foreach($name in @(@($map.Values | ForEach-Object {$_})+@('BtnCompGpUpdate','BtnCompRestart'))){
        Assert-False $script:Ctrl[$name].IsEnabled $name
        Assert-True ($script:Ctrl[$name].ToolTip -match 'Hors ligne') $name
    }
    $thrown=$false;try{Get-DomeniaSafetyDescriptor}catch{$thrown=$_.Exception.Message -match 'hors ligne'};Assert-True $thrown
    Assert-True ((Get-DomeniaControlCapabilityExplanation 'BtnUserSave').Text -match 'Hors ligne')
    Assert-Equal 0 $script:Logs.Count 'Le raccordement ne masque aucune erreur'
}
Test-Case 'D030 : retour du reseau sans relecture ne rend pas la fiche modifiable' {
    . ([scriptblock]::Create($script:OfflineFixture))
    [void](Register-DomeniaTaskOutcome $job -ErrorMessage '[DOMENIA:Unavailable;0;0x8007203A] Serveur indisponible')
    $outage=$script:DirectoryReachability.LastOutageUtc
    [void](Register-DomeniaTaskOutcome $job)
    Assert-False $script:DirectoryReachability.Offline
    Assert-Equal $outage $script:DirectoryReachability.LastOutageUtc
    Assert-False $script:Ctrl.BtnUserSave.IsEnabled
    Assert-False (Get-DomeniaSelectionCachePolicy).CanEdit
    # A newly validated attribute read, after the outage, permits edits again.
    [void](Set-DomeniaObservationTime $script:SelectedObject 'Attributes' (ConvertTo-DomeniaUtcDate $outage).AddMilliseconds(1))
    Apply-CurrentPermissionUi -StartupFastPath
    Assert-True (Get-DomeniaSelectionCachePolicy).CanEdit
    Assert-True $script:Ctrl.BtnUserSave.IsEnabled
    Assert-Equal $dn (Get-DomeniaSafetyDescriptor).ExpectedDn
}
Test-Case 'D030 : ouverture directe depuis un cache recent reste historique' {
    . ([scriptblock]::Create($script:OfflineFixture))
    $script:SelectionLoad=$null;$script:SelectedObject.Times=@{}
    $policy=Get-DomeniaSelectionCachePolicy
    Assert-True $policy.CanView;Assert-True $policy.CanCopy;Assert-False $policy.CanEdit
    Assert-True ($script:SelectedObject.LoadedAt -gt (Get-Date).AddMinutes(-1))
    $thrown=$false;try{Get-DomeniaSafetyDescriptor}catch{$thrown=$_.Exception.Message -match 'relecture'};Assert-True $thrown
}
Test-Case 'D030 : cache ou echec hors ligne reste visible grise et peut etre relu explicitement' {
    . ([scriptblock]::Create($script:OfflineFixture))
    $script:SelectionLoad.Phase='Cached';$script:SelectedObject.Times=@{}
    [void](Register-DomeniaTaskOutcome $job -ErrorMessage '[DOMENIA:Unavailable;0;0x8007203A] Serveur indisponible')
    Update-DomeniaSelectionReadUi -Phase Failed -Message 'Serveur indisponible'
    Assert-Equal 'Visible' $script:Ctrl.ObjectReadContent.Visibility
    Assert-False $script:Ctrl.ObjectReadContent.IsEnabled
    Assert-True $script:Ctrl.BtnObjectReadRetry.IsEnabled
    Assert-True ($script:Ctrl.LblObjectReadStatus.ToolTip -match 'hors ligne')
    Assert-False (Get-DomeniaSelectionCachePolicy).CanRetry 'CanRetry concerne le rejeu automatique'
    $script:WriteState='Unknown'
    Assert-Equal 'Operation a verifier' (Get-DomeniaSelectionCachePolicy).Reason
    Update-DomeniaSelectionReadUi
    Assert-False $script:Ctrl.BtnObjectReadRetry.IsEnabled
}
Test-Case 'D030 : delai CIM annulation demonstration et ancienne session ne changent pas le badge AD' {
    . ([scriptblock]::Create($script:OfflineFixture))
    $job.Provider='Cim';[void](Register-DomeniaTaskOutcome $job -TimedOut);Assert-False $script:DirectoryReachability.Offline;Assert-False $script:DirectoryReachability.Slow
    $job.Provider='Directory';[void](Register-DomeniaTaskOutcome $job -TimedOut -Cancelled);Assert-False $script:DirectoryReachability.Offline;Assert-False $script:DirectoryReachability.Slow
    $job.Demo=$true;[void](Register-DomeniaTaskOutcome $job -TimedOut);Assert-False $script:DirectoryReachability.Offline;Assert-False $script:DirectoryReachability.Slow
    $job.Demo=$false;$job.SessionEpoch=4L;[void](Register-DomeniaTaskOutcome $job -TimedOut);Assert-False $script:DirectoryReachability.Offline;Assert-False $script:DirectoryReachability.Slow
    $job.SessionEpoch=5L;[void](Register-DomeniaTaskOutcome $job -TimedOut)
    Assert-False $script:DirectoryReachability.Offline;Assert-True $script:DirectoryReachability.Slow 'Le delai doit etre signale meme sans ordonnanceur'
    Assert-Equal $null $script:DirectoryReachability.LastOutageUtc
    Assert-True $script:Ctrl.BtnUserSave.IsEnabled 'Un delai seul ne bloque pas une fiche deja validee'
}
Test-Case 'D030 : un delai apres une panne ne leve aucune protection decriture' {
    . ([scriptblock]::Create($script:OfflineFixture))
    [void](Register-DomeniaTaskOutcome $job -ErrorMessage '[DOMENIA:Unavailable;0;0x8007203A] Serveur indisponible')
    $outage=$script:DirectoryReachability.LastOutageUtc
    [void](Register-DomeniaTaskOutcome $job -TimedOut)
    Assert-True $script:DirectoryReachability.Offline;Assert-True $script:DirectoryReachability.Slow
    Assert-Equal $outage $script:DirectoryReachability.LastOutageUtc
    Assert-False $script:Ctrl.BtnUserSave.IsEnabled
    Assert-False (Get-DomeniaSelectionCachePolicy).CanEdit
}
Test-Case 'D030 : les points entree AD et poste refusent hors ligne sans lancer de travail' {
    . ([scriptblock]::Create($script:OfflineFixture))
    [void](Register-DomeniaTaskOutcome $job -ErrorMessage '[DOMENIA:Unavailable;0;0x8007203A] Serveur indisponible')
    foreach($action in @({Assert-DomeniaCapability Edit},{Assert-DomeniaRemoteWriteAllowed 'GPUpdate'})){
        $thrown=$false;try{& $action}catch{$thrown=$_.Exception.Message -match 'Hors ligne'};Assert-True $thrown
    }
    $script:SessionEpoch=6L;Initialize-DomeniaEngineState
    Assert-False $script:DirectoryReachability.Offline 'L ancien compte ne decide pas du nouveau contexte'
}
Test-Case 'D030 : ancienne identite ou attributs expires bloquent les modifications' {
    . ([scriptblock]::Create($script:OfflineFixture))
    $script:SelectedObject.Times.Attributes.ObservedUtc=[datetime]::UtcNow.AddHours(-1).ToString('o')
    Assert-False (Get-DomeniaSelectionCachePolicy).CanEdit
    [void](Set-DomeniaObservationTime $script:SelectedObject 'Attributes' ([datetime]::UtcNow))
    $script:SelectionLoad.Context.Guid='22222222-2222-2222-2222-222222222222'
    Assert-False (Get-DomeniaSelectionCachePolicy).CanEdit
    Assert-False (Get-DomeniaSelectionCachePolicy).CanView
}
Test-Case 'D030 : transition sans lecture disque ni worker et erreurs du raccordement tracees' {
    . ([scriptblock]::Create($script:OfflineFixture))
    function Apply-CurrentPermissionUi {param([switch]$StartupFastPath) throw 'erreur UI fictive'}
    [void](Register-DomeniaTaskOutcome $job -ErrorMessage '[DOMENIA:Unavailable;0;0x8007203A] Serveur indisponible')
    Assert-True $script:DirectoryReachability.Offline
    Assert-True (@($script:Logs | Where-Object{$_ -match 'Etat de connexion AD non applique.*erreur UI fictive'}).Count -eq 1)
    $text=Get-FunctionTextFromFile (Join-Path $modules 'Domenia-Engine.UI.ps1') 'Register-DomeniaTaskOutcome'
    Assert-False ($text -match 'Get-Command|Start-UiTask|Invoke-DomeniaDbQuery')
}


# K2: only disposable folders in the VM. Deny ACEs never touch the profile or installation.
$script:StorageCoreDefinitions=@(foreach($name in @('Get-DomeniaPreferencePath','Read-DomeniaPreference','Write-DomeniaPreference','Write-DomeniaAtomicText','Protect-DomeniaLogText','Initialize-DomeniaDataStore','Get-DomeniaFastLoginLogPath','Add-DomeniaUiLog')){Get-FunctionTextFromFile $core $name}) -join "`n"
$script:StorageUiDefinitions=@(foreach($name in @('Invoke-DomeniaPreferenceMigration')){Get-FunctionTextFromFile $storageUi $name}) -join "`n"
function Invoke-PreferenceSandbox {
    param([scriptblock]$Body)
    $sandbox=Join-Path ([IO.Path]::GetTempPath()) ('domenia-preferences-'+[guid]::NewGuid().ToString('N'))
    $savedEnvironment=@{LOCALAPPDATA=$env:LOCALAPPDATA;TEMP=$env:TEMP;TMP=$env:TMP}
    $savedState=@{}
    foreach($name in @('RootDir','DataDir','DataStoreValidated','StorageLayout','StoragePreferenceWarning','FastLoginLogPath','AuditPath','StartupTracePath','PreferenceLegacyReads')){
        $value=Get-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue
        $savedState[$name]=if($null -ne $value){$value.Value}else{$null}
    }
    $denied=New-Object 'System.Collections.Generic.List[object]'
    $script:RootDir=Join-Path $sandbox 'app\wad';$script:DataDir='';$script:DataStoreValidated=$false
    $script:StorageLayout=$null;$script:StoragePreferenceWarning='';$script:FastLoginLogPath='';$script:PreferenceLegacyReads=@{}
    $script:StorageMode='Portable';$script:StorageTrace=New-Object 'System.Collections.Generic.List[string]'
    $script:StorageUserRoot=Join-Path $sandbox 'profile'
    $env:LOCALAPPDATA=$script:StorageUserRoot;$env:TEMP=Join-Path $sandbox 'temp';$env:TMP=$env:TEMP
    foreach($dir in @($script:RootDir,$script:StorageUserRoot,$env:TEMP)){[void][IO.Directory]::CreateDirectory($dir)}
    . ([scriptblock]::Create($script:StorageCoreDefinitions))
    . ([scriptblock]::Create($script:StorageUiDefinitions))
    function Get-CfgValue {param($Section,$Name,$Default) if($Section -eq 'LocalStore' -and $Name -eq 'Mode'){return $script:StorageMode};return $Default}
    function Get-DomeniaUserLocalRoot {return $script:StorageUserRoot}
    function Write-StartupTrace {param($Stage,$Status,$Detail,$DurationMs) $script:StorageTrace.Add($Stage+' '+$Status+' '+$Detail)}
    function Set-StorageSandboxDeny {
        param([string]$Path)
        Assert-True ($Path.StartsWith($sandbox+'\',[StringComparison]::OrdinalIgnoreCase)) 'ACE hors du bac a sable refusee'
        [void][IO.Directory]::CreateDirectory($Path)
        $acl=[IO.Directory]::GetAccessControl($Path)
        $denied.Add([pscustomobject]@{Path=$Path;Acl=$acl})
        $denyAcl=[IO.Directory]::GetAccessControl($Path)
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule=[Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::Write,([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Deny)
        $denyAcl.AddAccessRule($rule);[IO.Directory]::SetAccessControl($Path,$denyAcl)
    }
    try {& $Body}
    finally {
        foreach($entry in $denied){[IO.Directory]::SetAccessControl($entry.Path,$entry.Acl)}
        foreach($name in $savedState.Keys){Set-Variable -Name $name -Scope Script -Value $savedState[$name]}
        foreach($name in $savedEnvironment.Keys){[Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name],'Process')}
        if([IO.Directory]::Exists($sandbox)){[IO.Directory]::Delete($sandbox,$true)}
    }
}
Test-Case 'D118 : copie reelle une fois, original intact et second passage sans ecriture' {
    Invoke-PreferenceSandbox {
        [void](Initialize-DomeniaDataStore)
        $source=Join-Path $script:DataDir 'Domenia.settings.json';$target=(Get-DomeniaPreferencePath 'Domenia.settings.json').User
        [IO.File]::WriteAllText($source,'{"Theme":"Dark","LogHeight":270}')
        $hash=(Get-FileHash $source -Algorithm SHA256).Hash
        $first=Invoke-DomeniaPreferenceMigration
        Assert-Equal 1 $first.Copied;Assert-Equal 0 @($first.Errors).Count
        Assert-Equal $hash (Get-FileHash $target -Algorithm SHA256).Hash;Assert-Equal $hash (Get-FileHash $source -Algorithm SHA256).Hash
        $stamp=(Get-Item $target).LastWriteTimeUtc
        $second=Invoke-DomeniaPreferenceMigration
        Assert-Equal 0 $second.Copied;Assert-Equal $stamp (Get-Item $target).LastWriteTimeUtc
        Assert-Equal 0 @(Get-ChildItem (Split-Path $target) -Filter '*.tmp' -Force).Count
    }
}
Test-Case 'D118 : preference existante jamais ecrasee par une migration' {
    Invoke-PreferenceSandbox {
        [void](Initialize-DomeniaDataStore)
        $target=(Get-DomeniaPreferencePath 'Domenia.settings.json').User
        [IO.File]::WriteAllText($target,'{"Theme":"Light"}')
        [IO.File]::WriteAllText((Join-Path $script:DataDir 'Domenia.settings.json'),'{"Theme":"Dark"}')
        $hash=(Get-FileHash $target -Algorithm SHA256).Hash
        Assert-Equal 0 (Invoke-DomeniaPreferenceMigration).Copied
        Assert-Equal $hash (Get-FileHash $target -Algorithm SHA256).Hash
    }
}
Test-Case 'D118 : DataDir refuse par ACE, aucun repli de preferences' {
    Invoke-PreferenceSandbox {
        Set-StorageSandboxDeny (Join-Path $script:RootDir 'data')
        $errorText='';try{[void](Initialize-DomeniaDataStore)}catch{$errorText=$_.Exception.Message}
        Assert-True ($errorText -match 'Aucun repli silencieux') $errorText
        Assert-False $script:DataStoreValidated
        Assert-False (Write-DomeniaPreference 'Domenia.settings.json' '{}')
        Assert-Equal 0 @(Get-ChildItem $sandbox -Filter 'Domenia.settings.json' -Recurse -Force).Count
        $log=Get-DomeniaFastLoginLogPath
        Assert-Equal (Join-Path $env:LOCALAPPDATA 'DOMENIA\Logs\Domenia-login.log') $log
    }
}
Test-Case 'D118 : Preferences refuse par ACE, avertissement et aucune ecriture ailleurs' {
    Invoke-PreferenceSandbox {
        Set-StorageSandboxDeny (Join-Path $script:RootDir 'data\Preferences')
        [void](Initialize-DomeniaDataStore)
        Assert-True $script:DataStoreValidated
        Assert-True ($script:StoragePreferenceWarning -match [regex]::Escape((Join-Path $script:DataDir 'Preferences')))
        Assert-False (Write-DomeniaPreference 'Domenia.settings.json' '{}')
        Assert-Equal 0 @(Get-ChildItem $sandbox -Filter 'Domenia.settings.json' -Recurse -Force).Count
        Assert-Equal 0 (Invoke-DomeniaPreferenceMigration).Copied
    }
}
Test-Case 'D118 : DataDir vide donne un chemin vide et aucune sauvegarde alternative' {
    Invoke-PreferenceSandbox {
        $paths=Get-DomeniaPreferencePath 'Domenia.settings.json'
        Assert-Equal '' $paths.User;Assert-Equal '' $paths.Previous;Assert-True ($paths.Legacy -is [string])
        Assert-False (Write-DomeniaPreference 'Domenia.settings.json' '{}')
        Assert-Equal 0 @(Get-ChildItem $sandbox -Filter 'Domenia.settings.json' -Recurse -Force).Count
    }
}
Test-Case 'D118 : Preferences en jonction refuse a la lecture et a l ecriture' {
    Invoke-PreferenceSandbox {
        $external=Join-Path $sandbox 'junction-target';[void][IO.Directory]::CreateDirectory($external)
        [IO.File]::WriteAllText((Join-Path $external 'Domenia.settings.json'),'{"Theme":"Dark"}')
        [void][IO.Directory]::CreateDirectory((Join-Path $script:RootDir 'data'))
        $junction=Join-Path $script:RootDir 'data\Preferences'
        [void](New-Item -ItemType Junction -Path $junction -Target $external)
        try {
            [void](Initialize-DomeniaDataStore)
            Assert-True ($script:StoragePreferenceWarning -match 'Lien')
            Assert-Equal '' (Read-DomeniaPreference 'Domenia.settings.json')
            Assert-False (Write-DomeniaPreference 'Domenia.settings.json' '{}')
            Assert-Equal '{"Theme":"Dark"}' ([IO.File]::ReadAllText((Join-Path $external 'Domenia.settings.json')))
        } finally {[IO.Directory]::Delete($junction)}
    }
}
Test-Case 'D118 : droits observes transmis a la regle, recus non observes' {
    Invoke-PreferenceSandbox {
        $rule=(Get-Item function:Get-DomeniaStorageLayout).ScriptBlock
        $script:StorageRightsCalls=New-Object 'System.Collections.Generic.List[object]'
        function Get-DomeniaStorageLayout {
            param($Mode,$InstallRoot,$UserLocalRoot,$PortableHasData,$Writable)
            $script:StorageRightsCalls.Add($Writable)
            & $rule -Mode $Mode -InstallRoot $InstallRoot -UserLocalRoot $UserLocalRoot -PortableHasData $PortableHasData -Writable $Writable
        }
        Set-StorageSandboxDeny (Join-Path $script:RootDir 'data\Preferences')
        [void](Initialize-DomeniaDataStore)
        $observed=$script:StorageRightsCalls[$script:StorageRightsCalls.Count-1]
        Assert-True $observed.Cache;Assert-False $observed.Preference
        Assert-False $observed[(Join-Path $script:DataDir 'Preferences')]
        Assert-False $observed.ContainsKey('Receipt')
        Assert-Equal 'Non verifie' @($script:StorageLayout.Categories | Where-Object {$_.Category -eq 'Receipt'})[0].State
    }
}
Test-Case 'D118 : fichiers livres non copies et lecture historique tracee une fois' {
    Invoke-PreferenceSandbox {
        [void](Initialize-DomeniaDataStore)
        foreach($name in @('Domenia.settings.json','Domenia.theme.cfg','Domenia.ui-profile.cfg')){[IO.File]::WriteAllText((Join-Path $script:RootDir $name),'{}')}
        Assert-Equal 0 (Invoke-DomeniaPreferenceMigration).Copied
        Assert-Equal 0 @(Get-ChildItem (Join-Path $script:DataDir 'Preferences') -File).Count
        Assert-Equal '{}' (Read-DomeniaPreference 'Domenia.settings.json')
        Assert-Equal '{}' (Read-DomeniaPreference 'Domenia.settings.json')
        Assert-Equal 1 @($script:StorageTrace | Where-Object {$_ -like 'Preferences/LectureHistorique*'}).Count
    }
}
Test-Case 'D118 : journaux suivent la zone Logs du mode portable' {
    Invoke-PreferenceSandbox {
        [void](Initialize-DomeniaDataStore)
        $logs=[string](@(@($script:StorageLayout.Categories | Where-Object {$_.Category -eq 'Cache'})[0].Areas | Where-Object {$_.Name -eq 'Logs'})[0].Path)
        Assert-Equal (Join-Path $logs 'Domenia.log') $script:AuditPath
        Assert-Equal (Join-Path $logs 'Domenia-startup.log') $script:StartupTracePath
        Assert-Equal (Join-Path $logs 'Domenia-login.log') (Get-DomeniaFastLoginLogPath)
        Assert-Equal 0 @(Get-ChildItem $script:StorageUserRoot -File -Recurse).Count
    }
}
Test-Case 'D118 : erreur du journal UI enregistree dans DataDir Logs' {
    Invoke-PreferenceSandbox {
        [void](Initialize-DomeniaDataStore)
        function Get-DomeniaControl {param($Name) throw 'erreur UI fictive'}
        Add-DomeniaUiLog -Area 'Test' -Text 'message'
        $path=Join-Path $script:DataDir 'Logs\Domenia-ui-log-errors.log'
        Assert-True ([IO.File]::Exists($path))
        Assert-True ([IO.File]::ReadAllText($path) -match 'erreur UI fictive')
        Assert-Equal 0 @(Get-ChildItem $script:StorageUserRoot -File -Recurse).Count
    }
}
Test-Case 'D118 : UserLocal isole, chemins du coeur alignes avec la regle' {
    Invoke-PreferenceSandbox {
        $script:StorageMode='UserLocal';[void](Initialize-DomeniaDataStore)
        Assert-Equal (Join-Path $script:StorageUserRoot 'Domenia\Data') $script:DataDir
        $paths=Get-DomeniaPreferencePath 'Domenia.settings.json'
        Assert-Equal (Join-Path $script:DataDir 'Preferences\Domenia.settings.json') $paths.User
        Assert-Equal (Join-Path $script:DataDir 'Domenia.settings.json') $paths.Previous
        Assert-True (Write-DomeniaPreference 'Domenia.settings.json' '{}')
        Assert-True ([IO.File]::Exists($paths.User));Assert-False ([IO.File]::Exists($paths.Previous))
        Assert-False ([IO.Directory]::Exists((Join-Path $script:RootDir 'data')))
        $worker=Get-FunctionTextFromFile $core 'Get-WorkerContext'
        Assert-True ($worker -match "ReceiptRoot\s*=.*LocalApplicationData.*Domenia\\Receipts")
    }
}
Test-Case 'D118 : disposition absente ou incoherente refusee explicitement' {
    Invoke-PreferenceSandbox {
        function Get-DomeniaStorageLayout {param($Mode,$InstallRoot,$UserLocalRoot,$PortableHasData,$Writable) return $null}
        $errorText='';try{[void](Initialize-DomeniaDataStore)}catch{$errorText=$_.Exception.Message}
        Assert-True ($errorText -match 'DOMENIA_STORE_LAYOUT') $errorText
        Assert-False $script:DataStoreValidated
    }
}
Test-Case 'D118 : journal de secours TEMP si le profil refuse aussi les ecritures' {
    Invoke-PreferenceSandbox {
        Set-StorageSandboxDeny (Join-Path $script:RootDir 'data')
        Set-StorageSandboxDeny (Join-Path $env:LOCALAPPDATA 'DOMENIA\Logs')
        $log=Get-DomeniaFastLoginLogPath
        Assert-Equal (Join-Path ([IO.Path]::GetTempPath()) 'DOMENIA\Logs\Domenia-login.log') $log
        Assert-False (Write-DomeniaPreference 'Domenia.settings.json' '{}')
        Assert-Equal 0 @(Get-ChildItem $sandbox -Filter 'Domenia.settings.json' -Recurse -Force).Count
    }
}
Test-Case 'D118 : migration reelle ignore JSON invalide et source trop grande' {
    Invoke-PreferenceSandbox {
        [void](Initialize-DomeniaDataStore)
        $source=Join-Path $script:DataDir 'Domenia.settings.json';$target=(Get-DomeniaPreferencePath 'Domenia.settings.json').User
        foreach($text in @('{"Password":"PREFERENCE-PRIVATE-MARKER"',('x'*(1MB+1)))){
            [IO.File]::WriteAllText($source,$text)
            $hash=(Get-FileHash $source -Algorithm SHA256).Hash
            $result=Invoke-DomeniaPreferenceMigration
            Assert-Equal 0 $result.Copied;Assert-False ([IO.File]::Exists($target))
            Assert-Equal 'Ignorer' $result.Plan.Steps[0].Action
            Assert-Equal $hash (Get-FileHash $source -Algorithm SHA256).Hash
            Assert-False (($script:StorageTrace -join ' ') -match 'PREFERENCE-PRIVATE-MARKER') 'Le diagnostic ne reproduit pas les valeurs du JSON invalide'
        }
    }
}
Test-Case 'D118 : source verrouillee, erreur tracee et aucune copie annoncee' {
    Invoke-PreferenceSandbox {
        [void](Initialize-DomeniaDataStore)
        $source=Join-Path $script:DataDir 'Domenia.settings.json';$target=(Get-DomeniaPreferencePath 'Domenia.settings.json').User
        [IO.File]::WriteAllText($source,'{"Theme":"Dark"}')
        $lock=[IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try {
            $result=Invoke-DomeniaPreferenceMigration
            Assert-Equal 0 $result.Copied;Assert-True (@($result.Errors).Count -gt 0)
            Assert-False ([IO.File]::Exists($target))
            Assert-True (@($script:StorageTrace | Where-Object {$_ -like '*Lecture des anciennes preferences impossible*'}).Count -gt 0)
            Assert-Equal 0 @($script:StorageTrace | Where-Object {$_ -like '*Copie confirmee*'}).Count
        } finally {$lock.Dispose()}
    }
}

# D029 L2: the pinned read-only worker runs against native SQLite, and the UI uses real WPF controls.
. ([scriptblock]::Create((Get-FunctionTextFromFile $storageWorker 'Get-DomeniaStorageUsageWorkerCode')))
$script:UsageControlDefinitions=@(foreach($name in @('Get-DomeniaControl','Set-DomeniaControlText')){Get-FunctionTextFromFile $core $name}) -join "`n"
$script:UsageUiDefinitions=@(foreach($name in @('Format-DomeniaStorageUsage','Start-DomeniaStorageUsage','Complete-DomeniaStorageUsage','Fail-DomeniaStorageUsage')){Get-FunctionTextFromFile $storageUi $name}) -join "`n"
function Invoke-UsageWorker {
    param([string]$Path=$script:TestDbPath)
    $Payload=[pscustomobject]@{Path=$Path}
    return & ([scriptblock]::Create((Get-DomeniaStorageUsageWorkerCode)))
}
function Add-UsageFixtureRows {
    $db=Open-DomeniaDatabase -Path $script:TestDbPath
    try {
        [void](Invoke-DomeniaDbExec @'
BEGIN IMMEDIATE;
CREATE TABLE adcc_live_queries(scope_key TEXT NOT NULL,query_key TEXT NOT NULL,observed_utc TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(scope_key,query_key));
CREATE TABLE adcc_live_observations(scope_key TEXT NOT NULL,object_key TEXT NOT NULL,checked_utc TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(scope_key,object_key));
INSERT INTO adcc_live_queries VALUES('scope','query','2026-01-01','{}');
INSERT INTO adcc_live_observations VALUES('scope','pc1','2026-01-01','{}');
INSERT INTO presence_cache(object_key,state) VALUES('pc1','Inconnu');
INSERT INTO park_state(computer_key,computer) VALUES('pc1','PC1');
INSERT INTO user_machine_history(computer_key,source) VALUES('pc1','Import CSV');
INSERT INTO user_scan_history(login_key,login) VALUES('alice','alice');
INSERT INTO operation_runs(operation) VALUES('Synthetic');
INSERT INTO ad_objects(object_key,object_type) VALUES('pc1','Computer');
INSERT INTO domenia_provenance(object_guid) VALUES('guid-pc1');
INSERT OR REPLACE INTO sync_state(scope,server) VALUES('legacy_import','legacy_import');
INSERT INTO user_machine_links(computer_key,user_login,source) VALUES('pc1','alice','Import CSV');
INSERT INTO secret_state(computer_key,verdict) VALUES('pc1','Synthetic');
COMMIT;
'@ $db)
        [void](Invoke-DomeniaDbExec 'PRAGMA wal_checkpoint(TRUNCATE);' $db)
    } finally {Close-DomeniaDatabase $db}
}
function Initialize-UsageUiFixture {
    $script:Ctrl=@{BtnStorageUsage=(New-Object Windows.Controls.Button);LblStorageUsage=(New-Object Windows.Controls.TextBlock)}
    $script:Ctrl.LblStorageUsage.Text='Avant mesure';$script:DetachedReadJobs=@();$script:AsyncJobs=@{}
    $script:UsageRequest=$null;$script:DatabaseScopedPath='C:\DomeniaLab\synthetic.db'
}
function New-UsagePacket {
    return [pscustomobject]@{Kind='StorageUsage';Path=$script:DatabaseScopedPath;ReadOnly=$true;MeasuredUtc='2026-01-01T12:00:00Z';DatabaseBytes=4096L;WalBytes=0L;ReusableBytes=0L;DbstatAvailable=$false;Categories=@(foreach($name in @('Observations','Snapshots','History','Index','ManualLinks','Secrets')){[pscustomobject]@{Category=$name;Rows=1L;Bytes=-1L}})}
}
Test-Case 'D029 : mesure native compte les six categories sans modifier la base' {
    $root=New-LegacySandbox
    try {
        Add-UsageFixtureRows
        $hash=(Get-FileHash $script:TestDbPath -Algorithm SHA256).Hash
        $result=Invoke-UsageWorker
        Assert-Equal 'StorageUsage' $result.Kind;Assert-True $result.ReadOnly
        Assert-Equal 6 @($result.Categories).Count
        # Index: the fixture rows plus the CO-26 repair marker of sync_state written at creation (lot L01).
        $expected=@{Observations=3;Snapshots=1;History=3;Index=4;ManualLinks=1;Secrets=1}
        foreach($c in $result.Categories){Assert-Equal $expected[$c.Category] $c.Rows $c.Category}
        Assert-Equal $hash (Get-FileHash $script:TestDbPath -Algorithm SHA256).Hash
        Assert-Equal ([IO.FileInfo]::new($script:TestDbPath).Length) $result.DatabaseBytes
        Assert-Equal ($result.FreePages*$result.PageSize) $result.ReusableBytes
        Assert-True ($result.WalBytes -ge 0)
        if(-not $result.DbstatAvailable){foreach($c in $result.Categories){Assert-Equal (-1L) $c.Bytes}}else{foreach($c in $result.Categories){Assert-True ($c.Bytes -gt 0)}}
        $script:CaseDetail='SQLite natif ; dbstat='+$result.DbstatAvailable+' ; base='+$result.DatabaseBytes+' octets ; six categories ; SHA256 inchange.'
    } finally {Remove-Item $root -Recurse -Force}
}
Test-Case 'D029 : dbstat optionnel absent donne inconnu mais une erreur SQLite reste une erreur' {
    $root=New-LegacySandbox
    try {
        Add-UsageFixtureRows
        $base=(Get-DomeniaStorageUsageWorkerCode).Replace('function Invoke-DomeniaDbQuery {','function Invoke-NativeUsageDbQuery {')
        $wrapper=@'
function Invoke-DomeniaDbQuery {
    param([string]$Sql,[IntPtr]$DatabaseHandle)
    if($Sql -like '*FROM dbstat*'){throw $Payload.OptionalError}
    return Invoke-NativeUsageDbQuery $Sql $DatabaseHandle
}
'@
        $base=$base.Replace('$path=Test-DomeniaStorageMeasurePath',($wrapper+"`n"+'$path=Test-DomeniaStorageMeasurePath'))
        $Payload=[pscustomobject]@{Path=$script:TestDbPath;OptionalError='SQLite prepare code 1 : no such table: dbstat'}
        $result=& ([scriptblock]::Create($base))
        Assert-False $result.DbstatAvailable
        foreach($category in $result.Categories){Assert-Equal (-1L) $category.Bytes}
        . ([scriptblock]::Create($script:UsageUiDefinitions))
        Assert-True ((Format-DomeniaStorageUsage $result) -match 'aucune estimation')
        $Payload.OptionalError='SQLite prepare code 11 : database disk image is malformed';$message=''
        try{[void](& ([scriptblock]::Create($base)))}catch{$message=$_.Exception.Message}
        Assert-True ($message -match 'malformed') $message
    } finally {Remove-Item $root -Recurse -Force}
}
Test-Case 'D029 : tables Live absentes restent inconnues et ne sont pas creees' {
    $root=New-LegacySandbox
    try {
        $hash=(Get-FileHash $script:TestDbPath).Hash;$result=Invoke-UsageWorker
        foreach($name in @('Observations','Snapshots')){Assert-Equal (-1L) @($result.Categories|Where-Object{$_.Category -eq $name})[0].Rows}
        Assert-Equal 0 @($result.Categories|Where-Object{$_.Category -eq 'ManualLinks'})[0].Rows
        Assert-Equal $hash (Get-FileHash $script:TestDbPath).Hash
        $db=Open-DomeniaDatabase -Path $script:TestDbPath -ReadOnly
        try {Assert-Equal 0 @(Invoke-DomeniaDbQuery "SELECT name FROM sqlite_master WHERE name LIKE 'adcc_live_%';" $db).Count}finally{Close-DomeniaDatabase $db}
    } finally {Remove-Item $root -Recurse -Force}
}
Test-Case 'D029 : chemin absent et chemin reseau refuses avant ouverture' {
    $root=New-LegacySandbox
    try {
        $absent=Join-Path $root 'absent.db'
        foreach($path in @($absent,'relative.db','\\invalid.example\share\database.db')){
            $message='';try{[void](Invoke-UsageWorker $path)}catch{$message=$_.Exception.Message}
            Assert-True ([bool]$message) ('Ouverture acceptee : '+$path)
        }
        Assert-False ([IO.File]::Exists($absent))
    } finally {Remove-Item $root -Recurse -Force}
}
Test-Case 'D029 : mesure refuse une base derriere une jonction' {
    $root=New-LegacySandbox;$junction=$root+'-link'
    try {
        [void](New-Item -ItemType Junction -Path $junction -Target $root)
        $message='';try{[void](Invoke-UsageWorker (Join-Path $junction 'Domenia.db'))}catch{$message=$_.Exception.Message}
        Assert-True ($message -match 'redirige') $message
    } finally {if([IO.Directory]::Exists($junction)){[IO.Directory]::Delete($junction)};Remove-Item $root -Recurse -Force}
}
Test-Case 'D029 : schema futur refuse intact sans migration' {
    $root=New-LegacySandbox
    try {
        $db=Open-DomeniaDatabase -Path $script:TestDbPath
        try{[void](Invoke-DomeniaDbExec "UPDATE schema_info SET value='12' WHERE key='schema_version';" $db)}finally{Close-DomeniaDatabase $db}
        $hash=(Get-FileHash $script:TestDbPath).Hash;$message=''
        try{[void](Invoke-UsageWorker)}catch{$message=$_.Exception.Message}
        Assert-True ($message -match 'Schema local non pris en charge') $message
        Assert-Equal $hash (Get-FileHash $script:TestDbPath).Hash
    } finally {Remove-Item $root -Recurse -Force}
}
Test-Case 'D029 : mesure native en runspace et progression du Dispatcher WPF' {
    $root=New-LegacySandbox;$ps=$null
    try {
        Add-UsageFixtureRows
        $db=Open-DomeniaDatabase -Path $script:TestDbPath
        try{[void](Invoke-DomeniaDbExec "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<10000) INSERT INTO user_machine_history(computer_key,source) SELECT 'PC'||x,'Synthetic' FROM n;" $db)}finally{Close-DomeniaDatabase $db}
        $ps=[PowerShell]::Create()
        [void]$ps.AddScript(('param($Payload)'+[Environment]::NewLine+(Get-DomeniaStorageUsageWorkerCode))).AddArgument([pscustomobject]@{Path=$script:TestDbPath})
        # TE-02: an independent DispatcherTimer counts its ticks only while the measure is still running, so the
        # assertion proves that the Dispatcher kept serving the UI during the work (a do/while counter always ran once).
        $probe=New-Object System.Windows.Threading.DispatcherTimer
        $probe.Interval=[TimeSpan]::FromMilliseconds(5)
        $probe.Tag=[pscustomobject]@{Async=$null;Ticks=0}
        $probe.Add_Tick({param($sender,$eventArgs) if(($null -ne $sender.Tag.Async) -and (-not $sender.Tag.Async.IsCompleted)){$sender.Tag.Ticks++}})
        $async=$ps.BeginInvoke();$probe.Tag.Async=$async;$probe.Start();$turns=0;$watch=[Diagnostics.Stopwatch]::StartNew()
        try {
            # Ceiling 60 s: a loaded VM may be slow; the duration is reported as a measure, not asserted tightly.
            while(-not $async.IsCompleted){Invoke-WiringPump 10;$turns++;if((-not $async.IsCompleted) -and ($watch.ElapsedMilliseconds -gt 60000)){throw ('Mesure runspace trop longue : '+$watch.ElapsedMilliseconds+' ms ; etat='+$ps.InvocationStateInfo.State+' ; erreurs='+$ps.Streams.Error.Count)}}
        } finally {$probe.Stop();$watch.Stop()}
        $out=@($ps.EndInvoke($async));Assert-Equal 0 $ps.Streams.Error.Count ($ps.Streams.Error|Out-String)
        $result=@($out|Where-Object{$_.Kind -eq 'StorageUsage'})[0]
        Assert-Equal 10003 @($result.Categories|Where-Object{$_.Category -eq 'History'})[0].Rows
        Assert-True ($probe.Tag.Ticks -gt 0) ('Dispatcher immobile pendant la mesure : aucun tick de minuterie pendant '+$watch.ElapsedMilliseconds+' ms.')
        $script:CaseDetail='Runspace natif ; ticks Dispatcher pendant la mesure='+$probe.Tag.Ticks+' ; tours='+$turns+' ; duree='+$watch.ElapsedMilliseconds+' ms (plafond 60000).'
    } finally {if($ps){$ps.Dispose()};Remove-Item $root -Recurse -Force}
}
Test-Case 'D029 : mesure UI transmet seulement le chemin et le contexte courant' {
    . ([scriptblock]::Create($script:UsageControlDefinitions));. ([scriptblock]::Create($script:UsageUiDefinitions));Initialize-UsageUiFixture
    function Start-UiTask {
        param($Name,$OperationId,$Code,$Payload,$CallbackState,$SuccessHandler,$ErrorHandler,$DisableControls,$TimeoutSeconds,$TaskClass)
        $script:UsageRequest=$PSBoundParameters;return 'usage-1'
    }
    Start-DomeniaStorageUsage
    Assert-Equal 'StorageUsage' $script:UsageRequest.OperationId
    Assert-Equal (Get-DomeniaStorageUsageWorkerCode) $script:UsageRequest.Code
    Assert-Equal 'Path' (@($script:UsageRequest.Payload.PSObject.Properties.Name) -join ',')
    Assert-Equal $script:DatabaseScopedPath $script:UsageRequest.Payload.Path
    Assert-Equal $script:SessionEpoch $script:UsageRequest.CallbackState.Epoch
    Assert-Equal 'BtnStorageUsage' ($script:UsageRequest.DisableControls -join ',')
    Assert-Equal 'Explicit' $script:UsageRequest.TaskClass
    Assert-True ($script:Ctrl.LblStorageUsage.Text -match 'en cours')
}
Test-Case 'D029 : mesure UI refuse demonstration, base absente et travail encore actif' {
    . ([scriptblock]::Create($script:UsageControlDefinitions));. ([scriptblock]::Create($script:UsageUiDefinitions))
    function Start-UiTask {throw 'Admission interdite dans ce scenario'}
    foreach($scenario in @('Demo','Absent','Active','Detached')){
        Initialize-UsageUiFixture;$script:DemoMode=$false
        switch($scenario){
            Demo {$script:DemoMode=$true}
            Absent {$script:DatabaseScopedPath=''}
            Active {$script:AsyncJobs=@{x=[pscustomobject]@{OperationId='StorageUsage'}}}
            Detached {$script:DetachedReadJobs=@([pscustomobject]@{OperationId='StoragePurge'})}
        }
        Start-DomeniaStorageUsage
        Assert-True ($script:Ctrl.LblStorageUsage.Text -match 'impossible')
        Assert-False ($script:Ctrl.LblStorageUsage.Text -match 'Admission interdite') 'Le refus doit preceder Start-UiTask'
    }
}
Test-Case 'D029 : resultat mesure affiche les inconnus et conserve les associations' {
    . ([scriptblock]::Create($script:UsageControlDefinitions));. ([scriptblock]::Create($script:UsageUiDefinitions));Initialize-UsageUiFixture
    $state=[pscustomobject]@{Path=$script:DatabaseScopedPath;Epoch=$script:SessionEpoch}
    Complete-DomeniaStorageUsage (New-UsagePacket) $state
    $text=$script:Ctrl.LblStorageUsage.Text
    Assert-True ($text -match 'Associations conservees : 1 ligne\(s\) ; inconnu') $text
    Assert-True ($text -match 'aucune estimation') $text
    Assert-Equal 'Stockage local mesure en lecture seule.' $script:Statuses[$script:Statuses.Count-1]
}
Test-Case 'D029 : resultat et erreur tardifs ne remplacent pas le nouveau contexte' {
    . ([scriptblock]::Create($script:UsageControlDefinitions));. ([scriptblock]::Create($script:UsageUiDefinitions));Initialize-UsageUiFixture
    foreach($state in @([pscustomobject]@{Path=$script:DatabaseScopedPath;Epoch=0L},[pscustomobject]@{Path='C:\ancienne.db';Epoch=$script:SessionEpoch})){
        Complete-DomeniaStorageUsage (New-UsagePacket) $state;Fail-DomeniaStorageUsage 'Erreur ancienne' $state
        Assert-Equal 'Avant mesure' $script:Ctrl.LblStorageUsage.Text
    }
}
Test-Case 'D029 : paquet incomplet ou contexte incorrect ne confirme aucune mesure' {
    . ([scriptblock]::Create($script:UsageControlDefinitions));. ([scriptblock]::Create($script:UsageUiDefinitions));Initialize-UsageUiFixture
    $state=[pscustomobject]@{Path=$script:DatabaseScopedPath;Epoch=$script:SessionEpoch}
    foreach($scenario in @('Date','Categories','Duplicate','Negative','Path','ReadOnly')){
        $packet=New-UsagePacket
        switch($scenario){
            Date {$packet.MeasuredUtc='invalid'}
            Categories {$packet.Categories=@($packet.Categories|Select-Object -First 5)}
            Duplicate {$packet.Categories[5].Category='History'}
            Negative {$packet.DatabaseBytes=-2L}
            Path {$packet.Path='C:\wrong.db'}
            ReadOnly {$packet.ReadOnly=$false}
        }
        Complete-DomeniaStorageUsage $packet $state
        Assert-True ($script:Ctrl.LblStorageUsage.Text -match 'impossible') $scenario
        Assert-False ($script:Statuses[$script:Statuses.Count-1] -eq 'Stockage local mesure en lecture seule.')
    }
}
Test-Case 'D029 : presentation de demonstration desactive le vrai bouton WPF' {
    . ([scriptblock]::Create($script:UsageControlDefinitions))
    Initialize-UsageUiFixture
    . ([scriptblock]::Create((Get-FunctionTextFromFile (Join-Path $modules 'Domenia-Demo.UI.ps1') 'Set-DomeniaDemoShellPresentation')))
    function Get-DomeniaDemoBannerText {return 'DEMONSTRATION'}
    Set-DomeniaDemoShellPresentation
    Assert-False $script:Ctrl.BtnStorageUsage.IsEnabled
    Assert-True ($script:Ctrl.BtnStorageUsage.ToolTip -match 'demonstration')
}

# D029 L3: disposable native SQLite fixtures, protected bytes, transaction rollback and real UI handlers.
. ([scriptblock]::Create((Get-FunctionTextFromFile $storageWorker 'Get-DomeniaStoragePurgeWorkerCode')))
$script:PurgeUiDefinitions=@(foreach($name in @('Get-DomeniaStoragePurgeChoice','Reset-DomeniaStoragePurgePreview','Assert-DomeniaStoragePurgeReady','Format-DomeniaStoragePurge','Start-DomeniaStoragePurge','Request-DomeniaStoragePurge','Complete-DomeniaStoragePurge','Fail-DomeniaStoragePurge')){Get-FunctionTextFromFile $storageUi $name}) -join "`n"
$script:PurgeAdmissionDefinition=Get-FunctionTextFromFile $core 'Start-UiTask'
$script:OrphanPruneDefinition=Get-FunctionTextFromFile $core 'Start-PruneOrphanLinks'
function Invoke-PurgeWorker {
    param([string[]]$Selection=@('Observations'),[bool]$DryRun=$true,[string]$Fingerprint='',[string]$Cutoff='2025-01-01T00:00:00.0000000Z',[string]$Path=$script:TestDbPath)
    $Payload=[pscustomobject]@{Path=$Path;Selection=$Selection;DryRun=$DryRun;HistoryCutoffUtc=$Cutoff;ExpectedFingerprint=$Fingerprint}
    return & ([scriptblock]::Create((Get-DomeniaStoragePurgeWorkerCode)))
}
function Get-PurgeTableDigest {
    param([string]$Table)
    $db=Open-DomeniaDatabase -Path $script:TestDbPath -ReadOnly
    try{$rows=@(Invoke-DomeniaDbQuery ('SELECT * FROM '+$Table+' ORDER BY rowid;') $db)}finally{Close-DomeniaDatabase $db}
    $hash=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes(($rows|ConvertTo-Json -Depth 6 -Compress))))}finally{$hash.Dispose()}
}
function Add-PurgeFixtureRows {
    Add-UsageFixtureRows
    $db=Open-DomeniaDatabase -Path $script:TestDbPath
    try {
        [void](Invoke-DomeniaDbExec @'
BEGIN IMMEDIATE;
INSERT INTO user_machine_links(computer_key,user_login,source) VALUES('MANUAL-PC','bob','Manual'),('SAISIE-PC','sue','Saisie manuelle'),('IMPORT-PC','ivy','Import CSV'),('AUTO-PC','amy','Journal du controleur');
INSERT INTO user_machine_history(computer_key,source,observed_at) VALUES('AUTO-PC','Journal du controleur','2020-01-01'),('pc1','Journal du controleur','2020-01-01'),('x',' manual ','2020-01-01'),('y','Saisie manuelle','2020-01-01'),('z','Import CSV','2020-01-01'),('recent','Journal du controleur','2026-01-01'),('invalid','Journal du controleur','non-date');
UPDATE user_scan_history SET scanned_at='2020-01-01';
UPDATE operation_runs SET finished_at='2020-01-01';
INSERT OR REPLACE INTO sync_state(scope,server,base_dn,highest_usn,last_sync,item_count,details) VALUES('directory','dc.example.invalid','DC=example,DC=invalid',123,'2026-01-01',1,'old state');
COMMIT;
'@ $db)
    } finally {Close-DomeniaDatabase $db}
}
Test-Case 'D029 : simulation puis purge atomique, associations et fichiers proteges intacts' {
    $root=New-LegacySandbox
    try {
        Add-PurgeFixtureRows
        $protected=@{};foreach($table in @('user_machine_links','secret_state','schema_info')){$protected[$table]=Get-PurgeTableDigest $table}
        $files=@('Domenia.config.ini','Domenia.config.ini.bak','Preferences\Domenia.settings.json','Preferences\Domenia.settings.json.bak','Logs\Domenia.log','Logs\relations.journal','Receipts\Prepared.json','Receipts\Sent.json','Receipts\Unknown.json','Receipts\Verified.json')
        $hashes=@{}
        foreach($relative in $files){$file=Join-Path $root $relative;[void][IO.Directory]::CreateDirectory((Split-Path $file));[IO.File]::WriteAllText($file,'Synthetic protected bytes '+$relative);$hashes[$relative]=(Get-FileHash $file).Hash}
        $before=(Get-FileHash $script:TestDbPath).Hash
        $preview=Invoke-PurgeWorker @('Observations','Snapshots','History','Index')
        Assert-True $preview.DryRun;Assert-False $preview.Committed
        Assert-Equal $before (Get-FileHash $script:TestDbPath).Hash
        Assert-Equal 9 (($preview.Counts|Where-Object Action -eq 'Delete'|Measure-Object Rows -Sum).Sum)
        $result=Invoke-PurgeWorker @('Observations','Snapshots','History','Index') $false $preview.Fingerprint
        Assert-True $result.Committed;Assert-False $result.DryRun;Assert-Equal 9 $result.DeletedRows;Assert-Equal 1 $result.ResetRows
        Assert-Equal ($preview.Counts|ConvertTo-Json -Compress) ($result.Counts|ConvertTo-Json -Compress)
        foreach($table in $protected.Keys){Assert-Equal $protected[$table] (Get-PurgeTableDigest $table) $table}
        foreach($relative in $files){Assert-Equal $hashes[$relative] (Get-FileHash (Join-Path $root $relative)).Hash $relative}
        foreach($table in @('ad_objects','domenia_provenance','adcc_live_queries','adcc_live_observations','presence_cache','park_state','user_scan_history','operation_runs')){Assert-Equal 0 (Get-LegacyCount $table) $table}
        Assert-Equal 7 (Get-LegacyCount 'user_machine_history')
        Assert-Equal 'legacy_import' (Get-LegacySyncState 'legacy_import').server
        $directory=Get-LegacySyncState 'directory';Assert-Equal 'DC=example,DC=invalid' $directory.base_dn;Assert-Equal 'dc.example.invalid' $directory.server
        Assert-Equal 0 $directory.highest_usn;Assert-Equal 0 $directory.item_count;Assert-True ($null -eq $directory.last_sync)
        # The actual adoption code must still choose this same database after the index is empty.
        . ([scriptblock]::Create((Get-FunctionTextFromFile $core 'Get-DomeniaDatabasePath')))
        $script:DataDir=$root;$script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid'};$script:DatabaseScopeIdentity='';$script:DatabaseScopedPath=''
        Assert-Equal $script:TestDbPath (Get-DomeniaDatabasePath)
    } finally {Remove-Item $root -Recurse -Force}
}
Test-Case 'D029 : categories protegees ou inconnues refusees avant toute suppression' {
    $root=New-LegacySandbox
    try {
        Add-PurgeFixtureRows;$hash=(Get-FileHash $script:TestDbPath).Hash
        foreach($category in @('Configuration','Preferences','ManualLinks','Secrets','Logs','Receipts','user_machine_links','Unknowable',"Index;DELETE FROM user_machine_links")){
            $message='';try{[void](Invoke-PurgeWorker @('Observations',$category) $false ('A'*64))}catch{$message=$_.Exception.Message}
            Assert-True ($message -match 'Categorie non purgeable') $category
            Assert-Equal $hash (Get-FileHash $script:TestDbPath).Hash
        }
    } finally {Remove-Item $root -Recurse -Force}
}
Test-Case 'D029 : modification du comptage apres simulation refuse la purge sans effacer' {
    $root=New-LegacySandbox
    try {
        Add-PurgeFixtureRows;$preview=Invoke-PurgeWorker
        $db=Open-DomeniaDatabase -Path $script:TestDbPath
        try{[void](Invoke-DomeniaDbExec "INSERT INTO presence_cache(object_key,state) VALUES('new','Inconnu');" $db)}finally{Close-DomeniaDatabase $db}
        $hash=(Get-FileHash $script:TestDbPath).Hash;$message=''
        try{[void](Invoke-PurgeWorker -DryRun $false -Fingerprint $preview.Fingerprint)}catch{$message=$_.Exception.Message}
        Assert-True ($message -match 'Refaites la simulation') $message
        Assert-Equal 2 (Get-LegacyCount 'presence_cache');Assert-Equal $hash (Get-FileHash $script:TestDbPath).Hash
    } finally {Remove-Item $root -Recurse -Force}
}
Test-Case 'D029 : erreur apres une premiere suppression annule toute la transaction' {
    $root=New-LegacySandbox
    try {
        Add-PurgeFixtureRows;$preview=Invoke-PurgeWorker
        $before=@{};foreach($table in @('adcc_live_observations','presence_cache','park_state','user_machine_links')){$before[$table]=Get-PurgeTableDigest $table}
        $code=(Get-DomeniaStoragePurgeWorkerCode).Replace('function Invoke-DomeniaDbExec {','function Invoke-NativePurgeDbExec {')
        $wrapper=@'
function Invoke-DomeniaDbExec {
    param([string]$Sql,[IntPtr]$DatabaseHandle)
    if($Sql -like 'DELETE FROM presence_cache*'){throw 'Synthetic second delete failure'}
    return Invoke-NativePurgeDbExec $Sql $DatabaseHandle
}
'@
        $code=$code.Replace('# Validate all input',($wrapper+"`n"+'# Validate all input'))
        $Payload=[pscustomobject]@{Path=$script:TestDbPath;Selection=@('Observations');DryRun=$false;ExpectedFingerprint=$preview.Fingerprint}
        $message='';try{[void](& ([scriptblock]::Create($code)))}catch{$message=$_.Exception.Message}
        Assert-True ($message -match 'Synthetic second delete failure') $message
        foreach($table in $before.Keys){Assert-Equal $before[$table] (Get-PurgeTableDigest $table) $table}
    } finally {Remove-Item $root -Recurse -Force}
}
Test-Case 'D029 : schema futur et declencheur SQLite refusent la purge intacts' {
    $root=New-LegacySandbox
    try {
        Add-PurgeFixtureRows
        foreach($scenario in @('Schema','Trigger')){
            $db=Open-DomeniaDatabase -Path $script:TestDbPath
            try{
                if($scenario -eq 'Schema'){[void](Invoke-DomeniaDbExec "UPDATE schema_info SET value='12' WHERE key='schema_version';" $db)}
                else{[void](Invoke-DomeniaDbExec "UPDATE schema_info SET value='11' WHERE key='schema_version'; CREATE TRIGGER unreviewed AFTER DELETE ON presence_cache BEGIN DELETE FROM user_machine_links; END;" $db)}
            }finally{Close-DomeniaDatabase $db}
            $hash=(Get-FileHash $script:TestDbPath).Hash;$message=''
            try{[void](Invoke-PurgeWorker)}catch{$message=$_.Exception.Message}
            Assert-True ([bool]$message) $scenario
            Assert-Equal $hash (Get-FileHash $script:TestDbPath).Hash;Assert-Equal 5 (Get-LegacyCount 'user_machine_links')
        }
    } finally {Remove-Item $root -Recurse -Force}
}
Test-Case 'D029 : confirmation, date et chemin controles sans creation implicite' {
    $root=New-LegacySandbox
    try {
        Add-PurgeFixtureRows
        $absent=Join-Path $root 'absent.db';$message=''
        try{[void](Invoke-PurgeWorker -Path $absent)}catch{$message=$_.Exception.Message};Assert-True ([bool]$message);Assert-False ([IO.File]::Exists($absent))
        foreach($cutoff in @('invalid','2999-01-01T00:00:00.0000000Z','2025-01-01T00:00:00.0000000')){
            $message='';try{[void](Invoke-PurgeWorker -Selection History -Cutoff $cutoff)}catch{$message=$_.Exception.Message};Assert-True ($message -match 'Date limite') $cutoff
        }
        $message='';try{[void](Invoke-PurgeWorker -DryRun $false)}catch{$message=$_.Exception.Message};Assert-True ($message -match 'Simulation confirmee')
    } finally {Remove-Item $root -Recurse -Force}
}
function Initialize-PurgeUiFixture {
    Initialize-UsageUiFixture
    foreach($name in @('Observations','Snapshots','History','Index')){$script:Ctrl['ChkStoragePurge'+$name]=New-Object Windows.Controls.CheckBox}
    $script:Ctrl.ChkStoragePurgeObservations.IsChecked=$true
    $script:Ctrl.TxtStorageHistoryDays=New-Object Windows.Controls.TextBox;$script:Ctrl.TxtStorageHistoryDays.Text='730'
    $script:Ctrl.BtnStoragePurgePreview=New-Object Windows.Controls.Button
    $script:Ctrl.BtnStoragePurge=New-Object Windows.Controls.Button;$script:Ctrl.BtnStoragePurge.IsEnabled=$false
    $script:Ctrl.LblStoragePurge=New-Object Windows.Controls.TextBlock
    $script:StoragePurgePreview=$null;$script:PurgeDispatches=[Collections.Generic.List[object]]::new();$script:Persistence=$null;$script:Live=$null
    $script:VisitCache=@{old='cached'};$script:InlineConfirm=$null;$script:InlineCancel=$null;$script:InlineCalls=0
    $script:PurgeIndexReloads=0;$script:PurgeSearchStops=0
}
function New-PurgePacket {
    param($State)
    $counts=@(foreach($category in $State.Selection){foreach($t in @(Get-DomeniaPurgeTargets $category)){[pscustomobject]@{Category=$category;Table=$t.Table;Action=$t.Action;Rows=2L;Exists=$true}}})
    return [pscustomobject]@{Kind='StoragePurge';Path=$State.Path;DryRun=[bool]$State.DryRun;Committed=(-not $State.DryRun);Selection=$State.Selection;HistoryCutoffUtc=$State.HistoryCutoffUtc;Fingerprint=('A'*64);Counts=$counts;DeletedRows=$(if($State.DryRun){0L}else{[long](($counts|Where-Object Action -eq 'Delete'|Measure-Object Rows -Sum).Sum)});ResetRows=$(if($State.DryRun){0L}else{[long](($counts|Where-Object Action -eq 'Reset'|Measure-Object Rows -Sum).Sum)})}
}
$script:PurgeFixtureDefinitions=@'
. ([scriptblock]::Create($script:UsageControlDefinitions))
. ([scriptblock]::Create($script:PurgeUiDefinitions))
Initialize-PurgeUiFixture
function Start-UiTask {
    param($Name,$OperationId,$Code,$Payload,$CallbackState,$SuccessHandler,$ErrorHandler,$DisableControls,[switch]$NonCancellable,$TimeoutSeconds,$TaskClass)
    $script:PurgeDispatches.Add([pscustomobject]@{OperationId=$OperationId;Code=$Code;Payload=$Payload;State=$CallbackState;NonCancellable=[bool]$NonCancellable})
    return 'purge-'+$script:PurgeDispatches.Count
}
function Request-DomeniaInlineConfirmation {param($Title,$Target,$Message,$ConfirmText,$CancelText,$OnConfirm,$OnCancel) $script:InlineCalls++;$script:InlineConfirm=$OnConfirm;$script:InlineCancel=$OnCancel}
function Request-DomeniaIndexMetadata {param([switch]$StartupChecks,[int]$Attempt=0) throw 'La purge confirme un index vide sans relire la base'}
function Load-DomeniaIndex {throw 'Aucune lecture SQLite sur le Dispatcher'}
function Rebuild-DomeniaIndexLookup {$script:PurgeIndexReloads++}
function Stop-DomeniaLiveSearch {$script:PurgeSearchStops++}
function Clear-VisitCache {throw 'Aucun rafraichissement indirect du dashboard pendant la purge'}
'@
Test-Case 'D029 : simulation requise et annulation ne lance aucune purge' {
    . ([scriptblock]::Create($script:PurgeFixtureDefinitions))
    Request-DomeniaStoragePurge;Assert-Equal 0 $script:PurgeDispatches.Count;Assert-Equal 0 $script:InlineCalls
    Start-DomeniaStoragePurge
    Assert-Equal 1 $script:PurgeDispatches.Count;Assert-True $script:PurgeDispatches[0].Payload.DryRun
    $state=$script:PurgeDispatches[0].State
    Complete-DomeniaStoragePurge (New-PurgePacket $state) $state
    Assert-True $script:Ctrl.BtnStoragePurge.IsEnabled
    Request-DomeniaStoragePurge;Assert-Equal 1 $script:InlineCalls
    & $script:InlineCancel
    Assert-Equal 1 $script:PurgeDispatches.Count
    Assert-True ($script:Statuses[$script:Statuses.Count-1] -match 'aucune suppression')
}
Test-Case 'D029 : confirmation reutilise exactement categories, date et empreinte simulees' {
    . ([scriptblock]::Create($script:PurgeFixtureDefinitions))
    $script:Ctrl.ChkStoragePurgeHistory.IsChecked=$true;$script:Ctrl.TxtStorageHistoryDays.Text='30'
    Start-DomeniaStoragePurge;$state=$script:PurgeDispatches[0].State
    Complete-DomeniaStoragePurge (New-PurgePacket $state) $state
    Request-DomeniaStoragePurge;& $script:InlineConfirm
    Assert-Equal 2 $script:PurgeDispatches.Count
    $apply=$script:PurgeDispatches[1]
    Assert-Equal 'StoragePurge' $apply.OperationId;Assert-True $apply.NonCancellable;Assert-False $apply.Payload.DryRun
    Assert-Equal $state.HistoryCutoffUtc $apply.Payload.HistoryCutoffUtc
    Assert-Equal ('A'*64) $apply.Payload.ExpectedFingerprint
    Assert-Equal ($state.Selection -join ',') ($apply.Payload.Selection -join ',')
    Assert-True ($null -eq $script:StoragePurgePreview);Assert-False $script:Ctrl.BtnStoragePurge.IsEnabled
}
Test-Case 'D029 : selection ou session changee invalide une ancienne confirmation' {
    . ([scriptblock]::Create($script:PurgeFixtureDefinitions))
    foreach($scenario in @('Selection','Age','Epoch','Path','Reset')){
        Initialize-PurgeUiFixture
        $script:Ctrl.ChkStoragePurgeHistory.IsChecked=$true
        Start-DomeniaStoragePurge;$state=$script:PurgeDispatches[0].State
        Complete-DomeniaStoragePurge (New-PurgePacket $state) $state
        Request-DomeniaStoragePurge
        switch($scenario){Selection{$script:Ctrl.ChkStoragePurgeIndex.IsChecked=$true}Age{$script:Ctrl.TxtStorageHistoryDays.Text='7'}Epoch{$script:SessionEpoch++}Path{$script:DatabaseScopedPath='C:\other.db'}Reset{Reset-DomeniaStoragePurgePreview}}
        & $script:InlineConfirm
        Assert-Equal 1 $script:PurgeDispatches.Count $scenario
        Assert-False $script:Ctrl.BtnStoragePurge.IsEnabled
    }
}
Test-Case 'D029 : purge refuse travaux actifs, detaches, attente de sauvegarde et demo' {
    . ([scriptblock]::Create($script:PurgeFixtureDefinitions))
    foreach($scenario in @('Active','Detached','Pending','PersistenceJob','Demo','Unknown','LiveSave')){
        Initialize-PurgeUiFixture;$script:DemoMode=$false;$script:WriteState='Known'
        switch($scenario){
            Active{$script:AsyncJobs=@{x=[pscustomobject]@{OperationId='GlobalSearch'}}}
            Detached{$script:DetachedReadJobs=@([pscustomobject]@{OperationId='StoragePurge'})}
            Pending{$script:Persistence=[pscustomobject]@{Job='';LinkBusy=$false;Pending=@{x=[pscustomobject]@{Kind='LegacyImport'}};LinkRequestTimer=$null}}
            PersistenceJob{$script:Persistence=[pscustomobject]@{Job='writer';LinkBusy=$false;Pending=@{};LinkRequestTimer=$null}}
            Demo{$script:DemoMode=$true}
            Unknown{$script:WriteState='Unknown'}
            LiveSave{$script:Live=[pscustomobject]@{SaveJob='live';SaveInFlight=1}}
        }
        Start-DomeniaStoragePurge;Assert-Equal 0 $script:PurgeDispatches.Count $scenario
        Assert-True ($script:Ctrl.LblStoragePurge.Text -match 'impossible') $scenario
    }
}
Test-Case 'D029 : resultat tardif et echec ne suppriment rien et ne rejouent pas' {
    . ([scriptblock]::Create($script:PurgeFixtureDefinitions))
    Start-DomeniaStoragePurge;$state=$script:PurgeDispatches[0].State;$old=$script:Ctrl.LblStoragePurge.Text
    $script:SessionEpoch++
    Complete-DomeniaStoragePurge (New-PurgePacket $state) $state;Fail-DomeniaStoragePurge 'old' $state
    Assert-Equal $old $script:Ctrl.LblStoragePurge.Text;Assert-True ($null -eq $script:StoragePurgePreview)
    $script:SessionEpoch=$state.Epoch
    Fail-DomeniaStoragePurge 'refus SQLite synthetique' $state
    Assert-Equal 1 $script:PurgeDispatches.Count;Assert-True ($script:Ctrl.LblStoragePurge.Text -match 'Aucun rejeu automatique')
    Assert-False $script:Ctrl.BtnStoragePurge.IsEnabled
}
Test-Case 'D029 : succes invalide seulement les caches choisis et aucune relecture AD' {
    . ([scriptblock]::Create($script:PurgeFixtureDefinitions))
    $script:Ctrl.ChkStoragePurgeSnapshots.IsChecked=$true;$script:Ctrl.ChkStoragePurgeIndex.IsChecked=$true
    Start-DomeniaStoragePurge;$state=$script:PurgeDispatches[0].State
    Complete-DomeniaStoragePurge (New-PurgePacket $state) $state;Request-DomeniaStoragePurge;& $script:InlineConfirm
    $state=$script:PurgeDispatches[1].State
    $script:Live=[pscustomobject]@{Observations=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new();ObservationsLoaded=$true;SaveQueue=@{old='observation'};Done=@{x=$true};PresenceSeen=@{x=$true};MemoryQueries=@{q='result'};QueryToSave='old query';Refresh=[Collections.Generic.Queue[object]]::new();Deferred=[Collections.Generic.Queue[object]]::new()}
    $script:PresenceCache=@{x='cached'};$script:ParkState=@{x='old'}
    Complete-DomeniaStoragePurge (New-PurgePacket $state) $state
    Assert-Equal 0 $script:Live.SaveQueue.Count;Assert-Equal 0 $script:Live.MemoryQueries.Count;Assert-True ($null -eq $script:Live.QueryToSave)
    Assert-Equal 0 $script:PresenceCache.Count;Assert-Equal 0 $script:ParkState.Count;Assert-Equal 0 $script:VisitCache.Count
    Assert-Equal 1 $script:PurgeIndexReloads;Assert-Equal 1 $script:PurgeSearchStops
    Assert-Equal 0 $script:IndexRows.Count;Assert-Equal 0 $script:IndexDbCount;Assert-True ($null -eq $script:IndexInfo)
    Assert-True ($script:Ctrl.LblStorageUsage.Text -match 'perimee')
    Assert-True ($script:Statuses[$script:Statuses.Count-1] -match 'Purge locale confirmee')
    Assert-Equal 2 $script:PurgeDispatches.Count
}
Test-Case 'D029 : admission centrale bloque les nouveaux producteurs pendant purge detachee' {
    . ([scriptblock]::Create($script:PurgeUiDefinitions))
    . ([scriptblock]::Create($script:PurgeAdmissionDefinition))
    $script:DetachedReadJobs=@([pscustomobject]@{OperationId='StoragePurge'})
    foreach($operation in @('LocalStore','LiveCache','IndexBuild','ScopeReconcile','GlobalSearch','LegacyMigration','StorageUsage')){
        $message='';try{[void](Start-UiTask -Name 'Test' -OperationId $operation -Code 'unreachable')}catch{$message=$_.Exception.Message}
        Assert-True ($message -match 'purge locale est encore active') ($operation+': '+$message)
    }
}
Test-Case 'D029 / UX-40 : le controle des orphelins ne propose que les sources automatiques et ne retire rien sans confirmation' {
    # UX-40 (L04): the result is listed in Relations (Show-DomeniaOrphanLinks); the confirmed, journaled and restorable
    # removal and the late promotion are proven in Test-DomeniaWiringRelations.ps1.
    . ([scriptblock]::Create($script:OrphanPruneDefinition))
    function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$ReplaceKey,$DisableControls,$TimeoutSeconds,$StatusText,$OnSuccess,$OnError) $script:OrphanPayload=$Payload;$script:OrphanComplete=$OnSuccess}
    function Confirm-Action {param($Message) $script:OrphanConfirms++;return $true}
    function Save-UserMachineLinks {$script:OrphanSaves++;return $true}
    function Show-ErrorBox {param($Message) throw $Message}
    function Show-DomeniaOrphanLinks {param($Result) $script:OrphanShown=$Result}
    $script:OrphanSaves=0;$script:OrphanConfirms=0;$script:OrphanShown=$null
    $script:UserMachineLinks=@(foreach($source in @('Manual',' Saisie manuelle ','import csv','Journal du controleur')){[pscustomobject]@{UserLogin='user';Computer=$source;Source=$source;When='old'}})
    Start-PruneOrphanLinks
    Assert-Equal 1 @($script:OrphanPayload.Links).Count
    $auto=$script:OrphanPayload.Links[0]
    Assert-Equal 'Journal du controleur' ([string]$auto.Source)
    $result=[pscustomobject]@{Checked=1;Rows=@([pscustomobject]@{UserLogin=$auto.UserLogin;Computer=$auto.Computer;When=$auto.When;UserExists=$false;ComputerExists=$false})}
    & $script:OrphanComplete $result
    Assert-True ([object]::ReferenceEquals($script:OrphanShown,$result)) 'Resultat non transmis a la liste de la page'
    Assert-Equal 4 $script:UserMachineLinks.Count;Assert-Equal 0 $script:OrphanSaves;Assert-Equal 0 $script:OrphanConfirms
}
Test-Case 'D029 : vrais evenements WPF de simulation et confirmation raccordes au coeur' {
    . ([scriptblock]::Create($script:PurgeFixtureDefinitions))
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput((Get-FunctionTextFromFile $core 'Wire-Events'),[ref]$tokens,[ref]$errors)
    foreach($name in @('BtnStoragePurgePreview','BtnStoragePurge')){
        $expression='$script:Ctrl["'+$name+'"]'
        $nodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'Add_Click' -and $n.Expression.Extent.Text -ceq $expression},$true))
        Assert-Equal 1 $nodes.Count ('Evenement manquant : '+$name)
        . ([scriptblock]::Create($nodes[0].Extent.Text))
    }
    $script:Ctrl.BtnStoragePurgePreview.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    Assert-Equal 1 $script:PurgeDispatches.Count;Assert-True $script:PurgeDispatches[0].Payload.DryRun
    $state=$script:PurgeDispatches[0].State
    Complete-DomeniaStoragePurge (New-PurgePacket $state) $state
    $script:Ctrl.BtnStoragePurge.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    Assert-Equal 1 $script:InlineCalls;Assert-Equal 1 $script:PurgeDispatches.Count
}
Test-Case 'D029 : un paquet de purge mal forme ne devient jamais une confirmation' {
    . ([scriptblock]::Create($script:PurgeFixtureDefinitions))
    foreach($scenario in @('Counts','Rows','Date','Mode','Fingerprint')){
        Initialize-PurgeUiFixture;Start-DomeniaStoragePurge;$state=$script:PurgeDispatches[0].State;$packet=New-PurgePacket $state
        switch($scenario){Counts{$packet.Counts=@($packet.Counts|Select-Object -First 1)}Rows{$packet.Counts[0].Rows=-1}Date{$packet.HistoryCutoffUtc='unexpected'}Mode{$packet.Committed=$true}Fingerprint{$packet.Fingerprint='bad'}}
        Complete-DomeniaStoragePurge $packet $state
        Assert-True ($null -eq $script:StoragePurgePreview) $scenario;Assert-False $script:Ctrl.BtnStoragePurge.IsEnabled $scenario
        Assert-True ($script:Ctrl.LblStoragePurge.Text -match 'non confirmee') $scenario
    }
}

Stop-TestTimers
# Persistent park cache uses the existing single writer and survives a new read context.
. (Join-Path $modules 'Domenia-Park.Model.ps1')
. ([scriptblock]::Create((Get-FunctionTextFromFile (Join-Path $modules 'Domenia-Engine.Worker.ps1') 'Get-DomeniaLocalIndexReadWorkerCode')))
function Invoke-ParkTargetsFixture {
    param([string]$Scope='Park',[object[]]$Targets=@())
    $Payload=[pscustomobject]@{Action='ParkTargets';Path=$script:TestDbPath;BusyTimeoutMs=250;Scope=$Scope;Targets=$Targets}
    return & ([scriptblock]::Create((Get-DomeniaLocalIndexReadWorkerCode)))
}
Test-Case 'Parc : cache durable relu au redemarrage sans expiration ni limite 150' {
    $root=New-LegacySandbox
    try{
        $db=Open-DomeniaDatabase -Path $script:TestDbPath
        try{
            [void](Invoke-DomeniaDbExec "WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM c WHERE n<151) INSERT INTO ad_objects(object_key,object_guid,object_type,name,state,distinguished_name) SELECT 'machine'||n,'guid'||n,'Machine','PC-'||n,'Actif','cn=pc-'||n||',dc=example,dc=invalid' FROM c; INSERT INTO ad_objects(object_key,object_guid,object_type,name,state,distinguished_name,usn_changed) VALUES('user','user-guid','Utilisateur','alice','Actif','CN=Alice,DC=example,DC=invalid',5);" $db)
        }finally{Close-DomeniaDatabase $db}
        $row=[pscustomobject]@{Version=1;Key='cn=pc-1,dc=example,dc=invalid';Guid='guid1';Computer='PC-1';CheckedUtc='2000-01-01T00:00:00Z';Outcome='Observed';RawAccount='EXAMPLE\alice';LinkUser='alice';UserDn='CN=Alice,DC=example,DC=invalid';UserGuid='user-guid';UserUsn='5';ObservedUtc='2000-01-01T00:00:00Z'}
        $Payload=[pscustomobject]@{Path=$script:TestDbPath;Items=@([pscustomobject]@{Kind='ParkSession';Row=$row})}
        $write=Invoke-LegacyWorker $Payload;Assert-True $write.Saved
        $read=Invoke-ParkTargetsFixture
        Assert-Equal 151 $read.Rows.Count
        $target=@($read.Rows|Where-Object Computer -eq 'PC-1')[0]
        Assert-True ($null -eq $target.Previous -and [bool]$target.PreviousJson) 'Le worker doit garder le cache en JSON, sans decoder tout le parc.'
        Assert-Equal 0 @($read.Rows|Where-Object{$null -ne $_.Previous}).Count 'Le parc a materialise tous les anciens releves.'
        Expand-DomeniaParkPrevious $target
        Assert-Equal 'EXAMPLE\alice' $target.Previous.RawAccount;Assert-False $target.Previous.DirectoryChanged
        Assert-Equal '' $target.PreviousJson 'Le buffer JSON doit etre libere apres materialisation.'
        Assert-Equal 1 (Get-LegacyCount 'park_session_cache');Assert-Equal 1 (Get-LegacyCount 'park_state');Assert-Equal 0 (Get-LegacyCount 'user_machine_links')
        $read=Invoke-ParkTargetsFixture -Scope Results -Targets @([pscustomobject]@{name='PC-1';distinguished_name=$row.Key;object_guid='guid1'})
        Assert-Equal 1 $read.Rows.Count;Expand-DomeniaParkPrevious $read.Rows[0];Assert-Equal 'alice' $read.Rows[0].Previous.LinkUser
        $db=Open-DomeniaDatabase -Path $script:TestDbPath
        try{[void](Invoke-DomeniaDbExec "UPDATE ad_objects SET usn_changed=6 WHERE object_key='user';" $db)}finally{Close-DomeniaDatabase $db}
        $read=Invoke-ParkTargetsFixture;Assert-True @($read.Rows|Where-Object Computer -eq 'PC-1')[0].DirectoryChanged
        $db=Open-DomeniaDatabase -Path $script:TestDbPath
        try{[void](Invoke-DomeniaDbExec "UPDATE ad_objects SET object_guid='recreated' WHERE object_key='machine1';" $db)}finally{Close-DomeniaDatabase $db}
        $read=Invoke-ParkTargetsFixture;$recreated=@($read.Rows|Where-Object Computer -eq 'PC-1')[0];Assert-True ($null -eq $recreated.Previous -and -not [string]$recreated.PreviousJson) 'Un nouveau GUID reprendrait le cache de lʼancien poste.'
    }finally{Remove-Item $root -Recurse -Force}
}
Test-Case 'Parc : utilisateur recree connu sous le meme DN ou login invalide le cache' {
    $root=New-LegacySandbox
    try{
        $db=Open-DomeniaDatabase -Path $script:TestDbPath
        try{[void](Invoke-DomeniaDbExec "INSERT INTO ad_objects(object_key,object_guid,object_type,name,state,distinguished_name) VALUES('machine','machine-guid','Machine','PC-1','Actif','cn=pc-1,dc=example,dc=invalid'); INSERT INTO ad_objects(object_key,object_guid,object_type,name,login,state,distinguished_name,usn_changed) VALUES('user','old-user-guid','Utilisateur','Alice','alice','Actif','CN=Alice,DC=example,DC=invalid',5);" $db)}finally{Close-DomeniaDatabase $db}
        $row=[pscustomobject]@{Version=1;Key='cn=pc-1,dc=example,dc=invalid';Guid='machine-guid';Computer='PC-1';CheckedUtc='2000-01-01T00:00:00Z';Outcome='Observed';RawAccount='EXAMPLE\alice';LinkUser='alice';UserDn='CN=Alice,DC=example,DC=invalid';UserGuid='old-user-guid';UserUsn='5';ObservedUtc='2000-01-01T00:00:00Z'}
        [void](Invoke-LegacyWorker ([pscustomobject]@{Path=$script:TestDbPath;Items=@([pscustomobject]@{Kind='ParkSession';Row=$row})}))
        $targets=@([pscustomobject]@{name='PC-1';distinguished_name=$row.Key;object_guid=$row.Guid})
        foreach($scope in @('Results','Park')){Assert-False (Invoke-ParkTargetsFixture -Scope $scope -Targets $targets).Rows[0].DirectoryChanged}
        $db=Open-DomeniaDatabase -Path $script:TestDbPath
        try{[void](Invoke-DomeniaDbExec "UPDATE ad_objects SET object_guid='new-user-guid' WHERE object_key='user';" $db)}finally{Close-DomeniaDatabase $db}
        foreach($scope in @('Results','Park')){Assert-True (Invoke-ParkTargetsFixture -Scope $scope -Targets $targets).Rows[0].DirectoryChanged 'Le meme DN avec un nouveau GUID doit etre revalide'}
        $db=Open-DomeniaDatabase -Path $script:TestDbPath
        try{[void](Invoke-DomeniaDbExec "UPDATE ad_objects SET distinguished_name='CN=Another,DC=example,DC=invalid' WHERE object_key='user';" $db)}finally{Close-DomeniaDatabase $db}
        foreach($scope in @('Results','Park')){Assert-True (Invoke-ParkTargetsFixture -Scope $scope -Targets $targets).Rows[0].DirectoryChanged 'Le meme login avec un nouveau GUID doit etre revalide'}
        $db=Open-DomeniaDatabase -Path $script:TestDbPath
        try{[void](Invoke-DomeniaDbExec "UPDATE ad_objects SET login='unrelated' WHERE object_key='user';" $db)}finally{Close-DomeniaDatabase $db}
        foreach($scope in @('Results','Park')){Assert-True (Invoke-ParkTargetsFixture -Scope $scope -Targets $targets).Rows[0].DirectoryChanged 'Une identite absente de lʼindex exige une revalidation ; son ancien cache ne vaut pas confirmation.'}
    }finally{Remove-Item $root -Recurse -Force}
}

Test-Case 'Parc : resultat vide reste vide et aucune expansion implicite' {
    $root=New-LegacySandbox
    try{$read=Invoke-ParkTargetsFixture -Scope Results;Assert-Equal 0 $read.Rows.Count}finally{Remove-Item $root -Recurse -Force}
}
Test-Case 'CO-08 : LocalIndexRead ResolveNames lit en lecture seule les comptes et postes d un import' {
    # L04 review: the import preview checks the accounts and workstations of the file in the SQLite index through the
    # pinned worker (never $script:IndexRows, which the application does not fill). Exact names only, no network.
    $root=New-LegacySandbox
    try{
        $Payload=[pscustomobject]@{Action='ResolveNames';Path=$script:TestDbPath;BusyTimeoutMs=250;Users=@('carol','zed');Computers=@('PC-NEW','PC-ZED')}
        $empty=& ([scriptblock]::Create((Get-DomeniaLocalIndexReadWorkerCode)))
        Assert-Equal 0 ([int]$empty.IndexCount) 'Index vide';Assert-Equal 0 @($empty.Users).Count;Assert-False ([bool]$empty.Busy)
        $db=Open-DomeniaDatabase -Path $script:TestDbPath
        try{[void](Invoke-DomeniaDbExec "INSERT INTO ad_objects(object_key,object_guid,object_type,name,login,state,distinguished_name) VALUES('u1','user-guid','Utilisateur','Carol','CAROL','Actif','CN=Carol,DC=example,DC=invalid'); INSERT INTO ad_objects(object_key,object_guid,object_type,name,login,state,distinguished_name) VALUES('m1','machine-guid','Machine','pc-new','PC-NEW$','Actif','CN=PC-NEW,DC=example,DC=invalid'); INSERT INTO ad_objects(object_key,object_guid,object_type,name,login,state,distinguished_name) VALUES('u2','other-guid','Utilisateur','PC-ZED','pc-zed','Actif','CN=PC-ZED,DC=example,DC=invalid');" $db)}finally{Close-DomeniaDatabase $db}
        $found=& ([scriptblock]::Create((Get-DomeniaLocalIndexReadWorkerCode)))
        Assert-Equal 3 ([int]$found.IndexCount)
        Assert-Equal 1 @($found.Users).Count 'Compte trouve par son identifiant, sans tenir compte de la casse'
        Assert-Equal 'user-guid' ([string]@($found.Users)[0].object_guid)
        Assert-Equal 1 @($found.Computers).Count 'Poste trouve par son nom, un utilisateur homonyme ignore'
        Assert-Equal 'machine-guid' ([string]@($found.Computers)[0].object_guid)
        $Payload=[pscustomobject]@{Action='ResolveNames';Path=$script:TestDbPath;BusyTimeoutMs=250;Users=@("x' OR 1=1 --");Computers=@()}
        Assert-Equal 0 @((& ([scriptblock]::Create((Get-DomeniaLocalIndexReadWorkerCode)))).Users).Count 'Nom non echappe'
        Assert-Equal 0 ([int](Get-LegacyCount 'user_machine_links')) 'Lecture qui ecrit'
    }finally{Remove-Item $root -Recurse -Force}
}
# ---------------------------------------------------------------- FI-19 (L20): the last SQLite reads of the Dispatcher
# Real schema, real pinned LocalIndexRead body executed in this process (as the CO-08 case), real callbacks of
# Domenia-Engine.UI.ps1 with a recording Start-UiTask. Nothing is written by a read; no network.
function Invoke-Fi19LocalRead {
    param([string]$Action,[hashtable]$Fields=@{},[string]$Path=$script:TestDbPath)
    $map=[ordered]@{Action=$Action;Path=$Path;BusyTimeoutMs=250}
    foreach($key in @($Fields.Keys)){$map[[string]$key]=$Fields[$key]}
    $Payload=[pscustomobject]$map
    return & ([scriptblock]::Create((Get-DomeniaLocalIndexReadWorkerCode)))
}
function Add-Fi19Rows { param([string]$Sql) $db=Open-DomeniaDatabase -Path $script:TestDbPath; try { [void](Invoke-DomeniaDbExec $Sql $db) } finally { Close-DomeniaDatabase $db } }
Test-Case 'FI-19 : LocalIndexRead IndexMetadata lit compteurs, repere et couverture en lecture seule' {
    $root=New-LegacySandbox
    try{
        $empty=Invoke-Fi19LocalRead 'IndexMetadata'
        Assert-False ([bool]$empty.Busy);Assert-False ([bool]$empty.Missing)
        Assert-Equal 0 ([long]$empty.Counts.Total) 'Base vide'
        Add-Fi19Rows ("INSERT INTO ad_objects(object_key,object_guid,object_type,name,login,state,distinguished_name) VALUES('u1','user-guid','Utilisateur','Alice','alice','Actif','CN=Alice,OU=Comptes,DC=example,DC=invalid'),('m1','pc1-guid','Machine','PC-1','PC-1$','Actif','CN=PC-1,OU=Parc,DC=example,DC=invalid'),('m2','pc2-guid','Machine','PC-2','PC-2$','Desactive','CN=PC-2,OU=Parc,DC=example,DC=invalid');" +
            " INSERT OR REPLACE INTO sync_state(scope,server,base_dn,highest_usn,last_sync,item_count,details) VALUES('directory','dc1.example.invalid','DC=example,DC=invalid',4242,'2026-10-01T08:00:00Z',3,'inv=11111111-2222-3333-4444-555555555555'),('ou:ou=parc,dc=example,dc=invalid','dc1.example.invalid','OU=Parc,DC=example,DC=invalid',4242,'2026-10-01T08:00:00Z',2,''),('autre:portee','dc1.example.invalid','DC=example,DC=invalid',0,'2026-10-01T08:00:00Z',0,'');")
        $read=Invoke-Fi19LocalRead 'IndexMetadata'
        Assert-Equal 3 ([long]$read.Counts.Total);Assert-Equal 1 ([long]$read.Counts.Users);Assert-Equal 2 ([long]$read.Counts.Computers)
        Assert-Equal 1 ([long]$read.Counts.MachinesActive);Assert-Equal 1 ([long]$read.Counts.MachinesDisabled);Assert-Equal 1 ([int]$read.MachineCount)
        $scopes=@($read.SyncStates|ForEach-Object{[string]$_.scope}|Sort-Object)
        Assert-True (($scopes -contains 'directory') -and ($scopes -contains 'ou:ou=parc,dc=example,dc=invalid')) ('Portees : '+($scopes -join ','))
        Assert-False ($scopes -contains 'autre:portee') 'Une portee hors repere est lue.'
        $state=ConvertTo-DomeniaIndexMetadataState -Result $read
        Assert-Equal '11111111-2222-3333-4444-555555555555' ([string]$state.Info.InvocationId);Assert-Equal 4242 ([long]$state.Info.Usn);Assert-Equal 'dc1.example.invalid' ([string]$state.Info.Server)
        $missing=Invoke-Fi19LocalRead 'IndexMetadata' -Path (Join-Path $root 'absente.db')
        Assert-True ([bool]$missing.Missing) 'Base absente non signalee.'
        Assert-False ([IO.File]::Exists((Join-Path $root 'absente.db'))) 'La lecture a cree une base.'
        Assert-Equal 0 ([int](ConvertTo-DomeniaIndexMetadataState -Result $missing).Counts.Total)
        Assert-Equal 3 (Get-LegacyCount 'ad_objects') 'Lecture qui ecrit'
    }finally{Remove-Item $root -Recurse -Force}
}
Test-Case 'FI-19 : LocalIndexRead associations, metadonnees de secrets et mesures, sans valeur secrete ni ecriture' {
    $root=New-LegacySandbox
    try{
        Assert-Equal 0 @((Invoke-Fi19LocalRead 'UserMachineLinks').Rows).Count 'Associations sur base vide'
        Add-Fi19Rows ("INSERT INTO user_machine_links(computer_key,user_login,computer,source,confidence,verified_in_ad,observed_at,details,user_guid,computer_guid,user_dn,computer_dn) VALUES('PC-1','alice','PC-1','Saisie manuelle',100,1,'2026-10-02T08:00:00Z','','user-guid','pc1-guid','CN=Alice,OU=Comptes,DC=example,DC=invalid','CN=PC-1,OU=Parc,DC=example,DC=invalid'),('PC-2','bob','PC-2','Console CIM/DCOM',60,0,'2026-10-03T08:00:00Z','','','','','');" +
            " INSERT INTO secret_state(computer_key,computer,checked_at,bitlocker_keys,bitlocker_last,laps_scheme,laps_expiry,verdict,detail) VALUES('PC-1','PC-1','2026-10-01T10:00:00Z',2,'01/10/2026','LAPS Windows','15/10/2026','Lecture autorisee','detail fournisseur');" +
            " INSERT INTO operation_runs(operation,item_count,duration_ms,bytes_estimated,remote_attempts,fallback_tasks,success_count,failure_count,finished_at) VALUES('IndexBuild',100,2000,1000,0,0,100,0,'2026-10-01T10:00:00Z'),('IndexBuild',100,4000,3000,0,0,90,10,'2026-10-02T10:00:00Z'),('IndexBuild',0,0,0,0,0,0,0,'2026-10-03T10:00:00Z');")
        $links=Invoke-Fi19LocalRead 'UserMachineLinks'
        Assert-Equal 'PC-2,PC-1' ((@($links.Rows)|ForEach-Object{[string]$_.Computer}) -join ',') 'Ordre du plus recent au plus ancien'
        $first=@($links.Rows|Where-Object{$_.Computer -eq 'PC-1'})[0]
        Assert-True ([bool]$first.VerifiedInAD) 'VerifiedInAD';Assert-Equal 100 ([int]$first.Confidence);Assert-Equal 'pc1-guid' ([string]$first.ComputerGuid)
        $secret=Invoke-Fi19LocalRead 'SecretIndexEntry' @{Computer=' pc-1 '}
        Assert-Equal 'PC-1' ([string]$secret.Computer) 'Nom normalise'
        Assert-Equal 1 @($secret.Rows).Count
        Assert-Equal 2 ([int]@($secret.Rows)[0].bitlocker_keys)
        Assert-True ($null -eq @($secret.Rows)[0].PSObject.Properties['detail']) 'Le detail du fournisseur est relu.'
        $summary=Format-DomeniaSecretIndexSummary -Entry @($secret.Rows)[0] -Now ([datetime]'2026-10-04T10:00:00Z')
        Assert-True (($summary.Contains('2 clé(s) BitLocker')) -and ($summary.Contains('LAPS Windows'))) ('Resume : '+$summary)
        Assert-Equal 0 @((Invoke-Fi19LocalRead 'SecretIndexEntry' @{Computer="x' OR 1=1 --"}).Rows).Count 'Nom non echappe'
        $refused=$false;try{[void](Invoke-Fi19LocalRead 'SecretIndexEntry' @{Computer='   '})}catch{$refused=$true}
        Assert-True $refused 'Poste vide accepte.'
        $stats=Invoke-Fi19LocalRead 'OperationStats'
        $row=@($stats.Rows|Where-Object{$_.operation -eq 'IndexBuild'})[0]
        Assert-Equal 3 ([int]$row.samples) 'Toutes les mesures comptent dans la grille';Assert-Equal 2 ([int]$row.n) 'Le modele ne garde que les mesures avec une duree'
        Assert-Equal 30 ([int][Math]::Round([double]$row.ms_per_item)) 'ms par objet'
        $models=ConvertTo-DomeniaOperationHistoryModels -Rows @($stats.Rows)
        Assert-Equal 2 ([int]$models['IndexBuild'].n)
        $unknown=$false;try{[void](Invoke-Fi19LocalRead 'Delete')}catch{$unknown=$true}
        Assert-True $unknown 'Action inconnue acceptee.'
        Assert-Equal 2 (Get-LegacyCount 'user_machine_links');Assert-Equal 1 (Get-LegacyCount 'secret_state');Assert-Equal 3 (Get-LegacyCount 'operation_runs')
    }finally{Remove-Item $root -Recurse -Force}
}
Test-Case 'FI-19 : rappel des metadonnees ignore une reponse perimee, relit une base occupee puis le signale' {
    $script:Fi19Starts=[Collections.Generic.List[object]]::new()
    function Start-UiTask { param($Name,$OperationId,$Code,$Payload,$CallbackState,$SuccessHandler,$ErrorHandler,$ReplaceKey,$TimeoutSeconds,$TaskClass,[switch]$NonCancellable) $script:Fi19Starts.Add([pscustomobject]@{OperationId=$OperationId;Payload=$Payload;State=$CallbackState;ReplaceKey=$ReplaceKey;TaskClass=$TaskClass;NonCancellable=[bool]$NonCancellable}); return ('fi19-'+$script:Fi19Starts.Count) }
    function Get-DomeniaLocalIndexReadWorkerCode { return 'corps epingle' }
    function Update-DomeniaIndexStats { $script:Fi19Stats++ }
    function Request-DomeniaIndexAutoRefresh { $script:Fi19Startup++ }
    function Request-DomeniaIndexFirstBuild { $script:Fi19Startup++ }
    function Request-DomeniaOperationStats { param([switch]$Export,[switch]$Quiet) $script:Fi19Startup++ }
    $script:Fi19Stats=0;$script:Fi19Startup=0;$script:IndexDbCount=-1;$script:IndexMetadataError='';$script:IndexMetadataGeneration=0L;$script:IndexMetadataStartupChecks=$false
    Request-DomeniaIndexMetadata -StartupChecks
    Request-DomeniaIndexMetadata
    Assert-Equal 2 $script:Fi19Starts.Count
    $first=$script:Fi19Starts[0];$second=$script:Fi19Starts[1]
    Assert-True (($first.OperationId -eq 'LocalIndexRead') -and ($first.Payload.Action -eq 'IndexMetadata') -and ($first.ReplaceKey -eq 'local:index-metadata') -and ($first.NonCancellable)) 'Lecture non confiee au worker LocalIndexRead.'
    # A view waits for it: never background work, which the Storage budget refuses while another local job runs.
    Assert-Equal 'Explicit' ([string]$first.TaskClass) 'Lecture des chiffres envoyee comme travail de fond.'
    $answer=[pscustomobject]@{Rows=@();Busy=$false;Missing=$false;MachineCount=1;SyncStates=@([pscustomobject]@{scope='directory';server='dc1';base_dn='DC=example,DC=invalid';highest_usn=7;last_sync='2026-10-01T08:00:00Z';item_count=2;details=''});Counts=[pscustomobject]@{Total=2;Users=1;Computers=1;MachinesActive=1;MachinesDisabled=0}}
    Complete-DomeniaIndexMetadataUi -Result $answer -State $first.State
    Assert-Equal (-1) ([int]$script:IndexDbCount) 'Une reponse remplacee par une demande plus recente a ete appliquee.'
    Complete-DomeniaIndexMetadataUi -Result $answer -State $second.State
    Assert-Equal 2 ([int]$script:IndexDbCount);Assert-Equal 7 ([long]$script:IndexInfo.Usn);Assert-Equal 1 $script:Fi19Stats
    Assert-Equal 3 $script:Fi19Startup 'Les avis de demarrage suivent la premiere reponse, une seule fois.'
    $busy=[pscustomobject]@{Rows=@();Busy=$true;Missing=$false;MachineCount=0}
    Request-DomeniaIndexMetadata
    for($i=0;$i -lt 3;$i++){$last=$script:Fi19Starts[$script:Fi19Starts.Count-1];Complete-DomeniaIndexMetadataUi -Result $busy -State $last.State}
    Assert-Equal 5 $script:Fi19Starts.Count 'Deux nouveaux essais attendus sur une base occupee.'
    Assert-True (([string]$script:IndexMetadataError).Contains('occupée')) ('Erreur : '+$script:IndexMetadataError)
    Assert-Equal 2 ([int]$script:IndexDbCount) 'Les derniers chiffres lus sont effaces par une base occupee.'
    $script:SessionEpoch=[long]2
    Request-DomeniaIndexMetadata
    $script:SessionEpoch=[long]3
    Complete-DomeniaIndexMetadataUi -Result $answer -State $script:Fi19Starts[$script:Fi19Starts.Count-1].State
    Assert-True (([string]$script:IndexMetadataError).Contains('occupée')) 'Une reponse d une autre session a ete appliquee.'
}
Test-Case 'FI-19 : associations lues pendant une modification : reference de la base, modification gardee puis enregistree' {
    $script:Fi19Starts=[Collections.Generic.List[object]]::new();$script:Fi19Persist=0
    function Start-UiTask { param($Name,$OperationId,$Code,$Payload,$CallbackState,$SuccessHandler,$ErrorHandler,$ReplaceKey,$TimeoutSeconds,$TaskClass,[switch]$NonCancellable) $script:Fi19Starts.Add([pscustomobject]@{OperationId=$OperationId;Payload=$Payload;State=$CallbackState}); return ('fi19-'+$script:Fi19Starts.Count) }
    function Get-DomeniaLocalIndexReadWorkerCode { return 'corps epingle' }
    function Request-DomeniaLinkPersistence { $script:Fi19Persist++ }
    # Canonical rule double: the most recent association per workstation (the real rule is covered by the Relations suite).
    function ConvertTo-DomeniaCanonicalLinks { param($Links) $seen=@{}; foreach($l in @(@($Links)|Sort-Object {[string]$_.When} -Descending)){ $k=([string]$l.Computer).ToUpperInvariant(); if(-not $seen.ContainsKey($k)){ $seen[$k]=$true; $l } } }
    function Update-DomeniaIndexStats { }
    function Request-DomeniaDashboardRefresh { }
    Initialize-DomeniaPersistence;Stop-TestTimers
    $script:LinkLoad=$null;$script:LinkLoadGeneration=0L
    Request-DomeniaUserMachineLinks
    Assert-True ([bool]$script:LinkLoad.Pending) 'Lecture des associations non signalee en cours.'
    # An association entered during the reading stays in memory; nothing is queued against an unknown reference.
    $script:UserMachineLinks=@([pscustomobject]@{Computer='PC-2';UserLogin='carol';Source='Saisie manuelle';When='2026-10-05T08:00:00Z'})
    Assert-True (Queue-DomeniaLinkChanges) 'Modification refusee pendant la lecture.'
    Assert-Equal 0 $script:Persistence.Pending.Count 'Une modification a ete mise en file sans reference.'
    Assert-True ([bool]$script:LinkLoad.Deferred) 'Modification differee non notee.'
    Assert-True (@($script:Statuses|Where-Object{$_ -match 'en cours de lecture'}).Count -eq 1) 'Operateur non informe.'
    $stored=[pscustomobject]@{Rows=@([pscustomobject]@{Computer='PC-1';UserLogin='alice';Source='Saisie manuelle';When='2026-10-01T08:00:00Z'},[pscustomobject]@{Computer='PC-2';UserLogin='bob';Source='Console CIM/DCOM';When='2026-10-02T08:00:00Z'});Busy=$false;Missing=$false;MachineCount=0}
    Complete-DomeniaUserMachineLinksUi -Result $stored -State $script:Fi19Starts[0].State
    Assert-True ($null -eq $script:LinkLoad) 'Lecture toujours en cours apres le rappel.'
    Assert-Equal 'alice' ([string]$script:LinkBaseline['PC-1'].UserLogin) 'Reference PC-1'
    Assert-Equal 'bob' ([string]$script:LinkBaseline['PC-2'].UserLogin) 'La reference doit etre la version de la base, pas la saisie.'
    Assert-Equal 'carol' ((@($script:UserMachineLinks)|Where-Object{$_.Computer -eq 'PC-2'}|ForEach-Object{[string]$_.UserLogin}) -join ',') 'La saisie faite pendant la lecture est perdue.'
    Assert-Equal 1 $script:Fi19Persist 'La saisie differee n est pas enregistree a la fin de la lecture.'
    Assert-True (Queue-DomeniaLinkChanges) 'Enregistrement refuse apres la lecture.'
    Assert-Equal 'PC-2' ((@($script:Persistence.Pending.Values)|ForEach-Object{[string]$_.Key}) -join ',') 'Seule la saisie differee doit partir.'
    Assert-Equal (Get-DomeniaLinkFingerprint $script:LinkBaseline['PC-2']) ([string]@($script:Persistence.Pending.Values)[0].Expected) 'Reference attendue absente du lot.'
    # A reading of an older session never holds the saves of the current one.
    $script:Persistence.Pending.Clear();$script:Persistence.LinkBusy=$false
    $script:LinkLoad=[pscustomobject]@{Pending=$true;Generation=99L;Epoch=0L;Deferred=$false}
    $script:UserMachineLinks=@($script:UserMachineLinks)+@([pscustomobject]@{Computer='PC-3';UserLogin='dave';Source='Saisie manuelle';When='2026-10-06T08:00:00Z'})
    Assert-True (Queue-DomeniaLinkChanges) 'Enregistrement refuse.'
    Assert-True (@(@($script:Persistence.Pending.Values)|ForEach-Object{[string]$_.Key}) -contains 'PC-3') 'Une lecture perimee bloque les enregistrements.'
    $script:LinkLoad=$null;Stop-TestTimers
}
Test-Case 'FI-19 : plus aucune lecture SQLite synchrone dans les chemins de l interface' {
    $coreText=[IO.File]::ReadAllText($core)
    foreach($removed in @('Load-DomeniaIndexMetadata','Load-UserMachineLinks','Get-DomeniaSecretIndexEntry','Get-DomeniaSecretIndexSummary','Refresh-DomeniaOperationStatsUi','Load-DomeniaParkState')){
        Assert-False ([regex]::IsMatch($coreText,'(?m)^function '+[regex]::Escape($removed)+'\b')) ('Lecteur synchrone encore defini : '+$removed)
    }
    # No product source still calls a removed reader (a dangling call fails only when its path runs).
    $removedReaders=@('Load-DomeniaIndexMetadata','Load-UserMachineLinks','Get-DomeniaSecretIndexEntry','Get-DomeniaSecretIndexSummary','Refresh-DomeniaOperationStatsUi','Load-DomeniaParkState','Invoke-DomeniaUiPump')
    foreach($source in @(@($core)+@(Get-ChildItem -LiteralPath $modules -Filter '*.ps1' -File|ForEach-Object{$_.FullName}))){
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
        $calls=@($ast.FindAll({param($n)($n -is [Management.Automation.Language.CommandAst])},$true)|ForEach-Object{[string]$_.GetCommandName()}|Where-Object{$removedReaders -contains $_})
        Assert-Equal 0 $calls.Count ('Appel a un lecteur retire dans '+[IO.Path]::GetFileName($source)+' : '+($calls -join ', '))
    }
    foreach($name in @('Get-DomeniaDatabaseObjectCount','Update-DomeniaIndexStats','Get-DomeniaParkCoverage','Get-DomeniaParkCoverageText','Get-DomeniaParkPriority','Get-DomeniaOperationHistoryModel','Export-DomeniaOperationStatsCsv','Reset-DomeniaSelectionBoundViews','Complete-DomeniaIndexBuildUi','Complete-DomeniaIndexRefreshUi','Complete-DomeniaIndexWalkUi','Initialize-DomeniaPresentation')){
        $text=Get-FunctionTextFromFile $core $name
        foreach($call in @('Invoke-DomeniaDbQuery','Invoke-DomeniaDbExec','Open-DomeniaDatabase','Initialize-DomeniaDatabase')){Assert-False ($text.Contains($call)) ($name+' appelle encore '+$call)}
    }
    $engineUi=Join-Path $modules 'Domenia-Engine.UI.ps1'
    foreach($name in @('Reset-DomeniaIndexMetadataState','Request-DomeniaIndexMetadataIfNeeded','Get-DomeniaParkMachineCount','Get-DomeniaParkCoverageWaitingText','Update-DomeniaParkCoverageAfterCount','Request-DomeniaIndexMetadata','Complete-DomeniaIndexMetadataUi','Request-DomeniaUserMachineLinks','Complete-DomeniaUserMachineLinksUi','Request-DomeniaSecretIndexSummary','Complete-DomeniaSecretIndexSummaryUi','Request-DomeniaOperationStats','Complete-DomeniaOperationStatsUi')){
        $text=Get-FunctionTextFromFile $engineUi $name
        foreach($call in @('Invoke-DomeniaDbQuery','Invoke-DomeniaDbExec','Open-DomeniaDatabase','Initialize-DomeniaDatabase')){Assert-False ($text.Contains($call)) ($name+' appelle '+$call)}
    }
    $storageText=[IO.File]::ReadAllText($storageUi)
    Assert-False ($storageText.Contains('Load-DomeniaIndexMetadata')) 'Le rappel du stockage relit encore la base sur le Dispatcher.'
    $relogin=Get-FunctionTextFromFile $core 'Start-DomeniaAccountRelogin'
    Assert-True (($relogin.Contains('Request-DomeniaIndexMetadata')) -and ($relogin.Contains('Request-DomeniaUserMachineLinks'))) 'Changer de compte ne relit plus la base locale.'
    $window=Get-FunctionTextFromFile $core 'Initialize-Window'
    Assert-True (($window.Contains('Request-DomeniaUserMachineLinks')) -and ($window.Contains('Request-DomeniaIndexMetadata -StartupChecks'))) 'Le demarrage ne lit plus la base hors du Dispatcher.'
}
Test-Case 'FI-19 : etat de la base remis a zero par session, relu a l ouverture de Base locale seulement s il manque' {
    $script:Fi19Starts=[Collections.Generic.List[object]]::new()
    function Start-UiTask { param($Name,$OperationId,$Code,$Payload,$CallbackState,$SuccessHandler,$ErrorHandler,$ReplaceKey,$TimeoutSeconds,$TaskClass,[switch]$NonCancellable) $script:Fi19Starts.Add([pscustomobject]@{OperationId=$OperationId;Payload=$Payload;State=$CallbackState}); return ('fi19-'+$script:Fi19Starts.Count) }
    function Get-DomeniaLocalIndexReadWorkerCode { return 'corps epingle' }
    function Update-DomeniaIndexStats { }
    function Update-DomeniaFirstSteps { $script:Fi19FirstSteps++ }
    $script:Fi19FirstSteps=0;$script:IndexMetadataStartupChecks=$false
    $script:IndexDbCount=12;$script:IndexDbUsers=5;$script:IndexDbComputers=7;$script:IndexDbMachinesActive=6;$script:IndexDbMachinesDisabled=1
    $script:IndexInfo=[pscustomobject]@{Server='ancien'};$script:IndexSyncStates=@{directory=$true};$script:IndexMetadataError='ancienne erreur'
    $generation=[long]$script:IndexMetadataGeneration
    Reset-DomeniaIndexMetadataState
    Assert-True ([long]$script:IndexMetadataGeneration -gt $generation) 'Une lecture de la base precedente resterait applicable.'
    foreach($name in @('IndexDbCount','IndexDbUsers','IndexDbComputers','IndexDbMachinesActive','IndexDbMachinesDisabled')){Assert-Equal (-1) ([int](Get-Variable -Scope Script -Name $name -ValueOnly)) ($name+' garde un chiffre de la base precedente.')}
    Assert-True (($null -eq $script:IndexInfo) -and ($script:IndexSyncStates.Count -eq 0) -and (-not $script:IndexMetadataError) -and (-not $script:IndexMetadataPending)) 'Etat de la base precedente conserve.'
    Request-DomeniaIndexMetadataIfNeeded
    Assert-Equal 1 $script:Fi19Starts.Count 'Chiffres inconnus : une lecture est attendue.'
    Assert-True ([bool]$script:IndexMetadataPending) 'Lecture en cours non notee.'
    Request-DomeniaIndexMetadataIfNeeded
    Assert-Equal 1 $script:Fi19Starts.Count 'Une seconde lecture part alors que la premiere court.'
    $answer=[pscustomobject]@{Rows=@();Busy=$false;Missing=$false;MachineCount=3;SyncStates=@();Counts=[pscustomobject]@{Total=9;Users=4;Computers=5;MachinesActive=3;MachinesDisabled=2}}
    Complete-DomeniaIndexMetadataUi -Result $answer -State $script:Fi19Starts[0].State
    Assert-False ([bool]$script:IndexMetadataPending) 'Lecture toujours notee en cours apres sa reponse.'
    Assert-Equal 9 ([int]$script:IndexDbCount);Assert-Equal 1 $script:Fi19FirstSteps 'Les premiers pas d Accueil ne suivent pas les chiffres lus.'
    Request-DomeniaIndexMetadataIfNeeded
    Assert-Equal 1 $script:Fi19Starts.Count 'Une page qui montre des chiffres est relue par un simple affichage.'
    Request-DomeniaIndexMetadata
    Fail-DomeniaIndexMetadataUi -Message 'Base locale occupée.' -State $script:Fi19Starts[1].State
    Assert-False ([bool]$script:IndexMetadataPending) 'Lecture toujours notee en cours apres son echec.'
    Assert-Equal 9 ([int]$script:IndexDbCount) 'Les derniers chiffres lus sont effaces par un echec.'
    Request-DomeniaIndexMetadataIfNeeded
    Assert-Equal 3 $script:Fi19Starts.Count 'Apres un echec, l ouverture de Base locale ne relit pas la base.'
    Reset-DomeniaIndexMetadataState
    Complete-DomeniaIndexMetadataUi -Result $answer -State $script:Fi19Starts[2].State
    Assert-Equal (-1) ([int]$script:IndexDbCount) 'Une reponse de la base precedente a ete appliquee apres la remise a zero.'
    $wire=Get-FunctionTextFromFile $core 'Wire-Events'
    Assert-True ([regex]::IsMatch($wire,"\`$script:Ctrl\['TabIndex'\]\)\)\s*\{\s*(#[^\n]*\n\s*)?Request-DomeniaIndexMetadataIfNeeded")) 'L ouverture de l onglet Base locale ne relit pas un etat manquant.'
    $relogin=Get-FunctionTextFromFile $core 'Start-DomeniaAccountRelogin'
    Assert-True ($relogin.IndexOf('Reset-DomeniaIndexMetadataState') -ge 0) 'Changer de compte garde les chiffres de la base precedente.'
    Assert-True ($relogin.IndexOf('Reset-DomeniaIndexMetadataState') -lt $relogin.IndexOf('Request-DomeniaIndexMetadata')) 'Remise a zero apres la demande de lecture.'
}
Test-Case 'FI-19 : base mise en service par une bascule : chiffres et associations relus hors du Dispatcher' {
    $script:Fi19Starts=[Collections.Generic.List[object]]::new()
    function Start-UiTask { param($Name,$OperationId,$Code,$Payload,$CallbackState,$SuccessHandler,$ErrorHandler,$ReplaceKey,$TimeoutSeconds,$TaskClass,[switch]$NonCancellable) $script:Fi19Starts.Add([pscustomobject]@{OperationId=$OperationId;Action=[string]$Payload.Action;State=$CallbackState}); return ('fi19-'+$script:Fi19Starts.Count) }
    function Get-DomeniaLocalIndexReadWorkerCode { return 'corps epingle' }
    function Initialize-DomeniaDatabase { if($script:Fi19InitFails){throw 'schema illisible'}; $script:Fi19Inits++; return $true }
    function Initialize-DomeniaQueryLibraryStore { param([switch]$Force) if($script:Fi19LibraryFails){throw 'bibliotheque illisible'} }
    function Request-DomeniaFleetRefresh { param([switch]$Force) }
    function Update-DomeniaIndexLocation { }
    function Update-DomeniaIndexStats { $script:Fi19Stats++ }
    . ([scriptblock]::Create((Get-FunctionTextFromFile (Join-Path $modules 'Domenia-StorageContext.UI.ps1') 'Resume-DomeniaDatabaseViews')))
    $script:Fi19Inits=0;$script:Fi19Stats=0;$script:Fi19InitFails=$false;$script:Fi19LibraryFails=$false;$script:LinkLoad=$null
    $script:IndexDbCount=40;$script:IndexDbMachinesActive=20;$script:IndexMetadataError=''
    Resume-DomeniaDatabaseViews
    Assert-Equal 0 $script:Fi19Starts.Count 'Une retention relit les associations : les saisies en memoire seraient prises pour des nouveautes.'
    Assert-Equal 40 ([int]$script:IndexDbCount)
    Resume-DomeniaDatabaseViews -ReloadLocalState
    Assert-Equal 'IndexMetadata,UserMachineLinks' ((@($script:Fi19Starts)|ForEach-Object{$_.Action}) -join ',') 'Lectures de la nouvelle base'
    Assert-True (@($script:Fi19Starts|Where-Object{$_.OperationId -ne 'LocalIndexRead'}).Count -eq 0) 'Lecture hors LocalIndexRead.'
    Assert-Equal (-1) ([int]$script:IndexDbMachinesActive) 'Les chiffres de la base precedente restent affiches.'
    Assert-True (($null -ne $script:LinkLoad) -and ([bool]$script:LinkLoad.Pending)) 'Les associations de la nouvelle base ne sont pas attendues.'
    Assert-True ($script:Fi19Stats -ge 1) 'La page Base locale ne dit pas que la base est en lecture.'
    # The schema of the new base cannot be opened: nothing of the replaced base stays (figures, pending associations),
    # and Base locale says that the base could not be read.
    $script:Fi19Starts.Clear();$script:Fi19InitFails=$true;$script:Fi19Stats=0
    $script:IndexDbCount=40;$script:IndexDbMachinesActive=20;$script:IndexMetadataError=''
    $script:LinkLoad=[pscustomobject]@{Pending=$true;Generation=[long]5;Epoch=[long]$script:SessionEpoch;Deferred=$false}
    Resume-DomeniaDatabaseViews -ReloadLocalState
    Assert-Equal 0 $script:Fi19Starts.Count 'Lecture d une base dont le schema n a pas pu etre ouvert.'
    Assert-True (@($script:Statuses|Where-Object{$_ -match 'relecture locale'}).Count -ge 1) 'Echec de l ouverture non signale.'
    Assert-Equal (-1) ([int]$script:IndexDbMachinesActive) 'Une ouverture en echec laisse les postes actifs de la base remplacee (couverture du parc).'
    Assert-Equal (-1) ([int]$script:IndexDbCount) 'Une ouverture en echec laisse les chiffres de la base remplacee.'
    Assert-True ($null -eq $script:LinkLoad) 'Une lecture d associations de la base remplacee reste attendue.'
    Assert-True (([string]$script:IndexMetadataError).Contains('schema illisible')) ('Base locale ne dit pas que la base n a pas pu etre lue : ' + [string]$script:IndexMetadataError)
    Assert-True ($script:Fi19Stats -ge 1) 'La page Base locale n est pas actualisee apres l echec.'
    # A later step fails after the opening: the reads already started keep the page, the error is not theirs.
    $script:Fi19Starts.Clear();$script:Fi19InitFails=$false;$script:Fi19LibraryFails=$true;$script:LinkLoad=$null;$script:IndexMetadataError=''
    Resume-DomeniaDatabaseViews -ReloadLocalState
    Assert-Equal 'IndexMetadata,UserMachineLinks' ((@($script:Fi19Starts)|ForEach-Object{$_.Action}) -join ',') 'Lectures de la nouvelle base apres son ouverture'
    Assert-Equal '' ([string]$script:IndexMetadataError) 'L echec d une etape posterieure est attribue a la lecture des chiffres.'
    Assert-True ([bool]$script:IndexMetadataPending) 'La lecture des chiffres n est plus attendue.'
    $script:Fi19LibraryFails=$false
    $apply=Get-FunctionTextFromFile $storageUi 'Complete-DomeniaStorageMaintenanceApply'
    Assert-True ($apply.Contains('Resume-DomeniaDatabaseViews -ReloadLocalState')) 'La bascule ne relit pas l etat de la nouvelle base.'
    $script:LinkLoad=$null;$script:IndexMetadataPending=$false
}
Test-Case 'FI-19 : retour sur Outils avec Base locale deja ouverte : etat manquant relu, page cachee ignoree' {
    # WPF raises no SelectionChanged on the inner tabs when Outils is shown again with Base locale already selected
    # (side bar, Ctrl+I, first steps of Accueil): the change of workspace asks, and only for that page.
    $script:Fi19Starts=[Collections.Generic.List[object]]::new()
    function Start-UiTask { param($Name,$OperationId,$Code,$Payload,$CallbackState,$SuccessHandler,$ErrorHandler,$ReplaceKey,$TimeoutSeconds,$TaskClass,[switch]$NonCancellable) $script:Fi19Starts.Add([pscustomobject]@{Action=[string]$Payload.Action;State=$CallbackState}); return ('fi19-'+$script:Fi19Starts.Count) }
    function Get-DomeniaLocalIndexReadWorkerCode { return 'corps epingle' }
    function Update-DomeniaIndexStats { }
    $script:Fi19Tabs=@{WorkspaceTabs=[pscustomobject]@{SelectedItem=[pscustomobject]@{Name='TabDashboard'}};ApplicationToolTabs=[pscustomobject]@{SelectedItem=[pscustomobject]@{Name='TabIndex'}}}
    function Get-DomeniaControl { param([string]$Name) return $script:Fi19Tabs[$Name] }
    Reset-DomeniaIndexMetadataState
    $script:IndexMetadataError='Base locale occupée.'
    Request-DomeniaIndexMetadataIfNeeded -IfShown
    Assert-Equal 0 $script:Fi19Starts.Count 'Lecture demandee alors que Base locale n est pas affichee.'
    $script:Fi19Tabs['WorkspaceTabs'].SelectedItem=[pscustomobject]@{Name='TabApplicationTools'}
    $script:Fi19Tabs['ApplicationToolTabs'].SelectedItem=[pscustomobject]@{Name='TabOperationStats'}
    Request-DomeniaIndexMetadataIfNeeded -IfShown
    Assert-Equal 0 $script:Fi19Starts.Count 'Lecture demandee pour un autre outil.'
    $script:Fi19Tabs['ApplicationToolTabs'].SelectedItem=[pscustomobject]@{Name='TabIndex'}
    Request-DomeniaIndexMetadataIfNeeded -IfShown
    Assert-Equal 'IndexMetadata' ((@($script:Fi19Starts)|ForEach-Object{$_.Action}) -join ',') 'Retour sur Base locale apres un echec : etat non relu.'
    Request-DomeniaIndexMetadataIfNeeded -IfShown
    Assert-Equal 1 $script:Fi19Starts.Count 'Une seconde lecture part alors que la premiere court.'
    $wire=Get-FunctionTextFromFile $core 'Wire-Events'
    Assert-True ($wire.Contains('Request-DomeniaIndexMetadataIfNeeded -IfShown')) 'Le changement d espace de travail ne relit pas l etat manquant de Base locale.'
    Reset-DomeniaIndexMetadataState
}
Test-Case 'FI-19 : vue d ensemble refusee pendant une lecture locale redemandee a sa reponse, jamais avant l affichage' {
    # D018: a background Storage job (the quiet overview of Accueil) is refused while a local read runs. The answers of
    # the figures and of the associations ask for it again; before the main window is shown the overview waits for the
    # remembered OU of Rechercher and is not asked.
    $script:Fi19Starts=[Collections.Generic.List[object]]::new();$script:Fi19Fleet=0
    function Start-UiTask { param($Name,$OperationId,$Code,$Payload,$CallbackState,$SuccessHandler,$ErrorHandler,$ReplaceKey,$TimeoutSeconds,$TaskClass,[switch]$NonCancellable) $script:Fi19Starts.Add([pscustomobject]@{Action=[string]$Payload.Action;State=$CallbackState}); return ('fi19-'+$script:Fi19Starts.Count) }
    function Get-DomeniaLocalIndexReadWorkerCode { return 'corps epingle' }
    function Update-DomeniaIndexStats { }
    function Update-DomeniaFirstSteps { }
    function Request-DomeniaDashboardRefresh { }
    function Request-DomeniaFleetRefresh { param([switch]$Force) $script:Fi19Fleet++ }
    function ConvertTo-DomeniaCanonicalLinks { param($Links) @($Links) }
    $shown=$script:DomeniaSessionShown
    try {
        $script:IndexMetadataStartupChecks=$false;$script:LinkLoad=$null;$script:UserMachineLinks=@()
        $figures=[pscustomobject]@{Rows=@();Busy=$false;Missing=$false;MachineCount=0;SyncStates=@();Counts=[pscustomobject]@{Total=0;Users=0;Computers=0;MachinesActive=0;MachinesDisabled=0}}
        $links=[pscustomobject]@{Rows=@();Busy=$false;Missing=$false;MachineCount=0}
        foreach($visible in @($false,$true)){
            $script:DomeniaSessionShown=$visible
            Request-DomeniaIndexMetadata
            Complete-DomeniaIndexMetadataUi -Result $figures -State $script:Fi19Starts[$script:Fi19Starts.Count-1].State
            Request-DomeniaUserMachineLinks
            Complete-DomeniaUserMachineLinksUi -Result $links -State $script:Fi19Starts[$script:Fi19Starts.Count-1].State
            if(-not $visible){Assert-Equal 0 $script:Fi19Fleet 'Vue d ensemble demandee avant l affichage de la fenetre principale.'}
        }
        Assert-Equal 2 $script:Fi19Fleet 'Vue d ensemble refusee pendant une lecture locale non redemandee a sa reponse.'
        Assert-Equal 0 ([int]$script:IndexDbCount) 'Chiffres non appliques.'
        Assert-True ($null -eq $script:LinkLoad) 'Associations toujours attendues.'
    } finally { $script:DomeniaSessionShown=$shown;$script:LinkLoad=$null;Reset-DomeniaIndexMetadataState }
}
Test-Case 'FI-19 : couverture du parc par les chiffres de la base, texte d attente complete par leur reponse' {
    $script:Fi19Label=[pscustomobject]@{Text=''}
    function Get-DomeniaControl { param([string]$Name) if($Name -eq 'LblParkStatus'){return $script:Fi19Label};return $null }
    function Set-DomeniaControlText { param($Name,$Text) if($Name -eq 'LblParkStatus'){$script:Fi19Label.Text=[string]$Text};return $true }
    function Request-DomeniaIndexMetadataIfNeeded { $script:Fi19MetadataAsks++ }
    function Request-DomeniaParkStateReload { $script:Fi19ParkReloads++ }
    . ([scriptblock]::Create((Get-FunctionTextFromFile $core 'Get-DomeniaParkCoverage')))
    . ([scriptblock]::Create((Get-FunctionTextFromFile $core 'Get-DomeniaParkCoverageText')))
    . ([scriptblock]::Create((Get-FunctionTextFromFile $core 'Get-DomeniaParkPriority')))
    $script:Fi19MetadataAsks=0;$script:Fi19ParkReloads=0;$script:ParkDormants=0;$script:IndexRows=@();$script:ParkCoverageWaitingText=''
    $script:IndexDbMachinesActive=-1;$script:ParkMachineCount=$null
    $script:ParkState=@{'PC-1'=[pscustomobject]@{Computer='PC-1';LastProbe=(Get-Date).AddHours(-2).ToString('s');Status='Session';User='alice';Attempts=1}}
    Assert-Equal (-1) (Get-DomeniaParkMachineCount) 'Compte inconnu'
    $script:ParkMachineCount=[pscustomobject]@{Epoch=[long]$script:SessionEpoch;Count=7}
    Assert-Equal 7 (Get-DomeniaParkMachineCount) 'Compte du releve enregistre de la session'
    $script:IndexDbMachinesActive=3
    Assert-Equal 3 (Get-DomeniaParkMachineCount) 'Les chiffres de la base, actualises apres chaque enregistrement, priment.'
    $script:IndexDbMachinesActive=-1;$script:ParkMachineCount=[pscustomobject]@{Epoch=([long]$script:SessionEpoch - 1);Count=7}
    Assert-Equal (-1) (Get-DomeniaParkMachineCount) 'Compte d une autre session'
    $waiting=Get-DomeniaParkStatusTextSafe
    Assert-True ($waiting.StartsWith('1 poste(s) relevé(s) en mémoire.')) $waiting
    Assert-True ($waiting.Contains('dès que lʼétat de la base locale est lu')) $waiting
    Assert-Equal 1 $script:Fi19MetadataAsks 'Le texte d attente promet une lecture qui n est pas demandee.'
    Assert-Equal $waiting (Get-DomeniaParkCoverageText) 'Les deux chemins du texte divergent.'
    $script:Fi19Label.Text=$waiting
    Update-DomeniaParkCoverageAfterCount
    Assert-Equal $waiting $script:Fi19Label.Text 'Compte toujours inconnu : le texte d attente doit rester.'
    $script:IndexDbMachinesActive=4
    Update-DomeniaParkCoverageAfterCount
    Assert-True ($script:Fi19Label.Text.StartsWith('4 poste(s) actif(s), 1 relevé(s) soit 25 pour cent, 1 avec un utilisateur connu')) $script:Fi19Label.Text
    Assert-Equal '' ([string]$script:ParkCoverageWaitingText) 'Texte d attente non oublie.'
    # A survey in progress keeps its own text: the answer of the figures never overwrites it.
    $script:IndexDbMachinesActive=-1
    $script:Fi19Label.Text=(Get-DomeniaParkStatusTextSafe)
    $script:Fi19Label.Text='Relevé en cours : 3 poste(s) sur 10.'
    $script:IndexDbMachinesActive=4
    Update-DomeniaParkCoverageAfterCount
    Assert-Equal 'Relevé en cours : 3 poste(s) sur 10.' $script:Fi19Label.Text 'Un texte de progression a ete remplace.'
    # Priority queue without the stored survey: asked off the Dispatcher, nothing computed on a guess, no error.
    $script:ParkState=$null;$script:IndexRows=@([pscustomobject]@{Type='Machine';State='Actif';Name='PC-9'})
    Assert-Equal 0 @(Get-DomeniaParkPriority).Count 'File de priorite calculee sans le releve enregistre.'
    Assert-Equal 1 $script:Fi19ParkReloads 'Releve enregistre non demande.'
    $script:IndexRows=@();$script:ParkState=$null;$script:IndexDbMachinesActive=-1
}
Test-Case 'FI-19 : libelle des statistiques, echec silencieux du resume des secrets, saisie differee d une autre session' {
    $script:Fi19Starts=[Collections.Generic.List[object]]::new();$script:Fi19Labels=@{};$script:Fi19Traces=[Collections.Generic.List[string]]::new()
    function Start-UiTask { param($Name,$OperationId,$Code,$Payload,$CallbackState,$SuccessHandler,$ErrorHandler,$ReplaceKey,$TimeoutSeconds,$TaskClass,[switch]$NonCancellable) $script:Fi19Starts.Add([pscustomobject]@{Action=[string]$Payload.Action;State=$CallbackState}); return ('fi19-'+$script:Fi19Starts.Count) }
    function Get-DomeniaLocalIndexReadWorkerCode { return 'corps epingle' }
    function Set-DomeniaControlText { param($Name,$Text) $script:Fi19Labels[[string]$Name]=[string]$Text;return $true }
    function Write-DomeniaTrace { param([string]$Text,[string]$Area='Tache') $script:Fi19Traces.Add($Text) }
    $script:OperationStatsExportPending=$false;$script:OperationStatsLabelPending=$false
    Request-DomeniaOperationStats
    Assert-Equal 'Lecture des mesures dans la base locale…' $script:Fi19Labels['LblOperationStats']
    Request-DomeniaOperationStats -Quiet
    Fail-DomeniaOperationStatsUi -Message 'Base locale occupée.' -State $script:Fi19Starts[1].State
    Assert-Equal 'Statistiques non relues : Base locale occupée.' $script:Fi19Labels['LblOperationStats'] 'Le libelle reste sur la lecture remplacee.'
    $script:Fi19Labels['LblOperationStats']='12 mesure(s) sur 2 type(s) dʼopération.'
    Request-DomeniaOperationStats -Quiet
    Fail-DomeniaOperationStatsUi -Message 'Base locale occupée.' -State $script:Fi19Starts[2].State
    Assert-Equal '12 mesure(s) sur 2 type(s) dʼopération.' $script:Fi19Labels['LblOperationStats'] 'Une lecture discrete (estimation) a remplace le libelle.'
    # Secret summary of a selection: a failure goes to the trace, never once per click into the session journal.
    $script:SecretIndexSummaryGeneration=[long]41
    $logs=$script:Logs.Count
    Fail-DomeniaSecretIndexSummaryUi -Message 'Maintenance de la base en cours.' -State ([pscustomobject]@{Generation=[long]41;Epoch=[long]$script:SessionEpoch;Computer='PC-1';Hint=''})
    Assert-Equal $logs $script:Logs.Count 'Echec du resume ecrit dans le journal de session.'
    Assert-True (($script:Fi19Traces.Count -eq 1) -and ($script:Fi19Traces[0].Contains('PC-1'))) 'Echec du resume absent de la trace.'
    # A change deferred while a reading of the previous session ran is not owed to the new session.
    $script:LinkLoad=[pscustomobject]@{Pending=$true;Generation=[long]7;Epoch=([long]$script:SessionEpoch - 1);Deferred=$true}
    Request-DomeniaUserMachineLinks
    Assert-False ([bool]$script:LinkLoad.Deferred) 'Saisie differee d une autre session reportee sur la nouvelle.'
    $script:LinkLoad.Deferred=$true
    Request-DomeniaUserMachineLinks -Attempt 1
    Assert-True ([bool]$script:LinkLoad.Deferred) 'Saisie differee de la session perdue par un nouvel essai.'
    $script:LinkLoad=$null
}

Test-Case 'Parc : cache durable fait partie de la mesure et de la purge explicite' {
    $root=New-LegacySandbox
    try{
        $row=[pscustomobject]@{Version=1;Key='cn=pc-1,dc=example,dc=invalid';Guid='guid1';Computer='PC-1';CheckedUtc='2000-01-01T00:00:00Z';Outcome='Unavailable';LinkUser='alice'}
        [void](Invoke-LegacyWorker ([pscustomobject]@{Path=$script:TestDbPath;Items=@([pscustomobject]@{Kind='ParkSession';Row=$row})}))
        $usage=Invoke-UsageWorker;$table=@(@($usage.Categories|Where-Object Category -eq 'Observations')[0].Tables|Where-Object Table -eq 'park_session_cache')[0];Assert-Equal 1 $table.Rows
        $Payload=[pscustomobject]@{Path=$script:TestDbPath;Selection=@('Observations');HistoryCutoffUtc='';DryRun=$true;ExpectedFingerprint=''}
        $preview=& ([scriptblock]::Create((Get-DomeniaStoragePurgeWorkerCode)))
        Assert-Equal 1 (Get-LegacyCount 'park_session_cache')
        $Payload.DryRun=$false;$Payload.ExpectedFingerprint=$preview.Fingerprint
        $apply=& ([scriptblock]::Create((Get-DomeniaStoragePurgeWorkerCode)))
        Assert-True $apply.Committed;Assert-Equal 0 (Get-LegacyCount 'park_session_cache')
    }finally{Remove-Item $root -Recurse -Force}
}

Test-Case 'Parc : remplacement atomique conserve ancien et nouveau user et refuse le conflit' {
    $root=New-LegacySandbox
    try{
        $old=[pscustomobject]@{UserLogin='alice';Computer='PC-1';Source='Console CIM/DCOM';Confidence=0;VerifiedInAD=$true;When='2026-01-01T00:00:00Z';Details='premier';UserGuid='user-1';ComputerGuid='machine-1';UserDn='CN=Alice,DC=example,DC=invalid';ComputerDn='CN=PC-1,DC=example,DC=invalid'}
        $item=[pscustomobject]@{Kind='Link';Key='PC-1';Expected='';Row=$old;Remove=$false}
        [void](Invoke-LegacyWorker ([pscustomobject]@{Path=$script:TestDbPath;Items=@($item)}))
        # Simulate an old primary imported before this history writer existed.
        $db=Open-DomeniaDatabase -Path $script:TestDbPath
        try{[void](Invoke-DomeniaDbExec 'DELETE FROM user_machine_history;' $db)}finally{Close-DomeniaDatabase $db}
        $new=$old.PSObject.Copy();$new.UserLogin='bob';$new.UserGuid='user-2';$new.UserDn='CN=Bob,DC=example,DC=invalid';$new.When='2026-02-01T00:00:00Z'
        $item.Expected=Get-DomeniaLinkFingerprint $old;$item.Row=$new
        $written=Invoke-LegacyWorker ([pscustomobject]@{Path=$script:TestDbPath;Items=@($item)})
        Assert-Equal 0 $written.Conflicts.Count;Assert-Equal 1 (Get-LegacyCount "user_machine_links WHERE user_login='bob'")
        Assert-Equal 1 (Get-LegacyCount "user_machine_history WHERE user_login='alice'");Assert-Equal 1 (Get-LegacyCount "user_machine_history WHERE user_login='bob'")
        $item.Row=$old
        $conflict=Invoke-LegacyWorker ([pscustomobject]@{Path=$script:TestDbPath;Items=@($item)})
        Assert-Equal 1 $conflict.Conflicts.Count;Assert-Equal 1 (Get-LegacyCount "user_machine_links WHERE user_login='bob'");Assert-Equal 2 (Get-LegacyCount 'user_machine_history')
    }finally{Remove-Item $root -Recurse -Force}
}

# ---------------------------------------------------------------- Lot L01 (decision David 2026-10-08): directory facts,
# fleet aggregates in SQL, daily snapshots, BitLocker presence. Real SQLite, real pinned bodies, no network.
Stop-TestTimers
. (Join-Path $modules 'Domenia-Boards.Model.ps1')
. (Join-Path $modules 'Domenia-BoardFleet.Model.ps1')
. ([scriptblock]::Create((Get-FunctionTextFromFile (Join-Path $modules 'Domenia-Secrets.Worker.ps1') 'Get-DomeniaBitLockerPresenceWorkerCode')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $core 'Get-DomeniaIndexWorkerCode')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $core 'Get-DomeniaIndexOuListWorkerCode')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $core 'Test-DomeniaSensitiveAttributeName')))
function Add-L01Rows { param([string]$Sql) $db = Open-DomeniaDatabase -Path $script:TestDbPath; try { [void](Invoke-DomeniaDbExec $Sql $db) } finally { Close-DomeniaDatabase $db } }
function Get-L01Rows { param([string]$Sql) $db = Open-DomeniaDatabase -Path $script:TestDbPath -ReadOnly; try { return @(Invoke-DomeniaDbQuery $Sql $db) } finally { Close-DomeniaDatabase $db } }
function New-L01IndexRow {
    param([string]$Name,[string]$Container,[string]$Guid,[string]$Os = 'Windows 11 Entreprise',[string]$Version = '10.0 (26100)',[string]$State = 'Actif',[string]$LastLogon = '01/10/2026 08:00:00',[string]$Created = '2025-01-01T00:00:00Z',[string]$Pwd = '2026-09-20T00:00:00Z',[string]$LapsKind = 'None',[string]$LapsExpiry = '')
    return [pscustomobject]@{ Type = 'Machine'; Name = $Name; Login = $Name; Upn = ($Name.ToLowerInvariant() + '.example.invalid'); Display = ''; Description = 'Poste fictif'; Extra = ($Os + ' / Lyon'); State = $State; DN = ('CN=' + $Name + ',' + $Container); WhenChanged = ''; Usn = 1; LastLogon = $LastLogon; Guid = $Guid; Facts = $true; OsVersion = $Version; WhenCreated = $Created; PwdLastSet = $Pwd; LapsKind = $LapsKind; LapsExpiry = $LapsExpiry }
}
function Invoke-L01Bulk {
    param([object[]]$Rows,[bool]$ReplaceAll = $true,[string]$At = '2026-10-08T08:00:00.0000000Z')
    $bulk = [pscustomobject]@{ Rows = @($Rows); Server = 'dc.example.invalid'; BaseDn = 'DC=example,DC=invalid'; HighestUsn = 10; TotalCount = @($Rows).Count; ReplaceAll = $ReplaceAll; InvocationId = ''; At = $At }
    return Invoke-LegacyWorker ([pscustomobject]@{ Path = $script:TestDbPath; Items = @([pscustomobject]@{ Kind = 'IndexBulk'; Key = 'directory'; Row = $bulk }) })
}
function Invoke-L01Fleet {
    param([string]$Scope = '',[bool]$Subtree = $true,[object[]]$Keys = @(),[datetime]$Now = [datetime]::Now)
    $Payload = [pscustomobject]@{ Action = 'FleetStats'; ModuleRoot = $modules; Path = $script:TestDbPath; BusyTimeoutMs = 250; Scope = $Scope; Subtree = $Subtree; Plan = (Get-DomeniaFleetQueryPlan -Now $Now); Keys = $Keys; ScopeKey = 'scope-l01' }
    return & ([scriptblock]::Create((Get-DomeniaLocalIndexReadWorkerCode)))
}
function Save-L01Observation {
    param([string]$Dn,[string]$Guid,[string]$Computer,[double]$DaysAgo,[string]$User = '')
    $stamp=[datetime]::UtcNow.AddDays(0 - $DaysAgo).ToString('o')
    $row = [pscustomobject]@{ Version = 1; Key = $Dn.ToLowerInvariant(); Guid = $Guid; Computer = $Computer; CheckedUtc = $stamp; ObservedUtc = $stamp; Outcome = 'Observed'; Presence = 'En ligne'; LinkUser = $User }
    return Invoke-LegacyWorker ([pscustomobject]@{ Path = $script:TestDbPath; Items = @([pscustomobject]@{ Kind = 'ParkSession'; Row = $row }) })
}

Test-Case 'L01 : base 11/1 existante, tables additives creees, schema_info inchange, sans sauvegarde de migration, relue par RC1.13.0' {
    $root = New-SchemaSandbox -Version '11' -Revision '1'
    try {
        Assert-True (Initialize-DomeniaDatabase) 'Ouverture refusee.'
        Assert-Equal '11' (Get-SchemaValue 'schema_version') 'Version modifiee.'
        Assert-Equal '1' (Get-SchemaValue 'domenia_schema') 'Revision modifiee.'
        Assert-Equal 2 @(Get-L01Rows 'SELECT key FROM schema_info;').Count 'Cle de schema ajoutee.'
        Assert-Equal 2 @(Get-L01Rows "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('ad_computer_facts','fleet_snapshots');").Count 'Tables additives absentes.'
        Assert-False ([IO.Directory]::Exists((Join-Path $root 'Backups\migrations'))) 'Sauvegarde de migration demandee pour une base 11/1.'
        Assert-Equal 0 $script:RecoverCalls 'Restauration tentee.'
        # The RC1.13.0 schema script (this function without the lines of the lot) still opens the completed base.
        $lines = @((Get-FunctionTextFromFile $core 'Initialize-DomeniaDatabase') -split "`n" | Where-Object { $_ -notmatch 'ad_computer_facts|fleet_snapshots|UPDATE ad_objects SET search_key|repair:search_key_extra' })
        $old = ($lines -join "`n") -replace 'function Initialize-DomeniaDatabase \{','function Initialize-L01PreviousDatabase {'
        Assert-False ($old -match 'ad_computer_facts|fleet_snapshots') 'Script precedent mal reconstitue.'
        . ([scriptblock]::Create($old))
        $script:DomeniaDatabaseReady = $false
        Assert-True (Initialize-L01PreviousDatabase) 'RC1.13.0 refuse la base completee.'
        Assert-Equal '11' (Get-SchemaValue 'schema_version'); Assert-Equal '1' (Get-SchemaValue 'domenia_schema')
        Assert-Equal 2 @(Get-L01Rows "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('ad_computer_facts','fleet_snapshots');").Count 'Tables additives supprimees par RC1.13.0.'
        $script:DomeniaDatabaseReady = $false
        Assert-True (Initialize-DomeniaDatabase) 'Deuxieme ouverture refusee.'
    } finally { Remove-Item $root -Recurse -Force }
}
Test-Case 'L01 : IndexBulk ecrit les faits par GUID, ReplaceAll les vide ; Index et IndexBulk ont le meme search_key' {
    $root = New-LegacySandbox
    try {
        $rows = @((New-L01IndexRow 'PC-1' 'OU=Lyon,DC=example,DC=invalid' 'AAAA-0001' -LapsKind 'Windows' -LapsExpiry '2026-11-01T00:00:00Z'), (New-L01IndexRow 'PC-2' 'OU=Lyon,DC=example,DC=invalid' 'BBBB-0002'))
        Assert-True (Invoke-L01Bulk $rows).Saved 'IndexBulk non enregistre.'
        Assert-Equal 2 (Get-LegacyCount 'ad_computer_facts')
        $facts = @(Get-L01Rows "SELECT * FROM ad_computer_facts WHERE object_guid='aaaa-0001';")[0]
        Assert-Equal '10.0 (26100)' $facts.os_version; Assert-Equal 'Windows' $facts.laps_kind; Assert-Equal '2026-11-01T00:00:00Z' $facts.laps_expiry
        Assert-Equal '2026-10-08T08:00:00.0000000Z' $facts.read_at 'Faits dates de la mise a jour.'
        $bulkKey = [string]@(Get-L01Rows "SELECT search_key FROM ad_objects WHERE name='PC-1';")[0].search_key
        Assert-True ($bulkKey -like '*windows 11 entreprise / lyon*') ('search_key IndexBulk : ' + $bulkKey)
        # A single row written when an object card is opened keeps the extra field (CO-26).
        $index = [pscustomobject]@{ Kind = 'Index'; Row = $rows[0]; Server = 'dc.example.invalid'; At = '2026-10-08T09:00:00Z' }
        Assert-True (Invoke-LegacyWorker ([pscustomobject]@{ Path = $script:TestDbPath; Items = @($index) })).Saved
        Assert-Equal $bulkKey ([string]@(Get-L01Rows "SELECT search_key FROM ad_objects WHERE name='PC-1';")[0].search_key) 'search_key different entre Index et IndexBulk.'
        Assert-True (Invoke-L01Bulk @($rows[1]) -At '2026-10-09T08:00:00.0000000Z').Saved
        Assert-Equal 1 (Get-LegacyCount 'ad_computer_facts') 'ReplaceAll ne vide pas les faits.'
        Assert-Equal 1 (Get-LegacyCount 'ad_objects')
    } finally { Remove-Item $root -Recurse -Force }
}
Test-Case 'L01 : faits anterieurs a la derniere mise a jour affiches a relire, mise a jour partielle conservee' {
    $root = New-LegacySandbox
    try {
        $rows = @((New-L01IndexRow 'PC-1' 'OU=Lyon,DC=example,DC=invalid' 'AAAA-0001'), (New-L01IndexRow 'PC-2' 'OU=Lyon,DC=example,DC=invalid' 'BBBB-0002'))
        [void](Invoke-L01Bulk $rows)
        [void](Invoke-L01Bulk @($rows[0]) -ReplaceAll $false -At '2026-10-08T12:00:00.0000000Z')
        $fresh = Invoke-L01Fleet -Scope 'OU=Lyon,DC=example,DC=invalid'
        Assert-Equal 2 ([int]$fresh.Coverage.FactsFresh) 'Mise a jour partielle : faits encore courants.'
        Assert-Equal 0 ([int]$fresh.Coverage.FactsStale)
        # A previous version rebuilds the index without the facts: they are older than the last update.
        Add-L01Rows "UPDATE sync_state SET last_sync='2026-12-01T00:00:00.0000000Z' WHERE scope='directory';"
        $stale = Invoke-L01Fleet -Scope 'OU=Lyon,DC=example,DC=invalid'
        Assert-Equal 0 ([int]$stale.Coverage.FactsFresh); Assert-Equal 2 ([int]$stale.Coverage.FactsStale)
        Assert-Equal 0 @(@($stale.Groups) | Where-Object { [string]$_.ver }).Count 'Version lue dans des faits perimes.'
        $board = Get-DomeniaFleetBoardData -Result $stale -Scope 'OU=Lyon,DC=example,DC=invalid' -Now ([datetime]::Now)
        Assert-Equal 'À relire' ([string]$board.Entries['fleet.laps'].Value)
        Assert-Equal 'À relire' ([string]$board.Entries['fleet.created'].Value)
    } finally { Remove-Item $root -Recurse -Force }
}
Test-Case 'L01 : FleetStats filtre l OU en SQL, rattache les observations par GUID et ecarte les anciennes' {
    $root = New-LegacySandbox
    try {
        $lyon = 'OU=Lyon,DC=example,DC=invalid'
        $rows = @(
            (New-L01IndexRow 'PC-1' $lyon 'guid-0001' -LapsKind 'Legacy' -LapsExpiry '2027-01-01T00:00:00Z')
            (New-L01IndexRow 'PC-2' $lyon 'guid-0002')
            (New-L01IndexRow 'PC-3' 'OU=Paris,DC=example,DC=invalid' 'guid-0003')
            (New-L01IndexRow 'PC-4' $lyon 'guid-0004' -State 'Desactive')
            (New-L01IndexRow 'PC-5' $lyon 'guid-0005' -Os 'Windows 10 Entreprise' -Version '10.0 (19045)')
            (New-L01IndexRow 'PC-6' ('OU=Etage,' + $lyon) 'guid-0006' -LastLogon '01/01/2026 08:00:00')
        )
        [void](Invoke-L01Bulk $rows)
        [void](Save-L01Observation ('CN=PC-1,' + $lyon) 'guid-0001' 'PC-1' 1 'EX\alice')
        [void](Save-L01Observation ('CN=PC-2,' + $lyon) 'guid-recreated' 'PC-2' 1 'EX\bob')
        [void](Save-L01Observation 'CN=PC-3,OU=Paris,DC=example,DC=invalid' 'guid-0003' 'PC-3' 1 'EX\carl')
        [void](Save-L01Observation ('CN=PC-5,' + $lyon) 'guid-0005' 'PC-5' 40 'EX\dan')
        $result = Invoke-L01Fleet -Scope $lyon -Keys @('cn=pc-3,ou=paris,dc=example,dc=invalid')
        Assert-False ([bool]$result.Busy)
        Assert-Equal 4 ([int]$result.MachineCount) 'Postes actifs de l OU et sous-OU.'
        Assert-Equal 'PC-1,PC-2,PC-4,PC-5,PC-6' (@(@($result.Machines) | ForEach-Object { [string]$_.name }) -join ',')
        $n = 0; foreach ($group in @($result.Groups)) { $n += [int]$group.n }
        Assert-Equal 5 $n 'Groupes = postes de l OU, desactive compris.'
        Assert-Equal 'D' ([string]@(@($result.Machines) | Where-Object { $_.name -eq 'PC-4' })[0].st)
        $presence = @($result.Presence)
        Assert-Equal 'cn=pc-1,ou=lyon,dc=example,dc=invalid|cn=pc-3,ou=paris,dc=example,dc=invalid' (@($presence | ForEach-Object { [string]$_.object_key } | Sort-Object) -join '|') 'GUID different ou releve de plus de 30 jours retenu.'
        Assert-False ([bool]@($presence | Where-Object { $_.name -eq 'PC-3' })[0].in_scope) 'Poste selectionne hors OU compte dans l OU.'
        Assert-True ([string]@($presence | Where-Object { $_.name -eq 'PC-1' })[0].gid) 'Observation sans groupe.'
        $board = Get-DomeniaFleetBoardData -Result $result -Scope $lyon -Now ([datetime]::Now)
        Assert-Equal '5' ([string]$board.Entries['fleet.machines'].Value) 'La tuile exclurait encore les desactives.'
        Assert-Equal ('dont 4 actifs et 1 désactivé · dans l OU et ses sous-OU') ([string]$board.Entries['fleet.machines'].Detail)
        Assert-Equal '1' ([string]$board.Entries['fleet.disabled'].Value)
        Assert-Equal '1' ([string]$board.Entries['fleet.users'].Value) 'Seul le releve rattache par GUID compte.'
        Assert-Equal 'En ligne|Non verifie' (@(@($board.Entries['fleet.presence'].Items) | ForEach-Object { [string]$_.Label }) -join '|')
        Assert-Equal '1|3' (@(@($board.Entries['fleet.presence'].Items) | ForEach-Object { [string][int]$_.Value }) -join '|')
        $one = Invoke-L01Fleet -Scope $lyon -Subtree $false
        Assert-Equal 'PC-1,PC-2,PC-4,PC-5' (@(@($one.Machines) | ForEach-Object { [string]$_.name }) -join ',') 'Sans les sous-OU.'
        $all = Invoke-L01Fleet
        Assert-Equal 5 ([int]$all.MachineCount) 'Domaine entier.'
        Assert-Equal 3 @($all.Parents).Count
    } finally { Remove-Item $root -Recurse -Force }
}
Test-Case 'L01 : instantane quotidien, premier du jour garde, retention 400 jours, purges Index et Historique' {
    $root = New-LegacySandbox
    try {
        [void](Invoke-L01Bulk @((New-L01IndexRow 'PC-1' 'OU=Lyon,DC=example,DC=invalid' 'guid-0001')))
        Add-L01Rows "INSERT INTO secret_state(computer_key,computer,checked_at,bitlocker_keys,verdict) VALUES('PC-1','PC-1','2026-10-01T00:00:00Z',1,'presence lue pour l OU');"
        $items = @(
            [pscustomobject]@{ Kind = 'FleetSnapshot'; Row = [pscustomobject]@{ ScopeKey = 'k1'; ScopeDn = 'OU=Lyon,DC=example,DC=invalid'; Day = '2026-01-15'; TakenAt = '2026-01-15T08:00:00Z'; Machines = 1; Figures = '{"Machines":1,"Problems":0}' } }
            [pscustomobject]@{ Kind = 'FleetSnapshot'; Row = [pscustomobject]@{ ScopeKey = 'k1'; ScopeDn = 'OU=Lyon,DC=example,DC=invalid'; Day = '2026-01-15'; TakenAt = '2026-01-15T18:00:00Z'; Machines = 9; Figures = '{"Machines":9,"Problems":9}' } }
            [pscustomobject]@{ Kind = 'FleetSnapshot'; Row = [pscustomobject]@{ ScopeKey = 'k1'; ScopeDn = 'OU=Lyon,DC=example,DC=invalid'; Day = '2020-01-15'; TakenAt = '2020-01-15T08:00:00Z'; Machines = 1; Figures = '{}' } }
        )
        Assert-True (Invoke-LegacyWorker ([pscustomobject]@{ Path = $script:TestDbPath; Items = $items })).Saved
        $snapshots = @(Get-L01Rows 'SELECT * FROM fleet_snapshots;')
        Assert-Equal 1 $snapshots.Count 'Premier instantane du jour seul garde, ancien au-dela de 400 jours supprime.'
        Assert-Equal 1 ([int]$snapshots[0].machines)
        $bad = $false
        try { [void](Invoke-LegacyWorker ([pscustomobject]@{ Path = $script:TestDbPath; Items = @([pscustomobject]@{ Kind = 'FleetSnapshot'; Row = [pscustomobject]@{ ScopeKey = 'k1'; Day = 'hier'; Figures = '{}' } }) })) } catch { $bad = $true }
        Assert-True $bad 'Instantane invalide accepte.'
        $usage = Invoke-UsageWorker
        Assert-Equal 1 @(@(@($usage.Categories | Where-Object Category -eq 'Index')[0].Tables) | Where-Object { $_.Table -eq 'ad_computer_facts' -and $_.Rows -eq 1 }).Count 'Faits mesures avec l index.'
        Assert-Equal 1 @(@(@($usage.Categories | Where-Object Category -eq 'History')[0].Tables) | Where-Object { $_.Table -eq 'fleet_snapshots' -and $_.Rows -eq 1 }).Count 'Instantanes mesures avec l historique.'
        $cutoff = [datetime]::UtcNow.AddMinutes(-1).ToString('o')
        $preview = Invoke-PurgeWorker @('Index','History') $true '' $cutoff
        Assert-Equal 1 @(@($preview.Counts) | Where-Object { $_.Table -eq 'ad_computer_facts' -and $_.Rows -eq 1 }).Count
        Assert-Equal 1 @(@($preview.Counts) | Where-Object { $_.Table -eq 'fleet_snapshots' -and $_.Rows -eq 1 }).Count
        Assert-Equal 0 @(@($preview.Counts) | Where-Object { $_.Table -eq 'secret_state' }).Count 'secret_state cible d une purge.'
        $applied = Invoke-PurgeWorker @('Index','History') $false $preview.Fingerprint $cutoff
        Assert-True $applied.Committed
        Assert-Equal 0 (Get-LegacyCount 'ad_computer_facts'); Assert-Equal 0 (Get-LegacyCount 'fleet_snapshots')
        Assert-Equal 1 (Get-LegacyCount 'secret_state') 'Metadonnees des secrets purgees avec l index.'
    } finally { Remove-Item $root -Recurse -Force }
}
Test-Case 'L01 : presence BitLocker en lot ecrite dans secret_state, lue par FleetStats, jamais une cle' {
    $root = New-LegacySandbox
    try {
        $lyon = 'OU=Lyon,DC=example,DC=invalid'
        [void](Invoke-L01Bulk @((New-L01IndexRow 'PC-1' $lyon 'guid-0001'), (New-L01IndexRow 'PC-2' $lyon 'guid-0002')))
        $rows = @([pscustomobject]@{ Computer = 'PC-1'; BitLockerKeys = 2; BitLockerLast = '2026-09-01T00:00:00Z'; LapsScheme = ''; LapsExpiry = ''; Verdict = 'presence lue pour l OU'; At = [datetime]::UtcNow.ToString('o') }, [pscustomobject]@{ Computer = 'PC-2'; BitLockerKeys = 0; BitLockerLast = ''; LapsScheme = ''; LapsExpiry = ''; Verdict = 'aucune cle visible avec ce compte'; At = [datetime]::UtcNow.ToString('o') })
        Assert-True (Invoke-LegacyWorker ([pscustomobject]@{ Path = $script:TestDbPath; Items = @([pscustomobject]@{ Kind = 'SecretMeta'; Row = [pscustomobject]@{ Rows = $rows } }) })).Saved
        Assert-Equal 2 (Get-LegacyCount 'secret_state')
        $result = Invoke-L01Fleet -Scope $lyon
        Assert-Equal 2 ([int]$result.Coverage.BitLockerRead)
        $board = Get-DomeniaFleetBoardData -Result $result -Scope $lyon -Now ([datetime]::Now)
        Assert-Equal '1' ([string]$board.Entries['fleet.bitlocker'].Value) 'Un poste sans cle visible.'
        Assert-True ([string]$board.Entries['fleet.bitlocker'].Detail -like '2 postes analysés sur 2, le *') ([string]$board.Entries['fleet.bitlocker'].Detail)
        $secrets = (@(Get-L01Rows 'SELECT * FROM secret_state;') | ConvertTo-Json -Compress)
        Assert-False ($secrets -match '\d{6}-\d{6}-\d{6}') 'Valeur de cle ecrite.'
    } finally { Remove-Item $root -Recurse -Force }
}
Test-Case 'L01 : lecture LAPS seule = BitLocker non lu ; presence d OU sans objet visible ne remplace jamais des cles lues' {
    $root = New-LegacySandbox
    try {
        $lyon = 'OU=Lyon,DC=example,DC=invalid'
        [void](Invoke-L01Bulk @((New-L01IndexRow 'PC-A' $lyon 'guid-000a'), (New-L01IndexRow 'PC-B' $lyon 'guid-000b'), (New-L01IndexRow 'PC-C' $lyon 'guid-000c')))
        $now = [datetime]::UtcNow.ToString('o')
        # LAPS read alone on PC-A (Save-DomeniaSecretIndexEntry sends BitLockerKeys -1): BitLocker stays unknown.
        $laps = [pscustomobject]@{ Computer = 'PC-A'; BitLockerKeys = -1; BitLockerLast = ''; LapsScheme = 'Windows'; LapsExpiry = '2026-12-01T00:00:00Z'; Verdict = 'mot de passe LAPS lisible'; At = $now }
        Assert-True (Invoke-LegacyWorker ([pscustomobject]@{ Path = $script:TestDbPath; Items = @([pscustomobject]@{ Kind = 'SecretMeta'; Row = $laps }) })).Saved
        Assert-Equal -1 ([int]@(Get-L01Rows "SELECT bitlocker_keys FROM secret_state WHERE computer_key='PC-A';")[0].bitlocker_keys) 'LAPS seul ecrit 0 cle BitLocker.'
        $result = Invoke-L01Fleet -Scope $lyon
        Assert-Equal 0 ([int]$result.Coverage.BitLockerRead) 'Lecture LAPS seule comptee comme BitLocker lu.'
        Assert-Equal 0 @(@($result.Groups) | Where-Object { [string]$_.bk -ne 'U' }).Count 'Poste LAPS seul hors U.'
        $board = Get-DomeniaFleetBoardData -Result $result -Scope $lyon -Now ([datetime]::Now)
        Assert-Equal 'Non lu' ([string]$board.Entries['fleet.bitlocker'].Value)
        Assert-Equal 0 @(@($board.Attention) | Where-Object { [string]$_.Point -eq 'bitlocker.none' }).Count 'Poste sans cle signale sans lecture BitLocker.'
        # Two keys read on PC-B one by one, then a read of the OU that sees nothing: PC-B keeps its two keys.
        $keyed = [pscustomobject]@{ Computer = 'PC-B'; BitLockerKeys = 2; BitLockerLast = '2026-09-01T00:00:00Z'; LapsScheme = ''; LapsExpiry = ''; Verdict = '2 cle(s) visible(s)'; At = $now }
        [void](Invoke-LegacyWorker ([pscustomobject]@{ Path = $script:TestDbPath; Items = @([pscustomobject]@{ Kind = 'SecretMeta'; Row = $keyed }) }))
        $blind = @(foreach ($name in @('PC-A','PC-B','PC-C')) { [pscustomobject]@{ Computer = $name; BitLockerKeys = 0; BitLockerLast = ''; LapsScheme = ''; LapsExpiry = ''; Verdict = 'aucune cle visible avec ce compte'; At = $now; KeepKnown = $true } })
        Assert-True (Invoke-LegacyWorker ([pscustomobject]@{ Path = $script:TestDbPath; Items = @([pscustomobject]@{ Kind = 'SecretMeta'; Row = [pscustomobject]@{ Rows = $blind } }) })).Saved
        Assert-Equal 2 ([int]@(Get-L01Rows "SELECT bitlocker_keys FROM secret_state WHERE computer_key='PC-B';")[0].bitlocker_keys) 'Cles lues poste par poste remplacees par 0.'
        Assert-Equal 'Windows' ([string]@(Get-L01Rows "SELECT laps_scheme FROM secret_state WHERE computer_key='PC-A';")[0].laps_scheme) 'Metadonnees LAPS perdues.'
        Assert-Equal 0 ([int]@(Get-L01Rows "SELECT bitlocker_keys FROM secret_state WHERE computer_key='PC-C';")[0].bitlocker_keys)
        # A read that sees keys elsewhere writes the zero of an unseen workstation (KeepKnown false).
        $seen = [pscustomobject]@{ Computer = 'PC-B'; BitLockerKeys = 0; BitLockerLast = ''; LapsScheme = ''; LapsExpiry = ''; Verdict = 'aucune cle visible avec ce compte'; At = $now; KeepKnown = $false }
        [void](Invoke-LegacyWorker ([pscustomobject]@{ Path = $script:TestDbPath; Items = @([pscustomobject]@{ Kind = 'SecretMeta'; Row = [pscustomobject]@{ Rows = @($seen) } }) }))
        Assert-Equal 0 ([int]@(Get-L01Rows "SELECT bitlocker_keys FROM secret_state WHERE computer_key='PC-B';")[0].bitlocker_keys) 'Cle supprimee de l annuaire encore comptee.'
    } finally { Remove-Item $root -Recurse -Force }
}
Test-Case 'L01 : releves d un poste hors OU lus seuls (ObservationsOnly), groupes distincts par la casse' {
    $root = New-LegacySandbox
    try {
        $lyon = 'OU=Lyon,DC=example,DC=invalid'
        [void](Invoke-L01Bulk @((New-L01IndexRow 'PC-1' $lyon 'guid-0001' -Os 'Windows 11 Entreprise'), (New-L01IndexRow 'PC-2' $lyon 'guid-0002' -Os 'WINDOWS 11 Entreprise'), (New-L01IndexRow 'PC-3' 'OU=Paris,DC=example,DC=invalid' 'guid-0003')))
        [void](Save-L01Observation ('CN=PC-1,' + $lyon) 'guid-0001' 'PC-1' 1 'EX\alice')
        [void](Save-L01Observation 'CN=PC-3,OU=Paris,DC=example,DC=invalid' 'guid-0003' 'PC-3' 1 'EX\carl')
        $Payload = [pscustomobject]@{ Action = 'FleetStats'; ModuleRoot = $modules; Path = $script:TestDbPath; BusyTimeoutMs = 250; Scope = ''; Subtree = $true; Plan = (Get-DomeniaFleetQueryPlan -Now ([datetime]::Now)); Keys = @('cn=pc-3,ou=paris,dc=example,dc=invalid'); ObservationsOnly = $true }
        $only = & ([scriptblock]::Create((Get-DomeniaLocalIndexReadWorkerCode)))
        Assert-Equal 0 @($only.Groups).Count 'Agregats calcules pour une lecture de releves.'
        Assert-Equal 0 @($only.Machines).Count
        Assert-Equal 'cn=pc-3,ou=paris,dc=example,dc=invalid' (@(@($only.Presence) | ForEach-Object { [string]$_.object_key }) -join '|') 'Releve du seul poste demande.'
        Assert-False ([bool]@($only.Presence)[0].in_scope)
        # Two systems that differ by case only: two groups, each workstation in its own (GROUP BY is case sensitive).
        $result = Invoke-L01Fleet -Scope $lyon
        $gids = @(@($result.Machines) | ForEach-Object { [string]$_.gid })
        Assert-Equal 2 @($result.Groups).Count ('Groupes : ' + @($result.Groups).Count)
        Assert-Equal 2 @($gids | Sort-Object -Unique).Count ('Postes rattaches au meme groupe : ' + ($gids -join ','))
        foreach ($gid in $gids) { Assert-True ([bool]$gid) 'Poste sans groupe.' }
    } finally { Remove-Item $root -Recurse -Force }
}
Test-Case 'L01 : search_key sans Extra repare une seule fois par base au demarrage (CO-26)' {
    $root = New-LegacySandbox
    try {
        # A base written by RC1.13.0 has no repair marker: rows written by its single-row updates lack the extra field.
        Add-L01Rows "DELETE FROM sync_state WHERE scope='repair:search_key_extra';"
        Add-L01Rows "INSERT INTO ad_objects(object_key,object_guid,object_type,name,extra,search_key,distinguished_name) VALUES('guid-9','guid-9','Machine','PC-9','Windows 10 Pro / Lyon','pc-9 pc-9','CN=PC-9,DC=example,DC=invalid'),('guid-8','guid-8','Machine','PC-8','','pc-8','CN=PC-8,DC=example,DC=invalid'),('guid-7','guid-7','Machine','PC-7','École / Étage 2','pc-7 école / étage 2','CN=PC-7,DC=example,DC=invalid');"
        $script:DomeniaDatabaseReady = $false
        Assert-True (Initialize-DomeniaDatabase)
        $key = [string]@(Get-L01Rows "SELECT search_key FROM ad_objects WHERE name='PC-9';")[0].search_key
        Assert-True ($key -like '*windows 10 pro / lyon*') ('search_key non repare : ' + $key)
        Assert-Equal 'pc-8' ([string]@(Get-L01Rows "SELECT search_key FROM ad_objects WHERE name='PC-8';")[0].search_key) 'Ligne sans Extra modifiee.'
        Assert-Equal 1 @(Get-L01Rows "SELECT scope FROM sync_state WHERE scope='repair:search_key_extra';").Count 'Marqueur de reparation absent.'
        # Later starts never scan again: a row still lacking the extra field is left to the next index write.
        Add-L01Rows "INSERT INTO ad_objects(object_key,object_guid,object_type,name,extra,search_key,distinguished_name) VALUES('guid-6','guid-6','Machine','PC-6','Windows 11 Pro / Paris','pc-6','CN=PC-6,DC=example,DC=invalid');"
        $accented = [string]@(Get-L01Rows "SELECT search_key FROM ad_objects WHERE name='PC-7';")[0].search_key
        $script:DomeniaDatabaseReady = $false
        Assert-True (Initialize-DomeniaDatabase)
        Assert-Equal $key ([string]@(Get-L01Rows "SELECT search_key FROM ad_objects WHERE name='PC-9';")[0].search_key) 'Reparation repetee.'
        Assert-Equal 'pc-6' ([string]@(Get-L01Rows "SELECT search_key FROM ad_objects WHERE name='PC-6';")[0].search_key) 'Parcours de reparation relance a un demarrage suivant.'
        Assert-Equal $accented ([string]@(Get-L01Rows "SELECT search_key FROM ad_objects WHERE name='PC-7';")[0].search_key) 'Majuscule accentuee recopiee a chaque demarrage.'
    } finally { Remove-Item $root -Recurse -Force }
}
Test-Case 'L01 : IndexBuild et BitLockerPresence ne demandent aucun attribut sensible ; BitLockerPresence refusee a la racine' {
    $script:L01Searches = New-Object System.Collections.ArrayList
    function New-WSearcher {
        param($Context,[string]$BaseDn,[string]$Filter,[string[]]$Properties,[string]$Scope = 'OneLevel',[int]$Limit = 0)
        [void]$script:L01Searches.Add([pscustomobject]@{ Base = $BaseDn; Filter = $Filter; Properties = @($Properties); Scope = $Scope })
        $searcher = [pscustomobject]@{ PageSize = 0; CacheResults = $true; ServerTimeLimit = $null; ClientTimeout = $null; Filter = $Filter }
        $searcher | Add-Member -MemberType ScriptMethod -Name FindAll -Value { if ($this.Filter -like '*attributeSchema*' -or $this.Filter -like '*classSchema*') { return ,@([pscustomobject]@{ Properties = @{} }) }; return ,@() }
        $searcher | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
        return $searcher
    }
    function New-WRootDse { param($Context) $r = [pscustomobject]@{ Properties = @{ highestCommittedUSN = @{ Value = 5 }; schemaNamingContext = @{ Value = 'CN=Schema,CN=Configuration,DC=example,DC=invalid' } } }; $r | Add-Member -MemberType ScriptMethod -Name RefreshCache -Value { param($Names) }; return $r }
    function Get-WDirectoryVersionSource { param($Context) return '' }
    function Get-WPropFirst { param($Props,[string]$Name,$Default = '') return $Default }
    function Get-DomeniaStructuredError { param($ErrorRecord,$Phase,$Provider,$Target) return [pscustomobject]@{ Kind = 'ReadFailed'; NativeCode = ''; Code = '' } }
    $Context = [pscustomobject]@{ BaseDn = 'DC=example,DC=invalid'; Server = 'dc.example.invalid'; OperationId = 'IndexBuild'; PageSize = 100 }
    $Payload = [pscustomobject]@{ MaxObjects = 1000; BudgetMs = 30000; LastUsn = 0; LastServer = ''; Since = ''; ComputerFirst = $true }
    $index = & ([scriptblock]::Create((Get-DomeniaIndexWorkerCode)))
    Assert-Equal 'Present' ([string]$index.LapsSchema) 'Presence des attributs LAPS dans le schema non lue.'
    $computer = @($script:L01Searches | Where-Object { $_.Filter -eq '(objectCategory=computer)' })[0]
    foreach ($name in @('operatingSystemVersion','whenCreated','pwdLastSet','ms-Mcs-AdmPwdExpirationTime','msLAPS-PasswordExpirationTime')) { Assert-True (@($computer.Properties) -contains $name) ('Attribut non lu : ' + $name) }
    foreach ($search in @($script:L01Searches)) { foreach ($name in @($search.Properties)) { Assert-False (Test-DomeniaSensitiveAttributeName -Name $name) ('Attribut sensible demande par IndexBuild : ' + $name) } }
    Assert-False ((Get-DomeniaIndexWorkerCode) -match '(?i)msLAPS-Password[^E]|ms-Mcs-AdmPwd[^E]|unicodePwd') 'Mot de passe LAPS demande.'
    # Index.MaxObjects is honoured up to the worker ceiling. It used to be clamped to 200 000 whatever the
    # configuration asked for, which left a domain larger than that unable to ever complete its local base.
    Assert-Equal 1000 ([int]$index.LimitMaxObjects) ('Plafond rendu par la passe : ' + [string]$index.LimitMaxObjects)
    $Payload = [pscustomobject]@{ MaxObjects = 300000; BudgetMs = 30000; LastUsn = 0; LastServer = ''; Since = ''; ComputerFirst = $true }
    $above = & ([scriptblock]::Create((Get-DomeniaIndexWorkerCode)))
    Assert-Equal 300000 ([int]$above.LimitMaxObjects) ('Index.MaxObjects au-dela de 200 000 encore ecrase : ' + [string]$above.LimitMaxObjects)
    $Payload = [pscustomobject]@{ MaxObjects = 9000000; BudgetMs = 30000; LastUsn = 0; LastServer = ''; Since = ''; ComputerFirst = $true }
    $ceiling = & ([scriptblock]::Create((Get-DomeniaIndexWorkerCode)))
    Assert-Equal 5000000 ([int]$ceiling.LimitMaxObjects) ('Plafond d Index.MaxObjects non applique : ' + [string]$ceiling.LimitMaxObjects)
    $script:L01Searches.Clear()
    $Context = [pscustomobject]@{ BaseDn = 'DC=example,DC=invalid'; Server = 'dc.example.invalid'; OperationId = 'BitLockerPresence'; PageSize = 100 }
    $Payload = [pscustomobject]@{ DN = 'DC=example,DC=invalid' }
    $refused = ''
    try { [void](& ([scriptblock]::Create((Get-DomeniaBitLockerPresenceWorkerCode)))) } catch { $refused = $_.Exception.Message }
    Assert-True ($refused -like '*racine du domaine*') ('Racine du domaine acceptee : ' + $refused)
    Assert-Equal 0 $script:L01Searches.Count 'Recherche envoyee a la racine du domaine.'
    $Payload = [pscustomobject]@{ DN = 'OU=Lyon,DC=example,DC=invalid' }
    $presence = & ([scriptblock]::Create((Get-DomeniaBitLockerPresenceWorkerCode)))
    Assert-True ([bool]$presence.Success) ([string]$presence.ErrorMessage)
    Assert-True ([bool]$presence.ClassPresent)
    $ou = @($script:L01Searches | Where-Object { $_.Filter -eq '(objectClass=msFVE-RecoveryInformation)' })[0]
    Assert-Equal 'OU=Lyon,DC=example,DC=invalid' ([string]$ou.Base) 'Recherche hors de l OU affichee.'
    Assert-Equal 'Subtree' ([string]$ou.Scope)
    Assert-Equal 'name,distinguishedName,whenCreated' (@($ou.Properties) -join ',')
    foreach ($search in @($script:L01Searches)) { foreach ($name in @($search.Properties)) { Assert-False (Test-DomeniaSensitiveAttributeName -Name $name) ('Attribut sensible demande par BitLockerPresence : ' + $name) } }
    Assert-False ((Get-DomeniaBitLockerPresenceWorkerCode) -match '(?i)msFVE-RecoveryPassword|msFVE-KeyPackage') 'Cle BitLocker demandee.'
    $Payload = [pscustomobject]@{ DN = 'OU=Ailleurs,DC=autre,DC=invalid' }
    $outside = ''
    try { [void](& ([scriptblock]::Create((Get-DomeniaBitLockerPresenceWorkerCode)))) } catch { $outside = $_.Exception.Message }
    Assert-True ($outside -like '*hors du domaine*') ('OU hors domaine acceptee : ' + $outside)
}
Test-Case 'L01 : passe par OU — IndexOuList rend les OU enfants, IndexBuild relit une OU en Subtree et la racine en OneLevel' {
    $script:L01Searches = New-Object System.Collections.ArrayList
    function New-WSearcher {
        param($Context,[string]$BaseDn,[string]$Filter,[string[]]$Properties,[string]$Scope = 'OneLevel',[int]$Limit = 0)
        [void]$script:L01Searches.Add([pscustomobject]@{ Base = $BaseDn; Filter = $Filter; Properties = @($Properties); Scope = $Scope })
        $rows = @()
        if ($Filter -like '*organizationalUnit*') { $rows = $script:L01OuRows }
        $searcher = [pscustomobject]@{ PageSize = 0; CacheResults = $true; ServerTimeLimit = $null; ClientTimeout = $null; Filter = $Filter; Rows = $rows }
        $searcher | Add-Member -MemberType ScriptMethod -Name FindAll -Value { if ($this.Filter -like '*attributeSchema*' -or $this.Filter -like '*classSchema*') { return ,@([pscustomobject]@{ Properties = @{} }) }; if (@($this.Rows).Count -gt 0) { return ,@($this.Rows) }; return ,@() }
        $searcher | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
        return $searcher
    }
    function New-WRootDse { param($Context) $r = [pscustomobject]@{ Properties = @{ highestCommittedUSN = @{ Value = 5 }; schemaNamingContext = @{ Value = '' } } }; $r | Add-Member -MemberType ScriptMethod -Name RefreshCache -Value { param($Names) }; return $r }
    function Get-WDirectoryVersionSource { param($Context) return '' }
    function Get-WPropFirst { param($Props,[string]$Name,$Default = '') if ($null -ne $Props -and $Props.ContainsKey($Name)) { return $Props[$Name] }; return $Default }
    function Get-DomeniaStructuredError { param($ErrorRecord,$Phase,$Provider,$Target) return [pscustomobject]@{ Kind = 'ReadFailed'; NativeCode = ''; Code = '' } }
    # La racine elle-meme peut remonter dans une lecture OneLevel mal filtree : elle ne doit jamais etre relue comme une OU.
    $script:L01OuRows = @(
        [pscustomobject]@{ Properties = @{ name = 'Postes'; distinguishedName = 'OU=Postes,DC=example,DC=invalid' } },
        [pscustomobject]@{ Properties = @{ name = 'Comptes'; distinguishedName = 'OU=Comptes,DC=example,DC=invalid' } },
        [pscustomobject]@{ Properties = @{ name = 'Ordinateurs'; distinguishedName = 'CN=Computers,DC=example,DC=invalid' } },
        [pscustomobject]@{ Properties = @{ name = 'example'; distinguishedName = 'DC=example,DC=invalid' } }
    )
    $Context = [pscustomobject]@{ BaseDn = 'DC=example,DC=invalid'; Server = 'dc.example.invalid'; OperationId = 'IndexOuList'; PageSize = 100 }
    $Payload = [pscustomobject]@{ SearchBase = '' }
    $list = & ([scriptblock]::Create((Get-DomeniaIndexOuListWorkerCode)))
    $ouSearch = @($script:L01Searches | Where-Object { $_.Filter -like '*organizationalUnit*' })[0]
    Assert-Equal 'OneLevel' ([string]$ouSearch.Scope) 'La liste des OU ne lit pas un seul niveau sous la racine.'
    Assert-Equal 'DC=example,DC=invalid' ([string]$ouSearch.Base) 'La liste des OU ne part pas de la racine du domaine.'
    Assert-Equal 3 (@($list.Rows).Count) ('OU rendues : ' + ((@($list.Rows) | ForEach-Object { [string]$_.DN }) -join ' | '))
    Assert-Equal 'CN=Computers,DC=example,DC=invalid' ([string](@($list.Rows)[0].DN)) ('OU rendues dans le desordre : ' + ((@($list.Rows) | ForEach-Object { [string]$_.DN }) -join ' | '))
    # Chaque OU est ensuite relue en Subtree ; la racine, elle, ne se lit qu'a un seul niveau.
    $Context = [pscustomobject]@{ BaseDn = 'DC=example,DC=invalid'; Server = 'dc.example.invalid'; OperationId = 'IndexBuild'; PageSize = 100 }
    $script:L01Searches.Clear()
    $Payload = [pscustomobject]@{ MaxObjects = 1000; BudgetMs = 30000; LastUsn = 0; LastServer = ''; Since = ''; ComputerFirst = $true; SearchBase = 'OU=Postes,DC=example,DC=invalid' }
    [void](& ([scriptblock]::Create((Get-DomeniaIndexWorkerCode))))
    $ouPass = @($script:L01Searches | Where-Object { $_.Filter -eq '(objectCategory=computer)' })[0]
    Assert-Equal 'Subtree' ([string]$ouPass.Scope) 'La passe d une OU ne relit plus tout son sous-arbre.'
    Assert-Equal 'OU=Postes,DC=example,DC=invalid' ([string]$ouPass.Base) 'La passe ne lit pas la OU demandee.'
    $script:L01Searches.Clear()
    $Payload = [pscustomobject]@{ MaxObjects = 1000; BudgetMs = 30000; LastUsn = 0; LastServer = ''; Since = ''; ComputerFirst = $true; SearchBase = 'DC=example,DC=invalid'; SearchScope = 'OneLevel' }
    [void](& ([scriptblock]::Create((Get-DomeniaIndexWorkerCode))))
    $rootPass = @($script:L01Searches | Where-Object { $_.Filter -eq '(objectCategory=computer)' })[0]
    Assert-Equal 'OneLevel' ([string]$rootPass.Scope) 'Les objets poses sur la racine du domaine ne sont pas relus a un seul niveau.'
    $script:L01Searches.Clear()
    $Payload = [pscustomobject]@{ MaxObjects = 1000; BudgetMs = 30000; LastUsn = 0; LastServer = ''; Since = ''; ComputerFirst = $true; SearchBase = 'OU=Postes,DC=example,DC=invalid'; SearchScope = 'Base' }
    [void](& ([scriptblock]::Create((Get-DomeniaIndexWorkerCode))))
    $guardedPass = @($script:L01Searches | Where-Object { $_.Filter -eq '(objectCategory=computer)' })[0]
    Assert-Equal 'Subtree' ([string]$guardedPass.Scope) 'Une portee inconnue nest pas ramenee a Subtree.'
}

Test-Case 'L01 : vue du parc sur 5 000 postes, agregats SQL et calcul des regles mesures' {
    $root = New-LegacySandbox
    try {
        Add-L01Rows @"
BEGIN IMMEDIATE;
WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM c WHERE n<5000)
INSERT INTO ad_objects(object_key,object_guid,object_type,name,login,extra,state,distinguished_name,last_logon,search_key)
 SELECT 'guid-'||n,'guid-'||n,'Machine','PC-'||n,'PC-'||n,CASE WHEN n%7=0 THEN 'Windows 10 Professionnel / Lyon' ELSE 'Windows 11 Entreprise / Lyon' END,CASE WHEN n%97=0 THEN 'Desactive' ELSE 'Actif' END,
 'CN=PC-'||n||',OU=Site'||(n%25)||',OU=Parc,DC=example,DC=invalid',printf('%02d/%02d/2026 08:00:00',1+(n%28),1+(n%9)),'pc-'||n FROM c;
WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM c WHERE n<5000)
INSERT INTO ad_computer_facts(object_guid,object_key,os_version,when_created,pwd_last_set,laps_kind,laps_expiry,read_at)
 SELECT 'guid-'||n,'guid-'||n,CASE WHEN n%7=0 THEN '10.0 (19045)' WHEN n%3=0 THEN '10.0 (22631)' ELSE '10.0 (26100)' END,'2025-01-01T00:00:00Z',printf('2026-%02d-01T00:00:00Z',1+(n%9)),CASE WHEN n%5=0 THEN 'None' ELSE 'Windows' END,'2026-12-01T00:00:00Z','2026-10-08T08:00:00.0000000Z' FROM c;
INSERT OR REPLACE INTO sync_state(scope,server,base_dn,highest_usn,last_sync,item_count,details) VALUES('directory','dc','DC=example,DC=invalid',1,'2026-10-08T08:00:00.0000000Z',5000,'test');
COMMIT;
"@
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-L01Fleet -Scope 'OU=Parc,DC=example,DC=invalid'
        $workerMs = $watch.ElapsedMilliseconds
        $lifecycle = [IO.File]::ReadAllText((Join-Path $modules 'Domenia-WindowsLifecycle.json'),[Text.Encoding]::UTF8) | ConvertFrom-Json
        [void](Get-DomeniaFleetBoardData -Result $result -Scope 'OU=Parc,DC=example,DC=invalid' -Now ([datetime]::Now) -Lifecycle $lifecycle)
        $watch.Restart()
        $board = Get-DomeniaFleetBoardData -Result $result -Scope 'OU=Parc,DC=example,DC=invalid' -Now ([datetime]::Now) -Lifecycle $lifecycle
        $modelMs = $watch.ElapsedMilliseconds
        Assert-Equal '5000' ([string]$board.Entries['fleet.machines'].Value) 'La tuile exclurait encore les desactives.'
        Assert-Equal ('dont 4949 actifs et 51 désactivés · dans l OU et ses sous-OU') ([string]$board.Entries['fleet.machines'].Detail)
        Assert-True (@($result.Groups).Count -lt 400) ('Trop de groupes : ' + @($result.Groups).Count)
        $script:CaseDetail = 'Worker FleetStats ' + $workerMs + ' ms ; regles sur les agregats ' + $modelMs + ' ms ; ' + @($result.Groups).Count + ' groupes pour 5000 postes.'
        Assert-True ($modelMs -lt 120) ('Calcul des regles trop long : ' + $modelMs + ' ms')
    } finally { Remove-Item $root -Recurse -Force }
}

$passed = @($checks | Where-Object { $_.Status -eq 'Passed' }).Count
$failed = @($checks | Where-Object { $_.Status -eq 'Failed' }).Count
if (-not $ReportPath) { $ReportPath = Join-Path ([IO.Path]::GetTempPath()) ('Domenia-wiring-cache-' + [guid]::NewGuid().ToString('N') + '.json') }
$report = [ordered]@{
    Kind='WiringCache'
    PowerShell=$PSVersionTable.PSVersion.ToString()
    Host=$PSVersionTable.PSVersion.ToString()
    NativeWindowsPowerShell51=$native
    Wpf=$true
    MockedNetwork=$true
    LiveAD=$false
    Points=@('D029','D118','D030','D023','D025','D028','D115','D113','D024','D026','D027','D021','D022','L01')
    Passed=$passed
    Failed=$failed
    Complete=($failed -eq 0 -and $passed -gt 0)
    Tests=$checks.ToArray()
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report | ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
if (-not $Quiet) {
    Write-Host ("$passed reussis, $failed en echec. Rapport : " + $ReportPath)
    $checks | Where-Object { $_.Status -eq 'Failed' } | ForEach-Object { Write-Host ('  ECHEC ' + $_.Name + ' : ' + $_.Detail) }
}
if ($failed -gt 0) { exit 1 }
exit 0
