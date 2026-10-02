#!/usr/bin/env python3
"""RC1.5 portable source/XML/hash checks. Never claimed to execute PowerShell or WPF."""
from pathlib import Path
import argparse,collections,hashlib,json,re,sys,functools
import xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'wad/tests'))
from powershell_lex import functions as raw_functions,mask_ps
functions=functools.lru_cache(maxsize=96)(raw_functions)

@functools.lru_cache(maxsize=96)
def text(p):return p.read_text('utf-8-sig')
def function(s,n):
 matches=functions(s).get(n,[])
 if len(matches)!=1:raise ValueError('Function count: '+n)
 a,b=matches[0];return s[a:b]
def literals(s):return [m[2] for m in re.finditer(r'@([\'"])\n(.*?)\n^\1@',s,re.S|re.M)]
def sha(s):return hashlib.sha256(s.encode() if isinstance(s,str) else s).hexdigest().upper()

def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--report',type=Path,required=True);args=ap.parse_args()
 checks=[]
 def ck(n,ok,kind='Source'):
  try:
   value=ok() if callable(ok) else ok
   assert value,n
   checks.append(dict(Name=n,Passed=True,Kind=kind))
  except Exception as exc:checks.append(dict(Name=n,Passed=False,Kind=kind,Error=str(exc)))
 core=text(ROOT/'wad/Domenia-Core.ps1');fn=lambda n:function(core,n)
 reg=dict(re.findall(r'(\w+)\s*=\s*"([A-F0-9]{64})"',fn('Get-DomeniaWorkerOperationHashes')))
 contracts=json.loads(text(ROOT/'tools/operation-contracts.json'))
 rows=json.loads(text(ROOT/'wad/docs/RC1.5-baseline.json'))
 ck('Same registry as RC1.4, including LiveSelectedPing',reg==rows['Registry'])
 ck('Exactly 55 reviewed operations for this release',len(reg)==55 and len(contracts)==55 and set(reg)=={r['Operation'] for r in contracts})
 validator=fn('Assert-DomeniaWorkerRegistry')
 expected=re.search(r'\$expectedFingerprint\s*=\s*"([A-F0-9]{64})"',validator)[1]
 def digest(r):return sha('\n'.join(k+'='+r[k] for k in sorted(r)))
 ck('Pinned complete-map digest matches actual registry',digest(reg)==expected,'Hash')
 ck('Initialization calls whole registry check', '$registeredOperations = Assert-DomeniaWorkerRegistry -Registry $registry' in fn('Initialize-AsyncEngine'))
 ck('No duplicated numeric operation counter in initializer',not re.search(r'\.Count\s*-\w+\s*\d+',fn('Initialize-AsyncEngine')))
 ck('Runtime log reports verified count', '-f $registeredOperations' in fn('Initialize-AsyncEngine'))
 ck('Legacy 54 message no longer emitted by core','Registre worker incomplet' not in core and '54 operations hash-pinnees' not in core)
 ck('Case sensitive ID and hash shape validation',"-cnotmatch '^[A-Za-z][A-Za-z0-9]{2,63}$'" in validator and "-cnotmatch '^[A-F0-9]{64}$'" in validator)
 ck('Registry empty/null rejected',"$null -eq $Registry -or $Registry.Count -eq 0" in validator)
 ck('Registry digest sorted ordinally','[Array]::Sort($names,[StringComparer]::Ordinal)' in validator)
 ck('Registry remains pinned, not relearned from runtime input','$actual,$expectedFingerprint,[StringComparison]::Ordinal' in validator and 'Set-Content' not in validator)
 ck('Per-operation hash enforcement retained', sha(fn('Assert-DomeniaWorkerOperationCode'))==rows['CoreFunctions']['Assert-DomeniaWorkerOperationCode'])
 # Independent mutation checks exercise the fingerprint recipe, not PowerShell execution.
 for key in ['LiveSelectedPing','ReadLaps','EngineSelfTest']:
  modified=dict(reg);modified.pop(key)
  ck('Fingerprint detects missing '+key,digest(modified)!=expected,'Python recipe')
 modified=dict(reg);modified.pop('LiveSelectedPing');modified['UnexpectedOperation']='A'*64
 ck('Fingerprint detects same-sized wrong name set',len(modified)==len(reg) and digest(modified)!=expected,'Python recipe')
 modified=dict(reg);modified['ReadLaps']='A'*64
 ck('Fingerprint detects changed valid-looking hash',digest(modified)!=expected,'Python recipe')
 ck('Fingerprint independent of declaration order',digest(dict(reversed(list(reg.items()))))==expected,'Python recipe')
 old=text(ROOT/'wad/tests/fixtures/RC1.4-Initialize-AsyncEngine.txt')
 limit=int(re.search(r'\$registry.Count -ne (\d+)',old)[1])
 ck('Original 54 check explains observed 55/54',limit==54 and len(reg)!=limit,'Source reproduction')
 for item in contracts:
  body=literals(function(text(ROOT/item['File']),item['Function']))[item['LiteralIndex']]
  ck('Operation unchanged and pinned: '+item['Operation'],sha(body)==reg[item['Operation']]==item['Sha256'],'Hash')
 for name in rows['SensitiveCoreFunctions']:
  ck('Preserved: '+name,sha(fn(name))==rows['CoreFunctions'][name],'Hash')
 currentf=functions(core)
 changed=[]
 for name,value in rows['CoreFunctions'].items():
  if name not in currentf or sha(fn(name))!=value:changed.append(name)
 ck('Only intended existing core functions changed',set(changed)=={'Initialize-AsyncEngine','Initialize-DomeniaPresentation','Get-DomeniaStandardLoginXaml','Invoke-DomeniaSelfTest'})
 ck('Only one new core function',set(currentf)-set(rows['CoreFunctions'])=={'Assert-DomeniaWorkerRegistry'})
 for rel,value in rows['UnchangedRuntime'].items():ck('Runtime preserved: '+rel,sha((ROOT/rel).read_bytes())==value,'Hash')
 login=literals(fn('Get-DomeniaStandardLoginXaml'))[0];tree=ET.fromstring(login)
 ns='{http://schemas.microsoft.com/winfx/2006/xaml/presentation}';xx='{http://schemas.microsoft.com/winfx/2006/xaml}'
 names={e.get(xx+'Name'):e for e in tree.iter() if e.get(xx+'Name')};parents={c:p for p in tree.iter() for c in p}
 ck('Root geometry from FILPRO',all(tree.get(k)==v for k,v in {'Width':'480','MinWidth':'340','SizeToContent':'Height','ResizeMode':'NoResize','FontFamily':'Segoe UI'}.items()),'XML')
 ck('Domenia branding, no Filpro runtime/window text',tree.get('Title')=='Domenia · Connexion' and 'FILPRO' not in login,'XML')
 for name in rows['LoginControlNames']:
  ck('Existing login control retained: '+name,name in names,'XML')
 ck('Separate header/form/actions grid rows',names['LoginHeader'].get('Grid.Row')=='0' and names['LoginFormScroll'].get('Grid.Row')=='1' and names['LoginActions'].get('Grid.Row')=='2','XML')
 ck('Only form scrolls, not authentication buttons',parents[names['LoginFormScroll']]==parents[names['LoginActions']],'XML')
 ck('FILPRO card geometry',names['PanelLogin'].get('Margin')=='16' and names['PanelLogin'].get('Padding')=='20','XML')
 for name in ['TxtLogin','PwdLogin']:
  ck('FILPRO 40-unit field: '+name,names[name].get('MinHeight')=='40' and names[name].get('Padding')=='11,7','XML')
 ck('Actual FILPRO templates reused',len(tree.findall('.//'+ns+'Grid.Resources/'+ns+'Style'))==12,'XML')
 source_styles=ET.parse(ROOT/'wad/docs/reference-filpro/Controls.xaml').getroot()
 original_styles={(e.get(xx+'Key') or e.get('TargetType')):e for e in source_styles if e.tag==ns+'Style'}
 remap={'BgWindow':'DomeniaBootWindow','BgCard':'DomeniaBootSurface','FgText':'DomeniaBootText','FgMuted':'DomeniaBootMuted','ClrBorder':'DomeniaBootBorder','BgInput':'DomeniaBootInput','BtnFg':'DomeniaBootButtonText','BtnBg':'DomeniaBootButton','BtnBorder':'DomeniaBootBorder','AddBg':'DomeniaBootAccent','FgAccent':'DomeniaBootAccentText','WarnFg':'DomeniaBootWarning','ErrFg':'DomeniaBootError','ErrBg':'DomeniaBootSurface','ErrBorder':'DomeniaBootError','SelBg':'DomeniaBootAccent'}
 def normalize(e,translate=False):
  attributes=[]
  for k,v in sorted(e.attrib.items()):
   if translate:
    for a,b in remap.items():v=v.replace('{DynamicResource '+a+'}','{DynamicResource '+b+'}')
   attributes.append((k,v))
  return (e.tag,tuple(attributes),(e.text or '').strip(),tuple(normalize(c,translate) for c in e))
 for style in tree.findall('.//'+ns+'Grid.Resources/'+ns+'Style'):
  key=style.get(xx+'Key') or style.get('TargetType')
  ck('Exact reference style: '+key,normalize(style)==normalize(original_styles[key],True),'XML reference')

 ck('Password helper controls remain hidden',parents[names['TxtLoginPasswordVisible']].get('Visibility')=='Collapsed','XML')
 ck('Password not read into tooltip',all(not re.search(r'\{Binding[^}]*(Text|Password)',str(names[n].get('ToolTip'))) for n in ['PwdLogin','TxtLoginPasswordVisible']),'XML')
 ck('SSO and cancel semantics retained',names['BtnWindowsLogin'].get('Content')=='Utiliser mon compte Windows' and names['BtnCancel'].get('IsCancel')=='True','XML')
 ck('Theme and CAPS retained','BtnSuiteLoginTheme' in names and 'LblSuiteCapsLock' in names,'XML')
 ck('Idle diagnostics not expanded',names['UxLoginDiagnostics'].get('IsExpanded')=='False' and names['UxLoginDiagnostics'].find('.//'+ns+'Setter[@Value="Collapsed"]') is not None,'XML')
 ck('Feedback scroll height bounded to 60',names['UxLoginFeedback'].find(ns+'ScrollViewer').get('MaxHeight')=='60','XML')
 dynamic=set(re.findall(r'\{DynamicResource (\w+)\}',login));valid={'DomeniaBoot'+k for k in ['Window','Surface','Input','Text','Muted','Border','Button','ButtonText','Accent','AccentText','OnAccent','Error','Warning','Success']}
 ck('No unresolved dynamic theme reference',not dynamic-valid,'XML')
 namedkeys={e.get(xx+'Key') for e in tree.iter() if e.get(xx+'Key')}
 ck('No unresolved named static reference',not(set(re.findall(r'\{StaticResource (\w+)\}',login))-namedkeys),'XML')
 for scope in tree.iter():
  if scope.tag.endswith('.Resources'):
   ks=[e.get(xx+'Key',e.get('TargetType','')) for e in scope if e.tag==ns+'Style' or e.get(xx+'Key')]
   ck('No duplicate resource keys in '+scope.tag,len(ks)==len(set(ks)),'XML')
 for name,e in names.items():
  if e.tag.rsplit('}',1)[-1] in ['Button','TextBox','PasswordBox','CheckBox','Expander','ProgressBar']:
   ck('Accessible help: '+name,bool(e.get('ToolTip') and e.get('AutomationProperties.HelpText') and e.get('ToolTipService.ShowOnDisabled')=='True'),'XML')
 for p in [ROOT/'wad/Domenia-Core.ps1',ROOT/'wad/modules/Domenia-UX.UI.ps1',ROOT/'wad/tests/Test-DomeniaStartupLogin.ps1']:
  ck('Lexical delimiters: '+p.name,not mask_ps(text(p))[1],'Lexical, not native parser')
 tests=text(ROOT/'wad/tests/Test-DomeniaStartupLogin.ps1');installer=text(ROOT/'INSTALLER-MISE-A-JOUR.ps1')
 count=len(re.findall("^    Case '",tests,re.M))+2*len(re.findall('^            Case ',tests,re.M))
 ck('44 substantive Windows scenarios declared',count==44 and '$expectedCases=44' in tests)
 ck('Native tests call exact initializer, not a copy of its rule','Initialize-AsyncEngine' in tests and 'Pump-FixtureDispatcher 500' in tests and '55/54' in tests)
 ck('Native tests reject partial completion','Complete=($script:Checks.Count -eq $expectedCases -and $failed.Count -eq 0)' in tests)
 ck('Installer gates on new tests before copying',installer.index('Test-DomeniaStartupLogin.ps1')<installer.index('Copy-CodeAtomically $from $to') and "'Test-DomeniaStartupLogin.ps1','Test-DomeniaModules.ps1'" in installer)
 ck('Package builder verifies workers/fingerprint before assembly','update_worker_contracts.py' in text(ROOT/'tools/build_packages.py'))
 ck('Release tool tracks whole-map fingerprint','RegistryFingerprint' in text(ROOT/'tools/update_worker_contracts.py'))
 bad=[c for c in checks if not c['Passed']]
 report={'Build':'2026.10.01-DOMENIA-1.0-RC1.5-BOOTLOGIN','Passed':len(checks)-len(bad),'Failed':len(bad),'Environment':'Linux Python source/XML/hash checks','PowerShellExecuted':False,'WpfExecuted':False,'LiveADExecuted':False,'Checks':checks,'ChangedCoreFunctions':changed,'NewFunction':'Assert-DomeniaWorkerRegistry','RegistryFingerprint':expected}
 args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
 print(json.dumps({k:v for k,v in report.items() if k!='Checks'},ensure_ascii=False,indent=2))
 for b in bad:print('FAIL',b)
 return bool(bad)
if __name__=='__main__':sys.exit(main())
