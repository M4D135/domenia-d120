function Get-DomeniaQueryTransferWorkerCode {
    return @'
$root=[string]$Payload.ModuleRoot
foreach($name in @('Common.Model','HealthRules.Model','Boards.Model','Probes.Model','QuerySchema.Model','Workstation.Model','Query.Model','QueryLibrary.Model')){. (Join-Path $root ('Domenia-'+$name+'.ps1'))}
$path=[IO.Path]::GetFullPath([string]$Payload.Path)
if([string]$Payload.Mode -eq 'ImportPreview'){
    $info=[IO.FileInfo]::new($path);if(-not $info.Exists -or $info.Length -gt 16777216){throw 'Pack absent ou supérieur à 16 Mio.'}
    $text=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
    $plan=New-DomeniaQueryPackImportPlan -Context $Payload.Context -Json $text -ExistingRows @($Payload.ExistingRows)
    [pscustomobject]@{Mode='ImportPreview';Path=$path;Plan=$plan};return
}
if([IO.File]::Exists($path)){throw 'Ce fichier existe déjà. Choisissez un autre nom.'}
if([string]$Payload.Mode -eq 'ExportPack'){
    if([IO.Path]::GetExtension($path) -ine '.json'){throw 'Le pack doit être un fichier JSON.'}
    $recipes=@($Payload.Recipes);if($recipes.Count -gt 5000){throw 'Un pack contient au maximum 5 000 recettes ; exportez la sélection en plusieurs packs.'}
    foreach($recipe in $recipes){[void](New-DomeniaQueryLibraryRecord -Context $Payload.Context -Recipe $recipe -ExpectedRevision 0)}
    $text=ConvertTo-Json -InputObject ([pscustomobject]@{Format='Domenia.QueryPack/1';Origin='Domenia · bibliothèque locale';DomainDn=$Payload.Context.DomainDn;ExportedAtUtc=[datetime]::UtcNow.ToString('o');Recipes=$recipes}) -Depth 32
}elseif([string]$Payload.Mode -eq 'ExportPowerShell'){
    if([IO.Path]::GetExtension($path) -ine '.ps1'){throw 'Le script doit avoir l’extension PS1.'}
    $text=ConvertTo-DomeniaQueryPowerShell -Recipe $Payload.Recipe
}else{throw 'Transfert de requêtes inconnu.'}
if([Text.Encoding]::UTF8.GetByteCount($text) -gt 16777216){throw 'Export supérieur à 16 Mio. Réduisez la sélection.'}
$temporary=Join-Path ([IO.Path]::GetDirectoryName($path)) ('.domenia-query-'+[guid]::NewGuid().ToString('N')+'.tmp')
try{
    $stream=[IO.FileStream]::new($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$bytes=[Text.UTF8Encoding]::new($true).GetPreamble()+[Text.Encoding]::UTF8.GetBytes($text);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    [IO.File]::Move($temporary,$path)
}finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
[pscustomobject]@{Mode=[string]$Payload.Mode;Path=$path;Complete=$true}
'@
}
