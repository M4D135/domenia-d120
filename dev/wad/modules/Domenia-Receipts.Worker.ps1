function Get-DomeniaReceiptsCommon {
return @'
function Get-WReceiptRoot {
    param($Context)
    if([string]::IsNullOrWhiteSpace([string]$Context.ReceiptRoot)){throw 'Racine des recus absente.'}
    $root=[IO.Path]::GetFullPath([string]$Context.ReceiptRoot)
    if ((-not $root) -or ($root.StartsWith('\\'))) {throw 'Stockage local des recus requis.'}
    $probe=[IO.DirectoryInfo]::new($root)
    while($null -ne $probe){if ((($probe.Exists)) -and ((($probe.Attributes -band [IO.FileAttributes]::ReparsePoint)))) {throw 'Chemin des recus redirige.'};$probe=$probe.Parent}
    [void][IO.Directory]::CreateDirectory($root)
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    # Ne modifier que la DACL : audit, proprietaire et groupe restent inchanges.
    $acl.SetSecurityDescriptorSddlForm(
        ('D:P(A;OICI;FA;;;'+$sid+')(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'),
        [Security.AccessControl.AccessControlSections]::Access
    )
    try { [IO.Directory]::SetAccessControl($root,$acl) }
    catch {
        throw [InvalidOperationException]::new(
            ('DOMENIA_RECEIPT_DACL : impossible de proteger le dossier des recus "' + $root + '". ' + $_.Exception.Message),
            $_.Exception
        )
    }
    return $root
}
function Get-WReceiptHash {
    param([string]$Value)
    $h=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}
}
function Write-WReceipt {
    param($Record,[string]$Root)
    if([string]$Record.Id -notmatch '^[a-f0-9]{32}$'){throw 'Identifiant de recu invalide.'}
    $path=Join-Path $Root ($Record.Id+'.json')
    if (([IO.File]::Exists($path)) -and (((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint))) {throw 'Recu redirige.'}
    $Record.UpdatedUtc=[datetime]::UtcNow.ToString('o')
    $json=$Record|ConvertTo-Json -Depth 5 -Compress
    if($json.Length -gt 65536){throw 'Recu trop volumineux.'}
    $tmp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes($json)
    try {
        $f=[IO.File]::Open($tmp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$f.Write($bytes,0,$bytes.Length);$f.Flush($true)}finally{$f.Dispose()}
        if([IO.File]::Exists($path)){[IO.File]::Replace($tmp,$path,[NullString]::Value,$true)}else{[IO.File]::Move($tmp,$path)}
    }finally{if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}}
}
function Invoke-WReceiptCompaction {
    param([string]$Root,[int]$Keep=256,[int]$Trigger=384)
    # Caller holds writer.lock. Only terminal receipts move; unresolved ones stay in place for resume.
    $all=@([IO.Directory]::EnumerateFiles($Root,'*.json')|Select-Object -First 4097)
    if($all.Count -le $Trigger){return 0}
    if($all.Count -gt 4096){throw 'Trop de recus : verification manuelle requise.'}
    $archive=Join-Path $Root 'archive'
    if (([IO.Directory]::Exists($archive)) -and (((Get-Item -LiteralPath $archive -Force).Attributes -band [IO.FileAttributes]::ReparsePoint))) {throw 'Archive des recus redirigee.'}
    $terminal=[Collections.Generic.List[object]]::new()
    foreach($path in $all){
        $info=[IO.FileInfo]::new($path)
        # Unreadable or redirected files stay where they are: the callers refuse them explicitly.
        if ((($info.Attributes -band [IO.FileAttributes]::ReparsePoint)) -or (($info.Length -gt 65536))) {continue}
        $r=$null
        try{$r=[IO.File]::ReadAllText($path)|ConvertFrom-Json}catch{continue}
        if ((($null -eq $r)) -or (($r.Format -ne 1)) -or (([string]$r.Id -notmatch '^[a-f0-9]{32}$')) -or (([IO.Path]::GetFileNameWithoutExtension($path) -cne [string]$r.Id))) {continue}
        if([string]$r.Stage -notin @('Verified','NotSent','Reviewed','Delivered')){continue}
        $terminal.Add([pscustomobject]@{Path=$path;Name=[IO.Path]::GetFileName($path);Updated=[string]$r.UpdatedUtc})
    }
    $excess=$all.Count-$Keep
    if ((($excess -le 0)) -or (($terminal.Count -eq 0))) {return 0}
    [void][IO.Directory]::CreateDirectory($archive)
    $moved=0
    # Oldest first (UpdatedUtc is round-trip ISO 8601), so the most recent plans keep their duplicate guard.
    foreach($t in @($terminal|Sort-Object Updated,Name|Select-Object -First $excess)){
        $dest=Join-Path $archive $t.Name
        if([IO.File]::Exists($dest)){continue}
        [IO.File]::Move($t.Path,$dest)
        $moved++
    }
    return $moved
}
function Set-WReceiptStage {
    param([string]$Stage)
    if($null -eq $script:ReceiptRecord){throw 'Recu d operation non initialise.'}
    $script:ReceiptRecord.Stage=$Stage
    # Point 49: the local time the request left, kept to compare a later re-read (pwdLastSet) with the send.
    if(($Stage -eq 'Sent') -and ($null -ne $script:ReceiptRecord.PSObject.Properties['SentUtc'])){$script:ReceiptRecord.SentUtc=[datetime]::UtcNow.ToString('o')}
    Write-WReceipt $script:ReceiptRecord $script:ReceiptDirectory
}
function Read-WReceiptObservation {
    # Point 49: re-reads, on the controller that received the write, the state its receipt expects. Reads only; the
    # object is found by its GUID when the receipt has one. A refusal or an unreadable value proves nothing.
    param($Context,$Record)
    $e=$Record.Expectation
    $kind=[string]$e.Kind
    $observed=[pscustomobject]@{ReadStatus='OK';Uac='';Lockout='';PwdLastSet='';AccountExpiresDay='';ParentDn='';Name='';Member=$null;Exists=$null}
    $guid=[string]$Record.Guid
    if ((($guid.StartsWith('{'))) -and (($guid.EndsWith('}')))) {$guid=$guid.Substring(1,$guid.Length-2)}
    $path=[string]$Record.DN;if($guid){$path='<GUID='+$guid+'>'}
    try{
        switch($kind){
            'UacFlags' {
                # userAccountControl left out of the answer is not read: never taken as 0 (every option cleared).
                $value=Get-WAttributeFirst $Context $path 'userAccountControl'
                if($null -ne $value){$observed.Uac=[string]$value}
            }
            'Unlocked' {
                # The unlock wrote lockoutTime=0: an attribute left out of the answer is not read, never taken as 0.
                $value=Get-WAttributeFirst $Context $path 'lockoutTime'
                if($null -ne $value){$observed.Lockout=[string](Convert-WLargeInteger $value)}
            }
            {$_ -in @('PwdLastSetZero','PasswordChangedAfterSend')} {
                # An attribute left out of the answer is not read: never taken as 0.
                $value=Get-WAttributeFirst $Context $path 'pwdLastSet'
                if($null -ne $value){$observed.PwdLastSet=[string](Convert-WLargeInteger $value)}
            }
            'AccountExpires' {
                $value=Get-WAttributeFirst $Context $path 'accountExpires'
                if($null -ne $value){
                    $ticks=Convert-WLargeInteger $value
                    if ((($ticks -eq 0)) -or (($ticks -eq 9223372036854775807))) {$observed.AccountExpiresDay='Jamais'}
                    else{$observed.AccountExpiresDay=[datetime]::FromFileTimeUtc([int64]$ticks).ToLocalTime().Date.ToString('yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)}
                }
            }
            'Parent' {$snap=Get-WObjectSnapshot $Context $path;if([bool]$snap.Exists){$observed.ParentDn=Get-WParentDn ([string]$snap.DN)}}
            'Name' {$snap=Get-WObjectSnapshot $Context $path;if([bool]$snap.Exists){$observed.Name=[string]$snap.Name}}
            'Membership' {
                $groupDn=[string]$e.GroupDn;if(-not $groupDn){$groupDn=Resolve-WGroupDn $Context ([string]$e.GroupValue)}
                $memberDn=[string]$e.MemberDn;if(-not $memberDn){$memberDn=Resolve-WObjectDn $Context ([string]$e.MemberValue)}
                $observed.Member=[bool](Test-WDirectMembership $Context $groupDn $memberDn)
            }
            'Existence' {
                $snap=Get-WObjectSnapshot $Context ('OU='+(Escape-WRdn ([string]$e.Name))+','+[string]$e.ParentDn)
                $observed.Exists=(([bool]$snap.Exists) -and ((@($snap.Classes) -contains 'organizationalUnit')))
            }
            'Absence' {
                if(-not $guid){$observed.ReadStatus='Unavailable'}
                else{$snap=Get-WObjectSnapshot $Context $path;$observed.Exists=[bool]$snap.Exists}
            }
            default {$observed.ReadStatus='NotRead'}
        }
    }catch{
        # A rejected account is shared with every job and stops here; it is never read as an outcome.
        if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
        $ex=$_.Exception;$h=0
        try{$h=[int]$ex.HResult}catch{}
        if (((($h -eq 0) -or ($h -eq -2146233087))) -and (($null -ne $ex.InnerException))) {try{$h=[int]$ex.InnerException.HResult}catch{}}
        $message=[string]$ex.Message;if($null -ne $ex.InnerException){$message+=' '+[string]$ex.InnerException.Message}
        if ((($h -eq -2147016656)) -or (($message -match '(?i)no such object|aucun objet de ce type'))) {
            # 0x80072030: the controller states that the object does not exist.
            if($kind -in @('Absence','Existence')){$observed.Exists=$false}else{$observed.ReadStatus='Unavailable'}
        }elseif ((($h -eq -2147024891)) -or (($message -match '(?i)access is denied|acc.s refus'))) {$observed.ReadStatus='Refused'}
        else{$observed.ReadStatus='Unavailable'}
    }
    return $observed
}
function New-WReceipt {
    param($Context,$Payload)
    $root=Get-WReceiptRoot $Context
    $script:ReceiptDirectory=$root
    $domain=([string]$Context.BaseDn).ToLowerInvariant()
    $identity=if($Context.UseCredential){[string]$Context.BindUser}else{[string]$Context.ProcessIdentity}
    $target=[string]$Payload.DN;if(-not $target){$target=[string]$Payload.Safety.ExpectedDn}
    $planFingerprint=''
    if ((($null -ne $Payload)) -and ((($null -ne $Payload.PSObject.Properties['PlanFingerprint'])))) { $planFingerprint=[string]$Payload.PlanFingerprint }
    $expected=[Collections.Generic.List[object]]::new()
    if($Context.OperationId -eq 'WriteAttributes'){
        foreach($c in @($Payload.Changes)){
            if ((([string]$c.Name -match '(?i:password|pwd|msfve|secret|token|credential|key)')) -or (([string]$c.Name -notmatch '^[A-Za-z][A-Za-z0-9-]{0,126}$'))) {continue}
            $expected.Add([pscustomobject]@{Name=[string]$c.Name;Clear=[bool]$c.Clear;Hash=(Get-WReceiptHash ([string]$c.New))})
        }
    }
    $canVerify=((($Context.OperationId -eq 'WriteAttributes')) -and (($expected.Count -gt 0)) -and (($expected.Count -eq @($Payload.Changes).Count)))
    # Point 49: every other directory write keeps the state to re-read later (shared rule, no secret value).
    $expectation=$null
    if($Context.OperationId -ne 'WriteAttributes'){$expectation=Get-DomeniaReceiptExpectation -OperationId ([string]$Context.OperationId) -Payload $Payload}
    if($null -ne $expectation){$canVerify=$true}
    $script:ReceiptRecord=[pscustomobject]@{Format=1;CanVerify=$canVerify;Expectation=$expectation;SentUtc='';Id=[string]$Payload.CorrelationId;Operation=[string]$Context.OperationId;Domain=$domain;Server=[string]$Context.Server;Identity=$identity;DN=$target;Guid=[string]$Payload.Safety.ExpectedGuid;PlanFingerprint=$planFingerprint;Stage='Prepared';CreatedUtc=[datetime]::UtcNow.ToString('o');UpdatedUtc='';Expected=$expected.ToArray();Review=''}
    Write-WReceipt $script:ReceiptRecord $root
}
'@
}
function Get-DomeniaReceiptWorkerCode {
return @'
$root=Get-WReceiptRoot $Context
# Never remove unresolved records. Terminal receipts beyond the working set move to archive\ under the writer lock.
$files=@([IO.Directory]::EnumerateFiles($root,'*.json')|Select-Object -First 513)
if($files.Count -gt 384){
    $compactLock=[IO.File]::Open((Join-Path $root 'writer.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{$null=Invoke-WReceiptCompaction $root}finally{$compactLock.Dispose()}
    $files=@([IO.Directory]::EnumerateFiles($root,'*.json')|Select-Object -First 513)
}
if($files.Count -gt 512){throw 'Plus de 512 recus non resolus : verification manuelle requise.'}
$rows=[Collections.Generic.List[object]]::new()
foreach($path in $files){
    $item=Get-Item -LiteralPath $path -Force
    if ((($item.Length -gt 65536)) -or ((($item.Attributes -band [IO.FileAttributes]::ReparsePoint)))) {throw 'Recu invalide : verification manuelle requise.'}
    $r=[IO.File]::ReadAllText($path)|ConvertFrom-Json
    if ((($r.Format -ne 1)) -or (([string]$r.Id -notmatch '^[a-f0-9]{32}$')) -or (([IO.Path]::GetFileNameWithoutExtension($path) -cne [string]$r.Id))) {throw 'Recu non reconnu : aucune mutation autorisee.'}
    if([string]$r.Domain -ine [string]$Context.BaseDn){continue}
    if ((($Payload.Action -in @('Verify','Review'))) -and (([string]$Payload.Id -ceq [string]$r.Id))) {
        $lock=[IO.File]::Open((Join-Path $root 'writer.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try{
            # Re-read under the writer lock: never overwrite a newer terminal receipt.
            $latest=Get-Item -LiteralPath $path -Force
            if ((($latest.Length -gt 65536)) -or ((($latest.Attributes -band [IO.FileAttributes]::ReparsePoint)))) {throw 'Recu invalide apres prise du verrou.'}
            $r=[IO.File]::ReadAllText($path)|ConvertFrom-Json
            if ((($r.Format -ne 1)) -or (([string]$r.Id -cne [string]$Payload.Id)) -or (([string]$r.Domain -ine [string]$Context.BaseDn))) {throw 'Recu modifie pendant la verification.'}
            if($r.Stage -in @('Verified','NotSent','Reviewed','Delivered')){throw 'Le recu a deja ete resolu. Actualisez la liste.'}
            if($Payload.Action -eq 'Review'){
                if (((([string]$Payload.Reason).Length -lt 12)) -or ((([string]$Payload.Reason).Length -gt 240))) {throw 'Motif de verification externe requis (12 a 240 caracteres).'}
                $r.Stage='Reviewed';$r.Review=[string]$Payload.Reason
            }elseif ((($r.Operation -eq 'WriteAttributes')) -and ((($r.CanVerify -eq $true))) -and ((@($r.Expected).Count -gt 0))) {
                $ctx=$Context.PSObject.Copy();$ctx.Server=[string]$r.Server
                $snap=Get-WObjectSnapshot $ctx ([string]$r.DN)
                if(-not $snap.Exists -or $snap.Guid -ine [string]$r.Guid){throw 'Cible non confirmee. Le recu reste a verifier.'}
                foreach($c in @($r.Expected)){
                    $value=Get-WAttributeFirst $ctx ([string]$r.DN) ([string]$c.Name)
                    if($c.Clear){if(-not [string]::IsNullOrEmpty([string]$value)){throw 'Effacement non confirme.'}}
                    elseif((Get-WReceiptHash ([string]$value)) -cne [string]$c.Hash){throw 'Valeur attendue non confirmee. Aucun rejeu.'}
                }
                $r.Stage='Verified';$r.Review='Postconditions relues sur le controleur initial.'
            }elseif((($null -ne $r.PSObject.Properties['Expectation'])) -and (($null -ne $r.Expectation))){
                # Point 49: the effective state is re-read on the initial controller and judged by the shared rule.
                $ctx=$Context.PSObject.Copy();$ctx.Server=[string]$r.Server
                $observed=Read-WReceiptObservation $ctx $r
                $sent='';if($null -ne $r.PSObject.Properties['SentUtc']){$sent=[string]$r.SentUtc}
                $check=Resolve-DomeniaReceiptCheck -Expectation $r.Expectation -Observed $observed -SentUtc $sent
                if(-not [bool]$check.Verified){throw ('Etat effectif non confirme : '+[string]$check.Reason+' Le recu reste a verifier ; aucun rejeu.')}
                $r.Stage='Verified';$r.Review=('Etat relu sur le controleur initial : '+[string]$check.Reason)
            }else{throw 'Cette operation demande une verification externe explicite, sans rejeu automatique.'}
            Write-WReceipt $r $root
        }finally{$lock.Dispose()}
    }
    $rows.Add([pscustomobject]@{Id=[string]$r.Id;PlanFingerprint=[string]$r.PlanFingerprint;Operation=[string]$r.Operation;DN=[string]$r.DN;Identity=[string]$r.Identity;Server=[string]$r.Server;Stage=[string]$r.Stage;UpdatedUtc=[string]$r.UpdatedUtc;Review=[string]$r.Review})
}
[pscustomobject]@{Rows=$rows.ToArray();Pending=@($rows|Where-Object{$_.Stage -notin @('Verified','NotSent','Reviewed','Delivered')}).Count}
'@
}
