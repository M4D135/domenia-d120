# Search and navigation rules: global search contract, search/browse separation, optional syntax,
# ranking, LDAP literals, pasted identifiers, explicit continuation, work views, OU paths, history.
# Pure text and data decisions: no LDAP query is sent from this module.

# ---------------------------------------------------------------- D035 LDAP literals
function ConvertTo-DomeniaLdapLiteral {
    # RFC 4515 escaping. With -KeepWildcard an asterisk typed by the operator stays a wildcard.
    param([AllowEmptyString()][AllowNull()][string]$Value,[switch]$KeepWildcard)
    $builder = New-Object Text.StringBuilder
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
    $tokens = New-Object 'System.Collections.Generic.List[object]'
    $notes = New-Object 'System.Collections.Generic.List[string]'
    $free = New-Object 'System.Collections.Generic.List[string]'
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
    $blocks = New-Object 'System.Collections.Generic.List[string]'
    $tokenTypes = New-Object 'System.Collections.Generic.List[string]'
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
    param([AllowEmptyString()][string]$Text,[Parameter(Mandatory=$true)][string]$DomainDn,[int]$Limit=100,[string]$Reader='',[long]$Generation=0)
    $syntax = ConvertFrom-DomeniaSearchSyntax $Text
    $identifier = Get-DomeniaPastedIdentifier $Text
    $filter = $null
    if ($identifier.Kind -ne 'None') { $filter = [pscustomobject]@{Filter=$identifier.Filter;Valid=$true;Reason='';Costly=$false} }
    else { $filter = ConvertTo-DomeniaSearchFilter -Text $syntax.FreeText -Type $syntax.Type -Tokens $syntax.Tokens }
    return [pscustomobject]@{
        Mode='Global';BaseDn=$DomainDn;Scope='Subtree';PresenceFilter='';LocalFilter='';OuDn=''
        Text=([string]$Text).Trim();Limit=[Math]::Max(1,[Math]::Min(1000,$Limit))
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
    if ($Subtree) { return ('Dans cette OU : ' + $name + ' · sous-OU incluses') }
    return ('Dans cette OU : ' + $name + ' · enfants directs')
}

# ---------------------------------------------------------------- D034 ranking
function Get-DomeniaSearchRank {
    # Lower is better: exact identifier, exact name, identifier prefix, name prefix, word prefix, the rest.
    param($Row,[AllowEmptyString()][string]$Query)
    $q = ([string]$Query).Trim().TrimEnd('*')
    if (-not $q) { return 9 }
    $login = [string](Get-DomeniaMember $Row 'Login' ''); $upn = [string](Get-DomeniaMember $Row 'UPN' '')
    $name = [string](Get-DomeniaMember $Row 'Name' ''); $display = [string](Get-DomeniaMember $Row 'Display' ''); $mail = [string](Get-DomeniaMember $Row 'Mail' '')
    $ordinal = [StringComparison]::OrdinalIgnoreCase
    if ($login.Equals($q,$ordinal) -or $upn.Equals($q,$ordinal) -or $mail.Equals($q,$ordinal) -or ($upn -and ($upn -split '@')[0].Equals($q,$ordinal))) { return 0 }
    if ($name.Equals($q,$ordinal) -or $display.Equals($q,$ordinal)) { return 1 }
    if ($login.StartsWith($q,$ordinal) -or $upn.StartsWith($q,$ordinal)) { return 2 }
    if ($name.StartsWith($q,$ordinal) -or $display.StartsWith($q,$ordinal)) { return 3 }
    foreach ($word in @(($name + ' ' + $display) -split '[\s\-]+' | Where-Object { $_ })) { if ($word.StartsWith($q,$ordinal)) { return 4 } }
    if ($login.IndexOf($q,$ordinal) -ge 0 -or $name.IndexOf($q,$ordinal) -ge 0 -or $display.IndexOf($q,$ordinal) -ge 0 -or $upn.IndexOf($q,$ordinal) -ge 0) { return 5 }
    return 6
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
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $ranked = New-Object 'System.Collections.Generic.List[object]'
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
    if ($value -match '^(?i)(CN|OU|DC)=[^,]+(,\s*(CN|OU|DC)=[^,]+)+$') {
        return [pscustomobject]@{Kind='DN';Value=$value;Filter='(distinguishedName=' + (ConvertTo-DomeniaLdapLiteral $value) + ')';Explanation='Nom distingue reconnu : recherche exacte de cet objet.';Ambiguous=$false;AutoOpen=$false}
    }
    if ($value -match '^[^\\/\s@]+\\[^\\/\s@]+$') {
        $account = ($value -split '\\')[1]
        return [pscustomobject]@{Kind='DownLevel';Value=$value;Filter='(sAMAccountName=' + (ConvertTo-DomeniaLdapLiteral $account) + ')';Explanation='Nom DOMAINE\compte reconnu : recherche exacte de l identifiant dans le domaine connecte.';Ambiguous=$true;AutoOpen=$false}
    }
    if ($value -match '^[^@\s]+@[^@\s]+\.[^@\s.]+$') {
        $literal = ConvertTo-DomeniaLdapLiteral $value
        return [pscustomobject]@{Kind='Upn';Value=$value;Filter='(|(userPrincipalName=' + $literal + ')(mail=' + $literal + '))';Explanation='Adresse reconnue : recherche exacte du nom de connexion ou de la messagerie.';Ambiguous=$true;AutoOpen=$false}
    }
    if ($value -match '^(?i)[a-z0-9]([a-z0-9-]{0,62})(\.[a-z0-9]([a-z0-9-]{0,62})){2,}$') {
        $literal = ConvertTo-DomeniaLdapLiteral $value
        return [pscustomobject]@{Kind='Fqdn';Value=$value;Filter='(dNSHostName=' + $literal + ')';Explanation='Nom DNS complet reconnu : recherche exacte du poste.';Ambiguous=$false;AutoOpen=$false}
    }
    return $none
}

# ---------------------------------------------------------------- D037 explicit continuation
function Get-DomeniaResultCounterText {
    # States plainly whether the list is complete, limited or still loading.
    param([int]$Loaded=0,[int]$Limit=100,[bool]$Complete=$false,[bool]$Loading=$false,[int]$Visible=-1)
    $text = [string]$Loaded + ' charge(s)'
    if ($Loading) { $text += ' · lecture en cours' }
    elseif ($Complete) { $text = [string]$Loaded + ' resultat(s) · liste complete' }
    else { $text += ' · liste limitee a ' + $Limit + ' : affinez ou chargez la suite' }
    if ($Visible -ge 0 -and $Visible -ne $Loaded) { $text += ' · ' + $Visible + ' visible(s) apres filtre local' }
    return $text
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
    param([datetime]$NowUtc=[datetime]::UtcNow)
    $in30 = $NowUtc.AddDays(30).ToFileTimeUtc(); $now = $NowUtc.ToFileTimeUtc()
    $inactive = $NowUtc.AddDays(-90).ToFileTimeUtc()
    return @(
        [pscustomobject]@{Id='expiring';Name='Comptes expirant sous 30 jours';Type='Utilisateur';NeedsOu=$false;Filter=('(&(objectCategory=person)(objectClass=user)(accountExpires>=' + $now + ')(accountExpires<=' + $in30 + '))');Note='Date d expiration du compte, pas du mot de passe.'}
        [pscustomobject]@{Id='disabled';Name='Comptes desactives';Type='Utilisateur';NeedsOu=$false;Filter='(&(objectCategory=person)(objectClass=user)(userAccountControl:1.2.840.113556.1.4.803:=2))';Note=''}
        [pscustomobject]@{Id='recent';Name='Objets modifies depuis 7 jours';Type='';NeedsOu=$false;Filter=('(whenChanged>=' + (ConvertTo-DomeniaLdapTime $NowUtc.AddDays(-7)) + ')');Note='whenChanged est propre a chaque controleur.'}
        [pscustomobject]@{Id='oucomputers';Name='Postes de cette OU';Type='Machine';NeedsOu=$true;Filter='(objectCategory=computer)';Note='Perimetre : OU selectionnee.'}
        [pscustomobject]@{Id='stalecomputers';Name='Postes sans connexion depuis 90 jours';Type='Machine';NeedsOu=$false;Filter=('(&(objectCategory=computer)(lastLogonTimestamp<=' + $inactive + '))');Note='lastLogonTimestamp est approximatif (retard de replication jusqu a 14 jours). Aucun objet n est declare supprimable.'}
    )
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
        Limit=[Math]::Max(1,[Math]::Min(1000,$limit))
        ViewId=[string](Get-DomeniaMember $View 'ViewId' '')
    }
}

# ---------------------------------------------------------------- D039 readable OU paths
function Split-DomeniaDn {
    # Splits on commas that are not escaped with a backslash.
    param([AllowEmptyString()][string]$Dn)
    return @([regex]::Split([string]$Dn,'(?<!\\),') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-DomeniaOuDisplayPath {
    param([AllowEmptyString()][string]$Dn)
    $parts = @(Split-DomeniaDn $Dn)
    if (-not $parts.Count) { return '' }
    $domain = @($parts | Where-Object { $_ -match '^(?i)DC=' } | ForEach-Object { $_.Substring(3) }) -join '.'
    $path = @($parts | Where-Object { $_ -notmatch '^(?i)DC=' } | ForEach-Object { ($_ -replace '^(?i)(OU|CN)=','') -replace '\\(.)','$1' })
    [array]::Reverse($path)
    $separator = ' ' + [string][char]0x203A + ' '
    return (@($domain) + $path | Where-Object { $_ }) -join $separator
}

function Resolve-DomeniaOuRestore {
    # A saved OU that no longer exists is never replaced silently by the whole domain.
    param([AllowEmptyString()][string]$SavedDn,[bool]$Exists,[AllowEmptyString()][string]$MovedToDn='',[bool]$ReadFailed=$false)
    if (-not $SavedDn) { return [pscustomobject]@{Action='None';TargetDn='';Message='';RequiresChoice=$false} }
    if ($ReadFailed) { return [pscustomobject]@{Action='AskRetry';TargetDn='';Message='Le perimetre memorise n a pas pu etre relu. Choisissez une OU ou relancez la lecture.';RequiresChoice=$true} }
    if ($Exists) { return [pscustomobject]@{Action='Restore';TargetDn=$SavedDn;Message='';RequiresChoice=$false} }
    if ($MovedToDn) { return [pscustomobject]@{Action='AskMoved';TargetDn=$MovedToDn;Message=('L OU memorisee a ete deplacee vers ' + (Get-DomeniaOuDisplayPath $MovedToDn) + '. Confirmez ce nouveau perimetre ou choisissez-en un autre.');RequiresChoice=$true} }
    return [pscustomobject]@{Action='AskMissing';TargetDn='';Message=('L OU memorisee (' + (Get-DomeniaOuDisplayPath $SavedDn) + ') est introuvable. Aucun perimetre n est applique : choisissez une OU.');RequiresChoice=$true}
}

# ---------------------------------------------------------------- D040 back / forward
function New-DomeniaNavHistory {
    param([ValidateRange(2,200)][int]$Capacity=40)
    return [pscustomobject]@{Capacity=$Capacity;Back=(New-Object System.Collections.ArrayList);Forward=(New-Object System.Collections.ArrayList);Current=$null}
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
