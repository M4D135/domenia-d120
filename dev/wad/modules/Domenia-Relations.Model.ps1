# Relation rules between users and workstations: both directions, declared assignment versus
# observation, explainable qualification, stable context, in-page association, candidates built
# from several proofs, explicit detection perimeter, exact identity and history.
# Pure decisions: no probe, no LDAP read and no storage access is started here.

# ---------------------------------------------------------------- D041 both directions
function Get-DomeniaRelationDirection {
    param([Parameter(Mandatory=$true)][ValidateSet('Utilisateur','Machine','User','Computer')][string]$SubjectType)
    if ($SubjectType -in @('Utilisateur','User')) {
        return [pscustomobject]@{SourceType='Utilisateur';TargetType='Machine';Action='Associer ce poste';SearchLabel='Rechercher un poste';DetectLabel='Detecter les postes';EmptyHint='Aucun poste associe a cet utilisateur.'}
    }
    return [pscustomobject]@{SourceType='Machine';TargetType='Utilisateur';Action='Associer cet utilisateur';SearchLabel='Rechercher un utilisateur';DetectLabel='Lire la session de ce poste';EmptyHint='Aucun utilisateur associe a ce poste.'}
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
    # Closed vocabulary derived from the stored source text of a relation.
    param([AllowEmptyString()][AllowNull()][string]$Source)
    $text = [string]$Source
    if ($text -match '(?i)saisie manuelle|manual|manuel|declar|affect') { return 'Affectation' }
    if ($text -match '(?i)import|csv') { return 'Importe' }
    if ($text -match '(?i)rdp|wts|session distante|terminal') { return 'SessionRdp' }
    if ($text -match '(?i)console|cim|dcom|explorer|interactive') { return 'Console' }
    if ($text -match '(?i)historique|journal|event|4624|harvest|logon') { return 'Historique' }
    if ($text -match '(?i)description|managedBy|kerberos|indice|attribut|inventaire|wapt|glpi') { return 'Indice' }
    return 'Inconnu'
}

function Get-DomeniaRelationKey {
    # One relation = one user, one workstation and one nature of proof. Several users per workstation are allowed.
    param($Relation)
    $user = ConvertTo-DomeniaGuidText (Get-DomeniaMember $Relation 'UserGuid' '')
    if (-not $user) { $user = 'login:' + ([string](Get-DomeniaMember $Relation 'UserLogin' '')).ToLowerInvariant() }
    $computer = ConvertTo-DomeniaGuidText (Get-DomeniaMember $Relation 'ComputerGuid' '')
    if (-not $computer) { $computer = 'name:' + ([string](Get-DomeniaMember $Relation 'Computer' '')).ToLowerInvariant() }
    $kind = [string](Get-DomeniaMember $Relation 'Kind' '')
    if (-not $kind) { $kind = Get-DomeniaRelationKind ([string](Get-DomeniaMember $Relation 'Source' '')) }
    return ($user + '|' + $computer + '|' + $kind)
}

function Resolve-DomeniaRelationUpsert {
    # Decides how an incoming relation joins the stored ones. A declared assignment is never replaced by an
    # observation, and a temporary console session of another account does not remove the owner.
    param([object[]]$Existing=@(),$Incoming)
    if ($null -eq $Incoming) { return [pscustomobject]@{Action='Ignore';Replace=$null;Reason='Relation absente.'} }
    $incomingKey = Get-DomeniaRelationKey $Incoming
    foreach ($relation in @($Existing)) {
        if ($null -eq $relation) { continue }
        if ((Get-DomeniaRelationKey $relation) -ceq $incomingKey) { return [pscustomobject]@{Action='Refresh';Replace=$relation;Reason='Meme relation, meme nature : date et detail mis a jour.'} }
    }
    return [pscustomobject]@{Action='Add';Replace=$null;Reason='Nouvelle relation ajoutee sans retirer les relations existantes.'}
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

function Get-DomeniaEvidenceBadge {
    # A badge with the rule that produced it. No percentage: no reliability rate has ever been measured.
    param($Relation,[bool]$Contradicted=$false)
    $source = [string](Get-DomeniaMember $Relation 'Source' '')
    $kind = [string](Get-DomeniaMember $Relation 'Kind' '')
    if (-not $kind) { $kind = Get-DomeniaRelationKind $source }
    $when = [string](Get-DomeniaMember $Relation 'When' '')
    $badge = 'Source a verifier'; $rule = 'Origine non reconnue : a verifier avant de s y fier.'
    switch ($kind) {
        'Affectation' { $badge = 'Declare'; $rule = 'Association declaree par un operateur dans Domenia.' }
        'Console'     { $badge = 'Observe'; $rule = 'Session console lue sur le poste a la date indiquee. Une observation ne vaut pas affectation.' }
        'SessionRdp'  { $badge = 'Observe'; $rule = 'Session distante lue sur le poste a la date indiquee. Une observation ne vaut pas affectation.' }
        'Historique'  { $badge = 'Observe'; $rule = 'Ouverture de session ancienne relevee dans un journal. Historique, pas presence actuelle.' }
        'Importe'     { $badge = 'Importe'; $rule = 'Ligne reprise d un fichier importe. Exactitude dependante du fichier source.' }
        'Indice'      { $badge = 'Indice'; $rule = 'Attribut AD ou inventaire qui suggere un lien, sans observation de session.' }
    }
    if ($Contradicted) { $badge = 'Contradictoire'; $rule = 'Des sources differentes designent des comptes differents pour ce poste. Aucune fusion automatique.' }
    $provenance = $source
    if ($when) { $provenance = ($source + ' · ' + $when).Trim(' ','·') }
    return [pscustomobject]@{Badge=$badge;Rule=$rule;Provenance=$provenance;Kind=$kind}
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
        'Pick'           { if ($State -eq 'Candidate') { $next = 'Pending' } }
        'Confirm'        { if ($State -eq 'Pending') { $next = 'Verifying' } }
        'Verified'       { if ($State -eq 'Verifying') { $next = 'Saved' } }
        'VerifyFailed'   { if ($State -eq 'Verifying') { $next = 'Failed' } }
    }
    if ($null -eq $next) { return [pscustomobject]@{State=$State;Accepted=$false;Reason=('Action « ' + $Event + ' » impossible dans l etat « ' + $State + ' ».')} }
    return [pscustomobject]@{State=$next;Accepted=$true;Reason=''}
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
    if ($identity.Form -eq 'Upn' -and -not $sameDomain) {
        $upn = [string](Get-DomeniaMember $Target 'Upn' '')
        if ($upn -and $upn -ieq $ObservedAccount.Trim()) { return [pscustomobject]@{Match=$true;Certain=$false;Reason='UPN identique (suffixe different du domaine DNS) : a confirmer par le SID.'} }
    }
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
    if ($null -eq $Entry -or [string]$Entry.Action -ne 'Removed') { return [pscustomobject]@{Restorable=$false;Relation=$null;Reason='Seule une suppression locale peut etre restauree.'} }
    foreach ($relation in @($Current)) { if ($null -ne $relation -and (Get-DomeniaRelationKey $relation) -ceq [string]$Entry.Key) { return [pscustomobject]@{Restorable=$false;Relation=$null;Reason='Cette association existe deja.'} } }
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
