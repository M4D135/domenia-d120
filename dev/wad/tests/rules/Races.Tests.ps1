# D008 : courses et selections rapides. Donnees fictives uniquement.
# Critere : une reponse d un ancien contexte ne change aucune donnee du contexte courant.
# Un petit etat simule (fiche, relations, assistance) rejoue des sequences d actions generees a graine fixe :
# selection A/B/C, changement de compte (avec retour possible au compte precedent), passage a un compte jamais
# utilise, nouvelle session, annulation, precedent/suivant, demarrage d une lecture en file et reponses tardives
# livrees dans un ordre quelconque. La decision d appliquer une reponse passe par les VRAIES regles du moteur :
# New-DomeniaSelectionIdentity, Test-DomeniaIdentityCurrent (SelectionIdentity.SameContext), Get-DomeniaTaskState,
# et l historique de navigation (Push-DomeniaNavState, Step-DomeniaNavHistory).
#
# Oracle independant : un compteur de contexte MONOTONE (ContextId) tenu par le simulateur, incremente a chaque
# changement de contexte et range dans chaque demande. Il ne lit jamais SelectionIdentity : il detecte aussi un
# contexte dont l identite repete une identite plus ancienne (compte A -> B -> A sans nouvelle generation), cas
# que SameContext ne peut pas voir.
#
# Contrat de l appelant (celui que suit le coeur lors d une nouvelle ouverture de session : Domenia-Core.ps1
# incremente SessionEpoch et SelectedObjectGeneration) : chaque changement de contexte donne une identite jamais
# utilisee dans la session. Le simulateur le respecte : Select, Back/Forward et Reader (bascule de compte, retour
# possible au compte precedent) incrementent Generation ; Session incremente Epoch ; NewReader passe a un compte
# jamais utilise, ce qui suffit a rendre l identite nouvelle (Generation conservee : la composante Reader de la
# regle est ainsi exercee seule). -ReaderKeepsGeneration rompt le contrat expres : l oracle doit alors signaler
# les reponses perimees que SameContext accepte.

$script:RaceDomain = 'example.invalid'
$script:RaceRows = @{
    A=[pscustomobject]@{Type='Utilisateur';Name='Alex Demo';Login='alex.demo';Guid='aaaaaaaa-0000-4000-8000-00000000000a';DN='CN=Alex Demo,OU=Demo,DC=example,DC=invalid';Sid='S-1-5-21-10-20-30-1101'}
    B=[pscustomobject]@{Type='Machine';Name='PC-B';Login='PC-B$';Guid='bbbbbbbb-0000-4000-8000-00000000000b';DN='CN=PC-B,OU=Postes,DC=example,DC=invalid';Sid='S-1-5-21-10-20-30-2202'}
    C=[pscustomobject]@{Type='Utilisateur';Name='Chris Demo';Login='chris.demo';Guid='cccccccc-0000-4000-8000-00000000000c';DN='CN=Chris Demo,OU=Demo,DC=example,DC=invalid';Sid='S-1-5-21-10-20-30-1303'}
}
$script:RaceKeys = @('A','B','C')
$script:RaceReaders = @('EX\lecteur','EX\support')
$script:RacePanels = @('Fiche','Relations','Assistance')
$script:RaceMaxPending = 12
# Reused by Find-DomeniaRaceJob: New-Object costs more than the search itself under Windows PowerShell 5.1.
$script:RaceMatches = New-Object 'System.Collections.Generic.List[int]'

function New-DomeniaRaceStep {
    # One simulated action. Pick chooses among the matching requests (-1 = the oldest one).
    param([Parameter(Mandatory=$true)][string]$Kind,[string]$Key='',[string]$Panel='',[long]$Id=0,[int]$Pick=-1)
    return [pscustomobject]@{Kind=$Kind;Key=$Key;Panel=$Panel;Id=$Id;Pick=$Pick}
}

function New-DomeniaRaceState {
    # -ReaderKeepsGeneration: an account switch keeps the generation (caller contract broken on purpose).
    param([switch]$ReaderKeepsGeneration)
    return @{
        Reader=$script:RaceReaders[0];Epoch=1L;Generation=0L;Key='';Current=$null
        ContextId=0L;ReaderSwitches=0L;FreshReaders=0;ReaderKeepsGeneration=[bool]$ReaderKeepsGeneration
        Panels=@{};Pending=(New-Object System.Collections.ArrayList);Nav=(New-DomeniaNavHistory);Sequence=0L
    }
}

function Set-DomeniaRaceContext {
    # Context change: a new oracle value, the identity rebuilt with the real rule, the panels cleared, the reads
    # of the new context started.
    param($State,[string]$Key,$Random)
    $row = $script:RaceRows[$Key]
    $State.Key = $Key
    $State.ContextId = $State.ContextId + 1
    $State.Current = New-DomeniaSelectionIdentity $row $script:RaceDomain $State.Reader $State.Epoch $State.Generation
    if ($null -eq $State.Current) { throw 'Identite de selection non construite.' }
    $State.Panels = @{}
    if ($State.Pending.Count -ge $script:RaceMaxPending) { return }
    foreach ($panel in $script:RacePanels) {
        $State.Sequence = $State.Sequence + 1
        $jobState = 'Running'
        if (($null -ne $Random) -and ($Random.Next(3) -eq 0)) { $jobState = 'Queued' }
        [void]$State.Pending.Add([pscustomobject]@{
            Id=$State.Sequence;Panel=$panel;Key=$Key;Identity=$State.Current;ContextId=$State.ContextId;ReaderSwitches=$State.ReaderSwitches
            State=$jobState;CancelRequested=$false
            Payload=($panel + ':' + $Key + ':' + $State.Reader + ':' + $State.Epoch + ':' + $State.Generation + ':#' + $State.Sequence)
        })
    }
}

function Get-DomeniaRaceSnapshot {
    # Everything the operator could see: the oracle context and the three panels.
    param($State)
    $text = 'ctx=' + $State.ContextId
    foreach ($panel in $script:RacePanels) {
        $shown = $State.Panels[$panel]
        if ($null -ne $shown) { $text += '|' + $panel + '=' + $shown.Value } else { $text += '|' + $panel + '=' }
    }
    return $text
}

function Find-DomeniaRaceJob {
    # Index of a pending request matching the filter, or -1. The simulator's own bookkeeping is read here;
    # the engine rule Get-DomeniaTaskState decides at delivery time.
    param($State,[string]$Kind,$Action)
    $matching = $script:RaceMatches
    $matching.Clear()
    for ($i = 0; $i -lt $State.Pending.Count; $i++) {
        $job = $State.Pending[$i]
        if (($Action.Id -gt 0) -and ($job.Id -ne $Action.Id)) { continue }
        if ($Action.Panel -and ($job.Panel -ne $Action.Panel)) { continue }
        if ($Action.Key -and ($job.Key -ne $Action.Key)) { continue }
        if (($Kind -eq 'Sent') -and ($job.State -eq 'Queued')) { continue }
        if (($Kind -eq 'Queued') -and ($job.State -ne 'Queued')) { continue }
        $matching.Add($i)
    }
    if ($matching.Count -eq 0) { return -1 }
    if ($Action.Pick -lt 0) { return $matching[0] }
    return $matching[$Action.Pick % $matching.Count]
}

function Invoke-DomeniaRaceAction {
    # Applies one action. Returns $null, or for a delivery the facts the invariant needs.
    # $Decide = $null uses the engine rule Test-DomeniaIdentityCurrent; a script block replaces it (weakened rules).
    param($State,$Action,[scriptblock]$Decide=$null,$Random=$null)
    switch ($Action.Kind) {
        'Select' {
            if (($State.Key -eq $Action.Key) -and ($null -ne $State.Current)) { return $null }
            $State.Generation = $State.Generation + 1
            Set-DomeniaRaceContext $State $Action.Key $Random
            [void](Push-DomeniaNavState $State.Nav ([pscustomobject]@{Page='Fiche';SelectionGuid=$script:RaceRows[$Action.Key].Guid}))
            return $null
        }
        'Reader' {
            # Account switch between two accounts: going back to the previous account is possible (A -> B -> A).
            if ($null -eq $State.Current) { return $null }
            if ($State.Reader -eq $script:RaceReaders[0]) { $State.Reader = $script:RaceReaders[1] } else { $State.Reader = $script:RaceReaders[0] }
            $State.ReaderSwitches = $State.ReaderSwitches + 1
            if (-not $State.ReaderKeepsGeneration) { $State.Generation = $State.Generation + 1 }
            Set-DomeniaRaceContext $State $State.Key $Random
            return $null
        }
        'NewReader' {
            # Switch to an account never used in this sequence: the reader alone makes the identity new.
            if ($null -eq $State.Current) { return $null }
            $State.FreshReaders = $State.FreshReaders + 1
            $State.Reader = 'EX\compte' + $State.FreshReaders
            $State.ReaderSwitches = $State.ReaderSwitches + 1
            Set-DomeniaRaceContext $State $State.Key $Random
            return $null
        }
        'Session' {
            if ($null -eq $State.Current) { return $null }
            $State.Epoch = $State.Epoch + 1
            Set-DomeniaRaceContext $State $State.Key $Random
            return $null
        }
        'Start' {
            $index = Find-DomeniaRaceJob $State 'Queued' $Action
            if ($index -ge 0) { $State.Pending[$index].State = 'Running' }
            return $null
        }
        'Cancel' {
            $index = Find-DomeniaRaceJob $State 'Any' $Action
            if ($index -lt 0) { return $null }
            $job = $State.Pending[$index]
            # A queued request is withdrawn before being sent; a running one only gets a stop request.
            if ((Get-DomeniaTaskState $job) -eq 'Queued') { $State.Pending.RemoveAt($index) } else { $job.CancelRequested = $true }
            return $null
        }
        'Deliver' {
            $index = Find-DomeniaRaceJob $State 'Sent' $Action
            if ($index -lt 0) { return $null }
            $job = $State.Pending[$index]
            $State.Pending.RemoveAt($index)
            $taskState = Get-DomeniaTaskState $job
            $before = Get-DomeniaRaceSnapshot $State
            $applied = $false
            $current = $false
            if ($taskState -eq 'Running') {
                if ($null -eq $Decide) { $current = [bool](Test-DomeniaIdentityCurrent $job.Identity $State.Current) }
                else { $current = [bool](& $Decide $job.Identity $State.Current) }
            }
            if ($current) {
                $State.Panels[$job.Panel] = [pscustomobject]@{Value=$job.Payload;Identity=$job.Identity;ContextId=$job.ContextId}
                $applied = $true
            }
            $after = Get-DomeniaRaceSnapshot $State
            # Stale = the oracle says the request belongs to another context; SameTuple = the engine rule's view.
            $stale = ($job.ContextId -ne $State.ContextId)
            $sameTuple = [bool]$job.Identity.SameContext($State.Current)
            return [pscustomobject]@{Job=$job;TaskState=$taskState;Applied=$applied;Stale=$stale;SameTuple=$sameTuple;Before=$before;After=$after}
        }
        { ($_ -eq 'Back') -or ($_ -eq 'Forward') } {
            # The real navigation rule chooses the visit; each visit is a new generation.
            $move = Step-DomeniaNavHistory $State.Nav $Action.Kind
            if (-not $move.Moved) { return $null }
            $target = ''
            foreach ($key in $script:RaceKeys) { if ($script:RaceRows[$key].Guid -eq [string]$move.State.SelectionGuid) { $target = $key } }
            $State.Generation = $State.Generation + 1
            Set-DomeniaRaceContext $State $target $Random
            return $null
        }
        default { throw ('Action simulee inconnue : ' + $Action.Kind) }
    }
}

function Test-DomeniaRaceInvariant {
    # Violations after one step (none when the invariant holds). Only the oracle (ContextId) decides here.
    param($State,$Delivery)
    $violations = @()
    if ($null -ne $Delivery) {
        $stopped = ($Delivery.TaskState -ne 'Running')
        if (($Delivery.Stale -or $stopped) -and ($Delivery.Before -cne $Delivery.After)) {
            $violations += ('Reponse hors contexte appliquee : ' + $Delivery.Job.Payload + ' (contexte ' + $Delivery.Job.ContextId + ') alors que le contexte courant est ' + $State.ContextId)
        }
        if ((-not $Delivery.Stale) -and (-not $stopped) -and (-not $Delivery.Applied)) {
            $violations += ('Reponse du contexte courant ecartee : ' + $Delivery.Job.Payload)
        }
    }
    foreach ($panel in $script:RacePanels) {
        $shown = $State.Panels[$panel]
        if ($null -eq $shown) { continue }
        if (($shown.ContextId -ne $State.ContextId) -or (-not $shown.Identity.SameContext($State.Current))) {
            $violations += ('Panneau ' + $panel + ' : donnee d un autre contexte affichee (' + $shown.Value + ').')
        }
    }
    return $violations
}

function Invoke-DomeniaRaceCorpus {
    # Plays $Count generated sequences from $Seed (System.Random: same seed, same sequence) and checks the
    # invariant after every step. At the end of a sequence every request still pending is answered, in a drawn order.
    param([int]$Seed,[int]$Count=300,[int]$MinSteps=6,[int]$MaxSteps=18,[scriptblock]$Decide=$null,[switch]$StopOnViolation,[switch]$ReaderKeepsGeneration)
    $random = New-Object System.Random -ArgumentList $Seed
    $stats = @{Sequences=0;Steps=0;Deliveries=0;Applied=0;Discarded=0;OnlyReader=0;OnlyEpoch=0;OnlyGeneration=0;OtherObject=0;AccountReturn=0;IdentityCollisions=0;StoppedCurrent=0;LateCrossings=0}
    $kinds = @{}
    $violations = New-Object 'System.Collections.Generic.List[string]'
    $trace = New-Object System.Text.StringBuilder
    for ($sequence = 0; $sequence -lt $Count; $sequence++) {
        $state = New-DomeniaRaceState -ReaderKeepsGeneration:$ReaderKeepsGeneration
        $length = $MinSteps + $random.Next($MaxSteps - $MinSteps + 1)
        $step = 0
        while ($true) {
            if ($step -ge $length) {
                if ($state.Pending.Count -eq 0) { break }
                $job = $state.Pending[$random.Next($state.Pending.Count)]
                $job.State = 'Running'
                $action = [pscustomobject]@{Kind='Deliver';Key='';Panel='';Id=[long]$job.Id;Pick=-1}
            } elseif ($null -eq $state.Current) {
                $action = [pscustomobject]@{Kind='Select';Key=$script:RaceKeys[$random.Next(3)];Panel='';Id=0L;Pick=-1}
            } else {
                # Deliveries dominate so that late answers keep crossing context changes.
                $roll = $random.Next(21)
                $pick = $random.Next(64)
                $key = ''
                if ($roll -lt 5) { $kind = 'Select'; $key = $script:RaceKeys[$random.Next(3)] }
                elseif ($roll -lt 6) { $kind = 'Reader' }
                elseif ($roll -lt 7) { $kind = 'NewReader' }
                elseif ($roll -lt 8) { $kind = 'Session' }
                elseif ($roll -lt 10) { $kind = 'Back' }
                elseif ($roll -lt 11) { $kind = 'Forward' }
                elseif ($roll -lt 12) { $kind = 'Cancel' }
                elseif ($roll -lt 14) { $kind = 'Start' }
                else { $kind = 'Deliver' }
                $action = [pscustomobject]@{Kind=$kind;Key=$key;Panel='';Id=0L;Pick=$pick}
            }
            $step++
            $stats.Steps = $stats.Steps + 1
            [void]$trace.Append($action.Kind).Append($action.Key).Append($action.Pick).Append($action.Id).Append(';')
            if ($kinds.ContainsKey($action.Kind)) { $kinds[$action.Kind] = $kinds[$action.Kind] + 1 } else { $kinds[$action.Kind] = 1 }
            $delivery = Invoke-DomeniaRaceAction $state $action $Decide $random
            if ($null -ne $delivery) {
                $stats.Deliveries = $stats.Deliveries + 1
                if ($delivery.Applied) { $stats.Applied = $stats.Applied + 1 } else { $stats.Discarded = $stats.Discarded + 1 }
                if ($delivery.Stale) {
                    # Which part of the identity changed while the request was out (statistics only, not the oracle).
                    $was = $delivery.Job.Identity; $now = $state.Current
                    $sameReader = ($was.Reader -ceq $now.Reader); $sameEpoch = ($was.Epoch -eq $now.Epoch); $sameGeneration = ($was.Generation -eq $now.Generation)
                    if ($state.Panels.Count -gt 0) { $stats.LateCrossings = $stats.LateCrossings + 1 }
                    if ($delivery.SameTuple) { $stats.IdentityCollisions = $stats.IdentityCollisions + 1 }
                    if (-not $was.SameObject($now)) { $stats.OtherObject = $stats.OtherObject + 1 }
                    else {
                        if ((-not $sameReader) -and $sameEpoch -and $sameGeneration) { $stats.OnlyReader = $stats.OnlyReader + 1 }
                        elseif ($sameReader -and (-not $sameEpoch) -and $sameGeneration) { $stats.OnlyEpoch = $stats.OnlyEpoch + 1 }
                        elseif ($sameReader -and $sameEpoch -and (-not $sameGeneration)) { $stats.OnlyGeneration = $stats.OnlyGeneration + 1 }
                        # Same object, back under the same account after at least one account switch (A -> B -> A).
                        if ($sameReader -and ($delivery.Job.ReaderSwitches -ne $state.ReaderSwitches)) { $stats.AccountReturn = $stats.AccountReturn + 1 }
                    }
                } elseif ($delivery.TaskState -ne 'Running') { $stats.StoppedCurrent = $stats.StoppedCurrent + 1 }
            }
            foreach ($violation in @(Test-DomeniaRaceInvariant $state $delivery)) {
                $violations.Add('graine ' + $Seed + ', sequence ' + $sequence + ', etape ' + $step + ' : ' + $violation)
            }
            if ($StopOnViolation -and ($violations.Count -gt 0)) { break }
        }
        $stats.Sequences = $stats.Sequences + 1
        if ($StopOnViolation -and ($violations.Count -gt 0)) { break }
    }
    $stats['Kinds'] = $kinds
    $stats['Violations'] = $violations.ToArray()
    $stats['TraceHash'] = Get-DomeniaTextHash $trace.ToString()
    return [pscustomobject]$stats
}

function Invoke-DomeniaRaceScript {
    # Plays a written scenario; returns the final state, the deliveries and every violation met on the way.
    param([object[]]$Steps,[scriptblock]$Decide=$null,[switch]$ReaderKeepsGeneration)
    $state = New-DomeniaRaceState -ReaderKeepsGeneration:$ReaderKeepsGeneration
    $violations = New-Object 'System.Collections.Generic.List[string]'
    $deliveries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $Steps) {
        $action = New-DomeniaRaceStep -Kind ([string](Get-DomeniaMember $item 'Kind' '')) -Key ([string](Get-DomeniaMember $item 'Key' '')) -Panel ([string](Get-DomeniaMember $item 'Panel' '')) -Id ([long](Get-DomeniaMember $item 'Id' 0)) -Pick ([int](Get-DomeniaMember $item 'Pick' -1))
        $delivery = Invoke-DomeniaRaceAction $state $action $Decide $null
        if ($null -ne $delivery) { $deliveries.Add($delivery) }
        foreach ($violation in @(Test-DomeniaRaceInvariant $state $delivery)) { $violations.Add($violation) }
    }
    return [pscustomobject]@{State=$state;Violations=$violations.ToArray();Deliveries=$deliveries.ToArray()}
}

Test-Case 'D008' 'A puis B : la reponse tardive de A ne remplace pas la fiche de B' {
    $run = Invoke-DomeniaRaceScript @(@{Kind='Select';Key='A'},@{Kind='Select';Key='B'},@{Kind='Deliver';Panel='Fiche';Key='A'},@{Kind='Deliver';Panel='Fiche';Key='B'})
    Assert-Equal 0 $run.Violations.Count ($run.Violations -join ' ; ')
    Assert-Equal 2 $run.Deliveries.Count
    Assert-False $run.Deliveries[0].Applied 'Reponse de A ecartee'
    Assert-Equal $run.Deliveries[0].Before $run.Deliveries[0].After 'Rien ne change a l arrivee de la reponse de A'
    Assert-True $run.Deliveries[1].Applied 'Reponse de B appliquee'
    Assert-True ($run.State.Panels['Fiche'].Value -like 'Fiche:B:*')
}
Test-Case 'D008' 'A, B puis retour a A : la reponse de la premiere visite de A est ecartee' {
    $run = Invoke-DomeniaRaceScript @(@{Kind='Select';Key='A'},@{Kind='Select';Key='B'},@{Kind='Select';Key='A'},@{Kind='Deliver';Panel='Relations';Key='A';Pick=0},@{Kind='Deliver';Panel='Relations';Key='A';Pick=0})
    Assert-Equal 0 $run.Violations.Count ($run.Violations -join ' ; ')
    Assert-False $run.Deliveries[0].Applied 'Meme objet, generation precedente : ecartee'
    Assert-True $run.Deliveries[1].Applied 'Visite courante de A : appliquee'
    Assert-True ($run.State.Panels['Relations'].Value -like 'Relations:A:*:3:#*') 'Donnee de la generation 3'
}
Test-Case 'D008' 'Changement de compte pendant la lecture : la reponse lue sous l ancien compte est ecartee' {
    $run = Invoke-DomeniaRaceScript @(@{Kind='Select';Key='C'},@{Kind='Reader'},@{Kind='Deliver';Panel='Assistance';Key='C';Pick=0},@{Kind='Deliver';Panel='Assistance';Key='C';Pick=0})
    Assert-Equal 0 $run.Violations.Count ($run.Violations -join ' ; ')
    Assert-False $run.Deliveries[0].Applied 'Lue sous EX\lecteur'
    Assert-True $run.Deliveries[1].Applied 'Lue sous EX\support'
    Assert-True ($run.State.Panels['Assistance'].Value -like '*:EX\support:*')
}
Test-Case 'D008' 'Compte A, B puis retour a A : la reponse lue avant la bascule ne remplace pas la reponse courante' {
    # Select A -> requests 1-3; account B -> 4-6; back to account A -> 7-9. Request 1 is answered last.
    $steps = @(@{Kind='Select';Key='A'},@{Kind='Reader'},@{Kind='Reader'},@{Kind='Deliver';Panel='Fiche';Id=7},@{Kind='Deliver';Panel='Fiche';Id=1})
    $run = Invoke-DomeniaRaceScript $steps
    Assert-Equal 0 $run.Violations.Count ($run.Violations -join ' ; ')
    Assert-Equal 'EX\lecteur' $run.State.Current.Reader 'Retour au premier compte'
    Assert-True $run.Deliveries[0].Applied 'Reponse de la visite courante appliquee'
    Assert-True $run.Deliveries[1].Stale 'La demande 1 appartient au premier contexte'
    Assert-Equal $run.State.Current.Reader $run.Deliveries[1].Job.Identity.Reader 'Meme compte que le contexte courant'
    Assert-False $run.Deliveries[1].Applied 'Reponse d avant la bascule ecartee'
    Assert-Equal $run.Deliveries[1].Before $run.Deliveries[1].After 'Rien ne change a son arrivee'
    Assert-True ($run.State.Panels['Fiche'].Value -like 'Fiche:A:EX\lecteur:*:#7') 'La fiche garde la reponse 7'
    # Same scenario with the caller contract broken (no new generation on an account switch): the identity tuple
    # repeats, SameContext accepts the stale answer, and the independent oracle reports it.
    $broken = Invoke-DomeniaRaceScript $steps -ReaderKeepsGeneration
    Assert-True $broken.Deliveries[1].SameTuple 'Contrat rompu : identite identique a celle du contexte courant'
    Assert-True $broken.Deliveries[1].Applied 'La regle reelle accepte la reponse perimee quand l appelant rompt le contrat'
    Assert-True ($broken.Violations.Count -gt 0) 'L oracle independant doit signaler la reponse perimee appliquee'
}
Test-Case 'D008' 'Passage a un compte jamais utilise : seul le compte distingue le contexte' {
    $run = Invoke-DomeniaRaceScript @(@{Kind='Select';Key='B'},@{Kind='NewReader'},@{Kind='Deliver';Panel='Relations';Key='B';Pick=0},@{Kind='Deliver';Panel='Relations';Key='B';Pick=0})
    Assert-Equal 0 $run.Violations.Count ($run.Violations -join ' ; ')
    $old = $run.Deliveries[0]
    Assert-Equal $run.State.Current.Generation $old.Job.Identity.Generation 'Meme generation'
    Assert-Equal $run.State.Current.Epoch $old.Job.Identity.Epoch 'Meme session'
    Assert-True ($run.State.Current.Reader -cne $old.Job.Identity.Reader) 'Compte different'
    Assert-False $old.Applied 'Reponse lue sous l ancien compte ecartee'
    Assert-True $run.Deliveries[1].Applied 'Reponse du nouveau compte appliquee'
    Assert-True ($run.State.Panels['Relations'].Value -like '*:EX\compte1:*')
}
Test-Case 'D008' 'Nouvelle session : les reponses de la session precedente sont ecartees' {
    $run = Invoke-DomeniaRaceScript @(@{Kind='Select';Key='B'},@{Kind='Session'},@{Kind='Deliver';Panel='Fiche';Key='B';Pick=0},@{Kind='Deliver';Panel='Fiche';Key='B';Pick=0})
    Assert-Equal 0 $run.Violations.Count ($run.Violations -join ' ; ')
    Assert-False $run.Deliveries[0].Applied; Assert-True $run.Deliveries[1].Applied
    Assert-Equal 2 $run.State.Current.Epoch
}
Test-Case 'D008' 'Annulation : une reponse arrivee apres l arret demande ne modifie rien' {
    $run = Invoke-DomeniaRaceScript @(@{Kind='Select';Key='A'},@{Kind='Cancel';Pick=0},@{Kind='Deliver';Panel='Fiche';Key='A'})
    Assert-Equal 0 $run.Violations.Count ($run.Violations -join ' ; ')
    Assert-Equal 'StopRequested' $run.Deliveries[0].TaskState
    Assert-False $run.Deliveries[0].Applied
    Assert-False $run.State.Panels.ContainsKey('Fiche') 'La fiche reste vide'
    $queued = New-DomeniaRaceState
    Set-DomeniaRaceContext $queued 'A' $null
    $queued.Pending[0].State = 'Queued'
    [void](Invoke-DomeniaRaceAction $queued (New-DomeniaRaceStep -Kind 'Cancel' -Pick 0))
    Assert-Equal 2 $queued.Pending.Count 'Une demande en file est retiree avant tout envoi'
}
Test-Case 'D008' 'Demande en file demarree apres un changement de selection : sa reponse est ecartee' {
    $state = New-DomeniaRaceState
    [void](Invoke-DomeniaRaceAction $state (New-DomeniaRaceStep -Kind 'Select' -Key 'A'))
    foreach ($job in $state.Pending) { $job.State = 'Queued' }
    [void](Invoke-DomeniaRaceAction $state (New-DomeniaRaceStep -Kind 'Select' -Key 'B'))
    [void](Invoke-DomeniaRaceAction $state (New-DomeniaRaceStep -Kind 'Start' -Key 'A' -Panel 'Fiche'))
    $delivery = Invoke-DomeniaRaceAction $state (New-DomeniaRaceStep -Kind 'Deliver' -Key 'A' -Panel 'Fiche')
    Assert-True ($null -ne $delivery) 'La demande demarree est livree'
    Assert-False $delivery.Applied 'Demarree tard, elle reste liee au contexte de A'
    Assert-Equal 0 @(Test-DomeniaRaceInvariant $state $delivery).Count
}
Test-Case 'D008' 'Precedent puis suivant pendant les lectures : seules les reponses de la derniere visite s appliquent' {
    $steps = @(@{Kind='Select';Key='A'},@{Kind='Select';Key='B'},@{Kind='Back'},@{Kind='Forward'})
    foreach ($key in @('A','B','A','B')) { $steps += @{Kind='Deliver';Panel='Fiche';Key=$key;Pick=0} }
    $run = Invoke-DomeniaRaceScript $steps
    Assert-Equal 0 $run.Violations.Count ($run.Violations -join ' ; ')
    Assert-Equal 'B' $run.State.Key
    Assert-Equal 4 $run.State.Current.Generation 'Retour et avance creent chacun une generation'
    $applied = @($run.Deliveries | Where-Object { $_.Applied })
    Assert-Equal 1 $applied.Count 'Une seule reponse appartient a la visite courante'
    Assert-True ($applied[0].Job.Payload -like 'Fiche:B:*:4:#*')
}
Test-Case 'D008' 'L invariant detecte une reponse perimee appliquee' {
    # The checker itself must fail when a stale answer changes the state.
    $accept = [scriptblock]{ param($Captured,$Current) $true }
    $run = Invoke-DomeniaRaceScript @(@{Kind='Select';Key='A'},@{Kind='Select';Key='B'},@{Kind='Deliver';Panel='Fiche';Key='A'}) $accept
    Assert-True ($run.Violations.Count -gt 0) 'Une reponse de A appliquee a la fiche de B doit etre signalee'
    $refuse = [scriptblock]{ param($Captured,$Current) $false }
    $run = Invoke-DomeniaRaceScript @(@{Kind='Select';Key='A'},@{Kind='Deliver';Panel='Fiche';Key='A'}) $refuse
    Assert-True ($run.Violations.Count -gt 0) 'Ecarter une reponse courante doit etre signale'
}
Test-Case 'D008' 'Generateur deterministe : meme graine, meme sequence' {
    $first = Invoke-DomeniaRaceCorpus -Seed 7 -Count 8
    $again = Invoke-DomeniaRaceCorpus -Seed 7 -Count 8
    $other = Invoke-DomeniaRaceCorpus -Seed 8 -Count 8
    Assert-Equal $first.TraceHash $again.TraceHash
    Assert-Equal $first.Steps $again.Steps
    Assert-Equal $first.Applied $again.Applied
    Assert-True ($first.TraceHash -cne $other.TraceHash) 'Une autre graine donne une autre sequence'
}
$script:RaceCorpus = $null
Test-Case 'D008' 'Sequences generees (graine fixe) : seule une reponse courante modifie l etat' {
    $script:RaceCorpus = Invoke-DomeniaRaceCorpus -Seed 20261002 -Count 300
    Assert-Equal 300 $script:RaceCorpus.Sequences
    Assert-Equal 0 $script:RaceCorpus.Violations.Count (@($script:RaceCorpus.Violations | Select-Object -First 3) -join ' ; ')
    Assert-True ($script:RaceCorpus.Applied -gt 0) 'Des reponses courantes sont appliquees'
    Assert-True ($script:RaceCorpus.Discarded -gt 0) 'Des reponses perimees sont ecartees'
    Assert-True ($script:RaceCorpus.LateCrossings -gt 0) 'Des reponses perimees arrivent alors que le contexte courant affiche deja des donnees'
    Assert-Equal 0 $script:RaceCorpus.IdentityCollisions 'Contrat respecte : aucune reponse perimee ne porte l identite du contexte courant'
}
Test-Case 'D008' 'Les sequences generees couvrent chaque course : objet, compte, retour de compte, session, generation, annulation' {
    if ($null -eq $script:RaceCorpus) { $script:RaceCorpus = Invoke-DomeniaRaceCorpus -Seed 20261002 -Count 300 }
    foreach ($kind in @('Select','Reader','NewReader','Session','Back','Forward','Cancel','Start','Deliver')) {
        Assert-True ($script:RaceCorpus.Kinds.ContainsKey($kind)) ('Action jamais tiree : ' + $kind)
    }
    Assert-True ($script:RaceCorpus.OtherObject -gt 0) 'Reponse d un autre objet'
    Assert-True ($script:RaceCorpus.OnlyReader -gt 0) 'Reponse lue sous un autre compte seulement'
    Assert-True ($script:RaceCorpus.AccountReturn -gt 0) 'Reponse lue avant un aller-retour de compte (A -> B -> A)'
    Assert-True ($script:RaceCorpus.OnlyEpoch -gt 0) 'Reponse d une autre session seulement'
    Assert-True ($script:RaceCorpus.OnlyGeneration -gt 0) 'Reponse d une autre visite du meme objet'
    Assert-True ($script:RaceCorpus.StoppedCurrent -gt 0) 'Reponse courante arrivee apres arret demande'
}
Test-Case 'D008' 'Une regle affaiblie ou un contrat d appelant rompu est detecte' {
    $mutants = [ordered]@{
        'objet seul'=[scriptblock]{ param($Captured,$Current) (($null -ne $Captured) -and ($null -ne $Current) -and $Captured.SameObject($Current)) }
        'compte ignore'=[scriptblock]{ param($Captured,$Current) (($null -ne $Captured) -and ($null -ne $Current) -and $Captured.SameObject($Current) -and ($Captured.Epoch -eq $Current.Epoch) -and ($Captured.Generation -eq $Current.Generation)) }
        'session ignoree'=[scriptblock]{ param($Captured,$Current) (($null -ne $Captured) -and ($null -ne $Current) -and $Captured.SameObject($Current) -and ($Captured.Reader -ceq $Current.Reader) -and ($Captured.Generation -eq $Current.Generation)) }
        'generation ignoree'=[scriptblock]{ param($Captured,$Current) (($null -ne $Captured) -and ($null -ne $Current) -and $Captured.SameObject($Current) -and ($Captured.Reader -ceq $Current.Reader) -and ($Captured.Epoch -eq $Current.Epoch)) }
    }
    foreach ($name in @($mutants.Keys)) {
        $run = Invoke-DomeniaRaceCorpus -Seed 20261002 -Count 300 -Decide $mutants[$name] -StopOnViolation
        Assert-True ($run.Violations.Count -gt 0) ('Regle affaiblie non detectee : ' + $name)
    }
    # Real rule, caller that keeps the generation on an account switch: the A -> B -> A collisions are found.
    $broken = Invoke-DomeniaRaceCorpus -Seed 20261002 -Count 300 -ReaderKeepsGeneration -StopOnViolation
    Assert-True ($broken.IdentityCollisions -gt 0) 'Le corpus doit produire des identites repetees quand le contrat est rompu'
    Assert-True ($broken.Violations.Count -gt 0) 'Contrat d appelant rompu non detecte'
}
