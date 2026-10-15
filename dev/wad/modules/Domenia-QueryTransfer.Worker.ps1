function Get-DomeniaQueryTransferWorkerCode {
    # QueryTransfer: local files only. Packs and scripts are data files; the import journal lives beside the database.
    return @'
$root=[string]$Payload.ModuleRoot
foreach($name in @('Common.Model','HealthRules.Model','Boards.Model','Probes.Model','QuerySchema.Model','Workstation.Model','Query.Model','QueryLibrary.Model')){. (Join-Path $root ('Domenia-'+$name+'.ps1'))}
$path=[IO.Path]::GetFullPath([string]$Payload.Path)
$mode=[string]$Payload.Mode
if($mode -in @('JournalAppend','JournalRead')){
    if(-not $path.EndsWith('.query-imports.jsonl',[StringComparison]::OrdinalIgnoreCase)){throw 'Journal des imports invalide.'}
    $lines=[Collections.Generic.List[string]]::new()
    if([IO.File]::Exists($path)){
        if(([IO.FileInfo]::new($path)).Length -gt 134217728){throw 'Journal des imports supérieur à 128 Mio.'}
        foreach($existing in [IO.File]::ReadAllLines($path,[Text.Encoding]::UTF8)){if($existing.Trim()){$lines.Add($existing)}}
    }
    if($mode -eq 'JournalRead'){
        $journal=ConvertFrom-DomeniaQueryImportJournal -Lines $lines.ToArray() -StoreId ([string]$Payload.StoreId)
        [pscustomobject]@{Mode=$mode;Path=$path;Entries=@($journal.Entries);Rejected=$journal.Rejected};return
    }
    $line=ConvertTo-Json -InputObject $Payload.Entry -Depth 32 -Compress
    if([Text.Encoding]::UTF8.GetByteCount($line) -gt 4194304){[pscustomobject]@{Mode=$mode;Path=$path;Journaled=$false;Reason='journal de cet import supérieur à 4 Mio'};return}
    $lines.Add($line)
    # Twenty imports with their rollback markers stay available; older lines are compacted away.
    while($lines.Count -gt 40){$lines.RemoveAt(0)}
    $temporary=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($temporary,([string]::Join("`n",$lines.ToArray())+"`n"),[Text.UTF8Encoding]::new($false))
        if([IO.File]::Exists($path)){[IO.File]::Replace($temporary,$path,[NullString]::Value)}else{[IO.File]::Move($temporary,$path)}
    }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
    [pscustomobject]@{Mode=$mode;Path=$path;Journaled=$true;Reason=''};return
}
if($mode -eq 'ImportPreview'){
    $info=[IO.FileInfo]::new($path);if(-not $info.Exists -or $info.Length -gt 16777216){throw 'Pack absent ou supérieur à 16 Mio.'}
    $text=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
    $plan=New-DomeniaQueryPackImportPlan -Context $Payload.Context -Json $text -ExistingRows @($Payload.ExistingRows) -History @(Get-DomeniaMember $Payload 'History' @())
    [pscustomobject]@{Mode='ImportPreview';Path=$path;Plan=$plan};return
}
if([IO.File]::Exists($path)){throw 'Ce fichier existe déjà. Choisissez un autre nom.'}
if($mode -eq 'ExportPack'){
    if([IO.Path]::GetExtension($path) -ine '.json'){throw 'Le pack doit être un fichier JSON.'}
    $pack=New-DomeniaQueryPack -Context $Payload.Context -Recipes @($Payload.Recipes) -PackName ([string]$Payload.PackName) -PackVersion ([long]$Payload.PackVersion) -Origin 'Domenia · bibliothèque locale'
    $text=ConvertTo-Json -InputObject $pack -Depth 32
}elseif($mode -eq 'ExportPowerShell'){
    if([IO.Path]::GetExtension($path) -ine '.ps1'){throw 'Le script doit avoir lʼextension PS1.'}
    $text=ConvertTo-DomeniaQueryPowerShell -Recipe $Payload.Recipe
}else{throw 'Transfert de requêtes inconnu.'}
if([Text.Encoding]::UTF8.GetByteCount($text) -gt 16777216){throw 'Export supérieur à 16 Mio. Réduisez la sélection.'}
$temporary=Join-Path ([IO.Path]::GetDirectoryName($path)) ('.domenia-query-'+[guid]::NewGuid().ToString('N')+'.tmp')
try{
    $stream=[IO.FileStream]::new($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$bytes=[Text.UTF8Encoding]::new($true).GetPreamble()+[Text.Encoding]::UTF8.GetBytes($text);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    [IO.File]::Move($temporary,$path)
}finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
[pscustomobject]@{Mode=$mode;Path=$path;Complete=$true;PackVersion=$(if($mode -eq 'ExportPack'){[long]$Payload.PackVersion}else{0L})}
'@
}
