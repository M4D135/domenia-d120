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
    if($null -ne $script:DomeniaQueryInformationCatalog){return $script:DomeniaQueryInformationCatalog}
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
checkedDays|Observation|Présence et console|Évaluer lʼâge du dernier ping enregistré, indépendamment des relevés WMI.|Jours|7|PresenceCheckedUtc
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
        $choices=@()
        if($field.Kind -eq 'Boolean'){$choices=@([pscustomobject]@{Name='Oui';Value=$true},[pscustomobject]@{Name='Non';Value=$false})}
        elseif($field.ProbeId -and [string]$probe.Transform -like 'Map:*'){$choices=@(([string]$probe.Transform).Substring(4).Split(';')|ForEach-Object{($_ -split '=',2)[-1]}|Select-Object -Unique|ForEach-Object{[pscustomobject]@{Name=$_;Value=$_}})}
        else{
            $coded=@{laps=@('O=Valide','E=Expiré','N=Aucun attribut lu','X=Schéma indisponible');bitlocker=@('K=Clé visible','N=Aucune clé visible','X=Indisponible');lifeStatus=@('Ended=Support terminé','Soon=Fin de support prochaine','Ok=Support en cours','Unknown=Cycle inconnu');presenceBucket=@('En ligne=En ligne','Sans reponse=Sans réponse','Non verifie=Non vérifié');osFamily=@('Serveurs=Serveurs','Postes de travail=Postes de travail','Système non renseigné=Système non renseigné')}
            if($coded.ContainsKey([string]$field.Id)){$choices=@($coded[[string]$field.Id]|ForEach-Object{$kv=$_ -split '=',2;[pscustomobject]@{Name=$kv[1];Value=$kv[0]}})}
        }
        $cost=if($sourceId -eq 'Probe' -and $probe.Slow){'Élevé : collecte explicite à cibler'}elseif($sourceId -in @('Probe','Observation')){'Lecture distante ciblée, réutilisation des relevés frais'}else{'Lecture locale, aucun accès aux postes'}
        $freshness=if($sourceId -in @('Probe','Observation')){'Date propre à chaque relevé ; un ping ne rajeunit ni WMI ni les sondes.'}else{'Date de la lecture AD qui a alimenté la base ; recalculer ne rajeunit pas les données.'}
        [pscustomobject]@{Id=[string]$field.Id;Name=[string]$field.Name;Kind=[string]$field.Kind;ProbeId=[string]$field.ProbeId;SourceId=$sourceId;Source=$sources[$sourceId];Category=$category;TypeLabel=$typeLabel;Unit=$unit;Description=$description;Example=$example;Collection=$collection;Availability=$availability;Technical=$technical;Cost=$cost;Freshness=$freshness;Choices=$choices;SearchText=([string]$field.Name+' '+$sources[$sourceId]+' '+$category+' '+$description+' '+$technical)}
    })
    $script:DomeniaQueryInformationCatalog=@($entries|Sort-Object -Property Category,Name,Id -Culture 'fr-FR')
    return $script:DomeniaQueryInformationCatalog
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
    param([string]$Name='Tous les postes recensés',[string]$Id='',[string]$Junction='All',[object[]]$Clauses=@(),[string]$GroupBy='',[object[]]$Refinements=@(),$ProbeSelection=$null,$ObjectIds=$null,[object[]]$Parameters=@(),$ParameterValues=$null,$Expression=$null,$CoherenceHours=$null,$ReadDefinition=$null)
    if(-not $Id){$Id=[guid]::NewGuid().ToString('N')}
    return [pscustomobject]@{Format=$(if($Parameters.Count -or $null -ne $Expression -or $null -ne $CoherenceHours -or $null -ne $ReadDefinition){'Domenia.Query/2'}else{'Domenia.Query/1'});Id=$Id;Name=$Name;Junction=$Junction;Clauses=@($Clauses);GroupBy=$GroupBy;Refinements=@($Refinements);ProbeSelection=$ProbeSelection;ObjectIds=$ObjectIds;Parameters=@($Parameters);ParameterValues=$ParameterValues;Expression=$Expression;CoherenceHours=$CoherenceHours;ReadDefinition=$ReadDefinition}
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
    if([string](Get-DomeniaMember $Recipe 'Format') -cnotin @('Domenia.Query/1','Domenia.Query/2')){throw 'Format de requête non reconnu.'}
    Assert-DomeniaQueryReadDefinition (Get-DomeniaMemberValue $Recipe 'ReadDefinition')
    $Recipe=Resolve-DomeniaQueryParameters $Recipe
    [void](ConvertTo-DomeniaQueryProbeSelection $Recipe)
    [void](Get-DomeniaQueryIdentitySelection $Recipe)
    $name=[string](Get-DomeniaMember $Recipe 'Name');$id=[string](Get-DomeniaMember $Recipe 'Id')
    if(-not $name.Trim() -or $name.Length -gt 120 -or $id -notmatch '^[a-zA-Z0-9_.-]{1,80}$'){throw 'Nom ou identifiant de requête invalide.'}
    $junction=[string](Get-DomeniaMember $Recipe 'Junction')
    if($junction -cnotin @('All','Any')){throw 'Choisir Toutes les conditions ou Au moins une condition.'}
    $definition=[M4D.Admin.Common.Query.QueryDefinition]::new()
    $definition.Junction=[M4D.Admin.Common.Query.QueryJunction]::$junction
    if($null -eq $script:DomeniaQueryCompileFields){
        $definitions=[Collections.Generic.List[M4D.Admin.Common.Query.FieldDefinition]]::new();$byId=@{}
        foreach($field in @(@(Get-DomeniaQueryFields)+@(Get-DomeniaQueryInstanceFields))){$byId[$field.Id]=$field;$definitionField=[M4D.Admin.Common.Query.FieldDefinition]::new($field.Id,[M4D.Admin.Common.Query.FieldKind]::$($field.Kind));$definitionField.ObservationTimestampField=Get-DomeniaQueryTimestampKey $field.Id;$definitions.Add($definitionField)}
        $script:DomeniaQueryCompileFields=[pscustomobject]@{Definitions=$definitions;ById=$byId}
    }
    $definitions=$script:DomeniaQueryCompileFields.Definitions;$byId=$script:DomeniaQueryCompileFields.ById
    $custom=@(Get-DomeniaQueryReadDefinitionFields $Recipe)
    if($custom.Count){
        $definitions=[Collections.Generic.List[M4D.Admin.Common.Query.FieldDefinition]]::new($script:DomeniaQueryCompileFields.Definitions);$byId=$byId.Clone()
        foreach($field in $custom){$byId[$field.Id]=$field;$definitionField=[M4D.Admin.Common.Query.FieldDefinition]::new($field.Id,[M4D.Admin.Common.Query.FieldKind]::$($field.Kind));$definitionField.ObservationTimestampField=Get-DomeniaQueryTimestampKey $field.Id;$definitions.Add($definitionField)}
    }
    $clauses=@(Get-DomeniaMember $Recipe 'Clauses' @())
    $refinements=@(Get-DomeniaMember $Recipe 'Refinements' @());$groupBy=[string](Get-DomeniaMember $Recipe 'GroupBy')
    if($groupBy -and $groupBy -cnotin @($byId.Keys)){throw 'Champ de répartition inconnu.'}
    if($refinements.Count){[void](ConvertTo-DomeniaCompiledQuery (New-DomeniaQueryRecipe -Clauses $refinements -ReadDefinition (Get-DomeniaMemberValue $Recipe 'ReadDefinition')))}
    if(($clauses.Count+$refinements.Count+@(Get-DomeniaQueryExpressionClauses (Get-DomeniaMemberValue $Recipe 'Expression')).Count) -gt 64){throw 'Une requête accepte 64 conditions au maximum.'}
    foreach($clause in $clauses){
        $key=[string](Get-DomeniaMember $clause 'Field');$op=[string](Get-DomeniaMember $clause 'Operator');$value=Get-DomeniaMemberValue $clause 'Value'
        if($key -like 'instance:*'){throw 'Une propriété dʼinstance doit être utilisée dans un groupe de collection.'}
        if(-not $byId.ContainsKey($key) -or $key -cnotin @($byId.Keys)){throw ('Champ inconnu : '+$key)}
        if($op -cnotin @(Get-DomeniaQueryOperators -Kind $byId[$key].Kind | ForEach-Object{$_.Id})){throw ('Opérateur invalide pour '+$byId[$key].Name)}
        if($null -ne $value -and $value -is [psobject]){$value=$value.PSObject.BaseObject}
        $definition.Clauses.Add([M4D.Admin.Common.Query.QueryClause]::new($key,[M4D.Admin.Common.Query.QueryOperator]::$op,$value))
    }
    $tree=Get-DomeniaMemberValue $Recipe 'Expression';if($null -ne $tree){$definition.Expression=ConvertTo-DomeniaQueryExpression -Node $tree -Fields $byId}
    $coherence=Get-DomeniaMemberValue $Recipe 'CoherenceHours';if($null -ne $coherence){$definition.MaximumObservationSpreadSeconds=[double]$coherence*3600}
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
    if($null -ne $script:DomeniaQueryTemplateCatalog){return $script:DomeniaQueryTemplateCatalog}
    $delivered=[Collections.Generic.List[object]]::new();$signatures=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$titles=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $make={param([string]$Id,[string]$Name,[string]$Category,[string]$Description,[object[]]$Clauses=@(),[string]$GroupBy='',[string]$Junction='All',[object[]]$Parameters=@(),$Expression=$null)
        $recipe=New-DomeniaQueryRecipe -Id ('template.'+$Id) -Name $Name -Clauses $Clauses -GroupBy $GroupBy -Junction $Junction -Parameters $Parameters -Expression $Expression
        $signature=$recipe|Select-Object Junction,Clauses,GroupBy,Parameters,Expression|ConvertTo-Json -Depth 12 -Compress
        if($signatures.Contains($signature) -or $titles.Contains($Name)){return}
        [void]$signatures.Add($signature);[void]$titles.Add($Name)
        $recipe|Add-Member -NotePropertyName Category -NotePropertyValue $Category
        $recipe|Add-Member -NotePropertyName Description -NotePropertyValue ($Description+' Évaluation locale des données disponibles ; les valeurs non lues ou périmées restent inconnues.')
        $delivered.Add($recipe)
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
    # Expand only the engine's supported catalog. Each entry answers a distinct coverage,
    # distribution or coded-state question; equivalent legacy recipes retain their IDs.
    foreach($field in @(Get-DomeniaQueryCatalog)){
        $key=([string]$field.Id).ToLowerInvariant().Replace(':','.')
        $label=[string]$field.Name
        foreach($pair in @(@('missing','valeur inconnue','IsMissing'),@('present','valeur disponible','IsPresent'))){
            & $make ('catalog.'+$key+'.'+$pair[0]) ($label+' : '+$pair[1]) 'Couverture des informations' ('Vérifier la couverture de « '+$label+' ». Une valeur inconnue peut être non lue, expirée, refusée ou incomplète ; consultez la fiche locale pour préciser la cause.') @((& $clause $field.Id $pair[2] $null))
        }
        if($field.Kind -ne 'Number' -and $field.Id -notin @('name','dn','user','site')){
            & $make ('catalog.'+$key+'.distribution') ($label+' : répartition') 'Répartitions détaillées' ('Répartir les postes par « '+$label+' », avec une catégorie séparée pour les valeurs inconnues. Source : '+$field.Source+'.') @() $field.Id
        }
        $choiceIndex=0
        foreach($choice in @($field.Choices)){
            $choiceIndex++
            & $make ('catalog.'+$key+'.state'+$choiceIndex) ($label+' : '+$choice.Name) ('États · '+$field.Category) ('Repérer la valeur « '+$choice.Name+' » de « '+$label+' ». La condition porte sur le relevé ou attribut enregistré et ne déclenche aucune lecture distante.') @((& $clause $field.Id 'Equal' $choice.Value))
        }
    }
    $thresholds=@'
ramGB|8,16,32
diskFreePercent|5,10,20
uptimeDays|7,30,90
checkedDays|1,7,14
inventoryDays|1,7,14
logonDays|30,90,180
probe:hw.ram|4,8,16,32
probe:hw.cores|2,4,8
probe:hw.threads|4,8,16
probe:hw.cpuload|80,90
probe:hw.batterylevel|20,50
probe:os.uptime|7,30,90
probe:os.freeram|1,2,4
probe:disk.cfree|5,10,20
probe:disk.csize|128,256,512
probe:sec.signatures|1,3,7
probe:sec.quickscan|7,14,30
probe:sec.fullscan|7,30,90
probe:net.speed|100,1000
'@
    $fieldMap=@{};foreach($field in @(Get-DomeniaQueryCatalog)){$fieldMap[$field.Id]=$field}
    foreach($line in ($thresholds -split "`r?`n")){
        $parts=$line.Split('|');$field=$fieldMap[$parts[0]];if($null -eq $field -or $field.Kind -ne 'Number'){throw 'Seuil sans information numérique prise en charge.'}
        foreach($number in $parts[1].Split(',')){
            foreach($pair in @(@('lt','moins de','Less'),@('ge','au moins','GreaterOrEqual'))){
                $key=([string]$field.Id).ToLowerInvariant().Replace(':','.')+'.'+$pair[0]+$number
                & $make ('threshold.'+$key) ($field.Name+' : '+$pair[1]+' '+$number+' '+$field.Unit) ('Seuils · '+$field.Category) ('Seuil de triage pour « '+$field.Name+' », à adapter aux usages ; une information manquante ne vaut jamais zéro. '+$field.Freshness) @((& $clause $field.Id $pair[2] ([decimal]::Parse($number,[Globalization.CultureInfo]::InvariantCulture))))
            }
        }
    }
    # Parameterised models (point 65): threshold, software, version, OU and period come from the typed form. Each
    # default is an editable example; the bounds keep the entry within a meaningful range.
    $parameter={param([string]$Name,[string]$Field,$Default,[string]$Label,$Minimum=$null,$Maximum=$null)
        $definition=[pscustomobject]@{Name=$Name;Field=$Field;Default=$Default;Label=$Label}
        if($null -ne $Minimum){$definition|Add-Member -NotePropertyName Minimum -NotePropertyValue $Minimum}
        if($null -ne $Maximum){$definition|Add-Member -NotePropertyName Maximum -NotePropertyValue $Maximum}
        $definition
    }
    $use={param([string]$Name)[pscustomobject]@{Parameter=$Name}}
    & $make 'param.diskfree' 'C: : espace libre sous un seuil à choisir' 'Modèles paramétrés' 'Seuil dʼespace libre sur C: saisi dans le formulaire des paramètres, 10 % par défaut ; une mesure absente ou expirée nʼest jamais assimilée à zéro.' @((& $clause 'diskFreePercent' 'Less' (& $use 'Seuil'))) '' 'All' @((& $parameter 'Seuil' 'diskFreePercent' ([decimal]10) 'Espace libre minimal sur C:' ([decimal]0) ([decimal]100)))
    & $make 'param.ram' 'Mémoire installée sous un seuil à choisir' 'Modèles paramétrés' 'Seuil de mémoire installée saisi dans le formulaire (8 Go par défaut, Mo et To acceptés) ; le dernier inventaire léger utilisable fournit la valeur.' @((& $clause 'ramGB' 'Less' (& $use 'Memoire'))) '' 'All' @((& $parameter 'Memoire' 'ramGB' ([decimal]8) 'Mémoire installée minimale' ([decimal]0) ([decimal]4096)))
    & $make 'param.logon' 'Comptes actifs sans connexion AD depuis une période à choisir' 'Modèles paramétrés' 'Période saisie en jours (90 par défaut) appliquée à la date AD répliquée lastLogonTimestamp, approximative ; une date absente reste inconnue et ne prouve aucune inactivité.' @((& $clause 'active' 'Equal' $true),(& $clause 'logonDays' 'GreaterOrEqual' (& $use 'Periode'))) '' 'All' @((& $parameter 'Periode' 'logonDays' ([decimal]90) 'Période sans connexion AD' ([decimal]1) ([decimal]3650)))
    & $make 'param.inventory' 'Inventaire plus ancien quʼune période à choisir' 'Modèles paramétrés' 'Âge maximal de lʼinventaire léger saisi en jours ou en heures (7 jours par défaut) ; un inventaire expiré ou jamais lu reste inconnu.' @((& $clause 'inventoryDays' 'Greater' (& $use 'Periode'))) '' 'All' @((& $parameter 'Periode' 'inventoryDays' ([decimal]7) 'Âge maximal de lʼinventaire' ([decimal]0) ([decimal]3650)))
    & $make 'param.ou' 'Postes dont le chemin AD contient une OU à choisir' 'Modèles paramétrés' 'Partie du chemin AD saisie dans le formulaire ou reprise de lʼOU du tableau de bord ; OU=Postes est un exemple à remplacer, la comparaison reste littérale.' @((& $clause 'dn' 'Contains' (& $use 'OU'))) '' 'All' @((& $parameter 'OU' 'dn' 'OU=Postes' 'Partie du chemin AD (OU)'))
    & $make 'param.release' 'Version Windows relevée à choisir' 'Modèles paramétrés' 'Version commerciale cherchée dans lʼinventaire du poste (24H2 par défaut), distincte du système déclaré dans AD ; un poste non inventorié reste inconnu.' @((& $clause 'observedRelease' 'Contains' (& $use 'Version'))) '' 'All' @((& $parameter 'Version' 'observedRelease' '24H2' 'Version Windows relevée'))
    $serviceTree=[pscustomobject]@{Kind='All';Children=@([pscustomobject]@{Kind='Collection';CollectionField='probe:soft.servicedetails';Quantifier='Any';Children=@([pscustomobject]@{Kind='All';Children=@([pscustomobject]@{Kind='Clause';Clause=(& $clause 'instance:soft.servicedetails:Name' 'Equal' (& $use 'Service'))})})})}
    & $make 'param.service' 'Service Windows présent, nom à choisir' 'Modèles paramétrés' 'Cherche le nom court saisi (Spooler par défaut) dans la liste détaillée des services du poste, relevée par une collecte explicite ; une liste incomplète ou non lue reste inconnue.' @() '' 'All' @((& $parameter 'Service' 'instance:soft.servicedetails:Name' 'Spooler' 'Nom court du service Windows')) $serviceTree
    $script:DomeniaQueryTemplateCatalog=$delivered.ToArray()
    return $script:DomeniaQueryTemplateCatalog
}
function ConvertFrom-DomeniaQueryLibrary {
    param([string]$Json='')
    if(-not $Json){return @()}
    if([Text.Encoding]::UTF8.GetByteCount($Json) -gt 16777216){throw 'Bibliothèque de requêtes trop volumineuse (16 Mio maximum en UTF-8).'}
    $library=ConvertFrom-Json -InputObject $Json -ErrorAction Stop
    if([string](Get-DomeniaMember $library 'Format') -cne 'Domenia.QueryLibrary/1'){throw 'Bibliothèque de requêtes non reconnue.'}
    $queries=@(Get-DomeniaMember $library 'Queries' @());if($queries.Count -gt 5000){throw '5 000 requêtes personnelles au maximum dans la bibliothèque locale.'}
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
    $json=ConvertTo-Json -InputObject ([pscustomobject]@{Format='Domenia.QueryLibrary/1';Queries=@($Queries)}) -Depth 32 -Compress
    [void](ConvertFrom-DomeniaQueryLibrary $json)
    return $json
}
function Get-DomeniaQueryProbeIds {
    param($Recipe)
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($field in @(Get-DomeniaQueryRequestedFields $Recipe)){
        if($field -like 'probe:*'){[void]$ids.Add($field.Substring(6))}
        elseif($field -like 'instance:*'){[void]$ids.Add(($field.Split(':'))[1])}
    }
    return @($ids|Sort-Object)
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
        foreach($field in @(Get-DomeniaQueryRequestedFields $recipe)){[void]$fields.Add($field)}
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
    $dateSources=@{name=@('Name');dn=@('DN');active=@('State');os=@('Details.operatingsystem');version=@('Details.operatingsystemversion');osLabel=@('Details.operatingsystem');release=@('Details.operatingsystem','Details.operatingsystemversion');osFamily=@('Details.operatingsystem');lifeStatus=@('Details.operatingsystem','Details.operatingsystemversion');win10=@('Details.operatingsystem');site=@('DN');logonDays=@('LastLogon');logonBucket=@('LastLogon');createdRecent=@('Details.whencreated');passwordOld=@('Details.pwdlastset');laps=@('Details.ms-mcs-admpwdexpirationtime','Details.mslaps-passwordexpirationtime')}
    $dateCache=@{}
    foreach($machine in @(Get-DomeniaMember $Fleet 'Machines' @())){
        $dn=[string]$machine.distinguished_name;$guid=[string]$machine.object_guid
        $v=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $v['presenceBucket']='Non verifie';$v['name']=[string]$machine.name;$v['dn']=$dn
        $fieldTimes=Get-DomeniaMemberValue $machine 'FieldTimes'
        if($null -eq $fieldTimes){
            $dateJson=[string](Get-DomeniaMember $machine 'FieldTimesJson')
            if($dateJson -and $dateJson.Length -le 65536){
                if($dateCache.ContainsKey($dateJson)){$fieldTimes=$dateCache[$dateJson]}
                else{try{$fieldTimes=ConvertFrom-Json -InputObject $dateJson -ErrorAction Stop}catch{$fieldTimes=$null};if($dateCache.Count -lt 256){$dateCache[$dateJson]=$fieldTimes}}
            }
        }
        foreach($dateField in $dateSources.Keys){$known=$true;$oldest=$null;foreach($source in $dateSources[$dateField]){$at=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaMember $fieldTimes $source));if($null -eq $at){$known=$false;break};if($null -eq $oldest -or $at -lt $oldest){$oldest=$at}};if($known -and $null -ne $oldest){$v['_at:field:'+$dateField]=$oldest.ToUniversalTime().ToString('o')}}

        if([string]$machine.st -in @('A','D')){$v['active']=([string]$machine.st -eq 'A')}
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
            # Ping owns this date. A fresh inventory or failed CIM attempt must never renew presence.
            $checked=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaMember $observation 'PresenceCheckedUtc'))
            $v['_at:presence']=[string](Get-DomeniaMember $observation 'PresenceCheckedUtc')
            if($null -ne $checked -and ($NowUtc-$checked).TotalDays -gt $MaxAgeDays){$v['_quality:presence']='Expiré';$v['_quality:checkedDays']='Expiré'}
            $usable=($null -ne $checked -and $checked -le $NowUtc.AddMinutes(5) -and ($NowUtc-$checked).TotalDays -le $MaxAgeDays)
            if($usable){
                $v['checkedDays']=[double][Math]::Max(0,($NowUtc-$checked).TotalDays)
                $presence=[string](Get-DomeniaMember $observation 'Presence');if($presence){$v['presence']=$presence}
                $v['presenceBucket']=if($presence -eq 'En ligne'){'En ligne'}elseif($presence -match '^(Sans r[eé]ponse(?: au ping)?|Hors ligne)$'){'Sans reponse'}else{'Non verifie'}
                if($presence -match '^(Erreur|Error)'){$v['_quality:presence']='Erreur de lecture'}
            }
            # Console, inventory and ping are independent channels, each with its own source date.
                $userAt=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaMember $observation 'ObservedUtc'))
                $v['_at:console']=[string](Get-DomeniaMember $observation 'ObservedUtc')
                if($null -ne $userAt -and ($NowUtc-$userAt).TotalDays -gt $MaxAgeDays){$v['_quality:user']='Expiré'}
                $user=[string](Get-DomeniaMember $observation 'LinkUser')
                if($user -and $null -ne $userAt -and $userAt -le $NowUtc.AddMinutes(5) -and ($NowUtc-$userAt).TotalDays -le $MaxAgeDays){$v['user']=$user}

                $inventory=Get-DomeniaMemberValue $observation 'Inventory'
                $inventoryAt=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaMember $inventory 'CheckedUtc'))
                $v['_at:inventory']=[string](Get-DomeniaMember $inventory 'CheckedUtc')
                $inventoryState=if([string](Get-DomeniaMember $observation 'InventoryError')){'Erreur au dernier relevé'}elseif($null -ne $inventoryAt -and ($NowUtc-$inventoryAt).TotalDays -gt $MaxAgeDays){'Expiré'}else{''}
                if($inventoryState){foreach($id in @('inventoryDays','model','observedRelease','ramGB','diskFreePercent','uptimeDays')){$v['_quality:'+$id]=$inventoryState}}
                if($null -ne $inventoryAt -and $inventoryAt -le $NowUtc.AddMinutes(5) -and ($NowUtc-$inventoryAt).TotalDays -le $MaxAgeDays){
                $v['inventoryDays']=[double][Math]::Max(0,($NowUtc-$inventoryAt).TotalDays)
                $model=[string](Get-DomeniaMember $inventory 'Model');if($model){$v['model']=$model}
                $build=[string](Get-DomeniaMember $inventory 'Build')
                $release=(Get-DomeniaWindowsRelease -Build $build -Caption ([string](Get-DomeniaMember $inventory 'OsCaption')) -Lifecycle $Lifecycle -Now $NowUtc).Name
                if($release){$v['observedRelease']=[string]$release}elseif($build){$v['observedRelease']='Build '+$build}
                $ram=Get-DomeniaMember $inventory 'RamBytes';if($null -ne $ram -and [double]$ram -gt 0){$v['ramGB']=[double]$ram/1GB}
                $size=Get-DomeniaMember $inventory 'DiskSize';$free=Get-DomeniaMember $inventory 'DiskFree'
                if($null -ne $size -and $null -ne $free -and [double]$size -gt 0 -and [double]$free -ge 0 -and [double]$free -le [double]$size){$v['diskFreePercent']=100.0*[double]$free/[double]$size}
                $boot=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaMember $inventory 'LastBootUtc'))
                if($null -ne $boot -and $boot -le $NowUtc){$v['uptimeDays']=[double]($NowUtc-$boot).TotalDays}
                }
            # A fresh ping must not freshen an older probe. Every probe has its own timestamp.
            $probes=Get-DomeniaMemberValue $observation 'Probes'
            # Visit only measurements actually present. Scanning every catalog field for every machine
            # makes an uncollected 10,000-machine fleet pay for 780,000 missing member lookups.
            if($observation -is [Domenia.Native.Observation]){[void]$observation.CopyQueryProbesTo($v,$NowUtc,$MaxAgeDays)}
            $probeIds=if($null -eq $probes){@()}elseif($probes -is [Collections.IDictionary]){$probes.Keys}else{$probes.PSObject.Properties.Name}
            foreach($probeId in $probeIds){
                $field=$probeFields[[string]$probeId];if($null -eq $field){continue}
                $result=Get-DomeniaMemberValue $probes $field.ProbeId
                if($null -eq $result){continue}
                $v['_at:'+$field.Id]=[string](Get-DomeniaMember $result 'CheckedUtc')
                if([string](Get-DomeniaMember $result 'Error')){$v['_quality:'+$field.Id]='Erreur de lecture';continue}
                if([string](Get-DomeniaMember $result 'Skipped')){$v['_quality:'+$field.Id]='Non applicable / ignoré';continue}
                $probeAt=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaMember $result 'CheckedUtc'))
                if($null -eq $probeAt -or $probeAt -gt $NowUtc.AddMinutes(5)){$v['_quality:'+$field.Id]='Date de relevé inconnue';continue}
                if(($NowUtc-$probeAt).TotalDays -gt $MaxAgeDays){$v['_quality:'+$field.Id]='Expiré';continue}
                $probe=$probeCatalog[$field.ProbeId]
                $v['_instances:'+$field.Id]=ConvertTo-DomeniaQueryInstances -Probe $probe -Result $result
                if([bool](Get-DomeniaMember $result 'Truncated' $false) -and $probe.Mode -ne 'Count'){$v['_quality:'+$field.Id]='Lecture incomplète';continue}
                if($probe.Mode -eq 'Count' -and $null -ne (Get-DomeniaMemberValue $result 'CountComplete') -and -not [bool]$result.CountComplete){[void]$v.Remove($field.Id);[void]$v.Remove('_probe:'+$field.ProbeId);$v['_quality:'+$field.Id]='Lecture incomplète';continue}
                if($probe.Mode -eq 'Count' -and $null -eq (Get-DomeniaMemberValue $result 'Count')){$v['_quality:'+$field.Id]='Non lu';continue}
                if($v.ContainsKey($field.Id)){continue} # Already projected by the native observation adapter.
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
function Get-DomeniaQueryValuePresentation {
    param($Record,[string]$Field)
    $v=$Record.Values;$known=$v.ContainsKey($Field)
    $state=if($v.ContainsKey('_quality:'+$Field)){[string]$v['_quality:'+$Field]}elseif($known){'Disponible'}else{'Non lu'}
    if($known -and $state -ne 'Disponible'){$state='Disponible · '+$state}
    $timestampKey=Get-DomeniaQueryTimestampKey $Field
    $at=if($v.ContainsKey($timestampKey)){ConvertFrom-DomeniaUtcText ([string]$v[$timestampKey])}else{$null}
    [pscustomobject]@{Known=$known;Value=$(if($known){[string]$v[$Field]}else{$state});State=$state;ObservedAt=$(if($null -ne $at){$at.ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss')}else{'Date non disponible'})}
}
function ConvertTo-DomeniaQueryGridRows {
    param($Rows,[string[]]$Fields=@())
    foreach($record in $Rows){
        $v=$record.Values
        $row=[ordered]@{Id=$record.Id;PresenceLabel=$v['presenceBucket'];PresenceState=$(switch([string]$v['presenceBucket']){'En ligne'{'●'};'Sans reponse'{'○'};default{'?'}});PresenceBrush=$(switch([string]$v['presenceBucket']){'En ligne'{'#22C55E'};'Sans reponse'{'#F59E0B'};default{'#94A3B8'}});name=$v['name'];StateLabel=$(if(-not $v.ContainsKey('active')){'Non lu'}elseif($v['active']){'Actif'}else{'Désactivé'});OS=$(if($v.ContainsKey('os')){$v['os']}else{'Non renseigné'});Version=$(if($v.ContainsKey('version')){$v['version']}else{'Non lue'});LogonDays=$(if($v.ContainsKey('logonDays')){[Math]::Floor([double]$v['logonDays'])}else{'Inconnue'});Observation=$(if($v.ContainsKey('checkedDays')){([Math]::Round([double]$v['checkedDays'],1).ToString()+' j')}else{'Non recueillie / expirée'});distinguished_name=$v['dn']}
        $details=[Collections.Generic.List[string]]::new()
        foreach($field in $Fields){$value=Get-DomeniaQueryValuePresentation -Record $record -Field $field;$details.Add($field+' = '+[string]$value.Value)}
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
    $Recipe=Resolve-DomeniaQueryParameters $Recipe
    $refinements=@(Get-DomeniaMember $Recipe 'Refinements' @())
    $probeSelection=ConvertTo-DomeniaQueryProbeSelection $Recipe
    $identities=Get-DomeniaQueryIdentitySelection $Recipe
    if(-not $refinements.Count -and $null -eq $probeSelection -and $null -eq $identities){return ,$Records}
    $compiled=ConvertTo-DomeniaCompiledQuery (New-DomeniaQueryRecipe -Clauses $refinements -ReadDefinition (Get-DomeniaMemberValue $Recipe 'ReadDefinition'))
    $selected=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
    foreach($record in $Records){
        if($null -ne $identities -and -not $identities.Contains($record.Id.Trim().Trim('{','}'))){continue}
        if(($null -eq $probeSelection -or $probeSelection.Matches($record.Values)) -and $compiled.Evaluate($record.Values) -eq [M4D.Admin.Common.Query.MatchState]::Match){$selected.Add($record)}
    }
    return ,$selected
}
function Get-DomeniaQueryMatchIds {
    param($Records,$Recipe)
    $Recipe=Resolve-DomeniaQueryParameters $Recipe
    $compiled=ConvertTo-DomeniaCompiledQuery $Recipe
    $refinements=@(Get-DomeniaMember $Recipe 'Refinements' @())
    $refined=if($refinements.Count){ConvertTo-DomeniaCompiledQuery (New-DomeniaQueryRecipe -Clauses $refinements -ReadDefinition (Get-DomeniaMemberValue $Recipe 'ReadDefinition'))}else{$null}
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
        $buckets=@($query.CountBy($population,$groupBy,100000));$known=@($buckets|Where-Object{-not $_.Missing}|Sort-Object Count -Descending)
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
    $result=New-DomeniaQueryRecipe -Name $name -Junction $Recipe.Junction -Clauses @($Recipe.Clauses) -Refinements $refinements -GroupBy ([string](Get-DomeniaMember $Recipe 'GroupBy')) -ProbeSelection (Get-DomeniaMemberValue $Recipe 'ProbeSelection') -ObjectIds (Get-DomeniaMemberValue $Recipe 'ObjectIds') -Parameters @(Get-DomeniaMember $Recipe 'Parameters' @()) -ParameterValues (Get-DomeniaMemberValue $Recipe 'ParameterValues') -Expression (Get-DomeniaMemberValue $Recipe 'Expression') -CoherenceHours (Get-DomeniaMemberValue $Recipe 'CoherenceHours') -ReadDefinition (Get-DomeniaMemberValue $Recipe 'ReadDefinition')
    [void](ConvertTo-DomeniaCompiledQuery $result)
    return $result
}

function ConvertTo-DomeniaQueryNumber {
    param([string]$Text,[string]$Field)
    $entry=@(@(Get-DomeniaQueryCatalog)+@(Get-DomeniaQueryInstanceFields)|Where-Object{$_.Id -ceq $Field})
    if($entry.Count -ne 1 -or $entry[0].Kind -ne 'Number'){throw 'Cette information ne reçoit pas de valeur numérique.'}
    $match=[regex]::Match($Text.Trim(),'^(?<n>[+-]?(?:[0-9]+(?:[.,][0-9]*)?|[.,][0-9]+)(?:[eE][+-]?[0-9]+)?)\s*(?<u>[%\p{L}/]+)?$')
    $number=[decimal]0
    if(-not $match.Success -or -not [decimal]::TryParse($match.Groups['n'].Value.Replace(',','.'),[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)){throw 'Saisissez un nombre fini, par exemple 8 Go ou 10,5.'}
    $suffix=$match.Groups['u'].Value.ToLowerInvariant();$unit=[string]$entry[0].Unit
    if(-not $suffix){return $number}
    # Divide the original decimal, not a rounded reciprocal (48 h must equal exactly2 days).
    if($unit -eq 'Jours' -and $suffix -in @('h','heure','heures')){return [decimal]($number/24)}
    if($unit -eq 'Jours' -and $suffix -in @('min','minute','minutes')){return [decimal]($number/1440)}
    $scales=@{}
    switch($unit){
        'Go'{$scales=@{go=1;gb=1;gio=1;gib=1;mo=([decimal]1/1024);mb=([decimal]1/1024);mio=([decimal]1/1024);mib=([decimal]1/1024);to=1024;tb=1024;tio=1024;tib=1024}}
        'Mo'{$scales=@{mo=1;mb=1;mio=1;mib=1;go=1024;gb=1024;gio=1024;gib=1024;ko=([decimal]1/1024);kb=([decimal]1/1024)}}
        'Jours'{$scales=@{j=1;jour=1;jours=1;d=1;day=1;days=1;h=([decimal]1/24);heure=([decimal]1/24);heures=([decimal]1/24);min=([decimal]1/1440);minute=([decimal]1/1440);minutes=([decimal]1/1440)}}
        '%'{$scales=@{'%'=1;pourcent=1}}
        'Mbit/s'{$scales=@{'mbit/s'=1;mbps=1;'gbit/s'=1000;gbps=1000;'kbit/s'=([decimal]1/1000);kbps=([decimal]1/1000)}}
        'MHz'{$scales=@{mhz=1;ghz=1000}}
    }
    if(-not $scales.ContainsKey($suffix)){throw ('Unité incompatible : '+$suffix+'. Unité attendue : '+$unit+'.')}
    return [decimal]($number*[decimal]$scales[$suffix])
}
function Get-DomeniaQueryNumberPreview {
    # Live check of a typed number: the converted canonical value with its unit, or the reason it is refused.
    param([string]$Text,[string]$Field)
    if(-not ([string]$Text).Trim()){return [pscustomobject]@{Valid=$false;Value=$null;Text=''}}
    try{$value=ConvertTo-DomeniaQueryNumber -Text $Text -Field $Field}catch{return [pscustomobject]@{Valid=$false;Value=$null;Text=[string]$_.Exception.Message}}
    $entry=@(@(Get-DomeniaQueryCatalog)+@(Get-DomeniaQueryInstanceFields)|Where-Object{$_.Id -ceq $Field}|Select-Object -First 1)
    $shown=Format-DomeniaQueryValueLabel -Value $value -Field $(if($entry.Count){$entry[0]}else{$null})
    $typed=([string]$Text).Trim()
    $message=if($typed -match '[%\p{L}/]\s*$' -and $typed -cne $shown){$typed+' = '+$shown}else{'Valeur retenue : '+$shown}
    return [pscustomobject]@{Valid=$true;Value=$value;Text=$message}
}
function Get-DomeniaQueryExplanation {
    param($Record,$Recipe)
    $Recipe=Resolve-DomeniaQueryParameters $Recipe
    $fields=Get-DomeniaQueryFieldMap $Recipe
    foreach($section in @('Clauses','Refinements')){
        $index=0
        foreach($clause in @(Get-DomeniaMember $Recipe $section @())){
            $index++;$single=New-DomeniaQueryRecipe -Clauses @($clause) -ReadDefinition (Get-DomeniaMemberValue $Recipe 'ReadDefinition');$compiled=ConvertTo-DomeniaCompiledQuery $single
            $verdict=[string]$compiled.Evaluate($Record.Values);$id=[string]$clause.Field;$value=Get-DomeniaQueryValuePresentation $Record $id
            $shown=if($value.Known){Format-DomeniaQueryValueLabel -Value $Record.Values[$id] -Field $fields[$id] -Bare}else{$value.Value}
            [pscustomobject]@{Condition=($(if($section -eq 'Refinements'){'Segment ET · '}else{''})+$index+'. '+(Get-DomeniaQueryClauseLabel -Clause $clause -Fields $fields));Value=$shown;Verdict=$(switch($verdict){Match{'Vrai'};NoMatch{'Faux'};default{'Inconnu'}});State=$value.State;ObservedAt=$value.ObservedAt}
        }
    }
    $tree=Get-DomeniaMemberValue $Recipe 'Expression'
    foreach($node in @(Get-DomeniaQueryExpressionOutline -Node $tree -Fields $fields)){
        if($node.CollectionProbe){continue}
        $single=New-DomeniaQueryRecipe -Expression $node.Node -ReadDefinition (Get-DomeniaMemberValue $Recipe 'ReadDefinition')
        $verdict=[string](ConvertTo-DomeniaCompiledQuery $single).Evaluate($Record.Values)
        $value=if($node.Kind -eq 'Clause'){
            $id=[string]$node.Node.Clause.Field;$presentation=Get-DomeniaQueryValuePresentation $Record $id
            if($presentation.Known){$presentation.Value=Format-DomeniaQueryValueLabel -Value $Record.Values[$id] -Field $fields[$id] -Bare}
            $presentation
        }elseif($node.Kind -eq 'Collection'){
            # The workshop keeps only the per-node verdict and its provenance; raw instances exist only in direct reads.
            $infoKey='_exprinfo:'+(Get-DomeniaQueryExpressionKey $node.Node);$info=if($Record.Values.ContainsKey($infoKey)){$Record.Values[$infoKey]}else{$null}
            $key='_instances:'+([string]$node.Node.CollectionField);$collection=if($Record.Values.ContainsKey($key)){$Record.Values[$key]}else{$null}
            if($null -ne $info){
                $checked=ConvertFrom-DomeniaUtcText ([string]$info.CheckedUtc)
                [pscustomobject]@{Value=([string]$info.InstanceCount+' instance(s) examinée(s)');State=[string]$info.Coverage;ObservedAt=$(if($null -ne $checked){$checked.ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss')}else{'Date non disponible'})}
            }else{
                [pscustomobject]@{Value=$(if($null -ne $collection){[string]$collection.Instances.Count+' instance(s) mémorisée(s)'}else{'Non lu'});State=$(if($null -eq $collection){'Non lu'}elseif($collection.Complete){'Collecte complète'}else{'Collecte partielle'});ObservedAt=(Get-DomeniaQueryValuePresentation $Record ([string]$node.Node.CollectionField)).ObservedAt}
            }
        }else{[pscustomobject]@{Value='Verdicts des sous-conditions';State='Calcul local';ObservedAt=''}}
        [pscustomobject]@{Condition=$node.Label;Value=$value.Value;Verdict=$(switch($verdict){Match{'Vrai'};NoMatch{'Faux'};default{'Inconnu'}});State=$value.State;ObservedAt=$value.ObservedAt}
    }
    if($null -ne (Get-DomeniaMemberValue $Recipe 'CoherenceHours')){
        $coverage=Measure-DomeniaQueryCoverage -Records @($Record) -Recipe $Recipe -CoherenceHours ([double]$Recipe.CoherenceHours)
        [pscustomobject]@{Condition=('Écart des dates sources ≤ '+[string]$Recipe.CoherenceHours+' h');Value=$(if($coverage.Undated){'Une date source manque'}elseif($coverage.MixedPeriod){'Mesures prises à des périodes différentes'}else{'Dates compatibles'});Verdict=$(if($coverage.Undated -or $coverage.MixedPeriod){'Inconnu'}else{'Vrai'});State='Cohérence temporelle';ObservedAt=''}
    }

}
function Measure-DomeniaQueryCoverage {
    param($Records,$Recipe,[double]$CoherenceHours=24)
    if($CoherenceHours -le 0 -or $CoherenceHours -gt 8760){throw 'Fenêtre de cohérence invalide (plus de 0 et au plus 8 760 heures).'}
    $byId=@{};foreach($entry in @(@(Get-DomeniaQueryCatalog)+@(Get-DomeniaQueryInstanceFields)+@(Get-DomeniaQueryReadDefinitionFields $Recipe))){$byId[$entry.Id]=$entry}
    $fields=@(foreach($id in @(Get-DomeniaQueryRequestedFields $Recipe)){
        if(-not $byId.ContainsKey($id)){throw ('Champ de couverture inconnu : '+$id)}
        [pscustomobject]@{Id=$id;Name=$byId[$id].Name;Available=0L;Expired=0L;Error=0L;Partial=0L;Unread=0L;Source=[string](Get-DomeniaMember $byId[$id] 'Source')}
    })
    $identities=Get-DomeniaQueryIdentitySelection $Recipe;$total=0L;$complete=0L;$mixed=0L;$undated=0L
    foreach($record in $Records){
        if($null -ne $identities -and -not $identities.Contains($record.Id.Trim().Trim('{','}'))){continue}
        $total++;$all=$true;$earliest=$null;$latest=$null;$missingDate=$false
        foreach($field in $fields){
            $id=[string]$field.Id;$v=$record.Values;$known=$v.ContainsKey($id);$partial=$false;$qualityKey=$id
            if($id -like 'instance:*'){
                $probeId=($id.Split(':'))[1];$qualityKey='probe:'+$probeId;$key='_instances:probe:'+$probeId
                if($v.ContainsKey($key)){
                    $collection=$v[$key];$known=[bool]$collection.Complete;$partial=(-not $known)
                    foreach($instance in $collection.Instances){if(-not $instance.Values.ContainsKey($id) -or $instance.Values.ContainsKey('_unknown:'+$id)){$known=$false;$partial=$true;break}}
                }
            }
            if($known){$field.Available++}else{
                $all=$false;$quality=if($v.ContainsKey('_quality:'+$qualityKey)){[string]$v['_quality:'+$qualityKey]}else{''}
                if($partial){$field.Partial++}else{switch($quality){'Expiré'{$field.Expired++};'Erreur de lecture'{$field.Error++};'Lecture incomplète'{$field.Partial++};default{$field.Unread++}}}
            }
            $dateKey=Get-DomeniaQueryTimestampKey $id
            $date=if($v.ContainsKey($dateKey)){ConvertFrom-DomeniaUtcText ([string]$v[$dateKey])}else{$null}
            if($null -ne $date){if($null -eq $earliest -or $date -lt $earliest){$earliest=$date};if($null -eq $latest -or $date -gt $latest){$latest=$date}}else{$missingDate=$true}
        }
        if($all){$complete++};if($missingDate){$undated++}
        if($null -ne $earliest -and $null -ne $latest -and ($latest-$earliest).TotalHours -gt $CoherenceHours){$mixed++}
    }
    [pscustomobject]@{Rows=$fields;Total=$total;Complete=$complete;Incomplete=($total-$complete);MixedPeriod=$mixed;Undated=$undated;CoherenceHours=$CoherenceHours;FieldCount=$fields.Count}
}

function Copy-DomeniaQueryRecipe {
    param($Recipe,[string]$Id,[string]$Name,$Clauses,$Refinements,$ObjectIds)
    $copy=New-DomeniaQueryRecipe -Id ([string]$Recipe.Id) -Name ([string]$Recipe.Name) -Junction ([string]$Recipe.Junction) -Clauses @(Get-DomeniaMember $Recipe 'Clauses' @()) -GroupBy ([string](Get-DomeniaMember $Recipe 'GroupBy')) -Refinements @(Get-DomeniaMember $Recipe 'Refinements' @()) -ProbeSelection (Get-DomeniaMemberValue $Recipe 'ProbeSelection') -ObjectIds (Get-DomeniaMemberValue $Recipe 'ObjectIds') -Parameters @(Get-DomeniaMember $Recipe 'Parameters' @()) -ParameterValues (Get-DomeniaMemberValue $Recipe 'ParameterValues') -Expression (Get-DomeniaMemberValue $Recipe 'Expression') -CoherenceHours (Get-DomeniaMemberValue $Recipe 'CoherenceHours') -ReadDefinition (Get-DomeniaMemberValue $Recipe 'ReadDefinition')
    foreach($key in @('Id','Name','Clauses','Refinements','ObjectIds')){if($PSBoundParameters.ContainsKey($key)){$copy.$key=$PSBoundParameters[$key]}}
    # Deep copy prevents an editor mutation from altering a saved recipe or an export in flight.
    return ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $copy -Depth 32 -Compress) -ErrorAction Stop
}
function Assert-DomeniaQueryParameterDefinition {
    # Closed parameter DTO: technical name, field, default value, optional French label and numeric bounds.
    param($Definition,$Field)
    if($null -eq $Definition -or $null -eq $Field){throw 'Définition de paramètre invalide ou dupliquée.'}
    foreach($property in $Definition.PSObject.Properties){if($property.Name -cnotin @('Name','Field','Default','Label','Minimum','Maximum')){throw ('Propriété de paramètre inconnue : '+$property.Name)}}
    $label=Get-DomeniaMemberValue $Definition 'Label'
    if($null -ne $label -and (($label -isnot [string]) -or ($label.Length -gt 80) -or ($label -match '[\p{Cc}]'))){throw 'Libellé de paramètre invalide (80 caractères, sans caractère de contrôle).'}
    $bounds=@{}
    foreach($bound in @('Minimum','Maximum')){
        $raw=Get-DomeniaMemberValue $Definition $bound
        if($null -eq $raw){continue}
        if([string]$Field.Kind -ne 'Number'){throw 'Seule une information numérique accepte des bornes.'}
        $number=[decimal]0
        if(($raw -is [bool]) -or -not [decimal]::TryParse([Convert]::ToString($raw,[Globalization.CultureInfo]::InvariantCulture),[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)){throw 'Borne de paramètre invalide.'}
        $bounds[$bound]=$number
    }
    if($bounds.ContainsKey('Minimum') -and $bounds.ContainsKey('Maximum') -and ($bounds['Minimum'] -gt $bounds['Maximum'])){throw 'La borne minimale du paramètre dépasse sa borne maximale.'}
}
function ConvertTo-DomeniaQueryParameterValue {
    # Typed value of one parameter, shared by the recipe compiler and the parameter form: number with units and
    # optional bounds, Oui/Non, or a non-empty literal text. Nothing is ever evaluated as code.
    param($Definition,$Field,$Value)
    $label=[string](Get-DomeniaMember $Definition 'Label' '');if(-not $label){$label=[string](Get-DomeniaMember $Definition 'Name')}
    if(($null -eq $Value) -or (($Value -is [string]) -and -not $Value.Trim())){throw ('Renseignez le paramètre '+$label+'.')}
    switch([string]$Field.Kind){
        'Number'{
            $number=ConvertTo-DomeniaQueryNumber -Field ([string]$Field.Id) -Text $(if($Value -is [string]){$Value}else{[Convert]::ToString($Value,[Globalization.CultureInfo]::InvariantCulture)})
            foreach($bound in @('Minimum','Maximum')){
                $raw=Get-DomeniaMemberValue $Definition $bound;if($null -eq $raw){continue}
                $limit=[decimal]::Parse([Convert]::ToString($raw,[Globalization.CultureInfo]::InvariantCulture),[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture)
                if((($bound -eq 'Minimum') -and ($number -lt $limit)) -or (($bound -eq 'Maximum') -and ($number -gt $limit))){throw ($label+' : valeur attendue '+$(if($bound -eq 'Minimum'){'supérieure ou égale à '}else{'inférieure ou égale à '})+(Format-DomeniaQueryValueLabel -Value $limit -Field $Field)+'.')}
            }
            return $number
        }
        'Boolean'{
            if($Value -is [bool]){return $Value}
            if([string]$Value -match '^(?i:true|vrai|oui|1)$'){return $true}
            if([string]$Value -match '^(?i:false|faux|non|0)$'){return $false}
            throw ('Le paramètre '+$label+' attend Oui ou Non.')
        }
        default{
            if(($Value -isnot [string]) -or ($Value.Length -gt 4096)){throw ('Le paramètre '+$label+' attend un texte de 4 096 caractères maximum.')}
            return $Value
        }
    }
}
function Get-DomeniaQueryParameterRows {
    # Typed form rows: French label, information, current value, accepted input and coded choices.
    param($Recipe)
    $fields=Get-DomeniaQueryFieldMap $Recipe;$values=Get-DomeniaMemberValue $Recipe 'ParameterValues'
    foreach($definition in @(Get-DomeniaMember $Recipe 'Parameters' @())){
        $name=[string](Get-DomeniaMember $definition 'Name');$id=[string](Get-DomeniaMember $definition 'Field');$field=$fields[$id]
        $label=[string](Get-DomeniaMember $definition 'Label' '');if(-not $label){$label=$name}
        $value=Get-DomeniaMemberValue $values $name (Get-DomeniaMemberValue $definition 'Default')
        $kind=if($null -ne $field){[string]$field.Kind}else{'Text'}
        $unit=if($null -ne $field){[string](Get-DomeniaMember $field 'Unit' '')}else{''}
        $choices=@(if($null -ne $field){Get-DomeniaMember $field 'Choices' @()})
        $min=Get-DomeniaMemberValue $definition 'Minimum';$max=Get-DomeniaMemberValue $definition 'Maximum'
        $hint=switch($kind){
            'Number'{'Nombre'+$(if($unit -and $unit -notin @('Nombre','Nombre / tranche','Valeur brute du fournisseur')){' en '+$unit+' (unités usuelles acceptées)'}else{''})+$(if($null -ne $min -and $null -ne $max){', de '+(Format-DomeniaQueryValueLabel -Value $min -Field $field)+' à '+(Format-DomeniaQueryValueLabel -Value $max -Field $field)}elseif($null -ne $min){', au moins '+(Format-DomeniaQueryValueLabel -Value $min -Field $field)}elseif($null -ne $max){', au plus '+(Format-DomeniaQueryValueLabel -Value $max -Field $field)}else{''})}
            'Boolean'{'Oui ou Non'}
            default{if($choices.Count){'Choix parmi '+$choices.Count+' valeurs connues'}else{'Texte littéral, 4 096 caractères au plus'}}
        }
        [pscustomobject]@{Name=$name;Label=$label;Field=$id;FieldName=$(if($null -ne $field){[string]$field.Name}else{$id});Kind=$kind;Unit=$unit;Value=$value;ValueLabel=(Format-DomeniaQueryValueLabel -Value $value -Field $field -Bare);Hint=$hint;Choices=$choices;Definition=$definition}
    }
}
function Resolve-DomeniaQueryParameters {
    param($Recipe)
    $definitions=@(Get-DomeniaMember $Recipe 'Parameters' @())
    if($definitions.Count -gt 32){throw 'Une recette accepte au maximum 32 paramètres.'}
    if(-not $definitions.Count){return $Recipe}
    $fields=Get-DomeniaQueryFieldMap $Recipe
    $values=Get-DomeniaMemberValue $Recipe 'ParameterValues';$resolved=@{}
    foreach($definition in $definitions){
        $name=[string](Get-DomeniaMember $definition 'Name');$id=[string](Get-DomeniaMember $definition 'Field')
        if(($name -cnotmatch '^[A-Za-z][A-Za-z0-9_]{0,63}$') -or $resolved.ContainsKey($name) -or -not $fields.ContainsKey($id)){throw 'Définition de paramètre invalide ou dupliquée.'}
        Assert-DomeniaQueryParameterDefinition -Definition $definition -Field $fields[$id]
        $value=ConvertTo-DomeniaQueryParameterValue -Definition $definition -Field $fields[$id] -Value (Get-DomeniaMemberValue $values $name (Get-DomeniaMemberValue $definition 'Default'))
        $resolved[$name]=[pscustomobject]@{Field=$id;Value=$value}
    }
    $copy=Copy-DomeniaQueryRecipe $Recipe
    foreach($section in @('Clauses','Refinements')){
        $copy.$section=@(foreach($clause in @($copy.$section)){
            $reference=Get-DomeniaMemberValue $clause.Value 'Parameter'
            if($null -ne $reference){
                if(-not $resolved.ContainsKey([string]$reference) -or $resolved[[string]$reference].Field -cne [string]$clause.Field){throw 'Le paramètre doit appartenir au même champ que sa condition.'}
                $clause.Value=$resolved[[string]$reference].Value
            }
            $clause
        })
    }
    if($null -ne $copy.Expression){$copy.Expression=Resolve-DomeniaQueryExpressionParameters -Node $copy.Expression -Values $resolved}
    $copy.Parameters=@();$copy.ParameterValues=$null
    return $copy
}
function Resolve-DomeniaQueryExpressionParameters {
    param($Node,[hashtable]$Values,[int]$Depth=0)
    if($Depth -gt 8){throw 'Arbre de requête limité à 8 niveaux.'}
    $kind=[string](Get-DomeniaMember $Node 'Kind')
    if($kind -eq 'Clause'){
        $clause=Get-DomeniaMemberValue $Node 'Clause';$reference=Get-DomeniaMemberValue $clause.Value 'Parameter'
        if($null -ne $reference){if(-not $Values.ContainsKey([string]$reference) -or $Values[[string]$reference].Field -cne [string]$clause.Field){throw 'Paramètre de condition imbriquée invalide.'};$clause.Value=$Values[[string]$reference].Value}
    }else{foreach($child in @(Get-DomeniaMember $Node 'Children' @())){[void](Resolve-DomeniaQueryExpressionParameters -Node $child -Values $Values -Depth ($Depth+1))}}
    return $Node
}
function Get-DomeniaQueryInstanceFields {
    if($null -ne $script:DomeniaQueryInstanceFieldCatalog){return $script:DomeniaQueryInstanceFieldCatalog}
    # Raw provider properties remain raw. A numeric view is offered only for explicitly declared scalar properties.
    $numeric=@('FreeSpace','Size','TotalPhysicalMemory','NumberOfCores','NumberOfLogicalProcessors','LoadPercentage','MaxClockSpeed','EstimatedChargeRemaining','PCSystemTypeEx','ProductType','OSLanguage','AllocatedBaseSize','FreePhysicalMemory','FreeVirtualMemory','TotalVisibleMemorySize','NumberOfUsers','MediaType','HealthStatus','ProtectionStatus','AntivirusSignatureAge','QuickScanAge','FullScanAge','Speed','EventCode')
    $boolean=@('VirtualizationFirmwareEnabled','SecondLevelAddressTranslationExtensions','AntivirusEnabled','RealTimeProtectionEnabled','BehaviorMonitorEnabled','DHCPEnabled','IsEnabled_InitialValue','IsActivated_InitialValue')
    $script:DomeniaQueryInstanceFieldCatalog=@(foreach($probe in @(Get-DomeniaProbeCatalog)){foreach($property in @($probe.Properties)){
        [pscustomobject]@{Id=('instance:'+$probe.Id+':'+$property);Name=($probe.Name+' · '+$property);Kind=$(if($property -in $numeric){'Number'}elseif($property -in $boolean){'Boolean'}else{'Text'});ProbeId=$probe.Id;Property=$property;Category=$probe.Category;Unit='Valeur brute du fournisseur'}
    }})
    return $script:DomeniaQueryInstanceFieldCatalog
}
function Get-DomeniaQueryTimestampKey {
    param([string]$Field)
    if($Field -like 'detail:*'){return '_at:detail:'+($Field.Split(':'))[1]}
    if($Field -like 'probe:*'){return '_at:'+$Field}
    if($Field -match '^instance:([^:]+):'){return '_at:probe:'+$Matches[1]}
    if($Field -in @('model','ramGB','diskFreePercent','uptimeDays','inventoryDays','observedRelease')){return '_at:inventory'}
    if($Field -eq 'user'){return '_at:console'}
    if($Field -in @('presence','presenceBucket','checkedDays')){return '_at:presence'}
    return '_at:field:'+$Field
}
function ConvertTo-DomeniaQueryExpression {
    param($Node,[Collections.IDictionary]$Fields,[int]$Depth=0,[string]$CollectionProbe='')
    if($null -eq $Node -or $Depth -gt 8){throw 'Arbre de conditions absent ou supérieur à 8 niveaux.'}
    $kind=[string](Get-DomeniaMember $Node 'Kind')
    if($kind -cnotin @('Clause','All','Any','Not','Collection')){throw 'Type de groupe de conditions inconnu.'}
    foreach($property in $Node.PSObject.Properties){if($property.Name -cnotin @('Kind','Clause','Children','CollectionField','Quantifier')){throw ('Propriété de groupe inconnue : '+$property.Name)}}
    $expression=[M4D.Admin.Common.Query.QueryExpression]::new([M4D.Admin.Common.Query.ExpressionKind]::$kind)
    if($kind -eq 'Clause'){
        $clause=Get-DomeniaMemberValue $Node 'Clause';$field=[string](Get-DomeniaMember $clause 'Field');$op=[string](Get-DomeniaMember $clause 'Operator')
        if(-not $Fields.Contains($field) -or $op -cnotin @(Get-DomeniaQueryOperators $Fields[$field].Kind|ForEach-Object{$_.Id})){throw 'Champ ou opérateur de groupe invalide.'}
        if($CollectionProbe){if(-not $field.StartsWith(('instance:'+$CollectionProbe+':'),[StringComparison]::Ordinal)){throw 'Les conditions dʼune collection doivent viser les propriétés de la même instance.'}}
        elseif($field -like 'instance:*'){throw 'Une propriété dʼinstance doit se trouver dans un groupe de collection.'}
        foreach($property in $clause.PSObject.Properties){if($property.Name -cnotin @('Field','Operator','Value')){throw 'Propriété de condition imbriquée inconnue.'}}
        $expression.Clause=[M4D.Admin.Common.Query.QueryClause]::new($field,[M4D.Admin.Common.Query.QueryOperator]::$op,(Get-DomeniaMemberValue $clause 'Value'))
    }elseif($kind -eq 'Collection'){
        if($CollectionProbe){throw 'Les collections imbriquées ne sont pas prises en charge.'}
        $key=[string](Get-DomeniaMember $Node 'CollectionField');$quantifier=[string](Get-DomeniaMember $Node 'Quantifier')
        if($key -notlike 'probe:*' -or $null -eq (Get-DomeniaProbe $key.Substring(6)) -or $quantifier -cnotin @('Any','All','None')){throw 'Source ou quantificateur de collection invalide.'}
        $expression.CollectionField=$key;$expression.ProjectionKey=Get-DomeniaQueryExpressionKey $Node;$expression.Quantifier=[M4D.Admin.Common.Query.CollectionQuantifier]::$quantifier;$CollectionProbe=$key.Substring(6)
    }
    foreach($child in @(Get-DomeniaMember $Node 'Children' @())){$expression.Children.Add((ConvertTo-DomeniaQueryExpression -Node $child -Fields $Fields -Depth ($Depth+1) -CollectionProbe $CollectionProbe))}
    return $expression
}
function ConvertTo-DomeniaQueryInstances {
    param($Probe,$Result)
    $typed=Get-DomeniaMemberValue $Result 'Instances'
    $rows=if($null -ne $typed){@($typed)}else{@(Get-DomeniaMember $Result 'Rows' @())}
    if($rows.Count -gt 10000){throw 'La collection dépasse le budget de 10 000 instances par poste.'}
    $instances=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new();$index=0;$ids=@{}
    $truncated=[bool](Get-DomeniaMember $Result 'Truncated' $false)
    foreach($raw in $rows){
        $values=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $id=if($null -ne $typed){[string](Get-DomeniaMember $raw 'Id')}else{''}
        if(-not $id -or $ids.ContainsKey($id)){$id=$Probe.Id+':'+$index};$ids[$id]=$true
        $properties=if($null -ne $typed){Get-DomeniaMemberValue $raw 'Values'}else{$null};$columns=@($raw)
        for($i=0;$i -lt @($Probe.Properties).Count;$i++){
            $property=[string]$Probe.Properties[$i];$key='instance:'+$Probe.Id+':'+$property
            if($null -ne $typed){
                $has=if($properties -is [Collections.IDictionary]){Test-DomeniaDictionaryKey $properties $property}else{$null -ne $properties -and $null -ne $properties.PSObject.Properties[$property]}
                if(-not $has){if($truncated){$values['_unknown:'+$key]=$true};continue}
                if($property -in @(Get-DomeniaMember $raw 'IncompleteProperties' @())){$values['_unknown:'+$key]=$true;continue}
                $value=Get-DomeniaMemberValue $properties $property
                if($null -ne $value){$values[$key]=$value}
            }else{
                if($i -ge $columns.Count){$values['_unknown:'+$key]=$true;continue}
                if($null -eq $columns[$i]){continue}
                $value=[string]$columns[$i]
                # Older rows were clipped and flattened: they cannot prove a predicate on the original property.
                if($value.Length -ge 200 -or $property -in @('DNSServerSearchOrder','DefaultIPGateway')){$values['_unknown:'+$key]=$true;continue}
                $values[$key]=$value
            }
        }
        $instances.Add([M4D.Admin.Common.Query.QueryRecord]::new($id,$values));$index++
    }
    $count=Get-DomeniaMemberValue $Result 'Count'
    $complete=($null -ne $count -and [long]$count -eq $rows.Count -and -not $truncated -and [string]$Probe.Mode -ne 'First')
    return [M4D.Admin.Common.Query.QueryCollection]::new($instances,$complete)
}

function Get-DomeniaQueryExpressionClauses {
    param($Node,[int]$Depth=0)
    if($null -eq $Node){return @()};if($Depth -gt 8){throw 'Arbre de conditions trop profond.'}
    if([string](Get-DomeniaMember $Node 'Kind') -eq 'Clause'){return (Get-DomeniaMemberValue $Node 'Clause')}
    foreach($child in @(Get-DomeniaMember $Node 'Children' @())){Get-DomeniaQueryExpressionClauses -Node $child -Depth ($Depth+1)}
}

function Get-DomeniaQueryRequestedFields {
    param($Recipe)
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($clause in @(@(Get-DomeniaMember $Recipe 'Clauses' @())+@(Get-DomeniaMember $Recipe 'Refinements' @())+@(Get-DomeniaQueryExpressionClauses (Get-DomeniaMemberValue $Recipe 'Expression')))){
        $id=[string](Get-DomeniaMember $clause 'Field');if($id){[void]$ids.Add($id)}
    }
    $group=[string](Get-DomeniaMember $Recipe 'GroupBy');if($group){[void]$ids.Add($group)}
    $probe=Get-DomeniaMemberValue $Recipe 'ProbeSelection';if($null -ne $probe){[void]$ids.Add('probe:'+([string]$probe.Key))}
    # Empty ANY/ALL predicates still depend on the existence and completeness of their collection.
    $walk=[Collections.Generic.Stack[object]]::new();$tree=Get-DomeniaMemberValue $Recipe 'Expression';if($null -ne $tree){$walk.Push($tree)};$budget=0
    while($walk.Count){if(++$budget -gt 256){throw 'Arbre de requête limité à 256 éléments.'};$node=$walk.Pop();if([string]$node.Kind -eq 'Collection'){[void]$ids.Add([string]$node.CollectionField)};foreach($child in @(Get-DomeniaMember $node 'Children' @())){if($null -ne $child){$walk.Push($child)}}}
    return @($ids|Sort-Object)
}
function Get-DomeniaQueryFieldMap {
    # French metadata (name, kind, unit, coded choices) of every field a recipe may reference, keyed by field id.
    param($Recipe=$null)
    $map=@{}
    foreach($field in @(@(Get-DomeniaQueryCatalog)+@(Get-DomeniaQueryInstanceFields)+@(Get-DomeniaQueryReadDefinitionFields $Recipe))){$map[[string]$field.Id]=$field}
    return $map
}
function Format-DomeniaQueryValueLabel {
    # Readable typed value: Oui/Non, French decimal with its unit, coded choice name, parameter reference or text.
    # -Bare omits the quotes around a literal text (observed values in a grid).
    param($Value,$Field=$null,[switch]$Bare)
    if($null -eq $Value){return ''}
    if($Value -is [bool]){if($Value){return 'Oui'};return 'Non'}
    if($Value -isnot [string] -and $Value -isnot [ValueType]){
        $reference=Get-DomeniaMemberValue $Value 'Parameter'
        if($null -ne $reference){return 'paramètre '+[string]$reference}
    }
    foreach($choice in @(Get-DomeniaMember $Field 'Choices' @())){if($null -ne $choice -and [string]$choice.Value -ceq [string]$Value){return [string]$choice.Name}}
    if(($Value -is [decimal]) -or ($Value -is [double]) -or ($Value -is [single]) -or ($Value -is [int]) -or ($Value -is [long])){
        $culture=[Globalization.CultureInfo]::GetCultureInfo('fr-FR')
        try{$text=([decimal]$Value).ToString('0.############',$culture)}catch{$text=[Convert]::ToString($Value,[Globalization.CultureInfo]::InvariantCulture)}
        $units=@{'Go'='Go';'Mo'='Mo';'Jours'='j';'%'='%';'Mbit/s'='Mbit/s';'MHz'='MHz'}
        $unit=[string](Get-DomeniaMember $Field 'Unit' '')
        if($units.ContainsKey($unit)){return $text+' '+$units[$unit]}
        return $text
    }
    if($Bare){return [string]$Value}
    return '« '+[string]$Value+' »'
}
function Get-DomeniaQueryClauseLabel {
    # One French sentence per condition, shared by the editor, the explanation and the pack comparison.
    param($Clause,[hashtable]$Fields=$null)
    if($null -eq $Fields){$Fields=Get-DomeniaQueryFieldMap}
    $id=[string](Get-DomeniaMember $Clause 'Field');$operatorId=[string](Get-DomeniaMember $Clause 'Operator')
    $field=$Fields[$id]
    $name=if($null -ne $field){[string]$field.Name}else{$id}
    $kind=if($null -ne $field){[string]$field.Kind}else{'Text'}
    $operator=@(Get-DomeniaQueryOperators $kind|Where-Object{$_.Id -ceq $operatorId}|Select-Object -First 1)
    $verb=if($operator.Count){[string]$operator[0].Name}else{$operatorId}
    if($operatorId -in @('IsMissing','IsPresent')){return $name+' '+$verb}
    return $name+' '+$verb+' '+(Format-DomeniaQueryValueLabel -Value (Get-DomeniaMemberValue $Clause 'Value') -Field $field)
}
function Get-DomeniaQueryExpressionOutline {
    param($Node,[string]$Path='',[int]$Depth=0,[string]$CollectionProbe='',[hashtable]$Fields=$null)
    if($null -eq $Node){return};if($Depth -gt 8){throw 'Arbre de conditions limité à 8 niveaux.'}
    if($null -eq $Fields){$Fields=Get-DomeniaQueryFieldMap}
    $kind=[string]$Node.Kind
    $label=switch($kind){
        All{'Toutes les conditions (ET)'}
        Any{'Au moins une condition (OU)'}
        Not{'Le groupe suivant ne correspond pas (NON)'}
        Collection{
            $source=[string]$Node.CollectionField;$entry=$Fields[$source];$probeName=if($null -ne $entry){[string]$entry.Name}else{$source}
            $quantifier=switch([string]$Node.Quantifier){All{'Toutes les instances'};None{'Aucune instance'};default{'Au moins une instance'}}
            $quantifier+' de « '+$probeName+' »'
        }
        Clause{Get-DomeniaQueryClauseLabel -Clause $Node.Clause -Fields $Fields}
        default{$kind}
    }
    [pscustomobject]@{Path=$Path;Depth=$Depth;Kind=$kind;Node=$Node;CollectionProbe=$CollectionProbe;Label=(('  '*$Depth)+$label)}
    if($kind -eq 'Collection'){$CollectionProbe=([string]$Node.CollectionField).Substring(6)}
    $i=0;foreach($child in @(Get-DomeniaMember $Node 'Children' @())){Get-DomeniaQueryExpressionOutline -Node $child -Path ($Path+'/'+$i) -Depth ($Depth+1) -CollectionProbe $CollectionProbe -Fields $Fields;$i++}
}

function Edit-DomeniaQueryExpression {
    # Pure edit operation shared by the visual builder and its tests. The caller compiles before publishing.
    param($Recipe,[string]$Path='',[ValidateSet('Add','Remove','Up','Down','Clear')][string]$Operation,$Node)
    $copy=Copy-DomeniaQueryRecipe $Recipe
    if($Operation -eq 'Clear'){$copy.Expression=$null;return $copy}
    if($null -eq $copy.Expression){$copy.Expression=[pscustomobject]@{Kind='All';Children=@()}}
    $current=$copy.Expression;$parent=$null;$index=-1
    if($Path){foreach($part in $Path.Trim('/').Split('/')){if($part -notmatch '^[0-9]+$'){throw 'Chemin de condition invalide.'};$index=[int]$part;$parent=$current;$children=@(Get-DomeniaMember $current 'Children' @());if($index -ge $children.Count){throw 'La condition sélectionnée a changé.'};$current=$children[$index]}}
    switch($Operation){
        'Add'{
            if($null -eq $Node){throw 'Condition à ajouter absente.'}
            if([string]$current.Kind -in @('Not','Collection')){$current=@($current.Children)[0]}
            elseif([string]$current.Kind -eq 'Clause'){if($null -eq $parent){throw 'Sélectionnez un groupe ET ou OU.'};$current=$parent}
            if([string]$current.Kind -notin @('All','Any')){throw 'Sélectionnez un groupe ET ou OU.'}
            $current.Children=@(Get-DomeniaMember $current 'Children' @())+@($Node)
        }
        'Remove'{if($null -eq $parent){$copy.Expression=$null}else{$parent.Children=@(for($i=0;$i -lt @($parent.Children).Count;$i++){if($i -ne $index){$parent.Children[$i]}})}}
        default{
            if($null -eq $parent){return $copy};$children=@($parent.Children);$other=if($Operation -eq 'Up'){$index-1}else{$index+1}
            if($other -ge 0 -and $other -lt $children.Count){$temporary=$children[$other];$children[$other]=$children[$index];$children[$index]=$temporary;$parent.Children=$children}
        }
    }
    # Removing the mandatory child of NOT/collection is refused by the compiler, with no draft mutation.
    $copy.Format='Domenia.Query/2';[void](ConvertTo-DomeniaCompiledQuery $copy)
    return $copy
}

function Get-DomeniaCollectionFieldFamily {
    # Measurement family that a remote read refreshes for one query field. AD fields are computed locally;
    # detail:* fields come from an explicit advanced WMI read on one workstation and are never park-collected.
    param([string]$Field)
    $key=Get-DomeniaQueryTimestampKey $Field
    if($key -ceq '_at:presence'){return 'Presence'}
    if($key -ceq '_at:console'){return 'Console'}
    if($key -ceq '_at:inventory'){return 'Inventory'}
    if($key.StartsWith('_at:probe:',[StringComparison]::Ordinal)){return 'Probe'}
    if($key.StartsWith('_at:detail:',[StringComparison]::Ordinal)){return 'Detail'}
    return 'Local'
}
function Get-DomeniaCollectionMaxAgeSeconds {
    # Same reuse windows as the park run: volatile measures one minute, light inventory five minutes, 24 h at most.
    param([string]$Field,[int]$CacheMinutes=15)
    $seconds=[Math]::Max(0,[Math]::Min(1440,$CacheMinutes))*60
    $key=Get-DomeniaQueryTimestampKey $Field
    if($key -ceq '_at:inventory'){$seconds=[Math]::Min(300,$seconds)}
    if(($key -in @('_at:presence','_at:console')) -or ($key -match '^_at:probe:(evt\.|svc\.|net\.)|load|battery|free|users|stopped|process')){$seconds=[Math]::Min(60,$seconds)}
    return $seconds
}
function New-DomeniaMissingCollectionPlan {
    # Reusable "collect only what is missing" plan, shared by workshop recipes and dashboard widgets. Pure: no network,
    # no settings. Fields are query field ids ('presence', 'user', 'ramGB', 'probe:<id>', 'instance:<probe>:<property>').
    # An active account is proposed only when a requested measurement is absent, flagged (expired, read error,
    # incomplete), undated, dated in the future or older than its reuse window. Disabled accounts and accounts whose
    # AD state is unknown are never targets. The park run revalidates every measurement again before reading it.
    param($Records,[string[]]$Fields=@(),$Identities=$null,[int]$CacheMinutes=15,[datetime]$NowUtc=[datetime]::UtcNow)
    $CacheMinutes=[Math]::Max(0,[Math]::Min(1440,$CacheMinutes))
    $requested=[Collections.Generic.List[object]]::new();$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($field in @($Fields)){
        $id=[string]$field;if(-not $id -or -not $seen.Add($id)){continue}
        if($seen.Count -gt 256){throw 'Un plan de collecte accepte au plus 256 informations distinctes.'}
        $family=Get-DomeniaCollectionFieldFamily $id
        if($family -ceq 'Local'){continue}
        $probeId='';if($id -like 'probe:*'){$probeId=$id.Substring(6)}elseif($id -like 'instance:*'){$probeId=($id.Split(':'))[1]}
        $requested.Add([pscustomobject]@{Id=$id;Family=$family;ProbeId=$probeId;QualityId=$(if($id -like 'instance:*'){'probe:'+$probeId}else{$id});TimestampKey=(Get-DomeniaQueryTimestampKey $id);MaxAgeSeconds=(Get-DomeniaCollectionMaxAgeSeconds -Field $id -CacheMinutes $CacheMinutes);CollectionKey=$(if($id -like 'instance:*'){'_instances:probe:'+$probeId}else{''})})
    }
    $targets=[Collections.Generic.List[object]]::new();$fieldMissing=@{}
    $families=[ordered]@{Presence=0L;Console=0L;Inventory=0L;Probe=0L}
    $probes=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $total=0L;$reused=0L;$disabled=0L;$unknownState=0L;$notCollectable=0L
    foreach($record in $Records){
        if($null -eq $record){continue}
        if($null -ne $Identities -and -not $Identities.Contains($record.Id.Trim().Trim('{','}'))){continue}
        $total++;$v=$record.Values
        if(-not $v.ContainsKey('active')){$unknownState++;continue};if(-not [bool]$v['active']){$disabled++;continue}
        $missing=[Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
        $missingProbes=[Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
        $targetFamilies=[Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal);$detailMissing=$false
        foreach($entry in $requested){
            $known=$v.ContainsKey($entry.Id)
            if($entry.CollectionKey){$known=($v.ContainsKey($entry.CollectionKey) -and [bool]$v[$entry.CollectionKey].Complete)}
            $at=if($v.ContainsKey($entry.TimestampKey)){ConvertFrom-DomeniaUtcText ([string]$v[$entry.TimestampKey])}else{$null}
            $fresh=($known -and -not $v.ContainsKey('_quality:'+$entry.QualityId) -and $null -ne $at -and $at -le $NowUtc.AddMinutes(1) -and ($NowUtc-$at).TotalSeconds -lt $entry.MaxAgeSeconds)
            if($fresh){continue}
            if($entry.Family -ceq 'Detail'){$detailMissing=$true;continue}
            [void]$missing.Add($entry.QualityId);[void]$targetFamilies.Add($entry.Family)
            if($entry.ProbeId){[void]$missingProbes.Add($entry.ProbeId)}
        }
        if($detailMissing){$notCollectable++}
        if(-not $missing.Count){if(-not $detailMissing){$reused++};continue}
        foreach($id in $missing){$fieldMissing[$id]=1L+[long]$fieldMissing[$id]}
        foreach($family in $targetFamilies){$families[$family]=1L+[long]$families[$family]}
        foreach($id in $missingProbes){[void]$probes.Add($id)}
        $targets.Add([pscustomobject]@{name=[string]$v['name'];distinguished_name=[string]$v['dn'];object_guid=$record.Id;MissingFields=@($missing);MissingProbeIds=@($missingProbes);Families=@($targetFamilies)})
    }
    $counts=@(foreach($key in @($fieldMissing.Keys)){[pscustomobject]@{Field=[string]$key;Missing=[long]$fieldMissing[$key]}})
    $counts=@($counts|Sort-Object -Property @{Expression='Missing';Descending=$true},@{Expression='Field';Descending=$false})
    [pscustomobject]@{Targets=$targets.ToArray();Total=$total;Reused=$reused;Disabled=$disabled;UnknownState=$unknownState;NotCollectable=$notCollectable;Ping=($families['Presence'] -gt 0);Console=($families['Console'] -gt 0);Inventory=($families['Inventory'] -gt 0);Wmi=(($families['Console']+$families['Inventory']+$families['Probe']) -gt 0);ProbeIds=@($probes|Sort-Object);FamilyTargets=[pscustomobject]$families;FieldCounts=$counts;Fields=@($requested|ForEach-Object{$_.Id});PreparedAtUtc=$NowUtc.ToUniversalTime().ToString('o');CacheMinutes=$CacheMinutes}
}
function New-DomeniaQueryMissingCollectionPlan {
    # Plan only: no network. The run scheduler revalidates identity, freshness and definitions before collection.
    param($Records,$Recipe,[int]$CacheMinutes=15,[datetime]$NowUtc=[datetime]::UtcNow)
    return (New-DomeniaMissingCollectionPlan -Records $Records -Fields @(Get-DomeniaQueryRequestedFields $Recipe) -Identities (Get-DomeniaQueryIdentitySelection $Recipe) -CacheMinutes $CacheMinutes -NowUtc $NowUtc)
}
function Measure-DomeniaCollectionPlanWorkload {
    # Remote work implied by a plan for the park-run mode it selects. Counts only: no duration is invented here.
    param($Plan)
    $targets=@($Plan.Targets)
    $mode=if([bool]$Plan.Ping -and -not [bool]$Plan.Wmi){'Ping'}elseif([bool]$Plan.Wmi -and -not [bool]$Plan.Ping){'Wmi'}else{'PingWmi'}
    $slow=@{};foreach($id in @($Plan.ProbeIds)){$probe=Get-DomeniaProbe ([string]$id);if($null -ne $probe -and [bool](Get-DomeniaMember $probe 'Slow' $false)){$slow[[string]$id]=[string]$probe.Name}}
    $probeReads=0L;$slowReads=0L
    foreach($target in $targets){foreach($id in @($target.MissingProbeIds)){$probeReads++;if($slow.ContainsKey([string]$id)){$slowReads++}}}
    $contacts=[long]$targets.Count
    # Same bands as the ParkSweep impact model (100 and 500 workstations); slow probes raise the level.
    $level=if(($contacts -gt 500) -or ($slowReads -gt 100)){'Élevé'}elseif(($contacts -gt 100) -or ($slowReads -gt 0)){'Modéré'}else{'Faible'}
    [pscustomobject]@{Mode=$mode;Targets=$contacts;PingReads=$(if($mode -ne 'Wmi'){$contacts}else{0L});ConsoleReads=$(if($mode -ne 'Ping'){$contacts}else{0L});InventoryReads=[long](Get-DomeniaMember $Plan.FamilyTargets 'Inventory' 0);ProbeReads=$probeReads;SlowProbeReads=$slowReads;SlowProbes=@($slow.Values|Sort-Object);Level=$level}
}
function Format-DomeniaQueryCollectionPlanText {
    # Operator summary shown before the explicit launch. The cost is counted from the plan; no duration is
    # displayed because the park run records no comparable timing history to calibrate one.
    param($Plan,$Workload=$null,[int]$Concurrency=4)
    if($null -eq $Workload){$Workload=Measure-DomeniaCollectionPlanWorkload $Plan}
    $Concurrency=[Math]::Max(1,[Math]::Min(8,$Concurrency))
    $names=@{};foreach($entry in @(@(Get-DomeniaQueryCatalog)+@(Get-DomeniaQueryInstanceFields))){$names[[string]$entry.Id]=[string]$entry.Name}
    $lines=[Collections.Generic.List[string]]::new()
    $at=ConvertFrom-DomeniaUtcText ([string]$Plan.PreparedAtUtc)
    $reuse=if([int]$Plan.CacheMinutes -gt 0){'mesures réutilisées si elles datent de moins de '+[int]$Plan.CacheMinutes+' min (1 min pour les mesures volatiles, 5 min pour lʼinventaire)'}else{'relecture forcée de toutes les mesures demandées'}
    $lines.Add('Plan préparé '+$(if($null -ne $at){'le '+$at.ToLocalTime().ToString('dd/MM HH:mm:ss')+' '}else{''})+'sur les données locales : '+$reuse+'.')
    $lines.Add([string]@($Plan.Targets).Count+' poste(s) à relire sur '+[string]$Plan.Total+' examiné(s) : '+[string]$Plan.Reused+' déjà à jour ; '+[string]$Plan.Disabled+' désactivé(s) et '+[string]$Plan.UnknownState+' à lʼétat AD inconnu exclus.')
    if(@($Plan.Targets).Count){
        $reads=[Collections.Generic.List[string]]::new()
        if($Workload.Mode -ne 'Wmi'){$reads.Add('ping ICMP')}
        if($Workload.Mode -ne 'Ping'){$reads.Add('utilisateur console')}
        if([bool]$Plan.Inventory){$reads.Add('inventaire léger sur '+[string]$Workload.InventoryReads+' poste(s)')}
        $probeIds=@($Plan.ProbeIds)
        if($probeIds.Count){
            $probeNames=@($probeIds|Select-Object -First 5|ForEach-Object{$label=$names['probe:'+[string]$_];if($label){$label}else{[string]$_}})
            $reads.Add([string]$probeIds.Count+' sonde(s) WMI ('+($probeNames -join ' ; ')+$(if($probeIds.Count -gt 5){' ; …'}else{''})+')')
        }
        $lines.Add('Lectures prévues : '+($reads.ToArray() -join ', ')+'. Lecture seule ; chaque poste ne relit que ses mesures manquantes ou anciennes.')
        $top=@(@($Plan.FieldCounts)|Select-Object -First 5|ForEach-Object{$label=$names[[string]$_.Field];if(-not $label){$label=[string]$_.Field};$label+' ('+[string]$_.Missing+')'})
        if($top.Count){$lines.Add('Informations les plus manquantes : '+($top -join ' ; ')+'.')}
        $cost='Coût : '+[string]$Workload.Level+' · '+[string]$Workload.Targets+' poste(s) contacté(s)'
        if([long]$Workload.ProbeReads -gt 0){$cost+=', au plus '+[string]$Workload.ProbeReads+' lecture(s) de sondes'}
        if([long]$Workload.SlowProbeReads -gt 0){$cost+=' dont '+[string]$Workload.SlowProbeReads+' sur des sondes lentes ('+(@($Workload.SlowProbes) -join ' ; ')+')'}
        $lines.Add($cost+' ; '+[string]$Concurrency+' poste(s) au maximum en parallèle. Durée non estimée : aucun relevé comparable nʼest chronométré.')
    }
    if([long]$Plan.NotCollectable -gt 0){$lines.Add([string]$Plan.NotCollectable+' poste(s) attendent aussi une lecture WMI avancée : elle se relance depuis la fiche du poste, pas dans cette collecte.')}
    return ($lines.ToArray() -join "`r`n")
}

function Get-DomeniaQueryExpressionKey {
    param($Node)
    $json=ConvertTo-Json -InputObject $Node -Depth 32 -Compress
    $hash=[Security.Cryptography.SHA256]::Create();try{return [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($json))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
}
function Get-DomeniaQueryCollectionNodes {
    param($Recipe)
    $resolved=Resolve-DomeniaQueryParameters $Recipe
    foreach($entry in @(Get-DomeniaQueryExpressionOutline (Get-DomeniaMemberValue $resolved 'Expression'))){
        if($entry.Kind -eq 'Collection'){[pscustomobject]@{ProbeId=([string]$entry.Node.CollectionField).Substring(6);ProjectionKey=(Get-DomeniaQueryExpressionKey $entry.Node);Node=$entry.Node}}
    }
}
function ConvertTo-DomeniaQueryCollectionProjections {
    # At most one SQL page is expanded. Only verdicts and provenance survive the worker callback.
    param([object[]]$Observations,[object[]]$Nodes,[datetime]$NowUtc=[datetime]::UtcNow,[int]$MaxAgeDays=30)
    $compiled=@{};foreach($node in $Nodes){$compiled[$node.ProjectionKey]=ConvertTo-DomeniaCompiledQuery (New-DomeniaQueryRecipe -Expression $node.Node)}
    foreach($observation in $Observations){
        foreach($node in $Nodes){
            if([string]$observation.Family -cne ('Probe:'+$node.ProbeId)){continue}
            $result=Get-DomeniaMemberValue (Get-DomeniaMemberValue $observation.Data 'Probes') $node.ProbeId
            $values=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);$coverage='Non lu';$count=0
            $at=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaMember $result 'CheckedUtc'))
            if([string]$observation.Status -ne 'Success' -or [string](Get-DomeniaMember $result 'Error')){$coverage='Erreur de lecture'}
            elseif($null -eq $at -or $at -gt $NowUtc.AddMinutes(5)){$coverage='Date de relevé inconnue'}
            elseif(($NowUtc-$at).TotalDays -gt $MaxAgeDays){$coverage='Expiré'}
            elseif(-not [string](Get-DomeniaMember $result 'Skipped')){
                $probe=Get-DomeniaProbe $node.ProbeId;$collection=ConvertTo-DomeniaQueryInstances -Probe $probe -Result $result
                $values['_instances:probe:'+$node.ProbeId]=$collection;$coverage=if($collection.Complete){'Disponible'}else{'Lecture incomplète'};$count=$collection.Instances.Count
            }
            $verdict=$compiled[$node.ProjectionKey].Evaluate($values)
            [pscustomobject]@{Guid=[string]$observation.Guid;ProjectionKey=$node.ProjectionKey;ProbeId=$node.ProbeId;Verdict=[int]$verdict;CheckedUtc=$(if($null -ne $at){$at.ToUniversalTime().ToString('o')}else{''});Coverage=$coverage;InstanceCount=$count}
        }
    }
}
function Add-DomeniaQueryCollectionProjectionRecords {
    param($Records,[object[]]$Projections=@())
    $byGuid=@{};foreach($entry in $Projections){$key=([string]$entry.Guid).ToLowerInvariant();if(-not $byGuid.ContainsKey($key)){$byGuid[$key]=[Collections.Generic.List[object]]::new()};$byGuid[$key].Add($entry)}
    $output=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
    foreach($record in $Records){
        $values=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach($pair in $record.Values.GetEnumerator()){if($pair.Key -notmatch '^_expr:|^_exprinfo:'){$values[$pair.Key]=$pair.Value}}
        foreach($entry in @($byGuid[$record.Id.ToLowerInvariant()])){
            if($null -eq $entry -or [string]$entry.ProjectionKey -cnotmatch '^[0-9a-f]{64}$' -or -not [Enum]::IsDefined([M4D.Admin.Common.Query.MatchState],[int]$entry.Verdict)){continue}
            $values['_expr:'+$entry.ProjectionKey]=[M4D.Admin.Common.Query.MatchState][int]$entry.Verdict
            $values['_exprinfo:'+$entry.ProjectionKey]=$entry
            if($entry.CheckedUtc){$values['_at:probe:'+$entry.ProbeId]=[string]$entry.CheckedUtc}
        }
        $output.Add([M4D.Admin.Common.Query.QueryRecord]::new($record.Id,$values))
    }
    return ,$output
}
