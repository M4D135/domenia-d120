import subprocess,json,time,datetime,pathlib
log=pathlib.Path('/tmp/domenia-r6-host-monitor.jsonl')
while True:
 r=subprocess.run(['python3','/tmp/domenia-vm-host.py','/tmp/domenia-vm-session-details.ps1'],capture_output=True,text=True,timeout=40)
 rows=[]
 for line in r.stdout.splitlines():
  try:d=json.loads(line)
  except ValueError:continue
  if any('query-navigation-20261013-r6' in x for x in d.get('Arguments',[])):rows.append(d)
 record={'UTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'Method':'Host VirtualBox COM GuestSession.Processes; no guest authentication','Rows':rows,'HostReadExitCode':r.returncode}
 with log.open('a')as f:f.write(json.dumps(record)+'\n')
 if rows and all(d['Status']>=500 for d in rows):print(json.dumps(record),flush=True);break
 time.sleep(60);time.sleep(60)
