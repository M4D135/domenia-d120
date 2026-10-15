# Point 133 : contrats versionnes entre modules (formats, erreurs, capacites). Regles pures de Domenia-Common.Model ;
# lectures seules des sources du depot pour verifier que chaque format ecrit est declare et lisible.
$script:CtrDev = Split-Path -Parent $wad
function New-CtrContract {
    param([string]$Family = 'Domenia.Exemple',[int]$Current = 3,[int[]]$Readable = @(1,2,3),[object[]]$Migrations = @())
    return [pscustomobject]@{ Family = $Family; Label = 'Exemple'; Kind = 'Format'; Separator = '/'; Current = $Current; Readable = $Readable; Migrations = $Migrations; Values = @(); Owner = 'test' }
}
function New-CtrStep { param([int]$From,[int]$To) return [pscustomobject]@{ From = $From; To = $To; Mode = 'Subset' } }

Test-Case 'CTR-001' 'Le catalogue livre est coherent : familles uniques, version courante lisible, migrations completes' {
    $check = Test-DomeniaContractCatalog
    Assert-True $check.Valid ([string]::Join(' | ',[string[]]$check.Problems))
    Assert-True (@(Get-DomeniaContractCatalog).Count -ge 15)
}

Test-Case 'CTR-002' 'Lecture des formats : barre oblique, ancienne forme pointee, refus des textes non versionnes' {
    $query = ConvertFrom-DomeniaContractFormat 'Domenia.Query/2'
    Assert-Equal 'Domenia.Query' $query.Family; Assert-Equal 2 $query.Version; Assert-Equal '/' $query.Separator
    $support = ConvertFrom-DomeniaContractFormat 'Domenia.Support.1'
    Assert-Equal 'Domenia.Support' $support.Family; Assert-Equal 1 $support.Version; Assert-Equal '.' $support.Separator
    foreach ($bad in @('','Domenia.Query','Domenia.Query/0','Domenia.Query/12345','Domenia.Query/2 ','../Domenia/1','Domenia Query/1','Domenia.Query/-1')) {
        Assert-True ($null -eq (ConvertFrom-DomeniaContractFormat $bad)) ('accepte : ' + $bad)
    }
}

Test-Case 'CTR-003' 'Decision : version courante lue, version 1 migree, version future refusee avec un message explicite' {
    $current = Resolve-DomeniaContractFormat -Format 'Domenia.Query/2' -Family 'Domenia.Query'
    Assert-True $current.Accepted; Assert-Equal 'Lire' $current.Decision; Assert-Equal '' $current.Message
    $old = Resolve-DomeniaContractFormat -Format 'Domenia.Query/1' -Family 'Domenia.Query'
    Assert-True $old.Accepted; Assert-Equal 'Migrer' $old.Decision; Assert-Equal 1 @($old.Steps).Count; Assert-Equal 'Subset' @($old.Steps)[0].Mode
    $future = Resolve-DomeniaContractFormat -Format 'Domenia.QueryPack/2' -Family 'Domenia.QueryPack'
    Assert-False $future.Accepted; Assert-Equal 'PlusRecent' $future.Reason
    Assert-True ($future.Message -like 'Pack de recettes : format Domenia.QueryPack/2 produit par une version plus récente de Domenia ; cette version lit jusquʼà la version 1. Rien nʼest lu ni modifié*') $future.Message
}

Test-Case 'CTR-004' 'Refus : autre famille, famille inconnue, format illisible ; aucun nʼest lu' {
    $other = Resolve-DomeniaContractFormat -Format 'Domenia.QueryLibrary/1' -Family 'Domenia.QueryPack'
    Assert-Equal 'Inattendu' $other.Reason; Assert-False $other.Accepted
    Assert-Equal 'Pack de recettes : format Domenia.QueryLibrary/1 inattendu (Domenia.QueryPack/1 attendu). Rien nʼest lu.' $other.Message
    $dotted = Resolve-DomeniaContractFormat -Format 'Domenia.Capture/1' -Family 'Domenia.Capture'
    Assert-Equal 'Inattendu' $dotted.Reason 'separateur different de celui du contrat'
    $unknown = Resolve-DomeniaContractFormat -Format 'Domenia.Rien/1' -Family 'Domenia.Rien'
    Assert-Equal 'Inconnu' $unknown.Reason
    $unreadable = Resolve-DomeniaContractFormat -Format '' -Family 'Domenia.Query'
    Assert-Equal 'Illisible' $unreadable.Reason
    Assert-Throws { Assert-DomeniaContractFormat -Format 'Domenia.WmiRead/9' -Family 'Domenia.WmiRead' } 'format futur accepte'
    $thrown = ''
    try { [void](Assert-DomeniaContractFormat -Format 'Domenia.Capture.7' -Family 'Domenia.Capture') } catch { $thrown = $_.Exception.Message }
    Assert-True ($thrown -like 'Capture historique : format Domenia.Capture.7 produit par une version plus récente*') $thrown
}

Test-Case 'CTR-005' 'Migration en chaine, version retiree et chaine incomplete' {
    $catalog = @(New-CtrContract -Readable @(1,2,3) -Migrations @((New-CtrStep 1 2),(New-CtrStep 2 3)))
    $chain = Resolve-DomeniaContractFormat -Format 'Domenia.Exemple/1' -Family 'Domenia.Exemple' -Catalog $catalog
    Assert-True $chain.Accepted; Assert-Equal 2 @($chain.Steps).Count
    Assert-Equal '1>2,2>3' ([string]::Join(',',[string[]]@($chain.Steps | ForEach-Object { [string]$_.From + '>' + [string]$_.To })))
    $retired = @(New-CtrContract -Readable @(2,3) -Migrations @((New-CtrStep 2 3)))
    $gone = Resolve-DomeniaContractFormat -Format 'Domenia.Exemple/1' -Family 'Domenia.Exemple' -Catalog $retired
    Assert-Equal 'TropAncien' $gone.Reason; Assert-True ($gone.Message -like '*versions lues : 2, 3*') $gone.Message
    $broken = @(New-CtrContract -Readable @(1,2,3) -Migrations @((New-CtrStep 2 3)))
    $missing = Resolve-DomeniaContractFormat -Format 'Domenia.Exemple/1' -Family 'Domenia.Exemple' -Catalog $broken
    Assert-False $missing.Accepted; Assert-True ($missing.Message -like '*aucune migration déclarée depuis la version 1*') $missing.Message
    Assert-False (Test-DomeniaContractCatalog -Catalog $broken).Valid
}

Test-Case 'CTR-006' 'Le catalogue refuse doublon, version courante illisible, vocabulaire vide et mode de migration inconnu' {
    $bad = @(
        (New-CtrContract -Family 'Domenia.A' -Current 2 -Readable @(1))
        (New-CtrContract -Family 'Domenia.A' -Current 1 -Readable @(1))
        [pscustomobject]@{ Family = 'Domenia.Erreurs'; Label = 'E'; Kind = 'Erreurs'; Separator = '/'; Current = 1; Readable = @(1); Migrations = @(); Values = @(); Owner = 'test' }
        [pscustomobject]@{ Family = 'Domenia.B'; Label = 'B'; Kind = 'Format'; Separator = '/'; Current = 2; Readable = @(1,2); Migrations = @([pscustomobject]@{ From = 1; To = 2; Mode = 'Devine' }); Values = @(); Owner = 'test' }
        [pscustomobject]@{ Family = 'Domenia.C'; Label = 'C'; Kind = 'Capacites'; Separator = '/'; Current = 1; Readable = @(1); Migrations = @(); Values = @('X','X'); Owner = 'test' }
    )
    $all = [string]::Join(' | ',[string[]](Test-DomeniaContractCatalog -Catalog $bad).Problems)
    foreach ($needle in @('Famille en double : Domenia.A','version courante doit être lisible','Domenia.Erreurs : vocabulaire','mode de migration inconnu','Domenia.C : vocabulaire')) { Assert-True ($all -like ('*' + $needle + '*')) ($needle + ' : ' + $all) }
}

Test-Case 'CTR-007' 'Chaque format versionne ecrit par les modules livres est declare et lisible par cette version' {
    $found = @{}
    $pattern = '(?:Format|Schema|Contract)\s*=\s*''(Domenia[A-Za-z0-9.]*[/.][0-9]+)'''
    foreach ($file in @(Get-ChildItem -LiteralPath $modules -Filter '*.ps1' -File)) {
        foreach ($match in [regex]::Matches([IO.File]::ReadAllText($file.FullName,[Text.Encoding]::UTF8),$pattern)) { $found[$match.Groups[1].Value] = $file.Name }
    }
    foreach ($json in @('Domenia-WindowsLifecycle.json','Domenia-Compatibility.json')) {
        $data = [IO.File]::ReadAllText((Join-Path $modules $json),[Text.Encoding]::UTF8) | ConvertFrom-Json
        $value = [string](Get-DomeniaMember $data 'Format' (Get-DomeniaMember $data 'Schema' ''))
        $found[$value] = $json
    }
    Assert-True ($found.Count -ge 12) ('formats trouves : ' + [string]$found.Count)
    foreach ($format in @($found.Keys)) {
        $parsed = ConvertFrom-DomeniaContractFormat $format
        Assert-True ($null -ne $parsed) ('illisible : ' + $format + ' dans ' + $found[$format])
        $resolution = Resolve-DomeniaContractFormat -Format $format -Family $parsed.Family
        Assert-True $resolution.Accepted ($format + ' (' + $found[$format] + ') : ' + $resolution.Message)
    }
}

Test-Case 'CTR-008' 'Vocabulaires fermes : issues des operations et fournisseurs de chaque operation epinglee' {
    foreach ($cancelled in @($false,$true)) { foreach ($timedOut in @($false,$true)) { foreach ($failed in @($false,$true)) {
        foreach ($kind in @('','LogonFailure','AccountLocked','AccountUnavailable','CredentialPaused','AccessDenied','Autre')) {
            $outcome = ConvertTo-DomeniaProviderOutcome -ErrorKind $kind -Cancelled $cancelled -TimedOut $timedOut -Failed $failed
            Assert-True (Test-DomeniaContractValue -Family 'Domenia.ProviderOutcome' -Value $outcome) ('issue non declaree : ' + $outcome)
        }
    } } }
    $operations = [IO.File]::ReadAllText((Join-Path $script:CtrDev 'tools\operation-contracts.json'),[Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-True (@($operations).Count -gt 50)
    foreach ($operation in @($operations)) {
        $provider = Get-DomeniaOperationProvider -OperationId ([string]$operation.Operation)
        Assert-True (Test-DomeniaContractValue -Family 'Domenia.Provider' -Value $provider) ('fournisseur non declare : ' + $provider + ' pour ' + [string]$operation.Operation)
    }
    Assert-False (Test-DomeniaContractValue -Family 'Domenia.Provider' -Value 'directory') 'vocabulaire sensible a la casse'
    Assert-False (Test-DomeniaContractValue -Family 'Domenia.Query' -Value 'Success') 'un format nʼa pas de vocabulaire'
}

Test-Case 'CTR-009' 'Le catalogue est construit une fois par runspace ; un catalogue fourni reste prioritaire' {
    $first = @(Get-DomeniaContractCatalog)
    $second = @(Get-DomeniaContractCatalog)
    Assert-Equal $first.Count $second.Count
    Assert-True ([object]::ReferenceEquals($first[0],$second[0])) 'catalogue reconstruit a chaque appel'
    $query = @($first | Where-Object { $_.Family -ceq 'Domenia.Query' })[0]
    Assert-True ([object]::ReferenceEquals($query,(Get-DomeniaContract 'Domenia.Query'))) 'index different du catalogue'
    Assert-True ($null -eq (Get-DomeniaContract 'domenia.query')) 'famille sensible a la casse'
    Assert-True ($null -eq (Get-DomeniaContract '')) 'famille vide'
    $own = @(New-CtrContract -Family 'Domenia.Query' -Current 3 -Readable @(3))
    Assert-Equal 3 ([int](Get-DomeniaContract -Family 'Domenia.Query' -Catalog $own).Current)
    Assert-Equal 2 ([int](Get-DomeniaContract -Family 'Domenia.Query').Current) 'catalogue fourni retenu par le cache'
}
