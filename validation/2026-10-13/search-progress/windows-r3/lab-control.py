#!/usr/bin/env python3
"""Existing relay/VM transport for a frozen RC1.17.7 candidate; no network reconfiguration."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
HOST = 'degun@192.168.1.173'
VM = 'CNAMTS-W11-01'
GUEST = r'C:\DomeniaLab\search-progress-20261013-r3'
STAGE = r'C:\Users\degun\domenia-lab\vmstage\search-progress-r3'
REMOTE = 'domenia-lab/vmstage/search-progress-r3'
DEV_SHA = 'fcb09dfc3fca21c7dd626db826050d625a8ca08c77fa83b539b4943d33369481'
PROD_SHA = '9cc5dfc58614456cfcb328e139ee4d5e01d0b214bb31dad31f89629e20bc4517'
PREFIX = r"$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$vb='C:\Program Files\Oracle\VirtualBox\VBoxManage.exe';"
AUTH = r"""$c=Get-Content -LiteralPath 'C:\Users\degun\domenia-lab\vm\vm.conf.json' -Raw|ConvertFrom-Json;$auth=@('--passwordfile',[string]$c.PasswordFile);$a=[string]$c.Account;if($a -match '^([^\\]+)\\(.+)$'){$auth=@('--username',$Matches[2],'--domain',$Matches[1])+$auth}else{$auth=@('--username',$a)+$auth};"""
STATUS = r"""
$vbox=New-Object -ComObject VirtualBox.VirtualBox
$session=New-Object -ComObject VirtualBox.Session
$rows=[Collections.Generic.List[object]]::new();$runnerProgress=$null;$progressError=''
$machine=$vbox.FindMachine('CNAMTS-W11-01');$locked=$false
$state=[int]$machine.State
$info=@(& $vb showvminfo 'CNAMTS-W11-01' --machinereadable);if($LASTEXITCODE){throw 'VM state lookup failed'}
$stateLine=@($info|Where-Object{$_ -match '^VMState='})
if($stateLine.Count -ne 1){throw 'VM state missing or ambiguous'}
$stateName=([string]$stateLine[0]).Substring(8).Trim('"')
try {
 if($stateName -eq 'running'){
  $machine.LockMachine($session,1);$locked=$true
  foreach($gs in $session.Console.Guest.Sessions){foreach($p in $gs.Processes){
   $pa=@($p.Arguments);$owned=(@($pa|Where-Object{[string]$_ -like '*search-progress-20261013-r3*'}).Count -gt 0)
   $rows.Add([pscustomobject]@{SessionId=$gs.Id;ProcessId=$p.PID;Status=[int]$p.Status;ManagedCampaign=$owned;Arguments=$(if($owned){$pa}else{@()})})
   if($owned -and [int]$p.Status -gt 0 -and [int]$p.Status -lt 500){
    # Reuse the existing owned session: ReadOnly=1, OpenExisting=1. Never create a guest session.
    $file=$null
    try{$file=$gs.FileOpen('C:\DomeniaLab\search-progress-20261013-r3\proof\runner-status.json',1,1,0);$runnerProgress=[Text.Encoding]::UTF8.GetString([byte[]]$file.Read(65536,2000))|ConvertFrom-Json}
    catch{$progressError=$_.Exception.Message}
    finally{if($null -ne $file){$file.Close()}}
   }
  }}
 }
 [pscustomobject]@{VM='CNAMTS-W11-01';MachineState=$state;MachineStateName=$stateName;Processes=$rows.ToArray();RunnerProgress=$runnerProgress;ProgressReadError=$progressError;Method='Host COM/state; optional read-only progress from existing owned guest session, no new authentication'}|ConvertTo-Json -Depth 6 -Compress
}finally{if($locked){$session.UnlockMachine()}}
"""

def relay(script, authenticate=False, timeout=60):
    body = PREFIX + (AUTH if authenticate else '') + script
    encoded = base64.b64encode(body.encode('utf-16le')).decode('ascii')
    proc = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', HOST,
                           'powershell -NoLogo -NoProfile -NonInteractive -EncodedCommand ' + encoded],
                          capture_output=True, timeout=timeout)
    # Windows errors can be emitted in the OEM codepage; never lose the actual exit code.
    stdout = proc.stdout.decode('utf-8', errors='replace').strip()
    stderr = proc.stderr.decode('utf-8', errors='replace').strip()
    if proc.returncode:
        raise RuntimeError('Existing relay failed (exit %s): %s' % (proc.returncode, stderr or stdout))
    if stderr:
        print(stderr, file=sys.stderr)
    return stdout

def status():
    return json.loads(relay(STATUS, timeout=30))

def require_idle():
    current = status()
    if current['MachineStateName'] != 'running':
        raise RuntimeError('Test VM is not running; this helper never changes VM state')
    active = [p for p in current['Processes'] if 0 < p['Status'] < 500]
    if active:
        raise RuntimeError('Guest processes active: use status only until completion: ' + json.dumps(active))

def launch():
    # Capture startup errors even before the runner can create its proof directory.
    # Process-scoped policy only; the guest's persistent Windows policies are unchanged.
    command = (r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe '
               '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -File '
               + GUEST + r'\guest-runner.ps1 > ' + GUEST + r'\launcher.txt 2>&1')
    script = ("& $vb guestcontrol '" + VM + "' start @auth --exe 'C:\\Windows\\System32\\cmd.exe' -- /d /c '"
              + command + "';if($LASTEXITCODE){throw 'Guest launch failed'}")
    print(relay(script, authenticate=True, timeout=60))
    print('Started. Use status only until terminal process state; no parallel GuestControl authentication.')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['status','stage-run','launch','pull'])
    parser.add_argument('--out',type=Path,default=Path('/tmp/domenia-search-progress-windows-r3-originals'))
    args=parser.parse_args()
    if args.action=='status':
        print(json.dumps(status(),indent=2));return
    require_idle()
    if args.action=='launch':
        launch();return
    if args.action=='stage-run':
        dev=REPO/'packs/Domenia_DEV.zip';prod=REPO/'packs/Domenia_PROD.zip'
        for path,expected in ((dev,DEV_SHA),(prod,PROD_SHA)):
            if hashlib.sha256(path.read_bytes()).hexdigest()!=expected:
                raise RuntimeError('Frozen archive mismatch: '+str(path))
        files={'dev.zip':dev,'prod.zip':prod,'guest-runner.ps1':HERE/'guest-runner.ps1'}
        if (HERE/'prod-check.ps1').is_file():files['prod-check.ps1']=HERE/'prod-check.ps1'
        print(relay("if(Test-Path -LiteralPath '"+STAGE+"'){throw 'Staging already exists; preserve previous attempt'};[void][IO.Directory]::CreateDirectory('"+STAGE+"')"))
        with tempfile.TemporaryDirectory(prefix='domenia-search-progress-transfer-') as folder:
            copies=[]
            for name,path in files.items():
                copy=Path(folder)/name;copy.write_bytes(path.read_bytes());copies.append(str(copy))
            subprocess.run(['scp','-q','-o','BatchMode=yes','-o','ConnectTimeout=8']+copies+[HOST+':'+REMOTE+'/'],check=True,timeout=120)
        script="& $vb guestcontrol '"+VM+"' mkdir @auth --parents '"+GUEST+"';if($LASTEXITCODE){throw 'Guest staging directory failed'}\n"
        for name in files:
            script+="& $vb guestcontrol '"+VM+"' copyto @auth '"+STAGE+'\\'+name+"' '"+GUEST+'\\'+name+"';if($LASTEXITCODE){throw 'Guest copy failed'}\n"
        print(relay(script,authenticate=True,timeout=120))
        launch()
    else:
        dest=STAGE+'\\returned'
        script="[void][IO.Directory]::CreateDirectory('"+dest+"'); & $vb guestcontrol '"+VM+"' copyfrom @auth --recursive '"+GUEST+"\\proof' '"+dest+"\\';if($LASTEXITCODE){throw 'Proof retrieval failed'}"
        print(relay(script,authenticate=True,timeout=120))
        args.out.mkdir(parents=True,exist_ok=True)
        if (args.out/'proof').exists():raise RuntimeError('Original proofs already exist; select a new output')
        subprocess.run(['scp','-q','-r','-o','BatchMode=yes','-o','ConnectTimeout=8',HOST+':'+REMOTE+'/returned/proof',str(args.out)+'/'],check=True,timeout=120)
        print('Original evidence preserved: '+str(args.out)+'. Transport success is not a test verdict.')

if __name__=='__main__':main()
