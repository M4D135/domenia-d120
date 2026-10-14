# Collection settings, session memories and durable campaigns (roadmap points 11, 15, 19, 20, 159, 160).
# Dot-sourced in the core scope by the closed loader. The decisions are the rules of Domenia-Collection.Model.ps1;
# this file reads the settings, keeps the session memories (last address of a workstation, missing capabilities)
# and writes the plan of the explicit campaign in the preference folder of the operator. Nothing here starts a
# network read: a campaign resumes only on an explicit answer of the operator, with its scope shown.

# ---------------------------------------------------------------- settings of the usage profile (points 11 and 159)
function Get-DomeniaProfileSetting {
    # Value stored for one profile in a JSON object {profile: value}; '' when absent or unreadable.
    param([AllowEmptyString()][string]$Text,[Parameter(Mandatory=$true)][string]$Profile)
    $clean = ([string]$Text).Trim()
    if (-not $clean) { return '' }
    $map = $null
    try { $map = ConvertFrom-Json -InputObject $clean -ErrorAction Stop } catch { return '' }
    if ($map -isnot [Management.Automation.PSCustomObject]) { return '' }
    $property = $map.PSObject.Properties[$Profile]
    if (($null -eq $property) -or ($null -eq $property.Value)) { return '' }
    if ($property.Value -is [string]) { return [string]$property.Value }
    return (ConvertTo-Json -InputObject $property.Value -Compress -Depth 3)
}

function Set-DomeniaProfileSetting {
    # New JSON text where the entry of one known profile is replaced, or removed when the value is empty.
    param([AllowEmptyString()][string]$Text,[Parameter(Mandatory=$true)][string]$Profile,[AllowEmptyString()][string]$Value,[switch]$Json)
    $known = @(Get-DomeniaCollectionProfiles | ForEach-Object { [string]$_.Id })
    $entries = [ordered]@{}
    foreach ($id in $known) {
        if ($id -ieq $Profile) { continue }
        $current = Get-DomeniaProfileSetting -Text $Text -Profile $id
        if (-not $current) { continue }
        if ($current.StartsWith('{')) { try { $entries[$id] = ConvertFrom-Json -InputObject $current -ErrorAction Stop } catch { } }
        else { $entries[$id] = $current }
    }
    $profileId = [string](Get-DomeniaCollectionProfile $Profile).Id
    if (([string]$Value).Trim()) {
        if ($Json) { $entries[$profileId] = ConvertFrom-Json -InputObject ([string]$Value) -ErrorAction Stop }
        else { $entries[$profileId] = ([string]$Value).Trim() }
    }
    if (-not $entries.Count) { return '' }
    return ([pscustomobject]$entries | ConvertTo-Json -Compress -Depth 4)
}

function Get-DomeniaCollectionProfileId {
    return [string](Get-DomeniaCollectionProfile ([string](Get-DomeniaSetting 'Collection.Profile' 'Standard'))).Id
}

function Get-DomeniaActiveFreshnessTable {
    # Effective durations of the current profile, cached by the raw settings they depend on: a presence lookup per
    # result row costs two setting reads and one comparison.
    $text = [string](Get-DomeniaSetting 'Collection.FreshnessJson' '')
    $signature = [string](Get-DomeniaSetting 'Collection.Profile' 'Standard') + '|' + $text
    if (($null -ne $script:DomeniaFreshnessCache) -and ([string]$script:DomeniaFreshnessCache.Signature -ceq $signature)) { return $script:DomeniaFreshnessCache.Table }
    $profile = Get-DomeniaCollectionProfileId
    $overrides = ConvertFrom-DomeniaFreshnessOverrides (Get-DomeniaProfileSetting -Text $text -Profile $profile)
    $table = Resolve-DomeniaFreshnessTable -Profile $profile -Overrides $overrides.Values
    $table | Add-Member -NotePropertyName Errors -NotePropertyValue @($overrides.Errors) -Force
    $script:DomeniaFreshnessCache = [pscustomobject]@{Signature=$signature;Table=$table}
    return $table
}

function Set-DomeniaFreshnessOverride {
    # -Seconds -1 removes the override of the family: the profile value applies again.
    param([Parameter(Mandatory=$true)][string]$Family,[int]$Seconds=-1)
    $profile = Get-DomeniaCollectionProfileId
    $text = [string](Get-DomeniaSetting 'Collection.FreshnessJson' '')
    $current = ConvertFrom-DomeniaFreshnessOverrides (Get-DomeniaProfileSetting -Text $text -Profile $profile)
    $values = @{}
    foreach ($key in @($current.Values.Keys)) { $values[$key] = $current.Values[$key] }
    if ($Seconds -lt 0) { [void]$values.Remove($Family) } else { $values[$Family] = $Seconds }
    $check = ConvertFrom-DomeniaFreshnessOverrides (ConvertTo-DomeniaFreshnessOverridesText $values)
    if (@($check.Errors).Count) { throw ([string]@($check.Errors)[0]) }
    Set-DomeniaSetting 'Collection.FreshnessJson' (Set-DomeniaProfileSetting -Text $text -Profile $profile -Value (ConvertTo-DomeniaFreshnessOverridesText $check.Values) -Json)
    $script:DomeniaFreshnessCache = $null
}

function Get-DomeniaCollectionWindowText {
    # The window of the current profile: the operator's text, else the default of the profile.
    $profile = Get-DomeniaCollectionProfileId
    $stored = Get-DomeniaProfileSetting -Text ([string](Get-DomeniaSetting 'Collection.WindowsJson' '')) -Profile $profile
    if ($stored) {
        if ($stored -ieq 'toujours') { return '' }
        return $stored
    }
    return [string](Get-DomeniaCollectionProfile $profile).Windows
}

function Set-DomeniaCollectionWindowText {
    # A window is saved only once it parses; 'toujours' is stored explicitly so that an empty field does not bring
    # back the default of the profile.
    param([AllowEmptyString()][string]$Text)
    $parsed = ConvertFrom-DomeniaCollectionWindowText $Text
    if (-not [bool]$parsed.Valid) { throw ('Fenêtre non enregistrée : ' + (@($parsed.Errors) -join ' ')) }
    $value = [string]$parsed.Text
    if (-not $value) { $value = 'toujours' }
    $profile = Get-DomeniaCollectionProfileId
    Set-DomeniaSetting 'Collection.WindowsJson' (Set-DomeniaProfileSetting -Text ([string](Get-DomeniaSetting 'Collection.WindowsJson' '')) -Profile $profile -Value $value)
    $script:DomeniaCollectionWindowCache = $null
}

function Get-DomeniaActiveCollectionWindow {
    # Parsed window of the current profile, cached by the raw settings it depends on.
    $signature = [string](Get-DomeniaSetting 'Collection.Profile' 'Standard') + '|' + [string](Get-DomeniaSetting 'Collection.WindowsJson' '')
    if (($null -ne $script:DomeniaCollectionWindowCache) -and ([string]$script:DomeniaCollectionWindowCache.Signature -ceq $signature)) { return $script:DomeniaCollectionWindowCache.Window }
    $window = ConvertFrom-DomeniaCollectionWindowText (Get-DomeniaCollectionWindowText)
    $script:DomeniaCollectionWindowCache = [pscustomobject]@{Signature=$signature;Window=$window}
    return $window
}

function Test-DomeniaCollectionWindowAllowsSource {
    # Point 159: called by the background gate of the engine. A failure of the setting never blocks explicit work.
    param([AllowEmptyString()][string]$Source)
    if (@(Get-DomeniaCollectionWindowSources) -notcontains [string]$Source) { return $true }
    return [bool](Test-DomeniaCollectionWindowAllows -Window (Get-DomeniaActiveCollectionWindow) -Source $Source -Now (Get-Date))
}

function Get-DomeniaCollectionWindowStatusText {
    $window = Get-DomeniaActiveCollectionWindow
    if (-not [bool]$window.Valid) { return ('Fenêtre de collecte invalide : ' + (@($window.Errors) -join ' ') + ' Travaux de fond suspendus jusquʼà correction.') }
    $now = Get-Date
    return (Format-DomeniaCollectionWindowState -State (Test-DomeniaCollectionWindowOpen -Window $window -Now $now) -Now $now)
}

function Get-DomeniaCollectionWindowCampaignNote {
    # Point 159: an explicit campaign stays possible outside the window; its confirmation says so with its scope.
    $window = Get-DomeniaActiveCollectionWindow
    if ([string]$window.Mode -eq 'Always') { return '' }
    $state = Test-DomeniaCollectionWindowOpen -Window $window -Now (Get-Date)
    if ([bool]$state.Open) { return '' }
    return ' Hors fenêtre de collecte du profil « ' + [string](Get-DomeniaCollectionProfile (Get-DomeniaCollectionProfileId)).Label + ' » : ce relevé part seulement parce que vous le confirmez, sur le périmètre indiqué.'
}

# ---------------------------------------------------------------- session memories (points 15 and 19)
function Register-DomeniaTargetAddress {
    # Last IPv4 address seen for a workstation in this session, from a ping detail. Bounded to 20 000 names.
    param([AllowEmptyString()][string]$Computer,[AllowEmptyString()][string]$Text)
    $name = ([string]$Computer).Trim().ToLowerInvariant()
    $address = Get-DomeniaAddressFromText $Text
    if ((-not $name) -or (-not $address)) { return '' }
    if ($null -eq $script:DomeniaTargetAddresses) { $script:DomeniaTargetAddresses = @{} }
    if (($script:DomeniaTargetAddresses.Count -ge 20000) -and (-not $script:DomeniaTargetAddresses.ContainsKey($name))) { $script:DomeniaTargetAddresses.Clear() }
    $script:DomeniaTargetAddresses[$name] = $address
    return $address
}

function Get-DomeniaTargetAddress {
    param([AllowEmptyString()][string]$Computer,$Previous=$null)
    $name = ([string]$Computer).Trim().ToLowerInvariant()
    if ($name -and ($null -ne $script:DomeniaTargetAddresses) -and $script:DomeniaTargetAddresses.ContainsKey($name)) { return [string]$script:DomeniaTargetAddresses[$name] }
    if ($null -ne $Previous) { return (Register-DomeniaTargetAddress -Computer $Computer -Text ([string](Get-DomeniaMember $Previous 'PresenceDetail' ''))) }
    return ''
}

function Get-DomeniaKnownTargetGroup {
    # Point 15: group of an engine read for its provider budget. The controller of the session for the directory;
    # the presumed subnet of a known workstation for CIM, WTS and network reads; '' when nothing is known.
    param([AllowEmptyString()][string]$Provider,[AllowEmptyString()][string]$Target='')
    if ($Provider -eq 'Directory') {
        # Every directory read of the session goes to the controller of the connection, whatever its resource.
        $server = ''
        try { $server = ([string]$script:Conn.Server).Trim() } catch { $server = '' }
        return $server.ToLowerInvariant()
    }
    if ($Provider -in @('Cim','Wts','Network')) {
        $subnet = Get-DomeniaSubnetKey (Get-DomeniaTargetAddress -Computer $Target)
        return $subnet
    }
    return ''
}

function Get-DomeniaCapabilityMemory {
    # Point 19: one memory per session; facts tied to accounts are checked against the account generation.
    if (($null -eq $script:DomeniaCapabilityMemory) -or ([long]$script:DomeniaCapabilityMemoryEpoch -ne [long]$script:SessionEpoch)) {
        $script:DomeniaCapabilityMemory = New-DomeniaCapabilityMemory
        $script:DomeniaCapabilityMemoryEpoch = [long]$script:SessionEpoch
    }
    return $script:DomeniaCapabilityMemory
}

function Register-DomeniaCollectionCapabilities {
    # Facts learnt from one committed workstation measurement: absent classes, WMI refused or inaccessible.
    # A success forgets the fact at once.
    param([AllowEmptyString()][string]$Computer,$Packet,[object[]]$Probes=@(),[AllowEmptyString()][string]$Build='')
    $memory = Get-DomeniaCapabilityMemory
    $generation = [long]$script:DomeniaAccountGeneration
    $outcome = [string](Get-DomeniaMember $Packet 'Outcome' '')
    $presence = [string](Get-DomeniaMember $Packet 'Presence' '')
    if ($outcome -in @('Observed','NoConsole')) { [void](Clear-DomeniaCapabilityFact -Memory $memory -Target $Computer -Capability 'cim') }
    elseif ($outcome -eq 'Denied') { [void](Register-DomeniaCapabilityFact -Memory $memory -Target $Computer -Capability 'cim' -Kind 'RightDenied' -Build $Build -AccountGeneration $generation) }
    elseif (($outcome -eq 'Unavailable') -and ($presence -eq 'En ligne')) { [void](Register-DomeniaCapabilityFact -Memory $memory -Target $Computer -Capability 'cim' -Kind 'ProtocolUnreachable' -Build $Build -AccountGeneration $generation) }
    $results = Get-DomeniaMemberValue $Packet 'Probes' $null
    foreach ($probe in @($Probes)) {
        if ($null -eq $probe) { continue }
        $entry = Get-DomeniaMemberValue $results ([string]$probe.Id) $null
        if ($null -eq $entry) { continue }
        $capability = Get-DomeniaProbeCapability $probe
        $failure = [string](Get-DomeniaMember $entry 'Error' '')
        if (Test-DomeniaWmiClassAbsentText $failure) { [void](Register-DomeniaCapabilityFact -Memory $memory -Target $Computer -Capability $capability -Kind 'ClassAbsent' -Build $Build -AccountGeneration $generation) }
        elseif (-not $failure) { [void](Clear-DomeniaCapabilityFact -Memory $memory -Target $Computer -Capability $capability) }
    }
}

# ---------------------------------------------------------------- durable campaign plan (point 20)
function Get-DomeniaCampaignPlanKind {
    param($Run)
    if ([bool](Get-DomeniaMember $Run 'PingOnly' $false)) { return 'Ping' }
    if ([bool](Get-DomeniaMember $Run 'WmiOnly' $false)) { return 'Wmi' }
    if ([bool](Get-DomeniaMember $Run 'Inventory' $false)) { return 'Analysis' }
    return 'Console'
}

function Save-DomeniaCampaignPlan {
    # Called once, when the operator approves the campaign. The plan and its progress are written in the preference
    # folder (local, per operator, atomic with a backup). A list too long for that file is reported, never truncated.
    param($Run)
    if ($null -eq $Run) { return $false }
    try {
        $plan = New-DomeniaCampaignPlan -Kind (Get-DomeniaCampaignPlanKind $Run) -Targets @($Run.Targets) -ProbeIds @(@(Get-DomeniaMember $Run 'Probes' @()) | ForEach-Object { [string](Get-DomeniaMember $_ 'Id' '') }) -Inventory ([bool](Get-DomeniaMember $Run 'Inventory' $false)) -ScopeLabel ([string](Get-DomeniaMember $Run 'ScopeLabel' '')) -DomainDn ([string]$script:Conn.BaseDn) -DatabasePath ([string]$Run.Path) -Id ([string]$Run.Id)
        if (@($plan.Targets).Count -ne @($Run.Targets).Count) { throw 'des postes sans nom, DN ou GUID utilisables' }
        $text = ConvertTo-DomeniaCampaignPlanText $plan
        if ([Text.Encoding]::UTF8.GetByteCount($text) -gt 900KB) { throw 'liste trop longue pour le fichier de reprise' }
        $progress = New-DomeniaCampaignProgress -Plan $plan
        if (-not (Write-DomeniaPreference -FileName 'Domenia.campaign-plan.json' -Value $text)) { throw 'écriture refusée' }
        if (-not (Write-DomeniaPreference -FileName 'Domenia.campaign-progress.json' -Value (ConvertTo-DomeniaCampaignProgressText $progress))) { throw 'écriture refusée' }
        $Run | Add-Member -NotePropertyName CampaignProgress -NotePropertyValue $progress -Force
        $Run | Add-Member -NotePropertyName CampaignSavedUtc -NotePropertyValue ([datetime]::UtcNow) -Force
        $Run | Add-Member -NotePropertyName CampaignDirty -NotePropertyValue $false -Force
        $Run | Add-Member -NotePropertyName CampaignNote -NotePropertyValue 'Plan de reprise enregistré.' -Force
        Register-DomeniaCampaignCloseHook
        return $true
    } catch {
        $Run | Add-Member -NotePropertyName CampaignProgress -NotePropertyValue $null -Force
        $Run | Add-Member -NotePropertyName CampaignNote -NotePropertyValue ('Plan de reprise non enregistré : ' + $_.Exception.Message + '.') -Force
        try { Write-AppLog ('Plan de reprise du relevé non enregistré : ' + $_.Exception.Message) 'WARN' } catch { }
        return $false
    }
}

function Set-DomeniaCampaignTargetValidated {
    # One workstation result was read back from SQLite: it will never be read again by a resume of this plan.
    param($Run,[int]$Index)
    $progress = Get-DomeniaMemberValue $Run 'CampaignProgress' $null
    if (($null -eq $progress) -or ($Index -lt 0)) { return }
    if (Set-DomeniaCampaignTargetDone -Progress $progress -Index $Index) { $Run.CampaignDirty = $true }
}

function Save-DomeniaCampaignProgress {
    # Debounced: at most every ten seconds while the campaign runs, at once with -Force (pause, end, close).
    # A complete plan is removed: nothing remains to resume.
    param($Run,[ValidateSet('','Running','Paused','Closed','Incident','Complete')][string]$State='',[AllowEmptyString()][string]$Reason='',[switch]$Force)
    $progress = Get-DomeniaMemberValue $Run 'CampaignProgress' $null
    if ($null -eq $progress) { return $false }
    if ($State) { $progress.State = $State; $progress.Reason = [string]$Reason }
    if ((-not $Force) -and (-not [bool](Get-DomeniaMember $Run 'CampaignDirty' $false))) { return $false }
    $last = Get-DomeniaMember $Run 'CampaignSavedUtc' ([datetime]::MinValue)
    if ((-not $Force) -and (([datetime]::UtcNow - [datetime]$last).TotalSeconds -lt 10)) { return $false }
    try {
        $progress.UpdatedUtc = [datetime]::UtcNow.ToString('o')
        if ([int]$progress.DoneCount -ge [int]$progress.Total) {
            [void](Write-DomeniaPreference -FileName 'Domenia.campaign-progress.json' -Value '{}')
            [void](Write-DomeniaPreference -FileName 'Domenia.campaign-plan.json' -Value '{}')
            $Run.CampaignProgress = $null
        }
        elseif (-not (Write-DomeniaPreference -FileName 'Domenia.campaign-progress.json' -Value (ConvertTo-DomeniaCampaignProgressText $progress))) { throw 'écriture refusée' }
        $Run.CampaignSavedUtc = [datetime]::UtcNow
        $Run.CampaignDirty = $false
        return $true
    } catch {
        try { Write-AppLog ('Avancement du relevé non enregistré : ' + $_.Exception.Message) 'WARN' } catch { }
        return $false
    }
}

function Complete-DomeniaCampaignPlan {
    # End of a campaign: complete plans disappear; the others keep their remaining workstations for a resume.
    param($Run)
    $progress = Get-DomeniaMemberValue $Run 'CampaignProgress' $null
    if ($null -eq $progress) { return }
    $state = 'Complete'; $reason = ''
    if ([int]$progress.DoneCount -lt [int]$progress.Total) {
        $failure = [string](Get-DomeniaMember $Run 'FailureMessage' '')
        if ($script:AsyncEngineClosing) { $state = 'Closed' }
        elseif ($failure) { $state = 'Incident'; $reason = $failure }
        elseif ([bool](Get-DomeniaMember $Run 'Stopping' $false)) {
            $state = 'Paused'
            $why = [string](Get-DomeniaMember $Run 'StopReason' '')
            if ($why) { $state = 'Incident'; $reason = $why }
        }
        else { $state = 'Incident'; $reason = 'postes non validés à la fin du relevé' }
    }
    [void](Save-DomeniaCampaignProgress -Run $Run -State $state -Reason $reason -Force)
}

function Register-DomeniaCampaignCloseHook {
    # Closing the window keeps the remaining workstations of the running campaign.
    if ([bool]$script:DomeniaCampaignCloseHooked -or ($null -eq $script:Window)) { return }
    $script:Window.Add_Closed({ try { if (($null -ne $script:ParkRun) -and ($null -ne (Get-DomeniaMemberValue $script:ParkRun 'CampaignProgress' $null))) { [void](Save-DomeniaCampaignProgress -Run $script:ParkRun -State 'Closed' -Force) } } catch { } })
    $script:DomeniaCampaignCloseHooked = $true
}

function Read-DomeniaCampaignProgressFile {
    # Small file only: the offer never unpacks the target list.
    $text = ''
    try { $text = [string](Read-DomeniaPreference -FileName 'Domenia.campaign-progress.json') } catch { $text = '' }
    if ((-not $text.Trim()) -or ($text.Trim() -eq '{}')) { return $null }
    try { return (ConvertFrom-DomeniaCampaignProgressText $text) } catch { return $null }
}

function Get-DomeniaCampaignResumeStatus {
    $progress = Read-DomeniaCampaignProgressFile
    return (Get-DomeniaCampaignResumeState -Progress $progress -DomainDn ([string]$script:Conn.BaseDn) -DatabasePath ([string]$script:DatabaseScopedPath))
}

function Get-DomeniaCampaignReplacementNote {
    # One plan is kept at a time: a new campaign says that it replaces the interrupted one before it is confirmed.
    try {
        $status = Get-DomeniaCampaignResumeStatus
        if ([bool]$status.Resumable) { return (' Un relevé interrompu attend sa reprise (' + [string]$status.Remaining + ' poste(s) restant(s)) : son plan sera remplacé par celui-ci à la confirmation.') }
    } catch { }
    return ''
}

function Start-DomeniaCampaignResume {
    # Explicit gesture only. The remaining workstations go through the usual preparation and the inline
    # confirmation of the collection, which shows their number and scope before any read.
    try {
        if ($script:DemoMode) { throw 'reprise indisponible en démonstration.' }
        if (($null -ne $script:ParkRun) -and (-not $script:ParkRun.Completed)) { throw 'un relevé est déjà en cours.' }
        $planText = [string](Read-DomeniaPreference -FileName 'Domenia.campaign-plan.json')
        $plan = ConvertFrom-DomeniaCampaignPlanText $planText
        $progress = ConvertFrom-DomeniaCampaignProgressText -Text ([string](Read-DomeniaPreference -FileName 'Domenia.campaign-progress.json')) -Plan $plan
        $status = Get-DomeniaCampaignResumeState -Progress $progress -DomainDn ([string]$script:Conn.BaseDn) -DatabasePath ([string]$script:DatabaseScopedPath)
        if (-not [bool]$status.Resumable) { throw ([string]$status.Reason) }
        $remaining = @(Get-DomeniaCampaignRemainingTargets -Plan $plan -Progress $progress)
        $label = 'reprise du relevé'
        $scope = [string]$plan.ScopeLabel
        if ($scope -like 'reprise*') { $label = $scope } elseif ($scope) { $label = 'reprise : ' + $scope }
        $arguments = @{ScopeTargets=$remaining;ScopeLabel=$label}
        switch ([string]$plan.Kind) {
            'Ping' { $arguments.PingOnly = $true }
            'Wmi' { $arguments.WmiOnly = $true; $arguments.Inventory = [bool]$plan.Inventory }
            'Analysis' { $arguments.Inventory = $true }
        }
        if (([string]$plan.Kind -ne 'Ping') -and @($plan.ProbeIds).Count) { $arguments.Probes = @(ConvertTo-DomeniaProbePayload -Ids @($plan.ProbeIds)) }
        Start-DomeniaOnlinePark @arguments
    } catch {
        Set-Status ('Reprise du relevé impossible : ' + $_.Exception.Message) 'WARN'
    }
    try { Update-DomeniaCampaignResumeUi } catch { }
}

function Clear-DomeniaCampaignPlan {
    # Explicit abandonment of an interrupted plan. Measurements already validated stay in the local base.
    try {
        [void](Write-DomeniaPreference -FileName 'Domenia.campaign-progress.json' -Value '{}')
        [void](Write-DomeniaPreference -FileName 'Domenia.campaign-plan.json' -Value '{}')
        Set-Status 'Plan de reprise abandonné. Les mesures déjà validées restent dans la base locale.'
    } catch { Set-Status ('Plan de reprise non supprimé : ' + $_.Exception.Message) 'WARN' }
    try { Update-DomeniaCampaignResumeUi } catch { }
}

function Request-DomeniaCampaignResumeOffer {
    # Once per session and local base, when nothing else waits for an answer: proposes to resume an interrupted
    # campaign of this domain. The safe answer keeps the plan for later; nothing is read without « Reprendre ».
    if ($script:DemoMode -or (-not [string]$script:DatabaseScopedPath) -or (-not [string]$script:Conn.BaseDn)) { return }
    $key = [string]$script:SessionEpoch + '|' + [string]$script:DatabaseScopedPath
    if ([string]$script:DomeniaCampaignResumeOfferKey -ceq $key) { return }
    if (($null -ne $script:ParkRun) -and (-not $script:ParkRun.Completed)) { return }
    try { if ($null -ne (Get-DomeniaInlinePendingRequest)) { return } } catch { return }
    $script:DomeniaCampaignResumeOfferKey = $key
    $status = Get-DomeniaCampaignResumeStatus
    if (-not [bool]$status.Resumable) { return }
    $resume = ${function:Start-DomeniaCampaignResume}
    [void](Request-DomeniaInlineConfirmation -Title 'Reprendre le relevé interrompu' -Target ([string]$script:Conn.Domain) -Message ([string]$status.Reason + ' Le nombre de postes et le périmètre sont confirmés avant toute lecture.') -ConfirmText 'Reprendre' -CancelText 'Plus tard' -OnConfirm ({ & $resume }.GetNewClosure()))
}

# ---------------------------------------------------------------- settings view (Outils > Requêtes > Réglages de collecte)
function Initialize-DomeniaCollectionSettingsUi {
    # The controls live in Domenia-Query.xaml; they exist only once the workshop view is loaded.
    $profileBox = Get-DomeniaControl 'CmbCollectionProfile'
    if (($null -eq $profileBox) -or [bool]$script:DomeniaCollectionSettingsWired) { return }
    $profileBox.DisplayMemberPath = 'Label'
    $profileBox.ItemsSource = @(Get-DomeniaCollectionProfiles)
    $current = Get-DomeniaCollectionProfileId
    foreach ($item in @($profileBox.ItemsSource)) { if ([string]$item.Id -eq $current) { $profileBox.SelectedItem = $item } }
    $profileBox.Add_SelectionChanged({
        param($sender,$eventArgs)
        try {
            if ($null -eq $sender.SelectedItem) { return }
            Set-DomeniaSetting 'Collection.Profile' ([string]$sender.SelectedItem.Id)
            $script:DomeniaFreshnessCache = $null; $script:DomeniaCollectionWindowCache = $null
            Update-DomeniaCollectionSettingsUi
        } catch { Set-Status ('Profil de collecte non enregistré : ' + $_.Exception.Message) 'WARN' }
    })
    $grid = Get-DomeniaControl 'DgCollectionFreshness'
    if ($null -ne $grid) { $grid.Add_SelectionChanged({ try { Update-DomeniaCollectionFreshnessEditor } catch { } }) }
    $value = Get-DomeniaControl 'CmbCollectionFreshnessValue'
    if ($null -ne $value) {
        $value.DisplayMemberPath = 'Label'
        $value.Add_SelectionChanged({
            param($sender,$eventArgs)
            if ([bool]$script:DomeniaCollectionEditorUpdating -or ($null -eq $sender.SelectedItem)) { return }
            try {
                $row = (Get-DomeniaControl 'DgCollectionFreshness').SelectedItem
                if ($null -eq $row) { return }
                Set-DomeniaFreshnessOverride -Family ([string]$row.Family) -Seconds ([int]$sender.SelectedItem.Seconds)
                Update-DomeniaCollectionSettingsUi -Family ([string]$row.Family)
            } catch { Set-Status ('Durée non enregistrée : ' + $_.Exception.Message) 'WARN' }
        })
    }
    $reset = Get-DomeniaControl 'BtnCollectionFreshnessReset'
    if ($null -ne $reset) {
        $reset.Add_Click({
            try {
                $profile = Get-DomeniaCollectionProfileId
                Set-DomeniaSetting 'Collection.FreshnessJson' (Set-DomeniaProfileSetting -Text ([string](Get-DomeniaSetting 'Collection.FreshnessJson' '')) -Profile $profile -Value '')
                $script:DomeniaFreshnessCache = $null
                Update-DomeniaCollectionSettingsUi
                Set-Status 'Durées du profil rétablies.'
            } catch { Set-Status ('Durées non rétablies : ' + $_.Exception.Message) 'WARN' }
        })
    }
    $apply = Get-DomeniaControl 'BtnCollectionWindowApply'
    if ($null -ne $apply) {
        $apply.Add_Click({
            try {
                Set-DomeniaCollectionWindowText ([string](Get-DomeniaControl 'TxtCollectionWindow').Text)
                Update-DomeniaCollectionSettingsUi
                Set-Status ('Fenêtre de collecte enregistrée. ' + (Get-DomeniaCollectionWindowStatusText))
            } catch { [void](Set-DomeniaControlText 'LblCollectionWindow' $_.Exception.Message); Set-Status $_.Exception.Message 'WARN' }
        })
    }
    $resumeButton = Get-DomeniaControl 'BtnCollectionResume'
    if ($null -ne $resumeButton) { $resumeButton.Add_Click({ Start-DomeniaCampaignResume }) }
    $discard = Get-DomeniaControl 'BtnCollectionResumeDiscard'
    if ($null -ne $discard) { $discard.Add_Click({ Clear-DomeniaCampaignPlan }) }
    $script:DomeniaCollectionSettingsWired = $true
    Update-DomeniaCollectionSettingsUi
}

function Update-DomeniaCollectionFreshnessEditor {
    $grid = Get-DomeniaControl 'DgCollectionFreshness'
    $value = Get-DomeniaControl 'CmbCollectionFreshnessValue'
    if (($null -eq $grid) -or ($null -eq $value)) { return }
    $row = $grid.SelectedItem
    $script:DomeniaCollectionEditorUpdating = $true
    try {
        if ($null -eq $row) { $value.ItemsSource = @(); $value.IsEnabled = $false; return }
        $choices = @(Get-DomeniaFreshnessDurationChoices -Family ([string]$row.Family) | ForEach-Object { [pscustomobject]@{Seconds=[int]$_;Label=(Format-DomeniaCollectionDuration ([long]$_))} })
        $value.ItemsSource = $choices
        $value.IsEnabled = $true
        foreach ($choice in $choices) { if ([int]$choice.Seconds -eq [int]$row.Seconds) { $value.SelectedItem = $choice } }
    } finally { $script:DomeniaCollectionEditorUpdating = $false }
}

function Update-DomeniaCollectionSettingsUi {
    param([AllowEmptyString()][string]$Family='')
    $table = Get-DomeniaActiveFreshnessTable
    $definition = Get-DomeniaCollectionProfile ([string]$table.Profile)
    $profileText = [string]$definition.Description + ' La durée retenue pour un relevé est la plus courte de cette durée et de « Réutiliser les mesures fraîches ».'
    if (@($table.Errors).Count) { $profileText += ' ' + (@($table.Errors) -join ' ') }
    [void](Set-DomeniaControlText 'LblCollectionProfile' $profileText)
    $grid = Get-DomeniaControl 'DgCollectionFreshness'
    if ($null -ne $grid) {
        $grid.ItemsSource = @($table.Rows)
        foreach ($row in @($table.Rows)) { if ($Family -and ([string]$row.Family -eq $Family)) { $grid.SelectedItem = $row } }
    }
    Update-DomeniaCollectionFreshnessEditor
    $box = Get-DomeniaControl 'TxtCollectionWindow'
    if ($null -ne $box) { $box.Text = Get-DomeniaCollectionWindowText }
    [void](Set-DomeniaControlText 'LblCollectionWindow' (Get-DomeniaCollectionWindowStatusText))
    Update-DomeniaCampaignResumeUi
}

function Update-DomeniaCampaignResumeUi {
    $label = Get-DomeniaControl 'LblCollectionResume'
    if ($null -eq $label) { return }
    $status = Get-DomeniaCampaignResumeStatus
    [void](Set-DomeniaControlText 'LblCollectionResume' ([string]$status.Reason))
    $running = (($null -ne $script:ParkRun) -and (-not $script:ParkRun.Completed))
    $resume = Get-DomeniaControl 'BtnCollectionResume'
    if ($null -ne $resume) { $resume.IsEnabled = ([bool]$status.Resumable -and (-not $running) -and (-not $script:DemoMode)) }
    $discard = Get-DomeniaControl 'BtnCollectionResumeDiscard'
    if ($null -ne $discard) { $discard.IsEnabled = (([int]$status.Remaining -gt 0) -and (-not $running)) }
}

# ---------------------------------------------------------------- operations panel (points 12, 13, 16, 160)
function Get-DomeniaCollectionHealthLines {
    # Local measures of this session only. A source that is not listed is healthy or was never used.
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($class in @('Explicit','Selection','Background')) {
        $wait = $null
        try { $wait = Get-DomeniaRuntimeMetricSummary -Provenance 'Queue' -Prefix ('Wait:' + $class) } catch { $wait = $null }
        if (($null -ne $wait) -and ([int]$wait.Count -gt 0)) {
            $name = switch ($class) { 'Explicit' { 'actions explicites' } 'Selection' { 'lectures de sélection' } default { 'travaux de fond' } }
            $lines.Add('Attente en file des ' + $name + ' : médiane ' + [string][Math]::Round([double]$wait.P50) + ' ms ; 95 % sous ' + [string][Math]::Round([double]$wait.P95) + ' ms (' + [string]$wait.Count + ' mesures).')
        }
    }
    if ([int]$script:DomeniaAgedPromotions -gt 0) { $lines.Add('Travaux de fond relancés après une longue attente : ' + [string][int]$script:DomeniaAgedPromotions + '.') }
    if ([int]$script:DomeniaSharedReadCount -gt 0) { $lines.Add('Lectures identiques partagées : ' + [string][int]$script:DomeniaSharedReadCount + ' (aucun second appel envoyé).') }
    if ([long]$script:DomeniaCimQueriesAvoided -gt 0) { $lines.Add('Requêtes WMI évitées par regroupement : ' + [string][long]$script:DomeniaCimQueriesAvoided + ' sur ' + [string]([long]$script:DomeniaCimQueriesAvoided + [long]$script:DomeniaCimQueriesExecuted) + ' besoins.') }
    try { foreach ($line in @(Get-DomeniaProviderStateSummary -State $script:DomeniaProviderState)) { $lines.Add([string]$line) } } catch { }
    try { $lines.Add('Profil de collecte : ' + [string](Get-DomeniaCollectionProfile (Get-DomeniaCollectionProfileId)).Label + '. ' + (Get-DomeniaCollectionWindowStatusText)) } catch { }
    return $lines.ToArray()
}
