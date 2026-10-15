#requires -Version 5.1
<# Domenia.Automation/1 : interface automatisable locale (points 139 et 140).
   Lecture seule de la base SQLite locale de Domenia ; aucun port réseau, aucun service, aucune liaison à lʼannuaire,
   aucun contact avec un poste, aucune écriture dans la base. Une commande, une réponse datée, puis le processus sʼarrête.

   Exemples (Windows PowerShell 5.1, depuis le dossier de Domenia) :
     powershell -NoProfile -File wad\Domenia-Automate.ps1 version
     powershell -NoProfile -File wad\Domenia-Automate.ps1 etat -DatabasePath "D:\Domenia\Domains\corp\Domenia.db"
     powershell -NoProfile -File wad\Domenia-Automate.ps1 postes -DatabasePath "…\Domenia.db" -OrganizationalUnit "OU=Postes,DC=corp,DC=example" -Format Csv -OutputPath "D:\Exports\postes.csv"
     powershell -NoProfile -File wad\Domenia-Automate.ps1 observations -DatabasePath "…\Domenia.db" -Computers PC-01,PC-02 -Family Inventory
     powershell -NoProfile -File wad\Domenia-Automate.ps1 dossier -DatabasePath "…\Domenia.db" -Computers PC-01 -OutputPath "D:\Diagnostics"

   Codes de sortie : 0 succès, 2 commande ou paramètre invalide, 3 base absente, illisible ou occupée,
   4 refus (périmètre absent, intégrité du paquet), 5 écriture du résultat impossible.
   La sortie standard suit la page de codes de la console : -OutputPath écrit un fichier UTF-8 et garde les accents.
#>
[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Command='version',
    [string]$DatabasePath='',
    [string]$OrganizationalUnit='',
    [string[]]$Computers=@(),
    [string[]]$Guids=@(),
    [string]$Family='',
    [int]$Limit=0,
    [string]$Format='',
    [string]$OutputPath='',
    [string[]]$Sections=@(),
    [string]$Build='',
    [switch]$PassThru
)
# The SQLite reader below is the core's own code, written for the core's mode (Domenia-Core.ps1 turns strict mode off):
# a strict caller (a test suite, an automation script) must not make it read its lazily created variables as errors.
# Scoped to this script: the caller keeps its own mode.
Set-StrictMode -Off
$ErrorActionPreference='Stop'
$automationWad=[IO.Path]::GetFullPath($PSScriptRoot)
$automationRoot=Split-Path -Parent $automationWad

function Stop-DomeniaAutomation {
    # One refusal: a machine-readable answer on the standard output and its exit code, or an exception for -PassThru.
    param([int]$Code,[string]$Message,[string]$Name='')
    if($PassThru){throw $Message}
    $answer=[pscustomobject]@{Contract='Domenia.Automation/1';Command=$Name;GeneratedUtc=[datetime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture);Error=$Message;ExitCode=$Code}
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject $answer -Depth 4))
    exit $Code
}

function Assert-DomeniaAutomationIntegrity {
    # The code read by this script must be the delivered one: same check as Domenia-Start.ps1 for these files.
    $manifestPath=Join-Path $automationWad 'package-manifest.json'
    if((-not [IO.File]::Exists($manifestPath)) -or (([IO.FileInfo]::new($manifestPath)).Length -gt 4MB)){Stop-DomeniaAutomation 4 'Manifeste du paquet absent ou trop volumineux : interface refusée.' $Command}
    $manifest=[IO.File]::ReadAllText($manifestPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
    foreach($relative in @('wad/Domenia-Core.ps1','wad/modules/Domenia-Common.Model.ps1','wad/modules/Domenia-Automation.Model.ps1')){
        $entry=@($manifest.Files|Where-Object{([string]$_.Path -ceq $relative) -and ($_.Runtime -eq $true)})
        $path=Join-Path $automationRoot ($relative.Replace('/','\'))
        if($entry.Count -ne 1){Stop-DomeniaAutomation 4 ('Fichier absent du manifeste : '+$relative+'. Reconstruisez ou réinstallez le paquet.') $Command}
        if(-not [IO.File]::Exists($path)){Stop-DomeniaAutomation 4 ('Fichier du paquet manquant : '+$relative+'.') $Command}
        $item=Get-Item -LiteralPath $path -Force
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){Stop-DomeniaAutomation 4 ('Fichier redirigé refusé : '+$relative+'.') $Command}
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine [string]$entry[0].Sha256){Stop-DomeniaAutomation 4 ('Empreinte différente du manifeste : '+$relative+'. Aucune lecture.') $Command}
    }
}

function Import-DomeniaAutomationSqlite {
    # The SQLite reader of Domenia itself, taken from the verified core by its syntax tree (no copy to drift).
    $core=Join-Path $automationWad 'Domenia-Core.ps1'
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($core,[ref]$tokens,[ref]$errors)
    if(@($errors).Count -gt 0){Stop-DomeniaAutomation 4 'Le cœur de Domenia ne passe pas le parseur PowerShell.' $Command}
    $definitions=New-Object 'System.Collections.Generic.List[string]'
    $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false))
    # P-CD-09: the reader traces a swallowed error with Write-DomeniaSwallowed, defined in the core script scope; the
    # core's own trace comes with it. It never throws and keeps the ring of Domenia-Common.Model.ps1 (dot-sourced
    # before this reader); there is no journal here and, without a masking rule, no message is kept.
    foreach($name in @('Write-DomeniaSwallowed','Initialize-DomeniaWinSqliteNative','New-DomeniaUtf8Ptr','ConvertFrom-DomeniaUtf8Ptr','Open-DomeniaDatabase','Close-DomeniaDatabase','Invoke-DomeniaDbQuery')){
        $found=@($nodes|Where-Object{$_.Name -ceq $name})
        if($found.Count -ne 1){Stop-DomeniaAutomation 4 ('Fonction de lecture introuvable dans le cœur : '+$name+'.') $Command}
        $definitions.Add($found[0].Extent.Text)
    }
    return ($definitions.ToArray() -join "`n")
}

function Get-DomeniaAutomationRows {
    param([string]$Sql)
    try{return @(Invoke-DomeniaDbQuery -Sql $Sql -DatabaseHandle $script:AutomationDb)}
    catch{
        $text=[string]$_.Exception.Message
        if($text -match 'code 5\b|code 6\b|locked|busy'){Stop-DomeniaAutomation 3 'Base locale occupée : réessayez dans un instant.' $Command}
        Stop-DomeniaAutomation 3 ('Lecture de la base impossible : '+$text) $Command
    }
}

function Get-DomeniaAutomationSection {
    # One read command of the contract, as an envelope (also used for each section of a dossier).
    param([string]$Name,$Request,$Source,[string[]]$Tables)
    $kinds=@{postes='Computers';observations='Observations';associations='Links';requetes='Recipes'}
    $tableOf=@{Computers='ad_objects';Observations='domenia_observations';Links='user_machine_links';Recipes='domenia_query_recipes'}
    if($Name -eq 'etat'){
        $facts=[ordered]@{}
        $file=[IO.FileInfo]::new([string]$Request.DatabasePath)
        $facts.Base=[pscustomobject]@{Chemin=$file.FullName;Octets=$file.Length;ModifieeUtc=$file.LastWriteTimeUtc.ToString('o',[Globalization.CultureInfo]::InvariantCulture)}
        $notes=New-Object 'System.Collections.Generic.List[string]'
        foreach($pair in @(@('Schema','schema_info'),@('Magasin','domenia_store_state'),@('Synchronisations','sync_state'),@('Objets','ad_objects'),@('Observations','domenia_observations'),@('Associations','user_machine_links'),@('Requetes','domenia_query_recipes'))){
            if($Tables -notcontains $pair[1]){$facts[$pair[0]]=$null;$notes.Add('Table '+$pair[1]+' absente : '+$pair[0]+' inconnu.');continue}
            $kind=switch($pair[0]){'Schema'{'Schema'}'Magasin'{'StoreState'}'Synchronisations'{'Sync'}'Objets'{'ObjectCounts'}'Observations'{'ObservationCounts'}'Associations'{'LinkCounts'}'Requetes'{'RecipeCount'}}
            $facts[$pair[0]]=@(Get-DomeniaAutomationRows (Get-DomeniaAutomationQuery -Kind $kind))
        }
        return (New-DomeniaAutomationEnvelope -Command 'etat' -Items @([pscustomobject]$facts) -Source $Source -Request $Request -Notes $notes.ToArray())
    }
    $kind=$kinds[$Name]
    if($Tables -notcontains $tableOf[$kind]){return (New-DomeniaAutomationEnvelope -Command $Name -Items @() -Source $Source -Request $Request -Notes @('Table '+$tableOf[$kind]+' absente de cette base : aucune donnée, ce qui ne prouve pas leur absence dans Active Directory.'))}
    if(($kind -in @('Observations','Links')) -and ($Tables -notcontains 'ad_objects')){return (New-DomeniaAutomationEnvelope -Command $Name -Items @() -Source $Source -Request $Request -Notes @('Index local des objets absent : périmètre non résolu.'))}
    $rows=@(Get-DomeniaAutomationRows (Get-DomeniaAutomationQuery -Kind $kind -Request $Request))
    $truncated=($rows.Count -gt [int]$Request.Limit)
    if($truncated){$rows=@($rows[0..([int]$Request.Limit-1)])}
    $converted=ConvertTo-DomeniaAutomationItems -Kind $kind -Rows $rows
    $notes=@()
    if($truncated){$notes=@('Limite de '+$Request.Limit+' lignes atteinte : résultat partiel.')}
    return (New-DomeniaAutomationEnvelope -Command $Name -Items @($converted.Items) -Source $Source -Request $Request -Truncated $truncated -Excluded @($converted.Excluded) -Notes $notes)
}

function Write-DomeniaAutomationText {
    # Atomic write of one named file: temporary file in the same folder, then replace. UTF-8, with BOM for CSV (Excel).
    param([string]$Path,[string]$Text,[bool]$Bom=$false)
    $folder=[IO.Path]::GetDirectoryName($Path)
    $temporary=Join-Path $folder ('.domenia-automate-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try{
        [IO.File]::WriteAllText($temporary,$Text,[Text.UTF8Encoding]::new($Bom))
        if([IO.File]::Exists($Path)){[IO.File]::Replace($temporary,$Path,[NullString]::Value,$true)}else{[IO.File]::Move($temporary,$Path)}
    }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}

function Test-DomeniaAutomationLocalPath {
    # Local, existing, not redirected: a network share (UNC path or mapped drive letter) or a link is refused for the
    # base and for the destination. SQLite over SMB can read torn pages; a dossier never leaves the workstation.
    param([string]$Path,[switch]$Directory)
    $full=[IO.Path]::GetFullPath($Path)
    if($full.StartsWith('\\')){return ''}
    $root=[IO.Path]::GetPathRoot($full)
    if(-not $root){return ''}
    try{if(([IO.DriveInfo]::new($root)).DriveType -eq [IO.DriveType]::Network){return ''}}catch{return ''}
    $exists=if($Directory){[IO.Directory]::Exists($full)}else{[IO.File]::Exists($full)}
    if(-not $exists){return ''}
    $cursor=Get-Item -LiteralPath $full -Force
    while($null -ne $cursor){
        if($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint){return ''}
        $cursor=if($cursor -is [IO.FileInfo]){$cursor.Directory}else{$cursor.Parent}
    }
    return $full
}

# ---------------------------------------------------------------- start
if(($PSVersionTable.PSEdition -eq 'Core') -or (-not [Environment]::Is64BitProcess)){Stop-DomeniaAutomation 2 'Utilisez Windows PowerShell 5.1 64 bits.' $Command}
Assert-DomeniaAutomationIntegrity
. (Join-Path $automationWad 'modules\Domenia-Common.Model.ps1')
. (Join-Path $automationWad 'modules\Domenia-Automation.Model.ps1')
$check=Test-DomeniaAutomationRequest -Command $Command -DatabasePath $DatabasePath -OrganizationalUnit $OrganizationalUnit -Computers $Computers -Guids $Guids -Family $Family -Limit $Limit -Format $Format -OutputPath $OutputPath -Sections $Sections
if(-not $check.Valid){Stop-DomeniaAutomation ([int]$check.ExitCode) ([string]$check.Error) $Command}
$request=$check.Request
$envelope=$null

if($request.Command -eq 'version'){
    $envelope=New-DomeniaAutomationEnvelope -Command 'version' -Items @(Get-DomeniaAutomationContract) -Request $null
}else{
    $databaseFile=Test-DomeniaAutomationLocalPath -Path ([string]$request.DatabasePath)
    if(-not $databaseFile){Stop-DomeniaAutomation 3 'Base locale absente, sur un partage réseau ou redirigée : indiquez le fichier .db local.' $request.Command}
    $request.DatabasePath=$databaseFile
    . ([scriptblock]::Create((Import-DomeniaAutomationSqlite)))
    function Get-CfgValue {param($Section,$Name,$Default);return $Default}
    # Inside Domenia (Atelier worker) the native SQLite type already exists: it is reused, never defined twice.
    $script:WinSqliteNative='Domenia.WinSqliteNative' -as [type]
    $script:AutomationDb=[IntPtr]::Zero
    try{
        try{[void](Initialize-DomeniaWinSqliteNative);$script:AutomationDb=Open-DomeniaDatabase -Path $databaseFile -ReadOnly}
        catch{Stop-DomeniaAutomation 3 ('Ouverture en lecture seule impossible : '+$_.Exception.Message) $request.Command}
        $tables=@(Get-DomeniaAutomationRows (Get-DomeniaAutomationQuery -Kind Tables)|ForEach-Object{[string]$_.name})
        $store=$null
        if($tables -contains 'domenia_store_state'){$store=@(Get-DomeniaAutomationRows (Get-DomeniaAutomationQuery -Kind StoreState))|Select-Object -First 1}
        $source=[pscustomobject]@{Base=$databaseFile;Magasin=$(if($null -ne $store){[string]$store.store_id}else{''});Domaine=$(if($null -ne $store){[string]$store.domain_dn}else{''});Revision=$(if($null -ne $store){[long]$store.revision}else{$null});LectureSeule=$true}
        if($request.Command -eq 'dossier'){
            $sections=[ordered]@{}
            foreach($name in @($request.Sections)){$sections[$name]=Get-DomeniaAutomationSection -Name $name -Request $request -Source $source -Tables $tables}
            try{$dossier=New-DomeniaOfflineDossier -Sections $sections -Request $request -Source $source -Build $Build}catch{Stop-DomeniaAutomation 4 $_.Exception.Message $request.Command}
        }else{
            $envelope=Get-DomeniaAutomationSection -Name $request.Command -Request $request -Source $source -Tables $tables
        }
    }finally{
        if($script:AutomationDb -ne [IntPtr]::Zero){Close-DomeniaDatabase $script:AutomationDb;$script:AutomationDb=[IntPtr]::Zero}
    }
    if($request.Command -eq 'dossier'){
        # Point 139: a new dated folder, written beside its final name then renamed; an existing folder is never reused.
        $parent=Test-DomeniaAutomationLocalPath -Path ([string]$request.OutputPath) -Directory
        if(-not $parent){Stop-DomeniaAutomation 5 'Dossier de destination absent, sur un partage réseau ou redirigé.' 'dossier'}
        $subject=switch([string]$request.Perimeter.Kind){'OU'{([string]$request.Perimeter.OrganizationalUnit).Split(',')[0] -replace '^(ou|dc)=',''}'Noms'{if(@($request.Perimeter.Computers).Count -eq 1){[string]@($request.Perimeter.Computers)[0]}else{[string]@($request.Perimeter.Computers).Count+'-postes'}}default{[string]@($request.Perimeter.Guids).Count+'-postes'}}
        $baseName=Get-DomeniaOfflineDossierName -Subject $subject
        $target=Join-Path $parent $baseName;$suffix=2
        while(([IO.Directory]::Exists($target)) -or ([IO.File]::Exists($target))){$target=Join-Path $parent ($baseName+'-'+$suffix);$suffix++}
        $temporary=Join-Path $parent ('.domenia-dossier-'+[guid]::NewGuid().ToString('N')+'.tmp')
        $moved=$false
        try{
            [void][IO.Directory]::CreateDirectory($temporary)
            foreach($file in @($dossier.Files)){[IO.File]::WriteAllText((Join-Path $temporary ([string]$file.Name)),[string]$file.Text,[Text.UTF8Encoding]::new($false))}
            [IO.Directory]::Move($temporary,$target);$moved=$true
        }catch{
            Stop-DomeniaAutomation 5 ('Écriture du dossier impossible : '+$_.Exception.Message) 'dossier'
        }finally{
            # Also on a stopped pipeline (task cancelled or timed out), where catch blocks do not run: no partial copy
            # of the data is left in the destination.
            if((-not $moved) -and ([IO.Directory]::Exists($temporary))){try{[IO.Directory]::Delete($temporary,$true)}catch{}}
        }
        $envelope=New-DomeniaAutomationEnvelope -Command 'dossier' -Items @([pscustomobject]@{Dossier=$target;Fichiers=@($dossier.Files|ForEach-Object{[string]$_.Name});Sections=@($dossier.Manifest.Sections)}) -Source $dossier.Manifest.Source -Request $request
    }
}

if($PassThru){return $envelope}
$csvColumns=@{postes=@('Guid','Nom','DN','Etat','Description','DerniereConnexion','ModifieAD','SynchroniseUtc','Controleur','Systeme','CreeAD','MotDePasseMachineDefini','FaitsLusUtc');associations=@('Poste','Compte','Source','Confiance','VerifieAD','ObserveUtc','Details','CompteGuid','PosteGuid','CompteDN','PosteDN')}
$isCsv=([string]$request.Format -eq 'Csv')
$text=if($isCsv){ConvertTo-DomeniaAutomationCsv -Items @($envelope.Items) -Columns $csvColumns[$request.Command]}else{ConvertTo-Json -InputObject $envelope -Depth 32}
if(($request.OutputPath) -and ($request.Command -ne 'dossier')){
    $wanted=if($isCsv){'.csv'}else{'.json'}
    $full=[IO.Path]::GetFullPath([string]$request.OutputPath)
    if([IO.Path]::GetExtension($full) -ine $wanted){Stop-DomeniaAutomation 5 ('Le fichier de sortie doit avoir lʼextension '+$wanted+'.') $request.Command}
    if(-not (Test-DomeniaAutomationLocalPath -Path ([IO.Path]::GetDirectoryName($full)) -Directory)){Stop-DomeniaAutomation 5 'Dossier du fichier de sortie absent, sur un partage réseau ou redirigé.' $request.Command}
    try{Write-DomeniaAutomationText -Path $full -Text $text -Bom $isCsv}catch{Stop-DomeniaAutomation 5 ('Écriture impossible : '+$_.Exception.Message) $request.Command}
    # The file holds the answer; the standard output only says where, how many and whether a bound was reached.
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject ([pscustomobject]@{Contract='Domenia.Automation/1';Command=$request.Command;Path=$full;Count=$envelope.Count;Truncated=$envelope.Truncated}) -Depth 4))
}else{
    [Console]::Out.WriteLine($text)
}
exit 0
