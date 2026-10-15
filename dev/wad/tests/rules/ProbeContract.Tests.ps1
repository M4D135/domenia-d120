# Points 135 et 136 : contrat de sonde Domenia.ProbeContract/1 et isolement des sondes avancées. Regles pures :
# le catalogue entier doit satisfaire son contrat, les tests attendus de chaque sonde sont executes ici, et une sonde
# personnalisee qui ne declare pas son comportement est refusee. Aucun reseau, aucune base, aucun WPF.
. (Join-Path $modules 'Domenia-Probes.Model.ps1')
. (Join-Path $modules 'Domenia-ProbeContract.Model.ps1')
$script:DomeniaProbeCatalog = $null
$script:DomeniaProbeContracts = $null

function New-PctCustomProbe {
    # A complete custom declaration; each test removes or alters one part of it.
    return [pscustomobject]@{
        Id='custom.enclosure';Name='Boitier declare';Category='Test';Namespace='root\cimv2';Class='Win32_SystemEnclosure'
        Properties=@('ChassisTypes','SMBIOSAssetTag');Filter='';Mode='All';Transform='Text';Visual='Bar';Slow=$true;SkipOnDc=$true;Origin='Personnalisée'
        Fields=@([pscustomobject]@{Name='ChassisTypes';CimType='uint16[]';Kind='Number';IsArray=$true;Unit='';Description='Types de boitier'},[pscustomobject]@{Name='SMBIOSAssetTag';CimType='string';Kind='Text';IsArray=$false;Unit='';Description='Etiquette'})
        Rights='Lecture WMI distante du poste.';Limitations='Valeurs declarees par le firmware.';UnknownMeaning='Absence ou refus : inconnu, jamais zero.'
        SourceUrls=@('https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-systemenclosure')
        Behavior=[pscustomobject]@{Reads='CIM';Writes=$false;Code='Aucun';Methods=@();Target='Poste choisi ou liste affichee'}
        Privilege=[pscustomobject]@{Level='LectureDistanteWmi';Text='Administrateur du poste ou delegation WMI.'}
        Cost=[pscustomobject]@{Level='Lourd';Reason='Classe peu connue : collecte explicite.'}
    }
}
function Copy-PctProbe {
    param($Probe)
    return ($Probe | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
}
function Get-PctFixtureCells {
    # Plausible raw cells for the transform of one probe (what the collector stores for one instance).
    param($Probe)
    $transform = [string]$Probe.Transform
    if ($transform -match '^(GB|GBfromKB|MB|Mbps|Number)$') { return @('1073741824') }
    if ($transform -match '^(DaysSince|Year)$') { return @('2026-10-01T00:00:00Z') }
    if ($transform -eq 'PercentFree') { return @('50','100') }
    if ($transform -eq 'Release') { return @('19045','1') }
    if ($transform -like 'Map:*') { return @($transform.Substring(4).Split(';')[0].Split('=')[0]) }
    return @('Valeur')
}
function New-PctResult {
    param([object[]]$Rows=@(),[int]$Count=0,[string]$Failure='',[string]$Skipped='',[bool]$Truncated=$false)
    $result = [pscustomobject]@{Rows=$Rows;Count=$Count;Error=$Failure;Truncated=$Truncated;CheckedUtc='2026-10-15T08:00:00.0000000Z'}
    if ($Skipped) { Add-Member -InputObject $result -MemberType NoteProperty -Name 'Skipped' -Value $Skipped }
    return $result
}
function Invoke-PctExpectedTest {
    # Runs one expected test of the contract on the real projection rule. Returns '' when it passes, else the reason.
    param($Probe,[string]$TestId)
    $cells = @(Get-PctFixtureCells $Probe)
    $rows = @(,$cells)
    switch ($TestId) {
        'Projection' {
            $result = if ([string]$Probe.Mode -eq 'Count') { New-PctResult -Count 3 } else { New-PctResult -Rows $rows -Count 1 }
            if (@(Get-DomeniaProbeValues -Probe $Probe -Result $result).Count -lt 1) { return 'aucune valeur projetee' }
        }
        'Inconnu' {
            if ([string]$Probe.Mode -ne 'Count') { if (@(Get-DomeniaProbeValues -Probe $Probe -Result (New-PctResult)).Count) { return 'valeur fabriquee sans ligne' } }
            if (@(Get-DomeniaProbeValues -Probe $Probe -Result (New-PctResult -Count 0 -Failure 'Delai depasse.')).Count) { return 'valeur fabriquee sur erreur' }
        }
        'Refus' { if (@(Get-DomeniaProbeValues -Probe $Probe -Result (New-PctResult -Rows $rows -Count 1 -Failure 'Acces refuse.')).Count) { return 'poste compte malgre un refus' } }
        'Troncature' { if (@(Get-DomeniaProbeValues -Probe $Probe -Result (New-PctResult -Rows $rows -Count 1 -Truncated $true)).Count) { return 'lecture tronquee presentee comme complete' } }
        'Controleur' { if (@(Get-DomeniaProbeValues -Probe $Probe -Result (New-PctResult -Rows $rows -Count 1 -Skipped 'DomainController')).Count) { return 'controleur compte' } }
        'Fenetre' {
            $live = [IO.File]::ReadAllText((Join-Path $modules 'Domenia-Live.Model.ps1'))
            if ((-not $live.Contains("'{SINCE_24H}'=")) -or (-not $live.Contains("'{SINCE_7D}'="))) { return 'jeton de fenetre non remplace par le collecteur' }
        }
        'Correspondance' {
            # A count outside the table (97) or a raw value outside the table is kept as read.
            $expected = 'valeur-hors-table'
            $result = New-PctResult -Rows @(,@($expected)) -Count 1
            if ([string]$Probe.Mode -eq 'Count') { $expected = '97'; $result = New-PctResult -Count 97 }
            $values = @(Get-DomeniaProbeValues -Probe $Probe -Result $result)
            if (($values.Count -ne 1) -or ([string]$values[0] -cne $expected)) { return 'valeur hors table inventee ou perdue' }
        }
        default { return ('test attendu sans execution : ' + $TestId) }
    }
    return ''
}

Test-Case 'PCT-001' 'Point 135 : chaque sonde du catalogue satisfait Domenia.ProbeContract/1' {
    $catalog = @(Get-DomeniaProbeCatalog)
    $gate = Test-DomeniaProbeCatalogContracts -Catalog $catalog
    Assert-True ($gate.Checked -ge 90) ('catalogue trop court : ' + $gate.Checked)
    Assert-True $gate.Valid ('contrats refuses : ' + (@($gate.Refused | ForEach-Object { $_.Id + ' (' + (@($_.Errors) -join ' ') + ')' }) -join ' ; '))
    foreach ($probe in $catalog) {
        $contract = ConvertTo-DomeniaProbeContract $probe
        Assert-Equal 'Domenia.ProbeContract/1' $contract.Schema
        Assert-True (@($contract.Types).Count -ge @($contract.Inputs.Properties).Count) ('types manquants : ' + $probe.Id)
        Assert-True ([string]$contract.Privilege.Text) ('privileges : ' + $probe.Id)
        Assert-True ([string]$contract.Cost.Level -in @('Léger','Modéré','Lourd')) ('cout : ' + $probe.Id)
        Assert-False ([bool]$contract.Behavior.Writes) ('ecriture : ' + $probe.Id)
        Assert-Equal 'Aucun' ([string]$contract.Behavior.Code) ('code : ' + $probe.Id)
    }
    Assert-Equal 'Catalogue détaillé' (ConvertTo-DomeniaProbeContract (Get-DomeniaProbe 'hw.memorymodules')).Origin
    Assert-Equal 'Intégrée' (ConvertTo-DomeniaProbeContract (Get-DomeniaProbe 'hw.maker')).Origin
    Assert-Equal 'Lourd' (ConvertTo-DomeniaProbeContract (Get-DomeniaProbe 'evt.syserrors')).Cost.Level
    Assert-Equal 'AdministrateurLocal' (ConvertTo-DomeniaProbeContract (Get-DomeniaProbe 'sec.bitlocker')).Privilege.Level
}
Test-Case 'PCT-002' 'Point 135 : les tests attendus de chaque sonde sont executes sur la regle de projection' {
    $failures = New-Object 'System.Collections.Generic.List[string]'
    foreach ($probe in @(Get-DomeniaProbeCatalog)) {
        $contract = ConvertTo-DomeniaProbeContract $probe
        foreach ($test in @($contract.ExpectedTests)) {
            $why = Invoke-PctExpectedTest -Probe $probe -TestId ([string]$test.Id)
            if ($why) { $failures.Add([string]$probe.Id + '/' + [string]$test.Id + ' : ' + $why) }
        }
    }
    Assert-Equal 0 $failures.Count ($failures.ToArray() -join ' ; ')
    $dc = ConvertTo-DomeniaProbeContract (Get-DomeniaProbe 'sec.localusers')
    Assert-True (@($dc.ExpectedTests | Where-Object { $_.Id -eq 'Controleur' }).Count -eq 1) 'test controleur absent pour une sonde NoDC'
    $window = ConvertTo-DomeniaProbeContract (Get-DomeniaProbe 'evt.unexpected')
    Assert-True (@($window.ExpectedTests | Where-Object { $_.Id -eq 'Fenetre' }).Count -eq 1) 'test de fenetre absent'
}
Test-Case 'PCT-003' 'Point 135 : les limites du contrat sont celles du collecteur' {
    $limits = Get-DomeniaProbeExecutionLimits
    $live = [IO.File]::ReadAllText((Join-Path $modules 'Domenia-Live.Model.ps1'))
    $park = [IO.File]::ReadAllText((Join-Path $modules 'Domenia-Park.UI.ps1'))
    # String.Contains, not -like: the brackets of [Math] would be read as a wildcard class.
    Assert-True ($live.Contains('$details.Count -ge ' + $limits.MaxDetailInstances)) 'nombre de details different du collecteur'
    Assert-True ($live.Contains('$detailBytes+$bytes -gt ' + $limits.MaxDetailBytes)) 'budget de details different du collecteur'
    Assert-True ($live.Contains('OperationTimeoutSec=[Math]::Max(' + $limits.MinQueryTimeoutSeconds + ',$timeout)')) 'delai de requete different du collecteur'
    Assert-True ($park.Contains('[Math]::Min(' + $limits.TaskMaxSeconds + ',' + $limits.TaskBaseSeconds + '+' + $limits.TaskSecondsPerProbe + '*')) 'delai de tache different du parc'
}
Test-Case 'PCT-004' 'Point 136 : une sonde personnalisee declare comportement, privileges et cout' {
    $custom = New-PctCustomProbe
    Assert-DomeniaCustomProbeDeclaration $custom
    $check = Test-DomeniaProbeContract (ConvertTo-DomeniaProbeContract $custom)
    Assert-True $check.Valid ('declaration complete refusee : ' + (@($check.Errors) -join ' '))
    $missing = Copy-PctProbe $custom; $missing.PSObject.Properties.Remove('Behavior')
    Assert-Throws { Assert-DomeniaCustomProbeDeclaration $missing } 'comportement absent accepte par le catalogue'
    $c = Test-DomeniaProbeContract (ConvertTo-DomeniaProbeContract $missing)
    Assert-True (@($c.Errors | Where-Object { $_ -match 'comportement à déclarer' }).Count -eq 1) 'comportement non exige par le contrat'
    $noPrivilege = Copy-PctProbe $custom; $noPrivilege.PSObject.Properties.Remove('Privilege')
    Assert-Throws { Assert-DomeniaCustomProbeDeclaration $noPrivilege } 'privileges absents acceptes'
    Assert-False (Test-DomeniaProbeContract (ConvertTo-DomeniaProbeContract $noPrivilege)).Valid 'privileges derives pour une sonde personnalisee'
    $writes = Copy-PctProbe $custom; $writes.Behavior.Writes = $true
    Assert-Throws { Assert-DomeniaCustomProbeDeclaration $writes } 'ecriture acceptee'
    Assert-False (Test-DomeniaProbeContract (ConvertTo-DomeniaProbeContract $writes)).Valid 'ecriture admise par le contrat'
    $script = Copy-PctProbe $custom; $script.Behavior.Code = 'Get-Process'
    Assert-Throws { Assert-DomeniaCustomProbeDeclaration $script } 'code accepte'
    $method = Copy-PctProbe $custom; $method.Behavior.Methods = @('Terminate')
    Assert-Throws { Assert-DomeniaCustomProbeDeclaration $method } 'methode WMI acceptee'
    $fast = Copy-PctProbe $custom; $fast.Slow = $false
    Assert-Throws { Assert-DomeniaCustomProbeDeclaration $fast } 'sonde personnalisee sans collecte explicite'
    $dc = Copy-PctProbe $custom; $dc.SkipOnDc = $false
    Assert-Throws { Assert-DomeniaCustomProbeDeclaration $dc } 'sonde personnalisee sur controleur'
    $origin = Copy-PctProbe $custom; $origin.Origin = 'Libre'
    Assert-Throws { Assert-DomeniaCustomProbeDeclaration $origin } 'origine inconnue acceptee'
    $plain = Copy-PctProbe $custom; $plain.PSObject.Properties.Remove('Origin')
    Assert-DomeniaCustomProbeDeclaration $plain
}
Test-Case 'PCT-005' 'Point 136 : entrees refusees par le contrat' {
    $custom = New-PctCustomProbe
    $cases = @(
        @{Name='Namespace';Value='root\subscription';Expect='Espace de noms refusé'},
        @{Name='Class';Value='Win32_Product';Expect='Classe refusée'},
        @{Name='Filter';Value='Name=1; DROP';Expect='caractère non admis'},
        @{Name='Filter';Value="TimeGenerated>='{NOW}'";Expect='Jeton de filtre inconnu'},
        @{Name='Mode';Value='Each';Expect='Mode de projection invalide'}
    )
    foreach ($case in $cases) {
        $probe = Copy-PctProbe $custom; $probe.($case.Name) = $case.Value
        $check = Test-DomeniaProbeContract (ConvertTo-DomeniaProbeContract $probe)
        Assert-True (@($check.Errors | Where-Object { $_ -match [regex]::Escape($case.Expect) }).Count -ge 1) ($case.Name + ' : ' + (@($check.Errors) -join ' '))
    }
    $accounts = Copy-PctProbe $custom; $accounts.Origin = 'Catalogue détaillé'; $accounts.Class = 'Win32_UserAccount'; $accounts.SkipOnDc = $false
    Assert-True (@((Test-DomeniaProbeContract (ConvertTo-DomeniaProbeContract $accounts)).Errors | Where-Object { $_ -match 'comptes locaux' }).Count -eq 1) 'enumeration du domaine admise'
    $heavy = Copy-PctProbe $custom; $heavy.Slow = $false
    Assert-True (@((Test-DomeniaProbeContract (ConvertTo-DomeniaProbeContract $heavy)).Errors | Where-Object { $_ -match 'Coût lourd sans collecte explicite' }).Count -eq 1) 'cout lourd sans collecte explicite'
    $untyped = Copy-PctProbe $custom; $untyped.Properties = @('ChassisTypes','SMBIOSAssetTag','SerialNumber')
    Assert-True (@((Test-DomeniaProbeContract (ConvertTo-DomeniaProbeContract $untyped)).Errors | Where-Object { $_ -match 'sans type déclaré' }).Count -eq 1) 'propriete non typee admise'
    $noSource = Copy-PctProbe $custom; $noSource.SourceUrls = @()
    Assert-False (Test-DomeniaProbeContract (ConvertTo-DomeniaProbeContract $noSource)).Valid 'source primaire non exigee'
}
Test-Case 'PCT-006' 'Point 136 : isolement decrit sans promettre de bac a sable' {
    $contract = ConvertTo-DomeniaProbeContract (New-PctCustomProbe)
    foreach ($enabled in @($false,$true)) {
        $plan = Get-DomeniaProbeIsolationPlan -Contract $contract -IsolatedReadsEnabled $enabled
        Assert-Equal 'Moteur' $plan.Mode 'la collecte LiveConsole n est pas retenue pour le processus auxiliaire'
        Assert-True (@($plan.NotGuaranteed | Where-Object { $_ -match 'Aucun bac à sable PowerShell' }).Count -eq 1) 'limite du confinement non dite'
        Assert-True (@($plan.NotGuaranteed | Where-Object { $_ -match 'fournisseur WMI du poste' }).Count -eq 1) 'comportement du fournisseur distant non dit'
        Assert-True (@($plan.Guarantees | Where-Object { $_ -match 'Contrôleurs de domaine exclus' }).Count -eq 1) 'exclusion des controleurs non dite'
        Assert-False ($plan.Text -match '(?i)sandbox|confinement garanti') 'promesse de confinement'
    }
    $summary = Get-DomeniaProbeContractSummary $contract
    Assert-True (($summary -match 'collecte explicite seulement') -and ($summary -match 'aucune écriture')) $summary
    $lines = @(Get-DomeniaProbeContractLines -Contract $contract -Check (Test-DomeniaProbeContract $contract) -Isolation (Get-DomeniaProbeIsolationPlan -Contract $contract))
    foreach ($section in @('Entrées','Types','Privilèges','Coût','Limites','Sources','Tests attendus','Isolement')) {
        Assert-True (@($lines | Where-Object { $_.Section -ceq $section }).Count -eq 1) ('section absente : ' + $section)
    }
}
