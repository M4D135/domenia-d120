from pathlib import Path
import argparse,hashlib,json,re,zipfile

a=argparse.ArgumentParser()
a.add_argument('--capture-evidence',required=True);a.add_argument('--attempt',default='R6');a.add_argument('--capture-script',required=True);a.add_argument('--source-root',default='/Users/david/Documents/Projets/Domenia-D120');a.add_argument('--source',required=True);a.add_argument('--out',required=True);a.add_argument('--dev-zip',required=True);a.add_argument('--prod-zip',required=True);a.add_argument('--captures',required=True)
args=a.parse_args();src=Path(args.source);out=Path(args.out);caps=Path(args.captures)
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
def strict_json(text):
    def invalid(value): raise ValueError('Nonfinite JSON constant: '+value)
    return json.loads(text, parse_constant=invalid)
read=lambda p:strict_json(Path(p).read_text(encoding='utf-8-sig'))
summary=read(src/'_quick-ui.json');completion=read(src/'run-complete.json');package=read(src/'package.json');wiring=read(src/'Test-DomeniaWiringRecherche.json')
additional=read(src/'_additional-ui.json')
remaining=read(src/'_all-offline-ui.json')
assert len(remaining['Suites'])==23 and remaining['RuntimeChanged']==[]
assert all(x['ExitCode']==0 and not x['TimedOut'] for x in remaining['Suites'])
prod_check=read(src/'PROD-CheckOnly-process.json')
assert prod_check['ExitCode']==0 and not prod_check['TimedOut']
assert prod_check['PROD_SHA256'].lower()==sha(args.prod_zip)
assert prod_check['EXEStarted'] is False and prod_check['ADAccessed'] is False
assert len(additional['Suites'])==12 and additional['RuntimeChanged']==[]
assert all(x['ExitCode']==0 and not x['TimedOut'] for x in additional['Suites'])
assert len(summary['Suites'])==27,'Expected exact 27-suite campaign'
assert summary['RuntimeChanged']==[],'Runtime modified by qualification'
assert all(x['ExitCode']==0 and not x['TimedOut'] for x in summary['Suites'])
assert completion['AllProcessesPassed'] and all(x['ExitCode']==0 and not x['TimedOut'] for x in completion['Processes'])
assert wiring['Complete'] and wiring['Failed']==0 and wiring['Passed']>=43
assert package['DEV'].lower()==sha(args.dev_zip)
assert package['CaptureScriptSHA256'].lower()==sha(args.capture_script)
capture_evidence=Path(args.capture_evidence)
capture_package=read(capture_evidence/'package.json');capture_process=read(capture_evidence/'GuideCaptures-process.json')
assert capture_package['DEV'].lower()==sha(args.dev_zip),'Captures came from a different archive'
assert capture_package['CaptureScriptSHA256'].lower()==sha(args.capture_script),'Capture harness source mismatch'
assert capture_process['ExitCode']==0 and not capture_process['TimedOut'],'Capture process did not pass'

with zipfile.ZipFile(args.dev_zip) as archive:
    test_files=sorted(Path(n).stem for n in archive.namelist() if '/wad/tests/' in n and Path(n).name.startswith('Test-') and n.endswith('.ps1') and n.count('/')==3)
executed=[x['Suite'] for x in summary['Suites']+additional['Suites']+remaining['Suites'] if x['Suite'].startswith('Test-')]+['Test-DomeniaWiringRecherche']
assert len(executed)==len(set(executed)),'Duplicate test suite execution'
assert set(test_files)==set(executed),'Not every Test-*.ps1 file was executed'

archive_inventory=[]; runtime_inventory=[]
with zipfile.ZipFile(args.dev_zip) as dev_archive, zipfile.ZipFile(args.prod_zip) as prod_archive:
    for entry in dev_archive.namelist():
        if entry.endswith('/'): continue
        raw=dev_archive.read(entry); current=Path(args.source_root)/entry
        assert current.is_file() and current.read_bytes()==raw,'Current source differs from final archive: '+entry
        archive_inventory.append({'File':entry,'SHA256':hashlib.sha256(raw).hexdigest(),'Bytes':len(raw)})
    for entry in prod_archive.namelist():
        if entry.endswith('/') or entry.endswith('/package-manifest.json'): continue
        raw=prod_archive.read(entry); relative=entry.removeprefix('prod/')
        assert dev_archive.read('dev/'+relative)==raw,'Runtime DEV/PROD mismatch: '+relative
        runtime_inventory.append({'File':relative,'SHA256':hashlib.sha256(raw).hexdigest(),'Bytes':len(raw)})
assert len(runtime_inventory)==93
by_path={x['File'].removeprefix('dev/'):x['SHA256'] for x in archive_inventory}
expected_runtime={p for p in by_path if p.startswith('wad/') and '/tests/' not in p and Path(p).suffix.lower() in {'.ps1','.dll','.xaml','.cs','.json'}}
for record_name in ['runtime-source.json','additional-runtime-source.json','all-offline-runtime-source.json']:
    runtime_record=read(src/record_name)
    paths=[x['File'].replace('\\','/') for x in runtime_record]
    assert len(paths)==len(set(paths)) and set(paths)==expected_runtime,'Executed runtime inventory missing, duplicated or unexpected: '+record_name
    for entry,path in zip(runtime_record,paths):
        assert by_path[path].lower()==entry['SHA256'].lower(),'Executed runtime source mismatch: '+record_name+'/'+path

def require_success_report(data, name):
    assert isinstance(data,dict),'Suite report must be object: '+name
    assert any(k in data for k in ['Passed','Pass','Status']),'Unrecognized success report schema: '+name
    for key in ['Failed','Fail','Errors','ErrorCount','WorkerFailures','Skipped']:
        if key in data:
            value=data[key]
            assert (len(value)==0 if isinstance(value,(list,dict)) else value==0),'Nonzero '+key+': '+name
    if 'Complete' in data: assert data['Complete'] is True,'Incomplete report: '+name
    if 'Status' in data: assert data['Status']=='PASS','Non-PASS report: '+name
    if 'Failure' in data: assert not data['Failure'],'Failure text present: '+name
    for key in ['Passed','Pass']:
        if key in data:
            value=data[key]
            assert value is True if isinstance(value,bool) else isinstance(value,(int,float)) and value>0,'No passed cases: '+name
no_json_reports={'StartupCheckOnly','Test-DomeniaQuery','Test-DomeniaIndexSorting','Test-DomeniaIndexActions','Test-DomeniaDnScopes','Test-DomeniaNative','Test-DomeniaIndexPersistence'}
for suite in summary['Suites']+additional['Suites']+remaining['Suites']:
    assert suite['ReportWritten'] is (suite['Suite'] not in no_json_reports),'Report completeness mismatch: '+suite['Suite']
    if suite['ReportWritten']: require_success_report(read(src/(suite['Suite']+'.json')),suite['Suite'])
require_success_report(wiring,'Test-DomeniaWiringRecherche')
cp=read(src/'text-encodings.json')['ConsoleOutputCodePage']
selected=set(src.glob('*.json'))
selected.update(src/n for n in ['external-runner.ps1','external-prod-check.ps1'])
selected.update(caps/n for n in ['capture-checks.json','capture-provenance.json','capture-layouts.json'])
for suite in summary['Suites']+additional['Suites']+remaining['Suites']:
    if not suite['ReportWritten']:selected.add(src/(suite['Suite']+'.stdout.txt'))
for p in src.glob('*.stderr.txt'):
    if p.stat().st_size:selected.add(p)
# All native originals remain outside Git. Only compact top-level proof documents are exported.
manifest=[];out.mkdir(parents=True,exist_ok=True)
for p in sorted(selected):
    raw=p.read_bytes()
    if raw.startswith((b'\xff\xfe',b'\xfe\xff')):encoding='utf-16'
    elif raw.startswith(b'\xef\xbb\xbf'):encoding='utf-8-sig'
    else:
        try:raw.decode('utf-8');encoding='utf-8'
        except UnicodeDecodeError:encoding='cp'+str(cp)
    text=raw.decode(encoding)
    normalized='\n'.join(line.rstrip(' \t') for line in text.replace('\r\n','\n').replace('\r','\n').split('\n')).rstrip('\n')+'\n'
    if p.suffix=='.json':assert strict_json(text)==strict_json(normalized)
    data=normalized.encode('utf-8');(out/p.name).write_bytes(data)
    manifest.append({'File':p.name,'OriginalPath':str(p),'OriginalSHA256':hashlib.sha256(raw).hexdigest(),'ExportedSHA256':hashlib.sha256(data).hexdigest(),'OriginalBytes':len(raw),'ExportedBytes':len(data),'OriginalEncoding':encoding,'Normalization':'UTF-8 without BOM; LF; trim trailing spaces; one final newline'})
reports=[]
for p in sorted(src.glob('*.json')):
    d=read(p)
    if isinstance(d,dict) and any(k in d for k in ['Passed','Pass','Status']):
        reports.append({'File':p.name,'Metrics':{k:d[k] for k in ['Passed','Failed','Pass','Fail','Status','Complete','Cases','Assertions','Files','Errors','Warnings'] if k in d}})
boards=read(src/'Test-DomeniaBoards.json');live=read(src/'Test-DomeniaLiveSearchView.json')
scale=next((r for r in live.get('Results',[]) if r['Name'].startswith('Five thousand')),None)
images=[]
for p in sorted(caps.glob('*.png')):
    raw=p.read_bytes();assert raw[:8]==b'\x89PNG\r\n\x1a\n'
    w=int.from_bytes(raw[16:20],'big');h=int.from_bytes(raw[20:24],'big')
    images.append({'File':p.name,'Width':w,'Height':h,'SHA256':sha(p)})
assert images,'No captures returned'
capture_checks=read(caps/'capture-checks.json')
assert capture_checks['Checks'] and all(c['Passed'] for c in capture_checks['Checks']),'Capture checks failed'
assert all(i['Width']>=1920 and i['Height']>=1080 for i in images if 'viewport-' not in i['File']),'Documentary image below native 1080p'
provenance=read(caps/'capture-provenance.json')
assert provenance['ToolTipsEnabled'] is False
with zipfile.ZipFile(args.dev_zip) as archive:
    assert provenance['SourceManifestSHA256'].lower()==hashlib.sha256(archive.read('dev/wad/package-manifest.json')).hexdigest(),'Capture source manifest mismatch'
recorded=provenance['Images'];names=[x['File'] for x in recorded]
assert len(names)==len(set(names)) and set(names)=={x['File'] for x in images},'Capture image inventory mismatch'
actual_images={x['File']:x for x in images}
for entry in recorded:
    actual=actual_images[entry['File']]
    assert entry['Width']==actual['Width'] and entry['Height']==actual['Height'] and entry['SHA256'].lower()==actual['SHA256'],'Capture bytes or dimensions mismatch'

qualification={'Build':read(Path(args.source_root)/'dev/wad/Domenia.release.json')['Build'],'Status':'PASS','BaseCommit':'443b999c61be5a2100e1f3fa4d18a55eb305456a','DEV_SHA256':sha(args.dev_zip),'PROD_SHA256':sha(args.prod_zip),'UTC':summary['UTC'],'Machine':summary['VM'],'PowerShell':summary['PowerShell'],'Session':summary['Session'],'TestFiles':test_files,'TestFileCount':len(test_files),'TotalQualificationSteps':63,'PassedQualificationSteps':63,'HelperSteps':4,'Suites':27,'PassedSuites':63,'FailedSuites':0,'TimedOutSuites':0,'AdditionalSuites':{'Count':12,'Passed':12,'Failed':0,'Report':'_additional-ui.json'},'RemainingOfflineSuites':{'Count':23,'Passed':23,'Failed':0,'Report':'_all-offline-ui.json'},'RuntimeChanged':[],'PROD_CheckOnly':prod_check,'WiringRecherche':{'Passed':wiring['Passed'],'Failed':0,'Complete':True},'Data':'Synthetic fixtures; no real AD directory, remote CIM or endpoint ping','Wpf':'Real Windows WPF, session0; not interactive Alt-Tab qualification','Reports':reports,'HiddenRenderMicrobench':boards.get('RenderTimings',[]),'HiddenRenderTimingScope':boards.get('RenderTimingScope',''),'Scale5000':{'ScenarioMilliseconds':scale.get('Milliseconds') if scale else None,'Meaning':'Synthetic progressive WPF/CollectionView plus dispatcher pumping/filtering, not AD throughput'},'CaptureScriptSHA256':package['CaptureScriptSHA256'],'Images':images,'OriginalEvidence':str(src),'NormalizationManifest':'proof-export-manifest.json'}
all_suites=summary['Suites']+additional['Suites']+remaining['Suites']
wiring_process=read(src/'Test-DomeniaWiringRecherche-process.json')
all_suites.append({'Suite':'Test-DomeniaWiringRecherche','ExitCode':wiring_process['ExitCode'],'TimedOut':wiring_process['TimedOut'],'Milliseconds':wiring_process['Milliseconds'],'ReportWritten':True})
assert len(all_suites)==63 and len({x['Suite'] for x in all_suites})==63 and all(x['ExitCode']==0 and not x['TimedOut'] for x in all_suites)
assert {x['Suite'] for x in all_suites if not x['Suite'].startswith('Test-')}=={'Ps51Compat','ProdFactory','NativeParser','StartupCheckOnly'}
qualification.update({'SourceBaseCommit':qualification['BaseCommit'],'DevZipSHA256':qualification['DEV_SHA256'],'ProdZipSHA256':qualification['PROD_SHA256'],'VM':summary['VM'],'Apartment':summary['Apartment'],'Is64Bit':summary['Is64Bit'],'ADAccessed':False,'Suites':all_suites,'SuiteCount':63,'CurrentSourceMatchesArchive':True,'SourceComparisonScope':'All files included in DEV archive; source-only engineering/history files excluded by the package contract are outside this inventory.','ExactInventory':'exact-source-inventory.json','Limitations':['Synthetic data only; no real Active Directory qualification.','WPF session0 does not replace a human interactive desktop walkthrough.','R4 Native.dll and R5 Query.dll Add-Type E_UNEXPECTED incidents are preserved as failed attempts. Seven isolated Query loads did not reproduce the error; its cause remains unestablished. The distinct R6 campaign uses the same immutable archives, with no concurrent authenticated GuestControl operations. A passing R6 proves that execution only, not correction of the earlier assembly-load incident.'],'SourceBinding':'Exact current source and executed runtime inventory matched to immutable DEV ZIP; package manifest binds all packaged tools and tests.','RuntimeFilesIdentical':93,'ArchiveComparison':'archive-comparison93.json','SuiteSummaries':{r['File'].removesuffix('.json'):r['Metrics'] for r in reports},'HumanGUI':{'Status':'BLOCKED_MAC_LOCKED_NOT_RUN','NotIncludedInOfflineQualification':True}})
(out/'exact-source-inventory.json').write_text(json.dumps({'CurrentSourceMatchesArchive':True,'DevZipSHA256':sha(args.dev_zip),'FileCount':len(archive_inventory),'Files':archive_inventory},indent=2)+'\n')
(out/'archive-comparison93.json').write_text(json.dumps({'DevZipSHA256':sha(args.dev_zip),'ProdZipSHA256':sha(args.prod_zip),'IdenticalRuntimeFiles':93,'Excluded':'package-manifest.json differs by package scope','Files':runtime_inventory},indent=2)+'\n')
scale_report=read(src/'Test-DomeniaScale.json')
qualification['SyntheticScale']={k:scale_report[k] for k in ['Count','ProbesPerObservedComputer','Checks','Passed','PeakWorkingSetMB','ManagedRetainedMB','DatabaseMB','Qualification'] if k in scale_report}
qualification['Attempt']=args.attempt
qualification['PreviousAttempt']={'Status':'FAIL','PassedSteps':62,'FailedSteps':1,'Evidence':'../intermediate/r5-campaign/attempt-status.json','NotMergedIntoThisCampaign':True}
qualification['EnvironmentDiagnostic']={'Status':'INCONCLUSIVE','Evidence':'../intermediate/profile-diagnostic/diagnostic-summary.json','NoRuntimeOrSecurityChanges':True,'NoAutomaticRetries':True}
qualification['CaptureEvidence']={'Attempt':'R5','RawEvidence':str(capture_evidence),'Process':capture_process,'Binding':'Exact same DEV archive SHA, capture harness SHA, source manifest SHA and every PNG SHA verified'}
qualification['ExternalOrchestration']={'Runner':'external-runner.ps1','ProdCheck':'external-prod-check.ps1','Source':'Guest files copied only after campaign termination; original and normalized SHA in proof-export-manifest.json'}
qualification['GuestProtocol']={'AuthenticatedGuestControlOperationsDuringCampaign':0,'Monitoring':'Host COM GuestSession.Processes.Status only; no guest authentication until termination','ProfileStart':'profile-start.json','ProfileEnd':'profile-end.json','ProfileOptionGuarantee':False}
qualification['EvidenceDirectory']=str(out.relative_to(Path(args.source_root))) if out.is_relative_to(Path(args.source_root)) else str(out)
qualification['EvidenceSha256']={str((out/m['File']).relative_to(Path(args.source_root))) if (out/m['File']).is_relative_to(Path(args.source_root)) else m['File']:m['ExportedSHA256'] for m in manifest}
for name in ['exact-source-inventory.json','archive-comparison93.json']:
    qualification['EvidenceSha256'][str((out/name).relative_to(Path(args.source_root))) if (out/name).is_relative_to(Path(args.source_root)) else name]=sha(out/name)
(out/'qualification.json').write_text(json.dumps(qualification,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
(out/'proof-export-manifest.json').write_text(json.dumps({'OriginalEvidence':str(src),'Entries':manifest},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
for m in manifest:assert sha(out/m['File'])==m['ExportedSHA256']
print(json.dumps({'Status':'PASS','Suites':27,'Wiring':wiring['Passed'],'ExportedFiles':len(manifest),'PNGs':len(images),'Destination':str(out)},ensure_ascii=False))
