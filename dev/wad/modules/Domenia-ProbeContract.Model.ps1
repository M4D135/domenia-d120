# Points 135 and 136: the contract every probe of the catalogue satisfies (Domenia.ProbeContract/1).
# Pure rules: no WPF, no network, no disk. Self-contained on purpose (no common helper needed), so a rules test or a
# tool can load it alone. The catalogue loader keeps its own check of custom entries (Assert-DomeniaCustomProbeDeclaration).
# A probe is data, never code: inputs (CIM namespace, class, properties, filter, mode), typed fields, privileges,
# cost, limits, documentary sources, the tests it must pass and its declared behaviour. A probe of origin
# "Personnalisée" must declare its behaviour, privileges, cost and tests itself; nothing is derived for it.

function Get-DomeniaProbeContractValue {
    # Strict-mode safe member read limited to this module (PSCustomObject or hashtable).
    param($InputObject,[string]$Name,$Default=$null)
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [Collections.IDictionary]) {
        # IDictionary.Contains is explicit on generic dictionaries and throws under Windows PowerShell 5.1.
        $present = $false
        try { $present = [bool]$InputObject.Contains($Name) } catch { try { $present = [bool]$InputObject.ContainsKey($Name) } catch { $present = $false } }
        if ($present) { return $InputObject[$Name] }
        return $Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-DomeniaProbeExecutionLimits {
    # Budgets actually applied by the LiveConsole collector (Domenia-Live.Model.ps1, Park.UI): a rules test checks that
    # these figures are the ones of the worker body. They are limits, not measures.
    return [pscustomobject]@{
        MaxDetailInstances=2000
        MaxDetailBytes=262144
        MinQueryTimeoutSeconds=10
        TaskBaseSeconds=20
        TaskSecondsPerProbe=8
        TaskMaxSeconds=150
        MaxProperties=64
        MaxFilterLength=512
        MaxCatalogProbes=256
    }
}

function Get-DomeniaProbeDeniedClasses {
    # Classes that act or walk far more than one workstation when read: never accepted in a probe.
    # Win32_Product triggers MSI consistency checks; the account and group classes enumerate the domain on a controller
    # unless restricted to local accounts (see Test-DomeniaProbeContract).
    return @('Win32_Product','CIM_Product','Win32_SoftwareFeature','Win32_SoftwareElement','Win32_ReliabilityRecords')
}

function Get-DomeniaProbeDeniedNamespaces {
    # Namespaces whose reading is an action or leaves the workstation: event subscriptions, directory, policy results.
    return @('root\subscription','root\directory\LDAP','root\RSOP','root\RSOP\Computer','root\RSOP\User','root\default','root\security')
}

function Get-DomeniaProbePrivilege {
    # Privilege needed on the target, from the declaration when present, otherwise from the namespace.
    param($Probe)
    $declared = Get-DomeniaProbeContractValue $Probe 'Privilege' $null
    $rights = [string](Get-DomeniaProbeContractValue $Probe 'Rights' '')
    if ($null -ne $declared) {
        return [pscustomobject]@{Level=[string](Get-DomeniaProbeContractValue $declared 'Level' '');Text=[string](Get-DomeniaProbeContractValue $declared 'Text' $rights);Declared=$true}
    }
    $namespace = [string](Get-DomeniaProbeContractValue $Probe 'Namespace' '')
    $class = [string](Get-DomeniaProbeContractValue $Probe 'Class' '')
    $local = (($namespace -match '(?i)^root\\cimv2\\Security\\') -or ($namespace -match '(?i)^root\\SecurityCenter2$') -or ($class -in @('Win32_EncryptableVolume','Win32_Tpm')))
    if ($local) {
        $text = 'Administrateur local du poste : ce fournisseur refuse les autres comptes, même délégués sur lʼespace de noms.'
        if ($rights) { $text = $rights + ' ' + $text }
        return [pscustomobject]@{Level='AdministrateurLocal';Text=$text;Declared=$false}
    }
    $text = 'Administrateur du poste, ou compte délégué « Activer à distance » sur lʼespace de noms et autorisé en DCOM ou WinRM.'
    if ($rights) { $text = $rights + ' ' + $text }
    return [pscustomobject]@{Level='LectureDistanteWmi';Text=$text;Declared=$false}
}

function Get-DomeniaProbeCost {
    # Cost class of one probe. The collector always enumerates the full stream of the class (to count it), so the class
    # and its filter decide the cost, not the projection mode. "Lourd" requires an explicit collection (Slow flag).
    param($Probe)
    $declared = Get-DomeniaProbeContractValue $Probe 'Cost' $null
    $limits = Get-DomeniaProbeExecutionLimits
    $slow = [bool](Get-DomeniaProbeContractValue $Probe 'Slow' $false)
    if ($null -ne $declared) {
        return [pscustomobject]@{Level=[string](Get-DomeniaProbeContractValue $declared 'Level' '');Reason=[string](Get-DomeniaProbeContractValue $declared 'Reason' '');Slow=$slow;MaxDetailInstances=$limits.MaxDetailInstances;MaxDetailBytes=$limits.MaxDetailBytes;Declared=$true}
    }
    $class = [string](Get-DomeniaProbeContractValue $Probe 'Class' '')
    $mode = [string](Get-DomeniaProbeContractValue $Probe 'Mode' '')
    $filter = [string](Get-DomeniaProbeContractValue $Probe 'Filter' '')
    $single = @('Win32_ComputerSystem','Win32_OperatingSystem','Win32_BIOS','Win32_TimeZone','MSFT_MpComputerStatus','Win32_Tpm','Win32_DeviceGuard','Win32_PhysicalMemoryArray')
    if ($slow) { $level = 'Lourd'; $reason = 'Requête signalée lente : journal, liste volumineuse ou fournisseur coûteux. Collecte explicite sur une liste courte.' }
    elseif ($class -in $single) { $level = 'Léger'; $reason = 'Classe à instance unique ou très courte.' }
    elseif ($filter) { $level = 'Modéré'; $reason = 'Énumère les instances filtrées de la classe.' }
    elseif ($mode -eq 'First') { $level = 'Modéré'; $reason = 'Énumère la classe pour en retenir la première instance.' }
    else { $level = 'Modéré'; $reason = 'Énumère toutes les instances de la classe.' }
    return [pscustomobject]@{Level=$level;Reason=$reason;Slow=$slow;MaxDetailInstances=$limits.MaxDetailInstances;MaxDetailBytes=$limits.MaxDetailBytes;Declared=$false}
}

function Get-DomeniaProbeExpectedTests {
    # Tests every probe must pass, from its characteristics. Rules tests run them generically on the whole catalogue
    # (ProbeContract.Tests.ps1, PCT-002); a declared list may add tests but never removes a required one.
    param($Probe)
    $tests = New-Object 'System.Collections.Generic.List[object]'
    $tests.Add([pscustomobject]@{Id='Projection';Text='Une ligne lue produit la valeur transformée attendue.'})
    $tests.Add([pscustomobject]@{Id='Inconnu';Text='Erreur, refus ou absence de ligne : aucune valeur, jamais zéro.'})
    $tests.Add([pscustomobject]@{Id='Refus';Text='Accès refusé : erreur conservée, poste non compté.'})
    if ([string](Get-DomeniaProbeContractValue $Probe 'Mode' '') -ne 'Count') { $tests.Add([pscustomobject]@{Id='Troncature';Text='Lecture tronquée : aucune valeur partielle présentée comme complète.'}) }
    if ([bool](Get-DomeniaProbeContractValue $Probe 'SkipOnDc' $false)) { $tests.Add([pscustomobject]@{Id='Controleur';Text='Contrôleur de domaine : lecture ignorée et signalée, jamais comptée.'}) }
    if ([string](Get-DomeniaProbeContractValue $Probe 'Filter' '') -match '\{SINCE_') { $tests.Add([pscustomobject]@{Id='Fenetre';Text='Fenêtre temporelle remplacée par le collecteur avant lʼappel.'}) }
    if ([string](Get-DomeniaProbeContractValue $Probe 'Transform' '') -like 'Map:*') { $tests.Add([pscustomobject]@{Id='Correspondance';Text='Valeur absente de la table conservée brute, jamais inventée.'}) }
    foreach ($extra in @(Get-DomeniaProbeContractValue $Probe 'ExpectedTests' @())) {
        $id = [string](Get-DomeniaProbeContractValue $extra 'Id' '')
        if (($id) -and (-not @($tests | Where-Object { $_.Id -ceq $id }).Count)) { $tests.Add([pscustomobject]@{Id=$id;Text=[string](Get-DomeniaProbeContractValue $extra 'Text' '')}) }
    }
    return $tests.ToArray()
}

function Get-DomeniaProbeBehavior {
    # Declared behaviour of a probe. Built-in and detailed probes are read-only CIM projections by construction; a
    # custom probe must declare the same block and the contract refuses anything else (point 136).
    param($Probe)
    $declared = Get-DomeniaProbeContractValue $Probe 'Behavior' $null
    if ($null -ne $declared) {
        return [pscustomobject]@{
            Reads=[string](Get-DomeniaProbeContractValue $declared 'Reads' '')
            Writes=(Get-DomeniaProbeContractValue $declared 'Writes' $null)
            Code=[string](Get-DomeniaProbeContractValue $declared 'Code' '')
            Methods=@(Get-DomeniaProbeContractValue $declared 'Methods' @())
            Target=[string](Get-DomeniaProbeContractValue $declared 'Target' '')
            Declared=$true
        }
    }
    return [pscustomobject]@{Reads='CIM';Writes=$false;Code='Aucun';Methods=@();Target='Poste choisi ou liste affichée';Declared=$false}
}

function ConvertTo-DomeniaProbeContract {
    # Normalised contract of one catalogue probe. Origin: Intégrée (historical table of Domenia-Probes.Model.ps1),
    # Catalogue détaillé (Domenia-ProbeCatalog.json) or Personnalisée (an entry of that file flagged Origin).
    param($Probe)
    if ($null -eq $Probe) { return $null }
    $origin = [string](Get-DomeniaProbeContractValue $Probe 'Origin' '')
    if (-not $origin) {
        $origin = 'Intégrée'
        if ($null -ne (Get-Command -Name 'Get-DomeniaExtendedProbeCatalog' -CommandType Function -ErrorAction SilentlyContinue)) {
            $id = [string](Get-DomeniaProbeContractValue $Probe 'Id' '')
            if (@(Get-DomeniaExtendedProbeCatalog | Where-Object { [string]$_.Id -ceq $id }).Count) { $origin = 'Catalogue détaillé' }
        }
    }
    $fields = New-Object 'System.Collections.Generic.List[object]'
    foreach ($field in @(Get-DomeniaProbeContractValue $Probe 'Fields' @())) {
        if ($null -eq $field) { continue }
        $fields.Add([pscustomobject]@{Name=[string](Get-DomeniaProbeContractValue $field 'Name' '');CimType=[string](Get-DomeniaProbeContractValue $field 'CimType' '');Kind=[string](Get-DomeniaProbeContractValue $field 'Kind' '');Unit=[string](Get-DomeniaProbeContractValue $field 'Unit' '')})
    }
    $filter = [string](Get-DomeniaProbeContractValue $Probe 'Filter' '')
    $tokens = @([regex]::Matches($filter,'\{[^}]*\}') | ForEach-Object { $_.Value })
    return [pscustomobject]@{
        Schema='Domenia.ProbeContract/1'
        Id=[string](Get-DomeniaProbeContractValue $Probe 'Id' '')
        Name=[string](Get-DomeniaProbeContractValue $Probe 'Name' '')
        Origin=$origin
        Inputs=[pscustomobject]@{Provider='CIM';Namespace=[string](Get-DomeniaProbeContractValue $Probe 'Namespace' '');Class=[string](Get-DomeniaProbeContractValue $Probe 'Class' '');Properties=@(Get-DomeniaProbeContractValue $Probe 'Properties' @() | ForEach-Object { [string]$_ });Filter=$filter;Mode=[string](Get-DomeniaProbeContractValue $Probe 'Mode' '');Tokens=$tokens;SkipOnDc=[bool](Get-DomeniaProbeContractValue $Probe 'SkipOnDc' $false)}
        Types=$fields.ToArray()
        Privilege=(Get-DomeniaProbePrivilege $Probe)
        Cost=(Get-DomeniaProbeCost $Probe)
        Limits=[pscustomobject]@{Text=[string](Get-DomeniaProbeContractValue $Probe 'Limitations' '');UnknownMeaning=[string](Get-DomeniaProbeContractValue $Probe 'UnknownMeaning' '');Execution=(Get-DomeniaProbeExecutionLimits)}
        Sources=@(Get-DomeniaProbeContractValue $Probe 'SourceUrls' @() | ForEach-Object { [string]$_ })
        Qualification=[string](Get-DomeniaProbeContractValue $Probe 'ProviderQualification' 'À qualifier sous Windows')
        ExpectedTests=@(Get-DomeniaProbeExpectedTests $Probe)
        Behavior=(Get-DomeniaProbeBehavior $Probe)
    }
}

function Test-DomeniaProbeContract {
    # Errors refuse the probe; warnings are shown, never hidden. Every check is about the declaration, nothing is read.
    param($Contract)
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $Contract) { return [pscustomobject]@{Valid=$false;Errors=@('Contrat absent.');Warnings=@()} }
    $limits = Get-DomeniaProbeExecutionLimits
    $id = [string]$Contract.Id
    if ([string]$Contract.Schema -cne 'Domenia.ProbeContract/1') { $errors.Add('Schéma de contrat non reconnu.') }
    if ($id -cnotmatch '^[a-z][a-z0-9_.-]{1,127}$') { $errors.Add('Identifiant de sonde invalide.') }
    if ([string]$Contract.Origin -cnotin @('Intégrée','Catalogue détaillé','Personnalisée')) { $errors.Add('Origine de sonde inconnue.') }
    $in = $Contract.Inputs
    if ([string]$in.Provider -cne 'CIM') { $errors.Add('Seules les lectures CIM sont admises.') }
    if ([string]$in.Namespace -notmatch '^[A-Za-z0-9_\\]+$') { $errors.Add('Espace de noms invalide.') }
    elseif (@(Get-DomeniaProbeDeniedNamespaces | Where-Object { $_ -ieq [string]$in.Namespace }).Count) { $errors.Add('Espace de noms refusé : ' + [string]$in.Namespace + '.') }
    if ([string]$in.Class -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { $errors.Add('Classe invalide.') }
    elseif (@(Get-DomeniaProbeDeniedClasses | Where-Object { $_ -ieq [string]$in.Class }).Count) { $errors.Add('Classe refusée : ' + [string]$in.Class + '.') }
    if (([string]$in.Class -in @('Win32_UserAccount','Win32_Group','Win32_GroupUser')) -and (-not [bool]$in.SkipOnDc) -and ([string]$in.Filter -notmatch '(?i)LocalAccount\s*=\s*TRUE')) { $errors.Add('Comptes et groupes : lecture limitée aux comptes locaux ou exclue des contrôleurs requise.') }
    if ([string]$in.Mode -cnotin @('First','All','Count')) { $errors.Add('Mode de projection invalide.') }
    $properties = @($in.Properties)
    if (($properties.Count -lt 1) -or ($properties.Count -gt $limits.MaxProperties)) { $errors.Add('Nombre de propriétés hors limites (1 à ' + $limits.MaxProperties + ').') }
    foreach ($name in $properties) { if ([string]$name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { $errors.Add('Propriété invalide : ' + [string]$name + '.') } }
    $filter = [string]$in.Filter
    if ($filter.Length -gt $limits.MaxFilterLength) { $errors.Add('Filtre trop long.') }
    # % is the wildcard of a WQL LIKE pattern (point 87: names that hint at a docking station); it has no other meaning.
    if ($filter -notmatch '^[A-Za-z0-9_ =''<>().:{}%\-]*$') { $errors.Add('Filtre : caractère non admis.') }
    foreach ($token in @($in.Tokens)) { if ([string]$token -cnotin @('{SINCE_24H}','{SINCE_7D}')) { $errors.Add('Jeton de filtre inconnu : ' + [string]$token + '.') } }
    $kinds = @{}
    foreach ($field in @($Contract.Types)) {
        if ([string]$field.Kind -cnotin @('Text','Number','Boolean','Timestamp')) { $errors.Add('Type de champ invalide : ' + [string]$field.Name + '.') }
        $kinds[[string]$field.Name] = $field
        if (-not [string]$field.CimType) { $warnings.Add('Type CIM de ' + [string]$field.Name + ' à qualifier : valeur gardée en texte.') }
    }
    foreach ($name in $properties) { if (-not $kinds.ContainsKey([string]$name)) { $errors.Add('Propriété sans type déclaré : ' + [string]$name + '.') } }
    if ([string]$Contract.Privilege.Level -cnotin @('LectureDistanteWmi','AdministrateurLocal')) { $errors.Add('Niveau de privilège inconnu.') }
    if (-not [string]$Contract.Privilege.Text) { $errors.Add('Privilèges non décrits.') }
    if ([string]$Contract.Cost.Level -cnotin @('Léger','Modéré','Lourd')) { $errors.Add('Coût inconnu.') }
    if (([string]$Contract.Cost.Level -ceq 'Lourd') -and (-not [bool]$Contract.Cost.Slow)) { $errors.Add('Coût lourd sans collecte explicite (indicateur Slow).') }
    if (-not [string]$Contract.Limits.Text) { $errors.Add('Limites non décrites.') }
    if (-not [string]$Contract.Limits.UnknownMeaning) { $errors.Add('Sens dʼun résultat inconnu non décrit.') }
    $sources = @($Contract.Sources)
    foreach ($url in $sources) { if ([string]$url -notmatch '^https://(learn\.microsoft\.com/|github\.com/(microsoft|MicrosoftDocs)/)') { $errors.Add('Référence documentaire non autorisée.') } }
    if (-not $sources.Count) {
        if ([string]$Contract.Origin -ceq 'Intégrée') { $warnings.Add('Aucune référence documentaire propre : documentation de la classe à rattacher.') }
        else { $errors.Add('Référence documentaire primaire requise.') }
    }
    $testIds = @($Contract.ExpectedTests | ForEach-Object { [string]$_.Id })
    foreach ($required in @('Projection','Inconnu','Refus')) { if ($testIds -cnotcontains $required) { $errors.Add('Test attendu manquant : ' + $required + '.') } }
    if (([string]$in.Mode -ne 'Count') -and ($testIds -cnotcontains 'Troncature')) { $errors.Add('Test attendu manquant : Troncature.') }
    $behavior = $Contract.Behavior
    if ([string]$behavior.Reads -cne 'CIM') { $errors.Add('Comportement : seule la lecture CIM est admise.') }
    if (($behavior.Writes -isnot [bool]) -or ([bool]$behavior.Writes)) { $errors.Add('Comportement : une sonde nʼécrit jamais.') }
    if ([string]$behavior.Code -cne 'Aucun') { $errors.Add('Comportement : aucun script ni commande ne peut accompagner une sonde.') }
    if (@($behavior.Methods).Count) { $errors.Add('Comportement : aucune méthode WMI nʼest appelée par une sonde.') }
    if ([string]$Contract.Origin -ceq 'Personnalisée') {
        # Point 136: nothing is derived for a custom probe; it runs only on an explicit collection, never on a controller.
        if (-not [bool]$behavior.Declared) { $errors.Add('Sonde personnalisée : comportement à déclarer (Behavior).') }
        if (-not [bool]$Contract.Privilege.Declared) { $errors.Add('Sonde personnalisée : privilèges à déclarer (Privilege).') }
        if (-not [bool]$Contract.Cost.Declared) { $errors.Add('Sonde personnalisée : coût à déclarer (Cost).') }
        if (-not [bool]$in.SkipOnDc) { $errors.Add('Sonde personnalisée : exclusion des contrôleurs de domaine requise (SkipOnDc).') }
        if (-not [bool]$Contract.Cost.Slow) { $errors.Add('Sonde personnalisée : collecte explicite requise (Slow).') }
        if (-not [string]$behavior.Target) { $errors.Add('Sonde personnalisée : cible à déclarer.') }
    }
    return [pscustomobject]@{Valid=($errors.Count -eq 0);Errors=$errors.ToArray();Warnings=$warnings.ToArray()}
}

function Get-DomeniaProbeIsolationPlan {
    # Point 136: what isolates a probe today, and what does not. No PowerShell sandbox is promised: the protection is
    # that a probe carries no code. The decision for the collector comes from the reviewed engine rule (D016).
    param($Contract,[bool]$IsolatedReadsEnabled=$false,[bool]$ExplicitCredential=$false)
    $decision = $null
    $decisionCommand = Get-Command -Name 'Get-DomeniaIsolationDecision' -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $decisionCommand) { $decision = Get-DomeniaIsolationDecision -OperationId 'LiveConsole' -Enabled $IsolatedReadsEnabled -HasCredential $ExplicitCredential -PayloadDigest 'probe-contract' }
    $helper = (($null -ne $decision) -and ([bool]$decision.Isolate))
    $limits = Get-DomeniaProbeExecutionLimits
    $guarantees = New-Object 'System.Collections.Generic.List[string]'
    $guarantees.Add('Aucun code fourni par la sonde : le collecteur construit une lecture SELECT à partir de noms validés.')
    $guarantees.Add('Aucune écriture : aucune méthode WMI nʼest appelée, aucune valeur nʼest modifiée sur le poste.')
    $guarantees.Add('Lecture hors du fil dʼinterface, avec délai de requête dʼau moins ' + $limits.MinQueryTimeoutSeconds + ' s et délai de tâche plafonné à ' + $limits.TaskMaxSeconds + ' s.')
    $guarantees.Add('Détails bornés à ' + $limits.MaxDetailInstances + ' instances et ' + [int]($limits.MaxDetailBytes / 1024) + ' Kio ; une limite atteinte est signalée.')
    if ([bool]$Contract.Inputs.SkipOnDc) { $guarantees.Add('Contrôleurs de domaine exclus : le type de système est lu avant la requête.') }
    $notGuaranteed = New-Object 'System.Collections.Generic.List[string]'
    $notGuaranteed.Add('Le fournisseur WMI du poste exécute la requête avec les droits du compte utilisé ; Domenia ne contrôle pas son comportement côté poste.')
    $notGuaranteed.Add('Aucun bac à sable PowerShell : la protection repose sur lʼabsence de code dans la définition, pas sur un confinement.')
    if ($helper) { $mode = 'ProcessusAuxiliaire'; $notGuaranteed.Add('Le processus auxiliaire peut être arrêté au délai ; le poste peut terminer la requête de son côté.') }
    else {
        $mode = 'Moteur'
        $why = 'décision moteur indisponible'
        if ($null -ne $decision) { $why = [string]$decision.Reason }
        $notGuaranteed.Add('Pas de processus auxiliaire pour cette collecte (' + $why.TrimEnd('.') + ') : un fournisseur bloqué retient sa tâche jusquʼau délai.')
    }
    $text = 'Isolement : ' + $(if ($helper) { 'processus auxiliaire borné' } else { 'moteur de Domenia, hors interface' }) + '. ' + ($guarantees.ToArray() -join ' ') + ' Non garanti : ' + ($notGuaranteed.ToArray() -join ' ')
    return [pscustomobject]@{Mode=$mode;Guarantees=$guarantees.ToArray();NotGuaranteed=$notGuaranteed.ToArray();Text=$text}
}

function Get-DomeniaProbeContractSummary {
    # One line for the widget editor and the probe details: rights, cost and behaviour, in that order.
    param($Contract)
    if ($null -eq $Contract) { return 'Contrat de sonde indisponible.' }
    $level = switch ([string]$Contract.Privilege.Level) { 'AdministrateurLocal' { 'administrateur local du poste' } default { 'lecture WMI distante (administrateur ou délégation)' } }
    $text = 'Droits : ' + $level + '. Coût : ' + [string]$Contract.Cost.Level + ' — ' + [string]$Contract.Cost.Reason
    $text += ' Lecture déclarative : aucune écriture, aucun code.'
    if ([string]$Contract.Origin -ceq 'Personnalisée') { $text += ' Sonde personnalisée : collecte explicite seulement.' }
    return $text
}

function Get-DomeniaProbeContractLines {
    # Detailed contract for the probe details page: one entry per section of Domenia.ProbeContract/1.
    param($Contract,$Check=$null,$Isolation=$null)
    if ($null -eq $Contract) { return @() }
    $lines = New-Object 'System.Collections.Generic.List[object]'
    $in = $Contract.Inputs
    $lines.Add([pscustomobject]@{Section='Origine';Valeur=[string]$Contract.Origin})
    $lines.Add([pscustomobject]@{Section='Entrées';Valeur=([string]$in.Namespace + ' · ' + [string]$in.Class + ' · ' + (@($in.Properties) -join ', ') + $(if ([string]$in.Filter) { ' · filtre ' + [string]$in.Filter } else { '' }) + ' · mode ' + [string]$in.Mode)})
    $typed = @($Contract.Types | ForEach-Object { [string]$_.Name + ' (' + $(if ([string]$_.CimType) { [string]$_.CimType } else { 'à qualifier' }) + $(if ([string]$_.Unit) { ', ' + [string]$_.Unit } else { '' }) + ')' })
    $lines.Add([pscustomobject]@{Section='Types';Valeur=($typed -join ' · ')})
    $lines.Add([pscustomobject]@{Section='Privilèges';Valeur=[string]$Contract.Privilege.Text})
    $lines.Add([pscustomobject]@{Section='Coût';Valeur=([string]$Contract.Cost.Level + ' : ' + [string]$Contract.Cost.Reason)})
    $lines.Add([pscustomobject]@{Section='Limites';Valeur=([string]$Contract.Limits.Text + ' Inconnu : ' + [string]$Contract.Limits.UnknownMeaning)})
    $lines.Add([pscustomobject]@{Section='Sources';Valeur=$(if (@($Contract.Sources).Count) { @($Contract.Sources) -join ' · ' } else { 'Aucune référence propre à cette sonde.' })})
    $lines.Add([pscustomobject]@{Section='Qualification';Valeur=[string]$Contract.Qualification})
    $lines.Add([pscustomobject]@{Section='Tests attendus';Valeur=(@($Contract.ExpectedTests | ForEach-Object { [string]$_.Id + ' : ' + [string]$_.Text }) -join ' · ')})
    if ($null -ne $Isolation) { $lines.Add([pscustomobject]@{Section='Isolement';Valeur=[string]$Isolation.Text}) }
    if ($null -ne $Check) {
        foreach ($warning in @($Check.Warnings)) { $lines.Add([pscustomobject]@{Section='Avertissement';Valeur=[string]$warning}) }
        foreach ($problem in @($Check.Errors)) { $lines.Add([pscustomobject]@{Section='Refus';Valeur=[string]$problem}) }
    }
    return $lines.ToArray()
}

function Get-DomeniaProbeContract {
    # Contract and check of one catalogue probe, built once per process: the catalogue is fixed for a session.
    param([string]$Id)
    $cache = Get-Variable -Name DomeniaProbeContracts -Scope Script -ErrorAction SilentlyContinue
    if (($null -eq $cache) -or ($null -eq $cache.Value)) { $script:DomeniaProbeContracts = @{} }
    if ($script:DomeniaProbeContracts.ContainsKey($Id)) { return $script:DomeniaProbeContracts[$Id] }
    $probe = Get-DomeniaProbe $Id
    if ($null -eq $probe) { return $null }
    $contract = ConvertTo-DomeniaProbeContract $probe
    $entry = [pscustomobject]@{Contract=$contract;Check=(Test-DomeniaProbeContract $contract)}
    $script:DomeniaProbeContracts[$Id] = $entry
    return $entry
}

function Test-DomeniaProbeCatalogContracts {
    # Whole-catalogue gate used by the rules tests and the widget editor: every probe must satisfy its contract.
    param([object[]]$Catalog=@())
    $refused = New-Object 'System.Collections.Generic.List[object]'
    $warnings = 0
    foreach ($probe in @($Catalog)) {
        if ($null -eq $probe) { continue }
        $check = Test-DomeniaProbeContract (ConvertTo-DomeniaProbeContract $probe)
        $warnings += @($check.Warnings).Count
        if (-not $check.Valid) { $refused.Add([pscustomobject]@{Id=[string](Get-DomeniaProbeContractValue $probe 'Id' '');Errors=@($check.Errors)}) }
    }
    return [pscustomobject]@{Valid=($refused.Count -eq 0);Checked=@($Catalog).Count;Refused=$refused.ToArray();Warnings=$warnings}
}
