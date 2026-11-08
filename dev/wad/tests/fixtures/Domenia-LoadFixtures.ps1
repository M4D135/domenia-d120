# Points 122 and 125: generated load fixtures and stability rules for wad/tests/Test-DomeniaLoadStability.ps1.
# Test-only file: dot-sourced by wad/tests, never loaded by the application. No directory, no network, no user data:
# every computer is derived from its index (PC-000001..., domain example.invalid), so two runs with the same parameters
# build identical fixtures and their timings can be compared from one run to the next.
#
# The number of computers alone does not describe a load (point 125). Each profile states its computers, the probe
# families of an observed computer, the heavy computers (many probe families, long software list) and the history
# depth. The generation rules below are shared with Get-DomeniaLoadExpectations: the suite compares what the
# production code returns with counts computed independently from the same rules, never with its own output.
#
# Generation rules (index n, 1-based):
#   disabled          n % 10 = 0                      (state Desactive, never a collection target)
#   observed          active and n % 7 <> 0           (one stored observation)
#   recreated         observed and n % 13 = 0         (observation of a previous GUID: must stay unknown)
#   stale inventory   observed and n % 11 = 0         (inventory 40 days old, beyond the 30-day limit: unknown)
#   heavy             n % 20 = 3, heavy profile only  (HeavyProbes probe families instead of ProbesPerComputer)
#   RAM               4 GB when n % 4 = 0, else 16 GB; model 'Model <n % 12>'; site 'Site<n % 20>'

function Get-DomeniaLoadProfiles {
    # Closed list of the load profiles. 10 000 computers is the minimum, 20 000 the qualification run.
    # Database: the fixture base a profile reads (Base: index and observations; History: Base plus one year of
    # history; Heavy: Base whose heavy computers carry HeavyProbes families).
    param([ValidateSet(10000,20000)][int]$Computers=10000)
    $heavy = 0
    for ($n = 1; $n -le $Computers; $n++) { if (($n % 20) -eq 3) { $heavy++ } }
    return @(
        [pscustomobject]@{ Id='ColdStart'; Label='Démarrage à froid'; Database='Base'; Computers=$Computers; ProbesPerComputer=4; HeavyComputers=0; HeavyProbes=0; SoftwareRows=0; HistoryDays=0; Receipts=0; OperationRuns=0
            Description='Premier accès à la base dans un processus Windows PowerShell neuf. Le cache disque du système nʼest pas vidé.' }
        [pscustomobject]@{ Id='WarmCache'; Label='Cache chaud'; Database='Base'; Computers=$Computers; ProbesPerComputer=4; HeavyComputers=0; HeavyProbes=0; SoftwareRows=0; HistoryDays=0; Receipts=0; OperationRuns=0
            Description='Lectures répétées dans le même processus après un premier accès.' }
        [pscustomobject]@{ Id='LargeHistory'; Label='Historique volumineux'; Database='History'; Computers=$Computers; ProbesPerComputer=4; HeavyComputers=0; HeavyProbes=0; SoftwareRows=0; HistoryDays=400; Receipts=50000; OperationRuns=10000
            Description='Base portant 400 instantanés quotidiens, 50 000 reçus de lots et 10 000 traces dʼopérations.' }
        [pscustomobject]@{ Id='HeavyInventory'; Label='Postes très équipés'; Database='Heavy'; Computers=$Computers; ProbesPerComputer=4; HeavyComputers=$heavy; HeavyProbes=40; SoftwareRows=2500; HistoryDays=0; Receipts=0; OperationRuns=0
            Description='5 % des postes portent 40 familles de sondes ; la synthèse logicielle dʼun poste lit 2 500 logiciels.' }
    )
}

function Get-DomeniaLoadComputer {
    # One generated computer. -HeavyProfile applies the heavy rule (n % 20 = 3).
    param([Parameter(Mandatory=$true)][ValidateRange(1,999999)][int]$Index,[switch]$HeavyProfile)
    $n = $Index
    $name = 'PC-{0:D6}' -f $n
    $site = 'Site{0:D2}' -f ($n % 20)
    $dn = 'CN=' + $name + ',OU=' + $site + ',OU=Postes,DC=example,DC=invalid'
    $active = (($n % 10) -ne 0)
    $observed = ($active -and (($n % 7) -ne 0))
    return [pscustomobject]@{
        Index=$n; Name=$name; Site=$site; Dn=$dn; Key=$dn.ToLowerInvariant()
        Guid=('00000000-0000-4000-8000-{0:D12}' -f $n)
        Active=$active; Observed=$observed
        Recreated=($observed -and (($n % 13) -eq 0))
        StaleInventory=($observed -and (($n % 11) -eq 0))
        Heavy=([bool]$HeavyProfile -and (($n % 20) -eq 3))
        Model=('Model ' + ($n % 12)); RamGB=$(if (($n % 4) -eq 0) { 4 } else { 16 })
        DiskFreeGB=($n % 100); Online=(($n % 3) -ne 0)
    }
}

function Get-DomeniaLoadExpectations {
    # Counts computed from the generation rules only, for the comparisons of the suite.
    # KnownRam: observed computers whose inventory is usable (not recreated, not stale).
    param([ValidateRange(1,999999)][int]$Computers=10000,[switch]$HeavyProfile)
    $active = 0; $observed = 0; $known = 0; $lowRam = 0; $heavy = 0
    $models = @{}
    for ($n = 1; $n -le $Computers; $n++) {
        $c = Get-DomeniaLoadComputer -Index $n -HeavyProfile:$HeavyProfile
        if ($c.Active) { $active++ }
        if ($c.Observed) { $observed++ }
        if ($c.Heavy) { $heavy++ }
        if ($c.Observed -and (-not $c.Recreated) -and (-not $c.StaleInventory)) {
            $known++
            if ($c.RamGB -lt 8) { $lowRam++ }
            if ($models.ContainsKey($c.Model)) { $models[$c.Model] = [int]$models[$c.Model] + 1 } else { $models[$c.Model] = 1 }
        }
    }
    return [pscustomobject]@{ Computers=$Computers; Active=$active; Disabled=($Computers - $active); Observed=$observed; KnownInventory=$known; UnknownInventory=($Computers - $known); LowRam=$lowRam; Heavy=$heavy; Models=$models }
}

function ConvertTo-DomeniaLoadIndexLine {
    # One JSON line of the IndexBulk transfer file read by the storage worker (same fields as Test-DomeniaScale).
    # Every value is generated ASCII without quote nor backslash, so the line is written without a serializer.
    param([Parameter(Mandatory=$true)]$Computer,[Parameter(Mandatory=$true)][string]$At,[Parameter(Mandatory=$true)][datetime]$NowUtc)
    $state = if ($Computer.Active) { 'Actif' } else { 'Desactive' }
    $logon = $NowUtc.AddDays(-([int]$Computer.Index % 200)).ToString('dd/MM/yyyy',[Globalization.CultureInfo]::InvariantCulture)
    return ('{"Guid":"' + $Computer.Guid + '","Type":"Machine","Name":"' + $Computer.Name + '","Login":"' + $Computer.Name + '$","DN":"' + $Computer.Dn +
        '","State":"' + $state + '","Extra":"Windows 11","LastLogon":"' + $logon + '","Facts":true,"OsVersion":"26100","WhenCreated":"' + $At +
        '","PwdLastSet":"' + $At + '","LapsKind":"None","Usn":' + [int]$Computer.Index + '}')
}

function ConvertTo-DomeniaLoadObservationJson {
    # Stored observation of one computer (park_session_cache payload, same shape as Test-DomeniaScale).
    # ProbeIds: probe identifiers of the catalogue; each probe holds one row '42'. A recreated computer keeps the
    # GUID of its previous object, a stale inventory is dated 40 days before -At.
    param([Parameter(Mandatory=$true)]$Computer,[Parameter(Mandatory=$true)][string]$At,[Parameter(Mandatory=$true)][string]$StaleAt,[string[]]$ProbeIds=@())
    $guid = if ($Computer.Recreated) { 'recreated' } else { [string]$Computer.Guid }
    $presence = if ($Computer.Online) { 'En ligne' } else { 'Sans reponse' }
    $inventoryAt = if ($Computer.StaleInventory) { $StaleAt } else { $At }
    $ram = [long]$Computer.RamGB * 1073741824L
    $free = [long]$Computer.DiskFreeGB * 1073741824L
    $text = New-Object System.Text.StringBuilder
    [void]$text.Append('{"Key":"').Append([string]$Computer.Key).Append('","Guid":"').Append($guid).Append('","CheckedUtc":"').Append($At)
    [void]$text.Append('","Presence":"').Append($presence).Append('","Inventory":{"CheckedUtc":"').Append($inventoryAt).Append('","Model":"').Append([string]$Computer.Model)
    [void]$text.Append('","RamBytes":').Append([string]$ram).Append(',"DiskSize":107374182400,"DiskFree":').Append([string]$free).Append('},"Probes":{')
    $first = $true
    foreach ($id in $ProbeIds) {
        if (-not $first) { [void]$text.Append(',') }
        $first = $false
        [void]$text.Append('"').Append([string]$id).Append('":{"CheckedUtc":"').Append($At).Append('","Count":1,"Rows":[["42"]],"Error":"","Skipped":"","Truncated":false}')
    }
    [void]$text.Append('}}')
    return $text.ToString()
}

function New-DomeniaLoadSoftwareRows {
    # Software list of one heavy computer: Count rows, 40 publishers, a few products in two versions, some without
    # publisher or size (they must stay 'non renseigné', never counted as zero).
    param([ValidateRange(1,100000)][int]$Count=2500,[datetime]$NowUtc=[datetime]::UtcNow)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    for ($i = 1; $i -le $Count; $i++) {
        $publisher = if (($i % 17) -eq 0) { '' } else { 'Editeur ' + ($i % 40) }
        $version = if (($i % 50) -eq 0) { '2.' + ($i % 7) + '.0' } else { '1.' + ($i % 9) + '.' + ($i % 100) }
        $size = if (($i % 23) -eq 0) { 0 } else { 1024 * (($i % 300) + 1) }
        $installed = if (($i % 5) -eq 0) { '' } else { $NowUtc.AddDays(-($i % 700)).ToString('dd/MM/yyyy',[Globalization.CultureInfo]::InvariantCulture) }
        $rows.Add([pscustomobject]@{ Name=('Produit ' + ($i % 2400)); Publisher=$publisher; Version=$version; Architecture=$(if (($i % 3) -eq 0) { '32 bits' } else { '64 bits' }); Scope=$(if (($i % 9) -eq 0) { 'Utilisateur' } else { 'Machine' }); SizeKb=$size; InstallDate=$installed })
    }
    return ,($rows.ToArray())
}

function Test-DomeniaMemoryStabilized {
    # Managed memory measured after each cycle (MB, after a full collection). The cycles before -Warmup fill the
    # caches and are not judged. Stable when the last value exceeds the first judged one by no more than
    # max(SlackMB, TolerancePercent % of it). Fewer than two judged cycles: 'Insufficient', never a pass.
    param([double[]]$SamplesMB=@(),[ValidateRange(0,100)][int]$Warmup=1,[ValidateRange(0,1000)][double]$TolerancePercent=10,[ValidateRange(0,100000)][double]$SlackMB=32)
    $values = New-Object 'System.Collections.Generic.List[double]'
    foreach ($value in $SamplesMB) {
        $number = [double]$value
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or ($number -lt 0)) { return [pscustomobject]@{ Verdict='Invalid'; Stable=$false; BaselineMB=$null; LastMB=$null; GrowthMB=$null; LimitMB=$null; Judged=0 } }
        $values.Add($number)
    }
    $judged = $values.Count - $Warmup
    if ($judged -lt 2) { return [pscustomobject]@{ Verdict='Insufficient'; Stable=$false; BaselineMB=$null; LastMB=$null; GrowthMB=$null; LimitMB=$null; Judged=[Math]::Max(0,$judged) } }
    $baseline = $values[$Warmup]
    $last = $values[$values.Count - 1]
    $growth = $last - $baseline
    $limit = [Math]::Max($SlackMB,$baseline * $TolerancePercent / 100.0)
    $stable = ($growth -le $limit)
    $verdict = if ($stable) { 'Stable' } else { 'Growing' }
    return [pscustomobject]@{ Verdict=$verdict; Stable=$stable; BaselineMB=[Math]::Round($baseline,1); LastMB=[Math]::Round($last,1); GrowthMB=[Math]::Round($growth,1); LimitMB=[Math]::Round($limit,1); Judged=$judged }
}

function Measure-DomeniaLoadAdmissionBurst {
    # Offers Requests background collections to the real admission rule (Test-DomeniaTaskAdmission) while every worker
    # place is taken: the queue must stop at MaxQueued and every other request must be refused explicitly.
    param([ValidateRange(1,1000000)][int]$Requests=20000,[int]$MaxConcurrent=6,[int]$MaxOutstanding=12,[int]$MaxQueued=32)
    $queued = 0; $refused = 0; $started = 0; $other = 0
    for ($i = 0; $i -lt $Requests; $i++) {
        $decision = Test-DomeniaTaskAdmission -Class 'Background' -Running $MaxConcurrent -Outstanding $MaxOutstanding -MaxConcurrent $MaxConcurrent -MaxOutstanding $MaxOutstanding -Queued $queued -MaxQueued $MaxQueued
        switch ([string]$decision.Decision) {
            'Queue' { $queued++ }
            'Reject' { $refused++ }
            'Start' { $started++ }
            default { $other++ }
        }
    }
    return [pscustomobject]@{ Requests=$Requests; Queued=$queued; Refused=$refused; Started=$started; Other=$other; MaxQueued=$MaxQueued; Bounded=(($queued -le $MaxQueued) -and ($started -eq 0) -and ($other -eq 0) -and (($queued + $refused) -eq $Requests)) }
}
