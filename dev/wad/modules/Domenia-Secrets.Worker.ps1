# D058: BitLocker recovery read in two steps. Each body is a single-quoted here-string pinned by SHA-256.
# ReadBitLockerList : metadata only (name, DN, recovery GUID, creation date). msFVE-RecoveryPassword is NOT requested.
# ReadBitLockerKey  : ONE key, chosen by the operator, read with a Base search on its own DN, after checking that
#                     the object is a direct child of the selected computer and carries the expected recovery GUID.
# Both bodies return their failures as data (ErrorKind, ErrorMessage) like ReadLaps: a rejected Secrets account
# is a refusal for this resource only and never suspends the directory channel of the session.

function Get-DomeniaBitLockerListWorkerCode {
return @'
$entries = New-Object Collections.ArrayList
$objectCount = 0
$errorKind = ''
$errorMessage = ''
$searcher = $null
$results = $null
try {
    $searcher = New-WSearcher $Context ([string]$Payload.DN) "(objectClass=msFVE-RecoveryInformation)" @("name","distinguishedName","msFVE-RecoveryGuid","whenCreated") "OneLevel" 0
    $results = $searcher.FindAll()
    foreach ($r in $results) {
        $objectCount++
        if ($objectCount -gt 256) { break }
        $p = $r.Properties
        [void]$entries.Add([pscustomobject]@{
            Name = [string](Get-WPropFirst $p "name" "")
            DN = [string](Get-WPropFirst $p "distinguishedname" "")
            RecoveryGuid = (Convert-WGuid (Get-WPropFirst $p "msfve-recoveryguid" ""))
            WhenCreated = (Get-WPropFirst $p "whencreated" $null)
        })
    }
} catch {
    $diagnostic = Get-DomeniaStructuredError $_ -Phase ([string]$Context.OperationId) -Provider 'LDAP' -Target ([string]$Context.Server)
    $errorKind = [string]$diagnostic.Kind
    if (-not $errorKind -or $errorKind -eq 'Unknown') { $errorKind = 'ReadFailed' }
    $errorMessage = '[DOMENIA:' + $diagnostic.Kind + ';' + $diagnostic.NativeCode + ';' + $diagnostic.Code + '] ' + $_.Exception.Message
} finally {
    if ($null -ne $results) { try { $results.Dispose() } catch { } }
    if ($null -ne $searcher) { try { $searcher.Dispose() } catch { } }
}
$reader = [string]$Context.BindUser
if (-not $reader) { $reader = [string]$Context.ProcessIdentity }
[pscustomobject]@{ Mode="BitLockerList"; Success=(-not $errorKind); Entries=@($entries); RecoveryObjectsFound=$objectCount; ErrorKind=$errorKind; ErrorMessage=$errorMessage; Reader=$reader }
'@
}

function Get-DomeniaBitLockerKeyWorkerCode {
return @'
$computerDn = ([string]$Payload.DN).Trim()
$keyDn = ([string]$Payload.KeyDn).Trim()
$wanted = ([string]$Payload.KeyGuid).Trim().Trim('{','}')
$row = $null
$errorKind = ''
$errorMessage = ''
$objectCount = 0
if (-not $computerDn -or -not $keyDn -or -not $wanted) { throw 'Demande de cle BitLocker incomplete. Aucune lecture envoyee.' }
if ($keyDn.Length -le ($computerDn.Length + 1) -or -not $keyDn.EndsWith(',' + $computerDn, [StringComparison]::OrdinalIgnoreCase)) { throw 'La cle demandee n appartient pas au poste selectionne. Aucune lecture envoyee.' }
$rdn = $keyDn.Substring(0, $keyDn.Length - $computerDn.Length - 1)
if ((($rdn -replace '\\.', '') -match ',') -or $rdn.EndsWith('\')) { throw 'La cle demandee n est pas un enfant direct du poste. Aucune lecture envoyee.' }
$searcher = $null
$results = $null
try {
    $searcher = New-WSearcher $Context $keyDn "(objectClass=msFVE-RecoveryInformation)" @("distinguishedName","msFVE-RecoveryGuid","msFVE-RecoveryPassword","whenCreated") "Base" 1
    $results = $searcher.FindAll()
    $guid = ''
    $value = ''
    $created = ''
    foreach ($r in $results) {
        $objectCount++
        $p = $r.Properties
        $guid = Convert-WGuid (Get-WPropFirst $p "msfve-recoveryguid" "")
        $value = [string](Get-WPropFirst $p "msfve-recoverypassword" "")
        $created = Convert-WDate (Get-WPropFirst $p "whencreated" "")
    }
    if ($objectCount -ne 1) {
        $errorKind = 'NoReadableValue'
        $errorMessage = 'Objet de recuperation non visible avec ce compte. L absence de resultat ne prouve pas l absence de cle.'
    } elseif ($guid -ine $wanted) {
        $errorKind = 'Mismatch'
        $errorMessage = 'Identifiant de recuperation different de la cle choisie : aucune valeur renvoyee.'
    } elseif (-not $value) {
        $errorKind = 'AccessDenied'
        $errorMessage = 'Objet de recuperation visible, mais la cle n est pas lisible avec ce compte.'
    } else {
        $row = [pscustomobject]@{ Kind="BitLocker"; Account=$guid.ToUpperInvariant(); Value=$value; Timestamp=$created; Source="msFVE-RecoveryInformation"; Detail=$keyDn }
    }
    $value = ''
} catch {
    $diagnostic = Get-DomeniaStructuredError $_ -Phase ([string]$Context.OperationId) -Provider 'LDAP' -Target ([string]$Context.Server)
    $errorKind = [string]$diagnostic.Kind
    if (-not $errorKind -or $errorKind -eq 'Unknown') { $errorKind = 'ReadFailed' }
    $errorMessage = '[DOMENIA:' + $diagnostic.Kind + ';' + $diagnostic.NativeCode + ';' + $diagnostic.Code + '] ' + $_.Exception.Message
} finally {
    if ($null -ne $results) { try { $results.Dispose() } catch { } }
    if ($null -ne $searcher) { try { $searcher.Dispose() } catch { } }
}
[pscustomobject]@{ Mode="BitLockerKey"; Success=($null -ne $row); Rows=@($(if ($null -ne $row) { $row })); KeyDn=$keyDn; KeyGuid=$wanted.ToUpperInvariant(); ErrorKind=$errorKind; ErrorMessage=$errorMessage }
'@
}

function Get-DomeniaBitLockerPresenceWorkerCode {
# BitLockerPresence (lot L01, decision David 2026-10-08): presence of recovery objects for the workstations of the OU
# shown on Accueil, on an explicit gesture. One paged search under that OU, refused at the domain root; it asks for
# name, distinguishedName and whenCreated only, never msFVE-RecoveryPassword nor msFVE-KeyPackage. One small read of the
# schema tells "class absent from this domain" from "no object visible with this account".
return @'
$ouDn = ([string]$Payload.DN).Trim()
$baseDn = ([string]$Context.BaseDn).Trim()
if (-not $ouDn) { throw 'OU absente : aucune lecture envoyee.' }
if ($baseDn -and ($ouDn -ieq $baseDn)) { throw 'Lecture refusee a la racine du domaine : choisissez une OU dans Rechercher.' }
if ($ouDn -notmatch '^(?i:OU|CN)=') { throw 'Perimetre de lecture invalide : une OU est attendue.' }
if ($baseDn -and (-not $ouDn.EndsWith(',' + $baseDn,[StringComparison]::OrdinalIgnoreCase))) { throw 'OU hors du domaine de la session : aucune lecture envoyee.' }
$limit = 100000
if ($null -ne $Payload.PSObject.Properties['Limit']) { $limit = [Math]::Max(1,[Math]::Min(100000,[int]$Payload.Limit)) }
$computers = @{}
$objectCount = 0
$truncated = $false
$classPresent = $true
$errorKind = ''
$errorMessage = ''
$schemaSearcher = $null; $schemaResults = $null; $searcher = $null; $results = $null
try {
    $schemaNc = ''
    try {
        $rootDse = New-WRootDse $Context
        $rootDse.RefreshCache(@('schemaNamingContext'))
        $schemaNc = [string]$rootDse.Properties['schemaNamingContext'].Value
    } catch { $schemaNc = '' }
    if ($schemaNc) {
        $schemaSearcher = New-WSearcher $Context $schemaNc '(&(objectClass=classSchema)(lDAPDisplayName=msFVE-RecoveryInformation))' @('lDAPDisplayName') 'OneLevel' 0
        $schemaResults = $schemaSearcher.FindAll()
        $classCount = 0
        foreach ($schemaResult in $schemaResults) { $classCount++ }
        $classPresent = ($classCount -gt 0)
    }
    if ($classPresent) {
        $searcher = New-WSearcher $Context $ouDn '(objectClass=msFVE-RecoveryInformation)' @('name','distinguishedName','whenCreated') 'Subtree' 0
        $searcher.PageSize = 500
        $results = $searcher.FindAll()
        foreach ($r in $results) {
            $objectCount++
            if ($objectCount -gt $limit) { $truncated = $true; break }
            $dn = [string](Get-WPropFirst $r.Properties 'distinguishedname' '')
            # The recovery object is a direct child of its computer: its parent DN is the computer DN.
            $parent = ''
            for ($i = 0; $i -lt $dn.Length; $i++) {
                if ($dn[$i] -eq [char]92) { $i++; continue }
                if ($dn[$i] -eq [char]44) { $parent = $dn.Substring($i + 1); break }
            }
            if (-not $parent) { continue }
            $key = $parent.ToLowerInvariant()
            $created = ''
            $raw = Get-WPropFirst $r.Properties 'whencreated' $null
            try { if ($raw -is [datetime]) { $created = $raw.ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture) } } catch { $created = '' }
            if (-not $computers.ContainsKey($key)) { $computers[$key] = [pscustomobject]@{ DN = $parent; Keys = 0; Last = '' } }
            $computers[$key].Keys = [int]$computers[$key].Keys + 1
            if ($created -and ([string]::CompareOrdinal($created,[string]$computers[$key].Last) -gt 0)) { $computers[$key].Last = $created }
        }
    }
} catch {
    $diagnostic = Get-DomeniaStructuredError $_ -Phase ([string]$Context.OperationId) -Provider 'LDAP' -Target ([string]$Context.Server)
    $errorKind = [string]$diagnostic.Kind
    if (-not $errorKind -or $errorKind -eq 'Unknown') { $errorKind = 'ReadFailed' }
    $errorMessage = '[DOMENIA:' + $diagnostic.Kind + ';' + $diagnostic.NativeCode + ';' + $diagnostic.Code + '] ' + $_.Exception.Message
} finally {
    if ($null -ne $results) { try { $results.Dispose() } catch { } }
    if ($null -ne $searcher) { try { $searcher.Dispose() } catch { } }
    if ($null -ne $schemaResults) { try { $schemaResults.Dispose() } catch { } }
    if ($null -ne $schemaSearcher) { try { $schemaSearcher.Dispose() } catch { } }
}
[pscustomobject]@{ Mode='BitLockerPresence'; Success=(-not $errorKind); DN=$ouDn; ClassPresent=$classPresent; RecoveryObjectsFound=$objectCount; Truncated=$truncated; Computers=@($computers.Values); ErrorKind=$errorKind; ErrorMessage=$errorMessage; ReadAtUtc=[datetime]::UtcNow.ToString('o') }
'@
}
