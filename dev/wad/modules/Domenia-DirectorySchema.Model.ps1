# Points 28 and 29: read-only view of the Active Directory schema (types, cardinality, index, description) and the
# cost of an LDAP filter before it is sent. Pure rules over values already read: no LDAP, no schema change, no disk.

# ---------------------------------------------------------------- point 28: schema definitions
function Get-DomeniaAdSyntaxLabel {
    # attributeSyntax OID of an attributeSchema entry, in plain words.
    param([AllowEmptyString()][AllowNull()][string]$AttributeSyntax)
    switch(([string]$AttributeSyntax).Trim()){
        '2.5.5.1' {return 'Référence à un objet (DN)'}
        '2.5.5.2' {return 'Identifiant OID'}
        '2.5.5.3' {return 'Texte sensible à la casse'}
        '2.5.5.4' {return 'Texte (Teletex)'}
        '2.5.5.5' {return 'Texte ASCII (IA5 ou imprimable)'}
        '2.5.5.6' {return 'Texte numérique'}
        '2.5.5.7' {return 'Référence avec données (DN binaire)'}
        '2.5.5.8' {return 'Booléen'}
        '2.5.5.9' {return 'Entier'}
        '2.5.5.10' {return 'Octets'}
        '2.5.5.11' {return 'Date et heure'}
        '2.5.5.12' {return 'Texte Unicode'}
        '2.5.5.13' {return 'Adresse de présentation'}
        '2.5.5.14' {return 'Référence avec texte (DN chaîne)'}
        '2.5.5.15' {return 'Descripteur de sécurité'}
        '2.5.5.16' {return 'Grand entier (compteur ou date FILETIME)'}
        '2.5.5.17' {return 'SID'}
    }
    return 'Syntaxe non reconnue'
}

function Get-DomeniaAdSyntaxKind {
    # Family used to suggest a filter: Dn, Text, Bool, Int, LargeInt, Time, Binary, Sid or Other.
    param([AllowEmptyString()][AllowNull()][string]$AttributeSyntax)
    $oid=([string]$AttributeSyntax).Trim()
    if($oid -in @('2.5.5.1','2.5.5.7','2.5.5.14')){return 'Dn'}
    if($oid -in @('2.5.5.2','2.5.5.3','2.5.5.4','2.5.5.5','2.5.5.6','2.5.5.12')){return 'Text'}
    if($oid -eq '2.5.5.8'){return 'Bool'}
    if($oid -eq '2.5.5.9'){return 'Int'}
    if($oid -eq '2.5.5.16'){return 'LargeInt'}
    if($oid -eq '2.5.5.11'){return 'Time'}
    if($oid -in @('2.5.5.10','2.5.5.15')){return 'Binary'}
    if($oid -eq '2.5.5.17'){return 'Sid'}
    return 'Other'
}

function ConvertFrom-DomeniaAdSearchFlags {
    # searchFlags bits of an attributeSchema entry.
    param([long]$Value=0)
    return [pscustomobject]@{
        Indexed=(($Value -band 1) -ne 0);ContainerIndexed=(($Value -band 2) -ne 0);Anr=(($Value -band 4) -ne 0)
        PreserveOnDelete=(($Value -band 8) -ne 0);Copy=(($Value -band 16) -ne 0);TupleIndexed=(($Value -band 32) -ne 0)
        SubtreeIndexed=(($Value -band 64) -ne 0);Confidential=(($Value -band 128) -ne 0);NeverAudit=(($Value -band 256) -ne 0)
        RodcFiltered=(($Value -band 512) -ne 0)
    }
}

function ConvertFrom-DomeniaAdSystemFlags {
    # systemFlags bits of an attributeSchema entry.
    param([long]$Value=0)
    return [pscustomobject]@{
        NotReplicated=(($Value -band 1) -ne 0);PartialSetRequired=(($Value -band 2) -ne 0);Constructed=(($Value -band 4) -ne 0)
        Operational=(($Value -band 8) -ne 0);BaseSchema=(($Value -band 16) -ne 0);Rdn=(($Value -band 32) -ne 0)
    }
}

function Get-DomeniaAdClassCategoryLabel {
    param([long]$Category=1)
    switch($Category){
        0 {return 'Classe 88'}
        1 {return 'Structurelle'}
        2 {return 'Abstraite'}
        3 {return 'Auxiliaire'}
    }
    return 'Inconnue'
}

function ConvertTo-DomeniaAdSchemaCatalog {
    # Indexes the schema read once (attributeSchema and classSchema entries) by lower-case lDAPDisplayName.
    # Defunct entries are kept and flagged: they cannot serve a new query.
    param([object[]]$Attributes=@(),[object[]]$Classes=@(),[string]$Server='',[string]$ObservedUtc='',[bool]$Truncated=$false,[string]$DomainDn='')
    $attributeMap=@{};$classMap=@{}
    foreach($a in @($Attributes)){
        $name=[string](Get-DomeniaMember $a 'Name' '')
        if($name -notmatch '^[A-Za-z0-9-]{1,128}$'){continue}
        $search=ConvertFrom-DomeniaAdSearchFlags ([long](Get-DomeniaMember $a 'SearchFlags' 0))
        $system=ConvertFrom-DomeniaAdSystemFlags ([long](Get-DomeniaMember $a 'SystemFlags' 0))
        $syntax=[string](Get-DomeniaMember $a 'Syntax' '')
        $attributeMap[$name.ToLowerInvariant()]=[pscustomobject]@{
            Name=$name;Description=(ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $a 'Description' '')) 500)
            Syntax=$syntax;SyntaxLabel=(Get-DomeniaAdSyntaxLabel $syntax);Kind=(Get-DomeniaAdSyntaxKind $syntax)
            SingleValued=[bool](Get-DomeniaMember $a 'SingleValued' $false);Indexed=[bool]$search.Indexed;TupleIndexed=[bool]$search.TupleIndexed
            Anr=[bool]$search.Anr;Confidential=[bool]$search.Confidential;Constructed=[bool]$system.Constructed;NotReplicated=[bool]$system.NotReplicated
            InGlobalCatalog=[bool](Get-DomeniaMember $a 'InGlobalCatalog' $false);Linked=([long](Get-DomeniaMember $a 'LinkId' 0) -ne 0)
            Defunct=[bool](Get-DomeniaMember $a 'Defunct' $false);RangeLower=(Get-DomeniaMember $a 'RangeLower' $null);RangeUpper=(Get-DomeniaMember $a 'RangeUpper' $null)
        }
    }
    foreach($c in @($Classes)){
        $name=[string](Get-DomeniaMember $c 'Name' '')
        if($name -notmatch '^[A-Za-z0-9-]{1,128}$'){continue}
        $classMap[$name.ToLowerInvariant()]=[pscustomobject]@{
            Name=$name;Description=(ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $c 'Description' '')) 500)
            SubClassOf=[string](Get-DomeniaMember $c 'SubClassOf' '');Auxiliary=@(Get-DomeniaMember $c 'Auxiliary' @())
            Must=@(Get-DomeniaMember $c 'Must' @());May=@(Get-DomeniaMember $c 'May' @())
            Category=(Get-DomeniaAdClassCategoryLabel ([long](Get-DomeniaMember $c 'Category' 1)));Defunct=[bool](Get-DomeniaMember $c 'Defunct' $false)
        }
    }
    return [pscustomobject]@{Attributes=$attributeMap;Classes=$classMap;Server=$Server;ObservedUtc=$ObservedUtc;Truncated=$Truncated;DomainDn=$DomainDn;AttributeCount=$attributeMap.Count;ClassCount=$classMap.Count}
}

function Get-DomeniaAdSchemaAttribute {
    # One attribute of the catalog, $null when the schema was not read or does not define it.
    param($Catalog,[AllowEmptyString()][AllowNull()][string]$Name)
    if(($null -eq $Catalog) -or (-not ([string]$Name).Trim())){return $null}
    $map=Get-DomeniaMember $Catalog 'Attributes' $null
    if($null -eq $map){return $null}
    $key=([string]$Name).Trim().ToLowerInvariant()
    if($map.ContainsKey($key)){return $map[$key]}
    return $null
}

function Get-DomeniaAdAttributeIndexText {
    param($Attribute)
    if($null -eq $Attribute){return 'Inconnu'}
    if([bool]$Attribute.Constructed){return 'Calculé, non filtrable'}
    if([bool]$Attribute.Indexed){if([bool]$Attribute.TupleIndexed){return 'Indexé, sous-chaîne comprise'};return 'Indexé'}
    return 'Non indexé'
}

function ConvertTo-DomeniaAdAttributeRow {
    param($Attribute,[bool]$Required=$false,[string]$Origin='')
    return [pscustomobject]@{
        Attribut=[string]$Attribute.Name;Obligatoire=$(if($Required){'Oui'}else{'Non'});Origine=$Origin;Type=[string]$Attribute.SyntaxLabel
        Valeurs=$(if([bool]$Attribute.SingleValued){'Une'}else{'Plusieurs'});Index=(Get-DomeniaAdAttributeIndexText $Attribute)
        CatalogueGlobal=$(if([bool]$Attribute.InGlobalCatalog){'Oui'}else{'Non'});Description=[string]$Attribute.Description;Defunct=[bool]$Attribute.Defunct
    }
}

function Get-DomeniaAdClassAttributes {
    # Attributes an object of $ClassName may carry: its own mustContain and mayContain, those of its superclasses up
    # to top and of their auxiliary classes. The walk is bounded: a schema loop never hangs the interface.
    param($Catalog,[AllowEmptyString()][AllowNull()][string]$ClassName)
    $classes=Get-DomeniaMember $Catalog 'Classes' $null
    $known=(($null -ne $classes) -and ([string]$ClassName) -and $classes.ContainsKey(([string]$ClassName).ToLowerInvariant()))
    if(-not $known){return [pscustomobject]@{Known=$false;Rows=@();Chain=@();Missing=@()}}
    $found=[ordered]@{};$chain=New-Object 'System.Collections.Generic.List[string]'
    $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $queue=New-Object 'System.Collections.Generic.Queue[string]'
    $queue.Enqueue([string]$ClassName)
    while(($queue.Count -gt 0) -and ($seen.Count -lt 256)){
        $name=$queue.Dequeue()
        if(-not $seen.Add($name)){continue}
        $key=$name.ToLowerInvariant()
        if(-not $classes.ContainsKey($key)){continue}
        $class=$classes[$key];$chain.Add([string]$class.Name)
        foreach($attribute in @($class.Must)){
            $attributeKey=([string]$attribute).ToLowerInvariant()
            if(-not $attributeKey){continue}
            if($found.Contains($attributeKey)){$found[$attributeKey].Required=$true}else{$found[$attributeKey]=[pscustomobject]@{Name=[string]$attribute;Required=$true;Origin=[string]$class.Name}}
        }
        foreach($attribute in @($class.May)){
            $attributeKey=([string]$attribute).ToLowerInvariant()
            if((-not $attributeKey) -or ($found.Contains($attributeKey))){continue}
            $found[$attributeKey]=[pscustomobject]@{Name=[string]$attribute;Required=$false;Origin=[string]$class.Name}
        }
        $parent=[string]$class.SubClassOf
        if($parent -and ($parent -ine [string]$class.Name)){$queue.Enqueue($parent)}
        foreach($auxiliary in @($class.Auxiliary)){if([string]$auxiliary){$queue.Enqueue([string]$auxiliary)}}
    }
    $rows=New-Object 'System.Collections.Generic.List[object]';$missing=New-Object 'System.Collections.Generic.List[string]'
    foreach($key in @($found.Keys)){
        $entry=$found[$key];$attribute=Get-DomeniaAdSchemaAttribute $Catalog $entry.Name
        if($null -eq $attribute){$missing.Add([string]$entry.Name);continue}
        $rows.Add((ConvertTo-DomeniaAdAttributeRow -Attribute $attribute -Required ([bool]$entry.Required) -Origin ([string]$entry.Origin)))
    }
    $ordered=@($rows.ToArray()|Sort-Object @{Expression={$_.Obligatoire -eq 'Oui'};Descending=$true},@{Expression={$_.Attribut}})
    return [pscustomobject]@{Known=$true;Rows=$ordered;Chain=$chain.ToArray();Missing=$missing.ToArray()}
}

function Find-DomeniaAdSchemaEntries {
    # Classes or attributes whose name or description contains $Text (case and accents of the text kept as typed).
    param($Catalog,[AllowEmptyString()][AllowNull()][string]$Text='',[ValidateSet('Classes','Attributes')][string]$Kind='Classes',[ValidateRange(1,5000)][int]$Limit=500)
    $term=([string]$Text).Trim()
    $map=Get-DomeniaMember $Catalog $Kind $null
    if($null -eq $map){return [pscustomobject]@{Rows=@();Total=0;Shown=0}}
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($key in @($map.Keys|Sort-Object)){
        $entry=$map[$key]
        if($term -and (([string]$entry.Name).IndexOf($term,[StringComparison]::OrdinalIgnoreCase) -lt 0) -and (([string]$entry.Description).IndexOf($term,[StringComparison]::OrdinalIgnoreCase) -lt 0)){continue}
        if($Kind -eq 'Classes'){
            $rows.Add([pscustomobject]@{Nom=[string]$entry.Name;Nature=$(if([bool]$entry.Defunct){'Obsolète'}else{[string]$entry.Category});Detail=('Hérite de '+[string]$entry.SubClassOf);Description=[string]$entry.Description;Kind='Class'})
        }else{
            $rows.Add([pscustomobject]@{Nom=[string]$entry.Name;Nature=$(if([bool]$entry.Defunct){'Obsolète'}else{[string]$entry.SyntaxLabel});Detail=($(if([bool]$entry.SingleValued){'Une valeur'}else{'Plusieurs valeurs'})+' · '+(Get-DomeniaAdAttributeIndexText $entry));Description=[string]$entry.Description;Kind='Attribute'})
        }
    }
    $total=$rows.Count
    $shown=@($rows.ToArray()|Select-Object -First $Limit)
    return [pscustomobject]@{Rows=$shown;Total=$total;Shown=$shown.Count}
}

function Get-DomeniaAdAttributeQueryHint {
    # How to use one attribute in an LDAP filter: an example clause and what the schema says about its cost.
    param($Attribute)
    if($null -eq $Attribute){return [pscustomobject]@{Example='';Notes=@('Attribut inconnu du schéma lu.')}}
    $name=[string]$Attribute.Name
    $notes=New-Object 'System.Collections.Generic.List[string]'
    $example='('+$name+'=valeur*)'
    switch([string]$Attribute.Kind){
        'Bool' {$example='('+$name+'=TRUE)'}
        'Dn' {$example='('+$name+'=CN=…,OU=…,DC=…)';$notes.Add('Valeur exacte : le chemin LDAP complet de lʼobjet visé, sans joker.')}
        'Int' {$example='('+$name+'>=1)'}
        'LargeInt' {$example='('+$name+'>=133000000000000000)';$notes.Add('Une date y est un nombre FILETIME : intervalles de 100 ns depuis le 01/01/1601 UTC.')}
        'Time' {$example='('+$name+'>=20260101000000.0Z)';$notes.Add('Date au format AAAAMMJJhhmmss.0Z, en UTC.')}
        'Sid' {$example='('+$name+'=S-1-5-21-…)'}
        'Binary' {$example='('+$name+'=\00\01…)';$notes.Add('Octets écrits en hexadécimal échappé (\xx).')}
    }
    if([bool]$Attribute.Constructed){
        $notes.Insert(0,'Attribut calculé par le contrôleur : il se lit, mais il ne sert pas de critère de filtre.')
        $example=''
    }elseif([bool]$Attribute.Indexed){
        $notes.Add('Attribut indexé : une égalité ou un début de valeur limite les objets que le contrôleur examine.')
        if(([string]$Attribute.Kind -eq 'Text') -and (-not [bool]$Attribute.TupleIndexed)){$notes.Add('Un joker en tête (*valeur) nʼutilise pas cet index.')}
    }else{
        $notes.Add('Attribut non indexé : combinez-le avec un critère sur un attribut indexé, ou limitez la recherche à une OU.')
    }
    if(-not [bool]$Attribute.SingleValued){$notes.Add('Plusieurs valeurs possibles : le filtre retient lʼobjet dès quʼune valeur correspond.')}
    if([bool]$Attribute.Confidential){$notes.Add('Attribut confidentiel : sans droit de lecture particulier, un filtre sur cet attribut ne retient aucun objet.')}
    if([bool]$Attribute.NotReplicated){$notes.Add('Non répliqué : chaque contrôleur a sa propre valeur.')}
    if([bool]$Attribute.Linked){$notes.Add('Attribut lié : sa valeur est maintenue par le contrôleur à partir de lʼattribut associé.')}
    if([bool]$Attribute.Defunct){$notes.Insert(0,'Attribut obsolète dans ce schéma : ne lʼutilisez pas dans une nouvelle requête.')}
    return [pscustomobject]@{Example=$example;Notes=$notes.ToArray()}
}

# ---------------------------------------------------------------- point 29: LDAP filter cost
function ConvertFrom-DomeniaLdapFilterItem {
    # One simple assertion: Equality, Presence, Substring, GreaterOrEqual, LessOrEqual, Approx or Extensible.
    param([string]$Item)
    $equal=$Item.IndexOf('=')
    if($equal -le 0){throw ('Assertion sans opérateur : « '+$Item+' ».')}
    $left=$Item.Substring(0,$equal);$value=$Item.Substring($equal+1)
    $kind='Equality';$rule=''
    $last=[string]$left[$left.Length-1]
    if($last -eq '~'){$kind='Approx';$left=$left.Substring(0,$left.Length-1)}
    elseif($last -eq '>'){$kind='GreaterOrEqual';$left=$left.Substring(0,$left.Length-1)}
    elseif($last -eq '<'){$kind='LessOrEqual';$left=$left.Substring(0,$left.Length-1)}
    elseif($last -eq ':'){$kind='Extensible';$left=$left.Substring(0,$left.Length-1)}
    $attribute=$left
    if($kind -eq 'Extensible'){
        $segments=@($left.Split(':'))
        $attribute=[string]$segments[0]
        $rule=(@($segments|Select-Object -Skip 1|Where-Object{([string]$_) -and ([string]$_ -ine 'dn')}) -join ':')
    }
    $attributeOk=($attribute -match '^[A-Za-z][A-Za-z0-9-]*(;[A-Za-z0-9-]+)*$') -or ($attribute -match '^\d+(\.\d+)+$') -or (($kind -eq 'Extensible') -and (-not $attribute))
    if(-not $attributeOk){throw ('Nom dʼattribut invalide : « '+$attribute+' ».')}
    if($kind -eq 'Equality'){
        if($value -eq '*'){$kind='Presence'}elseif($value.Contains('*')){$kind='Substring'}
    }
    return [pscustomobject]@{Kind=$kind;Children=@();Attribute=([string]$attribute).Split(';')[0];Value=$value;Rule=$rule;LeadingWildcard=(($kind -eq 'Substring') -and ($value.StartsWith('*')))}
}

function Read-DomeniaLdapFilterNode {
    param($State,[int]$Depth)
    if($Depth -gt 64){throw 'Filtre trop imbriqué : 64 niveaux au plus.'}
    $State.Items++
    if($State.Items -gt 2000){throw 'Filtre trop long : 2 000 éléments au plus.'}
    $text=[string]$State.Text
    if(($State.Pos -ge $text.Length) -or ($text[$State.Pos] -ne [char]'(')){throw ('Parenthèse ouvrante attendue, position '+($State.Pos+1)+'.')}
    $State.Pos++
    if($State.Pos -ge $text.Length){throw 'Filtre incomplet.'}
    $operator=$text[$State.Pos]
    if(($operator -eq [char]'&') -or ($operator -eq [char]'|') -or ($operator -eq [char]'!')){
        $State.Pos++
        $children=New-Object 'System.Collections.Generic.List[object]'
        while(($State.Pos -lt $text.Length) -and ($text[$State.Pos] -eq [char]'(')){$children.Add((Read-DomeniaLdapFilterNode $State ($Depth+1)))}
        if(($State.Pos -ge $text.Length) -or ($text[$State.Pos] -ne [char]')')){throw ('Parenthèse fermante attendue, position '+($State.Pos+1)+'.')}
        $State.Pos++
        $kind='Not';if($operator -eq [char]'&'){$kind='And'}elseif($operator -eq [char]'|'){$kind='Or'}
        if(($kind -eq 'Not') -and ($children.Count -ne 1)){throw 'Une négation (!) porte sur un seul filtre.'}
        if($children.Count -lt 1){throw 'Un ET (&) ou un OU (|) sans filtre est vide.'}
        return [pscustomobject]@{Kind=$kind;Children=$children.ToArray();Attribute='';Value='';Rule='';LeadingWildcard=$false}
    }
    # Values escape parentheses as \28 and \29: the first closing parenthesis ends the assertion.
    $end=$text.IndexOf([char]')',$State.Pos)
    if($end -lt 0){throw 'Parenthèse fermante manquante.'}
    $item=$text.Substring($State.Pos,$end-$State.Pos)
    $State.Pos=$end+1
    if($item.Contains('(')){throw ('Parenthèse non échappée dans « '+$item+' » : écrivez \28 et \29.')}
    return (ConvertFrom-DomeniaLdapFilterItem $item)
}

function ConvertFrom-DomeniaLdapFilter {
    # RFC 4515 filter as a tree. Bounded: 32 768 characters, 64 levels, 2 000 elements. Never throws: {Valid, Error, Root}.
    param([AllowEmptyString()][AllowNull()][string]$Filter)
    $text=([string]$Filter).Trim()
    if(-not $text){return [pscustomobject]@{Valid=$false;Error='Filtre vide.';Root=$null}}
    if($text.Length -gt 32768){return [pscustomobject]@{Valid=$false;Error='Filtre trop long : 32 768 caractères au plus.';Root=$null}}
    if(-not $text.StartsWith('(')){$text='('+$text+')'}
    $state=[pscustomobject]@{Text=$text;Pos=0;Items=0}
    try{
        $root=Read-DomeniaLdapFilterNode $state 0
        if($state.Pos -ne $text.Length){throw ('Texte inattendu après le filtre, position '+($state.Pos+1)+'.')}
        return [pscustomobject]@{Valid=$true;Error='';Root=$root}
    }catch{
        return [pscustomobject]@{Valid=$false;Error=[string]$_.Exception.Message;Root=$null}
    }
}

function Get-DomeniaLdapNodeIndexUse {
    # 'Yes': the controller can answer this node from an index; 'No': it reads every candidate object; 'Unknown':
    # an attribute is missing from the schema read in this session, or the schema was not read.
    param($Node,$Catalog)
    $kind=[string]$Node.Kind
    if($kind -eq 'Not'){return 'No'}
    if($kind -eq 'Extensible'){return 'No'}
    if($kind -eq 'And'){
        $uses=@(@($Node.Children)|ForEach-Object{Get-DomeniaLdapNodeIndexUse $_ $Catalog})
        if($uses -contains 'Yes'){return 'Yes'}
        if($uses -contains 'Unknown'){return 'Unknown'}
        return 'No'
    }
    if($kind -eq 'Or'){
        $uses=@(@($Node.Children)|ForEach-Object{Get-DomeniaLdapNodeIndexUse $_ $Catalog})
        if($uses -contains 'No'){return 'No'}
        if($uses -contains 'Unknown'){return 'Unknown'}
        return 'Yes'
    }
    # Ambiguous name resolution searches the ANR attributes, which the directory indexes for that purpose.
    if(([string]$Node.Attribute -ieq 'anr') -and (($kind -eq 'Equality') -or ($kind -eq 'Substring'))){return 'Yes'}
    $attribute=Get-DomeniaAdSchemaAttribute $Catalog ([string]$Node.Attribute)
    if($null -eq $attribute){return 'Unknown'}
    if([bool]$attribute.Constructed){return 'No'}
    if(-not [bool]$attribute.Indexed){return 'No'}
    if(($kind -eq 'Substring') -and ([bool]$Node.LeadingWildcard)){if([bool]$attribute.TupleIndexed){return 'Yes'};return 'No'}
    return 'Yes'
}

function Get-DomeniaLdapFilterLeaves {
    param($Node,[bool]$Negated=$false)
    if($null -eq $Node){return}
    if([string]$Node.Kind -in @('And','Or','Not')){
        foreach($child in @($Node.Children)){Get-DomeniaLdapFilterLeaves $child ($Negated -or ([string]$Node.Kind -eq 'Not'))}
        return
    }
    [pscustomobject]@{Node=$Node;Negated=$Negated}
}

function Get-DomeniaLdapFilterAnalysis {
    # What a filter costs before it is sent. Index use comes from the schema read in this session; without it the
    # answer stays unknown and says so. Nothing here contacts a controller.
    param([AllowEmptyString()][AllowNull()][string]$Filter,$Catalog=$null)
    $parsed=ConvertFrom-DomeniaLdapFilter $Filter
    if(-not $parsed.Valid){return [pscustomobject]@{Valid=$false;Error=$parsed.Error;Level='Invalide';IndexUse='Unknown';Attributes=@();NotIndexed=@();Unknown=@();LeadingWildcards=@();Constructed=@();Negations=0;Advice=@('Filtre non valide : '+$parsed.Error);Text=('Filtre non valide : '+$parsed.Error)}}
    $leaves=@(Get-DomeniaLdapFilterLeaves $parsed.Root)
    $attributes=New-Object 'System.Collections.Generic.List[string]';$notIndexed=New-Object 'System.Collections.Generic.List[string]'
    $unknown=New-Object 'System.Collections.Generic.List[string]';$leading=New-Object 'System.Collections.Generic.List[string]'
    $constructed=New-Object 'System.Collections.Generic.List[string]';$confidential=New-Object 'System.Collections.Generic.List[string]'
    $negations=0;$extensible=0
    foreach($leaf in $leaves){
        $node=$leaf.Node;$name=[string]$node.Attribute
        if($leaf.Negated){$negations++}
        if([string]$node.Kind -eq 'Extensible'){$extensible++}
        if($name -and (-not $attributes.Contains($name))){$attributes.Add($name)}
        if(([bool]$node.LeadingWildcard) -and (-not $leading.Contains($name))){$leading.Add($name)}
        if((-not $name) -or ($name -ieq 'anr')){continue}
        $attribute=Get-DomeniaAdSchemaAttribute $Catalog $name
        if($null -eq $attribute){if(-not $unknown.Contains($name)){$unknown.Add($name)};continue}
        if(([bool]$attribute.Constructed) -and (-not $constructed.Contains($name))){$constructed.Add($name)}
        if((-not [bool]$attribute.Indexed) -and (-not $notIndexed.Contains($name))){$notIndexed.Add($name)}
        if(([bool]$attribute.Confidential) -and (-not $confidential.Contains($name))){$confidential.Add($name)}
    }
    $use=Get-DomeniaLdapNodeIndexUse $parsed.Root $Catalog
    $level='Inconnu';if($use -eq 'Yes'){$level='Ciblé'}elseif($use -eq 'No'){$level='Large'}
    $advice=New-Object 'System.Collections.Generic.List[string]'
    if($null -eq $Catalog){$advice.Add('Index non vérifiés : lisez le schéma AD (onglet Schéma AD de lʼAtelier) pour savoir quels attributs sont indexés.')}
    if($use -eq 'Yes'){$advice.Add('Filtre ciblé : un critère indexé limite les objets examinés par le contrôleur.')}
    elseif($use -eq 'No'){$advice.Add('Filtre large : le contrôleur examine chaque objet du périmètre. Ajoutez un critère indexé (égalité ou début de valeur), ou limitez la recherche à une OU.')}
    elseif($null -ne $Catalog){$advice.Add('Coût indéterminé : '+($unknown.ToArray() -join ', ')+' absent(s) du schéma lu.')}
    if($leading.Count){$advice.Add('Joker en tête sur '+($leading.ToArray() -join ', ')+' : cette sous-chaîne nʼutilise pas lʼindex habituel.')}
    if($negations){$advice.Add('La négation (!) nʼutilise aucun index : gardez-la à côté dʼun critère indexé.')}
    if($extensible){$advice.Add('Règle de correspondance (par exemple sur les bits de userAccountControl) : évaluée objet par objet.')}
    if($constructed.Count){$advice.Add('Attribut calculé '+($constructed.ToArray() -join ', ')+' : le contrôleur ne lʼévalue pas dans un filtre ; utilisez lʼattribut stocké correspondant.')}
    if($confidential.Count){$advice.Add('Attribut confidentiel '+($confidential.ToArray() -join ', ')+' : sans droit de lecture particulier, ce critère ne retient aucun objet.')}
    return [pscustomobject]@{Valid=$true;Error='';Level=$level;IndexUse=$use;Attributes=$attributes.ToArray();NotIndexed=$notIndexed.ToArray();Unknown=$unknown.ToArray();LeadingWildcards=$leading.ToArray();Constructed=$constructed.ToArray();Negations=$negations;Advice=$advice.ToArray();Text=('Coût LDAP : '+$level+'. '+($advice.ToArray() -join ' '))}
}

function Test-DomeniaTypedSearchAllowed {
    # A search started while typing (optional, off by default) never becomes a broad LDAP read: listing a whole scope
    # (*), a leading wildcard or a very short text needs an explicit Rechercher.
    param([AllowEmptyString()][AllowNull()][string]$Text,[int]$MinimumLength=3)
    $value=([string]$Text).Trim();$minimum=[Math]::Max(3,$MinimumLength)
    if(-not $value){return [pscustomobject]@{Allowed=$false;Reason='Saisie vide : aucune recherche automatique.'}}
    if($value.StartsWith('*')){return [pscustomobject]@{Allowed=$false;Reason='Joker en tête : lancez la recherche par Entrée ou Rechercher ; elle nʼutilise pas lʼindex.'}}
    $meaningful=($value -replace '[\*\s]','').Length
    if($meaningful -lt $minimum){return [pscustomobject]@{Allowed=$false;Reason=('Au moins '+$minimum+' caractères avant une recherche automatique.')}}
    return [pscustomobject]@{Allowed=$true;Reason=''}
}
