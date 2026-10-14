# Shared local database ownership and redirection guards. No network or database is opened at load.
function Get-StoreWLeaseName {
    param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path).ToLowerInvariant();$sha=[Security.Cryptography.SHA256]::Create()
    try{$key=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($full))).Replace('-','')}finally{$sha.Dispose()}
    $prefix=if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){'Global\'}else{''}
    return $prefix+'Domenia.SQLite.'+$key
}
function Enter-StoreWDatabaseLease {
    param([string]$Path,[int]$TimeoutMs=1000)
    $mutex=[Threading.Mutex]::new($false,(Get-StoreWLeaseName $Path));$held=$false
    try{try{$held=$mutex.WaitOne([Math]::Max(0,[Math]::Min(5000,$TimeoutMs)))}catch [Threading.AbandonedMutexException]{$held=$true};if(-not $held){throw 'StorageBusy : autre ecriture ou maintenance locale en cours.'};return $mutex}catch{$mutex.Dispose();throw}
}
function Exit-StoreWDatabaseLease {
    param($Lease)
    if($null -ne $Lease){try{$Lease.ReleaseMutex()}finally{$Lease.Dispose()}}
}
function Read-StoreWLeaseScalar {
    param([IntPtr]$Db,[string]$Sql)
    $bytes=[Text.Encoding]::UTF8.GetBytes($Sql+[char]0);$ptr=[Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length);$stmt=[IntPtr]::Zero
    try{
        [Runtime.InteropServices.Marshal]::Copy($bytes,0,$ptr,$bytes.Length)
        $rc=[Domenia.WinSqliteNative]::sqlite3_prepare_v2($Db,$ptr,-1,[ref]$stmt,[IntPtr]::Zero);if($rc -ne 0){throw ('Controle du stockage impossible : SQLite '+$rc)}
        $rc=[Domenia.WinSqliteNative]::sqlite3_step($stmt);if($rc -eq 101){return ''};if($rc -ne 100){throw ('Controle du stockage impossible : SQLite '+$rc)}
        $n=[Domenia.WinSqliteNative]::sqlite3_column_bytes($stmt,0);if($n -le 0){return ''};$value=New-Object byte[] $n;[Runtime.InteropServices.Marshal]::Copy([Domenia.WinSqliteNative]::sqlite3_column_text($stmt,0),$value,0,$n);return [Text.Encoding]::UTF8.GetString($value)
    }finally{if($stmt -ne [IntPtr]::Zero){[void][Domenia.WinSqliteNative]::sqlite3_finalize($stmt)};[Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)}
}
function Assert-StoreWDatabaseWritable {
    param([IntPtr]$Db)
    if((Read-StoreWLeaseScalar $Db "SELECT name FROM sqlite_master WHERE type='table' AND name='domenia_store_redirect';")){
        $redirect=Read-StoreWLeaseScalar $Db "SELECT target_path FROM domenia_store_redirect WHERE id=1;"
        if($redirect){throw ('StorageRedirected : cette base est conservee en lecture seule apres bascule. Reprendre la base verifiee : '+$redirect)}
    }
}
