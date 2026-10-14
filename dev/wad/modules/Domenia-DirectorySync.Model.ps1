# Directory synchronisation rules (points 22, 23, 24 and 30): census advice for the chosen scope, moves between
# OUs, disappearance versus deletion, and dated directory snapshots ("relevés") with their coverage proof.
# Pure decisions: no LDAP, no SQLite, no disk access and no clock read (every "now" is a parameter).

# ---------------------------------------------------------------- DN helpers
function Get-DomeniaDnParts {
    # Trimmed RDNs of a raw LDAP DN; an escaped comma stays inside its RDN.
    param([AllowEmptyString()][AllowNull()][string]$Dn)
    $parts=New-Object 'System.Collections.Generic.List[string]'
    $text=([string]$Dn).Trim()
    if(-not $text){return ,$parts.ToArray()}
    foreach($part in @(Split-DomeniaRawDn $text)){
        $value=([string]$part).Trim()
        if($value){$parts.Add($value)}
    }
    return ,$parts.ToArray()
}

function Test-DomeniaDnInScope {
    # RDN-boundary membership of $Dn in $ScopeDn. Base: the scope object itself; OneLevel: its direct children;
    # Subtree: the scope and everything below it. A suffix that cuts an RDN is never membership.
    param([AllowEmptyString()][AllowNull()][string]$Dn,[AllowEmptyString()][AllowNull()][string]$ScopeDn,[ValidateSet('Base','OneLevel','Subtree')][string]$Scope='Subtree')
    $dnParts=@(Get-DomeniaDnParts $Dn)
    $scopeParts=@(Get-DomeniaDnParts $ScopeDn)
    if((-not $dnParts.Count) -or (-not $scopeParts.Count) -or ($dnParts.Count -lt $scopeParts.Count)){return $false}
    $offset=$dnParts.Count-$scopeParts.Count
    for($i=0;$i -lt $scopeParts.Count;$i++){
        if(-not [string]::Equals([string]$dnParts[$offset+$i],[string]$scopeParts[$i],[StringComparison]::OrdinalIgnoreCase)){return $false}
    }
    if($Scope -eq 'Base'){return ($offset -eq 0)}
    if($Scope -eq 'OneLevel'){return ($offset -eq 1)}
    return $true
}

function Get-DomeniaDnRdnValue {
    # Decoded value of one RDN ('OU=Lyon' gives 'Lyon'), for display only.
    param([AllowEmptyString()][AllowNull()][string]$Rdn)
    $text=([string]$Rdn).Trim()
    $index=$text.IndexOf('=')
    if($index -ge 0){$text=$text.Substring($index+1)}
    return (ConvertFrom-DomeniaDnLabel $text)
}

function Get-DomeniaDnPath {
    # Decoded OU and container names of a DN, from the domain head down. -ExcludeSelf stops at the direct parent.
    # The domain components (DC=) are not part of the path.
    param([AllowEmptyString()][AllowNull()][string]$Dn,[switch]$ExcludeSelf)
    $parts=@(Get-DomeniaDnParts $Dn)
    $labels=New-Object 'System.Collections.Generic.List[string]'
    $last=0;if($ExcludeSelf){$last=1}
    for($i=$parts.Count-1;$i -ge $last;$i--){
        $part=[string]$parts[$i]
        if($part -match '^(?i)DC='){continue}
        $labels.Add((Get-DomeniaDnRdnValue $part))
    }
    return ,$labels.ToArray()
}

function Get-DomeniaDnBreadcrumb {
    # Parent OUs and containers of an object, from the domain head down to its direct parent.
    param([AllowEmptyString()][AllowNull()][string]$Dn)
    return ,@(Get-DomeniaDnPath $Dn -ExcludeSelf)
}

function Get-DomeniaDnLocation {
    # Readable location of an object ('Lyon › Postes'); '(racine du domaine)' directly under the domain head.
    param([AllowEmptyString()][AllowNull()][string]$Dn)
    if(@(Get-DomeniaDnParts $Dn).Count -lt 2){return ''}
    $trail=@(Get-DomeniaDnBreadcrumb $Dn)
    if(-not $trail.Count){return '(racine du domaine)'}
    return ($trail -join ' › ')
}

# ---------------------------------------------------------------- point 23: moves between OUs
function Get-DomeniaDirectoryMove {
    # What a DN change means for a scope. The object keeps its GUID: a move or a rename never makes a second object.
    # Kind: Unchanged, Renamed, MovedWithin, MovedOut, MovedIn, MovedOutside, Unknown. An empty $ScopeDn means
    # that every location belongs (no scope to enforce).
    param([AllowEmptyString()][AllowNull()][string]$OldDn,[AllowEmptyString()][AllowNull()][string]$NewDn,[AllowEmptyString()][AllowNull()][string]$ScopeDn='',[ValidateSet('Base','OneLevel','Subtree')][string]$Scope='Subtree')
    $old=([string]$OldDn).Trim();$new=([string]$NewDn).Trim();$scopeText=([string]$ScopeDn).Trim()
    $result=[ordered]@{Kind='Unknown';Moved=$false;InScope=$false;WasInScope=$false;FromLocation='';ToLocation='';Breadcrumb=@();Text=''}
    if(-not $new){$result.Text='Nouvel emplacement inconnu : aucune conclusion.';return [pscustomobject]$result}
    $inScope=$true;$wasInScope=[bool]$old
    if($scopeText){
        $inScope=Test-DomeniaDnInScope $new $scopeText $Scope
        $wasInScope=([bool]$old -and (Test-DomeniaDnInScope $old $scopeText $Scope))
    }
    $result.InScope=[bool]$inScope;$result.WasInScope=[bool]$wasInScope
    $result.ToLocation=Get-DomeniaDnLocation $new
    $result.Breadcrumb=@(Get-DomeniaDnBreadcrumb $new)
    if(-not $old){$result.Text='Ancien emplacement inconnu ; emplacement actuel : '+$result.ToLocation+'.';return [pscustomobject]$result}
    $result.FromLocation=Get-DomeniaDnLocation $old
    if($old -ieq $new){$result.Kind='Unchanged';$result.Text='Emplacement inchangé.';return [pscustomobject]$result}
    $oldParts=@(Get-DomeniaDnParts $old);$newParts=@(Get-DomeniaDnParts $new)
    $oldParent=if($oldParts.Count -gt 1){($oldParts[1..($oldParts.Count-1)] -join ',')}else{''}
    $newParent=if($newParts.Count -gt 1){($newParts[1..($newParts.Count-1)] -join ',')}else{''}
    if($oldParent -ieq $newParent){
        $result.Kind='Renamed'
        $result.Text='Renommé au même emplacement : '+(Get-DomeniaDnRdnValue $oldParts[0])+' → '+(Get-DomeniaDnRdnValue $newParts[0])+'.'
        return [pscustomobject]$result
    }
    $result.Moved=$true
    if($wasInScope -and $inScope){$result.Kind='MovedWithin';$result.Text='Déplacé dans le périmètre : '+$result.FromLocation+' → '+$result.ToLocation+'.'}
    elseif($wasInScope){$result.Kind='MovedOut';$result.Text='Déplacé hors du périmètre affiché : désormais dans '+$result.ToLocation+'.'}
    elseif($inScope){$result.Kind='MovedIn';$result.Text='Entré dans le périmètre : venant de '+$result.FromLocation+'.'}
    else{$result.Kind='MovedOutside';$result.Text='Déplacé hors du périmètre : '+$result.FromLocation+' → '+$result.ToLocation+'.'}
    return [pscustomobject]$result
}

function Get-DomeniaMoveStateText {
    # Short state of a moved row in a result list; the full sentence stays in the Text of the move.
    param($Move)
    $kind=[string](Get-DomeniaMember $Move 'Kind' 'Unknown')
    $to=[string](Get-DomeniaMember $Move 'ToLocation' '')
    switch($kind){
        'Renamed' {return 'Renommé au même emplacement'}
        'MovedWithin' {return ('Déplacé vers '+$to)}
        'MovedIn' {return ('Entré dans le périmètre : '+$to)}
        'MovedOut' {return ('Sorti du périmètre : '+$to)}
        'MovedOutside' {return ('Déplacé : '+$to)}
        'Unchanged' {return 'AD vérifié'}
    }
    return 'Emplacement à vérifier'
}

# ---------------------------------------------------------------- point 24: disappearance versus deletion
function Get-DomeniaAbsenceStatusLabel {
    param([AllowEmptyString()][AllowNull()][string]$Status)
    switch([string]$Status){
        'NonVu' {return 'Non revu, à vérifier'}
        'Visible' {return 'De nouveau visible'}
        'Deplace' {return 'Déplacé'}
        'Supprime' {return 'Suppression constatée'}
        'Introuvable' {return 'Introuvable'}
        'NonVisible' {return 'Invisible pour ce compte'}
        'NonConfirme' {return 'Vérification impossible'}
    }
    return 'État inconnu'
}

function Resolve-DomeniaDirectoryAbsence {
    # Classifies an object that a complete read of its scope did not return. Only a deleted-object entry (isDeleted)
    # read by GUID proves a deletion. A partial read, a filter or a loss of rights only makes an object invisible.
    # $Absence: {Guid, LastDn, ScopeDn}. $Check: {DomainRead, FoundDn, DeletedRead, Deleted, DeletedWhenUtc,
    # LastKnownParent, Recycled}. DomainRead: Read | Refused | Unavailable. DeletedRead: Read (deleted objects are
    # visible to this account) | Empty (none visible: no right or empty container, indistinguishable) | Refused |
    # Unavailable | NotRequested.
    param($Absence,$Check)
    $guid=ConvertTo-DomeniaGuidText (Get-DomeniaMember $Absence 'Guid' '')
    $lastDn=[string](Get-DomeniaMember $Absence 'LastDn' '')
    $scopeDn=[string](Get-DomeniaMember $Absence 'ScopeDn' '')
    $out=[ordered]@{Guid=$guid;Status='NonConfirme';Label='';FoundDn='';Proof='';Text='';Move=$null}
    $domainRead=[string](Get-DomeniaMember $Check 'DomainRead' '')
    if(-not $guid){
        $out.Text='Identité absente : aucune vérification possible.'
    }elseif($domainRead -ne 'Read'){
        $out.Text=if($domainRead -eq 'Refused'){'Lecture du domaine refusée pour ce compte : aucune conclusion sur cet objet.'}else{'Domaine non lu (contrôleur indisponible ou délai dépassé) : aucune conclusion.'}
    }else{
        $found=([string](Get-DomeniaMember $Check 'FoundDn' '')).Trim()
        $deletedRead=[string](Get-DomeniaMember $Check 'DeletedRead' 'NotRequested')
        if($found){
            $move=Get-DomeniaDirectoryMove -OldDn $lastDn -NewDn $found -ScopeDn $scopeDn -Scope 'Subtree'
            $out.FoundDn=$found;$out.Move=$move;$out.Proof='Objet lu par son GUID dans le domaine.'
            if(([bool]$move.InScope) -and ([string]$move.Kind -in @('Unchanged','Renamed','MovedWithin'))){
                $out.Status='Visible'
                $out.Text='Objet de nouveau visible dans le périmètre ('+[string]$move.ToLocation+') : lʼabsence venait de la lecture ou des droits du moment, pas dʼune suppression.'
            }else{
                $out.Status='Deplace'
                $out.Text='Objet présent ailleurs dans le domaine : '+[string]$move.ToLocation+'. Il nʼa pas été supprimé ; son identité (GUID) est conservée.'
            }
        }elseif([bool](Get-DomeniaMember $Check 'Deleted' $false)){
            $out.Status='Supprime';$out.Proof='Objet lu par son GUID parmi les objets supprimés (isDeleted).'
            $text='Suppression constatée : lʼobjet figure parmi les objets supprimés'
            $when=ConvertTo-DomeniaUtcDate (Get-DomeniaMember $Check 'DeletedWhenUtc' $null)
            if($null -ne $when){$text+=', modifié pour la dernière fois le '+$when.ToLocalTime().ToString('dd/MM/yyyy HH:mm')}
            $parent=[string](Get-DomeniaMember $Check 'LastKnownParent' '')
            if($parent){
                $parentPath=@(Get-DomeniaDnPath $parent)
                $text+=' ; dernier emplacement connu : '+$(if($parentPath.Count){$parentPath -join ' › '}else{'(racine du domaine)'})
            }
            $text+='.'
            if([bool](Get-DomeniaMember $Check 'Recycled' $false)){$text+=' Lʼobjet est recyclé : la plupart de ses attributs ne sont plus conservés.'}
            $out.Text=$text
        }elseif($deletedRead -eq 'Read'){
            $out.Status='Introuvable'
            $out.Text='Absent du domaine et des objets supprimés lisibles : suppression plus ancienne que leur durée de conservation, ou objet devenu invisible pour ce compte. Aucune conclusion.'
        }elseif($deletedRead -in @('Empty','Refused')){
            $out.Status='NonVisible'
            $out.Text='Absent pour ce compte, et aucun objet supprimé nʼest visible avec ce compte : une suppression et un retrait de droits ne se distinguent pas ici.'
        }else{
            $out.Text='Objets supprimés non lus : lʼabsence dans le domaine ne suffit pas à conclure à une suppression.'
        }
    }
    $out.Label=Get-DomeniaAbsenceStatusLabel $out.Status
    return [pscustomobject]$out
}

function Select-DomeniaAbsencesToCheck {
    # The objects an explicit check reads, oldest first: those never verified, or whose verification was inconclusive
    # because the controller was unavailable. Bounded: one gesture never reads more than $Limit identities.
    param([object[]]$Rows=@(),[ValidateRange(1,500)][int]$Limit=200)
    $candidates=@(@($Rows)|Where-Object{($null -ne $_) -and ([string](Get-DomeniaMember $_ 'Status' '') -in @('NonVu','NonConfirme')) -and (ConvertTo-DomeniaGuidText (Get-DomeniaMember $_ 'Guid' ''))})
    $ordered=@($candidates|Sort-Object @{Expression={[string](Get-DomeniaMember $_ 'NoticedAt' '')}},@{Expression={[string](Get-DomeniaMember $_ 'Guid' '')}})
    if($ordered.Count -gt $Limit){$ordered=@($ordered[0..($Limit-1)])}
    return ,$ordered
}

function New-DomeniaAbsenceStoreRow {
    # What the local base keeps of one verification. A re-read record is kept only for an object that still exists
    # (visible again or moved), so that its new location replaces the old one under the same GUID.
    param($Resolution,$Record=$null,[datetime]$CheckedUtc=[datetime]::UtcNow,[string]$Server='')
    $status=[string](Get-DomeniaMember $Resolution 'Status' 'NonConfirme')
    $keep=$null
    if(($status -in @('Visible','Deplace')) -and ($null -ne $Record) -and ([string](Get-DomeniaMember $Record 'Type' '') -in @('Machine','Utilisateur')) -and ((ConvertTo-DomeniaGuidText (Get-DomeniaMember $Record 'Guid' '')) -ieq [string](Get-DomeniaMember $Resolution 'Guid' ''))){$keep=$Record}
    return [pscustomobject]@{
        Guid=([string](Get-DomeniaMember $Resolution 'Guid' '')).ToLowerInvariant()
        Status=$status
        FoundDn=[string](Get-DomeniaMember $Resolution 'FoundDn' '')
        Detail=(ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $Resolution 'Text' '')) 600)
        CheckedAt=$CheckedUtc.ToUniversalTime().ToString('o')
        Server=$Server
        Record=$keep
    }
}

function Format-DomeniaUtcText {
    # Local display of a stored UTC text; '' when absent or unreadable.
    param($Value)
    $date=ConvertTo-DomeniaUtcDate $Value
    if($null -eq $date){return ''}
    return $date.ToLocalTime().ToString('dd/MM/yyyy HH:mm')
}

function ConvertTo-DomeniaAbsenceRow {
    # Display row of one object recorded as not seen by a complete read (local base row, column names).
    param($Row)
    $status=[string](Get-DomeniaMember $Row 'status' 'NonVu')
    if(-not $status){$status='NonVu'}
    $lastDn=[string](Get-DomeniaMember $Row 'last_dn' '');$foundDn=[string](Get-DomeniaMember $Row 'found_dn' '')
    $noticed=Format-DomeniaUtcText (Get-DomeniaMember $Row 'noticed_at' '')
    $place=Get-DomeniaDnLocation $lastDn
    if($foundDn -and ($status -eq 'Deplace')){$place=$place+' → '+(Get-DomeniaDnLocation $foundDn)}
    $detail=ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $Row 'detail' '')) 600
    if((-not $detail) -and ($status -eq 'NonVu')){$detail='Absent de la lecture complète'+$(if($noticed){' du '+$noticed}else{''})+' : invisible, déplacé ou supprimé. À vérifier avant toute conclusion.'}
    return [pscustomobject]@{
        Guid=(ConvertTo-DomeniaGuidText (Get-DomeniaMember $Row 'object_guid' ''));Status=$status;Etat=(Get-DomeniaAbsenceStatusLabel $status)
        Nom=[string](Get-DomeniaMember $Row 'name' '');Type=[string](Get-DomeniaMember $Row 'object_type' '');Emplacement=$place
        Constate=$noticed;Verifie=(Format-DomeniaUtcText (Get-DomeniaMember $Row 'checked_at' ''));Detail=$detail
        LastDn=$lastDn;FoundDn=$foundDn;ScopeDn=[string](Get-DomeniaMember $Row 'scope_dn' '');NoticedAt=[string](Get-DomeniaMember $Row 'noticed_at' '')
    }
}

function Get-DomeniaAbsenceSummary {
    # One line for the list: exact total, totals by state, how many are still to verify.
    param([object[]]$Rows=@(),[long]$Total=0,[object[]]$Counts=@())
    if($Total -le 0){return 'Aucune disparition enregistrée. Un objet quʼune lecture complète ne retrouve plus apparaîtra ici au lieu dʼêtre déclaré supprimé.'}
    $parts=New-Object 'System.Collections.Generic.List[string]'
    foreach($count in @($Counts)){
        if($null -eq $count){continue}
        $number=[long](Get-DomeniaMember $count 'n' 0)
        if($number -gt 0){$parts.Add([string]$number+' '+(Get-DomeniaAbsenceStatusLabel ([string](Get-DomeniaMember $count 'status' ''))).ToLowerInvariant())}
    }
    $text=[string]$Total+' objet(s) non revu(s) par une lecture complète'
    if($parts.Count){$text+=' : '+($parts.ToArray() -join ', ')}
    $text+='.'
    $shown=@($Rows).Count
    if($shown -lt $Total){$text+=' Les '+$shown+' plus récents sont affichés.'}
    $pending=@(@($Rows)|Where-Object{($null -ne $_) -and ([string]$_.Status -in @('NonVu','NonConfirme'))}).Count
    if($pending){$text+=' '+$pending+' à vérifier.'}
    return $text
}

# ---------------------------------------------------------------- point 22: complete census of the chosen scope
function Get-DomeniaCensusAdvice {
    # Whether the chosen scope needs a complete census. A differential read (uSNChanged) neither sees an object that
    # became visible without being modified nor proves an absence: only a complete read of the scope can. $Coverage is
    # the result of Get-DomeniaFleetFreshness; $GapCount counts identities seen by the last domain census but missing
    # from the local base. Nothing is started from here: the operator decides.
    param($Coverage,[int]$GapCount=0,[int]$MaxAgeDays=7,[datetime]$NowUtc=[datetime]::UtcNow,[bool]$IsDomain=$false)
    $days=[Math]::Max(1,[Math]::Min(90,$MaxAgeDays))
    $status=[string](Get-DomeniaMember $Coverage 'Status' 'Missing')
    $at=ConvertTo-DomeniaUtcDate (Get-DomeniaMember $Coverage 'At' $null)
    $out=[ordered]@{State='Recent';Due=$false;AgeDays=-1;MaxAgeDays=$days;GapCount=[Math]::Max(0,$GapCount);Text=''}
    if($null -ne $at){$out.AgeDays=[int][Math]::Floor(($NowUtc-$at).TotalDays)}
    if($GapCount -gt 0){
        $out.State='Gap';$out.Due=$true
        $out.Text='Recensement : '+$GapCount+' objet(s) présent(s) dans lʼAD manquent dans la base locale. La prochaine mise à jour des changements relira tout le domaine pour les reprendre.'
    }elseif([bool](Get-DomeniaMember $Coverage 'Partial' $false)){
        $out.State='Partial';$out.Due=$true
        $out.Text='Recensement : la dernière tentative était incomplète. Aucune disparition nʼen est déduite ; relancez la lecture complète de ce périmètre.'
    }elseif(($null -eq $at) -or ($status -ne 'Complete')){
        $out.State='Absent';$out.Due=$true
        $out.Text='Recensement : aucune lecture complète de ce périmètre. Seule une lecture complète repère les objets disparus ou devenus visibles sans modification.'
    }elseif($at -gt $NowUtc.AddMinutes(5)){
        $out.State='Clock';$out.Due=$true
        $out.Text='Recensement daté dans le futur : vérifiez lʼhorloge de ce poste avant de vous y fier.'
    }elseif(($NowUtc-$at).TotalDays -gt $days){
        $out.State='Due';$out.Due=$true
        $out.Text='Recensement complet daté de '+$out.AgeDays+' jours (seuil : '+$days+' jours). Relisez ce périmètre pour repérer ce quʼune lecture différentielle ne voit pas : objets supprimés, devenus visibles ou invisibles pour ce compte.'
    }else{
        $out.Text='Recensement complet de moins de '+$days+' jours : les disparitions et déplacements de ce périmètre sont à jour à cette date.'
    }
    if($IsDomain -and ($out.State -eq 'Recent')){$out.Text+=' Chaque mise à jour des changements du domaine recense aussi toutes les identités.'}
    return [pscustomobject]$out
}

# ---------------------------------------------------------------- point 30: directory snapshots
function Get-DomeniaSnapshotNotice {
    return 'Un relevé est une copie datée de la base locale pour un périmètre : identité, emplacement et quelques attributs. Il ne contient ni mot de passe, ni droit, ni appartenance de groupe, et ne permet pas de restaurer lʼannuaire. Une disparition entre deux relevés nʼest pas une preuve de suppression.'
}

function ConvertTo-DomeniaSnapshotCoverage {
    # Coverage proof of a snapshot from the freshness of its scope (Get-DomeniaFleetFreshness). Only a complete read
    # covering the scope makes additions and disappearances conclusive.
    param($Coverage)
    $status=[string](Get-DomeniaMember $Coverage 'Status' 'Missing')
    $at=ConvertTo-DomeniaUtcDate (Get-DomeniaMember $Coverage 'At' $null)
    $state='Missing'
    if($status -eq 'Complete'){$state='Complete'}elseif($status -eq 'Partial'){$state='Partial'}elseif($status -eq 'UnknownDepth'){$state='Unknown'}
    if(($state -eq 'Complete') -and ($null -eq $at)){$state='Missing'}
    $source=[string](Get-DomeniaMember $Coverage 'SourceDn' '')
    $text='Couverture : aucune lecture complète de ce périmètre ; le relevé ne contient que les objets déjà connus.'
    if($state -eq 'Complete'){$text='Couverture : lecture complète du '+$at.ToLocalTime().ToString('dd/MM/yyyy HH:mm')+$(if($source){' ('+$source+')'}else{''})+'.'}
    elseif($state -eq 'Partial'){$text='Couverture : la dernière lecture de ce périmètre était incomplète ; ajouts et disparitions non concluants.'}
    elseif($state -eq 'Unknown'){$text='Couverture : profondeur de la dernière lecture inconnue ; ajouts et disparitions non concluants.'}
    return [pscustomobject]@{State=$state;AtUtc=$(if($null -ne $at){$at.ToString('o')}else{''});Source=$source;Text=$text}
}

function New-DomeniaSnapshotRequest {
    # Validated capture request: a scope inside the connected domain, a bounded label, an identifier and the coverage
    # known when the operator asked. The storage worker copies the rows of this scope in one transaction.
    param([AllowEmptyString()][string]$DomainDn,[AllowEmptyString()][string]$ScopeDn,[bool]$Subtree=$true,[AllowEmptyString()][string]$Label='',$Coverage=$null,[Parameter(Mandatory=$true)][string]$SnapshotId,[datetime]$NowUtc=[datetime]::UtcNow)
    $domain=([string]$DomainDn).Trim();$scope=([string]$ScopeDn).Trim()
    if(-not $domain){throw 'Domaine non connecté : relevé impossible.'}
    if(-not $scope){$scope=$domain}
    if(-not (Test-DomeniaDnInScope $scope $domain 'Subtree')){throw 'Périmètre hors du domaine connecté : relevé refusé.'}
    if($SnapshotId -cnotmatch '^[a-f0-9]{32}$'){throw 'Identifiant de relevé invalide.'}
    $name=ConvertTo-DomeniaFlatText $Label 120
    if(-not $name){$name='Relevé du '+$NowUtc.ToLocalTime().ToString('dd/MM/yyyy HH:mm')}
    $proof=ConvertTo-DomeniaSnapshotCoverage $Coverage
    return [pscustomobject]@{
        Action='Capture';SnapshotId=$SnapshotId;Label=$name;DomainDn=$domain;ScopeDn=$scope;Subtree=[bool]$Subtree
        CapturedUtc=$NowUtc.ToUniversalTime().ToString('o');CoverageState=$proof.State;CoverageAtUtc=$proof.AtUtc;CoverageSource=$proof.Source;CoverageText=$proof.Text
    }
}

function ConvertTo-DomeniaSnapshotRow {
    # Display row of one saved snapshot (local base row, column names).
    param($Row)
    $label=[string](Get-DomeniaMember $Row 'label' '')
    $date=Format-DomeniaUtcText (Get-DomeniaMember $Row 'captured_at' '')
    $path=@(Get-DomeniaDnPath ([string](Get-DomeniaMember $Row 'scope_dn' '')))
    $scopeText=if($path.Count){$path -join ' › '}else{'Domaine entier'}
    $subtree=([long](Get-DomeniaMember $Row 'subtree' 1) -ne 0)
    if(-not $subtree){$scopeText+=' (niveau direct)'}
    return [pscustomobject]@{
        SnapshotId=[string](Get-DomeniaMember $Row 'snapshot_id' '');Label=$label;DomainDn=[string](Get-DomeniaMember $Row 'domain_dn' '')
        ScopeDn=[string](Get-DomeniaMember $Row 'scope_dn' '');Subtree=$subtree;CapturedUtc=[string](Get-DomeniaMember $Row 'captured_at' '');DateText=$date
        ObjectCount=[long](Get-DomeniaMember $Row 'object_count' 0);ScopeText=$scopeText;CoverageState=[string](Get-DomeniaMember $Row 'coverage_state' '')
        CoverageText=[string](Get-DomeniaMember $Row 'coverage_text' '');RowsSha256=[string](Get-DomeniaMember $Row 'rows_sha256' '')
        Display=($label+' · '+$date+' · '+$scopeText)
    }
}

function Test-DomeniaSnapshotComparable {
    # Two snapshots compare only on the same domain and the same scope. Coverage that is not complete keeps the
    # comparison possible but makes additions and disappearances inconclusive.
    param($Before,$After)
    $reasons=New-Object 'System.Collections.Generic.List[string]';$warnings=New-Object 'System.Collections.Generic.List[string]'
    if(($null -eq $Before) -or ($null -eq $After)){$reasons.Add('Choisissez deux relevés.')}
    else{
        if([string](Get-DomeniaMember $Before 'SnapshotId' '') -ceq [string](Get-DomeniaMember $After 'SnapshotId' '')){$reasons.Add('Un relevé ne se compare pas à lui-même.')}
        if([string](Get-DomeniaMember $Before 'DomainDn' '') -ine [string](Get-DomeniaMember $After 'DomainDn' '')){$reasons.Add('Domaines différents.')}
        if(([string](Get-DomeniaMember $Before 'ScopeDn' '') -ine [string](Get-DomeniaMember $After 'ScopeDn' '')) -or ([bool](Get-DomeniaMember $Before 'Subtree' $true) -ne [bool](Get-DomeniaMember $After 'Subtree' $true))){$reasons.Add('Périmètres différents : comparez deux relevés du même périmètre.')}
        $first=ConvertTo-DomeniaUtcDate (Get-DomeniaMember $Before 'CapturedUtc' $null);$second=ConvertTo-DomeniaUtcDate (Get-DomeniaMember $After 'CapturedUtc' $null)
        if(($null -ne $first) -and ($null -ne $second) -and ($second -lt $first)){$warnings.Add('Le relevé « après » est plus ancien que le relevé « avant » : les ajouts apparaissent comme des disparitions.')}
        if([string](Get-DomeniaMember $Before 'CoverageState' '') -ne 'Complete'){$warnings.Add('Relevé « avant » sans couverture complète : ajouts et disparitions non concluants.')}
        if([string](Get-DomeniaMember $After 'CoverageState' '') -ne 'Complete'){$warnings.Add('Relevé « après » sans couverture complète : ajouts et disparitions non concluants.')}
    }
    return [pscustomobject]@{Comparable=($reasons.Count -eq 0);Reasons=$reasons.ToArray();Warnings=$warnings.ToArray()}
}

function Get-DomeniaSnapshotFields {
    # Compared values, by local column. whenChanged and lastLogonTimestamp move on their own and are not compared.
    return @(
        [pscustomobject]@{Column='object_type';Label='Type'}
        [pscustomobject]@{Column='name';Label='Nom'}
        [pscustomobject]@{Column='login';Label='Identifiant'}
        [pscustomobject]@{Column='upn';Label='UPN ou nom DNS'}
        [pscustomobject]@{Column='display_name';Label='Nom affiché'}
        [pscustomobject]@{Column='description';Label='Description'}
        [pscustomobject]@{Column='extra';Label='Service, système ou lieu'}
        [pscustomobject]@{Column='state';Label='État du compte'}
    )
}

function ConvertTo-DomeniaSnapshotReport {
    # Readable comparison from the worker answer: exact totals, bounded rows of each kind, coverage and limits.
    # $Result: {Counts={Added;Disappeared;Common;Differing}; Added; Disappeared; Pairs={Before,After}; Limit}.
    param($Result,$Before,$After)
    $rows=New-Object 'System.Collections.Generic.List[object]'
    $scope=[string](Get-DomeniaMember $After 'ScopeDn' '')
    foreach($row in @(Get-DomeniaMember $Result 'Added' @())){
        if($null -eq $row){continue}
        $rows.Add([pscustomobject]@{Nature='Ajout';Nom=[string](Get-DomeniaMember $row 'name' '');Detail=('Présent dans « après » : '+(Get-DomeniaDnLocation ([string](Get-DomeniaMember $row 'distinguished_name' ''))));Avant='';Apres=[string](Get-DomeniaMember $row 'distinguished_name' '');Guid=[string](Get-DomeniaMember $row 'object_guid' '')})
    }
    foreach($row in @(Get-DomeniaMember $Result 'Disappeared' @())){
        if($null -eq $row){continue}
        $rows.Add([pscustomobject]@{Nature='Disparition';Nom=[string](Get-DomeniaMember $row 'name' '');Detail='Absent de « après » : déplacé hors du périmètre, invisible ou supprimé ; non prouvé ici.';Avant=[string](Get-DomeniaMember $row 'distinguished_name' '');Apres='';Guid=[string](Get-DomeniaMember $row 'object_guid' '')})
    }
    $moved=0;$pairCount=0;$changed=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($pair in @(Get-DomeniaMember $Result 'Pairs' @())){
        if($null -eq $pair){continue}
        $pairCount++
        $before=Get-DomeniaMember $pair 'Before' $null;$after=Get-DomeniaMember $pair 'After' $null
        if(($null -eq $before) -or ($null -eq $after)){continue}
        $guid=[string](Get-DomeniaMember $after 'object_guid' '');$name=[string](Get-DomeniaMember $after 'name' '')
        $oldDn=[string](Get-DomeniaMember $before 'distinguished_name' '');$newDn=[string](Get-DomeniaMember $after 'distinguished_name' '')
        if($oldDn -ine $newDn){
            $move=Get-DomeniaDirectoryMove -OldDn $oldDn -NewDn $newDn -ScopeDn $scope
            $rows.Add([pscustomobject]@{Nature=$(if([string]$move.Kind -eq 'Renamed'){'Renommage'}else{'Déplacement'});Nom=$name;Detail=[string]$move.Text;Avant=$oldDn;Apres=$newDn;Guid=$guid})
            $moved++
        }
        foreach($field in @(Get-DomeniaSnapshotFields)){
            $old=[string](Get-DomeniaMember $before $field.Column '');$new=[string](Get-DomeniaMember $after $field.Column '')
            if($old -cne $new){
                $rows.Add([pscustomobject]@{Nature='Valeur modifiée';Nom=$name;Detail=[string]$field.Label;Avant=$old;Apres=$new;Guid=$guid})
                [void]$changed.Add($guid)
            }
        }
    }
    $counts=Get-DomeniaMember $Result 'Counts' $null
    $added=[long](Get-DomeniaMember $counts 'Added' 0);$gone=[long](Get-DomeniaMember $counts 'Disappeared' 0)
    $common=[long](Get-DomeniaMember $counts 'Common' 0);$differing=[long](Get-DomeniaMember $counts 'Differing' 0)
    $limit=[int](Get-DomeniaMember $Result 'Limit' 0)
    $check=Test-DomeniaSnapshotComparable $Before $After
    $lines=New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('« '+[string](Get-DomeniaMember $Before 'Label' '')+' » → « '+[string](Get-DomeniaMember $After 'Label' '')+' » : '+$added+' ajout(s), '+$gone+' disparition(s), '+$differing+' objet(s) déplacé(s) ou modifié(s), '+[Math]::Max([long]0,[long]($common-$differing))+' inchangé(s).')
    if(($limit -gt 0) -and (($added -gt $limit) -or ($gone -gt $limit) -or ($differing -gt $limit))){$lines.Add('Affichage limité à '+$limit+' lignes par catégorie ; les totaux ci-dessus sont exacts.')}
    if($pairCount -ge $differing){$lines.Add('Parmi les objets communs : '+$moved+' déplacement(s) ou renommage(s), '+$changed.Count+' objet(s) aux valeurs modifiées.')}
    foreach($side in @($Before,$After)){$lines.Add('« '+[string](Get-DomeniaMember $side 'Label' '')+' » · '+[string](Get-DomeniaMember $side 'CoverageText' ''))}
    foreach($warning in @($check.Warnings)){$lines.Add('À noter : '+$warning)}
    $lines.Add((Get-DomeniaSnapshotNotice))
    return [pscustomobject]@{Rows=$rows.ToArray();Summary=($lines.ToArray() -join [Environment]::NewLine);Comparable=[bool]$check.Comparable;Reasons=$check.Reasons;Moved=$moved;Changed=$changed.Count}
}
