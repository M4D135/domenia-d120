# Shared pure helpers for the Domenia rule modules. No WPF, no network, no disk access.
# Dot-sourced first by the closed loader: every other *.Model.ps1 may rely on these functions.

function Get-DomeniaMember {
    # Safe member read for PSCustomObject, hashtable and .NET objects. Never throws on a missing member.
    # Calling convention (relied on by every rule module): the value is written to the pipeline, so a collection is
    # enumerated; wrap the call in @() to read a collection, cast to read a scalar. Get-DomeniaMemberValue returns the
    # value itself (one-element collection, byte[] GUID or SID) when the exact object is needed.
    param($InputObject,[string]$Name,$Default=$null)
    if ($null -eq $InputObject -or [string]::IsNullOrEmpty($Name)) { return $Default }
    if ($InputObject -is [Collections.IDictionary]) {
        if (Test-DomeniaDictionaryKey $InputObject $Name) { return $InputObject[$Name] }
        return $Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-DomeniaMemberValue {
    # Same lookup as Get-DomeniaMember, but the value is returned as one object: a one-element collection,
    # an AD value collection or a byte[] (GUID, SID) is not unrolled. Do not wrap the call in @().
    param($InputObject,[string]$Name,$Default=$null)
    if ($null -eq $InputObject -or [string]::IsNullOrEmpty($Name)) { return ,$Default }
    if ($InputObject -is [Collections.IDictionary]) {
        if (Test-DomeniaDictionaryKey $InputObject $Name) { return ,$InputObject[$Name] }
        return ,$Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return ,$Default }
    return ,$property.Value
}

function Test-DomeniaDictionaryKey {
    # IDictionary.Contains is explicit on generic dictionaries: it throws under Windows PowerShell 5.1.
    param([Collections.IDictionary]$Dictionary,[string]$Name)
    try { return [bool]$Dictionary.Contains($Name) }
    catch { try { return [bool]$Dictionary.ContainsKey($Name) } catch { return $false } }
}

function Get-DomeniaCollectionItems {
    # Materialises any non-text collection (array, AD value collection, list) as object[]; a scalar gives one item.
    # byte[] is a single AD value (GUID, SID), never a collection of values.
    param($Value)
    if ($null -eq $Value) { return ,([object[]]@()) }
    if (($Value -is [string]) -or ($Value -is [byte[]])) { return ,([object[]]@(,$Value)) }
    if ($Value -is [Collections.IEnumerable]) {
        $items = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $Value) { $items.Add($item) }
        return ,($items.ToArray())
    }
    return ,([object[]]@(,$Value))
}

function ConvertFrom-DomeniaLargeInteger {
    # Reads an ADSI IADsLargeInteger (DirectoryEntry large-integer attribute) as Int64. $null when not one.
    param($Value)
    if ($null -eq $Value -or $Value -is [ValueType] -or $Value -is [string] -or $Value -is [Collections.IEnumerable]) { return $null }
    try {
        $type = $Value.GetType()
        $high = $type.InvokeMember('HighPart',[Reflection.BindingFlags]::GetProperty,$null,$Value,$null)
        $low = $type.InvokeMember('LowPart',[Reflection.BindingFlags]::GetProperty,$null,$Value,$null)
        if ($null -eq $high -or $null -eq $low) { return $null }
        return (([long][int]$high) * 4294967296L) + (([long][int]$low) -band 0xFFFFFFFFL)
    } catch { return $null }
}

function Test-DomeniaGuidText {
    param([AllowNull()][string]$Value)
    $parsed = [guid]::Empty
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return ([guid]::TryParse($Value,[ref]$parsed) -and $parsed -ne [guid]::Empty)
}

function ConvertTo-DomeniaGuidText {
    # Accepts a Guid, a 16-byte array (even when PowerShell unrolled it) or a text. Returns '' when unusable.
    param($Value)
    if ($null -eq $Value) { return '' }
    try {
        if ($Value -is [guid]) { if ($Value -eq [guid]::Empty) { return '' }; return $Value.ToString('D') }
        if ($Value -is [byte[]]) { if ($Value.Length -ne 16) { return '' }; return ([guid]::new($Value)).ToString('D') }
        if (($Value -isnot [string]) -and ($Value -is [Collections.IEnumerable]) -and ($Value -isnot [array])) {
            # AD value collection or list: same rules as an array (one element, or sixteen boxed bytes).
            return (ConvertTo-DomeniaGuidText (Get-DomeniaCollectionItems $Value))
        }
        if ($Value -is [array]) {
            # A one-element collection holding the byte array, or sixteen boxed bytes.
            if ($Value.Count -eq 1) { return (ConvertTo-DomeniaGuidText $Value[0]) }
            if ($Value.Count -ne 16) { return '' }
            $bytes = New-Object byte[] 16
            for ($i = 0; $i -lt 16; $i++) {
                $number = 0L
                if (-not [long]::TryParse([string]$Value[$i],[ref]$number) -or $number -lt 0 -or $number -gt 255) { return '' }
                $bytes[$i] = [byte]$number
            }
            return ([guid]::new($bytes)).ToString('D')
        }
        $parsed = [guid]::Empty
        if ([guid]::TryParse([string]$Value,[ref]$parsed) -and $parsed -ne [guid]::Empty) { return $parsed.ToString('D') }
    } catch { if (${function:Write-DomeniaRuleSwallowed}) { Write-DomeniaRuleSwallowed 'Common' 'ConvertTo-DomeniaGuidText' $_ } }
    return ''
}

function ConvertTo-DomeniaSidText {
    param($Value)
    if ($null -eq $Value) { return '' }
    try {
        if ($Value -is [Security.Principal.SecurityIdentifier]) { return $Value.Value }
        if ($Value -is [byte[]]) { return (New-Object Security.Principal.SecurityIdentifier -ArgumentList @($Value,0)).Value }
        if (($Value -isnot [string]) -and ($Value -is [Collections.IEnumerable])) {
            $items = Get-DomeniaCollectionItems $Value
            if ($items.Count -eq 1) { return (ConvertTo-DomeniaSidText $items[0]) }
            # A binary SID unrolled by the pipeline: 8 to 68 boxed bytes, revision 1.
            if ($items.Count -ge 8 -and $items.Count -le 68) {
                $bytes = New-Object byte[] $items.Count
                for ($i = 0; $i -lt $items.Count; $i++) {
                    $number = 0L
                    if (-not [long]::TryParse([string]$items[$i],[ref]$number) -or $number -lt 0 -or $number -gt 255) { return '' }
                    $bytes[$i] = [byte]$number
                }
                if ($bytes[0] -ne 1 -or (8 + 4 * [int]$bytes[1]) -ne $bytes.Length) { return '' }
                return (New-Object Security.Principal.SecurityIdentifier -ArgumentList @($bytes,0)).Value
            }
            return ''
        }
        $text = ([string]$Value).Trim()
        if ($text -match '^S-1-\d+(-\d+){1,14}$') { return $text.ToUpperInvariant() }
    } catch { if (${function:Write-DomeniaRuleSwallowed}) { Write-DomeniaRuleSwallowed 'Common' 'ConvertTo-DomeniaSidText' $_ } }
    return ''
}

function Get-DomeniaTextHash {
    param([AllowEmptyString()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$Text)))).Replace('-','') }
    finally { $sha.Dispose() }
}

function ConvertTo-DomeniaUtcDate {
    # Returns a UTC DateTime or $null. Accepts DateTime, ISO text, and an AD FILETIME (Int64 ticks since 1601).
    # A text or DateTime without offset is UTC by default; -AssumeLocal reads it as local time instead (CO-29: the
    # relation dates written before RC1.14 as local "yyyy-MM-dd HH:mm:ss"). An explicit offset or Z always wins.
    param($Value,[switch]$AssumeLocal)
    if ($null -eq $Value) { return $null }
    try {
        if ($Value -is [byte[]]) { return $null }
        if (($Value -isnot [string]) -and ($Value -is [Collections.IEnumerable])) {
            # One AD value in a collection is read; several values never pick one silently.
            $items = Get-DomeniaCollectionItems $Value
            if ($items.Count -ne 1) { return $null }
            return (ConvertTo-DomeniaUtcDate $items[0] -AssumeLocal:$AssumeLocal)
        }
        $large = ConvertFrom-DomeniaLargeInteger $Value
        if ($null -ne $large) { $Value = [long]$large }
        if ($Value -is [datetime]) {
            if ($Value.Kind -eq [DateTimeKind]::Unspecified) {
                if ($AssumeLocal) { return [datetime]::SpecifyKind($Value,[DateTimeKind]::Local).ToUniversalTime() }
                return [datetime]::SpecifyKind($Value,[DateTimeKind]::Utc)
            }
            return $Value.ToUniversalTime()
        }
        if ($Value -is [long] -or $Value -is [int] -or $Value -is [decimal] -or $Value -is [double]) {
            $ticks = [long]$Value
            # 0 and 0x7FFFFFFFFFFFFFFF both mean "never" for AD time attributes.
            if ($ticks -le 0 -or $ticks -eq [long]::MaxValue) { return $null }
            return [datetime]::FromFileTimeUtc($ticks)
        }
        $text = ([string]$Value).Trim()
        if (-not $text) { return $null }
        $number = 0L
        if ($text -match '^\d{12,19}$' -and [long]::TryParse($text,[ref]$number)) {
            if ($number -le 0 -or $number -eq [long]::MaxValue) { return $null }
            return [datetime]::FromFileTimeUtc($number)
        }
        $parsed = [datetime]::MinValue
        $assumed = [Globalization.DateTimeStyles]::AssumeUniversal
        if ($AssumeLocal) { $assumed = [Globalization.DateTimeStyles]::AssumeLocal }
        $styles = $assumed -bor [Globalization.DateTimeStyles]::AdjustToUniversal
        if ([datetime]::TryParse($text,[Globalization.CultureInfo]::InvariantCulture,$styles,[ref]$parsed)) { return $parsed }
    } catch { if (${function:Write-DomeniaRuleSwallowed}) { Write-DomeniaRuleSwallowed 'Common' 'ConvertTo-DomeniaUtcDate' $_ } }
    return $null
}

function Get-DomeniaFeatureFlag {
    # Reads Features.<Name> from the application configuration when the core is loaded.
    # PF-10: no command lookup. The answer is kept per configuration object: Load-AppConfig builds a new one, so a
    # flag is read once per configuration generation instead of once per call (timers, every task start).
    param([Parameter(Mandatory=$true)][string]$Name,[bool]$Default=$true)
    $config = $null; $cache = $null
    try { $config = $script:Config } catch { $config = $null }
    $key = $Name + '|' + [string]$Default
    if ($null -ne $config) {
        try { $cache = $script:DomeniaFeatureFlagCache } catch { $cache = $null }
        if (($null -eq $cache) -or (-not [object]::ReferenceEquals($cache.Config,$config))) {
            $cache = [pscustomobject]@{Config=$config;Values=@{}}
            $script:DomeniaFeatureFlagCache = $cache
        }
        if ($cache.Values.ContainsKey($key)) { return [bool]$cache.Values[$key] }
    }
    $result = $Default
    try {
        $value = Get-CfgValue 'Features' $Name $Default
        if ($value -is [bool]) { $result = $value }
        else {
            $text = ([string]$value).Trim()
            if ($text -match '^(?i:true|1|oui|yes|on)$') { $result = $true }
            elseif ($text -match '^(?i:false|0|non|no|off)$') { $result = $false }
        }
    } catch { $result = $Default }
    if ($null -ne $cache) { $cache.Values[$key] = [bool]$result }
    return [bool]$result
}

function New-DomeniaFact {
    # One explainable statement: what was seen, where, under which account, and what it does not prove.
    param(
        [Parameter(Mandatory=$true)][string]$Fait,
        [AllowEmptyString()][string]$Valeur='',
        [AllowEmptyString()][string]$Source='',
        [AllowEmptyString()][string]$Limite='',
        [AllowEmptyString()][string]$Hypothese='',
        [ValidateSet('Constate','Estime','Inconnu','Refuse','Indisponible')][string]$Etat='Constate',
        $Date=$null,
        [AllowEmptyString()][string]$Lecteur=''
    )
    $when = ConvertTo-DomeniaUtcDate $Date
    $stamp = ''
    if ($null -ne $when) { $stamp = $when.ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss') }
    return [pscustomobject]@{Fait=$Fait;Valeur=$Valeur;Etat=$Etat;Source=$Source;Limite=$Limite;Hypothese=$Hypothese;Date=$stamp;Lecteur=$Lecteur}
}

function ConvertTo-DomeniaFlatText {
    # Single-line, bounded text for status lines and tool tips.
    param([AllowNull()][string]$Text,[int]$Maximum=240)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $flat = ($Text -replace '\s+',' ').Trim()
    if ($Maximum -gt 3 -and $flat.Length -gt $Maximum) { return $flat.Substring(0,$Maximum - 1) + [string][char]0x2026 }
    return $flat
}


function Split-DomeniaRawDn {
    # Canonical LDAP DN from AD, as stored in SQLite. Search.Model separately handles
    # legacy quoted display paths; raw quotes are not a scope delimiter here.
    # A comma separates RDNs only after an even number of backslashes. Keep escaped
    # bytes verbatim: decoding before splitting would turn a label into a new scope.
    param([AllowEmptyString()][string]$Dn)
    if (-not $Dn) { return @() }
    $start=0; $slashes=0
    for ($i=0; $i -lt $Dn.Length; $i++) {
        $c=$Dn[$i]
        if ($c -eq ',' -and ($slashes % 2) -eq 0) { $Dn.Substring($start,$i-$start); $start=$i+1 }
        if ($c -eq [char]92) { $slashes++ } else { $slashes=0 }
    }
    $Dn.Substring($start)
}

function Get-DomeniaRawDnParent {
    param([AllowEmptyString()][string]$Dn)
    $parts=@(Split-DomeniaRawDn $Dn)
    if ($parts.Count -lt 2) { return '' }
    return $parts[1..($parts.Count-1)] -join ','
}

function ConvertFrom-DomeniaDnLabel {
    # Display only. Consecutive hexadecimal escapes encode UTF-8 bytes, not UTF-16
    # characters. Invalid bytes stay visible verbatim instead of losing identity.
    param([AllowEmptyString()][string]$Value)
    $result=New-Object Text.StringBuilder
    $utf8=New-Object Text.UTF8Encoding($false,$true)
    for ($i=0; $i -lt $Value.Length; $i++) {
        if ($Value[$i] -ne [char]92 -or $i+1 -ge $Value.Length) { [void]$result.Append($Value[$i]); continue }
        $start=$i; $bytes=New-Object 'System.Collections.Generic.List[byte]'
        while ($i+2 -lt $Value.Length -and $Value[$i] -eq [char]92 -and $Value.Substring($i+1,2) -match '^[0-9A-Fa-f]{2}$') {
            $bytes.Add([Convert]::ToByte($Value.Substring($i+1,2),16)); $i+=3
        }
        if ($bytes.Count) {
            try { [void]$result.Append($utf8.GetString($bytes.ToArray())) }
            catch { [void]$result.Append($Value.Substring($start,$i-$start)) }
            $i--; continue
        }
        $i++; [void]$result.Append($Value[$i])
    }
    return $result.ToString()
}

function Get-DomeniaDnSite {
    # Same bucket for the SQL parent aggregate and the per-object query adapter.
    # Scope comparison stays on raw RDNs; only the final human label is decoded.
    param([AllowEmptyString()][string]$ParentDn,[AllowEmptyString()][string]$Scope='')
    $parts=@(Split-DomeniaRawDn $ParentDn); $scopeParts=@(Split-DomeniaRawDn $Scope)
    $relativeCount=$parts.Count
    if ($scopeParts.Count -and $parts.Count -ge $scopeParts.Count) {
        $matches=$true; $offset=$parts.Count-$scopeParts.Count
        for ($i=0; $i -lt $scopeParts.Count; $i++) {
            if (-not [string]::Equals($parts[$offset+$i],$scopeParts[$i],[StringComparison]::OrdinalIgnoreCase)) { $matches=$false; break }
        }
        if ($matches) { $relativeCount=$offset }
    }
    $site=''
    for ($i=0; $i -lt $relativeCount; $i++) {
        if ($parts[$i].StartsWith('OU=',[StringComparison]::OrdinalIgnoreCase)) {
            $site=$parts[$i].Substring(3)
            if (-not $Scope) { break }
        }
    }
    if ($site) { return ConvertFrom-DomeniaDnLabel $site }
    if ($Scope) { return '(directement dans l OU)' }
    return 'Hors OU'
}

# ---------------------------------------------------------------- P-CD-09 swallowed errors
function Add-DomeniaSwallowedEntry {
    # P-CD-09: pure part of the trace of an error that a catch block deliberately does not rethrow. The core wrapper
    # Write-DomeniaSwallowed (Domenia-Core.ps1, defined before any script code) calls it and writes the returned line to
    # the technical journal; worker code that embeds this module may call it directly and keep the ring only.
    # Every call adds an entry to a bounded in-memory ring (Get-DomeniaSwallowedEntries, oldest first). At most once a
    # minute per category and operation, the call returns the journal line due, with the number of occurrences folded
    # in since the previous line: [pscustomobject]@{Line;Entry}. Nothing is returned when the line is sampled out or for
    # a reentry. Entry.Journal is Unavailable until the caller records the outcome (Logged), or Sampled, or Reentry.
    # A sampled-out entry keeps the category, operation and exception type, not the message (masked once per line due).
    # Texts are masked by -Mask (the core passes Protect-DomeniaLogText) or else Protect-DomeniaSecretText
    # (Access.Model, resolved at call time); with neither rule the exception message is not kept. Bounded: 200 entries,
    # 300 characters per message, 512 sampling keys. No journal, no WPF, no disk; never throws.
    # A call made while another is running (-Reentry from the core wrapper, or a masking rule that traces its own
    # failure) keeps the category, operation and exception type only, without calling a masking rule again.
    param(
        [AllowNull()][AllowEmptyString()][string]$Category='',
        [AllowNull()][AllowEmptyString()][string]$Operation='',
        [AllowNull()]$ErrorRecord=$null,
        [AllowNull()]$Now=$null,
        [AllowNull()][scriptblock]$Mask=$null,
        [switch]$Reentry
    )
    try {
        $state = $null
        try { $state = $script:DomeniaSwallowedState } catch { $state = $null }
        if ($null -eq $state) {
            $state = [pscustomobject]@{
                Entries=(New-Object 'System.Collections.Generic.Queue[object]');Capacity=200;MessageLength=300
                Sampling=@{};SamplingKeys=512;SamplingSeconds=60;Total=[long]0;Busy=$false
            }
            $script:DomeniaSwallowedState = $state
        }
        # PowerShell names are case-insensitive: $nested must not reuse the name of the -Reentry switch.
        $nested = (([bool]$Reentry) -or ([bool]$state.Busy))
        if (-not $nested) { $state.Busy = $true }
        try {
            $when = [datetime]::UtcNow
            if ($Now -is [datetime]) { $when = $Now.ToUniversalTime() }
            $exception = $null; $type = ''; $text = ''
            if ($ErrorRecord -is [Management.Automation.ErrorRecord]) { $exception = $ErrorRecord.Exception }
            elseif ($ErrorRecord -is [Exception]) { $exception = $ErrorRecord }
            if ($null -ne $exception) { $type = $exception.GetType().FullName; $text = [string]$exception.Message }
            elseif ($null -ne $ErrorRecord) { $text = [string]$ErrorRecord }
            # The sampling decision comes first: a repetition sampled out within the minute is not masked again (in a
            # loop that fails on every row, masking each occurrence would cost more than the trace is worth). The key
            # is the category and operation as given (identifiers chosen by the caller), kept in memory only; the entry
            # of a sampled-out call takes the masked category and operation of the line due and keeps no message.
            $key = [string]$Category + '|' + [string]$Operation
            $last = $null
            $sampled = $false
            if ((-not $nested) -and $state.Sampling.ContainsKey($key)) {
                $last = $state.Sampling[$key]
                $elapsed = ($when - [datetime]$last.Time).TotalSeconds
                $sampled = (($elapsed -ge 0) -and ($elapsed -lt [int]$state.SamplingSeconds))
            }
            if ($sampled) {
                $flatCategory = [string]$last.Category; $flatOperation = [string]$last.Operation; $message = ''
            }
            else {
                $values = @([string]$Category,[string]$Operation,$text)
                if ($nested) { $values[2] = '' }
                else {
                    for ($i = 0; $i -lt $values.Count; $i++) {
                        if ([string]::IsNullOrEmpty($values[$i])) { continue }
                        $masked = $null
                        if ($null -ne $Mask) { try { $masked = [string](& $Mask $values[$i]) } catch { $masked = $null } }
                        if ($null -eq $masked) { try { $masked = [string](Protect-DomeniaSecretText $values[$i]) } catch { $masked = $null } }
                        if ($null -eq $masked) {
                            # Category and operation are identifiers chosen by the caller; only the message is dropped.
                            if ($i -eq 2) { $masked = '[message non conservé : aucune règle de masquage chargée]' } else { $masked = $values[$i] }
                        }
                        $values[$i] = $masked
                    }
                }
                $flatCategory = ConvertTo-DomeniaFlatText $values[0] 80
                $flatOperation = ConvertTo-DomeniaFlatText $values[1] 120
                $message = ConvertTo-DomeniaFlatText $values[2] ([int]$state.MessageLength)
            }
            $journal = 'Unavailable'
            if ($nested) { $journal = 'Reentry' }
            elseif ($sampled) { $journal = 'Sampled' }
            $entry = [pscustomobject]@{Time=$when;Category=$flatCategory;Operation=$flatOperation;Type=$type;Message=$message;Journal=$journal}
            $state.Entries.Enqueue($entry)
            while ($state.Entries.Count -gt [int]$state.Capacity) { [void]$state.Entries.Dequeue() }
            $state.Total = [long]$state.Total + 1
            if ($nested) { return }
            if ($sampled) {
                $last.Folded = [int]$last.Folded + 1
                return
            }
            $folded = 0
            if ($null -ne $last) { $folded = [int]$last.Folded }
            elseif ($state.Sampling.Count -ge [int]$state.SamplingKeys) { $state.Sampling.Clear() }
            $state.Sampling[$key] = [pscustomobject]@{Time=$when;Folded=0;Category=$flatCategory;Operation=$flatOperation}
            $line = 'Erreur ignorée [' + $flatCategory + '] ' + $flatOperation
            if ($type) { $line += ' : ' + $type }
            if ($message) { $line += ' : ' + $message }
            if ($folded -gt 0) { $line += ' (+' + [string]$folded + ' occurrence(s) depuis la ligne précédente)' }
            return [pscustomobject]@{Line=$line;Entry=$entry}
        }
        finally { if (-not $nested) { $state.Busy = $false } }
    }
    catch {
        # Exempt from tools/audit_swallowed.py: the trace of a swallowed error cannot trace its own failure.
        $null = $_
    }
}

function Get-DomeniaSwallowedEntries {
    # Entries of the ring kept by Add-DomeniaSwallowedEntry (Write-DomeniaSwallowed in the core), oldest first, written
    # to the pipeline (wrap the call in @()): Time (UTC), Category, Operation, Type, Message (masked, bounded) and
    # Journal (Logged, Sampled, Unavailable or Reentry). Nothing before the first entry.
    $state = $null
    try { $state = $script:DomeniaSwallowedState } catch { $state = $null }
    if ($null -eq $state) { return }
    return $state.Entries.ToArray()
}

function Write-DomeniaRuleSwallowed {
    # P-CD-09: trace of an error swallowed by a pure rule (*.Model.ps1). A rule also runs in worker runspaces and in
    # test benches that do not load the core: the trace of the core (Write-DomeniaSwallowed: journal and ring) is used
    # when it is reachable, otherwise the ring of Add-DomeniaSwallowedEntry only. The rule itself stays free of journal
    # and disk code; its catch block calls this function through a guard, since a bench may load a rule without this
    # module:  catch { if (${function:Write-DomeniaRuleSwallowed}) { Write-DomeniaRuleSwallowed 'Probes' 'Get-X' $_ } }
    # Never throws and writes nothing to the pipeline.
    param(
        [AllowNull()][AllowEmptyString()][string]$Category='',
        [AllowNull()][AllowEmptyString()][string]$Operation='',
        [AllowNull()]$ErrorRecord=$null
    )
    try {
        if (${function:Write-DomeniaSwallowed}) { Write-DomeniaSwallowed $Category $Operation $ErrorRecord; return }
        [void](Add-DomeniaSwallowedEntry -Category $Category -Operation $Operation -ErrorRecord $ErrorRecord)
    }
    catch {
        # Exempt from tools/audit_swallowed.py: the trace of a swallowed error cannot trace its own failure.
        [void]$_
    }
}

# ---------------------------------------------------------------- point 133: versioned contracts between modules
# Kept here because every worker runspace dot-sources this file first: a format check reads the same catalog on the
# interface thread and in a worker.

function Get-DomeniaContractCatalog {
    # Formats and closed vocabularies exchanged between modules or kept on disk. Current is the highest version this
    # build writes (a writer may keep a lower version that is a strict subset, as Domenia.Query/1). Readable lists the
    # versions this build reads; each older one reaches Current through a declared migration ('Subset': read as is,
    # every field keeps its meaning). A version above Current comes from a newer Domenia and is refused, never guessed.
    # Values is the closed vocabulary of an error or capability contract.
    # The table is constant: it is built once per runspace (format checks run inside loops over thousands of recipes,
    # some on the interface thread). Read through try because a caller may run under Set-StrictMode.
    $cached = $null
    try { $cached = $script:DomeniaContractCatalogCache } catch { $cached = $null }
    if ($null -ne $cached) { return $cached }
    $subset = { param([int]$From,[int]$To) [pscustomobject]@{ From = $From; To = $To; Mode = 'Subset' } }
    $catalog = @(
        [pscustomobject]@{ Family = 'Domenia.Query'; Label = 'Recette de requête'; Kind = 'Format'; Separator = '/'; Current = 2; Readable = @(1,2); Migrations = @(& $subset 1 2); Values = @(); Owner = 'Domenia-Query.Model.ps1' }
        [pscustomobject]@{ Family = 'Domenia.QueryLibrary'; Label = 'Bibliothèque de requêtes'; Kind = 'Format'; Separator = '/'; Current = 1; Readable = @(1); Migrations = @(); Values = @(); Owner = 'Domenia-Query.Model.ps1' }
        # W09 (point 69): version 2 adds the pack identity, its version and a content fingerprint; a version 1 pack keeps
        # its meaning and is read without them (shown unverified).
        [pscustomobject]@{ Family = 'Domenia.QueryPack'; Label = 'Pack de recettes'; Kind = 'Format'; Separator = '/'; Current = 2; Readable = @(1,2); Migrations = @(& $subset 1 2); Values = @(); Owner = 'Domenia-QueryLibrary.Model.ps1' }
        [pscustomobject]@{ Family = 'Domenia.QueryLibraryRecord'; Label = 'Enregistrement de recette'; Kind = 'Format'; Separator = '/'; Current = 1; Readable = @(1); Migrations = @(); Values = @(); Owner = 'Domenia-QueryLibrary.Model.ps1' }
        # An import plan is built and read in the same session, never kept: only the current version is read.
        [pscustomobject]@{ Family = 'Domenia.QueryImportPlan'; Label = 'Plan dʼimport de recettes'; Kind = 'Format'; Separator = '/'; Current = 2; Readable = @(2); Migrations = @(); Values = @(); Owner = 'Domenia-QueryLibrary.Model.ps1' }
        [pscustomobject]@{ Family = 'Domenia.QueryImportJournal'; Label = 'Journal des imports de recettes'; Kind = 'Format'; Separator = '/'; Current = 1; Readable = @(1); Migrations = @(); Values = @(); Owner = 'Domenia-QueryLibrary.Model.ps1' }
        [pscustomobject]@{ Family = 'Domenia.QueryExport'; Label = 'Export de résultats'; Kind = 'Format'; Separator = '/'; Current = 1; Readable = @(1); Migrations = @(); Values = @(); Owner = 'Domenia-Query.Worker.ps1' }
        [pscustomobject]@{ Family = 'Domenia.WmiRead'; Label = 'Définition de lecture WMI'; Kind = 'Format'; Separator = '/'; Current = 1; Readable = @(1); Migrations = @(); Values = @(); Owner = 'Domenia-QuerySchema.Model.ps1' }
        [pscustomobject]@{ Family = 'Domenia.DetailQuerySummary'; Label = 'Résumé de lecture détaillée'; Kind = 'Format'; Separator = '/'; Current = 1; Readable = @(1); Migrations = @(); Values = @(); Owner = 'Domenia-Storage.Worker.ps1' }
        [pscustomobject]@{ Family = 'Domenia.CollectionRun'; Label = 'Horloge de collecte dʼune OU'; Kind = 'Format'; Separator = '/'; Current = 1; Readable = @(1); Migrations = @(); Values = @(); Owner = 'Domenia-Collection.Model.ps1' }
        [pscustomobject]@{ Family = 'DomeniaCampaignPlan'; Label = 'Plan de relevé'; Kind = 'Format'; Separator = '/'; Current = 1; Readable = @(1); Migrations = @(); Values = @(); Owner = 'Domenia-Collection.Model.ps1' }
        [pscustomobject]@{ Family = 'DomeniaCampaignProgress'; Label = 'Avancement du relevé'; Kind = 'Format'; Separator = '/'; Current = 1; Readable = @(1); Migrations = @(); Values = @(); Owner = 'Domenia-Collection.Model.ps1' }
        [pscustomobject]@{ Family = 'Domenia.ProbeContract'; Label = 'Contrat de sonde'; Kind = 'Format'; Separator = '/'; Current = 1; Readable = @(1); Migrations = @(); Values = @(); Owner = 'Domenia-ProbeContract.Model.ps1' }
        [pscustomobject]@{ Family = 'Domenia.Automation'; Label = 'Interface automatisable'; Kind = 'Format'; Separator = '/'; Current = 1; Readable = @(1); Migrations = @(); Values = @(); Owner = 'Domenia-Automation.Model.ps1' }
        [pscustomobject]@{ Family = 'Domenia.OfflineDossier'; Label = 'Dossier de diagnostic hors ligne'; Kind = 'Format'; Separator = '/'; Current = 1; Readable = @(1); Migrations = @(); Values = @(); Owner = 'Domenia-Automation.Model.ps1' }
        [pscustomobject]@{ Family = 'Domenia.Capture'; Label = 'Capture historique'; Kind = 'Format'; Separator = '.'; Current = 1; Readable = @(1); Migrations = @(); Values = @(); Owner = 'Domenia-Dossier.UI.ps1' }
        # W13 (point 124): the redacted diagnostic replaces the technical dossier (Domenia.Support.1, never read back by
        # Domenia); it carries the compatibility of the workstation (point 145).
        [pscustomobject]@{ Family = 'Domenia.Diagnostic'; Label = 'Diagnostic expurgé'; Kind = 'Format'; Separator = '.'; Current = 2; Readable = @(2); Migrations = @(); Values = @(); Owner = 'Domenia-Observability.Model.ps1' }
        [pscustomobject]@{ Family = 'DomeniaTicket'; Label = 'Ticket de support'; Kind = 'Format'; Separator = '/'; Current = 1; Readable = @(1); Migrations = @(); Values = @(); Owner = 'Domenia-Insight.Model.ps1' }
        [pscustomobject]@{ Family = 'DomeniaSuiteContract'; Label = 'Contrat de la suite'; Kind = 'Format'; Separator = '/'; Current = 1; Readable = @(1); Migrations = @(); Values = @(); Owner = 'Domenia-Workstation.Model.ps1' }
        [pscustomobject]@{ Family = 'DomeniaDemoDirectory'; Label = 'Annuaire de démonstration'; Kind = 'Format'; Separator = '/'; Current = 1; Readable = @(1); Migrations = @(); Values = @(); Owner = 'Domenia-Demo.Model.ps1' }
        [pscustomobject]@{ Family = 'DomeniaSelectionPreview'; Label = 'Aperçu de sélection'; Kind = 'Format'; Separator = '/'; Current = 1; Readable = @(1); Migrations = @(); Values = @(); Owner = 'Domenia-Shell.Model.ps1' }
        [pscustomobject]@{ Family = 'DomeniaWindowsLifecycle'; Label = 'Table des fins de service Windows'; Kind = 'Format'; Separator = '/'; Current = 1; Readable = @(1); Migrations = @(); Values = @(); Owner = 'Domenia-Dashboard.UI.ps1' }
        [pscustomobject]@{ Family = 'DomeniaCompatibilityMatrix'; Label = 'Matrice de compatibilité'; Kind = 'Format'; Separator = '/'; Current = 1; Readable = @(1); Migrations = @(); Values = @(); Owner = 'Domenia-Compatibility.Model.ps1' }
        [pscustomobject]@{ Family = 'DomeniaReleaseContract'; Label = 'Contrat de livraison'; Kind = 'Format'; Separator = '/'; Current = 1; Readable = @(1); Migrations = @(); Values = @(); Owner = 'tools/release_contract.py' }
        [pscustomobject]@{ Family = 'Domenia.ProviderOutcome'; Label = 'Issue dʼune opération'; Kind = 'Erreurs'; Separator = '/'; Current = 1; Readable = @(1); Migrations = @(); Values = @('Success','Cancelled','Timeout','CredentialRejected','AccessDenied','Failure'); Owner = 'Domenia-Engine.Model.ps1' }
        [pscustomobject]@{ Family = 'Domenia.Provider'; Label = 'Fournisseur dʼune opération'; Kind = 'Capacites'; Separator = '/'; Current = 1; Readable = @(1); Migrations = @(); Values = @('Directory','Cim','Wts','Storage','Local','Network'); Owner = 'Domenia-Engine.Model.ps1' }
    )
    $script:DomeniaContractCatalogCache = $catalog
    return $catalog
}

function Get-DomeniaContract {
    # Catalog entry of one family (case-sensitive), $null when the family is not declared. -Catalog replaces the
    # shipped catalog (rule tests of a future version).
    param([AllowEmptyString()][string]$Family,[object[]]$Catalog = $null)
    if ($null -eq $Catalog) {
        # Shipped catalog: one ordinal index per runspace, so that a check costs one lookup.
        $index = $null
        try { $index = $script:DomeniaContractIndex } catch { $index = $null }
        if ($null -eq $index) {
            $index = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
            foreach ($contract in @(Get-DomeniaContractCatalog)) {
                $name = [string](Get-DomeniaMember $contract 'Family' '')
                if (($name) -and (-not $index.ContainsKey($name))) { $index.Add($name,$contract) }
            }
            $script:DomeniaContractIndex = $index
        }
        $found = $null
        if ($index.TryGetValue([string]$Family,[ref]$found)) { return $found }
        return $null
    }
    foreach ($contract in @($Catalog)) { if ([string](Get-DomeniaMember $contract 'Family' '') -ceq $Family) { return $contract } }
    return $null
}

function ConvertFrom-DomeniaContractFormat {
    # 'Domenia.Query/2' or the dotted form 'Domenia.Diagnostic.2' -> Family, Separator, Version. $null when the
    # text is not a versioned format (no version, version 0, more than four digits, unexpected characters).
    param([AllowEmptyString()][string]$Format)
    $found = [regex]::Match(([string]$Format),'^([A-Za-z][A-Za-z0-9]*(?:\.[A-Za-z][A-Za-z0-9]*)*)([/.])([1-9][0-9]{0,3})$')
    if (-not $found.Success) { return $null }
    return [pscustomobject]@{ Family = $found.Groups[1].Value; Separator = $found.Groups[2].Value; Version = [int]$found.Groups[3].Value; Text = [string]$Format }
}

function Resolve-DomeniaContractFormat {
    # Decision for a format read from a file, a worker result or the local base. Accepted: Lire (current version) or
    # Migrer (older readable version, with the declared steps). Refused with a reason: Illisible, Inattendu (another
    # family), Inconnu (family not declared), PlusRecent (written by a newer Domenia) or TropAncien.
    param([AllowEmptyString()][string]$Format,[Parameter(Mandatory = $true)][string]$Family,[AllowEmptyString()][string]$Label = '',[object[]]$Catalog = $null)
    $contract = Get-DomeniaContract -Family $Family -Catalog $Catalog
    $name = $Label
    if ((-not $name) -and ($null -ne $contract)) { $name = [string]$contract.Label }
    if (-not $name) { $name = $Family }
    $shown = ConvertTo-DomeniaFlatText ([string]$Format) 80
    $result = [pscustomobject]@{ Accepted = $false; Decision = 'Refuser'; Reason = ''; Family = $Family; Version = 0; Current = 0; Steps = @(); Message = '' }
    if ($null -eq $contract) { $result.Reason = 'Inconnu'; $result.Message = 'Format inconnu : ' + $shown + '. Rien nʼest lu.'; return $result }
    $result.Current = [int]$contract.Current
    $parsed = ConvertFrom-DomeniaContractFormat $Format
    if ($null -eq $parsed) { $result.Reason = 'Illisible'; $result.Message = $name + ' : format illisible (' + $shown + '). Rien nʼest lu.'; return $result }
    if (([string]$parsed.Family -cne $Family) -or ([string]$parsed.Separator -cne [string]$contract.Separator)) { $result.Reason = 'Inattendu'; $result.Message = $name + ' : format ' + $shown + ' inattendu (' + $Family + [string]$contract.Separator + [string]$contract.Current + ' attendu). Rien nʼest lu.'; return $result }
    $result.Version = [int]$parsed.Version
    $readable = @($contract.Readable | ForEach-Object { [int]$_ })
    if ($result.Version -gt $result.Current) {
        $result.Reason = 'PlusRecent'
        $result.Message = $name + ' : format ' + $shown + ' produit par une version plus récente de Domenia ; cette version lit jusquʼà la version ' + [string]$result.Current + '. Rien nʼest lu ni modifié : utilisez la version de Domenia qui a produit ces données.'
        return $result
    }
    if ($readable -notcontains $result.Version) {
        $result.Reason = 'TropAncien'
        $result.Message = $name + ' : format ' + $shown + ' trop ancien pour cette version (versions lues : ' + [string]::Join(', ',[string[]]$readable) + '). Rien nʼest lu.'
        return $result
    }
    if ($result.Version -eq $result.Current) { $result.Accepted = $true; $result.Decision = 'Lire'; $result.Reason = 'Courant'; return $result }
    $steps = New-Object 'System.Collections.Generic.List[object]'
    $position = $result.Version
    while ($position -lt $result.Current) {
        $step = $null
        foreach ($migration in @($contract.Migrations)) { if ([int]$migration.From -eq $position) { $step = $migration; break } }
        if (($null -eq $step) -or ([int]$step.To -le $position)) {
            $result.Reason = 'TropAncien'
            $result.Message = $name + ' : format ' + $shown + ', aucune migration déclarée depuis la version ' + [string]$position + '. Rien nʼest lu.'
            return $result
        }
        $steps.Add($step)
        $position = [int]$step.To
    }
    $result.Accepted = $true; $result.Decision = 'Migrer'; $result.Reason = 'Ancien'; $result.Steps = $steps.ToArray()
    $result.Message = $name + ' : format ' + $shown + ' lu par migration vers la version ' + [string]$result.Current + '.'
    return $result
}

function Assert-DomeniaContractFormat {
    # Throws the French message of a refused format; returns the decision of an accepted one.
    param([AllowEmptyString()][string]$Format,[Parameter(Mandatory = $true)][string]$Family,[AllowEmptyString()][string]$Label = '')
    $resolution = Resolve-DomeniaContractFormat -Format $Format -Family $Family -Label $Label
    if (-not $resolution.Accepted) { throw [InvalidOperationException]::new([string]$resolution.Message) }
    return $resolution
}

function Test-DomeniaContractValue {
    # True when Value belongs to the closed vocabulary of an error or capability contract.
    param([Parameter(Mandatory = $true)][string]$Family,[AllowEmptyString()][string]$Value)
    $contract = Get-DomeniaContract $Family
    if (($null -eq $contract) -or (@($contract.Values).Count -eq 0)) { return $false }
    return (@($contract.Values) -ccontains $Value)
}

function Test-DomeniaContractCatalog {
    # Consistency of the catalog: unique families, Current readable, each older readable version reaching Current
    # through declared steps, a known separator, a closed and non-empty vocabulary for error and capability contracts.
    param([object[]]$Catalog = $null)
    if ($null -eq $Catalog) { $Catalog = @(Get-DomeniaContractCatalog) }
    $problems = New-Object 'System.Collections.Generic.List[string]'
    $seen = @{}
    foreach ($contract in @($Catalog)) {
        $family = [string](Get-DomeniaMember $contract 'Family' '')
        if ($null -eq (ConvertFrom-DomeniaContractFormat ($family + [string](Get-DomeniaMember $contract 'Separator' '/') + '1'))) { $problems.Add('Famille ou séparateur invalide : ' + $family); continue }
        if ($seen.ContainsKey($family)) { $problems.Add('Famille en double : ' + $family) }
        $seen[$family] = $true
        $current = [int](Get-DomeniaMember $contract 'Current' 0)
        $readable = @(@(Get-DomeniaMember $contract 'Readable' @()) | ForEach-Object { [int]$_ })
        if (($current -lt 1) -or ($readable -notcontains $current)) { $problems.Add($family + ' : la version courante doit être lisible.') }
        if (@($readable | Where-Object { $_ -gt $current }).Count -gt 0) { $problems.Add($family + ' : version lisible supérieure à la version courante.') }
        $migrations = @(Get-DomeniaMember $contract 'Migrations' @())
        foreach ($migration in $migrations) {
            if (@('Subset') -cnotcontains [string](Get-DomeniaMember $migration 'Mode' '')) { $problems.Add($family + ' : mode de migration inconnu.') }
        }
        foreach ($version in $readable) {
            $position = $version
            $guard = 0
            while (($position -lt $current) -and ($guard -lt 100)) {
                $next = @($migrations | Where-Object { [int](Get-DomeniaMember $_ 'From' 0) -eq $position })
                if (($next.Count -ne 1) -or ([int](Get-DomeniaMember $next[0] 'To' 0) -le $position)) { $problems.Add($family + ' : pas de migration unique depuis la version ' + [string]$position + '.'); break }
                $position = [int](Get-DomeniaMember $next[0] 'To' 0)
                $guard++
            }
        }
        $kind = [string](Get-DomeniaMember $contract 'Kind' '')
        $values = @(Get-DomeniaMember $contract 'Values' @())
        if (@('Format','Erreurs','Capacites') -cnotcontains $kind) { $problems.Add($family + ' : nature inconnue.') }
        $distinct = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($value in $values) { [void]$distinct.Add([string]$value) }
        if (($kind -cne 'Format') -and (($values.Count -eq 0) -or ($distinct.Count -ne $values.Count))) { $problems.Add($family + ' : vocabulaire fermé vide ou en double.') }
        if (($kind -ceq 'Format') -and ($values.Count -gt 0)) { $problems.Add($family + ' : un format nʼa pas de vocabulaire.') }
    }
    return [pscustomobject]@{ Valid = ($problems.Count -eq 0); Problems = $problems.ToArray() }
}
