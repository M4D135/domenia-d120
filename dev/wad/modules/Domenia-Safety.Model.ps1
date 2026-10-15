# Intervention safety rules: immutable confirmed plans, per-operation postconditions, durable receipts before
# dispatch, idempotent admission, conditional writes, locks scoped to a target, honest compensation, the raw
# attribute and typed target rules shared by the interface and the write workers, and the plain-words view of a plan.
# L07 (SE-09, 08/10/2026): the dry run, session end, batch and rollback-kind rules, never called by the application,
# were removed with their tests.
# Pure decisions: no write, no network call, no disk access and no clock read happens here.
# The only implicit values are those of the Domenia.InterventionPlan type (Id and CreatedUtc), which the
# fingerprint deliberately ignores; every time-dependent rule takes "now" as a parameter.

# ---------------------------------------------------------------- shared classification
function Get-DomeniaOperationEffect {
    # What an operation changes. An unknown identifier is never treated as a read (fail closed).
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$OperationId)
    $id = ([string]$OperationId).Trim()
    if (-not $id) { return 'Unknown' }
    # Same pattern as Start-DomeniaWriteTask: every directory write is named Write<Name>.
    if ($id -cmatch '^Write[A-Za-z0-9]{2,59}$') { return 'DirectoryWrite' }
    if ($id -in @('ComputerGpUpdate','ComputerRestart','RimotteRun','WakeOnLanSend')) { return 'RemoteMutation' }
    if ($id -in @('LocalStore','ReceiptStore','DocumentStore','StoragePurge','StorageBackup','LinkHistoryStore','LiveCache','IndexBuild','IndexRefresh')) { return 'LocalWrite' }
    # Points 101-109 (Audit AD) add DelegationRead, AdHealthRead, DcServicesRead and RelationHistoryRead: reads only.
    $reads = @(
        'SelectedPresence','PresenceScan','CmdletHelp','CmdletInventory','TreeChildren','GlobalSearch','PermissionAnalysis','SelfCheck',
        'ReadBitLocker','ReadBitLockerKey','ReadLaps','ComputerInventory','DomainOverview','BatchNetworkDiag','SoftwareInventory',
        'WmiNamespaces','WmiClasses','WmiQuery','UserComputerProbe','LogonHarvest','ParkSweep','ComputerDiagnostics','ComputerLastUser',
        'ComputerPing','ComputerAdminShare','PruneLinks','OpenLinkedObject','EngineSelfTest','OpenAdObject','StartupWarmCache','StartupWarmup','LiveConsole',
        'LiveDirectoryCheck','SessionsList','RemoteCredentialCheck','ScopeReconcile','ReconcileScope','LiveSelectedPing',
        'EmbeddedDirectoryLookup','EmbeddedPathBrowse','ObjectChanges','StorageUsage','ComputerQuickDiag','PasswordPolicyRead',
        'LockoutDiagnosis','GroupPathRead','JoinStateRead','UpdateStateRead','GpoLinksRead','GpoAppliedRead','DcCompareRead',
        'ComputerEventsRead','MachineIdentityRead','AdConsistencyScan','ConnectorRead','DemoDirectory',
        'DelegationRead','AdHealthRead','DcServicesRead','RelationHistoryRead'
    )
    if ($reads -contains $id) { return 'Read' }
    return 'Unknown'
}

function Test-DomeniaSecretAttribute {
    # Secret-bearing attributes never carry a value in a plan, a receipt, a summary or a compensation.
    param([AllowEmptyString()][AllowNull()][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $core = Get-Command -Name 'Test-DomeniaSensitiveAttributeName' -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $core -and (Test-DomeniaSensitiveAttributeName -Name $Name)) { return $true }
    # Same family as the core list, needed here because the rule tests run without the core.
    return ($Name.Trim() -match '^(?i:unicodePwd|userPassword|unixUserPassword|clearTextPassword|dBCSPwd|supplementalCredentials|ntPwdHistory|lmPwdHistory|currentValue|priorValue|pekList|trustAuthIncoming|trustAuthOutgoing|ms-Mcs-AdmPwd|msLAPS-.+|msFVE-RecoveryPassword|msFVE-KeyPackage|msDS-ManagedPassword.*|msDS-KeyCredentialLink)$')
}

function Test-DomeniaMemberPresent {
    # True when the object names this member, even with an empty or null value. A re-read must name every
    # attribute it was asked for: an LDAP answer leaves out an attribute the account may not read exactly as
    # it leaves out an empty one, so a missing name means "not read", never "empty".
    param($InputObject,[AllowEmptyString()][AllowNull()][string]$Name)
    if (($null -eq $InputObject) -or [string]::IsNullOrEmpty($Name)) { return $false }
    if ($InputObject -is [Collections.IDictionary]) { return [bool]$InputObject.Contains($Name) }
    return ($null -ne $InputObject.PSObject.Properties[$Name])
}

function ConvertTo-DomeniaDnKey {
    # Normalised distinguished name: lower case, no space around the separators. '' when the text is not a DN,
    # that is when one of its relative names does not read <attribute>=<value> (display name, SID, login...).
    param([AllowEmptyString()][AllowNull()][string]$Dn)
    $parts = @(Split-DomeniaDn ([string]$Dn))
    if (-not $parts.Count) { return '' }
    $normalized = New-Object 'System.Collections.Generic.List[string]'
    foreach ($part in $parts) {
        if ($part -notmatch '^[A-Za-z][A-Za-z0-9-]*\s*=') { return '' }
        $normalized.Add(($part -replace '^([A-Za-z][A-Za-z0-9-]*)\s*=\s*','$1='))
    }
    return ($normalized.ToArray() -join ',').ToLowerInvariant()
}

function Resolve-DomeniaTargetKeys {
    # Comparable keys for the objects an operation touches. A Domenia.SelectionIdentity gives its GUID and DN keys,
    # a GUID text (any form) a GUID key, a DN (any case and spacing) a DN key; 'guid:' and 'dn:' prefixes in any
    # case are normalised again and '*' (every target) is kept. Anything else (display name, SID, login...) is
    # returned in Invalid: it can never be compared with a lock, so every caller fails closed on it.
    param([object[]]$Targets=@())
    $keys = New-Object 'System.Collections.Generic.List[string]'
    $invalid = New-Object 'System.Collections.Generic.List[string]'
    foreach ($target in @($Targets)) {
        if ($null -eq $target) { continue }
        $found = New-Object 'System.Collections.Generic.List[string]'
        if ($target -is [Domenia.SelectionIdentity]) {
            $found.Add('guid:' + $target.Guid.ToLowerInvariant())
            $dnKey = ConvertTo-DomeniaDnKey $target.DN
            if ($dnKey) { $found.Add('dn:' + $dnKey) }
        } else {
            $text = ([string]$target).Trim()
            if (-not $text) { continue }
            if ($text -eq '*') { $found.Add('*') }
            else {
                $form = ''; $body = $text
                $colon = $text.IndexOf(':')
                if ($colon -gt 0) {
                    $prefix = $text.Substring(0,$colon).Trim().ToLowerInvariant()
                    if ($prefix -in @('guid','dn')) { $form = $prefix; $body = $text.Substring($colon + 1).Trim() }
                }
                $guid = ''
                if ($form -ne 'dn') { $guid = ConvertTo-DomeniaGuidText $body }
                if ($guid) { $found.Add('guid:' + $guid.ToLowerInvariant()) }
                elseif ($form -ne 'guid') {
                    $dnKey = ConvertTo-DomeniaDnKey $body
                    if ($dnKey) { $found.Add('dn:' + $dnKey) }
                }
            }
            if (-not $found.Count) { $invalid.Add((ConvertTo-DomeniaFlatText $text 120)) }
        }
        foreach ($key in $found) { if (-not $keys.Contains($key)) { $keys.Add($key) } }
    }
    return [pscustomobject]@{Keys=$keys.ToArray();Invalid=$invalid.ToArray()}
}

function Test-DomeniaDnValuedAttribute {
    # Attributes whose values are distinguished names: compared without regard to case or spacing.
    param([AllowEmptyString()][AllowNull()][string]$Name)
    return (([string]$Name).Trim() -in @('member','memberOf','managedBy','manager','distinguishedName','assistant','secretary'))
}

function ConvertTo-DomeniaComparableValue {
    # A DN-valued attribute (or a move) compares as a normalised DN; any other text, or a text that is not a DN,
    # compares exactly.
    param([AllowEmptyString()][AllowNull()][string]$Attribute,[AllowEmptyString()][AllowNull()][string]$Value,[bool]$AsDn=$false)
    $text = [string]$Value
    if ($text -and ($AsDn -or (Test-DomeniaDnValuedAttribute $Attribute))) {
        $dnKey = ConvertTo-DomeniaDnKey $text
        if ($dnKey) { return ('dn:' + $dnKey) }
    }
    return $text
}

function Get-DomeniaNamedValues {
    # Name/value pairs of a hashtable or of a PSCustomObject, sorted by name. Anything else gives nothing.
    param($InputObject)
    if ($null -eq $InputObject) { return }
    $pairs = New-Object 'System.Collections.Generic.List[object]'
    if ($InputObject -is [Collections.IDictionary]) {
        foreach ($key in @($InputObject.Keys)) { $pairs.Add([pscustomobject]@{Name=[string]$key;Value=$InputObject[$key]}) }
    } elseif ($InputObject -is [Management.Automation.PSCustomObject]) {
        foreach ($property in @($InputObject.PSObject.Properties)) { $pairs.Add([pscustomobject]@{Name=[string]$property.Name;Value=$property.Value}) }
    }
    $pairs.ToArray() | Sort-Object Name
}

function ConvertTo-DomeniaPlanChanges {
    # Normalises changes given as Domenia.PlanChange or as {Attribute|Name, Kind, Before|Old, After|New, Clear}
    # (the shape used by Start-DomeniaAttributeWrite). A secret attribute keeps its name and kind, never its value.
    # Kinds: Replace (Before -> After), Clear (Before -> ''), Add (After added), Remove (Before removed),
    # Move (DN Before -> After), Reset (secret set without any value kept).
    param([object[]]$Changes=@())
    $known = @('Replace','Clear','Add','Remove','Move','Reset')
    foreach ($change in @($Changes)) {
        if ($null -eq $change) { continue }
        $attribute = ''; $kind = ''; $before = ''; $after = ''
        if ($change -is [Domenia.PlanChange]) {
            $attribute = $change.Attribute; $kind = $change.Kind; $before = $change.Before; $after = $change.After
        } else {
            $attribute = [string](Get-DomeniaMember $change 'Attribute' (Get-DomeniaMember $change 'Name' ''))
            $kind = [string](Get-DomeniaMember $change 'Kind' '')
            $before = [string](Get-DomeniaMember $change 'Before' (Get-DomeniaMember $change 'Old' ''))
            $after = [string](Get-DomeniaMember $change 'After' (Get-DomeniaMember $change 'New' ''))
            if ([bool](Get-DomeniaMember $change 'Clear' $false)) { $kind = 'Clear'; $after = '' }
        }
        if ([string]::IsNullOrWhiteSpace($attribute)) { throw 'Changement sans attribut : plan refusé.' }
        # One spelling per kind, so that the fingerprint does not depend on the caller casing.
        if ([string]::IsNullOrWhiteSpace($kind)) { $kind = 'Replace' }
        $canonical = @($known | Where-Object { $_ -ieq $kind.Trim() })
        if (-not $canonical.Count) { throw ('Type de changement inconnu (' + $kind + ') : plan refusé.') }
        $kind = [string]$canonical[0]
        if ((Test-DomeniaSecretAttribute $attribute) -or ($kind -eq 'Reset')) {
            $before = ''
            if (-not [string]::IsNullOrEmpty($after)) { $after = '[valeur secrète non conservée]' }
        }
        New-Object Domenia.PlanChange -ArgumentList @($attribute,$kind,$before,$after)
    }
}

# ---------------------------------------------------------------- D091 immutable intervention plan
function New-DomeniaInterventionPlan {
    # Captures, before the confirmation screen, everything the execution will be checked against:
    # operation, exact target (domain and GUID), controller or workstation, account, ordered changes, effects.
    param(
        [Parameter(Mandatory=$true)][string]$OperationId,
        [Parameter(Mandatory=$true)][AllowNull()]$Target,
        [AllowEmptyString()][string]$Server='',
        [AllowEmptyString()][string]$Account='',
        [object[]]$Changes=@(),
        [string[]]$Effects=@(),
        [bool]$Simulation=$false
    )
    if ($Target -isnot [Domenia.SelectionIdentity]) { throw 'Cible non identifiée : un plan exige lʼidentité exacte de lʼobjet (domaine et GUID).' }
    $effect = Get-DomeniaOperationEffect $OperationId
    if ($effect -ne 'Read' -and [string]::IsNullOrWhiteSpace($Server)) { throw 'Destinataire non fixé : le plan doit nommer le contrôleur ou le poste qui recevra la demande.' }
    if ([string]::IsNullOrWhiteSpace($Account)) { throw 'Compte dʼexécution non fixé : le plan doit nommer le compte utilisé.' }
    $changeList = [Domenia.PlanChange[]]@(ConvertTo-DomeniaPlanChanges $Changes)
    $effectList = [string[]]@(foreach ($line in @($Effects)) { if (-not [string]::IsNullOrWhiteSpace($line)) { Protect-DomeniaSecretText ([string]$line) } })
    if (($effect -ne 'Read') -and ($changeList.Length -eq 0) -and ($effectList.Length -eq 0)) { throw 'Plan vide : aucun changement ni effet annoncé.' }
    # A secret value never enters the plan, so it is outside the fingerprint: the confirmation screen says so.
    if (Test-DomeniaPlanHasSecret $changeList) { $effectList = [string[]](@($effectList) + (Get-DomeniaPlanSecretLimit)) }
    return New-Object Domenia.InterventionPlan -ArgumentList @($OperationId,$Target,$Server.Trim(),$Account.Trim(),$changeList,$effectList,$Simulation)
}

function Test-DomeniaPlanHasSecret {
    # True when a change sets a secret: its value is never kept, so it is never compared either.
    param([object[]]$Changes=@())
    foreach ($change in @($Changes)) {
        if ($null -eq $change) { continue }
        if ((Test-DomeniaSecretAttribute ([string](Get-DomeniaMember $change 'Attribute' ''))) -or ([string](Get-DomeniaMember $change 'Kind' '') -eq 'Reset')) { return $true }
    }
    return $false
}

function Get-DomeniaPlanSecretLimit {
    return 'Valeur secrète hors du plan : elle nʼest ni conservée ni comparée, une saisie modifiée après la confirmation nʼinvalide pas le plan.'
}

function Test-DomeniaPlanStillValid {
    # Called at execution time with what is about to be sent. Any difference with the confirmed plan invalidates it:
    # nothing runs on another object, at another place, through another controller, under another account,
    # for another operation or with other values. A simulation plan is never executable.
    # The module never reads the clock: with an age limit (MaxAgeMinutes > 0), a missing NowUtc invalidates the plan.
    # MaxAgeMinutes 0 turns the age check off explicitly.
    param(
        $Plan,
        $Current,
        [AllowEmptyString()][string]$Server='',
        [AllowEmptyString()][string]$Account='',
        [object[]]$Changes=@(),
        [AllowEmptyString()][string]$OperationId='',
        $NowUtc=$null,
        [ValidateRange(0,1440)][int]$MaxAgeMinutes=15
    )
    $reasons = New-Object 'System.Collections.Generic.List[string]'
    if ($Plan -isnot [Domenia.InterventionPlan]) {
        return [pscustomobject]@{Valid=$false;Reasons=@('Aucun plan confirmé : rien nʼest exécuté.');Fingerprint='';Expected='';Limit=''}
    }
    $fingerprint = ''
    $operation = $Plan.Operation
    if ($OperationId.Trim()) {
        if ($OperationId.Trim() -cne $Plan.Operation) { $reasons.Add('Opération différente de celle du plan (' + $Plan.Operation + ') : rien nʼest exécuté.') }
        $operation = $OperationId.Trim()
    }
    if ($Plan.Simulation) { $reasons.Add('Plan de simulation : il ne sʼexécute jamais.') }
    if ($Current -isnot [Domenia.SelectionIdentity]) { $reasons.Add('Cible actuelle non identifiée : rien nʼest exécuté.') }
    else {
        $sameObject = $Plan.Target.SameObject($Current)
        if (-not $sameObject) { $reasons.Add('La cible a changé depuis la confirmation (' + $Current.Name + ' au lieu de ' + $Plan.Target.Name + ') : plan invalidé, rien nʼest exécuté sur un autre objet.') }
        else {
            if ($Plan.Target.Epoch -ne $Current.Epoch) { $reasons.Add('Session changée depuis la confirmation : nouvelle confirmation requise.') }
            # The request is addressed by DN: an object moved or renamed since the preview is not the place that was confirmed.
            $plannedDn = ConvertTo-DomeniaComparableValue '' $Plan.Target.DN $true
            if ($plannedDn -and $plannedDn -cne (ConvertTo-DomeniaComparableValue '' $Current.DN $true)) {
                $reasons.Add('Lʼobjet a été déplacé ou renommé depuis la confirmation : relire puis confirmer à nouveau.')
            }
        }
        if ($Server.Trim() -ine $Plan.Server) { $reasons.Add('Destinataire différent de celui du plan (' + $Plan.Server + ').') }
        if ($Account.Trim() -ine $Plan.Account) { $reasons.Add('Compte différent de celui du plan.') }
        try {
            $fingerprint = [Domenia.InterventionPlan]::ComputeFingerprint($operation,$Current,$Server.Trim(),$Account.Trim(),[Domenia.PlanChange[]]@(ConvertTo-DomeniaPlanChanges $Changes))
        } catch { $reasons.Add('Valeurs à envoyer illisibles : ' + (ConvertTo-DomeniaFlatText $_.Exception.Message 160)) }
        $sameRoute = (($Server.Trim() -ieq $Plan.Server) -and ($Account.Trim() -ieq $Plan.Account) -and ($operation -ceq $Plan.Operation))
        if ($sameObject -and $sameRoute -and $fingerprint -and ($fingerprint -cne $Plan.Fingerprint)) {
            $reasons.Add('Les valeurs à envoyer ne sont plus celles du plan confirmé : nouvelle confirmation requise.')
        }
    }
    $now = ConvertTo-DomeniaUtcDate $NowUtc
    if ($MaxAgeMinutes -gt 0) {
        if ($null -eq $now) { $reasons.Add('Heure de contrôle absente : lʼâge du plan nʼest pas vérifiable, rien nʼest exécuté.') }
        else {
            $age = ($now - $Plan.CreatedUtc).TotalMinutes
            if ($age -gt $MaxAgeMinutes) { $reasons.Add('Plan confirmé il y a plus de ' + $MaxAgeMinutes + ' min : relire puis confirmer à nouveau.') }
            elseif ($age -lt -1) { $reasons.Add('Heure de contrôle antérieure à la confirmation : horloge incohérente, rien nʼest exécuté.') }
        }
    }
    $limit = ''
    if (Test-DomeniaPlanHasSecret @($Plan.Changes)) { $limit = Get-DomeniaPlanSecretLimit }
    return [pscustomobject]@{Valid=(($reasons.Count -eq 0) -and ($fingerprint -ceq $Plan.Fingerprint));Reasons=$reasons.ToArray();Fingerprint=$fingerprint;Expected=$Plan.Fingerprint;Limit=$limit}
}

# ---------------------------------------------------------------- D093 postcondition per operation
function Get-DomeniaPostconditionRule {
    # The re-read that proves an operation. The return of the process is never the proof.
    param([Parameter(Mandatory=$true)][string]$OperationId)
    $map = @{
        'WriteGroupMember'=@('Membership','Relire lʼattribut member du groupe sur le contrôleur qui a reçu lʼécriture.')
        'WriteObjectGroup'=@('Membership','Relire lʼappartenance de lʼobjet à chaque groupe modifié, sur le contrôleur initial.')
        'WriteMoveObject'=@('Move','Relire lʼobjet par son GUID : il doit se trouver sous le conteneur choisi.')
        'WriteRenameComputer'=@('Move','Relire lʼobjet par son GUID : son DN doit porter le nouveau nom.')
        'WriteAttributes'=@('Attribute','Relire chaque attribut modifié sur le contrôleur initial et comparer à la valeur envoyée.')
        'WriteExpiration'=@('Attribute','Relire accountExpires sur le contrôleur initial.')
        'WriteExpirePassword'=@('Attribute','Relire pwdLastSet : la valeur 0 impose le changement à la prochaine ouverture.')
        'WriteAccountDisabled'=@('State','Relire userAccountControl : état activé ou désactivé attendu.')
        'WriteUnlock'=@('State','Relire lockoutTime : compte déverrouillé attendu.')
        'WriteAccountOptions'=@('State','Relire userAccountControl : options attendues.')
        'WriteResetPassword'=@('PasswordChange','Relire pwdLastSet : date postérieure à lʼenvoi. La valeur du mot de passe nʼest jamais relue.')
        'WriteCreateOu'=@('Existence','Relire lʼOU créée sous son parent.')
        'WriteDeleteObject'=@('Absence','Relire lʼobjet par son GUID : une absence constatée est requise, un refus de lecture ne vaut pas absence.')
        'ComputerRestart'=@('Restart','Relire le dernier démarrage du poste : postérieur à lʼenvoi.')
        'ComputerGpUpdate'=@('PolicyRefresh','Relire la dernière application des stratégies : postérieure à lʼenvoi.')
        'RimotteRun'=@('RemoteRun','Aucune relecture générique : le résultat dʼun script distant se vérifie sur le poste.')
        'WakeOnLanSend'=@('Presence','Relire la présence du poste : réponse postérieure à la demande. Une réponse ne prouve pas que le réveil vient de cette demande.')
    }
    $kind = 'Aucune'; $check = 'Aucune règle de vérification connue pour cette opération : à vérifier manuellement.'
    if ($map.ContainsKey($OperationId)) { $kind = [string]$map[$OperationId][0]; $check = [string]$map[$OperationId][1] }
    elseif ((Get-DomeniaOperationEffect $OperationId) -eq 'Read') { $kind = 'Lecture'; $check = 'Lecture : aucune postcondition.' }
    return [pscustomobject]@{OperationId=$OperationId;Kind=$kind;Check=$check;SameServer=$true;ProcessResultIsProof=$false;CanVerify=($kind -notin @('Aucune','RemoteRun','Lecture'))}
}

function Resolve-DomeniaPostcondition {
    # The status comes from the re-read only: Verifie (everything re-read as expected), Partiel (part of it, or the
    # expected state without proof of its cause), A verifier (nothing proven, read refused, incomplete or not done).
    # The process return is quoted, never used as proof.
    # $Expected: {Server, then per kind: Add/Remove (DNs), Guid + NewDn, Values or Flags (name -> value), Guid,
    # PreviousUtc (time value re-read just before dispatch from the same source as the re-read)}.
    # $Observed: {ReadStatus='OK'|'Refused'|'Unavailable'|'NotRead', Server, ReadUtc, then per kind: Members (the
    # complete list, even empty), Guid, DN, Values, Flags, Exists, PwdLastSetUtc, LastBootUtc, LastPolicyRefreshUtc,
    # RespondedUtc}. Every expected attribute, flag or list must be NAMED by the re-read, with an empty or null value
    # when it was read empty: one left out was not read (AD leaves out an unreadable attribute like an empty one),
    # so it never counts as conforming.
    # $ClockSkewSeconds: margin required when a re-read time from another clock is compared with the local send time.
    param([Parameter(Mandatory=$true)]$Rule,$Expected=$null,$Observed=$null,$ProcessResult=$null,$SentUtc=$null,[ValidateRange(0,3600)][int]$ClockSkewSeconds=0)
    if ($Rule -is [string]) { $Rule = Get-DomeniaPostconditionRule $Rule }
    $kind = [string](Get-DomeniaMember $Rule 'Kind' 'Aucune')
    $readStatus = [string](Get-DomeniaMember $Observed 'ReadStatus' 'NotRead')
    $server = [string](Get-DomeniaMember $Observed 'Server' '')
    $expectedServer = [string](Get-DomeniaMember $Expected 'Server' '')
    $readDate = Get-DomeniaMember $Observed 'ReadUtc' $null
    $sent = ConvertTo-DomeniaUtcDate $SentUtc
    $where = ''
    if ($server) { $where = ' sur ' + $server }
    $processText = ''
    if ($null -ne $ProcessResult) {
        $code = [string](Get-DomeniaMember $ProcessResult 'ExitCode' '')
        $message = ConvertTo-DomeniaFlatText (Protect-DomeniaSecretText ([string](Get-DomeniaMember $ProcessResult 'Message' ''))) 120
        $processText = 'Retour du processus'
        if ($code) { $processText += ' (code ' + $code + ')' }
        if ($message) { $processText += ' : ' + $message }
        $processText += ' ; ce retour nʼest pas une preuve.'
    }
    $details = New-Object 'System.Collections.Generic.List[object]'
    $missing = New-Object 'System.Collections.Generic.List[string]'
    $checked = 0; $satisfied = 0; $proof = ''; $limit = ''; $causeUnproven = $false
    $unreadLimit = 'Absent de la relecture : un attribut illisible et un attribut vide ne se distinguent pas dans une réponse LDAP.'
    if ($kind -in @('Aucune','RemoteRun','Lecture')) {
        $proof = 'Aucune relecture ne prouve lʼeffet de cette opération : vérification manuelle requise'
    } elseif ($readStatus -ne 'OK') {
        $label = 'non effectuée'
        if ($readStatus -eq 'Refused') { $label = 'refusée' } elseif ($readStatus -eq 'Unavailable') { $label = 'impossible (source injoignable)' }
        $proof = 'Relecture ' + $label + $where + ' : issue à vérifier. Un refus de lecture ne prouve pas lʼissue'
    } else {
        switch ($kind) {
            'Membership' {
                $membersRead = Test-DomeniaMemberPresent $Observed 'Members'
                $present = @(@(Get-DomeniaMember $Observed 'Members' @()) | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-DomeniaComparableValue 'member' ([string]$_) $true })
                foreach ($pair in @(@('Add',$true),@('Remove',$false))) {
                    foreach ($dn in @(Get-DomeniaMember $Expected $pair[0] @())) {
                        if ([string]::IsNullOrWhiteSpace([string]$dn)) { continue }
                        $checked++
                        $name = Get-DomeniaCnFromDn ([string]$dn)
                        if (-not $membersRead) {
                            $missing.Add('membres non relus : ' + $name)
                            $details.Add((New-DomeniaFact -Fait ('Membre ' + $name) -Valeur 'non relu' -Etat 'Inconnu' -Source ('Relecture' + $where) -Limite $unreadLimit -Date $readDate))
                            continue
                        }
                        $isThere = ($present -ccontains (ConvertTo-DomeniaComparableValue 'member' ([string]$dn) $true))
                        if ($isThere -eq [bool]$pair[1]) { $satisfied++ }
                        elseif ($pair[1]) { $missing.Add('ajout non constaté : ' + $name) }
                        else { $missing.Add('retrait non constaté : ' + $name) }
                        $shown = 'absent'
                        if ($isThere) { $shown = 'présent' }
                        $details.Add((New-DomeniaFact -Fait ('Membre ' + $name) -Valeur $shown -Source ('Relecture' + $where) -Date $readDate))
                    }
                }
                if ($membersRead) { $proof = 'Appartenance relue' + $where + ' : ' + $satisfied + '/' + $checked + ' conforme(s)' }
                else { $proof = 'Liste des membres absente de la relecture' + $where + ' : ' + $satisfied + '/' + $checked + ' conforme(s)' }
            }
            'Move' {
                $checked = 1
                $observedGuid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $Observed 'Guid' '')
                $expectedGuid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $Expected 'Guid' '')
                $observedDn = [string](Get-DomeniaMember $Observed 'DN' '')
                $expectedDn = [string](Get-DomeniaMember $Expected 'NewDn' '')
                $sameObject = ([bool]$observedGuid -and ($observedGuid -ieq $expectedGuid))
                $sameDn = ([bool]$observedDn -and [bool]$expectedDn -and ((ConvertTo-DomeniaComparableValue '' $observedDn $true) -ceq (ConvertTo-DomeniaComparableValue '' $expectedDn $true)))
                if ($sameObject -and $sameDn) { $satisfied = 1 }
                elseif (-not $sameObject) { $missing.Add('objet non retrouvé par son GUID') }
                elseif (-not $observedDn) { $missing.Add('emplacement non relu') }
                else { $missing.Add('emplacement relu : ' + (Get-DomeniaOuDisplayPath $observedDn)) }
                $details.Add((New-DomeniaFact -Fait 'Emplacement' -Valeur $observedDn -Source ('Relecture par GUID' + $where) -Date $readDate))
                $proof = 'Objet relu par son GUID' + $where + ' : ' + $satisfied + '/1 conforme'
            }
            { $_ -in @('Attribute','State') } {
                $field = 'Values'
                if ($kind -eq 'State') { $field = 'Flags' }
                $seen = Get-DomeniaMember $Observed $field $null
                $names = New-Object 'System.Collections.Generic.List[string]'
                foreach ($pair in @(Get-DomeniaNamedValues (Get-DomeniaMember $Expected $field $null))) {
                    $name = [string]$pair.Name
                    if (Test-DomeniaSecretAttribute $name) { continue }
                    $checked++
                    $names.Add($name)
                    if (-not (Test-DomeniaMemberPresent $seen $name)) {
                        $missing.Add($name + ' non relu')
                        $details.Add((New-DomeniaFact -Fait $name -Valeur 'non relu' -Etat 'Inconnu' -Source ('Relecture' + $where) -Limite $unreadLimit -Date $readDate))
                        continue
                    }
                    $expectedValue = [string]$pair.Value
                    $observedValue = [string](Get-DomeniaMember $seen $name '')
                    $ok = $false
                    if ($kind -eq 'State') { $ok = ($observedValue -ieq $expectedValue) }
                    else { $ok = ((ConvertTo-DomeniaComparableValue $name $observedValue) -ceq (ConvertTo-DomeniaComparableValue $name $expectedValue)) }
                    if ($ok) { $satisfied++ } else { $missing.Add($name + ' relu « ' + (ConvertTo-DomeniaFlatText $observedValue 60) + ' »') }
                    $details.Add((New-DomeniaFact -Fait $name -Valeur $observedValue -Source ('Relecture' + $where) -Date $readDate))
                }
                $what = 'Attributs relus'
                if ($kind -eq 'State') { $what = 'État relu' }
                $proof = $what + $where + ' (' + ($names.ToArray() -join ', ') + ') : ' + $satisfied + '/' + $checked + ' conforme(s)'
            }
            { $_ -in @('Existence','Absence') } {
                $checked = 1
                # Presence must be stated by the re-read as a boolean (or the text true/false): a missing or
                # unreadable answer is never taken as "present" nor as "absent".
                $existsValue = Get-DomeniaMember $Observed 'Exists' $null
                $exists = $null
                if ($existsValue -is [bool]) { $exists = $existsValue }
                elseif (($existsValue -is [string]) -and ($existsValue.Trim() -match '^(?i:true|false)$')) { $exists = ($existsValue.Trim() -ieq 'true') }
                $expectedGuid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $Expected 'Guid' '')
                $observedGuid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $Observed 'Guid' '')
                $shown = 'non relu'
                if ($null -eq $exists) { $missing.Add('présence non indiquée par la relecture') }
                else {
                    $shown = 'absent'
                    if ($exists) { $shown = 'présent' }
                    if ($kind -eq 'Existence') {
                        if ($exists -and ((-not $expectedGuid) -or ($expectedGuid -ieq $observedGuid))) { $satisfied = 1 } else { $missing.Add('objet non constaté') }
                    } else {
                        if (-not $exists) { $satisfied = 1 } else { $missing.Add('objet encore présent') }
                    }
                }
                if ($kind -eq 'Existence') { $proof = 'Présence relue' + $where + ' : ' + $satisfied + '/1 conforme' }
                else { $proof = 'Absence relue par GUID' + $where + ' : ' + $satisfied + '/1 conforme' }
                $etat = 'Constate'
                if ($null -eq $exists) { $etat = 'Inconnu' }
                $details.Add((New-DomeniaFact -Fait 'Objet' -Valeur $shown -Etat $etat -Source ('Relecture' + $where) -Date $readDate))
            }
            { $_ -in @('PasswordChange','Restart','PolicyRefresh','Presence') } {
                $checked = 1
                $field = @{PasswordChange='PwdLastSetUtc';Restart='LastBootUtc';PolicyRefresh='LastPolicyRefreshUtc';Presence='RespondedUtc'}[$kind]
                $label = @{PasswordChange='pwdLastSet';Restart='Dernier démarrage';PolicyRefresh='Dernière application des stratégies';Presence='Dernière réponse'}[$kind]
                # Whose clock stamped the re-read value. The send time comes from this administration computer.
                $clock = @{PasswordChange='horloge du contrôleur';Restart='horloge du poste';PolicyRefresh='horloge du poste';Presence='horloge locale'}[$kind]
                $raw = Get-DomeniaMember $Observed $field $null
                $value = ConvertTo-DomeniaUtcDate $raw
                $previous = ConvertTo-DomeniaUtcDate (Get-DomeniaMember $Expected 'PreviousUtc' $null)
                $shown = 'inconnu'
                if ($null -ne $value) { $shown = $value.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC (' + $clock + ')' }
                if (($kind -eq 'PasswordChange') -and ([string]$raw -eq '0')) { $shown = '0'; $missing.Add('pwdLastSet à 0 (changement imposé) : date non comparable') }
                elseif ($null -eq $value) { $missing.Add($label + ' non relu') }
                elseif ($null -ne $previous) {
                    # Same source before and after dispatch: a single clock, no skew.
                    $limit = 'Comparé à la valeur relue avant lʼenvoi, sur la même horloge.'
                    if ($value -gt $previous) { $satisfied = 1 } else { $missing.Add($label + ' inchangé depuis la relecture préalable') }
                }
                elseif ($null -eq $sent) { $missing.Add('heure dʼenvoi inconnue : comparaison impossible') }
                else {
                    $limit = 'Comparé à lʼheure dʼenvoi locale'
                    if ($kind -ne 'Presence') { $limit += ' : deux horloges différentes (' + $clock + ' et horloge locale), un décalage peut fausser la comparaison' }
                    if ($ClockSkewSeconds -gt 0) { $limit += ' ; marge exigée ' + $ClockSkewSeconds + ' s' }
                    $limit += '.'
                    if ($value -gt $sent.AddSeconds($ClockSkewSeconds)) { $satisfied = 1 } else { $missing.Add($label + ' antérieur à lʼenvoi') }
                }
                if ($kind -eq 'Presence') {
                    # A response shows the expected state, not its cause: never more than Partiel.
                    $causeUnproven = $true
                    $limit = 'Une réponse ne prouve pas que le réveil vient de cette demande : le poste était peut-être déjà allumé ou réveillé autrement.'
                }
                $etat = 'Constate'
                if ($null -eq $value) { $etat = 'Inconnu' }
                $details.Add((New-DomeniaFact -Fait $label -Valeur $shown -Etat $etat -Source ('Relecture' + $where) -Limite $limit -Date $readDate))
                $proof = $label + ' relu' + $where + ' : ' + $shown
                if ($null -ne $previous) { $proof += ', avant lʼenvoi ' + $previous.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC' }
                if ($null -ne $sent) { $proof += ', envoi à ' + $sent.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC (horloge locale)' }
            }
            default { $proof = 'Règle de vérification inconnue : issue à vérifier' }
        }
    }
    $status = 'A verifier'
    if (($checked -gt 0) -and ($satisfied -eq $checked)) { $status = 'Verifie' }
    elseif ($satisfied -gt 0) { $status = 'Partiel' }
    if ($causeUnproven -and ($status -eq 'Verifie')) { $status = 'Partiel' }
    if ($missing.Count) { $proof += ' (' + ($missing.ToArray() -join ' ; ') + ')' }
    $proof += '.'
    if ($limit) { $proof += ' ' + $limit }
    if ($server -and $expectedServer -and ($server -ine $expectedServer)) {
        $proof += ' Relu sur ' + $server + ' et non sur ' + $expectedServer + ' qui a reçu la demande : un écart peut venir de la réplication.'
    }
    if ($processText) { $proof += ' ' + $processText }
    $statusLabel = 'À vérifier'
    if ($status -eq 'Verifie') { $statusLabel = 'Vérifié' } elseif ($status -eq 'Partiel') { $statusLabel = 'Partiel' }
    return [pscustomobject]@{Status=$status;Label=$statusLabel;Proof=$proof;Limit=$limit;Kind=$kind;Server=$server;Checked=$checked;Satisfied=$satisfied;Details=$details.ToArray();ProcessResultIsProof=$false}
}

# ---------------------------------------------------------------- D094 receipts for every important mutation
function Get-DomeniaReceiptRequirement {
    # Which operations need a durable receipt written BEFORE the request leaves Domenia.
    param([Parameter(Mandatory=$true)][string]$OperationId)
    $effect = Get-DomeniaOperationEffect $OperationId
    $required = ($effect -in @('DirectoryWrite','RemoteMutation','Unknown'))
    $reason = ''
    switch ($effect) {
        'DirectoryWrite' { $reason = 'Écriture AD : reçu durable écrit avant lʼenvoi au contrôleur.' }
        'RemoteMutation' {
            $what = @{ComputerGpUpdate='Actualisation des stratégies à distance';ComputerRestart='Redémarrage à distance';RimotteRun='Exécution distante';WakeOnLanSend='Réveil réseau'}[$OperationId]
            if (-not $what) { $what = 'Action à distance' }
            $reason = $what + ' : reçu durable écrit avant lʼenvoi au poste.'
        }
        'Unknown' { $reason = 'Opération non classée : traitée comme une modification, reçu exigé.' }
        'LocalWrite' { $reason = 'Sauvegarde locale : suivie par la file dʼécriture locale, sans reçu dʼintervention.' }
        default { $reason = 'Lecture : pas de reçu, elle peut être relancée.' }
    }
    $after = ''
    if ($required) { $after = 'Sent' }
    return [pscustomobject]@{
        OperationId=$OperationId;Effect=$effect;Resource=(Get-DomeniaOperationResource $OperationId);Required=$required;WriteBeforeDispatch=$required;FailClosed=$required
        # Prepared then Sent are both written durably; the request leaves only once "Sent" is on disk.
        # ReplayOnResume and StoresSecretValues describe what Test-DomeniaWriteAdmission (origins) and
        # ConvertTo-DomeniaReceiptRecord (hashes only, no secret) enforce.
        DispatchAfterStage=$after;Stages=@('Prepared','Sent','Verified','Unknown','NotSent','Reviewed','Delivered')
        ReplayOnResume=$false;StoresSecretValues=$false;Reason=$reason
    }
}

function Get-DomeniaReceiptResumeState {
    # What a receipt found after a restart means. Nothing found here is ever sent again automatically.
    param($Receipt)
    $stage = [string](Get-DomeniaMember $Receipt 'Stage' '')
    $state = 'Uncertain'
    $text = 'Reçu illisible ou étape inconnue : issue à vérifier. Aucun nouvel envoi automatique.'
    if ($stage -eq 'Prepared') {
        $state = 'NotSent'
        $text = 'Interrompu avant lʼenvoi dʼaprès le reçu (étape préparée) : rien nʼa été transmis. Rien nʼest relancé automatiquement.'
    } elseif ($stage -eq 'NotSent') {
        $state = 'NotSent'
        $text = 'Non envoyé : aucune modification transmise.'
    } elseif ($stage -eq 'Verified') {
        $state = 'Verified'
        $text = 'Vérifié par relecture.'
    } elseif ($stage -eq 'Reviewed') {
        $state = 'Reviewed'
        $text = 'Contrôlé manuellement et consigné.'
    } elseif ($stage -eq 'Sent') {
        $state = 'Uncertain'
        $text = 'Envoyé sans confirmation avant la fermeture : issue à vérifier. Aucun nouvel envoi automatique.'
    } elseif ($stage -eq 'Unknown') {
        $state = 'Uncertain'
        $text = 'Issue inconnue après envoi : à vérifier. Aucun nouvel envoi automatique.'
    } elseif ($stage -eq 'Delivered') {
        $state = 'Delivered'
        $text = "Demande envoyée sans preuve d'effet : étape terminale non bloquante. Aucun rejeu automatique."
    }
    return [pscustomobject]@{Stage=$stage;State=$state;Uncertain=($state -eq 'Uncertain');Replay=$false;BlocksTarget=($state -eq 'Uncertain');Text=$text}
}

function ConvertTo-DomeniaReceiptRecord {
    # The durable record written BEFORE dispatch (format 1 of Domenia-Receipts.Worker.ps1, plus the plan fingerprint).
    # Expected values are kept as hashes; a secret attribute is not listed at all.
    # $Domain: the base DN used by the receipt store (the worker compares it with Context.BaseDn).
    param([Parameter(Mandatory=$true)][AllowNull()]$Plan,[Parameter(Mandatory=$true)][string]$Id,$NowUtc=$null,[AllowEmptyString()][string]$Domain='')
    if ($Plan -isnot [Domenia.InterventionPlan]) { throw 'Plan absent : aucun reçu, donc aucun envoi.' }
    if ($Plan.Simulation) { throw 'Plan de simulation : aucun reçu, aucun envoi.' }
    if ($Id -cnotmatch '^[a-f0-9]{32}$') { throw 'Identifiant de reçu invalide.' }
    $when = ConvertTo-DomeniaUtcDate $NowUtc
    if ($null -eq $when) { throw 'Date du reçu requise.' }
    $expected = New-Object 'System.Collections.Generic.List[object]'
    $secret = $false
    foreach ($change in @($Plan.Changes)) {
        if ((Test-DomeniaSecretAttribute $change.Attribute) -or ($change.Kind -eq 'Reset')) { $secret = $true; continue }
        $expected.Add([pscustomobject]@{Name=$change.Attribute;Kind=$change.Kind;Clear=[string]::IsNullOrEmpty($change.After);Hash=(Get-DomeniaTextHash $change.After).ToLowerInvariant()})
    }
    $scope = $Plan.Target.Domain
    if ($Domain.Trim()) { $scope = $Domain.Trim() }
    $stamp = $when.ToString('o')
    return [pscustomobject]@{
        Format=1;Id=$Id;Fingerprint=$Plan.Fingerprint;Operation=$Plan.Operation;Domain=$scope.ToLowerInvariant();Server=$Plan.Server;Identity=$Plan.Account
        DN=$Plan.Target.DN;Guid=$Plan.Target.Guid;Stage='Prepared';CreatedUtc=$stamp;UpdatedUtc=$stamp;Expected=$expected.ToArray()
        CanVerify=((-not $secret) -and ($expected.Count -gt 0));Review=''
    }
}

# ---------------------------------------------------------------- D095 idempotence and no replay
function New-DomeniaWriteRegistry {
    # In-memory admission registry. Entries: one per plan fingerprint (the idempotence key). Plans: the confirmed
    # plans already used. Seeded at start-up from the receipts, so that an uncertain request is recognised by its
    # fingerprint and never sent a second time.
    param([object[]]$Receipts=@())
    $registry = [pscustomobject]@{Entries=@{};Plans=@{};Sequence=0}
    foreach ($receipt in @($Receipts)) {
        if ($null -eq $receipt) { continue }
        $key = ([string](Get-DomeniaMember $receipt 'PlanFingerprint' '')).Trim().ToUpperInvariant()
        if (-not $key) { $key = ([string](Get-DomeniaMember $receipt 'Fingerprint' '')).Trim().ToUpperInvariant() }
        if (-not $key) { continue }
        $resume = Get-DomeniaReceiptResumeState $receipt
        $state = 'NotSent'
        if ($resume.State -eq 'Uncertain') { $state = 'Uncertain' } elseif ($resume.State -in @('Verified','Reviewed','Delivered')) { $state = $resume.State }
        # Several receipts with the same fingerprint: an uncertain one always wins.
        if ($registry.Entries.ContainsKey($key) -and [string]$registry.Entries[$key].State -eq 'Uncertain') { continue }
        $registry.Sequence = [int]$registry.Sequence + 1
        $registry.Entries[$key] = [pscustomobject]@{Key=$key;Operation=[string](Get-DomeniaMember $receipt 'Operation' '');State=$state;PlanId='';Origin='Receipt';Sequence=$registry.Sequence}
    }
    return $registry
}

function Test-DomeniaWriteAdmission {
    [CmdletBinding(DefaultParameterSetName='Plan')]
    # Idempotence key = plan fingerprint. One confirmed plan is sent at most once, and no identical request
    # starts while another one is reserved, sent or uncertain. An admitted request is recorded (reserved) at
    # once, by default, so the second click of a double-click is refused whatever the caller remembers.
    # -CheckOnly answers without recording anything: to grey out a button, never to send.
    # Start-up, resume, timers, reconnections and automatic retries never send a modification. Reads stay retryable.
    param(
        [Parameter(ParameterSetName='Plan',Position=0)][AllowNull()]$Registry,
        [Parameter(ParameterSetName='Plan',Position=1)][AllowNull()]$Plan,
        [Parameter(ParameterSetName='Fingerprint',Mandatory=$true)][AllowEmptyString()][string]$Fingerprint,
        [Parameter(ParameterSetName='Fingerprint')][AllowNull()][hashtable]$Submitted,
        [Parameter(ParameterSetName='Fingerprint')][AllowNull()][object[]]$Receipts=@(),
        [Parameter(ParameterSetName='Fingerprint')][AllowNull()]$Active=$null,
        [Parameter(ParameterSetName='Plan',Position=2)][Parameter(ParameterSetName='Fingerprint')][ValidateSet('Operator','Batch','Startup','Resume','AutoRetry','Timer','Reconnect')][string]$Origin='Operator',
        [Parameter(ParameterSetName='Plan')][Parameter(ParameterSetName='Fingerprint')][switch]$CheckOnly
    )
    $answer = { param([bool]$admit,[bool]$duplicate,[string]$key,[string]$why,[bool]$retryable,[bool]$reserved=$false) [pscustomobject]@{Admit=$admit;Duplicate=$duplicate;Key=$key;Reason=$why;Retryable=$retryable;Reserved=$reserved} }
    if ($PSCmdlet.ParameterSetName -eq 'Fingerprint') {
        $key = ([string]$Fingerprint).Trim().ToUpperInvariant()
        if (-not $key) { return (& $answer $false $false '' "Empreinte absente : rien n'est envoyé." $false) }
        if ($Origin -notin @('Operator','Batch')) { return (& $answer $false $false $key "Aucune modification n'est envoyée automatiquement (démarrage, reprise ou nouvel essai) : geste explicite requis." $false) }
        $state = ''
        if ((($null -ne $Submitted)) -and ($Submitted.ContainsKey($key))) {
            $state = [string](Get-DomeniaMember $Submitted[$key] 'State' '')
        }
        if ([string]::IsNullOrWhiteSpace($state)) {
            if ($null -ne $Receipts) {
                foreach ($receipt in @($Receipts)) {
                    if ($null -eq $receipt) { continue }
                    $receiptKey = ([string](Get-DomeniaMember $receipt 'PlanFingerprint' '')).Trim().ToUpperInvariant()
                    if (-not $receiptKey) { $receiptKey = ([string](Get-DomeniaMember $receipt 'Fingerprint' '')).Trim().ToUpperInvariant() }
                    if (-not $receiptKey) { $receiptKey = ([string](Get-DomeniaMember $receipt 'Id' '')).Trim().ToUpperInvariant() }
                    if ($receiptKey -ceq $key) {
                        $resume = Get-DomeniaReceiptResumeState $receipt
                        if ($resume.Uncertain) { $state = 'Uncertain' }
                        elseif ($resume.State -in @('Verified','Reviewed','Delivered')) { $state = [string]$resume.State }
                        else { $state = 'NotSent' }
                        break
                    }
                }
            }
        }
        if ([string]::IsNullOrWhiteSpace($state)) {
            if ($null -ne $Active) {
                $activeJobs = @()
                if ($Active -is [System.Collections.IDictionary]) { $activeJobs = @($Active.Values) } else { $activeJobs = @($Active) }
                foreach ($job in $activeJobs) {
                    if ($null -eq $job) { continue }
                    $jobKey = ([string](Get-DomeniaMember $job.Payload 'PlanFingerprint' '')).Trim().ToUpperInvariant()
                    if ($jobKey -ceq $key) {
                        $jobState = [string](Get-DomeniaMember $job 'State' '')
                        if ($jobState -notin @('Completed','Failed','Cancelled','Superseded')) { $state = 'Sent'; break }
                    }
                }
            }
        }
        if ((-not [string]::IsNullOrWhiteSpace($state)) -and (($state -notin @('NotSent','Failed')))) {
            if ($state -eq 'Uncertain') { return (& $answer $false $true $key 'Demande identique à vérifier : aucun nouvel envoi avant la vérification du reçu.' $false) }
            return (& $answer $false $true $key 'Demande identique déjà envoyée : un seul envoi.' $false)
        }
        if ($CheckOnly) { return (& $answer $true $false $key '' $false $false) }
        if ($null -ne $Submitted) { $Submitted[$key] = [pscustomobject]@{Key=$key;State='Reserved';Origin=$Origin} }
        return (& $answer $true $false $key '' $false $true)
    }
    if ($Plan -isnot [Domenia.InterventionPlan]) { return (& $answer $false $false '' 'Aucun plan confirmé : rien nʼest envoyé.' $false) }
    if ((Get-DomeniaOperationEffect $Plan.Operation) -eq 'Read') { return (& $answer $true $false '' 'Lecture : relance possible, aucun effet à protéger.' $true) }
    $key = $Plan.Fingerprint.ToUpperInvariant()
    if ($Plan.Simulation) { return (& $answer $false $false $key 'Plan de simulation : aucun envoi.' $false) }
    if ($Origin -notin @('Operator','Batch')) { return (& $answer $false $false $key 'Aucune modification nʼest envoyée automatiquement (démarrage, reprise ou nouvel essai) : geste explicite requis.' $false) }
    if ($null -eq $Registry) { return (& $answer $false $false $key 'Registre des envois indisponible : envoi refusé.' $false) }
    if ($Registry.Plans.ContainsKey($Plan.Id)) { return (& $answer $false $true $key 'Ce plan confirmé a déjà été utilisé : une confirmation ne part quʼune fois. Préparez un nouveau plan.' $false) }
    if ($Registry.Entries.ContainsKey($key)) {
        $entry = $Registry.Entries[$key]
        switch ([string]$entry.State) {
            { $_ -in @('Reserved','Sent') } { return (& $answer $false $true $key 'Demande identique déjà envoyée : un seul envoi.' $false) }
            'Uncertain' { return (& $answer $false $true $key 'Demande identique à vérifier : aucun nouvel envoi avant la vérification du reçu.' $false) }
        }
        # Verified, Reviewed, NotSent or Failed (certainly not applied, see Set-DomeniaWriteOutcome):
        # a NEW confirmation of the same change may be sent.
    }
    if ($CheckOnly) { return (& $answer $true $false $key '' $false $false) }
    $Registry.Sequence = [int]$Registry.Sequence + 1
    $Registry.Entries[$key] = [pscustomobject]@{Key=$key;Operation=$Plan.Operation;State='Reserved';PlanId=$Plan.Id;Origin=$Origin;Sequence=$Registry.Sequence}
    $Registry.Plans[$Plan.Id] = $key
    return (& $answer $true $false $key '' $false $true)
}

function Set-DomeniaWriteOutcome {
    # Records what happened to an admitted request. Once sent, a request never becomes "not sent" again,
    # and an uncertain one is only resolved by a verification or a recorded review.
    # Failed means "certainly not applied": never dispatched (from Reserved), or refused by the controller itself,
    # proven by its LDAP result code (1-80) for a directory write. A process error, a timeout or a lost connection
    # after dispatch (no code, or a client-side code from 81 up) proves nothing: the request may have been
    # applied, so it is marked Uncertain and verified, and never re-admitted as a failure.
    param(
        $Registry,
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][ValidateSet('Sent','Verified','Uncertain','NotSent','Failed','Reviewed','Delivered')][string]$Outcome,
        [int]$ControllerResultCode=0
    )
    $normalized = $Key.Trim().ToUpperInvariant()
    if (($null -eq $Registry) -or (-not $Registry.Entries.ContainsKey($normalized))) { return [pscustomobject]@{Accepted=$false;State='';Reason='Demande inconnue du registre.'} }
    $entry = $Registry.Entries[$normalized]
    $current = [string]$entry.State
    $allowed = @{
        'Reserved'=@('Sent','NotSent','Failed','Uncertain','Verified','Delivered')
        'Sent'=@('Verified','Uncertain','Failed','Reviewed','Delivered')
        'Uncertain'=@('Verified','Reviewed')
    }
    $reason = ''
    if (-not $allowed.ContainsKey($current)) { $reason = 'Demande déjà résolue (' + $current + ').' }
    elseif ($allowed[$current] -notcontains $Outcome) {
        if ($current -eq 'Uncertain') { $reason = 'Issue incertaine : seule une vérification ou une revue consignée la résout.' }
        elseif (($current -eq 'Sent') -and ($Outcome -eq 'NotSent')) { $reason = 'Une demande envoyée ne redevient jamais « non envoyée ».' }
        else { $reason = 'Transition refusée : ' + $current + ' vers ' + $Outcome + '.' }
    } elseif (($current -eq 'Sent') -and ($Outcome -eq 'Failed')) {
        $directory = ((Get-DomeniaOperationEffect ([string]$entry.Operation)) -eq 'DirectoryWrite')
        $refused = ($directory -and ($ControllerResultCode -ge 1) -and ($ControllerResultCode -le 80))
        if (-not $refused) { $reason = 'Échec signalé après lʼenvoi sans refus prouvé du contrôleur (code LDAP 1 à 80) : la demande a pu sʼappliquer. Marquez-la à vérifier ; elle nʼest pas renvoyée.' }
    }
    if ($reason) { return [pscustomobject]@{Accepted=$false;State=$current;Reason=$reason} }
    $entry.State = $Outcome
    return [pscustomobject]@{Accepted=$true;State=$Outcome;Reason=''}
}

# ---------------------------------------------------------------- D096 concurrency with other administrators
function Get-DomeniaAtomicStrategy {
    # Single-valued text attribute: the old value is deleted and the new one added in the SAME LDAP modify
    # request, so the controller refuses it when someone else changed the value. Otherwise: re-read on the
    # planned controller before and after, with the limit stated. No transaction is ever promised.
    param(
        [Parameter(Mandatory=$true)][string]$Attribute,
        [ValidateSet('Text','Integer','Boolean','Date','DN','Binary','Other')][string]$Syntax='Text',
        [bool]$SingleValued=$true,
        [AllowEmptyString()][AllowNull()][string]$Before='',
        [AllowEmptyString()][AllowNull()][string]$After='',
        [bool]$ConditionalSupported=$true
    )
    $transactionLimit = 'Aucune transaction entre plusieurs objets ni entre plusieurs requêtes : chaque requête est appliquée ou refusée seule.'
    $operations = New-Object 'System.Collections.Generic.List[object]'
    $build = { param([string]$strategy,[bool]$atomic,[string]$limit,[int[]]$codes) [pscustomobject]@{Attribute=$Attribute;Strategy=$strategy;Atomic=$atomic;SingleRequest=($operations.Count -gt 0);Operations=$operations.ToArray();PreRead=($strategy -ne 'NotApplicable');PostRead=($strategy -notin @('NotApplicable','NoChange'));ConflictCodes=$codes;Limit=$limit;Transaction=$false;TransactionLimit=$transactionLimit} }
    if (Test-DomeniaSecretAttribute $Attribute) { return (& $build 'NotApplicable' $false 'Attribut secret : opération dédiée, sa valeur nʼest ni comparée ni relue.' @()) }
    if ([string]$Before -ceq [string]$After) { return (& $build 'NoChange' $false 'Valeur identique : aucune écriture.' @()) }
    if ($SingleValued -and ($Syntax -eq 'Text') -and $ConditionalSupported) {
        if ($Before) { $operations.Add([pscustomobject]@{Op='Delete';Value=[string]$Before}) }
        if ($After) { $operations.Add([pscustomobject]@{Op='Add';Value=[string]$After}) }
        $strategy = 'ConditionalReplace'
        if (-not $Before) { $strategy = 'ConditionalAdd' } elseif (-not $After) { $strategy = 'ConditionalDelete' }
        # 16 noSuchAttribute (old value gone), 19 constraintViolation and 20 attributeOrValueExists (a value appeared).
        return (& $build $strategy $true 'Condition vérifiée par le contrôleur dans la même requête : une valeur modifiée ailleurs fait échouer la requête sans rien écraser. La comparaison suit la règle de lʼattribut (souvent insensible à la casse).' @(16,19,20))
    }
    $why = 'condition non prise en charge par ce chemin dʼécriture'
    if (-not $SingleValued) { $why = 'attribut multivalué' } elseif ($Syntax -ne 'Text') { $why = 'syntaxe ' + $Syntax }
    if ($After) { $operations.Add([pscustomobject]@{Op='Replace';Value=[string]$After}) } else { $operations.Add([pscustomobject]@{Op='Clear';Value=''}) }
    return (& $build 'ReadBeforeAfter' $false ('Pas de condition atomique (' + $why + ') : relecture sur le contrôleur prévu juste avant lʼenvoi, puis après. Une écriture concurrente entre ces deux lectures nʼest pas empêchée ; elle est signalée par la version de lʼattribut quand les métadonnées de réplication sont lisibles.') @())
}

function Test-DomeniaPreconditionCurrent {
    # Re-read on the planned controller just before sending: every "before" value of the plan must still be there.
    # $Current: attribute -> value(s) as re-read. Every attribute of the plan must be named, with an empty value
    # when it was read empty: one left out was not read (an LDAP answer omits an unreadable attribute like an
    # empty one), so nothing is sent. A difference means another change happened: nothing is sent either.
    param([object[]]$Changes=@(),[Collections.IDictionary]$Current=$null,[AllowEmptyString()][string]$Server='')
    if ($null -eq $Current) { return [pscustomobject]@{Current=$false;Conflicts=@();Unread=@();Text='Relecture préalable absente : rien nʼest envoyé.'} }
    $conflicts = New-Object 'System.Collections.Generic.List[object]'
    $unread = New-Object 'System.Collections.Generic.List[string]'
    foreach ($change in @(ConvertTo-DomeniaPlanChanges $Changes)) {
        if ((Test-DomeniaSecretAttribute $change.Attribute) -or ($change.Kind -eq 'Reset')) { continue }
        if (-not (Test-DomeniaMemberPresent $Current $change.Attribute)) { $unread.Add($change.Attribute); continue }
        $asDn = ($change.Kind -eq 'Move')
        $raw = @(@(Get-DomeniaMember $Current $change.Attribute @()) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        $observed = @($raw | ForEach-Object { ConvertTo-DomeniaComparableValue $change.Attribute $_ $asDn })
        $before = ConvertTo-DomeniaComparableValue $change.Attribute $change.Before $asDn
        $after = ConvertTo-DomeniaComparableValue $change.Attribute $change.After $asDn
        $ok = $true
        switch ($change.Kind) {
            'Add' { $ok = ($observed -cnotcontains $after) }
            'Remove' { $ok = ($observed -ccontains $before) }
            'Move' { $ok = (($observed.Count -eq 1) -and ($observed[0] -ceq $before)) }
            default {
                if ($observed.Count -gt 1) { $ok = $false }
                elseif ($observed.Count -eq 1) { $ok = ($observed[0] -ceq $before) }
                else { $ok = [string]::IsNullOrEmpty($change.Before) }
            }
        }
        if (-not $ok) { $conflicts.Add([pscustomobject]@{Attribute=$change.Attribute;Kind=$change.Kind;Expected=$change.Before;Observed=($raw -join '; ')}) }
    }
    $where = ''
    if ($Server) { $where = ' sur ' + $Server }
    $parts = New-Object 'System.Collections.Generic.List[string]'
    if ($conflicts.Count) { $parts.Add('Modifié ailleurs depuis lʼaperçu' + $where + ' (' + (@($conflicts | ForEach-Object { $_.Attribute }) -join ', ') + ') : rien nʼest envoyé, rien nʼest écrasé. Relisez puis préparez un nouveau plan.') }
    if ($unread.Count) { $parts.Add('Préconditions non relues' + $where + ' (' + ($unread.ToArray() -join ', ') + ') : un attribut absent de la relecture nʼest pas un attribut vide, rien nʼest envoyé.') }
    $text = 'Préconditions relues' + $where + ' : inchangées.'
    if ($parts.Count) { $text = $parts.ToArray() -join ' ' }
    return [pscustomobject]@{Current=(($conflicts.Count -eq 0) -and ($unread.Count -eq 0));Conflicts=$conflicts.ToArray();Unread=$unread.ToArray();Text=$text}
}

function Resolve-DomeniaConditionalWrite {
    # Interprets the controller answer for the chosen strategy. The result code is mandatory: no answer is never
    # read as a success. Codes 1-80 come from the controller: the request was refused and nothing was applied
    # (a refused condition is a detected conflict: nothing was overwritten). A negative code or one from 81 up
    # is client-side (server down, timeout, connection lost...): the request may have been applied, so the
    # outcome is unknown. Nothing is ever retried here.
    param([Parameter(Mandatory=$true)]$Strategy,[Parameter(Mandatory=$true)][int]$ResultCode,$VersionBefore=$null,$VersionAfter=$null)
    $name = [string](Get-DomeniaMember $Strategy 'Strategy' '')
    $make = { param([string]$outcome,[bool]$overwrote,[string]$text) [pscustomobject]@{Outcome=$outcome;OverwroteExternalChange=$overwrote;Retry=$false;Text=$text} }
    if ($name -in @('NoChange','NotApplicable')) { return (& $make 'NotSent' $false 'Aucune écriture envoyée.') }
    if (($ResultCode -lt 0) -or ($ResultCode -gt 80)) { return (& $make 'Unknown' $false ('Pas de réponse du contrôleur (code client ' + $ResultCode + ') : lʼécriture a pu sʼappliquer, issue à vérifier. Aucun nouvel essai automatique.')) }
    if ($name -like 'Conditional*') {
        if ($ResultCode -eq 0) { return (& $make 'Applied' $false 'Condition vérifiée par le contrôleur : valeur remplacée.') }
        if ($ResultCode -in @(16,19,20)) { return (& $make 'Conflict' $false 'La valeur a changé sur le contrôleur depuis la relecture : rien nʼa été écrasé. Relisez puis préparez un nouveau plan.') }
        return (& $make 'Error' $false ('Requête refusée par le contrôleur (code LDAP ' + $ResultCode + ') : rien nʼa été appliqué.'))
    }
    if ($ResultCode -ne 0) { return (& $make 'Error' $false ('Requête refusée par le contrôleur (code LDAP ' + $ResultCode + ') : rien nʼa été appliqué.')) }
    $before = 0L; $after = 0L
    $known = (($null -ne $VersionBefore) -and ($null -ne $VersionAfter) -and [long]::TryParse([string]$VersionBefore,[ref]$before) -and [long]::TryParse([string]$VersionAfter,[ref]$after))
    if (-not $known) { return (& $make 'AppliedUnchecked' $false 'Écriture acceptée. Écriture concurrente non détectable : métadonnées de réplication illisibles.') }
    if (($after - $before) -gt 1) { return (& $make 'ConcurrentWriteSuspected' $true ('Version de lʼattribut passée de ' + $before + ' à ' + $after + ' : une autre écriture lʼa aussi modifié. Vérifiez la valeur actuelle.')) }
    if (($after - $before) -eq 1) { return (& $make 'Applied' $false 'Version de lʼattribut +1 : aucune autre écriture détectée.') }
    return (& $make 'Unconfirmed' $false 'Version de lʼattribut inchangée : écriture non constatée, à vérifier.')
}

# ---------------------------------------------------------------- D097 locks scoped to target and action class
function Get-DomeniaLockClass {
    # Action class used by the locks. Unknown operations are treated as writes (fail closed).
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$OperationId)
    switch (Get-DomeniaOperationEffect $OperationId) {
        'DirectoryWrite' { return 'Write' }
        'RemoteMutation' { return 'Remote' }
        'LocalWrite' { return 'Local' }
        'Read' { return 'Read' }
        default { return 'Write' }
    }
}

function New-DomeniaOperationLock {
    # A lock names the objects an operation touches (group AND member, object AND destination...) and its class.
    # A read or a local save never takes a lock, unless -AsWrite (a receipt naming one is kept locked as a write).
    # Targets: Domenia.SelectionIdentity (preferred: GUID and DN), GUID or DN. A mutation whose targets are
    # missing or not recognised locks every target of its class (fail closed).
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$OperationId,
        [object[]]$Targets=@(),
        [ValidateSet('Running','Uncertain')][string]$State='Running',
        [AllowEmptyString()][string]$Id='',
        [switch]$AsWrite
    )
    $class = Get-DomeniaLockClass $OperationId
    if ($class -in @('Read','Local')) {
        if (-not $AsWrite) { return $null }
        $class = 'Write'
    }
    $resolved = Resolve-DomeniaTargetKeys $Targets
    $keys = @($resolved.Keys)
    if ((-not $keys.Count) -or (@($resolved.Invalid).Count -gt 0)) { $keys = @('*') }
    return [pscustomobject]@{Id=$Id;OperationId=$OperationId;Class=$class;State=$State;Targets=$keys}
}

function Get-DomeniaReceiptLocks {
    # Receipts left uncertain by a previous run lock their own target, not the whole application.
    param([object[]]$Receipts=@())
    foreach ($receipt in @($Receipts)) {
        if ($null -eq $receipt) { continue }
        if (-not (Get-DomeniaReceiptResumeState $receipt).Uncertain) { continue }
        $targets = @(@([string](Get-DomeniaMember $receipt 'Guid' ''),[string](Get-DomeniaMember $receipt 'DN' '')) | Where-Object { $_ })
        $operation = [string](Get-DomeniaMember $receipt 'Operation' '')
        # A receipt naming a read or a local save cannot belong to a sent mutation: it stays locked as a write anyway.
        New-DomeniaOperationLock -OperationId $operation -Targets $targets -State Uncertain -Id ([string](Get-DomeniaMember $receipt 'Id' '')) -AsWrite
    }
}

function Test-DomeniaOperationAllowed {
    # Lock check by target and action class. On a target held by a directory write or a remote action, running
    # or uncertain, every mutation waits: directory write, remote action and editing alike, whatever their class
    # (a rename touches the workstation, a remote script may change the object...). Reads are never blocked,
    # neither on that target (they are how it gets verified) nor on any other; a local save touches no target.
    # While a directory write is running, the other directory writes wait too, on every target (one at a time).
    # Targets: Domenia.SelectionIdentity (preferred), GUID or DN. Anything else is refused for a mutation.
    # A DN alone cannot tell two objects apart (it changes with a move or a rename): when the check or a lock
    # names no GUID, the objects are not provably different and the mutation waits.
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$OperationId,
        [object[]]$Targets=@(),
        [object[]]$Locks=@(),
        [ValidateSet('Run','Edit')][string]$Action='Run',
        [bool]$SerializeWrites=$true
    )
    $class = 'Edit'
    if ($Action -eq 'Run') { $class = Get-DomeniaLockClass $OperationId }
    $resolved = Resolve-DomeniaTargetKeys $Targets
    $keys = @($resolved.Keys)
    $hasGuid = (@($keys | Where-Object { $_ -like 'guid:*' }).Count -gt 0)
    $active = @(@($Locks) | Where-Object { $null -ne $_ })
    $answer = { param([bool]$allowed,[string]$why,[string]$note,$blocking) [pscustomobject]@{Allowed=$allowed;Class=$class;Reason=$why;Note=$note;Blocking=$blocking} }
    $keysOf = {
        param($lock)
        $lockResolved = Resolve-DomeniaTargetKeys @(Get-DomeniaMember $lock 'Targets' @())
        $found = @($lockResolved.Keys)
        if ((-not $found.Count) -or (@($lockResolved.Invalid).Count -gt 0)) { $found = @('*') }
        $found
    }
    if ($class -in @('Read','Local')) {
        $note = ''
        foreach ($lock in $active) {
            $lockKeys = @(& $keysOf $lock)
            $overlap = (($lockKeys -contains '*') -or (@($keys | Where-Object { $lockKeys -contains $_ }).Count -gt 0))
            if ($overlap -and ($keys.Count -gt 0) -and ([string](Get-DomeniaMember $lock 'State' '') -eq 'Running')) { $note = 'Lecture pendant une modification de cette cible : la valeur lue peut précéder sa fin.' }
        }
        return (& $answer $true '' $note $null)
    }
    if (@($resolved.Invalid).Count) { return (& $answer $false ('Cible non reconnue (' + (@($resolved.Invalid) -join ', ') + ') : une modification désigne chaque objet par son identité, son GUID ou son DN.') '' $null) }
    if (-not $keys.Count) { return (& $answer $false 'Cible requise : une modification sans cible identifiée est refusée.' '' $null) }
    foreach ($lock in $active) {
        # An unexpected class or state is read as the most restrictive one.
        $lockClass = [string](Get-DomeniaMember $lock 'Class' 'Write')
        if ($lockClass -ne 'Remote') { $lockClass = 'Write' }
        $lockState = [string](Get-DomeniaMember $lock 'State' 'Uncertain')
        if ($lockState -ne 'Running') { $lockState = 'Uncertain' }
        $lockKeys = @(& $keysOf $lock)
        $overlap = (($lockKeys -contains '*') -or ($keys -contains '*') -or (@($keys | Where-Object { $lockKeys -contains $_ }).Count -gt 0))
        $lockHasGuid = (@($lockKeys | Where-Object { $_ -like 'guid:*' }).Count -gt 0)
        $notProvablyOther = ((-not $overlap) -and ((-not $hasGuid) -or (-not $lockHasGuid)))
        $operation = [string](Get-DomeniaMember $lock 'OperationId' '')
        $what = 'Écriture'
        if ($lockClass -eq 'Remote') { $what = 'Action à distance' }
        $stateText = 'à vérifier'
        if ($lockState -eq 'Running') { $stateText = 'en cours' }
        $why = ''
        if ($overlap) {
            if ($lockState -eq 'Running') { $why = $what + ' en cours sur cette cible (' + $operation + ') : modifications, actions à distance et édition attendent sa vérification.' }
            else { $why = $what + ' à vérifier sur cette cible (' + $operation + ') : modifications, actions à distance et édition bloquées jusquʼà la vérification du reçu. Les lectures restent possibles.' }
        } elseif ($notProvablyOther) {
            $why = $what + ' ' + $stateText + ' (' + $operation + ') : un objet désigné sans GUID ne peut pas être distingué de sa cible (un DN change avec un déplacement ou un renommage). Désignez les objets par leur identité. Les lectures restent possibles.'
        } elseif (($lockClass -eq 'Write') -and ($class -eq 'Write') -and ($lockState -eq 'Running') -and $SerializeWrites) {
            $why = 'Une écriture est en cours (' + $operation + ') : les écritures partent une par une.'
        }
        if ($why) { return (& $answer $false $why '' $lock) }
    }
    return (& $answer $true '' '' $null)
}

# ---------------------------------------------------------------- D100 limited and honest rollback
function Get-DomeniaCompensation {
    # One operation at a time. A compensation is a NEW write with its own plan, confirmation, receipt and
    # verification, offered only while its preconditions can be re-read and still hold.
    # $Current: {ReadStatus, Guid, DN, Values (attribute -> value(s)), OriginalParentExists}. Values must name every
    # attribute of the plan, with an empty value when it was read empty: one left out was not read, and a value
    # that was not read is never taken as empty (nothing is offered).
    param($Plan,[ValidateSet('Verifie','Partiel','A verifier')][string]$OriginalStatus='A verifier',$Current=$null)
    $notCovered = 'Ne concerne ni le code de Domenia ni le cache local : seule la modification AD est compensée.'
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $refuse = { param([string]$why) [pscustomobject]@{Offered=$false;Reason=$why;OperationId='';Changes=@();Preconditions=$rows.ToArray();Scope='Annuaire';NewPlanRequired=$true;Automatic=$false;NotCovered=$notCovered} }
    if (($Plan -is [array]) -or ($Plan -is [Collections.IList])) { return (& $refuse 'Une compensation porte sur une seule opération : pas dʼannulation globale.') }
    if ($Plan -isnot [Domenia.InterventionPlan]) { return (& $refuse 'Plan dʼorigine absent : aucune compensation ne peut être établie.') }
    $operation = $Plan.Operation
    if ($operation -in @('WriteResetPassword','WriteExpirePassword')) { return (& $refuse 'Un mot de passe modifié nʼest pas restaurable : lʼancien nʼest ni connu ni conservé.') }
    if ($operation -eq 'WriteDeleteObject') { return (& $refuse 'Une suppression ne se compense pas ici : la restauration relève de la corbeille AD ou dʼune sauvegarde, avec ses propres contrôles.') }
    if ($operation -eq 'WriteCreateOu') { return (& $refuse 'Compenser une création reviendrait à supprimer : jamais proposé.') }
    if ($operation -eq 'WriteUnlock') { return (& $refuse 'Un déverrouillage ne se compense pas.') }
    if ($operation -eq 'WriteRenameComputer') { return (& $refuse 'Le renommage touche aussi le poste et le DNS : pas de compensation proposée.') }
    if ((Get-DomeniaOperationEffect $operation) -eq 'RemoteMutation') { return (& $refuse 'Action à distance déjà produite (redémarrage, stratégies, exécution ou réveil) : aucun inverse.') }
    if ($operation -notin @('WriteAttributes','WriteGroupMember','WriteObjectGroup','WriteMoveObject','WriteAccountDisabled','WriteExpiration','WriteAccountOptions')) { return (& $refuse 'Aucune compensation définie pour cette opération.') }
    foreach ($change in @($Plan.Changes)) {
        if ((Test-DomeniaSecretAttribute $change.Attribute) -or ($change.Kind -eq 'Reset')) { return (& $refuse 'Un mot de passe ou un secret modifié nʼest pas restaurable.') }
    }
    if (-not @($Plan.Changes).Count) { return (& $refuse 'Plan sans valeurs avant et après : la compensation ne peut pas être établie.') }
    if ($OriginalStatus -eq 'A verifier') { return (& $refuse 'Issue dʼorigine non vérifiée : vérifiez le reçu avant toute compensation.') }
    if (($null -eq $Current) -or ([string](Get-DomeniaMember $Current 'ReadStatus' '') -ne 'OK')) { return (& $refuse 'Préconditions non vérifiables : relecture absente ou refusée.') }
    if ((ConvertTo-DomeniaGuidText (Get-DomeniaMember $Current 'Guid' '')) -ine $Plan.Target.Guid) { return (& $refuse 'Objet relu différent de la cible dʼorigine : rien nʼest proposé.') }
    $values = Get-DomeniaMember $Current 'Values' $null
    $inverse = New-Object 'System.Collections.Generic.List[object]'
    foreach ($change in @($Plan.Changes)) {
        if ($change.Kind -eq 'Move') { $unread = (-not [string](Get-DomeniaMember $Current 'DN' '')) }
        else { $unread = (-not (Test-DomeniaMemberPresent $values $change.Attribute)) }
        if ($unread) {
            $rows.Add([pscustomobject]@{Attribute=$change.Attribute;Expected=$change.After;Observed='non relu';Met=$false})
            return (& $refuse ('Préconditions non vérifiables : ' + $change.Attribute + ' absent de la relecture. Une valeur non relue nʼest pas une valeur vide : rien nʼest proposé.'))
        }
        $raw = @(@(Get-DomeniaMember $values $change.Attribute @()) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        $observed = @($raw | ForEach-Object { ConvertTo-DomeniaComparableValue $change.Attribute $_ })
        $before = ConvertTo-DomeniaComparableValue $change.Attribute $change.Before
        $after = ConvertTo-DomeniaComparableValue $change.Attribute $change.After
        $applied = $false; $untouched = $false; $undo = $null; $shown = ($raw -join '; ')
        switch ($change.Kind) {
            'Add' {
                $applied = ($observed -ccontains $after); $untouched = (-not $applied)
                $undo = New-Object Domenia.PlanChange -ArgumentList @($change.Attribute,'Remove',$change.After,'')
            }
            'Remove' {
                $applied = ($observed -cnotcontains $before); $untouched = (-not $applied)
                $undo = New-Object Domenia.PlanChange -ArgumentList @($change.Attribute,'Add','',$change.Before)
            }
            'Move' {
                $shown = [string](Get-DomeniaMember $Current 'DN' '')
                $here = ConvertTo-DomeniaComparableValue '' $shown $true
                $applied = ([bool]$shown -and ($here -ceq (ConvertTo-DomeniaComparableValue '' $change.After $true)))
                $untouched = ([bool]$shown -and ($here -ceq (ConvertTo-DomeniaComparableValue '' $change.Before $true)))
                if ($applied -and (-not [bool](Get-DomeniaMember $Current 'OriginalParentExists' $false))) {
                    $rows.Add([pscustomobject]@{Attribute=$change.Attribute;Expected=$change.After;Observed=$shown;Met=$false})
                    return (& $refuse 'Conteneur dʼorigine absent ou non vérifié : le retour à lʼemplacement initial nʼest pas proposé.')
                }
                $undo = New-Object Domenia.PlanChange -ArgumentList @($change.Attribute,'Move',$change.After,$change.Before)
            }
            default {
                $single = $null
                if ($observed.Count -eq 0) { $single = '' } elseif ($observed.Count -eq 1) { $single = $observed[0] }
                $applied = (($null -ne $single) -and ($single -ceq $after))
                $untouched = (($null -ne $single) -and ($single -ceq $before))
                $kind = 'Replace'
                if ([string]::IsNullOrEmpty($change.Before)) { $kind = 'Clear' }
                $undo = New-Object Domenia.PlanChange -ArgumentList @($change.Attribute,$kind,$change.After,$change.Before)
            }
        }
        $rows.Add([pscustomobject]@{Attribute=$change.Attribute;Expected=$change.After;Observed=$shown;Met=$applied})
        if ($applied) { $inverse.Insert(0,$undo); continue }
        # After a partial operation, a change that never applied needs nothing.
        if ($untouched -and ($OriginalStatus -eq 'Partiel')) { continue }
        return (& $refuse ('Valeur modifiée depuis lʼopération (' + $change.Attribute + ') : la compensation écraserait un autre changement, elle nʼest pas proposée.'))
    }
    if (-not $inverse.Count) { return (& $refuse 'Rien à compenser : aucune modification de lʼopération nʼest présente.') }
    return [pscustomobject]@{
        Offered=$true;Reason='Compensation possible : nouvelle opération à confirmer, avec reçu et vérification.';OperationId=$operation
        Changes=[Domenia.PlanChange[]]$inverse.ToArray();Preconditions=$rows.ToArray();Scope='Annuaire';NewPlanRequired=$true;Automatic=$false;NotCovered=$notCovered
    }
}

# ---------------------------------------------------------------- L07 rules shared by the interface and the workers
function Test-DomeniaRawAttributeAllowed {
    # SE-02: one rule for a raw attribute write. The interface applies it before the confirmation and the
    # WriteAttributes worker applies it again (Test-WRawAttributeAllowed), whatever the interface did.
    # A raw write needs Security.AllowRawAttributeWrite; with Security.BlockSensitiveRawAttributes the block list applies.
    param(
        [AllowEmptyString()][AllowNull()][string]$Attribute,
        [bool]$AllowRaw=$false,
        [bool]$BlockSensitive=$true,
        [string[]]$BlockList=@()
    )
    $name = ([string]$Attribute).Trim()
    $answer = { param([bool]$allowed,[string]$why) [pscustomobject]@{Allowed=$allowed;Attribute=$name;Reason=$why} }
    if ($name -notmatch '^[A-Za-z][A-Za-z0-9-]{0,126}$') { return (& $answer $false 'Nom dʼattribut invalide.') }
    if (-not $AllowRaw) { return (& $answer $false 'Écriture brute désactivée par la configuration de sécurité (Security.AllowRawAttributeWrite).') }
    if ($BlockSensitive) {
        foreach ($blocked in @($BlockList)) {
            if (([string]$blocked).Trim() -ieq $name) { return (& $answer $false ('Attribut sensible, modification bloquée : ' + $name + '.')) }
        }
    }
    return (& $answer $true '')
}

function ConvertTo-DomeniaDnDisplayName {
    # Readable name of a DN for the operator: the value of its first relative name, or the dotted domain name when
    # the DN only has DC= parts. A text that is not a DN is returned flattened, as typed.
    param([AllowEmptyString()][AllowNull()][string]$Dn)
    $text = ([string]$Dn).Trim()
    if (-not (ConvertTo-DomeniaDnKey $text)) { return (ConvertTo-DomeniaFlatText $text 120) }
    $values = New-Object 'System.Collections.Generic.List[string]'
    $allDc = $true
    foreach ($part in @(Split-DomeniaDn $text)) {
        $equals = $part.IndexOf('=')
        if ($part.Substring(0,$equals).Trim() -ine 'DC') { $allDc = $false }
        $values.Add((ConvertFrom-DomeniaDnValue ($part.Substring($equals + 1).Trim())))
    }
    if ($allDc) { return (ConvertTo-DomeniaFlatText ($values.ToArray() -join '.') 120) }
    return (ConvertTo-DomeniaFlatText $values[0] 120)
}

function Test-DomeniaWriteTargetDn {
    # SE-12: a DN typed as a write target (group, member, destination) is accepted only when every relative name
    # reads <attribute>=<value>, it lies in the connected domain (BaseDn suffix, compared name by name), and it is
    # not in the configuration, schema or DNS application partitions that share the forest root suffix. The answer
    # names the target by its readable name; the DN itself only goes to the technical details.
    param([AllowEmptyString()][AllowNull()][string]$Dn,[AllowEmptyString()][AllowNull()][string]$BaseDn)
    $text = ([string]$Dn).Trim()
    $name = ConvertTo-DomeniaDnDisplayName $text
    $answer = { param([bool]$valid,[string]$why) [pscustomobject]@{Valid=$valid;Dn=$text;Name=$name;Reason=$why} }
    $baseKey = ConvertTo-DomeniaDnKey ([string]$BaseDn)
    if (-not $baseKey) { return (& $answer $false 'Domaine de connexion inconnu : aucune cible saisie nʼest acceptée.') }
    $key = ConvertTo-DomeniaDnKey $text
    $keyParts = @(Split-DomeniaDn $key)
    $empty = @($keyParts | Where-Object { -not ($_.Substring($_.IndexOf('=') + 1).Trim()) }).Count
    if ((-not $key) -or ($empty -gt 0)) { return (& $answer $false ('« ' + $name + ' » nʼest pas un nom distinctif valide : rien nʼest envoyé.')) }
    $baseParts = @(Split-DomeniaDn $baseKey)
    $inside = ($keyParts.Count -ge $baseParts.Count)
    if ($inside) {
        for ($i = 1; $i -le $baseParts.Count; $i++) {
            if ([string]$keyParts[$keyParts.Count - $i] -cne [string]$baseParts[$baseParts.Count - $i]) { $inside = $false; break }
        }
    }
    if (-not $inside) { return (& $answer $false ('« ' + $name + ' » est hors du domaine connecté : rien nʼest envoyé.')) }
    if ($keyParts.Count -gt $baseParts.Count) {
        $top = [string]$keyParts[$keyParts.Count - $baseParts.Count - 1]
        if ($top -in @('cn=configuration','dc=domaindnszones','dc=forestdnszones')) {
            return (& $answer $false ('« ' + $name + ' » appartient à la configuration de la forêt ou à une partition DNS : ce nʼest jamais une cible dʼécriture.'))
        }
    }
    return (& $answer $true '')
}

function Get-DomeniaPlanChangeText {
    # UX-08: each change of a plan in plain words, « Libellé : avant → après », for the confirmation in the page.
    # No DN and no GUID: a DN value is shown by its readable name, an empty value as « (vide) », a secret never.
    # Attribute names and raw values stay in the technical details (Format-DomeniaPlanConfirmation in the core).
    param([object[]]$Changes=@())
    $labels = @{
        givenname='Prénom';sn='Nom';displayname='Nom affiché';userprincipalname='Identifiant de connexion';mail='Adresse de messagerie'
        telephonenumber='Téléphone';physicaldeliveryofficename='Bureau';description='Description';title='Fonction';department='Service'
        company='Société';location='Emplacement';manager='Responsable';managedby='Géré par';accountexpires='Expiration du compte'
    }
    $flags = @{
        passwordneverexpires='Mot de passe sans expiration';passwordnotrequired='Mot de passe facultatif'
        allowreversiblepasswordencryption='Chiffrement réversible du mot de passe';smartcardlogonrequired='Carte à puce obligatoire'
        accountnotdelegated='Compte sensible, non délégable';doesnotrequirepreauth='Sans préauthentification Kerberos'
        usedeskeyonly='Chiffrement DES uniquement';trustedfordelegation='Approuvé pour la délégation'
        trustedtoauthfordelegation='Délégation avec transition de protocole'
    }
    $show = {
        param([string]$attribute,[AllowEmptyString()][string]$value)
        $v = ([string]$value).Trim()
        if (-not $v) { return '(vide)' }
        if (((Test-DomeniaDnValuedAttribute $attribute) -or ($v -match '^(?i:CN|OU|DC)\s*=')) -and (ConvertTo-DomeniaDnKey $v)) { return ('« ' + (ConvertTo-DomeniaDnDisplayName $v) + ' »') }
        if ($v -match '^\{?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}?$') { return '(identifiant, voir les détails techniques)' }
        return ('« ' + (ConvertTo-DomeniaFlatText $v 120) + ' »')
    }
    $yesNo = { param([string]$value) if ([string]$value -match '^(?i:true|1|oui)$') { 'oui' } else { 'non' } }
    $arrow = ' ' + [string][char]0x2192 + ' '
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($change in @(ConvertTo-DomeniaPlanChanges $Changes)) {
        $attribute = [string]$change.Attribute
        $lower = $attribute.ToLowerInvariant()
        $kind = [string]$change.Kind
        $before = [string]$change.Before
        $after = [string]$change.After
        if (($kind -eq 'Reset') -or (Test-DomeniaSecretAttribute $attribute)) { $lines.Add('Mot de passe : remplacé par la nouvelle valeur saisie, ni affichée ni conservée'); continue }
        if ($lower -eq 'useraccountcontrol') {
            $state = { param([string]$value) if ([string]$value -match '^(?i:desactive|désactivé|disabled)$') { 'désactivé' } elseif ([string]$value -match '^(?i:active|actif|enabled)$') { 'actif' } else { '' } }
            $from = & $state $before; $to = & $state $after
            if ($from -and $to) { $lines.Add('Compte : ' + $from + $arrow + $to); continue }
        }
        if (($lower -eq 'lockouttime') -and ($kind -eq 'Clear')) { $lines.Add('Compte : verrouillé' + $arrow + 'déverrouillé'); continue }
        if (($lower -eq 'pwdlastset') -and ($after -eq '0')) { $lines.Add('Changement du mot de passe à la prochaine connexion : imposé'); continue }
        if ($flags.ContainsKey($lower)) { $lines.Add($flags[$lower] + ' : ' + (& $yesNo $before) + $arrow + (& $yesNo $after)); continue }
        if ($kind -eq 'Move') {
            if ($lower -eq 'distinguishedname') {
                $from = Get-DomeniaOuDisplayPath (Get-DomeniaDnParent $before)
                $to = Get-DomeniaOuDisplayPath (Get-DomeniaDnParent $after)
                if (-not $from) { $from = '(inconnu)' }
                if (-not $to) { $to = '(inconnu)' }
                $lines.Add('Emplacement : « ' + $from + ' »' + $arrow + '« ' + $to + ' »')
            } else {
                $lines.Add('Nom : ' + (& $show '' $before) + $arrow + (& $show '' $after))
            }
            continue
        }
        if ($lower -eq 'memberof') {
            if ($kind -eq 'Add') { $lines.Add('Groupes : ajout à ' + (& $show 'member' $after)); continue }
            if ($kind -eq 'Remove') { $lines.Add('Groupes : retrait de ' + (& $show 'member' $before)); continue }
        }
        if ($lower -eq 'member') {
            if ($kind -eq 'Add') { $lines.Add('Membres : ajout de ' + (& $show 'member' $after)); continue }
            if ($kind -eq 'Remove') { $lines.Add('Membres : retrait de ' + (& $show 'member' $before)); continue }
        }
        $label = $attribute
        if ($labels.ContainsKey($lower)) { $label = $labels[$lower] }
        switch ($kind) {
            'Add' { $lines.Add($label + ' : ajout de ' + (& $show $attribute $after)) }
            'Remove' { $lines.Add($label + ' : retrait de ' + (& $show $attribute $before)) }
            default { $lines.Add($label + ' : ' + (& $show $attribute $before) + $arrow + (& $show $attribute $after)) }
        }
    }
    return $lines.ToArray()
}
