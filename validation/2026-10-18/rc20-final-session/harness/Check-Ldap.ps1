$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\d120-rc11720-final'
$core=Join-Path $root 'prod\wad\Domenia-Core.ps1'
$line=@(Get-Content $core -Encoding UTF8|Where-Object {$_ -match '^\s*\$searcher.PageSize = \[Math\]::Min\(\$ldapLimit - 1,'})
if($line.Count -ne 1){throw 'Exact shipped page-size expression not found'}
$expression=[scriptblock]::Create($line[0])
$cases=@(@{Legacy=$true;Limit=101;Expected=0},@{Legacy=$false;Limit=101;Expected=101},@{Legacy=$false;Limit=2;Expected=2},@{Legacy=$false;Limit=501;Expected=234})
$rows=@()
foreach($case in $cases){
 $searcher=New-Object System.DirectoryServices.DirectorySearcher
 $searcher.SearchRoot=New-Object System.DirectoryServices.DirectoryEntry('LDAP://dc01.cnamts.local/DC=cnamts,DC=local')
 $searcher.Filter='(|(&(objectCategory=person)(objectClass=user))(objectCategory=computer)(objectCategory=group)(objectCategory=organizationalUnit)(objectCategory=container))'
 $ldapLimit=$case.Limit;$Payload=[pscustomobject]@{StreamPageSize=250}
 $searcher.SizeLimit=$ldapLimit;$searcher.Asynchronous=$true;$searcher.CacheResults=$false
 $searcher.ServerTimeLimit=[timespan]::FromSeconds(5);$searcher.ClientTimeout=[timespan]::FromSeconds(8)
 [void]$searcher.PropertiesToLoad.Add('distinguishedName')
 if($case.Legacy){$searcher.PageSize=250}else{& $expression}
 $page=$searcher.PageSize;$collection=$null;$count=0;$errorText=''
 try{$collection=$searcher.FindAll();foreach($item in $collection){$count++;if($count -eq $ldapLimit){break}}}catch{$errorText=$_.Exception.Message}
 finally{if($null -ne $collection){$collection.Dispose()};$searcher.SearchRoot.Dispose();$searcher.Dispose()}
 $pass=if($case.Legacy){$count -eq 0 -and $errorText -match 'size limit'}else{$count -eq $case.Expected -and $errorText -eq ''}
 $rows += [pscustomobject]@{Legacy=$case.Legacy;Limit=$ldapLimit;Page=$page;Count=$count;Error=$errorText;Passed=$pass}
}
$r=[ordered]@{Passed=(@($rows|Where-Object {-not $_.Passed}).Count -eq 0);Utc=[datetime]::UtcNow.ToString('o');CoreSha256=(Get-FileHash $core -Algorithm SHA256).Hash;Expression=$line[0].Trim();Cases=$rows;DirectoryWrites=0}
[IO.File]::WriteAllText((Join-Path $root 'final-out\Ldap-Page-Limit.json'),($r|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
$r|ConvertTo-Json -Depth 5
if(-not $r.Passed){throw 'LDAP focused regression failed'}
