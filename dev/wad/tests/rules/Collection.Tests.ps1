# Verite de la collecte (feuille de route du 13/10/2026, points 4, 5 et 10) : horloges AD, ping et WMI d une OU,
# derniere reussite distincte de la derniere tentative et de son erreur, provenance et dates incoherentes.
# Regles pures, donnees fictives (domaine example.test), horloge fixe.
. (Join-Path $modules 'Domenia-Collection.Model.ps1')
$script:ColNow=[datetime]::SpecifyKind([datetime]'2026-10-14T12:00:00',[DateTimeKind]::Utc)
$script:ColDomain='DC=example,DC=test';$script:ColOu='OU=Postes,'+$script:ColDomain;$script:ColChild='OU=Lyon,'+$script:ColOu
function New-ColRun {
    # One committed run as the local readers project it (Storage.Worker receipt, FleetStats).
    param([string]$Family='Presence',[string]$Scope=$script:ColOu,[bool]$Subtree=$true,[string]$Success='',[string]$Attempt='',[string]$Status='Success',[string]$ErrorText='',[string]$Recorded='2026-10-14T11:00:00.0000000Z',[string]$Domain='dc=example,dc=test',$Done=8,$Targets=10)
    $key=Get-DomeniaCollectionRunKey $Scope $Subtree
    $successData=if($Success){[pscustomobject]@{Format='Domenia.CollectionRun/1';Family=$Family;ScopeDn=$Scope;Subtree=$Subtree;Provider='ICMP';Controller='';CollectorVersion='fixture-1';StartedAtUtc=$Success;FinishedAtUtc=$Success;Targets=$Targets;Done=$Done;Succeeded=$Done;Failed=0;RecordedAtUtc=$Recorded}}else{$null}
    $attemptData=if($Status -ne 'Success'){[pscustomobject]@{Format='Domenia.CollectionRun/1';Family=$Family;ScopeDn=$Scope;Subtree=$Subtree;Provider='ICMP';Controller='';CollectorVersion='fixture-1';StartedAtUtc=$Attempt;FinishedAtUtc=$Attempt;Targets=$Targets;Done=2;Succeeded=0;Failed=2;RecordedAtUtc=$Recorded}}else{$null}
    return [pscustomobject]@{Kind='CollectionRun';DomainDn=$Domain;Family=$Family;RequestKey=$key;LastAttemptAtUtc=$(if($Attempt){$Attempt}else{$Success});Status=$Status;Error=$ErrorText;LastSuccessAtUtc=$Success;Data=$successData;AttemptData=$attemptData;Revision=7}
}

Test-Case 'COL-001' 'La cle de perimetre separe profondeur et casse, et refuse un DN hors annuaire' {
    Assert-Equal ('subtree:'+$script:ColOu.ToLowerInvariant()) (Get-DomeniaCollectionRunKey $script:ColOu $true)
    Assert-Equal ('onelevel:'+$script:ColOu.ToLowerInvariant()) (Get-DomeniaCollectionRunKey $script:ColOu $false)
    Assert-Throws {Get-DomeniaCollectionRunKey 'OU=Sans domaine' $true} 'DN sans composante DC accepte'
    Assert-Throws {Get-DomeniaCollectionRunKey '' $true} 'perimetre vide accepte'
    Assert-Throws {Get-DomeniaCollectionRunKey ("OU=A`n,"+$script:ColDomain) $true} 'caractere de controle accepte'
}
Test-Case 'COL-002' 'Une vue lit son perimetre exact puis ses OU englobantes, jamais une passe directe parente' {
    $keys=@(Get-DomeniaCollectionRunKeys -ScopeDn $script:ColChild -DomainDn $script:ColDomain -Subtree $false)
    Assert-Equal ('onelevel:'+$script:ColChild.ToLowerInvariant()) $keys[0] 'perimetre exact absent'
    Assert-True ($keys -ccontains ('subtree:'+$script:ColOu.ToLowerInvariant())) 'OU englobante absente'
    Assert-True ($keys -ccontains ('subtree:'+$script:ColDomain.ToLowerInvariant())) 'domaine absent'
    Assert-False ($keys -ccontains ('onelevel:'+$script:ColOu.ToLowerInvariant())) 'passe directe parente acceptee'
    Assert-Equal 0 @(Get-DomeniaCollectionRunKeys -ScopeDn 'OU=X,DC=autre,DC=test' -DomainDn $script:ColDomain).Count 'perimetre hors domaine accepte'
    Assert-Equal 0 @(Get-DomeniaCollectionRunKeys -ScopeDn $script:ColOu -DomainDn '').Count 'domaine absent accepte'
    $escaped=@(Get-DomeniaCollectionRunKeys -ScopeDn ('OU=Paris\, Est,'+$script:ColDomain) -DomainDn $script:ColDomain)
    Assert-Equal 2 $escaped.Count 'virgule echappee prise pour une frontiere'
}
Test-Case 'COL-003' 'Un releve enregistre porte sa provenance et refuse les dates impossibles' {
    $change=New-DomeniaCollectionRunChange -Family Presence -DomainDn $script:ColDomain -ScopeDn $script:ColOu -Status Success -AttemptedAtUtc '2026-10-14T10:00:00Z' -FinishedAtUtc '2026-10-14T10:03:00Z' -Targets 10 -Done 10 -Succeeded 9 -Failed 1 -CollectorVersion 'build-1' -NowUtc $script:ColNow
    Assert-Equal 'CollectionRun' $change.Kind;Assert-Equal ('subtree:'+$script:ColOu.ToLowerInvariant()) $change.RequestKey
    Assert-Equal 'ICMP' $change.Data.Provider;Assert-Equal 'build-1' $change.Data.CollectorVersion;Assert-Equal '' $change.Error
    Assert-Equal 10L $change.Data.Targets;Assert-Equal 1L $change.Data.Failed
    Assert-Throws {New-DomeniaCollectionRunChange -Family Presence -DomainDn $script:ColDomain -ScopeDn $script:ColOu -Status Success -AttemptedAtUtc '2026-10-14T12:10:00Z' -FinishedAtUtc '2026-10-14T12:10:00Z' -NowUtc $script:ColNow} 'date future acceptee'
    Assert-Throws {New-DomeniaCollectionRunChange -Family Presence -DomainDn $script:ColDomain -ScopeDn $script:ColOu -Status Success -AttemptedAtUtc '2026-10-14T10:00:00Z' -FinishedAtUtc '2026-10-14T09:00:00Z' -NowUtc $script:ColNow} 'fin avant debut acceptee'
    Assert-Throws {New-DomeniaCollectionRunChange -Family Presence -DomainDn $script:ColDomain -ScopeDn $script:ColOu -Status Success -AttemptedAtUtc '2026-10-14T10:00:00Z' -FinishedAtUtc '2026-10-14T10:00:00Z' -ErrorText 'echec' -NowUtc $script:ColNow} 'reussite avec erreur acceptee'
    Assert-Throws {New-DomeniaCollectionRunChange -Family Presence -DomainDn $script:ColDomain -ScopeDn 'OU=X,DC=autre,DC=test' -Status Success -AttemptedAtUtc '2026-10-14T10:00:00Z' -FinishedAtUtc '2026-10-14T10:00:00Z' -NowUtc $script:ColNow} 'autre domaine accepte'
    Assert-Throws {New-DomeniaCollectionRunChange -Family Presence -DomainDn $script:ColDomain -ScopeDn $script:ColOu -Status Success -AttemptedAtUtc '2026-10-14T10:00:00Z' -FinishedAtUtc '2026-10-14T10:00:00Z' -Targets 2 -Done 3 -NowUtc $script:ColNow} 'plus de postes traites que de cibles'
    $failed=New-DomeniaCollectionRunChange -Family Inventory -DomainDn $script:ColDomain -ScopeDn $script:ColOu -Status Error -AttemptedAtUtc '2026-10-14T10:00:00Z' -FinishedAtUtc '2026-10-14T10:00:00Z' -NowUtc $script:ColNow
    Assert-True ([string]$failed.Error) 'echec sans cause';Assert-Equal $null $failed.Data.Targets 'compteur non mesure invente'
    $long=New-DomeniaCollectionRunChange -Family Inventory -DomainDn $script:ColDomain -ScopeDn $script:ColOu -Status Error -AttemptedAtUtc '2026-10-14T10:00:00Z' -FinishedAtUtc '2026-10-14T10:00:00Z' -ErrorText ('x'*3000) -NowUtc $script:ColNow
    Assert-True ($long.Error.Length -le 1024) 'erreur non bornee'
}
Test-Case 'COL-004' 'Une actualisation n enregistre que les collectes reellement lancees' {
    $directory=[pscustomobject]@{Started=$true;Status='Success';Error='';StartedUtc='2026-10-14T09:00:00Z';FinishedUtc='2026-10-14T09:01:00Z';Controller='dc1.example.test';Count=42L}
    $approved=[pscustomobject]@{Approved=$true;StartedUtc='2026-10-14T09:02:00Z';FinishedUtc='2026-10-14T09:05:00Z';Targets=10L;Done=10L;Failed=0L;Stopping=$false;FailureMessage='';StorageConfirmed=$true}
    $both=@(New-DomeniaRefreshRunChanges -Mode Both -DomainDn $script:ColDomain -ScopeDn $script:ColOu -Directory $directory -Collection $approved -CollectorVersion 'b' -NowUtc $script:ColNow)
    Assert-Equal 'Directory,Presence,Inventory' (@($both|ForEach-Object{$_.Family}) -join ',')
    Assert-Equal 'dc1.example.test' $both[0].Data.Controller;Assert-Equal 42L $both[0].Data.Done;Assert-Equal 'Success' $both[1].Status
    $declined=[pscustomobject]@{Approved=$false;StartedUtc='';Targets=10L;Done=0L;Failed=0L;Stopping=$true;FailureMessage='';StorageConfirmed=$true}
    Assert-Equal 'Directory' (@(New-DomeniaRefreshRunChanges -Mode Both -DomainDn $script:ColDomain -ScopeDn $script:ColOu -Directory $directory -Collection $declined -NowUtc $script:ColNow|ForEach-Object{$_.Family}) -join ',') 'confirmation refusee enregistree comme tentative'
    $notStarted=[pscustomobject]@{Started=$false}
    Assert-Equal 0 @(New-DomeniaRefreshRunChanges -Mode AD -DomainDn $script:ColDomain -ScopeDn $script:ColOu -Directory $notStarted -Outcome Error -OutcomeMessage 'refus' -NowUtc $script:ColNow).Count 'lecture AD jamais admise enregistree'
    $adFailed=@(New-DomeniaRefreshRunChanges -Mode Both -DomainDn $script:ColDomain -ScopeDn $script:ColOu -Directory ([pscustomobject]@{Started=$true;Status='';Error='';StartedUtc='2026-10-14T09:00:00Z';FinishedUtc='';Controller='';Count=-1L}) -Outcome Error -OutcomeMessage 'Acces refuse par le controleur.' -NowUtc $script:ColNow)
    Assert-Equal 1 $adFailed.Count 'ping ou WMI enregistres sans lancement';Assert-Equal 'Error' $adFailed[0].Status;Assert-True ($adFailed[0].Error -like '*refuse*') 'cause AD perdue'
    $partial=[pscustomobject]@{Approved=$true;StartedUtc='2026-10-14T09:02:00Z';FinishedUtc='2026-10-14T09:05:00Z';Targets=10L;Done=10L;Failed=3L;Stopping=$false;FailureMessage='';StorageConfirmed=$true}
    $ping=@(New-DomeniaRefreshRunChanges -Mode Ping -DomainDn $script:ColDomain -ScopeDn $script:ColOu -Collection $partial -NowUtc $script:ColNow)
    Assert-Equal 1 $ping.Count;Assert-Equal 'Presence' $ping[0].Family;Assert-Equal 'Partial' $ping[0].Status;Assert-Equal 7L $ping[0].Data.Succeeded
    $unsaved=$approved.PSObject.Copy();$unsaved.StorageConfirmed=$false
    Assert-Equal 'Error' @(New-DomeniaRefreshRunChanges -Mode Wmi -DomainDn $script:ColDomain -ScopeDn $script:ColOu -Collection $unsaved -NowUtc $script:ColNow)[0].Status 'reussite annoncee sans enregistrement'
    $stopped=$approved.PSObject.Copy();$stopped.Stopping=$true;$stopped.Done=4L
    $cancel=@(New-DomeniaRefreshRunChanges -Mode Wmi -DomainDn $script:ColDomain -ScopeDn $script:ColOu -Collection $stopped -NowUtc $script:ColNow)[0]
    Assert-Equal 'Cancelled' $cancel.Status;Assert-True ($cancel.Error -like '*4/10*') 'progression absente'
}
Test-Case 'COL-005' 'Un echec plus recent n efface ni ne rajeunit la derniere reussite' {
    $runs=@((New-ColRun -Family Presence -Success '2026-10-14T08:00:00.0000000Z' -Attempt '2026-10-14T10:00:00.0000000Z' -Status Error -ErrorText 'Identifiants refuses'))
    $clock=Get-DomeniaCollectionClock -Runs $runs -Family Presence -ScopeDn $script:ColOu -DomainDn $script:ColDomain -NowUtc $script:ColNow
    Assert-Equal 'SuccessThenFailure' $clock.State
    Assert-Equal 8 $clock.Success.AtUtc.Hour 'reussite rajeunie ou perdue';Assert-Equal 10 $clock.Attempt.AtUtc.Hour
    Assert-True $clock.AttemptFailedAfterSuccess
    $text=Format-DomeniaCollectionClock $clock -NowUtc $script:ColNow
    Assert-True ($text.Text -like 'relevé réussi le *dernière tentative le *en échec*Identifiants refuses*la dernière réussite reste la référence*') ('texte : '+$text.Text)
    Assert-True ($text.Detail -like '*fournisseur ICMP*version de collecte fixture-1*') 'provenance absente du detail'
    $later=@((New-ColRun -Family Presence -Success '2026-10-14T11:00:00.0000000Z'))
    $fresh=Get-DomeniaCollectionClock -Runs ($runs+$later) -Family Presence -ScopeDn $script:ColOu -DomainDn $script:ColDomain -NowUtc $script:ColNow
    Assert-Equal 11 $fresh.Success.AtUtc.Hour;Assert-False $fresh.AttemptFailedAfterSuccess 'ancien echec masque une reussite plus recente'
}
Test-Case 'COL-006' 'Un releve de l OU englobante date la sous-OU, jamais un autre domaine ou une autre famille' {
    $parent=New-ColRun -Family Inventory -Success '2026-10-14T09:00:00.0000000Z'
    $other=New-ColRun -Family Inventory -Success '2026-10-14T11:00:00.0000000Z' -Domain 'dc=autre,dc=test'
    $ping=New-ColRun -Family Presence -Success '2026-10-14T11:30:00.0000000Z' -Scope $script:ColChild
    $clock=Get-DomeniaCollectionClock -Runs @($parent,$other,$ping) -Family Inventory -ScopeDn $script:ColChild -DomainDn $script:ColDomain -NowUtc $script:ColNow
    Assert-Equal 9 $clock.Success.AtUtc.Hour 'autre domaine ou autre famille retenu';Assert-True $clock.Success.Inherited 'heritage non signale'
    Assert-True ((Format-DomeniaCollectionClock $clock -NowUtc $script:ColNow).Text -like '*via une OU englobante*') 'heritage absent du texte'
    $direct=New-ColRun -Family Inventory -Success '2026-10-14T11:45:00.0000000Z' -Scope $script:ColOu -Subtree $false
    $child=Get-DomeniaCollectionClock -Runs @($parent,$direct) -Family Inventory -ScopeDn $script:ColChild -DomainDn $script:ColDomain -NowUtc $script:ColNow
    Assert-Equal 9 $child.Success.AtUtc.Hour 'passe directe de l OU parente appliquee aux descendants'
    $none=Get-DomeniaCollectionClock -Runs @() -Family Presence -ScopeDn $script:ColOu -DomainDn $script:ColDomain -NowUtc $script:ColNow
    Assert-Equal 'NeverRecorded' $none.State;Assert-Equal '' (Format-DomeniaCollectionClock $none -NowUtc $script:ColNow).Text 'date inventee pour un perimetre jamais releve'
}
Test-Case 'COL-007' 'Les dates incoherentes sont signalees et jamais corrigees' {
    $future=Test-DomeniaCollectionClock -ObservedUtc '2026-10-14T12:30:00Z' -NowUtc $script:ColNow
    Assert-False $future.Coherent;Assert-Equal 'Future' $future.Issues[0].Code
    $saved=Test-DomeniaCollectionClock -ObservedUtc '2026-10-14T10:00:00Z' -FinishedUtc '2026-10-14T10:30:00Z' -RecordedUtc '2026-10-14T10:05:00Z' -NowUtc $script:ColNow
    Assert-True (@($saved.Issues|Where-Object{$_.Code -eq 'RecordedBeforeObserved'}).Count -eq 1) 'enregistrement avant collecte non signale'
    $reverse=Test-DomeniaCollectionClock -ObservedUtc '2026-10-14T10:00:00Z' -FinishedUtc '2026-10-14T09:00:00Z' -NowUtc $script:ColNow
    Assert-True (@($reverse.Issues|Where-Object{$_.Code -eq 'EndBeforeStart'}).Count -eq 1) 'fin avant debut non signalee'
    $broken=Test-DomeniaCollectionClock -ObservedUtc 'pas une date' -NowUtc $script:ColNow
    Assert-Equal 'Unreadable' $broken.Issues[0].Code
    $ok=Test-DomeniaCollectionClock -ObservedUtc '2026-10-14T10:00:00Z' -FinishedUtc '2026-10-14T10:02:00Z' -AttemptUtc '2026-10-14T10:00:00Z' -RecordedUtc '2026-10-14T10:02:01Z' -NowUtc $script:ColNow
    Assert-True $ok.Coherent ('faux positif : '+$ok.Text)
    $run=New-ColRun -Family Presence -Success '2026-10-14T10:00:00.0000000Z' -Recorded '2026-10-14T09:00:00.0000000Z'
    $clock=Get-DomeniaCollectionClock -Runs @($run) -Family Presence -ScopeDn $script:ColOu -DomainDn $script:ColDomain -NowUtc $script:ColNow
    Assert-Equal 'Incoherent' $clock.State
    $text=Format-DomeniaCollectionClock $clock -NowUtc $script:ColNow
    Assert-True (([bool]$text.Warning) -and ($text.Text -like '*Dates incohérentes*')) 'incoherence absente du texte'
}
Test-Case 'COL-008' 'Le resume des trois horloges reste muet sur ce qui n a pas ete releve' {
    $clocks=Get-DomeniaCollectionClocks -Runs @() -ScopeDn $script:ColOu -DomainDn $script:ColDomain -NowUtc $script:ColNow
    $summary=Format-DomeniaCollectionClocks $clocks -NowUtc $script:ColNow
    Assert-Equal '' $summary.DirectoryText;Assert-True ($summary.RunsText -like '*aucun relevé ping ou WMI*') 'absence de releve non dite'
    $ad=New-ColRun -Family Directory -Success '2026-10-14T08:00:00.0000000Z' -Attempt '2026-10-14T09:00:00.0000000Z' -Status Error -ErrorText 'Serveur indisponible'
    $summary=Format-DomeniaCollectionClocks (Get-DomeniaCollectionClocks -Runs @($ad) -ScopeDn $script:ColOu -DomainDn $script:ColDomain -NowUtc $script:ColNow) -NowUtc $script:ColNow
    Assert-True ($summary.DirectoryText -like 'dernière tentative le *Serveur indisponible*') ('AD : '+$summary.DirectoryText)
    Assert-True $summary.Warning
}
Test-Case 'COL-009' 'La provenance d une mesure nomme reussite, tentative, ecriture locale et definition' {
    $observation=[pscustomobject]@{LastSuccessAtUtc='2026-10-14T09:00:00.0000000Z';LastAttemptAtUtc='2026-10-14T10:00:00.0000000Z';Status='Error';Error='Classe absente';RecordedAtUtc='2026-10-14T10:00:02.0000000Z';DefinitionHash='0123456789abcdef0123'}
    $text=Format-DomeniaObservationProvenance -Observation $observation -NowUtc $script:ColNow
    Assert-True $text.Coherent ('faux positif : '+$text.Text)
    Assert-True ($text.Text -like 'Réussite UTC : 2026-10-14T09:00:00*Tentative UTC : 2026-10-14T10:00:00*non confirmée : Classe absente*Écriture locale UTC : 2026-10-14T10:00:02*Définition de collecte : 0123456789ab') $text.Text
    $legacy=[pscustomobject]@{LastSuccessAtUtc='2026-10-14T09:00:00Z';LastAttemptAtUtc='2026-10-14T09:00:00Z';Status='Success';Error='';RecordedAtUtc='';DefinitionHash=''}
    Assert-True ((Format-DomeniaObservationProvenance -Observation $legacy -NowUtc $script:ColNow).Text -like '*Écriture locale UTC : non conservée*') 'ecriture inconnue presentee comme connue'
    $bad=[pscustomobject]@{LastSuccessAtUtc='2026-10-14T11:00:00Z';LastAttemptAtUtc='2026-10-14T11:00:00Z';Status='Success';Error='';RecordedAtUtc='2026-10-14T10:00:00Z';DefinitionHash=''}
    $result=Format-DomeniaObservationProvenance -Observation $bad -NowUtc $script:ColNow
    Assert-False $result.Coherent 'enregistrement anterieur a la mesure accepte';Assert-True ($result.Text -like '*Dates incohérentes*') $result.Text
}
# Point 3 : etats d une mesure. Absent, non lu, refuse, perime, incomplet et erreur ne deviennent jamais connus.
function New-ColObservation {
    param([hashtable]$Fields=@{},[hashtable]$Times=@{})
    $o=[ordered]@{Guid='guid-1';Key='cn=pc-1,ou=postes,dc=example,dc=test'};foreach($k in $Fields.Keys){$o[$k]=$Fields[$k]}
    $t=[ordered]@{};foreach($k in $Times.Keys){$t[$k]=$Times[$k]};$o.Times=[pscustomobject]$t
    return [pscustomobject]$o
}
Test-Case 'COL-010' 'Une presence sans releve, non verifiee ou en echec n est jamais connue' {
    Assert-Equal 'Absent' (Get-DomeniaMeasureState -Observation $null -Family Presence -NowUtc $script:ColNow).State
    Assert-Equal 'Absent' (Get-DomeniaMeasureState -Observation (New-ColObservation) -Family Presence -NowUtc $script:ColNow).State 'famille absente'
    $ok=New-ColObservation @{Presence='En ligne';PresenceCheckedUtc='2026-10-14T10:00:00Z'} @{Presence=[pscustomobject]@{ObservedUtc='2026-10-14T10:00:00Z';LastAttemptUtc='2026-10-14T10:00:00Z';Succeeded=$true}}
    $known=Get-DomeniaMeasureState -Observation $ok -Family Presence -NowUtc $script:ColNow
    Assert-Equal 'Known' $known.State;Assert-False $known.LastAttemptFailed
    $notChecked=New-ColObservation @{Presence='Non vérifié';PresenceCheckedUtc='2026-10-14T10:00:00Z'}
    Assert-Equal 'NotRead' (Get-DomeniaMeasureState -Observation $notChecked -Family Presence -NowUtc $script:ColNow).State
    $failed=New-ColObservation @{Presence='Erreur de ping';PresenceCheckedUtc='2026-10-14T08:00:00Z';PresenceAttemptUtc='2026-10-14T11:00:00Z';PresenceError='Hôte introuvable'} @{Presence=[pscustomobject]@{ObservedUtc='2026-10-14T08:00:00Z';LastAttemptUtc='2026-10-14T11:00:00Z';Succeeded=$false}}
    $state=Get-DomeniaMeasureState -Observation $failed -Family Presence -NowUtc $script:ColNow
    Assert-Equal 'Error' $state.State 'ping en echec presente comme etat actuel'
    Assert-Equal 8 $state.LastSuccessUtc.Hour 'derniere reussite perdue';Assert-True $state.LastAttemptFailed
    $future=New-ColObservation @{Presence='En ligne';PresenceCheckedUtc='2026-10-14T13:00:00Z'}
    Assert-Equal 'Error' (Get-DomeniaMeasureState -Observation $future -Family Presence -NowUtc $script:ColNow).State 'date future acceptee'
    $old=New-ColObservation @{Presence='En ligne';PresenceCheckedUtc='2026-08-01T10:00:00Z'}
    Assert-Equal 'Expired' (Get-DomeniaMeasureState -Observation $old -Family Presence -NowUtc $script:ColNow -MaxDays 30).State
}
Test-Case 'COL-011' 'Un inventaire garde sa valeur datee apres un echec ; un refus reste un refus' {
    $kept=New-ColObservation @{Inventory=[pscustomobject]@{CheckedUtc='2026-10-13T10:00:00Z';Model='X'};InventoryAttemptUtc='2026-10-14T10:00:00Z';InventoryError='Délai dépassé'} @{Inventory=[pscustomobject]@{ObservedUtc='2026-10-13T10:00:00Z';LastAttemptUtc='2026-10-14T10:00:00Z';Succeeded=$false}}
    $state=Get-DomeniaMeasureState -Observation $kept -Family Inventory -NowUtc $script:ColNow
    Assert-Equal 'Known' $state.State 'valeur valide effacee par un echec';Assert-True $state.LastAttemptFailed;Assert-Equal 'Délai dépassé' $state.Error
    $refused=New-ColObservation @{InventoryAttemptUtc='2026-10-14T10:00:00Z';InventoryError='Accès refusé (0x80070005)'} @{Inventory=[pscustomobject]@{ObservedUtc='';LastAttemptUtc='2026-10-14T10:00:00Z';Succeeded=$false}}
    Assert-Equal 'Refused' (Get-DomeniaMeasureState -Observation $refused -Family Inventory -NowUtc $script:ColNow).State
    $failed=New-ColObservation @{InventoryAttemptUtc='2026-10-14T10:00:00Z';InventoryError='RPC indisponible'}
    Assert-Equal 'Error' (Get-DomeniaMeasureState -Observation $failed -Family Inventory -NowUtc $script:ColNow).State
    $broken=New-ColObservation @{Inventory=[pscustomobject]@{CheckedUtc='pas une date'}}
    Assert-Equal 'Error' (Get-DomeniaMeasureState -Observation $broken -Family Inventory -NowUtc $script:ColNow).State
    $console=New-ColObservation @{Outcome='AuthRejected';ConsoleAttemptUtc='2026-10-14T10:00:00Z';ConsoleError='Compte distant refusé'} @{Console=[pscustomobject]@{ObservedUtc='';LastAttemptUtc='2026-10-14T10:00:00Z';Succeeded=$false}}
    Assert-Equal 'Refused' (Get-DomeniaMeasureState -Observation $console -Family Console -NowUtc $script:ColNow).State
}
Test-Case 'COL-012' 'Une sonde non applicable, tronquee ou non confirmee reste distincte d une valeur' {
    $probe={param($Entry) New-ColObservation @{Probes=[pscustomobject]@{'disk.cfree'=$Entry}}}
    Assert-Equal 'NotRead' (Get-DomeniaMeasureState -Observation (& $probe ([pscustomobject]@{AttemptedUtc='2026-10-14T10:00:00Z';Skipped='DomainController';Error='Sonde non applicable au systeme.'})) -Family 'Probe:disk.cfree' -NowUtc $script:ColNow).State
    Assert-Equal 'Incomplete' (Get-DomeniaMeasureState -Observation (& $probe ([pscustomobject]@{CheckedUtc='2026-10-14T10:00:00Z';Truncated=$true;Mode='First'})) -Family 'Probe:disk.cfree' -NowUtc $script:ColNow).State
    Assert-Equal 'Known' (Get-DomeniaMeasureState -Observation (& $probe ([pscustomobject]@{CheckedUtc='2026-10-14T10:00:00Z';Truncated=$true;Mode='Count';CountComplete=$true})) -Family 'Probe:disk.cfree' -NowUtc $script:ColNow).State 'compte complet refuse'
    Assert-Equal 'Error' (Get-DomeniaMeasureState -Observation (& $probe ([pscustomobject]@{AttemptedUtc='2026-10-14T10:00:00Z';Succeeded=$false})) -Family 'Probe:disk.cfree' -NowUtc $script:ColNow).State
    Assert-Equal 'Absent' (Get-DomeniaMeasureState -Observation (& $probe ([pscustomobject]@{CheckedUtc='2026-10-14T10:00:00Z'})) -Family 'Probe:hw.ram' -NowUtc $script:ColNow).State 'autre sonde lue'
    Assert-Throws {Get-DomeniaMeasureState -Observation $null -Family 'Probe:a b' -NowUtc $script:ColNow} 'famille invalide acceptee'
}
Test-Case 'COL-013' 'Le decompte par etat couvre toute la population sans compter un inconnu comme mesure' {
    $items=@(
        [pscustomobject]@{Key='A';Observation=(New-ColObservation @{Presence='En ligne';PresenceCheckedUtc='2026-10-14T10:00:00Z'})}
        [pscustomobject]@{Key='a';Observation=(New-ColObservation @{Presence='En ligne';PresenceCheckedUtc='2026-10-14T09:00:00Z'})}
        [pscustomobject]@{Key='B';Observation=(New-ColObservation @{Presence='En ligne';PresenceCheckedUtc='2026-08-01T10:00:00Z'})}
        [pscustomobject]@{Key='C';Observation=(New-ColObservation @{Presence='Erreur de ping';PresenceCheckedUtc='';PresenceAttemptUtc='2026-10-14T10:00:00Z';PresenceError='DNS'})}
    )
    $measure=Measure-DomeniaMeasureStates -Items $items -Total 5 -Family Presence -NowUtc $script:ColNow -MaxDays 30
    Assert-Equal 1 $measure.Known 'doublon compte deux fois';Assert-Equal 10 $measure.NewestUtc.Hour 'mesure la plus recente du doublon perdue'
    Assert-Equal 1 ([int]$measure.Counts.Expired);Assert-Equal 1 ([int]$measure.Counts.Error);Assert-Equal 2 ([int]$measure.Counts.Absent) 'poste sans releve oublie'
    Assert-Equal 5 $measure.Total
    Assert-Equal '2 jamais relevés, 1 périmé, 1 en erreur' (Format-DomeniaMeasureStates $measure.Counts)
    $all=Measure-DomeniaMeasureStates -Items @($items[0]) -Total 1 -Family Presence -NowUtc $script:ColNow
    Assert-Equal '' (Format-DomeniaMeasureStates $all.Counts) 'etat inconnu invente'
    Assert-Equal 'Refusé' (Get-DomeniaMeasureStateLabel 'Refused');Assert-Equal 'En erreur' (Get-DomeniaMeasureStateLabel 'Inattendu')
}
