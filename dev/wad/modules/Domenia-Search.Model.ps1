# Search and navigation rules: global search contract, search/browse separation, optional syntax,
# ranking, LDAP literals, pasted identifiers, explicit continuation, work views, OU paths, history.
# Pure text and data decisions: no LDAP query is sent from this module.

# ---------------------------------------------------------------- D035 LDAP literals
function ConvertTo-DomeniaLdapLiteral {
    # RFC 4515 escaping. With -KeepWildcard an asterisk typed by the operator stays a wildcard.
    param([AllowEmptyString()][AllowNull()][string]$Value,[switch]$KeepWildcard)
    $builder = [Text.StringBuilder]::new()
    foreach ($character in ([string]$Value).ToCharArray()) {
        switch ([int]$character) {
            0  { [void]$builder.Append('\00') }
            40 { [void]$builder.Append('\28') }
            41 { [void]$builder.Append('\29') }
            42 { if ($KeepWildcard) { [void]$builder.Append('*') } else { [void]$builder.Append('\2a') } }
            92 { [void]$builder.Append('\5c') }
            default { [void]$builder.Append($character) }
        }
    }
    return $builder.ToString()
}

function Split-DomeniaSearchWords {
    # Words are separated by white space only: hyphens, apostrophes and accents stay inside a word.
    param([AllowEmptyString()][AllowNull()][string]$Text)
    return @(([string]$Text).Trim() -split '\s+' | Where-Object { $_ })
}

function Get-DomeniaTypeFilter {
    param([string]$Type='')
    switch -Regex ($Type) {
        '^(?i:Utilisateur|Utilisateurs|User)$' { return '(&(objectCategory=person)(objectClass=user))' }
        '^(?i:Machine|Machines|Poste|Computer)$' { return '(objectCategory=computer)' }
        '^(?i:Groupe|Groupes|Group)$' { return '(objectCategory=group)' }
        '^(?i:OU|OU et conteneurs|Conteneur)$' { return '(|(objectClass=organizationalUnit)(objectClass=container))' }
        default { return '(|(objectCategory=person)(objectCategory=computer)(objectCategory=group)(objectClass=organizationalUnit))' }
    }
}

# ---------------------------------------------------------------- D033 optional explicit syntax
function ConvertFrom-DomeniaSearchSyntax {
    # utilisateur: poste: groupe: mail: are the only prefixes that refine the global search.
    # Anything else stays plain text and is explained; no hidden filter is ever added.
    param([AllowEmptyString()][AllowNull()][string]$Text)
    $known = @{
        'utilisateur'='Utilisateur';'user'='Utilisateur';'u'='Utilisateur'
        'poste'='Machine';'pc'='Machine';'machine'='Machine';'ordinateur'='Machine'
        'groupe'='Groupe';'group'='Groupe';'g'='Groupe'
        'mail'='Mail';'email'='Mail';'courriel'='Mail'
    }
    $tokens = [Collections.Generic.List[object]]::new()
    $notes = [Collections.Generic.List[string]]::new()
    $free = [Collections.Generic.List[string]]::new()
    $pattern = '(?<prefix>[\p{L}]+):(?:"(?<quoted>[^"]*)"|(?<bare>\S*))|"(?<phrase>[^"]*)"|(?<word>\S+)'
    foreach ($match in [regex]::Matches(([string]$Text).Trim(),$pattern)) {
        if ($match.Groups['prefix'].Success) {
            $prefix = $match.Groups['prefix'].Value.ToLowerInvariant()
            $value = if ($match.Groups['quoted'].Success) { $match.Groups['quoted'].Value } else { $match.Groups['bare'].Value }
            if ($known.ContainsKey($prefix)) {
                if ([string]::IsNullOrWhiteSpace($value)) { $notes.Add('Jeton « ' + $prefix + ': » sans valeur : ignore.'); continue }
                $tokens.Add([pscustomobject]@{Prefix=$prefix;Kind=$known[$prefix];Value=$value.Trim();Label=($known[$prefix] + ' : ' + $value.Trim())})
            } else {
                $free.Add($match.Value)
                $notes.Add('« ' + $prefix + ': » n est pas un jeton reconnu : cherche comme texte.')
            }
            continue
        }
        if ($match.Groups['phrase'].Success) { if ($match.Groups['phrase'].Value.Trim()) { $free.Add($match.Groups['phrase'].Value.Trim()) }; continue }
        $free.Add($match.Groups['word'].Value)
    }
    $types = @($tokens | Where-Object { $_.Kind -ne 'Mail' } | ForEach-Object { $_.Kind } | Select-Object -Unique)
    $type = ''
    if ($types.Count -eq 1) { $type = [string]$types[0] }
    elseif ($types.Count -gt 1) { $notes.Add('Plusieurs types demandes : chaque jeton est cherche dans son type.') }
    return [pscustomobject]@{Tokens=$tokens.ToArray();FreeText=($free.ToArray() -join ' ');Type=$type;Notes=$notes.ToArray();HasSyntax=($tokens.Count -gt 0)}
}

# ---------------------------------------------------------------- D035 filter construction
function Get-DomeniaWordFilter {
    param([Parameter(Mandatory=$true)][string]$Word,[string[]]$Attributes=@('cn','sAMAccountName','displayName','sn','givenName','userPrincipalName','mail','dNSHostName'))
    $literal = ConvertTo-DomeniaLdapLiteral $Word -KeepWildcard
    # Prefix match only: a leading wildcard is used solely when the operator typed it.
    $suffix = '*'
    if ($literal.EndsWith('*')) { $suffix = '' }
    $parts = @($Attributes | ForEach-Object { '(' + $_ + '=' + $literal + $suffix + ')' })
    return '(|' + ($parts -join '') + ')'
}

function ConvertTo-DomeniaSearchFilter {
    # Returns {Filter, Valid, Reason, Costly}. Several words must all match (in any attribute).
    param([AllowEmptyString()][AllowNull()][string]$Text,[string]$Type='',[object[]]$Tokens=@(),[int]$MinimumLength=2)
    $words = @(Split-DomeniaSearchWords $Text)
    $blocks = [Collections.Generic.List[string]]::new()
    $tokenTypes = [Collections.Generic.List[string]]::new()
    foreach ($token in @($Tokens)) {
        $value = [string](Get-DomeniaMember $token 'Value' '')
        if (-not $value) { continue }
        $kind = [string](Get-DomeniaMember $token 'Kind' '')
        if ($kind -eq 'Mail') {
            $literal = ConvertTo-DomeniaLdapLiteral $value -KeepWildcard
            $blocks.Add('(|(mail=' + $literal + '*)(proxyAddresses=smtp:' + $literal + '*))')
        } else {
            $inner = '(&' + (($(Split-DomeniaSearchWords $value) | ForEach-Object { Get-DomeniaWordFilter $_ }) -join '') + ')'
            $tokenTypes.Add('(&' + (Get-DomeniaTypeFilter $kind) + $inner + ')')
        }
    }
    $meaningful = @($words | Where-Object { ($_ -replace '\*','').Length -ge $MinimumLength })
    if (-not $blocks.Count -and -not $tokenTypes.Count) {
        if (-not $words.Count) { return [pscustomobject]@{Filter='';Valid=$false;Reason='Saisissez un nom, un identifiant ou un jeton de recherche.';Costly=$false} }
        if (-not $meaningful.Count) { return [pscustomobject]@{Filter='';Valid=$false;Reason=('Saisissez au moins ' + $MinimumLength + ' caracteres : une recherche plus courte parcourrait tout le domaine.');Costly=$true} }
    }
    foreach ($word in $words) { $blocks.Add((Get-DomeniaWordFilter $word)) }
    $typeFilter = Get-DomeniaTypeFilter $Type
    $body = ''
    if ($blocks.Count) { $body = '(&' + $typeFilter + ($blocks.ToArray() -join '') + ')' }
    if ($tokenTypes.Count) {
        $alternatives = @($tokenTypes.ToArray())
        if ($body) { $alternatives += $body }
        if ($alternatives.Count -eq 1) { $body = $alternatives[0] } else { $body = '(|' + ($alternatives -join '') + ')' }
    }
    $costly = (@($words | Where-Object { $_.StartsWith('*') }).Count -gt 0)
    return [pscustomobject]@{Filter=$body;Valid=$true;Reason='';Costly=$costly}
}

# ---------------------------------------------------------------- D031 / D032 global search and browsing
function New-DomeniaGlobalSearchRequest {
    # The top bar always targets the connected domain. It never inherits an OU, a presence filter or a local filter.
    # Only an unambiguous identifier (GUID, SID, DN) replaces the filter; UPN, DOMAINE\compte and FQDN stay explained only.
    param([AllowEmptyString()][string]$Text,[Parameter(Mandatory=$true)][string]$DomainDn,[int]$Limit=100,[string]$Reader='',[long]$Generation=0)
    $syntax = ConvertFrom-DomeniaSearchSyntax $Text
    $identifier = Get-DomeniaPastedIdentifier $Text
    $filter = $null
    if ($identifier.Kind -in @('Guid','Sid','DN')) { $filter = [pscustomobject]@{Filter=$identifier.Filter;Valid=$true;Reason='';Costly=$false} }
    else { $filter = ConvertTo-DomeniaSearchFilter -Text $syntax.FreeText -Type $syntax.Type -Tokens $syntax.Tokens }
    return [pscustomobject]@{
        Mode='Global';BaseDn=$DomainDn;Scope='Subtree';PresenceFilter='';LocalFilter='';OuDn=''
        Text=([string]$Text).Trim();Limit=[Math]::Max(1,[Math]::Min(20000,$Limit))
        Filter=$filter.Filter;Valid=$filter.Valid;Reason=$filter.Reason
        Tokens=$syntax.Tokens;Notes=$syntax.Notes;Identifier=$identifier;Reader=$Reader;Generation=$Generation
        ScopeLabel='Domaine entier'
    }
}

function Test-DomeniaGlobalSearchRequest {
    param($Request,[Parameter(Mandatory=$true)][string]$DomainDn)
    if ($null -eq $Request) { return $false }
    return (([string]$Request.Mode) -eq 'Global' -and ([string]$Request.BaseDn) -ieq $DomainDn -and ([string]$Request.Scope) -eq 'Subtree' -and
        -not [string]$Request.PresenceFilter -and -not [string]$Request.LocalFilter -and -not [string]$Request.OuDn)
}

function New-DomeniaSearchState {
    return [pscustomobject]@{Global=[pscustomobject]@{Text='';Generation=0L};Browse=[pscustomobject]@{OuDn='';Subtree=$true;Filter='';Type='Tous'};Mode='Global'}
}

function Set-DomeniaBrowseOu {
    # Selecting an OU starts browsing with its own empty filter: the global text is kept but not applied to the OU.
    param($State,[Parameter(Mandatory=$true)][string]$OuDn,[bool]$Subtree=$true)
    $State.Browse.OuDn = $OuDn; $State.Browse.Subtree = $Subtree; $State.Browse.Filter = ''; $State.Mode = 'Browse'
    return $State
}

function Get-DomeniaScopeLabel {
    param([Parameter(Mandatory=$true)][ValidateSet('Global','Browse')][string]$Mode,[string]$OuName='',[bool]$Subtree=$true)
    if ($Mode -eq 'Global') { return 'Domaine entier' }
    $name = $OuName
    if (-not $name) { $name = 'OU non choisie' }
    if ($Subtree) { return ('Dans cette OU : ' + $name + ' · Sous-OU incluses') }
    return ('Dans cette OU : ' + $name + ' · Enfants directs')
}

function Get-DomeniaGlobalSearchPlan {
    # Decides, without any LDAP call, how the text of the upper bar refines the global search.
    # Kind: Default (runtime filters unchanged), Identifier (exact GUID/SID/DN only), Syntax (explicit tokens only),
    # Invalid (nothing is sent). MultiWordFilter replaces the broad fallback for several words (each word must match).
    # The upper bar never inherits an OU, a presence filter or a local filter: $TypeFilter is the global type filter.
    param([AllowEmptyString()][AllowNull()][string]$Text,[Parameter(Mandatory=$true)][string]$TypeFilter,[int]$MinimumLength=2,[bool]$SyntaxEnabled=$true)
    $value = ([string]$Text).Trim()
    $plan = [pscustomobject]@{Kind='Default';Filter='';MultiWordFilter='';Hint='';Valid=$true;Reason='';Identifier=$null;Tokens=@();AutoOpen=$false}
    if (-not $value -or $value -eq '*') { return $plan }
    $notes = [Collections.Generic.List[string]]::new()
    if ($SyntaxEnabled) {
        $identifier = Get-DomeniaPastedIdentifier $value
        if ($identifier.Kind -in @('Guid','Sid','DN')) {
            $plan.Kind = 'Identifier'; $plan.Identifier = $identifier
            $plan.Filter = '(&' + $TypeFilter + $identifier.Filter + ')'
            $plan.Hint = $identifier.Explanation + ' Aucun résultat nʼest ouvert automatiquement.'
            return $plan
        }
        if ($identifier.Kind -ne 'None') { $plan.Identifier = $identifier; $notes.Add($identifier.Explanation) }
        $syntax = ConvertFrom-DomeniaSearchSyntax $value
        if ($syntax.HasSyntax) {
            $built = ConvertTo-DomeniaSearchFilter -Text $syntax.FreeText -Type $syntax.Type -Tokens $syntax.Tokens -MinimumLength $MinimumLength
            $labels = @($syntax.Tokens | ForEach-Object { [string]$_.Label })
            $plan.Tokens = $syntax.Tokens
            if (-not $built.Valid) {
                $plan.Kind = 'Invalid'; $plan.Valid = $false; $plan.Reason = $built.Reason
                $plan.Hint = 'Jetons : ' + ($labels -join ' · ') + ' · ' + $built.Reason
                return $plan
            }
            $plan.Kind = 'Syntax'
            $plan.Filter = '(&' + $TypeFilter + $built.Filter + ')'
            $text = 'Jetons : ' + ($labels -join ' · ')
            if ($syntax.FreeText) { $text += ' · texte : ' + $syntax.FreeText }
            foreach ($note in @($syntax.Notes)) { $text += ' · ' + $note }
            $plan.Hint = $text
            return $plan
        }
        foreach ($note in @($syntax.Notes)) { $notes.Add($note) }
    }
    $plan.Hint = ($notes.ToArray() -join ' ')
    # An explicit wildcard keeps its own explicit filter in the runtime.
    if ($value.Contains('*')) { return $plan }
    $words = @(Split-DomeniaSearchWords $value)
    if ($words.Count -ge 2) {
        $plan.MultiWordFilter = '(&' + $TypeFilter + (($words | ForEach-Object { Get-DomeniaWordFilter $_ }) -join '') + ')'
    }
    return $plan
}

function Get-DomeniaFavouriteName {
    # Name of a saved search, built from what is visible. No dialog window, no account, no right.
    param([ValidateSet('Global','OU')][string]$Mode='Global',[AllowEmptyString()][string]$Text='',[AllowEmptyString()][string]$OuName='',[AllowEmptyString()][string]$ViewName='')
    $query = ([string]$Text).Trim()
    if ($ViewName) { $name = 'Vue : ' + $ViewName }
    elseif ($Mode -eq 'Global') { $name = 'Domaine entier : ' + $(if ($query) { $query } else { 'tout' }) }
    else {
        $ou = $OuName
        if (-not $ou) { $ou = 'OU' }
        $name = $ou + $(if ($query) { ' : ' + $query } else { '' })
    }
    return (ConvertTo-DomeniaFlatText $name 80)
}

# ---------------------------------------------------------------- D034 ranking
function Get-DomeniaSearchRank {
    # Lower is better: exact identifier, exact name, identifier prefix, whole word of the name,
    # name prefix, word prefix, substring, the rest. A whole word ('Jean Dupont' for 'dupont') ranks
    # before a longer word that only starts with the query ('Dupontel').
    param($Row,[AllowEmptyString()][string]$Query)
    $q = ([string]$Query).Trim().TrimEnd('*')
    if (-not $q) { return 9 }
    $login = [string](Get-DomeniaMember $Row 'Login' ''); $upn = [string](Get-DomeniaMember $Row 'UPN' '')
    $name = [string](Get-DomeniaMember $Row 'Name' ''); $display = [string](Get-DomeniaMember $Row 'Display' ''); $mail = [string](Get-DomeniaMember $Row 'Mail' '')
    $ordinal = [StringComparison]::OrdinalIgnoreCase
    if ($login.Equals($q,$ordinal) -or $upn.Equals($q,$ordinal) -or $mail.Equals($q,$ordinal) -or ($upn -and ($upn -split '@')[0].Equals($q,$ordinal))) { return 0 }
    if ($name.Equals($q,$ordinal) -or $display.Equals($q,$ordinal)) { return 1 }
    if ($login.StartsWith($q,$ordinal) -or $upn.StartsWith($q,$ordinal)) { return 2 }
    $words = @(($name + ' ' + $display) -split '[\s\-]+' | Where-Object { $_ })
    foreach ($word in $words) { if ($word.Equals($q,$ordinal)) { return 3 } }
    if ($name.StartsWith($q,$ordinal) -or $display.StartsWith($q,$ordinal)) { return 4 }
    foreach ($word in $words) { if ($word.StartsWith($q,$ordinal)) { return 5 } }
    if ($login.IndexOf($q,$ordinal) -ge 0 -or $name.IndexOf($q,$ordinal) -ge 0 -or $display.IndexOf($q,$ordinal) -ge 0 -or $upn.IndexOf($q,$ordinal) -ge 0) { return 6 }
    return 7
}

function Test-DomeniaAdminAccountRow {
    # An administration account stays recognisable in a result list (adminCount or naming rule from the configuration).
    param($Row,[string[]]$LoginPatterns=@('^adm[-_.]','[-_.]adm$','^admin'))
    if ([string](Get-DomeniaMember $Row 'AdminCount' '') -eq '1') { return $true }
    $login = [string](Get-DomeniaMember $Row 'Login' '')
    foreach ($pattern in @($LoginPatterns)) { if ($pattern -and $login -match $pattern) { return $true } }
    return $false
}

function Sort-DomeniaSearchResults {
    # Deduplicates by identity (GUID, else DN), never by label, then orders by relevance and name.
    param([object[]]$Rows=@(),[AllowEmptyString()][string]$Query='')
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $ranked = [Collections.Generic.List[object]]::new()
    $position = 0
    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }
        $identity = ConvertTo-DomeniaGuidText (Get-DomeniaMember $row 'Guid' '')
        if (-not $identity) { $identity = 'dn:' + [string](Get-DomeniaMember $row 'DN' '') }
        if ($identity -eq 'dn:' -or -not $seen.Add($identity)) { continue }
        $ranked.Add([pscustomobject]@{Row=$row;Rank=(Get-DomeniaSearchRank $row $Query);Name=[string](Get-DomeniaMember $row 'Name' '');Position=$position})
        $position++
    }
    return @($ranked | Sort-Object Rank,Name,Position | ForEach-Object { $_.Row })
}

# ---------------------------------------------------------------- D036 pasted identifiers
function ConvertTo-DomeniaGuidFilterValue {
    param([Parameter(Mandatory=$true)][string]$Guid)
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($Guid,[ref]$parsed)) { return '' }
    return (($parsed.ToByteArray() | ForEach-Object { '\' + $_.ToString('x2') }) -join '')
}

function Get-DomeniaPastedIdentifier {
    # Recognises a pasted DN, GUID, SID, UPN, down-level name or FQDN and proposes the exact search.
    # AutoOpen is always false: recognising an identifier never selects or opens the first result.
    param([AllowEmptyString()][AllowNull()][string]$Text)
    $value = ([string]$Text).Trim()
    $none = [pscustomobject]@{Kind='None';Value=$value;Filter='';Explanation='';Ambiguous=$false;AutoOpen=$false}
    # -and / -or have the same precedence in PowerShell: the grouping must be explicit.
    if (-not $value -or ($value -match '\s' -and $value -notmatch '^(?i)(CN|OU|DC)=')) { return $none }
    if ($value -match '^\{?[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\}?$') {
        $bytes = ConvertTo-DomeniaGuidFilterValue $value
        if ($bytes) { return [pscustomobject]@{Kind='Guid';Value=$value.Trim('{','}');Filter='(objectGUID=' + $bytes + ')';Explanation='GUID reconnu : recherche exacte de cet objet.';Ambiguous=$false;AutoOpen=$false} }
    }
    if ($value -match '^(?i)S-1-\d+(-\d+){1,14}$') {
        return [pscustomobject]@{Kind='Sid';Value=$value.ToUpperInvariant();Filter='(objectSid=' + $value.ToUpperInvariant() + ')';Explanation='SID reconnu : recherche exacte de ce compte.';Ambiguous=$false;AutoOpen=$false}
    }
    # A DN is recognised RDN by RDN, so an escaped comma ('CN=Dupont\, Jean') stays inside its RDN.
    $rdns = @()
    if ($value -match '^(?i)(CN|OU|DC)=') { $rdns = @(Split-DomeniaDn $value) }
    $wellFormed = ($rdns.Count -ge 2)
    foreach ($rdn in $rdns) { if ($rdn -notmatch '^(?i)(CN|OU|DC)=\S') { $wellFormed = $false } }
    if ($wellFormed) {
        return [pscustomobject]@{Kind='DN';Value=$value;Filter='(distinguishedName=' + (ConvertTo-DomeniaLdapLiteral $value) + ')';Explanation='Nom distingué reconnu : recherche exacte de cet objet.';Ambiguous=$false;AutoOpen=$false}
    }
    if ($value -match '^[^\\/\s@]+\\[^\\/\s@]+$') {
        $account = ($value -split '\\')[1]
        return [pscustomobject]@{Kind='DownLevel';Value=$value;Filter='(sAMAccountName=' + (ConvertTo-DomeniaLdapLiteral $account) + ')';Explanation='Nom DOMAINE\compte reconnu : lʼidentifiant est cherché dans le domaine connecté, avec les autres correspondances.';Ambiguous=$true;AutoOpen=$false}
    }
    if ($value -match '^[^@\s]+@[^@\s]+\.[^@\s.]+$') {
        $literal = ConvertTo-DomeniaLdapLiteral $value
        return [pscustomobject]@{Kind='Upn';Value=$value;Filter='(|(userPrincipalName=' + $literal + ')(mail=' + $literal + '))';Explanation='Adresse reconnue : nom de connexion et messagerie cherchés, avec les autres correspondances.';Ambiguous=$true;AutoOpen=$false}
    }
    if ($value -match '^(?i)[a-z0-9]([a-z0-9-]{0,62})(\.[a-z0-9]([a-z0-9-]{0,62})){2,}$') {
        $literal = ConvertTo-DomeniaLdapLiteral $value
        return [pscustomobject]@{Kind='Fqdn';Value=$value;Filter='(dNSHostName=' + $literal + ')';Explanation='Nom DNS complet reconnu : le poste est cherché avec les autres correspondances (un identifiant à points peut aussi être un compte).';Ambiguous=$true;AutoOpen=$false}
    }
    return $none
}

# ---------------------------------------------------------------- D037 explicit continuation
function Get-DomeniaResultCounterText {
    # States plainly whether the list is complete, limited or still loading.
    # At the safety maximum the next step is to refine: no further page is offered.
    param([int]$Loaded=0,[int]$Limit=100,[bool]$Complete=$false,[bool]$Loading=$false,[int]$Visible=-1,[int]$Maximum=20000)
    $text = [string]$Loaded + ' chargé(s)'
    if ($Loading) { $text += ' · lecture en cours' }
    elseif ($Complete) { $text = [string]$Loaded + ' résultat(s) · liste complète' }
    elseif ($Limit -ge $Maximum) { $text += ' · liste limitée à ' + $Limit + ' : affinez la recherche' }
    else { $text += ' · liste limitée à ' + $Limit + ' : affinez ou chargez la suite' }
    if ($Visible -ge 0 -and $Visible -ne $Loaded) { $text += ' · ' + $Visible + ' visible(s) après filtre local' }
    return $text
}

function Get-DomeniaContinuationDecision {
    # 'Charger la suite' is offered only for a finished, complete-but-limited list below the safety maximum.
    # The next load relaunches the same query with a larger bound: rows are deduplicated by identity and an
    # older generation is discarded by the caller.
    param([bool]$Finalized=$false,[bool]$HasError=$false,[bool]$LimitReached=$false,[int]$Limit=100,[int]$Maximum=20000)
    if (-not $Finalized) { return [pscustomobject]@{Allowed=$false;NextLimit=$Limit;Reason='Lecture en cours : attendez la fin du chargement.'} }
    if ($HasError) { return [pscustomobject]@{Allowed=$false;NextLimit=$Limit;Reason='Liste partielle après une erreur : relancez la recherche.'} }
    if (-not $LimitReached) { return [pscustomobject]@{Allowed=$false;NextLimit=$Limit;Reason='Liste complète : aucune suite à charger.'} }
    if ($Limit -ge $Maximum) { return [pscustomobject]@{Allowed=$false;NextLimit=$Limit;Reason=('Limite de sécurité de ' + $Maximum + ' lignes atteinte : affinez la recherche.')} }
    $next = [Math]::Max($Limit + 1,[Math]::Min($Maximum,$Limit * 2))
    return [pscustomobject]@{Allowed=$true;NextLimit=$next;Reason=('Relit la même recherche jusquʼà ' + $next + ' lignes, sans doublon.')}
}

function New-DomeniaContinuation {
    # Keyset continuation on the name attribute: the next page starts at the last name already loaded.
    param([Parameter(Mandatory=$true)][string]$BaseFilter,[AllowEmptyString()][string]$LastName='',[int]$PageSize=100,[string]$Reader='',[long]$Generation=0,[string]$BaseDn='')
    $filter = $BaseFilter
    if ($LastName) { $filter = '(&' + $BaseFilter + '(name>=' + (ConvertTo-DomeniaLdapLiteral $LastName) + '))' }
    return [pscustomobject]@{Filter=$filter;SortAttribute='name';PageSize=[Math]::Max(10,[Math]::Min(1000,$PageSize));Reader=$Reader;Generation=$Generation;BaseDn=$BaseDn;AfterName=$LastName}
}

function Test-DomeniaContinuationCurrent {
    # A page built for another account, another search or another perimeter is discarded.
    param($Continuation,[string]$Reader='',[long]$Generation=0,[string]$BaseDn='')
    if ($null -eq $Continuation) { return $false }
    return (([string]$Continuation.Reader) -ceq $Reader -and [long]$Continuation.Generation -eq $Generation -and ([string]$Continuation.BaseDn) -ieq $BaseDn)
}

# ---------------------------------------------------------------- D038 work views
function ConvertTo-DomeniaLdapTime {
    param([datetime]$Utc)
    return $Utc.ToUniversalTime().ToString('yyyyMMddHHmmss') + '.0Z'
}

function Get-DomeniaWorkViews {
    # Ready-made read-only views. Each one is a filter and a type: no account, no right and no write mode.
    # UX-33: every view applies to the OU chosen in the tree (NeedsOu); the whole domain is a secondary,
    # explicit choice decided by Get-DomeniaWorkViewPlan.
    param([datetime]$NowUtc=[datetime]::UtcNow)
    $in30 = $NowUtc.AddDays(30).ToFileTimeUtc(); $now = $NowUtc.ToFileTimeUtc()
    $inactive = $NowUtc.AddDays(-90).ToFileTimeUtc()
    return @(
        [pscustomobject]@{Id='expiring';Name='Comptes expirant sous 30 jours';Type='Utilisateur';NeedsOu=$true;Filter=('(&(objectCategory=person)(objectClass=user)(accountExpires>=' + $now + ')(accountExpires<=' + $in30 + '))');Note='Date d expiration du compte, pas du mot de passe.'}
        [pscustomobject]@{Id='disabled';Name='Comptes desactives';Type='Utilisateur';NeedsOu=$true;Filter='(&(objectCategory=person)(objectClass=user)(userAccountControl:1.2.840.113556.1.4.803:=2))';Note=''}
        [pscustomobject]@{Id='recent';Name='Objets modifies depuis 7 jours';Type='';NeedsOu=$true;Filter=('(whenChanged>=' + (ConvertTo-DomeniaLdapTime $NowUtc.AddDays(-7)) + ')');Note='whenChanged est propre a chaque controleur.'}
        [pscustomobject]@{Id='oucomputers';Name='Postes de cette OU';Type='Machine';NeedsOu=$true;Filter='(objectCategory=computer)';Note='Perimetre : OU selectionnee.'}
        # CO-20: a workstation that never logged on has no lastLogonTimestamp: it is listed too (shown 'Jamais').
        [pscustomobject]@{Id='stalecomputers';Name='Postes sans connexion depuis 90 jours';Type='Machine';NeedsOu=$true;Filter=('(&(objectCategory=computer)(|(lastLogonTimestamp<=' + $inactive + ')(!(lastLogonTimestamp=*))))');Note='Postes jamais connectés inclus. lastLogonTimestamp est approximatif (retard de réplication jusquʼà 14 jours). Aucun objet nʼest déclaré supprimable.'}
    )
}

function Get-DomeniaWorkViewPlan {
    # UX-33: a work view applies to the OU chosen in the tree ('Dans : Postes'). The whole domain is only a
    # secondary, explicit choice, and a whole-domain list never offers a survey of its workstations (ping,
    # detection or analysis): that would be a scan of the whole park.
    param($View,[ValidateSet('OU','Domain')][string]$Choice='OU',[AllowEmptyString()][string]$OuDn='',[AllowEmptyString()][string]$DomainDn='',[bool]$Subtree=$true,[AllowEmptyString()][string]$OuName='')
    if ($null -eq $View) { return $null }
    $survey = 'Vue sur tout le domaine : aucun relevé des postes (ping, détection, analyse) nʼest proposé sur cette liste.'
    if ($Choice -eq 'Domain') {
        return [pscustomobject]@{SearchMode='Global';BaseDn=$DomainDn;WholeDomain=$true;SurveyAllowed=$false;ChipText='Dans : tout le domaine';Reason=$survey}
    }
    $base = $OuDn
    if (-not $base) { $base = $DomainDn }
    $isDomain = ([bool]$DomainDn -and $base -ieq $DomainDn)
    $whole = ($isDomain -and $Subtree)
    $name = $OuName
    if ($isDomain) { $name = 'tout le domaine' } elseif (-not $name) { $name = 'OU choisie' }
    return [pscustomobject]@{SearchMode='OU';BaseDn=$base;WholeDomain=$whole;SurveyAllowed=(-not $whole);ChipText=('Dans : ' + $name);Reason=$(if ($whole) { $survey } else { '' })}
}

function ConvertTo-DomeniaSavedView {
    # Whitelist: a saved view never carries a credential, a privileged account or a write permission.
    param($View)
    if ($null -eq $View) { return $null }
    $limit = 100
    [void][int]::TryParse([string](Get-DomeniaMember $View 'Limit' 100),[ref]$limit)
    return [pscustomobject]@{
        Name=(ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $View 'Name' '')) 80)
        Text=(ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $View 'Text' '')) 256)
        Type=[string](Get-DomeniaMember $View 'Type' '')
        OuDn=[string](Get-DomeniaMember $View 'OuDn' '')
        Subtree=[bool](Get-DomeniaMember $View 'Subtree' $true)
        Limit=[Math]::Max(1,[Math]::Min(20000,$limit))
        ViewId=[string](Get-DomeniaMember $View 'ViewId' '')
    }
}

# ---------------------------------------------------------------- D039 readable OU paths
function Split-DomeniaDn {
    # Splits a DN into RDNs on commas that are not escaped and not quoted. A backslash escapes exactly
    # one character, so 'OU=Back\\,OU=Sites' ends the first RDN after the escaped backslash. Hex pairs
    # ('\C3\89') never contain a comma and are kept for ConvertFrom-DomeniaDnValue.
    param([AllowEmptyString()][AllowNull()][string]$Dn)
    $text = [string]$Dn
    $parts = [Collections.Generic.List[string]]::new()
    $start = 0; $escaped = $false; $quoted = $false
    for ($i = 0; $i -lt $text.Length; $i++) {
        $c = $text[$i]
        if ($escaped) { $escaped = $false; continue }
        if ($c -eq [char]92) { $escaped = $true; continue }
        if ($c -eq [char]34) { $quoted = -not $quoted; continue }
        if ($c -eq [char]44 -and -not $quoted) { $parts.Add($text.Substring($start,$i - $start).Trim()); $start = $i + 1 }
    }
    if ($start -lt $text.Length) { $parts.Add($text.Substring($start).Trim()) }
    return @($parts.ToArray() | Where-Object { $_ })
}

function ConvertFrom-DomeniaDnValue {
    # Display value of one RDN: UTF-8 hex pairs and escaped characters decoded in a single pass.
    param([AllowEmptyString()][AllowNull()][string]$Value)
    $text = [string]$Value
    if ($text.Length -ge 2 -and $text[0] -eq [char]34 -and $text[$text.Length - 1] -eq [char]34) { $text = $text.Substring(1,$text.Length - 2) }
    $hex = '0123456789abcdefABCDEF'
    $out = [Text.StringBuilder]::new()
    $bytes = [Collections.Generic.List[byte]]::new()
    $i = 0
    while ($i -lt $text.Length) {
        $c = $text[$i]
        if ($c -eq [char]92 -and ($i + 1) -lt $text.Length) {
            if (($i + 2) -lt $text.Length -and $hex.IndexOf($text[$i + 1]) -ge 0 -and $hex.IndexOf($text[$i + 2]) -ge 0) {
                $bytes.Add([Convert]::ToByte($text.Substring($i + 1,2),16)); $i += 3; continue
            }
            if ($bytes.Count) { [void]$out.Append([Text.Encoding]::UTF8.GetString($bytes.ToArray())); $bytes.Clear() }
            [void]$out.Append($text[$i + 1]); $i += 2; continue
        }
        if ($bytes.Count) { [void]$out.Append([Text.Encoding]::UTF8.GetString($bytes.ToArray())); $bytes.Clear() }
        [void]$out.Append($c); $i++
    }
    if ($bytes.Count) { [void]$out.Append([Text.Encoding]::UTF8.GetString($bytes.ToArray())) }
    return $out.ToString()
}

function Get-DomeniaDnParent {
    # Parent DN: everything after the first unescaped, unquoted comma. '' for a single RDN.
    param([AllowEmptyString()][AllowNull()][string]$Dn)
    $text = [string]$Dn
    $escaped = $false; $quoted = $false
    for ($i = 0; $i -lt $text.Length; $i++) {
        $c = $text[$i]
        if ($escaped) { $escaped = $false; continue }
        if ($c -eq [char]92) { $escaped = $true; continue }
        if ($c -eq [char]34) { $quoted = -not $quoted; continue }
        if ($c -eq [char]44 -and -not $quoted) { return $text.Substring($i + 1).Trim() }
    }
    return ''
}

function Get-DomeniaOuDisplayPath {
    # Readable path 'domaine / OU / sous-OU', same separator as the OU explorer. The exact DN stays the search root.
    param([AllowEmptyString()][string]$Dn)
    $parts = @(Split-DomeniaDn $Dn)
    if (-not $parts.Count) { return '' }
    $domain = [Collections.Generic.List[string]]::new()
    $path = [Collections.Generic.List[string]]::new()
    foreach ($part in $parts) {
        $equals = $part.IndexOf('=')
        if ($equals -lt 1) { continue }
        $kind = $part.Substring(0,$equals).Trim(); $value = ConvertFrom-DomeniaDnValue ($part.Substring($equals + 1))
        if ($kind -ieq 'DC') { $domain.Add($value) } else { $path.Insert(0,$value) }
    }
    $items = [Collections.Generic.List[string]]::new()
    if ($domain.Count) { $items.Add(($domain.ToArray() -join '.')) }
    foreach ($item in $path) { if ($item) { $items.Add($item) } }
    return ($items.ToArray() -join ' / ')
}

function Resolve-DomeniaOuRestore {
    # A saved OU that no longer exists is never replaced silently by the whole domain.
    param([AllowEmptyString()][string]$SavedDn,[bool]$Exists,[AllowEmptyString()][string]$MovedToDn='',[bool]$ReadFailed=$false)
    if (-not $SavedDn) { return [pscustomobject]@{Action='None';TargetDn='';Message='';RequiresChoice=$false} }
    if ($ReadFailed) { return [pscustomobject]@{Action='AskRetry';TargetDn='';Message='LʼOU mémorisée nʼa pas pu être relue dans le délai : aucune absence nʼest déduite. Relancez la lecture ou choisissez une OU ; aucun autre périmètre nʼest appliqué.';RequiresChoice=$true} }
    if ($Exists) { return [pscustomobject]@{Action='Restore';TargetDn=$SavedDn;Message='';RequiresChoice=$false} }
    if ($MovedToDn) { return [pscustomobject]@{Action='AskMoved';TargetDn=$MovedToDn;Message=('LʼOU mémorisée a été déplacée vers ' + (Get-DomeniaOuDisplayPath $MovedToDn) + '. Confirmez ce nouveau périmètre ou choisissez-en un autre.');RequiresChoice=$true} }
    return [pscustomobject]@{Action='AskMissing';TargetDn='';Message=('LʼOU mémorisée (' + (Get-DomeniaOuDisplayPath $SavedDn) + ') nʼapparaît plus sous son parent relu. Aucun périmètre nʼest appliqué : choisissez une OU ou relancez la lecture.');RequiresChoice=$true}
}

# ---------------------------------------------------------------- D040 back / forward
function New-DomeniaNavHistory {
    param([ValidateRange(2,200)][int]$Capacity=40)
    return [pscustomobject]@{Capacity=$Capacity;Back=([Collections.ArrayList]::new());Forward=([Collections.ArrayList]::new());Current=$null}
}

function Get-DomeniaNavStateKey {
    param($State)
    if ($null -eq $State) { return '' }
    return (@('Page','Tab','Mode','Text','OuDn','SelectionGuid') | ForEach-Object { [string](Get-DomeniaMember $State $_ '') }) -join '|'
}

function Push-DomeniaNavState {
    # Records where the operator is. Repeating the same place does not add an entry.
    param($History,$State)
    if ($null -eq $History -or $null -eq $State) { return $false }
    if ($null -ne $History.Current -and (Get-DomeniaNavStateKey $History.Current) -ceq (Get-DomeniaNavStateKey $State)) { $History.Current = $State; return $false }
    if ($null -ne $History.Current) {
        [void]$History.Back.Add($History.Current)
        while ($History.Back.Count -gt $History.Capacity) { $History.Back.RemoveAt(0) }
    }
    $History.Forward.Clear()
    $History.Current = $State
    return $true
}

function Step-DomeniaNavHistory {
    # Going back restores the stored view (rows, scroll, selection, tab). It never starts a machine sweep
    # and never discards a draft: with an unsaved draft the step is refused until the operator decides.
    param($History,[Parameter(Mandatory=$true)][ValidateSet('Back','Forward')][string]$Direction,[bool]$HasDraft=$false,[bool]$DraftDecisionTaken=$false)
    if ($null -eq $History) { return [pscustomobject]@{Moved=$false;State=$null;Blocked=$false;Reason='';RestoreWithoutScan=$true} }
    $source = $History.Back; $target = $History.Forward
    if ($Direction -eq 'Forward') { $source = $History.Forward; $target = $History.Back }
    if ($source.Count -eq 0) { return [pscustomobject]@{Moved=$false;State=$History.Current;Blocked=$false;Reason='Aucune etape dans ce sens.';RestoreWithoutScan=$true} }
    if ($HasDraft -and -not $DraftDecisionTaken) { return [pscustomobject]@{Moved=$false;State=$History.Current;Blocked=$true;Reason='Une saisie non enregistree est en cours : choisissez de la conserver ou de l abandonner avant de naviguer.';RestoreWithoutScan=$true} }
    $state = $source[$source.Count - 1]
    $source.RemoveAt($source.Count - 1)
    if ($null -ne $History.Current) { [void]$target.Add($History.Current) }
    $History.Current = $state
    return [pscustomobject]@{Moved=$true;State=$state;Blocked=$false;Reason='';RestoreWithoutScan=$true}
}

# ---------------------------------------------------------------- L03 OU tree, keyboard pacing, OU favourites
function Get-DomeniaSystemContainerNames {
    # UI-16: well-known containers created by Active Directory under the domain root. Users and Computers are not
    # in this list: they stay visible in the tree.
    return @('System','Program Data','ForeignSecurityPrincipals','LostAndFound','Infrastructure','NTDS Quotas','TPM Devices','Keys','Managed Service Accounts','Builtin')
}

function Test-DomeniaSystemContainer {
    # UI-16: true for a well-known system container placed directly under the domain root. An OU never is.
    param([AllowEmptyString()][AllowNull()][string]$Dn,[AllowEmptyString()][AllowNull()][string]$DomainDn,[AllowEmptyString()][AllowNull()][string]$Kind='')
    if (-not $Dn -or -not $DomainDn -or $Kind -eq 'OU') { return $false }
    if ((Get-DomeniaDnParent $Dn) -ine $DomainDn) { return $false }
    $parts = @(Split-DomeniaDn $Dn)
    if ($parts.Count -lt 1) { return $false }
    $first = [string]$parts[0]
    $equals = $first.IndexOf('=')
    if ($equals -lt 1 -or $first.Substring(0,$equals).Trim() -ine 'CN') { return $false }
    $name = ConvertFrom-DomeniaDnValue ($first.Substring($equals + 1))
    return (@(Get-DomeniaSystemContainerNames) -contains $name)
}

function Split-DomeniaTreeRows {
    # UI-16: the children of the domain root are split between the visible branches and the system containers
    # folded under 'Conteneurs système'. Any other parent keeps all its children visible, in the same order.
    param($Rows,[AllowEmptyString()][string]$ParentDn='',[AllowEmptyString()][string]$DomainDn='')
    $visible = [Collections.Generic.List[object]]::new()
    $system = [Collections.Generic.List[object]]::new()
    $isRoot = ([bool]$ParentDn -and [bool]$DomainDn -and $ParentDn -ieq $DomainDn)
    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }
        $dn = [string](Get-DomeniaMember $row 'DN' '')
        $kind = [string](Get-DomeniaMember $row 'Kind' '')
        if ($isRoot -and (Test-DomeniaSystemContainer $dn $DomainDn $kind)) { $system.Add($row) } else { $visible.Add($row) }
    }
    return [pscustomobject]@{Visible=$visible.ToArray();System=$system.ToArray()}
}

function Get-DomeniaTreeSelectionDelay {
    # PF-14: walking the tree with the keyboard, or changing the object type, waits 300 ms and only the last
    # stop is read; a mouse click is read at once. Milliseconds.
    param([AllowEmptyString()][string]$Source='Mouse')
    if ($Source -in @('Keyboard','Type')) { return 300 }
    return 0
}

function Test-DomeniaOuTreeMatch {
    # DS-07: local filter of the OU tree. Literal, case and accent insensitive, on the branch name only.
    # It never reads the directory.
    param([AllowEmptyString()][AllowNull()][string]$Name,[AllowEmptyString()][AllowNull()][string]$Filter)
    $needle = ([string]$Filter).Trim()
    if (-not $needle) { return $true }
    $compare = [Globalization.CultureInfo]::InvariantCulture.CompareInfo
    $options = [Globalization.CompareOptions]::IgnoreCase -bor [Globalization.CompareOptions]::IgnoreNonSpace
    return ($compare.IndexOf([string]$Name,$needle,$options) -ge 0)
}

function ConvertTo-DomeniaOuFavourite {
    # FO-04: an OU favourite keeps a perimeter only: the DN, a short name, the depth, the object type and an
    # optional term for the visible local filter (CO-21). Never a result, an account, a right or a write mode.
    # With a domain, a DN outside that domain is refused.
    param($Value,[AllowEmptyString()][string]$DomainDn='')
    if ($null -eq $Value) { return $null }
    $dn = ([string](Get-DomeniaMember $Value 'DN' '')).Trim()
    if (-not $dn -or $dn.Length -gt 4096) { return $null }
    $parts = @(Split-DomeniaDn $dn)
    if (@($parts | Where-Object { $_ -match '^(?i)DC=' }).Count -lt 1) { return $null }
    if ($DomainDn -and $dn -ine $DomainDn -and -not $dn.EndsWith(',' + $DomainDn,[StringComparison]::OrdinalIgnoreCase)) { return $null }
    $name = ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $Value 'Name' '')) 80
    if (-not $name) {
        $equals = ([string]$parts[0]).IndexOf('=')
        if ($equals -gt 0) { $name = ConvertTo-DomeniaFlatText (ConvertFrom-DomeniaDnValue (([string]$parts[0]).Substring($equals + 1))) 80 }
    }
    if (-not $name) { return $null }
    $type = [string](Get-DomeniaMember $Value 'Type' 'Tous')
    if ($type -notin @('Tous','Utilisateurs','Machines','Groupes','OU et conteneurs')) { $type = 'Tous' }
    $subtreeValue = Get-DomeniaMember $Value 'Subtree' $true
    $subtree = $true
    if ($subtreeValue -is [bool]) { $subtree = $subtreeValue }
    elseif ($null -ne $subtreeValue -and ([string]$subtreeValue).Trim() -in @('False','0')) { $subtree = $false }
    $term = ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $Value 'Term' '')) 120
    return [pscustomobject]@{DN=$dn;Name=$name;Subtree=$subtree;Type=$type;Term=$term}
}

function Get-DomeniaDnDomainKey {
    # FO-04: the domain of a DN (its DC= components, lower case), so that the favourites are counted per domain.
    param([AllowEmptyString()][AllowNull()][string]$Dn)
    $parts = @(Split-DomeniaDn ([string]$Dn) | Where-Object { ([string]$_).Trim() -match '^(?i)DC=' } | ForEach-Object { ([string]$_).Trim() })
    return (($parts -join ',').ToLowerInvariant())
}

function Import-DomeniaOuFavourites {
    # FO-04: one-time takeover of the former saved searches, which stay stored untouched. Only an OU search
    # becomes a favourite (its text goes to the visible local filter); a whole-domain text search has no OU
    # to pin. The existing favourite wins on the same DN; at most $Maximum favourites per domain, since only the
    # favourites of the session domain are shown.
    param($Existing,$SavedSearches,[int]$Maximum=50)
    $out = [Collections.Generic.List[object]]::new()
    $seen = @{}
    $perDomain = @{}
    foreach ($item in @($Existing)) {
        $fav = ConvertTo-DomeniaOuFavourite $item
        if ($null -eq $fav -or $seen.ContainsKey($fav.DN.ToLowerInvariant())) { continue }
        $domain = Get-DomeniaDnDomainKey $fav.DN
        if ([int]$perDomain[$domain] -ge $Maximum) { continue }
        $seen[$fav.DN.ToLowerInvariant()] = $true; $perDomain[$domain] = [int]$perDomain[$domain] + 1; $out.Add($fav)
    }
    $imported = 0
    foreach ($saved in @($SavedSearches)) {
        if ($null -eq $saved) { continue }
        if ([string](Get-DomeniaMember $saved 'SearchMode' 'OU') -eq 'Global') { continue }
        $candidate = [pscustomobject]@{DN=[string](Get-DomeniaMember $saved 'DN' '');Name=[string](Get-DomeniaMember $saved 'Name' '');Subtree=(Get-DomeniaMember $saved 'Subtree' $true);Type=[string](Get-DomeniaMember $saved 'Type' 'Tous');Term=[string](Get-DomeniaMember $saved 'Query' '')}
        $fav = ConvertTo-DomeniaOuFavourite $candidate
        if ($null -eq $fav -or $seen.ContainsKey($fav.DN.ToLowerInvariant())) { continue }
        $domain = Get-DomeniaDnDomainKey $fav.DN
        if ([int]$perDomain[$domain] -ge $Maximum) { continue }
        $seen[$fav.DN.ToLowerInvariant()] = $true; $perDomain[$domain] = [int]$perDomain[$domain] + 1; $out.Add($fav); $imported++
    }
    return [pscustomobject]@{Favourites=$out.ToArray();Imported=$imported}
}

function Set-DomeniaOuFavouriteState {
    # FO-04: pins or unpins one OU. Unpinning only forgets the favourite: nothing is changed in the directory.
    # $Maximum counts the favourites of the domain of that OU only: the other domains are not shown in the session.
    param($Favourites,$Favourite,[bool]$Pinned=$true,[AllowEmptyString()][string]$DomainDn='',[int]$Maximum=50)
    $fav = ConvertTo-DomeniaOuFavourite $Favourite $DomainDn
    $list = [Collections.Generic.List[object]]::new()
    foreach ($item in @($Favourites)) { $valid = ConvertTo-DomeniaOuFavourite $item; if ($null -ne $valid) { $list.Add($valid) } }
    if ($null -eq $fav) { return [pscustomobject]@{Favourites=$list.ToArray();Changed=$false;Reason='OU invalide ou hors du domaine de cette session.'} }
    $index = -1
    for ($i = 0; $i -lt $list.Count; $i++) { if ([string]$list[$i].DN -ieq $fav.DN) { $index = $i; break } }
    if ($Pinned) {
        if ($index -ge 0) { return [pscustomobject]@{Favourites=$list.ToArray();Changed=$false;Reason='Cette OU est déjà dans les favoris.'} }
        $domain = Get-DomeniaDnDomainKey $fav.DN
        if (@($list | Where-Object { (Get-DomeniaDnDomainKey $_.DN) -ceq $domain }).Count -ge $Maximum) { return [pscustomobject]@{Favourites=$list.ToArray();Changed=$false;Reason=([string]$Maximum + ' favoris au maximum : retirez un favori avant dʼen ajouter un.')} }
        $list.Add($fav)
        return [pscustomobject]@{Favourites=$list.ToArray();Changed=$true;Reason=''}
    }
    if ($index -lt 0) { return [pscustomobject]@{Favourites=$list.ToArray();Changed=$false;Reason='Cette OU nʼest pas dans les favoris.'} }
    $list.RemoveAt($index)
    return [pscustomobject]@{Favourites=$list.ToArray();Changed=$true;Reason=''}
}
