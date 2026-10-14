function Get-DomeniaQuerySchemaWorkerCode {
    return @'
$root=[string]$Payload.ModuleRoot
foreach($file in @('Domenia-Common.Model.ps1','Domenia-QuerySchema.Model.ps1','Domenia-ProbeDetails.Model.ps1')){. (Join-Path $root $file)}
$mode=[string]$Payload.Mode;$namespace=[string]$Payload.Namespace;$className=[string]$Payload.ClassName
if($mode -notin @('Schema','Select','Associations')){throw 'Mode WMI avancé inconnu.'}
$limit=[int]$Payload.Limit;if($limit -lt 1 -or $limit -gt 2000){throw 'Limite WMI comprise entre 1 et 2 000 instances requise.'}
$plan=$null
if($mode -eq 'Select'){$plan=ConvertFrom-DomeniaWqlSelect ([string]$Payload.Query);$className=$plan.ClassName}
Assert-DomeniaQuerySchemaTarget $namespace $className @($Payload.MsiClassNames)
if($mode -eq 'Associations'){
    Assert-DomeniaQuerySchemaTarget $namespace ([string]$Payload.AssociationClass) @($Payload.MsiClassNames)
    Assert-DomeniaQuerySchemaTarget $namespace ([string]$Payload.ResultClass) @($Payload.MsiClassNames)
}
if($null -ne $Context.PSObject.Properties['UseCim'] -and -not [bool]$Context.UseCim){throw 'Lecture CIM désactivée pour le compte distant.'}
$watch=[Diagnostics.Stopwatch]::StartNew();$session=$null
function Assert-QueryReadBudget {
    if($watch.Elapsed.TotalSeconds -gt 50){throw 'Budget de lecture WMI atteint (50 secondes).'}
    if($null -ne $Payload.StopToken -and $Payload.StopToken.IsCancellationRequested){throw 'Lecture WMI annulée.'}
    Assert-WCredentialAllowed -Context $Context -Channel Remote
}
function Read-QuerySchema($Class){
    foreach($property in @($Class.CimClassProperties)){
        $name=[string]$property.Name
        if($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or $name -match '(?i)password|passwd|pwd|secret|token|credential|recoverykey|privatekey|productkey|cleartext'){continue}
        $key=$false;foreach($qualifier in @($property.Qualifiers)){if($qualifier.Name -eq 'Key' -and [bool]$qualifier.Value){$key=$true}}
        [pscustomobject]@{Property=$name;Type=[string]$property.CimType;IsKey=$key}
    }
}
try{
    $credential=Get-WMachineCredential $Context
    $session=New-WDomeniaCimSession $Context ([string]$Payload.Computer) $credential 12
    Assert-QueryReadBudget
    $class=Get-CimClass -CimSession $session -Namespace $namespace -ClassName $className -OperationTimeoutSec 12 -ErrorAction Stop
    $schema=@(Read-QuerySchema $class|Sort-Object Property)
    if($schema.Count -gt 1024){throw 'Schéma supérieur au budget de 1 024 propriétés.'}
    $canonical='SCHEMA '+$className;$rows=[Collections.Generic.List[object]]::new();$readCount=0L;$truncated=$false;$bytes=0L;$countComplete=$true
    if($mode -eq 'Select'){
        $plan=ConvertFrom-DomeniaWqlSelect -Query ([string]$Payload.Query) -KnownProperties @($schema.Property);$canonical=$plan.CanonicalQuery
        # Keep provider identity even when key properties are not displayed by the user.
        $properties=@(@($plan.Properties)+@($schema|Where-Object IsKey|ForEach-Object Property)|Select-Object -Unique)
        $select='SELECT '+($properties -join ',')+' FROM '+$className
        $where=[regex]::Match($canonical,'(?is)\sWHERE\s(.+)$');if($where.Success){$select+=' WHERE '+$where.Groups[1].Value}
        $instances=@(Get-CimInstance -CimSession $session -Namespace $namespace -Query $select -OperationTimeoutSec 15 -ErrorAction Stop|Select-Object -First ($limit+1))
    }elseif($mode -eq 'Associations'){
        $association=Get-CimClass -CimSession $session -Namespace $namespace -ClassName ([string]$Payload.AssociationClass) -OperationTimeoutSec 12 -ErrorAction Stop
        if(-not @($association.CimClassQualifiers|Where-Object{$_.Name -eq 'Association' -and [bool]$_.Value}).Count){throw 'La classe choisie n’est pas une association déclarée par le fournisseur.'}
        $keys=@{};$keyNames=@($schema|Where-Object IsKey|ForEach-Object Property)
        if(-not $keyNames.Count){throw 'La classe source ne déclare pas d’identité de fournisseur.'}
        foreach($name in $keyNames){$value=Get-DomeniaMemberValue $Payload.KeyValues $name;if($null -eq $value -or $value -is [array]){throw 'Clé de l’instance source absente ou invalide.'};$keys[$name]=$value}
        $source=New-CimInstance -ClassName $className -Namespace $namespace -Property $keys -Key $keyNames -ClientOnly -ErrorAction Stop
        $resultClass=Get-CimClass -CimSession $session -Namespace $namespace -ClassName ([string]$Payload.ResultClass) -OperationTimeoutSec 12 -ErrorAction Stop
        $schema=@(Read-QuerySchema $resultClass|Sort-Object Property);$properties=@($schema.Property)
        $canonical='ASSOCIATION '+[string]$Payload.AssociationClass+' FROM '+$className+' '+(ConvertTo-Json -InputObject $keys -Depth 4 -Compress)+' TO '+[string]$Payload.ResultClass
        Assert-QueryReadBudget
        $instances=@(Get-CimAssociatedInstance -InputObject $source -CimSession $session -Namespace $namespace -Association ([string]$Payload.AssociationClass) -ResultClassName ([string]$Payload.ResultClass) -OperationTimeoutSec 15 -ErrorAction Stop|Select-Object -First ($limit+1))
        $className=[string]$Payload.ResultClass
    }
    if($mode -ne 'Schema'){
        $readCount=$instances.Count;$truncated=($readCount -gt $limit);$countComplete=(-not $truncated)
        for($i=0;$i -lt [Math]::Min($instances.Count,$limit);$i++){
            Assert-QueryReadBudget
            $instance=$instances[$i];$detached=ConvertTo-DomeniaProbeDetailInstance -Instance $instance -Properties $properties -Index $i
            $keys=[ordered]@{};foreach($name in @($schema|Where-Object IsKey|ForEach-Object Property)){$keys[$name]=Get-DomeniaMemberValue $detached.Values $name}
            if(-not $detached.Id -and $keys.Count){$detached.Id=$className+' '+(ConvertTo-Json -InputObject $keys -Depth 4 -Compress)}
            $row=[pscustomobject]@{Id=$detached.Id;ClassName=$className;KeyValues=[pscustomobject]$keys;Values=$detached.Values;IncompleteProperties=@($detached.IncompleteProperties)}
            $size=[Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $row -Depth 8 -Compress))
            if($bytes+$size -gt 1048576){$truncated=$true;$countComplete=$false;break};$bytes+=$size;$rows.Add($row)
        }
    }
    Assert-QueryReadBudget
    [pscustomobject]@{Computer=[string]$Payload.Computer;Success=$true;Mode=$mode;Namespace=$namespace;ClassName=$className;CanonicalQuery=$canonical;RequestKey=(Get-DomeniaQuerySchemaRequestKey $namespace $canonical);Schema=$schema;Rows=$rows.ToArray();StoredCount=$rows.Count;ObservedCountMinimum=$readCount;CountComplete=$countComplete;Truncated=$truncated;BudgetBytes=1048576;Limit=$limit;SourceCompletedUtc=[datetime]::UtcNow.ToString('o');DurationMs=[long]$watch.ElapsedMilliseconds}
}catch{[void](Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Remote);throw}
finally{Remove-WDomeniaCimSession $session}
'@
}
