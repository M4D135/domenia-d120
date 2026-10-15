# Search workspace rules (points 56 to 60): saved views, filter chips, collective scope, local preview and
# workstation comparison. Pure functions: no WPF, no network, no disk. Presentation preferences contain no result
# rows, credentials or executable code.
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
    # ConvertTo-DomeniaColumnLayout returns its array as one object: @() around the call would nest it.
    $columns=ConvertTo-DomeniaColumnLayout $Value.Columns
    [pscustomobject]@{Version=1;Id=$id.ToString('D');Name=$name;DomainDn=$DomainDn;OuDn=$dn;Subtree=[bool]$Value.Subtree;TypeLabel=[string]$Value.TypeLabel;Presence=[string]$Value.Presence;LocalFilter=$filter;Limit=$limit;Columns=$columns;Sort=$sort.ToArray()}
}

function ConvertFrom-DomeniaSearchWorkspaceStore {
    # Point 57: decodes the stored views. Windows PowerShell 5.1 writes a decoded JSON array as one object: the
    # value is assigned before it is enumerated, so that several views are never read as one malformed entry.
    # Former builds wrapped the stored array once more at each save ('[[],{v1}]', then '[[[],{v1}],{v2}]'): nested
    # arrays are flattened in order, so that every view they hold is listed again; the empty arrays of that former
    # format carry nothing and are the only entries dropped. Any other entry, of this domain or another one, readable
    # or not, stays in All exactly as decoded: the next save writes it back, so nothing is ever lost or repaired
    # silently. An unreadable entry is counted in Rejected.
    param([AllowEmptyString()][string]$Text,[AllowEmptyString()][string]$DomainDn)
    if(-not $Text){$Text='[]'}
    if([Text.Encoding]::UTF8.GetByteCount($Text) -gt 1048576){throw 'Bibliothèque de vues trop volumineuse.'}
    $decoded=ConvertFrom-Json -InputObject $Text -ErrorAction Stop
    $all=@($decoded|Where-Object{$null -ne $_})
    # Each pass opens one level of nesting; the former writer nested once per save, 100 views at most.
    for($level=0;$level -lt 128;$level++){
        $nested=$false;$flat=[Collections.Generic.List[object]]::new()
        foreach($item in $all){
            if($item -is [Array]){$nested=$true;foreach($inner in $item){if($null -ne $inner){$flat.Add($inner)}};continue}
            $flat.Add($item)
        }
        $all=$flat.ToArray()
        if(-not $nested){break}
    }
    if($all.Count -gt 100){throw 'Cent vues personnelles au maximum.'}
    $kept=[Collections.Generic.List[object]]::new();$views=[Collections.Generic.List[object]]::new();$ids=@{};$rejected=0
    foreach($item in $all){
        $kept.Add($item)
        # Not a view of any known version (a scalar, an object without Version, an array nested too deep).
        if(($item -isnot [Management.Automation.PSCustomObject]) -or ($null -eq $item.PSObject.Properties['Version'])){$rejected++;continue}
        if((-not $DomainDn) -or ([string](Get-DomeniaMember $item 'DomainDn' '') -ine $DomainDn)){continue}
        $record=$null
        try{$record=ConvertTo-DomeniaSearchWorkspace $item $DomainDn}catch{$record=$null}
        if(($null -eq $record) -or $ids.ContainsKey($record.Id)){$rejected++;continue}
        $ids[$record.Id]=$true;$views.Add($record)
    }
    return [pscustomobject]@{All=$kept.ToArray();Views=@($views.ToArray()|Sort-Object -Property Name);Rejected=$rejected}
}

function ConvertTo-DomeniaSearchWorkspaceStoreText {
    # Point 57: the stored form of the views, bounded like its reader.
    param([AllowEmptyCollection()][object[]]$Items)
    $list=@($Items|Where-Object{$null -ne $_})
    if(-not $list.Count){return '[]'}
    if($list.Count -gt 100){throw 'Cent vues personnelles au maximum.'}
    $text=ConvertTo-Json -InputObject $list -Depth 8 -Compress
    if([Text.Encoding]::UTF8.GetByteCount($text) -gt 1048576){throw 'Bibliothèque de vues trop volumineuse.'}
    return $text
}

function Add-DomeniaSearchWorkspaceRecord {
    # Point 57: adds one validated view. Its name is unique in its domain, without regard to case; nothing is replaced.
    param([AllowEmptyCollection()][object[]]$Items,$Candidate,[string]$DomainDn)
    $record=ConvertTo-DomeniaSearchWorkspace $Candidate $DomainDn
    $list=@($Items|Where-Object{$null -ne $_})
    if($list.Count -ge 100){throw 'Cent vues sont déjà enregistrées. Retirez une vue devenue inutile.'}
    # Unreadable entries kept as stored (a scalar, an object without these members) are compared without failing.
    foreach($item in $list){
        if(([string](Get-DomeniaMember $item 'DomainDn' '') -ieq $DomainDn) -and (([string](Get-DomeniaMember $item 'Name' '')).Trim() -ieq $record.Name)){throw 'Une vue porte déjà ce nom dans ce domaine. Choisissez un autre nom ou retirez lʼancienne vue.'}
    }
    return [pscustomobject]@{Items=@($list+@($record));Record=$record}
}

function Remove-DomeniaSearchWorkspaceRecord {
    # Point 57: removes the view with this identifier in this domain only.
    param([AllowEmptyCollection()][object[]]$Items,[string]$Id,[string]$DomainDn)
    $list=@($Items|Where-Object{$null -ne $_})
    $remaining=@($list|Where-Object{-not (([string](Get-DomeniaMember $_ 'Id' '') -ceq $Id) -and ([string](Get-DomeniaMember $_ 'DomainDn' '') -ieq $DomainDn))})
    return [pscustomobject]@{Items=$remaining;Removed=($list.Count-$remaining.Count)}
}

function Get-DomeniaSearchWorkspaceLabel {
    # Point 57: a view is recognised by its name, then its OU, depth and type.
    param($View)
    if($null -eq $View){return ''}
    $names=@(Get-DomeniaOuPathNames ([string]$View.OuDn))
    $place=if($names.Count){[string]$names[0]}else{Get-DomeniaOuDisplayPath ([string]$View.OuDn)}
    $parts=[Collections.Generic.List[string]]::new()
    $parts.Add([string]$View.Name)
    $parts.Add($place+$(if([bool]$View.Subtree){' et sous-OU'}else{' seulement'}))
    if(([bool][string]$View.TypeLabel) -and ([string]$View.TypeLabel -ne 'Tous')){$parts.Add([string]$View.TypeLabel)}
    return ($parts.ToArray() -join ' · ')
}

function Get-DomeniaSearchFilterChips {
    # Point 56: every criterion that shapes the list, with the place where it applies. A list-level chip is removed
    # without any network call; removing the type chip reads the OU again and says so; the scope has no ×.
    # $State: Mode, OuDn, Subtree, GlobalText, BarScope, BarOuDn, BarType, TypeLabel, Presence, LocalFilter, QueryName,
    # QueryKind, QuerySelection, SegmentName, Shown, Loaded.
    param($State)
    $chips=[Collections.Generic.List[object]]::new()
    $mode=[string](Get-DomeniaMember $State 'Mode' 'OU')
    if($mode -eq 'Global'){
        # FO-05 (X02): the perimeter chip and the type of the upper bar that produced the list are criteria of this
        # list too, shown here with the others; they change in the bar only, never from this row.
        $text=ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $State 'GlobalText' '')) 60
        $barOu=([string](Get-DomeniaMember $State 'BarOuDn' '')).Trim()
        if(([string](Get-DomeniaMember $State 'BarScope' 'Everywhere') -eq 'Ou') -and $barOu){
            $names=@(Get-DomeniaOuPathNames $barOu)
            $leaf=if($names.Count){[string]$names[0]}else{Get-DomeniaOuDisplayPath $barOu}
            $chips.Add([pscustomobject]@{Key='Scope';Scope='Annuaire';Label=('Dans « '+$leaf+' » · sous-OU incluses'+$(if($text){' : '+$text}else{''}));Removable=$false;Effect=('Recherche de la barre du haut dans '+(Get-DomeniaOuDisplayPath $barOu)+' et ses sous-OU. Changez le périmètre avec la puce de la barre, puis Rechercher.')})
        }else{
            $chips.Add([pscustomobject]@{Key='Scope';Scope='Annuaire';Label=('Partout · domaine entier'+$(if($text){' : '+$text}else{''}));Removable=$false;Effect='Recherche de la barre du haut dans tout le domaine. Changez le périmètre avec la puce de la barre, puis Rechercher ; lʼOU, le type et la présence de la liste dʼOU ne sʼappliquent pas.'})
        }
        $barType=[string](Get-DomeniaMember $State 'BarType' 'Tous')
        $typeEntry=@(Get-DomeniaSearchBarTypes|Where-Object{[string]$_.Key -eq $barType})
        if(($typeEntry.Count) -and ($barType -ne 'Tous')){$chips.Add([pscustomobject]@{Key='BarType';Scope='Annuaire';Label=('Type : '+[string]$typeEntry[0].Label);Removable=$false;Effect='Type cherché par la barre du haut. Changez-le avec ses puces, puis Rechercher : cette pastille ne relance rien.'})}
    }else{
        $dn=([string](Get-DomeniaMember $State 'OuDn' '')).Trim()
        $names=@(Get-DomeniaOuPathNames $dn)
        $leaf=if($names.Count){[string]$names[0]}elseif($dn){Get-DomeniaOuDisplayPath $dn}else{'aucune OU choisie'}
        $subtree=[bool](Get-DomeniaMember $State 'Subtree' $true)
        $chips.Add([pscustomobject]@{Key='Scope';Scope='Annuaire';Label=('OU '+$leaf+' · '+$(if($subtree){'sous-OU incluses'}else{'niveau direct'}));Removable=$false;Effect=('Périmètre lu dans lʼannuaire : '+$(if($dn){Get-DomeniaOuDisplayPath $dn}else{'aucun'})+'. Changez-le dans lʼarbre ou le fil dʼAriane ; il nʼest jamais élargi au domaine en silence.')})
        $type=[string](Get-DomeniaMember $State 'TypeLabel' 'Tous')
        if(($type) -and ($type -ne 'Tous')){$chips.Add([pscustomobject]@{Key='Type';Scope='Annuaire';Label=('Type : '+$type);Removable=$true;Effect='Retirer ce critère relit lʼOU dans lʼannuaire avec tous les types dʼobjets.'})}
    }
    $query=ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $State 'QueryName' '')) 60
    if($query){
        $kind=[string](Get-DomeniaMember $State 'QueryKind' 'Local')
        $selection=[string](Get-DomeniaMember $State 'QuerySelection' '')
        if($kind -eq 'Directory'){$chips.Add([pscustomobject]@{Key='Query';Scope='Annuaire';Label=('Requête : '+$query);Removable=$true;Effect='Retirer cette requête efface sa liste ; aucune autre lecture nʼest lancée.'})}
        else{$chips.Add([pscustomobject]@{Key='Query';Scope='Base locale';Label=('Requête : '+$query+$(if($selection){' · '+$selection}else{''}));Removable=$true;Effect='Retirer cette requête locale efface ses résultats ; aucune lecture de lʼannuaire ni des postes.'})}
    }
    $segment=ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $State 'SegmentName' '')) 60
    if($segment){$chips.Add([pscustomobject]@{Key='Segment';Scope='Base locale';Label=('Sélection de lʼatelier : '+$segment);Removable=$true;Effect='Retirer cette sélection réaffiche toutes les lignes chargées ; aucune lecture réseau.'})}
    # The presence filter applies to an OU list only; « Filtrer la liste » to any loaded list, a global one included
    # (CO-05 / SP-14, X02).
    if($mode -ne 'Global'){
        $presence=[string](Get-DomeniaMember $State 'Presence' 'Tous')
        if(($presence) -and ($presence -ne 'Tous')){$chips.Add([pscustomobject]@{Key='Presence';Scope='Liste chargée';Label=('Ping mémorisé : '+$presence);Removable=$true;Effect='Filtre local sur la dernière présence mémorisée ; retirer ce critère nʼenvoie aucun ping. Sans réponse ne prouve pas quʼun poste est éteint.'})}
    }
    $local=ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $State 'LocalFilter' '')) 60
    if($local){$chips.Add([pscustomobject]@{Key='Local';Scope='Liste chargée';Label=('Contient : '+$local);Removable=$true;Effect='Filtre local sur les lignes déjà chargées ; retirer ce critère nʼappelle pas lʼannuaire.'})}
    $summary='Combinaison : '+(@($chips|ForEach-Object{'['+$_.Scope+'] '+$_.Label}) -join ' ET ')
    $shown=[int](Get-DomeniaMember $State 'Shown' -1);$loaded=[int](Get-DomeniaMember $State 'Loaded' -1)
    if($shown -ge 0){
        $summary+=' → '+$shown+' ligne(s) affichée(s)'
        if(($loaded -ge 0) -and ($loaded -ne $shown)){$summary+=' sur '+$loaded+' chargée(s)'}
    }
    if(@($chips|Where-Object{$_.Scope -eq 'Liste chargée'}).Count){$summary+='. Les critères de la liste chargée ne lisent rien au-delà des lignes déjà chargées.'}
    return [pscustomobject]@{Chips=$chips.ToArray();Summary=$summary}
}

function Get-DomeniaSearchSelectionText {
    # Point 60 / FO-18 (X01): the short statement of the selected rows, the same in the bar of a multiple selection and
    # in the scope announced before an export or a survey: « 3 postes sélectionnés », « 3 lignes sélectionnées dont
    # 1 poste ». -MachineCount -1: the number of workstations is not known.
    param([int]$SelectedCount=0,[int]$MachineCount=-1)
    if($SelectedCount -le 0){return 'Aucune ligne sélectionnée'}
    if($MachineCount -eq $SelectedCount){return ([string]$SelectedCount+' '+$(if($SelectedCount -gt 1){'postes sélectionnés'}else{'poste sélectionné'}))}
    $text=[string]$SelectedCount+' '+$(if($SelectedCount -gt 1){'lignes sélectionnées'}else{'ligne sélectionnée'})
    if($MachineCount -gt 0){$text+=' dont '+[string]$MachineCount+' '+$(if($MachineCount -gt 1){'postes'}else{'poste'})}
    return $text
}

function Get-DomeniaSearchScopeSummary {
    # Point 60: the sentence that states what an export or a survey will process, from counts only, so that the
    # label beside the results stays cheap on 20 000 rows. Completeness: what is known, never more. Short: the
    # statement of the selection (Get-DomeniaSearchSelectionText), also shown by the bar of a multiple selection.
    param([ValidateSet('Visible','Selected')][string]$Mode='Visible',[int]$VisibleCount=0,[int]$SelectedCount=0,[int]$SelectedHidden=0,[int]$LoadedCount=-1,[ValidateSet('Complete','Limited','Partial','Loading','Unknown')][string]$Completeness='Unknown',[int]$Limit=0,[int]$SelectedMachines=-1)
    $hidden=if($LoadedCount -gt $VisibleCount){$LoadedCount-$VisibleCount}else{0}
    $note=switch($Completeness){
        'Complete'{'liste complète'}
        'Limited'{$(if($Limit -gt 0){'liste limitée à '+$Limit+' lignes : les objets au-delà ne sont pas inclus'}else{'liste limitée : les objets au-delà ne sont pas inclus'})}
        'Partial'{'lecture partielle : des objets peuvent manquer'}
        'Loading'{'lecture en cours : la liste peut encore changer'}
        default{'complétude de la liste non déterminée'}
    }
    $short=Get-DomeniaSearchSelectionText -SelectedCount $SelectedCount -MachineCount $SelectedMachines
    if($Mode -eq 'Selected'){
        if($SelectedCount -le 0){$label='Aucune ligne sélectionnée parmi les lignes affichées : sélectionnez des lignes (Ctrl ou Maj + clic) ou choisissez la liste affichée.'}
        else{$label='Lignes sélectionnées : '+$short+' sur '+$VisibleCount+' affichée(s)'}
        if($SelectedHidden -gt 0){$label+=' · '+$SelectedHidden+' ligne(s) sélectionnée(s) masquée(s) par un filtre, exclue(s)'}
    }else{
        $label='Liste affichée : '+$VisibleCount+' ligne(s)'
        if($hidden -gt 0){$label+=' · '+$hidden+' ligne(s) chargée(s) masquée(s) par les filtres, exclue(s)'}
        if($SelectedCount -gt 0){$label+=' · sélection de '+$SelectedCount+' ligne(s) non utilisée (la barre de sélection agit sur elle)'}
        $label+=' · '+$note
    }
    return [pscustomobject]@{Label=$label;Short=$short;HiddenByLocalFilter=$hidden}
}

function Get-DomeniaSearchSelectionPlan {
    # Point 60: the collective scope of an export or of a survey, stated before it runs. 'Visible': the rows of
    # the list as shown after the local filters, in the displayed order. 'Selected': the selected rows still shown,
    # in the same order. Rows beyond the loaded limit are never implied; an unknown completeness stays unknown.
    # The bar of a multiple selection (FO-18, X01) and its surveys use the 'Selected' plan: one rule, one statement.
    param([AllowEmptyCollection()][object[]]$VisibleRows,[AllowEmptyCollection()][object[]]$SelectedRows,[ValidateSet('Visible','Selected')][string]$Mode='Visible',[int]$LoadedCount=-1,[ValidateSet('Complete','Limited','Partial','Loading','Unknown')][string]$Completeness='Unknown',[int]$Limit=0)
    $visible=@($VisibleRows|Where-Object{$null -ne $_})
    $selectedKeys=@{}
    foreach($row in @($SelectedRows)){if($null -ne $row){$key=Get-DomeniaNavRowKey $row;if($key){$selectedKeys[$key]=$true}}}
    $rows=[Collections.Generic.List[object]]::new();$seen=@{};$shownSelected=@{}
    # Without selection, the visible list is taken as shown: no identity is computed per row.
    if(($Mode -eq 'Visible') -and (-not $selectedKeys.Count)){
        $summary=Get-DomeniaSearchScopeSummary -Mode Visible -VisibleCount $visible.Count -LoadedCount $LoadedCount -Completeness $Completeness -Limit $Limit
        return [pscustomobject]@{Rows=$visible;Count=$visible.Count;Mode=$Mode;VisibleCount=$visible.Count;SelectedCount=0;SelectedMachines=0;SelectedHidden=0;HiddenByLocalFilter=$summary.HiddenByLocalFilter;Machines=@($visible|Where-Object{[string]$_.Type -eq 'Machine'}).Count;Completeness=$Completeness;Label=$summary.Label;Short=$summary.Short}
    }
    $selectedMachines=0
    foreach($row in $visible){
        # Same identity as Get-DomeniaNavRowKey, computed inline for long lists.
        $key='';$guid=[guid]::Empty
        if(([guid]::TryParse([string]$row.Guid,[ref]$guid)) -and ($guid -ne [guid]::Empty)){$key='g:'+$guid.ToString('D')}elseif([string]$row.DN){$key='d:'+([string]$row.DN).ToLowerInvariant()}
        $isSelected=(([bool]$key) -and ($selectedKeys.ContainsKey($key)))
        if(($isSelected) -and (-not $shownSelected.ContainsKey($key))){$shownSelected[$key]=$true;if([string]$row.Type -eq 'Machine'){$selectedMachines++}}
        if(($Mode -eq 'Selected') -and (-not $isSelected)){continue}
        if($key){if($seen.ContainsKey($key)){continue};$seen[$key]=$true}
        $rows.Add($row)
    }
    $selectedCount=$shownSelected.Count
    $selectedHidden=[Math]::Max(0,$selectedKeys.Count-$selectedCount)
    $machines=@($rows|Where-Object{[string]$_.Type -eq 'Machine'}).Count
    $summary=Get-DomeniaSearchScopeSummary -Mode $Mode -VisibleCount $visible.Count -SelectedCount $selectedCount -SelectedHidden $selectedHidden -LoadedCount $LoadedCount -Completeness $Completeness -Limit $Limit -SelectedMachines $selectedMachines
    return [pscustomobject]@{Rows=$rows.ToArray();Count=$rows.Count;Mode=$Mode;VisibleCount=$visible.Count;SelectedCount=$selectedCount;SelectedMachines=$selectedMachines;SelectedHidden=$selectedHidden;HiddenByLocalFilter=$summary.HiddenByLocalFilter;Machines=$machines;Completeness=$Completeness;Label=$summary.Label;Short=$summary.Short}
}

function Get-DomeniaFileTimeAttributeNames {
    # AD attributes stored as FILETIME integers (UTC, 100 ns since 1601).
    return @('pwdlastset','lastlogontimestamp','lastlogon','accountexpires','badpasswordtime','lockouttime','ms-mcs-admpwdexpirationtime','mslaps-passwordexpirationtime')
}

function ConvertTo-DomeniaComparisonText {
    # Points 58-59: one display value. A missing value stays 'Non lu' and an empty observed value is not a missing
    # one. A one-value AD attribute shows its value; AD file times become UTC dates; nothing is rounded or guessed.
    param($Value,[AllowEmptyString()][string]$Name='')
    if($null -eq $Value){return 'Non lu'}
    if($Value -is [array]){
        $items=@($Value|Where-Object{$null -ne $_})
        if(-not $items.Count){return 'Vide observé'}
        if(($items.Count -le 20) -and (@($items|Where-Object{($_ -is [array]) -or ($_ -is [Management.Automation.PSCustomObject])}).Count -eq 0)){
            return (@($items|ForEach-Object{ConvertTo-DomeniaComparisonText $_ $Name}) -join ' ; ')
        }
        return (ConvertTo-Json -InputObject $Value -Depth 5 -Compress)
    }
    if($Value -is [Management.Automation.PSCustomObject]){return (ConvertTo-Json -InputObject $Value -Depth 5 -Compress)}
    if($Value -is [bool]){return $(if($Value){'Oui'}else{'Non'})}
    $text=[Convert]::ToString($Value,[Globalization.CultureInfo]::InvariantCulture)
    if($text -eq ''){return 'Vide observé'}
    # Stored AD dates are ISO 8601 UTC texts: shown to the minute, in UTC, like every other date of these tables.
    if($text -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}'){$date=Format-DomeniaComparisonDate $text;if($date){return $date}}
    if(([bool]$Name) -and (@(Get-DomeniaFileTimeAttributeNames) -contains $Name.ToLowerInvariant())){
        $ticks=0L
        if([long]::TryParse($text,[Globalization.NumberStyles]::Integer,[Globalization.CultureInfo]::InvariantCulture,[ref]$ticks)){
            if($ticks -le 0){return '0 (aucune date)'}
            if($ticks -eq [long]::MaxValue){return 'Jamais (valeur maximale)'}
            try{return ([datetime]::FromFileTimeUtc($ticks).ToString('yyyy-MM-dd HH:mm',[Globalization.CultureInfo]::InvariantCulture)+' UTC')}catch{return $text}
        }
    }
    return $text
}

function Format-DomeniaComparisonDate {
    # A stored UTC date to the minute, or '' when it is missing or unreadable.
    param($Value)
    $date=ConvertTo-DomeniaUtcDate $Value
    if($null -eq $date){return ''}
    return ($date.ToString('yyyy-MM-dd HH:mm',[Globalization.CultureInfo]::InvariantCulture)+' UTC')
}

function Get-DomeniaObservationFields {
    # Points 58-59: the measured values of one observation as named fields, two levels deep at most and $Maximum
    # fields at most. Identity and bookkeeping members are not measures. One record per field is written.
    param($Data,[AllowEmptyString()][string]$Prefix='',[ValidateRange(1,200)][int]$Maximum=40,[ValidateRange(1,4)][int]$Depth=2)
    if($null -eq $Data){return}
    if($Data -isnot [Management.Automation.PSCustomObject]){[pscustomobject]@{Name=$(if($Prefix){$Prefix}else{'Valeur'});Value=$Data};return}
    $skip=@('Guid','Key','DN','Version','Times','Probes','Computer','Revision','SummaryUnavailable','SummaryMissing')
    $count=0
    foreach($property in @($Data.PSObject.Properties)){
        if($count -ge $Maximum){break}
        if($property.Name -in $skip){continue}
        $name=if($Prefix){$Prefix+'.'+$property.Name}else{[string]$property.Name}
        if(($Depth -gt 1) -and ($property.Value -is [Management.Automation.PSCustomObject])){
            foreach($inner in @(Get-DomeniaObservationFields -Data $property.Value -Prefix $name -Maximum ($Maximum-$count) -Depth ($Depth-1))){$inner;$count++}
            continue
        }
        [pscustomobject]@{Name=$name;Value=$property.Value}
        $count++
    }
}

function Get-DomeniaComputerComparison {
    # Point 58: one to eight objects side by side, from the committed local base. Every value keeps its own date:
    # values of different measures are never mixed, and a missing value is never 'Identique'. Each row says whether
    # the values differ (Difference: Different, Unknown, DateOnly, Same, Single for one object).
    param([AllowEmptyCollection()][object[]]$Rows,[AllowEmptyCollection()][object[]]$Observations,[string[]]$Guids,[ValidateRange(1,200)][int]$FieldsPerFamily=40)
    if((@($Guids).Count -lt 1) -or (@($Guids).Count -gt 8)){throw 'Comparez de un à huit objets.'}
    $byGuid=@{};foreach($row in @($Rows)){if($null -ne $row){$byGuid[([string]$row.Guid).ToLowerInvariant()]=$row}}
    $families=@{};foreach($row in @($Observations)){if($null -ne $row){$families[([string]$row.Guid).ToLowerInvariant()+'|'+[string]$row.Family]=$row}}
    $keys=@($Guids|ForEach-Object{([string]$_).ToLowerInvariant()})
    $cells=[Collections.Generic.List[object]]::new()
    $definitions=@(
        @('Identité AD','Guid','AD'),@('Nom','Name','AD'),@('Chemin','DN','AD'),@('Compte activé','State','AD'),
        @('Description','Description','AD'),@('Connexion AD approximative','LastLogon','AD'),
        @('Système','operatingsystem','Attribute'),@('Version du système','operatingsystemversion','Attribute'),
        @('Création AD','whencreated','Attribute'),@('Mot de passe machine modifié','pwdlastset','Attribute')
    )
    foreach($definition in $definitions){
        $values=@(for($i=0;$i -lt $keys.Count;$i++){
            $row=$byGuid[$keys[$i]];$value=$null;$date='';$text='Non lu'
            if($null -ne $row){
                if($definition[2] -eq 'AD'){
                    $value=Get-DomeniaMember $row $definition[1] $null
                    $date=Format-DomeniaComparisonDate (Get-DomeniaMember $row.FieldTimes $definition[1] $null)
                    if(-not $date){$date=Format-DomeniaComparisonDate $row.ObservedAtUtc}
                    # An empty column of the base does not tell an empty AD value from an attribute never read.
                    if([string]$value -eq ''){$value=$null;$text='Non renseigné'}else{$text=ConvertTo-DomeniaComparisonText $value $definition[1]}
                }else{
                    $property=$null;if($null -ne $row.Details){$property=$row.Details.PSObject.Properties[$definition[1]]}
                    if($null -ne $property){$value=$property.Value;$text=ConvertTo-DomeniaComparisonText $value $definition[1];$date=Format-DomeniaComparisonDate (Get-DomeniaMember $row.FieldTimes ('Details.'+$definition[1]) $null)}
                }
            }
            [pscustomobject]@{Value=$value;Text=$text;Date=$date;Note=''}
        })
        $cells.Add([pscustomobject]@{Property=$definition[0];Values=$values})
    }
    foreach($family in @(@('Presence','Présence réseau'),@('Console','Utilisateur connecté'),@('Inventory','Inventaire'))){
        $names=[Collections.Generic.List[string]]::new();$perGuid=@{}
        foreach($key in $keys){
            $observation=$families[$key+'|'+$family[0]];$fields=@{}
            if(($null -ne $observation) -and ($null -ne $observation.Data)){
                foreach($field in @(Get-DomeniaObservationFields -Data $observation.Data -Maximum $FieldsPerFamily)){
                    $fields[$field.Name]=$field.Value
                    if((-not $names.Contains($field.Name)) -and ($names.Count -lt $FieldsPerFamily)){$names.Add($field.Name)}
                }
            }
            $perGuid[$key]=[pscustomobject]@{Observation=$observation;Fields=$fields}
        }
        # A family read nowhere stays one explicit unknown row instead of disappearing.
        if(-not $names.Count){$names.Add('')}
        foreach($fieldName in $names){
            $values=@(foreach($key in $keys){
                $entry=$perGuid[$key];$observation=$entry.Observation;$value=$null;$date='';$note=''
                if($null -ne $observation){
                    $date=Format-DomeniaComparisonDate $observation.LastSuccessAtUtc
                    if(([bool]$fieldName) -and ($entry.Fields.ContainsKey($fieldName))){$value=$entry.Fields[$fieldName]}
                    if([string]$observation.Error){$note=' · tentative '+(Format-DomeniaComparisonDate $observation.LastAttemptAtUtc)+' : '+(ConvertTo-DomeniaFlatText ([string]$observation.Error) 120)}
                }
                [pscustomobject]@{Value=$value;Text=(ConvertTo-DomeniaComparisonText $value $fieldName);Date=$date;Note=$note}
            })
            $cells.Add([pscustomobject]@{Property=$(if($fieldName){$family[1]+' · '+$fieldName}else{$family[1]});Values=$values})
        }
    }
    $output=[Collections.Generic.List[object]]::new()
    foreach($cell in $cells){
        $record=[ordered]@{Property=$cell.Property;Comparison='';Difference=''}
        $known=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$dates=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$unknown=$false
        for($i=0;$i -lt $cell.Values.Count;$i++){
            $item=$cell.Values[$i]
            if($null -eq $item.Value){$unknown=$true}else{[void]$known.Add($item.Text);[void]$dates.Add($item.Date)}
            $record['V'+$i]=$item.Text
            $record['T'+$i]=$(if($item.Date){$item.Date}else{'Date non confirmée'})+$item.Note
        }
        if($cell.Values.Count -eq 1){$record.Comparison='';$record.Difference='Single'}
        elseif($unknown){$record.Comparison=$(if($known.Count -gt 1){'Incomplet, valeurs connues différentes'}else{'Incomplet'});$record.Difference='Unknown'}
        elseif($known.Count -gt 1){$record.Comparison='Valeurs différentes';$record.Difference='Different'}
        elseif($dates.Count -gt 1){$record.Comparison='Valeurs identiques, dates différentes';$record.Difference='DateOnly'}
        else{$record.Comparison='Identique';$record.Difference='Same'}
        $output.Add([pscustomobject]$record)
    }
    return $output.ToArray()
}

function Get-DomeniaSearchPreviewRows {
    # Point 59: the stored fiche of one object, read from the local base only: AD fields with their own dates, the
    # stored directory attributes, then the measured families of a workstation. Unread values stay 'Non lu'.
    param($Row,[AllowEmptyCollection()][object[]]$Observations,[ValidateRange(1,500)][int]$MaximumAttributes=80,[ValidateRange(1,200)][int]$FieldsPerFamily=40)
    $out=[Collections.Generic.List[object]]::new()
    if($null -eq $Row){return $out.ToArray()}
    $fieldDate={param($Name)$d=Format-DomeniaComparisonDate (Get-DomeniaMember $Row.FieldTimes $Name $null);if(-not $d){$d=Format-DomeniaComparisonDate $Row.ObservedAtUtc};if($d){$d}else{'Date non confirmée'}}
    foreach($pair in @(@('Nom','Name'),@('Type','Type'),@('Chemin','DN'),@('État du compte','State'),@('Description','Description'),@('Identifiant','Login'),@('UPN / DNS','Upn'),@('Connexion AD approximative','LastLogon'))){
        $value=[string](Get-DomeniaMember $Row $pair[1] '')
        # An empty column of the base does not tell an empty AD value from an attribute never read.
        $text=if($value){ConvertTo-DomeniaComparisonText $value $pair[1]}else{'Non renseigné dans la base locale'}
        $out.Add([pscustomobject]@{Property=$pair[0];Value=$text;Date=(& $fieldDate $pair[1])})
    }
    $details=Get-DomeniaMember $Row 'Details' $null
    if($null -ne $details){
        $count=0
        foreach($property in @($details.PSObject.Properties|Sort-Object -Property Name)){
            if($count -ge $MaximumAttributes){$out.Add([pscustomobject]@{Property='Attributs AD';Value=('Affichage limité à '+$MaximumAttributes+' attributs ; les autres restent dans la base locale.');Date=''});break}
            if($property.Name -in @('objectguid','distinguishedname','name')){continue}
            $date=Format-DomeniaComparisonDate (Get-DomeniaMember $Row.FieldTimes ('Details.'+$property.Name) $null)
            $out.Add([pscustomobject]@{Property=('Attribut AD · '+$property.Name);Value=(ConvertTo-DomeniaComparisonText $property.Value $property.Name);Date=$(if($date){$date}else{'Date non confirmée'})})
            $count++
        }
    }
    if([string](Get-DomeniaMember $Row 'Type' '') -eq 'Machine'){
        $guid=([string]$Row.Guid).ToLowerInvariant()
        foreach($family in @(@('Presence','Présence réseau'),@('Console','Utilisateur connecté'),@('Inventory','Inventaire'))){
            $observation=@($Observations|Where-Object{($null -ne $_) -and (([string]$_.Guid).ToLowerInvariant() -eq $guid) -and ([string]$_.Family -ceq $family[0])}|Select-Object -First 1)
            if(-not $observation.Count){$out.Add([pscustomobject]@{Property=$family[1];Value='Non lu';Date='Aucun relevé enregistré'});continue}
            $o=$observation[0];$date=Format-DomeniaComparisonDate $o.LastSuccessAtUtc
            $note=if([string]$o.Error){' · tentative '+(Format-DomeniaComparisonDate $o.LastAttemptAtUtc)+' : '+(ConvertTo-DomeniaFlatText ([string]$o.Error) 120)}else{''}
            $fields=@(Get-DomeniaObservationFields -Data $o.Data -Maximum $FieldsPerFamily)
            if(-not $fields.Count){$out.Add([pscustomobject]@{Property=$family[1];Value='Non lu';Date=$(if($date){$date}else{'Date non confirmée'})+$note});continue}
            foreach($field in $fields){$out.Add([pscustomobject]@{Property=($family[1]+' · '+$field.Name);Value=(ConvertTo-DomeniaComparisonText $field.Value $field.Name);Date=$(if($date){$date}else{'Date non confirmée'})+$note})}
        }
    }
    return $out.ToArray()
}
