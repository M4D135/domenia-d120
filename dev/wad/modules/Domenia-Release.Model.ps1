# Release rules: one delivery identity read from a single contract, a standalone PROD tree, a rebuild that
# names every component, an explicit ADCC to Domenia migration, a version-level atomic installation, a
# forward-only data schema, integrity kept apart from publisher trust, an inventory bound to delivered files,
# one storage location per data category, the shared suite UI kit, and optional read-only connectors.
# Pure decisions: no file, registry, network or clock access. Callers read files and pass the observed values.
# Relies on Domenia-Common.Model.ps1 only.

# ---------------------------------------------------------------- shared helpers
function ConvertTo-DomeniaSha256Text {
    # Upper-case SHA-256 text, or '' when the value is not a 64-digit hexadecimal fingerprint.
    param([AllowNull()][AllowEmptyString()][string]$Value)
    $text = ([string]$Value).Trim()
    if ($text -notmatch '^[0-9A-Fa-f]{64}$') { return '' }
    return $text.ToUpperInvariant()
}

function Test-DomeniaReleaseRelativePath {
    # A delivered path is relative, uses '/', never leaves the package and avoids names Windows cannot hold.
    param([AllowNull()][AllowEmptyString()][string]$Path)
    $text = [string]$Path
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    if (($text.IndexOf([char]'\') -ge 0) -or ($text.IndexOf([char]':') -ge 0) -or ($text.IndexOf([char]0) -ge 0)) { return $false }
    if ($text.StartsWith('/',[StringComparison]::Ordinal) -or $text.EndsWith('/',[StringComparison]::Ordinal)) { return $false }
    foreach ($segment in $text.Split([char]'/')) {
        if (($segment -eq '') -or ($segment -eq '.') -or ($segment -eq '..')) { return $false }
        if ($segment.EndsWith(' ',[StringComparison]::Ordinal) -or $segment.EndsWith('.',[StringComparison]::Ordinal)) { return $false }
        if ($segment.IndexOfAny([char[]]@('<','>','"','|','?','*')) -ge 0) { return $false }
        if ($segment.Split([char]'.')[0] -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { return $false }
    }
    return $true
}

function Join-DomeniaReleasePath {
    # Text-only join: no provider lookup, so a location on an absent drive can still be described.
    param([AllowNull()][AllowEmptyString()][string]$Root,[AllowNull()][AllowEmptyString()][string]$Child)
    if ([string]::IsNullOrWhiteSpace($Root)) { return '' }
    $base = ([string]$Root).Trim().TrimEnd([char[]]@('\','/'))
    if ([string]::IsNullOrEmpty($Child)) { return $base }
    return ($base + '\' + ([string]$Child).TrimStart([char[]]@('\','/')).Replace('/','\'))
}

function Test-DomeniaReleaseMapKey {
    # Key lookup that works on every map a caller may pass: a hashtable, an ordered dictionary, or a generic
    # Dictionary[string,T] whose IDictionary.Contains is an explicit interface member that Windows PowerShell 5.1 cannot
    # call directly. The map keeps its own comparer (case-insensitive hashtable, ordinal Dictionary).
    param($Map,[AllowNull()][AllowEmptyString()][string]$Key)
    if (($null -eq $Map) -or ($null -eq $Key)) { return $false }
    if ($Map -is [hashtable]) { return $Map.ContainsKey($Key) }
    if ($null -ne $Map.PSObject.Methods['ContainsKey']) { return [bool]$Map.ContainsKey($Key) }
    if ($null -ne $Map.PSObject.Methods['Contains']) { return [bool]$Map.Contains($Key) }
    if ($Map -is [Collections.IDictionary]) { return [bool]([Collections.IDictionary].GetMethod('Contains').Invoke($Map.PSObject.BaseObject,[object[]]@($Key))) }
    return ($null -ne $Map.PSObject.Properties[$Key])
}

function Get-DomeniaReleaseMapValue {
    # Value of a key in any map (see Test-DomeniaReleaseMapKey) or a property of an object; $Default when absent.
    param($Map,[AllowNull()][AllowEmptyString()][string]$Key,$Default=$null)
    if ($null -eq $Map) { return $Default }
    if ($Map -is [Collections.IDictionary]) {
        if (Test-DomeniaReleaseMapKey $Map $Key) { return $Map[$Key] }
        return $Default
    }
    return (Get-DomeniaMember $Map $Key $Default)
}

function ConvertTo-DomeniaReleaseCanonicalText {
    # Deterministic text for fingerprints: keys sorted ordinally, invariant numbers, arrays kept in order.
    # A hashtable and the same data read back from JSON give the same text.
    param($Value,[int]$Depth=0)
    if ($Depth -gt 24) { throw 'Structure trop profonde pour calculer une empreinte.' }
    if ($null -eq $Value) { return 'null' }
    if (($Value -is [string]) -or ($Value -is [char])) { return ('"' + ([string]$Value).Replace('\','\\').Replace('"','\"') + '"') }
    if ($Value -is [bool]) { if ($Value) { return 'true' }; return 'false' }
    if ($Value -is [datetime]) { return ('"' + $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture) + '"') }
    if ($Value -is [enum]) { return ('"' + $Value.ToString() + '"') }
    if ($Value -is [IConvertible]) { return [Convert]::ToString($Value,[Globalization.CultureInfo]::InvariantCulture) }
    $names = New-Object 'System.Collections.Generic.List[string]'
    $parts = New-Object 'System.Collections.Generic.List[string]'
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) { $names.Add([string]$key) }
        $names.Sort([StringComparer]::Ordinal)
        foreach ($name in $names) { $parts.Add((ConvertTo-DomeniaReleaseCanonicalText $name) + ':' + (ConvertTo-DomeniaReleaseCanonicalText ($Value[$name]) ($Depth + 1))) }
        return ('{' + [string]::Join(',',$parts.ToArray()) + '}')
    }
    if ($Value -is [Management.Automation.PSCustomObject]) {
        foreach ($property in @($Value.PSObject.Properties)) { $names.Add([string]$property.Name) }
        $names.Sort([StringComparer]::Ordinal)
        foreach ($name in $names) { $parts.Add((ConvertTo-DomeniaReleaseCanonicalText $name) + ':' + (ConvertTo-DomeniaReleaseCanonicalText ($Value.PSObject.Properties[$name].Value) ($Depth + 1))) }
        return ('{' + [string]::Join(',',$parts.ToArray()) + '}')
    }
    if ($Value -is [Collections.IEnumerable]) {
        foreach ($item in $Value) { $parts.Add((ConvertTo-DomeniaReleaseCanonicalText $item ($Depth + 1))) }
        return ('[' + [string]::Join(',',$parts.ToArray()) + ']')
    }
    return (ConvertTo-DomeniaReleaseCanonicalText ([string]$Value))
}

function Get-DomeniaWorkerRegistryFingerprint {
    # Same digest as Assert-DomeniaWorkerRegistry in the core and tools/update_worker_contracts.py: SHA-256 of the
    # 'Operation=HASH' lines sorted ordinally and joined by LF. Accepts the core map or the contracts list.
    param($Registry)
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $entries = New-Object 'System.Collections.Generic.List[object]'
    if ($Registry -is [Collections.IDictionary]) {
        foreach ($key in @($Registry.Keys)) { $entries.Add([pscustomobject]@{Operation=[string]$key;Sha256=[string]$Registry[$key]}) }
    }
    else {
        # Windows PowerShell 5.1 ConvertFrom-Json emits a JSON array as one object: accept that nesting.
        $flat = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in @($Registry)) {
            if ($item -is [array]) { foreach ($inner in $item) { $flat.Add($inner) } }
            elseif ($null -ne $item) { $flat.Add($item) }
        }
        foreach ($item in $flat) {
            if ($null -eq $item) { continue }
            $entries.Add([pscustomobject]@{Operation=[string](Get-DomeniaMember $item 'Operation' '');Sha256=[string](Get-DomeniaMember $item 'Sha256' '')})
        }
    }
    $seen = New-Object -TypeName 'System.Collections.Generic.Dictionary[string,string]' -ArgumentList ([StringComparer]::Ordinal)
    foreach ($entry in $entries) {
        if ($entry.Operation -cnotmatch '^[A-Za-z][A-Za-z0-9]{2,63}$') { $errors.Add('Identifiant d operation invalide : <' + $entry.Operation + '>.'); continue }
        if ($entry.Sha256 -cnotmatch '^[A-F0-9]{64}$') { $errors.Add('Empreinte invalide pour ' + $entry.Operation + '.'); continue }
        if ($seen.ContainsKey($entry.Operation)) { $errors.Add('Operation declaree deux fois : ' + $entry.Operation + '.'); continue }
        $seen.Add($entry.Operation,$entry.Sha256)
    }
    [string[]]$names = @($seen.Keys)
    [Array]::Sort($names,[StringComparer]::Ordinal)
    $records = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in $names) { $records.Add($name + '=' + $seen[$name]) }
    $valid = (($errors.Count -eq 0) -and ($records.Count -gt 0))
    $fingerprint = ''
    if ($valid) { $fingerprint = Get-DomeniaTextHash ([string]::Join("`n",$records.ToArray())) }
    return [pscustomobject]@{Valid=$valid;Operations=$records.Count;Sha256=$fingerprint;Errors=$errors.ToArray()}
}

# ---------------------------------------------------------------- D010 one release identity
function ConvertFrom-DomeniaBuildLabel {
    # Splits 2026.10.02-DOMENIA-1.0-RC1.11.0-D120 into date, product, version, stage and label. $null when unusable.
    param([AllowNull()][AllowEmptyString()][string]$Build)
    $text = ([string]$Build).Trim()
    $found = [regex]::Match($text,'^(?<y>\d{4})\.(?<mo>\d{2})\.(?<d>\d{2})-(?<p>[A-Z][A-Z0-9]*)-(?<v>\d+\.\d+)-(?<s>[A-Z]+\d+(?:\.\d+){0,3})-(?<l>[A-Z0-9][A-Z0-9_]*)$')
    if (-not $found.Success) { return $null }
    $dateText = $found.Groups['y'].Value + '-' + $found.Groups['mo'].Value + '-' + $found.Groups['d'].Value
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($dateText,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)) { return $null }
    return [pscustomobject]@{Build=$text;Date=$dateText;Product=$found.Groups['p'].Value;Version=$found.Groups['v'].Value;Stage=$found.Groups['s'].Value;Label=$found.Groups['l'].Value}
}

function Get-DomeniaBuildLabelTokens {
    # Every text that looks like a build label (AAAA.MM.JJ-PRODUIT-...) inside a log line, a title or a report, as
    # written (a final sentence dot removed). Used to reject a surface that names another delivery.
    param([AllowNull()][AllowEmptyString()][string]$Text)
    $tokens = New-Object 'System.Collections.Generic.List[string]'
    if ([string]::IsNullOrEmpty($Text)) { return $tokens.ToArray() }
    foreach ($found in [regex]::Matches($Text,'(?<![0-9A-Za-z._-])\d{4}\.\d{2}\.\d{2}-[A-Za-z0-9][A-Za-z0-9._-]*')) {
        $tokens.Add($found.Value.TrimEnd([char[]]@('.','-','_')))
    }
    return $tokens.ToArray()
}

function Test-DomeniaReleaseContract {
    # Checks the single release contract (future tools/release-contract.json, read by the caller) before anything is
    # stamped: schema, mandatory fields, and agreement between build label, version, stage, date, channels, components
    # and the worker registry. Domenia.exe is kept byte for byte: its version is declared apart, bound to its SHA-256.
    # $WorkerContracts (optional) is the reviewed registry (tools/operation-contracts.json or the core map).
    # $PublishedBuilds (optional) lists the builds already delivered: the window only shows version and stage, so a
    # stage already used by another build is refused (two deliveries must never look the same on screen).
    param($Contract,$WorkerContracts=$null,[string[]]$PublishedBuilds=@())
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $Contract) {
        $errors.Add('Contrat de release absent.')
        return [pscustomobject]@{Valid=$false;Errors=$errors.ToArray();Warnings=$warnings.ToArray()}
    }
    $schema = [string](Get-DomeniaMember $Contract 'Schema' '')
    if ($schema -cne 'DomeniaReleaseContract/1') { $errors.Add('Schema de contrat non reconnu : <' + $schema + '>. Attendu : DomeniaReleaseContract/1.') }
    foreach ($field in @('Product','Version','Stage','Build','Channels','Components')) {
        $value = Get-DomeniaMember $Contract $field $null
        $missing = ($null -eq $value)
        if ((-not $missing) -and ($value -is [string])) { $missing = [string]::IsNullOrWhiteSpace($value) }
        elseif ((-not $missing) -and ($value -is [Collections.IEnumerable]) -and ($value -isnot [Collections.IDictionary])) { $missing = (@($value).Count -eq 0) }
        if ($missing) { $errors.Add('Champ obligatoire absent : ' + $field + '.') }
    }
    $product = ([string](Get-DomeniaMember $Contract 'Product' '')).Trim()
    $version = ([string](Get-DomeniaMember $Contract 'Version' '')).Trim()
    $stage = ([string](Get-DomeniaMember $Contract 'Stage' '')).Trim()
    $build = ([string](Get-DomeniaMember $Contract 'Build' '')).Trim()
    if ($build) {
        $parts = ConvertFrom-DomeniaBuildLabel $build
        if ($null -eq $parts) { $errors.Add('Build illisible : ' + $build + '. Forme attendue : AAAA.MM.JJ-DOMENIA-<version>-<etape>-<libelle>.') }
        else {
            if ($product -and ($parts.Product -cne $product.ToUpperInvariant())) { $errors.Add('Produit incoherent : contrat ' + $product + ', build ' + $parts.Product + '.') }
            if ($version -and ($parts.Version -cne $version)) { $errors.Add('Version incoherente : contrat ' + $version + ', build ' + $parts.Version + '.') }
            if ($stage -and ($parts.Stage -cne $stage)) { $errors.Add('Etape incoherente : contrat ' + $stage + ', build ' + $parts.Stage + '.') }
            $dateValue = Get-DomeniaMember $Contract 'Date' $null
            $dateText = ''
            if ($dateValue -is [datetime]) { $dateText = $dateValue.ToString('yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture) }
            elseif ($null -ne $dateValue) { $dateText = ([string]$dateValue).Trim() }
            if ($dateText -and ($dateText -cne $parts.Date)) { $errors.Add('Date incoherente : contrat ' + $dateText + ', build ' + $parts.Date + '.') }
            foreach ($published in @($PublishedBuilds)) {
                $other = ConvertFrom-DomeniaBuildLabel ([string]$published)
                if ($null -eq $other) { continue }
                if (($other.Build -cne $parts.Build) -and ($other.Product -ceq $parts.Product) -and ($other.Version -ceq $parts.Version) -and ($other.Stage -ceq $parts.Stage)) {
                    $errors.Add('Etape ' + $parts.Stage + ' deja publiee sous le build ' + $other.Build + ' : l interface (version et etape) ne distinguerait pas les deux livraisons. Changer d etape.')
                }
            }
        }
    }
    $seenChannels = @{}
    foreach ($channel in @(Get-DomeniaMember $Contract 'Channels' @())) {
        $name = [string]$channel
        if ($name -cnotin @('DEV','PROD')) { $errors.Add('Canal inconnu : <' + $name + '>. Canaux admis : DEV, PROD.'); continue }
        if ($seenChannels.ContainsKey($name)) { $errors.Add('Canal declare deux fois : ' + $name + '.') }
        $seenChannels[$name] = $true
    }
    # Windows paths are case-insensitive: the default hashtable comparer matches that.
    $paths = @{}
    foreach ($component in @(Get-DomeniaMember $Contract 'Components' @())) {
        if ($null -eq $component) { continue }
        $path = [string](Get-DomeniaMember $component 'Path' '')
        $name = [string](Get-DomeniaMember $component 'Name' '')
        $policy = [string](Get-DomeniaMember $component 'VersionPolicy' '')
        $componentVersion = ([string](Get-DomeniaMember $component 'Version' '')).Trim()
        $declaredSha = [string](Get-DomeniaMember $component 'Sha256' '')
        $sha = ConvertTo-DomeniaSha256Text $declaredSha
        if (-not (Test-DomeniaReleaseRelativePath $path)) { $errors.Add('Chemin de composant invalide : <' + $path + '> (' + $name + ').'); continue }
        if ($paths.ContainsKey($path)) { $errors.Add('Composant declare deux fois : ' + $path + '.') }
        $paths[$path] = $policy
        if (-not $name) { $errors.Add('Composant sans nom : ' + $path + '.') }
        if ($declaredSha -and (-not $sha)) { $errors.Add('Empreinte SHA-256 illisible pour ' + $path + '.') }
        if ($policy -cnotin @('Release','Distinct')) { $errors.Add('Politique de version inconnue pour ' + $path + ' : <' + $policy + '>. Attendu : Release ou Distinct.') }
        elseif ($policy -ceq 'Distinct') {
            if (-not $componentVersion) { $errors.Add('Version distincte non declaree pour ' + $path + '.') }
            if (-not $sha) { $errors.Add('Un composant a version distincte doit etre lie a son empreinte SHA-256 : ' + $path + '.') }
        }
        elseif ($componentVersion -and $build -and ($componentVersion -cne $build)) { $errors.Add('Version incoherente pour ' + $path + ' : ' + $componentVersion + ' au lieu de ' + $build + '. Declarer VersionPolicy=Distinct si cette version est voulue.') }
    }
    if (-not $paths.ContainsKey('Domenia.exe')) { $errors.Add('Composant Domenia.exe absent du contrat.') }
    elseif ([string]$paths['Domenia.exe'] -cne 'Distinct') { $errors.Add('Domenia.exe est conserve a l octet : sa version doit etre declaree a part (VersionPolicy=Distinct).') }
    if (-not $paths.ContainsKey('wad/Domenia-Core.ps1')) { $errors.Add('Composant wad/Domenia-Core.ps1 absent du contrat : version du moteur non declaree.') }
    elseif ([string]$paths['wad/Domenia-Core.ps1'] -cne 'Release') { $errors.Add('Le moteur wad/Domenia-Core.ps1 porte la version de la livraison (VersionPolicy=Release).') }
    $workers = Get-DomeniaMember $Contract 'WorkerRegistry' $null
    if ($null -eq $workers) { $warnings.Add('Registre des workers non declare dans le contrat : il ne sera pas estampille.') }
    else {
        $operations = 0
        [void][int]::TryParse([string](Get-DomeniaMember $workers 'Operations' ''),[ref]$operations)
        $workerSha = ConvertTo-DomeniaSha256Text ([string](Get-DomeniaMember $workers 'Sha256' ''))
        if ($operations -le 0) { $errors.Add('Registre des workers : nombre d operations absent ou invalide.') }
        if (-not $workerSha) { $errors.Add('Registre des workers : empreinte SHA-256 absente ou invalide.') }
        if ($null -ne $WorkerContracts) {
            $observed = Get-DomeniaWorkerRegistryFingerprint $WorkerContracts
            if (-not $observed.Valid) { $errors.Add('Registre des workers observe illisible : ' + [string]::Join(' ',[string[]]$observed.Errors)) }
            elseif (($observed.Operations -ne $operations) -or ($observed.Sha256 -cne $workerSha)) {
                $errors.Add('Registre des workers different du contrat : ' + $observed.Operations + ' operation(s), empreinte ' + $observed.Sha256 + '.')
            }
        }
    }
    return [pscustomobject]@{Valid=($errors.Count -eq 0);Errors=$errors.ToArray();Warnings=$warnings.ToArray()}
}

function Get-DomeniaReleaseIdentity {
    # The single identity of a delivery, derived from the contract only. Log, window, archive, manifest and report take
    # their text from here; Stamps lists every place the build writes it. A component with its own version keeps it.
    # Identifies states what each surface proves: the log and the report name the exact build; the window shows version
    # and stage only, which the contract keeps unique per build ($PublishedBuilds).
    param($Contract,[ValidateSet('DEV','PROD')][string]$Channel='PROD',$WorkerContracts=$null,[string[]]$PublishedBuilds=@())
    $Channel = $Channel.ToUpperInvariant()
    $check = Test-DomeniaReleaseContract $Contract $WorkerContracts $PublishedBuilds
    $errors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($message in @($check.Errors)) { $errors.Add([string]$message) }
    if ($errors.Count -eq 0) {
        $declared = @(@(Get-DomeniaMember $Contract 'Channels' @()) | ForEach-Object { [string]$_ })
        if ($declared -cnotcontains $Channel) { $errors.Add('Canal ' + $Channel + ' non prevu par le contrat.') }
    }
    $result = [ordered]@{
        Valid=$false;Errors=@();Warnings=@($check.Warnings);Product='';Version='';Stage='';Build='';Channel=$Channel
        DisplayName='';NavigationText='';ReadyText='';JournalText='';ArchiveName='';ManifestBuild='';ExeLabel='';Components=@();DistinctComponents=@();Stamps=@();Fingerprint=''
        Identifies=[pscustomobject]@{Journal='Build exact';Interface='Version et etape (uniques par build)';Exe='Version de composant liee a son SHA-256';Rapport='Build exact'}
    }
    if ($errors.Count -gt 0) { $result.Errors = $errors.ToArray(); return [pscustomobject]$result }
    $product = ([string](Get-DomeniaMember $Contract 'Product' '')).Trim()
    $version = ([string](Get-DomeniaMember $Contract 'Version' '')).Trim()
    $stage = ([string](Get-DomeniaMember $Contract 'Stage' '')).Trim()
    $build = ([string](Get-DomeniaMember $Contract 'Build' '')).Trim()
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $distinct = New-Object 'System.Collections.Generic.List[string]'
    $exeLabel = ''
    foreach ($component in @(Get-DomeniaMember $Contract 'Components' @())) {
        if ($null -eq $component) { continue }
        $path = [string](Get-DomeniaMember $component 'Path' '')
        $name = [string](Get-DomeniaMember $component 'Name' '')
        $isDistinct = ([string](Get-DomeniaMember $component 'VersionPolicy' '') -ceq 'Distinct')
        $componentVersion = $build
        $label = $name + ' ' + $build
        if ($isDistinct) {
            $componentVersion = ([string](Get-DomeniaMember $component 'Version' '')).Trim()
            $label = $name + ' ' + $componentVersion + ' (version de composant distincte, livraison ' + $build + ')'
            $distinct.Add($path)
        }
        if ($path -ieq 'Domenia.exe') { $exeLabel = 'Domenia.exe ' + $componentVersion + ' (version de composant distincte, livraison ' + $build + ')' }
        $rows.Add([pscustomobject]@{Name=$name;Path=$path;Version=$componentVersion;Distinct=$isDistinct;Sha256=(ConvertTo-DomeniaSha256Text ([string](Get-DomeniaMember $component 'Sha256' '')));Label=$label})
    }
    $display = $product + ' ' + $version + ' ' + $stage
    $navigation = $product.ToUpperInvariant() + ' ' + $version + ' ' + [string][char]0x00B7 + ' ' + $stage
    $ready = $display + ' pret.'
    # Same form as the identity line of Get-DomeniaRuntimeHealthText in the core ("DOMENIA <version> / <build>").
    $journal = $product.ToUpperInvariant() + ' ' + $version + ' / ' + $build
    $archive = $product + '_' + $version + '_' + $stage + '_' + $Channel + '.zip'
    $result.Valid = $true
    $result.Product = $product
    $result.Version = $version
    $result.Stage = $stage
    $result.Build = $build
    $result.DisplayName = $display
    $result.NavigationText = $navigation
    $result.ReadyText = $ready
    $result.JournalText = $journal
    $result.ArchiveName = $archive
    $result.ManifestBuild = $build
    $result.ExeLabel = $exeLabel
    $result.Components = $rows.ToArray()
    $result.DistinctComponents = $distinct.ToArray()
    # The four places of the current core, the build script, the manifests and the archive name.
    $result.Stamps = @(
        [pscustomobject]@{Surface='Source.MasterBuild';Location='wad/Domenia-Core.ps1 : $script:MasterBuild';Text=$build}
        [pscustomobject]@{Surface='Source.DomeniaBuild';Location='wad/Domenia-Core.ps1 : $script:DomeniaBuild';Text=$display}
        [pscustomobject]@{Surface='Source.Navigation';Location='wad/Domenia-Core.ps1 : pied de navigation (XAML)';Text=$navigation}
        [pscustomobject]@{Surface='Source.Pret';Location='wad/Domenia-Core.ps1 : journal de demarrage';Text=$ready}
        [pscustomobject]@{Surface='Source.BuildScript';Location='tools/build_packages.py : BUILD';Text=$build}
        [pscustomobject]@{Surface='Manifeste';Location='wad/package-manifest.json et tools/prod-manifest.json : Build';Text=$build}
        [pscustomobject]@{Surface='Archive';Location='Nom de l archive ' + $Channel;Text=$archive}
    )
    $result.Fingerprint = Get-DomeniaTextHash (ConvertTo-DomeniaReleaseCanonicalText $Contract)
    return [pscustomobject]$result
}

function Test-DomeniaReleaseConsistency {
    # The log, the window, the executable and the report must name the same delivery, or the executable must be the
    # exact file (SHA-256) whose distinct component version the contract declares. Every surface is reported; a text
    # that only resembles the identity (RC1.11.01 for RC1.11.0) does not match. The log must name the exact build
    # (a ready line giving version and stage only does not identify a delivery), and any surface that names another
    # build label is incoherent even when it also carries the expected version and stage.
    param($Identity,[object[]]$Observations=@())
    $requiredSurfaces = @('Journal','Interface','Exe','Rapport')
    if (($null -eq $Identity) -or (-not [bool](Get-DomeniaMember $Identity 'Valid' $false))) {
        return [pscustomobject]@{Consistent=$false;Complete=$false;MissingSurfaces=$requiredSurfaces;Rows=@();Reason='Identite de livraison invalide : aucune comparaison possible.'}
    }
    $build = [string](Get-DomeniaMember $Identity 'Build' '')
    $exeLabel = [string](Get-DomeniaMember $Identity 'ExeLabel' '')
    $partialJournal = @([string](Get-DomeniaMember $Identity 'DisplayName' ''),[string](Get-DomeniaMember $Identity 'ReadyText' '') | Where-Object { $_ })
    $expectedBySurface = @{
        'Journal'=@($build)
        'Interface'=@([string](Get-DomeniaMember $Identity 'NavigationText' ''),[string](Get-DomeniaMember $Identity 'DisplayName' ''))
        'Rapport'=@($build)
    }
    foreach ($stamp in @(Get-DomeniaMember $Identity 'Stamps' @())) {
        $stampSurface = [string](Get-DomeniaMember $stamp 'Surface' '')
        if ($stampSurface) { $expectedBySurface[$stampSurface] = @([string](Get-DomeniaMember $stamp 'Text' '')) }
    }
    $exe = @(@(Get-DomeniaMember $Identity 'Components' @()) | Where-Object { [string](Get-DomeniaMember $_ 'Path' '') -ieq 'Domenia.exe' })
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    foreach ($observation in @($Observations)) {
        if ($null -eq $observation) { continue }
        $surface = ([string](Get-DomeniaMember $observation 'Surface' '')).Trim()
        $value = ([string](Get-DomeniaMember $observation 'Value' '')).Trim()
        $state = 'Incoherent'
        $text = ''
        $expectedText = ''
        if ($surface -ieq 'Exe') {
            $sha = ConvertTo-DomeniaSha256Text ([string](Get-DomeniaMember $observation 'Sha256' ''))
            if ($exe.Count -ne 1) { $text = 'Domenia.exe non declare par le contrat.' }
            else {
                $exeVersion = [string](Get-DomeniaMember $exe[0] 'Version' '')
                $exeSha = [string](Get-DomeniaMember $exe[0] 'Sha256' '')
                $expectedText = $exeVersion
                if (-not $sha) { $state = 'Non verifie'; $text = 'Empreinte de l executable non fournie : comparaison impossible.' }
                elseif ($sha -cne $exeSha) { $text = 'Executable different de celui declare par le contrat (empreinte SHA-256).' }
                elseif ($value -and ($value -cne $exeVersion)) { $text = 'Version lue ' + $value + ' differente de la version declaree ' + $exeVersion + '.' }
                else { $state = 'Version distincte declaree'; $text = $exeLabel }
            }
        }
        elseif ($expectedBySurface.ContainsKey($surface)) {
            $candidates = @(@($expectedBySurface[$surface]) | Where-Object { -not [string]::IsNullOrEmpty([string]$_) })
            $expectedText = [string]::Join(' ou ',[string[]]$candidates)
            $foreignLabels = @(@(Get-DomeniaBuildLabelTokens $value) | Where-Object { [string]$_ -cne $build })
            $hit = $false
            foreach ($candidate in $candidates) {
                if ($value -ceq [string]$candidate) { $hit = $true; break }
                # A line of log or a window title may carry the identity among other words: match it as a whole token.
                $pattern = '(?<![A-Za-z0-9._-])' + [regex]::Escape([string]$candidate) + '(?![A-Za-z0-9_-]|\.[A-Za-z0-9])'
                if ($value -and [regex]::IsMatch($value,$pattern)) { $hit = $true; break }
            }
            $partial = $false
            if ((-not $hit) -and ($surface -ceq 'Journal')) {
                foreach ($candidate in $partialJournal) {
                    $pattern = '(?<![A-Za-z0-9._-])' + [regex]::Escape([string]$candidate) + '(?![A-Za-z0-9_-]|\.[A-Za-z0-9])'
                    if ($value -and [regex]::IsMatch($value,$pattern)) { $partial = $true; break }
                }
            }
            if ($foreignLabels.Count -gt 0) { $text = 'Autre livraison nommee : ' + [string]::Join(', ',[string[]]$foreignLabels) + ' au lieu de ' + $build + '.' }
            elseif ($hit) { $state = 'Identique'; $text = 'Meme livraison : ' + $build + '.' }
            elseif ($partial) { $state = 'Non identifie'; $text = 'Version et etape seulement : le journal doit nommer le build ' + $build + '.' }
            else { $text = 'Attendu : ' + $expectedText + '.' }
        }
        else { $state = 'Non reconnu'; $text = 'Surface inconnue : ' + $surface + '.' }
        $ok = ($state -ceq 'Identique') -or ($state -ceq 'Version distincte declaree')
        if ($surface) { $seen[$surface] = $true }
        $rows.Add([pscustomobject]@{Surface=$surface;Observed=$value;Expected=$expectedText;State=$state;Ok=$ok;Detail=$text})
    }
    $missing = @($requiredSurfaces | Where-Object { -not $seen.ContainsKey($_) })
    $allOk = (@($rows | Where-Object { -not $_.Ok }).Count -eq 0)
    $complete = ($missing.Count -eq 0)
    $reason = 'Journal, interface, executable et rapport designent la livraison ' + $build + '.'
    if (-not $allOk) { $reason = 'Livraisons differentes selon la surface : voir le detail.' }
    elseif (-not $complete) { $reason = 'Surface non observee : ' + [string]::Join(', ',[string[]]$missing) + '.' }
    return [pscustomobject]@{Consistent=($complete -and $allOk);Complete=$complete;MissingSurfaces=$missing;Rows=$rows.ToArray();Reason=$reason}
}

# ---------------------------------------------------------------- D111 standalone PROD
function Test-DomeniaProdLayout {
    # PROD is Domenia.exe plus wad/ and nothing else. Unblocking lives in wad/Support. No test, preview, fixture, demo,
    # tool, private data or launcher script is shipped or required, wherever it sits in the tree. $Paths are the relative
    # paths of the extracted PROD tree; $RuntimePaths are the files the runtime opens at start-up (Domenia-Start.ps1
    # list): each must be shipped. $Manifest (optional, the PROD manifest) turns the check into a positive list: only
    # its Runtime files and wad/package-manifest.json may be present.
    param([string[]]$Paths=@(),[string[]]$RuntimePaths=@(),$Manifest=$null)
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $present = @{}
    $roots = @{}
    $declared = $null
    if ($null -ne $Manifest) {
        $declared = @{'wad/package-manifest.json'=$true}
        foreach ($file in @(Get-DomeniaMember $Manifest 'Files' @())) {
            $declaredPath = ([string](Get-DomeniaMember $file 'Path' '')).Replace('\','/').Trim()
            if ($declaredPath -and ((Get-DomeniaMember $file 'Runtime' $false) -eq $true)) { $declared[$declaredPath] = $true }
        }
    }
    foreach ($raw in @($Paths)) {
        $path = ([string]$raw).Replace('\','/').Trim()
        if (-not $path) { continue }
        if (-not (Test-DomeniaReleaseRelativePath $path)) { $errors.Add('Chemin invalide dans PROD : <' + [string]$raw + '>.'); continue }
        if ($present.ContainsKey($path)) { $errors.Add('Chemin en double dans PROD (Windows ignore la casse) : ' + $path + '.'); continue }
        $present[$path] = $true
        $segments = $path.Split([char]'/')
        $first = $segments[0]
        if (-not $roots.ContainsKey($first)) {
            $roots[$first] = $true
            if (($first -cne 'Domenia.exe') -and ($first -cne 'wad')) { $errors.Add('Element non autorise a la racine PROD : ' + $first + '.') }
        }
        if (($first -ceq 'Domenia.exe') -and ($segments.Count -gt 1)) { $errors.Add('Domenia.exe doit etre un fichier a la racine : ' + $path + '.') }
        foreach ($segment in $segments) {
            if ($segment -in @('tests','test','tools','docs','demo','demos','engineering','data','history','backups','maintenance','fixtures','fixture','mocks','samples','preview')) { $errors.Add('Dossier de developpement ou de donnees dans PROD : ' + $path + '.'); break }
        }
        $leaf = $segments[$segments.Count - 1]
        # FI-06: the installer runs no test suite and ships in PROD, at this single path only.
        $shippedInstaller = ($path -ceq 'wad/Support/INSTALLER-MISE-A-JOUR.ps1')
        if (($leaf -match '^(?i:TESTER|APERCU|DEMO|QUALIFIER|LANCER|VERIFIER|INSTALLER)[-_]') -and (-not $shippedInstaller)) { $errors.Add('Lanceur, test, installateur ou demonstration dans PROD : ' + $path + '.') }
        elseif (($leaf -match '^(?i:Test|Tests)[-_.]') -or ($leaf -match '(?i)\.Tests?\.ps1$') -or ($leaf -match '^(?i:Preview|Demo|Mock|Fake|Fixture|Sample)')) { $errors.Add('Test, apercu, jeu d essai ou demonstration dans PROD : ' + $path + '.') }
        if (($leaf -match '(?i)\.(cmd|bat|vbs)$') -and (-not $path.StartsWith('wad/Support/',[StringComparison]::Ordinal))) { $errors.Add('Script de lancement hors de wad/Support : ' + $path + '.') }
        if (($null -ne $declared) -and (-not $declared.ContainsKey($path))) { $errors.Add('Fichier non declare runtime par le manifeste PROD : ' + $path + '.') }
    }
    # Domenia-Start.ps1 opens the lifecycle lock with FileMode.Open: without it PROD cannot start.
    foreach ($required in @('Domenia.exe','wad/Domenia-Start.ps1','wad/Domenia-Modules.ps1','wad/Domenia-Core.ps1','wad/package-manifest.json','wad/Support/DEBLOQUER_TOUT.cmd','wad/Support/.lifecycle.lock')) {
        if (-not $present.ContainsKey($required)) { $errors.Add('Fichier requis absent de PROD : ' + $required + '.') }
    }
    foreach ($raw in @($RuntimePaths)) {
        $path = ([string]$raw).Replace('\','/').Trim()
        if ($path -and (-not $present.ContainsKey($path))) { $errors.Add('Fichier necessaire au demarrage absent de PROD : ' + $path + '.') }
    }
    $rootNames = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in @($roots.Keys)) { $rootNames.Add([string]$key) }
    $rootNames.Sort([StringComparer]::Ordinal)
    return [pscustomobject]@{Valid=($errors.Count -eq 0);Errors=$errors.ToArray();RootEntries=$rootNames.ToArray();Files=$present.Count}
}

# ---------------------------------------------------------------- D112 reproducible DEV
function Compare-DomeniaRebuildManifest {
    # A rebuild made from the documented commit and environment must name every component it contains: same build,
    # same files, same SHA-256, and every binary dependency pinned by the contract (path and SHA-256). Each difference
    # is reported file by file; nothing is assumed identical.
    param($Reference,$Rebuilt,$Environment=$null,$Contract=$null)
    $differences = New-Object 'System.Collections.Generic.List[object]'
    $unidentified = New-Object 'System.Collections.Generic.List[string]'
    $unpinned = New-Object 'System.Collections.Generic.List[string]'
    $environmentErrors = New-Object 'System.Collections.Generic.List[string]'
    $before = @{}
    foreach ($file in @(Get-DomeniaMember $Reference 'Files' @())) {
        $path = [string](Get-DomeniaMember $file 'Path' '')
        if ($path) { $before[$path] = ConvertTo-DomeniaSha256Text ([string](Get-DomeniaMember $file 'Sha256' '')) }
    }
    $pins = @{}
    foreach ($component in @(Get-DomeniaMember $Contract 'Components' @())) {
        $pinPath = [string](Get-DomeniaMember $component 'Path' '')
        if ($pinPath) { $pins[$pinPath] = ConvertTo-DomeniaSha256Text ([string](Get-DomeniaMember $component 'Sha256' '')) }
    }
    $after = @{}
    foreach ($file in @(Get-DomeniaMember $Rebuilt 'Files' @())) {
        $path = [string](Get-DomeniaMember $file 'Path' '')
        $sha = ConvertTo-DomeniaSha256Text ([string](Get-DomeniaMember $file 'Sha256' ''))
        if ((-not (Test-DomeniaReleaseRelativePath $path)) -or (-not $sha)) {
            $label = '<sans chemin>'
            if ($path) { $label = $path }
            $unidentified.Add($label)
            continue
        }
        $after[$path] = $sha
        # Binaries are not produced by the build: they are dependencies and must be pinned by the contract.
        if ($path -match '(?i)\.(exe|dll)$') {
            if ($null -eq $Contract) { $unpinned.Add($path + ' (contrat absent)') }
            elseif (-not $pins.ContainsKey($path)) { $unpinned.Add($path + ' (non declare)') }
            elseif ([string]$pins[$path] -cne $sha) { $unpinned.Add($path + ' (empreinte differente de celle du contrat)') }
        }
    }
    $paths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in @($before.Keys)) { $paths.Add([string]$key) }
    foreach ($key in @($after.Keys)) { if (-not $before.ContainsKey($key)) { $paths.Add([string]$key) } }
    $paths.Sort([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $paths) {
        $inBefore = $before.ContainsKey($path)
        $inAfter = $after.ContainsKey($path)
        if ($inBefore -and (-not $inAfter)) { $differences.Add([pscustomobject]@{Path=$path;Kind='Absent';Reference=$before[$path];Rebuilt=''}) }
        elseif ($inAfter -and (-not $inBefore)) { $differences.Add([pscustomobject]@{Path=$path;Kind='Ajoute';Reference='';Rebuilt=$after[$path]}) }
        elseif ([string]$before[$path] -cne [string]$after[$path]) { $differences.Add([pscustomobject]@{Path=$path;Kind='Modifie';Reference=$before[$path];Rebuilt=$after[$path]}) }
    }
    $referenceBuild = [string](Get-DomeniaMember $Reference 'Build' '')
    $rebuiltBuild = [string](Get-DomeniaMember $Rebuilt 'Build' '')
    $buildMatches = ([bool]$referenceBuild -and ($referenceBuild -ceq $rebuiltBuild))
    if ($null -eq $Environment) { $environmentErrors.Add('Environnement de construction non documente.') }
    else {
        $commit = ([string](Get-DomeniaMember $Environment 'Commit' '')).Trim()
        if ($commit -notmatch '^[0-9a-fA-F]{40}$') { $environmentErrors.Add('Commit source absent ou invalide (40 caracteres hexadecimaux attendus).') }
        $tools = @(Get-DomeniaMember $Environment 'Tools' @())
        if ($tools.Count -eq 0) { $environmentErrors.Add('Outils de construction non declares.') }
        foreach ($tool in $tools) {
            $toolName = ([string](Get-DomeniaMember $tool 'Name' '')).Trim()
            $toolVersion = ([string](Get-DomeniaMember $tool 'Version' '')).Trim()
            if ((-not $toolName) -or (-not $toolVersion)) { $environmentErrors.Add('Outil sans nom ou sans version : <' + $toolName + '>.') }
        }
    }
    $identified = (($unidentified.Count -eq 0) -and ($unpinned.Count -eq 0) -and ($environmentErrors.Count -eq 0) -and ($after.Count -gt 0))
    return [pscustomobject]@{
        Identified=$identified;Reproducible=($identified -and $buildMatches -and ($differences.Count -eq 0));BuildMatches=$buildMatches
        Components=$after.Count;Differences=$differences.ToArray();Unidentified=$unidentified.ToArray();Unpinned=$unpinned.ToArray();EnvironmentErrors=$environmentErrors.ToArray()
    }
}

# ---------------------------------------------------------------- D113 explicit ADCC to Domenia migration
function ConvertTo-DomeniaMigrationDomain {
    # Domain identity for the migration check: DNS name in lower case. A DN made of DC= parts is converted;
    # any other DN (OU=, CN=) is not a domain and yields ''. A short NetBIOS name stays as it is.
    param([AllowNull()][AllowEmptyString()][string]$Domain)
    $text = ([string]$Domain).Trim().TrimEnd('.')
    if (-not $text) { return '' }
    if ($text -match '(?i)^DC\s*=') {
        $labels = New-Object 'System.Collections.Generic.List[string]'
        foreach ($part in $text.Split([char]',')) {
            $pair = [regex]::Match($part.Trim(),'(?i)^DC\s*=\s*(.+)$')
            if (-not $pair.Success) { return '' }
            $labels.Add($pair.Groups[1].Value.Trim())
        }
        $text = [string]::Join('.',$labels.ToArray())
    }
    elseif ($text.IndexOf([char]'=') -ge 0) { return '' }
    return $text.ToLowerInvariant()
}

function ConvertTo-DomeniaMigrationComputerKey {
    # Key of the core table user_machine_links (computer_key, as Normalize-LinkComputer builds it): text trimmed, the
    # trailing '$' of a machine account removed, first DNS label only, upper case. '' when unusable.
    param([AllowNull()][AllowEmptyString()][string]$Computer)
    $text = ([string]$Computer).Trim().Trim([char[]]@([char]34,[char]32,[char]9,[char]13,[char]10))
    if ($text.EndsWith('$',[StringComparison]::Ordinal)) { $text = $text.Substring(0,$text.Length - 1) }
    if ($text.IndexOf([char]'.') -ge 0) { $text = $text.Split([char]'.')[0] }
    return $text.ToUpperInvariant()
}

function ConvertTo-DomeniaMigrationUserLogin {
    # Same reading as Normalize-LinkUser in the core: domain prefix and UPN suffix removed; a machine account or a
    # built-in account is not a user. '' when unusable.
    param([AllowNull()][AllowEmptyString()][string]$User)
    $text = ([string]$User).Trim().Trim([char[]]@([char]34,[char]32,[char]9,[char]13,[char]10))
    if (-not $text) { return '' }
    if ($text.IndexOf([char]92) -ge 0) { $text = $text.Split([char]92)[-1] }
    if ($text.IndexOf([char]'@') -ge 0) { $text = $text.Split([char]'@')[0] }
    if ($text.EndsWith('$',[StringComparison]::Ordinal)) { return '' }
    if ($text.ToUpperInvariant() -in @('SYSTEM','LOCAL SERVICE','NETWORK SERVICE','ANONYMOUS LOGON','DWM-1','DWM-2','UMFD-0','UMFD-1','DEFAULTUSER0','ADMINISTRATEUR','ADMINISTRATOR')) { return '' }
    return $text
}

function Get-DomeniaMigrationPlan {
    # Explicit ADCC to Domenia migration plan, built on what the runtime really does:
    # - preferences: wad\ADCC.<name> is copied to wad\Domenia.<name> only when that file is absent, as
    #   INSTALLER-MISE-A-JOUR.ps1 does; the ADCC file is kept and a Domenia file already created always wins;
    # - database: Get-DomeniaDatabasePath adopts ADCC.db IN PLACE (no copy) and Initialize-DomeniaDatabase adds the
    #   domenia_schema revision after Backup-DomeniaDatabase. The file keeps its name but is modified: adoption needs
    #   schema_version 11, the same domain (base_dn of sync_state) and a backup;
    # - stores: Import-DomeniaLegacyStoreIfNeeded fills one Domenia table from objets.tsv, parc.tsv, recherches.tsv,
    #   secrets-etat.tsv only when the four target tables are empty. Existing workstation links are never replaced.
    #   The caller canonicalizes links through Relations before planning: declared assignment, then most recent.
    # $Legacy: ConfigFiles (wad\ADCC.* names), Domain (domain of the TSV/CSV data, read by the caller from their DN
    # columns), Stores (Kind = Objets, Parc, Recherches, Secrets or Liens; Path; Rows; Links for Liens).
    # $Current: ConfigFiles (wad\Domenia.* names), Domain, Database (Name, SchemaVersion, DomeniaSchema, BaseDn of the
    # file Get-DomeniaDatabasePath selected; $null when none exists yet), Tables (table -> row count), Links.
    # A refused plan writes nothing: every write it would have made is listed as 'Reporter'.
    param(
        $Legacy,$Current,
        [string[]]$SupportedSchemaVersions=@('11'),
        [string[]]$PreservedNames=@('Domenia.config.json','Domenia.login-mode.cfg','Domenia.theme.cfg','Domenia.ui-profile.cfg'),
        [ValidateSet('Explicit','Startup')][string]$Trigger='Explicit'
    )
    $steps = New-Object 'System.Collections.Generic.List[object]'
    $trace = New-Object 'System.Collections.Generic.List[object]'
    $blockers = New-Object 'System.Collections.Generic.List[string]'
    $tableOf = @{Objets='ad_objects';Parc='park_state';Liens='user_machine_links';Recherches='user_scan_history';Secrets='secret_state'}
    $currentDomain = ConvertTo-DomeniaMigrationDomain ([string](Get-DomeniaMember $Current 'Domain' ''))
    $addStep = {
        param([string]$Kind,[string]$Action,[string]$Source,[string]$Target,[string]$Reason,[string]$Key,$Item)
        $steps.Add([pscustomobject]@{Kind=$Kind;Action=$Action;Planned=$Action;Source=$Source;Target=$Target;Reason=$Reason;Key=$Key;Item=$Item})
    }
    $checkDomain = {
        param([string]$Origin,[string]$Domain)
        if (-not $Domain) { $blockers.Add('Domaine ' + $Origin + ' non identifie : aucune reprise de donnees.'); return }
        if (-not $currentDomain) { $blockers.Add('Domaine courant inconnu : reprise des donnees reportee.'); return }
        if ($Domain -cne $currentDomain) { $blockers.Add('Domaine different (' + $Origin + ' : ' + $Domain + ' ; Domenia : ' + $currentDomain + ') : aucune fusion entre domaines.') }
    }
    if ($Trigger -cne 'Explicit') { $blockers.Add('Reprise des anciennes donnees non lancee au demarrage : elle part seulement d un geste explicite de l operateur.') }

    # Preferences kept by the installer.
    $preserved = @{}
    foreach ($name in @($PreservedNames)) { if ($name) { $preserved[[string]$name] = $true } }
    $currentConfig = @{}
    foreach ($name in @(Get-DomeniaMember $Current 'ConfigFiles' @())) { if ($name) { $currentConfig[[string]$name] = $true } }
    foreach ($name in @(Get-DomeniaMember $Legacy 'ConfigFiles' @())) {
        $sourceName = [string]$name
        if (-not $sourceName) { continue }
        $found = [regex]::Match($sourceName,'^(?i:ADCC)\.([A-Za-z0-9][A-Za-z0-9._-]*)$')
        if (-not $found.Success) { & $addStep 'Configuration' 'Ignorer' $sourceName '' 'Nom non reconnu comme preference historique : fichier conserve, non repris.' '' $null; continue }
        $targetName = 'Domenia.' + $found.Groups[1].Value
        if (-not $preserved.ContainsKey($targetName)) { & $addStep 'Configuration' 'Ignorer' $sourceName '' 'Fichier historique sans equivalent Domenia : conserve, non repris.' '' $null; continue }
        if ($currentConfig.ContainsKey($targetName)) {
            & $addStep 'Configuration' 'Conserver' $sourceName $targetName 'Configuration Domenia deja presente : elle n est pas ecrasee.' $targetName $null
            $trace.Add([pscustomobject]@{Ancien=$sourceName;Nouveau=$targetName;Decision='Non repris : configuration Domenia conservee'})
            continue
        }
        $currentConfig[$targetName] = $true
        & $addStep 'Configuration' 'Copier' $sourceName $targetName 'Copie sous le nom Domenia ; le fichier historique est conserve.' $targetName $null
        $trace.Add([pscustomobject]@{Ancien=$sourceName;Nouveau=$targetName;Decision='Repris sous le nouveau nom ; fichier historique conserve'})
    }

    # Database selected by the core: Domenia.db, or ADCC.db adopted in place.
    $database = Get-DomeniaMember $Current 'Database' $null
    if ($null -ne $database) {
        $databaseName = [string](Get-DomeniaMember $database 'Name' 'Domenia.db')
        $schemaVersion = ([string](Get-DomeniaMember $database 'SchemaVersion' '')).Trim()
        $revision = ([string](Get-DomeniaMember $database 'DomeniaSchema' '')).Trim()
        if ((-not $schemaVersion) -or ($SupportedSchemaVersions -cnotcontains $schemaVersion)) {
            $blockers.Add('Version de base non prise en charge : <' + $schemaVersion + '>. Base ' + $databaseName + ' conservee telle quelle, aucune ecriture ; migration explicite requise.')
            & $addStep 'Base' 'Refuser' $databaseName '' 'Version de schema non prise en charge : base intacte.' '' $null
        }
        elseif ($revision -and ($revision -cne '1')) {
            $blockers.Add('Revision Domenia de la base non prise en charge : <' + $revision + '>. Base ' + $databaseName + ' intacte.')
            & $addStep 'Base' 'Refuser' $databaseName '' 'Revision Domenia inconnue : base intacte.' '' $null
        }
        elseif (-not $revision) {
            & $checkDomain ('de la base ' + $databaseName) (ConvertTo-DomeniaMigrationDomain ([string](Get-DomeniaMember $database 'BaseDn' '')))
            & $addStep 'Base' 'Adopter' $databaseName $databaseName 'Base historique adoptee sur place apres sauvegarde verifiee : ajout de la revision domenia_schema et de la table domenia_provenance. Le fichier garde son nom ; aucune donnee supprimee ni recreee.' $databaseName $null
            $trace.Add([pscustomobject]@{Ancien=$databaseName;Nouveau=($databaseName + ' (adoptee sur place)');Decision='Nom historique conserve ; fichier modifie apres sauvegarde (revision domenia_schema ajoutee)'})
        }
    }

    # TSV and CSV stores: four empty tables; existing workstation links are preserved.
    $tables = Get-DomeniaMember $Current 'Tables' $null
    $legacyDomain = ConvertTo-DomeniaMigrationDomain ([string](Get-DomeniaMember $Legacy 'Domain' ''))
    $marker = [string](Get-DomeniaMember $Legacy 'Marker' '')
    if (-not $marker) { $marker = Get-DomeniaTextHash ($Legacy | ConvertTo-Json -Depth 12 -Compress) }
    $existingMarker = [string](Get-DomeniaMember $Current 'MigrationMarker' '')
    $already = ($existingMarker -and ($existingMarker -ceq $marker))
    if ($existingMarker -and (-not $already)) { $blockers.Add('Une autre reprise de donnees a deja ete appliquee : aucun ajout automatique.') }
    $stores = @(@(Get-DomeniaMember $Legacy 'Stores' @()) | Where-Object { $null -ne $_ })
    if ($stores.Count -gt 0 -and (-not $already)) {
        foreach ($tableName in @('ad_objects','park_state','user_scan_history','secret_state')) {
            $n = Get-DomeniaReleaseMapValue $tables $tableName $null
            if ($null -eq $n) { $blockers.Add('Etat de la table ' + $tableName + ' inconnu.') }
            elseif ([long]$n -gt 0) { $blockers.Add('La table ' + $tableName + ' contient deja des donnees : reprise refusee.') }
        }
    }
    $existingComputers = @{}
    foreach ($link in @(Get-DomeniaMember $Current 'Links' @())) {
        $key = ConvertTo-DomeniaMigrationComputerKey ([string](Get-DomeniaMember $link 'Computer' ''))
        if ($key) { $existingComputers[$key] = $true }
    }
    $taken = @{}
    $domainChecked = $false
    foreach ($store in @(Get-DomeniaMember $Legacy 'Stores' @())) {
        if ($null -eq $store) { continue }
        $kind = [string](Get-DomeniaMember $store 'Kind' '')
        $path = [string](Get-DomeniaMember $store 'Path' '')
        $leaf = $path.Replace('/','\').Split([char]92)[-1]
        if (-not $tableOf.ContainsKey($kind)) { & $addStep 'Source' 'Ignorer' $path '' 'Source historique non reconnue : conservee, non reprise.' '' $null; continue }
        $kind = [string]@($tableOf.Keys | Where-Object { $_ -ieq $kind })[0]
        $table = [string]$tableOf[$kind]
        $links = @(@(Get-DomeniaMember $store 'Links' @()) | Where-Object { $null -ne $_ })
        $rows = 0
        if ($kind -ceq 'Liens') { $rows = $links.Count }
        else { [void][int]::TryParse([string](Get-DomeniaMember $store 'Rows' 0),[ref]$rows) }
        if ($already) { & $addStep 'Source' 'Ignorer' $path $table 'Reprise identique deja appliquee : rien a ecrire.' '' $null; continue }
        if ($rows -le 0) { & $addStep 'Source' 'Ignorer' $path $table 'Source vide : rien a reprendre.' '' $null; continue }
        $filled = Get-DomeniaReleaseMapValue $tables $table $null
        $count = -1
        if ($null -ne $filled) { [void][int]::TryParse([string]$filled,[ref]$count) }
        if ($count -lt 0) { & $addStep 'Source' 'Ignorer' $path $table ('Etat de la table ' + $table + ' non fourni : rien n est repris.') '' $null; continue }
        if (($count -gt 0) -and ($kind -cne 'Liens')) {
            & $addStep 'Source' 'Ignorer' $path $table ('Table ' + $table + ' deja alimentee dans Domenia : aucune fusion ni remplacement.') '' $null
            $trace.Add([pscustomobject]@{Ancien=$leaf;Nouveau=$table;Decision='Non repris : donnees Domenia conservees'})
            continue
        }
        if ($taken.ContainsKey($table)) { & $addStep 'Source' 'Ignorer' $path $table ('Une source est deja reprise pour ' + $table + ' : la premiere trouvee est retenue, comme dans le coeur.') '' $null; continue }
        $taken[$table] = $true
        if (-not $domainChecked) { & $checkDomain 'des fichiers historiques' $legacyDomain; $domainChecked = $true }
        $trace.Add([pscustomobject]@{Ancien=$leaf;Nouveau=$table;Decision=('Repris dans la table ' + $table + ' ; fichier historique conserve')})
        if ($kind -cne 'Liens') {
            & $addStep 'Source' 'Importer' $path $table ([string]$rows + ' ligne(s) reprises dans une table vide ; fichier historique conserve.') $table ([pscustomobject]@{Table=$table;Rows=$rows})
            continue
        }
        # Links: canonical as ConvertTo-DomeniaCanonicalLinks, most recent first, one per computer.
        $indexed = New-Object 'System.Collections.Generic.List[object]'
        for ($i = 0; $i -lt $links.Count; $i++) { $indexed.Add([pscustomobject]@{Index=$i;When=[string](Get-DomeniaMember $links[$i] 'When' '');Link=$links[$i]}) }
        $ordered = @($indexed.ToArray() | Sort-Object -Property @{Expression={$_.When};Descending=$true},@{Expression={$_.Index};Ascending=$true})
        $seenComputers = @{}
        foreach ($entry in $ordered) {
            $link = $entry.Link
            $user = ConvertTo-DomeniaMigrationUserLogin ([string](Get-DomeniaMember $link 'UserLogin' ''))
            $computerKey = ConvertTo-DomeniaMigrationComputerKey ([string](Get-DomeniaMember $link 'Computer' ''))
            $label = [string](Get-DomeniaMember $link 'UserLogin' '') + ' / ' + [string](Get-DomeniaMember $link 'Computer' '')
            if ((-not $user) -or (-not $computerKey)) { & $addStep 'Lien' 'Rejeter' $label '' 'Lien incomplet : utilisateur ou poste absent ou non reconnu.' '' $null; continue }
            if ($seenComputers.ContainsKey($computerKey)) { & $addStep 'Lien' 'Ignorer' $label '' 'Poste deja repris depuis un lien plus recent : la table garde un lien par poste.' $computerKey $null; continue }
            $seenComputers[$computerKey] = $true
            if ($existingComputers.ContainsKey($computerKey)) {
                & $addStep 'Lien' 'Conserver' $label $table 'Association Domenia existante : aucun remplacement.' $computerKey $null
                continue
            }
            & $addStep 'Lien' 'Ajouter' $label $table 'Lien repris avec sa source et sa date d origine.' $computerKey $link
        }
    }

    $allowed = ($blockers.Count -eq 0)
    if (-not $allowed) {
        foreach ($step in $steps) {
            if ($step.Action -in @('Copier','Adopter','Importer','Ajouter')) { $step.Action = 'Reporter'; $step.Reason = 'Reporte, rien n est ecrit : ' + $step.Reason }
        }
    }
    $all = $steps.ToArray()
    $copy = @($all | Where-Object { $_.Action -ceq 'Copier' }).Count
    $adopt = @($all | Where-Object { $_.Action -ceq 'Adopter' }).Count
    $import = @($all | Where-Object { $_.Action -ceq 'Importer' }).Count
    $add = @($all | Where-Object { $_.Action -ceq 'Ajouter' }).Count
    return [pscustomobject]@{
        Allowed=$allowed;Blockers=$blockers.ToArray();Steps=$all;Trace=$trace.ToArray();Marker=$marker;Already=[bool]$already
        CopyCount=$copy;AdoptCount=$adopt;ImportCount=$import;AddCount=$add
        KeepCount=@($all | Where-Object { $_.Action -ceq 'Conserver' }).Count
        SkipCount=@($all | Where-Object { $_.Action -ceq 'Ignorer' }).Count
        RefusedCount=@($all | Where-Object { $_.Action -ceq 'Refuser' }).Count
        RejectedCount=@($all | Where-Object { $_.Action -ceq 'Rejeter' }).Count
        DeferredCount=@($all | Where-Object { $_.Action -ceq 'Reporter' }).Count
        WriteCount=($copy + $adopt + $import + $add);RequiresBackup=(($adopt + $import + $add) -gt 0)
        ModifiesLegacyDatabase=($adopt -gt 0);SourceKept=(@($all | Where-Object { $_.Action -in @('Supprimer','Deplacer') }).Count -eq 0)
    }
}

function Get-DomeniaMigratedState {
    # The Domenia state a migration plan would produce, computed without touching anything. A refused plan changes
    # nothing. Copied names are added, an adopted base gets its domenia_schema revision, an imported table gets its
    # rows, links are appended; nothing present before is removed or replaced.
    param($Current,$Plan)
    $configs = New-Object 'System.Collections.Generic.List[string]'
    $seen = @{}
    foreach ($name in @(Get-DomeniaMember $Current 'ConfigFiles' @())) {
        if ($name -and (-not $seen.ContainsKey([string]$name))) { $seen[[string]$name] = $true; $configs.Add([string]$name) }
    }
    $links = New-Object 'System.Collections.Generic.List[object]'
    foreach ($link in @(Get-DomeniaMember $Current 'Links' @())) { if ($null -ne $link) { $links.Add($link) } }
    $sourceTables = Get-DomeniaMember $Current 'Tables' $null
    $tables = @{}
    foreach ($table in @('ad_objects','park_state','user_machine_links','user_scan_history','secret_state')) {
        $value = Get-DomeniaReleaseMapValue $sourceTables $table $null
        if ($null -ne $value) { $tables[$table] = [int]$value }
    }
    $database = Get-DomeniaMember $Current 'Database' $null
    $applied = ($null -ne $Plan) -and ((Get-DomeniaMember $Plan 'Allowed' $false) -eq $true)
    if ($applied) {
        foreach ($step in @(Get-DomeniaMember $Plan 'Steps' @())) {
            $action = [string](Get-DomeniaMember $step 'Action' '')
            $target = [string](Get-DomeniaMember $step 'Target' '')
            if (($action -ceq 'Copier') -and $target -and (-not $seen.ContainsKey($target))) { $seen[$target] = $true; $configs.Add($target) }
            elseif (($action -ceq 'Adopter') -and ($null -ne $database)) {
                $database = [pscustomobject]@{Name=[string](Get-DomeniaMember $database 'Name' '');SchemaVersion=[string](Get-DomeniaMember $database 'SchemaVersion' '');DomeniaSchema='1';BaseDn=[string](Get-DomeniaMember $database 'BaseDn' '')}
            }
            elseif ($action -ceq 'Importer') { $item = Get-DomeniaMember $step 'Item' $null; $tables[$target] = [int](Get-DomeniaMember $item 'Rows' 0) }
            elseif ($action -ceq 'Ajouter') {
                $item = Get-DomeniaMember $step 'Item' $null
                if ($null -ne $item) { $links.Add($item); $tables[$target] = 1 + [int](Get-DomeniaMember $tables $target 0) }
            }
        }
    }
    $migrationMarker = [string](Get-DomeniaMember $Current 'MigrationMarker' '')
    if ($applied -and ([int]$Plan.ImportCount + [int]$Plan.AddCount -gt 0)) { $migrationMarker = [string]$Plan.Marker }
    return [pscustomobject]@{Domain=[string](Get-DomeniaMember $Current 'Domain' '');ConfigFiles=$configs.ToArray();Database=$database;Tables=$tables;Links=$links.ToArray();MigrationMarker=$migrationMarker}
}

function Test-DomeniaMigrationIdempotent {
    # Runs the plan (only when it is allowed), then plans again on the result: a second run must have nothing to write,
    # no computer may hold two links because of the migration, no link may be lost, and no Domenia configuration
    # present before may be a copy target.
    param($Legacy,$Current,[string[]]$SupportedSchemaVersions=@('11'),[ValidateSet('Explicit','Startup')][string]$Trigger='Explicit')
    $first = Get-DomeniaMigrationPlan $Legacy $Current $SupportedSchemaVersions -Trigger $Trigger
    $after = Get-DomeniaMigratedState $Current $first
    $second = Get-DomeniaMigrationPlan $Legacy $after $SupportedSchemaVersions -Trigger $Trigger
    $existing = @{}
    foreach ($name in @(Get-DomeniaMember $Current 'ConfigFiles' @())) { if ($name) { $existing[[string]$name] = $true } }
    $overwritten = @(@($first.Steps) | Where-Object { ($_.Action -ceq 'Copier') -and $existing.ContainsKey([string]$_.Target) } | ForEach-Object { [string]$_.Target })
    $before = @{}
    foreach ($link in @(Get-DomeniaMember $Current 'Links' @())) {
        if ($null -eq $link) { continue }
        $key = ConvertTo-DomeniaMigrationComputerKey ([string](Get-DomeniaMember $link 'Computer' ''))
        $before[$key] = 1 + [int](Get-DomeniaMember $before $key 0)
    }
    $counts = @{}
    foreach ($link in @($after.Links)) {
        if ($null -eq $link) { continue }
        $key = ConvertTo-DomeniaMigrationComputerKey ([string](Get-DomeniaMember $link 'Computer' ''))
        $counts[$key] = 1 + [int](Get-DomeniaMember $counts $key 0)
    }
    $duplicates = @(@($counts.Keys) | Where-Object { ([int]$counts[$_] -gt 1) -and ([int]$counts[$_] -gt [int](Get-DomeniaMember $before $_ 0)) })
    $lost = @(@($before.Keys) | Where-Object { [int](Get-DomeniaMember $counts $_ 0) -lt [int]$before[$_] }).Count
    $idempotent = (($second.WriteCount -eq 0) -and ($overwritten.Count -eq 0) -and ($duplicates.Count -eq 0) -and ($lost -eq 0))
    return [pscustomobject]@{Idempotent=$idempotent;Applied=[bool]$first.Allowed;FirstWrites=$first.WriteCount;SecondWrites=$second.WriteCount;DuplicateLinks=$duplicates;OverwrittenConfig=$overwritten;LostLinks=$lost;First=$first;Second=$second;State=$after}
}

# ---------------------------------------------------------------- D114 version-level atomic installation
function Get-DomeniaInstallPlan {
    # Version-level installation compatible with the byte-identical Domenia.exe (it always starts wad\Domenia-Start.ps1):
    # the complete new version is prepared next to the active one and verified file by file; then, under the exclusive
    # lifecycle lock, the previous code is saved, the pending marker is written, files are replaced (manifest last), the
    # whole set is checked and the marker is removed. Removing the marker is the single activation point: before it every
    # launcher refuses (Domenia.exe and Domenia-Start.ps1 test the marker), after it the new version is complete.
    # $StagedHashes holds the SHA-256 read on the staged copy (path -> hash).
    param($Manifest,[Collections.IDictionary]$StagedHashes=$null,[AllowEmptyString()][string]$ActiveBuild='',[bool]$LauncherRunning=$false,[bool]$PendingInstall=$false,[bool]$PreviousIntact=$true)
    $blockers = New-Object 'System.Collections.Generic.List[string]'
    $checks = New-Object 'System.Collections.Generic.List[object]'
    $preserved = New-Object 'System.Collections.Generic.List[string]'
    $extra = New-Object 'System.Collections.Generic.List[string]'
    $newBuild = [string](Get-DomeniaMember $Manifest 'Build' '')
    $files = @(Get-DomeniaMember $Manifest 'Files' @())
    if (-not $newBuild) { $blockers.Add('Build du manifeste absent : version a installer non identifiee.') }
    if ($files.Count -eq 0) { $blockers.Add('Manifeste sans fichier : rien a installer.') }
    if ($newBuild -and ($newBuild -ceq $ActiveBuild)) { $blockers.Add('Version ' + $newBuild + ' deja active : rien a installer.') }
    if ($PendingInstall) { $blockers.Add('Installation precedente inachevee : la terminer ou restaurer la version precedente avant une nouvelle installation.') }
    $declared = @{}
    foreach ($file in $files) {
        $path = [string](Get-DomeniaMember $file 'Path' '')
        $expected = ConvertTo-DomeniaSha256Text ([string](Get-DomeniaMember $file 'Sha256' ''))
        $keep = [bool](Get-DomeniaMember $file 'PreserveExisting' $false)
        if ((-not (Test-DomeniaReleaseRelativePath $path)) -or (-not $expected)) { $blockers.Add('Entree de manifeste invalide : <' + $path + '>.'); continue }
        if ($path -match '^(?i:wad/data)(/|$)') { $blockers.Add('Le manifeste vise wad/data : les donnees ne font jamais partie d une installation.'); continue }
        $declared[$path] = $true
        if ($keep) { $preserved.Add($path) }
        $actual = ''
        $state = 'Non verifie'
        if ($null -ne $StagedHashes) {
            if (Test-DomeniaReleaseMapKey $StagedHashes $path) { $actual = ConvertTo-DomeniaSha256Text ([string]$StagedHashes[$path]) }
            if (-not $actual) { $state = 'Absent' }
            elseif ($actual -ceq $expected) { $state = 'Conforme' }
            elseif ($keep) { $state = 'Conserve' }
            else { $state = 'Modifie' }
        }
        $checks.Add([pscustomobject]@{Path=$path;Expected=$expected;Actual=$actual;State=$state})
    }
    if ($null -eq $StagedHashes) { $blockers.Add('Empreintes de la preparation non verifiees : la bascule attend la verification.') }
    else {
        foreach ($key in @($StagedHashes.Keys)) { if ((-not $declared.ContainsKey([string]$key)) -and ([string]$key -cne 'wad/package-manifest.json')) { $extra.Add([string]$key) } }
        $bad = @($checks | Where-Object { ($_.State -ceq 'Absent') -or ($_.State -ceq 'Modifie') }).Count
        if ($bad -gt 0) { $blockers.Add([string]$bad + ' fichier(s) de la preparation absents ou differents du manifeste : bascule refusee, la version active reste en place.') }
        if ($extra.Count -gt 0) { $blockers.Add([string]$extra.Count + ' fichier(s) non declares dans la preparation : bascule refusee.') }
    }
    if ($LauncherRunning) { $blockers.Add('Domenia est ouvert : le verrou exclusif attend sa fermeture. Rien n est modifie.') }
    $previousLabel = $ActiveBuild
    if (-not $previousLabel) { $previousLabel = '(aucune)' }
    $steps = @(
        [pscustomobject]@{Order=1;Step='Preparer';WritesActive=$false;LauncherSees='Version active complete';Detail=('Extraire la version ' + $newBuild + ' complete dans un dossier de preparation hors du runtime actif, sur le meme volume.')}
        [pscustomobject]@{Order=2;Step='Verifier';WritesActive=$false;LauncherSees='Version active complete';Detail='Comparer chaque fichier prepare a son empreinte SHA-256 du manifeste et analyser chaque script ; refuser tout fichier absent, modifie ou non declare.'}
        [pscustomobject]@{Order=3;Step='Verrouiller';WritesActive=$false;LauncherSees='Lancement en attente du verrou';Detail='Ouvrir wad/Support/.lifecycle.lock en exclusif : impossible tant qu un lanceur le tient, et aucun lanceur ne demarre ensuite.'}
        [pscustomobject]@{Order=4;Step='Sauvegarder';WritesActive=$false;LauncherSees='Lancement en attente du verrou';Detail=('Copier le code de la version ' + $previousLabel + ' et ecrire le journal de transaction avant tout remplacement.')}
        [pscustomobject]@{Order=5;Step='Marquer';WritesActive=$true;LauncherSees='Lancement refuse : installation inachevee';Detail='Ecrire wad/Support/.update.pending de facon atomique : tout lancement est refuse a partir d ici.'}
        [pscustomobject]@{Order=6;Step='Basculer';WritesActive=$true;LauncherSees='Lancement refuse : installation inachevee';Detail=('Remplacer chaque fichier depuis la preparation verifiee (remplacement atomique par fichier, empreinte relue), manifeste en dernier. Fichiers conserves : ' + [string]::Join(', ',$preserved.ToArray()) + '.')}
        [pscustomobject]@{Order=7;Step='Valider';WritesActive=$true;LauncherSees='Nouvelle version complete';Detail='Relire toutes les empreintes du runtime installe puis supprimer le marqueur : point unique d activation.'}
        [pscustomobject]@{Order=8;Step='Liberer';WritesActive=$false;LauncherSees='Nouvelle version complete';Detail='Liberer le verrou : les lanceurs lisent la nouvelle version complete.'}
    )
    $rollbackReason = 'Retour possible vers ' + $ActiveBuild + ' : restauration du code sauvegarde, controlee par empreintes, sous le meme verrou.'
    if (-not $ActiveBuild) { $rollbackReason = 'Aucune version precedente : premier deploiement.' }
    elseif (-not $PreviousIntact) { $rollbackReason = 'Fichiers modifies depuis l installation precedente : retour refuse pour ne pas melanger.' }
    $rollback = [pscustomobject]@{Available=([bool]$ActiveBuild -and $PreviousIntact);Target=$ActiveBuild;Reason=$rollbackReason}
    return [pscustomobject]@{
        Allowed=($blockers.Count -eq 0);Blockers=$blockers.ToArray();NewBuild=$newBuild;ActiveBuild=$ActiveBuild;Steps=$steps
        Verification=$checks.ToArray();Undeclared=$extra.ToArray();Preserved=$preserved.ToArray();KeepsPrevious=([bool]$ActiveBuild);Rollback=$rollback
    }
}

function Get-DomeniaInstallTimeline {
    # Every state a launcher can observe while the installer runs, in the installer's write order. Each state is also a
    # possible interruption point. Hashes holds the runtime files on disk; Manifest is the manifest on disk at that time.
    param($ActiveManifest,$NewManifest)
    $states = New-Object 'System.Collections.Generic.List[object]'
    $hashes = @{}
    foreach ($file in @(Get-DomeniaMember $ActiveManifest 'Files' @())) {
        $path = [string](Get-DomeniaMember $file 'Path' '')
        if ($path) { $hashes[$path] = ConvertTo-DomeniaSha256Text ([string](Get-DomeniaMember $file 'Sha256' '')) }
    }
    $onDisk = $ActiveManifest
    $add = {
        param([string]$Step,[string]$Detail,[bool]$Lock,[bool]$Pending)
        $copy = @{}
        foreach ($key in @($hashes.Keys)) { $copy[$key] = $hashes[$key] }
        $states.Add([pscustomobject]@{Index=$states.Count;Step=$Step;Detail=$Detail;LockHeld=$Lock;PendingMarker=$Pending;ManifestBuild=[string](Get-DomeniaMember $onDisk 'Build' '');Manifest=$onDisk;Hashes=$copy})
    }
    & $add 'Preparer' 'Preparation hors du runtime actif' $false $false
    & $add 'Verifier' 'Empreintes de la preparation controlees' $false $false
    & $add 'Verrouiller' 'Verrou exclusif pris' $true $false
    & $add 'Sauvegarder' 'Code precedent sauvegarde, journal ecrit' $true $false
    & $add 'Marquer' 'Marqueur .update.pending ecrit' $true $true
    foreach ($file in @(Get-DomeniaMember $NewManifest 'Files' @())) {
        $path = [string](Get-DomeniaMember $file 'Path' '')
        $sha = ConvertTo-DomeniaSha256Text ([string](Get-DomeniaMember $file 'Sha256' ''))
        if ((-not $path) -or (-not $sha)) { continue }
        # A preserved file already present is kept as it is, as INSTALLER-MISE-A-JOUR.ps1 does.
        if ([bool](Get-DomeniaMember $file 'PreserveExisting' $false) -and $hashes.ContainsKey($path)) { continue }
        if ($hashes.ContainsKey($path) -and ([string]$hashes[$path] -ceq $sha)) { continue }
        $hashes[$path] = $sha
        & $add 'Basculer' $path $true $true
    }
    $onDisk = $NewManifest
    & $add 'Basculer' 'wad/package-manifest.json' $true $true
    & $add 'Valider' 'Runtime controle, marqueur supprime' $true $false
    & $add 'Liberer' 'Verrou libere' $false $false
    return $states.ToArray()
}

function Test-DomeniaLaunchSet {
    # Launcher-side check before any module is loaded: no install in progress (lock or pending marker), and every
    # immutable runtime file carries the SHA-256 the manifest on disk declares. A file matching another known build, or
    # none, is a mixture: the launch is refused before anything is read.
    param($ActiveManifest,[Collections.IDictionary]$ObservedHashes=$null,[object[]]$KnownManifests=@(),[bool]$InstallLocked=$false,[bool]$PendingMarker=$false)
    if ($InstallLocked) { return [pscustomobject]@{Allowed=$false;Mixed=$false;Missing=@();Foreign=@();Checked=0;Reason='Installation en cours : le lancement attend la fin de la bascule.'} }
    if ($PendingMarker) { return [pscustomobject]@{Allowed=$false;Mixed=$false;Missing=@();Foreign=@();Checked=0;Reason='Installation interrompue : la terminer ou restaurer la version precedente avant de lancer Domenia.'} }
    $missing = New-Object 'System.Collections.Generic.List[string]'
    $foreign = New-Object 'System.Collections.Generic.List[object]'
    $build = [string](Get-DomeniaMember $ActiveManifest 'Build' '')
    $checked = 0
    foreach ($file in @(Get-DomeniaMember $ActiveManifest 'Files' @())) {
        if (-not [bool](Get-DomeniaMember $file 'Runtime' $false)) { continue }
        if ([bool](Get-DomeniaMember $file 'PreserveExisting' $false)) { continue }
        $path = [string](Get-DomeniaMember $file 'Path' '')
        $expected = ConvertTo-DomeniaSha256Text ([string](Get-DomeniaMember $file 'Sha256' ''))
        $checked++
        $actual = ''
        if (Test-DomeniaReleaseMapKey $ObservedHashes $path) { $actual = ConvertTo-DomeniaSha256Text ([string]$ObservedHashes[$path]) }
        if (-not $actual) { $missing.Add($path); continue }
        if ($expected -and ($actual -ceq $expected)) { continue }
        $origin = 'inconnue'
        foreach ($other in @($KnownManifests)) {
            if ($null -eq $other) { continue }
            foreach ($entry in @(Get-DomeniaMember $other 'Files' @())) {
                if (([string](Get-DomeniaMember $entry 'Path' '') -ieq $path) -and ((ConvertTo-DomeniaSha256Text ([string](Get-DomeniaMember $entry 'Sha256' ''))) -ceq $actual)) { $origin = [string](Get-DomeniaMember $other 'Build' 'inconnue') }
            }
        }
        $foreign.Add([pscustomobject]@{Path=$path;Build=$origin})
    }
    $reason = 'Version ' + $build + ' complete et coherente.'
    if ($checked -eq 0) { $reason = 'Manifeste actif sans fichier runtime : lancement refuse.' }
    elseif ($foreign.Count -gt 0) { $reason = 'Versions melangees : ' + $foreign.Count + ' fichier(s) ne correspondent pas a ' + $build + '. Lancement refuse avant tout chargement.' }
    elseif ($missing.Count -gt 0) { $reason = 'Composant absent : ' + [string]::Join(', ',$missing.ToArray()) + '. Lancement refuse.' }
    return [pscustomobject]@{Allowed=(($checked -gt 0) -and ($foreign.Count -eq 0) -and ($missing.Count -eq 0));Mixed=($foreign.Count -gt 0);Missing=$missing.ToArray();Foreign=$foreign.ToArray();Checked=$checked;Reason=$reason}
}

function Resolve-DomeniaInstallInterruption {
    # Which complete version a launcher may load after the installer stopped (crash, power loss) once the step named
    # last completed. The lock dies with the installer; the pending marker does not.
    param(
        [AllowEmptyString()][string]$PreviousBuild='',[AllowEmptyString()][string]$NewBuild='',
        [ValidateSet('Aucune','Preparer','Verifier','Verrouiller','Sauvegarder','Marquer','Basculer','Valider','Liberer')][string]$LastCompletedStep='Aucune'
    )
    $order = @('Aucune','Preparer','Verifier','Verrouiller','Sauvegarder','Marquer','Basculer','Valider','Liberer')
    $index = 0
    for ($i = 0; $i -lt $order.Count; $i++) { if ($order[$i] -ieq $LastCompletedStep) { $index = $i } }
    $active = ''
    $allowed = $false
    if ($index -lt 5) {
        $active = $PreviousBuild
        $allowed = [bool]$PreviousBuild
        $action = 'Reprendre ou abandonner la preparation ; la version active n a pas ete modifiee.'
        $text = 'Interruption avant toute ecriture dans le runtime : la version ' + $PreviousBuild + ' reste active et complete ; la preparation est ignoree par le lanceur.'
        if (-not $PreviousBuild) { $text = 'Interruption avant la bascule d un premier deploiement : aucune version active.' }
    }
    elseif ($index -lt 7) {
        $action = 'Restaurer la version ' + $PreviousBuild + ' depuis la sauvegarde (controle par empreintes) ou terminer l installation ; aucun lancement entre-temps.'
        $text = 'Installation interrompue pendant la bascule : le marqueur .update.pending fait refuser tout lancement, aucun melange ne peut etre charge.'
    }
    else {
        $active = $NewBuild
        $allowed = $true
        $action = 'Aucune reprise necessaire.'
        $text = 'Bascule validee : la version ' + $NewBuild + ' complete et verifiee est active.'
        if ($PreviousBuild) { $text += ' La version ' + $PreviousBuild + ' reste sauvegardee pour un retour.' }
    }
    return [pscustomobject]@{ActiveBuild=$active;LaunchAllowed=$allowed;MarkerPresent=(($index -ge 5) -and ($index -lt 7));RollbackAvailable=(($index -ge 4) -and [bool]$PreviousBuild);Action=$action;Text=$text}
}

# ---------------------------------------------------------------- D115 data compatibility and version return
function ConvertFrom-DomeniaSchemaLabel {
    # Reads a schema position 'version/revision' (revision 0 when absent, as on an ADCC base). $null when unreadable.
    param([AllowNull()][AllowEmptyString()][string]$Label)
    $found = [regex]::Match(([string]$Label).Trim(),'^(\d{1,6})(?:/(\d{1,6}))?$')
    if (-not $found.Success) { return $null }
    $revision = 0
    if ($found.Groups[2].Success) { $revision = [int]$found.Groups[2].Value }
    return [pscustomobject]@{Version=[int]$found.Groups[1].Value;Revision=$revision;Label=([string][int]$found.Groups[1].Value + '/' + [string]$revision)}
}

function Test-DomeniaSchemaStepSafety {
    # Audits schema steps whatever produced them: a step that lowers the schema (version, then revision), a step aimed
    # at the receipts, a step that deletes or recreates an existing base, or a position that cannot be read. Lowering
    # the schema is acceptable only inside an explicit restore of a verified backup; nothing may ever touch receipts.
    param([object[]]$Steps=@(),[bool]$ExplicitRestore=$false,[bool]$DatabaseExists=$true)
    $downgrade = $false; $receipts = $false; $recreate = $false; $unreadable = $false
    $findings = New-Object 'System.Collections.Generic.List[string]'
    foreach ($step in @($Steps)) {
        if ($null -eq $step) { continue }
        $action = [string](Get-DomeniaMember $step 'Action' '')
        $target = [string](Get-DomeniaMember $step 'Target' '')
        if (($target -match '^(?i:Recus|Receipts)$') -or ($target -match '(?i)(^|[\\/])Receipts([\\/]|$)')) { $receipts = $true; $findings.Add($action + ' vise les recus.') }
        if (($target -ceq 'Base') -and ((($action -ceq 'Creer') -and $DatabaseExists) -or ($action -in @('Supprimer','Recreer','Vider')))) { $recreate = $true; $findings.Add($action + ' sur une base existante.') }
        if ($action -in @('Migrer','Restaurer')) {
            $from = ConvertFrom-DomeniaSchemaLabel ([string](Get-DomeniaMember $step 'From' ''))
            $to = ConvertFrom-DomeniaSchemaLabel ([string](Get-DomeniaMember $step 'To' ''))
            if (($null -eq $from) -or ($null -eq $to)) { $unreadable = $true; $findings.Add($action + ' : position de schema illisible.'); continue }
            if (($to.Version -lt $from.Version) -or (($to.Version -eq $from.Version) -and ($to.Revision -lt $from.Revision))) { $downgrade = $true; $findings.Add($action + ' ' + $from.Label + ' vers ' + $to.Label + ' : retour arriere.') }
        }
    }
    $silent = ($downgrade -and (-not $ExplicitRestore))
    return [pscustomobject]@{Safe=((-not $silent) -and (-not $receipts) -and (-not $recreate) -and (-not $unreadable));Downgrade=$downgrade;SilentDowngrade=$silent;TouchesReceipts=$receipts;RecreatesBase=$recreate;Unreadable=$unreadable;Findings=$findings.ToArray()}
}

function Test-DomeniaSchemaCompatibility {
    # Forward-only schema, as Initialize-DomeniaDatabase in the core: schema_version (11 today) plus the domenia_schema
    # revision (1 today, absent on an ADCC base). An older base is upgraded only after a verified backup; a newer one is
    # neither written nor downgraded by an older version; an interrupted migration waits for an explicit resume or
    # restore. No step deletes or recreates an existing base, and receipts (stored apart) are never a step target.
    param(
        [AllowEmptyString()][string]$DatabaseVersion='',
        [AllowEmptyString()][string]$DatabaseRevision='',
        [ValidateRange(1,100000)][int]$ApplicationVersion=11,
        [ValidateRange(1,100000)][int]$ApplicationRevision=1,
        [bool]$DatabaseExists=$true,
        [bool]$BackupVerified=$false,
        [bool]$MigrationInterrupted=$false,
        [ValidateRange(0,100000)][int]$OldestUpgradable=0
    )
    if ($OldestUpgradable -le 0) { $OldestUpgradable = $ApplicationVersion }
    $steps = New-Object 'System.Collections.Generic.List[object]'
    $decision = 'Refuser'; $canOpen = $false; $canWrite = $false; $requiresBackup = $false; $message = ''
    $appLabel = [string]$ApplicationVersion + '/' + [string]$ApplicationRevision
    $version = 0
    $revision = 0
    $versionKnown = [int]::TryParse(([string]$DatabaseVersion).Trim(),[ref]$version)
    $revisionText = ([string]$DatabaseRevision).Trim()
    $revisionKnown = $true
    if ($revisionText) { $revisionKnown = [int]::TryParse($revisionText,[ref]$revision) }
    $dbLabel = ([string]$DatabaseVersion).Trim() + '/' + $revisionText
    if (-not $revisionText) { $dbLabel = ([string]$DatabaseVersion).Trim() + '/0' }
    $newer = ($versionKnown -and $revisionKnown -and (($version -gt $ApplicationVersion) -or (($version -eq $ApplicationVersion) -and ($revision -gt $ApplicationRevision))))
    if (-not $DatabaseExists) {
        $decision = 'Creer'; $canOpen = $true; $canWrite = $true
        $steps.Add([pscustomobject]@{Action='Creer';Target='Base';From='';To=$appLabel})
        $message = 'Nouvelle base au schema ' + $appLabel + '.'
    }
    elseif ($MigrationInterrupted) {
        $decision = 'Reprise requise'
        $message = 'Migration precedente interrompue : base conservee telle quelle. Reprendre la migration ou restaurer la sauvegarde verifiee, par un geste explicite.'
    }
    elseif ((-not $versionKnown) -or ($version -le 0) -or (-not $revisionKnown) -or ($revision -lt 0)) {
        $decision = 'Refuser'
        $message = 'Version de schema illisible : base conservee, aucune ecriture.'
    }
    elseif ($newer) {
        $decision = 'Refuser plus recente'
        $message = 'Base creee par une version plus recente (schema ' + $dbLabel + '). Cette version (schema ' + $appLabel + ') ne la modifie pas et ne la retrograde pas ; base et recus restent intacts. Utiliser la version recente, ou restaurer explicitement la sauvegarde faite avant la migration.'
    }
    elseif (($version -eq $ApplicationVersion) -and ($revision -eq $ApplicationRevision)) {
        $decision = 'Ouvrir'; $canOpen = $true; $canWrite = $true
        $message = 'Schema ' + $dbLabel + ' identique a celui de cette version.'
    }
    elseif ($version -lt $OldestUpgradable) {
        $decision = 'Refuser trop ancienne'
        $message = 'Schema ' + $dbLabel + ' trop ancien pour une migration par cette version : base conservee, migration explicite requise.'
    }
    elseif (-not $BackupVerified) {
        $decision = 'Sauvegarde requise'; $requiresBackup = $true
        $steps.Add([pscustomobject]@{Action='Sauvegarder';Target='Sauvegarde';From=$dbLabel;To=$dbLabel})
        $message = 'Migration du schema ' + $dbLabel + ' vers ' + $appLabel + ' : une sauvegarde verifiee est exigee avant toute ecriture.'
    }
    else {
        $decision = 'Migrer'; $canOpen = $true; $canWrite = $true; $requiresBackup = $true
        $current = $version
        $currentRevision = $revision
        if ($current -lt $ApplicationVersion) { $currentRevision = 0 }
        while ($current -lt $ApplicationVersion) {
            $steps.Add([pscustomobject]@{Action='Migrer';Target='Base';From=([string]$current + '/0');To=([string]($current + 1) + '/0')})
            $current++
        }
        while ($currentRevision -lt $ApplicationRevision) {
            $steps.Add([pscustomobject]@{Action='Migrer';Target='Base';From=([string]$current + '/' + [string]$currentRevision);To=([string]$current + '/' + [string]($currentRevision + 1))})
            $currentRevision++
        }
        $steps.Add([pscustomobject]@{Action='Controler';Target='Base';From=$appLabel;To=$appLabel})
        $message = 'Migration en avant du schema ' + $dbLabel + ' vers ' + $appLabel + ' apres sauvegarde verifiee, une transaction par etape.'
    }
    $all = $steps.ToArray()
    $safety = Test-DomeniaSchemaStepSafety $all $false $DatabaseExists
    if (-not $safety.Safe) {
        # Defensive: an unsafe plan is never handed to the caller as writable.
        $decision = 'Refuser'; $canOpen = $false; $canWrite = $false
        $message = 'Plan de schema refuse : ' + [string]::Join(' ',[string[]]$safety.Findings)
    }
    return [pscustomobject]@{
        Decision=$decision;CanOpen=$canOpen;CanWrite=$canWrite;RequiresBackup=$requiresBackup;Steps=$all
        Downgrade=$safety.Downgrade;TouchesReceipts=$safety.TouchesReceipts;Safety=$safety
        DatabaseVersion=$dbLabel;ApplicationVersion=$appLabel;Message=$message
    }
}

function Get-DomeniaSchemaRestorePlan {
    # Going back to an older version. Starting an older executable never changes the base: that version meets a newer
    # schema and refuses it (Test-DomeniaSchemaCompatibility, 'Refuser plus recente'). The only way back is an explicit
    # restore of a verified backup that this version can read: the current base is saved first, then replaced. Receipts
    # live apart (profile\Domenia\Receipts, see Get-DomeniaStorageLayout) and are never a step of the restore.
    param(
        [AllowEmptyString()][string]$DatabaseVersion='',[AllowEmptyString()][string]$DatabaseRevision='',
        [AllowEmptyString()][string]$BackupVersion='',[AllowEmptyString()][string]$BackupRevision='',
        [ValidateRange(1,100000)][int]$ApplicationVersion=11,[ValidateRange(1,100000)][int]$ApplicationRevision=1,
        [bool]$BackupVerified=$false,[bool]$Explicit=$false
    )
    $steps = New-Object 'System.Collections.Generic.List[object]'
    $joinLabel = { param([string]$V,[string]$R) $text = ([string]$V).Trim(); if (([string]$R).Trim()) { $text += '/' + ([string]$R).Trim() }; return $text }
    $database = ConvertFrom-DomeniaSchemaLabel (& $joinLabel $DatabaseVersion $DatabaseRevision)
    $backup = ConvertFrom-DomeniaSchemaLabel (& $joinLabel $BackupVersion $BackupRevision)
    $application = ConvertFrom-DomeniaSchemaLabel ([string]$ApplicationVersion + '/' + [string]$ApplicationRevision)
    $decision = 'Refuser'
    $message = ''
    if (-not $Explicit) { $message = 'Aucune restauration automatique : revenir a une sauvegarde part seulement d un geste explicite de l operateur.' }
    elseif (($null -eq $database) -or ($null -eq $backup)) { $message = 'Version de schema de la base ou de la sauvegarde illisible : rien n est restaure.' }
    elseif (-not $BackupVerified) { $message = 'Sauvegarde non verifiee (controle SQLite) : rien n est restaure.' }
    elseif (($backup.Version -gt $application.Version) -or (($backup.Version -eq $application.Version) -and ($backup.Revision -gt $application.Revision))) {
        $message = 'Sauvegarde au schema ' + $backup.Label + ', plus recent que cette version (' + $application.Label + ') : rien n est restaure.'
    }
    else {
        $decision = 'Restaurer'
        $steps.Add([pscustomobject]@{Action='Sauvegarder';Target='Sauvegarde';From=$database.Label;To=$database.Label})
        $steps.Add([pscustomobject]@{Action='Restaurer';Target='Base';From=$database.Label;To=$backup.Label})
        $message = 'Restauration explicite : la base actuelle (schema ' + $database.Label + ') est sauvegardee, puis remplacee par la sauvegarde verifiee (schema ' + $backup.Label + '). Les recus, ranges a part, ne sont pas modifies.'
    }
    $all = $steps.ToArray()
    $safety = Test-DomeniaSchemaStepSafety $all $Explicit $true
    if (($decision -ceq 'Restaurer') -and (-not $safety.Safe)) { $decision = 'Refuser'; $all = @(); $message = 'Plan de restauration refuse : ' + [string]::Join(' ',[string[]]$safety.Findings) }
    return [pscustomobject]@{Decision=$decision;Steps=$all;Downgrade=$safety.Downgrade;SilentDowngrade=$safety.SilentDowngrade;TouchesReceipts=$safety.TouchesReceipts;Safety=$safety;Message=$message}
}

# ---------------------------------------------------------------- D116 integrity versus publisher trust
function ConvertTo-DomeniaPublisherPin {
    # The publisher the organisation trusts, pinned by certificate: one or more thumbprints (SignerCertificate.Thumbprint,
    # 40 hexadecimal digits, or a 64-digit SHA-256 fingerprint), so a renewed certificate can be added. A name or a
    # subject alone is kept for display but proves nothing: any trusted CA can issue a certificate with the same CN.
    # Accepts an object (Name, Thumbprints), a thumbprint text, or a name text.
    param($Publisher)
    $name = ''
    $prints = New-Object 'System.Collections.Generic.List[string]'
    $candidates = @()
    if ($Publisher -is [string]) {
        $text = $Publisher.Trim()
        if ($text -match '^[0-9A-Fa-f]{40}$|^[0-9A-Fa-f]{64}$') { $candidates = @($text) } else { $name = $text }
    }
    elseif ($null -ne $Publisher) {
        $name = ([string](Get-DomeniaMember $Publisher 'Name' '')).Trim()
        $candidates = @(@(Get-DomeniaMember $Publisher 'Thumbprints' @()) + @(Get-DomeniaMember $Publisher 'Thumbprint' @()))
    }
    $invalid = 0
    foreach ($candidate in $candidates) {
        $value = ([string]$candidate).Trim().Replace(' ','')
        if (-not $value) { continue }
        if ($value -notmatch '^[0-9A-Fa-f]{40}$|^[0-9A-Fa-f]{64}$') { $invalid++; continue }
        $value = $value.ToUpperInvariant()
        if (-not $prints.Contains($value)) { $prints.Add($value) }
    }
    return [pscustomobject]@{Name=$name;Thumbprints=$prints.ToArray();Pinned=($prints.Count -gt 0);Invalid=$invalid;Configured=(($prints.Count -gt 0) -or [bool]$name)}
}

function Test-DomeniaSignerTrust {
    # Publisher verdict for one Authenticode result. Verified only when Windows reports Valid AND the signer certificate
    # is one of the pinned thumbprints. A matching CN or subject with another certificate is an unexpected publisher.
    param([AllowEmptyString()][string]$Status='',[AllowEmptyString()][string]$Signer='',[AllowEmptyString()][string]$Thumbprint='',$Pin)
    $print = ([string]$Thumbprint).Trim().Replace(' ','').ToUpperInvariant()
    $pinName = [string](Get-DomeniaMember $Pin 'Name' '')
    $commonName = {
        param([string]$Text)
        $found = [regex]::Match($Text,'(?i)(?:^|,\s*)CN=([^,]+)')
        if ($found.Success) { return $found.Groups[1].Value.Trim() }
        return $Text.Trim()
    }
    $sameName = ([bool]$pinName -and [bool]$Signer -and ((& $commonName $Signer) -ieq (& $commonName $pinName)))
    if ($Status -cne 'Valid') { return [pscustomobject]@{Verified=$false;Text=''} }
    if (-not [bool](Get-DomeniaMember $Pin 'Pinned' $false)) {
        if ($pinName) { return [pscustomobject]@{Verified=$false;Text='Editeur non prouve : nom seul, aucun certificat epingle'} }
        return [pscustomobject]@{Verified=$false;Text='Signature valide, editeur attendu non configure'}
    }
    if (-not $print) { return [pscustomobject]@{Verified=$false;Text='Editeur non prouve : empreinte du certificat signataire non fournie'} }
    if (@(Get-DomeniaMember $Pin 'Thumbprints' @()) -ccontains $print) { return [pscustomobject]@{Verified=$true;Text='Editeur verifie'} }
    if ($sameName) { return [pscustomobject]@{Verified=$false;Text='Editeur inattendu : meme nom, autre certificat'} }
    return [pscustomobject]@{Verified=$false;Text='Editeur inattendu'}
}

function Get-DomeniaSignatureVerdict {
    # Integrity (each file is the one the manifest lists) and publisher trust (Authenticode status and signer certificate
    # read by the caller, e.g. Get-AuthenticodeSignature .Status and .SignerCertificate.Thumbprint) are separate answers.
    # The publisher is pinned by certificate thumbprint (ConvertTo-DomeniaPublisherPin): a name alone never proves it.
    # A distribution that differs from what was published (file changed, removed or added, signature broken, signed
    # manifest broken) never keeps a valid signature status, even when a substituted file carries its own valid
    # signature. Files that cannot carry a signature are trusted only through a signed manifest. The verdict only reads
    # statuses; it never proposes to weaken a Windows protection.
    # SP-09: -PinnedComponents (path -> SHA-256, from the reviewed release contract) covers the frozen binaries that the
    # delivery chain never signs: Domenia.exe (F8) and the third-party components (signed by their own vendor, or not).
    # Such a file is accepted for its exact pinned bytes, whatever its Authenticode signature, and refused otherwise.
    # Each row says which proof covers it (Scope): Authenticode signature, pinned SHA-256, signed manifest, or the
    # unsigned manifest only. The publisher answer separates a complete cover ('Editeur verifie') from a cover of the
    # signed scripts and pinned binaries whose non-signable files rest on an unsigned manifest.
    param([object[]]$Files=@(),$Publisher=$null,$ManifestSignature=$null,[string[]]$UndeclaredFiles=@(),[Collections.IDictionary]$PinnedComponents=$null)
    $pin = ConvertTo-DomeniaPublisherPin $Publisher
    $manifestStatus = ([string](Get-DomeniaMember $ManifestSignature 'SignatureStatus' '')).Trim()
    $manifestSigner = ([string](Get-DomeniaMember $ManifestSignature 'Signer' '')).Trim()
    $manifestPrint = ([string](Get-DomeniaMember $ManifestSignature 'SignerThumbprint' '')).Trim()
    $manifestTrust = Test-DomeniaSignerTrust $manifestStatus $manifestSigner $manifestPrint $pin
    $manifestTrusted = [bool]$manifestTrust.Verified
    $manifestBroken = ($manifestStatus -ceq 'HashMismatch')
    $pinnedHashes = @{}
    if ($null -ne $PinnedComponents) {
        foreach ($key in @($PinnedComponents.Keys)) {
            $pinnedSha = ConvertTo-DomeniaSha256Text ([string]$PinnedComponents[$key])
            if ($pinnedSha) { $pinnedHashes[([string]$key).Replace('\','/').ToLowerInvariant()] = $pinnedSha }
        }
    }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($file in @($Files)) {
        if ($null -eq $file) { continue }
        $path = [string](Get-DomeniaMember $file 'Path' '')
        $expected = ConvertTo-DomeniaSha256Text ([string](Get-DomeniaMember $file 'ExpectedSha256' ''))
        $actual = ConvertTo-DomeniaSha256Text ([string](Get-DomeniaMember $file 'ActualSha256' ''))
        $isPresent = [bool](Get-DomeniaMember $file 'Present' $true)
        $status = ([string](Get-DomeniaMember $file 'SignatureStatus' '')).Trim()
        $signer = ([string](Get-DomeniaMember $file 'Signer' '')).Trim()
        $print = ([string](Get-DomeniaMember $file 'SignerThumbprint' '')).Trim()
        $signable = ($path -match '(?i)\.(exe|dll|ps1|psm1|psd1)$')
        $pinKey = $path.Replace('\','/').ToLowerInvariant()
        $isPinned = $pinnedHashes.ContainsKey($pinKey)
        $integrity = 'Non verifiee'
        if (-not $isPresent) { $integrity = 'Absente' }
        elseif ($expected -and $actual) { if ($expected -ceq $actual) { $integrity = 'Conforme' } else { $integrity = 'Modifiee' } }
        $verified = $false
        $publisher = 'Signature non verifiee'
        $scope = 'Signature'
        if (-not $isPresent) { $publisher = 'Fichier absent' }
        elseif ($isPinned) {
            $scope = 'Empreinte epinglee'
            if ($status -ceq 'HashMismatch') { $publisher = 'Signature invalide : fichier modifie apres signature' }
            elseif ($actual -and ($actual -ceq $pinnedHashes[$pinKey])) { $publisher = 'Composant fige epingle par son empreinte'; $verified = $true }
            elseif ($actual) { $publisher = 'Composant different de son empreinte epinglee' }
            else { $publisher = 'Empreinte du composant non calculee' }
        }
        elseif ($signable) {
            if ($status -ceq 'Valid') {
                $trust = Test-DomeniaSignerTrust $status $signer $print $pin
                $publisher = [string]$trust.Text
                $verified = [bool]$trust.Verified
            }
            elseif ($status -ceq 'NotSigned') { $publisher = 'Non signe' }
            elseif ($status -ceq 'HashMismatch') { $publisher = 'Signature invalide : fichier modifie apres signature' }
            elseif ($status -ceq 'NotTrusted') { $publisher = 'Signature non approuvee par ce poste' }
            elseif ($status) { $publisher = 'Signature non verifiee (' + $status + ')' }
        }
        elseif ($manifestTrusted) { $scope = 'Manifeste signe'; $publisher = 'Couvert par le manifeste signe'; $verified = $true }
        else { $scope = 'Manifeste seul'; $publisher = 'Editeur non prouve : fichier non signable et manifeste non signe par le certificat epingle' }
        $signatureValid = (($integrity -ceq 'Conforme') -and $verified)
        $display = $publisher
        if (($integrity -ceq 'Modifiee') -or ($integrity -ceq 'Absente')) { $display = 'Invalide : fichier different de la distribution publiee' }
        elseif (($integrity -ceq 'Non verifiee') -and $verified) { $display = 'Signature non retenue : integrite non verifiee' }
        $rows.Add([pscustomobject]@{Path=$path;Signable=$signable;Scope=$scope;Integrity=$integrity;Publisher=$publisher;PublisherVerified=$verified;SignatureStatus=$display;SignatureValid=$signatureValid;AuthenticodeStatus=$status;Signer=$signer;SignerThumbprint=$print.ToUpperInvariant()})
    }
    $all = $rows.ToArray()
    $undeclared = @(@($UndeclaredFiles) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $modified = @($all | Where-Object { ($_.Integrity -ceq 'Modifiee') -or ($_.Integrity -ceq 'Absente') }).Count + $undeclared.Count
    $unverified = @($all | Where-Object { $_.Integrity -ceq 'Non verifiee' }).Count
    $broken = @($all | Where-Object { $_.AuthenticodeStatus -ceq 'HashMismatch' }).Count
    if ($manifestBroken) { $broken++ }
    $trusted = @($all | Where-Object { $_.SignatureValid }).Count
    $publisherVerified = @($all | Where-Object { $_.PublisherVerified }).Count
    $manifestOnly = @($all | Where-Object { $_.Scope -ceq 'Manifeste seul' } | ForEach-Object { $_.Path })
    $signedScope = @($all | Where-Object { $_.Scope -ceq 'Signature' })
    # Every signed script carries the pinned signature and every frozen binary its pinned bytes; only the files that
    # Authenticode cannot sign rest on the manifest hashes, and the manifest itself is not signed.
    $partialCover = ([bool]$pin.Pinned -and ($signedScope.Count -gt 0) -and ($manifestOnly.Count -gt 0) -and (($publisherVerified + $manifestOnly.Count) -eq $all.Count))
    $overall = 'Conforme, editeur non prouve'
    $next = 'Integrite conforme au manifeste. Une empreinte ne prouve pas l identite de l editeur : verifier la provenance du manifeste avant diffusion.'
    # A modification is reported first: undeclared files make a distribution modified even when no file was examined.
    if ($modified -gt 0) { $overall = 'Distribution modifiee'; $next = 'Ne pas utiliser cette copie. Recuperer la distribution d origine et comparer ses empreintes au manifeste publie.' }
    elseif ($all.Count -eq 0) { $overall = 'Non verifiee'; $next = 'Aucun fichier examine : aucun statut de signature.' }
    elseif ($broken -gt 0) { $overall = 'Signature invalide'; $next = 'Ne pas utiliser cette copie : une signature ne correspond plus au contenu. Recuperer la distribution d origine.' }
    elseif ($unverified -gt 0) { $overall = 'Integrite non verifiee'; $next = 'Calculer les empreintes SHA-256 et les comparer au manifeste avant usage.' }
    elseif ($trusted -eq $all.Count) { $overall = 'Signee et conforme'; $next = 'Distribution conforme et signee par le certificat epingle de l editeur.' }
    elseif ($partialCover) { $overall = 'Conforme, code signe, manifeste non signe'; $next = 'Scripts signes par le certificat epingle et composants figes conformes a leur empreinte. Les fichiers non signables ne sont couverts que par le manifeste, qui n est pas signe : signer son catalogue pour les couvrir.' }
    # SP-09: the two answers are also given apart, for an offline report (tools/Test-DomeniaSignature.ps1). Integrity
    # comes from the manifest hashes only; the publisher from the Authenticode statuses read by the caller and the pin.
    $integrityStatus = 'Conforme'
    if ($modified -gt 0) { $integrityStatus = 'Modifiee' }
    elseif (($all.Count -eq 0) -or ($unverified -gt 0)) { $integrityStatus = 'Non verifiee' }
    $publisherStatus = 'Editeur non prouve'
    if ($all.Count -eq 0) { $publisherStatus = 'Non verifie' }
    elseif ($broken -gt 0) { $publisherStatus = 'Signature invalide' }
    elseif (-not [bool]$pin.Pinned) { $publisherStatus = 'Editeur attendu non configure' }
    elseif ($publisherVerified -eq $all.Count) { $publisherStatus = 'Editeur verifie' }
    elseif ($partialCover) { $publisherStatus = 'Editeur verifie, manifeste non signe' }
    return [pscustomobject]@{
        IntegrityStatus=$integrityStatus;PublisherStatus=$publisherStatus;PublisherVerifiedFiles=$publisherVerified
        ManifestOnlyFiles=$manifestOnly;PinnedFiles=@($all | Where-Object { $_.Scope -ceq 'Empreinte epinglee' } | ForEach-Object { $_.Path })
        Overall=$overall;DistributionSignatureValid=(($all.Count -gt 0) -and ($modified -eq 0) -and ($broken -eq 0) -and ($trusted -eq $all.Count))
        Files=$all;Undeclared=$undeclared;ManifestSigned=$manifestTrusted;PublisherPinned=[bool]$pin.Pinned;NextAction=$next
        IntegrityNote='Une empreinte conforme prouve que le fichier est celui du manifeste, pas l identite de son editeur.'
    }
}

# ---------------------------------------------------------------- D117 delivered component inventory
function Get-DomeniaComponentInventory {
    # One row per delivered file. A version is shown only when it is bound to that exact file: read from the file itself
    # (version resource read on a file with the same SHA-256), declared by the contract for that SHA-256, or the build of
    # the manifest for the text files the build produces. A version tied to a package name alone is not shown.
    param($Manifest,$Contract=$null,[Collections.IDictionary]$FileVersions=$null)
    $declared = @{}
    foreach ($component in @(Get-DomeniaMember $Contract 'Components' @())) {
        $path = [string](Get-DomeniaMember $component 'Path' '')
        if ($path) { $declared[$path] = $component }
    }
    $build = [string](Get-DomeniaMember $Manifest 'Build' '')
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($file in @(Get-DomeniaMember $Manifest 'Files' @())) {
        $path = [string](Get-DomeniaMember $file 'Path' '')
        if (-not $path) { continue }
        $sha = ConvertTo-DomeniaSha256Text ([string](Get-DomeniaMember $file 'Sha256' ''))
        $bytes = 0L
        [void][long]::TryParse([string](Get-DomeniaMember $file 'Bytes' 0),[ref]$bytes)
        $name = $path.Split([char]'/')[-1]
        $component = $null
        if ($declared.ContainsKey($path)) { $component = $declared[$path] }
        if ($null -ne $component) { $declaredName = [string](Get-DomeniaMember $component 'Name' ''); if ($declaredName) { $name = $declaredName } }
        $policy = ''
        if ($null -ne $component) { $policy = [string](Get-DomeniaMember $component 'VersionPolicy' '') }
        $isBinary = ($path -match '(?i)\.(exe|dll)$')
        $version = ''; $source = ''; $bound = $false; $note = ''
        if (-not $sha) { $note = 'Empreinte absente du manifeste : aucune version affichee.' }
        else {
            $read = $null
            if (Test-DomeniaReleaseMapKey $FileVersions $path) { $read = $FileVersions[$path] }
            if ($null -ne $read) {
                $readSha = ConvertTo-DomeniaSha256Text ([string](Get-DomeniaMember $read 'Sha256' ''))
                $readVersion = ([string](Get-DomeniaMember $read 'FileVersion' '')).Trim()
                if ($readSha -and ($readSha -ceq $sha) -and $readVersion) { $version = $readVersion; $source = 'Ressource de version du fichier livre'; $bound = $true }
                elseif ($readSha -and ($readSha -cne $sha)) { $note = 'Version lue sur un fichier dont l empreinte differe du manifeste : non affichee.' }
                elseif (-not $readSha) { $note = 'Version lue sans empreinte du fichier : non affichee.' }
            }
            if ((-not $bound) -and ($null -ne $component)) {
                $declaredSha = ConvertTo-DomeniaSha256Text ([string](Get-DomeniaMember $component 'Sha256' ''))
                $declaredVersion = ([string](Get-DomeniaMember $component 'Version' '')).Trim()
                if ($declaredVersion -and ($policy -cne 'Release')) {
                    if ($declaredSha -and ($declaredSha -ceq $sha)) { $version = $declaredVersion; $source = 'Contrat de release, lie a l empreinte du fichier'; $bound = $true; $note = '' }
                    elseif ($declaredSha) { $note = 'Version declaree pour une autre empreinte : non affichee.' }
                    elseif (-not $note) { $note = 'Version declaree sans empreinte (nom de paquet seulement) : non affichee.' }
                }
            }
            # Binaries are not produced by the build: they never inherit its label.
            if ((-not $bound) -and $build -and (-not $isBinary) -and ($policy -cne 'Distinct')) { $version = $build; $source = 'Build de la livraison (fichier liste par son manifeste)'; $bound = $true }
            elseif ((-not $bound) -and (-not $note)) { $note = 'Aucune version liee a l empreinte de ce fichier : version non affichee.' }
        }
        $licence = 'Non documentee'; $provenance = 'Non documentee'; $advisories = 'Non evaluees'
        if ($null -ne $component) {
            $value = [string](Get-DomeniaMember $component 'Licence' ''); if ($value) { $licence = $value }
            $value = [string](Get-DomeniaMember $component 'Provenance' ''); if ($value) { $provenance = $value }
            $value = [string](Get-DomeniaMember $component 'Vulnerabilities' ''); if ($value) { $advisories = $value }
        }
        $shortSha = $sha
        if ($sha.Length -gt 12) { $shortSha = $sha.Substring(0,12) }
        $display = $name + ' ' + [string][char]0x00B7 + ' version non reliee au fichier'
        if ($bound) { $display = $name + ' ' + $version + ' ' + [string][char]0x00B7 + ' SHA-256 ' + $shortSha }
        $rows.Add([pscustomobject]@{Name=$name;Path=$path;Sha256=$sha;Bytes=$bytes;Version=$version;VersionSource=$source;Bound=$bound;Licence=$licence;Provenance=$provenance;Vulnerabilities=$advisories;Note=$note;Display=$display})
    }
    $all = $rows.ToArray()
    $unbound = @($all | Where-Object { -not $_.Bound }).Count
    return [pscustomobject]@{Build=$build;Rows=$all;Unbound=$unbound;Complete=(($all.Count -gt 0) -and ($unbound -eq 0))}
}

# ---------------------------------------------------------------- D118 configuration, preference, cache and receipt
function Get-DomeniaStorageLayout {
    # One explicit location per data category, with its rights. $InstallRoot is the folder holding Domenia.exe and wad;
    # $UserLocalRoot is the local profile (LocalApplicationData). Write access is observed by the caller and passed in
    # ($Writable: category or path -> bool). A folder that cannot be written yields an explicit error for that category:
    # nothing is redirected elsewhere and the requested path is kept in the answer. Compatible mode is deduced from
    # existing portable data only, never from rights, and the deduction is announced.
    param(
        [ValidateSet('UserLocal','Portable','Compatible')][string]$Mode='UserLocal',
        [AllowEmptyString()][string]$InstallRoot='',
        [AllowEmptyString()][string]$UserLocalRoot='',
        [Collections.IDictionary]$Writable=$null,
        [bool]$PortableHasData=$false,
        [string[]]$NetworkDrives=@()
    )
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $notices = New-Object 'System.Collections.Generic.List[string]'
    $resolved = 'UserLocal'
    $modeSource = 'Explicite'
    if ($Mode -ieq 'Portable') { $resolved = 'Portable' }
    elseif ($Mode -ieq 'Compatible') {
        $modeSource = 'Deduit'
        if ($PortableHasData) { $resolved = 'Portable'; $notices.Add('Mode Compatible : des donnees existent dans wad\data, le mode Portable est retenu. Choisir UserLocal ou Portable pour un mode explicite.') }
        else { $notices.Add('Mode Compatible : aucune donnee portable, le mode UserLocal est retenu. Choisir UserLocal ou Portable pour un mode explicite.') }
    }
    if (-not $InstallRoot) { $errors.Add('Dossier d installation non fourni : configuration non localisee.') }
    if (-not $UserLocalRoot) {
        $scope = 'recus'
        if ($resolved -ceq 'UserLocal') { $scope = 'preferences, cache et recus' }
        $errors.Add('Profil local de l utilisateur non fourni : ' + $scope + ' non localises. Aucun dossier de remplacement choisi automatiquement.')
    }
    $wadRoot = Join-DomeniaReleasePath $InstallRoot 'wad'
    $dataRoot = Join-DomeniaReleasePath $UserLocalRoot 'Domenia\Data'
    $protectedRights = 'Utilisateur courant, SYSTEM et Administrateurs (DACL protegee).'
    if ($resolved -ceq 'Portable') {
        $dataRoot = Join-DomeniaReleasePath $wadRoot 'data'
        $protectedRights = 'Droits du dossier portable (aucune DACL posee) : reserve a un support personnel.'
    }
    $letters = @(@($NetworkDrives) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim().Substring(0,1).ToUpperInvariant() })
    $preferenceLegacy = @(@($dataRoot,$wadRoot) | Where-Object { $_ })
    $specs = @(
        [pscustomobject]@{Category='Configuration';Label='Configuration';Path=(Join-DomeniaReleasePath $wadRoot 'Domenia.config.json');WriteRequired=$false;MustBeLocal=$false;ReadAlsoFrom=@();Rights='Lecture par l application ; modifiee seulement par l installation ou l administrateur, conservee lors des mises a jour.'}
        [pscustomobject]@{Category='Preference';Label='Preferences';Path=(Join-DomeniaReleasePath $dataRoot 'Preferences');WriteRequired=$true;MustBeLocal=$true;ReadAlsoFrom=$preferenceLegacy;Rights=('Lecture et ecriture par l utilisateur courant. ' + $protectedRights + ' Anciens emplacements lus seulement, jamais effaces.')}
        [pscustomobject]@{Category='Cache';Label='Cache et base active';Path=$dataRoot;WriteRequired=$true;MustBeLocal=$true;ReadAlsoFrom=@();Rights=('Base SQLite active locale obligatoire. ' + $protectedRights)}
        [pscustomobject]@{Category='Receipt';Label='Recus d operations';Path=(Join-DomeniaReleasePath $UserLocalRoot 'Domenia\Receipts');WriteRequired=$true;MustBeLocal=$true;ReadAlsoFrom=@();Rights='Profil local en mode portable comme en mode local. Utilisateur courant, SYSTEM et Administrateurs (DACL protegee) ; ajout seulement, aucun recu reecrit ni purge automatiquement.'}
    )
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($spec in $specs) {
        $path = [string]$spec.Path
        # Write access may be observed per category and per path: the most restrictive answer wins, so a folder seen
        # as not writable is never reported ready because its category was declared writable.
        $canWrite = $null
        $answers = New-Object 'System.Collections.Generic.List[bool]'
        if (Test-DomeniaReleaseMapKey $Writable $spec.Category) { $answers.Add([bool]$Writable[$spec.Category]) }
        if ($path -and (Test-DomeniaReleaseMapKey $Writable $path)) { $answers.Add([bool]$Writable[$path]) }
        if ($answers.Count -gt 0) { $canWrite = ($answers -notcontains $false) }
        $isNetwork = $false
        if ($path.StartsWith('\\',[StringComparison]::Ordinal)) { $isNetwork = $true }
        elseif (($path.Length -ge 2) -and ($path.Substring(1,1) -eq ':') -and ($letters -contains $path.Substring(0,1).ToUpperInvariant())) { $isNetwork = $true }
        $state = 'Pret'
        $message = ''
        if (-not $path) { $state = 'Non localise' }
        elseif ($spec.MustBeLocal -and $isNetwork) { $state = 'Distant refuse'; $message = $spec.Label + ' : emplacement reseau refuse (' + $path + '). Choisir un dossier local ; aucune bascule automatique.' }
        elseif (-not $spec.WriteRequired) { $state = 'Lecture seule attendue' }
        elseif ($null -eq $canWrite) { $state = 'Non verifie'; $message = $spec.Label + ' : ecriture non verifiee dans ' + $path + '. Verifier avant usage ; aucune bascule automatique.' }
        elseif (-not $canWrite) { $state = 'Non inscriptible'; $message = $spec.Label + ' : dossier non inscriptible pour ce compte (' + $path + '). Aucune bascule silencieuse : corriger les droits ou choisir explicitement un autre mode ou dossier.' }
        if ($message) { $errors.Add($message) }
        $row=[pscustomobject]@{Category=$spec.Category;Label=$spec.Label;Path=$path;ReadAlsoFrom=$spec.ReadAlsoFrom;Rights=$spec.Rights;WriteRequired=$spec.WriteRequired;MustBeLocal=$spec.MustBeLocal;Writable=$canWrite;State=$state;Error=$message;Fallback=''}
        if($spec.Category -eq 'Cache'){
            $areas=@(foreach($name in @('Logs','Backups','Diagnostics','Exports','Legacy','Domains')){
                $note=''
                if($name -eq 'Backups'){$note='Les bases par domaine conservent <dossier de la base>\Backups.'}
                [pscustomobject]@{Name=$name;Path=(Join-DomeniaReleasePath $dataRoot $name);Note=$note}
            })
            $row | Add-Member -NotePropertyName Areas -NotePropertyValue $areas
        }
        $rows.Add($row)
    }
    return [pscustomobject]@{Ready=($errors.Count -eq 0);Mode=$resolved;ModeSource=$modeSource;DataRoot=$dataRoot;Errors=$errors.ToArray();Notices=$notices.ToArray();Categories=$rows.ToArray()}
}

function Get-DomeniaPreferenceMigrationPlan {
    # Pure plan over observations made by the caller. Only the old settings file in this
    # mode's DataRoot can be copied. Shipped configuration and other modes stay untouched.
    param($Layout,[object[]]$Files=@())
    $steps=New-Object 'System.Collections.Generic.List[object]'
    $errors=New-Object 'System.Collections.Generic.List[string]'
    $root=[string](Get-DomeniaMember $Layout 'DataRoot' '')
    $preferences=@((Get-DomeniaMember $Layout 'Categories' @()) | Where-Object {$_.Category -eq 'Preference'})
    $expected=Join-DomeniaReleasePath $root 'Preferences'
    $source=Join-DomeniaReleasePath $root 'Domenia.settings.json'
    $target=Join-DomeniaReleasePath $expected 'Domenia.settings.json'
    $reason=''
    if(-not $root -or $preferences.Count -ne 1){$reason='Disposition des preferences invalide. Aucun autre emplacement choisi.'}
    elseif([string]$preferences[0].Path -ine $expected){$reason='Emplacement des preferences incoherent : '+$preferences[0].Path+'. Aucun autre emplacement choisi.'}
    elseif([string]$preferences[0].State -ne 'Pret'){$reason='Preferences non inscriptibles ou non verifiees : '+$expected+'. Aucun autre emplacement choisi.'}
    if($reason){
        $errors.Add($reason)
        $steps.Add([pscustomobject]@{Action='Refuser';Source=$source;Target=$target;Reason=$reason})
        return [pscustomobject]@{Steps=$steps.ToArray();Errors=$errors.ToArray()}
    }
    $old=@($Files | Where-Object {[string](Get-DomeniaMember $_ 'Path' '') -ieq $source})
    $new=@($Files | Where-Object {[string](Get-DomeniaMember $_ 'Path' '') -ieq $target})
    if(@($new | Where-Object {[bool](Get-DomeniaMember $_ 'Exists' $false)}).Count -gt 0){
        $steps.Add([pscustomobject]@{Action='Conserver';Source=$source;Target=$target;Reason='Preferences deja presentes : aucun ecrasement.'})
    } elseif($new.Count -ne 1 -or $null -eq (Get-DomeniaMember $new[0] 'Exists' $null)){
        $reason='Absence de la destination non confirmee : '+$target+'. Copie refusee.'
        $errors.Add($reason)
        $steps.Add([pscustomobject]@{Action='Refuser';Source=$source;Target=$target;Reason=$reason})
    } elseif($old.Count -gt 1){
        $reason='Observations ambigues pour '+$source+'. Copie refusee.'
        $errors.Add($reason)
        $steps.Add([pscustomobject]@{Action='Refuser';Source=$source;Target=$target;Reason=$reason})
    } elseif($old.Count -eq 1 -and [bool](Get-DomeniaMember $old[0] 'Exists' $false)){
        $file=$old[0];$reason='';$bytes=[long]-1
        if(-not [long]::TryParse([string](Get-DomeniaMember $file 'Bytes' '-1'),[ref]$bytes)){$bytes=-1L}
        if([bool](Get-DomeniaMember $file 'IsReparse' $true)){$reason='Lien de fichier refuse.'}
        elseif($bytes -lt 0 -or $bytes -gt 1MB){$reason='Taille inconnue ou superieure a 1 Mio.'}
        elseif(-not [bool](Get-DomeniaMember $file 'ValidJson' $false)){$reason='Preferences JSON invalides.'}
        $action='Copier'
        if($reason){$action='Ignorer'}else{$reason='Copie unique dans Preferences ; original conserve.'}
        $steps.Add([pscustomobject]@{Action=$action;Source=$source;Target=$target;Reason=$reason})
    }
    foreach($file in $Files){
        $path=[string](Get-DomeniaMember $file 'Path' '')
        if($path -and $path -ine $source -and $path -ine $target -and [bool](Get-DomeniaMember $file 'Exists' $false)){
            $steps.Add([pscustomobject]@{Action='Ignorer';Source=$path;Target='';Reason='Fichier livre ou emplacement hors du DataRoot courant : lecture historique seulement.'})
        }
    }
    return [pscustomobject]@{Steps=$steps.ToArray();Errors=$errors.ToArray()}
}

# ---------------------------------------------------------------- D119 suite UI kit
function Get-DomeniaSuiteKitManifest {
    # Theme tokens, metrics and vocabulary shared by the suite, versioned by their content. $Design is the parsed
    # SupportSuite.UI.json, read by the caller. Both themes must define the same tokens with #RRGGBB values, including the
    # $RequiredTokens the runtime reader demands. Only Domenia runs here: the kit stays partial until Pesto and FILPRO do.
    param($Design,[string[]]$RequiredTokens=@())
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $tokens = New-Object 'System.Collections.Generic.List[object]'
    $vocabulary = New-Object 'System.Collections.Generic.List[object]'
    $metrics = New-Object 'System.Collections.Generic.List[object]'
    $limit = 'Kit verifie dans Domenia uniquement : Pesto et FILPRO ne sont pas disponibles ici.'
    if ($null -eq $Design) {
        $errors.Add('Contrat visuel absent.')
        return [pscustomobject]@{Valid=$false;Errors=$errors.ToArray();Name='';SchemaVersion=0;KitVersion='';ContentSha256='';Tokens=@();Metrics=@();Vocabulary=@();Products=@();Rules=@();Status='PARTIEL';Limit=$limit}
    }
    $schema = 0
    [void][int]::TryParse([string](Get-DomeniaMember $Design 'SchemaVersion' ''),[ref]$schema)
    if ($schema -ne 1) { $errors.Add('Version de contrat visuel non prise en charge : <' + [string](Get-DomeniaMember $Design 'SchemaVersion' '') + '>.') }
    $palettes = Get-DomeniaMember $Design 'Palettes' $null
    $themeTokens = @{}
    foreach ($theme in @('Light','Dark')) {
        $palette = Get-DomeniaMember $palettes $theme $null
        if ($null -eq $palette) { $errors.Add('Palette absente : ' + $theme + '.'); continue }
        $names = @{}
        $pairs = @()
        if ($palette -is [Collections.IDictionary]) { $pairs = @(@($palette.Keys) | ForEach-Object { [pscustomobject]@{Name=[string]$_;Value=[string]$palette[$_]} }) }
        else { $pairs = @(@($palette.PSObject.Properties) | ForEach-Object { [pscustomobject]@{Name=[string]$_.Name;Value=[string]$_.Value} }) }
        foreach ($pair in $pairs) {
            if ($pair.Value -notmatch '^#[0-9A-Fa-f]{6}$') { $errors.Add('Couleur invalide : ' + $theme + '.' + $pair.Name + ' = <' + $pair.Value + '>.') }
            $tokens.Add([pscustomobject]@{Theme=$theme;Token=$pair.Name;Value=$pair.Value.ToUpperInvariant()})
            $names[$pair.Name] = $true
        }
        foreach ($required in @($RequiredTokens)) { if ($required -and (-not $names.ContainsKey([string]$required))) { $errors.Add('Jeton requis absent du theme ' + $theme + ' : ' + $required + '.') } }
        $themeTokens[$theme] = $names
    }
    if ($themeTokens.ContainsKey('Light') -and $themeTokens.ContainsKey('Dark')) {
        foreach ($name in @($themeTokens['Light'].Keys)) { if (-not $themeTokens['Dark'].ContainsKey($name)) { $errors.Add('Jeton absent du theme sombre : ' + $name + '.') } }
        foreach ($name in @($themeTokens['Dark'].Keys)) { if (-not $themeTokens['Light'].ContainsKey($name)) { $errors.Add('Jeton absent du theme clair : ' + $name + '.') } }
    }
    foreach ($section in @('Vocabulary','Metrics')) {
        $source = Get-DomeniaMember $Design $section $null
        $pairs = @()
        if ($source -is [Collections.IDictionary]) { $pairs = @(@($source.Keys) | ForEach-Object { [pscustomobject]@{Name=[string]$_;Value=$source[$_]} }) }
        elseif ($null -ne $source) { $pairs = @(@($source.PSObject.Properties) | ForEach-Object { [pscustomobject]@{Name=[string]$_.Name;Value=$_.Value} }) }
        if ($pairs.Count -eq 0) { $errors.Add('Section absente ou vide : ' + $section + '.') }
        foreach ($pair in $pairs) {
            if ($section -ceq 'Vocabulary') { $vocabulary.Add([pscustomobject]@{Key=$pair.Name;Text=[string]$pair.Value}) }
            else { $metrics.Add([pscustomobject]@{Name=$pair.Name;Value=$pair.Value}) }
        }
    }
    $products = @(@(Get-DomeniaMember $Design 'Products' @()) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    if ($products.Count -eq 0) { $errors.Add('Produits de la suite non declares.') }
    $rules = @(@(Get-DomeniaMember $Design 'Rules' @()) | ForEach-Object { [string]$_ })
    $content = [ordered]@{Metrics=(Get-DomeniaMember $Design 'Metrics' $null);Palettes=$palettes;Vocabulary=(Get-DomeniaMember $Design 'Vocabulary' $null);Rules=$rules}
    $hash = Get-DomeniaTextHash (ConvertTo-DomeniaReleaseCanonicalText $content)
    return [pscustomobject]@{
        Valid=($errors.Count -eq 0);Errors=$errors.ToArray();Name=[string](Get-DomeniaMember $Design 'Name' 'SupportSuite');SchemaVersion=$schema
        KitVersion=('SupportSuite/' + $schema + '+' + $hash.Substring(0,12));ContentSha256=$hash
        Tokens=$tokens.ToArray();Metrics=$metrics.ToArray();Vocabulary=$vocabulary.ToArray();Products=$products;Rules=$rules;Status='PARTIEL';Limit=$limit
    }
}

function Test-DomeniaSuiteKitDiffusion {
    # A change of the shared kit is released only after it passed in every product of the suite with this exact kit
    # version. A validation of an earlier kit version, or a failed one, does not count.
    param($Kit,[object[]]$Validations=@())
    if (($null -eq $Kit) -or (-not [bool](Get-DomeniaMember $Kit 'Valid' $false))) { return [pscustomobject]@{Allowed=$false;Missing=@();Reason='Kit invalide : diffusion refusee.'} }
    $version = [string](Get-DomeniaMember $Kit 'KitVersion' '')
    $missing = New-Object 'System.Collections.Generic.List[string]'
    foreach ($product in @(Get-DomeniaMember $Kit 'Products' @())) {
        $passed = @(@($Validations) | Where-Object {
            ($null -ne $_) -and ([string](Get-DomeniaMember $_ 'Product' '') -ieq [string]$product) -and ([string](Get-DomeniaMember $_ 'KitVersion' '') -ceq $version) -and ((Get-DomeniaMember $_ 'Passed' $false) -eq $true)
        }).Count
        if ($passed -eq 0) { $missing.Add([string]$product) }
    }
    $reason = 'Kit ' + $version + ' valide dans tous les produits de la suite.'
    if ($missing.Count -gt 0) { $reason = 'Diffusion refusee : kit ' + $version + ' non valide dans ' + [string]::Join(', ',$missing.ToArray()) + '.' }
    return [pscustomobject]@{Allowed=($missing.Count -eq 0);Missing=$missing.ToArray();Reason=$reason}
}

# ---------------------------------------------------------------- D120 optional read-only connectors
function ConvertTo-DomeniaConnectorEndpoint {
    # Reads a connector server address without ever copying a secret it may carry. Usable only for https with a host
    # name or an address and an optional port. User information (user:password@) is a secret: refused. A query or a
    # fragment may carry a token: refused. Origin (https://host[:port]) is the only form shown or traced.
    param([AllowNull()][AllowEmptyString()][string]$Url)
    $text = [string]$Url
    $problem = ''; $origin = ''; $hostName = ''; $port = ''
    $parts = [regex]::Match($text.Trim(),'^(?<scheme>[A-Za-z][A-Za-z0-9+.-]*)://(?<authority>[^/?#]*)(?<path>/[^?#]*)?(?<query>\?[^#]*)?(?<fragment>#.*)?$')
    # The authority part (before the first / ? #, after an optional scheme) is checked for user information first,
    # whatever the rest of the text looks like.
    $afterScheme = $text.Trim()
    $schemeEnd = $afterScheme.IndexOf('://')
    if ($schemeEnd -ge 0) { $afterScheme = $afterScheme.Substring($schemeEnd + 3) }
    $authorityText = [regex]::Match($afterScheme,'^[^/?#]*').Value
    if ([string]::IsNullOrWhiteSpace($text)) { $problem = 'Absente' }
    elseif ($authorityText.IndexOf([char]'@') -ge 0) { $problem = 'Secret' }
    elseif (-not $parts.Success) { $problem = 'Illisible' }
    if (-not $problem) {
        $authority = $parts.Groups['authority'].Value
        if ($parts.Groups['scheme'].Value -ine 'https') { $problem = 'NonChiffree' }
        elseif ($parts.Groups['query'].Success -or $parts.Groups['fragment'].Success) { $problem = 'Parametres' }
        else {
            $address = [regex]::Match($authority,'^(?<host>(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*|\[[0-9A-Fa-f:.]+\])(?::(?<port>\d{1,5}))?$')
            if (-not $address.Success) { $problem = 'Illisible' }
            else {
                $hostName = $address.Groups['host'].Value.ToLowerInvariant()
                if ($address.Groups['port'].Success) {
                    $number = [int]$address.Groups['port'].Value
                    if (($number -lt 1) -or ($number -gt 65535)) { $problem = 'Illisible'; $hostName = '' }
                    else { $port = [string]$number }
                }
            }
        }
    }
    if ((-not $problem) -and $hostName) {
        $origin = 'https://' + $hostName
        if ($port) { $origin += ':' + $port }
    }
    return [pscustomobject]@{Usable=((-not $problem) -and [bool]$origin);Problem=$problem;Origin=$origin;Host=$hostName;Port=$port}
}

function Get-DomeniaConnectorCatalog {
    # Optional read sources. Only WAPT is implemented, read-only, from the existing WAPT section of the configuration
    # (Enabled, ServerUrl). A connector that is absent, disabled or not delivered stays hidden; a refused or unreachable
    # one is shown unavailable. None blocks the directory, collects on its own or writes. $Status holds the outcome of
    # explicit tests (Disponible, Refuse, Injoignable).
    param($Configuration=$null,[Collections.IDictionary]$Status=$null)
    $known = @(
        [pscustomobject]@{Name='Wapt';Label='WAPT';Section='WAPT';Implemented=$true;MappingVersion='WaptHost/1'}
        [pscustomobject]@{Name='Glpi';Label='GLPI';Section='GLPI';Implemented=$false;MappingVersion=''}
        [pscustomobject]@{Name='ConfigMgr';Label='Configuration Manager';Section='ConfigMgr';Implemented=$false;MappingVersion=''}
        [pscustomobject]@{Name='Intune';Label='Intune';Section='Intune';Implemented=$false;MappingVersion=''}
    )
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($connector in $known) {
        $settings = Get-DomeniaMember $Configuration $connector.Section $null
        $configured = ($null -ne $settings)
        $flag = Get-DomeniaMember $settings 'Enabled' $false
        $enabled = ((($flag -is [bool]) -and $flag) -or (($flag -isnot [bool]) -and ([string]$flag -match '^(?i:true|1|oui|yes|on)$')))
        # The raw address is never kept: it may hold user:password@ or a token in its query.
        $endpoint = ConvertTo-DomeniaConnectorEndpoint ([string](Get-DomeniaMember $settings 'ServerUrl' ''))
        $server = [string]$endpoint.Origin
        $auth = [string](Get-DomeniaMember $settings 'Auth' 'Integrated')
        $hasSecret = (@(@('Password','Pwd','Passwd','Secret','Token','AccessToken','ApiKey','ClientSecret','Credential') | Where-Object { $null -ne (Get-DomeniaMember $settings $_ $null) }).Count -gt 0)
        $observed = ''
        if (Test-DomeniaReleaseMapKey $Status $connector.Name) { $observed = [string]$Status[$connector.Name] }
        $state = 'Masque'; $visible = $false; $reason = ''
        if (-not $connector.Implemented) { $reason = 'Connecteur non livre dans cette version.' }
        elseif (-not $configured) { $reason = 'Connecteur non configure.' }
        elseif (-not $enabled) { $reason = 'Connecteur desactive dans la configuration.' }
        elseif ($hasSecret) { $state = 'Indisponible'; $visible = $true; $reason = 'Secret present dans la configuration : refuse. Utiliser l authentification Windows integree.' }
        elseif ($endpoint.Problem -ceq 'Secret') { $state = 'Indisponible'; $visible = $true; $reason = 'Secret present dans l adresse du serveur (identifiant avant @) : refuse. Utiliser l authentification Windows integree.' }
        elseif ($endpoint.Problem -ceq 'Parametres') { $state = 'Indisponible'; $visible = $true; $reason = 'Adresse du serveur avec parametres ou fragment (jeton possible) : refusee. Indiquer seulement https://serveur[:port].' }
        elseif (-not $endpoint.Usable) { $state = 'Indisponible'; $visible = $true; $reason = 'Adresse du serveur absente, illisible ou non chiffree : https exige, certificat verifie par Windows.' }
        elseif ($observed -ieq 'Refuse') { $state = 'Indisponible'; $visible = $true; $reason = 'Acces refuse par ' + $connector.Label + ' pour ce compte. L annuaire reste utilisable.' }
        elseif ($observed -ieq 'Injoignable') { $state = 'Indisponible'; $visible = $true; $reason = 'Serveur ' + $connector.Label + ' injoignable. L annuaire reste utilisable.' }
        elseif ($observed -ieq 'Disponible') { $state = 'Disponible'; $visible = $true; $reason = 'Lecture possible sur demande.' }
        else { $state = 'Non teste'; $visible = $true; $reason = 'Aucune lecture faite : lire sur demande.' }
        $provenance = ''
        if ($server) { $provenance = $connector.Label + ' ' + $server }
        $rows.Add([pscustomobject]@{
            Name=$connector.Name;Label=$connector.Label;Implemented=$connector.Implemented;Configured=$configured;Enabled=$enabled;Visible=$visible;State=$state;Reason=$reason
            Server=$server;AuthMode=$auth;MappingVersion=$connector.MappingVersion;Provenance=$provenance
            ReadOnly=$true;CanWrite=$false;RequiresExplicitRead=$true
        })
    }
    $all = $rows.ToArray()
    return [pscustomobject]@{Connectors=$all;VisibleCount=@($all | Where-Object { $_.Visible }).Count}
}

function Test-DomeniaConnectorAvailable {
    # A read through a connector needs a visible, usable connector, a read operation and an explicit operator gesture.
    # A selection, a timer or the start-up never trigger a collection, and no connector ever writes.
    param($Catalog,[Parameter(Mandatory=$true)][string]$Name,[ValidateSet('Explicit','Selection','Startup','Timer')][string]$Trigger='Explicit',[ValidateSet('Read','Write')][string]$Operation='Read')
    $connector = $null
    foreach ($row in @(Get-DomeniaMember $Catalog 'Connectors' @())) { if ([string](Get-DomeniaMember $row 'Name' '') -ieq $Name) { $connector = $row } }
    $allowed = $false; $visible = $false; $reason = ''
    if ($null -eq $connector) { $reason = 'Connecteur non reconnu par cette version : masque.' }
    elseif (-not [bool](Get-DomeniaMember $connector 'Visible' $false)) { $reason = ([string](Get-DomeniaMember $connector 'Reason' '') + ' Masque.').Trim() }
    else {
        $visible = $true
        $label = [string](Get-DomeniaMember $connector 'Label' $Name)
        if ($Operation -cne 'Read') { $reason = 'Connecteur ' + $label + ' en lecture seule : aucune ecriture.' }
        elseif ($Trigger -cne 'Explicit') { $reason = 'Aucune collecte automatique : la lecture ' + $label + ' part seulement d un geste explicite.' }
        elseif ([string](Get-DomeniaMember $connector 'State' '') -ceq 'Indisponible') { $reason = [string](Get-DomeniaMember $connector 'Reason' '') }
        else { $allowed = $true; $reason = 'Lecture ' + $label + ' autorisee sur demande.' }
    }
    return [pscustomobject]@{Allowed=$allowed;Visible=$visible;Reason=$reason}
}

function Get-DomeniaSourceReadPlan {
    # Reads for one object card. The directory read never depends on a connector: an absent, refused or unreachable
    # connector only drops its own line. A connector read joins only on an explicit gesture. DirectoryIncluded is
    # structural (the directory line is added first, unconditionally): what can fail is the connector evaluation, so a
    # malformed catalog or status must never throw here; the call site proves the rest once connected.
    param($Catalog,[ValidateSet('Explicit','Selection','Startup','Timer')][string]$Trigger='Selection',[string[]]$Connectors=@())
    $reads = New-Object 'System.Collections.Generic.List[object]'
    $skipped = New-Object 'System.Collections.Generic.List[object]'
    $reads.Add([pscustomobject]@{Source='Annuaire';Kind='Directory';Reason='Lecture de l annuaire, independante des connecteurs.'})
    foreach ($name in @($Connectors)) {
        if (-not $name) { continue }
        $check = Test-DomeniaConnectorAvailable $Catalog ([string]$name) $Trigger 'Read'
        if ($check.Allowed) { $reads.Add([pscustomobject]@{Source=[string]$name;Kind='Connector';Reason=$check.Reason}) }
        else { $skipped.Add([pscustomobject]@{Source=[string]$name;Visible=$check.Visible;Reason=$check.Reason}) }
    }
    $all = $reads.ToArray()
    return [pscustomobject]@{Reads=$all;Skipped=$skipped.ToArray();DirectoryIncluded=(@($all | Where-Object { $_.Kind -ceq 'Directory' }).Count -eq 1);Trigger=$Trigger}
}

function ConvertFrom-DomeniaWaptHost {
    # Converts one WAPT host record (read-only API answer) into facts. The record is what the WAPT agent last reported,
    # not a reading of the workstation. Old data is marked old; a missing record is not a verdict; a record whose name
    # differs from the AD computer is not attributed to it. A state is 'Constate' only for a recent record matched to
    # the AD computer; an old or unmatched record is 'Estime'. Names are compared without a final dot. The server is
    # shown only as https://host[:port]. Field mapping version WaptHost/1.
    param($Record,[Parameter(Mandatory=$true)][datetime]$NowUtc,[AllowEmptyString()][string]$Server='',[AllowEmptyString()][string]$ExpectedFqdn='',[ValidateRange(1,365)][int]$StaleDays=7)
    $source = 'WAPT (lecture seule)'
    $origin = [string](ConvertTo-DomeniaConnectorEndpoint $Server).Origin
    if ($origin) { $source = 'WAPT ' + $origin + ' (lecture seule)' }
    $facts = New-Object 'System.Collections.Generic.List[object]'
    if ($null -eq $Record) {
        $facts.Add((New-DomeniaFact -Fait 'Inventaire WAPT' -Valeur 'Aucune donnee WAPT lue pour ce poste' -Etat 'Inconnu' -Source $source -Limite 'Absence de donnee WAPT : ce n est ni une panne ni la preuve que le poste est absent.'))
        return [pscustomobject]@{Found=$false;Attributed=$false;Computer='';Fqdn='';Uuid='';LastSeenUtc=$null;Stale=$false;HostStatus='';Os='';MappingVersion='WaptHost/1';ReadOnly=$true;Facts=$facts.ToArray()}
    }
    $uuid = ([string](Get-DomeniaMember $Record 'uuid' '')).Trim()
    $fqdn = ([string](Get-DomeniaMember $Record 'computer_fqdn' '')).Trim().TrimEnd('.')
    $expected = ([string]$ExpectedFqdn).Trim().TrimEnd('.')
    $computer = ([string](Get-DomeniaMember $Record 'computer_name' '')).Trim()
    $status = ([string](Get-DomeniaMember $Record 'host_status' '')).Trim()
    $os = (([string](Get-DomeniaMember $Record 'os_name' '')).Trim() + ' ' + ([string](Get-DomeniaMember $Record 'os_version' '')).Trim()).Trim()
    $seen = ConvertTo-DomeniaUtcDate (Get-DomeniaMember $Record 'last_seen_on' $null)
    $now = ConvertTo-DomeniaUtcDate $NowUtc
    $stale = $false
    if (($null -ne $seen) -and ($null -ne $now)) { $stale = (($now - $seen).TotalDays -gt $StaleDays) }
    $attributed = $null
    if ($expected) {
        $attributed = ([bool]$fqdn -and ($fqdn -ieq $expected))
        if (-not $attributed) {
            $facts.Add((New-DomeniaFact -Fait 'Correspondance WAPT' -Valeur ('WAPT : ' + $fqdn + ' ; AD : ' + $expected) -Etat 'Inconnu' -Source $source -Limite 'Noms differents : ces donnees WAPT ne sont pas attribuees a ce poste.'))
            return [pscustomobject]@{Found=$true;Attributed=$false;Computer=$computer;Fqdn=$fqdn;Uuid=$uuid;LastSeenUtc=$seen;Stale=$stale;HostStatus=$status;Os=$os;MappingVersion='WaptHost/1';ReadOnly=$true;Facts=$facts.ToArray()}
        }
    }
    $limit = 'Etat declare par l agent WAPT lors de sa derniere remontee ; ce n est pas une lecture du poste.'
    if ($stale) { $limit = 'Donnee ancienne : derniere remontee il y a plus de ' + $StaleDays + ' jours. ' + $limit }
    if ($null -eq $attributed) { $limit += ' Correspondance avec le poste AD non verifiee.' }
    $statusText = 'Etat WAPT : ' + $status
    if ($status -ieq 'OK') { $statusText = 'A jour selon WAPT' }
    elseif ($status -ieq 'TO-UPGRADE') { $statusText = 'Mises a jour en attente selon WAPT' }
    elseif ($status -ieq 'ERROR') { $statusText = 'Erreur signalee par WAPT' }
    # Observed only when the record is recent and matched to the AD computer.
    $stateLevel = 'Estime'
    if ((-not $stale) -and ($null -ne $seen) -and ($attributed -eq $true)) { $stateLevel = 'Constate' }
    $dateLevel = 'Estime'
    if ($attributed -eq $true) { $dateLevel = 'Constate' }
    if ($status) { $facts.Add((New-DomeniaFact -Fait 'Etat WAPT' -Valeur $statusText -Etat $stateLevel -Source $source -Limite $limit -Date $seen)) }
    else { $facts.Add((New-DomeniaFact -Fait 'Etat WAPT' -Valeur '' -Etat 'Inconnu' -Source $source -Limite 'Etat non fourni par WAPT.')) }
    if ($null -ne $seen) {
        $seenText = $seen.ToString('yyyy-MM-dd HH:mm',[Globalization.CultureInfo]::InvariantCulture) + ' UTC'
        if ($stale) { $seenText += ' (ancienne)' }
        $facts.Add((New-DomeniaFact -Fait 'Derniere remontee WAPT' -Valeur $seenText -Etat $dateLevel -Source $source -Limite $limit -Date $seen))
    }
    else { $facts.Add((New-DomeniaFact -Fait 'Derniere remontee WAPT' -Valeur 'Date non fournie' -Etat 'Inconnu' -Source $source -Limite 'Sans date, l anciennete de la donnee est inconnue.')) }
    if ($os) { $facts.Add((New-DomeniaFact -Fait 'Systeme declare a WAPT' -Valeur $os -Etat $stateLevel -Source $source -Limite $limit -Date $seen)) }
    return [pscustomobject]@{Found=$true;Attributed=$attributed;Computer=$computer;Fqdn=$fqdn;Uuid=$uuid;LastSeenUtc=$seen;Stale=$stale;HostStatus=$status;Os=$os;MappingVersion='WaptHost/1';ReadOnly=$true;Facts=$facts.ToArray()}
}
