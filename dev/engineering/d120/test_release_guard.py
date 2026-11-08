import unittest, tempfile, zipfile, json, hashlib, stat, copy, sys, io, contextlib
from pathlib import Path
from release_guard import inspect_archive,require_evidence,canonical,GateError,REQUIRED,main as guard_main
TOOLS=Path(__file__).resolve().parents[2]/'tools'
if str(TOOLS) not in sys.path:sys.path.insert(0,str(TOOLS))
import build_packages
START='2026-10-02T10:00:00.1234567Z';END='2026-10-02T10:05:00.0000000Z'
class GuardTests(unittest.TestCase):
 def setUp(self):self.t=tempfile.TemporaryDirectory();self.root=Path(self.t.name)
 def tearDown(self):self.t.cleanup()
 def make(self,transform=None,extra=None,edition='prod',name='a.zip',build=None):
  data={edition+'/Domenia.exe':b'fixture-not-executable',edition+'/wad/Support/DEBLOQUER_TOUT.cmd':b'@echo off\r\n',edition+'/wad/model.ps1':b'function Example { 1 }'}
  files=[dict(Path=n[len(edition)+1:],Sha256=hashlib.sha256(v).hexdigest(),Bytes=len(v),Runtime=True,PreserveExisting=False) for n,v in data.items()]
  m={'Files':files}
  if build:m['Build']=build
  if transform:transform(data,m)
  data[edition+'/wad/package-manifest.json']=json.dumps(m).encode()
  if extra:data.update(extra)
  p=self.root/name
  with zipfile.ZipFile(p,'w') as z:
   for n,v in data.items():z.writestr(n,v)
  return p
 def add(self,rel,content,edition='prod'):
  # Adds a declared file to the fixture archive (manifest entry and member).
  def t(d,m):
   d[edition+'/'+rel]=content
   m['Files'].append(dict(Path=rel,Sha256=hashlib.sha256(content).hexdigest(),Bytes=len(content),Runtime=True,PreserveExisting=False))
  return t
 def evidence(self,info):return {'ArchiveSHA256':info['SHA256'],'Host':{'Platform':'Windows','PSEdition':'Desktop','PSVersion':'5.1.1'},'OverallStatus':'PASS','Scenarios':[{'Id':s,'Status':'PASS','Executed':True,'StartedUtc':START,'EndedUtc':END,'EvidenceSHA256':'a'*64} for s in REQUIRED]}
 def pair(self,build='2026.10.02-DOMENIA-1.0-RC1.11.0-D120'):
  dev=inspect_archive(self.make(edition='dev',name='dev.zip',build=build));prod=inspect_archive(self.make(edition='prod',name='prod.zip',build=build))
  r={'Build':build,'Archives':[{'Edition':'dev','Name':'dev.zip','SHA256':dev['SHA256'],'SHA256End':dev['SHA256']},{'Edition':'prod','Name':'prod.zip','SHA256':prod['SHA256'],'SHA256End':prod['SHA256']}],
     'Host':{'Platform':'Windows','PSEdition':'Desktop','PSVersion':'5.1.26100.1'},'OverallStatus':'PASS','Scenarios':[]}
  for s in REQUIRED:
   target=prod if s=='prod.standalone' else dev
   r['Scenarios'].append({'Id':s,'Status':'PASS','Executed':True,'Edition':target['Edition'],'ArchiveSHA256':target['SHA256'],'StartedUtc':START,'EndedUtc':END,'EvidenceSHA256':'b'*64})
  return dev,prod,r
 def test_valid(self):self.assertEqual(inspect_archive(self.make())['Files'],3)
 def test_tamper(self):
  p=self.make(lambda d,m:d.update({'prod/wad/model.ps1':b'changed'}))
  with self.assertRaises(GateError):inspect_archive(p)
 def test_missing(self):
  p=self.make(lambda d,m:d.pop('prod/wad/model.ps1'))
  with self.assertRaises(GateError):inspect_archive(p)
 def test_extra(self):
  with self.assertRaises(GateError):inspect_archive(self.make(extra={'prod/unknown.ps1':b'1'}))
 def test_bad_size(self):
  p=self.make(lambda d,m:m['Files'][0].update(Bytes=0))
  with self.assertRaises(GateError):inspect_archive(p)
 def test_duplicate(self):
  p=self.make(lambda d,m:m['Files'].append(dict(m['Files'][0])))
  with self.assertRaises(GateError):inspect_archive(p)
 def test_runtime_absent(self):
  p=self.make(lambda d,m:[x.update(Runtime=False) for x in m['Files']])
  with self.assertRaises(GateError):inspect_archive(p)
 def test_case_collision(self):
  with self.assertRaises(GateError):inspect_archive(self.make(extra={'prod/DOMENIA.exe':b'1'}))
 def test_traversal(self):
  for s in ('../x','/tmp/x','prod/../x','prod//x','prod/./x','C:/x','prod/NUL','prod/COM1.exe','prod/x.','prod/x ','prod\\x'):
   with self.subTest(s=s),self.assertRaises(GateError):canonical(s)
 def test_foreign_root(self):
  with self.assertRaises(GateError):inspect_archive(self.make(extra={'other/x':b'1'}))
 def test_evidence_valid_local_not_signed(self):
  i=inspect_archive(self.make());self.assertEqual(require_evidence(i,self.evidence(i))['WindowsQualification'],'PASS_REPORTED')
 def test_no_evidence(self):
  i=inspect_archive(self.make())
  with self.assertRaises(GateError):require_evidence(i,{})
 def test_hash_mismatch(self):
  i=inspect_archive(self.make());r=self.evidence(i);r['ArchiveSHA256']='0'*64
  with self.assertRaises(GateError):require_evidence(i,r)
 def test_linux_not_windows(self):
  i=inspect_archive(self.make());r=self.evidence(i);r['Host']['Platform']='Unix'
  with self.assertRaises(GateError):require_evidence(i,r)
 def test_ps7_not_ps51(self):
  i=inspect_archive(self.make());r=self.evidence(i);r['Host']['PSVersion']='7.6.0'
  with self.assertRaises(GateError):require_evidence(i,r)
 def test_missing_scenario(self):
  i=inspect_archive(self.make());r=self.evidence(i);r['Scenarios'].pop()
  with self.assertRaises(GateError):require_evidence(i,r)
 def test_skip_not_pass(self):
  i=inspect_archive(self.make());r=self.evidence(i);r['Scenarios'][0]['Status']='SKIP'
  with self.assertRaises(GateError):require_evidence(i,r)
 def test_not_executed_not_pass(self):
  i=inspect_archive(self.make());r=self.evidence(i);r['Scenarios'][0]['Executed']=False
  with self.assertRaises(GateError):require_evidence(i,r)
 def test_not_executed_status_not_pass(self):
  i=inspect_archive(self.make());r=self.evidence(i);r['Scenarios'][0]['Status']='NOT_EXECUTED'
  with self.assertRaises(GateError):require_evidence(i,r)
 def test_duplicate_scenario(self):
  i=inspect_archive(self.make());r=self.evidence(i);r['Scenarios'].append(dict(r['Scenarios'][0]))
  with self.assertRaises(GateError):require_evidence(i,r)
 def test_missing_evidence_hash(self):
  i=inspect_archive(self.make());r=self.evidence(i);r['Scenarios'][0].pop('EvidenceSHA256')
  with self.assertRaises(GateError):require_evidence(i,r)
 def test_unreadable_timestamp_refused(self):
  i=inspect_archive(self.make());r=self.evidence(i);r['Scenarios'][0]['StartedUtc']='fixture'
  with self.assertRaises(GateError):require_evidence(i,r)
 def test_inverted_timestamps_refused(self):
  i=inspect_archive(self.make());r=self.evidence(i);r['Scenarios'][0]['StartedUtc']=END;r['Scenarios'][0]['EndedUtc']=START
  with self.assertRaises(GateError):require_evidence(i,r)
 # ---- malformed reports are a structured refusal (GateError, exit 2), never a Python trace
 def test_null_archive_sha_is_gate_error(self):
  i=inspect_archive(self.make());r=self.evidence(i);r['ArchiveSHA256']=None
  with self.assertRaises(GateError):require_evidence(i,r)
 def test_host_not_object_is_gate_error(self):
  i=inspect_archive(self.make());r=self.evidence(i);r['Host']='Windows'
  with self.assertRaises(GateError):require_evidence(i,r)
 def test_scenario_not_object_is_gate_error(self):
  i=inspect_archive(self.make());r=self.evidence(i);r['Scenarios'][0]='parser.ps51'
  with self.assertRaises(GateError):require_evidence(i,r)
 def test_report_not_object_is_gate_error(self):
  i=inspect_archive(self.make())
  with self.assertRaises(GateError):require_evidence(i,['PASS'])
 def test_main_malformed_report_exit_2_json(self):
  p=self.make();rep=self.root/'r.json';rep.write_text(json.dumps({'ArchiveSHA256':None,'Host':'x'}))
  err=io.StringIO()
  with contextlib.redirect_stderr(err),contextlib.redirect_stdout(io.StringIO()):code=guard_main([str(p),'--windows-report',str(rep)])
  self.assertEqual(code,2);self.assertEqual(json.loads(err.getvalue())['Status'],'FAIL')
 def test_main_require_windows_without_report(self):
  p=self.make();err=io.StringIO()
  with contextlib.redirect_stderr(err),contextlib.redirect_stdout(io.StringIO()):code=guard_main([str(p),'--require-windows'])
  self.assertEqual(code,2)
 # ---- D009 two-archive campaign (DEV suites, PROD standalone)
 def test_two_archives_ok_for_dev_and_prod(self):
  dev,prod,r=self.pair()
  self.assertEqual(require_evidence(dev,r)['WindowsQualification'],'PASS_REPORTED')
  self.assertEqual(require_evidence(prod,r)['WindowsQualification'],'PASS_REPORTED')
 def test_prod_absent_refused(self):
  dev,prod,r=self.pair();r['Archives']=[a for a in r['Archives'] if a['Edition']=='dev']
  with self.assertRaises(GateError):require_evidence(dev,r)
 def test_scenario_edition_mismatch(self):
  dev,prod,r=self.pair()
  for s in r['Scenarios']:
   if s['Id']=='prod.standalone':s['ArchiveSHA256']=dev['SHA256'];s['Edition']='dev'
  with self.assertRaises(GateError):require_evidence(prod,r)
 def test_scenario_unbound_in_two_archive_report(self):
  dev,prod,r=self.pair();r['Scenarios'][0].pop('ArchiveSHA256')
  with self.assertRaises(GateError):require_evidence(dev,r)
 def test_build_mismatch(self):
  dev,prod,r=self.pair();r['Build']='2026.10.02-DOMENIA-1.0-RC1.11.1-D120'
  with self.assertRaises(GateError):require_evidence(dev,r)
 def test_archive_changed_during_campaign(self):
  dev,prod,r=self.pair();r['Archives'][0]['SHA256End']='c'*64
  with self.assertRaises(GateError):require_evidence(dev,r)
 def test_rebuilt_archive_needs_new_report(self):
  # D009: one changed file after the test gives another archive hash: the old report no longer applies.
  dev,prod,r=self.pair()
  changed=inspect_archive(self.make(lambda d,m:(d.update({'dev/wad/model.ps1':b'function Example { 2 }'}),m['Files'][2].update(Sha256=hashlib.sha256(b'function Example { 2 }').hexdigest(),Bytes=len(b'function Example { 2 }'))),edition='dev',name='dev2.zip',build=r['Build']))
  with self.assertRaises(GateError):require_evidence(changed,r)
 def test_evidence_dir_verified_and_tamper_detected(self):
  dev,prod,r=self.pair();ev=self.root/'ev'
  for s in r['Scenarios']:
   folder=ev/s['Id'];folder.mkdir(parents=True)
   (folder/'step.json').write_bytes(b'{"Status":"PASS"}')
   listing=(hashlib.sha256(b'{"Status":"PASS"}').hexdigest()+'  step.json\n').encode()
   (folder/'evidence.sha256').write_bytes(listing);s['EvidenceSHA256']=hashlib.sha256(listing).hexdigest()
  self.assertTrue(require_evidence(dev,r,ev)['EvidenceVerified'])
  (ev/'parser.ps51'/'step.json').write_bytes(b'{"Status":"FAIL"}')
  with self.assertRaises(GateError):require_evidence(dev,r,ev)
 # ---- D111 decision: demo provider allowed in PROD, real development tools refused, demo config refused
 def test_demo_provider_module_allowed_in_prod(self):
  self.assertEqual(inspect_archive(self.make(self.add('wad/modules/Domenia-Demo.Model.ps1',b'function Get-X { 1 }')))['Files'],4)
 def test_tests_folder_refused_in_prod(self):
  with self.assertRaises(GateError):inspect_archive(self.make(self.add('wad/tests/Test-X.ps1',b'1')))
 def test_launcher_tool_refused_in_prod(self):
  with self.assertRaises(GateError):inspect_archive(self.make(self.add('wad/Support/TESTER-X.cmd',b'@echo off\r\n')))
 def test_dev_tools_allowed_in_dev(self):
  self.assertEqual(inspect_archive(self.make(self.add('wad/tests/Test-X.ps1',b'1','dev'),edition='dev',name='d.zip'))['Edition'],'dev')
 def test_demo_config_refused(self):
  for value in (True,'true'):
   with self.subTest(value=value),self.assertRaises(GateError):
    inspect_archive(self.make(self.add('wad/Domenia.config.json',json.dumps({'Auth':{'DemoProvider':value}}).encode()),name='c'+str(value)+'.zip'))
 def test_standard_config_accepted(self):
  self.assertEqual(inspect_archive(self.make(self.add('wad/Domenia.config.json',b'\xef\xbb\xbf{"Auth":{"LoginWindowMode":"Standard"}}')))['Files'],4)

class BuildHelperTests(unittest.TestCase):
 """D112 and D111 helpers of tools/build_packages.py, on temporary trees (no build, no archive)."""
 def setUp(self):self.t=tempfile.TemporaryDirectory();self.root=Path(self.t.name)
 def tearDown(self):self.t.cleanup()
 def touch(self,rel,data=b'x'):
  p=self.root/rel;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data);return p
 def test_members_sorted_posix_without_junk_or_output(self):
  for rel in ['b.txt','A.txt','wad/x.ps1','wad/.DS_Store','Thumbs.db','wad/desktop.ini','__pycache__/m.pyc','wad/data/db.sqlite','dist/old.zip','wad/package-manifest.json','x.tmp']:self.touch(rel)
  self.assertEqual(build_packages.select_members(self.root,exclude=[self.root/'dist']),['A.txt','b.txt','wad/x.ps1'])
 def test_two_selections_identical(self):
  for rel in ['z/1','a/2','M/3']:self.touch(rel)
  self.assertEqual(build_packages.select_members(self.root),build_packages.select_members(self.root))
 def test_writejson_lf_only(self):
  p=self.root/'m.json';build_packages.writejson(p,{'Files':[{'Path':'a'}]})
  self.assertNotIn(b'\r\n',p.read_bytes())
 def test_output_inside_source_refused(self):
  with self.assertRaises(ValueError):build_packages.check_output(self.root/'out',self.root)
  with self.assertRaises(ValueError):build_packages.check_output(self.root,self.root)
  self.assertEqual(build_packages.check_output(self.root.parent/'elsewhere',self.root),(self.root.parent/'elsewhere').resolve())
 def test_demo_config_refused_by_build(self):
  with self.assertRaises(ValueError):build_packages.assert_config_not_demo(b'{"Auth":{"DemoProvider":true}}')
  build_packages.assert_config_not_demo(b'\xef\xbb\xbf{"Auth":{"LoginWindowMode":"Standard"}}')
 def test_signed_stage_must_match_audited_source(self):
  self.touch('wad/a.ps1',b'Write-Output 1\n')
  stage=self.root.parent/(self.root.name+'-stage');(stage/'wad').mkdir(parents=True)
  try:
   (stage/'wad/a.ps1').write_bytes(b'Write-Output 1\n\r\n# SIG # Begin signature block\r\n# AAAA\r\n# SIG # End signature block\r\n')
   self.assertTrue(build_packages.signed_source('wad/a.ps1',stage,self.root).endswith(b'End signature block\r\n'))
   (stage/'wad/a.ps1').write_bytes(b'Write-Output 2\n\r\n# SIG # Begin signature block\r\n# AAAA\r\n# SIG # End signature block\r\n')
   with self.assertRaises(ValueError):build_packages.signed_source('wad/a.ps1',stage,self.root)
   (stage/'wad/a.ps1').write_bytes(b'Write-Output 1\n')
   with self.assertRaises(ValueError):build_packages.signed_source('wad/a.ps1',stage,self.root)
  finally:
   for p in sorted(stage.rglob('*'),reverse=True):p.unlink() if p.is_file() else p.rmdir()
   stage.rmdir()
 def test_pe_version_read_from_bytes(self):
  blob=b'\x00'*8+(0xFEEF04BD).to_bytes(4,'little')+b'\x00\x00\x01\x00'+(0x00010000).to_bytes(4,'little')+(0x00000001).to_bytes(4,'little')
  self.assertEqual(build_packages.pe_file_version(blob),'1.0.0.1')
  self.assertEqual(build_packages.pe_file_version(b'MZ'),'')
if __name__=='__main__':unittest.main(verbosity=2)
