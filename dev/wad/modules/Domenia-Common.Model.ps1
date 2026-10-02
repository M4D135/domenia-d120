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
    param($Value)
    if ($null -eq $Value) { return $null }
    try {
        if ($Value -is [byte[]]) { return $null }
        if (($Value -isnot [string]) -and ($Value -is [Collections.IEnumerable])) {
            # One AD value in a collection is read; several values never pick one silently.
            $items = Get-DomeniaCollectionItems $Value
            if ($items.Count -ne 1) { return $null }
            return (ConvertTo-DomeniaUtcDate $items[0])
        }
        $large = ConvertFrom-DomeniaLargeInteger $Value
        if ($null -ne $large) { $Value = [long]$large }
        if ($Value -is [datetime]) {
            if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($Value,[DateTimeKind]::Utc) }
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
        $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
        if ([datetime]::TryParse($text,[Globalization.CultureInfo]::InvariantCulture,$styles,[ref]$parsed)) { return $parsed }
    } catch { }
    return $null
}

function Get-DomeniaFeatureFlag {
    # Reads Features.<Name> from the application configuration when the core is loaded.
    param([Parameter(Mandatory=$true)][string]$Name,[bool]$Default=$true)
    $reader = Get-Command -Name Get-CfgValue -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $reader) { return $Default }
    try {
        $value = Get-CfgValue 'Features' $Name $Default
        if ($value -is [bool]) { return $value }
        $text = ([string]$value).Trim()
        if ($text -match '^(?i:true|1|oui|yes|on)$') { return $true }
        if ($text -match '^(?i:false|0|non|no|off)$') { return $false }
    } catch { }
    return $Default
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
