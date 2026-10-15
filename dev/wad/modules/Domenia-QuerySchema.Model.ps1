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
    $state=@{Tokens=$tokens;Index=0;Known=$KnownProperties;Used=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);WhereUsed=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)}
    function Read-DomeniaWqlToken($State,[string]$Text='',[string]$Kind=''){
        if($State.Index -ge $State.Tokens.Count){throw 'SELECT incomplet.'};$token=$State.Tokens[$State.Index]
        if(($Text -and $token.Text -ine $Text) -or ($Kind -and $token.Kind -cne $Kind)){throw ('SELECT : '+$(if($Text){$Text}else{$Kind})+' attendu.')};$State.Index++;return $token
    }
    function Assert-DomeniaWqlProperty($State,[string]$Name){
        if($Name -match '(?i)password|passwd|pwd|secret|token|credential|recoverykey|privatekey|productkey|cleartext'){throw 'Une propriété de secret ne peut pas être conservée dans une requête.'}
        if($null -ne $State.Known -and $Name -notin $State.Known){throw ('Propriété absente du schéma lu : '+$Name)}
        [void]$State.Used.Add($Name)
    }
    # Each reader returns $true when its condition guarantees LocalAccount = TRUE: a predicate of that exact form, an
    # AND with at least one such operand, an OR whose every branch has one. NOT never guarantees it. Every operand is
    # always parsed: no short-circuit operator is used between two reads.
    function Read-DomeniaWqlPredicate($State,[int]$Depth){
        if($Depth -gt 8){throw 'Conditions WQL limitées à 8 niveaux.'}
        if($State.Index -ge $State.Tokens.Count){throw 'Condition WQL incomplète.'}
        $token=$State.Tokens[$State.Index]
        if($token.Text -ieq 'NOT'){[void](Read-DomeniaWqlToken $State 'NOT');[void](Read-DomeniaWqlPredicate $State ($Depth+1));return $false}
        if($token.Text -eq '('){[void](Read-DomeniaWqlToken $State '(');$local=Read-DomeniaWqlOr $State ($Depth+1);[void](Read-DomeniaWqlToken $State ')');return [bool]$local}
        $field=(Read-DomeniaWqlToken $State -Kind Identifier).Text;Assert-DomeniaWqlProperty $State $field;[void]$State.WhereUsed.Add($field)
        $operator=Read-DomeniaWqlToken $State
        if($operator.Text -ieq 'IS'){
            if($State.Index -lt $State.Tokens.Count -and $State.Tokens[$State.Index].Text -ieq 'NOT'){[void](Read-DomeniaWqlToken $State 'NOT')}
            [void](Read-DomeniaWqlToken $State 'NULL');return $false
        }
        if($operator.Kind -ne 'Operator' -and $operator.Text -ine 'LIKE'){throw 'Comparateur WQL non pris en charge.'}
        $literal=Read-DomeniaWqlToken $State
        if($literal.Kind -notin @('String','Number') -and $literal.Text -notin @('TRUE','FALSE','NULL')){throw 'Une valeur WQL doit être un texte entre apostrophes, un nombre, TRUE, FALSE ou NULL.'}
        if($operator.Text -ieq 'LIKE' -and $literal.Kind -ne 'String'){throw 'LIKE attend un texte entre apostrophes.'}
        return (($field -ieq 'LocalAccount') -and ($operator.Text -ceq '=') -and ($literal.Kind -ceq 'Identifier') -and ($literal.Text -ieq 'TRUE'))
    }
    function Read-DomeniaWqlAnd($State,[int]$Depth){
        $local=Read-DomeniaWqlPredicate $State $Depth
        while($State.Index -lt $State.Tokens.Count -and $State.Tokens[$State.Index].Text -ieq 'AND'){[void](Read-DomeniaWqlToken $State 'AND');$next=Read-DomeniaWqlPredicate $State $Depth;if($next){$local=$true}}
        return [bool]$local
    }
    function Read-DomeniaWqlOr($State,[int]$Depth){
        $local=Read-DomeniaWqlAnd $State $Depth
        while($State.Index -lt $State.Tokens.Count -and $State.Tokens[$State.Index].Text -ieq 'OR'){[void](Read-DomeniaWqlToken $State 'OR');$next=Read-DomeniaWqlAnd $State $Depth;if(-not $next){$local=$false}}
        return [bool]$local
    }
    [void](Read-DomeniaWqlToken $state 'SELECT');$properties=[Collections.Generic.List[string]]::new()
    do{
        $property=(Read-DomeniaWqlToken $state -Kind Identifier).Text;Assert-DomeniaWqlProperty $state $property
        if($property -in $properties){throw 'Propriété SELECT dupliquée.'};$properties.Add($property)
        if($properties.Count -gt 64){throw 'SELECT limité à 64 propriétés.'}
        if($state.Index -lt $tokens.Count -and $tokens[$state.Index].Text -eq ','){[void](Read-DomeniaWqlToken $state ',')}else{break}
    }while($true)
    [void](Read-DomeniaWqlToken $state 'FROM');$class=(Read-DomeniaWqlToken $state -Kind Identifier).Text
    if($class.Length -gt 128){throw 'Nom de classe trop long.'}
    $localOnly=$false
    if($state.Index -lt $tokens.Count){[void](Read-DomeniaWqlToken $state 'WHERE');$localOnly=Read-DomeniaWqlOr $state 0}
    if($state.Index -ne $tokens.Count){throw 'Une seule instruction SELECT est autorisée.'}
    Assert-DomeniaWqlAccountScope -ClassName $class -LocalAccountOnly ([bool]$localOnly)
    $canonical=($tokens|ForEach-Object{$_.Text}) -join ' '
    [pscustomobject]@{ClassName=$class;Properties=$properties.ToArray();ReferencedProperties=@($state.Used);WhereProperties=@($state.WhereUsed);CanonicalQuery=$canonical}
}
function Assert-DomeniaWqlAccountScope {
    # Never a whole-domain scan. On a domain member, the account classes enumerate every account or group of the domain
    # from the workstation: they require LocalAccount = TRUE in every branch of the WHERE clause. A fixed Domain = name
    # is not accepted: a recipe runs on every workstation of its OU, where that name is not the local one. Associations
    # and generic parent classes that also return domain accounts cannot be restricted this way and are refused.
    param([string]$ClassName,[bool]$LocalAccountOnly)
    $remedy=' Lisez les comptes et groupes locaux avec Win32_UserAccount ou Win32_Group WHERE LocalAccount = TRUE.'
    $refused=[ordered]@{
        Win32_GroupUser='elle énumère les appartenances de tous les groupes du domaine depuis le poste'
        Win32_GroupInDomain='elle énumère tous les groupes du domaine depuis le poste'
        Win32_UserInDomain='elle énumère tous les comptes du domaine depuis le poste'
        Win32_AccountSID='elle énumère tous les comptes du domaine depuis le poste'
        CIM_LogicalElement='cette classe générique inclut les comptes du domaine et chaque fichier du disque'
        CIM_ManagedSystemElement='cette classe générique inclut les comptes du domaine et chaque fichier du disque'
    }
    foreach($name in $refused.Keys){if($ClassName -ieq $name){throw ('Classe '+$name+' refusée : '+$refused[$name]+'.'+$remedy)}}
    if(($ClassName -in @('Win32_Account','Win32_UserAccount','Win32_Group')) -and (-not $LocalAccountOnly)){
        throw ('Classe '+$ClassName+' refusée sans LocalAccount = TRUE : depuis un poste du domaine, elle énumère tous les comptes ou groupes du domaine. Ajoutez LocalAccount = TRUE à la condition WHERE, dans chaque branche OU, pour ne lire que les comptes locaux du poste.')
    }
}
function Assert-DomeniaQuerySchemaNamespace {
    param([string]$Namespace)
    if($Namespace -notmatch '^root(?:\\[A-Za-z_][A-Za-z0-9_]*)*$' -or $Namespace.Length -gt 256){throw 'Espace de noms WMI invalide.'}
}
function Assert-DomeniaQuerySchemaClassFilter {
    # Class list filter: a class name, optionally ending with one wildcard (Win32_*). Never a WQL fragment.
    param([string]$Filter)
    if($Filter -and $Filter -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,126}\*?$'){throw 'Filtre de classes invalide : un nom de classe, éventuellement terminé par *.'}
}
function Assert-DomeniaQuerySchemaTarget {
    param([string]$Namespace,[string]$ClassName,[string[]]$MsiClassNames)
    Assert-DomeniaQuerySchemaNamespace $Namespace
    if($ClassName -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,127}$'){throw 'Nom de classe WMI invalide.'}
    if(-not @($MsiClassNames).Count){throw 'Garde du fournisseur MSI indisponible.'}
    if($ClassName -in $MsiClassNames){throw 'Fournisseur MSI interdit : sa lecture peut déclencher une vérification ou une réparation.'}
}
function Get-DomeniaWmiRelationPresets {
    # Relations a provider declares (association classes) or exposes through an identity property. A reference
    # relation reads the target by its key at the time of the read; a process identifier can be reused later.
    param([string]$ClassName='')
    $all=@(
        [pscustomobject]@{Source='Win32_DiskDrive';Kind='Association';Association='Win32_DiskDriveToDiskPartition';Result='Win32_DiskPartition';SourceProperty='';TargetProperty='';ValueKind='';Properties=@();Label='Partitions de ce disque physique'}
        [pscustomobject]@{Source='Win32_DiskPartition';Kind='Association';Association='Win32_DiskDriveToDiskPartition';Result='Win32_DiskDrive';SourceProperty='';TargetProperty='';ValueKind='';Properties=@();Label='Disque physique qui porte cette partition'}
        [pscustomobject]@{Source='Win32_DiskPartition';Kind='Association';Association='Win32_LogicalDiskToPartition';Result='Win32_LogicalDisk';SourceProperty='';TargetProperty='';ValueKind='';Properties=@();Label='Volume logique de cette partition'}
        [pscustomobject]@{Source='Win32_LogicalDisk';Kind='Association';Association='Win32_LogicalDiskToPartition';Result='Win32_DiskPartition';SourceProperty='';TargetProperty='';ValueKind='';Properties=@();Label='Partition qui porte ce volume'}
        [pscustomobject]@{Source='Win32_NetworkAdapter';Kind='Association';Association='Win32_NetworkAdapterSetting';Result='Win32_NetworkAdapterConfiguration';SourceProperty='';TargetProperty='';ValueKind='';Properties=@();Label='Configuration IP de cette carte'}
        [pscustomobject]@{Source='Win32_NetworkAdapterConfiguration';Kind='Association';Association='Win32_NetworkAdapterSetting';Result='Win32_NetworkAdapter';SourceProperty='';TargetProperty='';ValueKind='';Properties=@();Label='Carte réseau de cette configuration'}
        [pscustomobject]@{Source='Win32_Service';Kind='Association';Association='Win32_DependentService';Result='Win32_Service';SourceProperty='';TargetProperty='';ValueKind='';Properties=@();Label='Services liés par dépendance (dans les deux sens)'}
        [pscustomobject]@{Source='Win32_Service';Kind='Reference';Association='';Result='Win32_Process';SourceProperty='ProcessId';TargetProperty='Handle';ValueKind='String';Properties=@('Name','ProcessId','ParentProcessId','CreationDate','ExecutablePath');Label='Processus qui héberge ce service, au moment de la lecture'}
        [pscustomobject]@{Source='Win32_Process';Kind='Reference';Association='';Result='Win32_Service';SourceProperty='Handle';TargetProperty='ProcessId';ValueKind='Number';Properties=@('Name','DisplayName','State','StartMode','ProcessId');Label='Services hébergés par ce processus, au moment de la lecture'}
    )
    if(-not $ClassName){return $all}
    return @($all|Where-Object{$_.Source -ieq $ClassName})
}
function Get-DomeniaWmiRelationPreset {
    # Exact reference relation allowed for a worker read; $null for anything else. No free-form join is accepted.
    param([string]$SourceClass,[string]$SourceProperty,[string]$TargetClass,[string]$TargetProperty)
    foreach($preset in @(Get-DomeniaWmiRelationPresets $SourceClass)){
        if($preset.Kind -ceq 'Reference' -and $preset.SourceProperty -ieq $SourceProperty -and $preset.Result -ieq $TargetClass -and $preset.TargetProperty -ieq $TargetProperty){return $preset}
    }
    return $null
}
function ConvertTo-DomeniaWmiReferenceValue {
    # Identity value of a reference relation: digits only, never zero (a stopped service has no hosting process).
    param($Preset,$Value)
    if($null -eq $Value -or $Value -is [array]){throw ('La propriété '+[string]$Preset.SourceProperty+' nʼa pas été lue pour cette instance : ajoutez-la au SELECT puis exécutez-le à nouveau.')}
    $text=([string]$Value).Trim()
    if($text -notmatch '^[0-9]{1,10}$'){throw ('Identifiant '+[string]$Preset.SourceProperty+' invalide : la relation nʼest pas lue.')}
    $number=[long]$text
    if($number -le 0 -or $number -gt 4294967295){throw ('Aucun processus associé ('+[string]$Preset.SourceProperty+' = '+$text+') : un service arrêté nʼa pas de processus hôte.')}
    return $number.ToString([Globalization.CultureInfo]::InvariantCulture)
}
function Get-DomeniaWqlProviderWarnings {
    # Known costly providers. The list is not exhaustive: a syntax check never proves that a provider is inert.
    param([string]$ClassName,[bool]$HasWhere)
    $costly=[ordered]@{
        CIM_DataFile='parcourt les fichiers du disque';CIM_Directory='parcourt les dossiers du disque';Win32_Directory='parcourt les dossiers du disque'
        Win32_ShortcutFile='parcourt les raccourcis du disque';Win32_NTLogEvent='lit les journaux dʼévénements, parfois très volumineux'
        Win32_ReliabilityRecords='lit lʼhistorique de fiabilité, lent sur un poste ancien';Win32_PnPSignedDriver='interroge chaque pilote, lentement'
    }
    $warnings=[Collections.Generic.List[string]]::new()
    foreach($name in $costly.Keys){if($ClassName -ieq $name){$warnings.Add('Classe '+$name+' : '+$costly[$name]+'.'+$(if(-not $HasWhere){' Sans clause WHERE, la lecture porte sur tout ce périmètre.'}else{''}))}}
    $warnings.Add('La validation syntaxique ne garantit pas quʼun fournisseur est sans effet de bord : testez la requête sur un poste choisi avant dʼen faire une recette.')
    return $warnings.ToArray()
}
function Get-DomeniaWqlPlanReport {
    # Local review of a WQL SELECT before any remote read: requested and identity properties, preconditions,
    # limits, known provider costs and test status. Pure: the schema is the one already stored for the workstation.
    param([string]$Namespace,[string]$Query,[int]$Limit=100,[string[]]$KnownProperties=@(),[string[]]$KeyProperties=@(),[string]$SchemaClass='',$Tested=$null,[string]$Computer='')
    $report=[ordered]@{Valid=$false;Message='';ClassName='';CanonicalQuery='';Properties=@();KeyProperties=@();ReferencedProperties=@();MissingProperties=@();Preconditions=@();Limits=@();Warnings=@();Ready=$false;ReadyText='';Text=''}
    try{
        $plan=ConvertFrom-DomeniaWqlSelect $Query
        Assert-DomeniaQuerySchemaTarget $Namespace $plan.ClassName @(Get-DomeniaMsiProviderClassNames)
        if($Limit -lt 1 -or $Limit -gt 2000){throw 'Choisissez une limite entre 1 et 2 000 instances.'}
    }catch{$report.Message=$_.Exception.Message;$report.Text='Requête non exécutable : '+$report.Message;return [pscustomobject]$report}
    $report.Valid=$true;$report.ClassName=$plan.ClassName;$report.CanonicalQuery=$plan.CanonicalQuery;$report.Properties=@($plan.Properties)
    $schemaKnown=($SchemaClass -and $SchemaClass -ieq $plan.ClassName -and @($KnownProperties).Count -gt 0)
    if($schemaKnown){
        $report.MissingProperties=@($plan.ReferencedProperties|Where-Object{$_ -notin @($KnownProperties)})
        $report.KeyProperties=@($KeyProperties|Where-Object{$_ -notin @($plan.Properties)})
    }
    $report.ReferencedProperties=@($plan.ReferencedProperties)
    $preconditions=[Collections.Generic.List[string]]::new()
    $preconditions.Add($(if($Computer){'Poste choisi : '+$Computer+'.'}else{'Ouvrez la fiche du poste à interroger : aucune lecture sans poste choisi.'}))
    $preconditions.Add('Connexion CIM (DCOM, ou WinRM si activé) avec le compte distant configuré ; un refus dʼauthentification suspend les lectures.')
    $preconditions.Add('Droit de lecture sur lʼespace de noms '+$Namespace+'.')
    if($schemaKnown){
        $preconditions.Add('Schéma de '+$plan.ClassName+' relu pour ce poste : propriétés vérifiées.')
        if(@($report.MissingProperties).Count){$preconditions.Add('Propriétés absentes du schéma relu : '+(@($report.MissingProperties) -join ', ')+'. La lecture sera refusée.')}
    }else{$preconditions.Add('Schéma de '+$plan.ClassName+' non relu pour ce poste : la classe et les propriétés seront vérifiées au moment de la lecture.')}
    $report.Preconditions=$preconditions.ToArray()
    $identity=if(@($report.KeyProperties).Count){', plus les clés '+(@($report.KeyProperties) -join ', ')+' pour conserver lʼidentité des instances'}elseif(-not $schemaKnown){', plus les clés du fournisseur pour conserver lʼidentité des instances'}else{''}
    $report.Limits=@(
        ($Limit.ToString()+' instances au plus, 1 Mio de résultats conservés et 50 secondes de lecture.'),
        ('Seules les propriétés citées sont demandées'+$identity+' ; aucune méthode WMI nʼest appelée.'),
        'Un résultat partiel (limite ou budget atteint) reste marqué comme tel ; il nʼest jamais présenté comme complet.')
    $report.Warnings=@(Get-DomeniaWqlProviderWarnings -ClassName $plan.ClassName -HasWhere (@($plan.WhereProperties).Count -gt 0))
    $testedQuery=[string](Get-DomeniaMember $Tested 'CanonicalQuery');$testedComputer=[string](Get-DomeniaMember $Tested 'Computer')
    $report.Ready=($null -ne $Tested -and [string](Get-DomeniaMember $Tested 'Mode') -ceq 'Select' -and $testedQuery -ceq $plan.CanonicalQuery -and [string](Get-DomeniaMember $Tested 'Namespace') -ieq $Namespace -and $Computer -and $testedComputer -ieq $Computer)
    $report.ReadyText=if($report.Ready){'Testée sur '+$testedComputer+' (résultat enregistré le '+[string](Get-DomeniaMember $Tested 'At')+') : la recette locale peut être préparée.'}else{'Pas encore testée sous cette forme sur ce poste : exécutez-la avant dʼen faire une recette.'}
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add('Classe : '+$plan.ClassName+' · espace de noms : '+$Namespace)
    $lines.Add('Propriétés demandées : '+(@($plan.Properties) -join ', ')+$(if(@($report.KeyProperties).Count){' (+ clés : '+(@($report.KeyProperties) -join ', ')+')'}else{''}))
    $lines.Add($(if(@($plan.WhereProperties).Count){'Condition WHERE sur : '+(@($plan.WhereProperties) -join ', ')}else{'Aucune condition WHERE : toutes les instances de la classe, dans la limite choisie.'}))
    $lines.Add('Préconditions :');foreach($line in $report.Preconditions){$lines.Add(' • '+$line)}
    $lines.Add('Limites :');foreach($line in $report.Limits){$lines.Add(' • '+$line)}
    $lines.Add('Prudence :');foreach($line in $report.Warnings){$lines.Add(' • '+$line)}
    $lines.Add($report.ReadyText)
    $report.Text=[string]::Join("`r`n",$lines.ToArray())
    return [pscustomobject]$report
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
    [void](Assert-DomeniaContractFormat -Format ([string]$Definition.Format) -Family 'Domenia.WmiRead')
    $expected=New-DomeniaQueryReadDefinition -Namespace ([string]$Definition.Namespace) -Query ([string]$Definition.CanonicalQuery) -Limit ([int]$Definition.Limit)
    if($expected.RequestKey -cne [string]$Definition.RequestKey -or $expected.ClassName -cne [string]$Definition.ClassName -or $expected.CanonicalQuery -cne [string]$Definition.CanonicalQuery -or ($expected.Properties -join "`n") -cne (@($Definition.Properties) -join "`n")){throw 'Définition WMI ou empreinte incohérente.'}
}
function Get-DomeniaQueryReadDefinitionFields {
    param($Recipe)
    $definition=Get-DomeniaMemberValue $Recipe 'ReadDefinition';if($null -eq $definition){return @()}
    $prefix='detail:'+([string]$definition.RequestKey)+':'
    @([pscustomobject]@{Id=($prefix+'exists');Name=('WMI '+$definition.ClassName+' · au moins une instance correspond');Kind='Boolean';ProbeId='';Category='SELECT mémorisé';Unit='Oui / Non'},[pscustomobject]@{Id=($prefix+'count');Name=('WMI '+$definition.ClassName+' · nombre complet d''instances');Kind='Number';ProbeId='';Category='SELECT mémorisé';Unit='Instances'})
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
