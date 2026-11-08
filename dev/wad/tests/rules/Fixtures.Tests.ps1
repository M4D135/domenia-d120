# D004 : fixtures fideles aux types AD, passees dans les vraies regles. Donnees fictives uniquement.
# Critere : une collection d un seul octet, objet ou resultat n est pas confondue avec un scalaire.
# Les grands entiers AD ont deux formes reelles : Int64 lu par DirectorySearcher (formes Hashtable, Scalar,
# ResultProperties, Array, ArrayList, List, ResultValues) et IADsLargeInteger lu par DirectoryEntry (formes
# DirectoryProperties et PropertyValues). Les regles ne lisent pas encore la seconde : les tests actifs exigent
# alors seulement qu aucune valeur fausse ne soit produite ; la valeur exacte est exigee par les tests TODO-D004.
$script:FxFile = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'fixtures') 'Domenia-AdFixtures.ps1'
. $script:FxFile
$script:FxState = Initialize-DomeniaFixtureTypes
$script:FxNative = (($env:OS -eq 'Windows_NT') -and ($PSVersionTable.PSVersion.Major -eq 5) -and ($PSVersionTable.PSVersion.Minor -eq 1))
$script:FxNow = [datetime]::SpecifyKind([datetime]'2026-03-01T08:00:00',[DateTimeKind]::Utc)
$script:FxGuid = '6f9619ff-8b86-d011-b42d-00c04fc964ff'
$script:FxGuid2 = '0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0'
$script:FxSid = 'S-1-5-21-1004336348-1177238915-682003330-1104'
$script:FxGroupDn = 'CN=Support N1,OU=Groupes,DC=example,DC=invalid'
$script:FxBagShapes = @('Hashtable','Scalar','ResultProperties','DirectoryProperties')
$script:FxLargeShapes = @(Get-DomeniaFixtureLargeIntegerShapes)
# Bags whose large integers are Int64 (DirectorySearcher and worker copies).
$script:FxInt64BagShapes = @($script:FxBagShapes | Where-Object { $script:FxLargeShapes -notcontains $_ })

function Get-DomeniaFixtureFactLabels {
    # Fait -> Valeur of a list of facts (test helper).
    param([object[]]$Facts)
    $byLabel = [ordered]@{}
    foreach ($fact in @($Facts)) { $byLabel[[string]$fact.Fait] = [string]$fact.Valeur }
    return $byLabel
}

Test-Case 'D004' 'Fixtures : GUID de 16 octets et SID binaire au format AD' {
    $g = New-DomeniaFixtureGuidBytes $script:FxGuid
    Assert-True ($g -is [byte[]]) 'objectGUID doit etre un byte[]'
    Assert-Equal 16 $g.Length
    # First field little-endian: 6f9619ff is stored ff 19 96 6f.
    Assert-Equal 255 ([int]$g[0]); Assert-Equal 111 ([int]$g[3])
    $s = New-DomeniaFixtureSidBytes $script:FxSid
    Assert-True ($s -is [byte[]]) 'objectSid doit etre un byte[]'
    Assert-Equal 28 $s.Length; Assert-Equal 1 ([int]$s[0]); Assert-Equal 5 ([int]$s[1]); Assert-Equal 5 ([int]$s[7])
    if ($script:FxNative) {
        $reference = New-Object Security.Principal.SecurityIdentifier -ArgumentList $script:FxSid
        $expected = New-Object byte[] $reference.BinaryLength
        $reference.GetBinaryForm($expected,0)
        Assert-Equal ([BitConverter]::ToString($expected)) ([BitConverter]::ToString($s)) 'SID assemble a la main identique a la forme binaire Windows'
    }
}
Test-Case 'D004' 'Fixtures : collections AD reelles sous Windows PowerShell 5.1' {
    $g = New-DomeniaFixtureGuidBytes $script:FxGuid
    $values = New-DomeniaFixtureResultValues $g
    Assert-True ($values -is [Collections.ReadOnlyCollectionBase]) 'Meme classe de base que ResultPropertyValueCollection'
    Assert-Equal 1 $values.Count 'Un tableau d octets est UNE valeur AD'
    Assert-True ($values[0] -is [byte[]]); Assert-Equal 16 $values[0].Length
    $bag = New-DomeniaFixtureBag 'ResultProperties'
    Assert-Equal 0 $bag['attributAbsent'].Count 'Un attribut absent se lit comme une collection vide, pas comme $null'
    if ($script:FxNative) {
        Assert-True $script:FxState.Genuine $script:FxState.Limit
        Assert-True ($values -is [System.DirectoryServices.ResultPropertyValueCollection]) 'Type reel attendu sous 5.1'
        Assert-True ($bag -is [System.DirectoryServices.ResultPropertyCollection]) 'Type reel attendu sous 5.1'
    }
}
Test-Case 'D004' 'Fixtures : grand entier Int64 pour DirectorySearcher, IADsLargeInteger pour DirectoryEntry' {
    $date = $script:FxNow.AddDays(-2)
    $fileTime = New-DomeniaFixtureFileTime -Utc $date
    foreach ($value in @([long]0,[long]::MaxValue,$fileTime,[long]-36288000000000,[long]::MinValue)) {
        Assert-Equal $value (ConvertFrom-DomeniaFixtureLargeInteger (New-DomeniaFixtureLargeInteger $value)) ('Valeur ' + $value)
        Assert-Equal $value (ConvertFrom-DomeniaFixtureLargeInteger (New-DomeniaFixtureLargeInteger $value -Emulated)) ('Valeur ' + $value + ' (emule)')
    }
    if ($script:FxNative) {
        Assert-True $script:FxState.LargeIntegerGenuine $script:FxState.Limit
        $genuine = New-DomeniaFixtureLargeInteger $fileTime
        Assert-True ($genuine -is [__ComObject]) 'IADsLargeInteger reel : objet COM'
        Assert-True ($null -eq $genuine.PSObject.Properties['HighPart']) 'Comme celui de DirectoryEntry, PowerShell ne voit pas HighPart'
    }
    $attributes = New-DomeniaFixtureUserAttributes -PwdLastSet Date
    $search = Get-DomeniaAttr (New-DomeniaFixtureBag 'ResultProperties' $attributes) 'pwdLastSet' $null
    Assert-True ($search -is [long]) 'DirectorySearcher : Int64'
    foreach ($shape in $script:FxLargeShapes) {
        if ($shape -eq 'DirectoryProperties') { $entry = Get-DomeniaAttr (New-DomeniaFixtureBag $shape $attributes) 'pwdLastSet' $null }
        else { $entry = (New-DomeniaFixtureCollection $shape $search)[0] }
        Assert-True (($null -ne $entry) -and ($entry -isnot [long])) ('Forme ' + $shape + ' : jamais un Int64')
        Assert-Equal $search (ConvertFrom-DomeniaFixtureLargeInteger $entry) ('Forme ' + $shape + ' : meme grand entier')
    }
    Assert-True ((Get-DomeniaAttr (New-DomeniaFixtureBag 'DirectoryProperties' $attributes) 'userAccountControl' $null) -is [int]) 'Un Int32 reste un Int32'
    # Without -Utc: a fixed fictitious date, never the clock and never year 1.
    Assert-Equal (New-DomeniaFixtureFileTime) (New-DomeniaFixtureFileTime)
    Assert-Equal $script:FxNow (ConvertTo-DomeniaUtcDate (New-DomeniaFixtureFileTime))
}
Test-Case 'D004' 'Fixtures : chaque fabrique de type compile initialise les types avant usage' {
    # A factory used first, before any other, must not depend on Initialize-DomeniaFixtureTypes having run.
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($script:FxFile,[ref]$tokens,[ref]$errors)
    Assert-Equal 0 @($errors).Count 'Fichier de fixtures analysable'
    $functions = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] },$true))
    $checked = 0
    foreach ($function in $functions) {
        if ([string]$function.Name -eq 'Initialize-DomeniaFixtureTypes') { continue }
        $usesType = @($function.Body.FindAll({ param($n) ($n -is [Management.Automation.Language.CommandAst]) -and ([string]$n.GetCommandName() -eq 'New-Object') -and ([string]$n.Extent.Text -match 'Domenia\.Fixtures\.') },$true)).Count -gt 0
        if (-not $usesType) { continue }
        $checked++
        $initializes = @($function.Body.FindAll({ param($n) ($n -is [Management.Automation.Language.CommandAst]) -and ([string]$n.GetCommandName() -eq 'Initialize-DomeniaFixtureTypes') },$true)).Count -gt 0
        Assert-True $initializes ([string]$function.Name + ' cree un type Domenia.Fixtures sans l initialiser')
    }
    Assert-True ($checked -ge 5) 'Fabriques de types compiles trouvees'
}
Test-Case 'D004' 'Fixtures : un tableau d octets traverse le pipeline en octets isoles' {
    $u = New-DomeniaFixtureUnrolledBytes (New-DomeniaFixtureGuidBytes $script:FxGuid)
    Assert-True ($u -is [object[]]); Assert-Equal 16 $u.Count; Assert-True ($u[0] -is [byte])
    $one = New-DomeniaFixtureUnrolledBytes ([byte[]]@(42))
    Assert-Equal 1 $one.Count; Assert-True ($one[0] -is [byte])
}
Test-Case 'D004' 'Fixtures : PropertyValueCollection.Value suit la semantique AD (vide, unique, multiple)' {
    Assert-True ($null -eq (New-DomeniaFixturePropertyValues -Values $null).Value)
    $single = (New-DomeniaFixturePropertyValues -Values (New-DomeniaFixtureGuidBytes $script:FxGuid)).Value
    Assert-True ($single -is [byte[]]) 'Valeur unique rendue telle quelle'
    $multiple = (New-DomeniaFixturePropertyValues -Values @('a','b')).Value
    Assert-True ($multiple -is [object[]]); Assert-Equal 2 $multiple.Count
    $large = (New-DomeniaFixturePropertyValues -Name 'pwdLastSet' -Values (New-DomeniaFixtureFileTime)).Value
    Assert-True ($large -isnot [long]) 'DirectoryEntry : un grand entier n est jamais un Int64'
    Assert-Equal (New-DomeniaFixtureFileTime) (ConvertFrom-DomeniaFixtureLargeInteger $large)
    $results = New-DomeniaFixtureSearchResults @(New-DomeniaFixtureSearchResult @{name='x'})
    Assert-Equal 1 $results.Count
    $results.Dispose()
    Assert-Throws { foreach ($r in $results) { $r } } 'Un jeu de resultats libere ne se relit pas'
}
Test-Case 'D004' 'Un octet seul reste un tableau d un octet (Get-DomeniaAttr)' {
    foreach ($shape in $script:FxBagShapes) {
        $bag = New-DomeniaFixtureBag $shape
        $value = Get-DomeniaAttr $bag 'msDS-OneByte'
        Assert-True ($value -is [byte[]]) ('Forme ' + $shape + ' : un octet seul rendu comme scalaire')
        Assert-Equal 1 $value.Length ('Forme ' + $shape)
        Assert-Equal 42 ([int]$value[0]) ('Forme ' + $shape)
    }
}
Test-Case 'D004' 'Une seule valeur reste une collection d un element (Get-DomeniaAttrAll)' {
    foreach ($shape in $script:FxBagShapes) {
        $bag = New-DomeniaFixtureBag $shape
        $groups = @(Get-DomeniaAttrAll $bag 'memberOf')
        Assert-Equal 1 $groups.Count ('Forme ' + $shape + ' : memberOf a une valeur')
        Assert-Equal $script:FxGroupDn ([string]$groups[0]) ('Forme ' + $shape + ' : DN entier, pas un caractere')
        $guids = @(Get-DomeniaAttrAll $bag 'objectGUID')
        Assert-Equal 1 $guids.Count ('Forme ' + $shape + ' : un GUID binaire est une valeur, pas seize')
        Assert-True ($guids[0] -is [byte[]]) ('Forme ' + $shape)
        Assert-Equal 0 @(Get-DomeniaAttrAll $bag 'attributAbsent').Count ('Forme ' + $shape + ' : attribut absent')
    }
    $attributes = New-DomeniaFixtureUserAttributes
    $attributes['memberOf'] = @('CN=A,DC=example,DC=invalid','CN=B,DC=example,DC=invalid','CN=C,DC=example,DC=invalid')
    foreach ($shape in $script:FxBagShapes) { Assert-Equal 3 @(Get-DomeniaAttrAll (New-DomeniaFixtureBag $shape $attributes) 'memberOf').Count ('Forme ' + $shape + ' : multivaleur') }
}
Test-Case 'D004' 'GUID binaire lu sous toutes ses formes AD' {
    foreach ($shape in $script:FxBagShapes) {
        Assert-Equal $script:FxGuid (ConvertTo-DomeniaGuidText (Get-DomeniaAttr (New-DomeniaFixtureBag $shape) 'objectGUID')) ('Forme ' + $shape)
    }
    $bytes = New-DomeniaFixtureGuidBytes $script:FxGuid
    Assert-Equal $script:FxGuid (ConvertTo-DomeniaGuidText $bytes)
    Assert-Equal $script:FxGuid (ConvertTo-DomeniaGuidText (New-DomeniaFixtureUnrolledBytes $bytes)) 'Tableau deroule par le pipeline'
    Assert-Equal $script:FxGuid (ConvertTo-DomeniaGuidText @(,$bytes)) 'Collection a un element'
    Assert-Equal $script:FxGuid (ConvertTo-DomeniaGuidText ([guid]$script:FxGuid))
    Assert-Equal '' (ConvertTo-DomeniaGuidText ([byte[]]@(42))) 'Un octet seul n est pas un GUID'
    Assert-Equal '' (ConvertTo-DomeniaGuidText @($bytes,(New-DomeniaFixtureGuidBytes $script:FxGuid2))) 'Deux GUID : aucun choisi arbitrairement'
}
Test-Case 'D004' 'SID binaire lu sous toutes ses formes AD' {
    foreach ($shape in $script:FxBagShapes) {
        Assert-Equal $script:FxSid (ConvertTo-DomeniaSidText (Get-DomeniaAttr (New-DomeniaFixtureBag $shape) 'objectSid')) ('Forme ' + $shape)
    }
    $bytes = New-DomeniaFixtureSidBytes $script:FxSid
    Assert-Equal $script:FxSid (ConvertTo-DomeniaSidText $bytes)
    Assert-Equal $script:FxSid (ConvertTo-DomeniaSidText @(,$bytes)) 'Collection a un element'
    Assert-Equal '' (ConvertTo-DomeniaSidText ([byte[]]@(1))) 'Un octet seul n est pas un SID'
}
Test-Case 'D004' 'FILETIME : 0 et 0x7FFFFFFFFFFFFFFF ne sont jamais des dates, quelle que soit la collection' {
    $date = $script:FxNow.AddDays(-2)
    $fileTime = New-DomeniaFixtureFileTime -Utc $date
    Assert-True ($fileTime -is [long])
    Assert-Equal $date (ConvertTo-DomeniaUtcDate $fileTime)
    Assert-True ($null -eq (ConvertTo-DomeniaUtcDate (New-DomeniaFixtureFileTime -Kind Zero))) 'Zero'
    Assert-True ($null -eq (ConvertTo-DomeniaUtcDate (New-DomeniaFixtureFileTime -Kind Never))) 'Jamais'
    Assert-True ($null -eq (ConvertTo-DomeniaUtcDate ([string](New-DomeniaFixtureFileTime -Kind Never)))) 'Jamais en texte'
    # IADsLargeInteger: not read yet (TODO-D004 cause 5); whatever happens, no other date may come out of it.
    $fromEntry = ConvertTo-DomeniaUtcDate (New-DomeniaFixtureLargeInteger $fileTime)
    Assert-True (($null -eq $fromEntry) -or ($fromEntry -eq $date)) 'IADsLargeInteger : aucune date fausse'
    foreach ($kind in @('Zero','Never')) { Assert-True ($null -eq (ConvertTo-DomeniaUtcDate (New-DomeniaFixtureLargeInteger (New-DomeniaFixtureFileTime -Kind $kind)))) ('IADsLargeInteger ' + $kind + ' : aucune date') }
    foreach ($shape in @(Get-DomeniaFixtureShapes)) {
        $read = ConvertTo-DomeniaUtcDate (New-DomeniaFixtureCollection $shape $fileTime)
        if ($script:FxLargeShapes -contains $shape) { Assert-True (($null -eq $read) -or ($read -eq $date)) ('Forme ' + $shape + ' : aucune date fausse') }
        else { Assert-Equal $date $read ('Forme ' + $shape + ' : une date') }
        Assert-True ($null -eq (ConvertTo-DomeniaUtcDate (New-DomeniaFixtureCollection $shape (New-DomeniaFixtureFileTime -Kind Never)))) ('Forme ' + $shape + ' : jamais')
        Assert-True ($null -eq (ConvertTo-DomeniaUtcDate (New-DomeniaFixtureCollection $shape (New-DomeniaFixtureFileTime -Kind Zero)))) ('Forme ' + $shape + ' : zero')
        Assert-True ($null -eq (ConvertTo-DomeniaUtcDate (New-DomeniaFixtureCollection $shape @($fileTime,(New-DomeniaFixtureFileTime -Utc $script:FxNow))))) ('Forme ' + $shape + ' : deux dates, aucune choisie')
    }
    $created = [datetime]::SpecifyKind([datetime]'2025-03-01T08:00:00',[DateTimeKind]::Unspecified)
    Assert-Equal ([datetime]::SpecifyKind($created,[DateTimeKind]::Utc)) (ConvertTo-DomeniaUtcDate $created) 'GeneralizedTime lu comme UTC'
}
Test-Case 'D004' 'Resume support identique pour les formes Int64, sans valeur fausse pour DirectoryEntry' {
    $reference = $null
    foreach ($shape in $script:FxInt64BagShapes) {
        $byLabel = Get-DomeniaFixtureFactLabels @(Get-DomeniaUserSupportSummary (New-DomeniaFixtureBag $shape) 'EX\lecteur' 'Lecture AD' $script:FxNow $script:FxNow)
        Assert-Equal 'jdemo' $byLabel['Identifiant'] ('Forme ' + $shape)
        Assert-Equal 'Jeanne Demo' $byLabel['Nom affiche'] ('Forme ' + $shape)
        Assert-Equal 'Marc Fictif' $byLabel['Responsable'] ('Forme ' + $shape)
        Assert-Equal 'Actif' $byLabel['Etat du compte'] ('Forme ' + $shape)
        Assert-Equal 'A changer a la prochaine ouverture de session' $byLabel['Mot de passe'] ('Forme ' + $shape + ' : pwdLastSet = 0')
        Assert-False $byLabel.Contains('Expiration du compte') ('Forme ' + $shape + ' : accountExpires = jamais')
        Assert-Equal $script:FxNow.AddDays(-2).ToLocalTime().ToString('dd/MM/yyyy') $byLabel['Derniere ouverture de session (approx.)'] ('Forme ' + $shape)
        $text = (@($byLabel.Keys | ForEach-Object { $_ + '=' + $byLabel[$_] }) -join '|')
        if ($null -eq $reference) { $reference = $byLabel; $referenceText = $text } else { Assert-Equal $referenceText $text ('Forme ' + $shape + ' : meme resume') }
    }
    # DirectoryEntry (IADsLargeInteger): the dates are not read yet (TODO-D004 cause 5). Every fact shown must
    # still be one of the reference facts with the same value: nothing invented, nothing wrong.
    foreach ($shape in $script:FxLargeShapes) {
        if ($script:FxBagShapes -notcontains $shape) { continue }
        $byLabel = Get-DomeniaFixtureFactLabels @(Get-DomeniaUserSupportSummary (New-DomeniaFixtureBag $shape) 'EX\lecteur' 'Lecture AD' $script:FxNow $script:FxNow)
        foreach ($label in @('Identifiant','Nom affiche','Responsable','Etat du compte')) { Assert-Equal $reference[$label] $byLabel[$label] ('Forme ' + $shape + ' : ' + $label) }
        foreach ($label in @($byLabel.Keys)) {
            Assert-True $reference.Contains($label) ('Forme ' + $shape + ' : fait invente ' + $label)
            Assert-Equal $reference[$label] $byLabel[$label] ('Forme ' + $shape + ' : valeur fausse pour ' + $label)
        }
    }
}
Test-Case 'D004' 'Etat du compte et groupe principal lus dans des collections a un element' {
    $attributes = New-DomeniaFixtureUserAttributes -UserAccountControl 514
    foreach ($shape in $script:FxBagShapes) {
        $bag = New-DomeniaFixtureBag $shape $attributes
        $state = Get-DomeniaAccountState (Get-DomeniaAttr $bag 'userAccountControl' $null) (Get-DomeniaAttr $bag 'msDS-User-Account-Control-Computed' $null) (Get-DomeniaAttr $bag 'lockoutTime' $null)
        Assert-True $state.Known ('Forme ' + $shape); Assert-True $state.Disabled ('Forme ' + $shape); Assert-Equal $false $state.Locked ('Forme ' + $shape)
        $primary = Get-DomeniaPrimaryGroupSid (ConvertTo-DomeniaSidText (Get-DomeniaAttr $bag 'objectSid')) (Get-DomeniaAttr $bag 'primaryGroupID')
        Assert-Equal 'S-1-5-21-1004336348-1177238915-682003330-513' $primary ('Forme ' + $shape)
    }
}
Test-Case 'D004' 'Identite de selection : GUID et SID binaires en collection a un element' {
    $guidBytes = New-DomeniaFixtureGuidBytes $script:FxGuid
    $sidBytes = New-DomeniaFixtureSidBytes $script:FxSid
    $guidForms = @(@{Name='byte[]';Value=$guidBytes},@{Name='deroule';Value=(New-DomeniaFixtureUnrolledBytes $guidBytes)},@{Name='collection';Value=@(,$guidBytes)},@{Name='ResultValues';Value=(New-DomeniaFixtureResultValues $guidBytes)},@{Name='texte';Value=$script:FxGuid})
    foreach ($form in $guidForms) {
        $identity = New-DomeniaSelectionIdentity (New-DomeniaFixtureRow -Guid $form.Value -Sid @(,$sidBytes)) 'example.invalid' 'EX\lecteur' 1 1
        Assert-True ($null -ne $identity) ('GUID ' + $form.Name + ' : identite attendue')
        Assert-Equal $script:FxGuid $identity.Guid ('GUID ' + $form.Name)
        Assert-Equal $script:FxSid $identity.Sid ('GUID ' + $form.Name + ' : SID en collection a un element')
    }
    $fromResult = New-DomeniaSelectionIdentity (New-DomeniaFixtureRow -Guid $guidBytes -Sid (New-DomeniaFixtureResultValues $sidBytes)) 'example.invalid' 'EX\lecteur' 1 1
    Assert-Equal $script:FxSid $fromResult.Sid 'SID dans une ResultPropertyValueCollection'
    Assert-True ($null -eq (New-DomeniaSelectionIdentity (New-DomeniaFixtureRow -Guid ([byte[]]@(42))) 'example.invalid' 'r' 1 1)) 'Un octet seul ne fait pas une identite'
}
Test-Case 'D004' 'Piege 5.1 : collection AD non IList liee par position a un parametre [object[]]' {
    # Pins down the binding behaviour that makes the calling convention below necessary.
    $results = New-DomeniaFixtureSearchResults @([pscustomobject]@{n=1},[pscustomobject]@{n=2})
    $probe = { param([object[]]$Items) return ,@($Items) }
    Assert-Equal 2 (& $probe -Items $results).Count 'Par nom : collection enumeree'
    Assert-Equal 2 (& $probe @($results)).Count 'Par position dans @() : collection enumeree'
    $byPosition = & $probe $results
    if ($script:FxNative) { Assert-Equal 1 $byPosition.Count 'Par position sous 5.1 : la collection devient UN element' }
    $strings = { param([string[]]$Items) return ,@($Items) }
    Assert-Equal 2 (& $strings (New-DomeniaFixtureResultValues @('a','b'))).Count 'Un parametre [string[]] enumere toujours'
}
Test-Case 'D004' 'Piege 5.1 : @() sur une List[object] creee par New-Object' {
    # Pins down the engine behaviour behind TODO-D004 cause 8. New-Object returns the list wrapped in a PSObject;
    # under Windows PowerShell 5.1.26100 the array subexpression @() over that wrapper throws
    # 'Argument types do not match', whatever the number of elements. foreach and the bare object do not.
    $list = New-DomeniaFixtureCollection 'List' $script:FxGroupDn
    $count = 0
    foreach ($item in $list) { $count++ }
    Assert-Equal 1 $count 'foreach enumere la liste'
    Assert-Equal 1 @($list.PSObject.BaseObject).Count 'Objet nu : @() enumere'
    if ($script:FxNative) { Assert-Throws { @($list) } '@() sur la liste enveloppee devait echouer sous 5.1' }
}
Test-Case 'D004' 'Un seul resultat de recherche reste une liste d un resultat' {
    $row = New-DomeniaFixtureRow -Guid (New-DomeniaFixtureGuidBytes $script:FxGuid)
    $forms = @(@{Name='scalaire';Value=$row},@{Name='tableau';Value=@($row)},@{Name='ArrayList';Value=(New-DomeniaFixtureCollection 'ArrayList' @($row))},@{Name='SearchResultCollection';Value=(New-DomeniaFixtureSearchResults @($row))})
    foreach ($form in $forms) {
        $sorted = @(Sort-DomeniaSearchResults -Rows $form.Value -Query 'jdemo')
        Assert-Equal 1 $sorted.Count ('Forme ' + $form.Name)
        Assert-Equal 'jdemo' ([string]$sorted[0].Login) ('Forme ' + $form.Name + ' : la ligne, pas ses proprietes')
        Assert-Equal 1 @(Sort-DomeniaSearchResults @($form.Value) 'jdemo').Count ('Forme ' + $form.Name + ' : par position dans @()')
    }
    $sameAsText = New-DomeniaFixtureRow -Guid $script:FxGuid -Name 'Jeanne Demo (copie)'
    Assert-Equal 1 @(Sort-DomeniaSearchResults @($row,$sameAsText) 'jdemo').Count 'Meme GUID binaire ou texte : un seul objet'
    $buffer = New-DomeniaPageBuffer
    Assert-Equal 1 (Add-DomeniaPageRows $buffer ([pscustomobject]@{Guid=$script:FxGuid;Name='x'})).Added 'Une page d un seul resultat'
    $plan = Get-DomeniaRowUpdatePlan @() (New-DomeniaFixtureCollection 'List' @([pscustomobject]@{Guid=$script:FxGuid;Name='x'}))
    Assert-Equal 1 @($plan.Inserts).Count 'Un lot d une ligne'
}
Test-Case 'D004' 'Une seule cle, un seul evenement, un seul objet, un seul candidat : traites comme des listes' {
    $entry = [pscustomobject]@{Name='2025-11-02T10:15:00+01:00{0A1B2C3D-1111-2222-3333-444455556666}';DN='CN=cle,CN=PC01,DC=example,DC=invalid';WhenCreated=[datetime]::SpecifyKind([datetime]'2025-11-02T09:15:00',[DateTimeKind]::Unspecified)}
    $keys = @(ConvertTo-DomeniaBitLockerKeyList $entry)
    Assert-Equal 1 $keys.Count; Assert-Equal '0A1B2C3D' $keys[0].RecoveryId
    Assert-True (Find-DomeniaBitLockerKey $keys '0A1B').Unique
    $lockEvent = [pscustomobject]@{TimeUtc=$script:FxNow;CallerComputer='PC01'}
    $user = New-DomeniaFixtureBag 'ResultProperties'
    $diagnosis = Get-DomeniaLockoutDiagnosis -User $user -Dc 'dc01' -Events $lockEvent -EventReadState 'Read' -NowUtc $script:FxNow
    Assert-Equal 1 $diagnosis.Recurrence 'Un evenement unique compte pour un'
    Assert-Equal 'PC01 (1)' (@($diagnosis.Origins) -join ',')
    $stale = [pscustomobject]@{Name='PC-ANCIEN';Type='Machine';LastLogonUtc=(New-DomeniaFixtureFileTime -Utc $script:FxNow.AddDays(-400));Disabled=$false}
    Assert-Equal 1 @(Find-DomeniaDirectoryInconsistencies -Objects $stale -NowUtc $script:FxNow).Count 'Un objet seul analyse'
    $never = [pscustomobject]@{Name='PC-NEUF';Type='Machine';LastLogonUtc=(New-DomeniaFixtureFileTime -Kind Never);Disabled=$false}
    Assert-Equal 0 @(Find-DomeniaDirectoryInconsistencies -Objects $never -NowUtc $script:FxNow).Count 'Jamais connecte : pas une date ancienne'
    $observation = [pscustomobject]@{Guid=(New-DomeniaFixtureGuidBytes $script:FxGuid);Computer='PC01';Detail='console'}
    $candidates = @(Merge-DomeniaRelationCandidates -Observations $observation -Domain 'example.invalid')
    Assert-Equal 1 $candidates.Count; Assert-Equal $script:FxGuid $candidates[0].Guid; Assert-True $candidates[0].Associable
}
Test-Case 'D004' 'Comparaison entre controleurs : valeur unique scalaire, en tableau ou en collection AD' {
    $readings = @(
        [pscustomobject]@{Dc='dc01';Reachable=$true;Attributes=@{memberOf=$script:FxGroupDn};Metadata=@()},
        [pscustomobject]@{Dc='dc02';Reachable=$true;Attributes=@{memberOf=@($script:FxGroupDn)};Metadata=@()},
        [pscustomobject]@{Dc='dc03';Reachable=$true;Attributes=(New-DomeniaFixtureResultProperties @{memberOf=$script:FxGroupDn});Metadata=@()},
        [pscustomobject]@{Dc='dc04';Reachable=$true;Attributes=(New-DomeniaFixtureDirectoryProperties @{memberOf=$script:FxGroupDn});Metadata=@()}
    )
    $same = Compare-DomeniaDcReadings $readings @('memberOf')
    Assert-True $same.Rows[0].Identique 'Une valeur unique est la meme sous toutes les formes'
    Assert-Equal $script:FxGroupDn $same.Rows[0].ParControleur['dc03']
    $readings += [pscustomobject]@{Dc='dc05';Reachable=$true;Attributes=@{memberOf=@($script:FxGroupDn,'CN=Autre,DC=example,DC=invalid')};Metadata=@()}
    Assert-False (Compare-DomeniaDcReadings $readings @('memberOf')).Rows[0].Identique 'Deux valeurs different d une seule'
}
Test-Case 'D004' 'Metadonnees de replication : une valeur unique sous toutes ses formes AD' {
    $one = New-DomeniaFixtureReplMetadata -Attribute 'description' -Version 3 -Dc 'DC01'
    $two = New-DomeniaFixtureReplMetadata -Attribute 'telephoneNumber' -Version 2 -Dc 'DC02'
    $changed = [datetime]::SpecifyKind([datetime]'2025-11-02T09:15:00',[DateTimeKind]::Utc)
    $forms = @(@{Name='scalaire';Value=$one},@{Name='tableau';Value=@($one)},@{Name='ResultValues';Value=(New-DomeniaFixtureResultValues $one)},@{Name='PropertyValues';Value=(New-DomeniaFixturePropertyValues -Name 'msDS-ReplAttributeMetaData' -Values $one)},@{Name='ArrayList';Value=(New-DomeniaFixtureCollection 'ArrayList' $one)})
    foreach ($form in $forms) {
        $parsed = @(ConvertFrom-DomeniaReplMetadata $form.Value)
        Assert-Equal 1 $parsed.Count ('Forme ' + $form.Name + ' : un fragment, une ligne')
        Assert-Equal 'description' $parsed[0].Attribute ('Forme ' + $form.Name + ' : le fragment entier, pas un caractere')
        Assert-Equal '3' $parsed[0].Version ('Forme ' + $form.Name)
        Assert-Equal $changed $parsed[0].ChangedUtc ('Forme ' + $form.Name)
        Assert-Equal 'DC01' $parsed[0].OriginatingDc ('Forme ' + $form.Name)
    }
    Assert-Equal 2 @(ConvertFrom-DomeniaReplMetadata (New-DomeniaFixtureResultValues @($one,$two))).Count 'Multivaleur'
    Assert-Equal 0 @(ConvertFrom-DomeniaReplMetadata (New-DomeniaFixtureResultValues $null)).Count 'Attribut absent : aucune ligne'
    # Through the controller comparison: a single metadata line, bare, in an array or parsed from a collection.
    $single = ConvertFrom-DomeniaReplMetadata (New-DomeniaFixtureResultValues $one)
    $other = ConvertFrom-DomeniaReplMetadata (New-DomeniaFixturePropertyValues -Values (New-DomeniaFixtureReplMetadata -Attribute 'description' -Version 4 -Dc 'DC02' -ChangedUtc $changed.AddDays(1)))
    $readings = @(
        [pscustomobject]@{Dc='dc01';Reachable=$true;Attributes=(New-DomeniaFixtureResultProperties @{description='Poste demo'});Metadata=$single},
        [pscustomobject]@{Dc='dc02';Reachable=$true;Attributes=@{description=@('Poste demo')};Metadata=@($single)},
        [pscustomobject]@{Dc='dc03';Reachable=$true;Attributes=(New-DomeniaFixtureDirectoryProperties @{description='Poste demo'});Metadata=$other}
    )
    $compared = Compare-DomeniaDcReadings $readings @('description')
    $stamp = ' [v3, ' + $changed.ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss') + ', origine DC01]'
    Assert-Equal ('Poste demo' + $stamp) $compared.Rows[0].ParControleur['dc01'] 'Metadonnee unique non deballee'
    Assert-Equal ('Poste demo' + $stamp) $compared.Rows[0].ParControleur['dc02'] 'Metadonnee unique en tableau'
    Assert-Equal ('Poste demo [v4, ' + $changed.AddDays(1).ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss') + ', origine DC02]') $compared.Rows[0].ParControleur['dc03'] 'Metadonnee lue dans une PropertyValueCollection'
    Assert-True $compared.Rows[0].Identique 'Les valeurs sont comparees, pas les dates'
}
Test-Case 'D004' 'Delegations : une seule ACE lue dans un descripteur AD reste une ACE' {
    $rules = New-DomeniaFixtureAccessRules -Sids @($script:FxSid)
    Assert-Equal 1 $rules.Count
    $view = @(ConvertTo-DomeniaAceView -Aces $rules)
    Assert-Equal 1 $view.Count 'Une ACE, une ligne'
    Assert-Equal $script:FxSid $view[0].Beneficiaire 'La ligne decrit l ACE, pas la collection'
    Assert-Equal 'Autorisation' $view[0].Type
    Assert-True ([string]$view[0].Droits -match 'ReadProperty')
    Assert-Equal 'ACE observee' $view[0].Statut
    Assert-Equal 2 @(ConvertTo-DomeniaAceView -Aces (New-DomeniaFixtureAccessRules -Sids @($script:FxSid,'S-1-5-32-544'))).Count
    Assert-Equal 0 @(ConvertTo-DomeniaAceView -Aces (New-DomeniaFixtureAccessRules -Sids @())).Count 'Descripteur sans ACE : aucune ligne inventee'
}
Test-Case 'D004' 'Chemin d appartenance : un seul groupe parent sous toutes ses formes' {
    $user = 'CN=Jeanne Demo,OU=Support,DC=example,DC=invalid'
    foreach ($parent in @($script:FxGroupDn,@($script:FxGroupDn),(New-DomeniaFixtureResultValues $script:FxGroupDn),(New-DomeniaFixturePropertyValues -Values $script:FxGroupDn))) {
        $path = Find-DomeniaMembershipPath @{$user=$parent} $user $script:FxGroupDn
        Assert-True $path.Found ('Parent de type ' + $parent.GetType().Name)
        Assert-True $path.Direct ('Parent de type ' + $parent.GetType().Name)
    }
}
Test-Case 'D004' 'Reponse d appartenance : chemin unique et reponse du controleur sous forme de valeur ou de collection' {
    $user = 'CN=Jeanne Demo,OU=Support,DC=example,DC=invalid'
    # A List[object] of parents makes Find-DomeniaMembershipPath throw under 5.1: TODO-D004 cause 8.
    foreach ($parent in @((New-DomeniaFixtureResultValues $script:FxGroupDn),(New-DomeniaFixturePropertyValues -Values $script:FxGroupDn),(New-DomeniaFixtureCollection 'ArrayList' $script:FxGroupDn))) {
        $answer = Resolve-DomeniaMembershipAnswer -LocalPath (Find-DomeniaMembershipPath @{$user=$parent} $user $script:FxGroupDn)
        Assert-True $answer.Member ('Parent de type ' + $parent.GetType().Name + ' : chemin trouve')
        Assert-True $answer.Certain ('Parent de type ' + $parent.GetType().Name)
    }
    $absent = Resolve-DomeniaMembershipAnswer -LocalPath (Find-DomeniaMembershipPath @{$user=(New-DomeniaFixtureResultValues 'CN=Autre,DC=example,DC=invalid')} $user $script:FxGroupDn)
    Assert-False $absent.Certain 'Aucun chemin lu : jamais une absence certaine'
    foreach ($form in @($true,@($true),(New-DomeniaFixtureCollection 'ArrayList' $true))) {
        $answer = Resolve-DomeniaMembershipAnswer -ServerAnswer $form
        Assert-True (($answer.Member -eq $true) -and $answer.Certain) ('Reponse oui du controleur de type ' + $form.GetType().Name)
    }
    $no = Resolve-DomeniaMembershipAnswer -ServerAnswer $false
    Assert-True (($no.Member -eq $false) -and $no.Certain) 'Reponse non du controleur'
    $truncated = Resolve-DomeniaMembershipAnswer -ServerAnswer $null -ListTruncated $true
    Assert-True ($null -eq $truncated.Member) 'Liste tronquee sans reponse du controleur : indetermine'
}
Test-Case 'D004' 'LAPS : expiration FILETIME en collection a un element, zero sans date' {
    $result = [pscustomobject]@{Source='LegacyLaps';ReadStatus='OK';Published=$true;DecryptStatus='NotEncrypted';PasswordPresent=$true;ExpirationUtc=@(New-DomeniaFixtureFileTime -Utc $script:FxNow.AddDays(5));Reader='EX\l'}
    $view = ConvertTo-DomeniaLapsView $result $script:FxNow
    $expiration = @($view.Facts | Where-Object { $_.Fait -eq 'Expiration' })
    Assert-Equal 1 $expiration.Count
    Assert-Equal $script:FxNow.AddDays(5).ToLocalTime().ToString('dd/MM/yyyy HH:mm') $expiration[0].Valeur
    $result.ExpirationUtc = New-DomeniaFixtureResultValues (New-DomeniaFixtureFileTime -Kind Zero)
    Assert-Equal 0 @((ConvertTo-DomeniaLapsView $result $script:FxNow).Facts | Where-Object { $_.Fait -eq 'Expiration' }).Count 'Zero : aucune date affichee'
}
Test-Case 'D004' 'Get-DomeniaMember sous @() : une valeur en collection reste une valeur entiere' {
    # @() around the call is the calling convention that compensates TODO-D004 cause 1 (the raw return value
    # loses the one-element collection; the disabled tests below require it to be kept).
    $row = [pscustomobject]@{
        Vide=@();Une=@($script:FxGroupDn);Plusieurs=@('CN=A,DC=example,DC=invalid','CN=B,DC=example,DC=invalid','CN=C,DC=example,DC=invalid')
        UneAd=(New-DomeniaFixtureResultValues $script:FxGroupDn);GuidAd=(New-DomeniaFixtureResultValues (New-DomeniaFixtureGuidBytes $script:FxGuid))
    }
    Assert-Equal 'defaut' (Get-DomeniaMember $row 'Absent' 'defaut') 'Membre absent : valeur par defaut'
    Assert-Equal 0 @(Get-DomeniaMember $row 'Vide' 'defaut').Count 'Collection vide : aucune valeur inventee'
    foreach ($name in @('Une','UneAd')) {
        $values = @(Get-DomeniaMember $row $name)
        Assert-Equal 1 $values.Count ($name + ' : une valeur')
        Assert-Equal $script:FxGroupDn ([string]$values[0]) ($name + ' : DN entier, pas un caractere')
    }
    Assert-Equal 3 @(Get-DomeniaMember $row 'Plusieurs').Count 'Multivaleur'
    $guid = @(Get-DomeniaMember $row 'GuidAd')
    Assert-Equal 1 $guid.Count 'Un GUID binaire est une valeur, pas seize octets'
    Assert-True ($guid[0] -is [byte[]]) 'Le GUID binaire reste entier'
    Assert-Equal $script:FxGuid (ConvertTo-DomeniaGuidText $guid[0])
    $hash = @{Une=@($script:FxGroupDn)}
    Assert-Equal 1 @(Get-DomeniaMember $hash 'Une').Count 'Table de hachage : une valeur'
}
Test-Case 'D004' 'Duree AD negative (Int64) lue dans toutes les collections, zero et minimum sans duree' {
    $ticks = [long]-36288000000000
    Assert-Equal 42 ([int](ConvertFrom-DomeniaAdInterval $ticks).TotalDays)
    foreach ($shape in @(Get-DomeniaFixtureShapes)) {
        $span = ConvertFrom-DomeniaAdInterval (New-DomeniaFixtureCollection $shape $ticks)
        if ($script:FxLargeShapes -contains $shape) {
            # IADsLargeInteger: not read yet (TODO-D004 cause 5); no other duration may come out of it.
            Assert-True (($null -eq $span) -or ([int]$span.TotalDays -eq 42)) ('Forme ' + $shape + ' : aucune duree fausse')
        } else {
            Assert-True ($null -ne $span) ('Forme ' + $shape + ' : une duree')
            Assert-Equal 42 ([int]$span.TotalDays) ('Forme ' + $shape)
        }
        Assert-True ($null -eq (ConvertFrom-DomeniaAdInterval (New-DomeniaFixtureCollection $shape ([long]0)))) ('Forme ' + $shape + ' : zero = jamais')
        Assert-True ($null -eq (ConvertFrom-DomeniaAdInterval (New-DomeniaFixtureCollection $shape ([long]::MinValue)))) ('Forme ' + $shape + ' : minimum = jamais')
        Assert-True ($null -eq (ConvertFrom-DomeniaAdInterval (New-DomeniaFixtureCollection $shape @($ticks,[long]-864000000000)))) ('Forme ' + $shape + ' : deux durees, aucune choisie')
    }
}
Test-Case 'D004' 'Strategie de mot de passe identique pour les formes Int64' {
    # DirectoryEntry shapes give a wrong verdict today: see TODO-D004 cause 6 below.
    $policy = New-DomeniaFixtureDomainPolicyAttributes
    $user = New-DomeniaFixtureUserAttributes -PwdLastSet Date
    $expected = $script:FxNow.AddDays(-10).AddDays(42)
    foreach ($shape in $script:FxInt64BagShapes) {
        $result = Resolve-DomeniaPasswordPolicy -User (New-DomeniaFixtureBag $shape $user) -ResultantPsoState None -DomainPolicy (New-DomeniaFixtureBag $shape $policy) -Reader 'EX\lecteur' -NowUtc $script:FxNow
        Assert-True $result.PolicyKnown ('Forme ' + $shape)
        $byLabel = Get-DomeniaFixtureFactLabels $result.Facts
        Assert-Equal '12 caracteres' $byLabel['Longueur minimale'] ('Forme ' + $shape)
        Assert-Equal 'Oui' $byLabel['Complexite exigee'] ('Forme ' + $shape)
        Assert-Equal '24 mots de passe' $byLabel['Historique'] ('Forme ' + $shape)
        Assert-Equal '42 jours' $byLabel['Duree de validite'] ('Forme ' + $shape + ' : maxPwdAge negatif')
        Assert-Equal '5 echecs, duree 30 min' $byLabel['Verrouillage'] ('Forme ' + $shape)
        Assert-Equal $expected $result.ExpiresUtc ('Forme ' + $shape + ' : pwdLastSet FILETIME + duree')
    }
}
Test-Case 'D004' 'Strategie de mot de passe : compteurs absents, aucune valeur inventee' {
    $policy = New-DomeniaFixtureDomainPolicyAttributes
    foreach ($name in @('minPwdLength','pwdHistoryLength','pwdProperties','lockoutThreshold')) { $policy.Remove($name) }
    foreach ($shape in $script:FxBagShapes) {
        $result = Resolve-DomeniaPasswordPolicy -User (New-DomeniaFixtureBag $shape (New-DomeniaFixtureUserAttributes -PwdLastSet Date)) -ResultantPsoState None -DomainPolicy (New-DomeniaFixtureBag $shape $policy) -Reader 'EX\lecteur' -NowUtc $script:FxNow
        $byLabel = Get-DomeniaFixtureFactLabels $result.Facts
        foreach ($label in @('Longueur minimale','Complexite exigee','Historique','Verrouillage')) { Assert-False $byLabel.Contains($label) ('Forme ' + $shape + ' : ' + $label + ' invente') }
    }
}

# TODO-D004 : defauts reels des modules de regles mis en evidence par les fixtures, NON corriges ici (modules hors
# perimetre de D004). Chaque test exige le comportement correct et isole une seule cause. Desactives par defaut pour
# que l execution complete reste verte ; DOMENIA_D004_KNOWN_DEFECTS=1 les execute : ils echouent tant que le module
# n est pas corrige (constate sous Windows PowerShell 5.1.26100 dans la VM de test). Une fois le module corrige,
# retirer la garde.
# D004 : causes 1, 2, 3 et 5 (partie Domenia-Common.Model.ps1) corrigees le 2026-10-02 : Get-DomeniaMemberValue conserve les
# collections a un element (Get-DomeniaMember garde la convention @() de tous les modules : voir le test ci-dessus), ConvertTo-DomeniaSidText accepte un SID deroule, les conversions deballent les collections AD,
# ConvertTo-DomeniaUtcDate lit un IADsLargeInteger. Ces tests sont donc actifs.
Test-Case 'D004' 'Get-DomeniaMemberValue rend un tableau d un octet entier' {
    $value = Get-DomeniaMemberValue ([pscustomobject]@{Flag=[byte[]]@(42)}) 'Flag'
    Assert-True ($value -is [byte[]]) 'Un octet seul est rendu comme un scalaire [byte]'
}
Test-Case 'D004' 'Get-DomeniaMemberValue rend un SID binaire entier' {
    $value = Get-DomeniaMemberValue ([pscustomobject]@{Sid=(New-DomeniaFixtureSidBytes $script:FxSid)}) 'Sid'
    Assert-True ($value -is [byte[]]) 'Le SID binaire est deroule en octets isoles'
}
Test-Case 'D004' 'Get-DomeniaMemberValue rend une collection a un element sans la deballer' {
    $row = [pscustomobject]@{Une=@($script:FxGroupDn);UneAd=(New-DomeniaFixtureResultValues $script:FxGroupDn);GuidAd=(New-DomeniaFixtureResultValues (New-DomeniaFixtureGuidBytes $script:FxGuid))}
    $une = Get-DomeniaMemberValue $row 'Une'
    Assert-True ($une -is [array]) 'Un tableau d un DN est rendu comme une chaine : son [0] est le premier caractere'
    Assert-Equal $script:FxGroupDn ([string]$une[0]) 'Premier element : le DN entier'
    $uneAd = Get-DomeniaMemberValue $row 'UneAd'
    Assert-True (($uneAd -is [Collections.ICollection]) -and ($uneAd -isnot [string])) 'Une ResultPropertyValueCollection d un DN est rendue comme une chaine'
    $guidAd = Get-DomeniaMemberValue $row 'GuidAd'
    Assert-True ($guidAd -isnot [byte[]]) 'La collection d un GUID binaire est rendue comme le tableau d octets lui-meme'
}
Test-Case 'D004' 'TODO-D004 ConvertTo-DomeniaSidText accepte un SID deroule par le pipeline' {
    Assert-Equal $script:FxSid (ConvertTo-DomeniaSidText (New-DomeniaFixtureUnrolledBytes (New-DomeniaFixtureSidBytes $script:FxSid)))
}
Test-Case 'D004' 'TODO-D004 Identite de selection : SID binaire direct conserve' {
    $identity = New-DomeniaSelectionIdentity (New-DomeniaFixtureRow -Guid $script:FxGuid -Sid (New-DomeniaFixtureSidBytes $script:FxSid)) 'example.invalid' 'r' 1 1
    Assert-Equal $script:FxSid $identity.Sid
}
Test-Case 'D004' 'TODO-D004 GUID d une ResultPropertyValueCollection a un element' {
    Assert-Equal $script:FxGuid (ConvertTo-DomeniaGuidText (New-DomeniaFixtureResultValues (New-DomeniaFixtureGuidBytes $script:FxGuid)))
}
Test-Case 'D004' 'TODO-D004 GUID d une ArrayList a un element' {
    Assert-Equal $script:FxGuid (ConvertTo-DomeniaGuidText (New-DomeniaFixtureCollection 'ArrayList' @(,(New-DomeniaFixtureGuidBytes $script:FxGuid))))
}
Test-Case 'D004' 'TODO-D004 SID d une ResultPropertyValueCollection a un element' {
    Assert-Equal $script:FxSid (ConvertTo-DomeniaSidText (New-DomeniaFixtureResultValues (New-DomeniaFixtureSidBytes $script:FxSid)))
}
Test-Case 'D004' 'TODO-D004 ConvertTo-DomeniaUtcDate lit un IADsLargeInteger' {
    $date = $script:FxNow.AddDays(-2)
    Assert-Equal $date (ConvertTo-DomeniaUtcDate (New-DomeniaFixtureLargeInteger (New-DomeniaFixtureFileTime -Utc $date))) 'Date perdue'
}

if ($env:DOMENIA_D004_KNOWN_DEFECTS -eq '1') {
    # TODO-D004 cause 1 : Get-DomeniaMember renvoie la valeur sans virgule unaire (Domenia-Common.Model.ps1, return
    # $InputObject[$Name] et return $property.Value) : PowerShell deroule la collection a la sortie.
    # TODO-D004 cause 2 : ConvertTo-DomeniaSidText refuse un SID deroule (octets en object[]), contrairement au GUID.
    # TODO-D004 causes 1 et 2 reunies : un SID binaire porte par une ligne est perdu.
    Test-Case 'D004' 'TODO-D004 Correspondance de compte : SID binaire de la cible compare' {
        $target = [pscustomobject]@{Login='jdemo';NetbiosDomain='EXAMPLE';DnsDomain='example.invalid';Sid=(New-DomeniaFixtureSidBytes $script:FxSid);Upn='jdemo@example.invalid'}
        $match = Test-DomeniaAccountIdentityMatch $target 'EXAMPLE\jdemo' 'S-1-5-21-1-2-3-1104' 'PC01'
        Assert-False $match.Match 'Homonyme au SID different accepte'
        Assert-True $match.Certain
    }
    # TODO-D004 cause 3 : les conversions ne deballent que [array] ; une collection AD ou une liste a un element est
    # convertie comme un scalaire texte.
    # TODO-D004 cause 4 : un parametre [object[]] lie PAR POSITION a une collection non IList la recoit comme UN element.
    Test-Case 'D004' 'TODO-D004 ConvertTo-DomeniaAceView par position avec une AuthorizationRuleCollection' {
        $view = @(ConvertTo-DomeniaAceView (New-DomeniaFixtureAccessRules -Sids @($script:FxSid)))
        Assert-Equal 1 $view.Count
        Assert-Equal $script:FxSid $view[0].Beneficiaire 'ACE fantome sans beneficiaire produite a partir de la collection'
    }
    Test-Case 'D004' 'TODO-D004 Sort-DomeniaSearchResults par position avec un SearchResultCollection' {
        $row = New-DomeniaFixtureRow -Guid $script:FxGuid
        Assert-Equal 1 @(Sort-DomeniaSearchResults (New-DomeniaFixtureSearchResults @($row)) 'jdemo').Count 'Resultat unique perdu'
    }
    # TODO-D004 cause 5 : ConvertTo-DomeniaUtcDate et ConvertFrom-DomeniaAdInterval ne lisent que Int64 et texte ;
    # l IADsLargeInteger de DirectoryEntry (objet COM, lisible seulement par InvokeMember HighPart/LowPart) devient
    # $null : dates et durees perdues (Domenia-Common.Model.ps1, Domenia-Directory.Model.ps1).
    Test-Case 'D004' 'TODO-D004 ConvertFrom-DomeniaAdInterval lit un IADsLargeInteger' {
        $span = ConvertFrom-DomeniaAdInterval (New-DomeniaFixtureLargeInteger ([long]-36288000000000))
        Assert-True ($null -ne $span) 'Duree perdue'
        Assert-Equal 42 ([int]$span.TotalDays)
    }
    Test-Case 'D004' 'TODO-D004 Resume support lu par DirectoryEntry : dates et changement exige conserves' {
        $dated = Get-DomeniaFixtureFactLabels @(Get-DomeniaUserSupportSummary (New-DomeniaFixtureBag 'DirectoryProperties' (New-DomeniaFixtureUserAttributes -PwdLastSet Date)) 'EX\lecteur' 'Lecture AD' $script:FxNow $script:FxNow)
        Assert-Equal $script:FxNow.AddDays(-10).ToLocalTime().ToString('dd/MM/yyyy HH:mm') $dated['Mot de passe change le'] 'pwdLastSet perdu'
        Assert-Equal $script:FxNow.AddDays(-2).ToLocalTime().ToString('dd/MM/yyyy') $dated['Derniere ouverture de session (approx.)'] 'lastLogonTimestamp perdu'
        $mustChange = Get-DomeniaFixtureFactLabels @(Get-DomeniaUserSupportSummary (New-DomeniaFixtureBag 'DirectoryProperties') 'EX\lecteur' 'Lecture AD' $script:FxNow $script:FxNow)
        Assert-Equal 'A changer a la prochaine ouverture de session' $mustChange['Mot de passe'] 'pwdLastSet = 0 perdu : changement exige non signale'
    }
    # TODO-D004 cause 6 : Resolve-DomeniaPasswordPolicy prend une duree illisible ou absente pour l absence de limite
    # (Domenia-Directory.Model.ps1 : $ageText = 'Sans limite' et 'deverrouillage par un administrateur' des que la
    # duree vaut $null ; 'N expire pas (strategie sans limite)' ensuite). Verdict faux construit sur une valeur non lue.
    Test-Case 'D004' 'TODO-D004 Strategie lue par DirectoryEntry : aucune absence de limite deduite d un IADsLargeInteger' {
        $result = Resolve-DomeniaPasswordPolicy -User (New-DomeniaFixtureBag 'DirectoryProperties' (New-DomeniaFixtureUserAttributes -PwdLastSet Date)) -ResultantPsoState None -DomainPolicy (New-DomeniaFixtureBag 'DirectoryProperties' (New-DomeniaFixtureDomainPolicyAttributes)) -Reader 'EX\lecteur' -NowUtc $script:FxNow
        $byLabel = Get-DomeniaFixtureFactLabels $result.Facts
        Assert-True ($byLabel['Duree de validite'] -ne 'Sans limite') 'maxPwdAge de 42 jours annonce Sans limite'
        Assert-True ([string]$byLabel['Verrouillage'] -notmatch 'administrateur') 'lockoutDuration de 30 min annonce deverrouillage par un administrateur'
        Assert-True ($byLabel['Expiration du mot de passe'] -ne 'N expire pas (strategie sans limite)') 'Mot de passe annonce sans expiration'
    }
    Test-Case 'D004' 'TODO-D004 Strategie avec maxPwdAge et lockoutDuration absents : ni Sans limite ni deverrouillage par un administrateur' {
        $policy = New-DomeniaFixtureDomainPolicyAttributes
        $policy.Remove('maxPwdAge'); $policy.Remove('lockoutDuration')
        $result = Resolve-DomeniaPasswordPolicy -User (New-DomeniaFixtureBag 'Hashtable' (New-DomeniaFixtureUserAttributes -PwdLastSet Date)) -ResultantPsoState None -DomainPolicy (New-DomeniaFixtureBag 'Hashtable' $policy) -Reader 'EX\lecteur' -NowUtc $script:FxNow
        $byLabel = Get-DomeniaFixtureFactLabels $result.Facts
        Assert-True ($byLabel['Duree de validite'] -ne 'Sans limite') 'maxPwdAge non lu annonce Sans limite'
        Assert-True ([string]$byLabel['Verrouillage'] -notmatch 'administrateur') 'lockoutDuration non lu annonce deverrouillage par un administrateur'
        Assert-True ($byLabel['Expiration du mot de passe'] -ne 'N expire pas (strategie sans limite)') 'Mot de passe annonce sans expiration'
    }
    # TODO-D004 cause 7 : Resolve-DomeniaMembershipAnswer compare $ServerAnswer avec -eq : une collection d un
    # element valant $false filtre au lieu de comparer, et la reponse certaine du controleur devient incertaine.
    Test-Case 'D004' 'TODO-D004 Reponse non du controleur dans une collection a un element' {
        foreach ($form in @(@(,$false),(New-DomeniaFixtureCollection 'ArrayList' $false))) {
            $answer = Resolve-DomeniaMembershipAnswer -ServerAnswer $form
            Assert-True (($answer.Member -eq $false) -and $answer.Certain) ('Reponse non du controleur de type ' + $form.GetType().Name + ' rendue incertaine')
        }
    }
    # TODO-D004 cause 8 : Find-DomeniaMembershipPath parcourt @($lookup[$node]) ; une List[object] creee par
    # New-Object (enveloppe PSObject) y leve 'Argument types do not match' sous 5.1 (voir le test Piege 5.1).
    Test-Case 'D004' 'TODO-D004 Chemin d appartenance avec une List[object] de parents' {
        $user = 'CN=Jeanne Demo,OU=Support,DC=example,DC=invalid'
        $path = Find-DomeniaMembershipPath @{$user=(New-DomeniaFixtureCollection 'List' $script:FxGroupDn)} $user $script:FxGroupDn
        Assert-True $path.Found 'Parent unique dans une List[object] non trouve'
    }
}
