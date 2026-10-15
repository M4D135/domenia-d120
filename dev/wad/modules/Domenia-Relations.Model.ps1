# Relation rules between users and workstations: both directions, declared assignment versus
# observation, explainable qualification, stable context, in-page association, candidates built
# from several proofs, explicit detection perimeter, exact identity and history.
# Pure decisions: no probe, no LDAP read and no storage access is started here.

# ---------------------------------------------------------------- D041 both directions
function Get-DomeniaRelationDirection {
    param([Parameter(Mandatory=$true)][ValidateSet('Utilisateur','Machine','User','Computer')][string]$SubjectType)
    if ($SubjectType -in @('Utilisateur','User')) {
        return [pscustomobject]@{SourceType='Utilisateur';TargetType='Machine';Action='Associer ce poste';SearchLabel='Rechercher un poste';DetectLabel='Détecter les postes';EmptyHint='Aucun poste associé à cet utilisateur.'}
    }
    return [pscustomobject]@{SourceType='Machine';TargetType='Utilisateur';Action='Associer cet utilisateur';SearchLabel='Rechercher un utilisateur';DetectLabel='Lire la session de ce poste';EmptyHint='Aucun utilisateur associé à ce poste.'}
}

function ConvertTo-DomeniaRelationType {
    param([AllowEmptyString()][string]$Type)
    if ($Type -in @('Utilisateur','User')) { return 'Utilisateur' }
    if ($Type -in @('Machine','Computer','Poste')) { return 'Machine' }
    return ''
}

# ---------------------------------------------------------------- D044 stable context, double identity
function Test-DomeniaSameSubject {
    # Both descriptions must carry the same domain, GUID, type, reader, session and generation.
    param([AllowNull()]$Expected,[AllowNull()]$Actual)
    if ($null -eq $Expected -or $null -eq $Actual) { return $false }
    foreach ($key in @('Domain','Guid','Type','Reader','Session','Generation')) {
        $left = Get-DomeniaMember $Expected $key $null; $right = Get-DomeniaMember $Actual $key $null
        if ($null -eq $left -or $null -eq $right) { return $false }
        if ([string]::IsNullOrWhiteSpace([string]$left)) { return $false }
        if (-not [string]::Equals([string]$left,[string]$right,[StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return (Test-DomeniaGuidText ([string](Get-DomeniaMember $Expected 'Guid' '')))
}

function Test-DomeniaRelationConfirmation {
    # The source shown when the search began and the target shown when the operator confirms
    # must both still be the objects captured, and they must be of opposite types in one domain and session.
    param($SourceExpected,$SourceActual,$TargetExpected,$TargetActual)
    if (-not (Test-DomeniaSameSubject $SourceExpected $SourceActual)) { return $false }
    if (-not (Test-DomeniaSameSubject $TargetExpected $TargetActual)) { return $false }
    $sourceType = ConvertTo-DomeniaRelationType ([string](Get-DomeniaMember $SourceExpected 'Type' ''))
    if (-not $sourceType) { return $false }
    $direction = Get-DomeniaRelationDirection $sourceType
    if ((ConvertTo-DomeniaRelationType ([string](Get-DomeniaMember $TargetActual 'Type' ''))) -ne $direction.TargetType) { return $false }
    if ([string](Get-DomeniaMember $SourceActual 'Domain' '') -ine [string](Get-DomeniaMember $TargetActual 'Domain' '')) { return $false }
    if ([string](Get-DomeniaMember $SourceActual 'Session' '') -cne [string](Get-DomeniaMember $TargetActual 'Session' '')) { return $false }
    return $true
}

function Resolve-DomeniaRelationSubjectChange {
    # While a target is being searched or awaits confirmation, a new global selection does not replace the source subject.
    param($CurrentSubject,$NewSelection,[bool]$TargetSearchActive=$false,[bool]$PendingAssociation=$false)
    if ($null -eq $NewSelection) { return [pscustomobject]@{Change=$false;Reason='Aucune selection.'} }
    $type = ConvertTo-DomeniaRelationType ([string](Get-DomeniaMember $NewSelection 'Type' ''))
    if (-not $type) { return [pscustomobject]@{Change=$false;Reason='Seuls un utilisateur ou un poste portent des relations.'} }
    if ($null -eq $CurrentSubject) { return [pscustomobject]@{Change=$true;Reason=''} }
    $sameGuid = ([string](Get-DomeniaMember $CurrentSubject 'Guid' '')) -ieq ([string](Get-DomeniaMember $NewSelection 'Guid' ''))
    if ($sameGuid) { return [pscustomobject]@{Change=$false;Reason='Meme sujet.'} }
    if ($PendingAssociation) { return [pscustomobject]@{Change=$false;Reason='Une association attend sa confirmation : confirmez ou annulez avant de changer de sujet.'} }
    if ($TargetSearchActive) { return [pscustomobject]@{Change=$false;Reason='Recherche d une cible en cours : le sujet de depart est conserve.'} }
    return [pscustomobject]@{Change=$true;Reason=''}
}

# ---------------------------------------------------------------- D042 assignment versus observation
function Get-DomeniaRelationKind {
    # Closed vocabulary derived from the stored source text of a relation. The order matters:
    # an AD owner attribute is a clue, a LogonUI value or a profile is history, the current console is an observation.
    param([AllowEmptyString()][AllowNull()][string]$Source)
    $text = [string]$Source
    if ($text -match '(?i)responsable|managedby') { return 'Indice' }
    if ($text -match '(?i)saisie manuelle|manual|manuel|declar|affect') { return 'Affectation' }
    if ($text -match '(?i)import|csv') { return 'Importe' }
    if ($text -match '(?i)rdp|wts|session distante|terminal') { return 'SessionRdp' }
    if ($text -match '(?i)historique|journal|event|4624|harvest|logonui|logon|profil|registre') { return 'Historique' }
    if ($text -match '(?i)console|cim|dcom|explorer|interactive|computersystem|quser|utilisateur courant|winrm') { return 'Console' }
    if ($text -match '(?i)description|kerberos|indice|attribut|inventaire|wapt|glpi|mention') { return 'Indice' }
    return 'Inconnu'
}

function ConvertTo-DomeniaRelationLoginKey {
    # Comparable login: authority and UPN suffix removed, lower case. Empty when unusable.
    param([AllowEmptyString()][AllowNull()][string]$Login)
    $value = ([string]$Login).Trim()
    if ($value.Contains([string][char]92)) { $value = $value.Substring($value.LastIndexOf([char]92) + 1) }
    if ($value.Contains('@')) { $value = $value.Substring(0,$value.IndexOf('@')) }
    return $value.Trim().ToLowerInvariant()
}

function ConvertTo-DomeniaRelationComputerKey {
    # Comparable workstation name: first DNS label, no trailing $, lower case. Empty when unusable.
    param([AllowEmptyString()][AllowNull()][string]$Computer)
    $value = ([string]$Computer).Trim()
    if ($value.EndsWith('$')) { $value = $value.Substring(0,$value.Length - 1) }
    if ($value.Contains('.')) { $value = $value.Substring(0,$value.IndexOf('.')) }
    return $value.Trim().ToLowerInvariant()
}

function Get-DomeniaRelationKey {
    # One relation = one user, one workstation and one nature of proof. Several users per workstation are allowed.
    # The key is an identifier for journals and storage; equality decisions use Test-DomeniaSameRelation,
    # because a legacy row without GUID and the same row with GUID must not become two relations.
    param($Relation)
    $user = ConvertTo-DomeniaGuidText (Get-DomeniaMember $Relation 'UserGuid' '')
    if (-not $user) { $user = 'login:' + (ConvertTo-DomeniaRelationLoginKey ([string](Get-DomeniaMember $Relation 'UserLogin' ''))) }
    $computer = ConvertTo-DomeniaGuidText (Get-DomeniaMember $Relation 'ComputerGuid' '')
    if (-not $computer) { $computer = 'name:' + (ConvertTo-DomeniaRelationComputerKey ([string](Get-DomeniaMember $Relation 'Computer' ''))) }
    $kind = [string](Get-DomeniaMember $Relation 'Kind' '')
    if (-not $kind) { $kind = Get-DomeniaRelationKind ([string](Get-DomeniaMember $Relation 'Source' '')) }
    return ($user + '|' + $computer + '|' + $kind)
}

function Test-DomeniaSameRelation {
    # Same user, same workstation, same nature of proof. A GUID known on both sides decides (a renamed
    # account stays the same relation, a recreated object does not); otherwise normalized names decide.
    param($Left,$Right)
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    $leftKind = [string](Get-DomeniaMember $Left 'Kind' '')
    if (-not $leftKind) { $leftKind = Get-DomeniaRelationKind ([string](Get-DomeniaMember $Left 'Source' '')) }
    $rightKind = [string](Get-DomeniaMember $Right 'Kind' '')
    if (-not $rightKind) { $rightKind = Get-DomeniaRelationKind ([string](Get-DomeniaMember $Right 'Source' '')) }
    if ($leftKind -ne $rightKind) { return $false }
    $pairs = @(
        @('UserGuid','UserLogin','Login'),
        @('ComputerGuid','Computer','Computer')
    )
    foreach ($pair in $pairs) {
        $leftGuid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $Left $pair[0] '')
        $rightGuid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $Right $pair[0] '')
        if ($leftGuid -and $rightGuid) {
            if ($leftGuid -ne $rightGuid) { return $false }
            continue
        }
        if ($pair[2] -eq 'Login') {
            $leftName = ConvertTo-DomeniaRelationLoginKey ([string](Get-DomeniaMember $Left $pair[1] ''))
            $rightName = ConvertTo-DomeniaRelationLoginKey ([string](Get-DomeniaMember $Right $pair[1] ''))
        } else {
            $leftName = ConvertTo-DomeniaRelationComputerKey ([string](Get-DomeniaMember $Left $pair[1] ''))
            $rightName = ConvertTo-DomeniaRelationComputerKey ([string](Get-DomeniaMember $Right $pair[1] ''))
        }
        if (-not $leftName -or $leftName -ne $rightName) { return $false }
    }
    return $true
}

function Resolve-DomeniaRelationUpsert {
    # Decides how an incoming relation joins the stored ones. A declared assignment is never replaced by an
    # observation, and a temporary console session of another account does not remove the owner.
    param([object[]]$Existing=@(),$Incoming)
    if ($null -eq $Incoming) { return [pscustomobject]@{Action='Ignore';Replace=$null;Reason='Relation absente.'} }
    foreach ($relation in @($Existing)) {
        if ($null -eq $relation) { continue }
        if (Test-DomeniaSameRelation $relation $Incoming) { return [pscustomobject]@{Action='Refresh';Replace=$relation;Reason='Meme relation, meme nature : date et detail mis a jour.'} }
    }
    return [pscustomobject]@{Action='Add';Replace=$null;Reason='Nouvelle relation ajoutee sans retirer les relations existantes.'}
}

# ---------------------------------------------------------------- CO-29 relation dates
# Instants already read, by stored text, for the session: the same few thousand dates are sorted, qualified and shown
# on every refresh (review L04: three nested calls per date cost about one second for 3000 associations). A date
# text gives the same instant for the whole session (time zone of the workstation).
$script:DomeniaRelationWhenMemo = $null

function ConvertTo-DomeniaRelationUtcDate {
    # Date of a relation as a UTC DateTime, or $null. Relation dates are stored as UTC ISO 8601 ("o"). A date
    # without offset was written in local time before RC1.14 (manual and imported rows "yyyy-MM-dd HH:mm:ss",
    # Live rows "s"): it is read as local time, never as UTC. Texts are parsed once (same rules as
    # ConvertTo-DomeniaUtcDate -AssumeLocal) and kept in a bounded session memo.
    param($Value)
    if ($null -ne $Value -and $Value -isnot [string]) { return (ConvertTo-DomeniaUtcDate $Value -AssumeLocal) }
    $text = [string]$Value
    $memo = $script:DomeniaRelationWhenMemo
    if ($null -eq $memo -or $memo.Count -ge 50000) {
        $memo = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
        $script:DomeniaRelationWhenMemo = $memo
    }
    $known = $null
    if ($memo.TryGetValue($text,[ref]$known)) { return $known }
    $utc = $null
    $trimmed = $text.Trim()
    if ($trimmed) {
        # An AD FILETIME written as digits keeps the general reader; every relation date is a date text.
        if ($trimmed -match '^\d{12,19}$') { $utc = ConvertTo-DomeniaUtcDate $trimmed -AssumeLocal }
        else {
            $parsed = [datetime]::MinValue
            $styles = [Globalization.DateTimeStyles]::AssumeLocal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
            if ([datetime]::TryParse($trimmed,[Globalization.CultureInfo]::InvariantCulture,$styles,[ref]$parsed)) { $utc = $parsed }
        }
    }
    $memo[$text] = $utc
    return $utc
}

function Get-DomeniaRelationWhenTicks {
    # CO-29: UTC ticks of many relation dates in one call (0 when unreadable), for sorting without one call per row.
    param([AllowEmptyCollection()][string[]]$Values=@())
    $list = @($Values)
    $ticks = New-Object 'long[]' $list.Count
    for ($i = 0; $i -lt $list.Count; $i++) {
        $utc = ConvertTo-DomeniaRelationUtcDate ([string]$list[$i])
        if ($null -ne $utc) { $ticks[$i] = $utc.Ticks }
    }
    return ,$ticks
}

function ConvertTo-DomeniaRelationWhenText {
    # Storage form of a relation date: UTC ISO 8601 ("o"). An unreadable value gives '' (the caller decides).
    param($Value)
    $utc = ConvertTo-DomeniaRelationUtcDate $Value
    if ($null -eq $utc) { return '' }
    return $utc.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
}

function Format-DomeniaRelationWhen {
    # Local display of a relation date: "08/10 09:15" this year, "08/10/2025 09:15" for another year, '' when unreadable.
    param($Value,$NowUtc=$null)
    $utc = $Value
    if ($Value -isnot [datetime] -or $Value.Kind -ne [DateTimeKind]::Utc) { $utc = ConvertTo-DomeniaRelationUtcDate $Value }
    if ($null -eq $utc) { return '' }
    $now = $null
    if ($null -ne $NowUtc) { $now = ConvertTo-DomeniaUtcDate $NowUtc }
    if ($null -eq $now) { $now = [datetime]::UtcNow }
    $local = $utc.ToLocalTime()
    $format = 'dd/MM HH:mm'
    if ($local.Year -ne $now.ToLocalTime().Year) { $format = 'dd/MM/yyyy HH:mm' }
    return $local.ToString($format,[Globalization.CultureInfo]::InvariantCulture)
}

function Get-DomeniaRelationWhenSortKey {
    # Sort key of the Date columns: the UTC instant; an unreadable date sorts as the oldest.
    param($Value)
    $utc = ConvertTo-DomeniaRelationUtcDate $Value
    if ($null -eq $utc) { return [datetime]::MinValue }
    return $utc
}

function Select-DomeniaPrimaryRelation {
    # The relation shown first for a workstation: a declared assignment, otherwise the most recent relation.
    param([object[]]$Relations=@())
    $best = $null; $bestDeclared = $false; $bestWhen = $null
    foreach ($relation in @($Relations)) {
        if ($null -eq $relation) { continue }
        $kind = [string](Get-DomeniaMember $relation 'Kind' '')
        if (-not $kind) { $kind = Get-DomeniaRelationKind ([string](Get-DomeniaMember $relation 'Source' '')) }
        $declared = ($kind -eq 'Affectation')
        $when = ConvertTo-DomeniaRelationUtcDate (Get-DomeniaMember $relation 'When' $null)
        if ($null -eq $best) { $best = $relation; $bestDeclared = $declared; $bestWhen = $when; continue }
        if ($declared -and -not $bestDeclared) { $best = $relation; $bestDeclared = $true; $bestWhen = $when; continue }
        if ($declared -ne $bestDeclared) { continue }
        if ($null -ne $when -and ($null -eq $bestWhen -or $when -gt $bestWhen)) { $best = $relation; $bestWhen = $when }
    }
    return $best
}

function Resolve-DomeniaRelationStoragePlacement {
    # The RC1.10 local store keeps one row per workstation (computer_key). Until it keeps one row per relation,
    # the stored row of a workstation is chosen without ever replacing a declared assignment; among the other
    # natures the most recent relation is stored. The relation that is not stored stays visible for the session,
    # marked as such, and is never silently dropped.
    param($Stored,$Incoming,[bool]$MultiRelationStorage=$false)
    if ($null -eq $Incoming) { return [pscustomobject]@{Placement='Ignore';Demoted=$null;Reason='Relation absente.'} }
    if ($MultiRelationStorage) { return [pscustomobject]@{Placement='Stored';Demoted=$null;Reason='Relation enregistree a cote des relations existantes.'} }
    if ($null -eq $Stored) { return [pscustomobject]@{Placement='Stored';Demoted=$null;Reason='Premiere relation enregistree pour ce poste.'} }
    $storedKind = [string](Get-DomeniaMember $Stored 'Kind' '')
    if (-not $storedKind) { $storedKind = Get-DomeniaRelationKind ([string](Get-DomeniaMember $Stored 'Source' '')) }
    $incomingKind = [string](Get-DomeniaMember $Incoming 'Kind' '')
    if (-not $incomingKind) { $incomingKind = Get-DomeniaRelationKind ([string](Get-DomeniaMember $Incoming 'Source' '')) }
    if ($storedKind -eq 'Affectation') {
        return [pscustomobject]@{Placement='Session';Demoted=$null;Reason='Affectation declaree conservee : le stockage local ne garde qu une relation par poste ; cette relation reste visible pour la session.'}
    }
    if ($incomingKind -eq 'Affectation') {
        return [pscustomobject]@{Placement='Replace';Demoted=$Stored;Reason='Affectation declaree enregistree ; la relation observee precedente reste visible pour la session.'}
    }
    $storedWhen = ConvertTo-DomeniaRelationUtcDate (Get-DomeniaMember $Stored 'When' $null)
    $incomingWhen = ConvertTo-DomeniaRelationUtcDate (Get-DomeniaMember $Incoming 'When' $null)
    if ($null -ne $incomingWhen -and ($null -eq $storedWhen -or $incomingWhen -gt $storedWhen)) {
        return [pscustomobject]@{Placement='Replace';Demoted=$Stored;Reason='Observation plus recente enregistree ; la precedente reste visible pour la session.'}
    }
    return [pscustomobject]@{Placement='Session';Demoted=$null;Reason='Relation plus ancienne que celle enregistree : visible pour la session seulement.'}
}

function Get-DomeniaRelationStorageKey {
    # Storage key of one relation: the workstation key for the relation stored first (compatible with the
    # existing computer_key rows), and a relation-specific key for any other relation of the same workstation.
    param($Relation,[bool]$Primary=$true)
    $computer = ([string](Get-DomeniaMember $Relation 'Computer' '')).Trim()
    if ($computer.EndsWith('$')) { $computer = $computer.Substring(0,$computer.Length - 1) }
    if ($computer.Contains('.')) { $computer = $computer.Substring(0,$computer.IndexOf('.')) }
    $computer = $computer.ToUpperInvariant()
    if (-not $computer) { return '' }
    if ($Primary) { return $computer }
    return ($computer + '|' + (Get-DomeniaRelationKey $Relation))
}

# ---------------------------------------------------------------- D043 explainable qualification
function Get-DomeniaEvidenceKind {
    param([AllowEmptyString()][AllowNull()][string]$Source)
    switch (Get-DomeniaRelationKind $Source) {
        'Affectation' { return 'Declare' }
        'Console' { return 'Observe' }
        'SessionRdp' { return 'Observe' }
        'Historique' { return 'Observe' }
        'Importe' { return 'Importe' }
        'Indice' { return 'Indice' }
        default { return 'Source a verifier' }
    }
}

function Get-DomeniaEvidenceLabel {
    # DS-17: display label of an internal qualification key. The key (Badge) stays stable for filters, tests and logs.
    param([AllowEmptyString()][AllowNull()][string]$Badge)
    switch ([string]$Badge) {
        'Declare'           { return 'Déclaré' }
        'Observe'           { return 'Observé' }
        'Importe'           { return 'Importé' }
        'Indice'            { return 'Indice' }
        'Contradictoire'    { return 'Contradictoire' }
        'Source a verifier' { return 'À vérifier' }
    }
    return [string]$Badge
}

function Get-DomeniaEvidenceBadge {
    # A badge with the rule that produced it. No percentage: no reliability rate has ever been measured.
    # Badge is the internal key; Label is the text shown on the chip (DS-17).
    param($Relation,[bool]$Contradicted=$false)
    $source = [string](Get-DomeniaMember $Relation 'Source' '')
    $kind = [string](Get-DomeniaMember $Relation 'Kind' '')
    if (-not $kind) { $kind = Get-DomeniaRelationKind $source }
    $when = [string](Get-DomeniaMember $Relation 'When' '')
    $badge = 'Source a verifier'; $rule = 'Origine non reconnue : à vérifier avant de sʼy fier.'
    switch ($kind) {
        'Affectation' { $badge = 'Declare'; $rule = 'Association déclarée par un opérateur dans Domenia.' }
        'Console'     { $badge = 'Observe'; $rule = 'Session console lue sur le poste à la date indiquée. Une observation ne vaut pas affectation.' }
        'SessionRdp'  { $badge = 'Observe'; $rule = 'Session distante lue sur le poste à la date indiquée. Une observation ne vaut pas affectation.' }
        'Historique'  { $badge = 'Observe'; $rule = 'Ouverture de session ancienne relevée dans un journal. Historique, pas présence actuelle.' }
        'Importe'     { $badge = 'Importe'; $rule = 'Ligne reprise dʼun fichier importé. Exactitude dépendante du fichier source.' }
        'Indice'      { $badge = 'Indice'; $rule = 'Attribut AD ou inventaire qui suggère un lien, sans observation de session.' }
    }
    if ($Contradicted) { $badge = 'Contradictoire'; $rule = 'Des sources différentes désignent des comptes différents pour ce poste. Aucune fusion automatique.' }
    $provenance = $source
    if ($when) {
        $whenText = Format-DomeniaRelationWhen $when
        if (-not $whenText) { $whenText = $when }
        $provenance = ($source + ' · ' + $whenText).Trim(' ','·')
    }
    return [pscustomobject]@{Badge=$badge;Label=(Get-DomeniaEvidenceLabel $badge);Rule=$rule;Provenance=$provenance;Kind=$kind}
}

# ---------------------------------------------------------------- D045 in-page association
function Step-DomeniaAssociationState {
    # Idle -> Searching -> Candidate -> Pending -> Verifying -> Saved. Every refusal is explicit; nothing is modal.
    param([Parameter(Mandatory=$true)][string]$State,[Parameter(Mandatory=$true)][ValidateSet('Search','Results','Pick','Confirm','Verified','VerifyFailed','Cancel','SubjectChanged','Reset')][string]$Event)
    $next = $null
    switch ($Event) {
        'Reset'          { $next = 'Idle' }
        'SubjectChanged' { $next = 'Idle' }
        'Cancel'         { if ($State -in @('Searching','Candidate','Pending','Verifying','Failed')) { $next = 'Idle' } }
        'Search'         { if ($State -in @('Idle','Candidate','Failed','Saved')) { $next = 'Searching' } }
        'Results'        { if ($State -eq 'Searching') { $next = 'Candidate' } }
        # Results stay listed after a save or a failed verification: another row of the same list may be picked.
        'Pick'           { if ($State -in @('Candidate','Saved','Failed')) { $next = 'Pending' } }
        'Confirm'        { if ($State -eq 'Pending') { $next = 'Verifying' } }
        'Verified'       { if ($State -eq 'Verifying') { $next = 'Saved' } }
        'VerifyFailed'   { if ($State -eq 'Verifying') { $next = 'Failed' } }
    }
    # CO-30: Reason is shown to the operator; Detail, with the internal names, is for the log only.
    if ($null -eq $next) { return [pscustomobject]@{State=$State;Accepted=$false;Reason=(Get-DomeniaAssociationRefusal $State $Event);Detail=('Transition ' + $Event + ' refusée depuis ' + $State + '.')} }
    return [pscustomobject]@{State=$next;Accepted=$true;Reason='';Detail=''}
}

function Get-DomeniaAssociationRefusal {
    # CO-30: one French sentence per refused step of the association; no internal state or event name.
    param([AllowEmptyString()][string]$State,[AllowEmptyString()][string]$Event)
    switch ($Event) {
        'Pick' {
            if ($State -eq 'Pending') { return 'Une association attend déjà sa confirmation : confirmez-la ou annulez-la avant dʼen choisir une autre.' }
            if ($State -eq 'Verifying') { return 'Vérification en cours : attendez son résultat avant de choisir une autre ligne.' }
            if ($State -eq 'Searching') { return 'Recherche en cours : attendez les résultats avant de choisir une ligne.' }
            # Idle with rows still listed: the detection was stopped or interrupted, its list is no longer active.
            return 'Cette liste nʼest plus active (détection arrêtée, interrompue ou aucune lancée) : relancez la détection ou la recherche, puis choisissez une ligne.'
        }
        'Confirm' {
            if ($State -eq 'Verifying') { return 'Vérification déjà en cours : attendez son résultat.' }
            return 'Confirmation impossible : choisissez dʼabord une ligne dans les résultats.'
        }
        'Search' {
            if ($State -in @('Pending','Verifying')) { return 'Une association attend sa confirmation : confirmez-la ou annulez-la avant une nouvelle recherche.' }
            if ($State -eq 'Searching') { return 'Une recherche est déjà en cours : attendez son résultat ou arrêtez-la.' }
        }
        'Results' { return 'Résultats ignorés : aucune recherche nʼest en cours.' }
        'Verified' { return 'Résultat de vérification ignoré : aucune vérification nʼest en cours.' }
        'VerifyFailed' { return 'Résultat de vérification ignoré : aucune vérification nʼest en cours.' }
        'Cancel' { return 'Rien à annuler : aucune association en cours.' }
    }
    return 'Action impossible à cette étape de lʼassociation.'
}

# ---------------------------------------------------------------- D046 candidates from several proofs
function Merge-DomeniaRelationCandidates {
    # Groups every source by exact object identity. A candidate that only has an IP address or a partial
    # name is listed with its reason but cannot be associated.
    param([object[]]$Known=@(),[object[]]$Observations=@(),[object[]]$Hints=@(),[object[]]$Inventory=@(),[string]$Domain='')
    $byKey = @{}
    $order = New-Object 'System.Collections.Generic.List[string]'
    $add = {
        param($item,[string]$origin,[string]$reason)
        if ($null -eq $item) { return }
        $guid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $item 'Guid' (Get-DomeniaMember $item 'ComputerGuid' ''))
        $name = [string](Get-DomeniaMember $item 'Computer' (Get-DomeniaMember $item 'Name' ''))
        $key = $guid
        if (-not $key) { $key = 'unverified:' + $name.ToLowerInvariant() + '|' + [string](Get-DomeniaMember $item 'Address' '') }
        if ($key -eq 'unverified:|') { return }
        if (-not $byKey.ContainsKey($key)) {
            $byKey[$key] = [pscustomobject]@{Guid=$guid;Computer=$name;DN=[string](Get-DomeniaMember $item 'DN' (Get-DomeniaMember $item 'ComputerDn' ''));Domain=$Domain;Origins=(New-Object 'System.Collections.Generic.List[string]');Reasons=(New-Object 'System.Collections.Generic.List[string]');Associable=[bool]$guid;Blocker=''}
            $order.Add($key)
        }
        $candidate = $byKey[$key]
        if (-not $candidate.Origins.Contains($origin)) { $candidate.Origins.Add($origin) }
        if ($reason -and -not $candidate.Reasons.Contains($reason)) { $candidate.Reasons.Add($reason) }
        if (-not $candidate.DN) { $candidate.DN = [string](Get-DomeniaMember $item 'DN' (Get-DomeniaMember $item 'ComputerDn' '')) }
    }
    foreach ($item in @($Known)) { & $add $item 'Association memorisee' ('Lien deja connu (' + (Get-DomeniaEvidenceKind ([string](Get-DomeniaMember $item 'Source' ''))) + ').') }
    foreach ($item in @($Observations)) { & $add $item 'Observation' ('Session observee : ' + [string](Get-DomeniaMember $item 'Detail' (Get-DomeniaMember $item 'Source' ''))) }
    foreach ($item in @($Hints)) { & $add $item 'Indice AD' ('Indice : ' + [string](Get-DomeniaMember $item 'Detail' (Get-DomeniaMember $item 'Source' ''))) }
    foreach ($item in @($Inventory)) { & $add $item ('Inventaire ' + [string](Get-DomeniaMember $item 'Provider' '')).Trim() ('Inventaire : ' + [string](Get-DomeniaMember $item 'Detail' '')) }
    foreach ($key in $order) {
        $candidate = $byKey[$key]
        if (-not $candidate.Associable) { $candidate.Blocker = 'Objet AD non identifie par son GUID : une adresse IP ou un nom partiel ne suffit pas a associer.' }
        [pscustomobject]@{Guid=$candidate.Guid;Computer=$candidate.Computer;DN=$candidate.DN;Domain=$candidate.Domain;Origins=($candidate.Origins.ToArray() -join ' + ');Why=($candidate.Reasons.ToArray() -join ' ');Associable=$candidate.Associable;Blocker=$candidate.Blocker}
    }
}

# ---------------------------------------------------------------- D047 perimeter preview before detection
function Get-DomeniaDetectionScopePlan {
    # Builds the preview shown before any probe. The requested perimeter is never replaced by another one:
    # when it yields nothing, the plan is refused with the reason and the operator chooses again.
    param([Parameter(Mandatory=$true)][ValidateSet('Candidates','Loaded','OU')][string]$RequestedScope,[AllowEmptyString()][string]$OuDn='',[AllowEmptyString()][string]$DomainDn='',[object[]]$Candidates=@(),[ValidateRange(1,50)][int]$Limit=20,[bool]$IncludeRdp=$false)
    if ($RequestedScope -eq 'OU' -and ([string]::IsNullOrWhiteSpace($OuDn) -or $OuDn -ieq $DomainDn)) {
        return [pscustomobject]@{Allowed=$false;Scope=$RequestedScope;OuDn=$OuDn;Limit=$Limit;Candidates=@();Truncated=$false;IncludeRdp=$IncludeRdp;RequiresConfirmation=$true;Reason='Choisissez une OU explicite ; le domaine entier ne sera pas substitue.';ZeroMeaning=''}
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $list = New-Object 'System.Collections.Generic.List[object]'
    $eligible = 0
    foreach ($candidate in @($Candidates)) {
        if ($null -eq $candidate) { continue }
        $guid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $candidate 'Guid' '')
        $domain = [string](Get-DomeniaMember $candidate 'Domain' '')
        if (-not $guid -or -not $domain) { continue }
        if (-not $seen.Add($domain + '|' + $guid)) { continue }
        $eligible++
        if ($list.Count -lt $Limit) { $list.Add($candidate) }
    }
    $items = $list.ToArray()
    $reason = 'Perimetre a confirmer avant toute sonde.'
    $allowed = ($items.Count -gt 0)
    if (-not $items.Count) {
        if ($RequestedScope -eq 'OU') { $reason = 'Aucun poste lu dans cette OU. Lisez d abord son contenu ou choisissez une autre OU.' }
        elseif ($RequestedScope -eq 'Loaded') { $reason = 'Aucune machine dans la liste chargee. Choisissez un autre perimetre.' }
        else { $reason = 'Aucun poste connu a verifier. Choisissez un autre perimetre.' }
    }
    return [pscustomobject]@{
        Allowed=$allowed;Scope=$RequestedScope;OuDn=$OuDn;Limit=$Limit;Candidates=$items;Truncated=($eligible -gt $items.Count);Eligible=$eligible
        IncludeRdp=$IncludeRdp;RequiresConfirmation=$true;Reason=$reason
        ZeroMeaning='Zero candidat signifie qu aucune source n en propose, pas que cet utilisateur n a aucun poste.'
    }
}

function Test-DomeniaDetectionMatchesPlan {
    # The list actually probed must be exactly the list the operator confirmed.
    param($Plan,[object[]]$Targets=@())
    if ($null -eq $Plan -or -not [bool]$Plan.Allowed) { return $false }
    $expected = @(@($Plan.Candidates) | ForEach-Object { (ConvertTo-DomeniaGuidText (Get-DomeniaMember $_ 'Guid' '')) } | Sort-Object)
    $actual = @(@($Targets) | ForEach-Object { (ConvertTo-DomeniaGuidText (Get-DomeniaMember $_ 'Guid' '')) } | Sort-Object)
    if ($expected.Count -ne $actual.Count) { return $false }
    for ($i = 0; $i -lt $expected.Count; $i++) { if ($expected[$i] -ne $actual[$i]) { return $false } }
    return $true
}

function Test-DomeniaDetectionWithinPlan {
    # A probe may stop early (limit, budget, rejected credentials), but never reach a target outside the plan.
    param($Plan,[object[]]$Targets=@())
    if ($null -eq $Plan -or -not [bool](Get-DomeniaMember $Plan 'Allowed' $false)) { return $false }
    $allowed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in @(Get-DomeniaMember $Plan 'Candidates' @())) {
        $guid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $candidate 'Guid' '')
        if ($guid) { [void]$allowed.Add($guid) }
    }
    foreach ($target in @($Targets)) {
        if ($null -eq $target) { continue }
        $guid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $target 'Guid' $target)
        if (-not $guid -or -not $allowed.Contains($guid)) { return $false }
    }
    return $true
}

# ---------------------------------------------------------------- D048 bounded progressive detection
function Test-DomeniaProbeAllowed {
    # Only an explicit gesture starts a network probe. Rendering or scrolling a list never does.
    param([Parameter(Mandatory=$true)][string]$Origin)
    return ($Origin -in @('ExplicitDetect','ExplicitRecheck','SelectedMachine'))
}

function New-DomeniaDetectionCounters {
    param([int]$Planned=0)
    return [pscustomobject]@{Planned=$Planned;Queried=0;Refused=0;Unreachable=0;Confirmed=0;NoSession=0;Stopped=$false}
}

function Add-DomeniaDetectionOutcome {
    param($Counters,[Parameter(Mandatory=$true)][ValidateSet('Confirmed','NoSession','Refused','Unreachable','Stopped')][string]$Outcome)
    if ($null -eq $Counters) { return $null }
    if ($Outcome -eq 'Stopped') { $Counters.Stopped = $true; return $Counters }
    $Counters.Queried = [int]$Counters.Queried + 1
    switch ($Outcome) {
        'Confirmed'   { $Counters.Confirmed = [int]$Counters.Confirmed + 1 }
        'NoSession'   { $Counters.NoSession = [int]$Counters.NoSession + 1 }
        'Refused'     { $Counters.Refused = [int]$Counters.Refused + 1 }
        'Unreachable' { $Counters.Unreachable = [int]$Counters.Unreachable + 1 }
    }
    return $Counters
}

function ConvertTo-DomeniaDetectionOutcome {
    # Maps the status of one console read to a counter. Unknown statuses are not counted as a result.
    param([AllowEmptyString()][AllowNull()][string]$Status)
    switch -Regex ([string]$Status) {
        '^(?i:CONFIRME)$'              { return 'Confirmed' }
        '^(?i:LU)$'                    { return 'NoSession' }
        '^(?i:REFUSE|AUTH_REJETEE)$'   { return 'Refused' }
        '^(?i:DELAI|ERREUR)$'          { return 'Unreachable' }
    }
    return ''
}

function Get-DomeniaDetectionCounterText {
    param($Counters)
    if ($null -eq $Counters) { return '' }
    $remaining = [Math]::Max(0,[int]$Counters.Planned - [int]$Counters.Queried)
    $text = ('{0} interroge(s) sur {1} · {2} confirme(s) · {3} refuse(s) · {4} injoignable(s)' -f $Counters.Queried,$Counters.Planned,$Counters.Confirmed,$Counters.Refused,$Counters.Unreachable)
    if ($Counters.Stopped) { return ($text + ' · arrete : resultat partiel') }
    if ($remaining -gt 0) { return ($text + ' · ' + $remaining + ' restant(s)') }
    if (([int]$Counters.Refused + [int]$Counters.Unreachable) -gt 0) { return ($text + ' · resultat partiel') }
    return $text
}

# ---------------------------------------------------------------- D049 exact identity
function ConvertTo-DomeniaAccountIdentity {
    # Parses DOMAIN\login, login@domain, .\login and a bare login.
    param([AllowEmptyString()][AllowNull()][string]$Text)
    $value = ([string]$Text).Trim()
    if (-not $value) { return [pscustomobject]@{Authority='';Login='';Form='Empty'} }
    if ($value -match '^(?<authority>[^\\]+)\\(?<login>[^\\]+)$') { return [pscustomobject]@{Authority=$Matches['authority'];Login=$Matches['login'];Form='DownLevel'} }
    if ($value -match '^(?<login>[^@]+)@(?<authority>[^@]+)$') { return [pscustomobject]@{Authority=$Matches['authority'];Login=$Matches['login'];Form='Upn'} }
    return [pscustomobject]@{Authority='';Login=$value;Form='Bare'}
}

function Test-DomeniaAccountIdentityMatch {
    # $Target: {Login, NetbiosDomain, DnsDomain, Sid, Upn}. $Observed: account text and optional SID read on $MachineName.
    # A local account or a namesake from another domain is never the AD account that is searched.
    param($Target,[AllowEmptyString()][string]$ObservedAccount='',[AllowEmptyString()][string]$ObservedSid='',[AllowEmptyString()][string]$MachineName='')
    $targetSid = ConvertTo-DomeniaSidText (Get-DomeniaMember $Target 'Sid' '')
    $seenSid = ConvertTo-DomeniaSidText $ObservedSid
    if ($targetSid -and $seenSid) {
        if ($targetSid -eq $seenSid) { return [pscustomobject]@{Match=$true;Certain=$true;Reason='SID identique.'} }
        return [pscustomobject]@{Match=$false;Certain=$true;Reason='SID different : autre compte.'}
    }
    $identity = ConvertTo-DomeniaAccountIdentity $ObservedAccount
    $login = [string](Get-DomeniaMember $Target 'Login' '')
    if (-not $identity.Login -or -not $login) { return [pscustomobject]@{Match=$false;Certain=$false;Reason='Compte observe ou cible absent.'} }
    if ($identity.Form -eq 'Bare') { return [pscustomobject]@{Match=$false;Certain=$false;Reason='Nom non qualifie : domaine du compte observe inconnu.'} }
    $authority = [string]$identity.Authority
    $machine = ([string]$MachineName).Split('.')[0]
    if ($authority -eq '.' -or ($machine -and $authority -ieq $machine)) { return [pscustomobject]@{Match=$false;Certain=$true;Reason='Compte local du poste, pas un compte du domaine.'} }
    $netbios = [string](Get-DomeniaMember $Target 'NetbiosDomain' ''); $dns = [string](Get-DomeniaMember $Target 'DnsDomain' '')
    $sameDomain = (($netbios -and $authority -ieq $netbios) -or ($dns -and $authority -ieq $dns))
    $upn = [string](Get-DomeniaMember $Target 'Upn' '')
    # The explicit UPN names the account, whatever its prefix or suffix. It is tested before the login,
    # otherwise a UPN with the DNS suffix and a prefix different from sAMAccountName was refused.
    if ($identity.Form -eq 'Upn' -and $upn -and $upn -ieq $ObservedAccount.Trim()) { return [pscustomobject]@{Match=$true;Certain=$false;Reason='UPN identique : a confirmer par le SID.'} }
    if (-not $sameDomain) { return [pscustomobject]@{Match=$false;Certain=$true;Reason='Compte d un autre domaine ou d une autre autorite : ' + $authority + '.'} }
    if ($identity.Login -ine $login) { return [pscustomobject]@{Match=$false;Certain=$true;Reason='Identifiant different.'} }
    return [pscustomobject]@{Match=$true;Certain=$false;Reason='Domaine et identifiant identiques ; SID non compare.'}
}

# ---------------------------------------------------------------- D050 history and conflicts
function New-DomeniaLinkHistoryEntry {
    # Local journal only: nothing here reads or writes Active Directory.
    param([Parameter(Mandatory=$true)][ValidateSet('Added','Removed','Restored','Refreshed','Conflict')][string]$Action,$Relation,[string]$Declarant='',[datetime]$WhenUtc=[datetime]::UtcNow,[string]$Note='')
    if ($null -eq $Relation) { return $null }
    $snapshot = [ordered]@{}
    foreach ($name in @('UserLogin','UserGuid','UserDn','Computer','ComputerGuid','ComputerDn','Kind','Source','When','Details','VerifiedInAD','Declarant')) { $snapshot[$name] = [string](Get-DomeniaMember $Relation $name '') }
    if (-not $snapshot['Kind']) { $snapshot['Kind'] = Get-DomeniaRelationKind $snapshot['Source'] }
    return [pscustomobject]@{Id=[guid]::NewGuid().ToString('N');Action=$Action;WhenUtc=$WhenUtc.ToUniversalTime().ToString('o');Declarant=$Declarant;Note=$Note;Key=(Get-DomeniaRelationKey ([pscustomobject]$snapshot));Relation=[pscustomobject]$snapshot}
}

function Get-DomeniaLinkRestoreCandidate {
    # A removed local link can be put back from its journal entry. Active Directory is not involved.
    param($Entry,[object[]]$Current=@())
    if ($null -eq $Entry -or [string](Get-DomeniaMember $Entry 'Action' '') -ne 'Removed') { return [pscustomobject]@{Restorable=$false;Relation=$null;Reason='Seule une suppression locale peut etre restauree.'} }
    foreach ($relation in @($Current)) {
        if ($null -eq $relation) { continue }
        if (((Get-DomeniaRelationKey $relation) -ceq [string]$Entry.Key) -or (Test-DomeniaSameRelation $relation $Entry.Relation)) { return [pscustomobject]@{Restorable=$false;Relation=$null;Reason='Cette association existe deja.'} }
    }
    return [pscustomobject]@{Restorable=$true;Relation=$Entry.Relation;Reason=''}
}

function Get-DomeniaLinkConflicts {
    # Reports workstations for which sources designate different accounts. Nothing is merged or removed.
    param([object[]]$Relations=@())
    $byComputer = @{}
    foreach ($relation in @($Relations)) {
        if ($null -eq $relation) { continue }
        $computer = ConvertTo-DomeniaGuidText (Get-DomeniaMember $relation 'ComputerGuid' '')
        if (-not $computer) { $computer = 'name:' + ([string](Get-DomeniaMember $relation 'Computer' '')).ToLowerInvariant() }
        if ($computer -eq 'name:') { continue }
        if (-not $byComputer.ContainsKey($computer)) { $byComputer[$computer] = New-Object 'System.Collections.Generic.List[object]' }
        $byComputer[$computer].Add($relation)
    }
    foreach ($computer in @($byComputer.Keys | Sort-Object)) {
        $items = $byComputer[$computer]
        $declared = @($items | Where-Object { (Get-DomeniaEvidenceKind ([string](Get-DomeniaMember $_ 'Source' ''))) -eq 'Declare' })
        $observed = @($items | Where-Object { (Get-DomeniaEvidenceKind ([string](Get-DomeniaMember $_ 'Source' ''))) -eq 'Observe' })
        if (-not $declared.Count -or -not $observed.Count) { continue }
        $owners = @($declared | ForEach-Object { ([string](Get-DomeniaMember $_ 'UserLogin' '')).ToLowerInvariant() } | Select-Object -Unique)
        $others = @($observed | Where-Object { $owners -notcontains ([string](Get-DomeniaMember $_ 'UserLogin' '')).ToLowerInvariant() })
        if (-not $others.Count) { continue }
        [pscustomobject]@{
            Computer=[string](Get-DomeniaMember $items[0] 'Computer' '')
            Declared=(@($declared | ForEach-Object { [string](Get-DomeniaMember $_ 'UserLogin' '') }) -join ', ')
            Observed=(@($others | ForEach-Object { [string](Get-DomeniaMember $_ 'UserLogin' '') } | Select-Object -Unique) -join ', ')
            Message='Affectation declaree et session observee designent des comptes differents. Les deux sont conservees.'
            Relations=@($declared + $others)
        }
    }
}

function Get-DomeniaRelationRestoreLabel {
    # CO-28: the restore button names the association it puts back ("Restaurer jdupont → PC01").
    param($Entry)
    $relation = Get-DomeniaMember $Entry 'Relation' $null
    $user = [string](Get-DomeniaMember $relation 'UserLogin' ''); $computer = [string](Get-DomeniaMember $relation 'Computer' '')
    if (-not $user -or -not $computer) { return 'Restaurer la suppression' }
    $label = 'Restaurer ' + $user + ' → ' + $computer
    if ($label.Length -gt 48) { $label = $label.Substring(0,47) + [string][char]0x2026 }
    return $label
}

# ---------------------------------------------------------------- UX-40 orphans, FO-14 filter
function Get-DomeniaOrphanReason {
    # UX-40: why a stored association is listed as orphan, in words. The check reads names in the directory:
    # an absent name is a deleted or renamed object, never a proven deletion.
    param([bool]$UserExists,[bool]$ComputerExists)
    if (-not $UserExists -and -not $ComputerExists) { return 'Compte et poste absents dʼActive Directory (supprimés ou renommés).' }
    if (-not $UserExists) { return 'Compte absent dʼActive Directory (supprimé ou renommé).' }
    if (-not $ComputerExists) { return 'Poste absent dʼActive Directory (supprimé ou renommé).' }
    return ''
}

function Test-DomeniaRelationMatchesFilter {
    # FO-14: text filter (user, workstation, source, details, label) and qualification chips of Toutes les associations.
    param($Relation,[AllowEmptyString()][string]$Text='',[string[]]$Badges=@())
    if ($null -eq $Relation) { return $false }
    $wanted = @(@($Badges) | Where-Object { $_ })
    if ($wanted.Count -gt 0 -and ([string](Get-DomeniaMember $Relation 'Badge' '')) -notin $wanted) { return $false }
    $needle = ([string]$Text).Trim()
    if (-not $needle) { return $true }
    foreach ($name in @('UserLogin','Computer','Source','Details','BadgeLabel')) {
        if (([string](Get-DomeniaMember $Relation $name '')).IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------- CO-08 CSV import with preview
function ConvertFrom-DomeniaLinkCsvRow {
    # Reads the columns of one CSV row. Source, Confidence and VerifiedInAD are never taken from the file:
    # an imported row must not pass for a declaration, and the file source is only kept as a detail.
    param($Row)
    $values = [ordered]@{User='';Computer='';FileSource='';Details='';When=''}
    if ($null -ne $Row) {
        $columns = [ordered]@{User=@('UserLogin','User','Username','LastUser','SamAccountName');Computer=@('Computer','ComputerName','Hostname','Host','Machine','Name');FileSource=@('Source');Details=@('Details');When=@('When')}
        foreach ($key in @($columns.Keys)) {
            foreach ($name in @($columns[$key])) {
                $property = $Row.PSObject.Properties[$name]
                if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) { $values[$key] = ([string]$property.Value).Trim(); break }
            }
        }
    }
    return [pscustomobject]$values
}

function Get-DomeniaLinkImportStatus {
    # CO-08: what the import preview says about one row. Nothing here reads the directory: the local index
    # lookups are given by the caller. A workstation that already has a stored association is never replaced.
    # -Unverified says why the presence in Active Directory is not checked (index empty, unreadable or being read).
    # -ReadyBefore: rows already retained above; the storage takes 64 changes per request (Queue-DomeniaLinkChanges),
    # so the rows beyond -BatchLimit are left for a second import of the same file.
    # Point 138: every row also gets a Category for the preview: Valide, Conflit, Rejet, Doublon, Déjà connue, Inconnue
    # or Reportée. -Rejected is the identity refusal of the adapter, -FileConflict and -FileSuperseded the decision of
    # the source priority inside the file (Resolve-DomeniaInventoryPriority).
    param([AllowEmptyString()][string]$User='',[AllowEmptyString()][string]$Computer='',[AllowEmptyString()][string]$StoredLogin='',[bool]$DuplicateInFile=$false,[bool]$IndexAvailable=$false,[bool]$UserKnown=$false,[bool]$ComputerKnown=$false,[AllowEmptyString()][string]$Unverified='',[int]$ReadyBefore=0,[int]$BatchLimit=64,[AllowEmptyString()][string]$Rejected='',[AllowEmptyString()][string]$FileConflict='',[AllowEmptyString()][string]$FileSuperseded='')
    $out = { param($Status,$Category,$Reason,$Import=$false,$Verified=$false) [pscustomobject]@{Status=$Status;Category=$Category;Import=[bool]$Import;Verified=[bool]$Verified;Reason=$Reason} }
    if ($Rejected) { return (& $out 'Rejetée' 'Rejet' $Rejected) }
    if ((-not $User) -or (-not $Computer)) { return (& $out 'Ignorée' 'Rejet' 'Utilisateur ou poste manquant ou illisible.') }
    if ($FileConflict) { return (& $out 'Conflit' 'Conflit' $FileConflict) }
    if ($FileSuperseded) { return (& $out 'Ignorée' 'Doublon' $FileSuperseded) }
    if ($DuplicateInFile) { return (& $out 'Ignorée' 'Doublon' 'Poste déjà présent plus haut dans le fichier.') }
    if ($StoredLogin) {
        if ((ConvertTo-DomeniaRelationLoginKey $StoredLogin) -eq (ConvertTo-DomeniaRelationLoginKey $User)) { return (& $out 'Ignorée' 'Déjà connue' 'Association déjà connue.') }
        return (& $out 'Conflit' 'Conflit' ('Poste déjà associé à ' + $StoredLogin + ' : aucune association remplacée.'))
    }
    if ($IndexAvailable -and ((-not $UserKnown) -or (-not $ComputerKnown))) {
        $missing = 'poste absent'
        if ((-not $UserKnown) -and (-not $ComputerKnown)) { $missing = 'compte et poste absents' } elseif (-not $UserKnown) { $missing = 'compte absent' }
        return (& $out 'Inconnue' 'Inconnue' ('Inconnue dans lʼannuaire : ' + $missing + ' de lʼindex local. Ligne non importée.'))
    }
    if (($BatchLimit -gt 0) -and ($ReadyBefore -ge $BatchLimit)) {
        return (& $out 'Ignorée' 'Reportée' ('Au-delà de ' + $BatchLimit + ' associations par import : importez à nouveau le même fichier ensuite, les lignes déjà importées seront reconnues.'))
    }
    if (-not $IndexAvailable) {
        $why = ([string]$Unverified).Trim()
        if (-not $why) { $why = 'index local non lu' }
        return (& $out 'À importer' 'Valide' ('Présence dans Active Directory non vérifiée : ' + $why + '.') $true $false)
    }
    return (& $out 'À importer' 'Valide' 'Compte et poste connus de lʼindex local.' $true $true)
}

function New-DomeniaImportedRelation {
    # CO-08: an imported relation carries the Source of the adapter chosen by the operator (Import CSV, Import GLPI or
    # Import osquery, badge Importé), never the source written in the file, no score and a UTC date.
    # Only an ISO date (yyyy-MM-dd...) of the file is kept: "08/10/2026" is ambiguous and the import date is used.
    # Point 138: -BatchId starts the details ("Lot dʼimport <id>.") so the batch can be undone after a restart.
    param([string]$User,[string]$Computer,[AllowEmptyString()][string]$FileName='',[int]$Line=0,[AllowEmptyString()][string]$FileSource='',[AllowEmptyString()][string]$FileDetails='',[AllowEmptyString()][string]$When='',[bool]$Verified=$false,[string]$UserGuid='',[string]$ComputerGuid='',[string]$UserDn='',[string]$ComputerDn='',$NowUtc=$null,[ValidateSet('Import CSV','Import GLPI','Import osquery')][string]$Source='Import CSV',[AllowEmptyString()][string]$BatchId='',[AllowEmptyString()][string]$WhenNote='')
    $whenText = ''
    $note = ''
    if ($When -match '^\s*\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2}(\.\d+)?)?)?(Z|[+-]\d{2}:?\d{2})?\s*$') { $whenText = ConvertTo-DomeniaRelationWhenText $When }
    elseif ($When) { $note = ' Date du fichier non reconnue (' + $When + ') : date de lʼimport retenue.' }
    if ($WhenNote) { $note += ' ' + $WhenNote }
    if (-not $whenText) {
        $now = ConvertTo-DomeniaUtcDate $NowUtc
        if ($null -eq $now) { $now = [datetime]::UtcNow }
        $whenText = $now.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
    }
    # Import-Csv skips blank lines and joins quoted multi-line fields: the number is the record of the file, not its line.
    $details = ''
    if ($BatchId) { $details = 'Lot dʼimport ' + $BatchId + '. ' }
    $details += 'Importé depuis ' + $FileName
    if ($Line -gt 0) { $details += ', enregistrement ' + $Line }
    $details += '.' + $note
    if ($FileSource) { $details += ' Source indiquée dans le fichier : ' + $FileSource + ' (non reprise).' }
    if ($FileDetails) { $details += ' ' + $FileDetails }
    if ($details.Length -gt 400) { $details = $details.Substring(0,399) + [string][char]0x2026 }
    return [pscustomobject]@{UserLogin=$User;Computer=$Computer;Source=$Source;Confidence=0;VerifiedInAD=$Verified;When=$whenText;Details=$details;UserGuid=$UserGuid;ComputerGuid=$ComputerGuid;UserDn=$UserDn;ComputerDn=$ComputerDn;Kind='Importe'}
}
