#!/usr/bin/env python3
"""R1.1 offline source/XML/contrast checks, NOT a PowerShell or WPF runtime test.
Reads the actual literal palettes and XAML. Composition mirrors resource injection.
Native Windows tests are supplied separately in Test-DomeniaTheme.ps1.
"""
from __future__ import annotations
from pathlib import Path
import argparse,json,re,sys,xml.etree.ElementTree as ET
from powershell_lex import functions,mask_ps

WPF='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
X='http://schemas.microsoft.com/winfx/2006/xaml'

def contrast(fg,bg):
    def lum(s):
        channels=[int(s[i:i+2],16)/255 for i in (1,3,5)]
        return sum((c/12.92 if c<=0.04045 else ((c+0.055)/1.055)**2.4)*w for c,w in zip(channels,(0.2126,0.7152,0.0722)))
    a,b=sorted((lum(fg),lum(bg)))
    return (b+0.05)/(a+0.05)

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2])
    ap.add_argument('--report',type=Path,default=Path('/tmp/domenia-theme-audit.json'))
    args=ap.parse_args();root=args.root.resolve()
    s=(root/'wad/Domenia-Core.ps1').read_text(encoding='utf-8-sig');fs=functions(s)
    def fn(n):a,b=fs[n][0];return s[a:b]
    def literal(n,quote='"'):
        m=re.search('@'+re.escape(quote)+r'\n(.*?)\n'+re.escape(quote)+'@',fn(n),re.S)
        assert m,n;return m[1]
    tables=re.findall(r'return \[ordered\]@\{(.*?)\n    \}',fn('Get-DomeniaBootThemePalette'),re.S)
    # Do not guess palettes: this exact literal structure is part of the audit contract.
    assert len(tables)==2,'Expected exactly Dark and Light tables'
    palettes={theme:dict(re.findall(r'(\w+)\s*=\s*"(#[A-F0-9]{6})"',body)) for theme,body in zip(('Dark','Light'),tables)}
    styles=literal('Get-DomeniaBootThemeResources',"'")
    results=[];observations={}
    def require(test,msg='Assertion failed'):
        if not test:raise AssertionError(msg)
    def check(name,body):
        try:detail=body();status='PASS'
        except Exception as e:detail=str(e);status='FAIL'
        results.append({'Name':name,'Status':status,'Detail':detail or ''})
        print(status,name,detail or '')
    def delimiter_check():
        masked,issues=mask_ps(s);require(not issues,str(issues));stack=[]
        pairs={')':'(',']':'[','}':'{'}
        for i,c in enumerate(masked):
            if c in '([{':stack.append(c)
            elif c in ')]}':require(stack and stack.pop()==pairs[c],f'Delimiter at {i}')
        require(not stack)
    check('Core : lexique et delimiteurs (pas un parseur natif)',delimiter_check)
    def pref_guards():
        resolver=fn('Get-DomeniaStoredTheme');loader=fn('Load-DomeniaSettings')
        require('$theme -notin @("Light","Dark")' in resolver)
        require('if ($theme -eq "Light")' not in resolver)
        require('$settings["Theme"] = Get-DomeniaStoredTheme' in loader)
        require('$settings["Theme"] = $legacyTheme' not in loader)
        require('Save-DomeniaSettings -Immediate' in fn('Save-DomeniaTheme'))
        require('$script:BootTheme = $Theme' in fn('Save-DomeniaTheme'))
        require('if ($Persist) { Save-DomeniaTheme -Theme $Theme }' in fn('Apply-DomeniaTheme'))
        require(fn('Toggle-DomeniaTheme').count('-Persist')==2)
        require('Apply-DomeniaTheme -Theme (Get-DomeniaStoredTheme)' in fn('Load-XamlWindow'))
        require('Apply-DomeniaTheme -Theme $script:CurrentTheme' in fn('Initialize-DomeniaPresentation'))
    check('Source : priorite JSON, choix commun, sauvegarde immediate et restauration sans ecriture',pref_guards)
    def callback_guards():
        text='\n'.join(fn(n) for n in fs if 'FastLogin' in n or n=='Show-LoginWindow')
        require(not re.search(r'\.Error\.Foreground\s*=\s*"#',text))
        require(text.count('Get-DomeniaBootStatusColor')>=10)
    check('Source : messages dynamiques du login sans ancienne police foncee',callback_guards)
    def boot_factory():
        require('Get-DomeniaStartupXaml' in fn('New-DomeniaStartupWindow'))
        require('Factory=\'Get-DomeniaStartupXaml\'' in fn('Invoke-DomeniaSelfTest'))
        require('Get-DomeniaBootThemeResources -Theme $Theme' in fn('Convert-DomeniaXamlToBootTheme'))
    check('Source : moniteur et autotest utilisent le meme XAML',boot_factory)

    for theme,p in palettes.items():
        def semantic_contrast(p=p,theme=theme):
            pairs=[(fg,bg) for fg in ('Text','Muted','AccentText','Error','Warning','Success') for bg in ('Window','Surface','Input')]
            pairs.extend([('ButtonText','Button'),('OnAccent','Accent')])
            values=[(contrast(p[f],p[b]),f,b) for f,b in pairs]
            minimum=min(values);require(minimum[0]>=4.5,str(minimum))
            observations[theme+'MinimumSemanticContrast']=round(minimum[0],3)
            return f'minimum {minimum[0]:.2f}:1 ({minimum[1]}/{minimum[2]})'
        check(theme+' : contraste des 20 couples de texte de la palette',semantic_contrast)
        for factory in ('Get-LoginXamlLegacy','Get-DomeniaStandardLoginXaml','Get-DomeniaDebugLoginXaml','Get-DomeniaStartupXaml'):
            raw=literal(factory)
            brushes='\n'.join(f'<SolidColorBrush x:Key="DomeniaBoot{k}" Color="{v}"/>' for k,v in p.items())
            xml=raw.replace('<Window.Resources>','<Window.Resources>\n'+brushes+'\n'+styles)
            def validate(xml=xml,factory=factory,theme=theme,p=p):
                document=ET.fromstring(xml);resources=document.find('{'+WPF+'}Window.Resources')
                require(resources is not None)
                resource_map={}
                for item in resources:
                    key=item.attrib.get('{'+X+'}Key')
                    if key is None and item.tag.endswith('}Style'):key='Type:'+item.attrib['TargetType']
                    require(key is not None,'Unkeyed resource')
                    require(key not in resource_map,'Duplicate resource '+key)
                    resource_map[key]=item
                names=[item.attrib['{'+X+'}Name'] for item in document.iter() if '{'+X+'}Name' in item.attrib]
                require(len(names)==len(set(names)),'Duplicate x:Name')
                for key in re.findall(r'\{(?:Static|Dynamic)Resource\s+([^}]+)\}',xml):
                    require(key in resource_map,'Missing '+key)
                def style_values(style,seen=()):
                    base=style.attrib.get('BasedOn');vals={}
                    if base:
                        key=re.fullmatch(r'\{StaticResource ([^}]+)\}',base)[1]
                        require(key not in seen,'Style cycle')
                        vals.update(style_values(resource_map[key],seen+(key,)))
                        require(style.attrib['TargetType']==resource_map[key].attrib['TargetType'],'Invalid BasedOn type')
                    for setter in style.findall('{'+WPF+'}Setter'):
                        if 'Value' in setter.attrib:vals[setter.attrib['Property']]=setter.attrib['Value']
                    return vals
                for item in resources:
                    if item.tag.endswith('}Style'):style_values(item)
                def resolve(value):
                    if not value:return None
                    if value.startswith('#'):return value
                    if value=='Transparent':return None
                    match=re.fullmatch(r'\{(?:Static|Dynamic)Resource ([^}]+)\}',value)
                    require(match is not None,'Unexpected brush '+value)
                    return resource_map[match[1]].attrib['Color']
                parent_map={child:parent for parent in document.iter() for child in parent}
                def effective(item,prop):
                    if prop in item.attrib:return resolve(item.attrib[prop])
                    key='Type:'+item.tag.split('}')[-1]
                    if 'Style' in item.attrib:
                        key=re.fullmatch(r'\{StaticResource ([^}]+)\}',item.attrib['Style'])[1]
                    if key in resource_map:
                        value=style_values(resource_map[key]).get(prop)
                        if value:return resolve(value)
                    if prop=='Foreground' and item in parent_map:return effective(parent_map[item],prop)
                    return None
                def bg(item):
                    val=effective(item,'Background')
                    if val:return val
                    return bg(parent_map[item]) if item in parent_map else p['Window']
                measured=[]
                for item in document.iter():
                    typ=item.tag.split('}')[-1]
                    if typ not in ('TextBlock','TextBox','PasswordBox','Button','CheckBox','Run'):continue
                    # Exclude template internals, whose colours are bound to the control.
                    parent=item;inside_resources=False
                    while parent in parent_map:
                        parent=parent_map[parent]
                        if parent is resources:inside_resources=True;break
                    if inside_resources:continue
                    f=effective(item,'Foreground');b=bg(item)
                    require(f is not None,'No explicit text brush '+typ)
                    ratio=contrast(f,b);measured.append(ratio)
                    name=item.attrib.get('{'+X+'}Name',typ)
                    require(ratio>=4.5,f'{name}: {f}/{b} = {ratio:.2f}:1')
                require(measured)
                return f'{len(measured)} textes/champs/boutons ; minimum {min(measured):.2f}:1 ; ressources resolues statiquement'
            check(theme+' : '+factory+' (XML, ressources, styles, contraste)',validate)
    report={'Build':re.search(r'\$script:MasterBuild\s*=\s*[\'"]([^\'"]+)', s)[1],'Environment':'Linux/Python, analyse source et XML uniquement',
            'NativePowerShellExecuted':False,'WpfExecuted':False,'ActiveDirectoryExecuted':False,
            'Passed':sum(r['Status']=='PASS' for r in results),'Failed':sum(r['Status']=='FAIL' for r in results),
            'Observations':observations,'Results':results}
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(f"{report['Passed']} PASS / {report['Failed']} FAIL")
    return int(report['Failed']!=0)
if __name__=='__main__':raise SystemExit(main())
