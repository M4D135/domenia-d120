#requires -Version 5.1
# Points 139 et 140 : interface automatisable locale (wad\Domenia-Automate.ps1, Domenia.Automation/1) et dossier de
# diagnostic hors ligne de l Atelier (operation OfflineDossier). Base SQLite fictive creee dans le dossier temporaire,
# paquet minimal recopie avec son manifeste : aucune donnee reelle, aucun reseau, aucun annuaire.
[CmdletBinding()]param([string]$ReportPath='')
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
$wad=Split-Path -Parent $PSScriptRoot
$modules=Join-Path $wad 'modules'
$checks=[Collections.Generic.List[object]]::new()
function Expect($ok,$why){if(-not $ok){throw $why}}
function Case($name,[scriptblock]$body){try{&$body;$checks.Add([pscustomobject]@{Name=$name;Passed=$true;Error=''})}catch{$checks.Add([pscustomobject]@{Name=$name;Passed=$false;Error=($_.Exception.Message+' '+$_.ScriptStackTrace)})}}
$native=($env:OS -eq 'Windows_NT' -and $PSVersionTable.PSEdition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and [Environment]::Is64BitProcess)
$root=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-automation-'+[guid]::NewGuid().ToString('N'))
try{
if($native){
    # ------------------------------------------------------------ minimal package with its manifest
    $package=Join-Path $root 'paquet';$packageWad=Join-Path $package 'wad';[void][IO.Directory]::CreateDirectory((Join-Path $packageWad 'modules'))
    $copied=@('Domenia-Automate.ps1','Domenia-Core.ps1','modules\Domenia-Common.Model.ps1','modules\Domenia-Automation.Model.ps1')
    foreach($relative in $copied){[IO.File]::Copy((Join-Path $wad $relative),(Join-Path $packageWad $relative))}
    $entries=@(foreach($relative in $copied){[pscustomobject]@{Path=('wad/'+$relative.Replace('\','/'));Sha256=(Get-FileHash -LiteralPath (Join-Path $packageWad $relative) -Algorithm SHA256).Hash;Bytes=([IO.FileInfo]::new((Join-Path $packageWad $relative))).Length;Runtime=$true;PreserveExisting=$false}})
    [IO.File]::WriteAllText((Join-Path $packageWad 'package-manifest.json'),(ConvertTo-Json -InputObject ([pscustomobject]@{Format=1;Files=$entries}) -Depth 4),[Text.UTF8Encoding]::new($false))
    $cli=Join-Path $packageWad 'Domenia-Automate.ps1'
    # ------------------------------------------------------------ fixture base, written with the SQLite reader of the core
    $tokens=$null;$errors=$null;$coreAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$tokens,[ref]$errors)
    foreach($name in @('Initialize-DomeniaWinSqliteNative','New-DomeniaUtf8Ptr','ConvertFrom-DomeniaUtf8Ptr')){. ([scriptblock]::Create(@($coreAst.FindAll({param($n)($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -ceq $name)},$false))[0].Extent.Text))}
    $script:WinSqliteNative=$null;[void](Initialize-DomeniaWinSqliteNative)
    function Invoke-AutFixtureSql {
        param([string]$Path,[string]$Sql)
        $db=[IntPtr]::Zero;$pathPtr=New-DomeniaUtf8Ptr $Path;$sqlPtr=[IntPtr]::Zero
        try{
            $rc=[Domenia.WinSqliteNative]::sqlite3_open_v2($pathPtr,[ref]$db,6,[IntPtr]::Zero);if($rc -ne 0){throw ('Ouverture de la base fictive : '+$rc)}
            $sqlPtr=New-DomeniaUtf8Ptr $Sql;$err=[IntPtr]::Zero
            $rc=[Domenia.WinSqliteNative]::sqlite3_exec($db,$sqlPtr,[IntPtr]::Zero,[IntPtr]::Zero,[ref]$err);if($rc -ne 0){throw ('Base fictive : '+(ConvertFrom-DomeniaUtf8Ptr $err))}
        }finally{if($sqlPtr -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::FreeHGlobal($sqlPtr)};[Runtime.InteropServices.Marshal]::FreeHGlobal($pathPtr);if($db -ne [IntPtr]::Zero){[void][Domenia.WinSqliteNative]::sqlite3_close($db)}}
    }
    $database=Join-Path $root 'Domenia.db'
    Invoke-AutFixtureSql $database @'
CREATE TABLE schema_info(key TEXT PRIMARY KEY,value TEXT NOT NULL);
INSERT INTO schema_info VALUES('schema_version','11');
CREATE TABLE domenia_store_state(id INTEGER PRIMARY KEY CHECK(id=1),store_id TEXT NOT NULL,domain_dn TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 0);
INSERT INTO domenia_store_state VALUES(1,'store-test','dc=corp,dc=example',42);
CREATE TABLE sync_state(scope TEXT PRIMARY KEY,server TEXT,base_dn TEXT,highest_usn INTEGER DEFAULT 0,last_sync TEXT,item_count INTEGER DEFAULT 0,details TEXT);
INSERT INTO sync_state VALUES('directory','dc1.corp.example','DC=corp,DC=example',100,'2026-10-14T08:00:00Z',4,'detail interne');
CREATE TABLE ad_objects(object_key TEXT PRIMARY KEY, object_guid TEXT, object_type TEXT NOT NULL, name TEXT COLLATE NOCASE, login TEXT COLLATE NOCASE, upn TEXT COLLATE NOCASE, display_name TEXT, description TEXT, extra TEXT, state TEXT, distinguished_name TEXT, when_changed TEXT, usn_changed INTEGER DEFAULT 0, last_logon TEXT, search_key TEXT, source_dc TEXT, synced_at TEXT);
INSERT INTO ad_objects(object_key,object_guid,object_type,name,description,state,distinguished_name,last_logon,synced_at) VALUES
 ('pc-01','aaaaaaaa-0000-0000-0000-000000000001','Machine','PC-01','Accueil','Actif','CN=PC-01,OU=Postes,DC=corp,DC=example','2026-10-13T07:00:00Z','2026-10-14T08:00:00Z'),
 ('pc-02','aaaaaaaa-0000-0000-0000-000000000002','Machine','PC-02','=cmd|calc','Actif','CN=PC-02,OU=Postes,DC=corp,DC=example','2026-10-12T07:00:00Z','2026-10-14T08:00:00Z'),
 ('pc-03','aaaaaaaa-0000-0000-0000-000000000003','Machine','PC-03','Serveur','Actif','CN=PC-03,OU=Serveurs,DC=corp,DC=example','2026-10-12T07:00:00Z','2026-10-14T08:00:00Z'),
 ('pc-04','aaaaaaaa-0000-0000-0000-000000000004','Machine','PC-04','Salle 3','Actif','CN=PC-04,OU=Salle 3,OU=Écoles,DC=corp,DC=example','2026-10-12T07:00:00Z','2026-10-14T08:00:00Z'),
 ('pc-05','aaaaaaaa-0000-0000-0000-000000000005','Machine','PC-05','Sans accent','Actif','CN=PC-05,OU=Ecoles,DC=corp,DC=example','2026-10-12T07:00:00Z','2026-10-14T08:00:00Z'),
 ('alice','bbbbbbbb-0000-0000-0000-000000000001','Utilisateur','Alice','','Actif','CN=Alice,OU=Postes,DC=corp,DC=example','','2026-10-14T08:00:00Z');
CREATE TABLE ad_computer_facts(object_guid TEXT PRIMARY KEY,object_key TEXT,os_version TEXT,when_created TEXT,pwd_last_set TEXT,laps_kind TEXT,laps_expiry TEXT,read_at TEXT);
INSERT INTO ad_computer_facts VALUES('aaaaaaaa-0000-0000-0000-000000000001','pc-01','10.0 (22631)','2024-01-01T00:00:00Z','2026-10-01T00:00:00Z','Windows LAPS','LapsExpiry-NeverExported','2026-10-14T08:00:00Z');
CREATE TABLE domenia_observations(object_guid TEXT NOT NULL,family TEXT NOT NULL,dn TEXT NOT NULL,definition_hash TEXT NOT NULL DEFAULT '',attempt_at TEXT NOT NULL,status TEXT NOT NULL,error TEXT NOT NULL DEFAULT '',success_at TEXT NOT NULL DEFAULT '',payload TEXT,attempt_payload TEXT,summary_payload TEXT,attempt_summary TEXT,revision INTEGER NOT NULL,PRIMARY KEY(object_guid,family));
INSERT INTO domenia_observations(object_guid,family,dn,attempt_at,status,success_at,payload,revision) VALUES
 ('aaaaaaaa-0000-0000-0000-000000000001','Inventory','CN=PC-01,OU=Postes,DC=corp,DC=example','2026-10-14T08:00:00Z','Success','2026-10-14T08:00:00Z','{"Computer":"PC-01","Inventory":{"Model":"X1","AdminPassword":"S3cr3t-NeverExported"}}',40),
 ('aaaaaaaa-0000-0000-0000-000000000001','Presence','CN=PC-01,OU=Postes,DC=corp,DC=example','2026-10-14T08:05:00Z','Success','2026-10-14T08:05:00Z','{"Computer":"PC-01","Presence":"Online"}',41),
 ('aaaaaaaa-0000-0000-0000-000000000003','Console','CN=PC-03,OU=Serveurs,DC=corp,DC=example','2026-10-14T08:00:00Z','Error','','',42),
 ('aaaaaaaa-0000-0000-0000-000000000004','Presence','CN=PC-04,OU=Salle 3,OU=Écoles,DC=corp,DC=example','2026-10-14T08:05:00Z','Success','2026-10-14T08:05:00Z','{"Computer":"PC-04","Presence":"Online"}',43);
CREATE TABLE user_machine_links(computer_key TEXT PRIMARY KEY,user_login TEXT,computer TEXT,source TEXT,confidence INTEGER,verified_in_ad INTEGER,observed_at TEXT,details TEXT,user_guid TEXT,computer_guid TEXT,user_dn TEXT,computer_dn TEXT);
INSERT INTO user_machine_links VALUES('pc-01','alice','PC-01','Import GLPI',0,1,'2026-10-14T08:00:00Z','Lot dʼimport 20261014T080000000Z-aaaaaaaa. Importé depuis glpi.csv, enregistrement 1.','bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','CN=Alice,OU=Postes,DC=corp,DC=example','CN=PC-01,OU=Postes,DC=corp,DC=example');
CREATE TABLE secret_state(computer_key TEXT PRIMARY KEY,computer TEXT,checked_at TEXT,bitlocker_keys INTEGER DEFAULT 0,bitlocker_last TEXT,laps_scheme TEXT,laps_expiry TEXT,verdict TEXT,detail TEXT);
INSERT INTO secret_state VALUES('pc-01','PC-01','2026-10-14',1,'2026-10-01','Windows LAPS','2026-11-01','OK','BitLockerSecret-NeverExported');
CREATE TABLE domenia_query_recipes(id TEXT PRIMARY KEY NOT NULL, domain_dn TEXT NOT NULL, name TEXT NOT NULL, name_fold TEXT NOT NULL, category TEXT NOT NULL, revision INTEGER NOT NULL, definition_version INTEGER NOT NULL, definition_json TEXT NOT NULL, definition_sha256 TEXT NOT NULL, created_utc TEXT NOT NULL, updated_utc TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0);
INSERT INTO domenia_query_recipes VALUES('r1','dc=corp,dc=example','Disques pleins','disques pleins','Disques',3,2,'{"Format":"Domenia.Query/2","Name":"Disques pleins"}','ABC','2026-10-01T00:00:00Z','2026-10-10T00:00:00Z',0),('r2','dc=corp,dc=example','Ancienne','ancienne','Divers',1,2,'{"Format":"Domenia.Query/2","Name":"Ancienne"}','DEF','2026-10-01T00:00:00Z','2026-10-01T00:00:00Z',1);
'@
    $baseHash=(Get-FileHash -LiteralPath $database -Algorithm SHA256).Hash
    $exports=Join-Path $root 'Exports';[void][IO.Directory]::CreateDirectory($exports)
    function Invoke-AutCli {
        # Child Windows PowerShell 5.1 process, as an automation script would call it.
        param([string[]]$Arguments)
        # Continue: under Stop, a line of the child on its error stream would end this suite instead of being read.
        $ErrorActionPreference='Continue'
        $output=@(& (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $cli @Arguments 2>&1)
        return [pscustomobject]@{Code=$LASTEXITCODE;Text=(($output|ForEach-Object{[string]$_}) -join "`n")}
    }

    Case 'Point 140 : version et contrat sans base, codes de sortie des refus' {
        $r=Invoke-AutCli @('version');Expect ($r.Code -eq 0) ('version : '+$r.Text)
        $answer=$r.Text|ConvertFrom-Json;Expect ($answer.Contract -eq 'Domenia.Automation/1' -and @($answer.Items)[0].Version -eq 1) 'contrat absent'
        Expect ((Invoke-AutCli @('effacer','-DatabasePath',$database)).Code -eq 2) 'commande inconnue acceptee'
        Expect ((Invoke-AutCli @('observations','-DatabasePath',$database)).Code -eq 4) 'perimetre implicite accepte'
        Expect ((Invoke-AutCli @('etat','-DatabasePath',(Join-Path $root 'absente.db'))).Code -eq 3) 'base absente non signalee'
    }
    Case 'Point 140 : etat date, postes en CSV neutralise, observations sans secret, base inchangee' {
        $stateFile=Join-Path $root 'etat.json'
        $r=Invoke-AutCli @('etat','-DatabasePath',$database,'-OutputPath',$stateFile);Expect ($r.Code -eq 0) ('etat : '+$r.Text)
        $state=[IO.File]::ReadAllText($stateFile,[Text.Encoding]::UTF8)|ConvertFrom-Json
        $facts=@($state.Items)[0]
        Expect ($state.Source.Revision -eq 42 -and $state.Source.LectureSeule -and @($facts.Objets|Where-Object{$_.object_type -eq 'Machine'})[0].n -eq 5 -and @($facts.Observations).Count -eq 3) 'etat local incomplet'
        Expect ($state.Meaning -match 'non revérifiées') 'portee de la lecture non dite'
        $csv=Join-Path $root 'postes.csv'
        $r=Invoke-AutCli @('postes','-DatabasePath',$database,'-OrganizationalUnit','OU=Postes,DC=corp,DC=example','-Format','Csv','-OutputPath',$csv);Expect ($r.Code -eq 0) ('postes : '+$r.Text)
        $bytes=[IO.File]::ReadAllBytes($csv);$text=[Text.Encoding]::UTF8.GetString($bytes)
        Expect ($bytes[0] -eq 0xEF -and $text -match '"PC-01"' -and $text -match '"PC-02"' -and $text -notmatch 'PC-03' -and $text -notmatch 'PC-04' -and $text -match ([regex]::Escape('"''=cmd|calc"'))) 'CSV des postes de l OU'
        Expect ($text -notmatch 'NeverExported') 'metadonnees LAPS exportees'
        $obs=Join-Path $root 'observations.json'
        $r=Invoke-AutCli @('observations','-DatabasePath',$database,'-Computers','PC-01,PC-03','-OutputPath',$obs);Expect ($r.Code -eq 0) ('observations : '+$r.Text)
        $raw=[IO.File]::ReadAllText($obs,[Text.Encoding]::UTF8);$answer=$raw|ConvertFrom-Json
        Expect (@($answer.Items).Count -eq 3 -and $raw -notmatch 'NeverExported' -and @($answer.ExcludedFields) -contains 'aaaaaaaa-0000-0000-0000-000000000001:Inventory.Inventory.AdminPassword') 'secret de charge utile exporte ou exclusion non dite'
        $error3=@($answer.Items|Where-Object{$_.Famille -eq 'Console'})[0];Expect ($error3.Statut -eq 'Error' -and $null -eq $error3.Donnees) 'erreur presentee comme mesure'
        $one=Invoke-AutCli @('postes','-DatabasePath',$database,'-OrganizationalUnit','DC=corp,DC=example','-Limit','1');$limited=$one.Text|ConvertFrom-Json
        Expect ($one.Code -eq 0 -and $limited.Truncated -and @($limited.Items).Count -eq 1) 'limite non signalee'
        Expect ((Get-FileHash -LiteralPath $database -Algorithm SHA256).Hash -eq $baseHash) 'base modifiee par une lecture'
    }
    Case 'Points 139 et 140 : OU au nom accentue trouvee quelle que soit la casse saisie' {
        # SQLite lower() and LIKE fold ASCII only: an OU named with an upper case accented letter must still be found,
        # with its sub-OUs, and never the OU that differs by the accent.
        foreach($typed in @('OU=Écoles,DC=corp,DC=example','ou=écoles,dc=corp,dc=example','OU=ÉCOLES,DC=CORP,DC=EXAMPLE')){
            $file=Join-Path $root 'ecoles.json';if([IO.File]::Exists($file)){[IO.File]::Delete($file)}
            $r=Invoke-AutCli @('postes','-DatabasePath',$database,'-OrganizationalUnit',$typed,'-OutputPath',$file);Expect ($r.Code -eq 0) ('postes '+$typed+' : '+$r.Text)
            $answer=[IO.File]::ReadAllText($file,[Text.Encoding]::UTF8)|ConvertFrom-Json
            Expect ((@($answer.Items).Count -eq 1) -and (@($answer.Items)[0].Nom -eq 'PC-04') -and (-not $answer.Truncated) -and ([string]$answer.Perimeter.OrganizationalUnit -ceq $typed)) ('OU accentuee ('+$typed+') : '+@($answer.Items).Count+' poste(s)')
        }
        $obs=Join-Path $root 'ecoles-observations.json'
        $r=Invoke-AutCli @('observations','-DatabasePath',$database,'-OrganizationalUnit','ou=écoles,dc=corp,dc=example','-OutputPath',$obs);Expect ($r.Code -eq 0) ('observations : '+$r.Text)
        $answer=[IO.File]::ReadAllText($obs,[Text.Encoding]::UTF8)|ConvertFrom-Json
        Expect ((@($answer.Items).Count -eq 1) -and (@($answer.Items)[0].Guid -eq 'aaaaaaaa-0000-0000-0000-000000000004')) 'observations de l OU accentuee'
        $plain=Join-Path $root 'ecoles-sans-accent.json'
        $r=Invoke-AutCli @('postes','-DatabasePath',$database,'-OrganizationalUnit','OU=Ecoles,DC=corp,DC=example','-OutputPath',$plain);Expect ($r.Code -eq 0) ('postes sans accent : '+$r.Text)
        $answer=[IO.File]::ReadAllText($plain,[Text.Encoding]::UTF8)|ConvertFrom-Json
        Expect ((@($answer.Items).Count -eq 1) -and (@($answer.Items)[0].Nom -eq 'PC-05')) 'OU sans accent confondue avec l OU accentuee'
    }
    Case 'Point 139 : dossier date, manifeste, empreintes, secrets exclus, jamais reecrit' {
        $r=Invoke-AutCli @('dossier','-DatabasePath',$database,'-Computers','PC-01','-OutputPath',$exports,'-Build','TEST-AUTOMATION');Expect ($r.Code -eq 0) ('dossier : '+$r.Text)
        $answer=$r.Text|ConvertFrom-Json;$folder=[string]@($answer.Items)[0].Dossier
        Expect ([IO.Directory]::Exists($folder) -and ([IO.Path]::GetFileName($folder) -match '^Domenia-Diagnostic-pc-01-\d{8}-\d{4}$')) ('dossier : '+$folder)
        $names=@(Get-ChildItem -LiteralPath $folder -File|ForEach-Object{$_.Name}|Sort-Object)
        Expect (($names -join ',') -eq 'associations.json,etat.json,LISEZMOI.txt,manifeste.json,observations.json,postes.json,requetes.json,SHA256SUMS.txt') ('fichiers : '+($names -join ','))
        foreach($line in @([IO.File]::ReadAllLines((Join-Path $folder 'SHA256SUMS.txt'))|Where-Object{$_})){
            $hash,$file=$line -split '  ',2
            Expect ((Get-FileHash -LiteralPath (Join-Path $folder $file) -Algorithm SHA256).Hash -ieq $hash) ('empreinte fausse : '+$file)
        }
        $all=(@(Get-ChildItem -LiteralPath $folder -File|ForEach-Object{[IO.File]::ReadAllText($_.FullName,[Text.Encoding]::UTF8)}) -join "`n")
        Expect ($all -notmatch 'NeverExported') 'secret, LAPS ou table des secrets dans le dossier'
        $recipes=[IO.File]::ReadAllText((Join-Path $folder 'requetes.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json
        Expect (@($recipes.Items).Count -eq 1 -and @($recipes.Items)[0].Nom -eq 'Disques pleins') 'requete archivee exportee'
        $manifest=[IO.File]::ReadAllText((Join-Path $folder 'manifeste.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json
        Expect ($manifest.Contract -eq 'Domenia.OfflineDossier/1' -and $manifest.Build -eq 'TEST-AUTOMATION' -and $manifest.Source.Revision -eq 42) 'manifeste incomplet'
        $again=(Invoke-AutCli @('dossier','-DatabasePath',$database,'-Computers','PC-01','-OutputPath',$exports)).Text|ConvertFrom-Json
        Expect ([string]@($again.Items)[0].Dossier -ne $folder -and [IO.Directory]::Exists($folder)) 'dossier precedent reecrit'
        Expect (@(Get-ChildItem -LiteralPath $exports -Force|Where-Object{$_.Name -like '.domenia-dossier-*'}).Count -eq 0) 'dossier temporaire abandonne'
        Expect ((Get-FileHash -LiteralPath $database -Algorithm SHA256).Hash -eq $baseHash) 'base modifiee par un dossier'
    }
    Case 'Point 140 : integrite du paquet controlee avant toute lecture' {
        $tampered=Join-Path $packageWad 'modules\Domenia-Automation.Model.ps1'
        $original=[IO.File]::ReadAllText($tampered)
        try{
            [IO.File]::WriteAllText($tampered,$original+"`n# modification",[Text.UTF8Encoding]::new($true))
            $r=Invoke-AutCli @('etat','-DatabasePath',$database)
            Expect ($r.Code -eq 4 -and $r.Text -match 'Empreinte') ('paquet modifie accepte : '+$r.Text)
        }finally{[IO.File]::WriteAllText($tampered,$original,[Text.UTF8Encoding]::new($true))}
        Expect ((Invoke-AutCli @('version')).Code -eq 0) 'paquet restaure refuse'
    }
    Case 'Point 139 : Atelier, perimetre choisi, worker OfflineDossier et banniere du dossier' {
        foreach($m in @('Domenia-Common.Model.ps1','Domenia-Automation.Model.ps1','Domenia-Automation.Worker.ps1','Domenia-Automation.UI.ps1')){. (Join-Path $modules $m)}
        $script:DomeniaAutomationModuleRoot=Join-Path $packageWad 'modules'
        $script:Ctrl=@{CmbSupportOfflineScope=[pscustomobject]@{SelectedItem=[pscustomobject]@{Tag='Selected'}};ChkSupportOfflineObservations=[pscustomobject]@{IsChecked=$true};ChkSupportOfflineLinks=[pscustomobject]@{IsChecked=$false};ChkSupportOfflineQueries=[pscustomobject]@{IsChecked=$true}}
        $script:Texts=@{};$script:Submission=$null;$script:Banner=$null;$script:AsyncJobs=[ordered]@{};$script:TaskCount=0
        function Get-DomeniaControl {param([string]$Name);if($script:Ctrl.ContainsKey($Name)){return $script:Ctrl[$Name]};return $null}
        function Set-DomeniaControlText {param([string]$Name,[string]$Text);$script:Texts[$Name]=$Text;return $true}
        # Engine double: the task stays in AsyncJobs until the test ends, cancels or withdraws it, as the engine does.
        function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$SuccessHandler,$ErrorHandler,$TimeoutSeconds,$TaskClass,$DisableControls);$script:TaskCount++;$id='job-'+$script:TaskCount;$script:AsyncJobs[$id]=[pscustomobject]@{Id=$id;CancelRequested=$false};$script:Submission=[pscustomobject]@{Id=$id;Name=$Name;OperationId=$OperationId;Code=$Code;Payload=$Payload;State=$CallbackState;Success=$SuccessHandler;Error=$ErrorHandler;TaskClass=$TaskClass};return $id}
        function Get-DomeniaLocalDatabasePathForRead {return $database}
        function Get-DomeniaExportDirectory {return $exports}
        function Get-DomeniaEffectiveWorkerResult {param($Result,[string[]]$RequiredProperties);foreach($p in $RequiredProperties){if($null -eq $Result.PSObject.Properties[$p]){return $null}};return $Result}
        function Show-DomeniaPageBanner {param($Kind,$Message,$ActionText,$ActionPath);$script:Banner=[pscustomobject]@{Kind=$Kind;Message=$Message;ActionPath=$ActionPath};return $true}
        function Write-AppLog {param($Text,$Level)}
        function Set-Status {param($Text,$Level)}
        $script:SessionEpoch=3L;$script:Conn=[pscustomobject]@{BaseDn='DC=corp,DC=example'};$script:MasterBuild='TEST-ATELIER';$script:SelectedBranchDn='DC=corp,DC=example'
        $script:SelectedObject=[pscustomobject]@{Type='Utilisateur';Name='Alice';Guid='bbbbbbbb-0000-0000-0000-000000000001'}
        Start-DomeniaOfflineDossier
        Expect ($null -eq $script:Submission -and $script:Texts['LblSupportOfflineStatus'] -match 'Sélectionnez un poste') 'compte pris pour un poste'
        $script:Ctrl.CmbSupportOfflineScope.SelectedItem.Tag='Branch'
        Start-DomeniaOfflineDossier
        Expect ($null -eq $script:Submission -and $script:Texts['LblSupportOfflineStatus'] -match 'pas une OU') 'domaine entier accepte comme perimetre'
        $script:Ctrl.CmbSupportOfflineScope.SelectedItem.Tag='Selected'
        $script:SelectedObject=[pscustomobject]@{Type='Machine';Name='PC-01';Guid='AAAAAAAA-0000-0000-0000-000000000001'}
        Start-DomeniaOfflineDossier
        $sub=$script:Submission
        Expect ($null -ne $sub -and $sub.OperationId -eq 'OfflineDossier' -and $sub.TaskClass -eq 'Explicit' -and $sub.Code -ceq (Get-DomeniaOfflineDossierWorkerCode)) 'travail non confie au worker epingle'
        Expect ((@($sub.Payload.Guids) -join ',') -eq 'aaaaaaaa-0000-0000-0000-000000000001' -and (@($sub.Payload.Sections) -join ',') -eq 'etat,postes,observations,requetes' -and $sub.Payload.OutputPath -eq $exports) 'perimetre ou sections du dossier'
        Start-DomeniaOfflineDossier
        Expect (($script:Texts['LblSupportOfflineStatus'] -match 'déjà en préparation') -and ($script:Submission.Id -eq $sub.Id)) 'deux dossiers en parallele'
        # The worker runs in this strict-mode suite: the automation interface must not depend on the caller's mode.
        $Payload=$sub.Payload;$Context=$null
        $result=& ([scriptblock]::Create($sub.Code))
        Expect ([IO.Directory]::Exists([string]$result.Path) -and @($result.Files) -contains 'manifeste.json' -and @($result.Files) -notcontains 'associations.json') ('resultat du worker : '+[string]$result.Path)
        # A late answer of another dossier is ignored; the answer of this one ends it and opens the folder from the banner.
        Complete-DomeniaOfflineDossier -Result $result -State ([pscustomobject]@{Id='autre';Epoch=3L;BaseDn='DC=corp,DC=example'})
        Expect ($null -eq $script:Banner) 'reponse d un autre dossier affichee'
        $script:AsyncJobs.Remove($sub.Id)
        Complete-DomeniaOfflineDossier -Result $result -State $sub.State
        Expect ($null -ne $script:Banner -and $script:Banner.ActionPath -eq [string]$result.Path -and $script:Texts['LblSupportOfflineStatus'] -match 'secrets exclus' -and $null -eq $script:DomeniaOfflineDossierJob) 'dossier non annonce'
        Expect ((Get-FileHash -LiteralPath $database -Algorithm SHA256).Hash -eq $baseHash) 'base modifiee par l Atelier'
        # « Annuler » on a dossier: the engine calls no handler, the next request must still be admitted.
        Start-DomeniaOfflineDossier
        $cancelled=$script:Submission
        Expect (($cancelled.Id -ne $sub.Id) -and ($null -ne $script:DomeniaOfflineDossierJob)) 'nouveau dossier refuse apres la fin du precedent'
        $script:AsyncJobs[$cancelled.Id].CancelRequested=$true
        Start-DomeniaOfflineDossier
        $afterCancel=$script:Submission
        Expect (($afterCancel.Id -ne $cancelled.Id) -and ($script:Texts['LblSupportOfflineStatus'] -notmatch 'déjà en préparation')) 'Preparer le dossier bloque apres une annulation'
        # A queued entry withdrawn by the engine disappears from AsyncJobs without any handler either.
        $script:AsyncJobs.Remove($afterCancel.Id)
        Start-DomeniaOfflineDossier
        $afterWithdraw=$script:Submission
        Expect ($afterWithdraw.Id -ne $afterCancel.Id) 'Preparer le dossier bloque apres un retrait de la file'
        Complete-DomeniaOfflineDossier -Result $result -State $cancelled.State
        Expect ($null -ne $script:DomeniaOfflineDossierJob) 'reponse tardive d un dossier annule acceptee'
        $script:AsyncJobs.Remove($afterWithdraw.Id);$script:DomeniaOfflineDossierJob=$null
        # « OU sélectionnée » on an OU named with an upper case accented letter: the dossier holds its workstation.
        $script:Ctrl.CmbSupportOfflineScope.SelectedItem.Tag='Branch';$script:SelectedBranchDn='OU=Écoles,DC=corp,DC=example'
        Start-DomeniaOfflineDossier
        $branch=$script:Submission
        Expect (($branch.Id -ne $afterWithdraw.Id) -and ($branch.Payload.OrganizationalUnit -ceq 'OU=Écoles,DC=corp,DC=example') -and (@($branch.Payload.Guids).Count -eq 0)) 'perimetre de l OU accentuee'
        $Payload=$branch.Payload
        $schoolResult=& ([scriptblock]::Create($branch.Code))
        $postes=[IO.File]::ReadAllText((Join-Path ([string]$schoolResult.Path) 'postes.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json
        Expect ((@($postes.Items).Count -eq 1) -and (@($postes.Items)[0].Nom -eq 'PC-04')) ('dossier de l OU accentuee : '+@($postes.Items).Count+' poste(s)')
    }
}
Case 'Modules et interface automatisable passent le parseur' {
    foreach($file in @((Join-Path $wad 'Domenia-Automate.ps1'),(Join-Path $modules 'Domenia-Automation.Model.ps1'),(Join-Path $modules 'Domenia-Automation.Worker.ps1'),(Join-Path $modules 'Domenia-Automation.UI.ps1'))){
        $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors);Expect (@($errors).Count -eq 0) ('Parse '+$file)
    }
    $text=[IO.File]::ReadAllText((Join-Path $wad 'Domenia-Automate.ps1'))
    Expect ($text -notmatch '(?i)\b(HttpListener|TcpListener|Start-Job|New-Service|Register-ScheduledTask|Invoke-WebRequest|Invoke-RestMethod|Get-CimInstance|DirectoryEntry|DirectorySearcher)\b') 'reseau, service ou annuaire dans l interface automatisable'
}
}finally{if([IO.Directory]::Exists($root)){try{[IO.Directory]::Delete($root,$true)}catch{}}}
$failed=@($checks|Where-Object{-not $_.Passed}).Count
$report=[pscustomobject]@{Suite='Automation';Passed=($failed -eq 0);Total=$checks.Count;Failed=$failed;NativeWindowsPowerShell51=$native;NetworkUsed=$false;DirectoryUsed=$false;Checks=$checks.ToArray()}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
$checks|Where-Object{-not $_.Passed}|Format-List|Out-String|Write-Output;Write-Output (($checks.Count-$failed).ToString()+'/'+$checks.Count+' passed');if($failed -or -not $native){exit 1}
