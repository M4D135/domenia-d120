function Get-DomeniaQuerySchemaWorkerCode {
    return @'
$root=[string]$Payload.ModuleRoot
foreach($file in @('Domenia-Common.Model.ps1','Domenia-QuerySchema.Model.ps1','Domenia-ProbeDetails.Model.ps1')){. (Join-Path $root $file)}
# One explicit read on one workstation. Metadata modes never recurse: one namespace level, one class list, one schema.
$mode=[string]$Payload.Mode;$namespace=[string]$Payload.Namespace;$className=[string]$Payload.ClassName
if($mode -notin @('Namespaces','Classes','Schema','Select','Associations','Reference')){throw 'Mode WMI avancé inconnu.'}
$limit=[int]$Payload.Limit;if($limit -lt 1 -or $limit -gt 2000){throw 'Limite WMI comprise entre 1 et 2 000 instances requise.'}
Assert-DomeniaQuerySchemaNamespace $namespace
$plan=$null;$filter='';$preset=$null;$referenceValue=''
if($mode -eq 'Select'){$plan=ConvertFrom-DomeniaWqlSelect ([string]$Payload.Query);$className=$plan.ClassName}
if($mode -eq 'Classes'){$filter=[string]$Payload.ClassFilter;Assert-DomeniaQuerySchemaClassFilter $filter}
elseif($mode -ne 'Namespaces'){Assert-DomeniaQuerySchemaTarget $namespace $className @($Payload.MsiClassNames)}
if($mode -eq 'Associations'){
    Assert-DomeniaQuerySchemaTarget $namespace ([string]$Payload.AssociationClass) @($Payload.MsiClassNames)
    Assert-DomeniaQuerySchemaTarget $namespace ([string]$Payload.ResultClass) @($Payload.MsiClassNames)
}
if($mode -eq 'Reference'){
    $preset=Get-DomeniaWmiRelationPreset -SourceClass $className -SourceProperty ([string]$Payload.SourceProperty) -TargetClass ([string]$Payload.ResultClass) -TargetProperty ([string]$Payload.TargetProperty)
    if($null -eq $preset){throw 'Relation non prévue entre ces classes : aucune lecture.'}
    $referenceValue=ConvertTo-DomeniaWmiReferenceValue -Preset $preset -Value $Payload.SourceValue
    Assert-DomeniaQuerySchemaTarget $namespace ([string]$preset.Result) @($Payload.MsiClassNames)
}
if($null -ne $Context.PSObject.Properties['UseCim'] -and -not [bool]$Context.UseCim){throw 'Lecture CIM désactivée pour le compte distant.'}
$watch=[Diagnostics.Stopwatch]::StartNew();$session=$null
function Assert-QueryReadBudget {
    if($watch.Elapsed.TotalSeconds -gt 50){throw 'Budget de lecture WMI atteint (50 secondes).'}
    if($null -ne $Payload.StopToken -and $Payload.StopToken.IsCancellationRequested){throw 'Lecture WMI annulée.'}
    Assert-WCredentialAllowed -Context $Context -Channel Remote
}
function ConvertTo-QuerySchemaText([string]$Text,[int]$Max){
    $clean=([regex]::Replace([string]$Text,'[\p{Cc}]+',' ')).Trim()
    if($clean.Length -gt $Max){$clean=$clean.Substring(0,$Max)+'…'}
    return $clean
}
function Read-QuerySchema($Class){
    foreach($property in @($Class.CimClassProperties)){
        $name=[string]$property.Name
        if($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or $name -match '(?i)password|passwd|pwd|secret|token|credential|recoverykey|privatekey|productkey|cleartext'){continue}
        $key=$false;$unit='';$description=''
        foreach($qualifier in @($property.Qualifiers)){
            $qualifierName=[string]$qualifier.Name
            if($qualifierName -eq 'Key' -and [bool]$qualifier.Value){$key=$true}
            elseif($qualifierName -eq 'Units'){$unit=ConvertTo-QuerySchemaText ([string]$qualifier.Value) 64}
            elseif($qualifierName -eq 'Description'){$description=ConvertTo-QuerySchemaText ([string]$qualifier.Value) 600}
        }
        $type=[string]$property.CimType
        [pscustomobject]@{Property=$name;Type=$type;IsKey=$key;IsArray=$type.EndsWith('Array');Unit=$unit;Description=$description}
    }
}
function Get-QuerySchemaClass([string]$Name){
    # Descriptions are amended qualifiers: ask for the localized ones, and say so when the provider does not give them.
    $options=$null
    try{
        $options=[Microsoft.Management.Infrastructure.Options.CimOperationOptions]::new()
        $options.Timeout=[TimeSpan]::FromSeconds(12)
        $options.Flags=[Microsoft.Management.Infrastructure.Options.CimOperationFlags]::LocalizedQualifiers
        $localizedClass=$session.GetClass($namespace,$Name,$options)
        if($null -ne $localizedClass){return [pscustomobject]@{Class=$localizedClass;Localized=$true}}
    }catch{if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Remote){throw}}
    finally{if($null -ne $options){$options.Dispose()}}
    Assert-QueryReadBudget
    return [pscustomobject]@{Class=(Get-CimClass -CimSession $session -Namespace $namespace -ClassName $Name -OperationTimeoutSec 12 -ErrorAction Stop);Localized=$false}
}
try{
    $credential=Get-WMachineCredential $Context
    $session=New-WDomeniaCimSession $Context ([string]$Payload.Computer) $credential 12
    Assert-QueryReadBudget
    $schema=@();$rows=[Collections.Generic.List[object]]::new();$namespaces=@();$classes=@();$classDescription='';$localized=$false
    $canonical='';$readCount=0L;$truncated=$false;$bytes=0L;$countComplete=$true;$relation=''
    if($mode -eq 'Namespaces'){
        $canonical='NAMESPACES '+$namespace
        $children=@(Get-CimInstance -CimSession $session -Namespace $namespace -ClassName '__NAMESPACE' -OperationTimeoutSec 12 -ErrorAction Stop|Select-Object -First 501)
        $readCount=$children.Count;$truncated=($readCount -gt 500);$countComplete=(-not $truncated)
        $namespaces=@($children|Select-Object -First 500|ForEach-Object{[string]$_.Name}|Where-Object{$_ -match '^[A-Za-z_][A-Za-z0-9_]*$'}|Sort-Object|ForEach-Object{[pscustomobject]@{Namespace=($namespace+'\'+$_)}})
    }elseif($mode -eq 'Classes'){
        $canonical='CLASSES '+$namespace+' '+$(if($filter){$filter}else{'*'})
        $parameters=@{CimSession=$session;Namespace=$namespace;OperationTimeoutSec=20;ErrorAction='Stop'};if($filter){$parameters['ClassName']=$filter}
        $list=[Collections.Generic.List[object]]::new()
        foreach($class in @(Get-CimClass @parameters)){
            Assert-QueryReadBudget
            $name=[string]$class.CimClassName
            if($name -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,127}$' -or ($name.StartsWith('__') -and -not $filter.StartsWith('__'))){continue}
            $readCount++
            $size=[Text.Encoding]::UTF8.GetByteCount($name)+160
            if($list.Count -ge 2000 -or ($bytes+$size) -gt 1048576){$truncated=$true;$countComplete=$false;continue}
            $keys=0;foreach($property in @($class.CimClassProperties)){foreach($qualifier in @($property.Qualifiers)){if([string]$qualifier.Name -eq 'Key' -and [bool]$qualifier.Value){$keys++}}}
            $association=$false;$abstract=$false
            foreach($qualifier in @($class.CimClassQualifiers)){if([string]$qualifier.Name -eq 'Association' -and [bool]$qualifier.Value){$association=$true};if([string]$qualifier.Name -eq 'Abstract' -and [bool]$qualifier.Value){$abstract=$true}}
            $note=if($name -in @($Payload.MsiClassNames)){'Fournisseur MSI : lecture refusée'}elseif($abstract){'Classe abstraite : instances lues par ses sous-classes'}elseif($association){'Association entre deux classes'}else{''}
            $list.Add([pscustomobject]@{Class=$name;Properties=@($class.CimClassProperties).Count;Keys=$keys;Association=$association;Abstract=$abstract;Note=$note});$bytes+=$size
        }
        $classes=@($list|Sort-Object Class)
    }elseif($mode -eq 'Schema'){
        $read=Get-QuerySchemaClass $className;$localized=[bool]$read.Localized
        $schema=@(Read-QuerySchema $read.Class|Sort-Object Property)
        if($schema.Count -gt 1024){throw 'Schéma supérieur au budget de 1 024 propriétés.'}
        foreach($qualifier in @($read.Class.CimClassQualifiers)){if([string]$qualifier.Name -eq 'Description'){$classDescription=ConvertTo-QuerySchemaText ([string]$qualifier.Value) 1000}}
        $canonical='SCHEMA '+$className
    }else{
        $class=Get-CimClass -CimSession $session -Namespace $namespace -ClassName $className -OperationTimeoutSec 12 -ErrorAction Stop
        $schema=@(Read-QuerySchema $class|Sort-Object Property)
        if($schema.Count -gt 1024){throw 'Schéma supérieur au budget de 1 024 propriétés.'}
        $instances=@()
        if($mode -eq 'Select'){
            $plan=ConvertFrom-DomeniaWqlSelect -Query ([string]$Payload.Query) -KnownProperties @($schema.Property);$canonical=$plan.CanonicalQuery
            # Keep provider identity even when key properties are not displayed by the user.
            $properties=@(@($plan.Properties)+@($schema|Where-Object IsKey|ForEach-Object Property)|Select-Object -Unique)
            $select='SELECT '+($properties -join ',')+' FROM '+$className
            $where=[regex]::Match($canonical,'(?is)\sWHERE\s(.+)$');if($where.Success){$select+=' WHERE '+$where.Groups[1].Value}
            $instances=@(Get-CimInstance -CimSession $session -Namespace $namespace -Query $select -OperationTimeoutSec 15 -ErrorAction Stop|Select-Object -First ($limit+1))
        }elseif($mode -eq 'Associations'){
            $association=Get-CimClass -CimSession $session -Namespace $namespace -ClassName ([string]$Payload.AssociationClass) -OperationTimeoutSec 12 -ErrorAction Stop
            if(-not @($association.CimClassQualifiers|Where-Object{$_.Name -eq 'Association' -and [bool]$_.Value}).Count){throw 'La classe choisie nʼest pas une association déclarée par le fournisseur.'}
            $keys=@{};$keyNames=@($schema|Where-Object IsKey|ForEach-Object Property)
            if(-not $keyNames.Count){throw 'La classe source ne déclare pas dʼidentité de fournisseur.'}
            foreach($name in $keyNames){$value=Get-DomeniaMemberValue $Payload.KeyValues $name;if($null -eq $value -or $value -is [array]){throw 'Clé de lʼinstance source absente ou invalide.'};$keys[$name]=$value}
            $source=New-CimInstance -ClassName $className -Namespace $namespace -Property $keys -Key $keyNames -ClientOnly -ErrorAction Stop
            $resultClass=Get-CimClass -CimSession $session -Namespace $namespace -ClassName ([string]$Payload.ResultClass) -OperationTimeoutSec 12 -ErrorAction Stop
            $schema=@(Read-QuerySchema $resultClass|Sort-Object Property);$properties=@($schema.Property)
            $canonical='ASSOCIATION '+[string]$Payload.AssociationClass+' FROM '+$className+' '+(ConvertTo-Json -InputObject $keys -Depth 4 -Compress)+' TO '+[string]$Payload.ResultClass
            $relation=[string]$Payload.AssociationClass
            Assert-QueryReadBudget
            $instances=@(Get-CimAssociatedInstance -InputObject $source -CimSession $session -Namespace $namespace -Association ([string]$Payload.AssociationClass) -ResultClassName ([string]$Payload.ResultClass) -OperationTimeoutSec 15 -ErrorAction Stop|Select-Object -First ($limit+1))
            $className=[string]$Payload.ResultClass
        }else{
            # Reference relation: the target is read by its identity property, never matched by a display name.
            $resultClass=Get-CimClass -CimSession $session -Namespace $namespace -ClassName ([string]$preset.Result) -OperationTimeoutSec 12 -ErrorAction Stop
            $schema=@(Read-QuerySchema $resultClass|Sort-Object Property)
            $known=@($schema.Property)
            $properties=@(@($preset.Properties|Where-Object{$_ -in $known})+@($schema|Where-Object IsKey|ForEach-Object Property)|Select-Object -Unique)
            if(-not $properties.Count -or [string]$preset.TargetProperty -notin $known){throw 'Le schéma de la classe cible ne permet pas cette relation sur ce poste.'}
            $literal=if([string]$preset.ValueKind -eq 'String'){"'"+$referenceValue+"'"}else{$referenceValue}
            $select='SELECT '+($properties -join ',')+' FROM '+[string]$preset.Result+' WHERE '+[string]$preset.TargetProperty+'='+$literal
            $canonical='REFERENCE '+$className+'.'+[string]$preset.SourceProperty+'='+$referenceValue+' TO '+[string]$preset.Result+'.'+[string]$preset.TargetProperty
            $relation=[string]$preset.SourceProperty+' → '+[string]$preset.Result+'.'+[string]$preset.TargetProperty
            Assert-QueryReadBudget
            $instances=@(Get-CimInstance -CimSession $session -Namespace $namespace -Query $select -OperationTimeoutSec 15 -ErrorAction Stop|Select-Object -First ($limit+1))
            $className=[string]$preset.Result
        }
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
    [pscustomobject]@{Computer=[string]$Payload.Computer;Success=$true;Mode=$mode;Namespace=$namespace;ClassName=$className;CanonicalQuery=$canonical;RequestKey=(Get-DomeniaQuerySchemaRequestKey $namespace $canonical);Schema=$schema;Rows=$rows.ToArray();Namespaces=$namespaces;Classes=$classes;ClassDescription=$classDescription;DescriptionsAvailable=$localized;Filter=$filter;Relation=$relation;StoredCount=$(if($mode -eq 'Namespaces'){$namespaces.Count}elseif($mode -eq 'Classes'){$classes.Count}else{$rows.Count});ObservedCountMinimum=$readCount;CountComplete=$countComplete;Truncated=$truncated;BudgetBytes=1048576;Limit=$limit;SourceCompletedUtc=[datetime]::UtcNow.ToString('o');DurationMs=[long]$watch.ElapsedMilliseconds}
}catch{[void](Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Remote);throw}
finally{Remove-WDomeniaCimSession $session}
'@
}
