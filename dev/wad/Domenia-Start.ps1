#requires -Version 5.1
[CmdletBinding()]
param([switch]$CheckOnly,[switch]$Diagnostic)
$ErrorActionPreference='Stop'
$lifecycle=$null
$integrityHasher=$null
try {
    if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or -not [Environment]::Is64BitProcess -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){
        throw 'Windows PowerShell 5.1 x64 STA requis. Lancez Domenia.exe.'
    }
    $integrityWatch=[Diagnostics.Stopwatch]::StartNew()
    $root=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
    $cursor=[IO.DirectoryInfo]::new($root)
    while($null -ne $cursor){if($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Dossier du logiciel redirige. Utilisez une copie locale validee.'};$cursor=$cursor.Parent}
    $lockPath=Join-Path $PSScriptRoot 'Support\.lifecycle.lock'
    $lifecycle=[IO.File]::Open($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $pendingPath=Join-Path $PSScriptRoot 'Support\.update.pending'
    if([IO.File]::Exists($pendingPath)){
        # The marker names the backup of the interrupted installation, which holds its own restore script (written
        # before the first replacement, so it exists even when this update came from an older version).
        $pendingBackup=''
        try{$pendingBackup=[string](([IO.File]::ReadAllText($pendingPath)|ConvertFrom-Json).Backup)}catch{}
        $restoreHint="wad\Support\INSTALLER-MISE-A-JOUR.ps1 -RestoreLatest -Destination '"+$root+"'"
        if($pendingBackup){$restoreHint="'"+(Join-Path $pendingBackup 'RESTAURER-CODE.ps1')+"' -RestoreBackup '"+$pendingBackup+"' (ou "+$restoreHint+')'}
        throw ('Mise à jour incomplète. Restaurez le code avant le lancement, dans Windows PowerShell : '+$restoreHint+'.')
    }
    $manifestPath=Join-Path $PSScriptRoot 'package-manifest.json'
    $mi=Get-Item -LiteralPath $manifestPath -Force
    if($mi.Length -gt 2MB -or ($mi.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Manifeste invalide.'}
    $manifest=[IO.File]::ReadAllText($manifestPath)|ConvertFrom-Json
    if([int]$manifest.Format -ne 1){throw 'Version de manifeste non prise en charge.'}
    $entries=@($manifest.Files|Where-Object{$_.Runtime -eq $true})
    # Absolute sanity bound; the reviewed ceiling (FI-14) is read below from the hashed wad/Domenia.release.json.
    if($entries.Count -lt 10 -or $entries.Count -gt 1000){throw 'Liste du runtime invalide.'}
    # PF-19: one SHA-256 instance and sequential reads; each folder is checked for redirection once.
    $integrityHasher=[Security.Cryptography.SHA256]::Create()
    $hashFile={
        param([string]$Path)
        $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read,1048576,[IO.FileOptions]::SequentialScan)
        try{return [BitConverter]::ToString($integrityHasher.ComputeHash($stream)).Replace('-','')}finally{$stream.Dispose()}
    }
    # Un clone Windows (core.autocrlf) ou un editeur peut rendre le meme script avec d'autres octets : le manifeste
    # est calcule sur les octets du depot, en LF. Seule cette difference-la est acceptee ici, et elle est comptee.
    $eolCandidates={
        param([string]$Path)
        if('ps1','psm1','psd1','ps1xml','json','xml','xaml','cs','cfg','md','txt' -notcontains [IO.Path]::GetExtension($Path).ToLowerInvariant()){return @()}
        $texte=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($Path))
        $texte=$texte.Replace([string][char]13+[char]10,[string][char]10).Replace([string][char]13,[string][char]10)
        $resultat=@()
        foreach($octets in @([Text.Encoding]::UTF8.GetBytes($texte),[Text.Encoding]::UTF8.GetBytes([string][char]0xFEFF+$texte))){
            $resultat+=[BitConverter]::ToString($integrityHasher.ComputeHash($octets)).Replace('-','')
        }
        return ,$resultat
    }
    $checkedFolders=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $seen=@{}
    $eolDifferences=New-Object 'System.Collections.Generic.List[string]'
    foreach($entry in $entries){
        $relative=[string]$entry.Path
        if(-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[/\\])\.\.?([/\\]|$)|:|^wad[/\\]data([/\\]|$)' -or $seen.ContainsKey($relative)){throw 'Chemin de runtime invalide ou duplique.'}
        $seen[$relative]=$true
        $path=[IO.Path]::GetFullPath((Join-Path $root $relative))
        if(-not $path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Chemin hors paquet.'}
        $file=[IO.FileInfo]::new($path)
        if(-not $file.Exists){throw ('Composant manquant : '+$relative)}
        if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Composant redirige : '+$relative)}
        $folder=$file.Directory
        while(($null -ne $folder) -and ($folder.FullName.Length -ge $root.Length) -and (-not $checkedFolders.Contains($folder.FullName))){
            if($folder.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Composant redirige : '+$relative)}
            [void]$checkedFolders.Add($folder.FullName)
            $folder=$folder.Parent
        }
        # Hash immutable runtime on every startup. Configuration remains independently editable.
        if(-not [bool]$entry.PreserveExisting){
            $lue=& $hashFile $path
            if($lue -ine [string]$entry.Sha256){
                if(@(& $eolCandidates $path) -notcontains [string]$entry.Sha256){
                    throw ('Composant modifie ou versions melangees : '+$relative+' (attendu '+[string]$entry.Sha256+', lu '+$lue+', '+$file.Length+' octets).')
                }
                [void]$eolDifferences.Add($relative)
            }
        }
        if($CheckOnly -and [IO.Path]::GetExtension($path) -ieq '.ps1'){
            $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
            if(@($errors).Count){throw ($relative+' ligne '+$errors[0].Extent.StartLineNumber+' : '+$errors[0].Message)}
        }
    }
    $integrityHasher.Dispose();$integrityHasher=$null
    # FI-14: the ceiling comes from the release contract stamped into wad/Domenia.release.json (hash verified above).
    $runtimeLimit=250
    if($seen.ContainsKey('wad/Domenia.release.json')){
        $release=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Domenia.release.json'))|ConvertFrom-Json
        $declaredLimit=$release.PSObject.Properties['RuntimeFileLimit']
        if($null -ne $declaredLimit){
            if((($declaredLimit.Value -isnot [int]) -and ($declaredLimit.Value -isnot [long])) -or ([long]$declaredLimit.Value -lt 10) -or ([long]$declaredLimit.Value -gt 1000)){throw 'Plafond du runtime invalide dans wad\Domenia.release.json.'}
            $runtimeLimit=[int]$declaredLimit.Value
        }
    }
    if($entries.Count -gt $runtimeLimit){throw ('Liste du runtime invalide : '+$entries.Count+' fichiers pour un plafond de '+$runtimeLimit+'.')}
    # PF-19: the required list is the closed module plan of Domenia-Modules.ps1 (hash verified above), read from its
    # syntax tree without executing it, plus the files that start the application.
    $required=New-Object 'System.Collections.Generic.List[string]'
    foreach($rel in @(
        'Domenia.exe',
        'wad/Domenia-Core.ps1',
        'wad/Domenia-Main.xaml',
        'wad/Domenia-Start.ps1',
        'wad/Domenia-Modules.ps1',
        'wad/Domenia.release.json',
        'wad/modules/Domenia-CommonLibrary.json',
        'wad/Support/.lifecycle.lock'
    )){$required.Add($rel)}
    $tokens=$null;$errors=$null
    $loaderAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Domenia-Modules.ps1'),[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw ('wad/Domenia-Modules.ps1 ligne '+$errors[0].Extent.StartLineNumber+' : '+$errors[0].Message)}
    foreach($planName in @('Get-DomeniaRuntimeModulePlan','Get-DomeniaRuntimeTypePlan')){
        $planAst=@($loaderAst.FindAll({param($node) ($node -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -ceq $planName)},$true))
        if($planAst.Count -ne 1){throw ('Plan des modules illisible : '+$planName)}
        $planFiles=0
        foreach($table in @($planAst[0].Body.FindAll({param($node) $node -is [Management.Automation.Language.HashtableAst]},$true))){
            foreach($pair in @($table.KeyValuePairs)){
                if(($pair.Item1 -isnot [Management.Automation.Language.StringConstantExpressionAst]) -or ($pair.Item1.Value -cne 'File')){continue}
                $value=$pair.Item2.Find({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst]},$true)
                if(($null -eq $value) -or ($value.Value -cnotmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$')){throw ('Plan des modules illisible : '+$planName)}
                $required.Add('wad/modules/'+$value.Value);$planFiles++
            }
        }
        if($planFiles -eq 0){throw ('Plan des modules vide : '+$planName)}
    }
    foreach($rel in $required){
        if(-not $seen.ContainsKey($rel)){throw ('Manifeste incomplet : '+$rel)}
    }
    $integrityWatch.Stop()
    # Read by the core for the startup trace (stage Integrite du paquet); never used as a decision input.
    $DomeniaStartIntegrity=[pscustomobject]@{Files=$entries.Count;Required=$required.Count;Limit=$runtimeLimit;DurationMs=[long]$integrityWatch.ElapsedMilliseconds;Eol=$eolDifferences.Count}
    if($CheckOnly){
        # Exercise the real imports in a disposable scope, never the application.
        # This loads definitions only; it does not start a timer/window or contact AD.
        $importReport = @(& {
            param([string]$BootstrapPath)
            . $BootstrapPath
            [pscustomobject]@{Imports=@($script:DomeniaRuntimeImports);Expected=@(Get-DomeniaRuntimeModulePlan).Count}
        } (Join-Path $PSScriptRoot 'Domenia-Modules.ps1'))
        $expectedModules=[int]$importReport[0].Expected
        $importReport=@($importReport[0].Imports)
        if($importReport.Count -ne $expectedModules){throw 'Validation des modules incomplete.'}
        $noteEol=''
        if($eolDifferences.Count -gt 0){$noteEol=' ; '+$eolDifferences.Count+' fichier(s) avec fins de ligne différentes du manifeste'}
        Write-Host ('Runtime '+$manifest.Build+' : '+$entries.Count+' fichiers vérifiés en '+$DomeniaStartIntegrity.DurationMs+' ms (plafond '+$runtimeLimit+') ; '+$importReport.Count+' modules chargés et fonctions disponibles. Aucun accès AD.'+$noteEol)
        exit 0
    }
    & (Join-Path $PSScriptRoot 'Domenia-Core.ps1')
}catch{
    $message=$_.Exception.Message
    Write-Host $message -ForegroundColor Red
    try{
        $log=Join-Path ([IO.Path]::GetTempPath()) 'Domenia-startup-error.log'
        [IO.File]::AppendAllText($log,([datetime]::Now.ToString('o')+' '+$message+[Environment]::NewLine))
        if(-not $CheckOnly){
            Add-Type -AssemblyName PresentationFramework
            [void][Windows.MessageBox]::Show($message+"`r`n`r`nDiagnostic : "+$log,'Domenia | Démarrage','OK','Error')
        }
    }catch{}
    exit 1
}finally{if($null -ne $integrityHasher){$integrityHasher.Dispose()};if($null -ne $lifecycle){$lifecycle.Dispose()}}
