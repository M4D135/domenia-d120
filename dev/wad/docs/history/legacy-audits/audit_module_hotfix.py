#!/usr/bin/env python3
"""RC1.2 import graph and package regressions. Static/Python only, NOT WPF execution."""
from pathlib import Path
import argparse, hashlib, json, re, sys, zipfile, difflib
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from audit_candidate import balanced, functions, getfunc
BUILD='2026.10.01-DOMENIA-1.0-RC1.2-MODULES'

def sha(v):return hashlib.sha256(v.encode() if isinstance(v,str) else v).hexdigest().upper()
def text(p):return p.read_text('utf-8-sig')
def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--baseline-dev',type=Path,required=True);ap.add_argument('--report',type=Path,required=True)
    a=ap.parse_args();checks=[]
    def ck(name,predicate):
        try:
            value=predicate() if callable(predicate) else predicate
            assert value is None or bool(value),name
            checks.append(dict(Name=name,Passed=True))
        except Exception as e:checks.append(dict(Name=name,Passed=False,Detail=str(e)))
    with zipfile.ZipFile(a.baseline_dev) as z:
        ck('Baseline archive CRC',z.testzip() is None)
        baseline={n[4:]:z.read(n) for n in z.namelist() if n.startswith('dev/') and not n.endswith('/')}
    old=baseline['wad/Domenia-Core.ps1'].decode('utf-8-sig').replace('\r\n','\n')
    core=text(ROOT/'wad/Domenia-Core.ps1');loader=text(ROOT/'wad/Domenia-Modules.ps1');start=text(ROOT/'wad/Domenia-Start.ps1')
    # Fixed declarations, rather than glob-based runtime loading.
    plan=[]
    for m in re.finditer(r"\[pscustomobject\]@\{ File='([^']+)'; DotSource=\$(true|false); Functions=@\((.*?)\) \}",loader,re.S):
        plan.append(dict(File=m[1],DotSource=m[2]=='true',Functions=re.findall(r"'([A-Za-z][A-Za-z0-9-]+)'",m[3])))
    files={p.name:p for p in (ROOT/'wad/modules').glob('*.ps1')}
    ck('20 declared script modules',len(plan)==20)
    ck('No duplicate module declarations',len({x['File'] for x in plan})==len(plan))
    ck('All shipped script modules included',set(files)=={x['File'] for x in plan})
    ck('209 function exports explicitly checked',sum(len(x['Functions']) for x in plan)==209)
    ck('18 direct imports and 2 nested UX dependencies',sum(x['DotSource'] for x in plan)==18)
    for spec in plan:
        path=files[spec['File']];expected=set(functions(text(path)))
        ck('Exports match definitions: '+spec['File'],set(spec['Functions'])==expected)
        ck('Module bytes unchanged: '+spec['File'],path.read_bytes()==baseline['wad/modules/'+spec['File']])
    begin=old.index('    # Fixed local modules;');end=old.index('    Load-AppConfig | Out-Null',begin)
    imported=set(re.findall(r"'modules\\([^']+\.ps1)'",old[begin:end]))
    nested=set(re.findall(r"\. \(Join-Path \$PSScriptRoot '([^']+\.ps1)'\)",text(files['Domenia-UX.UI.ps1'])))
    missing=set(files)-(imported|nested)
    ck('Reproduce omission in RC1.1 import graph',missing=={'Domenia-Reconcile.UI.ps1','Domenia-Dossier.Model.ps1','Domenia-Dossier.UI.ps1'})
    for name in missing:ck('Omitted module now directly loaded: '+name,next(x['DotSource'] for x in plan if x['File']==name))
    coreboot=core[core.index('# Main autoritaire'):]
    ck('Core dot-sources shared entry at script scope',". (Join-Path $PSScriptRoot 'Domenia-Modules.ps1')" in coreboot)
    ck('Validation occurs before configuration/data and login',coreboot.index("'Domenia-Modules.ps1'")<coreboot.index('Load-AppConfig')<coreboot.index('Show-LoginWindow'))
    ck('Module functions stay in caller scope','. $domeniaModulePath' in loader and '& $domeniaModulePath' not in loader)
    ck('Function existence and actual source checked',"'Function:\\' + $name" in loader and 'DOMENIA_MODULE_ORIGIN' in loader and '$command.ScriptBlock.File' in loader)
    ck('Missing files checked before any imports',loader.index('DOMENIA_MODULE_MISSING')<loader.index('. $domeniaModulePath'))
    ck('Syntax checked before any imports',loader.index('Parser]::ParseFile')<loader.index('. $domeniaModulePath'))
    ck('Module import failures retain inner exception','DOMENIA_MODULE_IMPORT' in loader and '$_.Exception)' in loader)
    ck('Not a dynamic plugin discovery',not any(t in loader for t in ['Get-ChildItem','Invoke-Expression','Invoke-WebRequest']))
    ck('No code starts windows or timers in loader',not any(t in loader for t in ['.ShowDialog(','.Add_Tick(','.Start()','Start-UiTask -']))
    ck('CheckOnly exercises the same shared loader',". $BootstrapPath" in start and "Join-Path $PSScriptRoot 'Domenia-Modules.ps1'" in start)
    ck('Runtime startup verifies all 20 module paths',all("'wad/modules/"+s['File']+"'" in start for s in plan))
    ck('Runtime startup does not require development helpers','wad/tests' not in start and 'TESTER-' not in start and 'APERCU-' not in start)
    newfunc=functions(core);oldfunc=functions(old)
    ck('All core function names preserved',set(newfunc)==set(oldfunc))
    changed=[n for n in oldfunc if getfunc(old,n)!=getfunc(core,n)]
    ck('Only core presentation function changed',changed==['Initialize-DomeniaPresentation'])
    fn=getfunc(core,'Initialize-DomeniaPresentation')
    ck('Live initialization precedes reconciliation',fn.index('Initialize-DomeniaLive')<fn.index('Initialize-DomeniaReconcile'))
    common=lambda t:'\n'.join(re.findall(r"(?ms)^\$script:WorkerCommon (?:=|\+=) @'\n(.*?)\n'@",t))
    ck('Common worker byte content unchanged',common(old)==common(core))
    ck('Operation contracts unchanged',(ROOT/'tools/operation-contracts.json').read_bytes()==baseline['tools/operation-contracts.json'])
    ck('ACL-only fix retained',getfunc(old,'Initialize-DomeniaDataStore')==getfunc(core,'Initialize-DomeniaDataStore'))
    for f in ['Domenia.exe','wad/Domenia.config.json','wad/modules/Domenia-Receipts.Worker.ps1','wad/Support/DEBLOQUER_TOUT.cmd','wad/Support/Debloquer-Paquet.ps1','wad/Support/.lifecycle.lock']:
        ck('Preserved file: '+f,(ROOT/f).read_bytes()==baseline[f])
    for f in ['wad/Domenia-Core.ps1','wad/Domenia-Start.ps1','wad/Domenia-Modules.ps1','wad/tests/Test-DomeniaModules.ps1','INSTALLER-MISE-A-JOUR.ps1']:
        ck('Approximate lexical balance (not native parser): '+f,lambda f=f:balanced(text(ROOT/f)))
    native=text(ROOT/'wad/tests/Test-DomeniaModules.ps1')
    for label,part in [('fresh runspace','RunspaceFactory]::CreateRunspace'),('real entry point',". (Join-Path $Wad 'Domenia-Modules.ps1')"),('reference regression','CommandNotFound'),('missing exports','DOMENIA_MODULE_EXPORT'),('scope error','portee'),('function origin','ForeignOrigin'),('module syntax','DOMENIA_MODULE_PARSE'),('no implicit plugin','Extra.ps1'),('WPF timer lifetime','TimerStarted'),('skipped not PASS',"Status='Skipped'")]:
        ck('Native regression covers '+label,part in native)
    installer=text(ROOT/'INSTALLER-MISE-A-JOUR.ps1')
    ck('Module tests run before backup/copy',installer.index("'Test-DomeniaModules.ps1'")<installer.index('# Backup all original code'))
    ck('Installer refuses incomplete Windows module suite',"-not $result.Complete" in installer and '[int]$result.Skipped -ne 0' in installer)
    ck('New loader belongs to runtime manifest generation',"'Domenia-Modules.ps1'" in text(ROOT/'tools/build_packages.py'))
    ck('Same Support placement preserved','wad/Support/DEBLOQUER_TOUT.cmd' in text(ROOT/'tools/build_packages.py'))
    report=dict(Build=BUILD,BaselineSha256=sha(a.baseline_dev.read_bytes()),BaselineOmittedModules=sorted(missing),Modules=len(plan),ExportedFunctions=sum(len(x['Functions']) for x in plan),CoreFunctions=len(newfunc),CoreFunctionsChanged=changed,UnchangedCoreFunctions=len(newfunc)-len(changed),AllExistingModulesUnchanged=True,PowerShellExecuted=False,WindowsPowerShellExecuted=False,WpfExecuted=False,ADExecuted=False,Passed=sum(c['Passed'] for c in checks),Failed=sum(not c['Passed'] for c in checks),Checks=checks)
    a.report.parent.mkdir(parents=True,exist_ok=True);a.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n','utf-8')
    patch=''.join(difflib.unified_diff(old.splitlines(True),core.splitlines(True),fromfile='RC1.1/wad/Domenia-Core.ps1',tofile='RC1.2/wad/Domenia-Core.ps1'))
    (ROOT/'wad/docs/RC1.2-Modules.patch').write_text(patch,'utf-8')
    print(json.dumps({k:v for k,v in report.items() if k!='Checks'},indent=2))
    for c in checks:
        if not c['Passed']: print('FAIL:',c)
    return int(report['Failed']>0)
if __name__=='__main__':raise SystemExit(main())
