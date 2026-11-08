#requires -Version 5.1
# Host-side relay to the test VM (VirtualBox guest control). Runs on the lab host, NEVER runs tests on the host:
# it only stages files and asks VirtualBox to copy/execute them INSIDE the guest.
# Credentials: vm.conf.json next to this script (host-local, never in the repository) gives the guest Account and the
# PATH of an operator-provisioned password file. This script passes that FILE PATH to VBoxManage (--passwordfile);
# it never reads, prints or forwards the password.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true,Position=0)][ValidateSet('status','push','run','pull')][string]$Action,
    [string]$Vm='CNAMTS-W11-01',
    [ValidatePattern('^[A-Za-z0-9_-]{1,40}$')][string]$Name='d120',
    [string]$Tar='',
    [string]$Script='',
    [string]$Path='',
    [string]$Dest='',
    [switch]$Sta,
    [ValidateRange(10,14400)][int]$TimeoutSeconds=3600
)
$ErrorActionPreference='Stop'
$vb='C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
$confPath=Join-Path $PSScriptRoot 'vm.conf.json'
$guestRoot='C:\DomeniaLab'
$guestDir=$guestRoot+'\'+$Name
$guestShell='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'

function Get-VmState {
    $info=& $vb showvminfo $Vm --machinereadable
    $state=(($info|Where-Object{$_ -like 'VMState=*'}) -replace 'VMState=|"','')
    $level=(($info|Where-Object{$_ -like 'GuestAdditionsRunLevel=*'}) -replace 'GuestAdditionsRunLevel=','')
    return [pscustomobject]@{State=$state;AdditionsRunLevel=$level}
}
function Get-GuestAuth {
    if(-not [IO.File]::Exists($confPath)){throw ('Configuration absente : '+$confPath+' (Account, PasswordFile).')}
    $conf=[IO.File]::ReadAllText($confPath)|ConvertFrom-Json
    $account=([string]$conf.Account).Trim();$passwordFile=[string]$conf.PasswordFile
    if(-not $account){throw 'Compte invite absent de vm.conf.json.'}
    if(-not [IO.File]::Exists($passwordFile)){throw ('Fichier mot de passe absent : '+$passwordFile)}
    $auth=@('--passwordfile',$passwordFile)
    if($account -match '^([^\\]+)\\(.+)$'){$auth=@('--username',$Matches[2],'--domain',$Matches[1])+$auth}else{$auth=@('--username',$account)+$auth}
    return ,$auth
}
function Invoke-Guest {
    param([string[]]$Arguments)
    # Native stderr must not become a terminating error under the script-wide 'Stop' preference.
    $ErrorActionPreference='Continue'
    $output=& $vb guestcontrol $Vm @Arguments 2>&1
    $code=$LASTEXITCODE
    foreach($line in @($output)){[Console]::Out.WriteLine([string]$line)}
    return $code
}
function Invoke-GuestShell {
    # One PowerShell 5.1 process inside the guest. Exit code is carried by a marker line, not by VBoxManage.
    param([string]$Command,[switch]$UseSta)
    $auth=Get-GuestAuth
    $shellArgs=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass')
    if($UseSta){$shellArgs+='-STA'}
    $wrapped=$Command+'; Write-Output (''__DOMENIA_RC=''+[string]$(if($null -eq $global:LASTEXITCODE){0}else{$global:LASTEXITCODE}))'
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapped))
    $ErrorActionPreference='Continue'
    $arguments=@('run')+$auth+@('--exe',$guestShell,'--timeout',[string]($TimeoutSeconds*1000),'--wait-stdout','--wait-stderr','--','powershell.exe')+$shellArgs+@('-EncodedCommand',$encoded)
    $output=& $vb guestcontrol $Vm @arguments 2>&1
    $rc=$LASTEXITCODE
    $guestRc=$null
    foreach($line in @($output)){
        $text=[string]$line
        if($text -match '^__DOMENIA_RC=(-?\d+)\s*$'){$guestRc=[int]$Matches[1];continue}
        [Console]::Out.WriteLine($text)
    }
    if($null -eq $guestRc){[Console]::Out.WriteLine('vmctl: code de retour invite absent (VBoxManage='+$rc+')');return 95}
    return $guestRc
}

$state=Get-VmState
if($Action -eq 'status'){$state|Format-List|Out-String|Write-Output;exit 0}
if($state.State -ne 'running' -or [int]$state.AdditionsRunLevel -lt 2){throw ('VM '+$Vm+' indisponible : etat='+$state.State+' additions='+$state.AdditionsRunLevel)}

switch($Action){
    'push' {
        if(-not [IO.File]::Exists($Tar)){throw ('Archive absente : '+$Tar)}
        $reset='if(Test-Path -LiteralPath '''+$guestDir+'''){Remove-Item -LiteralPath '''+$guestDir+''' -Recurse -Force}; New-Item -ItemType Directory -Path '''+$guestDir+''' -Force | Out-Null'
        $rc=Invoke-GuestShell -Command $reset
        if($rc -ne 0){exit $rc}
        $auth=Get-GuestAuth
        $rc=Invoke-Guest (@('copyto')+$auth+@($Tar,($guestDir+'\tree.tar')))
        if($rc -ne 0){exit $rc}
        $rc=Invoke-GuestShell -Command ('Set-Location -LiteralPath '''+$guestDir+'''; & tar.exe -xf tree.tar; $x=$LASTEXITCODE; Remove-Item tree.tar -Force; $global:LASTEXITCODE=$x')
        if($rc -eq 0){[Console]::Out.WriteLine('synced -> '+$Vm+':'+$guestDir)}
        exit $rc
    }
    'run' {
        if(-not [IO.File]::Exists($Script)){throw ('Script absent : '+$Script)}
        $auth=Get-GuestAuth
        $leaf=[IO.Path]::GetFileName($Script)
        $rc=Invoke-Guest (@('mkdir')+$auth+@('--parents',$guestDir))
        if($rc -ne 0){exit $rc}
        $rc=Invoke-Guest (@('copyto')+$auth+@($Script,($guestDir+'\'+$leaf)))
        if($rc -ne 0){exit $rc}
        $command='if(Test-Path -LiteralPath '''+$guestDir+'\dev''){Set-Location -LiteralPath '''+$guestDir+'\dev''}else{Set-Location -LiteralPath '''+$guestDir+'''}; & '''+$guestDir+'\'+$leaf+''''
        exit (Invoke-GuestShell -Command $command -UseSta:$Sta)
    }
    'pull' {
        if(-not $Path -or $Path -match '\.\.' -or -not $Dest){throw 'Chemin invalide.'}
        $auth=Get-GuestAuth
        [void][IO.Directory]::CreateDirectory($Dest)
        exit (Invoke-Guest (@('copyfrom')+$auth+@('--recursive',($guestDir+'\'+$Path),$Dest)))
    }
}
