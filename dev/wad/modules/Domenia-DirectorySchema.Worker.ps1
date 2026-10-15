function Get-DomeniaAdSchemaWorkerCode {
return @'
# Point 28: read-only copy of the schema definitions (classSchema and attributeSchema) of the connected forest, on
# explicit request. Bounded: 8 000 attributes, 3 000 classes, 90 seconds. No object value is read, nothing is written.
$maxAttributes=8000;$maxClasses=3000;$budgetSeconds=90
$watch=[Diagnostics.Stopwatch]::StartNew()
$schemaNc='';$rootDse=$null
try{
    $rootDse=New-WRootDse $Context
    $rootDse.psbase.RefreshCache(@('schemaNamingContext'))
    $schemaNc=[string]$rootDse.psbase.get_Properties().get_Item('schemaNamingContext').Value
}catch{
    if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
    throw ('Schéma introuvable sur le contrôleur : '+[string]$_.Exception.Message)
}finally{if($null -ne $rootDse){$rootDse.Dispose()}}
if($schemaNc -notmatch '^(?i)CN=Schema,CN=Configuration,DC='){throw 'Contexte de schéma inattendu : lecture refusée.'}
function Get-SchemaText {
    param($Props,[string]$Name,[int]$Maximum=500)
    $value=[string](Get-WPropFirst $Props $Name '')
    $value=($value -replace '[\r\n\t]',' ').Trim()
    if($value.Length -gt $Maximum){$value=$value.Substring(0,$Maximum)}
    return $value
}
function Get-SchemaNames {
    param($Props,[string[]]$Names)
    $out=[Collections.Generic.List[string]]::new()
    foreach($name in $Names){
        foreach($value in @(Get-WPropAll $Props $name)){
            $text=[string]$value
            if(($text -match '^[A-Za-z0-9-]{1,128}$') -and (-not $out.Contains($text))){$out.Add($text)}
        }
    }
    return ,$out.ToArray()
}
function Get-SchemaFlag {
    param($Props,[string]$Name)
    $value=Get-WPropFirst $Props $Name $null
    if($null -eq $value){return $false}
    if($value -is [bool]){return $value}
    return ([string]$value -ieq 'TRUE')
}
function Get-SchemaNumber {
    param($Props,[string]$Name)
    $value=Get-WPropFirst $Props $Name $null
    if($null -eq $value){return $null}
    $number=0L
    if([long]::TryParse([string]$value,[ref]$number)){return $number}
    return $null
}
function Read-SchemaEntries {
    param([string]$Filter,[string[]]$Properties,[int]$Limit,[scriptblock]$Convert)
    $rows=[Collections.Generic.List[object]]::new();$cut=$false
    $searcher=$null;$searchRoot=$null;$results=$null
    try{
        # PF-02: the limit + 1 at most; the extra definition proves the limit and the read is marked truncated.
        $searcher=New-WSearcher $Context $schemaNc $Filter $Properties 'OneLevel' ($Limit+1)
        $searchRoot=$searcher.SearchRoot;$searcher.PageSize=500;$searcher.CacheResults=$false
        $searcher.ServerTimeLimit=[TimeSpan]::FromSeconds(60);$searcher.ClientTimeout=[TimeSpan]::FromSeconds(75)
        $results=$searcher.FindAll()
        foreach($r in $results){
            if(($watch.Elapsed.TotalSeconds -ge $budgetSeconds) -or ($rows.Count -ge $Limit)){$cut=$true;break}
            $row=& $Convert $r.Properties
            if($null -ne $row){$rows.Add($row)}
        }
    }catch{
        if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw}
        throw ('Lecture du schéma interrompue : '+[string]$_.Exception.Message)
    }finally{
        if($null -ne $results){$results.Dispose()}
        if($null -ne $searcher){$searcher.Dispose()}
        if($null -ne $searchRoot){$searchRoot.Dispose()}
    }
    return [pscustomobject]@{Rows=$rows.ToArray();Truncated=$cut}
}
$attributeRead=Read-SchemaEntries '(objectClass=attributeSchema)' @('lDAPDisplayName','adminDescription','attributeSyntax','oMSyntax','isSingleValued','searchFlags','systemFlags','isMemberOfPartialAttributeSet','rangeLower','rangeUpper','linkID','isDefunct') $maxAttributes {
    param($p)
    $name=[string](Get-WPropFirst $p 'ldapdisplayname' '')
    if($name -notmatch '^[A-Za-z0-9-]{1,128}$'){return $null}
    [pscustomobject]@{Name=$name;Description=(Get-SchemaText $p 'admindescription');Syntax=(Get-SchemaText $p 'attributesyntax' 32);OmSyntax=(Get-SchemaNumber $p 'omsyntax');SingleValued=(Get-SchemaFlag $p 'issinglevalued');SearchFlags=(Get-SchemaNumber $p 'searchflags');SystemFlags=(Get-SchemaNumber $p 'systemflags');InGlobalCatalog=(Get-SchemaFlag $p 'ismemberofpartialattributeset');RangeLower=(Get-SchemaNumber $p 'rangelower');RangeUpper=(Get-SchemaNumber $p 'rangeupper');LinkId=(Get-SchemaNumber $p 'linkid');Defunct=(Get-SchemaFlag $p 'isdefunct')}
}
$classRead=Read-SchemaEntries '(objectClass=classSchema)' @('lDAPDisplayName','adminDescription','subClassOf','auxiliaryClass','systemAuxiliaryClass','mayContain','systemMayContain','mustContain','systemMustContain','objectClassCategory','isDefunct') $maxClasses {
    param($p)
    $name=[string](Get-WPropFirst $p 'ldapdisplayname' '')
    if($name -notmatch '^[A-Za-z0-9-]{1,128}$'){return $null}
    $category=Get-SchemaNumber $p 'objectclasscategory';if($null -eq $category){$category=1}
    [pscustomobject]@{Name=$name;Description=(Get-SchemaText $p 'admindescription');SubClassOf=(Get-SchemaText $p 'subclassof' 128);Auxiliary=(Get-SchemaNames $p @('auxiliaryclass','systemauxiliaryclass'));May=(Get-SchemaNames $p @('maycontain','systemmaycontain'));Must=(Get-SchemaNames $p @('mustcontain','systemmustcontain'));Category=$category;Defunct=(Get-SchemaFlag $p 'isdefunct')}
}
$source=''
try{$source=[string](Get-WDirectoryVersionSource $Context)}catch{if(Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Directory){throw};$source=''}
$server=[string]$Context.Server
if($source -match '^(?<dc>[^|]+)\|'){$server=[string]$matches['dc']}
[pscustomobject]@{SchemaNc=$schemaNc;Attributes=$attributeRead.Rows;Classes=$classRead.Rows;Truncated=(([bool]$attributeRead.Truncated) -or ([bool]$classRead.Truncated));Server=$server;ObservedUtc=[datetime]::UtcNow.ToString('o');DurationMs=[long]$watch.ElapsedMilliseconds;DomainDn=[string]$Context.BaseDn}
'@
}
