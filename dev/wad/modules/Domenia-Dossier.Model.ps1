# Only the existing positive snapshot allowlist is imported/exported.
function ConvertTo-DomeniaStoredCapture {
    param($Capture,[string]$Domain)
    if($null -eq $Capture -or [int]$Capture.Format -ne 1 -or [string]$Capture.Scope -ine $Domain){throw 'Capture absente, incompatible ou provenant d un autre domaine.'}
    $properties=@{};$coverage=@{}
    foreach($name in Get-DomeniaSupportFieldNames){
        $value=$null;$has=$false
        if($Capture.Fields -is [Collections.IDictionary]){$has=$Capture.Fields.Contains($name);if($has){$value=$Capture.Fields[$name]}}
        elseif($null -ne $Capture.Fields.PSObject.Properties[$name]){$has=$true;$value=$Capture.Fields.$name}
        if($has){$properties[$name]=@($value|Select-Object -First 128)}
        if($Capture.Coverage -is [Collections.IDictionary]){$coverage[$name]=[string]$Capture.Coverage[$name]}else{$coverage[$name]=[string]$Capture.Coverage.$name}
    }
    $observed=[datetime]::MinValue;$captured=[datetime]::MinValue
    if(-not [datetime]::TryParse([string]$Capture.ObservedAtUtc,[ref]$observed) -or -not [datetime]::TryParse([string]$Capture.CapturedAtUtc,[ref]$captured)){throw 'Dates de la capture invalides.'}
    if($observed.ToUniversalTime() -gt [datetime]::UtcNow.AddMinutes(5) -or $captured.ToUniversalTime() -gt [datetime]::UtcNow.AddMinutes(5)){throw 'Capture datee dans le futur.'}
    $clean=New-DomeniaSupportSnapshot -Properties $properties -Scope $Domain -Dn ([string]$Capture.Dn) -Name ([string]$Capture.Name) -Type ([string]$Capture.Type) -Source Cache -ObservedAtUtc $observed -CapturedAtUtc $captured
    foreach($name in $coverage.Keys){if($coverage[$name] -ne 'Provided'){$clean.Coverage[$name]='Partial'}}
    return $clean
}
function Get-DomeniaDocumentWorkerCode {
return @'
$path=[IO.Path]::GetFullPath([string]$Payload.Path)
if(-not [IO.Path]::IsPathRooted($path) -or [IO.Path]::GetExtension($path) -notin @('.json','.html','.txt')){throw 'Chemin de document non pris en charge.'}
$probe=[IO.FileInfo]::new($path)
while($null -ne $probe){if($probe.Exists -and ($probe.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Document ou dossier redirige refuse.'};$probe=if($probe -is [IO.FileInfo]){$probe.Directory}else{$probe.Parent}}
if($Payload.Action -eq 'Read'){
    if(-not [IO.File]::Exists($path) -or ([IO.FileInfo]::new($path)).Length -gt 1MB){throw 'Capture absente ou trop volumineuse (1 Mo maximum).'}
    [pscustomobject]@{Content=[IO.File]::ReadAllText($path);Path=$path;Saved=$false};return
}
if($Payload.Action -ne 'Write' -or ([string]$Payload.Text).Length -gt 1MB){throw 'Export invalide ou trop volumineux (1 Mo maximum).'}
$tmp=Join-Path ([IO.Path]::GetDirectoryName($path)) ('.domenia-'+[guid]::NewGuid().ToString('N')+'.tmp')
try{
    $data=[Text.UTF8Encoding]::new($false).GetBytes([string]$Payload.Text)
    $f=[IO.File]::Open($tmp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$f.Write($data,0,$data.Length);$f.Flush($true)}finally{$f.Dispose()}
    if([IO.File]::Exists($path)){[IO.File]::Replace($tmp,$path,[NullString]::Value,$true)}else{[IO.File]::Move($tmp,$path)}
    [pscustomobject]@{Saved=$true;Path=$path;Content=''}
}finally{if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}}
'@
}
