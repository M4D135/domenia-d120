# Points 139 et 140 : contrat Domenia.Automation/1 (commandes versionnees, perimetre, requetes SQL en lecture seule,
# secrets exclus, CSV neutralise) et dossier de diagnostic hors ligne Domenia.OfflineDossier/1. Regles pures, sans base,
# sans reseau, sans WPF ; donnees fictives (corp.example).
. (Join-Path $modules 'Domenia-Automation.Model.ps1')

Test-Case 'AUT-001' 'Point 140 : commandes versionnees de lecture et d export, sans port ni service' {
    $contract = Get-DomeniaAutomationContract
    Assert-Equal 'Domenia.Automation/1' $contract.Contract
    Assert-Equal 1 ([int]$contract.Version)
    Assert-Equal 'version,etat,postes,observations,associations,requetes,dossier' ((@($contract.Commands) | ForEach-Object { $_.Name }) -join ',')
    Assert-True ($contract.Transport -match 'aucun port réseau, aucun service') $contract.Transport
    foreach ($command in @($contract.Commands)) { Assert-True ([string]$command.Kind -in @('Lecture','Export')) ('nature : ' + $command.Name) }
    Assert-Equal 'postes,observations,associations,dossier' ((@($contract.Commands | Where-Object { $_.Perimeter } | ForEach-Object { $_.Name })) -join ',') 'commandes a perimetre'
    Assert-Equal 4 ([int]$contract.ExitCodes.Refus)
}
Test-Case 'AUT-002' 'Point 140 : demande validee, perimetre obligatoire, refus nommes avec leur code de sortie' {
    $db = 'C:\Domenia\Domains\corp\Domenia.db'
    $check = { param($Expected,$Arguments) $r = Test-DomeniaAutomationRequest @Arguments; Assert-False $r.Valid ('accepte : ' + ($Arguments | Out-String)); Assert-Equal $Expected ([int]$r.ExitCode) $r.Error; $r.Error }
    [void](& $check 2 @{Command='effacer';DatabasePath=$db})
    [void](& $check 2 @{Command='etat'})
    [void](& $check 2 @{Command='etat';DatabasePath='C:\Domenia\base.sqlite'})
    Assert-True ((& $check 4 @{Command='observations';DatabasePath=$db}) -match 'tout le domaine') 'perimetre implicite'
    [void](& $check 2 @{Command='postes';DatabasePath=$db;OrganizationalUnit='OU=Postes,DC=corp,DC=example';Computers=@('PC-01')})
    [void](& $check 2 @{Command='postes';DatabasePath=$db;OrganizationalUnit='CN=Alice,OU=Users,DC=corp,DC=example'})
    [void](& $check 2 @{Command='postes';DatabasePath=$db;Computers=@('PC 01')})
    [void](& $check 2 @{Command='postes';DatabasePath=$db;Guids=@('pas-un-guid')})
    [void](& $check 2 @{Command='postes';DatabasePath=$db;Computers=@('PC-01');Limit=5001})
    [void](& $check 2 @{Command='observations';DatabasePath=$db;Computers=@('PC-01');Family='Secrets'})
    [void](& $check 2 @{Command='observations';DatabasePath=$db;Computers=@('PC-01');Format='Csv'})
    [void](& $check 2 @{Command='dossier';DatabasePath=$db;Computers=@('PC-01')})
    [void](& $check 2 @{Command='dossier';DatabasePath=$db;Computers=@('PC-01');OutputPath='D:\Diag';Sections=@('secrets')})
    $many = @(1..501 | ForEach-Object { 'PC-' + $_ })
    [void](& $check 2 @{Command='postes';DatabasePath=$db;Computers=$many})
    $ok = Test-DomeniaAutomationRequest -Command 'POSTES' -DatabasePath $db -OrganizationalUnit ' OU=Postes Paris , DC=corp,DC=example ' -Format 'csv'
    Assert-True $ok.Valid $ok.Error
    Assert-Equal 'postes' $ok.Request.Command
    Assert-Equal 'Csv' $ok.Request.Format
    Assert-Equal 'OU' $ok.Request.Perimeter.Kind
    Assert-Equal 'OU=Postes Paris,DC=corp,DC=example' $ok.Request.Perimeter.OrganizationalUnit
    Assert-Equal 1000 ([int]$ok.Request.Limit)
    $names = Test-DomeniaAutomationRequest -Command 'associations' -DatabasePath $db -Computers @('PC-01.corp.example$','pc-01,PC-02')
    Assert-Equal 'pc-01,pc-02' (@($names.Request.Perimeter.Computers) -join ',')
    $dossier = Test-DomeniaAutomationRequest -Command 'dossier' -DatabasePath $db -Guids @('{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}') -OutputPath 'D:\Diag'
    Assert-True ($dossier.Valid -and ($dossier.Request.Format -eq 'Dossier') -and ((@($dossier.Request.Sections) -join ',') -eq 'etat,postes,observations,associations,requetes')) 'dossier par defaut'
    Assert-Equal 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' @($dossier.Request.Perimeter.Guids)[0]
    Assert-True (Test-DomeniaAutomationRequest -Command 'version').Valid 'version sans base'
}
Test-Case 'AUT-003' 'Point 140 : requetes en lecture seule, valeurs echappees, jamais la table des secrets' {
    Assert-Equal "'O''Brien'" (ConvertTo-DomeniaAutomationSqlText "O'Brien")
    Assert-Equal "'*,[Aa]_1%[*][?][[]]9'" (ConvertTo-DomeniaAutomationGlobText 'a_1%*?[]9')
    $request = (Test-DomeniaAutomationRequest -Command 'observations' -DatabasePath 'C:\x.db' -OrganizationalUnit "OU=O'Brien_1,DC=corp,DC=example" -Family 'Probe:hw.ram' -Limit 10).Request
    $sql = Get-DomeniaAutomationQuery -Kind Observations -Request $request
    Assert-True ($sql.Contains("o.distinguished_name GLOB '*,[Oo][Uu]=[Oo]''[Bb][Rr][Ii][Ee][Nn]_1,[Dd][Cc]=[Cc][Oo][Rr][Pp],[Dd][Cc]=[Ee][Xx][Aa][Mm][Pp][Ll][Ee]'")) $sql
    Assert-False ($sql -match '(?i)\blower\(o\.distinguished_name\)|\bLIKE\b') ('comparaison ASCII seulement : ' + $sql)
    Assert-True ($sql.Contains("b.family='Probe:hw.ram'") -and $sql.EndsWith('LIMIT 11;')) $sql
    $names = (Test-DomeniaAutomationRequest -Command 'postes' -DatabasePath 'C:\x.db' -Computers @('PC-01','PC-02')).Request
    Assert-True ((Get-DomeniaAutomationQuery -Kind Computers -Request $names).Contains("lower(o.name) IN ('pc-01','pc-02')")) 'liste de noms'
    foreach ($kind in @('Tables','Schema','StoreState','Sync','ObjectCounts','ObservationCounts','LinkCounts','RecipeCount')) {
        $text = Get-DomeniaAutomationQuery -Kind $kind
        Assert-True ($text -match '^SELECT ') ('lecture seule : ' + $kind)
    }
    foreach ($kind in @('Computers','Observations','Links','Recipes')) {
        $text = Get-DomeniaAutomationQuery -Kind $kind -Request $names
        Assert-True ($text -match '^SELECT ') ('lecture seule : ' + $kind)
        Assert-False ($text -match '(?i)\b(secret_state|INSERT|UPDATE|DELETE|DROP|ATTACH|PRAGMA)\b|laps') ('table ou colonne interdite : ' + $kind)
    }
}
Test-Case 'AUT-004' 'Point 139 : champs secrets exclus a toute profondeur, dates et compteurs gardes' {
    foreach ($name in @('Password','unicodePwd','ms-Mcs-AdmPwd','msLAPS-Password','LapsExpiry','RecoveryKey','BitLockerRecoveryPassword','ApiKey','Token','ClientSecret','Credential')) { Assert-True (Test-DomeniaDiagnosticSecretName $name) ('secret garde : ' + $name) }
    foreach ($name in @('PwdLastSet','pwd_last_set','Computer','Presence','Inventory','Rows','Count','CheckedUtc')) { Assert-False (Test-DomeniaDiagnosticSecretName $name) ('champ utile retire : ' + $name) }
    $value = [pscustomobject]@{Computer='PC-01';Inventory=[pscustomobject]@{Model='X1';LocalAdminPassword='Ex3mple!';Nested=@([pscustomobject]@{Token='abc';Disk='C:'})};Map=@{Secret='s';Name='n'}}
    $clean = Protect-DomeniaDiagnosticValue -Value $value -Path 'Inventory'
    Assert-Equal 'PC-01' $clean.Value.Computer
    Assert-Equal 'X1' $clean.Value.Inventory.Model
    Assert-True ($null -eq $clean.Value.Inventory.PSObject.Properties['LocalAdminPassword']) 'mot de passe conserve'
    Assert-True ($null -eq @($clean.Value.Inventory.Nested)[0].PSObject.Properties['Token']) 'jeton conserve'
    Assert-Equal 'C:' @($clean.Value.Inventory.Nested)[0].Disk
    Assert-True ($null -eq $clean.Value.Map.PSObject.Properties['Secret']) 'secret de dictionnaire conserve'
    Assert-Equal 'Inventory.Inventory.LocalAdminPassword,Inventory.Inventory.Nested[0].Token,Inventory.Map.Secret' (@($clean.Excluded) -join ',')
    $text = ConvertTo-Json -InputObject $clean.Value -Depth 10
    Assert-False ($text -match 'Ex3mple|abc') 'valeur secrete dans la sortie'
}
Test-Case 'AUT-005' 'Point 140 : lignes publiees, donnees illisibles ou trop volumineuses jamais presentees comme vides' {
    $rows = @(
        [pscustomobject]@{object_guid='aaaaaaaa-0000-0000-0000-000000000001';family='Inventory';dn='CN=PC-01,OU=Postes,DC=corp,DC=example';definition_hash='';attempt_at='2026-10-14T08:00:00Z';status='Success';error='';success_at='2026-10-14T08:00:00Z';payload='{"Computer":"PC-01","Inventory":{"Model":"X1","AdminPassword":"x"}}'},
        [pscustomobject]@{object_guid='aaaaaaaa-0000-0000-0000-000000000002';family='Console';dn='CN=PC-02,OU=Postes,DC=corp,DC=example';definition_hash='';attempt_at='2026-10-14T08:00:00Z';status='Error';error='Acces refuse.';success_at='';payload='{pas du json'},
        [pscustomobject]@{object_guid='aaaaaaaa-0000-0000-0000-000000000003';family='Presence';dn='CN=PC-03,OU=Postes,DC=corp,DC=example';definition_hash='';attempt_at='2026-10-14T08:00:00Z';status='Success';error='';success_at='2026-10-14T08:00:00Z';payload=('{"x":"' + ('a' * 262200) + '"}')}
    )
    $converted = ConvertTo-DomeniaAutomationItems -Kind Observations -Rows $rows
    $items = @($converted.Items)
    Assert-Equal 3 $items.Count
    Assert-Equal 'X1' $items[0].Donnees.Inventory.Model
    Assert-Equal 'aaaaaaaa-0000-0000-0000-000000000001:Inventory.Inventory.AdminPassword' (@($converted.Excluded) -join ',')
    Assert-True (($null -eq $items[1].Donnees) -and ($items[1].Note -match 'illisibles') -and ($items[1].Erreur -eq 'Acces refuse.')) 'donnees illisibles'
    Assert-True (($null -eq $items[2].Donnees) -and ($items[2].Note -match 'non reprises')) 'donnees trop volumineuses'
    $links = @((ConvertTo-DomeniaAutomationItems -Kind Links -Rows @([pscustomobject]@{computer='PC-01';user_login='alice';source='Import GLPI';confidence=0;verified_in_ad=1;observed_at='2026-10-14T08:00:00Z';details='Lot';user_guid='';computer_guid='';user_dn='';computer_dn=''})).Items)
    Assert-True ([bool]@($links)[0].VerifieAD) 'verification AD perdue'
    $envelope = New-DomeniaAutomationEnvelope -Command 'observations' -Items $items -Truncated $true -Excluded @($converted.Excluded) -NowUtc '2026-10-15T10:00:00Z'
    Assert-True (($envelope.Contract -eq 'Domenia.Automation/1') -and ($envelope.Count -eq 3) -and $envelope.Truncated -and ($envelope.GeneratedUtc -eq '2026-10-15T10:00:00.0000000Z')) 'enveloppe'
    Assert-True ($envelope.Meaning -match 'non revérifiées') 'portee de la lecture non dite'
}
Test-Case 'AUT-006' 'Point 140 : CSV point-virgule, guillemets doubles, formules neutralisees' {
    $csv = ConvertTo-DomeniaAutomationCsv -Items @([pscustomobject]@{Nom='PC-01';Description='=cmd|calc'},[pscustomobject]@{Nom='PC "02"';Description='+1'}) -Columns @('Nom','Description','Absent')
    $lines = $csv.TrimEnd() -split "`r`n"
    Assert-Equal '"Nom";"Description";"Absent"' $lines[0]
    Assert-Equal ('"PC-01";"' + "'" + '=cmd|calc";""') $lines[1]
    Assert-Equal ('"PC ""02""";"' + "'" + '+1";""') $lines[2]
}
Test-Case 'AUT-007' 'Point 139 : dossier date, manifeste, empreintes et lisez-moi honnete' {
    $request = (Test-DomeniaAutomationRequest -Command 'dossier' -DatabasePath 'C:\x.db' -OrganizationalUnit 'OU=Postes,DC=corp,DC=example' -OutputPath 'D:\Diag').Request
    $sections = [ordered]@{}
    $sections['etat'] = New-DomeniaAutomationEnvelope -Command 'etat' -Items @([pscustomobject]@{Base='x'}) -Request $request -NowUtc '2026-10-15T10:00:00Z'
    $sections['postes'] = New-DomeniaAutomationEnvelope -Command 'postes' -Items @([pscustomobject]@{Nom='PC-01'}) -Request $request -Truncated $true -NowUtc '2026-10-15T10:00:00Z'
    $dossier = New-DomeniaOfflineDossier -Sections $sections -Request $request -Source ([pscustomobject]@{Revision=12}) -Build 'TEST' -NowUtc '2026-10-15T10:00:00Z'
    Assert-Equal 'etat.json,postes.json,LISEZMOI.txt,manifeste.json,SHA256SUMS.txt' ((@($dossier.Files) | ForEach-Object { $_.Name }) -join ',')
    Assert-Equal 'Domenia.OfflineDossier/1' $dossier.Manifest.Contract
    foreach ($entry in @($dossier.Manifest.Files)) {
        $file = @($dossier.Files | Where-Object { $_.Name -eq $entry.Fichier })[0]
        Assert-Equal (Get-DomeniaTextHash $file.Text) $entry.Sha256 ('empreinte : ' + $entry.Fichier)
    }
    $sums = @($dossier.Files | Where-Object { $_.Name -eq 'SHA256SUMS.txt' })[0].Text
    $manifestFile = @($dossier.Files | Where-Object { $_.Name -eq 'manifeste.json' })[0]
    Assert-True ($sums.Contains((Get-DomeniaTextHash $manifestFile.Text).ToLowerInvariant() + '  manifeste.json')) 'manifeste absent des empreintes'
    $postes = @($dossier.Manifest.Sections | Where-Object { $_.Section -eq 'postes' })[0]
    Assert-True ($postes.Tronque -and ($postes.Elements -eq 1)) 'limite atteinte non reportee'
    $readme = @($dossier.Files | Where-Object { $_.Name -eq 'LISEZMOI.txt' })[0].Text
    Assert-True (($readme -match 'OU ou=postes,dc=corp,dc=example') -and ($readme -match 'ne sont revérifiées') -and ($readme -match 'BitLocker') -and ($readme -match 'TEST')) $readme
    Assert-Equal 'Domenia-Diagnostic-Postes-Paris-Nord-20261015-1000' (Get-DomeniaOfflineDossierName -Subject 'Postes Paris/Nord' -NowUtc '2026-10-15T10:00:00Z')
    Assert-Equal 'Domenia-Diagnostic-perimetre-20261015-1000' (Get-DomeniaOfflineDossierName -Subject ' / ' -NowUtc '2026-10-15T10:00:00Z')
}
Test-Case 'AUT-008' 'Point 139 : perimetre choisi a l ecran, jamais le domaine entier implicitement' {
    $pc = [pscustomobject]@{Type='Machine';Name='PC-01';Guid='AAAAAAAA-0000-0000-0000-000000000001'}
    $selected = Get-DomeniaOfflineDossierPerimeter -Scope Selected -SelectedObject $pc
    Assert-True (($selected.Valid) -and ($selected.Kind -eq 'Guids') -and (@($selected.Guids)[0] -eq 'aaaaaaaa-0000-0000-0000-000000000001') -and ($selected.Label -eq 'PC-01')) 'poste selectionne'
    Assert-False (Get-DomeniaOfflineDossierPerimeter -Scope Selected -SelectedObject ([pscustomobject]@{Type='Utilisateur';Name='alice';Guid='aaaaaaaa-0000-0000-0000-000000000009'})).Valid 'compte pris pour un poste'
    Assert-False (Get-DomeniaOfflineDossierPerimeter -Scope Selected -SelectedObject ([pscustomobject]@{Type='Machine';Name='PC-X';Guid=''})).Valid 'poste sans GUID'
    $rows = @(1..600 | ForEach-Object { [pscustomobject]@{Type='Machine';Name=('PC-' + $_);Guid=('aaaaaaaa-0000-0000-0000-' + ('{0:000000000000}' -f $_))} }) + @($pc,$pc,[pscustomobject]@{Type='Groupe';Name='G';Guid='bbbbbbbb-0000-0000-0000-000000000001'})
    $displayed = Get-DomeniaOfflineDossierPerimeter -Scope Displayed -DisplayedRows $rows
    Assert-True ($displayed.Valid -and ($displayed.Count -eq 500) -and $displayed.Truncated -and ($displayed.Label -match '500 premiers')) ('postes affiches : ' + $displayed.Count)
    Assert-False (Get-DomeniaOfflineDossierPerimeter -Scope Displayed -DisplayedRows @()).Valid 'liste vide acceptee'
    $branch = Get-DomeniaOfflineDossierPerimeter -Scope Branch -BranchDn 'OU=Postes,OU=Paris,DC=corp,DC=example' -DomainDn 'DC=corp,DC=example'
    Assert-True (($branch.Kind -eq 'OU') -and ($branch.OrganizationalUnit -ceq 'OU=Postes,OU=Paris,DC=corp,DC=example') -and ($branch.Label -ceq 'OU Postes')) 'OU selectionnee'
    $school = Get-DomeniaOfflineDossierPerimeter -Scope Branch -BranchDn 'OU=Écoles,DC=corp,DC=fr' -DomainDn 'DC=corp,DC=fr'
    Assert-True (($school.Valid) -and ($school.OrganizationalUnit -ceq 'OU=Écoles,DC=corp,DC=fr') -and ($school.Label -ceq 'OU Écoles')) 'OU accentuee de l arborescence'
    Assert-False (Get-DomeniaOfflineDossierPerimeter -Scope Branch -BranchDn 'DC=corp,DC=example' -DomainDn 'DC=corp,DC=example').Valid 'domaine entier accepte'
    Assert-False (Get-DomeniaOfflineDossierPerimeter -Scope Branch -BranchDn 'CN=Computers,DC=corp,DC=example').Valid 'conteneur accepte comme OU'
}
Test-Case 'AUT-009' 'Points 139 et 140 : OU au nom accentue comparee sans casse, y compris hors ASCII' {
    # SQLite GLOB, reproduced here for the patterns of ConvertTo-DomeniaAutomationGlobText: '*', classes of literal
    # characters, every other character compared exactly (case-sensitive).
    $toRegex = {
        param([string]$Literal)
        $body = $Literal.Substring(1,$Literal.Length - 2).Replace("''","'")
        $builder = New-Object Text.StringBuilder
        [void]$builder.Append('^')
        $i = 0
        while ($i -lt $body.Length) {
            $c = [string]$body[$i]
            if ($c -ceq '*') { [void]$builder.Append('.*'); $i++; continue }
            if ($c -ceq '[') { $end = $body.IndexOf(']',$i + 2); [void]$builder.Append('[' + [regex]::Escape($body.Substring($i + 1,$end - $i - 1)) + ']'); $i = $end + 1; continue }
            [void]$builder.Append([regex]::Escape($c)); $i++
        }
        [void]$builder.Append('$')
        $builder.ToString()
    }
    $db = 'C:\Domenia\Domains\corp\Domenia.db'
    foreach ($typed in @('OU=Écoles,DC=corp,DC=fr','ou=écoles,dc=corp,dc=fr','OU=ÉCOLES,DC=CORP,DC=FR')) {
        $check = Test-DomeniaAutomationRequest -Command 'postes' -DatabasePath $db -OrganizationalUnit $typed
        Assert-True $check.Valid $check.Error
        Assert-Equal $typed $check.Request.Perimeter.OrganizationalUnit 'casse de l OU saisie perdue'
        $sql = Get-DomeniaAutomationPerimeterSql $check.Request.Perimeter
        Assert-True ($sql.Contains('[Éé][Cc][Oo][Ll][Ee][Ss]')) $sql
        $regex = & $toRegex ($sql.Substring($sql.IndexOf('GLOB ') + 5))
        foreach ($dn in @('CN=PC1,OU=Écoles,DC=corp,DC=fr','cn=pc1,ou=écoles,dc=corp,dc=fr','CN=PC2,OU=Salle 3,OU=Écoles,DC=corp,DC=fr')) { Assert-True ([regex]::IsMatch($dn,$regex)) ($typed + ' ne trouve pas ' + $dn) }
        foreach ($dn in @('CN=PC1,OU=Ecoles,DC=corp,DC=fr','CN=PC1,OU=Grandes Écoles,DC=corp,DC=fr','CN=PC1,OU=Écoles,DC=autre,DC=fr')) { Assert-False ([regex]::IsMatch($dn,$regex)) ($typed + ' trouve ' + $dn) }
    }
    $wildcards = Get-DomeniaAutomationPerimeterSql ([pscustomobject]@{Kind='OU';OrganizationalUnit='OU=A*B?[x],DC=corp,DC=fr'})
    $regex = & $toRegex ($wildcards.Substring($wildcards.IndexOf('GLOB ') + 5))
    Assert-True ([regex]::IsMatch('CN=PC1,OU=a*b?[X],DC=corp,DC=fr',$regex)) 'caracteres GLOB du nom non litteraux'
    Assert-False ([regex]::IsMatch('CN=PC1,OU=AzzBy[x],DC=corp,DC=fr',$regex)) 'joker GLOB actif dans le nom de l OU'
}
Test-Case 'AUT-010' 'Point 139 : OfflineDossier reste une operation locale, sans compte d annuaire ni recu' {
    Assert-Equal 'Local' (Get-DomeniaOperationProvider 'OfflineDossier') 'voie du stockage ou de l annuaire'
    $needs = Get-DomeniaOperationCredentialNeeds 'OfflineDossier'
    Assert-False $needs.Directory 'annuaire requis'
    Assert-False $needs.DirectoryCredential 'compte d annuaire requis'
    Assert-False $needs.RemoteAdmin 'compte d administration distante requis'
    Assert-False $needs.Secrets 'compte des secrets requis'
    Assert-Equal 'Local' ([string]$needs.Resource)
    Assert-Equal 'LocalWrite' (Get-DomeniaOperationEffect 'OfflineDossier')
    $receipt = Get-DomeniaReceiptRequirement 'OfflineDossier'
    Assert-False $receipt.Required 'recu d intervention exige'
}
