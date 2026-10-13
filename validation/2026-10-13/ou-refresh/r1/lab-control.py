#!/usr/bin/env python3
"""Sequential existing-lab transport. It never runs Domenia/tests on the relay or Mac."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
HOST = 'degun@192.168.1.173'
VM = 'CNAMTS-W11-01'
GUEST = r'C:\DomeniaLab\ou-refresh-20261013-r1'
STAGE = r'C:\Users\degun\domenia-lab\vmstage\ou-refresh-r1'
REMOTE = 'domenia-lab/vmstage/ou-refresh-r1'
DEV_SHA = '9e8e0d85d7be7cc2bda1c43bbfd9c8a41c655395ef0010e5196378b504bc8c3d'
PROD_SHA = '8ca88099a10c8c5f02cf2d7bb99be131a1ff9b70002cc1737dabd2dc1a7888be'
CAPTURE_SHA = 'fb8812dee1c6d420badd4bdb8c15bbf8abf7ec1188974de22954017a9165aec5'
PREFIX = r"""$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$vb='C:\Program Files\Oracle\VirtualBox\VBoxManage.exe';"""
AUTH = r"""$c=Get-Content -LiteralPath 'C:\Users\degun\domenia-lab\vm\vm.conf.json' -Raw|ConvertFrom-Json;$auth=@('--passwordfile',[string]$c.PasswordFile);$a=[string]$c.Account;if($a -match '^([^\\]+)\\(.+)$'){$auth=@('--username',$Matches[2],'--domain',$Matches[1])+$auth}else{$auth=@('--username',$a)+$auth};"""
STATUS = r"""
$vbox=New-Object -ComObject VirtualBox.VirtualBox
$session=New-Object -ComObject VirtualBox.Session
$rows=[Collections.Generic.List[object]]::new()
$machine=$vbox.FindMachine('CNAMTS-W11-01')
$state=[int]$machine.State
try {
 if($state -eq 5){
  $machine.LockMachine($session,1)
  foreach($gs in $session.Console.Guest.Sessions){foreach($p in $gs.Processes){
   $processArgs=@($p.Arguments);$owned=(@($processArgs|Where-Object{[string]$_ -like '*ou-refresh-20261013-r1*'}).Count -gt 0)
   $rows.Add([pscustomobject]@{SessionId=$gs.Id;ProcessId=$p.PID;Status=[int]$p.Status;ManagedCampaign=$owned;Arguments=$(if($owned){$processArgs}else{@()})})
  }}
 }
 [pscustomobject]@{VM='CNAMTS-W11-01';MachineState=$state;Processes=$rows.ToArray();Method='Host VirtualBox COM only; no guest authentication'}|ConvertTo-Json -Depth 6 -Compress
}finally{if($session.State -eq 1){$session.UnlockMachine()}}
"""
def relay(script, authenticate=False, timeout=120):
    body = PREFIX + (AUTH if authenticate else '') + script
    encoded = base64.b64encode(body.encode('utf-16le')).decode('ascii')
    proc = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', HOST,
                           'powershell -NoLogo -NoProfile -NonInteractive -EncodedCommand ' + encoded],
                          capture_output=True, text=True, timeout=timeout)
    if proc.returncode:
        raise RuntimeError('Existing relay failed (exit %s): %s' % (proc.returncode, proc.stderr.strip() or proc.stdout.strip()))
    return proc.stdout.strip()

def status():
    result = json.loads(relay(STATUS, timeout=30))
    return result

def require_idle():
    current = status()
    if current['MachineState'] != 5:
        raise RuntimeError('Test VM is not running; no VM state change is performed by this tool')
    active = [p for p in current['Processes'] if 0 < p['Status'] < 500]
    if active:
        raise RuntimeError('Guest processes are active. Keep authenticated operations stopped and use status only: ' + json.dumps(active))

def launch(phase):
    script = "& $vb guestcontrol '"+VM+"' start @auth --exe 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe' -- powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File '"+GUEST+"\\run.ps1' -Phase '"+phase+"' -ExpectedZip '"+DEV_SHA+"' -ExpectedCapture '"+CAPTURE_SHA+"';if($LASTEXITCODE){throw 'Guest launch failed'}"
    print(relay(script, authenticate=True, timeout=60))
    print('Started phase '+phase+'. Until terminal host status, use status only; no copyfrom/run/mkdir/guest authentication.')

def main():
    default_build=Path('/Users/david/Documents/Projets/Domenia-builds/2026-10-13-ou-refresh-rc1174-r1')
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['status','stage-capture','run-suites','pull'])
    p.add_argument('--dev-zip',type=Path,default=default_build/'Domenia_1.0_RC1.17.4_DEV.zip')
    p.add_argument('--prod-zip',type=Path,default=default_build/'Domenia_1.0_RC1.17.4_PROD.zip')
    p.add_argument('--capture-script',type=Path,default=REPO/'guides/captures/capture-guides.ps1')
    p.add_argument('--out',type=Path,default=Path('/tmp/domenia-ou-refresh-r1-originals'))
    a=p.parse_args()
    if a.action=='status':
        print(json.dumps(status(),indent=2));return
    require_idle()
    if a.action=='stage-capture':
        for file,digest in [(a.dev_zip,DEV_SHA),(a.prod_zip,PROD_SHA),(a.capture_script,CAPTURE_SHA)]:
            if hashlib.sha256(file.read_bytes()).hexdigest()!=digest:
                raise RuntimeError('Frozen source hash mismatch: '+str(file))
        print(relay("[void][IO.Directory]::CreateDirectory('"+STAGE+"')"))
        with tempfile.TemporaryDirectory(prefix='domenia-lab-transfer-') as folder:
            files={'dev.zip':a.dev_zip,'prod.zip':a.prod_zip,'capture-guides.ps1':a.capture_script,'run.ps1':HERE/'guest-runner.ps1','prod-check.ps1':HERE/'prod-check.ps1'}
            local=[]
            for name,source in files.items():
                path=Path(folder)/name;path.write_bytes(source.read_bytes());local.append(str(path))
            subprocess.run(['scp','-q','-o','BatchMode=yes','-o','ConnectTimeout=8']+local+[HOST+':'+REMOTE+'/'],check=True,timeout=180)
        script="& $vb guestcontrol '"+VM+"' mkdir @auth --parents '"+GUEST+"';if($LASTEXITCODE){throw 'Guest staging directory failed'}\n"
        for name in files:
            script+="& $vb guestcontrol '"+VM+"' copyto @auth '"+STAGE+'\\'+name+"' '"+GUEST+'\\'+name+"';if($LASTEXITCODE){throw 'Guest staging copy failed'}\n"
        print(relay(script,authenticate=True,timeout=300));launch('Capture')
    elif a.action=='run-suites':
        launch('Suites')
    elif a.action=='pull':
        destination=STAGE+'\\returned'
        script="[void][IO.Directory]::CreateDirectory('"+destination+"')\n"
        for name in ['proof','captures']:
            script+="& $vb guestcontrol '"+VM+"' copyfrom @auth --recursive '"+GUEST+'\\'+name+"' '"+destination+"\\';if($LASTEXITCODE){throw 'Guest proof copy failed'}\n"
        for source,name in [('run.ps1','external-runner.ps1'),('prod-check.ps1','external-prod-check.ps1')]:
            script+="& $vb guestcontrol '"+VM+"' copyfrom @auth '"+GUEST+'\\'+source+"' '"+destination+'\\proof\\'+name+"';if($LASTEXITCODE){throw 'Guest orchestrator copy failed'}\n"
        print(relay(script,authenticate=True,timeout=300));a.out.mkdir(parents=True,exist_ok=True)
        subprocess.run(['scp','-q','-r','-o','BatchMode=yes','-o','ConnectTimeout=8',HOST+':'+REMOTE+'/returned/proof',HOST+':'+REMOTE+'/returned/captures',str(a.out)+'/'],check=True,timeout=300)
        for original,returned in [(HERE/'guest-runner.ps1',a.out/'proof/external-runner.ps1'),(HERE/'prod-check.ps1',a.out/'proof/external-prod-check.ps1')]:
            if original.read_bytes()!=returned.read_bytes():raise RuntimeError('Executed orchestrator mismatch: '+str(returned))
        print('Original evidence preserved at '+str(a.out)+'. No PASS verdict is inferred from transport success.')
if __name__=='__main__':main()
