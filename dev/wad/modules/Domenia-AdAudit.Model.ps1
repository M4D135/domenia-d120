# Audit AD (points 102 to 109 of the roadmap of 13 October 2026): pure decisions on data already read by the pinned
# workers of Domenia-AdAudit.Worker.ps1. Effective password policy, nested groups and cycles, delegations with an
# access estimate and its limits, GPO links versus the applied result, controller health and replication, identity
# consistency of a perimeter and of one workstation, and the stored history of user / workstation relations.
# No LDAP, CIM, DNS, disk or clock access happens here: "now" is always a parameter. An unread value stays unknown.
# Relies on Domenia-Common.Model.ps1, Domenia-Search.Model.ps1 (DN split), Domenia-Directory.Model.ps1,
# Domenia-Workstation.Model.ps1 and Domenia-Relations.Model.ps1.

# ---------------------------------------------------------------- shared
function New-DomeniaAdAuditTarget {
    # The object an audit read is about, frozen at the gesture: a later selection never receives its results.
    param($Selected,[long]$Generation=0,[long]$Epoch=0)
    if ($null -eq $Selected) { return $null }
    $dn = [string](Get-DomeniaMember $Selected 'DN' '')
    if (-not $dn) { return $null }
    $entry = Get-DomeniaMember $Selected 'Entry' $null
    $props = Get-DomeniaMember $entry 'Properties' $null
    $name = [string](Get-DomeniaMember $Selected 'Name' '')
    if (-not $name) { $name = Get-DomeniaCnFromDn $dn }
    return [pscustomobject]@{
        Dn=$dn;Type=[string](Get-DomeniaMember $Selected 'Type' '');Name=$name
        Guid=(ConvertTo-DomeniaGuidText (Get-DomeniaMember $Selected 'Guid' ''))
        Sid=(ConvertTo-DomeniaSidText (Get-DomeniaAttr $props 'objectSid' ''))
        Sam=[string](Get-DomeniaAttr $props 'sAMAccountName' '')
        DnsHostName=[string](Get-DomeniaAttr $props 'dNSHostName' '')
        PrimaryGroupId=[string](Get-DomeniaAttr $props 'primaryGroupID' '')
        Generation=$Generation;Epoch=$Epoch
    }
}

function Test-DomeniaAdAuditStateCurrent {
    # A callback is applied only to the target, session and selection generation it was started for.
    param($State,$Target,[long]$Epoch)
    if (($null -eq $State) -or ($null -eq $Target)) { return $false }
    if ([long](Get-DomeniaMember $State 'Epoch' (-1)) -ne $Epoch) { return $false }
    if ([long](Get-DomeniaMember $State 'Generation' (-1)) -ne [long](Get-DomeniaMember $Target 'Generation' (-2))) { return $false }
    return ([string](Get-DomeniaMember $State 'Dn' '') -ieq [string](Get-DomeniaMember $Target 'Dn' ''))
}

function Get-DomeniaAdAuditAvailability {
    # Which audit read applies to which kind of object, with the reason shown when it does not.
    param([AllowEmptyString()][string]$Type='',[Parameter(Mandatory=$true)][ValidateSet('Policy','Groups','Acl','GpoLinks','GpoApplied','MachineIdentity','History')][string]$Check)
    if (-not $Type) { return [pscustomobject]@{Allowed=$false;Reason='Ouvrez dʼabord une fiche depuis Rechercher : cette lecture porte sur lʼobjet sélectionné.'} }
    $allowed = $false; $reason = ''
    switch ($Check) {
        'Policy' { $allowed = ($Type -eq 'Utilisateur'); $reason = 'La stratégie de mot de passe se lit pour un compte utilisateur.' }
        'Groups' { $allowed = ($Type -in @('Utilisateur','Machine','Groupe')); $reason = 'Les appartenances se lisent pour un utilisateur, un poste ou un groupe.' }
        'Acl' { $allowed = $true }
        'GpoLinks' { $allowed = ($Type -in @('Utilisateur','Machine','OU')); $reason = 'Les liens GPO se lisent pour un utilisateur, un poste ou une unité dʼorganisation.' }
        'GpoApplied' { $allowed = ($Type -eq 'Machine'); $reason = 'Le résultat appliqué se lit sur un poste.' }
        'MachineIdentity' { $allowed = ($Type -eq 'Machine'); $reason = 'Lʼidentité AD, DNS et poste se vérifie pour un poste.' }
        'History' { $allowed = ($Type -in @('Utilisateur','Machine')); $reason = 'Lʼhistorique des associations concerne un utilisateur ou un poste.' }
    }
    if ($allowed) { $reason = '' }
    return [pscustomobject]@{Allowed=$allowed;Reason=$reason}
}

function Get-DomeniaFactStateLabel {
    param([AllowEmptyString()][string]$State)
    switch ([string]$State) {
        'Constate' { return 'Constaté' }
        'Estime' { return 'Estimé' }
        'Refuse' { return 'Refusé' }
        'Indisponible' { return 'Indisponible' }
        'Inconnu' { return 'Inconnu' }
    }
    return [string]$State
}

function Format-DomeniaLegacyFactText {
    # Display form of the texts of the historical directory rules (D062, D069), written without accents nor
    # apostrophes. Whole words or fixed phrases only: an unknown text is returned unchanged.
    param([AllowEmptyString()][AllowNull()][string]$Text)
    $value = [string]$Text
    if (-not $value) { return '' }
    $pairs = @(
        @('\bResponsable a verifier\b','Responsable à vérifier'),
        @('\bA changer a la\b','À changer à la'),
        @('\bCarte a puce exigee\b','Carte à puce exigée'),
        @('\bCalcule a partir\b','Calculé à partir'),
        @('\bComplexite exigee\b','Complexité exigée'),
        @('\bne suffit pas a declarer\b','ne suffit pas à déclarer'),
        @('\bl objet a corriger\b','lʼobjet à corriger'),
        @('\bA revoir\b','À revoir'),
        @('\ba revoir\b','à revoir'),
        @('\bStrategie\b','Stratégie'),@('\bstrategie\b','stratégie'),
        @('\bcaracteres\b','caractères'),@('\bechecs\b','échecs'),@('\bechec\b','échec'),
        @('\bDuree\b','Durée'),@('\bduree\b','durée'),@('\bvalidite\b','validité'),
        @('\bdeverrouillage\b','déverrouillage'),@('\bN expire\b','Nʼexpire'),@('\bn expire\b','nʼexpire'),
        @('\bechu\b','échu'),@('\bn est\b','nʼest'),@('\bdesactive\b','désactivé'),@('\bdeduite\b','déduite'),
        @('\bcontroleur\b','contrôleur'),@('\bControleur\b','Contrôleur'),
        @('\bverifiee\b','vérifiée'),@('\bverifie\b','vérifié'),@('\bverifier\b','vérifier'),
        @('\bPerimetre\b','Périmètre'),@('\bperimetre\b','périmètre'),@('\bincomplete\b','incomplète'),
        @('\bdesigne\b','désigne'),@('\bDerniere\b','Dernière'),@('\bdefini\b','défini'),
        @('\bl utilisateur\b','lʼutilisateur'),@('\bReplication\b','Réplication'),@('\breplication\b','réplication'),
        @('\bdifferee\b','différée'),@('\butilise\b','utilisé'),@('\bConfirme\b','Confirmé'),@('\bconfirme\b','confirmé')
    )
    foreach ($pair in $pairs) { $value = [regex]::Replace($value,$pair[0],$pair[1]) }
    return $value
}

function ConvertTo-DomeniaAdAuditFactRows {
    # Grid rows of explainable facts (New-DomeniaFact), labels in their display form.
    param([object[]]$Facts=@())
    foreach ($fact in @($Facts)) {
        if ($null -eq $fact) { continue }
        [pscustomobject]@{
            Fait=(Format-DomeniaLegacyFactText ([string](Get-DomeniaMember $fact 'Fait' '')))
            Valeur=(Format-DomeniaLegacyFactText ([string](Get-DomeniaMember $fact 'Valeur' '')))
            Etat=(Get-DomeniaFactStateLabel ([string](Get-DomeniaMember $fact 'Etat' '')))
            Source=(Format-DomeniaLegacyFactText ([string](Get-DomeniaMember $fact 'Source' '')))
            Limite=(Format-DomeniaLegacyFactText (([string](Get-DomeniaMember $fact 'Limite' '') + ' ' + [string](Get-DomeniaMember $fact 'Hypothese' '')).Trim()))
            Date=[string](Get-DomeniaMember $fact 'Date' '')
        }
    }
}

function ConvertTo-DomeniaAdAuditCopyText {
    # Plain text of what a view shows, for a ticket: each section with its summary, then its rows, one per line, the
    # values separated by a tabulation. Nothing is read again; at most MaxRows rows per section.
    param([object[]]$Sections=@(),[AllowEmptyString()][string]$Title='',[ValidateRange(1,20000)][int]$MaxRows=2000)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    if ($Title) { $lines.Add($Title); $lines.Add('') }
    foreach ($section in @($Sections)) {
        if ($null -eq $section) { continue }
        $summary = [string](Get-DomeniaMember $section 'Summary' '')
        if ($summary) { $lines.Add($summary) }
        $columns = @(@(Get-DomeniaMember $section 'Columns' @()) | Where-Object { $null -ne $_ })
        $rows = @(@(Get-DomeniaMember $section 'Rows' @()) | Where-Object { $null -ne $_ })
        if (($columns.Count -gt 0) -and ($rows.Count -gt 0)) {
            $lines.Add((@($columns | ForEach-Object { [string](Get-DomeniaMember $_ 'Header' '') }) -join "`t"))
            $count = 0
            foreach ($row in $rows) {
                if ($count -ge $MaxRows) { $lines.Add([string]($rows.Count - $MaxRows) + ' ligne(s) non copiée(s).'); break }
                $lines.Add((@($columns | ForEach-Object { ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $row ([string](Get-DomeniaMember $_ 'Property' '')) '')) 400 }) -join "`t"))
                $count++
            }
        }
        $lines.Add('')
    }
    return ($lines.ToArray() -join [Environment]::NewLine).TrimEnd()
}

# ---------------------------------------------------------------- point 102 : applicable password policy
function ConvertTo-DomeniaPasswordPolicyView {
    # The policy that applies to one account, from the PasswordPolicyRead worker. msDS-ResultantPSO decides. The
    # domain policy is presumed only when this account can see the fine-grained policies and none applies; with no
    # fine-grained policy visible the applicable policy stays unknown and the domain policy is shown as a reference.
    # Nothing about the password itself is read, scored or called compromised.
    param($Read,[AllowEmptyString()][string]$Reader='',[datetime]$NowUtc=[datetime]::UtcNow)
    if ($null -eq $Read) { return [pscustomobject]@{State='NotRead';PolicyKnown=$false;Summary='Stratégie non lue.';Facts=@();ExpiresUtc=$null} }
    $user = Get-DomeniaMember $Read 'User' $null
    $resultant = [string](Get-DomeniaMember $Read 'ResultantPso' '')
    $pso = Get-DomeniaMember $Read 'Pso' $null
    $domain = Get-DomeniaMember $Read 'Domain' $null
    $visible = [int](Get-DomeniaMember $Read 'PsoVisibleCount' (-1))
    $state = 'Unreadable'; $reason = ''
    if ($resultant) {
        if ($null -ne $pso) { $state = 'Applies' }
        else { $reason = 'Une stratégie fine sʼapplique (' + (Get-DomeniaCnFromDn $resultant) + ') mais ses paramètres ne sont pas lisibles avec ce compte.' }
    }
    elseif ($visible -gt 0) {
        if ($null -ne $domain) { $state = 'None' }
        else { $reason = 'Aucune stratégie fine ne sʼapplique, mais la stratégie du domaine nʼa pas pu être lue.' }
    }
    elseif ($visible -eq 0) { $reason = 'Aucune stratégie fine visible avec ce compte : il nʼen existe peut-être aucune, ou ce compte ne peut pas les lire. La stratégie du domaine nʼest donc pas présumée.' }
    else { $reason = 'Conteneur des stratégies fines illisible : la stratégie applicable reste inconnue.' }
    $resolved = Resolve-DomeniaPasswordPolicy -User $user -ResultantPsoState $state -Pso $pso -DomainPolicy $domain -Reader $Reader -NowUtc $NowUtc
    $facts = New-Object 'System.Collections.Generic.List[object]'
    foreach ($fact in @($resolved.Facts)) { $facts.Add($fact) }
    if ($reason) { $facts.Insert([Math]::Min(1,$facts.Count),(New-DomeniaFact -Fait 'Pourquoi inconnue' -Valeur $reason -Etat Inconnu -Source 'msDS-ResultantPSO et conteneur des stratégies fines' -Lecteur $Reader)) }
    if ($state -eq 'Applies') {
        $precedence = [string](Get-DomeniaAttr $pso 'msDS-PasswordSettingsPrecedence' '')
        if ($precedence) { $facts.Add((New-DomeniaFact -Fait 'Priorité de la stratégie fine' -Valeur $precedence -Source 'msDS-PasswordSettingsPrecedence' -Limite 'La plus petite valeur gagne quand plusieurs stratégies visent le compte ; le contrôleur a déjà fait ce choix.' -Lecteur $Reader)) }
    }
    if (($state -ne 'None') -and ($null -ne $domain)) {
        # Shown as a reference only: never presented as the policy of this account.
        $reference = Resolve-DomeniaPasswordPolicy -User @{} -ResultantPsoState 'None' -DomainPolicy $domain -Reader $Reader -NowUtc $NowUtc
        foreach ($fact in @($reference.Facts)) {
            $label = [string](Get-DomeniaMember $fact 'Fait' '')
            if ($label -in @('Strategie applicable','Expiration du mot de passe','Restriction')) { continue }
            $facts.Add((New-DomeniaFact -Fait ('Domaine (référence) · ' + $label) -Valeur ([string]$fact.Valeur) -Etat Inconnu -Source 'Stratégie du domaine' -Limite 'Référence seulement : ne sʼapplique à ce compte que si aucune stratégie fine ne le vise.' -Lecteur $Reader))
        }
    }
    $summary = switch ($state) {
        'Applies' { 'Stratégie fine applicable : ' + (Get-DomeniaCnFromDn $resultant) + '.' }
        'None' { 'Aucune stratégie fine ne vise ce compte : la stratégie du domaine sʼapplique.' }
        default { 'Stratégie applicable inconnue. ' + $reason }
    }
    return [pscustomobject]@{State=$state;PolicyKnown=[bool]$resolved.PolicyKnown;Summary=$summary;Facts=$facts.ToArray();ExpiresUtc=$resolved.ExpiresUtc}
}

# ---------------------------------------------------------------- point 103 : nested groups and cycles
function ConvertTo-DomeniaGroupKey {
    param([AllowEmptyString()][AllowNull()][string]$Dn)
    return ([string]$Dn).Trim().ToLowerInvariant()
}

function Find-DomeniaGroupCycles {
    # Cycles of a membership graph (DN key -> parent DN keys), found by an iterative depth-first walk: no
    # recursion limit, each cycle reported once whatever its starting point, at most MaxCycles.
    param([Collections.IDictionary]$Edges,[ValidateRange(1,500)][int]$MaxCycles=20)
    $cycles = New-Object 'System.Collections.Generic.List[object]'
    if ($null -eq $Edges) { return ,$cycles.ToArray() }
    $comparer = [StringComparer]::OrdinalIgnoreCase
    $lookup = New-Object 'System.Collections.Generic.Dictionary[string,object]' $comparer
    foreach ($key in @($Edges.Keys)) {
        $children = New-Object 'System.Collections.Generic.List[string]'
        $value = $Edges[$key]
        if ($value -is [string]) { if ($value) { $children.Add($value) } }
        elseif ($value -is [Collections.IEnumerable]) { foreach ($item in $value) { if (($null -ne $item) -and ([string]$item)) { $children.Add([string]$item) } } }
        $lookup[[string]$key] = $children
    }
    $color = New-Object 'System.Collections.Generic.Dictionary[string,int]' $comparer
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' $comparer
    foreach ($root in @($lookup.Keys)) {
        if ($color.ContainsKey($root)) { continue }
        $stack = New-Object 'System.Collections.Generic.Stack[object]'
        $path = New-Object 'System.Collections.Generic.List[string]'
        $stack.Push([pscustomobject]@{Node=$root;Children=$lookup[$root];Index=0})
        $color[$root] = 1; $path.Add($root)
        while ($stack.Count -gt 0) {
            $frame = $stack.Peek()
            if ($frame.Index -lt $frame.Children.Count) {
                $next = [string]$frame.Children[$frame.Index]
                $frame.Index = $frame.Index + 1
                $state = 0
                if ($color.ContainsKey($next)) { $state = $color[$next] }
                if ($state -eq 0) {
                    $children = New-Object 'System.Collections.Generic.List[string]'
                    if ($lookup.ContainsKey($next)) { $children = $lookup[$next] }
                    $stack.Push([pscustomobject]@{Node=$next;Children=$children;Index=0})
                    $color[$next] = 1; $path.Add($next)
                }
                elseif ($state -eq 1) {
                    $start = -1
                    for ($i = 0; $i -lt $path.Count; $i++) { if ($comparer.Equals($path[$i],$next)) { $start = $i; break } }
                    if ($start -ge 0) {
                        $members = New-Object 'System.Collections.Generic.List[string]'
                        for ($i = $start; $i -lt $path.Count; $i++) { $members.Add($path[$i]) }
                        $sorted = @($members.ToArray() | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
                        if ($seen.Add(($sorted -join '|'))) {
                            $members.Add($next)
                            $cycles.Add($members.ToArray())
                            if ($cycles.Count -ge $MaxCycles) { return ,$cycles.ToArray() }
                        }
                    }
                }
            }
            else {
                [void]$stack.Pop()
                $color[[string]$frame.Node] = 2
                $path.RemoveAt($path.Count - 1)
            }
        }
    }
    return ,$cycles.ToArray()
}

function ConvertTo-DomeniaNestedGroupView {
    # Rows of the nested memberships read by the GroupPathRead worker: depth and first path from the object,
    # read state of each group, cycles, unread groups with their reason and the primary group, which memberOf never
    # lists. A truncated read never leads to "not a member".
    param($Read)
    if ($null -eq $Read) { return $null }
    $startDn = [string](Get-DomeniaMember $Read 'Dn' '')
    $startKey = ConvertTo-DomeniaGroupKey $startDn
    $display = @{}
    $display[$startKey] = $startDn
    $edges = @{}
    $startParents = New-Object 'System.Collections.Generic.List[string]'
    foreach ($parent in @(Get-DomeniaMember $Read 'StartParents' @())) {
        $dn = [string]$parent
        if (-not $dn) { continue }
        $key = ConvertTo-DomeniaGroupKey $dn
        if (-not $display.ContainsKey($key)) { $display[$key] = $dn }
        if (-not $startParents.Contains($key)) { $startParents.Add($key) }
    }
    $edges[$startKey] = $startParents.ToArray()
    $info = @{}
    foreach ($node in @(Get-DomeniaMember $Read 'Nodes' @())) {
        if ($null -eq $node) { continue }
        $dn = [string](Get-DomeniaMember $node 'Dn' '')
        if (-not $dn) { continue }
        $key = ConvertTo-DomeniaGroupKey $dn
        $display[$key] = $dn
        $parents = New-Object 'System.Collections.Generic.List[string]'
        foreach ($parent in @(Get-DomeniaMember $node 'Parents' @())) {
            $pdn = [string]$parent
            if (-not $pdn) { continue }
            $pkey = ConvertTo-DomeniaGroupKey $pdn
            if (-not $display.ContainsKey($pkey)) { $display[$pkey] = $pdn }
            if (-not $parents.Contains($pkey)) { $parents.Add($pkey) }
        }
        $edges[$key] = $parents.ToArray()
        $info[$key] = $node
    }
    $unread = @{}
    foreach ($item in @(Get-DomeniaMember $Read 'Unread' @())) {
        if ($null -eq $item) { continue }
        $dn = [string](Get-DomeniaMember $item 'Dn' '')
        if (-not $dn) { continue }
        $key = ConvertTo-DomeniaGroupKey $dn
        if (-not $display.ContainsKey($key)) { $display[$key] = $dn }
        if (-not $unread.ContainsKey($key)) { $unread[$key] = [string](Get-DomeniaMember $item 'Reason' 'Non lu') }
    }
    # Display label of every key: the group name read, else the first RDN of its distinguished name.
    $labels = @{}
    foreach ($key in @($display.Keys)) {
        $label = ''
        if ($info.ContainsKey($key)) { $label = [string](Get-DomeniaMember $info[$key] 'Name' '') }
        if (-not $label) { $label = Get-DomeniaCnFromDn ([string]$display[$key]) }
        $labels[$key] = $label
    }
    # Breadth-first from the object: depth and first parent give the path shown for each group.
    $depth = @{}; $via = @{}
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $depth[$startKey] = 0; $queue.Enqueue($startKey)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $edges.ContainsKey($current)) { continue }
        foreach ($parent in @($edges[$current])) {
            if ($depth.ContainsKey($parent)) { continue }
            $depth[$parent] = $depth[$current] + 1
            $via[$parent] = $current
            $queue.Enqueue($parent)
        }
    }
    $groupEdges = @{}
    foreach ($key in @($edges.Keys)) { if ($key -ne $startKey) { $groupEdges[$key] = $edges[$key] } }
    $cycles = Find-DomeniaGroupCycles -Edges $groupEdges -MaxCycles 20
    $inCycle = @{}
    foreach ($cycle in $cycles) { foreach ($member in @($cycle)) { $inCycle[[string]$member] = $true } }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($key in @($depth.Keys | Where-Object { $_ -ne $startKey })) {
        $dn = [string]$display[$key]
        $node = $null
        if ($info.ContainsKey($key)) { $node = $info[$key] }
        $stateText = 'Lu'
        if ($unread.ContainsKey($key)) { $stateText = 'Non lu : ' + $unread[$key] }
        elseif ($null -eq $node) { $stateText = 'Non lu : lecture arrêtée avant ce groupe' }
        elseif ([bool](Get-DomeniaMember $node 'Partial' $false)) { $stateText = 'Lu partiellement : plus de 1 500 appartenances, liste incomplète' }
        $viaText = 'Appartenance directe'
        if ($via.ContainsKey($key) -and ($via[$key] -ne $startKey)) { $viaText = 'Par ' + [string]$labels[$via[$key]] }
        $privileged = $false
        if ($null -ne $node) { $privileged = Test-DomeniaPrivilegedGroup ([pscustomobject]@{Sid=[string](Get-DomeniaMember $node 'Sid' '');Name=[string](Get-DomeniaMember $node 'Name' '');AdminCount=[string](Get-DomeniaMember $node 'AdminCount' '')}) }
        $rows.Add([pscustomobject]@{Groupe=[string]$labels[$key];Dn=$dn;Profondeur=[int]$depth[$key];Via=$viaText;Etat=$stateText;Cycle=$(if ($inCycle.ContainsKey($key)) { 'Oui' } else { '' });Privilegie=$(if ($privileged) { 'Oui' } else { '' })})
    }
    $sorted = @($rows.ToArray() | Sort-Object Profondeur,Groupe)
    $direct = @($sorted | Where-Object { $_.Profondeur -eq 1 }).Count
    $maxDepth = 0
    foreach ($row in $sorted) { if ($row.Profondeur -gt $maxDepth) { $maxDepth = $row.Profondeur } }
    $cycleTexts = @(foreach ($cycle in $cycles) { (@($cycle) | ForEach-Object { [string]$labels[[string]$_] }) -join ' → ' })
    $unreadRows = @(foreach ($key in @($unread.Keys | Sort-Object)) { [pscustomobject]@{Groupe=[string]$labels[$key];Dn=[string]$display[$key];Raison=[string]$unread[$key]} })
    $truncated = [bool](Get-DomeniaMember $Read 'Truncated' $false)
    $startComplete = [bool](Get-DomeniaMember $Read 'StartComplete' $true)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add([string]$sorted.Count + ' groupe(s) : ' + [string]$direct + ' direct(s), ' + [string]($sorted.Count - $direct) + ' par imbrication, profondeur maximale ' + [string]$maxDepth + '.')
    if ($cycles.Count) { $lines.Add([string]$cycles.Count + ' cycle(s) dʼimbrication : ' + ($cycleTexts -join ' ; ') + '.') }
    if ($unreadRows.Count) { $lines.Add([string]$unreadRows.Count + ' groupe(s) non lu(s) : leurs propres appartenances manquent.') }
    if (-not $startComplete) { $lines.Add('Appartenances directes de lʼobjet lues partiellement : ' + [string](Get-DomeniaMember $Read 'StartNote' '') ) }
    if ($truncated) { $lines.Add('Lecture bornée : ' + [string](Get-DomeniaMember $Read 'TruncatedReason' '') + ' Une absence ne prouve rien.') }
    $primary = Get-DomeniaMember $Read 'PrimaryGroup' $null
    $primaryText = ''
    if ($null -ne $primary) {
        $primaryName = [string](Get-DomeniaMember $primary 'Name' '')
        $primarySid = [string](Get-DomeniaMember $primary 'Sid' '')
        if ($primaryName) { $primaryText = 'Groupe principal : ' + $primaryName + ' (primaryGroupID, absent de memberOf).' }
        elseif ($primarySid) { $primaryText = 'Groupe principal : ' + $primarySid + ' (nom non lu).' }
    }
    if ($primaryText) { $lines.Add($primaryText) }
    $lines.Add('Groupes dʼautres domaines et appartenances par le groupe principal des groupes non couverts.')
    return [pscustomobject]@{
        Rows=$sorted;Unread=$unreadRows;Cycles=$cycleTexts;CycleCount=$cycles.Count;Edges=$edges;StartKey=$startKey;Display=$display;Labels=$labels
        Truncated=($truncated -or (-not $startComplete));Summary=($lines.ToArray() -join [Environment]::NewLine)
        PrimaryGroupSid=[string](Get-DomeniaMember $primary 'Sid' '');PrimaryGroupDn=[string](Get-DomeniaMember $primary 'Dn' '')
    }
}

function Get-DomeniaGroupMembershipExplanation {
    # Why the object is (or may be) a member of one group: the shortest path in the memberships read, then the
    # answer of the controller when it was asked. The primary group is named as such.
    param($View,[AllowEmptyString()][string]$TargetDn='',$ServerAnswer=$null,[AllowEmptyString()][string]$ServerError='')
    if (($null -eq $View) -or (-not $TargetDn)) { return [pscustomobject]@{Member=$null;Certain=$false;Path=@();Text='Choisissez un groupe.'} }
    $targetKey = ConvertTo-DomeniaGroupKey $TargetDn
    $labels = $View.Labels
    if (([string]$View.PrimaryGroupDn) -and ((ConvertTo-DomeniaGroupKey ([string]$View.PrimaryGroupDn)) -eq $targetKey)) {
        return [pscustomobject]@{Member=$true;Certain=$true;Path=@();Text='Membre par son groupe principal (primaryGroupID) : cette appartenance nʼapparaît pas dans memberOf.'}
    }
    $local = Find-DomeniaMembershipPath -Edges $View.Edges -Start ([string]$View.StartKey) -Target $targetKey
    $answer = Resolve-DomeniaMembershipAnswer $ServerAnswer $local ([bool]$View.Truncated)
    $names = @()
    if ([bool]$local.Found) { $names = @(@($local.Path) | ForEach-Object { $key = ConvertTo-DomeniaGroupKey ([string]$_); if ($labels.ContainsKey($key)) { [string]$labels[$key] } else { Get-DomeniaCnFromDn ([string]$_) } }) }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    if ($names.Count) { $lines.Add('Chemin : ' + ($names -join ' → ') + $(if ($names.Count -eq 2) { ' (appartenance directe)' } else { '' })) }
    if ($ServerAnswer -eq $true) { $lines.Add('Membre : confirmé par le contrôleur (appartenance directe ou imbriquée).') }
    elseif ($ServerAnswer -eq $false) { $lines.Add('Non membre selon le contrôleur pour ce compte de lecture. Le groupe principal et les groupes dʼautres domaines ne sont pas couverts par ce test.') }
    elseif ([bool]$local.Found) { $lines.Add('Membre : chemin trouvé dans les appartenances lues.') }
    elseif ($null -eq $answer.Member) { $lines.Add('Indéterminé : la lecture est bornée ou incomplète. Demandez la confirmation au contrôleur.') }
    else { $lines.Add('Aucun chemin dans les appartenances lues. Le groupe principal et les groupes dʼautres domaines ne sont pas couverts ; le contrôleur peut confirmer.') }
    if ($ServerError) { $lines.Add('Confirmation du contrôleur impossible : ' + $ServerError) }
    if ([bool]$local.CycleSeen) { $lines.Add('Un cycle dʼimbrication a été rencontré sur le parcours ; il est ignoré pour le calcul.') }
    return [pscustomobject]@{Member=$answer.Member;Certain=[bool]$answer.Certain;Path=$names;Text=($lines.ToArray() -join [Environment]::NewLine)}
}

# ---------------------------------------------------------------- point 104 : delegations and access estimate
function Get-DomeniaWellKnownSidName {
    # French label of a well-known or built-in SID; '' for any other account.
    param([AllowEmptyString()][AllowNull()][string]$Sid)
    $value = ([string]$Sid).Trim()
    if (-not $value) { return '' }
    $fixed = @{
        'S-1-1-0'='Tout le monde';'S-1-3-0'='Créateur propriétaire';'S-1-5-2'='Réseau';'S-1-5-4'='Interactif';'S-1-5-7'='Ouverture de session anonyme'
        'S-1-5-9'='Contrôleurs de domaine dʼentreprise';'S-1-5-10'='Lʼobjet lui-même (SELF)';'S-1-5-11'='Utilisateurs authentifiés';'S-1-5-18'='Système local'
        'S-1-5-19'='Service local';'S-1-5-20'='Service réseau';'S-1-5-32-544'='Administrateurs (intégré)';'S-1-5-32-545'='Utilisateurs (intégré)'
        'S-1-5-32-546'='Invités (intégré)';'S-1-5-32-548'='Opérateurs de compte';'S-1-5-32-549'='Opérateurs de serveur';'S-1-5-32-550'='Opérateurs dʼimpression'
        'S-1-5-32-551'='Opérateurs de sauvegarde';'S-1-5-32-554'='Accès compatible pré-Windows 2000';'S-1-5-32-560'='Groupe dʼaccès dʼautorisation Windows'
        'S-1-5-32-561'='Serveurs de licences des services Terminal Server'
    }
    if ($fixed.ContainsKey($value)) { return [string]$fixed[$value] }
    $rid = [regex]::Match($value,'^S-1-5-21-\d+-\d+-\d+-(?<rid>\d+)$')
    if ($rid.Success) {
        $domain = @{'500'='Administrateur du domaine';'502'='krbtgt';'512'='Admins du domaine';'513'='Utilisateurs du domaine';'515'='Ordinateurs du domaine';'516'='Contrôleurs de domaine';'517'='Éditeurs de certificats';'518'='Administrateurs du schéma';'519'='Administrateurs de lʼentreprise';'520'='Propriétaires créateurs de la stratégie de groupe';'521'='Contrôleurs de domaine en lecture seule';'526'='Administrateurs clés';'527'='Administrateurs clés de lʼentreprise';'553'='Serveurs RAS et IAS'}
        $key = $rid.Groups['rid'].Value
        if ($domain.ContainsKey($key)) { return [string]$domain[$key] }
    }
    return ''
}

function Get-DomeniaAdGuidLabel {
    # French label of the schema objects and extended rights met most often in delegations; '' otherwise.
    param([AllowEmptyString()][AllowNull()][string]$Guid)
    $key = ([string]$Guid).Trim().ToLowerInvariant()
    $table = @{
        '00299570-246d-11d0-a768-00aa006e0529'='Réinitialiser le mot de passe';'ab721a53-1e2f-11d0-9819-00aa0040529b'='Modifier le mot de passe'
        'ab721a54-1e2f-11d0-9819-00aa0040529b'='Envoyer en tant que';'ab721a56-1e2f-11d0-9819-00aa0040529b'='Recevoir en tant que'
        '4c164200-20c0-11d0-a768-00aa006e0529'='Restrictions du compte (ensemble de propriétés)';'5f202010-79a5-11d0-9020-00c04fc2d4cf'='Informations dʼouverture de session (ensemble de propriétés)'
        'bc0ac240-79a9-11d0-9020-00c04fc2d4cf'='Appartenance aux groupes (ensemble de propriétés)';'59ba2f42-79a2-11d0-9020-00c04fc2d3cf'='Informations générales (ensemble de propriétés)'
        '77b5b886-944a-11d1-aebd-0000f80367c1'='Informations personnelles (ensemble de propriétés)';'e48d0154-bcf8-11d1-8702-00c04fb96050'='Informations publiques (ensemble de propriétés)'
        'e45795b2-9455-11d1-aebd-0000f80367c1'='Informations de messagerie (ensemble de propriétés)';'e45795b3-9455-11d1-aebd-0000f80367c1'='Informations web (ensemble de propriétés)'
        '037088f8-0ae1-11d2-b422-00a0c968f939'='Informations dʼaccès distant (ensemble de propriétés)';'91e647de-d96f-4b70-9557-d63ff4f3ccd8'='Informations privées (ensemble de propriétés)'
        'bf9679c0-0de6-11d0-a285-00aa003049e2'='Membres du groupe (member)';'bf967a68-0de6-11d0-a285-00aa003049e2'='Options du compte (userAccountControl)'
        'bf967a0a-0de6-11d0-a285-00aa003049e2'='Date du mot de passe (pwdLastSet)';'28630ebf-41d5-11d1-a9c1-0000f80367c1'='Verrouillage (lockoutTime)'
        'bf9679a8-0de6-11d0-a285-00aa003049e2'='Script dʼouverture de session (scriptPath)';'f3a64788-5306-11d1-a9c5-0000f80367c1'='Noms de principal de service (servicePrincipalName)'
        '72e39547-7b18-11d1-adef-00c04fd8d5cd'='Écriture validée du nom DNS (dNSHostName)';'3f78c3e5-f79a-46bd-a0b8-9d18116ddc79'='Délégation contrainte basée sur la ressource (msDS-AllowedToActOnBehalfOfOtherIdentity)'
        '5b47d60f-6090-40b2-9f37-2a4de88f3063'='Informations dʼidentification de clé (msDS-KeyCredentialLink)';'1131f6aa-9c07-11d1-f79f-00c04fc2dcd2'='Répliquer les modifications de lʼannuaire'
        '1131f6ad-9c07-11d1-f79f-00c04fc2dcd2'='Répliquer toutes les modifications de lʼannuaire';'89e95b76-444d-4c62-991a-0facbeda640c'='Répliquer les modifications dʼun jeu filtré'
        'edacfd8f-ffb3-11d1-b41d-00a0c968f939'='Appliquer la stratégie de groupe';'bf967aba-0de6-11d0-a285-00aa003049e2'='Objets utilisateur'
        'bf967a86-0de6-11d0-a285-00aa003049e2'='Objets ordinateur';'bf967a9c-0de6-11d0-a285-00aa003049e2'='Objets groupe';'bf967aa5-0de6-11d0-a285-00aa003049e2'='Unités dʼorganisation'
        '4828cc14-1437-45bc-9b07-ad6f015e5f28'='Objets inetOrgPerson'
    }
    if ($table.ContainsKey($key)) { return [string]$table[$key] }
    return ''
}

function ConvertTo-DomeniaAdRightNames {
    # Names of an ActiveDirectoryRights value as text ('ReadProperty, WriteProperty'), generic rights kept whole.
    param([AllowEmptyString()][AllowNull()][string]$Rights)
    return @(([string]$Rights) -split '\s*,\s*' | Where-Object { $_ } | ForEach-Object { $_.Trim() })
}

function Format-DomeniaAdRights {
    param([AllowEmptyString()][AllowNull()][string]$Rights)
    $labels = @{
        GenericAll='Contrôle total';GenericRead='Lecture';GenericWrite='Écriture';GenericExecute='Exécution';ReadProperty='Lire des propriétés'
        WriteProperty='Écrire des propriétés';ExtendedRight='Droit étendu';CreateChild='Créer des objets enfants';DeleteChild='Supprimer des objets enfants'
        Delete='Supprimer';DeleteTree='Supprimer lʼarborescence';ReadControl='Lire les autorisations';WriteDacl='Modifier les autorisations'
        WriteOwner='Modifier le propriétaire';ListChildren='Lister le contenu';ListObject='Lister lʼobjet';Self='Écriture validée'
        AccessSystemSecurity='Accès à la sécurité système';Synchronize='Synchroniser'
    }
    $parts = @(foreach ($name in @(ConvertTo-DomeniaAdRightNames $Rights)) { if ($labels.ContainsKey($name)) { [string]$labels[$name] } else { $name } })
    return ($parts -join ', ')
}

function Test-DomeniaAceAppliesToObject {
    # An inherit-only entry (Descendents, Children) is carried by the object for its children, not applied to it.
    param($Ace)
    return ([string](Get-DomeniaMember $Ace 'InheritanceType' 'None') -in @('None','All','SelfAndChildren'))
}

function ConvertTo-DomeniaDelegationView {
    # Rows of the DelegationRead worker (Action Acl): each entry with its trustee, its rights in words, the
    # property, right or class it targets, the objects it applies to, and whether it is explicit or inherited.
    # An entry is an observation of the list, never a verified capability.
    param($Read)
    if ($null -eq $Read) { return $null }
    $state = [string](Get-DomeniaMember $Read 'State' 'Read')
    $names = Get-DomeniaMember $Read 'SidNames' $null
    $guids = Get-DomeniaMember $Read 'GuidNames' $null
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($ace in @(Get-DomeniaMember $Read 'Aces' @())) {
        if ($null -eq $ace) { continue }
        $sid = [string](Get-DomeniaMember $ace 'Sid' '')
        $trustee = Get-DomeniaWellKnownSidName $sid
        $resolved = [string](Get-DomeniaMember $names $sid '')
        if ($resolved -and ((-not $trustee) -or ($sid -match '^S-1-5-21-'))) { $trustee = $resolved }
        if (-not $trustee) { $trustee = $sid }
        $base = @(ConvertTo-DomeniaAceView -Aces @([pscustomobject]@{IdentityReference=$trustee;AccessControlType=[string](Get-DomeniaMember $ace 'AccessControlType' 'Allow');ActiveDirectoryRights=[string](Get-DomeniaMember $ace 'ActiveDirectoryRights' '');IsInherited=[bool](Get-DomeniaMember $ace 'IsInherited' $false);InheritanceType=[string](Get-DomeniaMember $ace 'InheritanceType' 'None');ObjectType=[string](Get-DomeniaMember $ace 'ObjectType' '')}) -GuidNames $guids)[0]
        $rightNames = @(ConvertTo-DomeniaAdRightNames ([string](Get-DomeniaMember $ace 'ActiveDirectoryRights' '')))
        $objectType = ([string](Get-DomeniaMember $ace 'ObjectType' '')).ToLowerInvariant()
        $target = ''
        if ($objectType -and $objectType -ne '00000000-0000-0000-0000-000000000000') {
            $target = Get-DomeniaAdGuidLabel $objectType
            if (-not $target) { $target = [string](Get-DomeniaMember $guids $objectType '') }
            if (-not $target) { $target = $objectType }
        }
        elseif ($rightNames -contains 'ExtendedRight') { $target = 'Tous les droits étendus' }
        elseif (($rightNames -contains 'WriteProperty') -or ($rightNames -contains 'ReadProperty')) { $target = 'Toutes les propriétés' }
        elseif (($rightNames -contains 'CreateChild') -or ($rightNames -contains 'DeleteChild')) { $target = 'Tous les types dʼobjets' }
        $inheritedType = ([string](Get-DomeniaMember $ace 'InheritedObjectType' '')).ToLowerInvariant()
        $appliesTo = 'Tous les objets'
        if ($inheritedType -and $inheritedType -ne '00000000-0000-0000-0000-000000000000') {
            $appliesTo = Get-DomeniaAdGuidLabel $inheritedType
            if (-not $appliesTo) { $appliesTo = [string](Get-DomeniaMember $guids $inheritedType '') }
            if (-not $appliesTo) { $appliesTo = $inheritedType }
        }
        $inherited = [bool](Get-DomeniaMember $ace 'IsInherited' $false)
        $rows.Add([pscustomobject]@{
            Beneficiaire=$trustee;Sid=$sid;Type=[string]$base.Type;Droits=(Format-DomeniaAdRights ([string](Get-DomeniaMember $ace 'ActiveDirectoryRights' '')))
            Cible=$target;SappliqueA=$appliesTo;Origine=$(if ($inherited) { 'Héritée dʼun conteneur parent' } else { 'Posée sur cet objet' })
            Portee=[string]$base.Portee;Explicite=(-not $inherited);SurObjet=(Test-DomeniaAceAppliesToObject $ace)
        })
    }
    $all = $rows.ToArray()
    $ownerSid = [string](Get-DomeniaMember $Read 'OwnerSid' '')
    $owner = Get-DomeniaWellKnownSidName $ownerSid
    $ownerResolved = [string](Get-DomeniaMember $names $ownerSid '')
    if ($ownerResolved) { $owner = $ownerResolved }
    if (-not $owner) { $owner = $ownerSid }
    $explicit = @($all | Where-Object { $_.Explicite }).Count
    $deny = @($all | Where-Object { $_.Type -eq 'Refus' }).Count
    $lines = New-Object 'System.Collections.Generic.List[string]'
    if ($state -eq 'Refused') { $lines.Add('Lecture de la liste de contrôle dʼaccès refusée : aucune délégation nʼest affichée et aucune absence nʼest déduite.') }
    elseif ($state -ne 'Read') { $lines.Add('Liste de contrôle dʼaccès non lue : ' + [string](Get-DomeniaMember $Read 'Message' '')) }
    else {
        $lines.Add([string]$all.Count + ' entrée(s) : ' + [string]$explicit + ' posée(s) sur lʼobjet, ' + [string]($all.Count - $explicit) + ' héritée(s), ' + [string]$deny + ' refus.')
        if ($owner) { $lines.Add('Propriétaire : ' + $owner + ' (droits implicites de lecture et de modification des autorisations).') }
        if ([bool](Get-DomeniaMember $Read 'Protected' $false)) { $lines.Add('Héritage désactivé sur cet objet : seules ses entrées propres comptent.') }
        if ([bool](Get-DomeniaMember $Read 'Truncated' $false)) { $lines.Add('Liste bornée à ' + [string](Get-DomeniaMember $Read 'MaxAces' 0) + ' entrées sur ' + [string](Get-DomeniaMember $Read 'Total' 0) + '.') }
        if ([string](Get-DomeniaMember $Read 'SidNamesError' '')) { $lines.Add('Noms de certains comptes non lus : leur SID est affiché.') }
    }
    $lines.Add('Une entrée observée nʼest pas un droit effectif : groupes, refus, propriétaire et privilèges changent le résultat.')
    return [pscustomobject]@{Rows=$all;State=$state;Owner=$owner;Explicit=$explicit;Inherited=($all.Count - $explicit);Deny=$deny;Summary=($lines.ToArray() -join [Environment]::NewLine)}
}

function Select-DomeniaDelegationRows {
    param([object[]]$Rows=@(),[bool]$ExplicitOnly=$false,[AllowEmptyString()][string]$Text='')
    $needle = ([string]$Text).Trim()
    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }
        if ($ExplicitOnly -and -not [bool]$row.Explicite) { continue }
        if ($needle) {
            $hit = $false
            foreach ($name in @('Beneficiaire','Sid','Droits','Cible','SappliqueA')) { if (([string](Get-DomeniaMember $row $name '')).IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true; break } }
            if (-not $hit) { continue }
        }
        $row
    }
}

function Get-DomeniaAdRightCategories {
    # Categories of the access estimate: the rights that grant them and, when the right is object-specific, the
    # GUIDs that count (an entry without GUID covers every property or right).
    return @(
        [pscustomobject]@{Id='Full';Label='Contrôle total';Rights=@('GenericAll');Guids=@();PartialRights=@()}
        [pscustomobject]@{Id='Read';Label='Lire lʼobjet';Rights=@('GenericRead','ReadProperty');Guids=@();PartialRights=@()}
        [pscustomobject]@{Id='Write';Label='Modifier des attributs';Rights=@('GenericWrite','WriteProperty');Guids=@();PartialRights=@('WriteProperty')}
        [pscustomobject]@{Id='Reset';Label='Réinitialiser le mot de passe';Rights=@('ExtendedRight');Guids=@('00299570-246d-11d0-a768-00aa006e0529');PartialRights=@()}
        [pscustomobject]@{Id='Members';Label='Modifier les membres dʼun groupe';Rights=@('GenericWrite','WriteProperty');Guids=@('bf9679c0-0de6-11d0-a285-00aa003049e2','bc0ac240-79a9-11d0-9020-00c04fc2d4cf');PartialRights=@()}
        [pscustomobject]@{Id='Create';Label='Créer des objets enfants';Rights=@('CreateChild');Guids=@();PartialRights=@('CreateChild')}
        [pscustomobject]@{Id='Delete';Label='Supprimer lʼobjet';Rights=@('Delete','DeleteTree');Guids=@();PartialRights=@()}
        [pscustomobject]@{Id='Dacl';Label='Modifier les autorisations';Rights=@('WriteDacl');Guids=@();PartialRights=@()}
        [pscustomobject]@{Id='Owner';Label='Changer le propriétaire';Rights=@('WriteOwner');Guids=@();PartialRights=@()}
    )
}

function Get-DomeniaAccessEstimate {
    # Estimate of what a set of SIDs (one trustee and, when read, its groups) may do on the object, from the entries
    # read. Canonical order: entries posed on the object first, then inherited ones; within each, a refusal wins. An
    # object-specific write counts as "partial". The result names its limits: owner, privileges and unread groups.
    param([object[]]$Aces=@(),[string[]]$Sids=@(),[bool]$IncludesGroups=$false,[AllowEmptyString()][string]$Trustee='')
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($sid in @($Sids)) { if ($sid) { [void]$set.Add(([string]$sid).Trim()) } }
    # Everyone and Authenticated Users apply to any authenticated trustee.
    [void]$set.Add('S-1-1-0'); [void]$set.Add('S-1-5-11')
    $applicable = @(@($Aces) | Where-Object { ($null -ne $_) -and (Test-DomeniaAceAppliesToObject $_) -and $set.Contains([string](Get-DomeniaMember $_ 'Sid' '')) })
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($category in @(Get-DomeniaAdRightCategories)) {
        $result = 'Non accordé par les entrées lues'; $by = ''
        foreach ($inheritedPass in @($false,$true)) {
            $deny = $null; $allow = $null; $partial = $null
            foreach ($ace in $applicable) {
                if ([bool](Get-DomeniaMember $ace 'IsInherited' $false) -ne $inheritedPass) { continue }
                $rights = @(ConvertTo-DomeniaAdRightNames ([string](Get-DomeniaMember $ace 'ActiveDirectoryRights' '')))
                $objectType = ([string](Get-DomeniaMember $ace 'ObjectType' '')).ToLowerInvariant()
                $anyObject = ((-not $objectType) -or ($objectType -eq '00000000-0000-0000-0000-000000000000'))
                $matched = $false; $isPartial = $false
                if ($rights -contains 'GenericAll') { $matched = $true }
                else {
                    foreach ($right in @($category.Rights)) {
                        if ($rights -notcontains $right) { continue }
                        if ($anyObject -or ($right -like 'Generic*')) { $matched = $true; break }
                        if ((@($category.Guids).Count -gt 0) -and (@($category.Guids) -contains $objectType)) { $matched = $true; break }
                        if (@($category.PartialRights) -contains $right) { $isPartial = $true }
                    }
                }
                $isDeny = ([string](Get-DomeniaMember $ace 'AccessControlType' 'Allow') -eq 'Deny')
                if ($matched -and $isDeny -and ($null -eq $deny)) { $deny = $ace }
                elseif ($matched -and (-not $isDeny) -and ($null -eq $allow)) { $allow = $ace }
                elseif ($isPartial -and (-not $isDeny) -and ($null -eq $partial)) { $partial = $ace }
            }
            if ($null -ne $deny) { $result = 'Refusé'; $by = $deny; break }
            if ($null -ne $allow) { $result = 'Autorisé'; $by = $allow; break }
            if ($null -ne $partial) { $result = 'Partiel : certains attributs ou types seulement'; $by = $partial; break }
        }
        $byText = ''
        if ($by) {
            $sidText = [string](Get-DomeniaMember $by 'Sid' '')
            $label = Get-DomeniaWellKnownSidName $sidText
            if (-not $label) { $label = $sidText }
            $byText = $label + $(if ([bool](Get-DomeniaMember $by 'IsInherited' $false)) { ' · entrée héritée' } else { ' · entrée posée sur lʼobjet' })
        }
        $rows.Add([pscustomobject]@{Droit=$category.Label;Resultat=$result;Par=$byText})
    }
    $limits = New-Object 'System.Collections.Generic.List[string]'
    $limits.Add('Estimation sur les entrées lues : le propriétaire (droits implicites), les privilèges (sauvegarde, restauration, prise de possession) et les refus portant sur des attributs précis ne sont pas évalués.')
    if ($IncludesGroups) { $limits.Add('Groupes du bénéficiaire lus par tokenGroups (groupes de sécurité de ce domaine et universels connus du contrôleur).') }
    else { $limits.Add('Groupes du bénéficiaire non lus : seules les entrées qui le désignent directement, et celles de Tout le monde et des Utilisateurs authentifiés, sont comptées.') }
    $subject = $Trustee
    if (-not $subject) { $subject = 'ce bénéficiaire' }
    return [pscustomobject]@{Rows=$rows.ToArray();Trustee=$subject;IncludesGroups=$IncludesGroups;Limits=($limits.ToArray() -join ' ')}
}

# ---------------------------------------------------------------- point 105 : GPO links versus applied result
function Get-DomeniaGpoContainerChain {
    # Containers whose gPLink applies to the object, closest first: the OU levels above a user or a workstation
    # (the OU itself for an OU), then the domain root. CN= containers carry no GPO link and are skipped.
    param([AllowEmptyString()][string]$Dn,[AllowEmptyString()][string]$DomainDn,[AllowEmptyString()][string]$Type='')
    $domain = ([string]$DomainDn).Trim()
    $parts = @(Split-DomeniaRawDn ([string]$Dn))
    if ((-not $domain) -or ($parts.Count -eq 0)) { return ,([string[]]@()) }
    $chain = New-Object 'System.Collections.Generic.List[string]'
    $start = 1
    if ($Type -in @('OU','Domaine')) { $start = 0 }
    if (([string]$Dn).Trim() -ieq $domain) { return ,([string[]]@($domain)) }
    $reached = $false
    for ($i = $start; $i -lt $parts.Count; $i++) {
        $candidate = ($parts[$i..($parts.Count - 1)] -join ',')
        if ($candidate -ieq $domain) { $chain.Add($candidate); $reached = $true; break }
        if (([string]$parts[$i]).TrimStart() -match '^(?i:ou)=') { $chain.Add($candidate) }
        if ($chain.Count -ge 40) { break }
    }
    if (-not $reached) { return ,([string[]]@()) }
    return ,$chain.ToArray()
}

function Get-DomeniaGpoStatusText {
    param($Flags)
    $value = -1
    if (($null -ne $Flags) -and (([string]$Flags) -match '^\d+$')) { $value = [int][string]$Flags }
    switch ($value) {
        0 { return 'Activée' }
        1 { return 'Paramètres utilisateur désactivés' }
        2 { return 'Paramètres ordinateur désactivés' }
        3 { return 'Toute la GPO désactivée' }
    }
    return 'État non lu'
}

function ConvertTo-DomeniaGpoAuditView {
    # Links read in AD (GpoLinksRead) and, for a workstation, the result read on it (GpoAppliedRead), kept apart by
    # Resolve-DomeniaGpoView. Adds the GPO state (flags) and the limits of what was not read (site links).
    param($Links,$Rsop=$null,[AllowEmptyString()][string]$Reader='')
    if ($null -eq $Links) { return $null }
    $names = @{}; $flags = @{}
    foreach ($gpo in @(Get-DomeniaMember $Links 'Gpos' @())) {
        $guid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $gpo 'Guid' '')
        if (-not $guid) { continue }
        $names[$guid] = [string](Get-DomeniaMember $gpo 'Name' '')
        $flags[$guid] = Get-DomeniaMember $gpo 'Flags' $null
    }
    $view = Resolve-DomeniaGpoView -Containers @(Get-DomeniaMember $Links 'Containers' @()) -Rsop $Rsop -GpoNames $names -Reader $Reader
    $rows = foreach ($row in @($view.Rows)) {
        $guid = [string]$row.Guid
        $lie = [string]$row.LieA
        $where = ''
        if ($lie) { $where = Get-DomeniaCnFromDn $lie; if ($lie -match '^(?i:dc)=') { $where = 'Domaine' } }
        $status = 'État non lu'
        if ($guid -and $flags.ContainsKey($guid)) { $status = Get-DomeniaGpoStatusText $flags[$guid] }
        [pscustomobject]@{Gpo=[string]$row.Nom;Guid=$guid;LieA=$where;LieADn=$lie;Lien=[string]$row.Lien;Force=[string]$row.Force;Heritage=[string]$row.Heritage;AttenduParLiens=[string]$row.AttenduParLiens;Resultat=[string]$row.Resultat;Etat=(Get-DomeniaFactStateLabel ([string]$row.Etat));Preuve=[string]$row.Preuve;EtatGpo=$status}
    }
    $facts = New-Object 'System.Collections.Generic.List[object]'
    foreach ($fact in @($view.Facts)) { $facts.Add($fact) }
    $facts.Add((New-DomeniaFact -Fait 'Liens de site' -Valeur 'Non lus' -Etat Inconnu -Source 'Sites Active Directory' -Limite 'Une GPO liée au site du poste sʼapplique aussi ; elle nʼapparaît ici que dans le résultat RSoP.' -Lecteur $Reader))
    if ([string](Get-DomeniaMember $Links 'NamesStatus' 'OK') -ne 'OK') { $facts.Add((New-DomeniaFact -Fait 'Noms des GPO' -Valeur 'Non lus' -Etat Indisponible -Source 'CN=Policies,CN=System' -Limite ([string](Get-DomeniaMember $Links 'NamesError' '')) -Lecteur $Reader)) }
    return [pscustomobject]@{Rows=@($rows);Facts=$facts.ToArray();AppliedProven=[bool]$view.AppliedProven;RsopState=[string]$view.RsopState;LinksComplete=[bool]$view.LinksComplete}
}

# ---------------------------------------------------------------- point 108 : controllers, time and replication
function ConvertFrom-DomeniaGeneralizedTime {
    # RootDSE currentTime ('20261015101530.0Z') or an ISO text, as UTC; $null when unreadable.
    param([AllowEmptyString()][AllowNull()][string]$Value)
    $text = ([string]$Value).Trim()
    if (-not $text) { return $null }
    $parsed = [datetime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    foreach ($format in @('yyyyMMddHHmmss.f''Z''','yyyyMMddHHmmss''Z''','yyyyMMddHHmmss.fff''Z''')) {
        if ([datetime]::TryParseExact($text,$format,[Globalization.CultureInfo]::InvariantCulture,$styles,[ref]$parsed)) { return $parsed }
    }
    return (ConvertTo-DomeniaUtcDate $text)
}

function ConvertFrom-DomeniaReplNeighbor {
    # Parses DS_REPL_NEIGHBOR values (msDS-ReplAllInboundNeighbors, one XML fragment per partner and partition).
    # A last success in 1601 means "never". No DTD and no external entity is resolved.
    param([string[]]$Values=@())
    foreach ($value in @($Values)) {
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        # A DTD is refused outright: no entity of the fragment is ever expanded.
        $settings = New-Object Xml.XmlReaderSettings
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $document = New-Object Xml.XmlDocument
        $document.XmlResolver = $null
        $reader = $null
        try {
            $reader = [Xml.XmlReader]::Create((New-Object IO.StringReader (([string]$value).Trim([char]0))),$settings)
            $document.Load($reader)
        }
        catch { continue }
        finally { if ($null -ne $reader) { $reader.Close() } }
        $node = $document.DocumentElement
        if (($null -eq $node) -or ($node.Name -ne 'DS_REPL_NEIGHBOR')) { continue }
        $get = { param([string]$name) $child = $node.SelectSingleNode($name); if ($null -ne $child) { return [string]$child.InnerText }; return '' }
        $sourceDn = & $get 'pszSourceDsaDN'
        $source = ''
        if ($sourceDn -match '(?i)CN=NTDS Settings,CN=([^,]+),') { $source = $Matches[1] }
        $success = ConvertTo-DomeniaUtcDate (& $get 'ftimeLastSyncSuccess')
        $attempt = ConvertTo-DomeniaUtcDate (& $get 'ftimeLastSyncAttempt')
        $never = (($null -eq $success) -or ($success.Year -le 1601))
        if ($never) { $success = $null }
        if (($null -ne $attempt) -and ($attempt.Year -le 1601)) { $attempt = $null }
        $result = 0L; [void][long]::TryParse((& $get 'dwLastSyncResult'),[ref]$result)
        $failures = 0L; [void][long]::TryParse((& $get 'cNumConsecutiveSyncFailures'),[ref]$failures)
        [pscustomobject]@{NamingContext=(& $get 'pszNamingContext');Source=$source;SourceDn=$sourceDn;LastSuccessUtc=$success;LastAttemptUtc=$attempt;LastResult=$result;ConsecutiveFailures=$failures;Never=$never}
    }
}

function Get-DomeniaReplResultText {
    param([long]$Code)
    $known = @{0='succès';5='accès refusé';1256='système distant non disponible';1722='serveur RPC non disponible';1753='point de terminaison introuvable';1908='contrôleur de domaine introuvable';8453='accès à la réplication refusé';8524='échec de la recherche DNS du partenaire';8545='objet déplacé ou partition différente';8606='attributs insuffisants pour créer lʼobjet';8614='durée de vie des objets supprimés dépassée'}
    if ($known.ContainsKey([int]$Code)) { return ([string]$Code + ' (' + [string]$known[[int]$Code] + ')') }
    return ('code ' + [string]$Code)
}

function Get-DomeniaDurationText {
    param([TimeSpan]$Span)
    $abs = $Span.Duration()
    if ($abs.TotalMinutes -lt 1) { return ([string][int][Math]::Round($abs.TotalSeconds) + ' s') }
    if ($abs.TotalHours -lt 1) { return ([string][int][Math]::Floor($abs.TotalMinutes) + ' min') }
    if ($abs.TotalDays -lt 2) { return ([string][int][Math]::Floor($abs.TotalHours) + ' h') }
    return ([string][int][Math]::Floor($abs.TotalDays) + ' j')
}

function Get-DomeniaAdHealthView {
    # Point 108: per controller, reachability (TCP 389 and 88), DNS (SRV records and address), time compared with
    # this computer, directory synchronisation and inbound replication, from the AdHealthRead worker (Action Probe).
    # An unreachable controller is "not read", never "down"; a refused replication read is not a replication fault.
    param($Probe,[datetime]$NowUtc=[datetime]::UtcNow,[ValidateRange(30,3600)][int]$MaxSkewSeconds=300,[ValidateRange(1,720)][int]$MaxReplicationHours=24)
    if ($null -eq $Probe) { return $null }
    $srvState = [string](Get-DomeniaMember $Probe 'SrvState' 'NotChecked')
    $srv = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @(Get-DomeniaMember $Probe 'Srv' @())) { if ($name) { [void]$srv.Add(([string]$name).Trim().TrimEnd('.')) } }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $neighborRows = New-Object 'System.Collections.Generic.List[object]'
    $probed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $pdcSkew = $null
    $pdc = [string](Get-DomeniaMember $Probe 'Pdc' '')
    $skews = @{}
    foreach ($result in @(Get-DomeniaMember $Probe 'Results' @())) {
        if ($null -eq $result) { continue }
        $dc = [string](Get-DomeniaMember $result 'Dc' '')
        [void]$probed.Add($dc)
        $reasons = New-Object 'System.Collections.Generic.List[string]'
        $notRead = $false
        $ldap = Get-DomeniaMember $result 'Ldap' $null
        $kerberos = Get-DomeniaMember $result 'Kerberos' $null
        $reach = 'LDAP 389 : ' + $(if ($ldap -eq $true) { 'oui' } elseif ($ldap -eq $false) { 'non' } else { 'non testé' }) + ' · Kerberos 88 : ' + $(if ($kerberos -eq $true) { 'oui' } elseif ($kerberos -eq $false) { 'non' } else { 'non testé' })
        if ($ldap -ne $true) { $notRead = $true; $reasons.Add('Injoignable en LDAP depuis ce poste : aucune conclusion sur son état.') }
        elseif ($kerberos -eq $false) { $reasons.Add('Port Kerberos 88 fermé depuis ce poste.') }
        $addresses = @(@(Get-DomeniaMember $result 'Addresses' @()) | Where-Object { $_ })
        $dnsText = 'Non vérifié'
        if ($srvState -eq 'Read') { if ($srv.Contains($dc)) { $dnsText = 'Présent dans les enregistrements SRV' } else { $dnsText = 'Absent des enregistrements SRV'; $reasons.Add('Absent des enregistrements SRV _ldap._tcp.dc._msdcs : les postes ne le trouvent pas par DNS.') } }
        if ($addresses.Count) { $dnsText += ' · ' + ($addresses -join ', ') }
        elseif ([string](Get-DomeniaMember $result 'DnsError' '')) { $dnsText += ' · nom non résolu'; $reasons.Add('Nom DNS du contrôleur non résolu depuis ce poste.') }
        $timeText = 'Non lue'; $syncText = 'Non lu'; $replText = 'Non lue'; $failText = ''
        $rootState = [string](Get-DomeniaMember $result 'RootDse' 'NotRead')
        if ($rootState -eq 'Read') {
            $dcTime = ConvertFrom-DomeniaGeneralizedTime ([string](Get-DomeniaMember $result 'CurrentTime' ''))
            $localTime = ConvertTo-DomeniaUtcDate (Get-DomeniaMember $result 'LocalUtc' $null)
            if (($null -ne $dcTime) -and ($null -ne $localTime)) {
                $skew = ($dcTime - $localTime).TotalSeconds
                $skews[$dc] = $skew
                $sign = '+'; if ($skew -lt 0) { $sign = '-' }
                $timeText = $sign + [string][int][Math]::Round([Math]::Abs($skew)) + ' s par rapport à ce poste'
                if ([Math]::Abs($skew) -gt $MaxSkewSeconds) { $reasons.Add('Écart dʼheure supérieur à ' + [string]$MaxSkewSeconds + ' s avec ce poste : risque dʼéchec Kerberos (à confirmer, lʼhorloge de ce poste peut aussi dériver).') }
            }
            $sync = [string](Get-DomeniaMember $result 'IsSynchronized' '')
            if ($sync -match '^(?i:true)$') { $syncText = 'Oui' }
            elseif ($sync -match '^(?i:false)$') { $syncText = 'Non'; $reasons.Add('Annuaire non synchronisé (isSynchronized faux) : le contrôleur nʼa pas terminé sa réplication initiale.') }
            $replState = [string](Get-DomeniaMember $result 'ReplState' 'NotRead')
            if ($replState -eq 'Read') {
                $neighbors = @(ConvertFrom-DomeniaReplNeighbor @(Get-DomeniaMember $result 'Neighbors' @()))
                $failing = 0; $oldest = $null; $stale = 0; $failureSum = 0L
                foreach ($neighbor in $neighbors) {
                    if ($neighbor.ConsecutiveFailures -gt 0) { $failing++; $failureSum += $neighbor.ConsecutiveFailures }
                    if ($neighbor.Never -or (($null -ne $neighbor.LastSuccessUtc) -and (($NowUtc - $neighbor.LastSuccessUtc).TotalHours -gt $MaxReplicationHours))) { $stale++ }
                    if (($null -ne $neighbor.LastSuccessUtc) -and (($null -eq $oldest) -or ($neighbor.LastSuccessUtc -lt $oldest))) { $oldest = $neighbor.LastSuccessUtc }
                    $neighborRows.Add([pscustomobject]@{
                        Controleur=$dc;Partenaire=$neighbor.Source;Partition=$neighbor.NamingContext
                        DernierSucces=$(if ($neighbor.Never) { 'Jamais' } elseif ($null -ne $neighbor.LastSuccessUtc) { $neighbor.LastSuccessUtc.ToLocalTime().ToString('dd/MM/yyyy HH:mm') } else { 'Non lu' })
                        DerniereTentative=$(if ($null -ne $neighbor.LastAttemptUtc) { $neighbor.LastAttemptUtc.ToLocalTime().ToString('dd/MM/yyyy HH:mm') } else { 'Non lue' })
                        Resultat=(Get-DomeniaReplResultText $neighbor.LastResult);Echecs=[string]$neighbor.ConsecutiveFailures
                    })
                }
                $replText = [string]$neighbors.Count + ' lien(s) entrant(s)'
                if ($null -ne $oldest) { $replText += ', plus ancien succès il y a ' + (Get-DomeniaDurationText ($NowUtc - $oldest)) }
                $failText = [string]$failureSum
                if ($failing -gt 0) { $reasons.Add([string]$failing + ' lien(s) de réplication en échec répété.') }
                if ($stale -gt 0) { $reasons.Add([string]$stale + ' lien(s) sans succès depuis plus de ' + [string]$MaxReplicationHours + ' h.') }
            }
            elseif ($replState -eq 'Empty') { $replText = 'Aucun partenaire renvoyé (contrôleur unique, ou lecture non autorisée)' }
            elseif ($replState -eq 'Error') { $replText = 'Lecture refusée ou impossible : ' + [string](Get-DomeniaMember $result 'ReplError' '') }
        }
        elseif ($rootState -eq 'Refused') { $notRead = $true; $reasons.Add('Lecture du RootDSE refusée.') }
        elseif ($ldap -eq $true) { $notRead = $true; $reasons.Add('RootDSE illisible : ' + [string](Get-DomeniaMember $result 'RootDseError' '')) }
        $verdict = 'Sans écart constaté'
        if ($notRead) { $verdict = 'Non lu' } elseif ($reasons.Count -gt 0) { $verdict = 'À vérifier' }
        $rows.Add([pscustomobject]@{Controleur=$dc;Joignable=$reach;Heure=$timeText;Synchronise=$syncText;Replication=$replText;Echecs=$failText;Dns=$dnsText;Verdict=$verdict;Detail=($reasons.ToArray() -join ' ')})
    }
    $facts = New-Object 'System.Collections.Generic.List[object]'
    if (($pdc) -and $skews.ContainsKey($pdc)) {
        foreach ($row in $rows) {
            if (($row.Controleur -ieq $pdc) -or (-not $skews.ContainsKey($row.Controleur))) { continue }
            $delta = $skews[$row.Controleur] - $skews[$pdc]
            if ([Math]::Abs($delta) -gt $MaxSkewSeconds) { $facts.Add((New-DomeniaFact -Fait ('Écart avec lʼémulateur PDC · ' + $row.Controleur) -Valeur ([string][int][Math]::Round($delta) + ' s') -Etat Estime -Source 'currentTime des RootDSE' -Limite 'Calculé à travers lʼhorloge de ce poste, à quelques secondes près.')) }
        }
    }
    switch ($srvState) {
        'Read' {
            $extra = @(foreach ($name in $srv) { if (-not $probed.Contains($name)) { $name } })
            $facts.Add((New-DomeniaFact -Fait 'Enregistrements SRV des contrôleurs' -Valeur ([string]$srv.Count + ' nom(s)' + $(if ($extra.Count) { ' dont non diagnostiqués : ' + ($extra -join ', ') } else { '' })) -Source '_ldap._tcp.dc._msdcs' -Limite 'Résolution faite depuis ce poste, avec son serveur DNS.'))
        }
        'ModuleMissing' { $facts.Add((New-DomeniaFact -Fait 'Enregistrements SRV des contrôleurs' -Valeur 'Non vérifiés' -Etat Inconnu -Source 'DNS' -Limite 'Commande Resolve-DnsName absente sur ce poste.')) }
        'Error' { $facts.Add((New-DomeniaFact -Fait 'Enregistrements SRV des contrôleurs' -Valeur 'Lecture impossible' -Etat Indisponible -Source 'DNS' -Limite ([string](Get-DomeniaMember $Probe 'SrvError' '')))) }
        default { $facts.Add((New-DomeniaFact -Fait 'Enregistrements SRV des contrôleurs' -Valeur 'Non vérifiés' -Etat Inconnu -Source 'DNS' -Limite 'Nom DNS du domaine inconnu.')) }
    }
    $all = $rows.ToArray()
    $summary = [string]$all.Count + ' contrôleur(s) diagnostiqué(s) : ' + [string]@($all | Where-Object { $_.Verdict -eq 'Sans écart constaté' }).Count + ' sans écart, ' + [string]@($all | Where-Object { $_.Verdict -eq 'À vérifier' }).Count + ' à vérifier, ' + [string]@($all | Where-Object { $_.Verdict -eq 'Non lu' }).Count + ' non lu(s). Sondes sans droit dʼadministration : aucune commande sur les contrôleurs.'
    return [pscustomobject]@{Rows=$all;Neighbors=$neighborRows.ToArray();Facts=$facts.ToArray();Summary=$summary}
}

function Get-DomeniaDcServiceView {
    # Privileged probe (DcServicesRead): directory services of each controller against the expected state. A
    # missing DNS service is normal when DNS is hosted elsewhere; one of DFSR or NtFrs replicates SYSVOL.
    param($Read)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($result in @(Get-DomeniaMember $Read 'Results' @())) {
        if ($null -eq $result) { continue }
        $dc = [string](Get-DomeniaMember $result 'Dc' '')
        $state = [string](Get-DomeniaMember $result 'State' '')
        if ($state -ne 'Read') {
            $text = 'Lecture impossible'
            if ($state -eq 'Refused') { $text = 'Lecture refusée : droits dʼadministration du contrôleur requis' }
            $rows.Add([pscustomobject]@{Controleur=$dc;Service='';Etat=$text;Demarrage='';Constat=([string](Get-DomeniaMember $result 'Message' ''))})
            continue
        }
        $services = @{}
        foreach ($service in @(Get-DomeniaMember $result 'Services' @())) { $services[[string](Get-DomeniaMember $service 'Name' '')] = $service }
        foreach ($name in @('NTDS','Netlogon','Kdc','W32Time','ADWS','DNS','DFSR','NtFrs')) {
            $service = $null
            foreach ($key in @($services.Keys)) { if ($key -ieq $name) { $service = $services[$key]; break } }
            $running = $false; $stateText = 'Absent'; $start = ''
            if ($null -ne $service) {
                $stateText = [string](Get-DomeniaMember $service 'State' '')
                $start = [string](Get-DomeniaMember $service 'StartMode' '')
                $running = ($stateText -eq 'Running')
            }
            $finding = ''
            if ($name -in @('NTDS','Netlogon','Kdc','W32Time','ADWS')) {
                if ($null -eq $service) { $finding = 'Absent : à vérifier' } elseif ($running) { $finding = 'Conforme' } else { $finding = 'Non démarré : à vérifier' }
            }
            elseif ($name -eq 'DNS') {
                if ($null -eq $service) { $finding = 'Absent : normal si le DNS est hébergé ailleurs' } elseif ($running) { $finding = 'Conforme' } else { $finding = 'Non démarré : à vérifier' }
            }
            else {
                $other = 'NtFrs'; if ($name -eq 'NtFrs') { $other = 'DFSR' }
                $otherRunning = $false
                foreach ($key in @($services.Keys)) { if (($key -ieq $other) -and ([string](Get-DomeniaMember $services[$key] 'State' '') -eq 'Running')) { $otherRunning = $true } }
                if ($running) { $finding = 'Conforme (réplication de SYSVOL)' }
                elseif ($otherRunning) { $finding = 'Non utilisé : ' + $other + ' réplique SYSVOL' }
                else { $finding = 'Aucun service de réplication de SYSVOL en cours : à vérifier' }
            }
            $display = switch ($stateText) { 'Running' { 'En cours' } 'Stopped' { 'Arrêté' } 'Absent' { 'Absent' } default { $stateText } }
            $startText = switch ($start) { 'Auto' { 'Automatique' } 'Manual' { 'Manuel' } 'Disabled' { 'Désactivé' } default { $start } }
            $rows.Add([pscustomobject]@{Controleur=$dc;Service=$name;Etat=$display;Demarrage=$startText;Constat=$finding})
        }
    }
    return ,$rows.ToArray()
}

# ---------------------------------------------------------------- point 109 : identity consistency
function ConvertTo-DomeniaIdentityScanObjects {
    # AdConsistencyScan rows in the shape of Find-DomeniaDirectoryInconsistencies (D069).
    param([object[]]$Rows=@())
    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }
        $uac = 0L; [void][long]::TryParse([string](Get-DomeniaMember $row 'Uac' ''),[ref]$uac)
        $pwd = Get-DomeniaMember $row 'PwdLastSet' $null
        [pscustomobject]@{
            Guid=[string](Get-DomeniaMember $row 'Guid' '');Name=[string](Get-DomeniaMember $row 'Name' '');Type=[string](Get-DomeniaMember $row 'Type' '')
            Mail=[string](Get-DomeniaMember $row 'Mail' '');Upn=[string](Get-DomeniaMember $row 'Upn' '');EmployeeId=[string](Get-DomeniaMember $row 'EmployeeId' '')
            Description=[string](Get-DomeniaMember $row 'Description' '');Department=[string](Get-DomeniaMember $row 'Department' '');ManagerDn=[string](Get-DomeniaMember $row 'Manager' '')
            Disabled=(($uac -band 2) -ne 0);LastLogonUtc=(ConvertTo-DomeniaUtcDate (Get-DomeniaMember $row 'LastLogon' $null));PwdLastSet=$(if ($null -eq $pwd) { 'x' } else { [string]$pwd })
        }
    }
}

function Find-DomeniaIdentityConflicts {
    # Point 109: names and identities to review in one perimeter: duplicates (mail, logon name, employee number),
    # computers sharing a DNS name, AD name and DNS name that diverge, and names the local index associates with
    # another object (recycled name or recreated object). Every finding is "À revoir": nothing is merged, renamed or
    # deleted, and observations stay with the object GUID they were read for.
    param([object[]]$Rows=@(),$LocalIndex=$null,[bool]$Truncated=$false,[datetime]$NowUtc=[datetime]::UtcNow,[ValidateRange(30,3650)][int]$StaleDays=180)
    $findings = New-Object 'System.Collections.Generic.List[object]'
    $limit = 'Périmètre choisi uniquement.'
    if ($Truncated) { $limit = 'Périmètre lu partiellement : la liste des constats est incomplète.' }
    $objects = @(ConvertTo-DomeniaIdentityScanObjects $Rows)
    # Only the duplicates of D069 concern identities; inactivity and missing information belong to point 101.
    foreach ($finding in @(Find-DomeniaDirectoryInconsistencies -Objects $objects -KnownDns @() -StaleDays $StaleDays -NowUtc $NowUtc -Truncated $Truncated | Where-Object { [string]$_.Categorie -eq 'Valeur en double' })) {
        $findings.Add([pscustomobject]@{Categorie=(Format-DomeniaLegacyFactText ([string]$finding.Categorie));Element=(Format-DomeniaLegacyFactText ([string]$finding.Element));Objets=[string]$finding.Objets;Conclusion='À revoir';Limite=(Format-DomeniaLegacyFactText ([string]$finding.Limite))})
    }
    $computers = @(@($Rows) | Where-Object { [string](Get-DomeniaMember $_ 'Type' '') -eq 'Machine' })
    $byDns = @(@($computers) | Where-Object { [string](Get-DomeniaMember $_ 'DnsHostName' '') } | Group-Object { ([string](Get-DomeniaMember $_ 'DnsHostName' '')).Trim().TrimEnd('.').ToLowerInvariant() } | Where-Object { $_.Count -gt 1 })
    foreach ($group in $byDns) {
        $findings.Add([pscustomobject]@{Categorie='Nom DNS partagé';Element=('dNSHostName : ' + $group.Name);Objets=(@($group.Group | ForEach-Object { [string](Get-DomeniaMember $_ 'Name' '') }) -join ', ');Conclusion='À revoir';Limite=($limit + ' Deux comptes ordinateur pour un même nom DNS : une adresse peut répondre pour lʼun ou lʼautre.')})
    }
    foreach ($computer in $computers) {
        $name = [string](Get-DomeniaMember $computer 'Name' '')
        $dns = [string](Get-DomeniaMember $computer 'DnsHostName' '')
        if ($name -and $dns -and ((Get-DomeniaWorkstationShortName $dns) -cne (Get-DomeniaWorkstationShortName $name))) {
            $findings.Add([pscustomobject]@{Categorie='Nom AD et nom DNS divergents';Element=($name + ' / ' + $dns);Objets=$name;Conclusion='À revoir';Limite='Renommage en cours ou compte réutilisé : vérifier lʼidentité du poste avant dʼy attribuer une lecture.'})
        }
    }
    $localState = 'NotRead'
    if ($null -ne $LocalIndex) {
        if ([bool](Get-DomeniaMember $LocalIndex 'Missing' $false)) { $localState = 'Missing' }
        elseif ([bool](Get-DomeniaMember $LocalIndex 'Busy' $false)) { $localState = 'Busy' }
        else { $localState = 'Read' }
    }
    if ($localState -eq 'Read') {
        $current = @{}
        foreach ($row in @($Rows)) {
            $guid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $row 'Guid' '')
            if (-not $guid) { continue }
            $type = [string](Get-DomeniaMember $row 'Type' '')
            $key = ''
            if ($type -eq 'Machine') { $key = 'm:' + (Get-DomeniaWorkstationShortName ([string](Get-DomeniaMember $row 'Name' ''))) }
            elseif ($type -eq 'Utilisateur') { $key = 'u:' + ([string](Get-DomeniaMember $row 'Sam' '')).ToLowerInvariant() }
            if ($key -and ($key -ne 'm:') -and ($key -ne 'u:')) { $current[$key] = [pscustomobject]@{Guid=$guid;Name=[string](Get-DomeniaMember $row 'Name' '')} }
        }
        $reported = @{}
        foreach ($pair in @(@('Computers','m:'),@('Users','u:'))) {
            foreach ($item in @(Get-DomeniaMember $LocalIndex $pair[0] @())) {
                if ($null -eq $item) { continue }
                $localGuid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $item 'object_guid' '')
                if (-not $localGuid) { continue }
                $key = ''
                if ($pair[1] -eq 'm:') { $key = 'm:' + (Get-DomeniaWorkstationShortName ([string](Get-DomeniaMember $item 'name' ''))) }
                else { $key = 'u:' + ([string](Get-DomeniaMember $item 'login' '')).ToLowerInvariant() }
                if (-not $current.ContainsKey($key)) { continue }
                $live = $current[$key]
                if ($live.Guid -ieq $localGuid) { continue }
                if ($reported.ContainsKey($key + '|' + $localGuid)) { continue }
                $reported[$key + '|' + $localGuid] = $true
                $findings.Add([pscustomobject]@{Categorie='Nom recyclé ou objet recréé';Element=($live.Name + ' : la base locale associe ce nom à un autre objet (' + $localGuid + ')');Objets=$live.Name;Conclusion='À revoir';Limite='Les relevés, associations et observations restent liés au GUID qui les a produits : rien nʼest reporté sur le nouvel objet.'})
            }
        }
    }
    $localText = switch ($localState) {
        'Read' { 'Noms comparés avec la base locale de ce poste.' }
        'Missing' { 'Base locale absente : noms recyclés non recherchés.' }
        'Busy' { 'Base locale occupée : noms recyclés non recherchés, relancez lʼanalyse.' }
        default { 'Base locale non consultée : noms recyclés non recherchés.' }
    }
    $all = $findings.ToArray()
    return [pscustomobject]@{Findings=$all;LocalIndex=$localState;Summary=([string]$all.Count + ' constat(s) à revoir sur ' + [string]@($Rows).Count + ' objet(s). ' + $localText + ' Aucune fusion ni correction automatique.')}
}

# ---------------------------------------------------------------- point 107 : stored relation history
function ConvertTo-DomeniaRelationHistoryRows {
    # Rows of the RelationHistoryRead worker (table user_machine_history), most recent first, each with the nature
    # of its proof (declared, observed, history...) and its origin. No reliability percentage is shown.
    param([object[]]$Rows=@())
    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }
        $source = [string](Get-DomeniaMember $row 'source' '')
        $when = ConvertTo-DomeniaRelationUtcDate (Get-DomeniaMember $row 'observed_at' $null)
        $badge = Get-DomeniaEvidenceBadge ([pscustomobject]@{Source=$source;When=[string](Get-DomeniaMember $row 'observed_at' '')})
        $verified = [string](Get-DomeniaMember $row 'verified_in_ad' '')
        [pscustomobject]@{
            Date=$(if ($null -ne $when) { $when.ToLocalTime().ToString('dd/MM/yyyy HH:mm') } else { 'Date illisible' })
            DateSort=$(if ($null -ne $when) { $when } else { [datetime]::MinValue })
            Utilisateur=[string](Get-DomeniaMember $row 'user_login' '');Poste=[string](Get-DomeniaMember $row 'computer' '')
            Nature=[string]$badge.Label;Badge=[string]$badge.Badge;Regle=[string]$badge.Rule;Source=$source
            VerifieAd=$(if ($verified -eq '1') { 'Oui' } elseif ($verified -eq '0') { 'Non' } else { '' })
            Details=(ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $row 'details' '')) 200)
        }
    }
}
