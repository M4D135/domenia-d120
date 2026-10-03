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
foreach ($file in @('Domenia-Common.Model.ps1','Domenia-Cache.Model.ps1')) {
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
. ([scriptblock]::Create((Get-FunctionTextFromFile $storageUi 'Request-DomeniaLinkPersistence')))
$script:QueueOriginal = (Get-Item function:Queue-DomeniaLinkChanges).ScriptBlock
$script:RequestOriginal = (Get-Item function:Request-DomeniaLinkPersistence).ScriptBlock
. ([scriptblock]::Create((Get-FunctionTextFromFile $liveUi 'Merge-DomeniaLiveLinkMemory')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $liveModel 'Get-DomeniaLiveCacheCode')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $selectionUi 'Get-DomeniaObjectCacheKey')))
. ([scriptblock]::Create((Get-FunctionTextFromFile $continuityUi 'Invoke-DomeniaObjectChanges')))
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

Test-Case 'D028 : Merge-DomeniaLiveLinkMemory (repli) demande la persistance a la fin' {
    Set-Item function:script:Request-DomeniaLinkPersistence { $script:RequestCalls++ }
    $script:FeatureFlagValue = $false
    $obs = [pscustomobject]@{
        Outcome='Observed'; Computer='PC-2.example.invalid'; LinkUser='User2'; UserDn='CN=User2,OU=Users,DC=example,DC=invalid'
        Guid='33333333-3333-3333-3333-333333333333'; UserGuid='44444444-4444-4444-4444-444444444444'
        ObservedUtc='2026-01-01T10:00:00Z'
    }
    Merge-DomeniaLiveLinkMemory $obs
    Assert-Equal 1 $script:RequestCalls
    Assert-Equal 1 @($script:UserMachineLinks).Count
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

Test-Case 'D024 : Set-DomeniaResultRowPresence stocke UpdatedUtc et file UTC' {
    function Queue-DomeniaMetadata { param($Kind,$Row,$Key='') $script:QueueSpyRow=$Row; return $true }
    function ConvertTo-DomeniaGridPresenceState { param($State) return 'En ligne' }
    function Apply-DomeniaPresenceFilter { }
    function Get-DomeniaControl { return $null }
    function Set-DomeniaLiveRowValue { param($Row,$Name,$Value) }

    $script:BranchObjects=@([pscustomobject]@{DN='CN=PC1,DC=example,DC=invalid';Presence='Inconnu'})
    $script:CurrentPresenceFilter='Tous'
    $script:PresenceCache=@{}
    Set-DomeniaResultRowPresence -Dn 'CN=PC1,DC=example,DC=invalid' -State 'En ligne' -Target 'PC1'
    $entry=$script:PresenceCache['cn=pc1,dc=example,dc=invalid']
    Assert-True ($null -ne $entry.PSObject.Properties['UpdatedUtc'])
    Assert-True ($entry.UpdatedUtc.Kind -eq [DateTimeKind]::Utc)
    Assert-True ($script:QueueSpyRow.At -match 'Z$')
}

Test-Case 'D024 : Show-AdObjectResult depuis cache utilise Created comme LoadedAt' {
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

    $createdUtc=[datetime]::UtcNow.AddMinutes(-10)
    $script:ShowingCachedObject=$true
    $script:ShowingCachedObjectCreated=$createdUtc.ToLocalTime()
    $script:SelectedObject=$null
    $script:SelectedObjectGeneration=0
    $script:RenderingObjectWithoutProbes=$false
    $script:AsyncJobs=@{}
    $script:ObservedTimeCalls=0
    $script:FreshnessCalls=0
    $result=[pscustomobject]@{Properties=@{name='PC1'};Live=$false}
    Show-AdObjectResult -Result $result -Dn 'CN=PC1,DC=x' -Type 'Machine' -NoNavigate
    Assert-True ($null -ne $script:SelectedObject)
    Assert-True ($script:ObservedTimeCalls -gt 0)
    Assert-True ($script:FreshnessCalls -gt 0)
    $delta=[Math]::Abs((([datetime]$script:SelectedObject.LoadedAt) - $createdUtc.ToLocalTime()).TotalMinutes)
    Assert-True ($delta -lt 1) ('LoadedAt=' + [string]$script:SelectedObject.LoadedAt)
}

Test-Case 'D024 : LiveCache ecrit checked_utc depuis UserCheckedUtc' {
    $code = Get-DomeniaLiveCacheCode
    Assert-True ($code -match '\$checkedForRetention=\[string\]\$observation\.UserCheckedUtc')
    Assert-True ($code -match '\$checkedForRetention,\$json')
}

Test-Case 'D024 : Complete-DomeniaLiveProbe appelle Set-DomeniaObservationTime et Get-DomeniaRecordFreshness' {
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
    function Set-DomeniaObservationTime { param($Object,$Nature,$ObservedUtc,[switch]$Succeeded) $script:ObservedTimeCalls++ }
    function Get-DomeniaRecordFreshness { param($Object,$Nature) $script:FreshnessCalls++; return [pscustomobject]@{Nature=$Nature;State='Fresh';AgeSeconds=0;Label=''} }

    $script:ObservedTimeCalls=0
    $script:FreshnessCalls=0
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
    $result=[pscustomobject]@{Outcome='Observed';Key='k';Computer='PC1';Guid='g'}
    $state=[pscustomobject]@{Key='k';Computer='PC1';Guid='g';Identity='id';Epoch=[long]1;Generation=1;RequestId='r'}
    Complete-DomeniaLiveProbe -Result $result -State $state
    Assert-True ($script:ObservedTimeCalls -ge 2)
    Assert-True ($script:FreshnessCalls -ge 2)
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
    function Get-DomeniaEffectiveWorkerResult { param($Result,$RequiredProperties) return $Result }
    function Save-DomeniaIndex { param($Rows,$Server,$BaseDn,$HighestUsn,$TotalCount,$InvocationId) $script:SaveIndexCalls++; return $true }
    function Update-DomeniaIndexDatabaseRows { param($Rows,$Server,$BaseDn,$HighestUsn,$TotalCount,$InvocationId) $script:UpdateIndexCalls++; return $true }
    function Load-DomeniaIndexMetadata { $script:IndexDbCount=1; return 1 }
    function Merge-DomeniaIndexRows { param($Existing,$Changed) return [pscustomobject]@{Total=1;Updated=1;Added=0} }
    function Set-DomeniaControlText { param($Name,$Text) return $true }
    function Set-Status { param($Text) }
    function Add-DomeniaUiLog { param($Area,$Text) }
    function Register-DomeniaOperationSample { param($Operation,$Mode,$ItemCount,$DurationMs,$BytesEstimated,$AdQueries,$SuccessCount) }
    function Update-DomeniaIndexStats { }

    $script:SaveIndexCalls=0
    $script:UpdateIndexCalls=0
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

try { Stop-TestTimers } catch { }
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
    Points=@('D025','D028','D115','D113','D024','D026','D027','D021','D022')
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
