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
function Set-WReceiptStage {
    param([string]$Stage)
    if($null -eq $script:ReceiptRecord){throw 'Recu d operation non initialise.'}
    $script:ReceiptRecord.Stage=$Stage
    Write-WReceipt $script:ReceiptRecord $script:ReceiptDirectory
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
    $script:ReceiptRecord=[pscustomobject]@{Format=1;CanVerify=$canVerify;Id=[string]$Payload.CorrelationId;Operation=[string]$Context.OperationId;Domain=$domain;Server=[string]$Context.Server;Identity=$identity;DN=$target;Guid=[string]$Payload.Safety.ExpectedGuid;PlanFingerprint=$planFingerprint;Stage='Prepared';CreatedUtc=[datetime]::UtcNow.ToString('o');UpdatedUtc='';Expected=$expected.ToArray();Review=''}
    Write-WReceipt $script:ReceiptRecord $root
}
'@
}
function Get-DomeniaReceiptWorkerCode {
return @'
$root=Get-WReceiptRoot $Context
# Never remove unresolved records. Bounded enumeration refuses ambiguity rather than skipping it.
$files=@([IO.Directory]::EnumerateFiles($root,'*.json')|Select-Object -First 513)
if($files.Count -gt 512){throw 'Trop de recus : archivage manuel des recus termines requis.'}
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
            }else{throw 'Cette operation demande une verification externe explicite, sans rejeu automatique.'}
            Write-WReceipt $r $root
        }finally{$lock.Dispose()}
    }
    $rows.Add([pscustomobject]@{Id=[string]$r.Id;PlanFingerprint=[string]$r.PlanFingerprint;Operation=[string]$r.Operation;DN=[string]$r.DN;Identity=[string]$r.Identity;Server=[string]$r.Server;Stage=[string]$r.Stage;UpdatedUtc=[string]$r.UpdatedUtc;Review=[string]$r.Review})
}
[pscustomobject]@{Rows=$rows.ToArray();Pending=@($rows|Where-Object{$_.Stage -notin @('Verified','NotSent','Reviewed','Delivered')}).Count}
'@
}
