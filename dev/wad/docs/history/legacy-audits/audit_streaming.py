#!/usr/bin/env python3
"""R1.12 portable source/XML/SQL checks. NOT PowerShell execution, WPF rendering or LDAP/CIM testing."""
import argparse, hashlib, json, re, sqlite3, sys, tempfile, xml.etree.ElementTree as ET
from pathlib import Path
from powershell_lex import functions
from audit_experience import delimiters
BUILD='2026.09.30-R1.12-PROGRESSIVE'
X='{http://schemas.microsoft.com/winfx/2006/xaml}'
W='{http://schemas.microsoft.com/winfx/2006/xaml/presentation}'
def sha(x):return hashlib.sha256(x.encode('utf8') if isinstance(x,str) else x).hexdigest()
def text(p):return p.read_text(encoding='utf-8-sig')
def docs(s):return {n:s[slice(*v[0])] for n,v in functions(s).items() if len(v)==1}
def literal(s):return re.search(r"@'\n(.*?)\n'@",s,re.S)[1]
def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2]);ap.add_argument('--report',type=Path,default=Path('/tmp/domenia-r112-audit.json'));a=ap.parse_args();r=a.root
    checks=[]
    def ck(name,f):
        try:
            result=f() if callable(f) else f
            assert result is None or bool(result),name
            checks.append({'Name':name,'Passed':True})
        except Exception as e:
            checks.append({'Name':name,'Passed':False,'Detail':str(e)});print('FAIL',name,':',e)
    c=text(r/'wad/Domenia-Core.ps1');f=docs(c);m=text(r/'wad/modules/Domenia-Live.Model.ps1');mf=docs(m);u=text(r/'wad/modules/Domenia-Live.UI.ps1');uf=docs(u)
    b=json.loads(text(r/'wad/tests/streaming-baseline-r111.json'))
    changes=[n for n,h in b['CoreFunctions'].items() if n not in f or sha(f[n])!=h]
    expected={'Set-DomeniaResultRowPresence','Sync-DomeniaResultRowFromEntry','Apply-DomeniaPresenceFilter','Get-MainXaml','Invalidate-DomeniaSearchResults','Complete-DomeniaGlobalSearchUi','Fail-DomeniaGlobalSearchUi','Clear-DomeniaGlobalSearch','Invoke-GlobalSearch','Start-ComputerUserLinkProbe','Set-RowAssociationMetadata','Get-DomeniaWorkerOperationHashes','New-DomeniaWorkerRunspace','Initialize-AsyncEngine','Start-UiTask','Request-UiTaskStop','Complete-UiTasks','Dispose-AsyncEngine','Get-WorkerContext','Initialize-DomeniaPresentation','Start-DomeniaWriteTask'}
    ck('All original core function names retained once',set(f)==set(b['CoreFunctions']) and all(len(v)==1 for v in functions(c).values()))
    ck('Only reviewed core functions changed',set(changes)==expected)
    common=re.search(r"(?ms)^\$script:WorkerCommon = @'\n(.*?)\n'@",c)[1]
    ck('Existing common remote worker preserved',sha(common)==b['WorkerCommonSha256'])
    for n in ['Invoke-DomeniaInProcessAuthProbe','Start-DomeniaFastLoginAttempt','Update-DomeniaFastLoginAttempt','Complete-DomeniaFastLoginSuccess','Start-DomeniaLoginAuthRunspace','Assert-DomeniaCapability','Wire-Events','Get-DomeniaSearchScope','Test-DomeniaSearchStateCurrent','Get-DomeniaStandardLoginXaml','Export-CurrentResults']:
        ck('Sensitive existing function preserved: '+n,sha(f[n])==b['CoreFunctions'][n])
    reg=dict(re.findall(r'(\w+)\s*=\s*"([A-F0-9]{64})"',f['Get-DomeniaWorkerOperationHashes']))
    literals={sha(x[1]).upper():x[1] for s in [c,m] for x in re.finditer(r"@'\n(.*?)\n'@",s,re.S)}
    ck('Closed registry of 47 literal worker bodies',len(reg)==47 and set(reg.values())<=set(literals))
    ck('44 pre-existing worker bodies preserved exactly',all(reg.get(k)==v for k,v in b['WorkerRegistry'].items() if k!='GlobalSearch'))
    ck('GlobalSearch is intentionally replaced',reg['GlobalSearch']!=b['WorkerRegistry']['GlobalSearch'])
    ck('New literal code registry matches its factories',sha(literal(mf['Get-DomeniaLiveProbeCode'])).upper()==reg['LiveConsole'] and sha(literal(mf['Get-DomeniaLiveCacheCode'])).upper()==reg['LiveCache'])
    ck('All pinned worker bodies pass approximate delimiter checks',lambda:all(delimiters(literals[h]) is None for h in reg.values()))
    for p in sorted(r.rglob('*.ps1')):
        ck('Approximate lexical balance, not native parse: '+str(p.relative_to(r)),lambda p=p:delimiters(text(p)))
    for p,h in b['ProtectedFiles'].items():ck('Preserved dependency: '+p,sha((r/p).read_bytes())==h)
    ck('Main build matches R1.12',BUILD in c and 'DOMENIA 1.0 R1.12 PROGRESSIF' in c)
    mainxml=re.search(r'@"\n(.*?)\n"@',f['Get-MainXaml'],re.S)[1];doc=ET.fromstring(mainxml)
    nodes={e.get(X+'Name'):e for e in doc.iter() if e.get(X+'Name')};parents={ch:p for p in doc.iter() for ch in p}
    ck('Original named main controls retained',set(b['MainNames'])<=set(nodes))
    ck('New controls all present',{'ChkLiveUsers','BtnLiveRecheck','LblLiveState'}<=set(nodes))
    ck('Results remain virtualized',nodes['DgObjects'].get('EnableRowVirtualization')=='True' and nodes['DgObjects'].get('EnableColumnVirtualization')=='True')
    ck('Toolbar is outside result grid (no overlapping rows)',parents[nodes['DgObjects']] is not parents[parents[nodes['ChkLiveUsers']]])
    ck('Stream controls have static help and accessibility names',all(nodes[n].get('ToolTip') and nodes[n].get('AutomationProperties.Name') for n in ['ChkLiveUsers','BtnLiveRecheck']))
    catalog=json.loads(text(r/'wad/modules/Domenia-UX.help.json'))
    ck('Help catalog contains both new commands',{'ChkLiveUsers','BtnLiveRecheck'} <= {e['Name'] for e in catalog})
    ck('New columns distinguish console user, attempt and directory freshness',all(x in mainxml for x in ['SessionDisplay','SessionState','DirectoryState','SessionDetail']))
    for p in (r/'wad/modules').glob('*.xaml'):ck('XML module parses: '+p.name,lambda p=p:ET.parse(p) is not None)
    ck('Module functions do not collide with core or each other',not (set(f)&set(mf) or set(f)&set(uf) or set(mf)&set(uf)))
    ck('New data type implements change notifications','INotifyPropertyChanged' in text(r/'wad/modules/Domenia-Live.Types.cs'))
    ck('Restricted host fallback without disabling protections','rowType' in mf['New-DomeniaLiveResultRow'] and 'Notifying=' in u)
    ck('Stable ObservableCollection and bounded dispatcher drainage','ObservableCollection[object]' in u and '$done -lt 12' in uf['Invoke-DomeniaLiveTick'] and '$watch.ElapsedMilliseconds -lt 6' in u and 'FromMilliseconds(80)' in u)
    ck('Probe completion never rebinds whole ItemsSource','ItemsSource' not in uf['Complete-DomeniaLiveProbe'] and 'Show-ObjectRows' not in uf['Complete-DomeniaLiveProbe'])
    ck('Native unfinished reads count toward physical concurrency','DetachedReadJobs' in uf['Get-DomeniaLiveWorkerCount'] and 'Get-DomeniaLiveWorkerCount' in uf['Start-DomeniaLiveBackgroundWork'])
    ck('Automatic user lookup defaults to two simultaneous jobs',"'MaxUserProbes' 2" in u and "Get-DomeniaLiveWorkerCount 'LiveConsole'" in u)
    ck('Interactive jobs retain spare concurrency slots','$max-2' in u)
    ck('LDAP and cache queues are separate','ConcurrentQueue[object]' in u and 'CacheProgress' in u and '.TryDequeue' in u)
    ck('Search callbacks verify identity, generation and OU scope','Test-DomeniaSearchStateCurrent' in uf['Test-DomeniaLiveSearchActive'] and 'Test-DomeniaLiveIdentity' in uf['Test-DomeniaLiveSearchActive'])
    ck('Old identity resets caches and visibly invalidates former session rows','MemoryQueries=@{}' in uf['Reset-DomeniaLiveIdentity'] and 'Compte changé · à revérifier' in u)
    ck('Recreated AD object rejected by GUID',"$current.Guid -ine $State.Guid" in u and '$Previous.Guid' in mf['ConvertTo-DomeniaLiveObservation'])
    ck('Failure keeps last observed user and old observation time','$last=Get-DomeniaLiveField $Previous' in m and "$outcome -eq 'Observed'" in mf['ConvertTo-DomeniaLiveObservation'])
    ck('Partial LDAP results never replace complete persistent query snapshot',"if(-not $s.Error)" in uf['Invoke-DomeniaLiveTick'] and '$script:Live.QueryToSave=$query' in u)
    ck('Fresh AD rows evict cached rows when quota full','Old cached rows never occupy the quota' in u and 'CacheKeys.Dequeue' in u)
    ck('Empty valid list prunes stale cache only after full response','if($s.Ended -and $s.Progress.IsEmpty' in u and '$s.Prune.Enqueue' in u)
    ck('Local filter includes console user literally',"'SessionDisplay','SessionState'" in uf['Update-DomeniaLiveFilter'] and 'OrdinalIgnoreCase' in uf['Update-DomeniaLiveFilter'])
    ck('Writes and unknown write states suspend progressive changes','UnknownPending' in uf['Invoke-DomeniaLiveTick'] and '$script:Live.Deferred.Enqueue' in uf['Complete-DomeniaLiveProbe'])
    ck('No full links-table rewrite on automatic observation','Save-UserMachineLinks' not in u and 'Add-UserMachineLinkIfMissing' not in u)
    ck('Duplicate automatic probes are gated','Busy.ContainsKey' in uf['Request-DomeniaLiveProbe'] and 'PendingKeys.ContainsKey' in uf['Request-DomeniaLiveProbe'])
    ck('Manual and automatic probes are not launched together','Get-DomeniaRunningComputerUserProbe' in uf['Start-DomeniaLiveBackgroundWork'])
    ck('Disk path resolved at most once per consultation identity','if($script:Live.DatabasePath)' in uf['Get-DomeniaLiveDatabasePath'] and 'Path=Get-DomeniaDatabasePath;' not in u)
    ck('Closing never flushes cache by waiting on worker','WaitOne' not in uf['Stop-DomeniaLive'] and 'enregistrées' in uf['Stop-DomeniaLive'])
    search=literals[reg['GlobalSearch']];probe=literals[reg['LiveConsole']];cache=literals[reg['LiveCache']]
    ck('LDAP actually streams to progress queue','Progress.Enqueue' in search and 'CacheResults = $false' in search and 'Asynchronous = $true' in search)
    ck('LDAP keeps selected root and depth','New-WSearcher $ctx ([string]$Payload.BaseDn)' in search and '([string]$Payload.Scope)' in search)
    ck('LDAP honors cooperative cancellation and disposes resources','StopToken.IsCancellationRequested' in search and '.Dispose()' in search)
    ck('Exactly one CIM session and one UserName request',probe.count('New-CimSession @')==1 and probe.count('Get-CimInstance -')==1 and '-Protocol Dcom' in probe)
    ck('CIM-off policy respected and no credential fallback',"$Context.UseCim" in probe and 'Get-WMachineCredential $Context' in probe and 'Get-WRemoteCredential' not in probe)
    ck('Automatic worker has no remote process/task/registry mutation',not re.search(r'(?i)\b(Invoke-Command|Start-Process|Invoke-CimMethod|Set-CimInstance|schtasks|reg\.exe|New-PSDrive|PsExec\.exe)\b',probe))
    ck('Console empty does not claim no RDP','NoConsole' in probe and 'sessions RDP' in probe)
    ck('AD validation keeps qualified domain; never guesses local/bare user','Context.Netbios' in probe and 'userPrincipalName' in probe and 'New-WSearcher $Context' in probe)
    ck('Auth rejection breaks automatic scheduling',"$script:Live.RemoteFaulted=$true" in u and '$script:DirectoryCredentialFaulted' in u)
    ck('CIM cleanup always attempted','finally{if($null -ne $cim)' in probe and 'Remove-CimSession' in probe)
    ck('Snapshot whitelist cannot persist arbitrary properties',"foreach($name in @('Type','Name','Login','UPN','Mail','Description','Changed','DN','State','OS','LastLogon','Guid'))" in m)
    ck('Cache opened only within pinned background operation','Open-DomeniaDatabase' not in u and 'Open-DomeniaDatabase' in cache)
    ck('Persistent data isolated by account scope and query key','PRIMARY KEY(scope_key,query_key)' in cache and 'PRIMARY KEY(scope_key,object_key)' in cache)
    ck('Record retention bounded independently from old AD database','OFFSET 20' in cache and 'OFFSET 5000' in cache and "'-30 days'" in cache and 'DELETE FROM user_machine_links' not in cache)
    ck('Cache read cannot overwrite newer in-memory observation','.TryAdd(' in cache)
    ck('Transactional persistence and bounded SQLite lock wait','BEGIN IMMEDIATE' in cache and "'ROLLBACK;'" in cache and 'sqlite3_busy_timeout($db,300)' in cache)
    ck('Manual associations preserved in targeted writes',"source LIKE 'Manual%'" in cache and "source LIKE 'Saisie manuelle%'" in cache and 'INSERT OR REPLACE INTO user_machine_links' in cache)
    installer=text(r/'INSTALLER-MISE-A-JOUR.ps1')
    ck('Native progressive tests gate code replacement',installer.index('Test-DomeniaStreaming.ps1')<installer.index('$backupParent=') and '$streamResult.Failed' in installer)
    ck('Install preserves existing configuration flags',"PreserveExisting" in installer and 'wad\\data' in installer)
    pv=text(r/'wad/maintenance/Preview-DomeniaProgress.ps1')
    ck('Preview bypasses network scheduler and disk cache','function Start-DomeniaLiveBackgroundWork { }' in pv and "function Initialize-DomeniaWinSqliteNative {throw" in pv)
    ck('Preview feeds actual production queues and callbacks','Begin-DomeniaLiveSearch' in pv and 'Progress.Enqueue' in pv and 'Complete-DomeniaLiveProbe' in pv)
    # Actual SQLite semantics, executed using Python SQLite, not the PowerShell wrapper.
    db=sqlite3.connect(':memory:');db.isolation_level=None
    ddl=re.search(r'CREATE TABLE IF NOT EXISTS adcc_live_queries.*?BEGIN IMMEDIATE;',cache,re.S)[0]
    db.executescript(ddl);db.execute('COMMIT')
    db.execute('CREATE TABLE user_machine_links(computer_key TEXT PRIMARY KEY,user_login TEXT,computer TEXT,source TEXT,confidence INT,verified_in_ad INT,observed_at TEXT,details TEXT,user_guid TEXT,computer_guid TEXT,user_dn TEXT,computer_dn TEXT)')
    cols='computer_key,user_login,computer,source,confidence,verified_in_ad,observed_at,details,user_guid,computer_guid,user_dn,computer_dn'
    def lit(v):return "'"+str(v).replace("'","''")+"'"
    def link(user,source='Console CIM/DCOM',at='2026-09-30T10:00:00'):
        vals=['PC-01',user,'PC-01',source,97,1,at,'Console','ug','cg','CN=User','CN=PC-01']
        sql='INSERT OR REPLACE INTO user_machine_links('+cols+') SELECT '+','.join(map(lit,vals))+" WHERE NOT EXISTS(SELECT 1 FROM user_machine_links WHERE computer_key='PC-01' AND (source LIKE 'Manual%' OR source LIKE 'Saisie manuelle%' OR julianday(observed_at)>julianday("+lit(at)+")));"
        db.execute(sql)
    ck('SQL: first targeted observed link inserted',lambda:(link('alice') or db.execute('SELECT user_login FROM user_machine_links').fetchone()[0]=='alice'))
    link("O'Neil");ck('SQL: apostrophe preserved as literal',db.execute('SELECT user_login FROM user_machine_links').fetchone()[0]=="O'Neil")
    link('bob',at='2026-09-30T09:00:00');ck('SQL: older observation cannot replace newer one',db.execute('SELECT user_login FROM user_machine_links').fetchone()[0]=="O'Neil")
    db.execute("UPDATE user_machine_links SET source='Saisie manuelle',user_login='manual'");link('automatic',at='2026-09-30T11:00:00');ck('SQL: manual link never replaced',db.execute('SELECT user_login FROM user_machine_links').fetchone()[0]=='manual')
    db.execute("UPDATE user_machine_links SET source='Manual'");link('auto2',at='2026-09-30T12:00:00');ck('SQL: English manual source also protected',db.execute('SELECT user_login FROM user_machine_links').fetchone()[0]=='manual')
    for scope in ['a','b']:
        db.execute('INSERT INTO adcc_live_queries VALUES(?,?,?,?)',(scope,'q','2026-09-30T10:00:00Z',json.dumps({'Scope':scope})))
    ck('SQL: same query key in two scopes remains separate',db.execute('SELECT count(*) FROM adcc_live_queries').fetchone()[0]==2)
    before=db.execute('SELECT * FROM adcc_live_queries').fetchall();db.execute('BEGIN IMMEDIATE');db.execute("DELETE FROM adcc_live_queries WHERE scope_key='a'");db.execute('ROLLBACK');ck('SQL: rollback restores prior cache exactly',before==db.execute('SELECT * FROM adcc_live_queries').fetchall())
    for n in range(25):db.execute('INSERT INTO adcc_live_queries VALUES(?,?,?,?)',('a','q'+str(n),'2026-09-30T10:%02d:00Z'%n,'{}'))
    db.execute("DELETE FROM adcc_live_queries WHERE scope_key='a' AND query_key IN (SELECT query_key FROM adcc_live_queries WHERE scope_key='a' ORDER BY observed_utc DESC LIMIT -1 OFFSET 20)")
    ck('SQL: retains 20 query snapshots in a scope',db.execute("SELECT count(*) FROM adcc_live_queries WHERE scope_key='a'").fetchone()[0]==20)
    ck('SQL: retention of one scope leaves another untouched',db.execute("SELECT count(*) FROM adcc_live_queries WHERE scope_key='b'").fetchone()[0]==1)
    db.executemany('INSERT INTO adcc_live_observations VALUES(?,?,?,?)',[('a',str(i),'2026-09-30T10:00:00Z','{}') for i in range(5003)])
    db.execute("DELETE FROM adcc_live_observations WHERE scope_key='a' AND object_key IN (SELECT object_key FROM adcc_live_observations WHERE scope_key='a' ORDER BY checked_utc DESC LIMIT -1 OFFSET 5000)")
    ck('SQL: keeps 5000 recent observations per scope',db.execute('SELECT count(*) FROM adcc_live_observations').fetchone()[0]==5000)
    ck('SQL: retention never clears legacy associations',db.execute('SELECT user_login FROM user_machine_links').fetchone()[0]=='manual')
    db.execute("INSERT INTO adcc_live_queries VALUES('a','expired','2000-01-01T00:00:00Z','{}')")
    db.execute("DELETE FROM adcc_live_queries WHERE observed_utc<strftime('%Y-%m-%dT%H:%M:%fZ','now','-30 days')")
    ck('SQL: records beyond 30 days are removed from new cache',db.execute("SELECT count(*) FROM adcc_live_queries WHERE query_key='expired'").fetchone()[0]==0)
    ck('SQL: database remains internally consistent',db.execute('PRAGMA quick_check').fetchone()[0]=='ok');db.close()
    ps=text(r/'wad/tests/Test-DomeniaStreaming.ps1');count=len(re.findall(r'^Case ',ps,re.M))+4 # four-case outcome loop indented once
    out={'Build':BUILD,'Environment':'Linux/Python, source/XML checks + Python SQLite in memory','Passed':sum(c['Passed'] for c in checks),'Failed':sum(not c['Passed'] for c in checks),'Checks':checks,'OriginalCoreFunctions':len(b['CoreFunctions']),'ChangedCoreFunctions':changes,'UnchangedCoreFunctions':len(b['CoreFunctions'])-len(changes),'PinnedWorkers':len(reg),'WindowsScenariosProvided':count,'NotExecuted':['PowerShell native parser','Windows PowerShell 5.1 tests','WPF render','AD LDAP','CIM/DCOM','Performance benchmark']}
    a.report.parent.mkdir(parents=True,exist_ok=True);a.report.write_text(json.dumps(out,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    print('Passed',out['Passed'],'Failed',out['Failed'],'Native scenarios provided',count)
    return 1 if out['Failed'] else 0
if __name__=='__main__':sys.exit(main())
