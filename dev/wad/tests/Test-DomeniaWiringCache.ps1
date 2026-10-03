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
    Points=@('D025','D028')
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
