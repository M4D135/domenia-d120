# Points 137 and 138: explicit adapters for existing inventories (generic CSV, GLPI CSV export, osquery results) feeding
# the user/workstation association import of Relations, with identity matching, dates, source priority and a durable
# rollback batch. Pure rules: no WPF, no network, no disk. The caller reads the chosen file and gives its rows or text.
# Every record becomes the same shape (New-DomeniaInventoryRecord); nothing is written here.

function Get-DomeniaInventoryAdapters {
    # The provenance (Source) is imposed by the adapter chosen by the operator, never read from the file.
    return @(
        [pscustomobject]@{Id='Csv';Label='CSV générique';Source='Import CSV';FileFilter='CSV générique (*.csv)|*.csv';Description='Colonnes UserLogin (ou User, Username, SamAccountName) et Computer (ou ComputerName, Hostname), date ISO facultative When.'}
        [pscustomobject]@{Id='Glpi';Label='Export GLPI (CSV)';Source='Import GLPI';FileFilter='Export GLPI des ordinateurs (*.csv)|*.csv';Description='Export CSV de la liste des ordinateurs GLPI : Nom, Usager (ou Login), date du dernier inventaire ou de dernière modification, numéro de série.'}
        [pscustomobject]@{Id='Osquery';Label='Résultats osquery (JSON)';Source='Import osquery';FileFilter='Résultats osquery (*.json;*.jsonl;*.log)|*.json;*.jsonl;*.log';Description='Table logged_in_users : journal de résultats osqueryd (une ligne JSON par événement) ou tableau dʼosqueryi --json avec une colonne hostname.'}
    )
}

function Get-DomeniaInventoryAdapter {
    param([string]$Id)
    foreach ($adapter in @(Get-DomeniaInventoryAdapters)) { if ([string]$adapter.Id -ceq $Id) { return $adapter } }
    return $null
}

function Get-DomeniaInventoryLimits {
    # Explicit bounds of one import: file size read on the interface thread, records parsed, rows shown in the preview,
    # associations written per request (Queue-DomeniaLinkChanges takes 64 changes).
    return [pscustomobject]@{MaxCsvBytes=8388608;MaxJsonBytes=2097152;MaxRecords=20000;PreviewRecords=1000;BatchLimit=64;FutureToleranceMinutes=60}
}

function New-DomeniaInventoryRecord {
    param([string]$Adapter,[int]$Record,[AllowEmptyString()][string]$User='',[AllowEmptyString()][string]$Computer='',[AllowEmptyString()][string]$When='',[bool]$UnixTime=$false,[AllowEmptyString()][string]$Serial='',[AllowEmptyString()][string]$FileSource='',[AllowEmptyString()][string]$Details='',[AllowEmptyString()][string]$Reject='')
    return [pscustomobject]@{InventoryAdapter=$Adapter;Record=$Record;User=$User;Computer=$Computer;When=$When;UnixTime=$UnixTime;Serial=$Serial;FileSource=$FileSource;Details=$Details;Reject=$Reject}
}

function ConvertTo-DomeniaInventoryHeaderKey {
    # Comparable column name: lower case, without accents, apostrophes unified, separators collapsed to one space.
    param([AllowEmptyString()][string]$Name)
    $decomposed = ([string]$Name).Normalize([Text.NormalizationForm]::FormD)
    $builder = New-Object Text.StringBuilder
    foreach ($character in $decomposed.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($character) -eq [Globalization.UnicodeCategory]::NonSpacingMark) { continue }
        [void]$builder.Append($character)
    }
    $text = $builder.ToString().ToLowerInvariant()
    foreach ($apostrophe in @([string][char]0x2019,[string][char]0x02BC,[string][char]0x2018,[string][char]0x0060)) { $text = $text.Replace($apostrophe,"'") }
    return ([regex]::Replace($text,'[\s_\-]+',' ')).Trim()
}

function Get-DomeniaInventoryColumnValue {
    # First non-empty value among the aliases (compared with ConvertTo-DomeniaInventoryHeaderKey). Returns the value and
    # the column it came from, so the preview can say which column was used.
    param($Row,[string[]]$Aliases=@())
    $wanted = @($Aliases | ForEach-Object { ConvertTo-DomeniaInventoryHeaderKey $_ })
    if ($null -eq $Row) { return [pscustomobject]@{Value='';Column=''} }
    $columns = @{}
    foreach ($property in @($Row.PSObject.Properties)) {
        $key = ConvertTo-DomeniaInventoryHeaderKey ([string]$property.Name)
        if (-not $columns.ContainsKey($key)) { $columns[$key] = $property }
    }
    foreach ($key in $wanted) {
        if (-not $columns.ContainsKey($key)) { continue }
        $value = ([string]$columns[$key].Value).Trim()
        if ($value) { return [pscustomobject]@{Value=$value;Column=[string]$columns[$key].Name} }
    }
    return [pscustomobject]@{Value='';Column=''}
}

function ConvertFrom-DomeniaCsvInventoryRow {
    # Generic CSV: the historical columns of the association import (ConvertFrom-DomeniaLinkCsvRow, CO-08).
    param($Row,[int]$Record)
    $v = ConvertFrom-DomeniaLinkCsvRow $Row
    return (New-DomeniaInventoryRecord -Adapter 'Csv' -Record $Record -User ([string]$v.User) -Computer ([string]$v.Computer) -When ([string]$v.When) -FileSource ([string]$v.FileSource) -Details ([string]$v.Details))
}

function ConvertFrom-DomeniaGlpiRow {
    # GLPI computer list export. The login comes from Usager / Login (filled by the inventory agent); the User column
    # of GLPI may hold a display name ("Dupont Alice"), which is never taken as a login.
    param($Row,[int]$Record)
    $computer = Get-DomeniaInventoryColumnValue $Row @('Nom','Name','Ordinateur','Computer','Nom de lʼordinateur')
    $login = Get-DomeniaInventoryColumnValue $Row @('Usager','Alternate username','Login','Identifiant','Nom dʼusager','Nom dʼutilisateur','User login','Contact')
    $reject = ''
    if (-not $login.Value) {
        $login = Get-DomeniaInventoryColumnValue $Row @('Utilisateur','User')
        if ($login.Value -match '\s') { $reject = 'Nom affiché (« ' + $login.Value + ' ») : identifiant de connexion absent. Exportez la colonne Usager ou Login de GLPI.' }
    }
    $when = Get-DomeniaInventoryColumnValue $Row @('Dernière date dʼinventaire','Date du dernier inventaire','Dernier inventaire','Last inventory date','Last inventory','Last inventory update','Dernière modification','Last update','Date de modification')
    $serial = Get-DomeniaInventoryColumnValue $Row @('Numéro de série','Serial number','Serial')
    $entity = Get-DomeniaInventoryColumnValue $Row @('Entité','Entity')
    $details = ''
    if ($serial.Value) { $details = 'Numéro de série GLPI : ' + $serial.Value + '.' }
    if ($entity.Value) { $details = ($details + ' Entité GLPI : ' + $entity.Value + '.').Trim() }
    if ($when.Column) { $details = ($details + ' Date lue dans « ' + $when.Column + ' ».').Trim() }
    return (New-DomeniaInventoryRecord -Adapter 'Glpi' -Record $Record -User $login.Value -Computer $computer.Value -When $when.Value -Serial $serial.Value -Details $details -Reject $reject)
}

function Get-DomeniaOsqueryMember {
    param($InputObject,[string[]]$Names=@())
    if ($null -eq $InputObject) { return '' }
    foreach ($name in $Names) {
        $property = $InputObject.PSObject.Properties[$name]
        if (($null -ne $property) -and ($null -ne $property.Value) -and ([string]$property.Value).Trim()) { return ([string]$property.Value).Trim() }
    }
    return ''
}

function ConvertFrom-DomeniaOsqueryText {
    # osquery logged_in_users results: osqueryd results log (one JSON object per line, "columns" for an event or
    # "snapshot" for a snapshot) or the JSON array of osqueryi --json. A "removed" event is the end of a session and
    # is skipped; session types without a user (boot, runlevel, listen...) are skipped too. Bounded by -MaxRecords.
    param([AllowEmptyString()][string]$Text,[int]$MaxRecords=20000)
    $records = New-Object 'System.Collections.Generic.List[object]'
    $rejected = New-Object 'System.Collections.Generic.List[object]'
    $skipped = 0
    $trimmed = ([string]$Text).Trim()
    $format = 'ResultsLog'
    $entries = New-Object 'System.Collections.Generic.List[object]'
    if (-not $trimmed) { return [pscustomobject]@{Format='';Records=@();Rejected=@();Skipped=0;Truncated=$false} }
    if ($trimmed.StartsWith('[')) {
        $format = 'Array'
        $parsed = $null
        try { $parsed = ConvertFrom-Json -InputObject $trimmed -ErrorAction Stop } catch { $rejected.Add([pscustomobject]@{Line=1;Reason='Tableau JSON illisible : ' + $_.Exception.Message}) }
        $line = 0
        foreach ($item in @($parsed)) { foreach ($row in $item) { $line++; $entries.Add([pscustomobject]@{Line=$line;Entry=$row}) } }
    }
    else {
        $lines = $trimmed -split "`r?`n"
        $bulk = $null
        $kept = @($lines | Where-Object { ([string]$_).Trim() })
        # One parse for the whole log; the line by line parse only runs to name the unreadable lines.
        try { $bulk = ConvertFrom-Json -InputObject ('[' + ($kept -join ',') + ']') -ErrorAction Stop } catch { $bulk = $null }
        if ($null -ne $bulk) {
            $index = 0
            foreach ($item in @($bulk)) { foreach ($row in $item) { $index++; $entries.Add([pscustomobject]@{Line=$index;Entry=$row}) } }
        }
        else {
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $current = ([string]$lines[$i]).Trim()
                if (-not $current) { continue }
                try { $entries.Add([pscustomobject]@{Line=($i + 1);Entry=(ConvertFrom-Json -InputObject $current -ErrorAction Stop)}) }
                catch { $rejected.Add([pscustomobject]@{Line=($i + 1);Reason='Ligne JSON illisible.'}) }
            }
        }
    }
    $sessionTypes = @('user','active','connected','disconnected','idle')
    $truncated = $false
    $record = 0
    foreach ($wrapper in $entries) {
        $entry = $wrapper.Entry
        if ($null -eq $entry) { continue }
        $action = Get-DomeniaOsqueryMember $entry @('action')
        if ($action -ceq 'removed') { $skipped++; continue }
        $hostName = Get-DomeniaOsqueryMember $entry @('hostIdentifier','host_identifier')
        $eventTime = Get-DomeniaOsqueryMember $entry @('unixTime')
        $rows = @()
        $columns = $entry.PSObject.Properties['columns']
        $snapshot = $entry.PSObject.Properties['snapshot']
        if (($null -ne $columns) -and ($null -ne $columns.Value)) { $rows = @($columns.Value) }
        elseif (($null -ne $snapshot) -and ($null -ne $snapshot.Value)) { $rows = @($snapshot.Value) }
        else { $rows = @($entry) }
        foreach ($row in $rows) {
            if ($null -eq $row) { continue }
            $type = Get-DomeniaOsqueryMember $row @('type')
            if (($type) -and ($sessionTypes -notcontains $type.ToLowerInvariant())) { $skipped++; continue }
            if ($records.Count -ge $MaxRecords) { $truncated = $true; break }
            $record++
            $computer = Get-DomeniaOsqueryMember $row @('hostname','computer_name','host_identifier','hostIdentifier')
            if (-not $computer) { $computer = $hostName }
            $user = Get-DomeniaOsqueryMember $row @('user','username')
            $loginTime = Get-DomeniaOsqueryMember $row @('time')
            $when = $eventTime
            $details = 'Relevé osquery'
            if ($loginTime -match '^[1-9]\d{8,10}$') { $when = $loginTime; $details = 'Ouverture de session osquery' }
            $details += ', ligne ' + $wrapper.Line + $(if ($format -eq 'Array') { ' du tableau' } else { ' du journal' }) + '.'
            if ($type) { $details += ' Type de session : ' + $type + '.' }
            $reject = ''
            if (-not $computer) { $reject = 'Poste absent : ajoutez la colonne hostname (table system_info) ou importez le journal de résultats osqueryd.' }
            $records.Add((New-DomeniaInventoryRecord -Adapter 'Osquery' -Record $record -User $user -Computer $computer -When $when -UnixTime $true -Details $details -Reject $reject))
        }
        if ($truncated) { break }
    }
    return [pscustomobject]@{Format=$format;Records=$records.ToArray();Rejected=$rejected.ToArray();Skipped=$skipped;Truncated=$truncated}
}

function ConvertTo-DomeniaInventoryWhen {
    # Date of one record. ISO dates (an offset or Z wins, otherwise local time, as every relation date) and Unix seconds
    # are read; any other text ("08/10/2026" is ambiguous) stays unread and the import date is used. A date in the
    # future beyond the tolerance is never trusted: it would win the priority of the file.
    param([AllowEmptyString()][string]$Value,[bool]$UnixTime=$false,$NowUtc=$null)
    $now = $null
    if ($null -ne $NowUtc) { $now = ConvertTo-DomeniaUtcDate $NowUtc }
    if ($null -eq $now) { $now = [datetime]::UtcNow }
    $limits = Get-DomeniaInventoryLimits
    $text = ([string]$Value).Trim()
    $utc = $null
    if (-not $text) { return [pscustomobject]@{Text='';Ticks=0L;Note=''} }
    if ($UnixTime) {
        $seconds = 0L
        if (($text -match '^\d{1,11}$') -and ([long]::TryParse($text,[ref]$seconds)) -and ($seconds -gt 0)) { $utc = ([datetime]::new(1970,1,1,0,0,0,[DateTimeKind]::Utc)).AddSeconds($seconds) }
    }
    elseif ($text -match '^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2}(\.\d+)?)?)?(Z|[+-]\d{2}:?\d{2})?$') { $utc = ConvertTo-DomeniaRelationUtcDate $text }
    if ($null -eq $utc) { return [pscustomobject]@{Text=$text;Ticks=0L;Note=''} }
    if ($utc -gt $now.AddMinutes($limits.FutureToleranceMinutes)) { return [pscustomobject]@{Text='';Ticks=0L;Note=('Date du fichier dans le futur (' + $text + ') : ignorée, date de lʼimport retenue.')} }
    return [pscustomobject]@{Text=$utc.ToString('o',[Globalization.CultureInfo]::InvariantCulture);Ticks=$utc.Ticks;Note=''}
}

function Select-DomeniaLatestInventoryRecords {
    # An osquery log repeats a workstation at every event: only the most recent records of each workstation reach the
    # preview (equal dates are all kept, to be shown as a conflict). Older records are counted, never silently lost.
    param([object[]]$Records=@(),$NowUtc=$null)
    $list = @($Records)
    $keys = New-Object 'string[]' $list.Count
    $ticks = New-Object 'long[]' $list.Count
    $best = @{}
    for ($i = 0; $i -lt $list.Count; $i++) {
        $keys[$i] = ConvertTo-DomeniaRelationComputerKey ([string]$list[$i].Computer)
        $ticks[$i] = [long](ConvertTo-DomeniaInventoryWhen -Value ([string]$list[$i].When) -UnixTime ([bool]$list[$i].UnixTime) -NowUtc $NowUtc).Ticks
        if (-not $keys[$i]) { continue }
        if ((-not $best.ContainsKey($keys[$i])) -or ($ticks[$i] -gt [long]$best[$keys[$i]])) { $best[$keys[$i]] = $ticks[$i] }
    }
    $kept = New-Object 'System.Collections.Generic.List[object]'
    $dropped = 0
    for ($i = 0; $i -lt $list.Count; $i++) {
        if ((-not $keys[$i]) -or ($ticks[$i] -eq [long]$best[$keys[$i]])) { $kept.Add($list[$i]) } else { $dropped++ }
    }
    return [pscustomobject]@{Records=$kept.ToArray();Dropped=$dropped}
}

function Test-DomeniaInventoryIdentity {
    # Identity matching before the local index lookup. A qualified name of another domain is rejected instead of being
    # silently cut to its first part: DOMAINE\compte must name this domain (NetBIOS or first DNS label), compte@suffixe
    # must use the DNS name of the domain, and a FQDN workstation must belong to it. Without a known domain the
    # qualifier cannot be checked and the record is rejected rather than guessed.
    param([AllowEmptyString()][string]$User='',[AllowEmptyString()][string]$Computer='',[AllowEmptyString()][string]$DomainDns='',[AllowEmptyString()][string]$Netbios='')
    $dns = ([string]$DomainDns).Trim().TrimEnd('.').ToLowerInvariant()
    $short = ([string]$Netbios).Trim().ToLowerInvariant()
    $label = if ($dns.Contains('.')) { $dns.Substring(0,$dns.IndexOf('.')) } else { $dns }
    $u = ([string]$User).Trim()
    $c = ([string]$Computer).Trim().TrimEnd('.')
    $slash = [string][char]92
    if ($u.Contains($slash)) {
        $authority = $u.Substring(0,$u.IndexOf($slash)).Trim().ToLowerInvariant()
        if ((-not $dns) -and (-not $short)) { return [pscustomobject]@{Reject=('Compte qualifié (' + $u + ') : domaine courant inconnu, correspondance non vérifiable.')} }
        if (($authority -cne $short) -and ($authority -cne $label) -and ($authority -cne $dns)) { return [pscustomobject]@{Reject=('Compte dʼun autre domaine (' + $u + ') : ligne non importée.')} }
    }
    elseif ($u.Contains('@')) {
        $suffix = $u.Substring($u.IndexOf('@') + 1).Trim().ToLowerInvariant()
        if (-not $dns) { return [pscustomobject]@{Reject=('Compte au format UPN (' + $u + ') : domaine courant inconnu, correspondance non vérifiable.')} }
        if ($suffix -cne $dns) { return [pscustomobject]@{Reject=('Suffixe UPN différent du domaine (' + $u + ') : correspondance non vérifiable, ligne non importée.')} }
    }
    if ($c.Contains('.') -and ($c -notmatch '^\d{1,3}(\.\d{1,3}){3}$')) {
        $suffix = $c.Substring($c.IndexOf('.') + 1).ToLowerInvariant()
        if (-not $dns) { return [pscustomobject]@{Reject=('Nom DNS complet (' + $c + ') : domaine courant inconnu, correspondance non vérifiable.')} }
        if ($suffix -cne $dns) { return [pscustomobject]@{Reject=('Poste dʼun autre domaine DNS (' + $c + ') : ligne non importée.')} }
    }
    if ($c -match '^\d{1,3}(\.\d{1,3}){3}$') { return [pscustomobject]@{Reject=('Adresse IP (' + $c + ') au lieu dʼun nom de poste : ligne non importée.')} }
    # osquery may identify a host by its UUID (host_identifier=uuid): never taken for a workstation name.
    if ($c -match '^\{?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}?$') { return [pscustomobject]@{Reject=('Identifiant matériel (' + $c + ') au lieu dʼun nom de poste : configurez host_identifier=hostname dans osquery ou ajoutez la colonne hostname.')} }
    return [pscustomobject]@{Reject=''}
}

function Resolve-DomeniaInventoryPriority {
    # Source priority inside one file, per workstation key: the most recent dated record wins; a dated record wins over
    # an undated one; the same account again is a duplicate; two accounts with no date to decide between them (same
    # date or no date) are a conflict and none of them is imported. Input: objects with Record, ComputerKey, UserKey,
    # Ticks (0 = undated), in file order. Output: one decision per input, same order.
    param([object[]]$Items=@())
    $list = @($Items)
    $decisions = New-Object 'object[]' $list.Count
    $groups = @{}
    for ($i = 0; $i -lt $list.Count; $i++) {
        $item = $list[$i]
        $decisions[$i] = [pscustomobject]@{Kind='Retenue';Reason=''}
        $key = [string]$item.ComputerKey
        if ((-not $key) -or (-not [string]$item.UserKey)) { continue }
        if (-not $groups.ContainsKey($key)) { $groups[$key] = New-Object 'System.Collections.Generic.List[int]' }
        $groups[$key].Add($i)
    }
    foreach ($key in @($groups.Keys)) {
        $members = @($groups[$key])
        if ($members.Count -lt 2) { continue }
        $best = [long]0
        foreach ($index in $members) { if ([long]$list[$index].Ticks -gt $best) { $best = [long]$list[$index].Ticks } }
        $top = @($members | Where-Object { [long]$list[$_].Ticks -eq $best })
        $topUsers = @($top | ForEach-Object { [string]$list[$_].UserKey } | Select-Object -Unique)
        if ($topUsers.Count -gt 1) {
            $names = ($topUsers -join ', ')
            $why = if ($best -gt 0) { 'même date' } else { 'aucune date' }
            foreach ($index in $members) {
                if ($top -contains $index) { $decisions[$index] = [pscustomobject]@{Kind='Conflit';Reason=('Conflit dans le fichier : le poste désigne ' + $names + ' (' + $why + ' pour les départager). Aucune de ces lignes nʼest importée.')} }
                else { $decisions[$index] = [pscustomobject]@{Kind='Remplacée';Reason='Poste présent ailleurs dans le fichier avec une date plus récente, en conflit : ligne non importée.'} }
            }
            continue
        }
        $winner = $top[0]
        foreach ($index in $members) {
            if ($index -eq $winner) { continue }
            $where = if ($list[$winner].Record -lt $list[$index].Record) { 'plus haut' } else { 'plus bas' }
            if ([string]$list[$index].UserKey -ceq [string]$list[$winner].UserKey) { $decisions[$index] = [pscustomobject]@{Kind='Doublon';Reason=('Poste déjà présent ' + $where + ' dans le fichier avec le même compte.')} }
            else { $decisions[$index] = [pscustomobject]@{Kind='Remplacée';Reason=('Poste déjà présent ' + $where + ' dans le fichier avec une date plus récente (compte ' + [string]$list[$winner].UserKey + ') : ligne non importée.')} }
        }
    }
    return ,$decisions
}

function New-DomeniaImportBatchId {
    # Rollback batch of one import: UTC minute of the preview and the first 8 hex digits of its identifier.
    param([string]$Id,$NowUtc=$null)
    $now = $null
    if ($null -ne $NowUtc) { $now = ConvertTo-DomeniaUtcDate $NowUtc }
    if ($null -eq $now) { $now = [datetime]::UtcNow }
    $hex = ([string]$Id).ToLowerInvariant() -replace '[^0-9a-f]',''
    if ($hex.Length -lt 8) { $hex = ($hex + [guid]::NewGuid().ToString('N')) }
    return ($now.ToString('yyyyMMdd''T''HHmm',[Globalization.CultureInfo]::InvariantCulture) + 'Z-' + $hex.Substring(0,8))
}

function Get-DomeniaImportBatchToken {
    # Batch identifier written at the start of the details of an imported association, '' when absent.
    param([AllowEmptyString()][AllowNull()][string]$Details)
    $match = [regex]::Match([string]$Details,'^Lot dʼimport (\d{8}T\d{4}Z-[0-9a-f]{8})\.')
    if ($match.Success) { return $match.Groups[1].Value }
    return ''
}

function Get-DomeniaImportBatches {
    # Durable rollback (point 138): the batches still present in the stored associations, most recent first. A batch is
    # identified by its token, never by a file name; associations imported before batches existed have none.
    param([object[]]$Links=@())
    $byId = @{}
    foreach ($link in @($Links)) {
        if ($null -eq $link) { continue }
        $source = [string](Get-DomeniaMember $link 'Source' '')
        if ($source -notmatch '^Import ') { continue }
        $details = [string](Get-DomeniaMember $link 'Details' '')
        $token = Get-DomeniaImportBatchToken $details
        if (-not $token) { continue }
        if (-not $byId.ContainsKey($token)) {
            $file = ''
            $fileMatch = [regex]::Match($details,'Importé depuis (.+?)(, enregistrement \d+)?\.( |$)')
            if ($fileMatch.Success) { $file = $fileMatch.Groups[1].Value }
            $stamp = [datetime]::ParseExact($token.Substring(0,13),'yyyyMMdd''T''HHmm',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
            $byId[$token] = [pscustomobject]@{Id=$token;ImportedUtc=$stamp.ToString('o',[Globalization.CultureInfo]::InvariantCulture);FileName=$file;Source=$source;Relations=(New-Object 'System.Collections.Generic.List[object]')}
        }
        $byId[$token].Relations.Add($link)
    }
    return @($byId.Values | Sort-Object -Property @{Expression={[string]$_.Id};Descending=$true} | ForEach-Object { [pscustomobject]@{Id=$_.Id;ImportedUtc=$_.ImportedUtc;FileName=$_.FileName;Source=$_.Source;Relations=$_.Relations.ToArray()} })
}
