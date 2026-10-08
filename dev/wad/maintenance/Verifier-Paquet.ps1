#requires -Version 5.1
[CmdletBinding()]
param([string]$Root=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),[string]$ReportPath='',[switch]$StrictConfig,[switch]$Quiet,[string[]]$PublisherThumbprint=@(),[switch]$RequireSignature)
$ErrorActionPreference='Stop'
$rootPath=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
$prefix=$rootPath+[IO.Path]::DirectorySeparatorChar
if(-not [IO.Directory]::Exists($rootPath)){throw 'Dossier DOMENIA absent.'}
if((Get-Item -LiteralPath $rootPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Racine redirigee par un lien.'}
$manifestPath=Join-Path $rootPath 'wad\package-manifest.json'
foreach($segment in @((Join-Path $rootPath 'wad'),$manifestPath)){
    if(Test-Path -LiteralPath $segment){if((Get-Item -LiteralPath $segment -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Chemin du manifeste redirige par un lien.'}}
}
if(-not [IO.File]::Exists($manifestPath) -or ([IO.FileInfo]::new($manifestPath)).Length -gt 4MB){throw 'Manifeste absent ou trop volumineux.'}
$data=[IO.File]::ReadAllText($manifestPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
if([int]$data.Format -ne 1 -or @($data.Files).Count -lt 5 -or @($data.Files).Count -gt 5000){throw 'Manifeste invalide.'}
$results=New-Object 'System.Collections.Generic.List[object]';$seen=@{}
foreach($entry in $data.Files){
    $relative=[string]$entry.Path;$state='OK';$message='Empreinte correcte.'
    try{
        if([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative.Contains(':') -or ($relative -split '[/\\]') -contains '..'){throw 'Chemin de manifeste non autorise.'}
        if($seen.ContainsKey($relative)){throw 'Chemin en double.'};$seen[$relative]=$true
        $path=[IO.Path]::GetFullPath((Join-Path $rootPath $relative))
        if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Chemin hors du paquet.'}
        $cursor=$path
        while($cursor.Length -gt $rootPath.Length){
            if(Test-Path -LiteralPath $cursor){if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Fichier ou dossier redirige par un lien.'}}
            $cursor=Split-Path -Parent $cursor
        }
        if(-not [IO.File]::Exists($path)){throw 'Fichier manquant.'}
        if([bool]$entry.PreserveExisting -and -not $StrictConfig){$state='LOCAL';$message='Configuration conservee : empreinte non imposee.'}
        else{
            if([string]$entry.Sha256 -notmatch '^[0-9A-Fa-f]{64}$'){throw 'Empreinte attendue invalide.'}
            if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine [string]$entry.Sha256){throw 'Empreinte differente : fichier modifie ou melange de versions.'}
        }
        if($relative.EndsWith('.ps1',[StringComparison]::OrdinalIgnoreCase)){
            $t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$t,[ref]$e)
            if(@($e).Count){throw ('Syntaxe : '+$e[0].Message)}
        }
    }catch{$state='ERROR';$message=$_.Exception.Message}
    $results.Add([pscustomobject]@{File=$relative;State=$state;Detail=$message})
}
$errors=@($results|Where-Object{$_.State -eq 'ERROR'})
# SP-09: offline signature report (DEV package): integrity and publisher are two separate answers.
$signature=$null;$signatureFailed=$false
$signatureTool=Join-Path $rootPath 'tools\Test-DomeniaSignature.ps1'
if([IO.File]::Exists($signatureTool)){
    $signature=@(& $signatureTool -Root $rootPath -PublisherThumbprint $PublisherThumbprint -RequireSignature:$RequireSignature -PassThru -Quiet)|Select-Object -Last 1
    $signatureFailed=(($null -eq $signature) -or (-not [bool]$signature.Passed))
}elseif($RequireSignature){$signatureFailed=$true}
$signatureSummary=if($null -ne $signature){[ordered]@{Integrity=$signature.Integrity.Status;Publisher=$signature.Publisher.Status;Overall=$signature.Overall;Undeclared=@($signature.Integrity.Undeclared);Offline=$true}}else{$null}
$report=[ordered]@{Build=[string]$data.Build;Executed=(Get-Date).ToString('o');Runtime=$PSVersionTable.PSVersion.ToString();Failed=$errors.Count;NoADAccess=$true;NoApplicationStartup=$true;SignatureVerified=(($null -ne $signature) -and ($signature.Publisher.Status -ceq 'Editeur verifie'));Signature=$signatureSummary;Files=$results.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-pack-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){
    $results|Format-Table File,State -AutoSize;Write-Host ('Rapport : '+$ReportPath)
    if($null -ne $signature){Write-Host ('Intégrité : '+$signature.Integrity.Status+' ; éditeur : '+$signature.Publisher.Status+'. '+$signature.IntegrityNote)}
    else{Write-Host 'Un manifeste local vérifie la cohérence, pas la signature ou la provenance du code.'}
}
if($errors.Count){throw ('Verification du paquet en echec : '+$errors.Count+' fichier(s).')}
if($signatureFailed){throw ('Vérification de signature en échec : '+$(if($null -ne $signature){$signature.Overall+' ; éditeur : '+$signature.Publisher.Status}else{'outil tools\Test-DomeniaSignature.ps1 absent'}))}
