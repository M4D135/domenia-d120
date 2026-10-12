# Typed recipes shared by the fleet workshop, saved widgets and Search. No network access.
function Get-DomeniaQueryFields {
    $fields = [Collections.Generic.List[object]]::new()
    foreach ($line in @(
        'name|Nom du poste|Text','dn|Chemin AD complet|Text','active|Compte actif|Boolean',
        'os|Système déclaré dans AD|Text','version|Version déclarée dans AD|Text',
        'osLabel|Libellé système du dashboard|Text','release|Version Windows du dashboard|Text','osFamily|Famille poste / serveur|Text',
        'site|OU du regroupement dashboard|Text','lifeStatus|Cycle Windows (Ended, Soon, Ok, Unknown)|Text','win10|Windows 10 hors LTSC, LTSB et IoT|Boolean',
        'logonDays|Jours depuis la connexion AD (approximatif)|Number','logonBucket|Tranche de connexion AD|Number',
        'createdRecent|Créé depuis 30 jours|Boolean','passwordOld|Mot de passe machine de plus de 60 jours|Boolean',
        'laps|État LAPS (O valide, E expiré, N absent, X sans schéma)|Text',
        'bitlocker|Clé AD (K présente, N aucune visible, X indisponible)|Text',
        'presenceBucket|Présence regroupée du dashboard|Text','inventoryDays|Ancienneté de lʼinventaire en jours|Number','observedRelease|Windows relevé sur le poste|Text',
        'checkedDays|Ancienneté du relevé en jours|Number','presence|Dernière présence observée|Text',
        'user|Utilisateur console observé|Text','model|Modèle relevé|Text',
        'ramGB|Mémoire relevée en Go|Number','diskFreePercent|Espace libre C: relevé (%)|Number','uptimeDays|Jours depuis le démarrage relevé|Number'
    )) { $p=$line.Split('|'); $fields.Add([pscustomobject]@{Id=$p[0];Name=$p[1];Kind=$p[2];ProbeId='';Category='Données du parc'}) }
    foreach ($probe in @(Get-DomeniaProbeCatalog)) {
        $numeric=([string]$probe.Transform -notlike 'Map:*') -and ([string]$probe.Mode -eq 'Count' -or [string]$probe.Transform -match '^(GB|GBfromKB|MB|Mbps|Number|DaysSince|PercentFree|Year)$')
        $fields.Add([pscustomobject]@{Id=('probe:'+[string]$probe.Id);Name=([string]$probe.Category+' · '+[string]$probe.Name);Kind=$(if($numeric){'Number'}else{'Text'});ProbeId=[string]$probe.Id;Category=[string]$probe.Category})
    }
    return $fields.ToArray()
}
function Get-DomeniaQueryCatalog {
    # The catalog describes precisely the fields accepted by the query engine, never discovers remote classes.
    $metadata=@{}
    foreach($line in @'
name|Ad|Identité AD|Retrouver un poste par son nom.|Texte|PC-EXEMPLE|name
 dn|Ad|Identité AD|Limiter les résultats à un chemin de lʼannuaire.|Texte|OU=Support|distinguishedName
active|Ad|Identité AD|Distinguer les comptes ordinateurs actifs et désactivés.|Oui / Non|Oui|userAccountControl
os|Ad|Système AD|Filtrer le système déclaré dans le compte ordinateur.|Texte|Windows 11|operatingSystem
version|Ad|Système AD|Filtrer la version déclarée dans lʼannuaire.|Texte|10.0|operatingSystemVersion
osLabel|Local|Cycle de vie Windows|Regrouper les libellés système harmonisés du tableau de bord.|Texte|Windows 11 Pro|operatingSystem
release|Local|Cycle de vie Windows|Retrouver la version Windows déduite du build AD.|Texte|24H2|operatingSystemVersion
osFamily|Local|Cycle de vie Windows|Séparer postes de travail, serveurs et systèmes non renseignés.|Texte|Serveurs|operatingSystem
site|Local|Périmètre AD|Regrouper les postes par OU dans le périmètre courant.|Texte|Support|distinguishedName
lifeStatus|Local|Cycle de vie Windows|Repérer une fin de support connue par le référentiel livré.|Texte|Ended, Soon, Ok, Unknown|Référentiel Windows local + système AD
win10|Local|Cycle de vie Windows|Repérer Windows 10 hors éditions LTSC, LTSB et IoT.|Oui / Non|Oui|operatingSystem
logonDays|Local|Activité AD|Rechercher une ancienneté de connexion AD ; cette date est approximative et répliquée.|Jours|90|lastLogonTimestamp
logonBucket|Local|Activité AD|Filtrer les mêmes tranches de connexion que le tableau de bord.|Nombre / tranche|0 : 0–6 j ; 1 : 7–29 j ; 2 : 30–89 j ; 3 : 90–179 j ; 4 : 180 j et plus ; 5 : non renseignée|lastLogonTimestamp
createdRecent|Local|Activité AD|Repérer les comptes créés depuis trente jours.|Oui / Non|Oui|whenCreated
passwordOld|Local|Activité AD|Repérer les mots de passe machine âgés de plus de soixante jours.|Oui / Non|Oui|pwdLastSet
laps|Ad|Protection AD|Filtrer lʼétat dʼexpiration LAPS visible avec les droits de la session.|Code texte|O : valide ; E : expiré ; N : absent ; X : sans schéma|Attributs dʼexpiration LAPS
bitlocker|Ad|Protection AD|Filtrer la présence dʼune clé visible dans AD ; cela ne mesure pas le chiffrement du disque.|Code texte|K : présente ; N : aucune visible ; X : indisponible|Objets msFVE-RecoveryInformation
presenceBucket|Observation|Présence et console|Regrouper le dernier constat réseau utilisable du tableau de bord.|Texte|En ligne, Sans reponse, Non verifie|Observation ICMP/CIM enregistrée
inventoryDays|Observation|Inventaire du poste|Évaluer lʼâge de la dernière lecture dʼinventaire réussie.|Jours|5|Inventory.CheckedUtc
observedRelease|Observation|Inventaire du poste|Filtrer la version Windows relevée sur le poste.|Texte|24H2|Win32_OperatingSystem : Caption, BuildNumber
checkedDays|Observation|Présence et console|Évaluer lʼâge du dernier relevé du poste.|Jours|7|CheckedUtc
presence|Observation|Présence et console|Filtrer le dernier résultat de présence enregistré.|Texte|En ligne|Presence
user|Observation|Présence et console|Retrouver lʼutilisateur console résolu dans AD ; les sessions RDP ne sont pas recensées.|Texte|jdupont|Win32_ComputerSystem.UserName + identité AD
model|Observation|Inventaire du poste|Regrouper les postes par modèle matériel relevé.|Texte|Latitude|Win32_ComputerSystem.Model
ramGB|Observation|Inventaire du poste|Rechercher les postes sous un seuil de mémoire installée.|Go|8|Win32_ComputerSystem.TotalPhysicalMemory
 diskFreePercent|Observation|Inventaire du poste|Repérer un manque dʼespace libre sur C:.|%|10|Win32_LogicalDisk.FreeSpace / Size
uptimeDays|Observation|Inventaire du poste|Rechercher les postes restés allumés longtemps.|Jours|30|Win32_OperatingSystem.LastBootUpTime
'@ -split "`r?`n"){
        $parts=$line.Trim().Split('|');if($parts.Count -eq 7){$metadata[$parts[0]]=$parts}
    }
    $sources=@{Ad='Annuaire AD';Local='Calcul local';Observation='Relevé du poste';Probe='Sonde WMI'}
    $probes=@{};foreach($probe in @(Get-DomeniaProbeCatalog)){$probes[[string]$probe.Id]=$probe}
    $entries=@(foreach($field in @(Get-DomeniaQueryFields)){
        $sourceId='Local';$category=[string]$field.Category;$description='Information disponible dans les données locales du parc.'
        $unit='Texte';$example='';$technical='';$collection='Actualisez la base AD du périmètre choisi, puis exécutez la requête localement.'
        $availability='Les valeurs absentes ou expirées restent inconnues. Le calcul lit uniquement les données déjà enregistrées.'
        if([string]$field.ProbeId){
            $probe=$probes[[string]$field.ProbeId];if($null -eq $probe){continue}
            $sourceId='Probe';$category=[string]$probe.Category
            $description='Interroger « '+[string]$probe.Name+' » dans les relevés des postes.'
            $collection='Ajoutez ce champ à une condition ou à une répartition, puis utilisez Collecter les données requises. La collecte est préparée sur les postes actifs du périmètre et confirmée avant lancement.'
            $availability='Fournisseur WMI/CIM Windows requis, poste joignable et droits de lecture distants. Une classe absente, un accès refusé ou une lecture incomplète reste inconnu.'
            if($probe.Slow){$availability+=' Cette sonde peut être lente, notamment sur un journal volumineux.'}
            if($probe.SkipOnDc){$availability+=' Elle est ignorée sur les contrôleurs de domaine.'}
            $mode=[string]$probe.Mode
            if($mode -eq 'Count'){$description+=' Compte toutes les instances lues ; le détail conservé est limité à vingt lignes.';$unit='Nombre';$example='0'}
            elseif($mode -eq 'All'){$description+=' Plusieurs valeurs par poste sont réunies en un texte séparé par des points-virgules ; utilisez contient pour chercher une valeur.'}
            else{$description+=' Utilise la première instance renvoyée par le fournisseur.'}
            switch -Regex ([string]$probe.Transform){
                '^(GB|GBfromKB)$'{$unit='Go';$example='8';break}
                '^MB$'{$unit='Mo';$example='1024';break}
                '^Mbps$'{$unit='Mbit/s';$example='1000';break}
                '^DaysSince$'{$unit='Jours';$example='30';break}
                '^PercentFree$'{$unit='%';$example='10';break}
                '^Year$'{$unit='Année';$example='2024';break}
                '^Number$'{if($mode -ne 'Count'){$unit='Nombre';$example='1'};break}
                '^Map:'{$unit='Texte';$example=(@(([string]$probe.Transform).Substring(4).Split(';')|ForEach-Object{($_ -split '=',2)[-1]}|Select-Object -Unique) -join ', ');break}
            }
            $units=@{'hw.cpuload'='%';'hw.batterylevel'='%';'hw.cpumhz'='MHz';'sec.signatures'='Jours';'sec.quickscan'='Jours';'sec.fullscan'='Jours'}
            if($units.ContainsKey([string]$probe.Id)){$unit=$units[[string]$probe.Id]}
            $technical='Identifiant : '+[string]$field.Id+"`r`n"+'Espace de noms : '+[string]$probe.Namespace+"`r`n"+'Classe : '+[string]$probe.Class+"`r`n"+'Propriétés : '+(@($probe.Properties) -join ', ')+"`r`n"+'Filtre : '+$(if($probe.Filter){[string]$probe.Filter}else{'aucun'})+"`r`n"+'Lecture : '+$mode+' ; conversion : '+[string]$probe.Transform
        }elseif($metadata.ContainsKey([string]$field.Id)){
            $parts=$metadata[[string]$field.Id];$sourceId=$parts[1];$category=$parts[2];$description=$parts[3];$unit=$parts[4];$example=$parts[5];$technical='Identifiant : '+[string]$field.Id+"`r`n"+'Origine : '+$parts[6]
            if($sourceId -eq 'Observation'){
                $collection='Lancez un relevé explicite du poste ou du périmètre, puis exécutez la requête. Collecter les données requises prépare uniquement les mesures nécessaires à la requête, avec confirmation.'
                $availability='Poste Windows joignable et droits de lecture distants selon la mesure. Chaque relevé conserve sa date ; une ancienne valeur ne devient pas fraîche après un échec.'
            }elseif($sourceId -eq 'Ad'){$availability='Dépend des attributs lus, du schéma et des droits AD de la session. La mise à jour de la base doit couvrir le périmètre choisi.'}
            else{$availability='Calculé à partir de la base AD et du référentiel local, selon leur couverture et leur date. Aucun accès au poste pendant le calcul.'}
        }
        if($field.Kind -eq 'Boolean'){$typeLabel='Oui / Non'}elseif($field.Kind -eq 'Number'){$typeLabel='Nombre'}else{$typeLabel='Texte'}
        [pscustomobject]@{Id=[string]$field.Id;Name=[string]$field.Name;Kind=[string]$field.Kind;ProbeId=[string]$field.ProbeId;SourceId=$sourceId;Source=$sources[$sourceId];Category=$category;TypeLabel=$typeLabel;Unit=$unit;Description=$description;Example=$example;Collection=$collection;Availability=$availability;Technical=$technical;SearchText=([string]$field.Name+' '+$sources[$sourceId]+' '+$category+' '+$description+' '+$technical)}
    })
    return @($entries|Sort-Object -Property Category,Name,Id -Culture 'fr-FR')
}
function Find-DomeniaQueryCatalogEntries {
    param([object[]]$Entries=@(),[string]$Text='',[string]$SourceId='',[string]$Category='')
    $terms=@($Text.Trim() -split '\s+'|Where-Object{$_})
    $compare=[Globalization.CultureInfo]::GetCultureInfo('fr-FR').CompareInfo
    $options=[Globalization.CompareOptions]::IgnoreCase -bor [Globalization.CompareOptions]::IgnoreNonSpace
    return @(foreach($entry in $Entries){
        if($SourceId -and [string]$entry.SourceId -cne $SourceId){continue}
        if($Category -and [string]$entry.Category -cne $Category){continue}
        $match=$true;foreach($term in $terms){if($compare.IndexOf([string]$entry.SearchText,$term,$options) -lt 0){$match=$false;break}}
        if($match){$entry}
    })
}
function Get-DomeniaQueryOperators {
    param([string]$Kind='Text')
    $ops=[ordered]@{Equal='est égal à';NotEqual='est différent de';IsMissing='est absent';IsPresent='est renseigné'}
    if($Kind -eq 'Text'){$ops.Contains='contient';$ops.StartsWith='commence par';$ops.EndsWith='se termine par'}
    if($Kind -in @('Number','Timestamp')){$ops.Greater='est supérieur à';$ops.GreaterOrEqual='est supérieur ou égal à';$ops.Less='est inférieur à';$ops.LessOrEqual='est inférieur ou égal à'}
    return @(foreach($entry in $ops.GetEnumerator()){[pscustomobject]@{Id=[string]$entry.Key;Name=[string]$entry.Value}})
}
function New-DomeniaQueryRecipe {
    param([string]$Name='Tous les postes recensés',[string]$Id='',[string]$Junction='All',[object[]]$Clauses=@(),[string]$GroupBy='',[object[]]$Refinements=@(),$ProbeSelection=$null,$ObjectIds=$null)
    if(-not $Id){$Id=[guid]::NewGuid().ToString('N')}
    return [pscustomobject]@{Format='Domenia.Query/1';Id=$Id;Name=$Name;Junction=$Junction;Clauses=@($Clauses);GroupBy=$GroupBy;Refinements=@($Refinements);ProbeSelection=$ProbeSelection;ObjectIds=$ObjectIds}
}
function Get-DomeniaQueryIdentitySelection {
    # A frozen alert selection is explicit, GUID-bound and may be saved. Empty never means all.
    param($Recipe)
    $values=Get-DomeniaMemberValue $Recipe 'ObjectIds'
    if($null -eq $values){return $null}
    if($values -is [string] -or @($values).Count -gt 20000){throw 'La sélection accepte au plus 20 000 GUID.'}
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($value in $values){
        $guid=[guid]::Empty
        if(-not [guid]::TryParse([string]$value,[ref]$guid) -or $guid -eq [guid]::Empty){throw 'GUID invalide dans la sélection de postes.'}
        [void]$ids.Add($guid.ToString('D'))
    }
    return ,$ids
}
function ConvertTo-DomeniaCompiledQuery {
    param([Parameter(Mandatory=$true)]$Recipe)
    if([string](Get-DomeniaMember $Recipe 'Format') -cne 'Domenia.Query/1'){throw 'Format de requête non reconnu.'}
    [void](ConvertTo-DomeniaQueryProbeSelection $Recipe)
    [void](Get-DomeniaQueryIdentitySelection $Recipe)
    $name=[string](Get-DomeniaMember $Recipe 'Name');$id=[string](Get-DomeniaMember $Recipe 'Id')
    if(-not $name.Trim() -or $name.Length -gt 120 -or $id -notmatch '^[a-zA-Z0-9_.-]{1,80}$'){throw 'Nom ou identifiant de requête invalide.'}
    $junction=[string](Get-DomeniaMember $Recipe 'Junction')
    if($junction -cnotin @('All','Any')){throw 'Choisir Toutes les conditions ou Au moins une condition.'}
    $definition=[M4D.Admin.Common.Query.QueryDefinition]::new()
    $definition.Junction=[M4D.Admin.Common.Query.QueryJunction]::$junction
    $definitions=[Collections.Generic.List[M4D.Admin.Common.Query.FieldDefinition]]::new();$byId=@{}
    foreach($field in @(Get-DomeniaQueryFields)){$byId[$field.Id]=$field;$definitions.Add([M4D.Admin.Common.Query.FieldDefinition]::new($field.Id,[M4D.Admin.Common.Query.FieldKind]::$($field.Kind)))}
    $clauses=@(Get-DomeniaMember $Recipe 'Clauses' @())
    $refinements=@(Get-DomeniaMember $Recipe 'Refinements' @());$groupBy=[string](Get-DomeniaMember $Recipe 'GroupBy')
    if($groupBy -and $groupBy -cnotin @($byId.Keys)){throw 'Champ de répartition inconnu.'}
    if($refinements.Count){[void](ConvertTo-DomeniaCompiledQuery (New-DomeniaQueryRecipe -Clauses $refinements))}
    if(($clauses.Count+$refinements.Count) -gt 64){throw 'Une requête accepte 64 conditions au maximum.'}
    foreach($clause in $clauses){
        $key=[string](Get-DomeniaMember $clause 'Field');$op=[string](Get-DomeniaMember $clause 'Operator');$value=Get-DomeniaMemberValue $clause 'Value'
        if(-not $byId.ContainsKey($key) -or $key -cnotin @($byId.Keys)){throw ('Champ inconnu : '+$key)}
        if($op -cnotin @(Get-DomeniaQueryOperators -Kind $byId[$key].Kind | ForEach-Object{$_.Id})){throw ('Opérateur invalide pour '+$byId[$key].Name)}
        if($null -ne $value -and $value -is [psobject]){$value=$value.PSObject.BaseObject}
        $definition.Clauses.Add([M4D.Admin.Common.Query.QueryClause]::new($key,[M4D.Admin.Common.Query.QueryOperator]::$op,$value))
    }
    return [M4D.Admin.Common.Query.QueryEngine]::Compile($definitions,$definition)
}
function ConvertTo-DomeniaQueryProbeSelection {
    param($Recipe)
    $selection=Get-DomeniaMemberValue $Recipe 'ProbeSelection'
    if($null -eq $selection){return $null}
    $key=[string](Get-DomeniaMember $selection 'Key');$mode=[string](Get-DomeniaMember $selection 'Mode')
    $probe=Get-DomeniaProbe $key
    if($null -eq $probe -or $mode -cnotin @('Equal','Range','Other')){throw 'Segment de sonde inconnu.'}
    $numeric=([string]$probe.Transform -notlike 'Map:*') -and ($probe.Mode -eq 'Count' -or $probe.Transform -match '^(GB|GBfromKB|MB|Mbps|Number|DaysSince|PercentFree|Year)$')
    $result=[Domenia.Native.ProbeSelection]::new();$result.Key=$key;$result.Mode=$mode;$result.Numeric=$numeric
    if($mode -eq 'Range'){
        $low=Get-DomeniaMemberValue $selection 'Low';$high=Get-DomeniaMemberValue $selection 'High'
        $result.Low=if($null -eq $low){[double]::NegativeInfinity}else{[double]$low};$result.High=if($null -eq $high){[double]::PositiveInfinity}else{[double]$high}
        if(-not $numeric -or [double]::IsNaN($result.Low) -or [double]::IsNaN($result.High) -or $result.Low -ge $result.High){throw 'Bornes de segment invalides.'}
    }elseif($mode -eq 'Equal'){
        $value=Get-DomeniaMemberValue $selection 'Value';if($null -eq $value){throw 'Valeur de segment absente.'}
        $result.Value=[Convert]::ToString($value,[Globalization.CultureInfo]::InvariantCulture)
        if($result.Value.Length -gt 4096 -or ($numeric -and $null -eq (ConvertTo-DomeniaProbeNumber $result.Value))){throw 'Valeur de segment invalide.'}
    }else{
        $excluded=@(Get-DomeniaMember $selection 'Excluded' @())
        if(-not $excluded.Count -or $excluded.Count -gt 64){throw 'Catégories du segment invalides.'}
        $result.Excluded=[string[]]$excluded
    }
    return $result
}
function Get-DomeniaQueryTemplates {
    # Curated local recipes, shared by Fleet and Computer. No remote query is performed by this library.
    # Metadata belongs only to delivered templates; saving a copy keeps the existing user recipe schema.
    $make={param([string]$Id,[string]$Name,[string]$Category,[string]$Description,[object[]]$Clauses=@(),[string]$GroupBy='',[string]$Junction='All')
        $recipe=New-DomeniaQueryRecipe -Id ('template.'+$Id) -Name $Name -Clauses $Clauses -GroupBy $GroupBy -Junction $Junction
        $recipe|Add-Member -NotePropertyName Category -NotePropertyValue $Category
        $recipe|Add-Member -NotePropertyName Description -NotePropertyValue ($Description+' Évaluation locale des données disponibles ; les valeurs non lues ou périmées restent inconnues.')
        return $recipe
    }
    $clause={param([string]$Field,[string]$Operator,$Value);[pscustomobject]@{Field=$Field;Operator=$Operator;Value=$Value}}
    & $make 'all' 'Tous les postes recensés' 'Inventaire général' 'Tous les comptes ordinateur du périmètre, actifs et désactivés ; sur le tableau du poste, le seul objet sélectionné.'
    & $make 'stale' 'Comptes actifs sans connexion depuis au moins 90 jours' 'Comptes et activité AD' 'Date AD répliquée dʼau moins quatre-vingt-dix jours ; exclut les dates non renseignées et ne prouve pas une absence dʼutilisation.' @(
        (& $clause 'active' 'Equal' $true),(& $clause 'logonBucket' 'GreaterOrEqual' 3),(& $clause 'logonBucket' 'LessOrEqual' 4))
    # Id | category | title | field | operator | typed value | operational description.
    $rows=@'
active|Comptes et activité AD|Comptes actifs|active|Equal|b:true|Comptes ordinateurs activés dans la copie AD du périmètre.
disabled|Comptes et activité AD|Comptes désactivés|active|Equal|b:false|Comptes désactivés, conservés dans le recensement ; ce modèle ne lance aucune collecte.
never|Qualité des données|Date de connexion AD non renseignée|logonDays|IsMissing|z:|Date AD absente ou non exploitable ; cela ne prouve pas que le poste nʼa jamais été utilisé.
created|Comptes et activité AD|Créés depuis 30 jours|createdRecent|Equal|b:true|Comptes créés dans les trente derniers jours, utiles au suivi des nouveaux équipements.
password|Comptes et activité AD|Mot de passe machine ancien|passwordOld|Equal|b:true|Mot de passe du compte machine âgé de plus de soixante jours ; vérifier la relation au domaine.
laps|Protection AD|Expiration LAPS dépassée|laps|Equal|t:E|Expiration LAPS dépassée dʼaprès les attributs visibles, sans lire le secret.
nolaps|Protection AD|Aucun attribut LAPS lu|laps|Equal|t:N|Aucun attribut LAPS utilisable lu ; vérifier le déploiement et les droits avant de conclure.
nokey|Protection AD|Aucune clé BitLocker visible dans AD|bitlocker|Equal|t:N|Aucune clé de récupération visible dans AD ; cela ne mesure pas le chiffrement du disque.
servers|Système et cycle Windows|Système AD contenant Server|os|Contains|t:Server|Comptes dont le système déclaré dans AD contient Server.
unchecked|Qualité des données|Sans relevé utilisable|checkedDays|IsMissing|z:|Aucun relevé exploitable dans la durée de conservation ; préparer une collecte ciblée.
oldcheck|Qualité des données|Relevé de plus de 7 jours|checkedDays|Greater|n:7|Relevé encore disponible mais vieux de plus dʼune semaine ; les relevés expirés restent inconnus.
lowdisk|Disques et capacité|C: moins de 10 % libre|diskFreePercent|Less|n:10|Seuil de triage pour lʼespace libre de C: ; lʼurgence dépend aussi du volume et de lʼusage.
ram|Matériel|Moins de 8 Go de RAM|ramGB|Less|n:8|Mémoire installée inférieure à 8 Go dans le dernier inventaire ; seuil à adapter aux usages.
uptime|Système et cycle Windows|Sans redémarrage depuis plus de 30 jours|uptimeDays|Greater|n:30|Démarrage relevé il y a plus de trente jours ; préparer une vérification des maintenances.
cpu|Matériel|Charge CPU supérieure à 80 %|probe:hw.cpuload|Greater|n:80|Charge instantanée du premier processeur supérieure à 80 %, sans présumer dʼune saturation durable.
services|Services et processus|Services automatiques arrêtés|probe:soft.stoppedauto|Greater|n:0|Au moins un service automatique arrêté ; certains services restent volontairement à lʼarrêt.
syserrors|Événements|Erreurs système depuis 24 h|probe:evt.syserrors|Greater|n:0|Au moins une erreur du journal Système sur vingt-quatre heures ; lecture potentiellement lente.
ad.recentlogon|Comptes et activité AD|Connexion AD depuis moins de 7 jours|logonDays|Less|n:7|Date répliquée lastLogonTimestamp récente ; cette mesure est approximative, ce nʼest pas une présence réseau.
ad.logon30|Comptes et activité AD|Connexion AD de plus de 30 jours|logonDays|Greater|n:30|Premier tri des dates AD anciennes, à rapprocher du rôle du poste et de ses derniers relevés.
ad.logon180|Comptes et activité AD|Connexion AD de plus de 180 jours|logonDays|GreaterOrEqual|n:180|Comptes à examiner pour un inventaire de longue inactivité ; aucune suppression proposée automatiquement.
ad.existing|Comptes et activité AD|Comptes créés depuis plus de 30 jours|createdRecent|Equal|b:false|Écarte les créations récentes dans une revue du parc installé.
ad.passwordcurrent|Comptes et activité AD|Mot de passe machine de 60 jours au plus|passwordOld|Equal|b:false|Complément des comptes au mot de passe ancien, limité aux dates connues.
ad.nameexample|Comptes et activité AD|Postes dont le nom commence par PC-|name|StartsWith|t:PC-|Exemple de convention de nommage ; adaptez le préfixe à votre annuaire.
ad.ouexample|Comptes et activité AD|Chemin AD contenant OU=Support|dn|Contains|t:OU=Support|Exemple de filtre textuel de chemin ; utilisez le sélecteur OU pour borner précisément le périmètre.
os.win11|Système et cycle Windows|Windows 11 déclaré dans AD|os|Contains|t:Windows 11|Recense les systèmes Windows 11 déclarés ; la version relevée sur le poste peut différer.
os.win10|Système et cycle Windows|Windows 10 hors éditions longue durée|win10|Equal|b:true|Windows 10 hors LTSC, LTSB et IoT selon le libellé AD.
os.workstations|Système et cycle Windows|Famille postes de travail|osFamily|Equal|t:Postes de travail|Même regroupement de famille que le tableau de bord, établi à partir du système AD.
os.server2022|Système et cycle Windows|Windows Server 2022 déclaré|os|Contains|t:Server 2022|Inventaire dʼune génération serveur à partir de lʼattribut AD.
os.server2025|Système et cycle Windows|Windows Server 2025 déclaré|os|Contains|t:Server 2025|Inventaire dʼune génération serveur à partir de lʼattribut AD.
os.ltsc|Système et cycle Windows|Éditions LTSC déclarées|os|Contains|t:LTSC|Repère les éditions longue durée nommées LTSC ; leur support dépend de lʼédition exacte.
os.ended|Système et cycle Windows|Fin de support connue dépassée|lifeStatus|Equal|t:Ended|Fin de support dépassée selon le référentiel Windows livré et lʼédition reconnue.
os.soon|Système et cycle Windows|Fin de support dans les 90 jours|lifeStatus|Equal|t:Soon|Version dont le référentiel local annonce une fin de support proche.
os.supported|Système et cycle Windows|Support connu au-delà de 90 jours|lifeStatus|Equal|t:Ok|Cycle connu et hors de la fenêtre dʼalerte ; ce nʼest pas une preuve de niveau de correctifs.
os.lifecycleunknown|Qualité des données|Cycle de vie Windows non déterminé|lifeStatus|Equal|t:Unknown|Référentiel ou version insuffisant pour déterminer une date de fin de support.
os.observed11|Système et cycle Windows|Windows 11 relevé sur le poste|observedRelease|Contains|t:Windows 11|Filtre la version issue de lʼinventaire, distincte du système déclaré dans AD.
os.observed24h2|Système et cycle Windows|Version 24H2 relevée|observedRelease|Contains|t:24H2|Version commerciale déduite du build de lʼinventaire léger.
os.32bit|Système et cycle Windows|Architecture Windows 32 bits|probe:os.arch|Contains|t:32|Architecture retournée par Windows ; utile au repérage des systèmes à moderniser.
os.dc|Système et cycle Windows|Rôle contrôleur de domaine relevé|probe:os.producttype|Equal|t:Controleur de domaine|Rôle Windows lu sur le poste ; les sondes interdites sur un contrôleur restent exclues.
os.reboot7|Système et cycle Windows|Redémarré depuis moins de 7 jours|uptimeDays|Less|n:7|Dernier démarrage inférieur à une semaine, dʼaprès le dernier inventaire utilisable.
os.multiusers|Présence et utilisateurs|Plusieurs utilisateurs déclarés par Windows|probe:os.users|Greater|n:1|Compteur NumberOfUsers supérieur à un ; il ne fournit pas lʼidentité de chaque session.
os.freeramlow|Matériel|Mémoire physique libre inférieure à 1 Go|probe:os.freeram|Less|n:1|Mesure instantanée de mémoire libre ; seuil de triage à confirmer sur le poste.
os.virtualfreelow|Matériel|Mémoire virtuelle libre inférieure à 2 Go|probe:os.virtualfree|Less|n:2|Faible mémoire virtuelle libre au relevé ; comparer avec la charge et le fichier dʼéchange.
os.oldinstall|Système et cycle Windows|Windows installé avant 2020|probe:os.installyear|Less|n:2020|Année dʼinstallation Windows ancienne ; indicateur dʼinventaire, pas une preuve de vétusté du matériel.
hw.ram16|Matériel|Au moins 16 Go de RAM|ramGB|GreaterOrEqual|n:16|Postes dont lʼinventaire confirme au moins 16 Go de mémoire installée.
hw.twocores|Matériel|Moins de 2 cœurs sur le premier processeur|probe:hw.cores|Less|n:2|Capacité faible du premier processeur ; ce seul critère ne détermine pas une compatibilité Windows.
hw.threads|Matériel|Au moins 8 processeurs logiques|probe:hw.threads|GreaterOrEqual|n:8|Repère une capacité de calcul déclarée, sans mesurer les performances applicatives.
hw.virtualizationoff|Matériel|Virtualisation désactivée dans le firmware|probe:hw.virtualization|Equal|t:Non|Virtualisation déclarée désactivée sur le premier processeur ; vérifier les réglages et le matériel.
hw.slatabsent|Matériel|SLAT non déclaré par le processeur|probe:hw.slat|Equal|t:Non|Capacité de traduction de second niveau non déclarée ; utile avant un projet de virtualisation.
hw.lowbattery|Matériel|Première batterie à moins de 20 %|probe:hw.batterylevel|Less|n:20|Charge instantanée de la première batterie ; les postes sans batterie ne sont pas assimilés à zéro.
hw.batterypresent|Matériel|Batterie présente|probe:hw.battery|NotEqual|t:Non|Au moins une batterie reconnue, y compris lorsque le fournisseur recense plus de deux instances.
hw.portable|Matériel|Type de système portable|probe:hw.chassis|Equal|t:Portable|Type PCSystemTypeEx déclaré Portable ; la classification dépend du constructeur.
hw.tablet|Matériel|Type de système tablette|probe:hw.chassis|Equal|t:Tablette|Type PCSystemTypeEx déclaré Tablette.
hw.multiscreen|Matériel|Au moins deux écrans recensés|probe:hw.screens|GreaterOrEqual|n:2|Nombre dʼinstances WmiMonitorID lues ; ne garantit pas que chaque écran est actuellement allumé.
hw.oldbios|Matériel|BIOS daté avant 2020|probe:hw.biosyear|Less|n:2020|Date de publication BIOS ancienne ; vérifier la politique du constructeur avant une mise à jour.
hw.serialplaceholder|Qualité des données|Numéro de série générique constructeur|probe:hw.serialmissing|Contains|t:To Be Filled|Exemple de numéro de série générique à examiner dans lʼinventaire matériel.
hw.dell|Matériel|Fabricant contenant Dell|probe:hw.maker|Contains|t:Dell|Exemple de segmentation constructeur, modifiable dans Composer.
hw.lenovo|Matériel|Fabricant contenant Lenovo|probe:hw.maker|Contains|t:Lenovo|Exemple de segmentation constructeur pour un lot de maintenance.
disk.low20|Disques et capacité|C: moins de 20 % libre|diskFreePercent|Less|n:20|Seuil de prévention plus large que le triage à 10 %, à adapter à la taille du volume.
disk.small|Disques et capacité|C: de moins de 128 Go|probe:disk.csize|Less|n:128|Capacité du volume système faible pour certains usages ; ce seuil nʼest pas une exigence universelle.
disk.multivolume|Disques et capacité|Plusieurs volumes locaux|probe:disk.count|Greater|n:1|Recense les postes ayant plusieurs volumes de type disque local.
disk.ssd|Disques et capacité|Premier disque physique déclaré SSD|probe:disk.media|Equal|t:SSD|Type du premier disque physique renvoyé par le fournisseur Storage.
disk.hdd|Disques et capacité|Premier disque physique déclaré disque dur|probe:disk.media|Equal|t:Disque dur|Repère les disques mécaniques déclarés pour préparer une étude de remplacement.
disk.warning|Disques et capacité|Premier disque en avertissement|probe:disk.health|Equal|t:Avertissement|État HealthStatus de la première instance ; vérifier lʼensemble des disques dans la fiche.
disk.failed|Disques et capacité|Premier disque déclaré défaillant|probe:disk.health|Equal|t:Defaillant|État de défaillance signalé par le fournisseur Storage, à confirmer rapidement.
disk.removable|Disques et capacité|Volume amovible présent au relevé|probe:disk.removable|Greater|n:0|Au moins un volume de type amovible ; cette mesure ne couvre pas tous les périphériques USB.
disk.zero|Disques et capacité|C: à zéro pour cent libre|diskFreePercent|Equal|n:0|Zéro est une mesure connue ; une valeur absente ne correspond pas à ce modèle.
sec.lapsvalid|Protection AD|Expiration LAPS encore valide|laps|Equal|t:O|Expiration LAPS visible et non dépassée ; aucun secret nʼest lu par la requête.
sec.lapsnoschema|Protection AD|Schéma LAPS indisponible|laps|Equal|t:X|Le schéma LAPS nʼest pas disponible pour cette lecture.
sec.recoveryvisible|Protection AD|Clé de récupération visible dans AD|bitlocker|Equal|t:K|Présence dʼune clé visible dans lʼannuaire, indépendamment de lʼétat actuel du disque.
sec.recoveryunavailable|Protection AD|Lecture BitLocker AD indisponible|bitlocker|Equal|t:X|Lecture des objets de récupération indisponible ; ne pas assimiler à une absence de clé.
sec.unencrypted|Sécurité du poste|Protection BitLocker C: désactivée|probe:sec.bitlocker|Equal|t:Non protege|ProtectionStatus non protégé pour C: ; lecture locale distante distincte de la clé AD.
sec.encrypted|Sécurité du poste|Protection BitLocker C: active|probe:sec.bitlocker|Equal|t:Protege|ProtectionStatus actif pour C: au dernier relevé.
sec.defenderoff|Sécurité du poste|Antivirus Defender déclaré inactif|probe:sec.defender|Equal|t:Non|Defender peut être désactivé au profit dʼun autre antivirus ; vérifier le produit en place.
sec.realtimeoff|Sécurité du poste|Protection temps réel Defender inactive|probe:sec.realtime|Equal|t:Non|État de protection temps réel au relevé, selon la disponibilité du fournisseur Defender.
sec.behavioroff|Sécurité du poste|Surveillance comportementale Defender inactive|probe:sec.behavior|Equal|t:Non|Surveillance comportementale déclarée inactive, à comparer à la stratégie de protection.
sec.signaturesold|Sécurité du poste|Signatures Defender de plus de 3 jours|probe:sec.signatures|Greater|n:3|Seuil de revue opérationnelle ; la valeur spéciale 65535 signifie jamais selon le fournisseur.
sec.quickscanold|Sécurité du poste|Analyse rapide Defender de plus de 7 jours|probe:sec.quickscan|Greater|n:7|Ancienneté de lʼanalyse rapide ; adapter à la politique du parc, 65535 signifie jamais.
sec.fullscannever|Sécurité du poste|Aucune analyse complète Defender déclarée|probe:sec.fullscan|Equal|n:65535|Valeur spéciale du fournisseur ; ce constat ne suffit pas à juger la protection globale.
sec.tpm2|Sécurité du poste|Spécification TPM contenant 2.0|probe:sec.tpmversion|Contains|t:2.0|Version TPM déclarée ; ne valide pas à elle seule une compatibilité Windows 11.
sec.tpmoff|Sécurité du poste|TPM déclaré désactivé|probe:sec.tpmenabled|Equal|t:Non|État initial du TPM déclaré désactivé au relevé.
sec.tpmnotactivated|Sécurité du poste|TPM déclaré non opérationnel|probe:sec.tpmactivated|Equal|t:Non|État dʼactivation initial du TPM ; vérifier le firmware et la stratégie.
sec.localmany|Sécurité du poste|Plus de 3 comptes locaux activés|probe:sec.localusers|Greater|n:3|Seuil dʼexamen des comptes locaux ; la sonde est exclue des contrôleurs de domaine.
sec.shares|Sécurité du poste|Partages de type disque recensés|probe:sec.shares|Greater|n:0|Partages retournés par la requête Type=0 ; leur présence ne prouve pas une exposition anormale.
net.slow|Réseau|Premier lien réseau inférieur à 100 Mbit/s|probe:net.speed|Less|n:100|Vitesse déclarée du premier adaptateur physique connecté, différente du débit réellement disponible.
net.gigabit|Réseau|Premier lien réseau à au moins 1 Gbit/s|probe:net.speed|GreaterOrEqual|n:1000|Capacité déclarée du lien, sans test de débit réseau.
net.fixed|Réseau|Configuration IP déclarée fixe|probe:net.dhcp|Equal|t:Fixe|DHCP désactivé sur la première configuration IP lue.
net.dhcp|Réseau|Configuration IP via DHCP|probe:net.dhcp|Equal|t:DHCP|DHCP déclaré actif sur la première configuration IP lue.
net.wifi|Réseau|Wi-Fi connecté au relevé|probe:net.wifi|NotEqual|t:Non|Au moins une interface Wi-Fi connectée, y compris lorsque le fournisseur recense plus de deux instances.
net.vpnexample|Réseau|Adaptateur contenant Ethernet|probe:net.adapter|Contains|t:Ethernet|Exemple de filtre sur les noms dʼadaptateurs physiques connectés ; modifiez le terme si nécessaire.
soft.printersmany|Services et processus|Au moins 5 imprimantes installées|probe:soft.printers|GreaterOrEqual|n:5|Nombre dʼinstances dʼimprimantes, y compris les imprimantes virtuelles.
soft.startupmany|Services et processus|Au moins 10 entrées de démarrage|probe:soft.startup|GreaterOrEqual|n:10|Seuil de revue du démarrage ; le nombre dʼentrées ne mesure pas à lui seul leur impact.
soft.processmany|Services et processus|Plus de 200 processus au relevé|probe:soft.processes|Greater|n:200|Photographie du nombre de processus, utile pour comparer des postes de même usage.
soft.spoolerstopped|Services et processus|Spouleur dʼimpression arrêté|probe:soft.spooler|Equal|t:Stopped|Service Spooler arrêté ; peut être volontaire sur un serveur ou un poste sans impression.
soft.updatestopped|Services et processus|Service Windows Update arrêté|probe:soft.wuauserv|Equal|t:Stopped|État du service à la lecture ; un service à démarrage déclenché peut être arrêté normalement.
soft.winrmrunning|Services et processus|Service WinRM en cours|probe:soft.winrm|Equal|t:Running|Service WinRM démarré ; ne garantit ni lʼouverture du transport ni les droits dʼaccès.
soft.bitsstopped|Services et processus|Service BITS arrêté|probe:soft.bits|Equal|t:Stopped|État instantané de BITS, à interpréter selon le mode de démarrage configuré.
soft.timestopped|Services et processus|Service Heure Windows arrêté|probe:soft.w32time|Equal|t:Stopped|À rapprocher de la stratégie de synchronisation horaire et du rôle du système.
soft.rdprunning|Services et processus|Service Bureau à distance en cours|probe:soft.rdp|Equal|t:Running|Service TermService en cours ; ce nʼest pas une preuve de session RDP ouverte.
soft.firewallstopped|Services et processus|Service Pare-feu Windows arrêté|probe:soft.firewall|Equal|t:Stopped|État MpsSvc arrêté ; vérifier la stratégie et le dispositif de protection utilisé.
soft.defenderstopped|Services et processus|Service Defender arrêté|probe:soft.defender|Equal|t:Stopped|Peut correspondre à un autre produit antivirus ; comparer aux données de protection.
soft.dnsstopped|Services et processus|Service Client DNS arrêté|probe:soft.dnsclient|Equal|t:Stopped|État du cache client DNS, à examiner dans le contexte du poste.
user.manyprofiles|Présence et utilisateurs|Plus de 10 profils non spéciaux|probe:user.profiles|Greater|n:10|Profils stockés sur le poste ; ce nʼest ni un nombre dʼutilisateurs actifs ni une autorisation de suppression.
user.multisessions|Présence et utilisateurs|Plusieurs sessions interactives recensées|probe:user.sessions|Greater|n:1|Compte les sessions répondant au filtre WMI de la sonde, sans liste nominative exhaustive.
user.online|Présence et utilisateurs|Postes ayant répondu au dernier relevé|presence|Equal|t:En ligne|Présence observée dans les données disponibles ; ce résultat nʼest pas un ping en temps réel.
user.noresponse|Présence et utilisateurs|Dernier relevé sans réponse|presenceBucket|Equal|t:Sans reponse|Absence de réponse au dernier relevé ; cela ne prouve pas que le poste est éteint.
user.consoleknown|Présence et utilisateurs|Utilisateur console résolu|user|IsPresent|z:|Utilisateur de console résolu dans AD et encore exploitable ; les sessions RDP ne sont pas recensées ici.
evt.unexpected|Événements|Arrêt inattendu depuis 7 jours|probe:evt.unexpected|Greater|n:0|Événement 6008 du journal Système dans les sept jours ; lecture potentiellement lente.
evt.manyerrors|Événements|Au moins 10 erreurs système en 24 h|probe:evt.syserrors|GreaterOrEqual|n:10|Seuil de triage des volumes dʼerreurs, sans diagnostic automatique de cause.
quality.os|Qualité des données|Système AD non renseigné|os|IsMissing|z:|Attribut système absent de la copie locale ; actualiser lʼOU si la couverture est incomplète.
quality.version|Qualité des données|Version AD non renseignée|version|IsMissing|z:|Version système absente ou non lue dans AD.
quality.inventory|Qualité des données|Aucun inventaire léger exploitable|inventoryDays|IsMissing|z:|Inventaire absent ou expiré ; un ping seul ne le rafraîchit pas.
quality.inventoryold|Qualité des données|Inventaire de plus de 7 jours|inventoryDays|Greater|n:7|Dernière lecture dʼinventaire réussie de plus dʼune semaine, encore dans la durée utilisable.
quality.disk|Qualité des données|Espace disque inconnu|diskFreePercent|IsMissing|z:|Pas de mesure exploitable pour C: ; ne pas assimiler à un disque plein.
quality.ram|Qualité des données|Mémoire installée inconnue|ramGB|IsMissing|z:|Aucune valeur RAM exploitable dans lʼinventaire disponible.
quality.console|Qualité des données|Utilisateur console non résolu|user|IsMissing|z:|Identité console absente, non résolue ou expirée ; cela ne prouve pas lʼabsence dʼutilisateur.
quality.defender|Qualité des données|État Defender inconnu|probe:sec.defender|IsMissing|z:|Sonde absente, fournisseur indisponible, refus ou mesure expirée.
quality.bitlocker|Qualité des données|Protection BitLocker du disque inconnue|probe:sec.bitlocker|IsMissing|z:|Aucune valeur WMI exploitable pour C:, distincte de la présence dʼune clé AD.
quality.tpm|Qualité des données|Spécification TPM inconnue|probe:sec.tpmversion|IsMissing|z:|Aucune spécification TPM exploitable ; distinguer absence matérielle et impossibilité de lecture.
quality.events|Qualité des données|Journal Système non collecté ou expiré|probe:evt.syserrors|IsMissing|z:|Le nombre dʼerreurs est inconnu tant que la sonde nʼa pas fourni un relevé utilisable.
quality.network|Qualité des données|Vitesse réseau inconnue|probe:net.speed|IsMissing|z:|Absence de mesure de lien utilisable ; ce nʼest pas un débit nul.
quality.presence|Qualité des données|Présence non vérifiée|presenceBucket|Equal|t:Non verifie|Aucun constat de présence utilisable dans le regroupement du tableau de bord.
'@
    foreach($line in ($rows -split "`r?`n")){
        $p=$line.Split('|');if($p.Count -ne 7){throw 'Définition de modèle invalide.'}
        $value=$null
        switch($p[5].Substring(0,2)){'b:'{$value=($p[5].Substring(2) -eq 'true')};'n:'{$value=[decimal]::Parse($p[5].Substring(2),[Globalization.CultureInfo]::InvariantCulture)};'t:'{$value=$p[5].Substring(2)};'z:'{$value=$null};default{throw 'Type de valeur de modèle invalide.'}}
        & $make $p[0] $p[2] $p[1] $p[6] @((& $clause $p[3] $p[4] $value))
    }
    # Each grouping addresses a distinct inventory question. Numeric measures are not split into arbitrary ranges.
    $groups=@'
by.state|Comptes actifs et désactivés|active|Répartition des états AD connus et inconnus.
by.ou|Postes par OU du périmètre|site|Même regroupement par OU que le tableau de bord ; le résultat dépend du périmètre choisi.
by.os|Systèmes déclarés dans AD|os|Répartition des libellés bruts du système déclaré dans lʼannuaire.
by.release|Versions Windows du référentiel|release|Versions déduites du build AD, avec la catégorie inconnue lorsque nécessaire.
by.lifecycle|États du cycle Windows|lifeStatus|Répartition Ended, Soon, Ok et Unknown du référentiel local.
by.logon|Tranches de connexion AD|logonBucket|Tranches 0–6, 7–29, 30–89, 90–179, 180 jours et plus, puis date non renseignée.
by.presence|Dernière présence par état|presenceBucket|Photographie locale des derniers résultats de présence, sans nouveau ping.
by.user|Utilisateurs console résolus|user|Répartition des utilisateurs de console connus ; les sessions RDP ne sont pas recensées.
by.model|Modèles de lʼinventaire léger|model|Regroupement par modèle des inventaires encore exploitables.
by.observedrelease|Versions Windows relevées|observedRelease|Versions issues des relevés des postes, distinctes des attributs AD.
by.maker|Constructeurs matériels|probe:hw.maker|Regrouper les postes par fabricant relevé.
by.cpu|Modèles du premier processeur|probe:hw.cpu|Première instance de processeur renvoyée par chaque poste.
by.bios|Versions BIOS déclarées|probe:hw.bios|Inventaire des versions, sans comparaison automatique aux versions recommandées.
by.gpu|Premières cartes graphiques|probe:hw.gpu|Première carte vidéo renvoyée par poste, sans inventaire exhaustif multi-GPU.
by.chassis|Types de systèmes matériels|probe:hw.chassis|Répartition des catégories PCSystemTypeEx déclarées par Windows.
by.arch|Architectures Windows|probe:os.arch|Répartition de lʼarchitecture du système dʼexploitation.
by.language|Langues Windows|probe:os.lang|Langue Windows convertie depuis le code de langue fourni.
by.timezone|Fuseaux horaires Windows|probe:os.tz|Libellé du fuseau horaire relevé sur chaque poste.
by.diskmedia|Types du premier disque physique|probe:disk.media|Répartition des types déclarés par le fournisseur Storage.
by.diskhealth|Santé du premier disque physique|probe:disk.health|Répartition des états connus ; ce nʼest pas un test physique du support.
by.encryption|Protection BitLocker C:|probe:sec.bitlocker|État de protection du volume C:, indépendamment de la clé enregistrée dans AD.
by.defender|État de lʼantivirus Defender|probe:sec.defender|Comparer les états connus et les données manquantes, sans assimiler inactif à absence dʼantivirus.
by.dhcp|DHCP et configurations fixes|probe:net.dhcp|Première configuration IP lue par poste.
by.defaultprinter|Imprimantes par défaut|probe:soft.defaultprinter|Regroupe les noms dʼimprimantes par défaut disponibles au relevé.
by.laps|États LAPS visibles|laps|Codes dʼexpiration LAPS visibles dans AD ; aucun secret nʼest exposé.
'@
    foreach($line in ($groups -split "`r?`n")){$p=$line.Split('|');if($p.Count -ne 4){throw 'Répartition de modèle invalide.'};& $make $p[0] $p[1] 'Répartitions' $p[3] @() $p[2]}
    & $make 'active.lowdisk' 'Comptes actifs avec moins de 10 % libre sur C:' 'Vérifications croisées' 'Croise lʼétat AD actif avec un manque dʼespace relevé ; une mesure manquante reste inconnue.' @(
        (& $clause 'active' 'Equal' $true),(& $clause 'diskFreePercent' 'Less' 10))
    & $make 'active.ended' 'Comptes actifs avec support Windows dépassé' 'Vérifications croisées' 'Priorise les comptes actifs dont la fin de support est connue et dépassée, selon le référentiel livré.' @(
        (& $clause 'active' 'Equal' $true),(& $clause 'lifeStatus' 'Equal' 'Ended'))
    & $make 'observed.healthyspace' 'Inventaire récent avec au moins 20 % libre sur C:' 'Vérifications croisées' 'Inventaire réussi de moins dʼun jour et espace libre de prévention ; cela ne constitue pas un diagnostic de santé global.' @(
        (& $clause 'inventoryDays' 'Less' 1),(& $clause 'diskFreePercent' 'GreaterOrEqual' 20))
    & $make 'resource.review' 'Mémoire faible ou disque peu disponible' 'Vérifications croisées' 'Au moins un seuil de revue atteint : RAM inférieure à 8 Go ou espace C: inférieur à 10 %. Ajustez selon lʼusage.' @(
        (& $clause 'ramGB' 'Less' 8),(& $clause 'diskFreePercent' 'Less' 10)) '' 'Any'
}
function ConvertFrom-DomeniaQueryLibrary {
    param([string]$Json='')
    if(-not $Json){return @()}
    if([Text.Encoding]::UTF8.GetByteCount($Json) -gt 1048576){throw 'Bibliothèque de requêtes trop volumineuse (1 Mio maximum en UTF-8).'}
    $library=ConvertFrom-Json -InputObject $Json -ErrorAction Stop
    if([string](Get-DomeniaMember $library 'Format') -cne 'Domenia.QueryLibrary/1'){throw 'Bibliothèque de requêtes non reconnue.'}
    $queries=@(Get-DomeniaMember $library 'Queries' @());if($queries.Count -gt 100){throw '100 requêtes enregistrées au maximum.'}
    $ids=@{}
    foreach($recipe in $queries){
        [void](ConvertTo-DomeniaCompiledQuery $recipe)
        if($ids.ContainsKey([string]$recipe.Id) -or [string]$recipe.Id -like 'template.*'){throw 'Identifiant réservé ou dupliqué.'}
        $ids[[string]$recipe.Id]=$true
    }
    return $queries
}
function ConvertTo-DomeniaQueryLibraryJson {
    param([object[]]$Queries=@())
    $json=ConvertTo-Json -InputObject ([pscustomobject]@{Format='Domenia.QueryLibrary/1';Queries=@($Queries)}) -Depth 8 -Compress
    [void](ConvertFrom-DomeniaQueryLibrary $json)
    return $json
}
function Get-DomeniaQueryProbeIds {
    param($Recipe)
    return @(@(@(Get-DomeniaMember $Recipe 'Clauses' @())+@(Get-DomeniaMember $Recipe 'Refinements' @())+@([pscustomobject]@{Field=[string](Get-DomeniaMember $Recipe 'GroupBy')},[pscustomobject]@{Field=$(if($null -ne (Get-DomeniaMemberValue $Recipe 'ProbeSelection')){'probe:'+([string]$Recipe.ProbeSelection.Key)}else{''})})) | ForEach-Object{[string](Get-DomeniaMember $_ 'Field')} | Where-Object{$_ -like 'probe:*'} | ForEach-Object{$_.Substring(6)} | Select-Object -Unique)
}
function Get-DomeniaQueryCollectionRequirements {
    # Resolve the union once for all recipes on a board. AD-only filters never require an endpoint read.
    param([object[]]$Recipes=@(),[string[]]$ProbeIds=@())
    $fields=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $probes=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($id in $ProbeIds){if($id){[void]$probes.Add($id)}}
    foreach($recipe in $Recipes){
        if($null -eq $recipe){continue}
        foreach($id in @(Get-DomeniaQueryProbeIds $recipe)){[void]$probes.Add($id)}
        foreach($clause in @(@(Get-DomeniaMember $recipe 'Clauses' @())+@(Get-DomeniaMember $recipe 'Refinements' @()))){[void]$fields.Add([string](Get-DomeniaMember $clause 'Field'))}
        [void]$fields.Add([string](Get-DomeniaMember $recipe 'GroupBy'))
    }
    $inventory=$false;$observation=$false
    foreach($field in $fields){
        if($field -in @('model','ramGB','diskFreePercent','uptimeDays','inventoryDays','observedRelease')){$inventory=$true}
        if($field -in @('presence','presenceBucket','user','checkedDays')){$observation=$true}
    }
    return [pscustomobject]@{ProbeIds=@($probes|Sort-Object);Inventory=$inventory;Remote=($inventory -or $observation -or $probes.Count -gt 0)}
}
function ConvertTo-DomeniaQueryRecords {
    param($Fleet,[hashtable]$Observations=@{},[datetime]$NowUtc=[datetime]::UtcNow,[int]$MaxAgeDays=30,$Lifecycle=$null)
    if($null -eq $Observations){$Observations=@{}}
    $groups=@{};foreach($group in @(Get-DomeniaMember $Fleet 'Groups' @())){$groups[[string]$group.gid]=$group}
    $derived=@{}
    foreach($group in $groups.Values){
        $os=([string]$group.os).Trim();if(-not $os){$os='Systeme non renseigne'};$os=$os -replace '^Microsoft ','' -replace 'Professionnel|Professional','Pro'
        $release=Get-DomeniaWindowsRelease -Build ([string]$group.ver) -Caption $os -Lifecycle $Lifecycle -Now $NowUtc
        $derived[[string]$group.gid]=@{osLabel=$os;release=$(if($release.Build){if($release.Label){[string]$release.Label}else{$os+' (build '+[string]$release.Build+')'}}else{'Version non lue'});osFamily=$(if(-not ([string]$group.os).Trim()){'Système non renseigné'}elseif($release.Family -eq 'Server'){'Serveurs'}else{'Postes de travail'});lifeStatus=[string]$release.Status;win10=($os -match '(?i)Windows 10' -and $os -notmatch '(?i)LTSC|LTSB|IoT')}
    }
    $probeFields=@{};foreach($field in @(Get-DomeniaQueryFields | Where-Object{$_.ProbeId})){$probeFields[$field.ProbeId]=$field}
    $probeCatalog=@{};foreach($p in @(Get-DomeniaProbeCatalog)){$probeCatalog[$p.Id]=$p}
    $records=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
    foreach($machine in @(Get-DomeniaMember $Fleet 'Machines' @())){
        $dn=[string]$machine.distinguished_name;$guid=[string]$machine.object_guid
        $v=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $v['presenceBucket']='Non verifie';$v['name']=[string]$machine.name;$v['dn']=$dn;$v['active']=([string]$machine.st -ne 'D')
        $group=$groups[[string]$machine.gid]
        if($null -ne $group){
            foreach($entry in $derived[[string]$group.gid].GetEnumerator()){$v[$entry.Key]=$entry.Value}
            foreach($mapping in @(@('os','os'),@('ver','version'),@('lk','laps'),@('bk','bitlocker'))){$value=[string](Get-DomeniaMember $group $mapping[0]);if($value -and $value -ne 'U'){$v[$mapping[1]]=$value}}
            $v['logonBucket']=[int]$group.lb
            if([string]$group.cr -in @('R','O')){$v['createdRecent']=([string]$group.cr -eq 'R')}
            if([string]$group.pw -in @('R','O')){$v['passwordOld']=([string]$group.pw -eq 'O')}
        }
        $v['site']=Get-DomeniaDnSite -ParentDn (Get-DomeniaRawDnParent $dn) -Scope ([string](Get-DomeniaMember $Fleet 'Scope'))
        $logon=[datetime]::MinValue
        if([datetime]::TryParseExact([string]$machine.logon,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$logon) -and $logon.ToUniversalTime() -le $NowUtc.AddMinutes(5)){$v['logonDays']=[double][Math]::Max(0,($NowUtc-$logon.ToUniversalTime()).TotalDays)}
        $observation=$Observations[$dn.ToLowerInvariant()]
        $observedGuid=[string](Get-DomeniaMember $observation 'Guid')
        # A DN alone cannot attach an observation to a recreated account.
        if($guid -and $observedGuid -and $guid.Trim().Trim('{','}').ToLowerInvariant() -eq $observedGuid.Trim().Trim('{','}').ToLowerInvariant()){
            $checked=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaMember $observation 'CheckedUtc'))
            $usable=($null -ne $checked -and $checked -le $NowUtc.AddMinutes(5) -and ($NowUtc-$checked).TotalDays -le $MaxAgeDays)
            if($usable){
                $v['checkedDays']=[double][Math]::Max(0,($NowUtc-$checked).TotalDays)
                $presence=[string](Get-DomeniaMember $observation 'Presence');if($presence){$v['presence']=$presence}
                $v['presenceBucket']=if($presence -eq 'En ligne'){'En ligne'}elseif($presence -match 'Sans|Erreur|Hors'){'Sans reponse'}else{'Non verifie'}
                $userAt=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaMember $observation 'ObservedUtc'))
                $user=[string](Get-DomeniaMember $observation 'LinkUser')
                if($user -and $null -ne $userAt -and $userAt -le $NowUtc.AddMinutes(5) -and ($NowUtc-$userAt).TotalDays -le $MaxAgeDays){$v['user']=$user}

                $inventory=Get-DomeniaMemberValue $observation 'Inventory'
                $inventoryAt=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaMember $inventory 'CheckedUtc'))
                if($null -ne $inventoryAt -and $inventoryAt -le $NowUtc.AddMinutes(5) -and ($NowUtc-$inventoryAt).TotalDays -le $MaxAgeDays){
                $v['inventoryDays']=[double][Math]::Max(0,($NowUtc-$inventoryAt).TotalDays)
                $model=[string](Get-DomeniaMember $inventory 'Model');$v['model']=if($model){$model}else{'Modele inconnu'}
                $build=[string](Get-DomeniaMember $inventory 'Build')
                $release=(Get-DomeniaWindowsRelease -Build $build -Caption ([string](Get-DomeniaMember $inventory 'OsCaption')) -Lifecycle $Lifecycle -Now $NowUtc).Name
                $v['observedRelease']=if($release){[string]$release}elseif($build){'Build '+$build}else{'Version inconnue'}
                $ram=Get-DomeniaMember $inventory 'RamBytes';if($null -ne $ram -and [double]$ram -gt 0){$v['ramGB']=[double]$ram/1GB}
                $size=Get-DomeniaMember $inventory 'DiskSize';$free=Get-DomeniaMember $inventory 'DiskFree'
                if($null -ne $size -and $null -ne $free -and [double]$size -gt 0 -and [double]$free -ge 0 -and [double]$free -le [double]$size){$v['diskFreePercent']=100.0*[double]$free/[double]$size}
                $boot=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaMember $inventory 'LastBootUtc'))
                if($null -ne $boot -and $boot -le $NowUtc){$v['uptimeDays']=[double]($NowUtc-$boot).TotalDays}
                }
            }
            # A fresh ping must not freshen an older probe. Every probe has its own timestamp.
            $probes=Get-DomeniaMemberValue $observation 'Probes'
            # Visit only measurements actually present. Scanning every catalog field for every machine
            # makes an uncollected 10,000-machine fleet pay for 780,000 missing member lookups.
            $probeIds=if($observation -is [Domenia.Native.Observation]){@($observation.CopyQueryProbesTo($v,$NowUtc,$MaxAgeDays))}elseif($null -eq $probes){@()}elseif($probes -is [Collections.IDictionary]){$probes.Keys}else{$probes.PSObject.Properties.Name}
            foreach($probeId in $probeIds){
                $field=$probeFields[[string]$probeId];if($null -eq $field){continue}
                $result=Get-DomeniaMemberValue $probes $field.ProbeId
                if($null -eq $result -or [string](Get-DomeniaMember $result 'Error') -or [string](Get-DomeniaMember $result 'Skipped')){continue}
                $probeAt=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaMember $result 'CheckedUtc'))
                if($null -eq $probeAt -or $probeAt -gt $NowUtc.AddMinutes(5) -or ($NowUtc-$probeAt).TotalDays -gt $MaxAgeDays){continue}
                $probe=$probeCatalog[$field.ProbeId]
                if([bool](Get-DomeniaMember $result 'Truncated' $false) -and $probe.Mode -eq 'All'){continue}
                $values=@(Get-DomeniaProbeValues -Probe $probe -Result $result)
                if(-not $values.Count){continue}
                $v['_probe:'+$field.ProbeId]=[object[]]$values
                if($field.Kind -eq 'Number'){$number=ConvertTo-DomeniaProbeNumber $values[0];if($null -ne $number){$v[$field.Id]=[double]$number}}
                else{$v[$field.Id]=[string]($values -join ' ; ')}
            }
        }
        $records.Add([M4D.Admin.Common.Query.QueryRecord]::new($(if($guid){$guid.ToLowerInvariant()}else{$dn.ToLowerInvariant()}),$v))
    }
    return ,$records
}
function ConvertTo-DomeniaQueryGridRows {
    param($Rows,[string[]]$Fields=@())
    foreach($record in $Rows){
        $v=$record.Values
        $row=[ordered]@{Id=$record.Id;PresenceLabel=$v['presenceBucket'];PresenceState=$(switch([string]$v['presenceBucket']){'En ligne'{'●'};'Sans reponse'{'○'};default{'?'}});PresenceBrush=$(switch([string]$v['presenceBucket']){'En ligne'{'#22C55E'};'Sans reponse'{'#F59E0B'};default{'#94A3B8'}});name=$v['name'];StateLabel=$(if($v['active']){'Actif'}else{'Désactivé'});OS=$(if($v.ContainsKey('os')){$v['os']}else{'Non renseigné'});Version=$(if($v.ContainsKey('version')){$v['version']}else{'Non lue'});LogonDays=$(if($v.ContainsKey('logonDays')){[Math]::Floor([double]$v['logonDays'])}else{'Inconnue'});Observation=$(if($v.ContainsKey('checkedDays')){([Math]::Round([double]$v['checkedDays'],1).ToString()+' j')}else{'Non recueillie / expirée'});distinguished_name=$v['dn']}
        $details=[Collections.Generic.List[string]]::new()
        foreach($field in $Fields){$value=if($v.ContainsKey($field)){$v[$field]}else{'Inconnu'};$details.Add($field+' = '+[string]$value)}
        $row['QueryValues']=[string]::Join(' · ',$details.ToArray())
        [pscustomobject]$row
    }
}

function Select-DomeniaQueryPopulation {
    param($Records,$Recipe)
    # PowerShell conditionals/pipelines can unwrap a generic list into Object[].
    # The shared DLL requires IEnumerable<QueryRecord>, including empty/singleton
    # populations. Preserve an already typed list and adapt other enumerables once.
    if ($Records -isnot [Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]) {
        $typed=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
        foreach ($record in $Records) { $typed.Add($record) }
        $Records=$typed
    }
    $refinements=@(Get-DomeniaMember $Recipe 'Refinements' @())
    $probeSelection=ConvertTo-DomeniaQueryProbeSelection $Recipe
    $identities=Get-DomeniaQueryIdentitySelection $Recipe
    if(-not $refinements.Count -and $null -eq $probeSelection -and $null -eq $identities){return ,$Records}
    $compiled=ConvertTo-DomeniaCompiledQuery (New-DomeniaQueryRecipe -Clauses $refinements)
    $selected=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
    foreach($record in $Records){
        if($null -ne $identities -and -not $identities.Contains($record.Id.Trim().Trim('{','}'))){continue}
        if(($null -eq $probeSelection -or $probeSelection.Matches($record.Values)) -and $compiled.Evaluate($record.Values) -eq [M4D.Admin.Common.Query.MatchState]::Match){$selected.Add($record)}
    }
    return ,$selected
}
function Get-DomeniaQueryMatchIds {
    param($Records,$Recipe)
    $compiled=ConvertTo-DomeniaCompiledQuery $Recipe
    $refinements=@(Get-DomeniaMember $Recipe 'Refinements' @())
    $refined=if($refinements.Count){ConvertTo-DomeniaCompiledQuery (New-DomeniaQueryRecipe -Clauses $refinements)}else{$null}
    $ids=@{}
    $population=Select-DomeniaQueryPopulation $Records $Recipe
    foreach($record in $population){
        if($null -ne $refined -and $refined.Evaluate($record.Values) -ne [M4D.Admin.Common.Query.MatchState]::Match){continue}
        if($compiled.Evaluate($record.Values) -eq [M4D.Admin.Common.Query.MatchState]::Match){$ids[$record.Id.Trim().Trim('{','}').ToLowerInvariant()]=$true}
    }
    return $ids
}
function Measure-DomeniaQueryWidget {
    param($Records,$Recipe)
    $population=Select-DomeniaQueryPopulation $Records $Recipe
    $query=ConvertTo-DomeniaCompiledQuery $Recipe
    $counts=$query.Execute($population,[M4D.Admin.Common.Query.QueryOptions]@{Limit=0})
    $groupBy=[string](Get-DomeniaMember $Recipe 'GroupBy');$items=@()
    if($groupBy){
        # Bounded distinct categories. Exceeding the bound is explicit, never a silently sampled chart.
        $buckets=@($query.CountBy($population,$groupBy,10000));$known=@($buckets|Where-Object{-not $_.Missing}|Sort-Object Count -Descending)
        $top=@($known|Select-Object -First 10);$items=@(foreach($bucket in $top){[pscustomobject]@{Label=[string]$bucket.Value;Value=[double]$bucket.Count;Select=[pscustomobject]@{Label=[string]$bucket.Value;Field=$groupBy;Missing=$false;Value=$bucket.Value;Excluded=@()}}})
        $others=0L;foreach($bucket in @($known|Select-Object -Skip 10)){$others+=$bucket.Count}
        if($others){$items+=@([pscustomobject]@{Label='Autres valeurs';Value=[double]$others;Select=[pscustomobject]@{Label='Autres valeurs';Field=$groupBy;Missing=$false;Value=$null;Excluded=@($top|ForEach-Object{$_.Value})}})}
        foreach($bucket in @($buckets|Where-Object{$_.Missing})){$items+=@([pscustomobject]@{Label='Valeur inconnue';Value=[double]$bucket.Count;Select=[pscustomobject]@{Label='Valeur inconnue';Field=$groupBy;Missing=$true;Value=$null;Excluded=@()}})}
    }
    return [pscustomobject]@{Total=$counts.Total;Matched=$counts.Matched;Unknown=$counts.Unknown;NotMatched=$counts.NotMatched;GroupBy=$groupBy;Items=$items;Error=''}
}
function New-DomeniaQuerySegmentRecipe {
    param($Recipe,$Selection)
    $refinements=@(Get-DomeniaMember $Recipe 'Refinements' @());$field=[string]$Selection.Field
    if([bool]$Selection.Missing){$refinements+=@([pscustomobject]@{Field=$field;Operator='IsMissing';Value=$null})}
    elseif(@($Selection.Excluded).Count){
        $refinements+=@([pscustomobject]@{Field=$field;Operator='IsPresent';Value=$null})
        foreach($value in @($Selection.Excluded)){$refinements+=@([pscustomobject]@{Field=$field;Operator='NotEqual';Value=$value})}
    }else{$refinements+=@([pscustomobject]@{Field=$field;Operator='Equal';Value=$Selection.Value})}
    $name=[string]$Recipe.Name+' · '+[string]$Selection.Label;if($name.Length -gt 120){$name=$name.Substring(0,120)}
    $result=New-DomeniaQueryRecipe -Name $name -Junction $Recipe.Junction -Clauses @($Recipe.Clauses) -Refinements $refinements -GroupBy ([string](Get-DomeniaMember $Recipe 'GroupBy')) -ProbeSelection (Get-DomeniaMemberValue $Recipe 'ProbeSelection') -ObjectIds (Get-DomeniaMemberValue $Recipe 'ObjectIds')
    [void](ConvertTo-DomeniaCompiledQuery $result)
    return $result
}
