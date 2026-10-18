# Domenia-Collection.Model : regles pures, donnees fictives (domaine example.test), horloge fixe.
# - Verite de la collecte (feuille de route du 13/10/2026, points 4, 5 et 10) : horloges AD, ping et WMI d une OU,
#   derniere reussite distincte de la derniere tentative et de son erreur, provenance et dates incoherentes.
# - Collecte adaptee aux reseaux lents (points 11, 13 a 20, 159 et 160), sans reseau ni base.
. (Join-Path $modules 'Domenia-Collection.Model.ps1')
. (Join-Path $modules 'Domenia-HealthRules.Model.ps1')
. (Join-Path $modules 'Domenia-Boards.Model.ps1')
. (Join-Path $modules 'Domenia-Park.Model.ps1')
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
    # One vocabulary: the counters carry exactly the state keys, in their order (the WMI answer of the board uses them).
    Assert-Equal 'Known,Absent,NotRead,Refused,Expired,Incomplete,Error' ((@(Get-DomeniaMeasureStateKeys)) -join ',')
    Assert-Equal ((@(Get-DomeniaMeasureStateKeys)) -join ',') ((@($measure.Counts.PSObject.Properties|ForEach-Object{$_.Name})) -join ',') 'compteurs hors vocabulaire'
}
# Point 2 : populations comparees.
Test-Case 'COL-014' 'Deux chiffres ne se comparent que sur le meme domaine, perimetre, profondeur, types, criteres et instantane' {
    $base=New-DomeniaPopulationDescriptor -DomainDn $script:ColDomain -ScopeDn $script:ColOu -Subtree $true -Types @('Machine') -Criteria 'comptes recensés' -StoreId 'store-1' -SnapshotRevision 12
    Assert-Equal 'dc=example,dc=test' $base.DomainDn;Assert-Equal 64 $base.Key.Length
    Assert-True ($base.Text -like 'comptes ordinateur · OU=Postes,DC=example,DC=test et ses sous-OU · comptes recensés · base locale, révision 12') $base.Text
    $same=New-DomeniaPopulationDescriptor -DomainDn 'dc=EXAMPLE,dc=test' -ScopeDn $script:ColOu -Subtree $true -Types @('Machine','Machine') -Criteria 'comptes recensés' -StoreId 'store-1' -SnapshotRevision 12
    Assert-Equal $base.Key $same.Key 'casse du domaine ou doublon de type change la population'
    Assert-True (Compare-DomeniaPopulation $base $same).Same
    $variants=@{
        'périmètre'=(New-DomeniaPopulationDescriptor -DomainDn $script:ColDomain -ScopeDn $script:ColChild -Subtree $true -Types @('Machine') -Criteria 'comptes recensés' -StoreId 'store-1' -SnapshotRevision 12)
        'profondeur'=(New-DomeniaPopulationDescriptor -DomainDn $script:ColDomain -ScopeDn $script:ColOu -Subtree $false -Types @('Machine') -Criteria 'comptes recensés' -StoreId 'store-1' -SnapshotRevision 12)
        'types dʼobjets'=(New-DomeniaPopulationDescriptor -DomainDn $script:ColDomain -ScopeDn $script:ColOu -Subtree $true -Types @('Machine','Utilisateur') -Criteria 'comptes recensés' -StoreId 'store-1' -SnapshotRevision 12)
        'critères'=(New-DomeniaPopulationDescriptor -DomainDn $script:ColDomain -ScopeDn $script:ColOu -Subtree $true -Types @('Machine') -Criteria 'comptes activés' -StoreId 'store-1' -SnapshotRevision 12)
        'instantané de la base'=(New-DomeniaPopulationDescriptor -DomainDn $script:ColDomain -ScopeDn $script:ColOu -Subtree $true -Types @('Machine') -Criteria 'comptes recensés' -StoreId 'store-1' -SnapshotRevision 13)
    }
    foreach($name in @($variants.Keys)){
        $compare=Compare-DomeniaPopulation $base $variants[$name]
        Assert-False $compare.Same ('difference non vue : '+$name);Assert-Equal $name ((@($compare.Differences)) -join ',') ('difference mal nommee : '+$name)
        Assert-True ($base.Key -cne $variants[$name].Key) ('cle identique malgre : '+$name)
    }
    Assert-False (Compare-DomeniaPopulation $base $null).Same 'population absente presumee identique'
    Assert-Throws {New-DomeniaPopulationDescriptor -DomainDn '' -ScopeDn $script:ColOu} 'domaine absent accepte'
    Assert-Throws {New-DomeniaPopulationDescriptor -DomainDn $script:ColDomain -ScopeDn 'OU=X,DC=autre,DC=test'} 'perimetre hors domaine accepte'
    Assert-Throws {New-DomeniaPopulationDescriptor -DomainDn $script:ColDomain -Types @('Imprimante')} 'type inconnu accepte'
    $domain=New-DomeniaPopulationDescriptor -DomainDn $script:ColDomain
    Assert-True ($domain.Text -like 'tous types dʼobjets · tout le domaine indexé · révision de la base non connue') $domain.Text
}
Test-Case 'COL-015' 'La vue directe d une OU datee par le releve de son propre sous-arbre n est pas dite heritee' {
    $own=New-ColRun -Family Presence -Success '2026-10-14T10:00:00.0000000Z' -Scope $script:ColOu -Subtree $true
    $clock=Get-DomeniaCollectionClock -Runs @($own) -Family Presence -ScopeDn $script:ColOu -DomainDn $script:ColDomain -Subtree $false -NowUtc $script:ColNow
    Assert-Equal 10 $clock.Success.AtUtc.Hour 'releve du sous-arbre de l OU non retenu pour sa vue directe'
    Assert-False $clock.Success.Inherited 'releve de la meme OU dit herite'
    $text=Format-DomeniaCollectionClock $clock -NowUtc $script:ColNow
    Assert-False ($text.Text -like '*OU englobante*') ('texte : '+$text.Text)
    Assert-False ($text.Detail -like '*OU englobante*') ('infobulle : '+$text.Detail)
    $domain=New-ColRun -Family Presence -Success '2026-10-14T10:00:00.0000000Z' -Scope $script:ColDomain
    $root=Get-DomeniaCollectionClock -Runs @($domain) -Family Presence -ScopeDn '' -DomainDn $script:ColDomain -NowUtc $script:ColNow
    Assert-False $root.Success.Inherited 'releve du domaine dit herite pour la vue du domaine'
    $child=Get-DomeniaCollectionClock -Runs @($own) -Family Presence -ScopeDn $script:ColChild -DomainDn $script:ColDomain -NowUtc $script:ColNow
    Assert-True $child.Success.Inherited 'releve de l OU parente non signale pour la sous-OU'
}
Test-Case 'COL-016' 'Une lecture AD compte des objets AD, un releve de postes compte des postes' {
    $ad=New-ColRun -Family Directory -Success '2026-10-14T10:00:00.0000000Z' -Done 1234 -Targets $null
    $clock=Get-DomeniaCollectionClock -Runs @($ad) -Family Directory -ScopeDn $script:ColOu -DomainDn $script:ColDomain -NowUtc $script:ColNow
    $text=Format-DomeniaCollectionClock $clock -NowUtc $script:ColNow
    Assert-True ($text.Detail -like '*1234 objets AD*') ('infobulle AD : '+$text.Detail)
    Assert-False ($text.Detail -like '*1234 poste*') ('objets AD comptes comme postes : '+$text.Detail)
    Assert-Equal '1 objet AD' (Format-DomeniaCollectionCounts ([pscustomobject]@{Done=1;Targets=$null;Failed=$null}) -Family Directory)
    Assert-Equal '8/10 postes, 2 non confirmés' (Format-DomeniaCollectionCounts ([pscustomobject]@{Done=8;Targets=10;Failed=2}) -Family Presence)
}

# ================================================================ collecte adaptee aux reseaux lents
$script:CT0 = [datetime]::SpecifyKind([datetime]'2026-10-14T10:00:00',[DateTimeKind]::Utc)

# ---------------------------------------------------------------- point 11
Test-Case 'P11' 'Profils : chaque famille a une durée, Standard reprend les durées historiques' {
    foreach ($profile in @(Get-DomeniaCollectionProfiles)) {
        foreach ($family in @(Get-DomeniaFreshnessFamilies)) { Assert-True ($profile.Seconds.ContainsKey([string]$family.Id)) ($profile.Id + ' sans ' + $family.Id) }
        Assert-True ([bool](ConvertFrom-DomeniaCollectionWindowText ([string]$profile.Windows)).Valid) ('Fenêtre par défaut invalide : ' + $profile.Id)
    }
    $standard = Resolve-DomeniaFreshnessTable 'Standard' $null
    Assert-Equal 120 $standard.Seconds['Presence']; Assert-Equal 300 $standard.Seconds['Console']; Assert-Equal 900 $standard.Seconds['Attributes']
    Assert-Equal 300 $standard.Seconds['Inventory']; Assert-Equal 60 $standard.Seconds['VolatileProbe']; Assert-Equal 900 $standard.Seconds['StaticProbe']
    Assert-Equal 'Presence,Console,Attributes,Inventory,StaticProbe,VolatileProbe' (@(Get-DomeniaFreshnessFamilies | ForEach-Object { [string]$_.Id }) -join ',') 'Seules les familles appliquées par un lecteur sont proposées'
    Assert-False $standard.Seconds.ContainsKey('Identity') 'Aucune durée sans lecteur'
    Assert-Equal 'Standard' (Resolve-DomeniaFreshnessTable 'Inexistant' $null).Profile 'Profil inconnu : Standard'
}
Test-Case 'P11' 'Durées personnalisées : famille inconnue, valeur non entière ou hors bornes ignorées et signalées' {
    $o = ConvertFrom-DomeniaFreshnessOverrides '{"Presence":600,"Inconnue":5,"Console":"abc","Identity":10}'
    Assert-Equal 600 $o.Values['Presence']
    Assert-False $o.Values.ContainsKey('Console'); Assert-False $o.Values.ContainsKey('Identity')
    Assert-Equal 3 @($o.Errors).Count
    $bad = ConvertFrom-DomeniaFreshnessOverrides '{pas du json'
    Assert-Equal 0 $bad.Values.Count; Assert-Equal 1 @($bad.Errors).Count
    Assert-Equal 0 (ConvertFrom-DomeniaFreshnessOverrides '').Values.Count
}
Test-Case 'P11' 'Une durée personnalisée remplace celle du profil et le tableau le dit' {
    $t = Resolve-DomeniaFreshnessTable 'SlowNetwork' @{Inventory=60}
    Assert-Equal 60 $t.Seconds['Inventory']
    $row = @($t.Rows | Where-Object { $_.Family -eq 'Inventory' })[0]
    Assert-Equal 'Personnalisé' $row.Source; Assert-Equal 3600 $row.ProfileSeconds; Assert-Equal '1 min' $row.Duration
    Assert-Equal 'Profil' (@($t.Rows | Where-Object { $_.Family -eq 'Presence' })[0]).Source
    $text = ConvertTo-DomeniaFreshnessOverridesText @{VolatileProbe=30;Presence=600}
    Assert-Equal '{"Presence":600,"VolatileProbe":30}' $text
    Assert-Equal 30 (ConvertFrom-DomeniaFreshnessOverrides $text).Values['VolatileProbe']
    Assert-Equal '' (ConvertTo-DomeniaFreshnessOverridesText @{})
}
Test-Case 'P11' 'Fraîcheur : la table du profil remplace la durée de la nature, lʼhistorique ne vieillit pas' {
    $t = Resolve-DomeniaFreshnessTable 'Troubleshooting' $null
    Assert-Equal 'Stale' (Get-DomeniaFreshness 'Presence' $script:CT0 $null $script:CT0.AddSeconds(60) $t).State
    Assert-Equal 'Fresh' (Get-DomeniaFreshness 'Presence' $script:CT0 $null $script:CT0.AddSeconds(60)).State 'Sans table : 120 s'
    Assert-Equal 'Historical' (Get-DomeniaFreshness 'History' $script:CT0 $null $script:CT0.AddDays(30) $t).State
    Assert-Equal 'Fresh' (Get-DomeniaFreshness 'Presence' $script:CT0 $null $script:CT0.AddSeconds(500) @{Presence=600}).State 'Dictionnaire famille vers secondes'
    $record = [pscustomobject]@{Times=@{Attributes=[pscustomobject]@{ObservedUtc=$script:CT0.ToString('o');LastAttemptUtc=$script:CT0.ToString('o')}}}
    Assert-Equal 'Fresh' (Get-DomeniaRecordFreshness $record 'Attributes' $script:CT0.AddMinutes(30) (Resolve-DomeniaFreshnessTable 'SlowNetwork' $null)).State
    Assert-Equal 'Stale' (Get-DomeniaRecordFreshness $record 'Attributes' $script:CT0.AddMinutes(30)).State
}
Test-Case 'P11' 'Plan de collecte : durée retenue la plus courte du profil et du plafond, zéro force la relecture' {
    $previous = [pscustomobject]@{Guid='g1';Key='cn=pc-1';InventoryError='';Inventory=[pscustomobject]@{CheckedUtc=$script:CT0.AddMinutes(-20).ToString('o')}
        Probes=[pscustomobject]@{'hw.bios'=[pscustomobject]@{CheckedUtc=$script:CT0.AddMinutes(-20).ToString('o');DefinitionHash='h1'};'net.adapter'=[pscustomobject]@{CheckedUtc=$script:CT0.AddMinutes(-4).ToString('o');DefinitionHash='h2'}}}
    $probes = @([pscustomobject]@{Id='hw.bios';DefinitionHash='h1'},[pscustomobject]@{Id='net.adapter';DefinitionHash='h2'})
    $standard = New-DomeniaCollectionPlan -Previous $previous -Guid 'g1' -Key 'cn=pc-1' -Probes $probes -Inventory $true -CacheMinutes 15 -NowUtc $script:CT0 -Freshness (Resolve-DomeniaFreshnessTable 'Standard' $null)
    Assert-Equal 0 $standard.Reused; Assert-True $standard.Inventory; Assert-Equal 2 @($standard.Probes).Count
    $slow = New-DomeniaCollectionPlan -Previous $previous -Guid 'g1' -Key 'cn=pc-1' -Probes $probes -Inventory $true -CacheMinutes 60 -NowUtc $script:CT0 -Freshness (Resolve-DomeniaFreshnessTable 'SlowNetwork' $null)
    Assert-Equal 3 $slow.Reused; Assert-False $slow.Inventory; Assert-Equal 0 @($slow.Probes).Count
    $capped = New-DomeniaCollectionPlan -Previous $previous -Guid 'g1' -Key 'cn=pc-1' -Probes $probes -Inventory $true -CacheMinutes 5 -NowUtc $script:CT0 -Freshness (Resolve-DomeniaFreshnessTable 'SlowNetwork' $null)
    Assert-Equal 1 $capped.Reused 'Le plafond de 5 min ne garde que la sonde de 4 min'
    $forced = New-DomeniaCollectionPlan -Previous $previous -Guid 'g1' -Key 'cn=pc-1' -Probes $probes -Inventory $true -CacheMinutes 0 -NowUtc $script:CT0 -Freshness (Resolve-DomeniaFreshnessTable 'SlowNetwork' $null)
    Assert-Equal 0 $forced.Reused
    $legacy = New-DomeniaCollectionPlan -Previous $previous -Guid 'g1' -Key 'cn=pc-1' -Probes $probes -Inventory $true -CacheMinutes 15 -NowUtc $script:CT0
    Assert-Equal $standard.Reused $legacy.Reused 'Sans table : durées historiques'
}

# ---------------------------------------------------------------- point 159
$script:Monday10 = [datetime]'2026-10-12T10:00:00'
$script:Monday1230 = [datetime]'2026-10-12T12:30:00'
Test-Case 'P159' 'Fenêtre : syntaxe des jours et des plages, erreurs nommées' {
    $w = ConvertFrom-DomeniaCollectionWindowText 'lun-ven 07:30-12:00 13:30-18:00; sam 08:00-12:00'
    Assert-True $w.Valid; Assert-Equal 'Rules' $w.Mode; Assert-Equal 3 @($w.Rules).Count
    Assert-Equal 5 @(@($w.Rules)[0].Days).Count
    Assert-Equal 'Always' (ConvertFrom-DomeniaCollectionWindowText '').Mode
    Assert-Equal 'Always' (ConvertFrom-DomeniaCollectionWindowText 'Toujours').Mode
    Assert-Equal 'Never' (ConvertFrom-DomeniaCollectionWindowText 'jamais').Mode
    $wrap = ConvertFrom-DomeniaCollectionWindowText 'ven-lun'
    Assert-Equal 4 @(@($wrap.Rules)[0].Days).Count 'Vendredi, samedi, dimanche, lundi'
    $bad = ConvertFrom-DomeniaCollectionWindowText 'lundo 07:00-08:00; mar 25:00-26:00; mer 10:00-10:00'
    Assert-False $bad.Valid; Assert-Equal 3 @($bad.Errors).Count
}
Test-Case 'P159' 'Fenêtre : ouverte ou fermée selon le jour et lʼheure locale, plage de nuit' {
    $w = ConvertFrom-DomeniaCollectionWindowText 'lun-ven 12:00-14:00 22:00-06:00; sam-dim'
    Assert-True (Test-DomeniaCollectionWindowOpen $w $script:Monday1230).Open
    Assert-False (Test-DomeniaCollectionWindowOpen $w $script:Monday10).Open
    Assert-True (Test-DomeniaCollectionWindowOpen $w ([datetime]'2026-10-13T03:00:00')).Open 'Nuit de lundi à mardi'
    Assert-False (Test-DomeniaCollectionWindowOpen $w ([datetime]'2026-10-12T03:00:00')).Open 'Dimanche nʼouvre pas la nuit du lundi'
    Assert-True (Test-DomeniaCollectionWindowOpen $w ([datetime]'2026-10-17T15:00:00')).Open 'Samedi entier'
    Assert-True (Test-DomeniaCollectionWindowOpen (ConvertFrom-DomeniaCollectionWindowText '') $script:Monday10).Open
    Assert-False (Test-DomeniaCollectionWindowOpen (ConvertFrom-DomeniaCollectionWindowText 'jamais') $script:Monday10).Open
    $quick = Test-DomeniaCollectionWindowOpen $w ([datetime]'2026-10-13T03:00:00') -StateOnly
    Assert-True $quick.Open 'État seul identique'; Assert-True ($null -eq $quick.NextChange) 'État seul : prochain changement non calculé'
}
Test-Case 'P159' 'Fenêtre : prochain changement et texte sans promesse' {
    $w = ConvertFrom-DomeniaCollectionWindowText 'lun-ven 12:00-14:00'
    $closed = Test-DomeniaCollectionWindowOpen $w $script:Monday10
    Assert-Equal ([datetime]'2026-10-12T12:00:00') $closed.NextChange
    Assert-True ((Format-DomeniaCollectionWindowState $closed $script:Monday10) -match 'reprise à 12:00')
    $open = Test-DomeniaCollectionWindowOpen $w $script:Monday1230
    Assert-Equal ([datetime]'2026-10-12T14:00:00') $open.NextChange
    Assert-True ((Format-DomeniaCollectionWindowState $open $script:Monday1230) -match 'ouverte jusqu.à 14:00')
    $friday = Test-DomeniaCollectionWindowOpen $w ([datetime]'2026-10-16T15:00:00')
    Assert-True ((Format-DomeniaCollectionWindowState $friday ([datetime]'2026-10-16T15:00:00')) -match 'reprise lundi à 12:00')
}
Test-Case 'P159' 'Fenêtre : seules les sources de fond réseau sont retenues ; une fenêtre invalide les suspend' {
    $never = ConvertFrom-DomeniaCollectionWindowText 'jamais'
    Assert-False (Test-DomeniaCollectionWindowAllows $never 'Reconcile' $script:Monday10)
    Assert-False (Test-DomeniaCollectionWindowAllows $never 'ObjectChanges' $script:Monday10)
    Assert-True (Test-DomeniaCollectionWindowAllows $never 'Live' $script:Monday10) 'Une sélection nʼest pas un travail de fond'
    Assert-True (Test-DomeniaCollectionWindowAllows $never 'Storage' $script:Monday10)
    Assert-True (Test-DomeniaCollectionWindowAllows $never 'Dashboard' $script:Monday10)
    Assert-False (Test-DomeniaCollectionWindowAllows (ConvertFrom-DomeniaCollectionWindowText 'xx') 'Park' $script:Monday10)
    Assert-True (Test-DomeniaCollectionWindowAllows (ConvertFrom-DomeniaCollectionWindowText '') 'Park' $script:Monday10)
}

# ---------------------------------------------------------------- point 14
Test-Case 'P14' 'Concurrence : moitié moins après un délai, une place de plus après une série de réponses' {
    $p = New-DomeniaSourcePolicy -MaxLimit 8 -FailureThreshold 0 -DecreaseCooldownSeconds 0
    $h = New-DomeniaSourceHealth; $k = 'site:10.1.2.0/24'
    $e = Get-DomeniaSourceEntry $h $k $p
    Assert-Equal 8 $e.Limit 'Départ à la borne choisie'
    [void](Register-DomeniaSourceOutcome $h $k 'Timeout' -1 $p $script:CT0)
    Assert-Equal 4 $e.Limit
    [void](Register-DomeniaSourceOutcome $h $k 'Timeout' -1 $p $script:CT0.AddSeconds(1))
    Assert-Equal 2 $e.Limit
    [void](Register-DomeniaSourceOutcome $h $k 'Success' 100 $p $script:CT0.AddSeconds(2))
    Assert-Equal 2 $e.Limit
    [void](Register-DomeniaSourceOutcome $h $k 'Success' 100 $p $script:CT0.AddSeconds(3))
    Assert-Equal 3 $e.Limit
    Assert-Equal 'Closed' $e.State 'Sans seuil de suspension'
}
Test-Case 'P14' 'Concurrence : une latence qui double ralentit, la remontée reste sous la borne choisie' {
    $p = New-DomeniaSourcePolicy -MaxLimit 4 -FailureThreshold 0 -DecreaseCooldownSeconds 0 -SlowFloorMs 500
    $h = New-DomeniaSourceHealth; $k = 'site:10.1.2.0/24'
    foreach ($i in 1..3) { [void](Register-DomeniaSourceOutcome $h $k 'Success' 200 $p $script:CT0.AddSeconds($i)) }
    Assert-Equal 4 $h[$k].Limit
    [void](Register-DomeniaSourceOutcome $h $k 'Success' 2000 $p $script:CT0.AddSeconds(4))
    Assert-Equal 2 $h[$k].Limit 'Latence décuplée'
    foreach ($i in 5..30) { [void](Register-DomeniaSourceOutcome $h $k 'Success' 200 $p $script:CT0.AddSeconds($i)) }
    Assert-Equal 4 $h[$k].Limit 'Jamais au-delà de la borne'
}
Test-Case 'P14' 'Concurrence : une seule baisse par intervalle, les réponses sans valeur ne changent rien' {
    $p = New-DomeniaSourcePolicy -MaxLimit 8 -FailureThreshold 0 -DecreaseCooldownSeconds 10
    $h = New-DomeniaSourceHealth; $k = 'site:10.1.2.0/24'
    [void](Register-DomeniaSourceOutcome $h $k 'Timeout' -1 $p $script:CT0)
    [void](Register-DomeniaSourceOutcome $h $k 'Timeout' -1 $p $script:CT0.AddSeconds(2))
    Assert-Equal 4 $h[$k].Limit
    [void](Register-DomeniaSourceOutcome $h $k 'Timeout' -1 $p $script:CT0.AddSeconds(11))
    Assert-Equal 2 $h[$k].Limit
    foreach ($i in 1..10) { [void](Register-DomeniaSourceOutcome $h $k 'Neutral' -1 $p $script:CT0.AddSeconds(20 + $i)) }
    Assert-Equal 2 $h[$k].Limit; Assert-Equal 3 $h[$k].ConsecutiveFailures
}
Test-Case 'P14' 'Latence par étape : ni lʼattente en file ni un plan déjà en cache ne ralentissent un site sain' {
    $f = 1000L
    Assert-Equal 200.0 (Get-DomeniaReadStepLatencyMs -StartedTimestamp 1000 -LastTimestamp 1400 -Steps 2 -Frequency $f)
    Assert-Equal ([double]-1) (Get-DomeniaReadStepLatencyMs -StartedTimestamp 0 -LastTimestamp 1400 -Steps 2 -Frequency $f) 'Lecture jamais partie'
    Assert-Equal ([double]-1) (Get-DomeniaReadStepLatencyMs -StartedTimestamp 1000 -LastTimestamp 1400 -Steps 0 -Frequency $f) 'Aucune étape terminée'
    Assert-Equal ([double]-1) (Get-DomeniaReadStepLatencyMs -StartedTimestamp 1500 -LastTimestamp 1400 -Steps 2 -Frequency $f) 'Horloge incohérente'
    $s = New-DomeniaCampaignSources -MaxLimit 4; $k = 'site:10.1.2.0/24'; $policy = Get-DomeniaCampaignSourcePolicy $s $k
    # Three plans of reused measurements (ping and one query in 0.4 s), then full reads (ping and twelve queries in
    # 2.6 s): the same pace per step, so no decrease.
    $at = $script:CT0
    foreach ($i in 1..3) { $at = $at.AddSeconds(1); [void](Register-DomeniaSourceOutcome $s.Health $k 'Success' (Get-DomeniaReadStepLatencyMs 1000 1400 2 $f) $policy $at) }
    foreach ($i in 1..5) { $at = $at.AddSeconds(1); [void](Register-DomeniaSourceOutcome $s.Health $k 'Success' (Get-DomeniaReadStepLatencyMs 1000 3600 13 $f) $policy $at) }
    Assert-Equal 4 $s.Health[$k].Limit 'Lecture complète prise pour un ralentissement'
    Assert-Equal 0 ([int]$s.Health[$k].Decreases)
    # Steps that really became slower still halve the source.
    $at = $at.AddSeconds(20); [void](Register-DomeniaSourceOutcome $s.Health $k 'Success' (Get-DomeniaReadStepLatencyMs 1000 13000 2 $f) $policy $at)
    Assert-Equal 2 $s.Health[$k].Limit 'Étapes trente fois plus lentes'
}

# ---------------------------------------------------------------- point 15
Test-Case 'P15' 'Budgets par site : un sous-réseau lent ne prend pas les places des autres' {
    $s = New-DomeniaCampaignSources -MaxLimit 4
    $slow = 'site:10.1.2.0/24'; $fast = 'site:10.9.9.0/24'
    [void](Register-DomeniaSourceOutcome $s.Health $slow 'Timeout' -1 (Get-DomeniaCampaignSourcePolicy $s $slow) $script:CT0)
    [void](Register-DomeniaSourceOutcome $s.Health $slow 'Timeout' -1 (Get-DomeniaCampaignSourcePolicy $s $slow) $script:CT0.AddSeconds(11))
    Assert-Equal 1 $s.Health[$slow].Limit
    Assert-False (Test-DomeniaSourceAdmission $s.Health $slow 1 (Get-DomeniaCampaignSourcePolicy $s $slow) $script:CT0.AddSeconds(12)).Allowed
    Assert-True (Test-DomeniaSourceAdmission $s.Health $fast 3 (Get-DomeniaCampaignSourcePolicy $s $fast) $script:CT0.AddSeconds(12)).Allowed
    Assert-False (Test-DomeniaSourceAdmission $s.Health $fast 4 (Get-DomeniaCampaignSourcePolicy $s $fast) $script:CT0.AddSeconds(12)).Allowed 'Borne choisie'
    Assert-True ((Get-DomeniaCampaignSourceSummary $s $script:CT0.AddSeconds(12)) -match 'sous-réseau présumé 10\.1\.2\.0/24 ralenti à 1/4')
}
Test-Case 'P15' 'Adresses : sous-réseau présumé, adresses invalides ignorées, clé par fournisseur' {
    Assert-Equal '10.1.2.0/24' (Get-DomeniaSubnetKey '10.1.2.37')
    Assert-Equal '10.1.0.0/16' (Get-DomeniaSubnetKey '10.1.2.37' 16)
    Assert-Equal '' (Get-DomeniaSubnetKey '127.0.0.1'); Assert-Equal '' (Get-DomeniaSubnetKey '256.1.1.1'); Assert-Equal '' (Get-DomeniaSubnetKey 'fe80::1')
    Assert-Equal '10.77.0.20' (Get-DomeniaAddressFromText 'Réponse ICMP · 12 ms · 10.77.0.20')
    Assert-Equal '' (Get-DomeniaAddressFromText 'ICMP : TimedOut · PC-1')
    Assert-Equal 'site:10.77.0.0/24' (Get-DomeniaCollectionSourceKey 'Cim' '' '10.77.0.20')
    Assert-Equal 'site:?' (Get-DomeniaCollectionSourceKey 'Cim' '' '')
    Assert-Equal 'dc:dc01.example.test' (Get-DomeniaCollectionSourceKey 'Directory' 'DC01.example.test' '')
    Assert-False (Test-DomeniaSourceAdmission $null 'site:?' 4 (New-DomeniaCampaignSources -MaxLimit 4).UnknownPolicy).Allowed
}

# ---------------------------------------------------------------- point 160
Test-Case 'P160' 'Suspension : échecs répétés suspendent la source seule, puis une lecture dʼessai et une reprise progressive' {
    $p = New-DomeniaSourcePolicy -MaxLimit 4 -FailureThreshold 3 -OpenSeconds 60 -DecreaseCooldownSeconds 0
    $h = New-DomeniaSourceHealth; $k = 'site:10.1.2.0/24'
    foreach ($i in 0..2) { [void](Register-DomeniaSourceOutcome $h $k 'Timeout' -1 $p $script:CT0.AddSeconds($i)) }
    $closed = Test-DomeniaSourceAdmission $h $k 0 $p $script:CT0.AddSeconds(10)
    Assert-False $closed.Allowed; Assert-Equal 'Open' $closed.State; Assert-True ($null -ne $closed.RetryAfterUtc)
    Assert-True (Test-DomeniaSourceAdmission $h 'site:10.9.9.0/24' 0 $p $script:CT0.AddSeconds(10)).Allowed 'Un autre site continue'
    $trial = Test-DomeniaSourceAdmission $h $k 0 $p $script:CT0.AddSeconds(70)
    Assert-True $trial.Allowed; Assert-Equal 'HalfOpen' $trial.State
    Assert-False (Test-DomeniaSourceAdmission $h $k 1 $p $script:CT0.AddSeconds(70)).Allowed 'Une seule lecture dʼessai'
    [void](Register-DomeniaSourceOutcome $h $k 'Success' 300 $p $script:CT0.AddSeconds(72))
    Assert-Equal 'Closed' $h[$k].State; Assert-Equal 1 $h[$k].Limit
    [void](Register-DomeniaSourceOutcome $h $k 'Success' 300 $p $script:CT0.AddSeconds(73))
    Assert-Equal 2 $h[$k].Limit 'Reprise progressive'
}
Test-Case 'P160' 'Suspension : un échec pendant lʼessai suspend plus longtemps, sans dépasser la borne' {
    $p = New-DomeniaSourcePolicy -MaxLimit 4 -FailureThreshold 3 -OpenSeconds 60 -MaxOpenSeconds 900 -DecreaseCooldownSeconds 0
    $h = New-DomeniaSourceHealth; $k = 'dc:dc01.example.test'
    foreach ($i in 0..2) { [void](Register-DomeniaSourceOutcome $h $k 'Failure' -1 $p $script:CT0) }
    Assert-Equal 60 ([int]($h[$k].OpenUntilUtc - $script:CT0).TotalSeconds)
    [void](Register-DomeniaSourceOutcome $h $k 'Timeout' -1 $p $script:CT0.AddSeconds(70))
    Assert-Equal 120 ([int]($h[$k].OpenUntilUtc - $script:CT0.AddSeconds(70)).TotalSeconds)
    $at = $script:CT0.AddSeconds(70)
    foreach ($i in 1..12) { $at = $h[$k].OpenUntilUtc.AddSeconds(1); [void](Register-DomeniaSourceOutcome $h $k 'Timeout' -1 $p $at) }
    Assert-True ((($h[$k].OpenUntilUtc) - $at).TotalSeconds -le 900)
    Assert-True ([int]$h[$k].Suspensions -ge 14)
}
Test-Case 'P160' 'Suspension : machine éteinte, droit refusé ou compte rejeté ne comptent pas contre le site' {
    $p = New-DomeniaSourcePolicy -MaxLimit 4 -FailureThreshold 3 -DecreaseCooldownSeconds 0
    $h = New-DomeniaSourceHealth; $k = 'site:10.1.2.0/24'
    foreach ($outcome in @('Offline','AccessDenied','Credential')) {
        $class = ConvertTo-DomeniaCollectionFailure -Outcome $(switch ($outcome) { 'Offline' { 'Timeout' } 'AccessDenied' { 'Denied' } default { 'AuthRejected' } }) -Presence 'Sans réponse au ping'
        foreach ($i in 1..5) { [void](Register-DomeniaSourceOutcome $h $k ([string]$class.Health) 100 $p $script:CT0.AddSeconds($i)) }
    }
    Assert-Equal 'Closed' $h[$k].State; Assert-Equal 0 $h[$k].ConsecutiveFailures
    Assert-True (Test-DomeniaSourceAdmission $h $k 0 $p $script:CT0.AddSeconds(30)).Allowed
}

# ---------------------------------------------------------------- point 17
Test-Case 'P17' 'Progression : résultats validés, temps écoulé, attente réelle et absence de progrès' {
    $state = Get-DomeniaCampaignProgressState -Total 400 -Validated 120 -Pending 4 -Waiting 276 -StartedUtc $script:CT0 -LastValidatedUtc $script:CT0.AddSeconds(200) -HeldSeconds 35 -NowUtc $script:CT0.AddSeconds(250)
    Assert-False $state.Stalled; Assert-Equal 50 ([int]$state.IdleSeconds); Assert-Equal 250 ([int]$state.ElapsedSeconds)
    Assert-True ($state.Text -match '120/400'); Assert-True ($state.Text -match 'attente réelle 35 s'); Assert-True ($state.Text -match '4 min 10 s')
    $stall = Get-DomeniaCampaignProgressState -Total 400 -Validated 120 -Pending 4 -StartedUtc $script:CT0 -LastValidatedUtc $script:CT0.AddSeconds(10) -NowUtc $script:CT0.AddSeconds(250) -StallSeconds 120
    Assert-True $stall.Stalled; Assert-True ($stall.Text -match 'aucun progrès depuis')
    $none = Get-DomeniaCampaignProgressState -Total 10 -Validated 0 -Pending 2 -StartedUtc $script:CT0 -NowUtc $script:CT0.AddSeconds(5)
    Assert-True ($none.Text -match 'aucun résultat validé'); Assert-False $none.Stalled
    $done = Get-DomeniaCampaignProgressState -Total 10 -Validated 10 -StartedUtc $script:CT0 -LastValidatedUtc $script:CT0 -NowUtc $script:CT0.AddHours(1)
    Assert-False $done.Stalled 'Rien en cours : pas de blocage'
}

# ---------------------------------------------------------------- point 18
Test-Case 'P18' 'Classement : seul un incident transitoire est repris, borné et espacé' {
    Assert-Equal 'Transient' (ConvertTo-DomeniaCollectionFailure -Outcome 'Timeout' -Presence 'En ligne').Category
    Assert-Equal 'Transient' (ConvertTo-DomeniaCollectionFailure -Outcome 'Timeout' -Presence '' -PingCollected $false).Category 'WMI seul'
    Assert-Equal 'Offline' (ConvertTo-DomeniaCollectionFailure -Outcome 'Timeout' -Presence 'Sans réponse au ping').Category
    Assert-Equal 'Credential' (ConvertTo-DomeniaCollectionFailure -Outcome 'AuthRejected').Category
    Assert-Equal 'AccessDenied' (ConvertTo-DomeniaCollectionFailure -Outcome 'Denied').Category
    Assert-Equal 'ProtocolUnreachable' (ConvertTo-DomeniaCollectionFailure -Outcome 'Unavailable' -Presence 'En ligne').Category
    Assert-Equal 'Transient' (ConvertTo-DomeniaCollectionFailure -JobFailed $true -ErrorText 'Délai dépassé : Console du parc' -Presence 'En ligne').Category 'Arrêté par le moteur après un ping réussi'
    Assert-Equal 'Credential' (ConvertTo-DomeniaCollectionFailure -JobFailed $true -ErrorText 'Identifiants rejetés pour cette ressource').Category
    Assert-Equal 'Success' (ConvertTo-DomeniaCollectionFailure -Outcome 'Observed' -Presence 'En ligne').Category
    $first = Get-DomeniaCollectionRetryDecision -Category 'Transient' -Attempt 1 -NowUtc $script:CT0
    Assert-True $first.Retry; Assert-Equal 30 $first.DelaySeconds; Assert-Equal $script:CT0.AddSeconds(30) $first.NotBeforeUtc
    Assert-Equal 120 (Get-DomeniaCollectionRetryDecision -Category 'Transient' -Attempt 2 -NowUtc $script:CT0).DelaySeconds
    Assert-False (Get-DomeniaCollectionRetryDecision -Category 'Transient' -Attempt 3 -NowUtc $script:CT0).Retry 'Trois essais au plus'
    foreach ($category in @('Credential','AccessDenied','Offline','Unreachable','ProtocolUnreachable','Permanent','ClassAbsent','Success')) { Assert-False (Get-DomeniaCollectionRetryDecision -Category $category -Attempt 1).Retry $category }
    Assert-False (Get-DomeniaCollectionRetryDecision -Category 'Transient' -Attempt 1 -IsWrite $true).Retry 'Une écriture nʼest jamais rejouée'
}
Test-Case 'P18' 'Classement : sans preuve que le poste répond, ni reprise ni charge comptée contre son site' {
    # WMI only: DCOM answers « serveur RPC indisponible » (Unavailable) for a workstation switched off.
    $wmiOnly = ConvertTo-DomeniaCollectionFailure -Outcome 'Unavailable' -Presence 'Non vérifié' -PingCollected $false
    Assert-Equal 'Unreachable' $wmiOnly.Category; Assert-Equal 'Neutral' $wmiOnly.Health
    Assert-False (Get-DomeniaCollectionRetryDecision -Category $wmiOnly.Category -Attempt 1).Retry 'WMI seul, poste éteint relu'
    # Read stopped by the engine: the ping step reported by the worker decides.
    $unknown = ConvertTo-DomeniaCollectionFailure -JobFailed $true -ErrorText 'Délai dépassé : Console du parc : PC-1 — aucune étape terminée pendant le délai' -Presence ''
    Assert-Equal 'Unreachable' $unknown.Category 'Ping non terminé'; Assert-Equal 'Neutral' $unknown.Health
    Assert-Equal 'Offline' (ConvertTo-DomeniaCollectionFailure -JobFailed $true -ErrorText 'Délai dépassé' -Presence 'Sans réponse au ping').Category
    Assert-Equal 'Unreachable' (ConvertTo-DomeniaCollectionFailure -JobFailed $true -ErrorText 'Délai dépassé' -Presence '' -PingCollected $false).Category 'WMI seul arrêté par le moteur'
    $proven = ConvertTo-DomeniaCollectionFailure -JobFailed $true -ErrorText 'Délai dépassé' -Presence 'En ligne'
    Assert-Equal 'Transient' $proven.Category; Assert-Equal 'Timeout' $proven.Health
    Assert-Equal 'Transient' (ConvertTo-DomeniaCollectionFailure -Outcome 'Timeout' -Presence 'Non vérifié' -PingCollected $false).Category 'Délai dʼune requête CIM signalé par le worker'
    # Five workstations switched off in one subnet leave its budget untouched.
    $p = New-DomeniaSourcePolicy -MaxLimit 4 -FailureThreshold 3 -DecreaseCooldownSeconds 0
    $h = New-DomeniaSourceHealth; $k = 'site:10.1.2.0/24'
    foreach ($i in 1..5) { [void](Register-DomeniaSourceOutcome $h $k ([string]$wmiOnly.Health) -1 $p $script:CT0.AddSeconds($i)) }
    Assert-Equal 4 $h[$k].Limit; Assert-Equal 'Closed' $h[$k].State
}

# ---------------------------------------------------------------- point 19
Test-Case 'P19' 'Capacités : classe absente liée à la version de Windows, refus lié aux comptes, durée limitée' {
    $m = New-DomeniaCapabilityMemory
    $class = 'class:root\cimv2:Win32_Battery'
    [void](Register-DomeniaCapabilityFact -Memory $m -Target 'PC-1' -Capability $class -Kind 'ClassAbsent' -NowUtc $script:CT0 -Build '22631' -AccountGeneration 3)
    Assert-True (Test-DomeniaCapabilityFact $m 'pc-1' 'CLASS:root\cimv2:Win32_Battery' $script:CT0.AddHours(1) '22631' 3).Known
    Assert-False (Test-DomeniaCapabilityFact $m 'pc-1' $class $script:CT0.AddHours(1) '26100' 3).Known 'Nouvelle version de Windows'
    [void](Register-DomeniaCapabilityFact -Memory $m -Target 'PC-1' -Capability $class -Kind 'ClassAbsent' -NowUtc $script:CT0 -Build '22631' -AccountGeneration 3)
    Assert-False (Test-DomeniaCapabilityFact $m 'pc-1' $class $script:CT0.AddDays(8) '22631' 3).Known 'Expire après sept jours'
    [void](Register-DomeniaCapabilityFact -Memory $m -Target 'PC-1' -Capability 'cim' -Kind 'RightDenied' -NowUtc $script:CT0 -AccountGeneration 3)
    Assert-True (Test-DomeniaCapabilityFact $m 'PC-1' 'cim' $script:CT0.AddMinutes(10) '' 3).Known
    Assert-False (Test-DomeniaCapabilityFact $m 'PC-1' 'cim' $script:CT0.AddMinutes(10) '' 4).Known 'Changement de compte'
    Assert-True (Test-DomeniaWmiClassAbsentText 'Classe non valide') ; Assert-True (Test-DomeniaWmiClassAbsentText 'Invalid namespace (0x8004100E)')
    Assert-False (Test-DomeniaWmiClassAbsentText 'Accès refusé')
}
Test-Case 'P19' 'Capacités : plan sans les lectures impossibles, relecture forcée, mémoire semée par le dernier relevé' {
    $battery = [pscustomobject]@{Id='hw.battery';Namespace='root\cimv2';Class='Win32_Battery'}
    $bios = [pscustomobject]@{Id='hw.bios';Namespace='root\cimv2';Class='Win32_BIOS'}
    $previous = [pscustomobject]@{Probes=[pscustomobject]@{'hw.battery'=[pscustomobject]@{Error='Classe non valide (0x80041010)';CheckedUtc=$script:CT0.AddHours(-2).ToString('o')}}}
    $m = New-DomeniaCapabilityMemory
    $plan = Get-DomeniaCapabilityPlan -Memory $m -Target 'PC-1' -Probes @($battery,$bios) -Previous $previous -NowUtc $script:CT0 -Build '22631' -AccountGeneration 1
    Assert-Equal 1 @($plan.Probes).Count; Assert-Equal 'hw.bios' @($plan.Probes)[0].Id; Assert-Equal 1 @($plan.Skipped).Count; Assert-False $plan.SkipCim
    Assert-Equal 2 @((Get-DomeniaCapabilityPlan -Memory $m -Target 'PC-1' -Probes @($battery,$bios) -Previous $previous -NowUtc $script:CT0 -Force $true).Probes).Count 'Relecture forcée'
    $old = [pscustomobject]@{Probes=[pscustomobject]@{'hw.battery'=[pscustomobject]@{Error='Classe non valide';CheckedUtc=$script:CT0.AddDays(-9).ToString('o')}}}
    Assert-Equal 2 @((Get-DomeniaCapabilityPlan -Memory (New-DomeniaCapabilityMemory) -Target 'PC-2' -Probes @($battery,$bios) -Previous $old -NowUtc $script:CT0).Probes).Count 'Constat trop ancien'
    [void](Register-DomeniaCapabilityFact -Memory $m -Target 'PC-1' -Capability 'cim' -Kind 'ProtocolUnreachable' -NowUtc $script:CT0 -AccountGeneration 1)
    Assert-True (Get-DomeniaCapabilityPlan -Memory $m -Target 'PC-1' -Probes @($bios) -NowUtc $script:CT0.AddMinutes(5) -AccountGeneration 1).SkipCim
    Assert-False (Get-DomeniaCapabilityPlan -Memory $m -Target 'PC-1' -Probes @($bios) -NowUtc $script:CT0.AddMinutes(16) -AccountGeneration 1).SkipCim 'Quinze minutes au plus'
    [void](Register-DomeniaCapabilityFact -Memory $m -Target 'PC-1' -Capability 'cim' -Kind 'ProtocolUnreachable' -NowUtc $script:CT0 -AccountGeneration 1)
    Assert-Equal 1 (Clear-DomeniaCapabilityFact $m 'PC-1' 'cim')
    Assert-False (Get-DomeniaCapabilityPlan -Memory $m -Target 'PC-1' -Probes @($bios) -NowUtc $script:CT0.AddMinutes(5) -AccountGeneration 1).SkipCim 'Une réussite efface le constat'
}

# ---------------------------------------------------------------- point 13
Test-Case 'P13' 'Regroupement WMI : console, inventaire et sondes de même classe partagent leurs lectures' {
    $probes = @(
        [pscustomobject]@{Id='hw.maker';Namespace='root\cimv2';Class='Win32_ComputerSystem';Filter='';Skip=''}
        [pscustomobject]@{Id='hw.model';Namespace='root\cimv2';Class='Win32_ComputerSystem';Filter='';Skip=''}
        [pscustomobject]@{Id='disk.cfree';Namespace='root\cimv2';Class='Win32_LogicalDisk';Filter="DeviceID='C:'";Skip=''}
        [pscustomobject]@{Id='sec.av';Namespace='root\SecurityCenter2';Class='AntiVirusProduct';Filter='';Skip='DomainController'}
    )
    $plan = Measure-DomeniaCimQueryPlan -ProbeUser $true -Inventory $true -Probes $probes
    Assert-Equal 9 $plan.Requested; Assert-Equal 4 $plan.Executed; Assert-Equal 5 $plan.Avoided
    Assert-Equal 0 (Measure-DomeniaCimQueryPlan -ProbeUser $true -Inventory $false -Probes @()).Avoided
    Assert-Equal (Get-DomeniaCimGroupKey 'ROOT\CIMV2' 'win32_logicaldisk' "DeviceID='C:'") (Get-DomeniaCimGroupKey 'root\cimv2' 'Win32_LogicalDisk' "DeviceID='C:'")
    Assert-True ((Get-DomeniaCimGroupKey 'root\cimv2' 'Win32_Service' "Name='A'") -cne (Get-DomeniaCimGroupKey 'root\cimv2' 'Win32_Service' "Name='a'")) 'Filtres distincts : lectures distinctes'
}

# ---------------------------------------------------------------- point 20
function New-CltPlan {
    $targets = @(for ($i = 1; $i -le 300; $i++) { [pscustomobject]@{Computer=('PC-' + $i);Key=('CN=PC-' + $i + ',OU=Postes,DC=example,DC=test');Guid=('00000000-0000-0000-0000-' + $i.ToString('d12'))} })
    $targets += $targets[0]
    return (New-DomeniaCampaignPlan -Kind 'Analysis' -Targets $targets -ProbeIds @('hw.bios','id invalide!') -Inventory $true -ScopeLabel 'OU=Postes' -DomainDn 'DC=example,DC=test' -DatabasePath 'C:\fixture\base.db' -NowUtc $script:CT0)
}
Test-Case 'P20' 'Plan durable : relu à lʼidentique, compressé, sans doublon et refusé sʼil est altéré' {
    $plan = New-CltPlan
    Assert-Equal 300 @($plan.Targets).Count 'Doublon retiré'
    Assert-Equal 1 @($plan.ProbeIds).Count
    $text = ConvertTo-DomeniaCampaignPlanText $plan
    Assert-True ($text.Length -lt 20000) 'Liste compressée'
    $back = ConvertFrom-DomeniaCampaignPlanText $text
    Assert-Equal 300 @($back.Targets).Count; Assert-Equal 'PC-300' $back.Targets[299].N; Assert-Equal $plan.Id $back.Id
    Assert-Equal 'Analysis' $back.Kind; Assert-True $back.Inventory; Assert-Equal 'hw.bios' @($back.ProbeIds)[0]
    $head = ConvertFrom-Json $text; $head.TargetsSha256 = '00'
    Assert-Throws { ConvertFrom-DomeniaCampaignPlanText ($head | ConvertTo-Json -Compress) } 'Empreinte altérée acceptée'
    $head = ConvertFrom-Json $text; $head.Kind = 'Write'
    Assert-Throws { ConvertFrom-DomeniaCampaignPlanText ($head | ConvertTo-Json -Compress) } 'Type non autorisé accepté'
    Assert-Throws { ConvertFrom-DomeniaCampaignPlanText 'pas du json' }
    $odd = New-DomeniaCampaignPlan -Kind 'Ping' -Targets @([pscustomobject]@{Computer='PC 1';Key='CN=PC 1,DC=example,DC=test';Guid='00000000-0000-0000-0000-000000000001'},[pscustomobject]@{Computer='PC-2';Key=('CN=PC-2' + [char]10 + ',DC=example,DC=test');Guid='00000000-0000-0000-0000-000000000002'},[pscustomobject]@{Computer='PC-3';Key='CN=PC-3,DC=example,DC=test';Guid='00000000-0000-0000-0000-000000000003'})
    Assert-Equal 1 @($odd.Targets).Count 'Nom dʼhôte ou DN non relisible à lʼidentique : poste écarté, plan signalé non enregistré'
    Assert-Equal 'PC-3' (ConvertFrom-DomeniaCampaignPlanText (ConvertTo-DomeniaCampaignPlanText $odd)).Targets[0].N
}
Test-Case 'P20' 'Avancement : un poste validé nʼest jamais relu, le compteur vient des bits' {
    $plan = New-CltPlan
    $progress = New-DomeniaCampaignProgress $plan $script:CT0
    Assert-True (Set-DomeniaCampaignTargetDone $progress 0); Assert-False (Set-DomeniaCampaignTargetDone $progress 0) 'Double livraison'
    Assert-True (Set-DomeniaCampaignTargetDone $progress 299); Assert-False (Set-DomeniaCampaignTargetDone $progress 300)
    Assert-Equal 2 $progress.DoneCount
    $data = ConvertFrom-Json (ConvertTo-DomeniaCampaignProgressText $progress); $data.DoneCount = 0
    $back = ConvertFrom-DomeniaCampaignProgressText ($data | ConvertTo-Json -Compress) $plan
    Assert-Equal 2 $back.DoneCount
    $remaining = @(Get-DomeniaCampaignRemainingTargets $plan $back)
    Assert-Equal 298 $remaining.Count; Assert-Equal 'PC-2' $remaining[0].name
    Assert-Equal 0 @($remaining | Where-Object { $_.name -eq 'PC-300' }).Count
    Assert-Throws { ConvertFrom-DomeniaCampaignProgressText (ConvertTo-DomeniaCampaignProgressText $progress) ([pscustomobject]@{Id='ffffffffffffffffffffffffffffffff';Targets=@()}) } 'Avancement dʼun autre plan accepté'
}
Test-Case 'P20' 'Avancement : bits comptés octet par octet, bits au-delà du dernier poste ignorés' {
    $plan = New-CltPlan
    $progress = New-DomeniaCampaignProgress $plan $script:CT0
    foreach ($i in @(0,7,8,150,296,299)) { [void](Set-DomeniaCampaignTargetDone $progress $i) }
    $data = ConvertFrom-Json (ConvertTo-DomeniaCampaignProgressText $progress)
    # 300 workstations: 38 bytes, the last one holds four of them; its four high bits belong to no workstation.
    $bytes = [Convert]::FromBase64String([string]$data.Done); $bytes[37] = [byte]($bytes[37] -bor 0xF0)
    $data.Done = [Convert]::ToBase64String($bytes); $data.DoneCount = 0
    $back = ConvertFrom-DomeniaCampaignProgressText ($data | ConvertTo-Json -Compress) $plan
    Assert-Equal 6 $back.DoneCount 'Bits hors plan comptés'
    $remaining = @(Get-DomeniaCampaignRemainingTargets $plan $back)
    Assert-Equal 294 $remaining.Count; Assert-Equal 'PC-2' $remaining[0].name; Assert-Equal 'PC-299' $remaining[-1].name
    $full = New-DomeniaCampaignProgress $plan $script:CT0
    for ($i = 0; $i -lt 300; $i++) { [void](Set-DomeniaCampaignTargetDone $full $i) }
    Assert-Equal 300 (ConvertFrom-DomeniaCampaignProgressText (ConvertTo-DomeniaCampaignProgressText $full) $plan).DoneCount
}
Test-Case 'P20' 'Plan durable : champs du relevé ou du périmètre explicite, GUID texte ou octets, même lecture' {
    $targets = @(
        [pscustomobject]@{Computer='PC-7';Key='CN=PC-7,DC=example,DC=test';Guid=([guid]'00000000-0000-0000-0000-000000000007').ToString('B')},
        [pscustomobject]@{name='PC-8';distinguished_name='CN=PC-8,DC=example,DC=test';object_guid=([guid]'00000000-0000-0000-0000-000000000008').ToByteArray()},
        @{Computer='PC-9';Key='CN=PC-9,DC=example,DC=test';Guid='00000000-0000-0000-0000-000000000009'},
        [pscustomobject]@{Computer='PC-10';Key='CN=PC-10,DC=example,DC=test';Guid=[guid]::Empty.ToString()},
        [pscustomobject]@{Computer='PC-11';Key='CN=PC-11,DC=example,DC=test';Guid='pas un guid'})
    $plan = New-DomeniaCampaignPlan -Kind 'Ping' -Targets $targets
    Assert-Equal 3 @($plan.Targets).Count 'GUID vide ou invalide accepté'
    Assert-Equal '00000000-0000-0000-0000-000000000007' $plan.Targets[0].G
    Assert-Equal 'PC-8' $plan.Targets[1].N; Assert-Equal '00000000-0000-0000-0000-000000000008' $plan.Targets[1].G
    Assert-Equal 'CN=PC-9,DC=example,DC=test' $plan.Targets[2].D
    Assert-True (Test-DomeniaCampaignTargetName 'PC-9'); Assert-False (Test-DomeniaCampaignTargetName 'PC 9')
}
Test-Case 'P20' 'Reprise : proposée seulement sur le même domaine et la même base, avec le motif' {
    $plan = New-CltPlan
    $progress = New-DomeniaCampaignProgress $plan $script:CT0
    [void](Set-DomeniaCampaignTargetDone $progress 0); [void](Set-DomeniaCampaignTargetDone $progress 1)
    $progress.State = 'Paused'
    $state = Get-DomeniaCampaignResumeState -Progress $progress -DomainDn 'dc=example,dc=test' -DatabasePath 'C:\fixture\base.db'
    Assert-True $state.Resumable; Assert-Equal 298 $state.Remaining; Assert-True ($state.Reason -match 'arrêté par lʼopérateur'); Assert-True ($state.Reason -match 'lecture seule')
    Assert-False (Get-DomeniaCampaignResumeState -Progress $progress -DomainDn 'DC=autre,DC=test' -DatabasePath 'C:\fixture\base.db').Resumable
    Assert-False (Get-DomeniaCampaignResumeState -Progress $progress -DomainDn 'DC=example,DC=test' -DatabasePath 'C:\autre.db').Resumable
    for ($i = 2; $i -lt 300; $i++) { [void](Set-DomeniaCampaignTargetDone $progress $i) }
    Assert-False (Get-DomeniaCampaignResumeState -Progress $progress -DomainDn 'DC=example,DC=test' -DatabasePath 'C:\fixture\base.db').Resumable 'Tout est validé'
    Assert-False (Get-DomeniaCampaignResumeState -Progress $null).Resumable
}
Test-Case 'P20' 'Plan durable : seul un relevé de la portée des listes est une campagne, jamais le poste ouvert ni un widget' {
    Assert-True (Test-DomeniaCampaignRunDurable ([pscustomobject]@{Slot='List';ScopeKind='Results'})) 'liste affichée'
    Assert-True (Test-DomeniaCampaignRunDurable ([pscustomobject]@{Slot='List';ScopeKind='Scope';RefreshOperationId='ou-1'})) 'actualisation dʼune OU'
    Assert-True (Test-DomeniaCampaignRunDurable ([pscustomobject]@{Targets=@()})) 'relevé sans portée nommée : celle des listes'
    Assert-False (Test-DomeniaCampaignRunDurable ([pscustomobject]@{Slot='Computer'})) 'poste ouvert'
    Assert-False (Test-DomeniaCampaignRunDurable ([pscustomobject]@{Slot='List';WidgetBoard='Fleet'})) 'collecte dʼun widget de lʼOU'
    Assert-False (Test-DomeniaCampaignRunDurable ([pscustomobject]@{Slot='Computer';WidgetBoard='Computer'})) 'collecte dʼun widget du poste'
    Assert-False (Test-DomeniaCampaignRunDurable $null)
}
