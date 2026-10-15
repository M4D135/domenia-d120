#requires -Version 5.1
# Build-time functions only. Product scripts are parsed, never dot-sourced or executed.
function Read-DomeniaBuildText {
    param([string]$Path)
    $text=[IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false,$true))
    if([IO.Path]::GetExtension($Path) -ieq '.ps1' -and $text -match '[^\x00-\x7F]'){
        $bytes=[IO.File]::ReadAllBytes($Path)
        if($bytes.Length -lt 3 -or $bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191){throw ('UTF-8 avec BOM requis pour PowerShell 5.1 : '+$Path)}
    }
    return $text.Replace("`r`n","`n").Replace("`r","`n")
}
function Write-DomeniaBuildText {
    param([string]$Path,[string]$Text,[bool]$Bom=$true)
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($Bom))
}
function Get-DomeniaBuildHash {
    param([string]$Text)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','')}
    finally{$sha.Dispose()}
}
function Assert-DomeniaBuildPlainPath {
    param([string]$Path)
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while($null -ne $item){
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Chemin redirige refuse : '+$Path)}
        if($item -is [IO.FileInfo]){$item=$item.Directory}else{$item=$item.Parent}
    }
}
function Get-DomeniaBuildChildPath {
    param([string]$Root,[string]$Relative)
    if(-not $Relative -or $Relative -match '(^|[/\\])\.\.?([/\\]|$)|:|^[/\\]|[\x00-\x1f]'){throw ('Chemin relatif invalide : '+$Relative)}
    foreach($part in $Relative.Replace('\','/').Split('/')){
        if(-not $part -or $part -match '[<>"|?*]|[. ]$|^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){throw ('Nom de fichier Windows invalide : '+$Relative)}
    }
    $base=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $full=[IO.Path]::GetFullPath((Join-Path $base $Relative))
    if(-not $full.StartsWith($base+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw ('Chemin hors source : '+$Relative)}
    return $full
}
function Get-DomeniaBuildAst {
    param([string]$Text,[string]$Label)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw ($Label+' ligne '+$errors[0].Extent.StartLineNumber+' : '+$errors[0].Message)}
    return $ast
}
function Get-DomeniaBuildFunction {
    param($Ast,[string]$Name)
    $found=@($Ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true))
    if($found.Count -ne 1){throw ('Fonction absente ou ambigue : '+$Name)}
    return $found[0]
}
function Get-DomeniaBuildField {
    param($Table,[string]$Name)
    $pairs=@($Table.KeyValuePairs|Where-Object{$_.Item1 -is [Management.Automation.Language.StringConstantExpressionAst] -and $_.Item1.Value -ceq $Name})
    if($pairs.Count -ne 1){throw ('Champ absent ou ambigu du plan : '+$Name)}
    return $pairs[0].Item2
}
function Get-DomeniaBuildFileName {
    param($Table)
    $field=Get-DomeniaBuildField $Table 'File'
    # A single literal is allowed. No expression in the plan is evaluated.
    if($field.Extent.Text -cnotmatch "^'([A-Za-z0-9][A-Za-z0-9.-]*)'$" -and $field.Extent.Text -cnotmatch '^"([A-Za-z0-9][A-Za-z0-9.-]*)"$'){throw 'Nom de fichier non litteral dans le plan.'}
    return $Matches[1]
}
function Set-DomeniaBuildEdits {
    param([string]$Text,[object[]]$Edits)
    $previous=$Text.Length+1
    foreach($edit in @($Edits|Sort-Object Start -Descending)){
        if($edit.End -gt $previous -or $edit.Start -lt 0 -or $edit.End -lt $edit.Start){throw 'Modifications de preparation superposees.'}
        $Text=$Text.Substring(0,$edit.Start)+$edit.Text+$Text.Substring($edit.End);$previous=$edit.Start
    }
    return $Text
}
function Update-DomeniaBuildModulePlan {
    param([string]$WadRoot)
    $path=Join-Path $WadRoot 'Domenia-Modules.ps1';$text=Read-DomeniaBuildText $path
    $ast=Get-DomeniaBuildAst $text $path;$edits=[Collections.Generic.List[object]]::new()
    $provided=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $declaredModules=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($planName in @('Get-DomeniaRuntimeModulePlan','Get-DomeniaRuntimeTypePlan')){
        $plan=Get-DomeniaBuildFunction $ast $planName
        $tables=@($plan.Body.FindAll({param($n) $n -is [Management.Automation.Language.HashtableAst]},$true))
        if(-not $tables.Count){throw ('Plan vide : '+$planName)}
        foreach($table in $tables){
            $file=Get-DomeniaBuildFileName $table;$source=Join-Path (Join-Path $WadRoot 'modules') $file
            if(-not [IO.File]::Exists($source)){throw ('Composant declare absent : '+$file)}
            if($planName -eq 'Get-DomeniaRuntimeTypePlan'){
                if([IO.Path]::GetExtension($file) -ne '.dll'){continue}
                $field=Get-DomeniaBuildField $table 'SHA256';$newText="'"+(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()+"'"
            }else{
                if(-not $declaredModules.Add($file)){throw ('Module declare plusieurs fois : '+$file)}
                $moduleAst=Get-DomeniaBuildAst (Read-DomeniaBuildText $source) $file
                $names=@($moduleAst.EndBlock.Statements|Where-Object{$_ -is [Management.Automation.Language.FunctionDefinitionAst]}|ForEach-Object{$_.Name})
                foreach($name in $names){if($name -cnotmatch '^[A-Za-z][A-Za-z0-9-]*$' -or -not $provided.Add($name)){throw ('Nom de fonction invalide ou duplique : '+$name)}}
                $field=Get-DomeniaBuildField $table 'Functions'
                $newText='@('+((@($names|ForEach-Object{"'"+$_+"'"})) -join ',')+')'
                # Preserve an already prepared literal plan byte for byte. Only
                # whitespace OUTSIDE quoted ASCII names is insignificant; stripping
                # whitespace globally could retain an invalid 'Function Name'.
                $atom='(?:''(?<name>[A-Za-z][A-Za-z0-9-]*)''|"(?<name>[A-Za-z][A-Za-z0-9-]*)")'
                $literal=[regex]::Match($field.Extent.Text,('\A@\(\s*(?:'+$atom+'(?:\s*,\s*'+$atom+')*)?\s*\)\z'))
                if($literal.Success){
                    $oldNames=@($literal.Groups['name'].Captures|ForEach-Object{$_.Value})
                    $same=($oldNames.Count -eq $names.Count)
                    for($n=0;$same -and $n -lt $names.Count;$n++){
                        if(-not [string]::Equals($oldNames[$n],$names[$n],[StringComparison]::Ordinal)){$same=$false}
                    }
                    if($same){$newText=$field.Extent.Text}
                }
            }
            $edits.Add([pscustomobject]@{Start=$field.Extent.StartOffset;End=$field.Extent.EndOffset;Text=$newText})
        }
    }
    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $WadRoot 'modules') -File -Filter '*.ps1')){
        if(-not $declaredModules.Contains($file.Name)){throw ('Module non declare dans Get-DomeniaRuntimeModulePlan : '+$file.Name)}
    }
    Write-DomeniaBuildText $path (Set-DomeniaBuildEdits $text $edits.ToArray())
}
function Update-DomeniaBuildMigration {
    param([string]$WadRoot,[string]$ToolsRoot)
    $spec=Read-DomeniaBuildText (Join-Path $ToolsRoot 'migration-worker.json')|ConvertFrom-Json
    $bodies=[Collections.Generic.List[string]]::new()
    foreach($row in $spec.Sources){
        $source=Get-DomeniaBuildChildPath $WadRoot $row.File
        $text=Read-DomeniaBuildText $source
        foreach($name in $row.Functions){
            # Same textual extraction as update_migration_worker.py, then parse the result.
            $match=[regex]::Match($text,'(?ms)^function '+[regex]::Escape($name)+'\s*\{.*?(?=^function |\z)')
            if(-not $match.Success){throw ('Helper de migration absent : '+$name)}
            $body=$match.Value;$end=$body.LastIndexOf("`n}",[StringComparison]::Ordinal)
            if($end -ge 0){$body=$body.Substring(0,$end+2)}
            else{$body=$body.Split([char]10)[0];if(-not $body.EndsWith('}')){throw ('Helper de migration incomplet : '+$name)}}
            [void](Get-DomeniaBuildAst $body $name);$bodies.Add($body)
        }
    }
    $body=($bodies.ToArray() -join "`n`n")+[string]$spec.Tail
    # Same dependency check as the Python factory generator: a missing helper must
    # stop packaging rather than create a worker that fails only during migration.
    $withoutComments=[regex]::Replace($body,'(?m)^\s*#.*$','')
    $definitions=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($match in [regex]::Matches($withoutComments,'(?m)^function (\S+)')){[void]$definitions.Add($match.Groups[1].Value)}
    # P-CD-08: the lease code and the shared SQLite layer are composed at run time from their single sources (never
    # copied into the literal); their functions satisfy the dependency check like those of the literal.
    $lease=Read-DomeniaBuildText (Get-DomeniaBuildChildPath $WadRoot 'modules/Domenia-StorageLease.Model.ps1')
    $common=[regex]::Match((Read-DomeniaBuildText (Get-DomeniaBuildChildPath $WadRoot 'modules/Domenia-Storage.Worker.ps1')),'(?ms)^function Get-DomeniaSqliteWorkerCommon \{.*?@''\n(.*?)\n^''@')
    if(-not $common.Success){throw 'Couche SQLite partagee absente : Get-DomeniaSqliteWorkerCommon.'}
    foreach($match in [regex]::Matches($lease+"`n"+$common.Groups[1].Value,'(?m)^function (\S+)')){[void]$definitions.Add($match.Groups[1].Value)}
    foreach($match in [regex]::Matches($withoutComments,'\b([A-Za-z]+-Domenia[A-Za-z0-9]+)\b')){
        if(-not $definitions.Contains($match.Groups[1].Value)){throw ('Dependance de migration absente : '+$match.Groups[1].Value)}
    }
    $prelude='    # Lease code and shared SQLite layer of the workers, composed from their single sources (P-CD-08).'+"`n"+'    return (Get-DomeniaStorageLeaseWorkerCode)+[Environment]::NewLine+(Get-DomeniaSqliteWorkerCommon)+[Environment]::NewLine+@'''+"`n"
    $code="# Generated by tools/update_migration_worker.py; review and pin after changes.`nfunction Get-DomeniaMigrationWorkerCode {`n"+$prelude+$body+"'@`n}`n"
    [void](Get-DomeniaBuildAst $code 'Migration generee')
    Write-DomeniaBuildText (Join-Path $WadRoot 'modules/Domenia-Migration.Worker.ps1') $code
}
function Get-DomeniaBuildSourceFunction {
    # One function of a wad file, parsed once per preparation ($Cache: relative path -> AST); never executed.
    param([string]$WadRoot,[string]$Relative,[string]$Name,[hashtable]$Cache)
    if(-not $Cache.ContainsKey($Relative)){$Cache[$Relative]=Get-DomeniaBuildAst (Read-DomeniaBuildText (Get-DomeniaBuildChildPath $WadRoot $Relative)) $Relative}
    return (Get-DomeniaBuildFunction $Cache[$Relative] $Name)
}
function Get-DomeniaBuildLiteral {
    # Here-string number $Index of a function, read like literal_bodies of tools/update_worker_contracts.py.
    param($Function,[int]$Index,[string]$Label)
    $literals=@([regex]::Matches($Function.Extent.Text,'(?ms)@([''"])\n(.*?)\n^\1@'))
    if(($Index -lt 0) -or ($Index -ge $literals.Count)){throw ('Corps worker absent : '+$Label)}
    return $literals[$Index].Groups[2].Value
}
function Get-DomeniaBuildWorkerBody {
    # P-CD-08: the exact body the generator of a pinned operation returns at run time, composed from the files of the
    # wad being prepared like composed_body of tools/update_worker_contracts.py: same operations, same parts, LF joins
    # (the run time joins with [Environment]::NewLine and the worker hash reads CRLF as LF). A literal alone would pin
    # a body the run time never sends, and Assert-DomeniaWorkerOperationCode would refuse the operation. Nothing is
    # executed; tools/check_sqlite_layer.py keeps the lists below equal to the Python ones.
    param([string]$WadRoot,$Item,[hashtable]$Cache)
    $op=[string]$Item.Operation
    if([string]$Item.File -cnotmatch '^wad/(.+)$'){throw ('Source worker invalide : '+$op)}
    $literal=Get-DomeniaBuildLiteral (Get-DomeniaBuildSourceFunction $WadRoot $Matches[1] ([string]$Item.Function) $Cache) ([int]$Item.LiteralIndex) $op
    $sqliteWithLease=@('StorageUsage','StoragePurge','StorageBackup','StorageMaintenance','LiveCache','LegacyMigration')
    $sqliteReadOnly=@('LocalIndexRead','RelationHistoryRead')
    $localStoreModules=@('Common.Model','HealthRules.Model','Boards.Model','ProbeCatalog.Model','Probes.Model','QuerySchema.Model','Workstation.Model','Query.Model','QueryLibrary.Model')
    $probeDetailFunctions=@('ConvertTo-DomeniaProbeDetailValue','ConvertTo-DomeniaProbeDetailInstance','New-DomeniaProbeDetailProjection')
    # W06: storage operations that reuse the pinned helpers of another storage worker, up to the marker of their body.
    $through=$null
    if($op -ceq 'StorageRetention'){$through=@('Get-DomeniaStoragePurgeWorkerCode','# Validate all input before opening the existing database. No payload identifier becomes SQL.')}
    elseif($op -ceq 'StorageIntegrity'){$through=@('Get-DomeniaStorageUsageWorkerCode','$path=Test-DomeniaStorageMeasurePath ([string]$Payload.Path)')}
    if([string]$Item.Function -ceq 'Get-DomeniaLiveProbeCode'){
        $definitions=foreach($name in $probeDetailFunctions){
            $text=(Get-DomeniaBuildSourceFunction $WadRoot 'modules/Domenia-ProbeDetails.Model.ps1' $name $Cache).Extent.Text
            $open=$text.IndexOf([char]'{');$close=$text.LastIndexOf([char]'}')
            'function '+$name+" {`n"+$text.Substring($open+1,$close-$open-1)+"`n}"
        }
        return ((@($definitions) -join "`n")+"`n"+$literal)
    }
    if(($op -cne 'LocalStore') -and ($op -cnotin $sqliteWithLease) -and ($op -cnotin $sqliteReadOnly) -and ($null -eq $through)){return $literal}
    $lease=Read-DomeniaBuildText (Get-DomeniaBuildChildPath $WadRoot 'modules/Domenia-StorageLease.Model.ps1')
    $storage='modules/Domenia-Storage.Worker.ps1'
    $sqlite=Get-DomeniaBuildLiteral (Get-DomeniaBuildSourceFunction $WadRoot $storage 'Get-DomeniaSqliteWorkerCommon' $Cache) 0 'Get-DomeniaSqliteWorkerCommon'
    if($op -ceq 'LocalStore'){
        $definitions=[Collections.Generic.List[string]]::new()
        foreach($name in $localStoreModules){
            $relative='modules/Domenia-'+$name+'.ps1'
            if(-not $Cache.ContainsKey($relative)){$Cache[$relative]=Get-DomeniaBuildAst (Read-DomeniaBuildText (Get-DomeniaBuildChildPath $WadRoot $relative)) $relative}
            # Exactly like the runtime validator: top-level function statements only, in source order.
            $found=@($Cache[$relative].EndBlock.Statements|Where-Object{$_ -is [Management.Automation.Language.FunctionDefinitionAst]})
            foreach($fn in $found){$definitions.Add($fn.Extent.Text)}
        }
        $catalogJson=Read-DomeniaBuildText (Get-DomeniaBuildChildPath $WadRoot 'modules/Domenia-ProbeCatalog.json')
        $catalogBase64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($catalogJson))
        $definitions.Add("`$script:DomeniaExtendedProbeCatalog=@((ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$catalogBase64')))).Probes)")
        $definitions.Add((Get-DomeniaBuildLiteral (Get-DomeniaBuildSourceFunction $WadRoot 'modules/Domenia-QueryLibrary.Model.ps1' 'Get-DomeniaQueryLibraryDefinitionValidationCode' $Cache) 0 'Get-DomeniaQueryLibraryDefinitionValidationCode'))
        return ($lease+"`n"+$sqlite+"`n"+($definitions.ToArray() -join "`n")+"`n"+$literal)
    }
    if($op -cin $sqliteWithLease){return ($lease+"`n"+$sqlite+"`n"+$literal)}
    if($op -cin $sqliteReadOnly){return ($sqlite+"`n"+$literal)}
    $body=$lease+"`n"+$sqlite+"`n"+(Get-DomeniaBuildLiteral (Get-DomeniaBuildSourceFunction $WadRoot $storage $through[0] $Cache) 0 $through[0])
    $at=$body.IndexOf($through[1],[StringComparison]::Ordinal)
    if($at -lt 0){throw ('Repere du worker de stockage absent : '+$op)}
    return ($body.Substring(0,$at)+$literal)
}
function Update-DomeniaBuildWorkerContracts {
    param([string]$WadRoot,[string]$ToolsRoot)
    $contractText=Read-DomeniaBuildText (Join-Path $ToolsRoot 'operation-contracts.json')
    if(-not $contractText.TrimStart().StartsWith('[')){throw 'Tableau JSON attendu dans tools/operation-contracts.json.'}
    # Windows PowerShell 5.1 emits a JSON array as ONE pipeline object. Decode first,
    # then enumerate that value; wrapping ConvertFrom-Json itself nests the array.
    $decoded=$contractText|ConvertFrom-Json -ErrorAction Stop
    $items=@($decoded)
    $corePath=Join-Path $WadRoot 'Domenia-Core.ps1';$core=Read-DomeniaBuildText $corePath
    $coreAst=Get-DomeniaBuildAst $core 'Domenia-Core.ps1'
    $getter=Get-DomeniaBuildFunction $coreAst 'Get-DomeniaWorkerOperationHashes'
    $registered=@([regex]::Matches($getter.Extent.Text,'(\w+)\s*=\s*"([0-9A-F]{64})"')|ForEach-Object{$_.Groups[1].Value})
    $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if($registered.Count -ne $items.Count){throw 'Operations worker differentes du contrat tools/operation-contracts.json.'}
    $newGetter=$getter.Extent.Text;$cache=@{}
    foreach($item in $items){
        if($null -eq $item -or $item -is [array] -or $item -isnot [pscustomobject]){throw 'Objet operation JSON attendu dans tools/operation-contracts.json.'}
        $op=[string]$item.Operation
        if($op -cnotmatch '^[A-Za-z][A-Za-z0-9]{2,63}$' -or -not $names.Add($op) -or $registered -cnotcontains $op){throw ('Operation inconnue ou dupliquee : '+$op)}
        # P-CD-08: the body the generator returns, the layer and the lease of a composed operation included.
        $hash=Get-DomeniaBuildHash (Get-DomeniaBuildWorkerBody $WadRoot $item $cache)
        $pattern='(\b'+[regex]::Escape($op)+'\s*=\s*")[A-F0-9]{64}(\")'
        $newGetter=[regex]::Replace($newGetter,$pattern,('${1}'+$hash+'${2}'))
        $item.Sha256=$hash
    }
    [string[]]$sortedNames=@($names);[Array]::Sort($sortedNames,[StringComparer]::Ordinal)
    $map=@{};foreach($item in $items){$map[$item.Operation]=$item.Sha256}
    $fingerprint=Get-DomeniaBuildHash ((@($sortedNames|ForEach-Object{$_+'='+$map[$_]})) -join "`n")
    $validation=Get-DomeniaBuildFunction $coreAst 'Assert-DomeniaWorkerRegistry'
    $pattern='(\$expectedFingerprint\s*=\s*")[A-F0-9]{64}(")'
    if([regex]::Matches($validation.Extent.Text,$pattern).Count -ne 1){throw 'Empreinte du registre absente ou ambigue.'}
    $newValidation=[regex]::Replace($validation.Extent.Text,$pattern,('${1}'+$fingerprint+'${2}'))
    $edits=@([pscustomobject]@{Start=$getter.Extent.StartOffset;End=$getter.Extent.EndOffset;Text=$newGetter},[pscustomobject]@{Start=$validation.Extent.StartOffset;End=$validation.Extent.EndOffset;Text=$newValidation})
    Write-DomeniaBuildText $corePath (Set-DomeniaBuildEdits $core $edits)
    return $items.Count
}
function New-DomeniaProductionPayload {
    param([string]$SourceWad,[string]$LauncherPath,[string]$PayloadRoot,[string]$ToolsRoot)
    Assert-DomeniaBuildPlainPath $SourceWad;Assert-DomeniaBuildPlainPath $LauncherPath
    if([IO.Directory]::Exists($PayloadRoot) -or [IO.File]::Exists($PayloadRoot)){throw 'Le dossier de preparation doit etre neuf.'}
    $layout=Read-DomeniaBuildText (Join-Path $ToolsRoot 'prod-layout.json')|ConvertFrom-Json
    if($layout.Schema -cne 'DomeniaProductionLayout/1'){throw 'Version du plan PROD inconnue.'}
    $files=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($rel in $layout.RequiredFiles){
        [void](Get-DomeniaBuildChildPath $SourceWad $rel)
        if($files.ContainsKey($rel)){throw ('Chemin PROD duplique : '+$rel)}
        $files.Add($rel,$rel)
    }
    foreach($dir in $layout.RuntimeDirectories){
        $directory=Get-DomeniaBuildChildPath $SourceWad $dir
        if(-not [IO.Directory]::Exists($directory)){continue}
        # Explicit stack: refuse links before traversing, including on PowerShell 5.1.
        $pending=[Collections.Generic.Stack[string]]::new();$pending.Push($directory)
        while($pending.Count){
            $current=$pending.Pop();Assert-DomeniaBuildPlainPath $current
            foreach($item in Get-ChildItem -LiteralPath $current -Force){
                if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Composant redirige : '+$item.FullName)}
                if($item.PSIsContainer){if($layout.ExcludedDirectoryNames -notcontains $item.Name){$pending.Push($item.FullName)};continue}
                if($layout.ExcludedFileNames -contains $item.Name -or $layout.ExcludedExtensions -contains $item.Extension){continue}
                $relative=$item.FullName.Substring($SourceWad.TrimEnd('/','\').Length+1).Replace('\','/')
                [void](Get-DomeniaBuildChildPath $SourceWad $relative)
                if($files.ContainsKey($relative)){throw ('Chemin PROD duplique ou casse ambigue : '+$relative)}
                $files.Add($relative,$relative)
            }
        }
    }
    [void][IO.Directory]::CreateDirectory((Join-Path $PayloadRoot 'wad'))
    [IO.File]::Copy($LauncherPath,(Join-Path $PayloadRoot 'Domenia.exe'))
    [string[]]$sortedFiles=@($files.Keys);[Array]::Sort($sortedFiles,[StringComparer]::Ordinal)
    foreach($rel in $sortedFiles){
        $source=Get-DomeniaBuildChildPath $SourceWad $rel;Assert-DomeniaBuildPlainPath $source
        $target=Get-DomeniaBuildChildPath (Join-Path $PayloadRoot 'wad') $rel
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target));[IO.File]::Copy($source,$target)
        if([IO.Path]::GetExtension($rel) -ieq '.ps1'){
            $text=Read-DomeniaBuildText $target
            if($text.Contains('# SIG # Begin signature block')){throw ('Source signee : reconstruisez depuis les sources non signees avant de signer la distribution : '+$rel)}
            [void](Get-DomeniaBuildAst $text $rel);Write-DomeniaBuildText $target $text
        }
        if([IO.Path]::GetExtension($rel) -ieq '.json'){
            try{[void](Read-DomeniaBuildText $target|ConvertFrom-Json -ErrorAction Stop)}
            catch{throw ('JSON invalide dans '+$rel+' : '+$_.Exception.Message)}
        }
    }
    $wad=Join-Path $PayloadRoot 'wad'
    foreach($name in @('Domenia.config.json')){
        $jsonPath=Join-Path $wad $name
        if((Get-Item -LiteralPath $jsonPath).Length -gt 4MB){throw ('Configuration trop volumineuse : '+$name)}
        $config=Read-DomeniaBuildText $jsonPath|ConvertFrom-Json
        if($null -eq $config -or $config -isnot [pscustomobject]){throw ('Objet JSON attendu : '+$name)}
        if($name -eq 'Domenia.config.json'){
            $auth=$config.PSObject.Properties['Auth']
            if($auth -and $auth.Value){$demo=$auth.Value.PSObject.Properties['DemoProvider'];if($demo -and ([string]$demo.Value).Trim() -match '^(true|1|yes|oui|on)$'){throw 'Auth.DemoProvider doit etre desactive pour PROD.'}}
        }
    }
    Update-DomeniaBuildMigration $wad $ToolsRoot
    Update-DomeniaBuildModulePlan $wad
    $operations=Update-DomeniaBuildWorkerContracts $wad $ToolsRoot
    $releasePath=Join-Path $wad 'Domenia.release.json';$release=Read-DomeniaBuildText $releasePath|ConvertFrom-Json
    foreach($component in $release.Components){$component.Sha256=(Get-FileHash -LiteralPath (Get-DomeniaBuildChildPath $PayloadRoot $component.Path) -Algorithm SHA256).Hash.ToLowerInvariant()}
    $release.ReleaseStatus='LocalBuildRequiresValidation'
    Write-DomeniaBuildText $releasePath (($release|ConvertTo-Json -Depth 12)+"`n") $false
    $rows=[Collections.Generic.List[object]]::new()
    foreach($file in @(Get-ChildItem -LiteralPath $PayloadRoot -Recurse -File -Force|Sort-Object FullName)){
        $relative=$file.FullName.Substring($PayloadRoot.TrimEnd('/','\').Length+1).Replace('\','/')
        $rows.Add([ordered]@{Path=$relative;Sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash;Bytes=$file.Length;Runtime=$true;PreserveExisting=($relative -in @('wad/Domenia.config.json','wad/Domenia.login-mode.cfg','wad/Domenia.theme.cfg','wad/Domenia.ui-profile.cfg'))})
    }
    if($rows.Count -gt [int]$release.RuntimeFileLimit){throw 'Le nombre de composants depasse RuntimeFileLimit dans Domenia.release.json.'}
    $manifest=[ordered]@{Format=1;Version=$release.Version;Build=$release.Build;Edition='prod';ReleaseStatus=$release.ReleaseStatus;Files=$rows.ToArray()}
    Write-DomeniaBuildText (Join-Path $wad 'package-manifest.json') (($manifest|ConvertTo-Json -Depth 6)+"`n") $false
    return [pscustomobject]@{Files=$rows.Count+1;Operations=$operations;Build=$release.Build}
}
