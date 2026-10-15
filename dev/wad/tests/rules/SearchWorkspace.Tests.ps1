# W08 espace de recherche (points 56 a 60) : vues, criteres, portee collective, apercu et comparaison.
# Donnees fictives uniquement.
$script:WsDomain='DC=example,DC=invalid'
function New-WsCandidate {param([string]$Name='Postes Lyon',[string]$Ou='OU=Postes,OU=Lyon,DC=example,DC=invalid')
    [pscustomobject]@{Version=1;Id=[guid]::NewGuid().ToString('D');Name=$Name;DomainDn=$script:WsDomain;OuDn=$Ou;Subtree=$true;TypeLabel='Machines';Presence='Tous';LocalFilter='pc';Limit='500'
        Columns=@([pscustomobject]@{Key='Name';Index=1;Width='260';Unit='Pixel'},[pscustomobject]@{Key='Type';Index=0;Width='1';Unit='Star'});Sort=@([pscustomobject]@{Field='Name';Direction='Descending'})}
}
Test-Case 'P57' 'Vue : colonnes et tri conserves sans imbrication, champs bornes' {
    $view=ConvertTo-DomeniaSearchWorkspace (New-WsCandidate) $script:WsDomain
    Assert-Equal 2 @($view.Columns).Count 'Les colonnes ne doivent pas etre imbriquees dans un tableau unique'
    Assert-Equal 'Name' $view.Columns[0].Key;Assert-Equal 260 ([int]$view.Columns[0].Width);Assert-Equal 'Descending' $view.Sort[0].Direction
    Assert-Throws {ConvertTo-DomeniaSearchWorkspace ((New-WsCandidate) | ForEach-Object {$_.Limit='20001';$_}) $script:WsDomain} 'Limite au-dela de 20 000 acceptee'
    Assert-Throws {ConvertTo-DomeniaSearchWorkspace (New-WsCandidate -Ou 'OU=Postes,DC=autre,DC=invalid') $script:WsDomain} 'Vue hors domaine acceptee'
    Assert-Throws {ConvertTo-DomeniaSearchWorkspace (New-WsCandidate -Ou $script:WsDomain) $script:WsDomain} 'Le domaine entier ne peut pas etre une vue'
}
Test-Case 'P57' 'Bibliotheque de vues : aller-retour JSON avec plusieurs vues, autre domaine conserve' {
    $a=Add-DomeniaSearchWorkspaceRecord -Items @() -Candidate (New-WsCandidate 'Bravo') -DomainDn $script:WsDomain
    $b=Add-DomeniaSearchWorkspaceRecord -Items $a.Items -Candidate (New-WsCandidate 'Alpha') -DomainDn $script:WsDomain
    $foreign=[pscustomobject]@{Version=1;Id=[guid]::NewGuid().ToString('D');Name='Ailleurs';DomainDn='DC=autre,DC=invalid';OuDn='OU=X,DC=autre,DC=invalid';Subtree=$true;TypeLabel='Tous';Presence='Tous';LocalFilter='';Limit=100;Columns=@();Sort=@()}
    $text=ConvertTo-DomeniaSearchWorkspaceStoreText -Items (@($b.Items)+@($foreign))
    $store=ConvertFrom-DomeniaSearchWorkspaceStore -Text $text -DomainDn $script:WsDomain
    Assert-Equal 3 @($store.All).Count 'Toutes les vues stockees, autre domaine compris';Assert-Equal 2 @($store.Views).Count
    Assert-Equal 'Alpha' $store.Views[0].Name 'Vues triees par nom';Assert-Equal 2 @($store.Views[1].Columns).Count;Assert-Equal 0 $store.Rejected
    Assert-Throws {Add-DomeniaSearchWorkspaceRecord -Items $store.All -Candidate (New-WsCandidate 'alpha') -DomainDn $script:WsDomain} 'Nom en double accepte'
    $removed=Remove-DomeniaSearchWorkspaceRecord -Items $store.All -Id $store.Views[0].Id -DomainDn $script:WsDomain
    Assert-Equal 1 $removed.Removed;Assert-Equal 2 @($removed.Items).Count
    Assert-Equal '[]' (ConvertTo-DomeniaSearchWorkspaceStoreText -Items @());Assert-Equal 0 @((ConvertFrom-DomeniaSearchWorkspaceStore -Text '' -DomainDn $script:WsDomain).Views).Count
}
Test-Case 'P57' 'Bibliotheque de vues : entree illisible comptee, jamais reparee ni perdue' {
    $good=ConvertTo-DomeniaSearchWorkspaceStoreText -Items @((Add-DomeniaSearchWorkspaceRecord -Items @() -Candidate (New-WsCandidate) -DomainDn $script:WsDomain).Items)
    $text='['+$good.Substring(1,$good.Length-2)+',{"Version":1,"Id":"x","Name":"Cassee","DomainDn":"DC=example,DC=invalid"},{"Note":"sans version"},"texte"]'
    $store=ConvertFrom-DomeniaSearchWorkspaceStore -Text $text -DomainDn $script:WsDomain
    Assert-Equal 1 @($store.Views).Count;Assert-Equal 3 $store.Rejected;Assert-Equal 4 @($store.All).Count 'Chaque entree illisible reste stockee'
    # The next write keeps every unreadable entry as it was.
    $added=Add-DomeniaSearchWorkspaceRecord -Items $store.All -Candidate (New-WsCandidate 'Autre') -DomainDn $script:WsDomain
    $again=ConvertFrom-DomeniaSearchWorkspaceStore -Text (ConvertTo-DomeniaSearchWorkspaceStoreText -Items $added.Items) -DomainDn $script:WsDomain
    Assert-Equal 2 @($again.Views).Count;Assert-Equal 3 $again.Rejected;Assert-Equal 5 @($again.All).Count 'Une ecriture a efface une entree illisible'
    Assert-True (@($again.All|Where-Object{$_ -is [string]}) -ccontains 'texte') 'La valeur scalaire n est plus stockee telle quelle'
    Assert-Equal 'sans version' ([string]@($again.All|Where-Object{($_ -isnot [string]) -and ($null -ne $_.PSObject.Properties['Note'])})[0].Note)
    Assert-Throws {ConvertFrom-DomeniaSearchWorkspaceStore -Text ('['+((1..101|ForEach-Object{'{}'}) -join ',')+']') -DomainDn $script:WsDomain} 'Plus de cent vues acceptees'
    Assert-True ((Get-DomeniaSearchWorkspaceLabel $store.Views[0]) -ceq 'Postes Lyon · Postes et sous-OU · Machines')
}
Test-Case 'P57' 'Bibliotheque de vues : le format imbrique des anciennes versions est relu sans perte' {
    # Former builds wrapped the stored array at each save: '[[],{v1}]', then '[[[],{v1}],{v2}]'.
    $v1=ConvertTo-DomeniaSearchWorkspaceStoreText -Items @((Add-DomeniaSearchWorkspaceRecord -Items @() -Candidate (New-WsCandidate 'Premiere') -DomainDn $script:WsDomain).Items)
    $v2=ConvertTo-DomeniaSearchWorkspaceStoreText -Items @((Add-DomeniaSearchWorkspaceRecord -Items @() -Candidate (New-WsCandidate 'Seconde') -DomainDn $script:WsDomain).Items)
    $one=ConvertFrom-DomeniaSearchWorkspaceStore -Text ('[[],'+$v1.Substring(1,$v1.Length-2)+']') -DomainDn $script:WsDomain
    Assert-Equal 1 @($one.Views).Count;Assert-Equal 0 $one.Rejected 'Le tableau vide de l ancien format n est pas une vue illisible';Assert-Equal 1 @($one.All).Count
    $text='[[[],'+$v1.Substring(1,$v1.Length-2)+'],'+$v2.Substring(1,$v2.Length-2)+']'
    $store=ConvertFrom-DomeniaSearchWorkspaceStore -Text $text -DomainDn $script:WsDomain
    Assert-Equal 2 @($store.Views).Count 'Une vue imbriquee n est pas relue';Assert-Equal 0 $store.Rejected;Assert-Equal 2 @($store.All).Count
    Assert-Equal 'Premiere' $store.Views[0].Name;Assert-Equal 2 @($store.Views[0].Columns).Count 'Colonnes de la vue imbriquee perdues'
    # A save then a removal write both views back flat: the first one is never lost.
    $added=Add-DomeniaSearchWorkspaceRecord -Items $store.All -Candidate (New-WsCandidate 'Troisieme') -DomainDn $script:WsDomain
    $saved=ConvertFrom-DomeniaSearchWorkspaceStore -Text (ConvertTo-DomeniaSearchWorkspaceStoreText -Items $added.Items) -DomainDn $script:WsDomain
    $second=@($saved.Views|Where-Object{$_.Name -eq 'Seconde'})[0]
    $removed=Remove-DomeniaSearchWorkspaceRecord -Items $saved.All -Id $second.Id -DomainDn $script:WsDomain
    $final=ConvertFrom-DomeniaSearchWorkspaceStore -Text (ConvertTo-DomeniaSearchWorkspaceStoreText -Items $removed.Items) -DomainDn $script:WsDomain
    Assert-Equal 'Premiere,Troisieme' ((@($final.Views)|ForEach-Object{$_.Name}) -join ',');Assert-Equal 0 $final.Rejected
}
Test-Case 'P56' 'Criteres visibles : portee, type, requete, presence et filtre local, avec leur lieu' {
    $m=Get-DomeniaSearchFilterChips -State ([pscustomobject]@{Mode='OU';OuDn='OU=Postes,OU=Lyon,DC=example,DC=invalid';Subtree=$false;TypeLabel='Machines';Presence='En ligne';LocalFilter='pc-0';QueryName='Disques pleins';QueryKind='Local';QuerySelection='Inconnus';Shown=3;Loaded=40})
    Assert-Equal 'Scope,Type,Query,Presence,Local' ((@($m.Chips)|ForEach-Object{$_.Key}) -join ',')
    Assert-False $m.Chips[0].Removable 'La portee ne se retire pas';Assert-True ($m.Chips[0].Label.Contains('niveau direct'))
    Assert-Equal 'Annuaire' $m.Chips[1].Scope;Assert-True ($m.Chips[1].Effect.Contains('relit'));Assert-Equal 'Base locale' $m.Chips[2].Scope;Assert-True ($m.Chips[2].Label.Contains('Inconnus'))
    Assert-Equal 'Liste chargée' $m.Chips[3].Scope;Assert-True ($m.Chips[3].Effect.Contains('aucun ping'))
    Assert-True ($m.Summary.Contains(' ET ') -and $m.Summary.Contains('3 ligne(s) affichée(s) sur 40 chargée(s)') -and $m.Summary.Contains('ne lisent rien au-delà')) $m.Summary
}
Test-Case 'P56' 'Criteres visibles : la recherche globale ignore les filtres de l OU, une requete annuaire est nommee' {
    # FO-05 / CO-05 (X02): the chip and the type of the upper bar, and the filter of the list, describe a global list;
    # the type and the presence of the OU list do not. The bar criteria change in the bar only (no x here).
    $g=Get-DomeniaSearchFilterChips -State ([pscustomobject]@{Mode='Global';GlobalText='dupont';TypeLabel='Machines';Presence='En ligne';LocalFilter='x';Shown=5;Loaded=5})
    Assert-Equal 'Scope,Local' ((@($g.Chips)|ForEach-Object{$_.Key}) -join ',') 'Type et presence de la liste d OU ignores, filtre de la liste garde'
    Assert-True ($g.Chips[0].Label.StartsWith('Partout') -and $g.Chips[0].Label.Contains('dupont')) $g.Chips[0].Label
    $b=Get-DomeniaSearchFilterChips -State ([pscustomobject]@{Mode='Global';GlobalText='dupont';BarScope='Ou';BarOuDn='OU=Postes,OU=Lyon,DC=example,DC=invalid';BarType='Machines';TypeLabel='Utilisateurs';Presence='En ligne';LocalFilter='';Shown=2;Loaded=2})
    Assert-Equal 'Scope,BarType' ((@($b.Chips)|ForEach-Object{$_.Key}) -join ',')
    Assert-True ($b.Chips[0].Label.StartsWith('Dans « Postes » · sous-OU incluses') -and $b.Chips[0].Effect.Contains('puce de la barre')) $b.Chips[0].Label
    Assert-Equal 'Type : Postes' $b.Chips[1].Label;Assert-False $b.Chips[1].Removable 'Le type de la barre ne se retire pas depuis la liste'
    $o=Get-DomeniaSearchFilterChips -State ([pscustomobject]@{Mode='Global';GlobalText='';BarScope='Ou';BarOuDn='';BarType='Inconnu'})
    Assert-Equal 1 @($o.Chips).Count 'Puce sans OU ou type inconnu : rien d invente';Assert-True ($o.Chips[0].Label.StartsWith('Partout'))
    $d=Get-DomeniaSearchFilterChips -State ([pscustomobject]@{Mode='OU';OuDn='OU=A,DC=example,DC=invalid';Subtree=$true;TypeLabel='Tous';Presence='Tous';LocalFilter='';QueryName='Comptes desactives';QueryKind='Directory';SegmentName='12 poste(s) retenu(s)'})
    Assert-Equal 'Scope,Query,Segment' ((@($d.Chips)|ForEach-Object{$_.Key}) -join ',');Assert-Equal 'Annuaire' $d.Chips[1].Scope;Assert-True ($d.Chips[2].Label.Contains('12 poste'))
}
Test-Case 'P60' 'Portee collective : liste affichee, selection, lignes masquees et completude dites avant l action' {
    $rows=@(1..5|ForEach-Object{[pscustomobject]@{Type=$(if($_ -eq 5){'Utilisateur'}else{'Machine'});Name=('PC-'+$_);Guid=('0000000'+$_+'-0000-4000-8000-000000000000');DN=('CN=PC-'+$_+',OU=P,DC=example,DC=invalid')}})
    $visible=@($rows[0],$rows[1],$rows[2],$rows[4])
    $all=Get-DomeniaSearchSelectionPlan -VisibleRows $visible -SelectedRows @() -Mode Visible -LoadedCount 5 -Completeness Limited -Limit 5
    Assert-Equal 4 $all.Count;Assert-Equal 3 $all.Machines;Assert-Equal 1 $all.HiddenByLocalFilter
    Assert-True ($all.Label.Contains('1 ligne(s) chargée(s) masquée(s)') -and $all.Label.Contains('limitée à 5')) $all.Label
    $sel=Get-DomeniaSearchSelectionPlan -VisibleRows $visible -SelectedRows @($rows[2],$rows[0],$rows[3]) -Mode Selected -LoadedCount 5 -Completeness Complete
    Assert-Equal 2 $sel.Count 'La ligne selectionnee mais masquee est exclue';Assert-Equal 'PC-1' $sel.Rows[0].Name 'Ordre affiche conserve';Assert-Equal 1 $sel.SelectedHidden
    Assert-True ($sel.Label.Contains('2 postes sélectionnés sur 4') -and $sel.Label.Contains('exclue')) $sel.Label
    Assert-Equal '2 postes sélectionnés' $sel.Short 'Meme enonce que la barre de selection';Assert-Equal 2 $sel.SelectedMachines
    $none=Get-DomeniaSearchSelectionPlan -VisibleRows $visible -SelectedRows @() -Mode Selected
    Assert-Equal 0 $none.Count;Assert-True ($none.Label.StartsWith('Aucune ligne sélectionnée'))
    $withSel=Get-DomeniaSearchSelectionPlan -VisibleRows $visible -SelectedRows @($rows[1]) -Mode Visible
    Assert-Equal 4 $withSel.Count 'La liste affichee reste complete';Assert-True ($withSel.Label.Contains('sélection de 1 ligne(s) non utilisée') -and $withSel.Label.Contains('non déterminée'))
}
Test-Case 'P60' 'Enonce de la selection : le meme pour la barre de selection multiple et la portee annoncee' {
    Assert-Equal '3 postes sélectionnés' (Get-DomeniaSearchSelectionText -SelectedCount 3 -MachineCount 3)
    Assert-Equal '3 lignes sélectionnées dont 1 poste' (Get-DomeniaSearchSelectionText -SelectedCount 3 -MachineCount 1)
    Assert-Equal '4 lignes sélectionnées dont 2 postes' (Get-DomeniaSearchSelectionText -SelectedCount 4 -MachineCount 2)
    Assert-Equal '2 lignes sélectionnées' (Get-DomeniaSearchSelectionText -SelectedCount 2 -MachineCount 0)
    Assert-Equal '1 poste sélectionné' (Get-DomeniaSearchSelectionText -SelectedCount 1 -MachineCount 1)
    Assert-Equal '1 ligne sélectionnée' (Get-DomeniaSearchSelectionText -SelectedCount 1)
    Assert-Equal 'Aucune ligne sélectionnée' (Get-DomeniaSearchSelectionText -SelectedCount 0 -MachineCount 0)
    $summary=Get-DomeniaSearchScopeSummary -Mode Selected -VisibleCount 10 -SelectedCount 3 -SelectedMachines 1
    Assert-Equal 'Lignes sélectionnées : 3 lignes sélectionnées dont 1 poste sur 10 affichée(s)' $summary.Label;Assert-Equal '3 lignes sélectionnées dont 1 poste' $summary.Short
}
Test-Case 'P58' 'Comparaison : dates propres a chaque valeur, inconnu jamais identique, attributs par leur date' {
    $g1='11111111-1111-4111-8111-111111111111';$g2='22222222-2222-4222-8222-222222222222'
    $r1=[pscustomobject]@{Guid=$g1;Name='PC-1';DN='CN=PC-1,DC=example,DC=invalid';State='Actif';Description='';LastLogon='2026-10-01T08:00:00.0000000Z';ObservedAtUtc='2026-10-10T08:00:00Z';Details=[pscustomobject]@{operatingsystem=@('Windows 11 Pro');pwdlastset=@(133000000000000000)};FieldTimes=[pscustomobject]@{'Details.operatingsystem'='2026-10-09T07:00:00Z';State='2026-10-10T08:00:00Z'}}
    $r2=[pscustomobject]@{Guid=$g2;Name='PC-2';DN='CN=PC-2,DC=example,DC=invalid';State='Actif';Description='';LastLogon='';ObservedAtUtc='2026-10-11T08:00:00Z';Details=[pscustomobject]@{operatingsystem=@('Windows 10 Pro')};FieldTimes=[pscustomobject]@{'Details.operatingsystem'='2026-10-11T07:00:00Z';State='2026-10-11T08:00:00Z'}}
    $o1=[pscustomobject]@{Guid=$g1;Family='Inventory';LastSuccessAtUtc='2026-10-12T09:00:00Z';LastAttemptAtUtc='2026-10-12T09:00:00Z';Error='';Data=[pscustomobject]@{Model='HP 800';MemoryGb=16}}
    $o2=[pscustomobject]@{Guid=$g2;Family='Inventory';LastSuccessAtUtc='2026-10-12T10:00:00Z';LastAttemptAtUtc='2026-10-13T10:00:00Z';Error='Accès refusé';Data=[pscustomobject]@{Model='HP 800'}}
    $c=@(Get-DomeniaComputerComparison -Rows @($r1,$r2) -Observations @($o1,$o2) -Guids @($g1,$g2))
    $os=@($c|Where-Object{$_.Property -eq 'Système'})[0]
    Assert-Equal 'Windows 11 Pro' $os.V0 'Une valeur AD unique se lit sans crochets';Assert-Equal 'Different' $os.Difference;Assert-Equal '2026-10-09 07:00 UTC' $os.T0 'La date de l attribut est la sienne'
    $state=@($c|Where-Object{$_.Property -eq 'Compte activé'})[0];Assert-Equal 'DateOnly' $state.Difference 'Memes valeurs, dates differentes'
    $model=@($c|Where-Object{$_.Property -eq 'Inventaire · Model'})[0];Assert-Equal 'DateOnly' $model.Difference;Assert-True ($model.T1.Contains('tentative') -and $model.T1.Contains('Accès refusé')) $model.T1
    $memory=@($c|Where-Object{$_.Property -eq 'Inventaire · MemoryGb'})[0];Assert-Equal 'Unknown' $memory.Difference;Assert-Equal 'Non lu' $memory.V1
    $presence=@($c|Where-Object{$_.Property -eq 'Présence réseau'})[0];Assert-Equal 'Unknown' $presence.Difference 'Une famille jamais lue reste une ligne inconnue'
    $pwd=@($c|Where-Object{$_.Property -eq 'Mot de passe machine modifié'})[0];Assert-True ($pwd.V0.EndsWith(' UTC')) $pwd.V0;Assert-Equal 'Non lu' $pwd.V1
    Assert-Throws {Get-DomeniaComputerComparison -Rows @() -Observations @() -Guids @(1..9|ForEach-Object{[guid]::NewGuid().ToString()})} 'Neuf postes acceptes'
}
Test-Case 'P59' 'Apercu : fiche locale datee, attributs bornes, familles du poste, rien d invente' {
    $g='33333333-3333-4333-8333-333333333333'
    $row=[pscustomobject]@{Guid=$g;Name='PC-3';Type='Machine';DN='CN=PC-3,DC=example,DC=invalid';State='Actif';Description='';Login='PC-3';Upn='pc-3.example.invalid';LastLogon='2026-10-01T08:00:00Z';ObservedAtUtc='2026-10-10T08:00:00Z';Details=[pscustomobject]@{operatingsystem=@('Windows 11 Pro');whencreated=@('2025-01-02T03:04:05.0000000Z');a1=1;a2=2;a3=3};FieldTimes=[pscustomobject]@{Name='2026-10-10T08:00:00Z'}}
    $obs=@([pscustomobject]@{Guid=$g;Family='Presence';LastSuccessAtUtc='2026-10-12T09:00:00Z';LastAttemptAtUtc='2026-10-12T09:00:00Z';Error='';Data=[pscustomobject]@{Presence='En ligne'}})
    $p=@(Get-DomeniaSearchPreviewRows -Row $row -Observations $obs -MaximumAttributes 3)
    Assert-Equal 'PC-3' ($p|Where-Object{$_.Property -eq 'Nom'})[0].Value;Assert-Equal '2026-10-10 08:00 UTC' ($p|Where-Object{$_.Property -eq 'Nom'})[0].Date
    Assert-Equal 'Non renseigné dans la base locale' ($p|Where-Object{$_.Property -eq 'Description'})[0].Value 'Une colonne vide n est pas une valeur observee'
    Assert-Equal 1 @($p|Where-Object{$_.Property -eq 'Attributs AD'}).Count 'La borne des attributs est annoncee'
    Assert-Equal 'En ligne' ($p|Where-Object{$_.Property -eq 'Présence réseau · Presence'})[0].Value
    Assert-Equal 'Non lu' ($p|Where-Object{$_.Property -eq 'Inventaire'})[0].Value 'Une famille absente reste non lue'
    Assert-Equal '2025-01-02 03:04 UTC' (ConvertTo-DomeniaComparisonText '2025-01-02T03:04:05.0000000Z' 'whencreated')
    Assert-Equal 'Jamais (valeur maximale)' (ConvertTo-DomeniaComparisonText ([long]::MaxValue) 'accountexpires');Assert-Equal 'Vide observé' (ConvertTo-DomeniaComparisonText @() 'x');Assert-Equal 'a ; b' (ConvertTo-DomeniaComparisonText @('a','b') 'x')
}
