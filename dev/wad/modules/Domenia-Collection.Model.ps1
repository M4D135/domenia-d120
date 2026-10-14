# Collection truth (roadmap of 13 October 2026, points 3, 4, 5 and 10). Pure rules: no WPF, no network, no disk and
# no hidden clock (every rule receives NowUtc; the default is only a convenience for callers).
# - Three collection clocks per scope (AD objects, network presence, WMI inventory) recorded by the explicit OU
#   commands; recalculating a view never writes nor rejuvenates them.
# - The last success of a scope is kept apart from its last attempt and that attempt's error.
# - Each run keeps its provenance: controller, provider, collector version, observed and recorded times. Incoherent
#   dates are reported, never corrected.
# - An absent, unread, refused, stale, incomplete or failed measure keeps its own state: it never becomes a zero, a
#   healthy value or a fresh date.
# Depends only on Domenia-Common.Model.ps1 (Get-DomeniaMember, Get-DomeniaMemberValue, ConvertTo-DomeniaUtcDate,
# Get-DomeniaRawDnParent), loaded first by every runner.

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
    $exact=if($keys.Count){[string]$keys[0]}else{''}
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
            ScopeDn=[string](Get-DomeniaMember $data 'ScopeDn' '');Inherited=($best.RequestKey -cne $exact)
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
            ScopeDn=[string](Get-DomeniaMember $data 'ScopeDn' '');Inherited=($latest.RequestKey -cne $exact)
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
    # "198/200 postes" or "198 postes" or "": only measured counters are written.
    param($View)
    $done=Get-DomeniaMember $View 'Done' $null;$targets=Get-DomeniaMember $View 'Targets' $null;$failed=Get-DomeniaMember $View 'Failed' $null
    if($null -eq $done){return ''}
    $text=[string]$done
    if($null -ne $targets){$text+='/'+[string]$targets}
    $text+=' poste'+$(if([long]$done -gt 1){'s'}else{''})
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
    $parts=[Collections.Generic.List[string]]::new();$detail=[Collections.Generic.List[string]]::new();$warning=$false
    $describe={param($View,[string]$Kind)
        $line=$Kind+' : '+(& $date $View.AtUtc)
        if($View.FinishedAtUtc -is [datetime]){$line+=' → '+(& $date $View.FinishedAtUtc)}
        if($View.RecordedAtUtc -is [datetime]){$line+=' ; enregistré le '+(& $date $View.RecordedAtUtc)}else{$line+=' ; heure dʼenregistrement non conservée'}
        if($View.ScopeDn){$line+=' ; périmètre '+$View.ScopeDn+$(if($View.Inherited){' (OU englobante)'}else{''})}
        $source=@(@($(if($View.Provider){'fournisseur '+$View.Provider}),$(if($View.Controller){'contrôleur '+$View.Controller}),$(if($View.CollectorVersion){'version de collecte '+$View.CollectorVersion}))|Where-Object{$_})
        if($source.Count){$line+=' ; '+($source -join ', ')}
        $counts=Format-DomeniaCollectionCounts $View;if($counts){$line+=' ; '+$counts}
        return $line
    }
    if($null -ne $success){
        if($family -ne 'Directory'){
            $text='relevé réussi le '+(& $date $success.AtUtc)
            $counts=Format-DomeniaCollectionCounts $success;if($counts){$text+=' ('+$counts+')'}
            if($success.Inherited){$text+=' via une OU englobante'}
            $parts.Add($text)
        }
        $detail.Add((& $describe $success 'Dernière réussite'))
        if(-not [bool]$success.Qualification.Coherent){$parts.Add([string]$success.Qualification.Text);$warning=$true}
    }elseif($family -ne 'Directory'){$parts.Add('aucun relevé réussi enregistré')}
    if(([bool](Get-DomeniaMember $Clock 'AttemptFailedAfterSuccess' $false)) -and ($null -ne $attempt)){
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
    if(($status -ne 'Success') -and $failure){$line+=' (non confirmée : '+(ConvertTo-DomeniaCollectionText $failure 240)+')'}
    $parts.Add($line)
    $parts.Add('Écriture locale UTC : '+$(if($recorded){$recorded}else{'non conservée'}))
    if($definition){$parts.Add('Définition de collecte : '+$definition.Substring(0,[Math]::Min(12,$definition.Length)))}
    $quality=Test-DomeniaCollectionClock -ObservedUtc $success -AttemptUtc $attempt -RecordedUtc $recorded -NowUtc $NowUtc
    if(-not [bool]$quality.Coherent){$parts.Add([string]$quality.Text)}
    return [pscustomobject]@{Text=($parts -join ' · ');Coherent=[bool]$quality.Coherent;Issues=$quality.Issues}
}

# ---------------------------------------------------------------- point 3: states of a measure
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
    $counts=[ordered]@{Known=0;Absent=0;NotRead=0;Refused=0;Expired=0;Incomplete=0;Error=0}
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
