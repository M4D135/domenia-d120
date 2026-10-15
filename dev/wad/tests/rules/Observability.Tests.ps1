# W13 (points 118, 121, 123, 124) : traces des operations, lenteurs expliquees, diagnostic expurge. Donnees fictives.
Test-Case 'P123' 'Identifiant de trace : explicite, puis demande en cours, puis contexte, puis correlation' {
    $corr='0123456789abcdef0123456789abcdef'
    Assert-Equal 'explicit-0001' (Resolve-DomeniaTraceId -Requested 'explicit-0001' -Ambient 'ambient-0001' -ContextRequestId 'context-0001' -CorrelationId $corr)
    Assert-Equal 'ambient-0001' (Resolve-DomeniaTraceId -Requested '' -Ambient 'ambient-0001' -ContextRequestId 'context-0001' -CorrelationId $corr)
    Assert-Equal 'context-0001' (Resolve-DomeniaTraceId -Ambient '' -ContextRequestId 'context-0001' -CorrelationId $corr)
    Assert-Equal $corr (Resolve-DomeniaTraceId -CorrelationId $corr)
    Assert-Equal $corr (Resolve-DomeniaTraceId -Requested 'nom de poste PC-01' -Ambient 'x' -CorrelationId $corr) 'Une valeur qui n est pas un identifiant est ignoree'
    Assert-Equal '' (Resolve-DomeniaTraceId)
    Assert-Equal '01234567' (Get-DomeniaTraceReference $corr)
    Assert-Equal '11111111' (Get-DomeniaTraceReference '11111111-2222-3333-4444-555555555555')
    Assert-Throws { New-DomeniaOperationTrace -TraceId 'court' }
}
Test-Case 'P123' 'Une demande relie collecte, validation, lecture locale et publication sous un seul identifiant' {
    $t=New-DomeniaOperationTrace -TraceId '11111111-2222-3333-4444-555555555555' -OperationId 'GlobalSearch' -Name 'Recherche dans l annuaire' -AtMs 1000
    [void](Add-DomeniaTraceJob -Trace $t -JobRef 'aaaaaaaa0000' -IsWrite $false)
    [void](Add-DomeniaOperationTraceEvent -Trace $t -Phase 'Request' -AtMs 1000 -Detail 'GlobalSearch' -JobRef 'aaaaaaaa')
    [void](Add-DomeniaOperationTraceEvent -Trace $t -Phase 'StoreRead' -AtMs 1500 -Volume 100 -DurationMs 40)
    [void](Add-DomeniaOperationTraceEvent -Trace $t -Phase 'StoreRead' -AtMs 1700 -Volume 150 -DurationMs 60)
    [void](Add-DomeniaOperationTraceEvent -Trace $t -Phase 'Collect' -AtMs 1010 -DurationMs 2300 -JobRef 'aaaaaaaa')
    [void](Add-DomeniaOperationTraceEvent -Trace $t -Phase 'Validate' -AtMs 3310 -DurationMs 4 -JobRef 'aaaaaaaa')
    [void](Add-DomeniaOperationTraceEvent -Trace $t -Phase 'Publish' -AtMs 3314 -DurationMs 85 -Volume 250 -Detail 'Complete-DomeniaGlobalSearchUi' -JobRef 'aaaaaaaa')
    [void](Complete-DomeniaTraceJob -Trace $t -JobRef 'aaaaaaaa' -Outcome 'Succeeded' -AtMs 3400)
    Assert-Equal 6 $t.Events.Count 'Deux lots de lecture locale fusionnes en un evenement'
    $store=@($t.Events|Where-Object{$_.Phase -eq 'StoreRead'})[0]
    Assert-Equal 250 ([int]$store.Volume);Assert-Equal 2 ([int]$store.Batches);Assert-Equal 100 ([int]$store.DurationMs)
    Assert-Equal 0 $t.OpenJobs.Count;Assert-Equal 3400 ([int]$t.EndedMs)
    $s=Get-DomeniaOperationTraceSummary -Trace $t
    Assert-Equal 'Succeeded' $s.Outcome;Assert-False $s.Open;Assert-Equal 2400 ([int]$s.TotalMs)
    Assert-Equal 'Collect' $s.Dominant 'La collecte est la phase la plus longue'
    $order=@($s.Phases|ForEach-Object{$_.Phase})
    Assert-Equal 'Request,Collect,StoreRead,Validate,Publish,End' ($order -join ',') 'Phases dans l ordre du temps, pas dans l ordre d arrivee'
    Assert-True ($s.Text.Contains('Collecte 2,3 s')) $s.Text
    Assert-True ($s.Text.Contains('Lecture locale 100 ms, 250 éléments, 2 lots')) $s.Text
    Assert-True ($s.Text.Contains('Fin : Terminée')) $s.Text
    Assert-True ($s.Text.Contains([string][char]0x2192)) 'Etapes reliees par une fleche'
    Assert-False ($s.Text.Contains('Recherche dans')) 'La chaine ne contient pas le nom affiche, seulement les etapes'
}
Test-Case 'P123' 'Lot sans mesure : volume et duree annonces au moins, jamais comptes a zero' {
    $t=New-DomeniaOperationTrace -TraceId 'bbbbbbbb-0000' -OperationId 'OpenAdObject' -AtMs 0
    [void](Add-DomeniaOperationTraceEvent -Trace $t -Phase 'StoreRead' -AtMs 10 -Volume 3 -DurationMs 20)
    [void](Add-DomeniaOperationTraceEvent -Trace $t -Phase 'StoreRead' -AtMs 20)
    $e=$t.Events[0]
    Assert-False $e.VolumeComplete;Assert-False $e.DurationComplete
    $s=Get-DomeniaOperationTraceSummary -Trace $t
    Assert-True ($s.Text.Contains('au moins 20 ms')) $s.Text;Assert-True ($s.Text.Contains('au moins 3 éléments')) $s.Text
}
Test-Case 'P123' 'Trace bornee : la fin est toujours conservee, le reste est compte' {
    $t=New-DomeniaOperationTrace -TraceId 'cccccccc-0000' -OperationId 'LocalStore' -AtMs 0
    [void](Add-DomeniaTraceJob -Trace $t -JobRef 'cccccccc')
    for($i=0;$i -lt 40;$i++){[void](Add-DomeniaOperationTraceEvent -Trace $t -Phase $(if($i % 2){'Shared'}else{'Request'}) -AtMs $i)}
    Assert-Equal 32 $t.Events.Count;Assert-Equal 8 ([int]$t.Dropped)
    [void](Complete-DomeniaTraceJob -Trace $t -JobRef 'cccccccc' -Outcome 'Stopped' -AtMs 50)
    Assert-Equal 32 $t.Events.Count;Assert-Equal 'End' $t.Events[$t.Events.Count-1].Phase;Assert-Equal 'Request' ([string]$t.Events[0].Phase) -Why 'La demande reste en tete'
    Assert-True ((Get-DomeniaOperationTraceSummary -Trace $t).Text.Contains('non conservé')) 'Les evenements perdus sont annonces'
    Assert-Throws { Add-DomeniaOperationTraceEvent -Trace $t -Phase 'Inventee' }
    Assert-Throws { Complete-DomeniaTraceJob -Trace $t -Outcome 'Inventee' }
}
Test-Case 'P123' 'Plusieurs taches : la pire fin l emporte, la trace reste ouverte tant qu une tache tourne' {
    $t=New-DomeniaOperationTrace -TraceId 'dddddddd-0000' -OperationId 'GlobalSearch' -AtMs 0
    [void](Add-DomeniaTraceJob -Trace $t -JobRef 'job11111');[void](Add-DomeniaTraceJob -Trace $t -JobRef 'job22222')
    [void](Complete-DomeniaTraceJob -Trace $t -JobRef 'job11111' -Outcome 'Failed' -AtMs 10 -Category 'AccessDenied')
    $open=Get-DomeniaOperationTraceSummary -Trace $t -NowMs 30
    Assert-True $open.Open;Assert-Equal 'Pending' $open.OutcomeStatus;Assert-Equal 30 ([int]$open.TotalMs)
    [void](Complete-DomeniaTraceJob -Trace $t -JobRef 'job22222' -Outcome 'Succeeded' -AtMs 40)
    Assert-Equal 'Failed' $t.Outcome 'Une reussite ne masque pas un echec';Assert-Equal 'AccessDenied' $t.Category
    Assert-Equal 'job11111,job22222' ($t.JobRefs.ToArray() -join ',')
    $w=New-DomeniaOperationTrace -TraceId 'eeeeeeee-0000' -OperationId 'UserWrite' -IsWrite $true -AtMs 0
    [void](Add-DomeniaTraceJob -Trace $w -JobRef 'w1111111' -IsWrite $true);[void](Add-DomeniaTraceJob -Trace $w -JobRef 'w2222222')
    [void](Complete-DomeniaTraceJob -Trace $w -JobRef 'w1111111' -Outcome 'Unknown' -AtMs 5);[void](Complete-DomeniaTraceJob -Trace $w -JobRef 'w2222222' -Outcome 'Failed' -AtMs 6 -Category 'Timeout')
    Assert-Equal 'Unknown' $w.Outcome 'Un resultat d ecriture inconnu reste visible';Assert-Equal 'Écriture' $w.Kind
    Assert-Equal 'Uncertain' (Get-DomeniaOperationTraceSummary -Trace $w).OutcomeStatus
}
Test-Case 'P123' 'Anneau plein : les traces terminees les plus anciennes partent d abord' {
    $traces=@(for($i=0;$i -lt 5;$i++){$t=New-DomeniaOperationTrace -TraceId ('trace000'+$i) -OperationId 'LocalStore' -AtMs ($i*10);$t.LastMs=$i*10;$t})
    [void](Add-DomeniaTraceJob -Trace $traces[0] -JobRef 'open0000')
    $out=@(Select-DomeniaTraceEviction -Traces $traces -Maximum 3)
    Assert-Equal 'trace0001,trace0002' ($out -join ',') 'La trace ouverte la plus ancienne est gardee'
    Assert-Equal 0 @(Select-DomeniaTraceEviction -Traces $traces -Maximum 10).Count
}
Test-Case 'P123' 'Travail automatique : liste seulement s il finit mal, et quitte l anneau le premier' {
    $save=New-DomeniaOperationTrace -TraceId 'save0000' -OperationId 'LocalStore' -AtMs 100 -Foreground $false
    $failed=New-DomeniaOperationTrace -TraceId 'fail0000' -OperationId 'LiveConsole' -AtMs 200 -Foreground $false
    $user=New-DomeniaOperationTrace -TraceId 'user0000' -OperationId 'GlobalSearch' -AtMs 0
    foreach($t in @($save,$failed,$user)){[void](Add-DomeniaTraceJob -Trace $t -JobRef ('j'+$t.TraceId))}
    [void](Complete-DomeniaTraceJob -Trace $save -JobRef 'jsave0000' -Outcome 'Succeeded' -AtMs 150)
    [void](Complete-DomeniaTraceJob -Trace $failed -JobRef 'jfail0000' -Outcome 'TimedOut' -AtMs 250)
    [void](Complete-DomeniaTraceJob -Trace $user -JobRef 'juser0000' -Outcome 'Succeeded' -AtMs 50)
    Assert-False (Test-DomeniaTraceListed $save) 'Une sauvegarde automatique reussie ne masque pas les demandes'
    Assert-True (Test-DomeniaTraceListed $failed) 'Un travail automatique hors delai reste visible'
    Assert-True (Test-DomeniaTraceListed $user)
    Assert-Equal 'save0000' (@(Select-DomeniaTraceEviction -Traces @($user,$save,$failed) -Maximum 2) -join ',') 'Le travail automatique reussi part avant la demande la plus ancienne'
    $bg=New-DomeniaOperationTrace -TraceId 'bgwr0000' -OperationId 'LocalStore' -Foreground $false
    [void](Add-DomeniaTraceJob -Trace $bg -JobRef 'w0000000' -IsWrite $true)
    Assert-True $bg.Foreground 'Une ecriture est toujours une demande de l operateur'
}
Test-Case 'P121' 'Durees lisibles en francais ; une mesure absente est dite non mesuree' {
    Assert-Equal 'non mesurée' (Format-DomeniaDurationText -1);Assert-Equal '< 1 ms' (Format-DomeniaDurationText 0.4)
    Assert-Equal '850 ms' (Format-DomeniaDurationText 850);Assert-Equal '2,3 s' (Format-DomeniaDurationText 2300)
    Assert-Equal '1 min 05 s' (Format-DomeniaDurationText 65000)
    Assert-Equal 'volume non mesuré' (Format-DomeniaVolumeText -1);Assert-Equal '1 élément' (Format-DomeniaVolumeText 1);Assert-Equal 'au moins 4 éléments' (Format-DomeniaVolumeText 4 -Complete $false)
}
Test-Case 'P121' 'Volume rendu a l interface lu sans enumeration' {
    Assert-Equal 0 ([int](Get-DomeniaOutputVolume $null));Assert-Equal 1 ([int](Get-DomeniaOutputVolume 'texte'));Assert-Equal 1 ([int](Get-DomeniaOutputVolume 42))
    Assert-Equal 3 ([int](Get-DomeniaOutputVolume @(1,2,3)))
    $list=New-Object 'System.Collections.Generic.List[object]';$list.Add(1);$list.Add(2)
    Assert-Equal 2 ([int](Get-DomeniaOutputVolume $list))
    $set=New-Object 'System.Collections.Generic.HashSet[int]';[void]$set.Add(1);[void]$set.Add(2);[void]$set.Add(3);[void]$set.Add(4)
    Assert-Equal 4 ([int](Get-DomeniaOutputVolume $set)) 'Collection generique comptee'
    Assert-Equal 5 ([int](Get-DomeniaOutputVolume ([pscustomobject]@{Rows=@(1,2,3,4,5);BaseDn='DC=example,DC=invalid'})))
    Assert-Equal 2 ([int](Get-DomeniaOutputVolume @{Items=@('a','b')}))
    Assert-Equal 1 ([int](Get-DomeniaOutputVolume @{Saved=$true}))
    Assert-Equal 1 ([int](Get-DomeniaOutputVolume ([pscustomobject]@{Items='un seul texte'})))
}
Test-Case 'P121' 'Lenteur expliquee par operation, phase, volume et traitement' {
    $v=Get-DomeniaSlownessVerdict -Name 'Recherche dans l annuaire' -OperationId 'GlobalSearch' -Handler 'Complete-DomeniaGlobalSearchUi' -QueueMs 0 -CollectMs 2100 -ValidateMs 3 -PublishMs 850 -Volume 1240 -PublishThresholdMs 120
    Assert-True $v.Slow;Assert-Equal 'Publish' $v.Phase 'Le message de lenteur de l interface vise le traitement'
    foreach($part in @('Recherche dans l annuaire','le traitement dans lʼinterface (850 ms)','1240 éléments','par élément','Complete-DomeniaGlobalSearchUi','collecte 2,1 s')){Assert-True ($v.Text.Contains($part)) ($part+' : '+$v.Text)}
    $u=Get-DomeniaSlownessVerdict -OperationId 'LocalStore' -CollectMs 6000 -TotalThresholdMs 5000
    Assert-True $u.Slow;Assert-Equal 'Collect' $u.Phase;Assert-True ($u.Text.Contains('volume non mesuré'));Assert-True ($u.Text.Contains('file non mesurée')) $u.Text
    Assert-True ($u.Text.StartsWith('LocalStore')) 'Sans nom, l identifiant d operation'
    $q=Get-DomeniaSlownessVerdict -OperationId 'LocalStore' -CollectMs 50 -PublishMs 10
    Assert-False $q.Slow
    $n=Get-DomeniaSlownessVerdict -OperationId 'LocalStore'
    Assert-False $n.Slow;Assert-True ($n.Text.Contains('durée non mesurée'))
    $x=Get-DomeniaSlownessVerdict -OperationId 'bad id' -Handler 'pwd=SECRET_SENTINEL_P121' -PublishMs 500
    Assert-False ($x.Text.Contains('SECRET_SENTINEL_P121')) 'Un traitement qui n est pas un nom de fonction n est pas repris';Assert-Equal '' $x.OperationId
}
Test-Case 'P121' 'Retard de l interface attribue au travail qui le recouvre, sinon dit non attribue' {
    Assert-True ($null -eq (Get-DomeniaStallAttribution -LateMs 100 -NowMs 10000))
    $recent=@(
        [pscustomobject]@{Name='Lecture objet Utilisateur';OperationId='OpenAdObject';Handler='Complete-DomeniaOpenObjectTaskUi';StartMs=8000;EndMs=9900}
        [pscustomobject]@{Name='Minuteur Timer:Live';OperationId='';Handler='Timer:Live';StartMs=9900;EndMs=9960}
        [pscustomobject]@{Name='Ancien';OperationId='LocalStore';Handler='Complete-DomeniaStorageWork';StartMs=1000;EndMs=1200}
    )
    $a=Get-DomeniaStallAttribution -LateMs 1500 -NowMs 10000 -Recent $recent
    Assert-True $a.Attributed;Assert-Equal 2 @($a.Culprits).Count 'Le travail termine avant le retard est ecarte'
    Assert-Equal 'OpenAdObject' ([string]@($a.Culprits)[0].Work.OperationId) 'Le plus long recouvrement en premier'
    Assert-True ($a.Text.Contains('Complete-DomeniaOpenObjectTaskUi')) $a.Text;Assert-True ($a.Text.Contains('1,5 s')) $a.Text
    $b=Get-DomeniaStallAttribution -LateMs 600 -NowMs 50000 -Recent $recent
    Assert-False $b.Attributed;Assert-True ($b.Text.Contains('non attribuée')) $b.Text
}
Test-Case 'P124' 'Diagnostic expurge : liste blanche, aucun secret, aucun nom, aucun message' {
    $sentinels=@('SECRET_SENTINEL_P124A','SECRET_SENTINEL_P124B','PC-PARIS-SENTINEL','alex.sentinel','10.77.0.99','CN=Sentinel')
    $versions=[pscustomobject]@{Domenia='1.0';Build='2026.10.13-DOMENIA-1.0-RC1.17.7-D120';PowerShell='5.1.26100.9549';Os='10.0.26100.0';Bitness='64';UiProfile='password=SECRET_SENTINEL_P124A';Theme='Dark'}
    $counters=[pscustomobject]@{Tasks=2;MemoryMb=312.4;ReadOnly=$true;TraceFaults=1;Secret='SECRET_SENTINEL_P124B';DispatcherP95Ms='PC-PARIS-SENTINEL'}
    $metrics=@([pscustomobject]@{Provenance='Ldap';OperationId='GlobalSearch';Count=12;P50=850.2;P95=2300.7;Max=4000},[pscustomobject]@{Provenance='Dispatcher';OperationId='Callback:GlobalSearch';Count=3;P50=40;P95=90;Max=91},[pscustomobject]@{Provenance='Ldap';OperationId='PC-PARIS-SENTINEL';Count=1;P50=1;P95=1;Max=1})
    $errors=@([pscustomobject]@{Code='INC-7F3A';Count=3;Type='System.UnauthorizedAccessException';Where='Domenia-Core.ps1:2345';Message='Acces refuse a CN=Sentinel'},[pscustomobject]@{Code='INC-0000';Count=1;Type='alex.sentinel n a pas';Where='C:\Users\alex.sentinel\x.ps1:12'},[pscustomobject]@{Code='pas un code';Count=1})
    $traces=@([pscustomobject]@{Reference='0123abcd';OperationId='GlobalSearch';Name='Recherche PC-PARIS-SENTINEL';Kind='Lecture';Outcome='Succeeded';Category='';Open=$false;TotalMs=2400;Text='alex.sentinel';Phases=@([pscustomobject]@{Phase='Collect';DurationMs=2300;Volume=-1;Batches=1;Label='PC-PARIS-SENTINEL'},[pscustomobject]@{Phase='Inventee';DurationMs=1;Volume=1;Batches=1})},[pscustomobject]@{Reference='PC-PARIS';OperationId='GlobalSearch';Phases=@()})
    $slow=@([pscustomobject]@{OperationId='GlobalSearch';Phase='Publish';Handler='Complete-DomeniaGlobalSearchUi';DurationMs=850;TotalMs=2900;Volume=1240;Text='Recherche PC-PARIS-SENTINEL'},[pscustomobject]@{OperationId='';Phase='Stall';Handler='mot de passe 10.77.0.99';DurationMs=1500;TotalMs=-1;Volume=-1})
    $d=New-DomeniaRedactedDiagnostic -Versions $versions -Counters $counters -Metrics $metrics -Errors $errors -Traces $traces -Slow $slow -CapturedUtc '2026-10-15T08:00:00.0000000Z'
    $json=$d|ConvertTo-Json -Depth 8
    foreach($sentinel in $sentinels){Assert-False ($json.Contains($sentinel)) ('Fuite : '+$sentinel)}
    Assert-False $d.ContainsSecrets;Assert-False $d.ContainsNames;Assert-False $d.ContainsMessages
    Assert-Equal '5.1.26100.9549' $d.Versions.PowerShell;Assert-True ($null -eq $d.Versions.PSObject.Properties['UiProfile']) 'Valeur hors forme ecartee'
    Assert-Equal 2 ([int]$d.Counters.Tasks);Assert-True $d.Counters.ReadOnly;Assert-Equal 1 ([int]$d.Counters.TraceFaults);Assert-True ($null -eq $d.Counters.PSObject.Properties['Secret']);Assert-True ($null -eq $d.Counters.PSObject.Properties['DispatcherP95Ms'])
    Assert-Equal 2 @($d.Metrics).Count;Assert-Equal 'Callback:GlobalSearch' ([string]@($d.Metrics)[1].OperationId)
    Assert-Equal 2 @($d.Errors).Count 'Un code incident invalide est ecarte';Assert-Equal 'Domenia-Core.ps1:2345' ([string]@($d.Errors)[0].Where);Assert-Equal '' ([string]@($d.Errors)[1].Type);Assert-Equal '' ([string]@($d.Errors)[1].Where)
    Assert-Equal 1 @($d.Traces).Count;Assert-Equal 1 @(@($d.Traces)[0].Phases).Count 'Phase hors catalogue ecartee'
    Assert-Equal 2 @($d.Slowness).Count;Assert-Equal '' ([string]@($d.Slowness)[1].Handler)
    Assert-Equal '2026-10-15T08:00:00.0000000Z' $d.CapturedUtc
    $preview=Get-DomeniaDiagnosticPreviewText -Diagnostic $d
    Assert-True ($preview.Contains('Jamais inclus')) $preview;Assert-True ($preview.Contains('2 code(s) incident')) $preview
}
Test-Case 'P124' 'Diagnostic borne : 200 mesures, 64 traces, 16 lenteurs au plus' {
    $metrics=@(for($i=0;$i -lt 260;$i++){[pscustomobject]@{Provenance='Ldap';OperationId=('Op'+$i);Count=1;P50=1;P95=1;Max=1}})
    $traces=@(for($i=0;$i -lt 80;$i++){[pscustomobject]@{Reference=('{0:x8}' -f $i);OperationId='LocalStore';Kind='Lecture';Outcome='Succeeded';Category='';Open=$false;TotalMs=1;Phases=@()}})
    $slow=@(for($i=0;$i -lt 30;$i++){[pscustomobject]@{OperationId='LocalStore';Phase='Collect';Handler='';DurationMs=6000;TotalMs=6000;Volume=-1}})
    $d=New-DomeniaRedactedDiagnostic -Metrics $metrics -Traces $traces -Slow $slow
    Assert-Equal 200 @($d.Metrics).Count;Assert-Equal 64 @($d.Traces).Count;Assert-Equal 16 @($d.Slowness).Count;Assert-Equal '' $d.CapturedUtc
}
Test-Case 'P118' 'Apres une fin : que faire, sans relance automatique ni rejeu d ecriture' {
    Assert-Equal '' (Get-DomeniaTraceAdvice -Outcome 'Succeeded')
    $unknown=Get-DomeniaTraceAdvice -Outcome 'Unknown' -IsWrite $true -Reference '0123abcd'
    Assert-True ($unknown.Contains('relisez')) $unknown;Assert-True ($unknown.Contains('0123abcd')) $unknown
    Assert-True ((Get-DomeniaTraceAdvice -Outcome 'Failed' -Category 'AccessDenied').Contains('compte autorisé'))
    Assert-True ((Get-DomeniaTraceAdvice -Outcome 'Failed' -Category 'CredentialsRejected').Contains('verrouillage'))
    Assert-True ((Get-DomeniaTraceAdvice -Outcome 'TimedOut' -IsWrite $true).Contains('jamais une écriture')) 'Une ecriture hors delai n est jamais presentee comme relancable'
    Assert-True ((Get-DomeniaTraceAdvice -Outcome 'Withdrawn').Contains('aucun appel'))
    foreach($o in @(Get-DomeniaTraceOutcomes)){
        $text=Get-DomeniaTraceAdvice -Outcome ([string]$o.Code) -IsWrite $true -Category 'Timeout'
        Assert-False ($text -match '(?i)relance(ra)? automatiquement|nouvel essai automatique') ([string]$o.Code)
        Assert-True ((Get-DomeniaStatusGlyph ([string]$o.Status)).Recognized) ('Etat lisible par symbole et texte : '+[string]$o.Code)
    }
}
