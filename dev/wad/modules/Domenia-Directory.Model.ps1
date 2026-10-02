# Directory rules for users, groups and the domain: support summary, effective password policy,
# lockout diagnosis, membership paths, user comparison, group deltas, ACE reading, account life cycle,
# inconsistency review and comparison between domain controllers.
# Pure decisions on data already read: no LDAP request is sent from this module.

function Get-DomeniaAttr {
    # First value of an attribute from a property bag, whatever the key casing and whether the value is a collection.
    param($Properties,[Parameter(Mandatory=$true)][string]$Name,$Default='')
    if ($null -eq $Properties) { return $Default }
    $value = $null; $found = $false
    if ($Properties -is [Collections.IDictionary]) {
        foreach ($key in @($Properties.Keys)) { if ([string]$key -ieq $Name) { $value = $Properties[$key]; $found = $true; break } }
    } else {
        foreach ($property in @($Properties.PSObject.Properties)) { if ([string]$property.Name -ieq $Name) { $value = $property.Value; $found = $true; break } }
    }
    if (-not $found -or $null -eq $value) { return $Default }
    # A byte array (GUID, SID) must leave the function whole: without the comma PowerShell would unroll it.
    if ($value -is [byte[]]) { return ,$value }
    if ($value -is [string]) { return $value }
    if ($value -is [Collections.IEnumerable]) {
        foreach ($item in $value) {
            if ($item -is [byte[]]) { return ,$item }
            return $item
        }
        return $Default
    }
    return $value
}

function Get-DomeniaAttrAll {
    param($Properties,[Parameter(Mandatory=$true)][string]$Name)
    if ($null -eq $Properties) { return @() }
    $value = $null
    if ($Properties -is [Collections.IDictionary]) { foreach ($key in @($Properties.Keys)) { if ([string]$key -ieq $Name) { $value = $Properties[$key]; break } } }
    else { foreach ($property in @($Properties.PSObject.Properties)) { if ([string]$property.Name -ieq $Name) { $value = $property.Value; break } } }
    if ($null -eq $value) { return @() }
    if ($value -is [string] -or $value -is [byte[]]) { return @(,$value) }
    if ($value -is [Collections.IEnumerable]) { return @($value) }
    return @(,$value)
}

function ConvertFrom-DomeniaAdInterval {
    # AD stores durations as negative 100-nanosecond counts. 0 and Int64.MinValue mean "never".
    param($Value)
    $ticks = 0L
    if ($null -eq $Value -or -not [long]::TryParse([string]$Value,[ref]$ticks)) { return $null }
    if ($ticks -eq 0 -or $ticks -eq [long]::MinValue) { return $null }
    return [TimeSpan]::FromTicks([Math]::Abs($ticks))
}

function Get-DomeniaCnFromDn {
    param([AllowEmptyString()][string]$Dn)
    $first = @(Split-DomeniaDn $Dn | Select-Object -First 1)
    if (-not $first.Count) { return '' }
    return (([string]$first[0] -replace '^(?i)(CN|OU)=','') -replace '\\(.)','$1')
}

function Get-DomeniaAccountState {
    # $Uac = userAccountControl, $Computed = msDS-User-Account-Control-Computed (may be unreadable).
    param($Uac,$Computed=$null,$LockoutTime=$null)
    $flags = 0L
    if ($null -eq $Uac -or -not [long]::TryParse([string]$Uac,[ref]$flags)) { return [pscustomobject]@{Known=$false;Disabled=$false;Locked=$null;PasswordExpired=$null;NeverExpires=$false;Label='Etat non determine'} }
    $computedFlags = 0L
    $hasComputed = ($null -ne $Computed -and [long]::TryParse([string]$Computed,[ref]$computedFlags))
    $disabled = (($flags -band 2) -ne 0)
    $locked = $null; $expired = $null
    if ($hasComputed) { $locked = (($computedFlags -band 16) -ne 0); $expired = (($computedFlags -band 8388608) -ne 0) }
    $label = 'Actif'
    if ($disabled) { $label = 'Desactive' }
    if ($locked -eq $true) { $label += ' · verrouille' }
    elseif ($null -eq $locked) {
        $lock = 0L
        if ($null -ne $LockoutTime -and [long]::TryParse([string]$LockoutTime,[ref]$lock) -and $lock -gt 0) { $label += ' · verrouillage a verifier' }
    }
    if ($expired -eq $true) { $label += ' · mot de passe expire' }
    return [pscustomobject]@{Known=$true;Disabled=$disabled;Locked=$locked;PasswordExpired=$expired;NeverExpires=(($flags -band 65536) -ne 0);SmartcardRequired=(($flags -band 262144) -ne 0);PasswordNotRequired=(($flags -band 32) -ne 0);Label=$label}
}

# ---------------------------------------------------------------- D061 support-oriented user summary
function Get-DomeniaUserSupportSummary {
    # A short, readable context for a technician. Technical attributes stay in the advanced view.
    param($Properties,[string]$Reader='',[string]$Source='Lecture AD',[datetime]$NowUtc=[datetime]::UtcNow,$ReadUtc=$null)
    $facts = New-Object 'System.Collections.Generic.List[object]'
    $add = {
        param([string]$group,[string]$label,[string]$value,[string]$limit='')
        if ([string]::IsNullOrWhiteSpace($value)) { return }
        $fact = New-DomeniaFact -Fait $label -Valeur $value -Source $Source -Limite $limit -Date $ReadUtc -Lecteur $Reader
        $fact | Add-Member -NotePropertyName Rubrique -NotePropertyValue $group
        $facts.Add($fact)
    }
    & $add 'Identite' 'Nom affiche' ([string](Get-DomeniaAttr $Properties 'displayName' (Get-DomeniaAttr $Properties 'name' '')))
    & $add 'Identite' 'Identifiant' ([string](Get-DomeniaAttr $Properties 'sAMAccountName' ''))
    & $add 'Identite' 'Nom de connexion' ([string](Get-DomeniaAttr $Properties 'userPrincipalName' ''))
    & $add 'Service' 'Service' ([string](Get-DomeniaAttr $Properties 'department' ''))
    & $add 'Service' 'Fonction' ([string](Get-DomeniaAttr $Properties 'title' ''))
    & $add 'Service' 'Societe' ([string](Get-DomeniaAttr $Properties 'company' ''))
    & $add 'Service' 'Bureau' ([string](Get-DomeniaAttr $Properties 'physicalDeliveryOfficeName' ''))
    & $add 'Service' 'Responsable' (Get-DomeniaCnFromDn ([string](Get-DomeniaAttr $Properties 'manager' '')))
    & $add 'Contact' 'Messagerie' ([string](Get-DomeniaAttr $Properties 'mail' ''))
    & $add 'Contact' 'Telephone' ([string](Get-DomeniaAttr $Properties 'telephoneNumber' ''))
    & $add 'Contact' 'Mobile' ([string](Get-DomeniaAttr $Properties 'mobile' ''))
    $state = Get-DomeniaAccountState (Get-DomeniaAttr $Properties 'userAccountControl' $null) (Get-DomeniaAttr $Properties 'msDS-User-Account-Control-Computed' $null) (Get-DomeniaAttr $Properties 'lockoutTime' $null)
    $stateLimit = ''
    if ($state.Known -and $null -eq $state.Locked) { $stateLimit = 'Etat calcule du controleur non lu : verrouillage et expiration non confirmes.' }
    & $add 'Compte' 'Etat du compte' $state.Label $stateLimit
    $expires = ConvertTo-DomeniaUtcDate (Get-DomeniaAttr $Properties 'accountExpires' $null)
    if ($null -ne $expires) {
        $text = $expires.ToLocalTime().ToString('dd/MM/yyyy')
        if ($expires -lt $NowUtc) { $text += ' (echu)' }
        & $add 'Compte' 'Expiration du compte' $text
    }
    $created = ConvertTo-DomeniaUtcDate (Get-DomeniaAttr $Properties 'whenCreated' $null)
    if ($null -ne $created) { & $add 'Dates' 'Cree le' $created.ToLocalTime().ToString('dd/MM/yyyy') }
    $pwd = ConvertTo-DomeniaUtcDate (Get-DomeniaAttr $Properties 'pwdLastSet' $null)
    if ($null -ne $pwd) { & $add 'Dates' 'Mot de passe change le' $pwd.ToLocalTime().ToString('dd/MM/yyyy HH:mm') }
    elseif ([string](Get-DomeniaAttr $Properties 'pwdLastSet' '') -eq '0') { & $add 'Dates' 'Mot de passe' 'A changer a la prochaine ouverture de session' }
    $logon = ConvertTo-DomeniaUtcDate (Get-DomeniaAttr $Properties 'lastLogonTimestamp' $null)
    if ($null -ne $logon) { & $add 'Dates' 'Derniere ouverture de session (approx.)' $logon.ToLocalTime().ToString('dd/MM/yyyy') 'Valeur repliquee avec un retard pouvant atteindre 14 jours.' }
    return $facts.ToArray()
}

# ---------------------------------------------------------------- D062 effective password policy
function Resolve-DomeniaPasswordPolicy {
    # $ResultantPsoState: 'Applies' (a fine-grained policy was read), 'None' (attribute readable and empty: the domain
    # policy applies) or 'Unreadable' (the policy stays unknown: nothing is assumed from the domain).
    param($User,[ValidateSet('Applies','None','Unreadable')][string]$ResultantPsoState='Unreadable',$Pso=$null,$DomainPolicy=$null,[string]$Reader='',[datetime]$NowUtc=[datetime]::UtcNow)
    $facts = New-Object 'System.Collections.Generic.List[object]'
    $known = $false; $sourceLabel = ''; $bag = $null; $prefix = ''
    if ($ResultantPsoState -eq 'Applies' -and $null -ne $Pso) { $known = $true; $bag = $Pso; $prefix = 'msDS-'; $sourceLabel = 'Strategie fine : ' + [string](Get-DomeniaAttr $Pso 'name' (Get-DomeniaCnFromDn ([string](Get-DomeniaAttr $Pso 'distinguishedName' '')))) }
    elseif ($ResultantPsoState -eq 'None' -and $null -ne $DomainPolicy) { $known = $true; $bag = $DomainPolicy; $sourceLabel = 'Strategie du domaine' }
    $maxAge = $null
    if (-not $known) {
        $facts.Add((New-DomeniaFact -Fait 'Strategie applicable' -Valeur 'Inconnue' -Etat Inconnu -Source 'msDS-ResultantPSO' -Limite 'Strategie non lisible avec ce compte : aucune valeur n est deduite de la strategie du domaine.' -Lecteur $Reader))
    } else {
        $facts.Add((New-DomeniaFact -Fait 'Strategie applicable' -Valeur $sourceLabel -Source 'msDS-ResultantPSO' -Lecteur $Reader))
        if ($prefix) {
            $minLength = [string](Get-DomeniaAttr $bag 'msDS-MinimumPasswordLength' ''); $history = [string](Get-DomeniaAttr $bag 'msDS-PasswordHistoryLength' '')
            $complex = [string](Get-DomeniaAttr $bag 'msDS-PasswordComplexityEnabled' ''); $threshold = [string](Get-DomeniaAttr $bag 'msDS-LockoutThreshold' '')
            $maxAge = ConvertFrom-DomeniaAdInterval (Get-DomeniaAttr $bag 'msDS-MaximumPasswordAge' $null)
            $lockDuration = ConvertFrom-DomeniaAdInterval (Get-DomeniaAttr $bag 'msDS-LockoutDuration' $null)
            $complexText = if ($complex -match '^(?i:true|1)$') { 'Oui' } elseif ($complex) { 'Non' } else { '' }
        } else {
            $minLength = [string](Get-DomeniaAttr $bag 'minPwdLength' ''); $history = [string](Get-DomeniaAttr $bag 'pwdHistoryLength' '')
            $threshold = [string](Get-DomeniaAttr $bag 'lockoutThreshold' '')
            $maxAge = ConvertFrom-DomeniaAdInterval (Get-DomeniaAttr $bag 'maxPwdAge' $null)
            $lockDuration = ConvertFrom-DomeniaAdInterval (Get-DomeniaAttr $bag 'lockoutDuration' $null)
            $properties = 0L; $complexText = ''
            if ([long]::TryParse([string](Get-DomeniaAttr $bag 'pwdProperties' ''),[ref]$properties)) { $complexText = if (($properties -band 1) -ne 0) { 'Oui' } else { 'Non' } }
        }
        if ($minLength) { $facts.Add((New-DomeniaFact -Fait 'Longueur minimale' -Valeur ($minLength + ' caracteres') -Source $sourceLabel -Lecteur $Reader)) }
        if ($complexText) { $facts.Add((New-DomeniaFact -Fait 'Complexite exigee' -Valeur $complexText -Source $sourceLabel -Lecteur $Reader)) }
        if ($history) { $facts.Add((New-DomeniaFact -Fait 'Historique' -Valeur ($history + ' mots de passe') -Source $sourceLabel -Lecteur $Reader)) }
        $ageText = 'Sans limite'
        if ($null -ne $maxAge) { $ageText = [string][int]$maxAge.TotalDays + ' jours' }
        $facts.Add((New-DomeniaFact -Fait 'Duree de validite' -Valeur $ageText -Source $sourceLabel -Lecteur $Reader))
        if ($threshold) {
            $lockText = if ($threshold -eq '0') { 'Aucun verrouillage' } else { $threshold + ' echecs' }
            if ($threshold -ne '0' -and $null -ne $lockDuration) { $lockText += ', duree ' + [string][int]$lockDuration.TotalMinutes + ' min' }
            elseif ($threshold -ne '0') { $lockText += ', deverrouillage par un administrateur' }
            $facts.Add((New-DomeniaFact -Fait 'Verrouillage' -Valeur $lockText -Source $sourceLabel -Lecteur $Reader))
        }
    }
    # Expiration: the controller's computed value first; otherwise only when the policy is known.
    $state = Get-DomeniaAccountState (Get-DomeniaAttr $User 'userAccountControl' $null) (Get-DomeniaAttr $User 'msDS-User-Account-Control-Computed' $null)
    $expiryUtc = $null; $expiryText = ''; $expiryState = 'Constate'; $expiryLimit = ''
    $computedRaw = [string](Get-DomeniaAttr $User 'msDS-UserPasswordExpiryTimeComputed' '')
    $pwdLastSetRaw = [string](Get-DomeniaAttr $User 'pwdLastSet' '')
    if ($state.Known -and $state.NeverExpires) { $expiryText = 'N expire jamais (option du compte)' }
    elseif ($pwdLastSetRaw -eq '0') { $expiryText = 'A changer a la prochaine ouverture de session' }
    elseif ($computedRaw -and $computedRaw -ne '0') {
        if ($computedRaw -eq '9223372036854775807') { $expiryText = 'N expire pas' }
        else { $expiryUtc = ConvertTo-DomeniaUtcDate $computedRaw; if ($null -ne $expiryUtc) { $expiryText = $expiryUtc.ToLocalTime().ToString('dd/MM/yyyy HH:mm') } }
    } elseif ($known) {
        $pwdLastSet = ConvertTo-DomeniaUtcDate $pwdLastSetRaw
        if ($null -eq $maxAge) { $expiryText = 'N expire pas (strategie sans limite)' }
        elseif ($null -ne $pwdLastSet) { $expiryUtc = $pwdLastSet.Add($maxAge); $expiryText = $expiryUtc.ToLocalTime().ToString('dd/MM/yyyy HH:mm'); $expiryState = 'Estime'; $expiryLimit = 'Calcule a partir de la strategie lue ; valeur du controleur non disponible.' }
    }
    if (-not $expiryText) { $expiryText = 'Inconnue'; $expiryState = 'Inconnu'; $expiryLimit = 'Strategie ou date de changement non lisible.' }
    elseif ($null -ne $expiryUtc -and $expiryUtc -lt $NowUtc) { $expiryText += ' (echu)' }
    $facts.Add((New-DomeniaFact -Fait 'Expiration du mot de passe' -Valeur $expiryText -Etat $expiryState -Source 'Compte utilisateur' -Limite $expiryLimit -Lecteur $Reader))
    $reasons = New-Object 'System.Collections.Generic.List[string]'
    if ($state.Known) {
        if ($state.SmartcardRequired) { $reasons.Add('Carte a puce exigee : le mot de passe n est pas utilisable pour ouvrir une session interactive.') }
        if ($state.PasswordNotRequired) { $reasons.Add('Mot de passe non requis (PASSWD_NOTREQD) : a revoir.') }
        if ($state.Disabled) { $reasons.Add('Compte desactive.') }
    }
    foreach ($reason in $reasons) { $facts.Add((New-DomeniaFact -Fait 'Restriction' -Valeur $reason -Source 'userAccountControl' -Lecteur $Reader)) }
    return [pscustomobject]@{PolicyKnown=$known;PolicySource=$sourceLabel;ExpiresUtc=$expiryUtc;Facts=$facts.ToArray()}
}

# ---------------------------------------------------------------- D063 lockout diagnosis on demand
function Get-DomeniaLockoutDiagnosis {
    # $User: attributes read on the controller named $Dc. $Events: lockout events {TimeUtc, CallerComputer} or $null when not read.
    param($User,[string]$Dc='',[object[]]$Events=$null,[string]$EventReadState='NotRequested',[TimeSpan]$LockoutDuration=[TimeSpan]::Zero,[bool]$PolicyKnown=$false,[string]$Reader='',[datetime]$NowUtc=[datetime]::UtcNow)
    $facts = New-Object 'System.Collections.Generic.List[object]'
    $source = 'Controleur ' + $Dc
    $state = Get-DomeniaAccountState (Get-DomeniaAttr $User 'userAccountControl' $null) (Get-DomeniaAttr $User 'msDS-User-Account-Control-Computed' $null) (Get-DomeniaAttr $User 'lockoutTime' $null)
    $lockoutUtc = ConvertTo-DomeniaUtcDate (Get-DomeniaAttr $User 'lockoutTime' $null)
    $verdict = 'Inconnu'
    if ($state.Locked -eq $true) { $verdict = 'Verrouille' ; $facts.Add((New-DomeniaFact -Fait 'Etat calcule par le controleur' -Valeur 'Verrouille' -Source $source -Date $NowUtc -Lecteur $Reader)) }
    elseif ($state.Locked -eq $false) { $verdict = 'NonVerrouille'; $facts.Add((New-DomeniaFact -Fait 'Etat calcule par le controleur' -Valeur 'Non verrouille' -Source $source -Date $NowUtc -Lecteur $Reader)) }
    else { $facts.Add((New-DomeniaFact -Fait 'Etat calcule par le controleur' -Valeur 'Non lu' -Etat Inconnu -Source $source -Limite 'Sans cet etat, un lockoutTime non nul ne prouve pas un verrouillage actuel.' -Lecteur $Reader)) }
    if ($null -ne $lockoutUtc) {
        $text = $lockoutUtc.ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss')
        $limit = 'Date du dernier verrouillage enregistre, pas son etat actuel.'
        if ($PolicyKnown -and $LockoutDuration -gt [TimeSpan]::Zero -and $state.Locked -ne $true -and $lockoutUtc.Add($LockoutDuration) -lt $NowUtc) { $text += ' (duree de verrouillage ecoulee)' }
        $facts.Add((New-DomeniaFact -Fait 'Dernier verrouillage' -Valeur $text -Source $source -Limite $limit -Lecteur $Reader))
    }
    $badCount = [string](Get-DomeniaAttr $User 'badPwdCount' '')
    if ($badCount) { $facts.Add((New-DomeniaFact -Fait 'Echecs de mot de passe' -Valeur $badCount -Source $source -Limite 'Compteur propre a ce controleur : il n est pas replique.' -Lecteur $Reader)) }
    $badTime = ConvertTo-DomeniaUtcDate (Get-DomeniaAttr $User 'badPasswordTime' $null)
    if ($null -ne $badTime) { $facts.Add((New-DomeniaFact -Fait 'Dernier echec' -Valeur $badTime.ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss') -Source $source -Limite 'Valeur propre a ce controleur.' -Lecteur $Reader)) }
    $recurrence = 0; $origins = @()
    switch ($EventReadState) {
        'Read' {
            $list = @(@($Events) | Where-Object { $null -ne $_ })
            $recurrence = $list.Count
            $origins = @($list | ForEach-Object { [string](Get-DomeniaMember $_ 'CallerComputer' '') } | Where-Object { $_ } | Group-Object | Sort-Object Count -Descending | ForEach-Object { $_.Name + ' (' + $_.Count + ')' })
            if ($recurrence) {
                $facts.Add((New-DomeniaFact -Fait 'Verrouillages journalises' -Valeur ([string]$recurrence + ' evenement(s) 4740') -Source ('Journal Securite de ' + $Dc) -Limite 'Fenetre et volume bornes ; un journal recycle peut ne plus contenir les evenements anciens.' -Lecteur $Reader))
                if ($origins.Count) { $facts.Add((New-DomeniaFact -Fait 'Postes a l origine' -Valeur ($origins -join ', ') -Source ('Journal Securite de ' + $Dc) -Hypothese 'Un poste recurrent suggere une session, un lecteur reseau ou un service utilisant un ancien mot de passe.' -Lecteur $Reader)) }
            } else {
                $facts.Add((New-DomeniaFact -Fait 'Verrouillages journalises' -Valeur 'Aucun dans la fenetre lue' -Source ('Journal Securite de ' + $Dc) -Limite 'Absence dans la fenetre lue seulement.' -Lecteur $Reader))
            }
        }
        'Refused' { $facts.Add((New-DomeniaFact -Fait 'Verrouillages journalises' -Valeur 'Lecture refusee' -Etat Refuse -Source ('Journal Securite de ' + $Dc) -Limite 'Un refus de lecture ne signifie pas qu aucun verrouillage n a eu lieu.' -Lecteur $Reader)) }
        'Unavailable' { $facts.Add((New-DomeniaFact -Fait 'Verrouillages journalises' -Valeur 'Journal injoignable' -Etat Indisponible -Source ('Journal Securite de ' + $Dc) -Limite 'Aucune conclusion sur les verrouillages passes.' -Lecteur $Reader)) }
        default { $facts.Add((New-DomeniaFact -Fait 'Verrouillages journalises' -Valeur 'Non demandes' -Etat Inconnu -Source 'Journal Securite' -Limite 'La lecture du journal se demande explicitement.' -Lecteur $Reader)) }
    }
    return [pscustomobject]@{Verdict=$verdict;Recurrence=$recurrence;Origins=$origins;Facts=$facts.ToArray()}
}

# ---------------------------------------------------------------- D064 membership paths
function Get-DomeniaPrimaryGroupSid {
    param([AllowEmptyString()][string]$UserSid,[AllowEmptyString()][string]$PrimaryGroupId)
    $sid = ConvertTo-DomeniaSidText $UserSid
    $rid = 0L
    if (-not $sid -or -not [long]::TryParse([string]$PrimaryGroupId,[ref]$rid) -or $rid -le 0) { return '' }
    return ($sid.Substring(0,$sid.LastIndexOf('-')) + '-' + $rid)
}

function Find-DomeniaMembershipPath {
    # Breadth-first walk of memberOf edges with cycle protection and explicit limits.
    # $Edges: hashtable DN -> array of group DNs it is a direct member of.
    param([Collections.IDictionary]$Edges,[Parameter(Mandatory=$true)][string]$Start,[Parameter(Mandatory=$true)][string]$Target,[ValidateRange(1,64)][int]$MaxDepth=16,[ValidateRange(1,100000)][int]$MaxNodes=5000)
    $comparer = [StringComparer]::OrdinalIgnoreCase
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' $comparer
    $parent = New-Object 'System.Collections.Generic.Dictionary[string,string]' $comparer
    $depth = New-Object 'System.Collections.Generic.Dictionary[string,int]' $comparer
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $lookup = New-Object 'System.Collections.Generic.Dictionary[string,object]' $comparer
    if ($null -ne $Edges) { foreach ($key in @($Edges.Keys)) { $lookup[[string]$key] = $Edges[$key] } }
    [void]$visited.Add($Start); $depth[$Start] = 0; $queue.Enqueue($Start)
    $truncated = $false; $cycle = $false
    while ($queue.Count -gt 0) {
        $node = $queue.Dequeue()
        if ($comparer.Equals($node,$Target) -and -not $comparer.Equals($node,$Start)) {
            $path = New-Object 'System.Collections.Generic.List[string]'
            $cursor = $node
            while ($null -ne $cursor) { $path.Insert(0,$cursor); if ($parent.ContainsKey($cursor)) { $cursor = $parent[$cursor] } else { $cursor = $null } }
            return [pscustomobject]@{Found=$true;Path=$path.ToArray();Direct=($path.Count -eq 2);Truncated=$truncated;CycleSeen=$cycle;Visited=$visited.Count}
        }
        if ($depth[$node] -ge $MaxDepth) { $truncated = $true; continue }
        if (-not $lookup.ContainsKey($node)) { continue }
        foreach ($next in @($lookup[$node])) {
            $name = [string]$next
            if (-not $name) { continue }
            if (-not $visited.Add($name)) { $cycle = ($cycle -or $comparer.Equals($name,$Start) -or $parent.ContainsKey($name)); continue }
            if ($visited.Count -gt $MaxNodes) { $truncated = $true; break }
            $parent[$name] = $node; $depth[$name] = $depth[$node] + 1; $queue.Enqueue($name)
        }
        if ($visited.Count -gt $MaxNodes) { break }
    }
    return [pscustomobject]@{Found=$false;Path=@();Direct=$false;Truncated=$truncated;CycleSeen=$cycle;Visited=$visited.Count}
}

function Resolve-DomeniaMembershipAnswer {
    # $ServerAnswer: $true / $false from the controller's transitive test, or $null when it was not obtained.
    # A truncated local walk never concludes that a member is absent.
    param($ServerAnswer=$null,$LocalPath=$null,[bool]$ListTruncated=$false)
    if ($ServerAnswer -eq $true) { return [pscustomobject]@{Member=$true;Certain=$true;Text='Membre : confirme par le controleur (appartenance directe ou imbriquee).'} }
    if ($ServerAnswer -eq $false) { return [pscustomobject]@{Member=$false;Certain=$true;Text='Non membre : confirme par le controleur pour ce compte de lecture.'} }
    if ($null -ne $LocalPath -and [bool](Get-DomeniaMember $LocalPath 'Found' $false)) { return [pscustomobject]@{Member=$true;Certain=$true;Text='Membre : chemin d appartenance trouve.'} }
    $truncated = ($ListTruncated -or ($null -ne $LocalPath -and [bool](Get-DomeniaMember $LocalPath 'Truncated' $false)))
    if ($truncated) { return [pscustomobject]@{Member=$null;Certain=$false;Text='Indetermine : la liste lue est tronquee. Demandez le test au controleur.'} }
    return [pscustomobject]@{Member=$false;Certain=$false;Text='Aucun chemin dans les appartenances lues. Appartenance au groupe principal et groupes d autres domaines non couverts.'}
}

# ---------------------------------------------------------------- D065 comparing two users
function Test-DomeniaPrivilegedGroup {
    param($Group)
    $sid = [string](Get-DomeniaMember $Group 'Sid' '')
    $name = [string](Get-DomeniaMember $Group 'Name' '')
    if ([string](Get-DomeniaMember $Group 'AdminCount' '') -eq '1') { return $true }
    if ($sid -match '^S-1-5-32-(544|548|549|550|551)$') { return $true }
    if ($sid -match '-(512|516|517|518|519|520|526|527)$') { return $true }
    return ($name -match '(?i)^(Admins du domaine|Domain Admins|Administrateurs de l.entreprise|Enterprise Admins|Administrateurs du sch.ma|Schema Admins|Administrateurs|Administrators|Op.rateurs de compte|Account Operators|Op.rateurs de serveur|Server Operators|Op.rateurs de sauvegarde|Backup Operators|Propri.taires cr.ateurs de la strat.gie de groupe|Group Policy Creator Owners|DnsAdmins)$')
}

function Compare-DomeniaUserAccess {
    # Read-only comparison. The result carries no "apply" action: nothing is copied from one user to the other.
    param($Left,$Right,[string[]]$Attributes=@('department','title','company','physicalDeliveryOfficeName','manager'))
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $labels = @{department='Service';title='Fonction';company='Societe';physicalDeliveryOfficeName='Bureau';manager='Responsable'}
    foreach ($attribute in $Attributes) {
        $l = [string](Get-DomeniaAttr (Get-DomeniaMember $Left 'Attributes' $null) $attribute ''); $r = [string](Get-DomeniaAttr (Get-DomeniaMember $Right 'Attributes' $null) $attribute '')
        if ($attribute -eq 'manager') { $l = Get-DomeniaCnFromDn $l; $r = Get-DomeniaCnFromDn $r }
        $label = $attribute; if ($labels.ContainsKey($attribute)) { $label = $labels[$attribute] }
        $rows.Add([pscustomobject]@{Rubrique='Organisation';Element=$label;Gauche=$l;Droite=$r;Identique=($l -ceq $r);Privilegie=$false;Alerte=''})
    }
    $index = @{}
    foreach ($side in @('Left','Right')) {
        $user = if ($side -eq 'Left') { $Left } else { $Right }
        foreach ($group in @(Get-DomeniaMember $user 'Groups' @())) {
            if ($null -eq $group) { continue }
            $key = ([string](Get-DomeniaMember $group 'Dn' (Get-DomeniaMember $group 'Name' ''))).ToLowerInvariant()
            if (-not $key) { continue }
            if (-not $index.ContainsKey($key)) { $index[$key] = [pscustomobject]@{Group=$group;Left=$false;Right=$false} }
            $index[$key].$side = $true
        }
    }
    foreach ($key in @($index.Keys | Sort-Object)) {
        $entry = $index[$key]
        $privileged = Test-DomeniaPrivilegedGroup $entry.Group
        $alert = ''
        if ($privileged) { $alert = 'Groupe a privileges : toute attribution se decide et se justifie au cas par cas.' }
        $rows.Add([pscustomobject]@{Rubrique='Groupes';Element=[string](Get-DomeniaMember $entry.Group 'Name' $key);Gauche=$(if ($entry.Left) { 'Membre' } else { '' });Droite=$(if ($entry.Right) { 'Membre' } else { '' });Identique=($entry.Left -eq $entry.Right);Privilegie=$privileged;Alerte=$alert})
    }
    $different = @($rows | Where-Object { -not $_.Identique })
    return [pscustomobject]@{Rows=$rows.ToArray();Differences=$different.Count;PrivilegedDifferences=@($different | Where-Object { $_.Privilegie }).Count;CanApply=$false;Note='Comparaison en lecture. Aucune difference n est appliquee automatiquement.'}
}

# ---------------------------------------------------------------- D066 group changes as a delta
function New-DomeniaGroupDelta {
    # Only the chosen additions and removals. The full membership list in memory is never written back.
    param([string[]]$CurrentGroups=@(),[string[]]$Add=@(),[string[]]$Remove=@(),[string]$MemberDn='')
    $comparer = [StringComparer]::OrdinalIgnoreCase
    $current = New-Object 'System.Collections.Generic.HashSet[string]' $comparer
    foreach ($group in @($CurrentGroups)) { if ($group) { [void]$current.Add($group) } }
    $operations = New-Object 'System.Collections.Generic.List[object]'
    $notes = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' $comparer
    foreach ($group in @($Add)) {
        if (-not $group -or -not $seen.Add('+' + $group)) { continue }
        if (@($Remove) -contains $group) { $notes.Add((Get-DomeniaCnFromDn $group) + ' : demande d ajout et de retrait a la fois, ignoree.'); continue }
        if ($current.Contains($group)) { $notes.Add((Get-DomeniaCnFromDn $group) + ' : deja membre d apres la derniere lecture ; l ajout sera revérifie sur le controleur.') }
        $operations.Add([pscustomobject]@{Action='Add';GroupDn=$group;MemberDn=$MemberDn;Label=('Ajouter a ' + (Get-DomeniaCnFromDn $group));Expected=$true})
    }
    foreach ($group in @($Remove)) {
        if (-not $group -or -not $seen.Add('-' + $group)) { continue }
        if (@($Add) -contains $group) { continue }
        if (-not $current.Contains($group)) { $notes.Add((Get-DomeniaCnFromDn $group) + ' : non membre d apres la derniere lecture ; le retrait sera revérifie sur le controleur.') }
        $operations.Add([pscustomobject]@{Action='Remove';GroupDn=$group;MemberDn=$MemberDn;Label=('Retirer de ' + (Get-DomeniaCnFromDn $group));Expected=$false})
    }
    return [pscustomobject]@{Operations=$operations.ToArray();Notes=$notes.ToArray();WritesFullList=$false;Effects=@($operations | ForEach-Object { $_.Label })}
}

function Test-DomeniaGroupDeltaPostcondition {
    # $Observed: hashtable groupDn -> $true/$false/$null (membership re-read on the controller after the change).
    param($Delta,[Collections.IDictionary]$Observed)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($operation in @($Delta.Operations)) {
        $seen = $null
        if ($null -ne $Observed) { foreach ($key in @($Observed.Keys)) { if ([string]$key -ieq [string]$operation.GroupDn) { $seen = $Observed[$key]; break } } }
        $status = 'A verifier'
        if ($null -ne $seen) { $status = if ([bool]$seen -eq [bool]$operation.Expected) { 'Verifie' } else { 'Echec' } }
        $rows.Add([pscustomobject]@{Label=$operation.Label;GroupDn=$operation.GroupDn;Status=$status})
    }
    $all = $rows.ToArray()
    $overall = 'Verifie'
    if (@($all | Where-Object { $_.Status -eq 'Echec' }).Count) { $overall = 'Partiel' }
    elseif (@($all | Where-Object { $_.Status -eq 'A verifier' }).Count) { $overall = 'A verifier' }
    if (-not $all.Count) { $overall = 'Aucun changement' }
    return [pscustomobject]@{Overall=$overall;Rows=$all}
}

# ---------------------------------------------------------------- D067 reading delegations
function ConvertTo-DomeniaAceView {
    # Shows what an ACE says and where it comes from. An observed ACE is not a verified capability.
    param([object[]]$Aces=@(),[Collections.IDictionary]$GuidNames=$null)
    foreach ($ace in @($Aces)) {
        if ($null -eq $ace) { continue }
        $inherited = [bool](Get-DomeniaMember $ace 'IsInherited' $false)
        $scope = switch ([string](Get-DomeniaMember $ace 'InheritanceType' 'None')) {
            'All' { 'Cet objet et tous ses descendants' } 'Descendents' { 'Descendants uniquement' } 'Children' { 'Enfants directs uniquement' }
            'SelfAndChildren' { 'Cet objet et ses enfants directs' } default { 'Cet objet uniquement' }
        }
        $objectType = [string](Get-DomeniaMember $ace 'ObjectType' '')
        $on = ''
        if ($objectType -and $objectType -ne '00000000-0000-0000-0000-000000000000') {
            $on = $objectType
            if ($null -ne $GuidNames) { foreach ($key in @($GuidNames.Keys)) { if ([string]$key -ieq $objectType) { $on = [string]$GuidNames[$key]; break } } }
        }
        [pscustomobject]@{
            Beneficiaire=[string](Get-DomeniaMember $ace 'IdentityReference' '')
            Type=$(if ([string](Get-DomeniaMember $ace 'AccessControlType' 'Allow') -eq 'Deny') { 'Refus' } else { 'Autorisation' })
            Droits=[string](Get-DomeniaMember $ace 'ActiveDirectoryRights' '')
            Cible=$on
            Origine=$(if ($inherited) { 'Heritee d un conteneur parent' } else { 'Posee sur cet objet' })
            Portee=$scope
            Statut='ACE observee'
            Limite='Lecture de la liste de controle d acces. Le droit effectif depend aussi des groupes, des refus et des privileges du compte.'
        }
    }
}

# ---------------------------------------------------------------- D068 account life cycle
function New-DomeniaLifecyclePlan {
    # A prepared sequence. Each sensitive step needs its own confirmation; nothing deletes or migrates.
    param([Parameter(Mandatory=$true)][ValidateSet('Arrivee','ChangementService','Suspension')][string]$Kind,[Parameter(Mandatory=$true)]$User,$Template=$null)
    $steps = New-Object 'System.Collections.Generic.List[object]'
    $add = { param([string]$title,[string]$operation,[bool]$sensitive,$parameters) $steps.Add([pscustomobject]@{Id=($steps.Count + 1);Title=$title;Operation=$operation;Sensitive=$sensitive;Parameters=$parameters;State='Pending';Note=''}) }
    $groupsAdd = @(Get-DomeniaMember $Template 'AddGroups' @()); $groupsRemove = @(Get-DomeniaMember $Template 'RemoveGroups' @())
    $targetOu = [string](Get-DomeniaMember $Template 'TargetOu' '')
    switch ($Kind) {
        'Arrivee' {
            & $add 'Verifier la fiche (service, responsable, bureau)' 'Review' $false $null
            if ($groupsAdd.Count) { & $add ('Ajouter aux groupes du modele (' + $groupsAdd.Count + ')') 'GroupDelta' $true ([pscustomobject]@{Add=$groupsAdd;Remove=@()}) }
            & $add 'Activer le compte' 'EnableAccount' $true $null
        }
        'ChangementService' {
            & $add 'Mettre a jour service, fonction et responsable' 'Attributes' $true (Get-DomeniaMember $Template 'Attributes' $null)
            if ($groupsAdd.Count -or $groupsRemove.Count) { & $add 'Ajuster les groupes choisis' 'GroupDelta' $true ([pscustomobject]@{Add=$groupsAdd;Remove=$groupsRemove}) }
            if ($targetOu) { & $add 'Deplacer vers la nouvelle OU' 'Move' $true ([pscustomobject]@{TargetOu=$targetOu}) }
        }
        'Suspension' {
            & $add 'Desactiver le compte' 'DisableAccount' $true $null
            & $add 'Consigner le motif dans la description' 'Attributes' $true (Get-DomeniaMember $Template 'Attributes' $null)
            if ($targetOu) { & $add 'Deplacer vers l OU des comptes suspendus' 'Move' $true ([pscustomobject]@{TargetOu=$targetOu}) }
        }
    }
    return [pscustomobject]@{Kind=$Kind;User=$User;Steps=$steps.ToArray();Deletes=$false;Migrates=$false;Blocked=$false;BlockReason=''}
}

function Set-DomeniaLifecycleStep {
    # Records the outcome of one step. An uncertain outcome blocks the following steps and is never replayed.
    param($Plan,[int]$StepId,[Parameter(Mandatory=$true)][ValidateSet('Verified','Failed','Uncertain','Skipped','Resolved')][string]$Outcome,[string]$Note='')
    $step = @($Plan.Steps | Where-Object { $_.Id -eq $StepId })
    if (-not $step.Count) { return $Plan }
    if ($Outcome -eq 'Resolved') {
        if ($step[0].State -eq 'Uncertain') { $step[0].State = 'Verified'; $step[0].Note = $Note; $Plan.Blocked = $false; $Plan.BlockReason = '' }
        return $Plan
    }
    $step[0].State = $Outcome; $step[0].Note = $Note
    if ($Outcome -eq 'Uncertain') { $Plan.Blocked = $true; $Plan.BlockReason = ('Etape ' + $StepId + ' a verifier avant de poursuivre. Elle ne sera pas rejouee.') }
    if ($Outcome -eq 'Failed') { $Plan.Blocked = $true; $Plan.BlockReason = ('Etape ' + $StepId + ' en echec : decidez de la reprendre ou d arreter.') }
    return $Plan
}

function Get-DomeniaLifecycleNextStep {
    param($Plan)
    if ($null -eq $Plan -or [bool]$Plan.Blocked) { return $null }
    return @($Plan.Steps | Where-Object { $_.State -eq 'Pending' } | Select-Object -First 1)[0]
}

# ---------------------------------------------------------------- D069 inconsistencies on a chosen perimeter
function Find-DomeniaDirectoryInconsistencies {
    # $Objects: rows {Guid, Name, Type, Mail, Upn, EmployeeId, Description, ManagerDn, Disabled, LastLogonUtc, PwdLastSet}.
    # Every finding is "to review". Nothing is ever declared removable.
    param([object[]]$Objects=@(),[string[]]$KnownDns=@(),[ValidateRange(30,3650)][int]$StaleDays=180,[datetime]$NowUtc=[datetime]::UtcNow,[bool]$Truncated=$false)
    $findings = New-Object 'System.Collections.Generic.List[object]'
    $limit = 'Perimetre choisi uniquement.'
    if ($Truncated) { $limit = 'Perimetre lu partiellement : la liste des constats est incomplete.' }
    foreach ($field in @(@('Mail','Adresse de messagerie'),@('Upn','Nom de connexion'),@('EmployeeId','Matricule'))) {
        $groups = @(@($Objects) | Where-Object { [string](Get-DomeniaMember $_ $field[0] '') } | Group-Object { ([string](Get-DomeniaMember $_ $field[0] '')).ToLowerInvariant() } | Where-Object { $_.Count -gt 1 })
        foreach ($group in $groups) {
            $findings.Add([pscustomobject]@{Categorie='Valeur en double';Element=$field[1] + ' : ' + $group.Name;Objets=(@($group.Group | ForEach-Object { [string](Get-DomeniaMember $_ 'Name' '') }) -join ', ');Conclusion='A revoir';Limite=$limit + ' Un doublon visible ne designe pas l objet a corriger.'})
        }
    }
    $known = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($dn in @($KnownDns)) { if ($dn) { [void]$known.Add($dn) } }
    foreach ($object in @($Objects)) {
        if ($null -eq $object) { continue }
        $name = [string](Get-DomeniaMember $object 'Name' '')
        $type = [string](Get-DomeniaMember $object 'Type' '')
        $manager = [string](Get-DomeniaMember $object 'ManagerDn' '')
        if ($type -eq 'Utilisateur' -and -not [string](Get-DomeniaMember $object 'Description' '') -and -not [string](Get-DomeniaMember $object 'Department' 'x')) {
            $findings.Add([pscustomobject]@{Categorie='Information manquante';Element='Service et description absents';Objets=$name;Conclusion='A revoir';Limite=$limit})
        }
        if ($manager -and $known.Count -gt 0 -and -not $known.Contains($manager)) {
            $findings.Add([pscustomobject]@{Categorie='Responsable a verifier';Element=(Get-DomeniaCnFromDn $manager);Objets=$name;Conclusion='A revoir';Limite='Responsable hors du perimetre lu : son existence n est pas verifiee ici.'})
        }
        $lastLogon = ConvertTo-DomeniaUtcDate (Get-DomeniaMember $object 'LastLogonUtc' $null)
        if ($null -ne $lastLogon -and ($NowUtc - $lastLogon).TotalDays -gt $StaleDays -and -not [bool](Get-DomeniaMember $object 'Disabled' $false)) {
            $findings.Add([pscustomobject]@{Categorie='Objet peu utilise';Element=('Derniere ouverture de session il y a ' + [int]($NowUtc - $lastLogon).TotalDays + ' jours');Objets=$name;Conclusion='A revoir';Limite='Date approximative (replication differee). Une date ancienne ne suffit pas a declarer un objet supprimable.'})
        }
        if ($type -eq 'Utilisateur' -and [string](Get-DomeniaMember $object 'PwdLastSet' 'x') -eq '0' -and $null -eq $lastLogon) {
            $findings.Add([pscustomobject]@{Categorie='Compte jamais utilise';Element='Mot de passe jamais defini par l utilisateur';Objets=$name;Conclusion='A revoir';Limite=$limit})
        }
    }
    return $findings.ToArray()
}

# ---------------------------------------------------------------- D070 comparing a target between controllers
function ConvertFrom-DomeniaReplMetadata {
    # Parses msDS-ReplAttributeMetaData values (one XML fragment per attribute).
    param([string[]]$Values=@())
    foreach ($value in @($Values)) {
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $document = New-Object Xml.XmlDocument
        # Fragments come from a directory attribute: no DTD and no external entity is ever resolved.
        $document.XmlResolver = $null
        try { $document.LoadXml(([string]$value).Trim([char]0)) } catch { continue }
        $node = $document.DocumentElement
        if ($null -eq $node) { continue }
        $get = { param([string]$name) $child = $node.SelectSingleNode($name); if ($null -ne $child) { return [string]$child.InnerText }; return '' }
        $dsa = & $get 'pszLastOriginatingDsaDN'
        $origin = ''
        if ($dsa -match '(?i)CN=NTDS Settings,CN=([^,]+),') { $origin = $Matches[1] }
        [pscustomobject]@{
            Attribute=(& $get 'pszAttributeName');Version=(& $get 'dwVersion')
            ChangedUtc=(ConvertTo-DomeniaUtcDate (& $get 'ftimeLastOriginatingChange'))
            OriginatingDc=$origin;LocalUsn=(& $get 'usnLocalChange');OriginatingUsn=(& $get 'usnOriginatingChange')
        }
    }
}

function Compare-DomeniaDcReadings {
    # $Readings: {Dc, Reachable, Error, Attributes (hashtable), Metadata (from ConvertFrom-DomeniaReplMetadata)} for ONE object GUID.
    # Differences are dated per controller. Local USNs are shown but never compared across controllers.
    param([object[]]$Readings=@(),[string[]]$Attributes=@())
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $read = @(@($Readings) | Where-Object { $null -ne $_ -and [bool](Get-DomeniaMember $_ 'Reachable' $false) })
    $names = @($Attributes)
    if (-not $names.Count) { $names = @($read | ForEach-Object { @((Get-DomeniaMember $_ 'Attributes' @{}).Keys) } | ForEach-Object { [string]$_ } | Sort-Object -Unique) }
    foreach ($attribute in $names) {
        $values = New-Object 'System.Collections.Generic.List[string]'
        $cells = [ordered]@{}
        foreach ($reading in $read) {
            $dc = [string](Get-DomeniaMember $reading 'Dc' '')
            $value = (@(Get-DomeniaAttrAll (Get-DomeniaMember $reading 'Attributes' $null) $attribute) | ForEach-Object { [string]$_ } | Sort-Object) -join ' | '
            $meta = @(@(Get-DomeniaMember $reading 'Metadata' @()) | Where-Object { [string](Get-DomeniaMember $_ 'Attribute' '') -ieq $attribute } | Select-Object -First 1)
            $stamp = ''
            if ($meta.Count -and $null -ne $meta[0].ChangedUtc) { $stamp = ' [v' + $meta[0].Version + ', ' + $meta[0].ChangedUtc.ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss') + ', origine ' + $meta[0].OriginatingDc + ']' }
            $cells[$dc] = $value + $stamp
            $values.Add($value)
        }
        $distinct = @($values.ToArray() | Select-Object -Unique)
        $rows.Add([pscustomobject]@{Attribut=$attribute;Identique=($distinct.Count -le 1);ParControleur=$cells;Lus=$read.Count})
    }
    $unreachable = @(@($Readings) | Where-Object { $null -ne $_ -and -not [bool](Get-DomeniaMember $_ 'Reachable' $false) } | ForEach-Object { [string](Get-DomeniaMember $_ 'Dc' '') + ' : ' + [string](Get-DomeniaMember $_ 'Error' 'non lu') })
    $note = 'Les USN sont locaux a chaque controleur : ils ne constituent pas une horloge commune. Les dates sont celles de la derniere modification d origine.'
    $comparable = ($read.Count -ge 2)
    return [pscustomobject]@{Rows=$rows.ToArray();Differences=@($rows | Where-Object { -not $_.Identique }).Count;Comparable=$comparable;NotRead=$unreachable;Note=$note}
}
