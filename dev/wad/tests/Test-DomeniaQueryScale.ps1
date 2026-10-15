#requires -Version 5.1
[CmdletBinding()]
param([switch]$QuerySource,[string]$ReportPath='')
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot;$modules=Join-Path $wad 'modules'
if($QuerySource){Add-Type -Path (Join-Path (Split-Path -Parent $wad) 'vendor/m4d-admin-common/src/Query/QueryEngine.cs')}else{Add-Type -Path (Join-Path $modules 'M4D.Admin.Common.Query.dll')}
Add-Type -Path (Join-Path $modules 'Domenia.Native.dll')
foreach($name in @('Common.Model','HealthRules.Model','Boards.Model','Probes.Model','QuerySchema.Model','Workstation.Model','Query.Model','Query.Worker')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$checks=0;$watch=[Diagnostics.Stopwatch]::StartNew()
function Expect([bool]$Good,[string]$Name){$script:checks++;if(-not $Good){throw $Name}}
function Reject([scriptblock]$Action,[string]$Name){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Expect $failed $Name}
$folder=Join-Path ([IO.Path]::GetTempPath()) ('domenia-query-scale-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($folder)
try{
    $records=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
    for($i=0;$i -lt 20000;$i++){
        $values=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
        $values.Add('name',('PC-{0:00000}' -f $i));$values.Add('dn',('CN=PC-{0:00000},OU=Fixture,DC=example,DC=test' -f $i));$values.Add('active',$true)
        if($i -lt 10000){$values.Add('ramGB',8.0)}
        $records.Add([M4D.Admin.Common.Query.QueryRecord]::new(('00000000-0000-0000-0000-{0:000000000000}' -f $i),$values))
    }
    $recipe=New-DomeniaQueryRecipe -Name 'Scale 20000' -GroupBy 'name'
    $widgets=Measure-DomeniaQueryWidget $records $recipe
    Expect ($widgets.Matched -eq 20000 -and ($widgets.Items|Measure-Object Value -Sum).Sum -eq 20000) '20000 distinct categories retain exact widget total'
    $other=@($widgets.Items|Where-Object Label -eq 'Autres valeurs')[0]
    $segment=New-DomeniaQuerySegmentRecipe $recipe $other.Select
    $ids=Get-DomeniaQueryMatchIds $records $segment
    Expect ($ids.Count -eq 19990) 'Other segment provides all 19990 exact identities'
    $request=[pscustomobject]@{SnapshotKey='fixture-20000';RecipeJson=($recipe|ConvertTo-Json -Depth 16 -Compress);TextFilter='';StateFilter='';Selection='Match';SortField='name';Descending=$true;ExpectedRows=20000;EvaluatedAtUtc='2026-10-13T10:00:00Z';ScopeDn='OU=Fixture,DC=example,DC=test';Subtree=$true}
    $Payload=[pscustomobject]@{ModuleRoot=$modules;Path=(Join-Path $folder 'all.csv');Records=$records;Request=$request}
    $code=[scriptblock]::Create((Get-DomeniaQueryExportWorkerCode))
    $result=& $code
    Expect ($result.Complete -and $result.RowCount -eq 20000 -and $result.Pages -eq 100) 'actual export worker writes all100 pages /20000 rows'
    $csv=@(Import-Csv -LiteralPath $result.Path -Delimiter ';');$metadata=Get-Content -Raw -LiteralPath $result.MetadataPath|ConvertFrom-Json
    Expect ($csv.Count -eq 20000 -and $csv[0].Nom -ceq 'PC-19999' -and $csv[19999].Nom -ceq 'PC-00000') 'global descending order crosses every page boundary'
    Expect (@($csv.GUID|Select-Object -Unique).Count -eq 20000) 'no omitted or duplicated identity in full export'
    Expect ($metadata.RowCount -eq 20000 -and $metadata.SnapshotKey -ceq 'fixture-20000' -and $metadata.ScopeDn -ceq $request.ScopeDn) 'export metadata identifies exact scope and snapshot'
    Expect ((Get-FileHash -LiteralPath $result.Path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $metadata.CsvSHA256) 'export receipt SHA256 matches actual file'
    Reject {& $code} 'existing export is never overwritten'
    $Payload.Path=Join-Path $folder 'mismatch.csv';$request.ExpectedRows=19999
    Reject {& $code} 'count mismatch rejects incomplete export'
    Expect (-not [IO.File]::Exists($Payload.Path) -and -not [IO.File]::Exists($Payload.Path+'.metadata.json')) 'rejected count creates no published files'
    $ram=New-DomeniaQueryRecipe -Clauses @([pscustomobject]@{Field='ramGB';Operator='Less';Value=16})
    $request.RecipeJson=$ram|ConvertTo-Json -Depth 16 -Compress;$request.Selection='Unknown';$request.ExpectedRows=10000;$request.Descending=$false;$Payload.Path=Join-Path $folder 'unknown.csv'
    $result=& $code;$csv=@(Import-Csv -LiteralPath $result.Path -Delimiter ';')
    Expect ($result.RowCount -eq 10000 -and $result.Pages -eq 50 -and $csv[0].Nom -ceq 'PC-10000' -and $csv[9999].Nom -ceq 'PC-19999') 'unknown selection exports10000 without inventing zero'
    $request.Selection='NoMatch';$request.ExpectedRows=0;$Payload.Path=Join-Path $folder 'empty.csv';$result=& $code
    Expect ($result.RowCount -eq 0 -and $result.Pages -eq 0 -and @([IO.File]::ReadAllLines($result.Path)).Count -eq 1) 'empty selection publishes a valid header-only CSV'
    $unsafe=[Collections.Generic.Dictionary[string,object]]::new();$unsafe.Add('name','  =HYPERLINK("bad")');$unsafe.Add('dn',"CN=line1`nline2");$unsafe.Add('active',$false)
    $Payload.Records=@([M4D.Admin.Common.Query.QueryRecord]::new('literal',$unsafe));$request.RecipeJson=(New-DomeniaQueryRecipe|ConvertTo-Json -Depth 16 -Compress);$request.Selection='Match';$request.ExpectedRows=1;$Payload.Path=Join-Path $folder 'literal.csv'
    $result=& $code;$csv=@(Import-Csv -LiteralPath $result.Path -Delimiter ';')
    Expect ($csv.Count -eq 1 -and $csv[0].Nom.StartsWith("'  =") -and $csv[0].'Chemin AD' -ceq "CN=line1`nline2") 'formula neutralized and embedded newline roundtrips'
    Expect (@(Get-ChildItem -LiteralPath $folder -Filter '*.tmp*' -Force).Count -eq 0) 'owned temporary files cleaned on every tested path'
    $many=@(for($i=0;$i -lt 125;$i++){New-DomeniaQueryRecipe -Name ('Personal '+$i)})
    $roundtrip=@(ConvertFrom-DomeniaQueryLibrary (ConvertTo-DomeniaQueryLibraryJson $many))
    Expect ($roundtrip.Count -eq 125) 'personal library accepts more than100 recipes'
    Reject {ConvertFrom-DomeniaQueryLibrary ('x'*16777217)} 'library rejects data over explicit16MiB budget before parsing'
    $now=[datetime]::UtcNow;$fleet=[pscustomobject]@{Groups=@();Machines=@([pscustomobject]@{name='Fixture';object_guid='fixture';distinguished_name='CN=Fixture,DC=test';st='A';gid='';logon=''})}
    foreach($case in @(
        @{Presence='En ligne';CheckedUtc=$now.ToString('o');PresenceCheckedUtc=$now.AddDays(-40).ToString('o');Expected='Non verifie'},
        @{Presence='En ligne';CheckedUtc=$now.AddDays(-40).ToString('o');PresenceCheckedUtc=$now.ToString('o');Expected='En ligne'},
        @{Presence='Erreur';CheckedUtc=$now.ToString('o');PresenceCheckedUtc=$now.ToString('o');Expected='Non verifie'},
        @{Presence='Sans réponse au ping';CheckedUtc=$now.ToString('o');PresenceCheckedUtc=$now.ToString('o');Expected='Sans reponse'}
    )){
        $observations=@{'cn=fixture,dc=test'=[pscustomobject]@{Guid='fixture';Presence=$case.Presence;CheckedUtc=$case.CheckedUtc;PresenceCheckedUtc=$case.PresenceCheckedUtc}}
        $adapted=ConvertTo-DomeniaQueryRecords -Fleet $fleet -Observations $observations -NowUtc $now
        Expect ($adapted[0].Values['presenceBucket'] -ceq $case.Expected) ('presence uses its own source date and category: '+$case.Presence+'/'+$case.Expected)
    }
    $report=[pscustomobject]@{Status='PASS';Assertions=$checks;Records=20000;SourceMode=[bool]$QuerySource;ElapsedSeconds=[Math]::Round($watch.Elapsed.TotalSeconds,3);PowerShell=$PSVersionTable.PSVersion.ToString();Platform=[Environment]::OSVersion.ToString();WindowsGUI=$false}
    if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
    $report|ConvertTo-Json -Compress
}finally{if([IO.Directory]::Exists($folder)){[IO.Directory]::Delete($folder,$true)}}
