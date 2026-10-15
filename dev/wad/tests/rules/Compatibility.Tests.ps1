# Point 145 : matrice de compatibilite livree et verdict du poste. Regles pures, faits fictifs ; la matrice reelle est
# relue depuis wad/modules (lecture seule d un fichier du depot).
. (Join-Path $modules 'Domenia-Compatibility.Model.ps1')
$script:CmpMatrix = [IO.File]::ReadAllText((Join-Path $modules 'Domenia-Compatibility.json'),[Text.Encoding]::UTF8) | ConvertFrom-Json
function New-CmpFacts {
    param([string]$Type = 'Client',[string]$Build = '26200',[string]$Display = '25H2',[string]$Edition = 'Desktop',[string]$Version = '5.1.26100.6584',$Is64 = $true,$Release = 533320,$Sqlite = $true)
    return ConvertTo-DomeniaEnvironmentFacts -InstallationType $Type -CurrentBuild $Build -DisplayVersion $Display -ShellEdition $Edition -ShellVersion $Version -Is64BitProcess $Is64 -NetRelease $Release -SqlitePresent $Sqlite -SqliteVersion '3.43.2'
}
function Get-CmpRow { param($Verdict,[string]$Dimension) return @($Verdict.Rows | Where-Object { $_.Dimension -ceq $Dimension })[0] }

Test-Case 'CMP-001' 'La matrice livree est valide et aucun environnement nʼy est declare qualifie sans rapport lie au ZIP' {
    $check = Test-DomeniaCompatibilityMatrix $script:CmpMatrix
    Assert-True $check.Valid ([string]::Join(' | ',[string[]]$check.Problems))
    foreach ($dimension in @($script:CmpMatrix.Dimensions)) {
        foreach ($entry in @($dimension.Entries)) { Assert-True ([string]$entry.Status -cne 'Qualifie') ('qualifie sans preuve : ' + [string]$entry.Id) }
    }
}

Test-Case 'CMP-002' 'Le poste du labo est teste pour Windows, PowerShell et SQLite, .NET reste prevu faute de releve' {
    $verdict = Get-DomeniaCompatibilityVerdict -Matrix $script:CmpMatrix -Facts (New-CmpFacts)
    Assert-Equal 'Teste' (Get-CmpRow $verdict 'Windows').Status
    Assert-Equal 'Teste' (Get-CmpRow $verdict 'PowerShell').Status
    Assert-Equal 'Teste' (Get-CmpRow $verdict 'Sqlite').Status
    Assert-Equal 'Attendu' (Get-CmpRow $verdict 'DotNet').Status
    Assert-Equal 'Attendu' $verdict.Overall
    Assert-Equal 'Windows 11 25H2 (build 26200)' (Get-CmpRow $verdict 'Windows').Observed
    $text = Get-DomeniaCompatibilityText $verdict
    Assert-True ($text -like 'Compatibilité de ce poste : environnement prévu, jamais testé. .NET Framework : .NET Framework 4.8.1, prévu, jamais testé.*') $text
}

Test-Case 'CMP-003' 'Un fait non lu reste inconnu : jamais compatible par defaut' {
    $facts = ConvertTo-DomeniaEnvironmentFacts
    $verdict = Get-DomeniaCompatibilityVerdict -Matrix $script:CmpMatrix -Facts $facts
    Assert-Equal 4 @($verdict.Rows).Count
    foreach ($row in @($verdict.Rows)) { Assert-Equal 'Inconnu' $row.Status ($row.Dimension); Assert-Equal 'non relevé' $row.Observed }
    Assert-Equal 'Inconnu' $verdict.Overall
    Assert-True ((Get-DomeniaCompatibilityText $verdict) -like '*inconnu*')
    $partial = Get-DomeniaCompatibilityVerdict -Matrix $script:CmpMatrix -Facts (New-CmpFacts -Release $null)
    Assert-Equal 'Inconnu' (Get-CmpRow $partial 'DotNet').Status
    Assert-Equal 'Inconnu' $partial.Overall
}

Test-Case 'CMP-004' 'PowerShell 7, un processus 32 bits ou une version de Windows sans support ne sont pas pris en charge' {
    Assert-Equal 'NonPrisEnCharge' (Get-DomeniaCompatibilityVerdict -Matrix $script:CmpMatrix -Facts (New-CmpFacts -Edition 'Core' -Version '7.4.6')).Overall
    Assert-Equal 'NonPrisEnCharge' (Get-CmpRow (Get-DomeniaCompatibilityVerdict -Matrix $script:CmpMatrix -Facts (New-CmpFacts -Is64 $false)) 'PowerShell').Status
    Assert-Equal 'NonPrisEnCharge' (Get-CmpRow (Get-DomeniaCompatibilityVerdict -Matrix $script:CmpMatrix -Facts (New-CmpFacts -Build '19044' -Display '21H2')) 'Windows').Status
    Assert-Equal 'Attendu' (Get-CmpRow (Get-DomeniaCompatibilityVerdict -Matrix $script:CmpMatrix -Facts (New-CmpFacts -Build '19045' -Display '22H2')) 'Windows').Status
    Assert-Equal 'NonPrisEnCharge' (Get-CmpRow (Get-DomeniaCompatibilityVerdict -Matrix $script:CmpMatrix -Facts (New-CmpFacts -Release 461308)) 'DotNet').Status
    Assert-Equal 'NonPrisEnCharge' (Get-CmpRow (Get-DomeniaCompatibilityVerdict -Matrix $script:CmpMatrix -Facts (New-CmpFacts -Sqlite $false)) 'Sqlite').Status
}

Test-Case 'CMP-005' 'Un Windows absent de la matrice est inconnu, un serveur Core est reconnu comme serveur' {
    $future = Get-DomeniaCompatibilityVerdict -Matrix $script:CmpMatrix -Facts (New-CmpFacts -Build '27000' -Display '')
    $row = Get-CmpRow $future 'Windows'
    Assert-Equal 'Inconnu' $row.Status
    Assert-True ($row.Message -like '*absent de la matrice*') $row.Message
    $server = Get-DomeniaCompatibilityVerdict -Matrix $script:CmpMatrix -Facts (New-CmpFacts -Type 'Server Core' -Build '20348' -Display '')
    Assert-Equal 'Attendu' (Get-CmpRow $server 'Windows').Status
    Assert-Equal 'Windows Server (build 20348)' (Get-CmpRow $server 'Windows').Observed
}

Test-Case 'CMP-006' 'Versions .NET Framework lues depuis la valeur Release' {
    Assert-Equal '4.8.1' (ConvertTo-DomeniaNetFrameworkLabel 533320)
    Assert-Equal '4.8' (ConvertTo-DomeniaNetFrameworkLabel 528372)
    Assert-Equal '4.7.2' (ConvertTo-DomeniaNetFrameworkLabel 461814)
    Assert-Equal '' (ConvertTo-DomeniaNetFrameworkLabel $null)
    Assert-Equal '' (ConvertTo-DomeniaNetFrameworkLabel 'abc')
    Assert-Equal '' (ConvertTo-DomeniaNetFrameworkLabel 1000)
}

Test-Case 'CMP-007' 'Conditions : vide, inconnue, bornes de version et de build' {
    $facts = [pscustomobject]@{ Product = 'Client'; Build = 26200; Edition = 'Desktop'; Version = [version]'5.1.26100.6584'; Bitness = 64; Release = $null; Present = $null }
    Assert-Equal 'NoMatch' (Test-DomeniaCompatibilityMatch ([pscustomobject]@{}) $facts)
    Assert-Equal 'Match' (Test-DomeniaCompatibilityMatch ([pscustomobject]@{ Product = 'Client'; MinBuild = 26200; MaxBuild = 26299 }) $facts)
    Assert-Equal 'NoMatch' (Test-DomeniaCompatibilityMatch ([pscustomobject]@{ Product = 'Server'; MinBuild = 0 }) $facts)
    Assert-Equal 'Unknown' (Test-DomeniaCompatibilityMatch ([pscustomobject]@{ MinRelease = 461808 }) $facts)
    Assert-Equal 'Match' (Test-DomeniaCompatibilityMatch ([pscustomobject]@{ Edition = 'Desktop'; MinVersion = '5.1'; MaxVersion = '5.1.65535.65535' }) $facts)
    Assert-Equal 'NoMatch' (Test-DomeniaCompatibilityMatch ([pscustomobject]@{ MinVersion = '7.0' }) $facts)
    Assert-Equal 'NoMatch' (Test-DomeniaCompatibilityMatch ([pscustomobject]@{ Inattendu = 1 }) $facts)
}

Test-Case 'CMP-008' 'La validation refuse un qualifie sans rapport lie, un teste sans reference, un statut inconnu et un doublon' {
    $matrix = [pscustomobject]@{ Schema = 'DomeniaCompatibilityMatrix/1'; ReviewedOn = '2026-10-15'; Dimensions = @(
        [pscustomobject]@{ Id = 'Sqlite'; Label = 'SQLite'; Observed = $true; Entries = @(
            [pscustomobject]@{ Id = 'a'; Label = 'A'; Match = [pscustomobject]@{ Present = $true }; Status = 'Qualifie'; Evidence = @([pscustomobject]@{ Kind = 'Rapport'; Ref = 'x.json' }) }
            [pscustomobject]@{ Id = 'b'; Label = 'B'; Match = [pscustomobject]@{ Present = $false }; Status = 'Teste'; Evidence = @() }
            [pscustomobject]@{ Id = 'b'; Label = 'B2'; Match = [pscustomobject]@{ Present = $false }; Status = 'Teste'; Evidence = @() }
            [pscustomobject]@{ Id = 'c'; Label = 'C'; Match = [pscustomobject]@{}; Status = 'Peut-etre'; Evidence = @() }
        ) }
    ) }
    $check = Test-DomeniaCompatibilityMatrix $matrix
    Assert-False $check.Valid
    $all = [string]::Join(' | ',[string[]]$check.Problems)
    foreach ($needle in @('Qualifie exige','Teste exige','en double','statut inconnu','sans condition')) { Assert-True ($all -like ('*' + $needle + '*')) ($needle + ' : ' + $all) }
    $verdict = Get-DomeniaCompatibilityVerdict -Matrix $matrix -Facts (New-CmpFacts)
    Assert-False $verdict.MatrixValid
    Assert-Equal 'Inconnu' $verdict.Overall
    Assert-True ((Get-DomeniaCompatibilityText $verdict) -like '*matrice de compatibilité absente ou illisible*')
    Assert-False (Test-DomeniaCompatibilityMatrix $null).Valid
    Assert-Equal 'Compatibilité de ce poste : non évaluée.' (Get-DomeniaCompatibilityText $null)
}

Test-Case 'CMP-009' 'Qualifie nʼest donne que si chaque dimension observee est qualifiee par un rapport lie au ZIP' {
    $sha = 'A' * 64
    $matrix = [pscustomobject]@{ Schema = 'DomeniaCompatibilityMatrix/1'; ReviewedOn = '2026-10-15'; Dimensions = @(
        [pscustomobject]@{ Id = 'Sqlite'; Label = 'SQLite'; Observed = $true; Entries = @([pscustomobject]@{ Id = 'p'; Label = 'Present'; Match = [pscustomobject]@{ Present = $true }; Status = 'Qualifie'; Evidence = @([pscustomobject]@{ Kind = 'Qualification'; Ref = 'qualification-report.json'; ArchiveSha256 = $sha }) }) }
        [pscustomobject]@{ Id = 'PowerShell'; Label = 'PowerShell'; Observed = $true; Entries = @([pscustomobject]@{ Id = 'd'; Label = 'Desktop'; Match = [pscustomobject]@{ Edition = 'Desktop' }; Status = 'Qualifie'; Evidence = @([pscustomobject]@{ Kind = 'Qualification'; Ref = 'qualification-report.json'; ArchiveSha256 = $sha }) }) }
        [pscustomobject]@{ Id = 'Directory'; Label = 'Annuaire'; Observed = $false; Entries = @([pscustomobject]@{ Id = 'x'; Label = 'Labo'; Match = [pscustomobject]@{}; Status = 'Attendu'; Evidence = @() }) }
    ) }
    $verdict = Get-DomeniaCompatibilityVerdict -Matrix $matrix -Facts (New-CmpFacts)
    Assert-True $verdict.MatrixValid
    Assert-Equal 2 @($verdict.Rows).Count 'une dimension documentaire nʼest jamais evaluee sur le poste'
    Assert-Equal 'Qualifie' $verdict.Overall
    Assert-Equal 'Compatibilité de ce poste : environnement qualifié.' (Get-DomeniaCompatibilityText $verdict)
}

Test-Case 'CMP-010' 'Une matrice dʼune version plus recente est refusee avec sa version, par le catalogue des contrats' {
    $future = [pscustomobject]@{ Schema = 'DomeniaCompatibilityMatrix/2'; ReviewedOn = '2027-01-01'; Dimensions = @($script:CmpMatrix.Dimensions) }
    $check = Test-DomeniaCompatibilityMatrix $future
    Assert-False $check.Valid
    $all = [string]::Join(' | ',[string[]]$check.Problems)
    Assert-True ($all -like '*Matrice de compatibilité : format DomeniaCompatibilityMatrix/2 produit par une version plus récente de Domenia*') $all
    $other = Test-DomeniaCompatibilityMatrix ([pscustomobject]@{ Schema = 'DomeniaWindowsLifecycle/1'; Dimensions = @($script:CmpMatrix.Dimensions) })
    Assert-True ([string]::Join(' | ',[string[]]$other.Problems) -like '*inattendu (DomeniaCompatibilityMatrix/1 attendu)*')
    Assert-Equal 'Inconnu' (Get-DomeniaCompatibilityVerdict -Matrix $future -Facts (New-CmpFacts)).Overall
}
