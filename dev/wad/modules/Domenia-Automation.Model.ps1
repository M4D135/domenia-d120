# Points 139 and 140: local automation contract (Domenia.Automation/1) and offline diagnostic folder
# (Domenia.OfflineDossier/1). Pure rules: no WPF, no network, no disk. wad/Domenia-Automate.ps1 reads the local SQLite
# store read-only and writes the files; the Atelier calls the same script through the OfflineDossier worker.
# No listening port, no service: one explicit command, one answer, then the process or the task ends.

function Get-DomeniaAutomationContract {
    # Versioned commands. A command never writes the store, never binds to the directory and never contacts a workstation.
    $perimeter = 'Périmètre : -OrganizationalUnit (DN dʼune OU), -Computers (noms) ou -Guids (GUID de postes).'
    return [pscustomobject]@{
        Contract='Domenia.Automation/1'
        Version=1
        Transport='Ligne de commande locale ; aucun port réseau, aucun service, aucune écriture dans la base.'
        ExitCodes=[pscustomobject]@{Succes=0;Usage=2;Base=3;Refus=4;Ecriture=5}
        Commands=@(
            [pscustomobject]@{Name='version';Kind='Lecture';Description='Contrat, version et commandes disponibles.';Perimeter=$false;Formats=@('Json')}
            [pscustomobject]@{Name='etat';Kind='Lecture';Description='État daté de la base locale : identité, révision, synchronisations et volumes par famille.';Perimeter=$false;Formats=@('Json')}
            [pscustomobject]@{Name='postes';Kind='Lecture';Description=('Postes de lʼindex local. ' + $perimeter);Perimeter=$true;Formats=@('Json','Csv')}
            [pscustomobject]@{Name='observations';Kind='Lecture';Description=('Dernières observations enregistrées (présence, console, inventaire, sondes), datées, champs secrets exclus. ' + $perimeter);Perimeter=$true;Formats=@('Json')}
            [pscustomobject]@{Name='associations';Kind='Lecture';Description=('Associations utilisateur ↔ poste mémorisées. ' + $perimeter);Perimeter=$true;Formats=@('Json','Csv')}
            [pscustomobject]@{Name='requetes';Kind='Lecture';Description='Requêtes enregistrées non archivées (définition et empreinte).';Perimeter=$false;Formats=@('Json')}
            [pscustomobject]@{Name='dossier';Kind='Export';Description=('Dossier de diagnostic hors ligne daté : état, postes, observations, associations et requêtes du périmètre choisi, avec empreintes SHA-256. ' + $perimeter);Perimeter=$true;Formats=@('Dossier')}
        )
    }
}

function Get-DomeniaAutomationLimits {
    # Explicit bounds of one command; a bound reached is always reported (Truncated), never hidden.
    return [pscustomobject]@{DefaultRows=1000;MaxRows=5000;MaxNames=500;MaxPayloadChars=262144;MaxDossierChars=67108864;MaxOuLength=2048}
}

function ConvertTo-DomeniaAutomationSqlText {
    # SQLite string literal. Every value placed in a statement comes from a validated request and goes through here.
    param([AllowEmptyString()][AllowNull()][string]$Value)
    return ("'" + ([string]$Value).Replace("'","''") + "'")
}

function ConvertTo-DomeniaAutomationLikeText {
    # LIKE pattern: the value escaped with '!' (ESCAPE '!'), after an unescaped -Prefix (the wildcards of the caller).
    param([AllowEmptyString()][AllowNull()][string]$Value,[AllowEmptyString()][string]$Prefix='')
    $escaped = ([string]$Value).Replace('!','!!').Replace('%','!%').Replace('_','!_')
    return (ConvertTo-DomeniaAutomationSqlText ($Prefix + $escaped))
}

function ConvertTo-DomeniaAutomationDn {
    # Comparable OU distinguished name: spaces around separators removed, lower case. '' when it is not an OU, a
    # container or a domain naming context (a perimeter is a branch of the directory, never a single object).
    param([AllowEmptyString()][AllowNull()][string]$Dn)
    $text = ([regex]::Replace([regex]::Replace(([string]$Dn).Trim(),'\s*,\s*',','),'\s*=\s*','='))
    if (-not $text) { return '' }
    if ($text.Length -gt (Get-DomeniaAutomationLimits).MaxOuLength) { return '' }
    if ($text -notmatch '^(?i)((OU|CN)=[^,=]+,)*(DC=[^,=]+)(,DC=[^,=]+)*$') { return '' }
    if ($text -notmatch '^(?i)(OU|DC)=') { return '' }
    return $text.ToLowerInvariant()
}

function Test-DomeniaAutomationRequest {
    # Validates one command line. Returns the normalised request, or the French reason and the exit code of a refusal.
    param([AllowEmptyString()][string]$Command='',[AllowEmptyString()][string]$DatabasePath='',[AllowEmptyString()][string]$OrganizationalUnit='',[string[]]$Computers=@(),[string[]]$Guids=@(),[AllowEmptyString()][string]$Family='',[int]$Limit=0,[AllowEmptyString()][string]$Format='Json',[AllowEmptyString()][string]$OutputPath='',[string[]]$Sections=@())
    $refuse = { param($Why,$Code) [pscustomobject]@{Valid=$false;Error=$Why;ExitCode=$Code;Request=$null} }
    $contract = Get-DomeniaAutomationContract
    $limits = Get-DomeniaAutomationLimits
    $name = ([string]$Command).Trim().ToLowerInvariant()
    $definition = @($contract.Commands | Where-Object { $_.Name -ceq $name })
    if ($definition.Count -ne 1) { return (& $refuse ('Commande inconnue : « ' + $Command + ' ». Commandes : ' + (@($contract.Commands | ForEach-Object { $_.Name }) -join ', ') + '.') 2) }
    $definition = $definition[0]
    $formatName = ([string]$Format).Trim()
    if (-not $formatName) { $formatName = [string]@($definition.Formats)[0] }
    $formatMatch = @($definition.Formats | Where-Object { $_ -ieq $formatName })
    if ($formatMatch.Count -ne 1) { return (& $refuse ('Format « ' + $Format + ' » non pris en charge par ' + $name + ' (' + (@($definition.Formats) -join ', ') + ').') 2) }
    if (($name -ne 'version') -and (-not ([string]$DatabasePath).Trim())) { return (& $refuse 'Base locale requise : -DatabasePath <fichier .db>.' 2) }
    if (($name -ne 'version') -and ([string]$DatabasePath).Trim() -notmatch '(?i)\.db$') { return (& $refuse 'La base locale doit être un fichier .db.' 2) }
    $ou = ''
    if (([string]$OrganizationalUnit).Trim()) {
        $ou = ConvertTo-DomeniaAutomationDn $OrganizationalUnit
        if (-not $ou) { return (& $refuse ('OU non reconnue : « ' + $OrganizationalUnit + ' » (OU=…,DC=… attendu).') 2) }
    }
    $names = @($Computers | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim().TrimEnd('$') } | Where-Object { $_ } | ForEach-Object { if ($_.Contains('.')) { $_.Substring(0,$_.IndexOf('.')) } else { $_ } } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
    foreach ($computer in $names) { if ($computer -notmatch '^[a-z0-9][a-z0-9_-]{0,62}$') { return (& $refuse ('Nom de poste invalide : « ' + $computer + ' ».') 2) } }
    $guidList = @($Guids | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim().Trim('{','}') } | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
    foreach ($guid in $guidList) { if ($guid -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { return (& $refuse ('GUID invalide : « ' + $guid + ' ».') 2) } }
    if (($names.Count + $guidList.Count) -gt $limits.MaxNames) { return (& $refuse ([string]$limits.MaxNames + ' postes au plus par commande : choisissez une OU ou découpez la liste.') 2) }
    $kinds = 0
    if ($ou) { $kinds++ }
    if ($names.Count) { $kinds++ }
    if ($guidList.Count) { $kinds++ }
    if ([bool]$definition.Perimeter -and ($kinds -eq 0)) { return (& $refuse ('Périmètre requis pour ' + $name + ' : -OrganizationalUnit, -Computers ou -Guids. Aucune commande ne parcourt tout le domaine implicitement.') 4) }
    if ($kinds -gt 1) { return (& $refuse 'Un seul périmètre à la fois : OU, noms ou GUID.' 2) }
    $familyName = ([string]$Family).Trim()
    if ($familyName -and ($familyName -notmatch '^(Presence|Console|Inventory|Probe:[A-Za-z0-9_.-]{1,128})$')) { return (& $refuse ('Famille dʼobservation inconnue : « ' + $Family + ' » (Presence, Console, Inventory ou Probe:<sonde>).') 2) }
    $rows = $Limit
    if ($rows -le 0) { $rows = $limits.DefaultRows }
    if ($rows -gt $limits.MaxRows) { return (& $refuse ('Limite de ' + $limits.MaxRows + ' lignes au plus.') 2) }
    $wanted = @('etat','postes','observations','associations','requetes')
    $chosen = @($Sections | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
    foreach ($section in $chosen) { if ($wanted -notcontains $section) { return (& $refuse ('Section de dossier inconnue : « ' + $section + ' ».') 2) } }
    if (-not $chosen.Count) { $chosen = $wanted }
    if (($name -eq 'dossier') -and (-not ([string]$OutputPath).Trim())) { return (& $refuse 'Dossier de destination requis : -OutputPath <dossier parent>.' 2) }
    $kind = 'Aucun'
    if ($ou) { $kind = 'OU' } elseif ($names.Count) { $kind = 'Noms' } elseif ($guidList.Count) { $kind = 'Guids' }
    return [pscustomobject]@{Valid=$true;Error='';ExitCode=0;Request=[pscustomobject]@{Command=$name;Format=[string]$formatMatch[0];DatabasePath=([string]$DatabasePath).Trim();Perimeter=[pscustomobject]@{Kind=$kind;OrganizationalUnit=$ou;Computers=$names;Guids=$guidList};Family=$familyName;Limit=$rows;OutputPath=([string]$OutputPath).Trim();Sections=$chosen}}
}

function Get-DomeniaAutomationPerimeterSql {
    # WHERE clause on ad_objects (alias o) for the computers of the perimeter.
    param($Perimeter)
    $machine = "o.object_type='Machine'"
    switch ([string]$Perimeter.Kind) {
        'OU' {
            $ou = [string]$Perimeter.OrganizationalUnit
            return ($machine + " AND lower(o.distinguished_name) LIKE " + (ConvertTo-DomeniaAutomationLikeText -Value $ou -Prefix '%,') + " ESCAPE '!'")
        }
        'Noms' { return ($machine + ' AND lower(o.name) IN (' + ((@($Perimeter.Computers) | ForEach-Object { ConvertTo-DomeniaAutomationSqlText $_ }) -join ',') + ')') }
        'Guids' { return ($machine + ' AND lower(o.object_guid) IN (' + ((@($Perimeter.Guids) | ForEach-Object { ConvertTo-DomeniaAutomationSqlText $_ }) -join ',') + ')') }
        default { return $machine }
    }
}

function Get-DomeniaAutomationQuery {
    # Read-only statements of the contract. One row more than the limit is asked, to report a truncation honestly.
    # Secret tables (secret_state) and LAPS columns are never read.
    param([Parameter(Mandatory=$true)][ValidateSet('Tables','Schema','StoreState','Sync','ObjectCounts','ObservationCounts','LinkCounts','RecipeCount','Computers','Observations','Links','Recipes')][string]$Kind,$Request=$null)
    $limit = 0
    if ($null -ne $Request) { $limit = [int]$Request.Limit + 1 }
    switch ($Kind) {
        'Tables' { return "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;" }
        'Schema' { return "SELECT key,value FROM schema_info ORDER BY key;" }
        'StoreState' { return "SELECT store_id,domain_dn,revision FROM domenia_store_state WHERE id=1;" }
        'Sync' { return "SELECT scope,server,base_dn,last_sync,item_count FROM sync_state ORDER BY scope;" }
        'ObjectCounts' { return "SELECT object_type,count(*) AS n,max(synced_at) AS last_sync FROM ad_objects GROUP BY object_type ORDER BY object_type;" }
        'ObservationCounts' { return "SELECT family,count(*) AS n,sum(CASE WHEN status='Success' THEN 1 ELSE 0 END) AS success,max(success_at) AS last_success,max(attempt_at) AS last_attempt FROM domenia_observations GROUP BY family ORDER BY family;" }
        'LinkCounts' { return "SELECT source,count(*) AS n,max(observed_at) AS last_observed FROM user_machine_links GROUP BY source ORDER BY source;" }
        'RecipeCount' { return "SELECT count(*) AS n,max(updated_utc) AS last_update FROM domenia_query_recipes WHERE archived=0;" }
        'Computers' {
            $where = Get-DomeniaAutomationPerimeterSql $Request.Perimeter
            return ("SELECT o.object_guid,o.name,o.distinguished_name,o.state,o.description,o.last_logon,o.when_changed,o.synced_at,o.source_dc,f.os_version,f.when_created,f.pwd_last_set,f.read_at FROM ad_objects o LEFT JOIN ad_computer_facts f ON lower(f.object_guid)=lower(o.object_guid) WHERE " + $where + " ORDER BY lower(o.name) LIMIT " + $limit + ";")
        }
        'Observations' {
            $where = Get-DomeniaAutomationPerimeterSql $Request.Perimeter
            $family = ''
            if ([string]$Request.Family) { $family = ' AND b.family=' + (ConvertTo-DomeniaAutomationSqlText ([string]$Request.Family)) }
            return ("SELECT b.object_guid,b.family,b.dn,b.definition_hash,b.attempt_at,b.status,b.error,b.success_at,b.payload FROM domenia_observations b WHERE lower(b.object_guid) IN (SELECT lower(o.object_guid) FROM ad_objects o WHERE " + $where + ")" + $family + " ORDER BY lower(b.dn),b.family LIMIT " + $limit + ";")
        }
        'Links' {
            $where = Get-DomeniaAutomationPerimeterSql $Request.Perimeter
            return ("SELECT l.computer,l.user_login,l.source,l.confidence,l.verified_in_ad,l.observed_at,l.details,l.user_guid,l.computer_guid,l.user_dn,l.computer_dn FROM user_machine_links l WHERE lower(l.computer_key) IN (SELECT lower(o.name) FROM ad_objects o WHERE " + $where + ") OR lower(l.computer_guid) IN (SELECT lower(o.object_guid) FROM ad_objects o WHERE " + $where + ") ORDER BY lower(l.computer) LIMIT " + $limit + ";")
        }
        'Recipes' { return ("SELECT id,name,category,revision,definition_version,definition_json,definition_sha256,created_utc,updated_utc FROM domenia_query_recipes WHERE archived=0 ORDER BY name_fold,id LIMIT " + $limit + ";") }
    }
}

function Test-DomeniaDiagnosticSecretName {
    # A field whose name says it carries a secret is never exported, whatever its value.
    param([AllowEmptyString()][AllowNull()][string]$Name)
    $text = ([string]$Name).Trim()
    if (-not $text) { return $false }
    # LAPS fields are all left out, metadata included (expiry, scheme): the readme says so. pwdLastSet is a date, kept.
    return ($text -match '(?i)(password|passwd|pwd(?!_?last_?set)|secret|token|credential|ms-mcs-admpwd|laps|bitlocker.*(key|recovery)|recoverypassword|recoverykey|msfve|privatekey|apikey|bearer|cookie)')
}

function Protect-DomeniaDiagnosticValue {
    # Copy of a value without the fields named as secrets, recursively. Returns the copy and the excluded field names
    # (paths), so the dossier can say what was left out. Depth and size are bounded by the caller.
    param($Value,[string]$Path='',[int]$Depth=0)
    $excluded = New-Object 'System.Collections.Generic.List[string]'
    if ($Depth -gt 32) { $excluded.Add($Path + ' (profondeur)'); return [pscustomobject]@{Value=$null;Excluded=$excluded.ToArray()} }
    if ($null -eq $Value) { return [pscustomobject]@{Value=$null;Excluded=@()} }
    if (($Value -is [string]) -or ($Value -is [ValueType])) { return [pscustomobject]@{Value=$Value;Excluded=@()} }
    if ($Value -is [Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in @($Value.Keys)) {
            $child = $Path + '.' + [string]$key
            if (Test-DomeniaDiagnosticSecretName ([string]$key)) { $excluded.Add($child.TrimStart('.')); continue }
            $inner = Protect-DomeniaDiagnosticValue -Value $Value[$key] -Path $child -Depth ($Depth + 1)
            $copy[[string]$key] = $inner.Value
            foreach ($item in @($inner.Excluded)) { $excluded.Add($item) }
        }
        return [pscustomobject]@{Value=[pscustomobject]$copy;Excluded=$excluded.ToArray()}
    }
    if ($Value -is [Collections.IEnumerable]) {
        $items = New-Object 'System.Collections.Generic.List[object]'
        $index = 0
        foreach ($element in $Value) {
            $inner = Protect-DomeniaDiagnosticValue -Value $element -Path ($Path + '[' + $index + ']') -Depth ($Depth + 1)
            $items.Add($inner.Value)
            foreach ($item in @($inner.Excluded)) { $excluded.Add($item) }
            $index++
        }
        return [pscustomobject]@{Value=$items.ToArray();Excluded=$excluded.ToArray()}
    }
    $copy = [ordered]@{}
    foreach ($property in @($Value.PSObject.Properties)) {
        $child = $Path + '.' + [string]$property.Name
        if (Test-DomeniaDiagnosticSecretName ([string]$property.Name)) { $excluded.Add($child.TrimStart('.')); continue }
        $inner = Protect-DomeniaDiagnosticValue -Value $property.Value -Path $child -Depth ($Depth + 1)
        $copy[[string]$property.Name] = $inner.Value
        foreach ($item in @($inner.Excluded)) { $excluded.Add($item) }
    }
    return [pscustomobject]@{Value=[pscustomobject]$copy;Excluded=$excluded.ToArray()}
}

function ConvertTo-DomeniaAutomationItems {
    # Rows of one statement in the published shape of the contract. An observation payload is parsed, cleaned of its
    # secret fields and bounded; an unreadable payload stays unread (never an empty success).
    param([Parameter(Mandatory=$true)][ValidateSet('Computers','Observations','Links','Recipes')][string]$Kind,[object[]]$Rows=@())
    $limits = Get-DomeniaAutomationLimits
    $items = New-Object 'System.Collections.Generic.List[object]'
    $excluded = New-Object 'System.Collections.Generic.List[string]'
    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }
        switch ($Kind) {
            'Computers' {
                $items.Add([pscustomobject]@{Guid=[string]$row.object_guid;Nom=[string]$row.name;DN=[string]$row.distinguished_name;Etat=[string]$row.state;Description=[string]$row.description;DerniereConnexion=[string]$row.last_logon;ModifieAD=[string]$row.when_changed;SynchroniseUtc=[string]$row.synced_at;Controleur=[string]$row.source_dc;Systeme=[string]$row.os_version;CreeAD=[string]$row.when_created;MotDePasseMachineDefini=[string]$row.pwd_last_set;FaitsLusUtc=[string]$row.read_at})
            }
            'Observations' {
                $data = $null;$note = ''
                $payload = [string]$row.payload
                if ($payload.Length -gt $limits.MaxPayloadChars) { $note = 'Données de ' + $payload.Length + ' caractères non reprises (limite ' + $limits.MaxPayloadChars + ').' }
                elseif ($payload) {
                    try {
                        $parsed = ConvertFrom-Json -InputObject $payload -ErrorAction Stop
                        $clean = Protect-DomeniaDiagnosticValue -Value $parsed -Path ([string]$row.family)
                        $data = $clean.Value
                        foreach ($item in @($clean.Excluded)) { $excluded.Add([string]$row.object_guid + ':' + $item) }
                    } catch { $note = 'Données enregistrées illisibles : non reprises.' }
                }
                $items.Add([pscustomobject]@{Guid=[string]$row.object_guid;DN=[string]$row.dn;Famille=[string]$row.family;Statut=[string]$row.status;TentativeUtc=[string]$row.attempt_at;ReussiteUtc=[string]$row.success_at;Erreur=[string]$row.error;Definition=[string]$row.definition_hash;Donnees=$data;Note=$note})
            }
            'Links' {
                $items.Add([pscustomobject]@{Poste=[string]$row.computer;Compte=[string]$row.user_login;Source=[string]$row.source;Confiance=$row.confidence;VerifieAD=([string]$row.verified_in_ad -eq '1');ObserveUtc=[string]$row.observed_at;Details=[string]$row.details;CompteGuid=[string]$row.user_guid;PosteGuid=[string]$row.computer_guid;CompteDN=[string]$row.user_dn;PosteDN=[string]$row.computer_dn})
            }
            'Recipes' {
                $definition = $null;$note = ''
                try { $definition = (Protect-DomeniaDiagnosticValue -Value (ConvertFrom-Json -InputObject ([string]$row.definition_json) -ErrorAction Stop)).Value } catch { $note = 'Définition illisible : non reprise.' }
                $items.Add([pscustomobject]@{Id=[string]$row.id;Nom=[string]$row.name;Categorie=[string]$row.category;Revision=$row.revision;VersionDefinition=$row.definition_version;Empreinte=[string]$row.definition_sha256;CreeeUtc=[string]$row.created_utc;ModifieeUtc=[string]$row.updated_utc;Definition=$definition;Note=$note})
            }
        }
    }
    return [pscustomobject]@{Items=$items.ToArray();Excluded=$excluded.ToArray()}
}

function New-DomeniaAutomationEnvelope {
    # Published answer of one command: the contract, the date, the source and its revision, the perimeter, the items and
    # whether a bound was reached. The date is the time of the read, not a proof that the data is still current.
    param([string]$Command,[object[]]$Items=@(),$Source=$null,$Request=$null,[bool]$Truncated=$false,[string[]]$Excluded=@(),[string[]]$Notes=@(),$NowUtc=$null)
    $now = $null
    if ($null -ne $NowUtc) { $now = ConvertTo-DomeniaUtcDate $NowUtc }
    if ($null -eq $now) { $now = [datetime]::UtcNow }
    $perimeter = $null;$limit = 0
    if ($null -ne $Request) { $perimeter = $Request.Perimeter; $limit = [int]$Request.Limit }
    return [pscustomobject]@{
        Contract='Domenia.Automation/1'
        Command=$Command
        GeneratedUtc=$now.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        Source=$Source
        Perimeter=$perimeter
        Limit=$limit
        Count=@($Items).Count
        Truncated=$Truncated
        ExcludedFields=@($Excluded)
        Notes=@($Notes)
        Items=@($Items)
        Meaning='Lecture de la base locale de Domenia : données datées, non revérifiées dans Active Directory ni sur les postes.'
    }
}

function ConvertTo-DomeniaAutomationCsv {
    # Same CSV as the exports of Domenia (CO-04): semicolon, quoted cells, formula-like cells neutralised.
    param([object[]]$Items=@(),[string[]]$Columns=@())
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $quote = { param($Text) $value = [string]$Text; if ($value -match '^[=+\-@\t\r]') { $value = "'" + $value }; '"' + $value.Replace('"','""') + '"' }
    $lines.Add((@($Columns | ForEach-Object { & $quote $_ }) -join ';'))
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        $cells = foreach ($column in $Columns) { $property = $item.PSObject.Properties[$column]; if ($null -eq $property) { & $quote '' } else { & $quote $property.Value } }
        $lines.Add((@($cells) -join ';'))
    }
    return (($lines.ToArray() -join "`r`n") + "`r`n")
}

function Get-DomeniaOfflineDossierName {
    # Folder name of a dossier: Domenia-Diagnostic-<sujet>-AAAAMMJJ-HHmm, letters, digits, dot, dash and underscore only.
    param([string]$Subject='',$NowUtc=$null)
    $now = $null
    if ($null -ne $NowUtc) { $now = ConvertTo-DomeniaUtcDate $NowUtc }
    if ($null -eq $now) { $now = [datetime]::UtcNow }
    $clean = [regex]::Replace(([string]$Subject).Trim(),'[^\p{L}\p{Nd}._-]+','-').Trim('-','.')
    if ($clean.Length -gt 60) { $clean = $clean.Substring(0,60).Trim('-','.') }
    if (-not $clean) { $clean = 'perimetre' }
    return ('Domenia-Diagnostic-' + $clean + '-' + $now.ToString('yyyyMMdd-HHmm',[Globalization.CultureInfo]::InvariantCulture))
}

function New-DomeniaOfflineDossier {
    # Point 139: the files of one offline diagnostic folder, as texts. Every section is an envelope of the automation
    # contract; the manifest lists the files with their SHA-256 (UTF-8 without BOM, as written) and what was excluded.
    # -Sections: ordered dictionary name -> envelope. Nothing secret is added here: the envelopes were cleaned before.
    param([Parameter(Mandatory=$true)][Collections.IDictionary]$Sections,$Request=$null,$Source=$null,[string]$Build='',$NowUtc=$null)
    $now = $null
    if ($null -ne $NowUtc) { $now = ConvertTo-DomeniaUtcDate $NowUtc }
    if ($null -eq $now) { $now = [datetime]::UtcNow }
    $limits = Get-DomeniaAutomationLimits
    $files = New-Object 'System.Collections.Generic.List[object]'
    $summary = New-Object 'System.Collections.Generic.List[object]'
    $total = 0L
    foreach ($name in @($Sections.Keys)) {
        $envelope = $Sections[$name]
        $text = ConvertTo-Json -InputObject $envelope -Depth 32
        $total += $text.Length
        if ($total -gt $limits.MaxDossierChars) { throw ('Dossier supérieur à ' + [int]($limits.MaxDossierChars / 1MB) + ' Mio de texte : réduisez le périmètre ou la limite.') }
        $files.Add([pscustomobject]@{Name=([string]$name + '.json');Text=$text})
        $summary.Add([pscustomobject]@{Section=[string]$name;Elements=[int]$envelope.Count;Tronque=[bool]$envelope.Truncated;ChampsExclus=@($envelope.ExcludedFields).Count})
    }
    $perimeterText = 'aucun'
    if (($null -ne $Request) -and ($null -ne $Request.Perimeter)) {
        switch ([string]$Request.Perimeter.Kind) {
            'OU' { $perimeterText = 'OU ' + [string]$Request.Perimeter.OrganizationalUnit }
            'Noms' { $perimeterText = [string]@($Request.Perimeter.Computers).Count + ' poste(s) nommé(s)' }
            'Guids' { $perimeterText = [string]@($Request.Perimeter.Guids).Count + ' poste(s) choisi(s)' }
        }
    }
    $readme = @(
        'Dossier de diagnostic hors ligne Domenia'
        ('Créé le ' + $now.ToString('yyyy-MM-dd HH:mm',[Globalization.CultureInfo]::InvariantCulture) + ' UTC' + $(if ($Build) { ' par la version ' + $Build } else { '' }) + '.')
        ('Périmètre choisi : ' + $perimeterText + '.')
        ''
        'Contenu : état de la base locale, postes, dernières observations enregistrées, associations et requêtes enregistrées,'
        'selon les sections retenues. Chaque fichier JSON suit le contrat Domenia.Automation/1 et porte sa date de lecture.'
        ''
        'Ce que ce dossier ne prouve pas : les données viennent de la base locale de Domenia ; elles ne sont revérifiées ni'
        'dans Active Directory ni sur les postes. Un relevé ancien reste ancien, une absence de relevé reste inconnue.'
        ''
        'Exclus : mots de passe, clés de récupération BitLocker, mots de passe et métadonnées LAPS, jetons et tout champ nommé'
        'comme un secret (liste dans manifeste.json), table des secrets de la base, journaux bruts et comptes de connexion.'
        'Le dossier contient des noms de postes, de comptes et des chemins internes : conservez-le sur un support protégé.'
        ''
        'Intégrité : SHA256SUMS.txt donne lʼempreinte de chaque fichier (Get-FileHash -Algorithm SHA256).'
    ) -join "`r`n"
    $files.Add([pscustomobject]@{Name='LISEZMOI.txt';Text=($readme + "`r`n")})
    $entries = @($files | ForEach-Object { [pscustomobject]@{Fichier=$_.Name;Sha256=(Get-DomeniaTextHash $_.Text);Caracteres=$_.Text.Length} })
    $manifest = [pscustomobject]@{
        Contract='Domenia.OfflineDossier/1'
        CreatedUtc=$now.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        Build=$Build
        Source=$Source
        Perimeter=$(if ($null -ne $Request) { $Request.Perimeter } else { $null })
        Sections=$summary.ToArray()
        Files=$entries
        Excluded=@('Mots de passe et secrets','Clés de récupération BitLocker','Mots de passe et métadonnées LAPS','Table secret_state','Détails dʼannuaire bruts (domenia_details)','Journaux bruts','Comptes de connexion et jetons')
        Network='Aucun accès réseau pour produire ce dossier.'
    }
    $manifestText = ConvertTo-Json -InputObject $manifest -Depth 16
    $files.Add([pscustomobject]@{Name='manifeste.json';Text=$manifestText})
    $sums = @($files | ForEach-Object { (Get-DomeniaTextHash $_.Text).ToLowerInvariant() + '  ' + $_.Name }) -join "`r`n"
    $files.Add([pscustomobject]@{Name='SHA256SUMS.txt';Text=($sums + "`r`n")})
    return [pscustomobject]@{Files=$files.ToArray();Manifest=$manifest}
}

function Get-DomeniaOfflineDossierPerimeter {
    # Point 139: the perimeter chosen in the Atelier, from what is on screen: the selected workstation, the workstations
    # of the displayed results (bounded) or the selected OU. Never the whole domain implicitly.
    param([ValidateSet('Selected','Displayed','Branch')][string]$Scope='Selected',$SelectedObject=$null,[object[]]$DisplayedRows=@(),[AllowEmptyString()][string]$BranchDn='',[AllowEmptyString()][string]$DomainDn='')
    $limits = Get-DomeniaAutomationLimits
    $fail = { param($Why) [pscustomobject]@{Valid=$false;Error=$Why;Kind='';Guids=@();OrganizationalUnit='';Label='';Count=0;Truncated=$false} }
    switch ($Scope) {
        'Selected' {
            if (($null -eq $SelectedObject) -or ([string](Get-DomeniaMember $SelectedObject 'Type' '') -cne 'Machine')) { return (& $fail 'Sélectionnez un poste, ou choisissez les postes affichés ou la branche sélectionnée.') }
            $guid = ConvertTo-DomeniaGuidText (Get-DomeniaMemberValue $SelectedObject 'Guid' '')
            if (-not $guid) { return (& $fail 'Poste sélectionné sans GUID connu : relisez sa fiche avant de préparer le dossier.') }
            $name = [string](Get-DomeniaMember $SelectedObject 'Name' '')
            return [pscustomobject]@{Valid=$true;Error='';Kind='Guids';Guids=@($guid.ToLowerInvariant());OrganizationalUnit='';Label=$(if ($name) { $name } else { 'poste sélectionné' });Count=1;Truncated=$false}
        }
        'Displayed' {
            $guids = New-Object 'System.Collections.Generic.List[string]'
            $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            $truncated = $false
            foreach ($row in @($DisplayedRows)) {
                if (($null -eq $row) -or ([string](Get-DomeniaMember $row 'Type' '') -cne 'Machine')) { continue }
                $guid = ConvertTo-DomeniaGuidText (Get-DomeniaMemberValue $row 'Guid' '')
                if ((-not $guid) -or (-not $seen.Add($guid))) { continue }
                if ($guids.Count -ge $limits.MaxNames) { $truncated = $true; break }
                $guids.Add($guid.ToLowerInvariant())
            }
            if (-not $guids.Count) { return (& $fail 'Aucun poste identifié dans les résultats affichés.') }
            $label = [string]$guids.Count + ' poste(s) affiché(s)'
            if ($truncated) { $label += ', limité aux ' + $limits.MaxNames + ' premiers' }
            return [pscustomobject]@{Valid=$true;Error='';Kind='Guids';Guids=$guids.ToArray();OrganizationalUnit='';Label=$label;Count=$guids.Count;Truncated=$truncated}
        }
        'Branch' {
            $ou = ConvertTo-DomeniaAutomationDn $BranchDn
            if ((-not $ou) -or ($ou -notmatch '^ou=')) { return (& $fail 'Sélectionnez une OU dans lʼarborescence : la branche courante nʼest pas une OU.') }
            $label = 'OU ' + ($ou.Split(',')[0] -replace '^ou=','')
            return [pscustomobject]@{Valid=$true;Error='';Kind='OU';Guids=@();OrganizationalUnit=$ou;Label=$label;Count=0;Truncated=$false}
        }
    }
}
