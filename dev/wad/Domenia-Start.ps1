#requires -Version 5.1
[CmdletBinding()]
param([switch]$CheckOnly,[switch]$Diagnostic)
$ErrorActionPreference='Stop'
$lifecycle=$null
try {
    if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or -not [Environment]::Is64BitProcess -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){
        throw 'Windows PowerShell 5.1 x64 STA requis. Lancez Domenia.exe.'
    }
    $root=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
    $cursor=[IO.DirectoryInfo]::new($root)
    while($null -ne $cursor){if($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Dossier du logiciel redirige. Utilisez une copie locale validee.'};$cursor=$cursor.Parent}
    $lockPath=Join-Path $PSScriptRoot 'Support\.lifecycle.lock'
    $lifecycle=[IO.File]::Open($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    if([IO.File]::Exists((Join-Path $PSScriptRoot 'Support\.update.pending'))){throw 'Mise a jour incomplete. Restaurez le code avec l installateur DEV avant lancement.'}
    $manifestPath=Join-Path $PSScriptRoot 'package-manifest.json'
    $mi=Get-Item -LiteralPath $manifestPath -Force
    if($mi.Length -gt 2MB -or ($mi.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Manifeste invalide.'}
    $manifest=[IO.File]::ReadAllText($manifestPath)|ConvertFrom-Json
    if([int]$manifest.Format -ne 1){throw 'Version de manifeste non prise en charge.'}
    $entries=@($manifest.Files|Where-Object{$_.Runtime -eq $true})
    if($entries.Count -lt 10 -or $entries.Count -gt 100){throw 'Liste du runtime invalide.'}
    $seen=@{}
    foreach($entry in $entries){
        $relative=[string]$entry.Path
        if(-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[/\\])\.\.?([/\\]|$)|:|^wad[/\\]data([/\\]|$)' -or $seen.ContainsKey($relative)){throw 'Chemin de runtime invalide ou duplique.'}
        $seen[$relative]=$true
        $path=[IO.Path]::GetFullPath((Join-Path $root $relative))
        if(-not $path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Chemin hors paquet.'}
        if(-not [IO.File]::Exists($path)){throw ('Composant manquant : '+$relative)}
        $cursor=Get-Item -LiteralPath $path -Force
        while($null -ne $cursor -and $cursor.FullName.Length -ge $root.Length){
            if($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Composant redirige : '+$relative)}
            $cursor=if($cursor -is [IO.FileInfo]){$cursor.Directory}else{$cursor.Parent}
        }
        # Hash immutable runtime on every startup. Configuration remains independently editable.
        if(-not [bool]$entry.PreserveExisting -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine [string]$entry.Sha256){throw ('Composant modifie ou versions melangees : '+$relative)}
        if($CheckOnly -and [IO.Path]::GetExtension($path) -ieq '.ps1'){
            $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
            if(@($errors).Count){throw ($relative+' ligne '+$errors[0].Extent.StartLineNumber+' : '+$errors[0].Message)}
        }
    }
    foreach($required in @(
        'Domenia.exe',
        'wad/Domenia-Core.ps1',
        'wad/Domenia-Start.ps1',
        'wad/Domenia-Modules.ps1',
        'wad/modules/Domenia-Identity.Types.cs',
        'wad/modules/Domenia-Common.Model.ps1',
        'wad/modules/Domenia-Engine.Model.ps1',
        'wad/modules/Domenia-Cache.Model.ps1',
        'wad/modules/Domenia-Search.Model.ps1',
        'wad/modules/Domenia-Relations.Model.ps1',
        'wad/modules/Domenia-Access.Model.ps1',
        'wad/modules/Domenia-Directory.Model.ps1',
        'wad/modules/Domenia-Workstation.Model.ps1',
        'wad/modules/Domenia-Shell.Model.ps1',
        'wad/modules/Domenia-Safety.Model.ps1',
        'wad/modules/Domenia-Insight.Model.ps1',
        'wad/modules/Domenia-Release.Model.ps1',
        'wad/modules/Domenia-Embedded.UI.ps1',
        'wad/modules/Domenia-UX.UI.ps1',
        'wad/modules/Domenia-Experience.Model.ps1',
        'wad/modules/Domenia-Experience.UI.ps1',
        'wad/modules/Domenia-Support.Model.ps1',
        'wad/modules/Domenia-Support.UI.ps1',
        'wad/modules/Domenia-Live.Model.ps1',
        'wad/modules/Domenia-Live.UI.ps1',
        'wad/modules/Domenia-Access.UI.ps1',
        'wad/modules/Domenia-Continuity.Model.ps1',
        'wad/modules/Domenia-Continuity.UI.ps1',
        'wad/modules/Domenia-Guard.Model.ps1',
        'wad/modules/Domenia-Accounts.Async.ps1',
        'wad/modules/Domenia-Storage.Worker.ps1',
        'wad/modules/Domenia-Storage.UI.ps1',
        'wad/modules/Domenia-Receipts.Worker.ps1',
        'wad/modules/Domenia-Sessions.UI.ps1',
        'wad/modules/Domenia-Dossier.Model.ps1',
        'wad/modules/Domenia-Dossier.UI.ps1',
        'wad/modules/Domenia-Reconcile.UI.ps1',
        'wad/modules/Domenia-Guard.UI.ps1'
    )){
        if(-not $seen.ContainsKey($required)){throw ('Manifeste incomplet : '+$required)}
    }
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
        Write-Host ('Runtime '+$manifest.Build+' : '+$entries.Count+' fichiers verifies ; '+$importReport.Count+' modules charges et fonctions disponibles. Aucun acces AD.')
        exit 0
    }
    & (Join-Path $PSScriptRoot 'Domenia-Core.ps1')
}catch{
    $message=$_.Exception.Message
    Write-Host $message -ForegroundColor Red
    try{
        $log=Join-Path ([IO.Path]::GetTempPath()) 'Domenia-startup-error.log'
        [IO.File]::AppendAllText($log,([datetime]::Now.ToString('o')+' '+$message+[Environment]::NewLine))
        Add-Type -AssemblyName PresentationFramework
        [void][Windows.MessageBox]::Show($message+"`r`n`r`nDiagnostic : "+$log,'Domenia | Demarrage','OK','Error')
    }catch{}
    exit 1
}finally{if($null -ne $lifecycle){$lifecycle.Dispose()}}
