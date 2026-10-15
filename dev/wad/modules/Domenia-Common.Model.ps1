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
    } catch { }
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
    } catch { }
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
    } catch { }
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
    # Write-DomeniaSwallowed (Domenia-Core.ps1, next to Write-AppLog) calls it and writes the returned line to the
    # technical journal; worker code that embeds this module may call it directly and keep the ring only.
    # Every call adds an entry to a bounded in-memory ring (Get-DomeniaSwallowedEntries, oldest first). At most once a
    # minute per category and operation, the call returns the journal line due, with the number of occurrences folded
    # in since the previous line: [pscustomobject]@{Line;Entry}. Nothing is returned when the line is sampled out or for
    # a reentry. Entry.Journal is Unavailable until the caller records the outcome (Logged), or Sampled, or Reentry.
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
            $journal = 'Unavailable'
            if ($nested) { $journal = 'Reentry' }
            $entry = [pscustomobject]@{Time=$when;Category=$flatCategory;Operation=$flatOperation;Type=$type;Message=$message;Journal=$journal}
            $state.Entries.Enqueue($entry)
            while ($state.Entries.Count -gt [int]$state.Capacity) { [void]$state.Entries.Dequeue() }
            $state.Total = [long]$state.Total + 1
            if ($nested) { return }
            $key = $flatCategory + '|' + $flatOperation
            $last = $null
            if ($state.Sampling.ContainsKey($key)) { $last = $state.Sampling[$key] }
            if ($null -ne $last) {
                $elapsed = ($when - [datetime]$last.Time).TotalSeconds
                if (($elapsed -ge 0) -and ($elapsed -lt [int]$state.SamplingSeconds)) {
                    $last.Folded = [int]$last.Folded + 1
                    $entry.Journal = 'Sampled'
                    return
                }
            }
            $folded = 0
            if ($null -ne $last) { $folded = [int]$last.Folded }
            elseif ($state.Sampling.Count -ge [int]$state.SamplingKeys) { $state.Sampling.Clear() }
            $state.Sampling[$key] = [pscustomobject]@{Time=$when;Folded=0}
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
