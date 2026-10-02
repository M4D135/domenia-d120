import unittest, tempfile, zipfile, json, hashlib, stat, copy
from pathlib import Path
from release_guard import inspect_archive,require_evidence,canonical,GateError,REQUIRED
class GuardTests(unittest.TestCase):
 def setUp(self):self.t=tempfile.TemporaryDirectory();self.root=Path(self.t.name)
 def tearDown(self):self.t.cleanup()
 def make(self,transform=None,extra=None):
  data={'prod/Domenia.exe':b'fixture-not-executable','prod/wad/Support/DEBLOQUER_TOUT.cmd':b'@echo off\r\n','prod/wad/model.ps1':b'function Example { 1 }'}
  files=[dict(Path=n[5:],Sha256=hashlib.sha256(v).hexdigest(),Bytes=len(v),Runtime=True,PreserveExisting=False) for n,v in data.items()]
  m={'Files':files}
  if transform:transform(data,m)
  data['prod/wad/package-manifest.json']=json.dumps(m).encode()
  if extra:data.update(extra)
  p=self.root/'a.zip'
  with zipfile.ZipFile(p,'w') as z:
   for n,v in data.items():z.writestr(n,v)
  return p
 def evidence(self,info):return {'ArchiveSHA256':info['SHA256'],'Host':{'Platform':'Windows','PSEdition':'Desktop','PSVersion':'5.1.1'},'OverallStatus':'PASS','Scenarios':[{'Id':s,'Status':'PASS','Executed':True,'StartedUtc':'fixture','EndedUtc':'fixture','EvidenceSHA256':'a'*64} for s in REQUIRED]}
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
 def test_duplicate_scenario(self):
  i=inspect_archive(self.make());r=self.evidence(i);r['Scenarios'].append(dict(r['Scenarios'][0]))
  with self.assertRaises(GateError):require_evidence(i,r)
 def test_missing_evidence_hash(self):
  i=inspect_archive(self.make());r=self.evidence(i);r['Scenarios'][0].pop('EvidenceSHA256')
  with self.assertRaises(GateError):require_evidence(i,r)
if __name__=='__main__':unittest.main(verbosity=2)
