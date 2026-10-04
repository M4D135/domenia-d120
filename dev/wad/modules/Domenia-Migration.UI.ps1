# D113: explicit legacy-store migration. Reads never create or initialize a database.
function ConvertTo-DomeniaLegacyNumber {
    param([string]$Text,[long]$Maximum=[int]::MaxValue)
    if ([string]::IsNullOrWhiteSpace($Text)) { return [long]0 }
    $value=[long]0
    if (-not [long]::TryParse($Text,[Globalization.NumberStyles]::Integer,[Globalization.CultureInfo]::InvariantCulture,[ref]$value) -or $value -lt 0 -or $value -gt $Maximum) { throw 'Nombre historique invalide.' }
    return $value
}
function ConvertTo-DomeniaLegacyDate {
    param([string]$Text,[switch]$Required)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        if ($Required) { throw 'Date historique absente.' }
        return ''
    }
    $value=[datetime]::MinValue
    if (-not [datetime]::TryParse($Text,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$value)) { throw 'Date historique invalide.' }
    return $value.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
}
function Read-DomeniaLegacySource {
    # The same locked file supplies its hash and its rows. A writer cannot alter it between these reads.
    param([string]$Path,[ValidateSet('Objets','Parc','Recherches','Secrets','Liens')][string]$Kind)
    $rows=[Collections.Generic.List[object]]::new();$rejected=0;$count=0
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $reader=$null
    try {
        if ($stream.Length -gt 128MB) { throw ('Fichier historique trop volumineux : '+[IO.Path]::GetFileName($Path)) }
        $hash=[Security.Cryptography.SHA256]::Create()
        try { $sha=[BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-','').ToLowerInvariant() } finally { $hash.Dispose() }
        $stream.Position=0
        if ($Kind -eq 'Liens') {
            Import-Csv -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop | ForEach-Object {
                $count++
                if ($count -gt 250000) { throw 'Plus de 250000 lignes dans une source historique.' }
                try {
                    $computer=Normalize-LinkComputer ([string]$_.Computer);$user=Normalize-LinkUser ([string]$_.UserLogin)
                    if (-not $computer -or -not $user) { throw 'Association incomplete.' }
                    $verified=$false;$flag=[string]$_.VerifiedInAD
                    if ($flag -eq '1') { $verified=$true }
                    elseif ($flag -ne '' -and $flag -ne '0' -and (-not [bool]::TryParse($flag,[ref]$verified))) { throw 'Indicateur historique invalide.' }
                    $rows.Add([pscustomobject]@{
                        UserLogin=$user;Computer=$computer;Source=[string]$_.Source
                        Confidence=[int](ConvertTo-DomeniaLegacyNumber ([string]$_.Confidence) 100);VerifiedInAD=$verified
                        When=(ConvertTo-DomeniaLegacyDate ([string]$_.When) -Required);Details=[string]$_.Details
                        UserGuid=[string]$_.UserGuid;ComputerGuid=[string]$_.ComputerGuid;UserDn=[string]$_.UserDn;ComputerDn=[string]$_.ComputerDn
                    })
                } catch { $rejected++ }
            }
        } else {
            $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true,4096,$true)
            while ($null -ne ($line=$reader.ReadLine())) {
                $count++
                if ($count -gt 250001) { throw 'Plus de 250000 lignes dans une source historique.' }
                if (-not $line.Trim()) { continue }
                $f=$line.Split([char]9)
                if ($count -eq 1 -and (($Kind -eq 'Objets' -and $f[0] -eq 'Type') -or ($Kind -in @('Parc','Secrets') -and $f[0] -eq 'Computer') -or ($Kind -eq 'Recherches' -and $f[0] -eq 'Login'))) { continue }
                try {
                    $row=$null
                    switch ($Kind) {
                        'Objets' {
                            if ($f.Length -lt 9 -or [string]::IsNullOrWhiteSpace($f[8])) { throw 'Objet incomplet.' }
                            $row=[pscustomobject]@{Type=$f[0];Name=$f[1];Login=$f[2];Upn=$f[3];Display=$f[4];Description=$f[5];Extra=$f[6];State=$f[7];DN=$f[8].Trim();WhenChanged='';Usn=[long]0;LastLogon='';Guid=''}
                            if ($f.Length -ge 10) { $row.WhenChanged=ConvertTo-DomeniaLegacyDate $f[9] }
                            if ($f.Length -ge 11) { $row.Usn=ConvertTo-DomeniaLegacyNumber $f[10] ([long]::MaxValue) }
                            if ($f.Length -ge 12) { $row.LastLogon=ConvertTo-DomeniaLegacyDate $f[11] }
                            if ($f.Length -ge 13) { $row.Guid=$f[12] }
                        }
                        'Parc' {
                            if ($f.Length -lt 4) { throw 'Etat parc incomplet.' }
                            $computer=Normalize-LinkComputer $f[0]
                            if (-not $computer) { throw 'Poste absent.' }
                            $attempts=0;if ($f.Length -ge 5) { $attempts=ConvertTo-DomeniaLegacyNumber $f[4] }
                            $row=[pscustomobject]@{Key=$computer.ToUpperInvariant();Computer=$computer;LastProbe=(ConvertTo-DomeniaLegacyDate $f[1]);Status=$f[2];User=$f[3];Attempts=[int]$attempts}
                        }
                        'Recherches' {
                            if ($f.Length -lt 7 -or -not $f[0].Trim() -or $f[2] -notin @('0','1')) { throw 'Recherche incomplete.' }
                            $row=[pscustomobject]@{Login=$f[0].Trim();At=(ConvertTo-DomeniaLegacyDate $f[1]);Scanned=($f[2] -eq '1');Candidates=[int](ConvertTo-DomeniaLegacyNumber $f[3]);Reachable=[int](ConvertTo-DomeniaLegacyNumber $f[4]);Probed=[int](ConvertTo-DomeniaLegacyNumber $f[5]);Found=$f[6]}
                        }
                        'Secrets' {
                            if ($f.Length -lt 8) { throw 'Metadonnees incompletes.' }
                            $computer=Normalize-LinkComputer $f[0]
                            if (-not $computer) { throw 'Poste absent.' }
                            # Never import the free-form detail column: only the known metadata fields.
                            $row=[pscustomobject]@{Computer=$computer;At=(ConvertTo-DomeniaLegacyDate $f[1]);BitLockerKeys=[int](ConvertTo-DomeniaLegacyNumber $f[2]);BitLockerLast=(ConvertTo-DomeniaLegacyDate $f[3]);LapsScheme=$f[4];LapsExpiry=(ConvertTo-DomeniaLegacyDate $f[5]);Verdict=$f[6]}
                        }
                    }
                    $rows.Add($row)
                } catch { $rejected++ }
            }
        }
        if ($rows.Count -gt 250000) { throw 'Plus de 250000 lignes dans une source historique.' }
        return [pscustomobject]@{Kind=$Kind;Path=$Path;Sha256=$sha;Rows=$rows.ToArray();Rejected=$rejected}
    } finally { if ($null -ne $reader) { $reader.Dispose() };$stream.Dispose() }
}
function Get-DomeniaLegacySnapshot {
    param([string]$LocalAppData=$env:LOCALAPPDATA)
    $roots=[Collections.Generic.List[string]]::new()
    if ($script:DataDir) { $roots.Add([IO.Path]::GetFullPath([string]$script:DataDir)) }
    if ($LocalAppData) { $roots.Add((Join-Path $LocalAppData 'DOMENIA')) }
    $names=[ordered]@{Objets='Index\objets.tsv';Parc='Index\parc.tsv';Recherches='Index\recherches.tsv';Secrets='Index\secrets-etat.tsv';Liens='Domenia-user-machine-links.csv'}
    $sources=[Collections.Generic.List[object]]::new();$data=@{};$rejected=0;$domains=@{}
    foreach ($kind in $names.Keys) {
        $data[$kind]=@()
        foreach ($root in $roots) {
            $path=Join-Path $root $names[$kind]
            if (-not [IO.File]::Exists($path)) { continue }
            $source=Read-DomeniaLegacySource -Path $path -Kind $kind
            $sources.Add($source);$data[$kind]=@($source.Rows);$rejected+=$source.Rejected
            break
        }
    }
    foreach ($row in $data.Objets) {
        $match=[regex]::Match([string]$row.DN,'(?i)(?:^|,)\s*(DC=[^,=\s]+(?:\s*,\s*DC=[^,=\s]+)*)$')
        if (-not $match.Success) { throw 'Domaine non identifiable dans les objets historiques.' }
        $dn=($match.Groups[1].Value -split ',' | ForEach-Object { $_.Trim() }) -join ','
        $domain=ConvertTo-DomeniaMigrationDomain $dn
        $domains[$domain]=$dn
        $row.DN=([string]$row.DN).Substring(0,$match.Index)+$(if ($match.Index -gt 0) { ',' } else { '' })+$dn
    }
    if ($domains.Count -gt 1) { throw 'Plusieurs domaines dans les objets historiques : reprise refusee.' }
    $baseDn='';if ($domains.Count -eq 1) { $baseDn=[string]@($domains.Values)[0] }
    # Always use the Relations rule, independent of feature flags or multi-relation display mode.
    $groups=@{}
    foreach ($link in $data.Liens) {
        $key=([string]$link.Computer).ToUpperInvariant()
        if (-not $groups.ContainsKey($key)) { $groups[$key]=[Collections.Generic.List[object]]::new() }
        $groups[$key].Add($link)
    }
    $links=[Collections.Generic.List[object]]::new()
    foreach ($key in @($groups.Keys | Sort-Object)) {
        $link=Select-DomeniaPrimaryRelation -Relations $groups[$key].ToArray()
        $origin=[string]$link.Source
        $link.Details=('Reprise historique ; source d origine : '+$origin+'. '+[string]$link.Details).Trim()
        $link.Source='Import CSV'
        $links.Add($link)
    }
    $data.Liens=$links.ToArray()
    foreach ($kind in @('Objets','Parc','Recherches','Secrets')) {
        $keys=@{}
        foreach ($row in @($data[$kind])) {
            $key=switch ($kind) {
                'Objets' { if ([string]$row.Guid) { [string]$row.Guid } else { ([string]$row.Type)+'|'+([string]$row.DN) } }
                'Parc' { [string]$row.Key }
                'Recherches' { [string]$row.Login }
                'Secrets' { [string]$row.Computer }
            }
            if ($keys.ContainsKey($key)) { throw ('Doublon dans les donnees '+$kind+'. Corrigez la source avant reprise.') }
            $keys[$key]=$true
        }
    }
    $marker=Get-DomeniaTextHash ((@($sources | ForEach-Object { $_.Kind+'|'+$_.Path+'|'+$_.Sha256 }) -join [Environment]::NewLine))
    return [pscustomobject]@{Data=$data;Sources=$sources.ToArray();BaseDn=$baseDn;Marker=$marker;Rejected=$rejected}
}
function New-DomeniaLegacyImportPlan {
    param([string]$LocalAppData=$env:LOCALAPPDATA)
    $path=[string]$script:DatabaseScopedPath
    if (-not $path -or -not [IO.File]::Exists($path)) { throw 'Base du contexte non disponible : reprise impossible.' }
    $snapshot=Get-DomeniaLegacySnapshot -LocalAppData $LocalAppData
    $db=Open-DomeniaDatabase -Path $path -ReadOnly
    try {
        $tables=[ordered]@{}
        foreach ($table in @('ad_objects','park_state','user_scan_history','secret_state','user_machine_links')) {
            $tables[$table]=[long](@(Invoke-DomeniaDbQuery ("SELECT count(*) AS n FROM "+$table+';') $db)[0].n)
        }
        $links=@(Invoke-DomeniaDbQuery 'SELECT computer AS Computer FROM user_machine_links ORDER BY computer_key;' $db)
        $sync=@(Invoke-DomeniaDbQuery "SELECT scope,base_dn,details FROM sync_state WHERE scope IN ('directory','legacy_import') ORDER BY scope;" $db)
        $schema=@(Invoke-DomeniaDbQuery "SELECT key,value FROM schema_info WHERE key IN ('schema_version','domenia_schema') ORDER BY key;" $db)
    } finally { Close-DomeniaDatabase $db }
    $marker='';$directoryDn='';$version='';$revision=''
    foreach ($row in $sync) {
        if ($row.scope -eq 'legacy_import') { $marker=([string]$row.details) -replace '^marker=','' }
        if ($row.scope -eq 'directory') { $directoryDn=[string]$row.base_dn }
    }
    foreach ($row in $schema) { if ($row.key -eq 'schema_version') { $version=[string]$row.value } else { $revision=[string]$row.value } }
    $stores=@($snapshot.Sources | ForEach-Object { [pscustomobject]@{Kind=$_.Kind;Path=$_.Path;Rows=@($snapshot.Data[$_.Kind]).Count;Links=$(if ($_.Kind -eq 'Liens') { @($snapshot.Data.Liens) } else { @() })} })
    $legacy=[pscustomobject]@{Domain=$snapshot.BaseDn;ConfigFiles=@();Stores=$stores;Marker=$snapshot.Marker}
    $current=[pscustomobject]@{Domain=[string]$script:Conn.BaseDn;ConfigFiles=@();Tables=$tables;Links=$links;MigrationMarker=$marker;Database=[pscustomobject]@{Name=[IO.Path]::GetFileName($path);SchemaVersion=$version;DomeniaSchema=$revision;BaseDn=$directoryDn}}
    $plan=Get-DomeniaMigrationPlan $legacy $current -Trigger Explicit
    if (-not (Test-DomeniaMigrationIdempotent $legacy $current -Trigger Explicit).Idempotent) { throw 'La simulation ne garantit pas une reprise sans doublons.' }
    if ($directoryDn -and (ConvertTo-DomeniaMigrationDomain $directoryDn) -ne (ConvertTo-DomeniaMigrationDomain ([string]$script:Conn.BaseDn))) { throw 'Le domaine de la base differe du contexte courant.' }
    if ($revision -ne '1') { throw 'Base non preparee pour Domenia : reprise refusee.' }
    $fingerprint=Get-DomeniaTextHash (([ordered]@{Marker=$snapshot.Marker;Path=$path;Epoch=[long]$script:SessionEpoch;Domain=$current.Domain;Tables=$tables;Links=$links;Sync=$sync;Schema=$schema}) | ConvertTo-Json -Depth 8 -Compress)
    $payload=[pscustomobject]@{Marker=$snapshot.Marker;BaseDn=$snapshot.BaseDn;At=[datetime]::UtcNow.ToString('o');Objects=@($snapshot.Data.Objets);Park=@($snapshot.Data.Parc);UserScans=@($snapshot.Data.Recherches);Secrets=@($snapshot.Data.Secrets);Links=@($snapshot.Data.Liens)}
    $plan | Add-Member -NotePropertyMembers @{Fingerprint=$fingerprint;Path=$path;Epoch=[long]$script:SessionEpoch;Payload=$payload;Sources=$snapshot.Sources;RejectedLines=$snapshot.Rejected;Queued=$false}
    return $plan
}
function Invoke-DomeniaLegacyImport {
    param([switch]$DryRun,[string]$ExpectedFingerprint='')
    $plan=New-DomeniaLegacyImportPlan
    if ($DryRun) { return $plan }
    if ($ExpectedFingerprint -and $plan.Fingerprint -cne $ExpectedFingerprint) { throw 'Les donnees ou le contexte ont change. Refaites la simulation.' }
    if (-not $plan.Allowed) { throw ($plan.Blockers -join [Environment]::NewLine) }
    if ($plan.WriteCount -eq 0) { return $plan }
    if ($null -eq $script:Persistence) { Initialize-DomeniaPersistence }
    if ($script:Persistence.LinkBusy -or $script:Persistence.Job -or $script:Persistence.InFlight -or $script:Persistence.LegacyImportJob) { throw 'Un enregistrement est en cours. Attendez sa fin puis refaites la simulation.' }
    if (@($script:Persistence.Pending.Values | Where-Object { $_.Kind -in @('Link','IndexBulk','LegacyImport') }).Count -or @($script:AsyncJobs.Values | Where-Object { $_.OperationId -in @('LocalStore','LiveCache','IndexBuild') }).Count -or @($script:DetachedReadJobs | Where-Object { $_.OperationId -in @('LocalStore','LiveCache','IndexBuild') }).Count) { throw 'Une ecriture locale est en attente. Refaites la simulation apres son enregistrement.' }
    if ([string](Get-DomeniaDatabasePath) -cne [string]$plan.Path) { throw 'Base du contexte modifiee : reprise annulee.' }
    $backup=Backup-DomeniaDatabase -Migration
    if (-not $backup -or -not [IO.File]::Exists([string]$backup)) { throw 'Sauvegarde de migration non confirmee : rien ne sera importe.' }
    if (-not (Queue-DomeniaMetadata -Kind LegacyImport -Row $plan.Payload -Key 'legacy')) { throw 'Reprise non admise dans la file locale.' }
    $plan.Queued=$true
    foreach ($entry in $plan.Trace) { Write-AppLog ('Reprise de donnees : '+$entry.Ancien+' vers '+$entry.Nouveau+' ; '+$entry.Decision) 'INFO' }
    Set-Status 'Reprise des anciennes donnees en attente d enregistrement.'
    return $plan
}
function Show-DomeniaLegacyImportPlan {
    param($plan)
    try {
        $lines=[Collections.Generic.List[string]]::new()
        $lines.Add('Reprise des anciennes donnees dans Domenia.')
        $lines.Add('Objets : '+$plan.Payload.Objects.Count+' ; postes : '+$plan.Payload.Park.Count+' ; recherches : '+$plan.Payload.UserScans.Count+' ; metadonnees : '+$plan.Payload.Secrets.Count+'.')
        $lines.Add('Associations a ajouter : '+$plan.AddCount+' ; associations existantes conservees : '+$plan.KeepCount+'.')
        $lines.Add('Lignes invalides ignorees : '+$plan.RejectedLines+'. Les fichiers sources restent conserves.')
        $lines.Add('Associations importees protegees sous Import CSV ; source d origine conservee dans le detail.')
        foreach ($source in $plan.Sources) { $lines.Add('Source : '+$source.Path) }
        foreach ($blocker in $plan.Blockers) { $lines.Add('Blocage : '+$blocker) }
        $message=$lines.ToArray() -join [Environment]::NewLine
        if (-not $plan.Allowed -or $plan.WriteCount -eq 0) {
            $script:LegacyImportPreview=$null
            [void](Set-DomeniaControlText 'LblGuardMigration' ($message+[Environment]::NewLine+'Aucune reprise proposee.'))
            Set-Status $(if ($plan.Already) { 'Anciennes donnees deja reprises : rien a importer.' } elseif (-not $plan.Allowed) { 'Reprise bloquee : consultez la simulation dans Fiabilite.' } else { 'Rien a ajouter : consultez la simulation.' })
            return
        }
        $script:LegacyImportPreview=[pscustomobject]@{Fingerprint=$plan.Fingerprint;Path=$plan.Path;Epoch=$plan.Epoch}
        [void](Set-DomeniaControlText 'LblGuardMigration' $message)
        $confirmation=('Sauvegarder la base puis appliquer cette reprise ?'+[Environment]::NewLine+$message)
        [void](Request-DomeniaInlineConfirmation -Title 'Reprendre les anciennes donnees' -Message $confirmation -Target ('migration|'+$plan.Path) -ConfirmText 'Oui, reprendre' -CancelText 'Non' -OnConfirm {
            $preview=$script:LegacyImportPreview;$script:LegacyImportPreview=$null
            if ($null -eq $preview -or $preview.Epoch -ne [long]$script:SessionEpoch -or $preview.Path -cne [string]$script:DatabaseScopedPath) { throw 'Contexte modifie : refaites la simulation.' }
            Start-DomeniaLegacyImportWork -Mode Prepare -ExpectedFingerprint $preview.Fingerprint
        } -OnCancel { $script:LegacyImportPreview=$null;Set-Status 'Reprise annulee : aucune donnee importee.' })
    } catch { Set-Status ('Reprise impossible : '+$_.Exception.Message) 'ERROR';Write-AppLog ('Reprise impossible : '+$_.Exception.Message) 'ERROR' }
}
function Request-DomeniaLegacyImport {
    try { Start-DomeniaLegacyImportWork -Mode Preview }
    catch { Set-Status ('Simulation impossible : '+$_.Exception.Message) 'ERROR' }
}
function Start-DomeniaLegacyImportWork {
    param([ValidateSet('Preview','Prepare')][string]$Mode,[string]$ExpectedFingerprint='')
    if (@($script:AsyncJobs.Values | Where-Object { $_.OperationId -in @('LegacyMigration','LocalStore','LiveCache','IndexBuild') }).Count -or @($script:DetachedReadJobs | Where-Object { $_.OperationId -in @('LegacyMigration','LocalStore','LiveCache','IndexBuild') }).Count) { throw 'Une operation locale est en cours. Attendez sa fin puis relancez la simulation.' }
    if ($Mode -eq 'Prepare' -and $null -ne $script:Persistence -and ($script:Persistence.LinkBusy -or @($script:Persistence.Pending.Values | Where-Object { $_.Kind -in @('Link','IndexBulk','LegacyImport') }).Count)) { throw 'Des modifications sont en attente. Refaites la simulation apres leur enregistrement.' }
    [void](Initialize-DomeniaWinSqliteNative)
    $token=[guid]::NewGuid().ToString('N')
    $payload=[pscustomobject]@{Mode=$Mode;ExpectedFingerprint=$ExpectedFingerprint;Path=[string]$script:DatabaseScopedPath;DataDir=[string]$script:DataDir;LocalAppData=[string]$env:LOCALAPPDATA;BaseDn=[string]$script:Conn.BaseDn;Epoch=[long]$script:SessionEpoch;BackupTimeoutSeconds=[int](Get-CfgValue 'LocalStore' 'BackupTimeoutSeconds' 30)}
    $state=[pscustomobject]@{Token=$token;Mode=$Mode;Path=$payload.Path;Epoch=$payload.Epoch}
    $script:LegacyImportWork=$state
    try {
        $id=Start-UiTask -Name 'Preparer la reprise des anciennes donnees' -OperationId 'LegacyMigration' -Code (Get-DomeniaMigrationWorkerCode) -Payload $payload -CallbackState $state -SuccessHandler 'Complete-DomeniaLegacyImportWork' -ErrorHandler 'Fail-DomeniaLegacyImportWork' -NonCancellable:($Mode -eq 'Prepare') -TimeoutSeconds 600 -TaskClass 'Explicit'
        if (-not $id) { throw 'Preparation non admise dans le moteur.' }
        Set-Status $(if ($Mode -eq 'Preview') { 'Simulation des anciennes donnees en cours.' } else { 'Verification de la simulation et sauvegarde en cours.' })
    } catch { $script:LegacyImportWork=$null;throw }
}
function Complete-DomeniaLegacyImportWork {
    param($Result,$State)
    if ($null -eq $script:LegacyImportWork -or $script:LegacyImportWork.Token -cne $State.Token) { return }
    try {
    if ($State.Epoch -ne [long]$script:SessionEpoch -or $State.Path -cne [string]$script:DatabaseScopedPath) { Set-Status 'Contexte modifie : simulation retiree.';return }
    $plan=Get-DomeniaEffectiveWorkerResult $Result @('Allowed','Fingerprint')
    if ($null -eq $plan) { throw 'Preparation de reprise non confirmee.' }
    if ($State.Mode -eq 'Preview') { Show-DomeniaLegacyImportPlan $plan;return }
    if (-not $plan.Allowed) { throw ($plan.Blockers -join [Environment]::NewLine) }
    if ($plan.WriteCount -eq 0) { Set-Status 'Aucune donnee supplementaire a reprendre.';return }
    if (-not $plan.BackupPath -or -not [IO.File]::Exists([string]$plan.BackupPath)) { throw 'Sauvegarde de reprise non confirmee.' }
    if ($null -ne $script:Persistence -and @($script:Persistence.Pending.Values | Where-Object { $_.Kind -in @('Link','IndexBulk','LegacyImport') }).Count) { throw 'Des donnees ont change pendant la preparation. Refaites la simulation.' }
    if (-not (Queue-DomeniaMetadata -Kind LegacyImport -Row $plan.Payload -Key 'legacy')) { throw 'Reprise non admise dans la file locale. Refaites la simulation.' }
    foreach ($entry in $plan.Trace) { Write-AppLog ('Reprise de donnees : '+$entry.Ancien+' vers '+$entry.Nouveau+' ; '+$entry.Decision) 'INFO' }
    Set-Status 'Reprise des anciennes donnees en attente d enregistrement.'
    } catch { Fail-DomeniaLegacyImportWork $_.Exception.Message $State }
    finally { if ($null -ne $script:LegacyImportWork -and $script:LegacyImportWork.Token -ceq $State.Token) { $script:LegacyImportWork=$null } }
}

function Fail-DomeniaLegacyImportWork {
    param($Message,$State)
    if ($null -eq $script:LegacyImportWork -or $script:LegacyImportWork.Token -cne $State.Token) { return }
    $script:LegacyImportWork=$null
    if ($State.Epoch -ne [long]$script:SessionEpoch -or $State.Path -cne [string]$script:DatabaseScopedPath) { return }
    Set-Status ('Preparation impossible, sans rejeu automatique : '+[string]$Message) 'ERROR'
    Write-AppLog ('Preparation de reprise impossible : '+[string]$Message) 'ERROR'
}
