# Releves de la liste de Rechercher (lot X01) : regles pures de Domenia-Park.Model, sans reseau, base ni WPF.
# Donnees fictives uniquement (domaine example.test).
. (Join-Path $modules 'Domenia-Live.Model.ps1')
. (Join-Path $modules 'Domenia-Park.Model.ps1')

Test-Case 'P-SE-05' 'Plafond : au-dela de 500 postes, racine sans filtre et recherche globale sans terme refuses' {
    $over = Test-DomeniaParkTargetAdmission -Count 501 -Maximum 500 -ScopeDn 'OU=Postes,DC=example,DC=test' -BaseDn 'DC=example,DC=test'
    Assert-False $over.Allowed '501 postes admis'
    Assert-Equal 'Ceiling' ([string]$over.Code)
    Assert-Equal '501 postes affichés : plafond 500. Filtrez la liste.' ([string]$over.Reason)
    Assert-True (Test-DomeniaParkTargetAdmission -Count 500 -Maximum 500 -ScopeDn 'OU=Postes,DC=example,DC=test' -BaseDn 'DC=example,DC=test').Allowed '500 postes refuses'
    Assert-True (Test-DomeniaParkTargetAdmission -Count 48 -ScopeDn 'OU=Postes,DC=example,DC=test' -BaseDn 'DC=example,DC=test').Allowed '48 postes dans une OU refuses'
    $root = Test-DomeniaParkTargetAdmission -Count 48 -ScopeDn 'dc=example,dc=test' -BaseDn 'DC=example,DC=test'
    Assert-False $root.Allowed 'racine du domaine sans filtre admise'
    Assert-Equal 'DomainRoot' ([string]$root.Code)
    Assert-True ([string]$root.Reason -like '*aucun relevé de tout le domaine*') ([string]$root.Reason)
    Assert-True (Test-DomeniaParkTargetAdmission -Count 48 -ScopeDn 'DC=example,DC=test' -BaseDn 'DC=example,DC=test' -HasFilter $true).Allowed 'racine filtree refusee'
    $global = Test-DomeniaParkTargetAdmission -Count 12 -BaseDn 'DC=example,DC=test' -Global $true
    Assert-False $global.Allowed 'recherche globale sans terme admise'
    Assert-Equal 'GlobalWithoutTerm' ([string]$global.Code)
    Assert-True (Test-DomeniaParkTargetAdmission -Count 12 -BaseDn 'DC=example,DC=test' -Global $true -HasSearchTerm $true -HasFilter $true).Allowed 'recherche globale avec terme refusee'
    $empty = Test-DomeniaParkTargetAdmission -Count 0 -ScopeDn 'OU=Postes,DC=example,DC=test' -BaseDn 'DC=example,DC=test'
    Assert-False $empty.Allowed 'liste vide admise'
    Assert-Equal 'Aucun poste dans les résultats affichés.' ([string]$empty.Reason)
}
Test-Case 'P-SE-05' 'Plafond : une selection est son propre filtre, sous le meme plafond ; reglage borne' {
    $selection = Test-DomeniaParkTargetAdmission -Count 501 -Maximum 500 -Selection $true
    Assert-False $selection.Allowed '501 postes selectionnes admis'
    Assert-Equal '501 postes sélectionnés : plafond 500. Réduisez la sélection.' ([string]$selection.Reason)
    Assert-True (Test-DomeniaParkTargetAdmission -Count 3 -ScopeDn 'DC=example,DC=test' -BaseDn 'DC=example,DC=test' -Selection $true).Allowed 'choix de lignes a la racine refuse'
    Assert-True (Test-DomeniaParkTargetAdmission -Count 3 -Global $true -Selection $true).Allowed 'choix de lignes d une recherche globale refuse'
    Assert-Equal 'Aucun poste dans la sélection.' ([string](Test-DomeniaParkTargetAdmission -Count 0 -Selection $true).Reason)
    Assert-Equal 500 ([int](Test-DomeniaParkTargetAdmission -Count 1 -Maximum 0 -Selection $true).Maximum) 'reglage absent ou nul'
    Assert-Equal 5000 ([int](Test-DomeniaParkTargetAdmission -Count 1 -Maximum 99999 -Selection $true).Maximum) 'reglage plafonne'
    Assert-False (Test-DomeniaParkTargetAdmission -Count 120 -Maximum 100 -Selection $true).Allowed 'plafond regle ignore'
}
Test-Case 'P-SE-05' 'Plafond : toute la liste selectionnee (Ctrl+A) suit les regles de la liste, jamais un releve deguise du domaine' {
    $root = Test-DomeniaParkTargetAdmission -Count 480 -ScopeDn 'dc=example,dc=test' -BaseDn 'DC=example,DC=test' -Selection $true -SelectionCoversList $true
    Assert-False $root.Allowed 'racine sans filtre admise par Ctrl+A'
    Assert-Equal 'DomainRoot' ([string]$root.Code)
    Assert-True ([string]$root.Reason -like ('Toute la liste est s' + [char]0x00E9 + 'lectionn' + [char]0x00E9 + 'e. *aucun relev' + [char]0x00E9 + ' de tout le domaine*')) ([string]$root.Reason)
    $global = Test-DomeniaParkTargetAdmission -Count 12 -BaseDn 'DC=example,DC=test' -Global $true -Selection $true -SelectionCoversList $true
    Assert-False $global.Allowed 'recherche globale sans terme admise par Ctrl+A'
    Assert-Equal 'GlobalWithoutTerm' ([string]$global.Code)
    Assert-True (Test-DomeniaParkTargetAdmission -Count 48 -ScopeDn 'DC=example,DC=test' -BaseDn 'DC=example,DC=test' -HasFilter $true -Selection $true -SelectionCoversList $true).Allowed 'racine filtree entierement selectionnee refusee'
    Assert-True (Test-DomeniaParkTargetAdmission -Count 48 -ScopeDn 'OU=Postes,DC=example,DC=test' -BaseDn 'DC=example,DC=test' -Selection $true -SelectionCoversList $true).Allowed 'OU entierement selectionnee refusee'
    Assert-True (Test-DomeniaParkTargetAdmission -Count 12 -BaseDn 'DC=example,DC=test' -Global $true -HasSearchTerm $true -Selection $true -SelectionCoversList $true).Allowed 'recherche avec terme entierement selectionnee refusee'
    $over = Test-DomeniaParkTargetAdmission -Count 501 -Maximum 500 -ScopeDn 'OU=Postes,DC=example,DC=test' -BaseDn 'DC=example,DC=test' -Selection $true -SelectionCoversList $true
    Assert-Equal 'Ceiling' ([string]$over.Code)
    Assert-Equal ('501 postes s' + [char]0x00E9 + 'lectionn' + [char]0x00E9 + 's : plafond 500. R' + [char]0x00E9 + 'duisez la s' + [char]0x00E9 + 'lection.') ([string]$over.Reason)
}
Test-Case 'P-MO-08' 'Delai du ping de liste : derive des attentes du worker par lot de 32, borne a 30 minutes' {
    Assert-Equal 62 (Get-DomeniaParkPingTimeoutSeconds -Count 200) '200 postes : 7 lots de 6 s plus 20 s'
    Assert-Equal 26 (Get-DomeniaParkPingTimeoutSeconds -Count 1) 'un poste'
    Assert-Equal 20 (Get-DomeniaParkPingTimeoutSeconds -Count 0) 'aucun poste'
    Assert-Equal 962 (Get-DomeniaParkPingTimeoutSeconds -Count 5000) '5000 postes : au-dela du pire cas de 157 lots'
    Assert-True ((Get-DomeniaParkPingTimeoutSeconds -Count 5000) -gt (157 * 4.5)) 'budget inferieur aux attentes du worker'
    Assert-Equal 76 (Get-DomeniaParkPingTimeoutSeconds -Count 200 -TimeoutMs 3000) 'delai dʼecho de 3 s'
    Assert-Equal 76 (Get-DomeniaParkPingTimeoutSeconds -Count 200 -TimeoutMs 99999) 'delai dʼecho borne comme le worker'
    Assert-Equal 1800 (Get-DomeniaParkPingTimeoutSeconds -Count 100000) 'borne de 30 minutes'
    Assert-Equal 38 (Get-DomeniaParkPingTimeoutSeconds -Count 3 -BatchSize 0) 'lot borne a un echo, comme le worker'
}
Test-Case 'P-CO-19' 'Compteurs : en ligne, sans reponse et erreur distincts ; une erreur DNS nʼest jamais un poste muet' {
    Assert-Equal 'Online' (Get-DomeniaParkOutcomeKind 'En ligne')
    Assert-Equal 'NoReply' (Get-DomeniaParkOutcomeKind 'Sans réponse au ping')
    Assert-Equal 'NoReply' (Get-DomeniaParkOutcomeKind 'Hors ligne') 'ancienne valeur enregistree'
    # ParkPing writes 'Erreur de ping' for a name that cannot be resolved (detail 'Résolution DNS impossible').
    Assert-Equal 'Error' (Get-DomeniaParkOutcomeKind 'Erreur de ping')
    Assert-Equal 'Error' (Get-DomeniaParkOutcomeKind 'Error') 'cle deja normalisee'
    Assert-Equal 'Error' (Get-DomeniaParkOutcomeKind '') 'aucune mesure apres un ping demande'
    Assert-Equal 'Error' (Get-DomeniaParkOutcomeKind 'Non vérifié') 'aucune mesure apres un ping demande'
    Assert-Equal '' (Get-DomeniaParkOutcomeKind 'En ligne' -PingRequested $false) 'releve WMI seul compte comme un echo'
}
Test-Case 'P-UX-12' 'Avancement court : 12/48 · 9 joignables en cours, trois compteurs a la fin, accents et pluriels' {
    Assert-Equal '12/48 · 9 joignables' (Get-DomeniaParkProgressText -Done 12 -Total 48 -Online 9)
    Assert-Equal '1/48 · 1 joignable' (Get-DomeniaParkProgressText -Done 1 -Total 48 -Online 1)
    Assert-Equal '48/48 · 30 en ligne · 15 sans réponse · 3 erreurs' (Get-DomeniaParkProgressText -Done 48 -Total 48 -Online 30 -NoReply 15 -Errors 3 -Completed $true)
    Assert-Equal '2/2 · 1 en ligne · 0 sans réponse · 1 erreur' (Get-DomeniaParkProgressText -Done 2 -Total 2 -Online 1 -Errors 1 -Completed $true)
    Assert-Equal 'Arrêté à 20/48 · 12 en ligne · 6 sans réponse · 2 erreurs' (Get-DomeniaParkProgressText -Done 20 -Total 48 -Online 12 -NoReply 6 -Errors 2 -Completed $true -Stopped $true)
    Assert-Equal '5/10 postes lus' (Get-DomeniaParkProgressText -Done 5 -Total 10 -PingRequested $false)
    Assert-Equal '1/10 poste lu' (Get-DomeniaParkProgressText -Done 1 -Total 10 -PingRequested $false)
    $partial = Get-DomeniaParkProgressText -Done 40 -Total 48 -Online 40 -Completed $true -Failed 1 -Unchecked 8
    Assert-True ($partial.EndsWith(' · 1 lecture non confirmée · 8 postes non vérifiés')) $partial
}
Test-Case 'P-UX-24' 'Confirmation : trois lignes, ecart explique, cible lisible, bouton chiffre, sans jargon' {
    $ping = New-DomeniaParkConfirmationText -Count 48 -Skipped 3 -ScopeLabel 'OU Postes' -Subtree $true -PingOnly $true
    Assert-Equal 3 @($ping.Lines).Count
    Assert-Equal '48 postes affichés (OU Postes, sous-OU) · 3 lignes sans identifiant AD ignorées' ([string]$ping.Lines[0])
    Assert-Equal 'Ce qui sera lu : présence, en lecture seule.' ([string]$ping.Lines[1])
    Assert-Equal 'Durée estimée : moins dʼune minute, échos envoyés par lots de 32 ; arrêt possible à tout moment.' ([string]$ping.Lines[2])
    Assert-Equal 'Pinger 48 postes' ([string]$ping.ConfirmText)
    Assert-Equal 'OU Postes' ([string]$ping.Target) 'la cible est la liste, jamais le domaine'
    Assert-Equal 'Vérifier la liste : qui répond ?' ([string]$ping.Title)
    Assert-False ([string]$ping.Message -match 'CIM|DCOM|ICMP|example\.test') ([string]$ping.Message)
    Assert-Equal (([string]$ping.Lines[0]) + "`r`n" + ([string]$ping.Lines[1]) + "`r`n" + ([string]$ping.Lines[2])) ([string]$ping.Message)
    $console = New-DomeniaParkConfirmationText -Count 48 -ScopeLabel 'OU Postes' -Concurrency 4 -CacheMinutes 15
    Assert-Equal '48 postes affichés (OU Postes)' ([string]$console.Lines[0])
    Assert-Equal 'Ce qui sera lu : présence · utilisateur connecté, en lecture seule.' ([string]$console.Lines[1])
    Assert-Equal 'Durée estimée : moins dʼune minute, 4 postes à la fois ; arrêt possible à tout moment. Mesures de moins de 15 min réutilisées.' ([string]$console.Lines[2])
    Assert-Equal 'Vérifier 48 postes' ([string]$console.ConfirmText)
    $analyse = New-DomeniaParkConfirmationText -Count 48 -Ignored 2 -Inventory $true -ProbeCount 3 -ScopeLabel 'recherche « PC »'
    Assert-Equal '48 postes affichés (recherche « PC ») · 2 postes au nom inutilisable ou en double ignorés' ([string]$analyse.Lines[0])
    Assert-Equal 'Ce qui sera lu : présence · utilisateur connecté · matériel · 3 requêtes des widgets, en lecture seule.' ([string]$analyse.Lines[1])
    Assert-True ([string]$analyse.Lines[2] -like 'Durée estimée : environ 3 min, 4 postes à la fois*') ([string]$analyse.Lines[2])
    Assert-Equal 'Analyser 48 postes' ([string]$analyse.ConfirmText)
    Assert-Equal 'Vérifier la liste : matériel et widgets' ([string]$analyse.Title)
}
Test-Case 'P-UX-24' 'Confirmation : selection, perimetre, liste tronquee, un seul poste et lecture WMI seule' {
    $selection = New-DomeniaParkConfirmationText -Count 3 -ScopeKind Selection -PingOnly $true
    Assert-Equal '3 postes sélectionnés' ([string]$selection.Lines[0])
    Assert-Equal 'la sélection' ([string]$selection.Target)
    Assert-Equal 'Vérifier la sélection : qui répond ?' ([string]$selection.Title)
    Assert-Equal 'Pinger 3 postes' ([string]$selection.ConfirmText)
    $scope = New-DomeniaParkConfirmationText -Count 12 -ScopeKind Scope -ScopeLabel 'OU=Postes,DC=example,DC=test et ses sous-OU' -Inventory $true
    Assert-Equal '12 postes de OU=Postes,DC=example,DC=test et ses sous-OU' ([string]$scope.Lines[0])
    Assert-Equal 'OU=Postes,DC=example,DC=test et ses sous-OU' ([string]$scope.Target)
    $limited = New-DomeniaParkConfirmationText -Count 100 -ScopeLabel 'OU Postes' -ListLimit 100 -PingOnly $true
    Assert-True ([string]$limited.Lines[0]).EndsWith(' · liste limitée à 100 lignes : les autres postes ne sont pas concernés') ([string]$limited.Lines[0])
    $one = New-DomeniaParkConfirmationText -Count 1 -PingOnly $true
    Assert-Equal '1 poste affiché' ([string]$one.Lines[0])
    Assert-Equal 'Pinger 1 poste' ([string]$one.ConfirmText)
    Assert-Equal 'les résultats affichés' ([string]$one.Target)
    $wmi = New-DomeniaParkConfirmationText -Count 5 -ScopeKind Scope -WmiOnly $true -Inventory $true -CacheMinutes 0
    Assert-Equal 'Ce qui sera lu : utilisateur connecté · matériel, en lecture seule.' ([string]$wmi.Lines[1])
    Assert-False ([string]$wmi.Lines[2] -like '*réutilisées*') 'relecture forcee annoncee comme reutilisee'
}
Test-Case 'P-UX-24' 'Confirmation : profil de collecte, requetes WMI regroupees et budget par sous-reseau dans les trois lignes' {
    $console = New-DomeniaParkConfirmationText -Count 48 -ScopeLabel 'OU Postes' -Concurrency 4 -CacheMinutes 15 -Inventory $true -ProfileLabel 'Réseau lent ou site distant' -CimRequested 4 -CimExecuted 3 -SourceBudgets $true
    Assert-Equal 3 @($console.Lines).Count
    Assert-Equal 'Ce qui sera lu : présence · utilisateur connecté · matériel, en lecture seule. Requêtes WMI prévues par poste : 3 au lieu de 4 grâce au regroupement.' ([string]$console.Lines[1])
    Assert-True ([string]$console.Lines[2]).EndsWith(' ; arrêt possible à tout moment. Les postes dʼun même sous-réseau présumé partagent un budget qui ralentit si leurs réponses tardent ; les autres continuent. Un incident transitoire est relu au plus deux fois, espacé ; aucun nouvel essai après un refus dʼidentifiants. Réutilisation des mesures encore fraîches selon le profil « Réseau lent ou site distant », au plus 15 min.') ([string]$console.Lines[2])
    $ping = New-DomeniaParkConfirmationText -Count 48 -PingOnly $true -ProfileLabel 'Standard' -CimRequested 4 -CimExecuted 3 -SourceBudgets $true
    Assert-Equal 'Ce qui sera lu : présence, en lecture seule.' ([string]$ping.Lines[1]) 'aucune requete WMI annoncee pour un ping'
    Assert-Equal 'Durée estimée : moins dʼune minute, échos envoyés par lots de 32 ; arrêt possible à tout moment. Les postes dʼun même sous-réseau présumé partagent un budget qui ralentit si leurs réponses tardent ; les autres continuent.' ([string]$ping.Lines[2]) 'un ping nʼest jamais relu ni reutilise'
    $none = New-DomeniaParkConfirmationText -Count 2 -ScopeKind Scope -ScopeLabel 'PC-1' -CimRequested 2 -CimExecuted 2 -ProfileLabel 'Standard' -CacheMinutes 0
    Assert-Equal 'Ce qui sera lu : présence · utilisateur connecté, en lecture seule.' ([string]$none.Lines[1]) 'rien evite : aucune mention du regroupement'
    Assert-False ([string]$none.Lines[2] -like '*réutilis*') 'relecture forcee annoncee comme reutilisee'
    $widget = New-DomeniaParkConfirmationText -Count 3 -ScopeKind Scope -ScopeLabel 'Postes' -WmiOnly $true -NoConsole $true -ProbeCount 1 -Widget $true -ReuseMaxAgeDays 30 -ProfileLabel 'Standard' -SourceBudgets $true
    Assert-True ([string]$widget.Lines[2]).EndsWith(' Seules les mesures absentes, en erreur ou de plus de 30 jours sont relues.') ([string]$widget.Lines[2])
}
Test-Case 'P-UX-24' 'Duree estimee : echos par lots de 32, lectures quatre par quatre, libelles en francais' {
    Assert-Equal 14 (Get-DomeniaParkDurationEstimate -Count 200 -PingOnly $true)
    Assert-Equal 500 (Get-DomeniaParkDurationEstimate -Count 500 -Concurrency 4)
    Assert-Equal 0 (Get-DomeniaParkDurationEstimate -Count 0)
    Assert-Equal 'moins dʼune minute' (Format-DomeniaParkDuration 59)
    Assert-Equal 'environ 9 min' (Format-DomeniaParkDuration 500)
    Assert-Equal 'environ 1,5 h' (Format-DomeniaParkDuration 5400)
}
Test-Case 'P-FI-18' 'Un releve par portee : le poste ouvert a la sienne, la liste et les perimetres partagent la leur' {
    $open = 'CN=PC-7,OU=Postes,DC=example,DC=test'
    $target = [pscustomobject]@{ name = 'PC-7'; distinguished_name = 'cn=pc-7,ou=postes,dc=example,dc=test'; object_guid = '0f8fad5b-d9cb-469f-a165-70867728950e' }
    $other = [pscustomobject]@{ name = 'PC-8'; distinguished_name = 'CN=PC-8,OU=Postes,DC=example,DC=test'; object_guid = '1f8fad5b-d9cb-469f-a165-70867728950e' }
    Assert-Equal 'Computer' (Get-DomeniaParkRunSlot -Targets @($target) -OpenComputerDn $open) 'requetes du poste ouvert'
    Assert-Equal 'List' (Get-DomeniaParkRunSlot -Targets @($other) -OpenComputerDn $open) 'autre poste'
    Assert-Equal 'List' (Get-DomeniaParkRunSlot -Targets @($target,$other) -OpenComputerDn $open) 'perimetre de plusieurs postes'
    Assert-Equal 'List' (Get-DomeniaParkRunSlot -DisplayedResults $true -Targets @($target) -OpenComputerDn $open) 'selection de la liste'
    Assert-Equal 'List' (Get-DomeniaParkRunSlot -Targets @($target)) 'aucun poste ouvert'
    Assert-Equal 'Computer' (Get-DomeniaParkRunSlot -Slot 'Computer') 'portee explicite'
    Assert-Equal 'List' (Get-DomeniaParkRunSlot -Slot 'Autre') 'portee inconnue'
}
Test-Case 'P-UI-23' 'Verifier la liste : trois lectures graduees, de la plus legere a la plus complete' {
    $modes = @(Get-DomeniaParkVerifyModes)
    Assert-Equal 'Ping,Console,Analyse' (($modes | ForEach-Object { [string]$_.Mode }) -join ',')
    Assert-Equal 'Qui répond ?|Qui est connecté ?|Matériel et widgets' (($modes | ForEach-Object { [string]$_.Label }) -join '|')
    foreach ($mode in $modes) { Assert-True ([string]$mode.Detail).Length ('detail absent : ' + [string]$mode.Mode) }
}

Test-Case 'P60-23' 'Plan de collecte : sondes rapides avant les lentes, ordre stable et aucune sonde ajoutée' {
    $probes=@([pscustomobject]@{Id='slow.one';Slow=$true},[pscustomobject]@{Id='fast.one';Slow=$false},[pscustomobject]@{Id='slow.two';Slow=$true},[pscustomobject]@{Id='fast.two'})
    $plan=New-DomeniaCollectionPlan -Guid 'g' -Key 'k' -Probes $probes -CacheMinutes 0
    Assert-Equal 'fast.one,fast.two,slow.one,slow.two' (($plan.Probes|ForEach-Object{$_.Id}) -join ',')
    Assert-Equal 4 $plan.Requested
    Assert-Equal 'slow.one,fast.one,slow.two,fast.two' (($probes|ForEach-Object{$_.Id}) -join ',') 'Le catalogue source a été modifié'
}
Test-Case 'P60-24' 'Plan de collecte : forcer prime sur un âge de réutilisation fourni par un appelant' {
    $now=[datetime]::UtcNow;$stamp=$now.AddSeconds(-5).ToString('o')
    $probe=[pscustomobject]@{Id='hw.fixture';DefinitionHash='same'}
    $previous=[pscustomobject]@{Guid='g';Key='k';Inventory=[pscustomobject]@{CheckedUtc=$stamp};Probes=[pscustomobject]@{'hw.fixture'=[pscustomobject]@{CheckedUtc=$stamp;DefinitionHash='same';Error=''}}}
    $selective=New-DomeniaCollectionPlan -Previous $previous -Guid 'g' -Key 'k' -Probes @($probe) -Inventory $true -CacheMinutes 15 -ReuseMaxAgeDays 30 -NowUtc $now
    Assert-Equal 2 $selective.Reused;Assert-False $selective.Inventory;Assert-Equal 0 @($selective.Probes).Count
    $forced=New-DomeniaCollectionPlan -Previous $previous -Guid 'g' -Key 'k' -Probes @($probe) -Inventory $true -CacheMinutes 0 -ReuseMaxAgeDays 30 -NowUtc $now
    Assert-Equal 0 $forced.Reused;Assert-True $forced.Inventory;Assert-Equal 1 @($forced.Probes).Count
}
