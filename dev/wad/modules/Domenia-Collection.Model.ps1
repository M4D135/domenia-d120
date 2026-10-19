# Collection rules, pure: no WPF, no network, no disk, no timer, no runspace and no hidden clock (every rule receives
# its NowUtc or Now; the default is only a convenience for callers). Two parts share this domain:
# Collection truth (roadmap of 13 October 2026, points 2, 3, 4, 5 and 10):
# - Three collection clocks per scope (AD objects, network presence, WMI inventory) recorded by the explicit OU
#   commands; recalculating a view never writes nor rejuvenates them.
# - The last success of a scope is kept apart from its last attempt and that attempt's error.
# - Each run keeps its provenance: controller, provider, collector version, observed and recorded times. Incoherent
#   dates are reported, never corrected.
# - An absent, unread, refused, stale, incomplete or failed measure keeps its own state: it never becomes a zero, a
#   healthy value or a fresh date.
# Collection for slow networks (roadmap points 11, 13, 14, 15, 17, 18, 19, 20, 159 and 160): freshness per usage
# profile, collection windows, budgets per controller or presumed subnet with suspension and progressive recovery,
# classification before any retry, capabilities of the workstations, grouping of the CIM reads, progress and durable
# plan of a campaign. Domenia-Collection.UI.ps1, Domenia-Park.UI.ps1 and Domenia-Engine.UI.ps1 apply them to the live
# engine and to every survey (lists, batch ping, widget collections).
# Depends only on Domenia-Common.Model.ps1 (Get-DomeniaMember, Get-DomeniaMemberValue, ConvertTo-DomeniaUtcDate,
# Get-DomeniaRawDnParent, ConvertTo-DomeniaGuidText), loaded first by every runner.

function Get-DomeniaCollectionLimits {
    # Explicit bounds of a recorded run. A counter above MaxCount or a text above its length is refused or cut,
    # never silently widened.
    return [pscustomobject]@{Version=1;MaxErrorLength=1024;MaxTextLength=256;MaxCount=10000000L;MaxPayloadBytes=16384;MaxScopeKeys=128;MaxDnLength=4096;ClockToleranceMinutes=2}
}

function Get-DomeniaCollectionFamilies {
    # The three explicit collection commands of an OU and the clock each one owns.
    return @(
        [pscustomobject]@{Family='Directory';Label='Objets AD';Clock='AD';Provider='LDAP'}
        [pscustomobject]@{Family='Presence';Label='Présence réseau (ping)';Clock='Ping';Provider='ICMP'}
        [pscustomobject]@{Family='Inventory';Label='Inventaire WMI';Clock='WMI';Provider='CIM/DCOM'}
    )
}

function ConvertTo-DomeniaCollectionRunListRows {
    # Decision David 2026-10-19 (Outils > Relevés, « Derniers relevés par OU »): one row per recorded family and scope,
    # newest attempt first. Only what was recorded is shown: date, OU, type, state, workstations read, last success and
    # reason. A record without a readable date is left out; nothing is guessed.
    param([object[]]$Runs=@())
    $culture=[Globalization.CultureInfo]::InvariantCulture
    $format={param($At) if($At -is [datetime]){return $At.ToLocalTime().ToString('dd/MM/yyyy HH:mm',$culture)};return ''}
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($raw in @($Runs)){
        $run=ConvertFrom-DomeniaCollectionRunRecord $raw
        if(($null -eq $run) -or ($null -eq $run.AttemptAtUtc)){continue}
        $family=[string]$run.Family
        $type=switch($family){'Directory'{'Objets AD'};'Presence'{'Ping'};'Inventory'{'WMI'};default{''}}
        if(-not $type){continue}
        $key=[string]$run.RequestKey;$subtree=$key.StartsWith('subtree:',[StringComparison]::Ordinal)
        $scope=[string](Get-DomeniaMember $run.Attempt 'ScopeDn' '')
        if(-not $scope){$scope=[string](Get-DomeniaMember $run.Success 'ScopeDn' '')}
        if((-not $scope) -and ($key.IndexOf(':') -ge 0)){$scope=$key.Substring($key.IndexOf(':')+1)}
        $name=$scope
        if($scope -match '^(?i)(OU|CN|DC)=([^,]+)'){$name=$Matches[2]}
        if($subtree -and $name){$name+=' et sous-OU'}
        $counts=Format-DomeniaCollectionCounts ([pscustomobject]@{Done=(Get-DomeniaMember $run.Attempt 'Done' $null);Targets=(Get-DomeniaMember $run.Attempt 'Targets' $null);Failed=(Get-DomeniaMember $run.Attempt 'Failed' $null)}) -Family $family
        $reason=([string]$run.Error).Trim()
        if($reason.Length -gt 200){$reason=$reason.Substring(0,200)+'…'}
        $rows.Add([pscustomobject]@{
            Date=(& $format $run.AttemptAtUtc);Ou=$name;OuDn=$scope;Type=$type;Etat=(Get-DomeniaCollectionStatusText ([string]$run.Status))
            Postes=$counts;Reussite=$(if($null -ne $run.SuccessAtUtc){& $format $run.SuccessAtUtc}else{'aucune'});Motif=$reason;AttemptUtc=$run.AttemptAtUtc
        })
    }
    return @($rows.ToArray()|Sort-Object -Property AttemptUtc -Descending)
}
function Get-DomeniaCollectionFamily {
    param([AllowEmptyString()][string]$Family)
    foreach($item in @(Get-DomeniaCollectionFamilies)){if([string]$item.Family -ceq $Family){return $item}}
    throw ('Famille de collecte inconnue : '+$Family)
}

function Get-DomeniaCollectionRunKey {
    # Identity of a collected scope: its depth and its raw DN in lower case, escapes kept. A direct-children run and
    # a subtree run of the same OU are two different scopes.
    param([AllowEmptyString()][string]$ScopeDn,[bool]$Subtree=$true)
    $limits=Get-DomeniaCollectionLimits
    $dn=([string]$ScopeDn).Trim()
    if((-not $dn) -or ($dn.Length -gt $limits.MaxDnLength) -or ($dn -match '[\x00-\x1f]') -or ($dn -notmatch '(?i)(^|,)\s*DC=')){throw 'Périmètre de collecte invalide.'}
    $prefix=if($Subtree){'subtree:'}else{'onelevel:'}
    return ($prefix+$dn.ToLowerInvariant())
}

function Get-DomeniaCollectionRunKeys {
    # Keys whose runs may date a view: the exact scope at its own depth, then every enclosing subtree up to the
    # domain. A direct-children run never dates the descendants of its OU, and a scope outside the domain has none.
    param([AllowEmptyString()][string]$ScopeDn,[AllowEmptyString()][string]$DomainDn,[bool]$Subtree=$true)
    $domain=([string]$DomainDn).Trim();$scope=([string]$ScopeDn).Trim()
    if(-not $domain){return}
    if(-not $scope){$scope=$domain}
    $chain=[Collections.Generic.List[string]]::new();$current=$scope;$inside=$false;$guard=0
    while(($current) -and ($guard -lt 512)){
        $chain.Add($current);$guard++
        if($current -ieq $domain){$inside=$true;break}
        $current=Get-DomeniaRawDnParent $current
    }
    if(-not $inside){return}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $first=Get-DomeniaCollectionRunKey $scope $Subtree
    if($seen.Add($first)){$first}
    foreach($dn in $chain){$key=Get-DomeniaCollectionRunKey $dn $true;if($seen.Add($key)){$key}}
}

function ConvertTo-DomeniaCollectionCount {
    # -1 (or less) means "not measured" and stays unknown ($null); a measured count is a bounded whole number.
    param([long]$Value,[string]$Name)
    if($Value -lt 0){return $null}
    if($Value -gt (Get-DomeniaCollectionLimits).MaxCount){throw ('Compteur de collecte hors limite : '+$Name)}
    return [long]$Value
}

function ConvertTo-DomeniaCollectionText {
    # One bounded line without control characters. The cut is visible.
    param([AllowNull()][AllowEmptyString()][string]$Text,[int]$Maximum=256)
    $value=([regex]::Replace([string]$Text,'[\x00-\x1f\x7f]+',' ')).Trim()
    $value=[regex]::Replace($value,'\s{2,}',' ')
    if(($Maximum -gt 1) -and ($value.Length -gt $Maximum)){return ($value.Substring(0,$Maximum-1)+[string][char]0x2026)}
    return $value
}

function New-DomeniaCollectionRunChange {
    # One finished OU collection, in the form admitted by the local store (Kind CollectionRun). Only a run that
    # really started a collection is recorded: a refusal or a cancellation before any network action is not an
    # attempt. The caller gives source times; no time is taken here except to refuse a future date.
    param(
        [Parameter(Mandatory=$true)][ValidateSet('Directory','Presence','Inventory')][string]$Family,
        [Parameter(Mandatory=$true)][string]$DomainDn,
        [Parameter(Mandatory=$true)][string]$ScopeDn,
        [bool]$Subtree=$true,
        [Parameter(Mandatory=$true)][ValidateSet('Success','Partial','Error','Cancelled')][string]$Status,
        [Parameter(Mandatory=$true)]$AttemptedAtUtc,
        [Parameter(Mandatory=$true)]$FinishedAtUtc,
        [AllowEmptyString()][string]$ErrorText='',
        [long]$Targets=-1,[long]$Done=-1,[long]$Succeeded=-1,[long]$Failed=-1,
        [AllowEmptyString()][string]$Controller='',
        [AllowEmptyString()][string]$CollectorVersion='',
        [datetime]$NowUtc=[datetime]::UtcNow
    )
    $limits=Get-DomeniaCollectionLimits
    $domain=([string]$DomainDn).Trim();$scope=([string]$ScopeDn).Trim()
    if($domain -notmatch '(?i)(^|,)\s*DC='){throw 'Domaine de collecte invalide.'}
    if(($scope -ine $domain) -and (-not $scope.EndsWith(','+$domain,[StringComparison]::OrdinalIgnoreCase))){throw 'Périmètre de collecte hors du domaine de connexion.'}
    $key=Get-DomeniaCollectionRunKey $scope $Subtree
    $started=ConvertTo-DomeniaUtcDate $AttemptedAtUtc;$finished=ConvertTo-DomeniaUtcDate $FinishedAtUtc
    if(($null -eq $started) -or ($null -eq $finished)){throw 'Dates de collecte absentes ou illisibles.'}
    $latest=$NowUtc.ToUniversalTime().AddMinutes($limits.ClockToleranceMinutes)
    if(($started -gt $latest) -or ($finished -gt $latest)){throw 'Date de collecte dans le futur : vérifiez lʼhorloge de ce poste.'}
    if($finished -lt $started){throw 'Fin de collecte antérieure à son début.'}
    $message=ConvertTo-DomeniaCollectionText $ErrorText $limits.MaxErrorLength
    if($Status -eq 'Success'){if($message){throw 'Une collecte réussie ne porte pas dʼerreur.'}}
    elseif(-not $message){
        $message=switch($Status){'Partial'{'Collecte partielle : certaines lectures ne sont pas confirmées.'};'Cancelled'{'Collecte arrêtée avant la fin.'};default{'Collecte non confirmée.'}}
    }
    $counts=[ordered]@{Targets=(ConvertTo-DomeniaCollectionCount $Targets 'Targets');Done=(ConvertTo-DomeniaCollectionCount $Done 'Done');Succeeded=(ConvertTo-DomeniaCollectionCount $Succeeded 'Succeeded');Failed=(ConvertTo-DomeniaCollectionCount $Failed 'Failed')}
    if(($null -ne $counts.Targets) -and ($null -ne $counts.Done) -and ($counts.Done -gt $counts.Targets)){throw 'Plus de postes traités que de cibles.'}
    if(($null -ne $counts.Done) -and ($null -ne $counts.Succeeded) -and ($null -ne $counts.Failed) -and (($counts.Succeeded+$counts.Failed) -gt $counts.Done)){throw 'Comptes de réussites et dʼéchecs incohérents.'}
    $info=Get-DomeniaCollectionFamily $Family
    $data=[ordered]@{
        Format='Domenia.CollectionRun/1';Family=$Family;ScopeDn=$scope;Subtree=[bool]$Subtree
        Provider=[string]$info.Provider;Controller=(ConvertTo-DomeniaCollectionText $Controller $limits.MaxTextLength)
        CollectorVersion=(ConvertTo-DomeniaCollectionText $CollectorVersion 128)
        StartedAtUtc=$started.ToString('o',[Globalization.CultureInfo]::InvariantCulture);FinishedAtUtc=$finished.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        Targets=$counts.Targets;Done=$counts.Done;Succeeded=$counts.Succeeded;Failed=$counts.Failed
    }
    return [pscustomobject]@{Kind='CollectionRun';Family=$Family;DomainDn=$domain;ScopeDn=$scope;Subtree=[bool]$Subtree;RequestKey=$key;Status=$Status;AttemptedAtUtc=$data.StartedAtUtc;FinishedAtUtc=$data.FinishedAtUtc;Error=$message;Data=[pscustomobject]$data}
}

function New-DomeniaRefreshRunChanges {
    # Run records of one finished OU refresh (Refresh.UI): AD objects when the AD read of the OU was started; network
    # presence and WMI inventory only when the workstation collection was confirmed and dispatched. A refusal or a
    # cancellation before any network action records nothing. Counters come only from what the run measured.
    # Directory: {Started;Status;Error;StartedUtc;FinishedUtc;Controller;Count}. Collection: {Approved;StartedUtc;
    # FinishedUtc;Targets;Done;Failed;Stopping;FailureMessage;StorageConfirmed}. Outcome: '' while still running
    # normally, Error or Cancelled when the refresh stopped, with OutcomeMessage.
    param(
        [Parameter(Mandatory=$true)][ValidateSet('AD','Ping','Wmi','Base','Postes','Both')][string]$Mode,
        [Parameter(Mandatory=$true)][string]$DomainDn,
        [Parameter(Mandatory=$true)][string]$ScopeDn,
        $Directory=$null,$Collection=$null,
        [ValidateSet('','Error','Cancelled')][string]$Outcome='',
        [AllowEmptyString()][string]$OutcomeMessage='',
        [AllowEmptyString()][string]$CollectorVersion='',
        [datetime]$NowUtc=[datetime]::UtcNow
    )
    $now=$NowUtc.ToUniversalTime()
    if(($Mode -in @('AD','Base','Both')) -and ([bool](Get-DomeniaMember $Directory 'Started' $false))){
        $status=[string](Get-DomeniaMember $Directory 'Status' '');$message=[string](Get-DomeniaMember $Directory 'Error' '')
        if($status -notin @('Success','Partial')){
            if($Outcome -eq 'Cancelled'){$status='Cancelled';if(-not $message){$message='Lecture AD arrêtée avant son enregistrement.'}}
            else{$status='Error';if(-not $message){$message=$(if($OutcomeMessage){$OutcomeMessage}else{'Lecture AD sans reçu dʼenregistrement.'})}}
        }
        if($status -eq 'Success'){$message=''}
        $started=Get-DomeniaMember $Directory 'StartedUtc' $null;$finished=Get-DomeniaMember $Directory 'FinishedUtc' $null
        if($null -eq (ConvertTo-DomeniaUtcDate $finished)){$finished=$now}
        $count=[long](Get-DomeniaMember $Directory 'Count' -1)
        New-DomeniaCollectionRunChange -Family Directory -DomainDn $DomainDn -ScopeDn $ScopeDn -Subtree $true -Status $status -AttemptedAtUtc $started -FinishedAtUtc $finished -ErrorText $message -Done $count -Controller ([string](Get-DomeniaMember $Directory 'Controller' '')) -CollectorVersion $CollectorVersion -NowUtc $now
    }
    $families=@(switch($Mode){'Ping'{'Presence'};'Wmi'{'Inventory'};'Postes'{'Presence';'Inventory'};'Both'{'Presence';'Inventory'}})
    if(($families.Count -eq 0) -or (-not [bool](Get-DomeniaMember $Collection 'Approved' $false))){return}
    $started=Get-DomeniaMember $Collection 'StartedUtc' $null
    if($null -eq (ConvertTo-DomeniaUtcDate $started)){return}
    $finished=Get-DomeniaMember $Collection 'FinishedUtc' $null;if($null -eq (ConvertTo-DomeniaUtcDate $finished)){$finished=$now}
    $targets=[long](Get-DomeniaMember $Collection 'Targets' -1);$done=[long](Get-DomeniaMember $Collection 'Done' -1);$failed=[long](Get-DomeniaMember $Collection 'Failed' -1)
    $succeeded=if(($done -ge 0) -and ($failed -ge 0) -and ($failed -le $done)){$done-$failed}else{-1L}
    $failure=[string](Get-DomeniaMember $Collection 'FailureMessage' '')
    $progress=if($done -ge 0){[string]$done+$(if($targets -ge 0){'/'+[string]$targets}else{''})+' poste(s) traité(s)'}else{'progression non mesurée'}
    if($failure){$status='Error';$message=$failure}
    elseif($Outcome -eq 'Error'){$status='Error';$message=$(if($OutcomeMessage){$OutcomeMessage}else{'Relevé interrompu.'})}
    elseif(($Outcome -eq 'Cancelled') -or ([bool](Get-DomeniaMember $Collection 'Stopping' $false))){$status='Cancelled';$message='Relevé arrêté : '+$progress+'.'}
    elseif(-not [bool](Get-DomeniaMember $Collection 'StorageConfirmed' $false)){$status='Error';$message='Relevé terminé, enregistrement local non confirmé.'}
    elseif($failed -gt 0){$status='Partial';$message=[string]$failed+' poste(s) avec au moins une lecture non confirmée ; '+$progress+'.'}
    else{$status='Success';$message=''}
    foreach($family in $families){
        New-DomeniaCollectionRunChange -Family $family -DomainDn $DomainDn -ScopeDn $ScopeDn -Subtree $true -Status $status -AttemptedAtUtc $started -FinishedAtUtc $finished -ErrorText $message -Targets $targets -Done $done -Succeeded $succeeded -Failed $failed -CollectorVersion $CollectorVersion -NowUtc $now
    }
}

function Test-DomeniaCollectionClock {
    # Reports incoherent dates of a run or of a measure; nothing is corrected. Observed: start of the collection or
    # time of the measure. Finished: end of the collection. Attempt: last attempt of the same record. Recorded: commit
    # of the batch that saved the observed value. A future date, an end before its start, a success after its own
    # last attempt or a value committed before it was collected makes the record unusable as a fresh value.
    param($ObservedUtc=$null,$FinishedUtc=$null,$AttemptUtc=$null,$RecordedUtc=$null,[datetime]$NowUtc=[datetime]::UtcNow)
    $tolerance=[timespan]::FromMinutes((Get-DomeniaCollectionLimits).ClockToleranceMinutes)
    $issues=[Collections.Generic.List[object]]::new()
    $read={param($Value,[string]$Name)
        if(($null -eq $Value) -or (($Value -is [string]) -and (-not $Value.Trim()))){return $null}
        $date=ConvertTo-DomeniaUtcDate $Value
        if($null -eq $date){$issues.Add([pscustomobject]@{Code='Unreadable';Text=('date '+$Name+' illisible')})}
        return $date
    }
    $observed=& $read $ObservedUtc 'observée';$finished=& $read $FinishedUtc 'de fin';$attempt=& $read $AttemptUtc 'de tentative';$recorded=& $read $RecordedUtc 'dʼenregistrement'
    $latest=$NowUtc.ToUniversalTime().Add($tolerance)
    foreach($pair in @(@($observed,'observée'),@($finished,'de fin'),@($attempt,'de tentative'),@($recorded,'dʼenregistrement'))){
        if(($null -ne $pair[0]) -and ($pair[0] -gt $latest)){$issues.Add([pscustomobject]@{Code='Future';Text=('date '+$pair[1]+' future : horloge à vérifier')})}
    }
    if(($null -ne $observed) -and ($null -ne $finished) -and ($finished -lt $observed)){$issues.Add([pscustomobject]@{Code='EndBeforeStart';Text='fin de collecte antérieure à son début'})}
    if(($null -ne $observed) -and ($null -ne $attempt) -and ($observed -gt $attempt.Add($tolerance))){$issues.Add([pscustomobject]@{Code='SuccessAfterAttempt';Text='réussite postérieure à la dernière tentative enregistrée'})}
    if($null -ne $recorded){
        # The record dates the measure it holds (start and end), not a later attempt saved in another batch.
        $reference=$observed
        if(($null -ne $finished) -and (($null -eq $reference) -or ($finished -gt $reference))){$reference=$finished}
        if(($null -ne $reference) -and ($recorded.Add($tolerance) -lt $reference)){$issues.Add([pscustomobject]@{Code='RecordedBeforeObserved';Text='enregistrement antérieur à la collecte'})}
    }
    $text=if($issues.Count){'Dates incohérentes : '+(@($issues|ForEach-Object{[string]$_.Text}|Select-Object -Unique) -join ' ; ')+'.'}else{''}
    return [pscustomobject]@{Coherent=($issues.Count -eq 0);Issues=$issues.ToArray();Text=$text}
}

function ConvertFrom-DomeniaCollectionRunRecord {
    # One committed domenia_domain_metadata record, as projected by the local readers (LastAttemptAtUtc, Status,
    # Error, LastSuccessAtUtc, Data, AttemptData), into typed clocks. A malformed record gives no date.
    param($Record)
    if($null -eq $Record){return $null}
    $success=Get-DomeniaMemberValue $Record 'Data';$attempt=Get-DomeniaMemberValue $Record 'AttemptData'
    $status=[string](Get-DomeniaMember $Record 'Status' '')
    if($status -notin @('Success','Partial','Error','Cancelled')){$status='Error'}
    $successAt=ConvertTo-DomeniaUtcDate ([string](Get-DomeniaMember $Record 'LastSuccessAtUtc' ''))
    $attemptAt=ConvertTo-DomeniaUtcDate ([string](Get-DomeniaMember $Record 'LastAttemptAtUtc' ''))
    if($null -eq $successAt){$success=$null}
    $attemptData=if($status -eq 'Success'){$success}else{$attempt}
    return [pscustomobject]@{
        Family=[string](Get-DomeniaMember $Record 'Family' '');RequestKey=[string](Get-DomeniaMember $Record 'RequestKey' '');DomainDn=[string](Get-DomeniaMember $Record 'DomainDn' '')
        Revision=[long](Get-DomeniaMember $Record 'Revision' 0)
        SuccessAtUtc=$successAt;Success=$success
        AttemptAtUtc=$attemptAt;Status=$status;Error=[string](Get-DomeniaMember $Record 'Error' '');Attempt=$attemptData
    }
}

function Get-DomeniaCollectionClock {
    # Clock of one family for one view: the newest successful run and the newest attempt among the exact scope and
    # its enclosing subtrees. A failed attempt never hides an older success and never ages it; an older failure
    # never hides a newer success. Records of another domain or family are ignored.
    param([object[]]$Runs=@(),[Parameter(Mandatory=$true)][ValidateSet('Directory','Presence','Inventory')][string]$Family,[AllowEmptyString()][string]$ScopeDn='',[AllowEmptyString()][string]$DomainDn='',[bool]$Subtree=$true,[datetime]$NowUtc=[datetime]::UtcNow)
    $info=Get-DomeniaCollectionFamily $Family
    $keys=@(Get-DomeniaCollectionRunKeys -ScopeDn $ScopeDn -DomainDn $DomainDn -Subtree $Subtree)
    # A run is inherited when it was collected on another OU (an enclosing subtree), not when only its depth differs:
    # the subtree run of the viewed OU dates its direct-children view without coming from an enclosing OU.
    $viewDn=([string]$ScopeDn).Trim();if(-not $viewDn){$viewDn=([string]$DomainDn).Trim()}
    $viewDn=$viewDn.ToLowerInvariant()
    $inherited={param([string]$RequestKey) return ($RequestKey.Substring($RequestKey.IndexOf(':')+1) -cne $viewDn)}
    $best=$null;$latest=$null
    foreach($raw in @($Runs)){
        if(($null -eq $raw) -or ([string](Get-DomeniaMember $raw 'Family' '') -cne $Family)){continue}
        if([string](Get-DomeniaMember $raw 'DomainDn' '') -ine ([string]$DomainDn).Trim()){continue}
        $key=[string](Get-DomeniaMember $raw 'RequestKey' '')
        if($keys -cnotcontains $key){continue}
        $run=ConvertFrom-DomeniaCollectionRunRecord $raw
        if(($null -ne $run.SuccessAtUtc) -and (($null -eq $best) -or ($run.SuccessAtUtc -gt $best.SuccessAtUtc))){$best=$run}
        if(($null -ne $run.AttemptAtUtc) -and (($null -eq $latest) -or ($run.AttemptAtUtc -gt $latest.AttemptAtUtc))){$latest=$run}
    }
    $successView=$null;$attemptView=$null
    if($null -ne $best){
        $data=$best.Success
        $successView=[pscustomobject]@{
            AtUtc=$best.SuccessAtUtc;FinishedAtUtc=(ConvertTo-DomeniaUtcDate ([string](Get-DomeniaMember $data 'FinishedAtUtc' '')));RecordedAtUtc=(ConvertTo-DomeniaUtcDate ([string](Get-DomeniaMember $data 'RecordedAtUtc' '')))
            ScopeDn=[string](Get-DomeniaMember $data 'ScopeDn' '');Inherited=(& $inherited $best.RequestKey)
            Controller=[string](Get-DomeniaMember $data 'Controller' '');Provider=[string](Get-DomeniaMember $data 'Provider' $info.Provider);CollectorVersion=[string](Get-DomeniaMember $data 'CollectorVersion' '')
            Targets=(Get-DomeniaMember $data 'Targets' $null);Done=(Get-DomeniaMember $data 'Done' $null);Succeeded=(Get-DomeniaMember $data 'Succeeded' $null);Failed=(Get-DomeniaMember $data 'Failed' $null)
        }
        $successView|Add-Member -NotePropertyName Qualification -NotePropertyValue (Test-DomeniaCollectionClock -ObservedUtc $successView.AtUtc -FinishedUtc $successView.FinishedAtUtc -AttemptUtc $best.AttemptAtUtc -RecordedUtc $successView.RecordedAtUtc -NowUtc $NowUtc)
    }
    if($null -ne $latest){
        $data=$latest.Attempt
        $attemptView=[pscustomobject]@{
            AtUtc=$latest.AttemptAtUtc;Status=$latest.Status;Error=$latest.Error
            FinishedAtUtc=(ConvertTo-DomeniaUtcDate ([string](Get-DomeniaMember $data 'FinishedAtUtc' '')));RecordedAtUtc=(ConvertTo-DomeniaUtcDate ([string](Get-DomeniaMember $data 'RecordedAtUtc' '')))
            ScopeDn=[string](Get-DomeniaMember $data 'ScopeDn' '');Inherited=(& $inherited $latest.RequestKey)
            Controller=[string](Get-DomeniaMember $data 'Controller' '');Provider=[string](Get-DomeniaMember $data 'Provider' $info.Provider);CollectorVersion=[string](Get-DomeniaMember $data 'CollectorVersion' '')
            Targets=(Get-DomeniaMember $data 'Targets' $null);Done=(Get-DomeniaMember $data 'Done' $null);Succeeded=(Get-DomeniaMember $data 'Succeeded' $null);Failed=(Get-DomeniaMember $data 'Failed' $null)
        }
        $attemptView|Add-Member -NotePropertyName Qualification -NotePropertyValue (Test-DomeniaCollectionClock -ObservedUtc $attemptView.AtUtc -FinishedUtc $attemptView.FinishedAtUtc -RecordedUtc $attemptView.RecordedAtUtc -NowUtc $NowUtc)
    }
    # The attempt is shown beside the success only when it is newer and did not succeed.
    $failedAfter=(($null -ne $attemptView) -and ($attemptView.Status -ne 'Success') -and (($null -eq $successView) -or ($attemptView.AtUtc -gt $successView.AtUtc)))
    $coherent=((($null -eq $successView) -or ([bool]$successView.Qualification.Coherent)) -and (($null -eq $attemptView) -or ([bool]$attemptView.Qualification.Coherent)))
    $state=if($null -eq $attemptView){'NeverRecorded'}elseif(-not $coherent){'Incoherent'}elseif(($failedAfter) -and ($null -ne $successView)){'SuccessThenFailure'}elseif($failedAfter){'FailureOnly'}else{'Success'}
    return [pscustomobject]@{Version=1;Family=$Family;Label=[string]$info.Label;Clock=[string]$info.Clock;State=$state;Success=$successView;Attempt=$attemptView;AttemptFailedAfterSuccess=$failedAfter;Coherent=$coherent;ScopeDn=([string]$ScopeDn).Trim();Subtree=$Subtree}
}

function Get-DomeniaCollectionClocks {
    # The three clocks of one view, from one committed snapshot of collection runs.
    param([object[]]$Runs=@(),[AllowEmptyString()][string]$ScopeDn='',[AllowEmptyString()][string]$DomainDn='',[bool]$Subtree=$true,[datetime]$NowUtc=[datetime]::UtcNow)
    $result=[ordered]@{Version=1}
    foreach($family in @('Directory','Presence','Inventory')){$result[$family]=Get-DomeniaCollectionClock -Runs $Runs -Family $family -ScopeDn $ScopeDn -DomainDn $DomainDn -Subtree $Subtree -NowUtc $NowUtc}
    return [pscustomobject]$result
}

function Get-DomeniaCollectionStatusText {
    param([AllowEmptyString()][string]$Status)
    switch($Status){'Success'{return 'réussi'};'Partial'{return 'partiel'};'Cancelled'{return 'arrêté'};default{return 'en échec'}}
}

function Format-DomeniaCollectionCounts {
    # "198/200 postes" or "198 postes" or "": only measured counters are written. An AD read (Directory) counts every
    # object read in its OU (users, groups, OUs and computers): its unit is the AD object, never the workstation.
    param($View,[AllowEmptyString()][string]$Family='')
    $done=Get-DomeniaMember $View 'Done' $null;$targets=Get-DomeniaMember $View 'Targets' $null;$failed=Get-DomeniaMember $View 'Failed' $null
    if($null -eq $done){return ''}
    $text=[string]$done
    if($null -ne $targets){$text+='/'+[string]$targets}
    $plural=([long]$done -gt 1)
    $text+=$(if($Family -ceq 'Directory'){' objet'+$(if($plural){'s'}else{''})+' AD'}else{' poste'+$(if($plural){'s'}else{''})})
    if(($null -ne $failed) -and ([long]$failed -gt 0)){$text+=', '+[string]$failed+' non confirmé'+$(if([long]$failed -gt 1){'s'}else{''})}
    return $text
}

function Format-DomeniaCollectionClock {
    # French text of one clock. Text: one line for the page. Detail: provenance for the tool tip (controller,
    # provider, observed, end and recorded times, collector version). Nothing is said for a family never recorded,
    # except Text='' and the caller's own wording.
    param($Clock,[datetime]$NowUtc=[datetime]::UtcNow)
    $culture=[Globalization.CultureInfo]::InvariantCulture
    $date={param($At) if($At -is [datetime]){return $At.ToLocalTime().ToString('dd/MM/yyyy HH:mm',$culture)};return 'date inconnue'}
    $success=Get-DomeniaMemberValue $Clock 'Success';$attempt=Get-DomeniaMemberValue $Clock 'Attempt'
    $label=[string](Get-DomeniaMember $Clock 'Label' '');$family=[string](Get-DomeniaMember $Clock 'Family' '')
    if(($null -eq $success) -and ($null -eq $attempt)){return [pscustomobject]@{Text='';Detail=($label+' : aucun relevé de périmètre enregistré.');Warning=$false}}
    $parts=[Collections.Generic.List[string]]::new();$detail=[Collections.Generic.List[string]]::new();$warning=$false;$partialShown=$false
    $describe={param($View,[string]$Kind)
        $line=$Kind+' : '+(& $date $View.AtUtc)
        if($View.FinishedAtUtc -is [datetime]){$line+=' → '+(& $date $View.FinishedAtUtc)}
        if($View.RecordedAtUtc -is [datetime]){$line+=' ; enregistré le '+(& $date $View.RecordedAtUtc)}else{$line+=' ; heure dʼenregistrement non conservée'}
        if($View.ScopeDn){$line+=' ; périmètre '+$View.ScopeDn+$(if($View.Inherited){' (OU englobante)'}else{''})}
        $source=@(@($(if($View.Provider){'fournisseur '+$View.Provider}),$(if($View.Controller){'contrôleur '+$View.Controller}),$(if($View.CollectorVersion){'version de collecte '+$View.CollectorVersion}))|Where-Object{$_})
        if($source.Count){$line+=' ; '+($source -join ', ')}
        $counts=Format-DomeniaCollectionCounts $View -Family $family;if($counts){$line+=' ; '+$counts}
        return $line
    }
    if($null -ne $success){
        if($family -ne 'Directory'){
            $text='relevé réussi le '+(& $date $success.AtUtc)
            $counts=Format-DomeniaCollectionCounts $success -Family $family;if($counts){$text+=' ('+$counts+')'}
            if($success.Inherited){$text+=' via une OU englobante'}
            $parts.Add($text)
        }
        $detail.Add((& $describe $success 'Dernière réussite'))
        if(-not [bool]$success.Qualification.Coherent){$parts.Add([string]$success.Qualification.Text);$warning=$true}
    }elseif($family -ne 'Directory'){
        # Decision David 2026-10-19: a stopped or incomplete survey stays usable. Without any success, the workstations
        # it read are named as a partial survey instead of « aucun relevé réussi » (each measure keeps its own date).
        $partialDone=[long](Get-DomeniaMember $attempt 'Done' 0)
        if(($null -ne $attempt) -and ($partialDone -gt 0)){
            $text='relevé partiel le '+(& $date $attempt.AtUtc)+' ('+(Format-DomeniaCollectionCounts $attempt -Family $family)+', '+(Get-DomeniaCollectionStatusText $attempt.Status)+') ; les postes lus sont exploitables'
            if($attempt.Inherited){$text+=' via une OU englobante'}
            $parts.Add($text);$warning=$true;$partialShown=$true
            $detail.Add((& $describe $attempt ('Relevé partiel ('+(Get-DomeniaCollectionStatusText $attempt.Status)+')'))+$(if($attempt.Error){' ; motif : '+$attempt.Error}else{''}))
        }else{$parts.Add('aucun relevé réussi enregistré')}
    }
    if((-not $partialShown) -and ([bool](Get-DomeniaMember $Clock 'AttemptFailedAfterSuccess' $false)) -and ($null -ne $attempt)){
        $text='dernière tentative le '+(& $date $attempt.AtUtc)+' : '+(Get-DomeniaCollectionStatusText $attempt.Status)
        if($attempt.Error){$text+=' — '+(ConvertTo-DomeniaCollectionText $attempt.Error 160)}
        if($null -ne $success){$text+=' ; la dernière réussite reste la référence'}
        $parts.Add($text);$warning=$true
        $detail.Add((& $describe $attempt ('Dernière tentative ('+(Get-DomeniaCollectionStatusText $attempt.Status)+')'))+$(if($attempt.Error){' ; erreur : '+$attempt.Error}else{''}))
        if(-not [bool]$attempt.Qualification.Coherent){$parts.Add([string]$attempt.Qualification.Text)}
    }
    return [pscustomobject]@{Text=($parts -join ' ; ');Detail=($label+"`r`n"+($detail -join "`r`n"));Warning=$warning}
}

function Format-DomeniaCollectionClocks {
    # DirectoryText completes the AD line; RunsText is the line of the ping and WMI campaigns of the OU; Detail is the
    # provenance tool tip of the three clocks.
    param($Clocks,[datetime]$NowUtc=[datetime]::UtcNow)
    $directory=Format-DomeniaCollectionClock (Get-DomeniaMemberValue $Clocks 'Directory') $NowUtc
    $presence=Format-DomeniaCollectionClock (Get-DomeniaMemberValue $Clocks 'Presence') $NowUtc
    $inventory=Format-DomeniaCollectionClock (Get-DomeniaMemberValue $Clocks 'Inventory') $NowUtc
    $runs=[Collections.Generic.List[string]]::new()
    if($presence.Text){$runs.Add('ping '+$presence.Text)}
    if($inventory.Text){$runs.Add('WMI '+$inventory.Text)}
    $runsText=if($runs.Count){'Relevés de lʼOU : '+($runs -join ' · ')}else{'Relevés de lʼOU : aucun relevé ping ou WMI enregistré pour ce périmètre.'}
    return [pscustomobject]@{DirectoryText=$directory.Text;RunsText=$runsText;Detail=(@($directory.Detail,$presence.Detail,$inventory.Detail) -join "`r`n`r`n");Warning=(([bool]$directory.Warning) -or ([bool]$presence.Warning) -or ([bool]$inventory.Warning))}
}

function Format-DomeniaObservationProvenance {
    # Provenance of one committed measure family as read by StoreRead (point 10): last success, last attempt and its
    # error, commit of the last local write, collector definition. Incoherent dates are named, never corrected.
    param($Observation,[datetime]$NowUtc=[datetime]::UtcNow)
    $success=[string](Get-DomeniaMember $Observation 'LastSuccessAtUtc' '');$attempt=[string](Get-DomeniaMember $Observation 'LastAttemptAtUtc' '')
    $recorded=[string](Get-DomeniaMember $Observation 'RecordedAtUtc' '');$status=[string](Get-DomeniaMember $Observation 'Status' '')
    $failure=[string](Get-DomeniaMember $Observation 'Error' '');$definition=[string](Get-DomeniaMember $Observation 'DefinitionHash' '')
    $parts=[Collections.Generic.List[string]]::new()
    $parts.Add('Réussite UTC : '+$(if($success){$success}else{'aucune'}))
    $line='Tentative UTC : '+$(if($attempt){$attempt}else{'inconnue'})
    if(($status -ne 'Success') -and ($failure)){$line+=' (non confirmée : '+(ConvertTo-DomeniaCollectionText $failure 240)+')'}
    $parts.Add($line)
    $parts.Add('Écriture locale UTC : '+$(if($recorded){$recorded}else{'non conservée'}))
    if($definition){$parts.Add('Définition de collecte : '+$definition.Substring(0,[Math]::Min(12,$definition.Length)))}
    $quality=Test-DomeniaCollectionClock -ObservedUtc $success -AttemptUtc $attempt -RecordedUtc $recorded -NowUtc $NowUtc
    if(-not [bool]$quality.Coherent){$parts.Add([string]$quality.Text)}
    return [pscustomobject]@{Text=($parts -join ' · ');Coherent=[bool]$quality.Coherent;Issues=$quality.Issues}
}

# ---------------------------------------------------------------- point 3: states of a measure
function Get-DomeniaMeasureStateKeys {
    # The one vocabulary of a measure state, for every family and every channel (ping, console, WMI inventory, probes
    # and the WMI answer of the fleet board, point 72): Known is a valid dated measure; every other key is a reason why
    # none is usable. Counters, filters and texts read these keys, never a label.
    return @('Known','Absent','NotRead','Refused','Expired','Incomplete','Error')
}

function Get-DomeniaMeasureStateLabel {
    param([AllowEmptyString()][string]$State)
    switch($State){
        'Known'{return 'Mesure valide'};'Absent'{return 'Jamais relevé'};'NotRead'{return 'Non lu'};'Refused'{return 'Refusé'}
        'Expired'{return 'Périmé'};'Incomplete'{return 'Incomplet'};default{return 'En erreur'}
    }
}

function Test-DomeniaMeasureRefusal {
    # A refusal of access or of credentials, from the outcome or the stored error text.
    param([AllowEmptyString()][string]$Outcome='',[AllowEmptyString()][string]$ErrorText='')
    if($Outcome -in @('Denied','AuthRejected')){return $true}
    return ([string]$ErrorText -match '(?i)acc[eè]s\s+refus|access\s+(is\s+)?denied|refus[eé]|identifiants?\s+(rejet|refus)|logon\s+failure|unauthori[sz]ed|0x80070005|AuthRejected|CredentialsRejected')
}

function Get-DomeniaMeasureState {
    # One measurement family of one workstation from its committed projection (PowerShell or native). Known only
    # when a successful, dated, complete and unexpired value exists; otherwise the reason stays visible: Absent
    # (never collected), NotRead (not requested or not applicable), Refused, Expired, Incomplete or Error (failure
    # or incoherent clock). Presence and the console user are instant facts: a newer failed attempt makes them
    # unknown now (the older success keeps its own date). Inventory and probe values stay usable with their date,
    # and the newer failed attempt is reported beside them.
    # ToleranceMinutes: clock skew accepted before a date counts as future (the collection limit by default).
    param($Observation,[Parameter(Mandatory=$true)][string]$Family,[datetime]$NowUtc=[datetime]::UtcNow,[int]$MaxDays=30,[int]$ToleranceMinutes=-1)
    if($Family -notmatch '^(Presence|Console|Inventory|Probe:[A-Za-z0-9_.-]{1,128})$'){throw 'Famille de mesure invalide.'}
    if($ToleranceMinutes -lt 0){$ToleranceMinutes=(Get-DomeniaCollectionLimits).ClockToleranceMinutes}
    $make={param([string]$State,[string]$Reason,$Success,$Attempt,[bool]$Failed,[string]$ErrorText)
        [pscustomobject]@{Family=$Family;State=$State;Label=(Get-DomeniaMeasureStateLabel $State);Reason=$Reason;LastSuccessUtc=$Success;LastAttemptUtc=$Attempt;LastAttemptFailed=$Failed;Error=$ErrorText}
    }
    if($null -eq $Observation){return (& $make 'Absent' 'Aucun relevé enregistré pour ce poste.' $null $null $false '')}
    $times=Get-DomeniaMemberValue $Observation 'Times'
    $time=Get-DomeniaMemberValue $times $Family
    $successText='';$attemptText='';$errorText='';$outcome='';$skipped='';$truncated=$false;$countComplete=$false;$instant=$false;$present=($null -ne $time);$value=''
    switch -Regex ($Family){
        '^Presence$'{
            $instant=$true;$successText=[string](Get-DomeniaMember $Observation 'PresenceCheckedUtc' '');$attemptText=[string](Get-DomeniaMember $Observation 'PresenceAttemptUtc' '')
            $errorText=[string](Get-DomeniaMember $Observation 'PresenceError' '');$value=[string](Get-DomeniaMember $Observation 'Presence' '')
            if(($successText) -or ($attemptText) -or ($value)){$present=$true}
        }
        '^Console$'{
            $instant=$true;$successText=[string](Get-DomeniaMember $Observation 'ConsoleCheckedUtc' '');if(-not $successText){$successText=[string](Get-DomeniaMember $Observation 'UserCheckedUtc' '')}
            $attemptText=[string](Get-DomeniaMember $Observation 'ConsoleAttemptUtc' '');$errorText=[string](Get-DomeniaMember $Observation 'ConsoleError' '');$outcome=[string](Get-DomeniaMember $Observation 'Outcome' '')
            if(($successText) -or ($attemptText)){$present=$true}
        }
        '^Inventory$'{
            $inventory=Get-DomeniaMemberValue $Observation 'Inventory'
            $successText=[string](Get-DomeniaMember $inventory 'CheckedUtc' '');if(-not $successText){$successText=[string](Get-DomeniaMember $Observation 'InventoryCheckedUtc' '')}
            $attemptText=[string](Get-DomeniaMember $Observation 'InventoryAttemptUtc' '');$errorText=[string](Get-DomeniaMember $Observation 'InventoryError' '')
            if(($successText) -or ($attemptText) -or ($errorText)){$present=$true}
        }
        default{
            $probe=Get-DomeniaMemberValue (Get-DomeniaMemberValue $Observation 'Probes') $Family.Substring(6)
            if($null -ne $probe){
                $present=$true;$successText=[string](Get-DomeniaMember $probe 'CheckedUtc' '');$attemptText=[string](Get-DomeniaMember $probe 'AttemptedUtc' '')
                $errorText=[string](Get-DomeniaMember $probe 'Error' '');$skipped=[string](Get-DomeniaMember $probe 'Skipped' '')
                $truncated=[bool](Get-DomeniaMember $probe 'Truncated' $false)
                $countComplete=(([string](Get-DomeniaMember $probe 'Mode' '') -ceq 'Count') -and ([bool](Get-DomeniaMember $probe 'CountComplete' $false)))
                $flag=Get-DomeniaMember $probe 'Succeeded' $null
                if(($null -ne $flag) -and (-not [bool]$flag) -and (-not $errorText)){$errorText='Lecture non confirmée.'}
            }
        }
    }
    if(-not $present){return (& $make 'Absent' 'Aucun relevé enregistré pour cette famille.' $null $null $false '')}
    if($null -ne $time){
        if(-not $successText){$successText=[string](Get-DomeniaMember $time 'ObservedUtc' '')}
        if(-not $attemptText){$attemptText=[string](Get-DomeniaMember $time 'LastAttemptUtc' '')}
    }
    $success=ConvertTo-DomeniaUtcDate $successText;$attempt=ConvertTo-DomeniaUtcDate $attemptText
    $latest=$NowUtc.ToUniversalTime().AddMinutes($ToleranceMinutes)
    $lastFailed=$false
    if($null -ne $time){$lastFailed=(-not [bool](Get-DomeniaMember $time 'Succeeded' $true))}
    elseif(($errorText) -and (($null -eq $success) -or (($null -ne $attempt) -and ($attempt -gt $success)))){$lastFailed=$true}
    if(-not $lastFailed){$errorText=''}
    $refused=(($lastFailed) -and (Test-DomeniaMeasureRefusal -Outcome $outcome -ErrorText $errorText))
    if((($null -ne $success) -and ($success -gt $latest)) -or (($null -ne $attempt) -and ($attempt -gt $latest))){return (& $make 'Error' 'Date future : horloge à vérifier, la mesure nʼest pas utilisée.' $success $attempt $lastFailed $errorText)}
    if(($successText) -and ($null -eq $success)){return (& $make 'Error' 'Date de mesure illisible.' $null $attempt $lastFailed $errorText)}
    if(($skipped) -and (($null -eq $success) -or (-not $errorText))){return (& $make 'NotRead' 'Mesure non applicable à ce poste.' $success $attempt $false '')}
    if(($Family -eq 'Presence') -and ($null -ne $success) -and (-not $lastFailed) -and ($value -notmatch '^(En ligne|Sans r[eé]ponse(?: au ping)?|Hors ligne)$')){return (& $make 'NotRead' 'Présence non vérifiée.' $success $attempt $false '')}
    if($null -eq $success){
        if($refused){return (& $make 'Refused' 'Lecture refusée ; aucune mesure réussie enregistrée.' $null $attempt $true $errorText)}
        if(($lastFailed) -or ($errorText)){return (& $make 'Error' 'Lecture non confirmée ; aucune mesure réussie enregistrée.' $null $attempt $true $errorText)}
        return (& $make 'NotRead' 'Tentative sans mesure datée.' $null $attempt $false '')
    }
    if(($instant) -and ($lastFailed)){
        $state=if($refused){'Refused'}else{'Error'}
        return (& $make $state 'Dernière tentative non confirmée : état actuel inconnu, dernière réussite conservée avec sa date.' $success $attempt $true $errorText)
    }
    if(($NowUtc.ToUniversalTime()-$success).TotalDays -gt [Math]::Max(1,$MaxDays)){return (& $make 'Expired' ('Mesure de plus de '+[Math]::Max(1,$MaxDays)+' jours.') $success $attempt $lastFailed $errorText)}
    if(($truncated) -and (-not $countComplete)){return (& $make 'Incomplete' 'Lecture partielle : valeur incomplète.' $success $attempt $lastFailed $errorText)}
    $reason=if($lastFailed){'Mesure valide datée ; la dernière tentative nʼa pas été confirmée.'}else{'Mesure valide datée.'}
    return (& $make 'Known' $reason $success $attempt $lastFailed $errorText)
}

function Measure-DomeniaMeasureStates {
    # Counts each target once per state for one family. A target without any record is Absent; Known never absorbs
    # an unknown state. Items are {Key; Observation}; the newest record of a duplicated key wins.
    param([object[]]$Items=@(),[int]$Total=0,[Parameter(Mandatory=$true)][string]$Family,[datetime]$NowUtc=[datetime]::UtcNow,[int]$MaxDays=30,[int]$ToleranceMinutes=-1)
    $byKey=@{}
    foreach($item in @($Items)){
        if($null -eq $item){continue}
        $key=([string](Get-DomeniaMember $item 'Key' '')).Trim().ToLowerInvariant();if(-not $key){continue}
        $state=Get-DomeniaMeasureState -Observation (Get-DomeniaMemberValue $item 'Observation') -Family $Family -NowUtc $NowUtc -MaxDays $MaxDays -ToleranceMinutes $ToleranceMinutes
        $previous=$byKey[$key]
        if(($null -eq $previous) -or (($state.State -eq 'Known') -and ($previous.State -ne 'Known')) -or (($state.State -eq $previous.State) -and ($null -ne $state.LastSuccessUtc) -and (($null -eq $previous.LastSuccessUtc) -or ($state.LastSuccessUtc -gt $previous.LastSuccessUtc)))){$byKey[$key]=$state}
    }
    $counts=[ordered]@{};foreach($stateKey in @(Get-DomeniaMeasureStateKeys)){$counts[$stateKey]=0}
    $failedAttempts=0;$keptAfterFailure=0;$oldest=$null;$newest=$null
    foreach($state in $byKey.Values){
        $counts[[string]$state.State]=[int]$counts[[string]$state.State]+1
        if($state.LastAttemptFailed){$failedAttempts++}
        if($state.State -eq 'Known'){
            if($state.LastAttemptFailed){$keptAfterFailure++}
            if(($null -eq $oldest) -or ($state.LastSuccessUtc -lt $oldest)){$oldest=$state.LastSuccessUtc}
            if(($null -eq $newest) -or ($state.LastSuccessUtc -gt $newest)){$newest=$state.LastSuccessUtc}
        }
    }
    $population=[Math]::Max([Math]::Max(0,$Total),$byKey.Count)
    $counts.Absent=[int]$counts.Absent+($population-$byKey.Count)
    return [pscustomobject]@{Family=$Family;Total=$population;Known=[int]$counts.Known;Counts=[pscustomobject]$counts;FailedAttempts=$failedAttempts;KnownWithFailedAttempt=$keptAfterFailure;OldestUtc=$oldest;NewestUtc=$newest}
}

function Format-DomeniaMeasureStates {
    # "1 jamais relevé, 2 en erreur": the unknown states only, in a fixed order; '' when every target is known.
    param($Counts)
    $counts=$Counts
    $parts=[Collections.Generic.List[string]]::new()
    foreach($pair in @(@('Absent','jamais relevé','jamais relevés'),@('NotRead','non lu','non lus'),@('Refused','refusé','refusés'),@('Expired','périmé','périmés'),@('Incomplete','incomplet','incomplets'),@('Error','en erreur','en erreur'))){
        $n=[int](Get-DomeniaMember $counts $pair[0] 0)
        if($n -gt 0){$parts.Add([string]$n+' '+$(if($n -gt 1){$pair[2]}else{$pair[1]}))}
    }
    return ($parts -join ', ')
}

# ---------------------------------------------------------------- point 2: compared populations
function New-DomeniaPopulationDescriptor {
    # What a figure, a widget, a result list or an export counts. Two counts are comparable only when the domain,
    # scope, depth, object types, criteria and committed snapshot are the same: the Key changes with any of them.
    param([AllowEmptyString()][string]$DomainDn,[AllowEmptyString()][string]$ScopeDn='',[bool]$Subtree=$true,[string[]]$Types=@(),[AllowEmptyString()][string]$Criteria='',[AllowEmptyString()][string]$StoreId='',[long]$SnapshotRevision=-1)
    $domain=([string]$DomainDn).Trim().ToLowerInvariant()
    if($domain -notmatch '(^|,)\s*dc='){throw 'Domaine de population invalide.'}
    $scope=([string]$ScopeDn).Trim()
    if(($scope) -and ($scope -ine $domain) -and (-not $scope.EndsWith(','+$domain,[StringComparison]::OrdinalIgnoreCase))){throw 'Périmètre de population hors du domaine.'}
    $typeList=@(@($Types)|ForEach-Object{([string]$_).Trim()}|Where-Object{$_}|Sort-Object -Unique)
    $typeNames=@{Machine='comptes ordinateur';Utilisateur='comptes utilisateur';Groupe='groupes';OU='OU';Conteneur='conteneurs'}
    foreach($type in $typeList){if(-not $typeNames.ContainsKey($type)){throw ('Type de population inconnu : '+$type)}}
    $criteriaText=ConvertTo-DomeniaCollectionText $Criteria 4096
    $criteriaHash=(Get-DomeniaTextHash $criteriaText).ToLowerInvariant()
    $depth=if($Subtree){'subtree'}else{'onelevel'}
    $canonical=@('population/1',$domain,$scope.ToLowerInvariant(),$depth,($typeList -join ','),$criteriaHash,([string]$StoreId).ToLowerInvariant(),[string]$SnapshotRevision) -join "`n"
    $what=if($typeList.Count){@($typeList|ForEach-Object{$typeNames[$_]}) -join ', '}else{'tous types dʼobjets'}
    $where=if($scope){$scope+$(if($Subtree){' et ses sous-OU'}else{' sans les sous-OU'})}else{'tout le domaine indexé'}
    $text=$what+' · '+$where
    if($criteriaText){$text+=' · '+$criteriaText}
    $text+=' · '+$(if($SnapshotRevision -ge 0){'base locale, révision '+[string]$SnapshotRevision}else{'révision de la base non connue'})
    return [pscustomobject]@{Version=1;DomainDn=$domain;ScopeDn=$scope;Subtree=[bool]$Subtree;Types=[string[]]$typeList;Criteria=$criteriaText;CriteriaHash=$criteriaHash;StoreId=[string]$StoreId;SnapshotRevision=$SnapshotRevision;Key=(Get-DomeniaTextHash $canonical).ToLowerInvariant();Text=$text}
}

function Compare-DomeniaPopulation {
    # Names every difference between two populations; Same only when none exists. A missing description is never
    # presumed identical.
    param($Reference,$Candidate)
    $differences=[Collections.Generic.List[string]]::new()
    if(($null -eq $Reference) -or ($null -eq $Candidate)){$differences.Add('population non décrite')}
    else{
        $field={param($Object,[string]$Name) return [string](Get-DomeniaMember $Object $Name '')}
        if((& $field $Reference 'DomainDn') -ine (& $field $Candidate 'DomainDn')){$differences.Add('domaine')}
        if((& $field $Reference 'ScopeDn') -ine (& $field $Candidate 'ScopeDn')){$differences.Add('périmètre')}
        if([bool](Get-DomeniaMember $Reference 'Subtree' $true) -ne [bool](Get-DomeniaMember $Candidate 'Subtree' $true)){$differences.Add('profondeur')}
        if((@(Get-DomeniaMember $Reference 'Types' @()) -join ',') -cne (@(Get-DomeniaMember $Candidate 'Types' @()) -join ',')){$differences.Add('types dʼobjets')}
        if((& $field $Reference 'CriteriaHash') -cne (& $field $Candidate 'CriteriaHash')){$differences.Add('critères')}
        if(((& $field $Reference 'StoreId') -cne (& $field $Candidate 'StoreId')) -or ([long](Get-DomeniaMember $Reference 'SnapshotRevision' -1) -ne [long](Get-DomeniaMember $Candidate 'SnapshotRevision' -1))){$differences.Add('instantané de la base')}
    }
    $text=if($differences.Count){'Populations différentes : '+($differences -join ', ')+'.'}else{'Même population.'}
    return [pscustomobject]@{Same=($differences.Count -eq 0);Differences=$differences.ToArray();Text=$text}
}

# ================================================================ collection for slow networks
# ---------------------------------------------------------------- point 11: freshness per data family and usage profile
function Get-DomeniaFreshnessFamilies {
    # Families whose reuse delay the operator may set. Minimum and Maximum bound one setting, in seconds. Only the
    # families that a reader really applies are listed: no reader applies a reuse delay to the AD identity, so it is
    # not offered as a setting that would change nothing.
    return @(
        [pscustomobject]@{Id='Presence';Label='Présence réseau (ping)';Minimum=0;Maximum=604800;Effect='Le dernier ping reste affiché comme récent pendant cette durée ; au-delà il est marqué à relire.'}
        [pscustomobject]@{Id='Console';Label='Utilisateur console';Minimum=0;Maximum=604800;Effect='Lʼutilisateur console relevé reste récent pendant cette durée. Un relevé relit toujours la console.'}
        [pscustomobject]@{Id='Attributes';Label='Attributs AD';Minimum=0;Maximum=604800;Effect='Les attributs AD affichés restent récents pendant cette durée ; au-delà la fiche indique « à relire ».'}
        [pscustomobject]@{Id='Inventory';Label='Inventaire léger WMI';Minimum=0;Maximum=604800;Effect='Un relevé réutilise lʼinventaire léger plus récent que cette durée au lieu de le relire.'}
        [pscustomobject]@{Id='StaticProbe';Label='Sondes WMI stables';Minimum=0;Maximum=604800;Effect='Un relevé réutilise le résultat des sondes stables (matériel, BIOS, système) plus récent que cette durée.'}
        [pscustomobject]@{Id='VolatileProbe';Label='Sondes WMI variables';Minimum=0;Maximum=604800;Effect='Un relevé réutilise le résultat des sondes variables (services, réseau, charge, journaux) plus récent que cette durée.'}
    )
}

function Get-DomeniaCollectionProfiles {
    # Usage profiles. Seconds per freshness family; Windows is the default collection window of the profile (point 159).
    return @(
        [pscustomobject]@{Id='Standard';Label='Standard';Description='Réseau local ou rapide : durées habituelles de Domenia, travaux de fond permis à tout moment.';Windows='';Seconds=@{Presence=120;Console=300;Attributes=900;Inventory=300;StaticProbe=900;VolatileProbe=60}}
        [pscustomobject]@{Id='SlowNetwork';Label='Réseau lent ou site distant';Description='Mesures réutilisées plus longtemps ; travaux de fond limités aux heures creuses.';Windows='lun-ven 00:00-08:00 12:00-14:00 18:00-24:00; sam-dim';Seconds=@{Presence=600;Console=900;Attributes=3600;Inventory=3600;StaticProbe=14400;VolatileProbe=300}}
        [pscustomobject]@{Id='Troubleshooting';Label='Dépannage en direct';Description='Mesures relues rapidement pendant une intervention ; travaux de fond permis à tout moment.';Windows='';Seconds=@{Presence=30;Console=60;Attributes=300;Inventory=120;StaticProbe=300;VolatileProbe=30}}
    )
}

function Get-DomeniaCollectionProfile {
    # Unknown or empty identifiers fall back to Standard: a damaged setting never removes every duration.
    param([AllowEmptyString()][string]$Id='Standard')
    $profiles = @(Get-DomeniaCollectionProfiles)
    foreach ($profile in $profiles) { if ([string]$profile.Id -ieq ([string]$Id).Trim()) { return $profile } }
    return $profiles[0]
}

function Get-DomeniaFreshnessDurationChoices {
    # Durations offered by the editor, limited to the bounds of the family.
    param([Parameter(Mandatory=$true)][string]$Family)
    $definition = @(Get-DomeniaFreshnessFamilies | Where-Object { [string]$_.Id -ieq $Family })
    if (-not $definition.Count) { return @() }
    $choices = @(0,30,60,120,300,600,900,1800,3600,7200,14400,43200,86400,604800)
    return @($choices | Where-Object { ($_ -ge [int]$definition[0].Minimum) -and ($_ -le [int]$definition[0].Maximum) })
}

function Format-DomeniaCollectionDuration {
    # Short French duration: '30 s', '5 min', '1 h 30 min', '1 j'. Zero means the value is always read again.
    param([long]$Seconds)
    if ($Seconds -le 0) { return '0 s (toujours relire)' }
    if ($Seconds -lt 60) { return ([string]$Seconds + ' s') }
    if ($Seconds -lt 3600) {
        $minutes = [long][Math]::Floor($Seconds / 60); $rest = $Seconds % 60
        if ($rest) { return ([string]$minutes + ' min ' + [string]$rest + ' s') }
        return ([string]$minutes + ' min')
    }
    if ($Seconds -lt 86400) {
        $hours = [long][Math]::Floor($Seconds / 3600); $minutes = [long][Math]::Floor(($Seconds % 3600) / 60)
        if ($minutes) { return ([string]$hours + ' h ' + [string]$minutes + ' min') }
        return ([string]$hours + ' h')
    }
    $days = [long][Math]::Floor($Seconds / 86400); $hours = [long][Math]::Floor(($Seconds % 86400) / 3600)
    if ($hours) { return ([string]$days + ' j ' + [string]$hours + ' h') }
    return ([string]$days + ' j')
}

function ConvertFrom-DomeniaFreshnessOverrides {
    # Settings text (JSON object family -> seconds) to a validated table. An unknown family, a non-integer or a value
    # outside the bounds of its family is dropped and reported; nothing is guessed.
    param([AllowEmptyString()][string]$Text)
    $values = @{}
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $clean = ([string]$Text).Trim()
    if (-not $clean) { return [pscustomobject]@{Values=$values;Errors=@()} }
    $parsed = $null
    try { $parsed = ConvertFrom-Json -InputObject $clean -ErrorAction Stop } catch { $parsed = $null }
    if ($parsed -isnot [Management.Automation.PSCustomObject]) {
        $errors.Add('Durées personnalisées illisibles : les durées du profil sʼappliquent.')
        return [pscustomobject]@{Values=$values;Errors=$errors.ToArray()}
    }
    $families = @{}
    foreach ($family in @(Get-DomeniaFreshnessFamilies)) { $families[[string]$family.Id] = $family }
    foreach ($property in @($parsed.PSObject.Properties)) {
        if (-not $families.ContainsKey([string]$property.Name)) { $errors.Add('Famille inconnue ignorée : ' + [string]$property.Name); continue }
        $family = $families[[string]$property.Name]
        $number = 0L
        if (-not [long]::TryParse([string]$property.Value,[Globalization.NumberStyles]::Integer,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)) {
            $errors.Add('Durée non entière ignorée : ' + [string]$family.Label); continue
        }
        if (($number -lt [long]$family.Minimum) -or ($number -gt [long]$family.Maximum)) {
            $errors.Add('Durée hors limites ignorée : ' + [string]$family.Label); continue
        }
        $values[[string]$family.Id] = [int]$number
    }
    return [pscustomobject]@{Values=$values;Errors=$errors.ToArray()}
}

function ConvertTo-DomeniaFreshnessOverridesText {
    # Stable text (families in catalog order) for the settings file. Unknown families are not written.
    param($Values)
    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($family in @(Get-DomeniaFreshnessFamilies)) {
        $id = [string]$family.Id
        $present = $false
        if ($Values -is [Collections.IDictionary]) { $present = $Values.Contains($id) }
        if (-not $present) { continue }
        $parts.Add('"' + $id + '":' + [string][int]$Values[$id])
    }
    if (-not $parts.Count) { return '' }
    return ('{' + ($parts.ToArray() -join ',') + '}')
}

function Resolve-DomeniaFreshnessTable {
    # Effective durations: the profile, then the validated overrides. Rows describe each family for the settings view.
    param([AllowEmptyString()][string]$Profile='Standard',$Overrides=$null)
    $definition = Get-DomeniaCollectionProfile $Profile
    $custom = @{}
    if ($Overrides -is [Collections.IDictionary]) { $custom = $Overrides }
    $seconds = @{}
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($family in @(Get-DomeniaFreshnessFamilies)) {
        $id = [string]$family.Id
        $base = [int]$definition.Seconds[$id]
        $value = $base; $source = 'Profil'
        if ($custom.Contains($id)) { $value = [int]$custom[$id]; $source = 'Personnalisé' }
        $seconds[$id] = $value
        $rows.Add([pscustomobject]@{Family=$id;Label=[string]$family.Label;Seconds=$value;Duration=(Format-DomeniaCollectionDuration $value);ProfileSeconds=$base;Source=$source;Effect=[string]$family.Effect})
    }
    return [pscustomobject]@{Profile=[string]$definition.Id;Label=[string]$definition.Label;Seconds=$seconds;Rows=$rows.ToArray()}
}

# ---------------------------------------------------------------- point 159: collection windows
function Get-DomeniaCollectionWindowSources {
    # Background sources that read the network on their own. Live (a selection), Dashboard (local rebuild), Storage and
    # Receipts are never held by a window: they are either an operator gesture or local work.
    return @('Reconcile','ObjectChanges','Park','Index')
}

function ConvertFrom-DomeniaCollectionWindowText {
    # 'lun-ven 07:30-12:00 13:30-18:00; sam 08:00-12:00'. Empty or 'toujours' = always open, 'jamais' = never open.
    # Days: lun mar mer jeu ven sam dim (full names accepted), lists 'lun,mer', ranges 'lun-ven' or 'ven-lun', 'tous'.
    # A day without range is open all day. A range whose end precedes its start continues the next day.
    param([AllowEmptyString()][string]$Text)
    $clean = ([string]$Text).Trim()
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $rules = New-Object 'System.Collections.Generic.List[object]'
    if ((-not $clean) -or ($clean -ieq 'toujours')) { return [pscustomobject]@{Valid=$true;Mode='Always';Rules=@();Errors=@();Text=''} }
    if ($clean -ieq 'jamais') { return [pscustomobject]@{Valid=$true;Mode='Never';Rules=@();Errors=@();Text='jamais'} }
    $dayMap = @{lun=1;lundi=1;mar=2;mardi=2;mer=3;mercredi=3;jeu=4;jeudi=4;ven=5;vendredi=5;sam=6;samedi=6;dim=0;dimanche=0}
    foreach ($clause in @($clean.Split(';'))) {
        $part = ([string]$clause).Trim()
        if (-not $part) { continue }
        $tokens = @($part.Split([char[]]@(' ',"`t"),[StringSplitOptions]::RemoveEmptyEntries))
        $days = New-Object 'System.Collections.Generic.List[int]'
        $dayText = ([string]$tokens[0]).ToLowerInvariant()
        $dayValid = $true
        if ($dayText -in @('tous','tlj')) { foreach ($d in 0..6) { $days.Add($d) } }
        else {
            foreach ($item in @($dayText.Split(','))) {
                if (-not $item) { $dayValid = $false; continue }
                $bounds = @($item.Split('-'))
                if ($bounds.Count -eq 1) {
                    if ($dayMap.ContainsKey($bounds[0])) { if (-not $days.Contains([int]$dayMap[$bounds[0]])) { $days.Add([int]$dayMap[$bounds[0]]) } } else { $dayValid = $false }
                }
                elseif (($bounds.Count -eq 2) -and $dayMap.ContainsKey($bounds[0]) -and $dayMap.ContainsKey($bounds[1])) {
                    # Monday-based walk so that 'ven-lun' covers vendredi, samedi, dimanche, lundi.
                    $start = ([int]$dayMap[$bounds[0]] + 6) % 7; $end = ([int]$dayMap[$bounds[1]] + 6) % 7
                    $index = $start
                    for ($guard = 0; $guard -lt 7; $guard++) {
                        $day = ($index + 1) % 7
                        if (-not $days.Contains($day)) { $days.Add($day) }
                        if ($index -eq $end) { break }
                        $index = ($index + 1) % 7
                    }
                }
                else { $dayValid = $false }
            }
        }
        if ((-not $dayValid) -or (-not $days.Count)) { $errors.Add('Jours non reconnus : « ' + [string]$tokens[0] + ' » (exemple : lun-ven).'); continue }
        $ranges = @($tokens | Select-Object -Skip 1)
        if (-not $ranges.Count) { $rules.Add([pscustomobject]@{Days=$days.ToArray();StartMinute=0;EndMinute=1440;Overnight=$false}); continue }
        foreach ($range in $ranges) {
            if ([string]$range -notmatch '^(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})$') { $errors.Add('Plage horaire non reconnue : « ' + [string]$range + ' » (exemple : 07:30-12:00).'); continue }
            $sh = [int]$Matches[1]; $sm = [int]$Matches[2]; $eh = [int]$Matches[3]; $em = [int]$Matches[4]
            if (($sh -gt 23) -or ($sm -gt 59) -or ($em -gt 59) -or ($eh -gt 24) -or (($eh -eq 24) -and ($em -ne 0))) { $errors.Add('Heure invalide : « ' + [string]$range + ' ».'); continue }
            $startMinute = $sh * 60 + $sm; $endMinute = $eh * 60 + $em
            if ($startMinute -eq $endMinute) { $errors.Add('Plage vide : « ' + [string]$range + ' ».'); continue }
            $rules.Add([pscustomobject]@{Days=$days.ToArray();StartMinute=$startMinute;EndMinute=$endMinute;Overnight=($endMinute -lt $startMinute)})
        }
    }
    if ($errors.Count) { return [pscustomobject]@{Valid=$false;Mode='Invalid';Rules=@();Errors=$errors.ToArray();Text=$clean} }
    if (-not $rules.Count) { return [pscustomobject]@{Valid=$false;Mode='Invalid';Rules=@();Errors=@('Aucune plage reconnue.');Text=$clean} }
    return [pscustomobject]@{Valid=$true;Mode='Rules';Rules=$rules.ToArray();Errors=@();Text=$clean}
}

function Test-DomeniaCollectionWindowRule {
    # $true when the rule covers the local instant $At.
    param($Rule,[datetime]$At)
    $minute = $At.Hour * 60 + $At.Minute
    $day = [int]$At.DayOfWeek
    $days = @($Rule.Days)
    if (-not [bool]$Rule.Overnight) { return (($days -contains $day) -and ($minute -ge [int]$Rule.StartMinute) -and ($minute -lt [int]$Rule.EndMinute)) }
    $previous = ($day + 6) % 7
    return ((($days -contains $day) -and ($minute -ge [int]$Rule.StartMinute)) -or (($days -contains $previous) -and ($minute -lt [int]$Rule.EndMinute)))
}

function Test-DomeniaCollectionWindowOpen {
    # State of a parsed window at the local instant $Now, with the next change (opening or closing) within eight days.
    # -StateOnly skips the next change: the background gate of the engine asks from its ticks and needs the state only.
    param($Window,[datetime]$Now=(Get-Date),[switch]$StateOnly)
    $mode = [string](Get-DomeniaMember $Window 'Mode' 'Always')
    if ($mode -eq 'Always') { return [pscustomobject]@{Open=$true;Mode=$mode;NextChange=$null} }
    if ($mode -ne 'Rules') { return [pscustomobject]@{Open=$false;Mode=$mode;NextChange=$null} }
    $rules = @(Get-DomeniaMember $Window 'Rules' @())
    $at = $Now.Date.AddHours($Now.Hour).AddMinutes($Now.Minute)
    $isOpen = $false
    foreach ($rule in $rules) { if (Test-DomeniaCollectionWindowRule $rule $at) { $isOpen = $true; break } }
    if ($StateOnly) { return [pscustomobject]@{Open=$isOpen;Mode=$mode;NextChange=$null} }
    # Boundaries are rule starts and ends: the state can only change there.
    $boundaries = New-Object 'System.Collections.Generic.List[datetime]'
    for ($offset = -1; $offset -le 8; $offset++) {
        $day = $Now.Date.AddDays($offset)
        foreach ($rule in $rules) {
            if (@($rule.Days) -notcontains [int]$day.DayOfWeek) { continue }
            $boundaries.Add($day.AddMinutes([int]$rule.StartMinute))
            $endDay = $day
            if ([bool]$rule.Overnight) { $endDay = $day.AddDays(1) }
            $boundaries.Add($endDay.AddMinutes([int]$rule.EndMinute))
        }
    }
    $next = $null
    foreach ($moment in @($boundaries.ToArray() | Where-Object { $_ -gt $at } | Sort-Object -Unique)) {
        $state = $false
        foreach ($rule in $rules) { if (Test-DomeniaCollectionWindowRule $rule $moment) { $state = $true; break } }
        if ($state -ne $isOpen) { $next = $moment; break }
    }
    return [pscustomobject]@{Open=$isOpen;Mode=$mode;NextChange=$next}
}

function Format-DomeniaCollectionWindowState {
    # One sentence for the settings view and the campaign confirmation.
    param($State,[datetime]$Now=(Get-Date))
    $mode = [string](Get-DomeniaMember $State 'Mode' 'Always')
    if ($mode -eq 'Always') { return 'Travaux de fond permis à tout moment (aucune fenêtre de collecte).' }
    if ($mode -eq 'Never') { return 'Travaux de fond suspendus : aucune fenêtre de collecte. Les actions explicites restent possibles.' }
    if ($mode -ne 'Rules') { return 'Fenêtre de collecte invalide : travaux de fond suspendus jusquʼà correction.' }
    $next = Get-DomeniaMember $State 'NextChange' $null
    $day = ''; $time = ''
    if ($null -ne $next) {
        $names = @('dimanche','lundi','mardi','mercredi','jeudi','vendredi','samedi')
        $moment = [datetime]$next
        $time = $moment.ToString('HH:mm')
        if ($moment.Date -eq $Now.Date.AddDays(1)) { $day = 'demain' }
        elseif ($moment.Date -ne $Now.Date) { $day = $names[[int]$moment.DayOfWeek] }
    }
    if ([bool](Get-DomeniaMember $State 'Open' $false)) {
        if (-not $time) { return 'Fenêtre de collecte ouverte.' }
        if ($day) { return ('Fenêtre de collecte ouverte jusquʼà ' + $day + ' ' + $time + '.') }
        return ('Fenêtre de collecte ouverte jusquʼà ' + $time + '.')
    }
    if (-not $time) { return 'Fenêtre de collecte fermée : travaux de fond en pause.' }
    if ($day) { return ('Fenêtre de collecte fermée : travaux de fond en pause, reprise ' + $day + ' à ' + $time + '.') }
    return ('Fenêtre de collecte fermée : travaux de fond en pause, reprise à ' + $time + '.')
}

function Test-DomeniaCollectionWindowAllows {
    # $true when the window lets this background source read the network now. Sources outside the list are not held.
    param($Window,[AllowEmptyString()][string]$Source,[datetime]$Now=(Get-Date))
    if (@(Get-DomeniaCollectionWindowSources) -notcontains [string]$Source) { return $true }
    if ($null -eq $Window) { return $true }
    if (-not [bool](Get-DomeniaMember $Window 'Valid' $true)) { return $false }
    return [bool](Test-DomeniaCollectionWindowOpen -Window $Window -Now $Now -StateOnly).Open
}

# ---------------------------------------------------------------- points 14, 15, 160: health of a collection source
function New-DomeniaSourcePolicy {
    # One budget: MaxLimit is the bound chosen by the operator, never exceeded. FailureThreshold 0 never suspends.
    param([int]$MaxLimit=4,[int]$MinLimit=1,[int]$FailureThreshold=3,[int]$OpenSeconds=60,[int]$MaxOpenSeconds=900,
        [double]$SlowFactor=2.0,[int]$SlowFloorMs=1500,[int]$DecreaseCooldownSeconds=10)
    $max = [Math]::Max(1,$MaxLimit)
    return [pscustomobject]@{MaxLimit=$max;MinLimit=[Math]::Max(1,[Math]::Min($MinLimit,$max));FailureThreshold=[Math]::Max(0,$FailureThreshold)
        OpenSeconds=[Math]::Max(1,$OpenSeconds);MaxOpenSeconds=[Math]::Max([Math]::Max(1,$OpenSeconds),$MaxOpenSeconds)
        SlowFactor=[Math]::Max(1.1,$SlowFactor);SlowFloorMs=[Math]::Max(0,$SlowFloorMs);DecreaseCooldownSeconds=[Math]::Max(0,$DecreaseCooldownSeconds)}
}

function New-DomeniaSourceHealth { return @{} }

function Get-DomeniaSourceEntry {
    # Creates the entry of a source on first use. A new source starts at the bound chosen by the operator.
    param($Health,[Parameter(Mandatory=$true)][string]$Key,$Policy)
    if ($null -eq $Health) { return $null }
    if ($null -eq $Policy) { $Policy = New-DomeniaSourcePolicy }
    if (-not $Health.ContainsKey($Key)) {
        $Health[$Key] = [pscustomobject]@{Key=$Key;State='Closed';Limit=[int]$Policy.MaxLimit;Successes=0;ConsecutiveFailures=0;Opens=0
            OpenUntilUtc=[datetime]::MinValue;BaselineMs=[double]0;Samples=0;LastLatencyMs=[double]-1;LastDecreaseUtc=[datetime]::MinValue
            LastOutcome='';LastUtc=[datetime]::MinValue;Suspensions=0;Decreases=0}
    }
    return $Health[$Key]
}

function Get-DomeniaSourceOpenSeconds {
    # Delay of the n-th consecutive suspension: doubling and bounded.
    param($Policy,[int]$Opens)
    $power = [Math]::Max(0,[Math]::Min(10,$Opens - 1))
    return [int][Math]::Min([double]$Policy.MaxOpenSeconds,[double]$Policy.OpenSeconds * [Math]::Pow(2,$power))
}

function Register-DomeniaSourceOutcome {
    # Additive increase, multiplicative decrease (point 14) and suspension with progressive recovery (point 160).
    # Success: an answer proved the path works. Timeout and Failure count against the source. Neutral (machine off,
    # refused right, rejected account) and Cancelled say nothing about the source and change nothing.
    param($Health,[Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][ValidateSet('Success','Timeout','Failure','Neutral','Cancelled')][string]$Outcome,
        [double]$LatencyMs=-1,$Policy=$null,[datetime]$NowUtc=[datetime]::UtcNow)
    if ($null -eq $Policy) { $Policy = New-DomeniaSourcePolicy }
    $entry = Get-DomeniaSourceEntry -Health $Health -Key $Key -Policy $Policy
    if ($null -eq $entry) { return $null }
    if ($Outcome -in @('Neutral','Cancelled')) { return $entry }
    $entry.LastOutcome = $Outcome; $entry.LastUtc = $NowUtc
    # A source whose suspension has expired is half open: the first answer decides.
    $halfOpen = (([string]$entry.State -eq 'HalfOpen') -or (([string]$entry.State -eq 'Open') -and ($NowUtc -ge [datetime]$entry.OpenUntilUtc)))
    $decrease = {
        if (($NowUtc - [datetime]$entry.LastDecreaseUtc).TotalSeconds -ge [double]$Policy.DecreaseCooldownSeconds) {
            $next = [int][Math]::Max([double]$Policy.MinLimit,[Math]::Floor([double]$entry.Limit / 2))
            if ($next -lt [int]$entry.Limit) { $entry.Decreases = [int]$entry.Decreases + 1 }
            $entry.Limit = $next; $entry.LastDecreaseUtc = $NowUtc; $entry.Successes = 0
        }
    }
    if ($Outcome -eq 'Success') {
        $entry.ConsecutiveFailures = 0
        $recovered = $false
        if ($halfOpen -or ([string]$entry.State -eq 'Open')) {
            # Progressive recovery: the trial answer reopens the source at one read at a time; the following answers
            # widen it by the additive increase.
            $entry.State = 'Closed'; $entry.Limit = [int]$Policy.MinLimit; $entry.Successes = 0; $entry.LastDecreaseUtc = $NowUtc
            $recovered = $true
        }
        $slow = $false
        if ($LatencyMs -ge 0) {
            $entry.LastLatencyMs = $LatencyMs
            $threshold = [Math]::Max([double]$Policy.SlowFloorMs,[double]$Policy.SlowFactor * [double]$entry.BaselineMs)
            $slow = (([int]$entry.Samples -ge 3) -and ($LatencyMs -gt $threshold))
            if ($slow) {
                # A slow answer still moves the reference a little: a site that became slower for good is accepted.
                $entry.BaselineMs = [double]$entry.BaselineMs + 0.05 * ($LatencyMs - [double]$entry.BaselineMs)
            }
            elseif ([int]$entry.Samples -eq 0) { $entry.BaselineMs = $LatencyMs; $entry.Samples = 1 }
            else { $entry.BaselineMs = 0.8 * [double]$entry.BaselineMs + 0.2 * $LatencyMs; $entry.Samples = [int]$entry.Samples + 1 }
        }
        if ($slow) { & $decrease }
        elseif (-not $recovered) {
            $entry.Successes = [int]$entry.Successes + 1
            if (([int]$entry.Successes -ge [int]$entry.Limit) -and ([int]$entry.Limit -lt [int]$Policy.MaxLimit)) { $entry.Limit = [int]$entry.Limit + 1; $entry.Successes = 0 }
            if ([int]$entry.Limit -ge [int]$Policy.MaxLimit) { $entry.Opens = 0 }
        }
        return $entry
    }
    # Timeout or failure.
    $entry.ConsecutiveFailures = [int]$entry.ConsecutiveFailures + 1
    $entry.Successes = 0
    & $decrease
    $suspend = $halfOpen
    if ((-not $suspend) -and ([int]$Policy.FailureThreshold -gt 0) -and ([int]$entry.ConsecutiveFailures -ge [int]$Policy.FailureThreshold) -and ([string]$entry.State -eq 'Closed')) { $suspend = $true }
    if ($suspend -and ([int]$Policy.FailureThreshold -gt 0)) {
        $entry.Opens = [int]$entry.Opens + 1
        $entry.Suspensions = [int]$entry.Suspensions + 1
        $entry.State = 'Open'
        $entry.Limit = [int]$Policy.MinLimit
        $entry.OpenUntilUtc = $NowUtc.AddSeconds((Get-DomeniaSourceOpenSeconds -Policy $Policy -Opens ([int]$entry.Opens)))
    }
    return $entry
}

function Test-DomeniaSourceAdmission {
    # May one more read start on this source now? $Running counts the reads of the source still in flight.
    param($Health,[Parameter(Mandatory=$true)][string]$Key,[int]$Running=0,$Policy=$null,[datetime]$NowUtc=[datetime]::UtcNow)
    if ($null -eq $Policy) { $Policy = New-DomeniaSourcePolicy }
    $entry = $null
    if (($null -ne $Health) -and $Health.ContainsKey($Key)) { $entry = $Health[$Key] }
    if ($null -eq $entry) {
        if ($Running -lt [int]$Policy.MaxLimit) { return [pscustomobject]@{Allowed=$true;State='Closed';Limit=[int]$Policy.MaxLimit;Reason='';RetryAfterUtc=$null} }
        return [pscustomobject]@{Allowed=$false;State='Closed';Limit=[int]$Policy.MaxLimit;Reason=('Limite atteinte : ' + [string]$Policy.MaxLimit + ' lecture(s) simultanée(s) pour cette source.');RetryAfterUtc=$null}
    }
    $state = [string]$entry.State
    if ($state -eq 'Open') {
        if ($NowUtc -lt [datetime]$entry.OpenUntilUtc) {
            return [pscustomobject]@{Allowed=$false;State='Open';Limit=0;Reason=('Source suspendue après ' + [string]$entry.ConsecutiveFailures + ' échec(s) consécutif(s) : nouvel essai après ' + ([datetime]$entry.OpenUntilUtc).ToLocalTime().ToString('HH:mm:ss') + '.');RetryAfterUtc=[datetime]$entry.OpenUntilUtc}
        }
        $state = 'HalfOpen'
    }
    if ($state -eq 'HalfOpen') {
        if ($Running -lt 1) { return [pscustomobject]@{Allowed=$true;State='HalfOpen';Limit=1;Reason='Reprise progressive : une seule lecture dʼessai.';RetryAfterUtc=$null} }
        return [pscustomobject]@{Allowed=$false;State='HalfOpen';Limit=1;Reason='Reprise progressive : une lecture dʼessai est déjà en cours.';RetryAfterUtc=$null}
    }
    $limit = [int][Math]::Max(1,[Math]::Min([int]$entry.Limit,[int]$Policy.MaxLimit))
    if ($Running -lt $limit) { return [pscustomobject]@{Allowed=$true;State='Closed';Limit=$limit;Reason='';RetryAfterUtc=$null} }
    return [pscustomobject]@{Allowed=$false;State='Closed';Limit=$limit;Reason=('Limite adaptée atteinte : ' + [string]$limit + ' lecture(s) simultanée(s) pour cette source.');RetryAfterUtc=$null}
}

function Get-DomeniaReadStepLatencyMs {
    # Point 14: latency of one workstation read for its source budget, as the mean duration of one finished step
    # (ping or CIM query) measured on the dispatch clock of its progress channel. The wait in the engine queue is
    # excluded, and a plan whose measurements were reused (two steps) compares with a full read (inventory and
    # probes). -1 when the channel holds no valid measurement: the answer then carries no latency.
    param([long]$StartedTimestamp=0,[long]$LastTimestamp=0,[long]$Steps=0,[long]$Frequency=[Diagnostics.Stopwatch]::Frequency)
    if (($StartedTimestamp -le 0) -or ($LastTimestamp -lt $StartedTimestamp) -or ($Steps -le 0) -or ($Frequency -le 0)) { return [double]-1 }
    return ([double]($LastTimestamp - $StartedTimestamp) * 1000.0 / [double]$Frequency / [double]$Steps)
}

function ConvertTo-DomeniaIPv4Text {
    # Dotted IPv4 text or ''. Loopback, unspecified and multicast addresses are not a site.
    param([AllowEmptyString()][string]$Text)
    $value = ([string]$Text).Trim()
    if ($value -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return '' }
    $octets = @([int]$Matches[1],[int]$Matches[2],[int]$Matches[3],[int]$Matches[4])
    foreach ($octet in $octets) { if ($octet -gt 255) { return '' } }
    if (($octets[0] -eq 0) -or ($octets[0] -eq 127) -or ($octets[0] -ge 224)) { return '' }
    return ($octets -join '.')
}

function Get-DomeniaAddressFromText {
    # Last IPv4 address quoted in a worker text such as 'Réponse ICMP · 12 ms · 10.1.2.3'.
    param([AllowEmptyString()][string]$Text)
    $found = ''
    foreach ($match in [regex]::Matches([string]$Text,'(?<![\d.])(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(?![\d.])')) {
        $candidate = ConvertTo-DomeniaIPv4Text $match.Groups[1].Value
        if ($candidate) { $found = $candidate }
    }
    return $found
}

function Get-DomeniaSubnetKey {
    # Presumed subnet of an address ('10.1.2.0/24'); '' when the address is unknown. The prefix is an assumption made
    # without reading the real mask: the label says « présumé ».
    param([AllowEmptyString()][string]$Address,[ValidateRange(8,30)][int]$PrefixLength=24)
    $ip = ConvertTo-DomeniaIPv4Text $Address
    if (-not $ip) { return '' }
    $parts = @($ip.Split('.') | ForEach-Object { [long]$_ })
    $value = ($parts[0] -shl 24) -bor ($parts[1] -shl 16) -bor ($parts[2] -shl 8) -bor $parts[3]
    $full = [long]4294967295
    $mask = ($full -shl (32 - $PrefixLength)) -band $full
    $network = $value -band $mask
    return ((@((($network -shr 24) -band 255),(($network -shr 16) -band 255),(($network -shr 8) -band 255),($network -band 255)) -join '.') + '/' + [string]$PrefixLength)
}

function Get-DomeniaCollectionSourceKey {
    # Budget of one read: the controller for the directory, the presumed subnet for a workstation, else the provider.
    param([Parameter(Mandatory=$true)][string]$Provider,[AllowEmptyString()][string]$Server='',[AllowEmptyString()][string]$Address='')
    if ($Provider -eq 'Directory') {
        $dc = ([string]$Server).Trim().ToLowerInvariant()
        if ($dc) { return ('dc:' + $dc) }
        return 'dc:?'
    }
    if ($Provider -in @('Cim','Wts','Network')) {
        $subnet = Get-DomeniaSubnetKey $Address
        if ($subnet) { return ('site:' + $subnet) }
        return 'site:?'
    }
    return ('provider:' + ([string]$Provider).ToLowerInvariant())
}

function Get-DomeniaCollectionSourceLabel {
    param([AllowEmptyString()][string]$Key)
    if ($Key -eq 'site:?') { return 'postes sans adresse connue' }
    if ($Key -like 'site:*') { return ('sous-réseau présumé ' + $Key.Substring(5)) }
    if ($Key -eq 'dc:?') { return 'contrôleur non désigné' }
    if ($Key -like 'dc:*') { return ('contrôleur ' + $Key.Substring(3)) }
    return $Key
}

function New-DomeniaCampaignSources {
    # Per-source budgets of one campaign: every site or controller adapts on its own, bounded by the chosen value.
    # Workstations without known address share one budget that never suspends (it is not a site). The latency is
    # per finished step (Get-DomeniaReadStepLatencyMs), so the floor of a slow answer is per step too.
    param([int]$MaxLimit=4)
    $max = [Math]::Max(1,[Math]::Min(32,$MaxLimit))
    return [pscustomobject]@{Health=(New-DomeniaSourceHealth);Policy=(New-DomeniaSourcePolicy -MaxLimit $max -SlowFloorMs 500);UnknownPolicy=(New-DomeniaSourcePolicy -MaxLimit $max -FailureThreshold 0 -SlowFloorMs 500);MaxLimit=$max}
}

function Get-DomeniaCampaignSourcePolicy {
    param($Sources,[AllowEmptyString()][string]$Key)
    if ($null -eq $Sources) { return (New-DomeniaSourcePolicy) }
    if ($Key -in @('site:?','dc:?')) { return $Sources.UnknownPolicy }
    return $Sources.Policy
}

function Get-DomeniaCampaignSourceSummary {
    # Sources that are reduced or suspended, for the status line. Healthy sources are not listed.
    param($Sources,[datetime]$NowUtc=[datetime]::UtcNow)
    $parts = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $Sources) { return '' }
    foreach ($key in @($Sources.Health.Keys | Sort-Object)) {
        $entry = $Sources.Health[$key]
        $label = Get-DomeniaCollectionSourceLabel ([string]$key)
        if (([string]$entry.State -eq 'Open') -and ($NowUtc -lt [datetime]$entry.OpenUntilUtc)) { $parts.Add($label + ' suspendu jusquʼà ' + ([datetime]$entry.OpenUntilUtc).ToLocalTime().ToString('HH:mm:ss')) }
        elseif (([string]$entry.State -eq 'Open') -or ([string]$entry.State -eq 'HalfOpen')) { $parts.Add($label + ' en reprise (une lecture dʼessai)') }
        elseif ([int]$entry.Limit -lt [int]$Sources.MaxLimit) { $parts.Add($label + ' ralenti à ' + [string]$entry.Limit + '/' + [string]$Sources.MaxLimit) }
    }
    return ($parts.ToArray() -join ' ; ')
}

# ---------------------------------------------------------------- point 18: classify before any retry
function ConvertTo-DomeniaCollectionFailure {
    # Class of one workstation measurement. Health feeds the source budget; Category decides a retry.
    # Point 18: only a workstation proven reachable is read again. Transient: the machine answered the ping and the
    # read did not finish, or the worker itself reported the time-out of a CIM query. Offline: no answer to the ping.
    # Unreachable: the read failed and nothing proves the machine is on (WMI only, or the engine stopped the read
    # before its ping ended); a machine switched off looks the same, so it waits for the next campaign and says
    # nothing about its site. A refusal is never transient. For -JobFailed, $Presence is the ping step the worker
    # reported before it was stopped ('' when unknown).
    param([AllowEmptyString()][string]$Outcome='',[AllowEmptyString()][string]$Presence='',[bool]$PingCollected=$true,[bool]$JobFailed=$false,[AllowEmptyString()][string]$ErrorText='')
    $online = ([string]$Presence -eq 'En ligne')
    $silent = ([string]$Presence -in @('Sans réponse au ping','Erreur de ping'))
    if ($JobFailed) {
        if ([string]$ErrorText -match '(?i)timeout|timed out|d[eé]lai|aucune requ[eê]te') {
            if ($PingCollected -and $online) { return [pscustomobject]@{Category='Transient';Health='Timeout';Reason='Délai dépassé sur un poste qui répond au ping.'} }
            if ($PingCollected -and $silent) { return [pscustomobject]@{Category='Offline';Health='Neutral';Reason='Poste sans réponse : pas de reprise immédiate.'} }
            return [pscustomobject]@{Category='Unreachable';Health='Neutral';Reason='Délai dépassé sans preuve que le poste est joignable : pas de reprise immédiate.'}
        }
        if ([string]$ErrorText -match '(?i)identifiants?.{0,20}(rejet|refus)|logon failure|password is incorrect|mot de passe') { return [pscustomobject]@{Category='Credential';Health='Neutral';Reason='Identifiants rejetés.'} }
        return [pscustomobject]@{Category='Permanent';Health='Failure';Reason='Lecture interrompue : erreur non transitoire.'}
    }
    switch ([string]$Outcome) {
        'AuthRejected' { return [pscustomobject]@{Category='Credential';Health='Neutral';Reason='Identifiants rejetés : aucune reprise automatique.'} }
        'Denied' { return [pscustomobject]@{Category='AccessDenied';Health='Success';Reason='Droit refusé : aucune reprise automatique.'} }
        'Timeout' {
            if ($PingCollected -and $silent) { return [pscustomobject]@{Category='Offline';Health='Neutral';Reason='Poste sans réponse : pas de reprise immédiate.'} }
            return [pscustomobject]@{Category='Transient';Health='Timeout';Reason='Délai dépassé sur un poste joignable.'}
        }
        'Unavailable' {
            if ($online) { return [pscustomobject]@{Category='ProtocolUnreachable';Health='Neutral';Reason='Le poste répond au ping mais refuse WMI (DCOM) : pas de reprise immédiate.'} }
            if ($PingCollected -and $silent) { return [pscustomobject]@{Category='Offline';Health='Neutral';Reason='Poste sans réponse : pas de reprise immédiate.'} }
            # WMI only: DCOM gives the same answer (RPC server unavailable) for a machine switched off.
            return [pscustomobject]@{Category='Unreachable';Health='Neutral';Reason='Lecture WMI non confirmée sans preuve que le poste est joignable : pas de reprise immédiate.'}
        }
        default {
            if ($PingCollected -and ([string]$Presence -eq 'Erreur de ping')) { return [pscustomobject]@{Category='Permanent';Health='Neutral';Reason='Nom non résolu ou erreur réseau locale.'} }
            if ($PingCollected -and ([string]$Presence -eq 'Sans réponse au ping') -and ([string]$Outcome -in @('PresenceOnly',''))) { return [pscustomobject]@{Category='Success';Health='Neutral';Reason=''} }
            return [pscustomobject]@{Category='Success';Health='Success';Reason=''}
        }
    }
}

function Get-DomeniaCollectionRetryDecision {
    # Bounded and spaced retries of a READ after a transient incident only: 30 s, then 2 min, three attempts at most.
    # Never for a write, a rejected account, a refused right, an offline machine or an absent class.
    param([AllowEmptyString()][string]$Category,[int]$Attempt=1,[int]$MaxAttempts=3,[bool]$IsWrite=$false,
        [int]$BaseDelaySeconds=30,[int]$MaxDelaySeconds=300,[datetime]$NowUtc=[datetime]::UtcNow)
    if ($IsWrite) { return [pscustomobject]@{Retry=$false;DelaySeconds=0;NotBeforeUtc=$null;Reason='Une écriture nʼest jamais rejouée.'} }
    if ([string]$Category -ne 'Transient') {
        $why = switch ([string]$Category) {
            'Credential' { 'Identifiants rejetés : reprise seulement après un changement de compte explicite.' }
            'AccessDenied' { 'Droit refusé : une nouvelle lecture donnerait le même refus.' }
            'Offline' { 'Poste sans réponse : il sera relu au prochain relevé.' }
            'Unreachable' { 'Poste non joignable sans preuve quʼil est allumé : il sera relu au prochain relevé.' }
            'ProtocolUnreachable' { 'WMI inaccessible sur ce poste : il sera relu au prochain relevé.' }
            'Success' { '' }
            default { 'Erreur non transitoire : aucune reprise automatique.' }
        }
        return [pscustomobject]@{Retry=$false;DelaySeconds=0;NotBeforeUtc=$null;Reason=$why}
    }
    $max = [Math]::Max(1,[Math]::Min(5,$MaxAttempts))
    if ($Attempt -ge $max) { return [pscustomobject]@{Retry=$false;DelaySeconds=0;NotBeforeUtc=$null;Reason=('Incident transitoire persistant après ' + [string]$Attempt + ' essai(s) : arrêt des reprises.')} }
    $delay = [int][Math]::Min([double][Math]::Max(1,$MaxDelaySeconds),[double][Math]::Max(1,$BaseDelaySeconds) * [Math]::Pow(4,[Math]::Max(0,$Attempt - 1)))
    return [pscustomobject]@{Retry=$true;DelaySeconds=$delay;NotBeforeUtc=$NowUtc.AddSeconds($delay);Reason=('Incident transitoire : nouvel essai dans ' + (Format-DomeniaCollectionDuration $delay) + ' (essai ' + [string]($Attempt + 1) + '/' + [string]$max + ').')}
}

# ---------------------------------------------------------------- point 19: capabilities of the workstations
function New-DomeniaCapabilityMemory { return [pscustomobject]@{Entries=@{}} }

function Get-DomeniaCapabilityTtlSeconds {
    param([Parameter(Mandatory=$true)][string]$Kind)
    switch ($Kind) {
        'ClassAbsent' { return 604800 }
        'ProtocolUnreachable' { return 900 }
        'RightDenied' { return 3600 }
        default { return 0 }
    }
}

function Test-DomeniaWmiClassAbsentText {
    # WMI answers « classe non valide » (0x80041010) or « espace de noms non valide » (0x8004100E): the class is
    # absent from this system, which is a capability, not an incident.
    param([AllowEmptyString()][string]$Text)
    return ([string]$Text -match '(?i)0x80041010|0x8004100e|invalid class|classe non valide|invalid namespace|espace de noms non valide')
}

function Get-DomeniaCapabilityKey {
    param([AllowEmptyString()][string]$Target,[AllowEmptyString()][string]$Capability)
    return (([string]$Target).Trim().ToLowerInvariant() + '|' + ([string]$Capability).Trim().ToLowerInvariant())
}

function Get-DomeniaProbeCapability {
    # Capability name of a catalog probe: its namespace and class.
    param($Probe)
    return ('class:' + [string](Get-DomeniaMember $Probe 'Namespace' '') + ':' + [string](Get-DomeniaMember $Probe 'Class' ''))
}

function Register-DomeniaCapabilityFact {
    # Remembers that a capability is missing on one workstation for a limited time. Build and AccountGeneration are
    # the context of the fact: a new Windows build invalidates an absent class, a new account a refused right.
    param($Memory,[Parameter(Mandatory=$true)][string]$Target,[Parameter(Mandatory=$true)][string]$Capability,
        [Parameter(Mandatory=$true)][ValidateSet('ClassAbsent','ProtocolUnreachable','RightDenied')][string]$Kind,
        [datetime]$NowUtc=[datetime]::UtcNow,[AllowEmptyString()][string]$Build='',[long]$AccountGeneration=0)
    if ($null -eq $Memory) { return $null }
    $entry = [pscustomobject]@{Target=$Target;Capability=$Capability;Kind=$Kind;ObservedUtc=$NowUtc;UntilUtc=$NowUtc.AddSeconds((Get-DomeniaCapabilityTtlSeconds $Kind));Build=([string]$Build).Trim();AccountGeneration=$AccountGeneration}
    $Memory.Entries[(Get-DomeniaCapabilityKey $Target $Capability)] = $entry
    return $entry
}

function Clear-DomeniaCapabilityFact {
    # A success proves the capability: the fact is forgotten at once.
    param($Memory,[AllowEmptyString()][string]$Target,[AllowEmptyString()][string]$Capability='')
    if ($null -eq $Memory) { return 0 }
    $removed = 0
    $prefix = ([string]$Target).Trim().ToLowerInvariant() + '|'
    foreach ($key in @($Memory.Entries.Keys)) {
        if ($Capability) { if ([string]$key -ne (Get-DomeniaCapabilityKey $Target $Capability)) { continue } }
        elseif (-not ([string]$key).StartsWith($prefix,[StringComparison]::Ordinal)) { continue }
        [void]$Memory.Entries.Remove($key); $removed++
    }
    return $removed
}

function Test-DomeniaCapabilityFact {
    # Known=$true when a fact still holds: not expired, same build for an absent class, same accounts for a refusal.
    param($Memory,[AllowEmptyString()][string]$Target,[AllowEmptyString()][string]$Capability,[datetime]$NowUtc=[datetime]::UtcNow,
        [AllowEmptyString()][string]$Build='',[long]$AccountGeneration=0)
    $none = [pscustomobject]@{Known=$false;Kind='';Reason='';UntilUtc=$null}
    if ($null -eq $Memory) { return $none }
    $key = Get-DomeniaCapabilityKey $Target $Capability
    if (-not $Memory.Entries.ContainsKey($key)) { return $none }
    $entry = $Memory.Entries[$key]
    $stale = ($NowUtc -ge [datetime]$entry.UntilUtc)
    if ((-not $stale) -and ([string]$entry.Kind -eq 'ClassAbsent') -and [string]$entry.Build -and ([string]$Build).Trim() -and ([string]$entry.Build -ine ([string]$Build).Trim())) { $stale = $true }
    if ((-not $stale) -and ([string]$entry.Kind -in @('RightDenied','ProtocolUnreachable')) -and ([long]$entry.AccountGeneration -ne $AccountGeneration)) { $stale = $true }
    if ($stale) { [void]$Memory.Entries.Remove($key); return $none }
    $until = ([datetime]$entry.UntilUtc).ToLocalTime().ToString('dd/MM HH:mm')
    $reason = switch ([string]$entry.Kind) {
        'ClassAbsent' { 'Classe WMI absente sur ce poste (relevé du ' + ([datetime]$entry.ObservedUtc).ToLocalTime().ToString('dd/MM HH:mm') + ') : non relue jusquʼau ' + $until + ' ou jusquʼà un changement de version de Windows.' }
        'ProtocolUnreachable' { 'WMI (DCOM) inaccessible sur ce poste : ping seul jusquʼà ' + ([datetime]$entry.UntilUtc).ToLocalTime().ToString('HH:mm') + ' ou jusquʼà un changement de compte.' }
        default { 'Droit refusé sur ce poste : lecture WMI suspendue jusquʼà ' + ([datetime]$entry.UntilUtc).ToLocalTime().ToString('HH:mm') + ' ou jusquʼà un changement de compte.' }
    }
    return [pscustomobject]@{Known=$true;Kind=[string]$entry.Kind;Reason=$reason;UntilUtc=[datetime]$entry.UntilUtc}
}

function Get-DomeniaCapabilityPlan {
    # Removes from one collection plan what is known to be impossible on this workstation. A forced read ignores the
    # memory. The previous stored result of a probe also proves an absent class while its date is recent enough.
    param($Memory,[AllowEmptyString()][string]$Target,[object[]]$Probes=@(),$Previous=$null,[datetime]$NowUtc=[datetime]::UtcNow,
        [AllowEmptyString()][string]$Build='',[long]$AccountGeneration=0,[bool]$Force=$false)
    $kept = New-Object 'System.Collections.Generic.List[object]'
    $skipped = New-Object 'System.Collections.Generic.List[object]'
    $all = @(@($Probes) | Where-Object { $null -ne $_ })
    if ($Force) { return [pscustomobject]@{Probes=$all;Skipped=@();SkipCim=$false;CimReason=''} }
    $cim = Test-DomeniaCapabilityFact -Memory $Memory -Target $Target -Capability 'cim' -NowUtc $NowUtc -Build $Build -AccountGeneration $AccountGeneration
    $previousProbes = Get-DomeniaMemberValue $Previous 'Probes' $null
    $ttl = Get-DomeniaCapabilityTtlSeconds 'ClassAbsent'
    foreach ($probe in $all) {
        $capability = Get-DomeniaProbeCapability $probe
        $fact = Test-DomeniaCapabilityFact -Memory $Memory -Target $Target -Capability $capability -NowUtc $NowUtc -Build $Build -AccountGeneration $AccountGeneration
        if ((-not [bool]$fact.Known) -and ($null -ne $previousProbes)) {
            $old = Get-DomeniaMemberValue $previousProbes ([string]$probe.Id) $null
            $oldError = [string](Get-DomeniaMember $old 'Error' '')
            $oldAt = ConvertTo-DomeniaUtcDate (Get-DomeniaMember $old 'CheckedUtc' $null)
            if ((Test-DomeniaWmiClassAbsentText $oldError) -and ($null -ne $oldAt) -and (($NowUtc - $oldAt).TotalSeconds -lt $ttl) -and ($oldAt -le $NowUtc.AddMinutes(1))) {
                $fact = Register-DomeniaCapabilityFact -Memory $Memory -Target $Target -Capability $capability -Kind 'ClassAbsent' -NowUtc $oldAt -Build $Build -AccountGeneration $AccountGeneration
                $fact = Test-DomeniaCapabilityFact -Memory $Memory -Target $Target -Capability $capability -NowUtc $NowUtc -Build $Build -AccountGeneration $AccountGeneration
            }
        }
        if ([bool]$fact.Known) { $skipped.Add([pscustomobject]@{Id=[string]$probe.Id;Kind=[string]$fact.Kind;Reason=[string]$fact.Reason}); continue }
        $kept.Add($probe)
    }
    return [pscustomobject]@{Probes=$kept.ToArray();Skipped=$skipped.ToArray();SkipCim=[bool]$cim.Known;CimReason=[string]$cim.Reason}
}

# ---------------------------------------------------------------- point 13: grouping of the CIM reads
function Get-DomeniaCimGroupKey {
    # Namespace and class names are case-insensitive; the filter is kept byte for byte (two literals never share).
    param([AllowEmptyString()][string]$Namespace,[AllowEmptyString()][string]$Class,[AllowEmptyString()][string]$Filter='')
    return (([string]$Namespace).ToUpperInvariant() + '|' + ([string]$Class).ToUpperInvariant() + '|' + [string]$Filter)
}

function Measure-DomeniaCimQueryPlan {
    # Expected CIM queries of one workstation: what each consumer would send alone, and what the shared reads send.
    # Console and inventory share Win32_ComputerSystem; the system type of the controller check joins the inventory
    # read of Win32_OperatingSystem; catalog probes of a class already read reuse it when their properties are there.
    param([bool]$ProbeUser=$true,[bool]$Inventory=$false,[object[]]$Probes=@())
    $requested = 0; $groups = @{}
    $cs = Get-DomeniaCimGroupKey 'root\cimv2' 'Win32_ComputerSystem' ''
    $os = Get-DomeniaCimGroupKey 'root\cimv2' 'Win32_OperatingSystem' ''
    $disk = Get-DomeniaCimGroupKey 'root\cimv2' 'Win32_LogicalDisk' "DeviceID='C:'"
    if ($ProbeUser) { $requested++; $groups[$cs] = $true }
    if ($Inventory) { $requested += 3; $groups[$cs] = $true; $groups[$os] = $true; $groups[$disk] = $true }
    $needProductType = $false
    foreach ($probe in @($Probes)) {
        if ($null -eq $probe) { continue }
        $requested++
        if ([string](Get-DomeniaMember $probe 'Skip' '') -eq 'DomainController') { $needProductType = $true }
        $groups[(Get-DomeniaCimGroupKey ([string](Get-DomeniaMember $probe 'Namespace' '')) ([string](Get-DomeniaMember $probe 'Class' '')) ([string](Get-DomeniaMember $probe 'Filter' '')))] = $true
    }
    if ($needProductType) { $requested++; $groups[$os] = $true }
    $executed = $groups.Count
    return [pscustomobject]@{Requested=$requested;Executed=$executed;Avoided=[Math]::Max(0,$requested - $executed)}
}

# ---------------------------------------------------------------- point 17: progress of a campaign
function Get-DomeniaCampaignProgressState {
    # Validated results are those read back from SQLite after COMMIT. Elapsed is the total time, Idle the time since
    # the last validated result, Held the time spent waiting with free places (budgets, retries, storage).
    param([int]$Total=0,[int]$Validated=0,[int]$Pending=0,[int]$Waiting=0,$StartedUtc=$null,$LastValidatedUtc=$null,[double]$HeldSeconds=0,
        [datetime]$NowUtc=[datetime]::UtcNow,[int]$StallSeconds=120)
    $started = ConvertTo-DomeniaUtcDate $StartedUtc
    $last = ConvertTo-DomeniaUtcDate $LastValidatedUtc
    $elapsed = 0.0
    if ($null -ne $started) { $elapsed = [Math]::Max(0.0,($NowUtc - $started).TotalSeconds) }
    $idle = $elapsed
    if ($null -ne $last) { $idle = [Math]::Max(0.0,($NowUtc - $last).TotalSeconds) }
    $active = (($Pending -gt 0) -or ($Waiting -gt 0))
    $stalled = ($active -and ($idle -gt [Math]::Max(10,$StallSeconds)))
    $text = [string]$Validated + '/' + [string]$Total + ' résultat(s) validé(s) · ' + (Format-DomeniaCollectionDuration ([long]$elapsed)) + ' écoulé(s)'
    if ($null -ne $last) { $text += ' · dernier résultat validé il y a ' + (Format-DomeniaCollectionDuration ([long]$idle)) }
    elseif ($active) { $text += ' · aucun résultat validé pour lʼinstant' }
    if ($HeldSeconds -ge 1) { $text += ' · attente réelle ' + (Format-DomeniaCollectionDuration ([long]$HeldSeconds)) }
    if ($stalled) { $text += ' · aucun progrès depuis ' + (Format-DomeniaCollectionDuration ([long]$idle)) + ' : les lectures en cours attendent leur délai' }
    return [pscustomobject]@{ElapsedSeconds=$elapsed;IdleSeconds=$idle;HeldSeconds=$HeldSeconds;Stalled=$stalled;Text=$text}
}

# ---------------------------------------------------------------- point 20: durable campaign plan
function Get-DomeniaCampaignPlanKinds { return @('Ping','Console','Wmi','Analysis') }

function Test-DomeniaCampaignRunDurable {
    # One survey per scope (FI-18) and one plan at a time: only a survey of the scope of the lists (the list, its
    # selection, an OU, a board or a query perimeter) is a campaign kept for a resume. The survey of the workstation
    # open in Poste and the collection of a widget (which the widget resumes itself, reading only what is missing)
    # never write a plan, so they never replace the plan of an interrupted campaign.
    param($Run)
    if ($null -eq $Run) { return $false }
    if ([string](Get-DomeniaMember $Run 'Slot' 'List') -eq 'Computer') { return $false }
    if ([string](Get-DomeniaMember $Run 'WidgetBoard' '')) { return $false }
    return $true
}

function Get-DomeniaCampaignTargetNamePattern {
    # A workstation kept in a durable plan: a host name that the resume reads back exactly. The same rule decides at
    # approval (a plan that could not be read back is reported as not saved) and when the plan is read.
    return '^[A-Za-z0-9][A-Za-z0-9._-]{0,252}$'
}

function Test-DomeniaCampaignTargetName {
    param([AllowEmptyString()][string]$Name)
    return ([string]$Name -cmatch (Get-DomeniaCampaignTargetNamePattern))
}

function New-DomeniaCampaignPlan {
    # Read-only campaigns only: ping, console, WMI or analysis of explicit workstations. The plan never holds a
    # credential, an AD write or a free query; only names, DN, GUID and the probe identifiers of the catalog.
    # It runs on the Dispatcher at approval for up to tens of thousands of workstations: the fields are read directly
    # (no helper call per target) and the name rule is fetched once.
    param([Parameter(Mandatory=$true)][ValidateSet('Ping','Console','Wmi','Analysis')][string]$Kind,[object[]]$Targets=@(),
        [string[]]$ProbeIds=@(),[bool]$Inventory=$false,[AllowEmptyString()][string]$ScopeLabel='',[AllowEmptyString()][string]$DomainDn='',
        [AllowEmptyString()][string]$DatabasePath='',[datetime]$NowUtc=[datetime]::UtcNow,[AllowEmptyString()][string]$Id='')
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    $namePattern = Get-DomeniaCampaignTargetNamePattern
    foreach ($target in @($Targets)) {
        if ($null -eq $target) { continue }
        $name = ''; $dn = ''; $guidValue = $null
        if ($target -is [Collections.IDictionary]) {
            $name = [string](Get-DomeniaMember $target 'Computer' (Get-DomeniaMember $target 'name' ''))
            $dn = [string](Get-DomeniaMember $target 'Key' (Get-DomeniaMember $target 'distinguished_name' ''))
            $guidValue = Get-DomeniaMemberValue $target 'Guid' (Get-DomeniaMemberValue $target 'object_guid' '')
        }
        else {
            # Same precedence as Get-DomeniaMember: the collection fields first, then the explicit scope fields.
            $properties = $target.PSObject.Properties
            $field = $properties['Computer']; if ($null -eq $field) { $field = $properties['name'] }
            if ($null -ne $field) { $name = [string]$field.Value }
            $field = $properties['Key']; if ($null -eq $field) { $field = $properties['distinguished_name'] }
            if ($null -ne $field) { $dn = [string]$field.Value }
            $field = $properties['Guid']; if ($null -eq $field) { $field = $properties['object_guid'] }
            if ($null -ne $field) { $guidValue = $field.Value }
        }
        $guid = ''
        if ($guidValue -is [string]) {
            $parsed = [guid]::Empty
            if ([guid]::TryParse($guidValue,[ref]$parsed) -and ($parsed -ne [guid]::Empty)) { $guid = $parsed.ToString('D') }
        }
        elseif ($null -ne $guidValue) { $guid = ConvertTo-DomeniaGuidText $guidValue }
        if ((-not ($name -cmatch $namePattern)) -or (-not $dn) -or ($dn -match '[\x00-\x1F]') -or (-not $guid)) { continue }
        $key = $guid.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $rows.Add([pscustomobject]@{N=$name;D=$dn;G=$guid})
    }
    if (-not $Id) { $Id = [guid]::NewGuid().ToString('N') }
    return [pscustomobject]@{Schema='DomeniaCampaignPlan/1';Id=$Id;Kind=$Kind;CreatedUtc=$NowUtc.ToString('o');DomainDn=([string]$DomainDn).Trim();DatabasePath=[string]$DatabasePath
        ScopeLabel=[string]$ScopeLabel;Inventory=$Inventory;ProbeIds=@(@($ProbeIds) | Where-Object { [string]$_ -match '^[A-Za-z0-9_.-]{1,128}$' } | ForEach-Object { [string]$_ } | Select-Object -Unique);Targets=$rows.ToArray()}
}

function New-DomeniaCampaignProgress {
    # The progress file repeats the head of the plan: the resume offer reads it without unpacking the target list.
    param([Parameter(Mandatory=$true)]$Plan,[datetime]$NowUtc=[datetime]::UtcNow)
    $count = @($Plan.Targets).Count
    return [pscustomobject]@{Schema='DomeniaCampaignProgress/1';PlanId=[string]$Plan.Id;Kind=[string]$Plan.Kind;CreatedUtc=[string]$Plan.CreatedUtc;DomainDn=[string]$Plan.DomainDn
        DatabasePath=[string]$Plan.DatabasePath;ScopeLabel=[string]$Plan.ScopeLabel;Done=(New-Object byte[] ([int][Math]::Ceiling($count / 8.0)));DoneCount=0;Total=$count
        State='Running';Reason='';UpdatedUtc=$NowUtc.ToString('o')}
}

function Set-DomeniaCampaignTargetDone {
    # Marks one target as validated (result committed). Idempotent: a duplicate delivery counts once.
    param([Parameter(Mandatory=$true)]$Progress,[int]$Index)
    if (($Index -lt 0) -or ($Index -ge [int]$Progress.Total)) { return $false }
    $byte = [int][Math]::Floor($Index / 8); $bit = [byte](1 -shl ($Index % 8))
    if (([byte]$Progress.Done[$byte] -band $bit) -ne 0) { return $false }
    $Progress.Done[$byte] = [byte]([byte]$Progress.Done[$byte] -bor $bit)
    $Progress.DoneCount = [int]$Progress.DoneCount + 1
    return $true
}

function ConvertTo-DomeniaCampaignTargetsText {
    # One line per workstation: name, DN and GUID separated by tabs. A DN with a control character is refused rather
    # than written in a form that could not be read back exactly.
    param([object[]]$Targets=@())
    $builder = New-Object Text.StringBuilder
    foreach ($target in @($Targets)) {
        $name = [string]$target.N; $dn = [string]$target.D; $guid = [string]$target.G
        if (($name + $dn + $guid) -match '[\x00-\x1F]') { throw 'Poste au nom ou DN non conservable dans le plan.' }
        [void]$builder.Append($name).Append([char]9).Append($dn).Append([char]9).Append($guid).Append([char]10)
    }
    return $builder.ToString()
}

function ConvertTo-DomeniaCampaignPlanText {
    # The target list is compressed: a 20 000 workstation plan stays under the size limit of a preference file.
    param([Parameter(Mandatory=$true)]$Plan)
    $raw = ConvertTo-DomeniaCampaignTargetsText @($Plan.Targets)
    $bytes = [Text.Encoding]::UTF8.GetBytes($raw)
    $buffer = [IO.MemoryStream]::new()
    try {
        $zip = [IO.Compression.GZipStream]::new($buffer,[IO.Compression.CompressionMode]::Compress,$true)
        try { $zip.Write($bytes,0,$bytes.Length) } finally { $zip.Dispose() }
        $packed = [Convert]::ToBase64String($buffer.ToArray())
    } finally { $buffer.Dispose() }
    $head = [ordered]@{Schema=[string]$Plan.Schema;Id=[string]$Plan.Id;Kind=[string]$Plan.Kind;CreatedUtc=[string]$Plan.CreatedUtc;DomainDn=[string]$Plan.DomainDn
        DatabasePath=[string]$Plan.DatabasePath;ScopeLabel=[string]$Plan.ScopeLabel;Inventory=[bool]$Plan.Inventory;ProbeIds=@($Plan.ProbeIds);Count=@($Plan.Targets).Count
        TargetsSha256=(Get-DomeniaTextHash $raw);Targets=$packed}
    return ([pscustomobject]$head | ConvertTo-Json -Depth 4 -Compress)
}

function ConvertFrom-DomeniaCampaignPlanText {
    # Refuses anything else than a well formed read campaign whose target list matches its digest.
    param([AllowEmptyString()][string]$Text)
    $head = $null
    try { $head = ConvertFrom-Json -InputObject ([string]$Text) -ErrorAction Stop } catch { throw 'Plan de relevé illisible.' }
    # Point 133: a plan written by a newer Domenia is refused with its version (contract catalogue of Common.Model).
    [void](Assert-DomeniaContractFormat -Format ([string](Get-DomeniaMember $head 'Schema' '')) -Family 'DomeniaCampaignPlan')
    if (@(Get-DomeniaCampaignPlanKinds) -notcontains [string](Get-DomeniaMember $head 'Kind' '')) { throw 'Plan de relevé dʼun type non autorisé.' }
    if ([string](Get-DomeniaMember $head 'Id' '') -notmatch '^[0-9a-fA-F]{32}$') { throw 'Identifiant de plan invalide.' }
    $raw = $null
    try {
        $source = [IO.MemoryStream]::new([Convert]::FromBase64String([string](Get-DomeniaMember $head 'Targets' '')))
        try {
            $zip = [IO.Compression.GZipStream]::new($source,[IO.Compression.CompressionMode]::Decompress)
            $output = [IO.MemoryStream]::new()
            try { $zip.CopyTo($output); $raw = [Text.Encoding]::UTF8.GetString($output.ToArray()) } finally { $output.Dispose(); $zip.Dispose() }
        } finally { $source.Dispose() }
    } catch { throw 'Liste des postes du plan illisible.' }
    if ((Get-DomeniaTextHash $raw) -cne [string](Get-DomeniaMember $head 'TargetsSha256' '')) { throw 'Liste des postes du plan altérée.' }
    $clean = New-Object 'System.Collections.Generic.List[object]'
    $namePattern = Get-DomeniaCampaignTargetNamePattern
    foreach ($line in $raw.Split([char]10)) {
        if (-not $line) { continue }
        $fields = $line.Split([char]9)
        if ($fields.Count -ne 3) { throw 'Poste du plan invalide.' }
        $parsed = [guid]::Empty
        if ((-not [guid]::TryParse($fields[2],[ref]$parsed)) -or ($parsed -eq [guid]::Empty) -or (-not ($fields[0] -cmatch $namePattern)) -or (-not $fields[1])) { throw 'Poste du plan invalide.' }
        $clean.Add([pscustomobject]@{N=$fields[0];D=$fields[1];G=$parsed.ToString('D')})
    }
    if ($clean.Count -ne [int](Get-DomeniaMember $head 'Count' -1)) { throw 'Nombre de postes du plan incohérent.' }
    return [pscustomobject]@{Schema='DomeniaCampaignPlan/1';Id=[string]$head.Id;Kind=[string]$head.Kind;CreatedUtc=[string](Get-DomeniaMember $head 'CreatedUtc' '');DomainDn=[string](Get-DomeniaMember $head 'DomainDn' '')
        DatabasePath=[string](Get-DomeniaMember $head 'DatabasePath' '');ScopeLabel=[string](Get-DomeniaMember $head 'ScopeLabel' '');Inventory=[bool](Get-DomeniaMember $head 'Inventory' $false)
        ProbeIds=@(@(Get-DomeniaMember $head 'ProbeIds' @()) | Where-Object { [string]$_ -match '^[A-Za-z0-9_.-]{1,128}$' } | ForEach-Object { [string]$_ });Targets=$clean.ToArray()}
}

function ConvertTo-DomeniaCampaignProgressText {
    param([Parameter(Mandatory=$true)]$Progress)
    return ([pscustomobject][ordered]@{Schema='DomeniaCampaignProgress/1';PlanId=[string]$Progress.PlanId;Kind=[string]$Progress.Kind;CreatedUtc=[string]$Progress.CreatedUtc
        DomainDn=[string]$Progress.DomainDn;DatabasePath=[string]$Progress.DatabasePath;ScopeLabel=[string]$Progress.ScopeLabel;Total=[int]$Progress.Total;DoneCount=[int]$Progress.DoneCount
        Done=[Convert]::ToBase64String([byte[]]$Progress.Done);State=[string]$Progress.State;Reason=[string]$Progress.Reason;UpdatedUtc=[string]$Progress.UpdatedUtc} | ConvertTo-Json -Compress)
}

function ConvertFrom-DomeniaCampaignProgressText {
    # Progress alone (resume offer) or checked against its plan (resume). The counter is recomputed from the bits:
    # a damaged counter never hides a remaining workstation.
    param([AllowEmptyString()][string]$Text,$Plan=$null)
    $data = $null
    try { $data = ConvertFrom-Json -InputObject ([string]$Text) -ErrorAction Stop } catch { throw 'Avancement du relevé illisible.' }
    [void](Assert-DomeniaContractFormat -Format ([string](Get-DomeniaMember $data 'Schema' '')) -Family 'DomeniaCampaignProgress')
    if ([string](Get-DomeniaMember $data 'PlanId' '') -notmatch '^[0-9a-fA-F]{32}$') { throw 'Avancement du relevé illisible.' }
    if (@(Get-DomeniaCampaignPlanKinds) -notcontains [string](Get-DomeniaMember $data 'Kind' '')) { throw 'Avancement dʼun relevé dʼun type non autorisé.' }
    $total = [int](Get-DomeniaMember $data 'Total' -1)
    if ($null -ne $Plan) {
        if ([string](Get-DomeniaMember $data 'PlanId' '') -cne [string]$Plan.Id) { throw 'Avancement dʼun autre plan.' }
        if ($total -ne @($Plan.Targets).Count) { throw 'Avancement incohérent avec le plan.' }
    }
    if ($total -lt 0) { throw 'Avancement incohérent.' }
    $bytes = $null
    try { $bytes = [Convert]::FromBase64String([string](Get-DomeniaMember $data 'Done' '')) } catch { throw 'Avancement du relevé illisible.' }
    if ($bytes.Length -ne [int][Math]::Ceiling($total / 8.0)) { throw 'Avancement incohérent avec le plan.' }
    # Bits counted byte by byte (each settings refresh and the resume offer read this file on the Dispatcher): the
    # bits past the last target of a partial byte are ignored.
    $done = 0
    $whole = [int][Math]::Floor($total / 8)
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        $value = [int]$bytes[$index]
        if ($index -ge $whole) { $value = $value -band ((1 -shl ($total % 8)) - 1) }
        while ($value -ne 0) { $value = $value -band ($value - 1); $done++ }
    }
    return [pscustomobject]@{Schema='DomeniaCampaignProgress/1';PlanId=[string]$data.PlanId;Kind=[string]$data.Kind;CreatedUtc=[string](Get-DomeniaMember $data 'CreatedUtc' '')
        DomainDn=[string](Get-DomeniaMember $data 'DomainDn' '');DatabasePath=[string](Get-DomeniaMember $data 'DatabasePath' '');ScopeLabel=[string](Get-DomeniaMember $data 'ScopeLabel' '')
        Done=$bytes;DoneCount=$done;Total=$total;State=[string](Get-DomeniaMember $data 'State' 'Interrupted');Reason=[string](Get-DomeniaMember $data 'Reason' '');UpdatedUtc=[string](Get-DomeniaMember $data 'UpdatedUtc' '')}
}

function Get-DomeniaCampaignRemainingTargets {
    # Workstations not validated yet, in plan order, in the shape of the explicit scope of a collection.
    param([Parameter(Mandatory=$true)]$Plan,[Parameter(Mandatory=$true)]$Progress)
    $out = New-Object 'System.Collections.Generic.List[object]'
    $done = [byte[]]$Progress.Done
    $index = 0
    foreach ($target in @($Plan.Targets)) {
        # Bit layout of Set-DomeniaCampaignTargetDone, read inline: one call per target would hold the Dispatcher.
        if (($index -ge $done.Length * 8) -or (([int]$done[$index -shr 3] -band (1 -shl ($index -band 7))) -eq 0)) { $out.Add([pscustomobject]@{name=[string]$target.N;distinguished_name=[string]$target.D;object_guid=[string]$target.G}) }
        $index++
    }
    return $out.ToArray()
}

function Get-DomeniaCampaignResumeState {
    # A plan is offered again only on the same domain and the same local base, and only while targets remain.
    param($Progress,[AllowEmptyString()][string]$DomainDn='',[AllowEmptyString()][string]$DatabasePath='')
    if ($null -eq $Progress) { return [pscustomobject]@{Resumable=$false;Remaining=0;Total=0;Reason='Aucun relevé interrompu.'} }
    $total = [int]$Progress.Total
    $remaining = [Math]::Max(0,$total - [int]$Progress.DoneCount)
    if ($remaining -eq 0) { return [pscustomobject]@{Resumable=$false;Remaining=0;Total=$total;Reason='Relevé terminé : aucun poste restant.'} }
    if ([string]$Progress.DomainDn -ine ([string]$DomainDn).Trim()) { return [pscustomobject]@{Resumable=$false;Remaining=$remaining;Total=$total;Reason='Relevé interrompu sur un autre domaine : non proposé ici.'} }
    if ([string]$Progress.DatabasePath -ine [string]$DatabasePath) { return [pscustomobject]@{Resumable=$false;Remaining=$remaining;Total=$total;Reason='Relevé interrompu sur une autre base locale : non proposé ici.'} }
    $when = ''
    $created = ConvertTo-DomeniaUtcDate ([string]$Progress.CreatedUtc)
    if ($null -ne $created) { $when = ' du ' + $created.ToLocalTime().ToString('dd/MM à HH:mm') }
    $label = ''
    if ([string]$Progress.ScopeLabel) { $label = ' (' + [string]$Progress.ScopeLabel + ')' }
    $why = ''
    switch ([string]$Progress.State) {
        'Paused' { $why = ' arrêté par lʼopérateur' }
        'Closed' { $why = ' interrompu par la fermeture de Domenia' }
        'Incident' { $why = ' interrompu par un incident' }
        default { $why = ' interrompu' }
    }
    $detail = ''
    if ([string]$Progress.Reason) { $detail = ' Motif : ' + [string]$Progress.Reason }
    return [pscustomobject]@{Resumable=$true;Remaining=$remaining;Total=$total;Reason=('Relevé' + $when + $label + $why + ' : ' + [string]$remaining + ' poste(s) restant(s) sur ' + [string]$total + '. La reprise ne relit que les postes non validés, en lecture seule.' + $detail)}
}
