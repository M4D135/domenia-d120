from pathlib import Path
import sys,re,json,hashlib,collections
from lxml import etree as E
import argparse
ap=argparse.ArgumentParser(description='Static UI audit only. Requires lxml and the extracted R1.9 baseline; no PowerShell/WPF/AD execution.')
ap.add_argument('--baseline-root',type=Path,required=True)
ap.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2])
args=ap.parse_args();base=args.baseline_root;root=args.root
sys.path.insert(0,str(base/'wad/tests'))
from powershell_lex import functions,mask_ps
from audit_ui import assert_scoped_names,window_controls
import xml.etree.ElementTree as ET
checks=[]
def ck(n,condition,detail=''):
 try:
  v=condition() if callable(condition) else condition
  assert (v is not False) if callable(condition) else bool(v),detail
  checks.append({'Name':n,'Passed':True,'Detail':detail})
 except Exception as e: checks.append({'Name':n,'Passed':False,'Detail':str(e)});print('FAIL',n,str(e))
def text(p):return p.read_text(encoding='utf-8-sig')
def sha(b):return hashlib.sha256(b.encode() if isinstance(b,str) else b).hexdigest()
s=text(root/'wad/Domenia-Core.ps1');b=text(base/'wad/Domenia-Core.ps1');fs=functions(s);bf=functions(b)
def f(n):return s[slice(*fs[n][0])]
changes=[n for n in bf if n not in fs or b[slice(*bf[n][0])]!=f(n)]
ck('All core functions retained, no new duplicates',set(fs)==set(bf) and all(len(v)==1 for v in fs.values()))
ck('Only five presentation/settings core functions changed',set(changes)=={'Get-DomeniaDefaultSettings','Get-MainXaml','Update-DomeniaSearchScopeUi','Get-DomeniaStandardLoginXaml','Show-LoginWindow'},str(changes))
for name in ['Get-DomeniaWorkerOperationHashes','Get-DomeniaAuthWorkerCode','Start-DomeniaFastLoginAttempt','Update-DomeniaFastLoginAttempt','Complete-DomeniaFastLoginSuccess','New-DomeniaFastLoginSession','Start-DomeniaLoginAuthRunspace','Get-DomeniaSearchScope','Invoke-GlobalSearch','Invalidate-DomeniaSearchResults','Test-DomeniaSearchStateCurrent','Set-SelectedBranch','Reset-DomeniaSearchScope','Wire-Events']:
 if name in fs: ck('Preserved engine '+name,b[slice(*bf[name][0])]==f(name))
reg=dict(re.findall(r'(\w+)\s*=\s*"([A-F0-9]{64})"',f('Get-DomeniaWorkerOperationHashes')))
literals={sha(m[1]).upper() for m in re.finditer(r"@'\n(.*?)\n'@",s,re.S)}
ck('All 45 pinned worker bodies unchanged and resolvable',len(reg)==45 and set(reg.values())<=literals)
for rel in ['Domenia.exe','Domenia.ps1','wad/PsExec.exe','wad/Microsoft.ActiveDirectory.Management.dll','wad/ActiveDirectoryPowerShellResources.dll','wad/modules/Domenia-Support.Model.ps1','wad/modules/Domenia-Support.UI.ps1','wad/modules/Domenia-Support.xaml','wad/Domenia.config.json']:
 ck('Unchanged '+rel,(base/rel).read_bytes()==(root/rel).read_bytes())
# Lexical scanning is approximate. Normalize typographic quote characters as PS recognizes them.
def lex(s):
 m,err=mask_ps(s.replace('\u2018',"'").replace('\u2019',"'").replace('\u201c','"').replace('\u201d','"'))
 assert not err,str(err)
 stack=[];opp={')':'(',']':'[','}':'{'}
 for c in m:
  if c in '([{':stack.append(c)
  elif c in opp:assert stack and stack.pop()==opp[c], 'Mismatched delimiter'
 assert not stack,'Unclosed delimiter'
for rel in ['wad/Domenia-Core.ps1','wad/modules/Domenia-UX.UI.ps1','wad/maintenance/Preview-DomeniaUi.ps1','wad/maintenance/Preview-DomeniaLogin.ps1','wad/tests/Test-DomeniaCompactUi.ps1','INSTALLER-MISE-A-JOUR.ps1']:
 p=root/rel;ck('Lexical delimiters (not native parse) '+rel,lambda p=p:lex(text(p)))
 ck('Windows Unicode BOM '+rel,p.read_bytes().startswith(b'\xef\xbb\xbf'))
for p in root.glob('*.cmd'):
 if p.name in ['APERCU-CONNEXION.cmd','TESTER-ERGONOMIE.cmd']:
  ck('No accidental control character '+p.name,all(c>=32 or c in (10,13,9) for c in p.read_bytes()))
main=re.search(r'@"\n(.*?)\n"@',f('Get-MainXaml'),re.S)[1];er=ET.fromstring(main);r=E.fromstring(main.encode());cs=window_controls(er)
ns={'p':'http://schemas.microsoft.com/winfx/2006/xaml/presentation','x':'http://schemas.microsoft.com/winfx/2006/xaml'};namekey='{'+ns['x']+'}Name'
ck('Main XML with unique namescopes',lambda:assert_scoped_names(er))
oldxml=re.search(r'@"\n(.*?)\n"@',b[slice(*bf['Get-MainXaml'][0])],re.S)[1]
oldcs=window_controls(ET.fromstring(oldxml))
ck('All original main controls remain',set(oldcs)<=set(cs),str(len(oldcs)))
cat=json.loads(text(root/'wad/modules/Domenia-UX.help.json'));cats={i['Name']:i for i in cat}
ck('Unique static help names',len(cats)==len(cat))
for name in ['BtnUxSidebarToggle','BtnUxHelpClose','BtnUxCopyOuPath','UxOuPathDetails']:
 el=cs[name];ck('New control is catalogued and accessible '+name,name in cats and el.get('ToolTip') and el.get('ToolTipService.ShowOnDisabled')=='True' and el.get('AutomationProperties.HelpText'))
ck('Collapsible sidebar uses named column','UxNavColumn' in cs and cs['UxNavColumn'].get('Width')=='204')
for suffix in ['Home','Search','Object','Relations','Computer','Support','Accounts','Tools']:
 ck('Navigation route and icon retained '+suffix,cs['BtnUxNav'+suffix].get('Uid')==oldcs['BtnUxNav'+suffix].get('Uid') and all('UxNav'+k+suffix in cs for k in ['Label','Icon','Content']))
ck('Full DN no longer in a fixed-height field',cs['TxtBranchDn'].get('Height') is None and cs['TxtBranchDn'].get('MinHeight')=='64' and cs['TxtBranchDn'].get('MaxHeight')=='128' and cs['TxtBranchDn'].get('VerticalContentAlignment')=='Top')
ck('DN under collapsed details expander',cs['UxOuPathDetails'].get('IsExpanded')=='False' and 'TxtBranchDn' in {el.get(namekey) for el in cs['UxOuPathDetails'].iter()})
ck('Readable short OU label and ancestry','LblOuScopeName' in cs and 'LblOuScopePath' in cs and cs['LblOuScopeName'].get('TextWrapping')=='Wrap')
ck('Scope summary can trim without hiding full DN',cs['LblSearchScope'].get('TextTrimming')=='CharacterEllipsis')
ck('OU column still resizable',cs['SearchOuSplitter'].get('ResizeBehavior')=='PreviousAndNext' and cs['UxOuColumn'].get('MinWidth')=='230')
ck('OU and results remain in the same search page',{'TvDirectory','DgObjects','ChkSubtree','TxtBranchDn'}<={el.get(namekey) for el in cs['WsSearch'].iter()})
keys={e.get('{'+ns['x']+'}Key') for e in r.iter()};impl={e.get('TargetType') for e in r.iter() if E.QName(e).localname=='Style' and not e.get('{'+ns['x']+'}Key')}
refs=set(re.findall(r'\{StaticResource\s+(\{x:Type\s+\w+\}|[^{}]+)\}',main))
ck('Main static resource names resolve',all(v in keys or (v.startswith('{x:Type ') and v[8:-1] in impl) for v in refs))
ux=text(root/'wad/modules/Domenia-UX.UI.ps1');uf=functions(ux)
ck('No duplicate UX function',all(len(v)==1 for v in uf.values()))
for key in ['UxNavCollapsed','UxHelpVisible','UxHelpCompactOpen']:
 ck('Preference survives loader allowlist '+key,key in f('Get-DomeniaDefaultSettings') and ('Set-DomeniaSetting -Name \''+key+"'") in ux)
ck('Hidden help releases gutter','$workspaces.Margin=[Windows.Thickness]::new(0,0,[double]$plan.WorkspaceGap,0)' in ux)
ck('Toggle applies to both compact and expanded modes','$script:UxHelpCompactOpen=$script:UxHelpVisible' in ux)
ck('Collapse is not a permission change','IsEnabled=' not in ux[slice(*uf['Update-DomeniaUxSidebar'][0])] and '.Tag=' not in ux[slice(*uf['Update-DomeniaUxSidebar'][0])])
ck('Only display helper changes scope text','Update-DomeniaUxOuScope -Scope $scope' in f('Update-DomeniaSearchScopeUi') and '$script:SelectedBranchDn =' not in ux)
login=re.search(r'@"\n(.*?)\n"@',f('Get-DomeniaStandardLoginXaml'),re.S)[1];lr=E.fromstring(login.encode());lcs=window_controls(ET.fromstring(login))
ck('Login XML unique namescopes',lambda:assert_scoped_names(ET.fromstring(login)))
ck('Login simple and no maximize',lr.get('Width')=='460' and lr.get('ResizeMode')=='NoResize' and lr.get('SizeToContent')=='Height' and lr.get('Height') is None)
oldlogin=re.search(r'@"\n(.*?)\n"@',b[slice(*bf['Get-DomeniaStandardLoginXaml'][0])],re.S)[1];oldlc=window_controls(ET.fromstring(oldlogin))
ck('All old login controls remain',set(oldlc)<=set(lcs))
ck('Diagnostics present but collapsed',lcs['UxLoginDiagnostics'].get('IsExpanded')=='False' and {'BtnLoginLog','BtnCopyLoginDiag','TxtLoginTechnical'}<={e.get(namekey) for e in lcs['UxLoginDiagnostics'].iter()})
ck('Error and progress not allocated when empty','MultiDataTrigger' in login and 'Value="Collapsed"' in login and lcs['LblLoginError'].get('TextWrapping')=='Wrap')
ck('Login actions laid out like reference',lcs['BtnWindowsLogin'].get('Content')=='Utiliser mon compte Windows' and lcs['BtnLogin'].get('Grid.Column')=='2' and lcs['BtnCancel'].get('Content')=='Annuler')
ck('Input named parts retained',len(lr.xpath('//p:ScrollViewer[@x:Name="PART_ContentHost"]',namespaces=ns))==2)
ck('Boot-theme transform remains', 'Convert-DomeniaXamlToBootTheme -Xaml' in f('Get-DomeniaStandardLoginXaml'))
# Resource references plus boot resources.
boot=f('Get-DomeniaBootThemeResources');lk={e.get('{'+ns['x']+'}Key') for e in lr.iter()}|set(re.findall(r'x:Key="([^"{}]+)"',boot))
lrefs=set(re.findall(r'\{StaticResource\s+([^{}]+)\}',login));ck('Login static resource names resolve',lrefs<=lk,str(lrefs-lk))
for n in ['TxtLogin','PwdLogin','BtnLogin','BtnWindowsLogin','ChkRemember','UxLoginDiagnostics','BtnLoginLog','BtnCopyLoginDiag']:
 ck('Login help '+n,n in cats and bool(lcs[n].get('ToolTip')) and bool(lcs[n].get('AutomationProperties.HelpText')))
installer=text(root/'INSTALLER-MISE-A-JOUR.ps1')
ck('New tests before code replacement',installer.index('$compactTests=')<installer.index('$backupParent=') and installer.index('$loginView=')<installer.index('$backupParent='))
ck('Native test errors stop install', '$compactResult.Failed -ne 0' in installer and '$loginViewResult.Failed -ne 0' in installer)
count=len(re.findall(r'^Test-UiCase ',text(root/'wad/tests/Test-DomeniaCompactUi.ps1'),re.M))
ck('22 pure PowerShell display tests provided',count==22)
for p in [root/'wad/maintenance/Preview-DomeniaUi.ps1',root/'wad/maintenance/Preview-DomeniaLogin.ps1']:
 t=text(p);ck('Offline presentation-only preview '+p.name,'. $core' not in t and '& $core' not in t and 'FunctionDefinitionAst' in t)
# Computed contrast for the existing theme brushes used by the new login.
from audit_ui import contrast
palettes=re.findall(r'return \[ordered\]@\{(.*?)\}',f('Get-DomeniaBootThemePalette'),re.S)
for theme,raw in zip(['Dark','Light'],palettes):
    palette=dict(re.findall(r'(\w+)\s*=\s*"(#[0-9A-Fa-f]{6})"',raw))
    for fg,bg in [('Text','Input'),('Muted','Surface'),('ButtonText','Button'),('OnAccent','Accent'),('AccentText','Surface')]:
        ratio=contrast(palette[fg],palette[bg]);ck('Calculated login contrast '+theme+' '+fg+'/'+bg,ratio>=4.5,str(round(ratio,2)))
report={'Build':'2026.09.30-R1.10-COMPACT','Environment':'Linux / Python (no native PowerShell, WPF or domain test)','PowerShellExecuted':False,'WpfExecuted':False,'LiveADExecuted':False,'ChangedCoreFunctions':changes,'PreservedCoreFunctions':len(bf)-len(changes),'NativeNewTestsProvided':{'PureRules':22,'AdditionalMainWpf':9,'LoginWpf':18},'Passed':sum(c['Passed'] for c in checks),'Failed':sum(not c['Passed'] for c in checks),'Checks':checks}
(root/'wad/docs/AUDIT-ERGONOMIE-R1.10.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print('PASS',report['Passed'],'FAIL',report['Failed'],'preserved functions',report['PreservedCoreFunctions'])
raise SystemExit(bool(report['Failed']))
