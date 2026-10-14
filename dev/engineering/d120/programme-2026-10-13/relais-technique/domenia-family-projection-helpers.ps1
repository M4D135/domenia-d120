function Convert-StoreWObservation {
    param($Row,[string]$Kind='Observation')
    return [pscustomobject]@{Kind=$Kind;SummaryMissing=([bool]$Row.summary_missing);Guid=[string]$Row.object_guid;DN=[string]$Row.dn;Family=[string]$Row.family;ResultKind=[string]$Row.result_kind;RequestKey=[string]$Row.request_key;LastAttemptAtUtc=[string]$Row.attempt_at;Status=[string]$Row.status;Error=[string]$Row.error;LastSuccessAtUtc=[string]$Row.success_at;Data=(Get-StoreWJson ([string]$Row.payload));AttemptData=(Get-StoreWJson ([string]$Row.attempt_payload));DefinitionHash=[string]$Row.definition_hash;Revision=[long]$Row.revision}
}
function Get-StoreWProjection {
    param([object[]]$Observations,[string]$Name='')
    if(-not $Observations.Count){return $null}
    $first=$Observations[0];$p=[ordered]@{Version=1;Key=([string]$first.DN).ToLowerInvariant();Guid=[string]$first.Guid;Computer=$Name;CheckedUtc='';Revision=0L;Probes=[ordered]@{};Times=[ordered]@{}}
    foreach($o in $Observations){
        $p.Revision=[Math]::Max([long]$p.Revision,[long]$o.Revision)
        $data=$o.Data;$summaryMissing=([bool]$o.SummaryMissing -or ($null -ne $data -and [bool]$data.SummaryUnavailable))
        if([string]$o.Family -like 'Probe:*'){
            $probeId=([string]$o.Family).Substring(6);$probe=$data
            if($null -ne $data -and $null -ne $data.Probes){$probe=$data.Probes.$probeId}
            $probeMap=Get-StoreWMap $probe
            # The GUI projection is bounded. Full instance graphs remain in the typed family readback.
            if($probeMap.Contains('Instances')){[void]$probeMap.Remove('Instances')}
            if($summaryMissing){$probeMap.Skipped='SummaryUnavailable';$probeMap.SummaryMissing=$true}
            if([string]$o.Status -eq 'Error'){
                $probeMap.Error=$(if([string]$o.Error){[string]$o.Error}else{'Lecture non confirmee.'})
                $probeMap.AttemptedUtc=[string]$o.LastAttemptAtUtc
                $probeMap.CheckedUtc=[string]$o.LastSuccessAtUtc
                $probeMap.Succeeded=$false
            }
            $p.Probes[$probeId]=[pscustomobject]$probeMap
        }else{
            if($null -ne $data){foreach($field in $data.PSObject.Properties){if($field.Name -notin @('Guid','Key','DN','Version','Times','Probes','CheckedUtc') -and (-not $Name -or $field.Name -ne 'Computer')){$p[$field.Name]=$field.Value}}}
            # A failed attempt may replace diagnostics, never successful measured values with null/empty fields.
            if([string]$o.Status -eq 'Error' -and $null -ne $o.AttemptData){
                foreach($field in $o.AttemptData.PSObject.Properties){
                    if($field.Name -in @('Outcome','Detail','PresenceDetail','InventoryError','ConsoleError','Error','ErrorKind','Status','DirectoryAuthRejected')){$p[$field.Name]=$field.Value}
                }
            }
        }
        $timeName=[string]$o.Family
        if($summaryMissing){$p['SummaryMissing.'+$timeName]=$true}
        $p.Times[$timeName]=[pscustomobject]@{ObservedUtc=[string]$o.LastSuccessAtUtc;LastAttemptUtc=[string]$o.LastAttemptAtUtc;Succeeded=([string]$o.Status -eq 'Success')}
        if([string]::CompareOrdinal([string]$o.LastAttemptAtUtc,[string]$p.CheckedUtc) -gt 0){$p.CheckedUtc=[string]$o.LastAttemptAtUtc;$p.Key=([string]$o.DN).ToLowerInvariant()}
        switch([string]$o.Family){
            'Presence' {$p.PresenceCheckedUtc=[string]$o.LastSuccessAtUtc;$p.PresenceAttemptUtc=[string]$o.LastAttemptAtUtc;$p.PresenceError=[string]$o.Error;if($o.Status -eq 'Error'){$p.Presence='Erreur de ping'}}
            'Console' {$p.ObservedUtc=[string]$o.LastSuccessAtUtc;$p.ConsoleCheckedUtc=[string]$o.LastSuccessAtUtc;$p.UserCheckedUtc=[string]$o.LastSuccessAtUtc;$p.ConsoleAttemptUtc=[string]$o.LastAttemptAtUtc;$p.ConsoleError=[string]$o.Error;if($o.Status -eq 'Error' -and -not $p.Outcome){$p.Outcome='Unavailable'}}
            'Inventory' {$p.InventoryCheckedUtc=[string]$o.LastSuccessAtUtc;$p.InventoryAttemptUtc=[string]$o.LastAttemptAtUtc;$p.InventoryError=[string]$o.Error}
        }
    }
    return [pscustomobject]$p
}
function Read-StoreWCommitted {
    param([IntPtr]$Db,[string[]]$Guids,[bool]$IncludeDirectoryDetails=$true,[bool]$IncludeObservations=$true,[bool]$IncludeDetails=$true,[string]$DetailWhere='1=1',[string[]]$ObservationFamilies=$null,[ValidateSet('Full','QuerySummary')][string]$DetailProjection='Full',[ValidateSet('Full','Summary')][string]$ObservationProjection='Full')
    $keys=@($Guids|Select-Object -Unique|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ','
    $rows=[Collections.Generic.List[object]]::new();$observations=[Collections.Generic.List[object]]::new();$details=[Collections.Generic.List[object]]::new();$projections=[Collections.Generic.List[object]]::new()
    if($keys){
        $names=@{};$payloadColumn=if($IncludeDirectoryDetails){'d.payload'}else{'NULL'}
        foreach($r in @(Invoke-DomeniaDbQuery ("SELECT a.*,$payloadColumn AS store_payload,d.field_times,d.revision AS store_revision FROM ad_objects a LEFT JOIN domenia_directory_data d ON d.object_guid=a.object_guid WHERE a.object_guid IN ($keys) ORDER BY a.name COLLATE NOCASE,a.object_guid;") $Db)){$rows.Add((Convert-StoreWDirectory $r));$names[[string]$r.object_guid]=[string]$r.name}
        $groups=@{};$familyWhere=''
        if($PSBoundParameters.ContainsKey('ObservationFamilies') -and $null -ne $ObservationFamilies){
            foreach($family in @($ObservationFamilies)){if($family -notmatch '^(Presence|Console|Inventory|Probe:[A-Za-z0-9_.-]{1,128})$'){throw 'Famille de lecture invalide.'}}
            $families=@($ObservationFamilies|Select-Object -Unique|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ','
            $familyWhere=if($families){" AND family IN ($families)"}else{' AND 0=1'}
        }
        if($IncludeObservations){
        $observationColumns='*'
        if($ObservationProjection -eq 'Summary'){
            $available=@(Invoke-DomeniaDbQuery 'PRAGMA table_info(domenia_observations);' $Db|ForEach-Object{[string]$_.name})
            $successSummary=if($available -contains 'summary_payload'){'summary_payload'}else{'NULL'};$attemptSummary=if($available -contains 'attempt_summary'){'attempt_summary'}else{'NULL'}
            $successRead="CASE WHEN $successSummary IS NOT NULL AND length(CAST($successSummary AS BLOB))<=262144 THEN $successSummary WHEN $successSummary IS NULL AND length(CAST(payload AS BLOB))<=16384 THEN payload ELSE NULL END"
            $attemptRead="CASE WHEN $attemptSummary IS NOT NULL AND length(CAST($attemptSummary AS BLOB))<=262144 THEN $attemptSummary WHEN $attemptSummary IS NULL AND length(CAST(attempt_payload AS BLOB))<=16384 THEN attempt_payload ELSE NULL END"
            $missing="CASE WHEN payload IS NOT NULL AND payload<>'null' AND ($successRead) IS NULL THEN 1 ELSE 0 END"
            $observationColumns="object_guid,family,dn,definition_hash,attempt_at,status,error,success_at,revision,$successRead AS payload,$attemptRead AS attempt_payload,$missing AS summary_missing"
        }
        foreach($r in @(Invoke-DomeniaDbQuery ("SELECT $observationColumns FROM domenia_observations WHERE object_guid IN ($keys)$familyWhere ORDER BY object_guid,family;") $Db)){
            $o=Convert-StoreWObservation $r;$observations.Add($o)
            if(-not $groups.ContainsKey($o.Guid)){$groups[$o.Guid]=[Collections.Generic.List[object]]::new()};$groups[$o.Guid].Add($o)
        }
        foreach($g in $groups.Keys){$projections.Add((Get-StoreWProjection $groups[$g].ToArray() ([string]$names[$g])))}}
        if($IncludeDetails){
            $detailColumns='*'
            if($DetailProjection -eq 'QuerySummary'){
                $available=@(Invoke-DomeniaDbQuery 'PRAGMA table_info(domenia_details);' $Db|ForEach-Object{[string]$_.name})
                $successColumn=if($available -contains 'summary_payload'){'summary_payload'}else{'NULL'};$attemptColumn=if($available -contains 'attempt_summary'){'attempt_summary'}else{'NULL'}
                # No JSON extension and no full payload scan: old rows without a summary stay unknown.
                $detailColumns="object_guid,result_kind,request_key,dn,attempt_at,status,error,success_at,revision,$successColumn AS payload,$attemptColumn AS attempt_payload"
            }
            foreach($r in @(Invoke-DomeniaDbQuery ("SELECT $detailColumns FROM domenia_details WHERE object_guid IN ($keys) AND ($DetailWhere) ORDER BY object_guid,result_kind,request_key;") $Db)){$details.Add((Convert-StoreWObservation $r 'DetailResult'))}
        }
    }
    $state=@(Invoke-DomeniaDbQuery 'SELECT * FROM domenia_store_state WHERE id=1;' $Db)
    return [pscustomobject]@{Rows=$rows.ToArray();Observations=$observations.ToArray();ObservationRows=$projections.ToArray();Details=$details.ToArray();SnapshotRevision=$(if($state.Count){[long]$state[0].revision}else{0L})}
}
