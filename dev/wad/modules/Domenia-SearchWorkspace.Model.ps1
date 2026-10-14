# Presentation preferences contain no result rows, credentials or executable code.
function ConvertTo-DomeniaSearchWorkspace {
    param($Value,[string]$DomainDn)
    if($null -eq $Value -or [int]$Value.Version -ne 1){throw 'Version de vue non reconnue.'}
    $id=[guid]::Empty
    if(-not [guid]::TryParse([string]$Value.Id,[ref]$id) -or $id -eq [guid]::Empty){throw 'Identifiant de vue invalide.'}
    $name=([string]$Value.Name).Trim();$dn=[string]$Value.OuDn
    if(-not $name -or $name.Length -gt 80 -or $name -match '[\x00-\x1f]' -or $dn.Length -gt 4096){throw 'Nom ou périmètre de vue invalide.'}
    if([string]$Value.DomainDn -ine $DomainDn -or -not $DomainDn){throw 'Cette vue appartient à un autre domaine.'}
    # DN components, not a suffix of an escaped component, define the domain boundary.
    $scope=@(Split-DomeniaRawDn $dn);$domain=@(Split-DomeniaRawDn $DomainDn)
    if($scope.Count -le $domain.Count){throw 'Une OU ou un conteneur du domaine est requis.'}
    for($i=1;$i -le $domain.Count;$i++){if($scope[-$i] -ine $domain[-$i]){throw 'Vue hors du domaine.'}}
    $limit=0
    if(-not [int]::TryParse([string]$Value.Limit,[ref]$limit) -or $limit -lt 1 -or $limit -gt 20000){throw 'Limite de vue invalide.'}
    if([string]$Value.TypeLabel -notin @('Tous','Utilisateurs','Machines','Groupes','OU et conteneurs')){throw 'Type de vue invalide.'}
    if([string]$Value.Presence -notin @('Tous','En ligne','Sans réponse au ping','Non vérifié','Erreur de ping')){throw 'Filtre présence invalide.'}
    $filter=[string]$Value.LocalFilter;if($filter.Length -gt 120){throw 'Filtre de vue trop long.'}
    $sort=[Collections.Generic.List[object]]::new();$seen=@{}
    foreach($item in @($Value.Sort)){
        $field=[string]$item.Field
        if($sort.Count -ge 20 -or $seen.ContainsKey($field) -or $field -cnotmatch '^[A-Za-z][A-Za-z0-9_]{0,79}$' -or [string]$item.Direction -notin @('Ascending','Descending')){throw 'Tri de vue invalide.'}
        $seen[$field]=$true;$sort.Add([pscustomobject]@{Field=$field;Direction=[string]$item.Direction})
    }
    [pscustomobject]@{Version=1;Id=$id.ToString('D');Name=$name;DomainDn=$DomainDn;OuDn=$dn;Subtree=[bool]$Value.Subtree;TypeLabel=[string]$Value.TypeLabel;Presence=[string]$Value.Presence;LocalFilter=$filter;Limit=$limit;Columns=@(ConvertTo-DomeniaColumnLayout $Value.Columns);Sort=$sort.ToArray()}
}
function Get-DomeniaSearchSelectionPlan {
    param([object[]]$VisibleRows,[object[]]$SelectedRows,[ValidateSet('Loaded','Selected')][string]$Mode='Loaded')
    $visible=@{};foreach($row in $VisibleRows){$id=[string]$row.Guid;if(-not $id){$id=[string]$row.DN};if($id){$visible[$id]=$true}}
    $seen=@{};$result=[Collections.Generic.List[object]]::new();$excluded=0
    $source=if($Mode -eq 'Selected'){$SelectedRows}else{$VisibleRows}
    foreach($row in $source){
        $id=[string]$row.Guid;if(-not $id){$id=[string]$row.DN}
        if(-not $id -or -not $visible.ContainsKey($id)){$excluded++;continue}
        if(-not $seen.ContainsKey($id)){$result.Add($row);$seen[$id]=$true}
    }
    [pscustomobject]@{Rows=$result.ToArray();Count=$result.Count;Mode=$Mode;Excluded=$excluded;LoadedCount=$visible.Count}
}
function ConvertTo-DomeniaComparisonText {
    param($Value)
    if($null -eq $Value){return 'Non lu'}
    if($Value -is [array]){if(-not $Value.Count){return 'Vide observé'};return ($Value|ConvertTo-Json -Depth 5 -Compress)}
    if($Value -is [bool]){return $(if($Value){'Oui'}else{'Non'})}
    if([string]$Value -eq ''){return 'Vide observé'}
    return [Convert]::ToString($Value,[Globalization.CultureInfo]::InvariantCulture)
}
function Get-DomeniaComputerComparison {
    param([object[]]$Rows,[object[]]$Observations,[string[]]$Guids)
    if($Guids.Count -lt 1 -or $Guids.Count -gt 8){throw 'Comparez de un à huit objets.'}
    $byGuid=@{};foreach($row in $Rows){$byGuid[[string]$row.Guid]=$row}
    $families=@{};foreach($row in $Observations){$families[([string]$row.Guid+'|'+[string]$row.Family)]=$row}
    $definitions=@(
        @('Identité AD','Guid','AD'),@('Nom','Name','AD'),@('Chemin','DN','AD'),@('Compte activé','State','AD'),
        @('Description','Description','AD'),@('Connexion AD approximative','LastLogon','AD'),
        @('Système','operatingsystem','Attribute'),@('Version du système','operatingsystemversion','Attribute'),
        @('Création AD','whencreated','Attribute'),@('Mot de passe machine modifié','pwdlastset','Attribute'),
        @('Présence réseau','Presence','Family'),@('Utilisateur connecté','Console','Family'),@('Inventaire','Inventory','Family')
    )
    $output=[Collections.Generic.List[object]]::new()
    foreach($definition in $definitions){
        $record=[ordered]@{Propriété=$definition[0];Comparaison=''};$values=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$dates=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$unknown=$false
        for($i=0;$i -lt $Guids.Count;$i++){
            $row=$byGuid[$Guids[$i]];$value=$null;$date='';$note=''
            if($null -ne $row){
                if($definition[2] -eq 'AD'){$value=$row.($definition[1]);$date=[string]$row.ObservedAtUtc}
                elseif($definition[2] -eq 'Attribute'){
                    $property=$row.Details.PSObject.Properties[$definition[1]]
                    if($null -ne $property){$value=$property.Value;$date=[string](Get-DomeniaMember $row.FieldTimes $definition[1] '')}
                }else{
                    $observation=$families[($Guids[$i]+'|'+$definition[1])]
                    if($null -ne $observation){
                        $date=[string]$observation.LastSuccessAtUtc
                        if($null -ne $observation.Data){
                            # Keep exact named fields and their values; never infer off-line from a failed WMI read.
                            $value=ConvertTo-Json -InputObject $observation.Data -Depth 6 -Compress
                        }
                        if([string]$observation.Error){$note=' · Tentative '+[string]$observation.LastAttemptAtUtc+' : '+[string]$observation.Error}
                    }
                }
            }
            if($null -eq $value){$unknown=$true};$text=ConvertTo-DomeniaComparisonText $value
            [void]$values.Add($text);[void]$dates.Add($date)
            $record['V'+$i]=$text;$record['T'+$i]=$(if($date){$date+' UTC'}else{'Date non confirmée'})+$note
        }
        $record['Comparaison']=if($unknown){'Incomplet'}elseif($values.Count -gt 1){'Valeurs différentes'}elseif($dates.Count -gt 1){'Valeurs identiques, dates différentes'}else{'Identique'}
        $output.Add([pscustomobject]$record)
    }
    return $output.ToArray()
}
