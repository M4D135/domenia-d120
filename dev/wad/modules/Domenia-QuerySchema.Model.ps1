# A deliberately small WQL SELECT grammar. It never evaluates PowerShell or accepts statements/method calls.
function ConvertFrom-DomeniaWqlSelect {
    param([string]$Query,[string[]]$KnownProperties=$null)
    if(-not $Query.Trim() -or $Query.Length -gt 8192 -or $Query -match '[\x00-\x08\x0b\x0c\x0e-\x1f]'){throw 'SELECT vide ou supérieur à 8 192 caractères.'}
    $pattern="\G\s*(?:(?<String>'(?:[^'\\]|\\.|'')*')|(?<Number>[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)|(?<Identifier>[A-Za-z_][A-Za-z0-9_]*)|(?<Operator><=|>=|<>|!=|=|<|>)|(?<Symbol>[(),]))"
    $tokens=[Collections.Generic.List[object]]::new();$offset=0
    while($offset -lt $Query.Length){
        if(-not $Query.Substring($offset).Trim()){break}
        # Match starts at zero unless StartAt is supplied; use a Regex instance for the current anchored position.
        $regex=[regex]::new($pattern,[Text.RegularExpressions.RegexOptions]::CultureInvariant,[timespan]::FromSeconds(1));$match=$regex.Match($Query,$offset)
        if(-not $match.Success -or $match.Index -ne $offset){throw ('Syntaxe WQL non prise en charge à la position '+$offset+'. SELECT de propriétés explicites uniquement.')}
        $kind=@('String','Number','Identifier','Operator','Symbol')|Where-Object{$match.Groups[$_].Success}|Select-Object -First 1
        $tokens.Add([pscustomobject]@{Kind=$kind;Text=$match.Groups[$kind].Value});$offset=$match.Index+$match.Length
        if($tokens.Count -gt 512){throw 'SELECT limité à 512 éléments.'}
    }
    $state=@{Tokens=$tokens;Index=0;Known=$KnownProperties;Used=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)}
    function Read-DomeniaWqlToken($State,[string]$Text='',[string]$Kind=''){
        if($State.Index -ge $State.Tokens.Count){throw 'SELECT incomplet.'};$token=$State.Tokens[$State.Index]
        if(($Text -and $token.Text -ine $Text) -or ($Kind -and $token.Kind -cne $Kind)){throw ('SELECT : '+$(if($Text){$Text}else{$Kind})+' attendu.')};$State.Index++;return $token
    }
    function Assert-DomeniaWqlProperty($State,[string]$Name){
        if($Name -match '(?i)password|passwd|pwd|secret|token|credential|recoverykey|privatekey|productkey|cleartext'){throw 'Une propriété de secret ne peut pas être conservée dans une requête.'}
        if($null -ne $State.Known -and $Name -notin $State.Known){throw ('Propriété absente du schéma lu : '+$Name)}
        [void]$State.Used.Add($Name)
    }
    function Read-DomeniaWqlPredicate($State,[int]$Depth){
        if($Depth -gt 8){throw 'Conditions WQL limitées à 8 niveaux.'}
        if($State.Index -ge $State.Tokens.Count){throw 'Condition WQL incomplète.'}
        $token=$State.Tokens[$State.Index]
        if($token.Text -ieq 'NOT'){[void](Read-DomeniaWqlToken $State 'NOT');Read-DomeniaWqlPredicate $State ($Depth+1);return}
        if($token.Text -eq '('){[void](Read-DomeniaWqlToken $State '(');Read-DomeniaWqlOr $State ($Depth+1);[void](Read-DomeniaWqlToken $State ')');return}
        $field=(Read-DomeniaWqlToken $State -Kind Identifier).Text;Assert-DomeniaWqlProperty $State $field
        $operator=Read-DomeniaWqlToken $State
        if($operator.Text -ieq 'IS'){
            if($State.Index -lt $State.Tokens.Count -and $State.Tokens[$State.Index].Text -ieq 'NOT'){[void](Read-DomeniaWqlToken $State 'NOT')}
            [void](Read-DomeniaWqlToken $State 'NULL');return
        }
        if($operator.Kind -ne 'Operator' -and $operator.Text -ine 'LIKE'){throw 'Comparateur WQL non pris en charge.'}
        $literal=Read-DomeniaWqlToken $State
        if($literal.Kind -notin @('String','Number') -and $literal.Text -notin @('TRUE','FALSE','NULL')){throw 'Une valeur WQL doit être un texte entre apostrophes, un nombre, TRUE, FALSE ou NULL.'}
        if($operator.Text -ieq 'LIKE' -and $literal.Kind -ne 'String'){throw 'LIKE attend un texte entre apostrophes.'}
    }
    function Read-DomeniaWqlAnd($State,[int]$Depth){Read-DomeniaWqlPredicate $State $Depth;while($State.Index -lt $State.Tokens.Count -and $State.Tokens[$State.Index].Text -ieq 'AND'){[void](Read-DomeniaWqlToken $State 'AND');Read-DomeniaWqlPredicate $State $Depth}}
    function Read-DomeniaWqlOr($State,[int]$Depth){Read-DomeniaWqlAnd $State $Depth;while($State.Index -lt $State.Tokens.Count -and $State.Tokens[$State.Index].Text -ieq 'OR'){[void](Read-DomeniaWqlToken $State 'OR');Read-DomeniaWqlAnd $State $Depth}}
    [void](Read-DomeniaWqlToken $state 'SELECT');$properties=[Collections.Generic.List[string]]::new()
    do{
        $property=(Read-DomeniaWqlToken $state -Kind Identifier).Text;Assert-DomeniaWqlProperty $state $property
        if($property -in $properties){throw 'Propriété SELECT dupliquée.'};$properties.Add($property)
        if($properties.Count -gt 64){throw 'SELECT limité à 64 propriétés.'}
        if($state.Index -lt $tokens.Count -and $tokens[$state.Index].Text -eq ','){[void](Read-DomeniaWqlToken $state ',')}else{break}
    }while($true)
    [void](Read-DomeniaWqlToken $state 'FROM');$class=(Read-DomeniaWqlToken $state -Kind Identifier).Text
    if($class.Length -gt 128){throw 'Nom de classe trop long.'}
    if($state.Index -lt $tokens.Count){[void](Read-DomeniaWqlToken $state 'WHERE');Read-DomeniaWqlOr $state 0}
    if($state.Index -ne $tokens.Count){throw 'Une seule instruction SELECT est autorisée.'}
    $canonical=($tokens|ForEach-Object{$_.Text}) -join ' '
    [pscustomobject]@{ClassName=$class;Properties=$properties.ToArray();ReferencedProperties=@($state.Used);CanonicalQuery=$canonical}
}
function Assert-DomeniaQuerySchemaTarget {
    param([string]$Namespace,[string]$ClassName,[string[]]$MsiClassNames)
    if($Namespace -notmatch '^root(?:\\[A-Za-z_][A-Za-z0-9_]*)*$' -or $Namespace.Length -gt 256){throw 'Espace de noms WMI invalide.'}
    if($ClassName -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,127}$'){throw 'Nom de classe WMI invalide.'}
    if(-not @($MsiClassNames).Count){throw 'Garde du fournisseur MSI indisponible.'}
    if($ClassName -in $MsiClassNames){throw 'Fournisseur MSI interdit : sa lecture peut déclencher une vérification ou une réparation.'}
}
function Get-DomeniaQuerySchemaRequestKey {
    param([string]$Namespace,[string]$CanonicalQuery)
    $hash=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Namespace.ToLowerInvariant()+"`n"+$CanonicalQuery))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
}

function New-DomeniaQueryReadDefinition {
    param([string]$Namespace,[string]$Query,[int]$Limit=100)
    $plan=ConvertFrom-DomeniaWqlSelect $Query
    Assert-DomeniaQuerySchemaTarget $Namespace $plan.ClassName @(Get-DomeniaMsiProviderClassNames)
    if($Limit -lt 1 -or $Limit -gt 2000){throw 'La définition WMI accepte entre 1 et 2 000 instances.'}
    [pscustomobject]@{Format='Domenia.WmiRead/1';Namespace=$Namespace;ClassName=$plan.ClassName;CanonicalQuery=$plan.CanonicalQuery;Properties=$plan.Properties;RequestKey=(Get-DomeniaQuerySchemaRequestKey $Namespace $plan.CanonicalQuery);Limit=$Limit}
}
function Assert-DomeniaQueryReadDefinition {
    param($Definition)
    if($null -eq $Definition){return}
    foreach($property in $Definition.PSObject.Properties){if($property.Name -cnotin @('Format','Namespace','ClassName','CanonicalQuery','Properties','RequestKey','Limit')){throw ('Propriété de lecture WMI inconnue : '+$property.Name)}}
    if([string]$Definition.Format -cne 'Domenia.WmiRead/1'){throw 'Format de définition WMI inconnu.'}
    $expected=New-DomeniaQueryReadDefinition -Namespace ([string]$Definition.Namespace) -Query ([string]$Definition.CanonicalQuery) -Limit ([int]$Definition.Limit)
    if($expected.RequestKey -cne [string]$Definition.RequestKey -or $expected.ClassName -cne [string]$Definition.ClassName -or $expected.CanonicalQuery -cne [string]$Definition.CanonicalQuery -or ($expected.Properties -join "`n") -cne (@($Definition.Properties) -join "`n")){throw 'Définition WMI ou empreinte incohérente.'}
}
function Get-DomeniaQueryReadDefinitionFields {
    param($Recipe)
    $definition=Get-DomeniaMemberValue $Recipe 'ReadDefinition';if($null -eq $definition){return @()}
    $prefix='detail:'+([string]$definition.RequestKey)+':'
    @([pscustomobject]@{Id=($prefix+'exists');Name=('WMI '+$definition.ClassName+' · au moins une instance correspond');Kind='Boolean';ProbeId='';Category='SELECT mémorisé';Unit='Oui / Non'},[pscustomobject]@{Id=($prefix+'count');Name=('WMI '+$definition.ClassName+' · nombre complet d’instances');Kind='Number';ProbeId='';Category='SELECT mémorisé';Unit='Instances'})
}
function Add-DomeniaQueryDetailRecords {
    param($Records,[object[]]$Details=@(),[datetime]$NowUtc=[datetime]::UtcNow,[int]$MaxAgeDays=30)
    $byGuid=@{}
    foreach($detail in $Details){
        $guid=([string]$detail.Guid).ToLowerInvariant();$key=[string]$detail.RequestKey
        if($guid -notmatch '^[0-9a-f-]{36}$' -or $key -cnotmatch '^[0-9a-f]{64}$' -or [string]$detail.ResultKind -cne 'WmiQuery'){continue}
        if(-not $byGuid.ContainsKey($guid)){$byGuid[$guid]=[Collections.Generic.List[object]]::new()};$byGuid[$guid].Add($detail)
    }
    $output=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
    foreach($record in $Records){
        $v=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        # Custom detail fields are replaced as one read snapshot; stale cached fields never survive an empty SQL result.
        foreach($pair in $record.Values.GetEnumerator()){if($pair.Key -notmatch '^(detail:|_at:detail:|_quality:detail:)'){$v[$pair.Key]=$pair.Value}}
        foreach($detail in @($byGuid[$record.Id.ToLowerInvariant()])){
            if($null -eq $detail){continue};$prefix='detail:'+([string]$detail.RequestKey)+':';$data=$detail.Data
            $at=ConvertFrom-DomeniaUtcText ([string]$detail.LastSuccessAtUtc)
            $quality=if([string]$detail.Status -ne 'Success'){'Erreur de lecture'}elseif($null -eq $at -or $at -gt $NowUtc.AddMinutes(5)){'Date de relevé inconnue'}elseif(($NowUtc-$at).TotalDays -gt $MaxAgeDays){'Expiré'}else{''}
            if($quality){$v['_quality:'+$prefix+'exists']=$quality;$v['_quality:'+$prefix+'count']=$quality;continue}
            if($null -eq $data -or [string]$data.Mode -cne 'Select' -or [string]$data.RequestKey -cne [string]$detail.RequestKey -or [string]$detail.RequestKey -cne (Get-DomeniaQuerySchemaRequestKey $data.Namespace $data.CanonicalQuery)){continue}
            $v['_at:detail:'+[string]$detail.RequestKey]=$at.ToUniversalTime().ToString('o')
            $rows=[long]$data.StoredCount
            if($rows -gt 0){$v[$prefix+'exists']=$true}elseif([bool]$data.CountComplete){$v[$prefix+'exists']=$false}
            if([bool]$data.CountComplete -and -not [bool]$data.Truncated){$v[$prefix+'count']=$rows}else{$v['_quality:'+$prefix+'count']='Lecture incomplète'}
        }
        $output.Add([M4D.Admin.Common.Query.QueryRecord]::new($record.Id,$v))
    }
    return ,$output
}
