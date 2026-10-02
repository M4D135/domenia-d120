"""Offline, reproducible x64 launcher build using clang and lld-link; no NuGet/download."""
from pathlib import Path
import subprocess, tempfile, shutil, struct, json, hashlib
root=Path(__file__).resolve().parent
out=root.parent.parent/'Domenia.exe'
clang=shutil.which('clang');lld=shutil.which('lld-link')
if not clang or not lld:raise SystemExit('clang and lld-link are required only for rebuilding.')
# Windows .res file, built directly to avoid a platform SDK for the optional launcher.
def res_entry(kind,ident,data):
    name=struct.pack('<HHHH',0xffff,kind,0xffff,ident)
    header=struct.pack('<II',len(data),32)+name+struct.pack('<IHHII',0,0x1030,0x409,0,0)
    return header+data+b'\x00'*((-len(data))%4)
res=res_entry(0,0,b'')
ico=root.parent.parent/'wad'/'Domenia.ico'
if ico.exists():
    data=ico.read_bytes();count=struct.unpack_from('<H',data,4)[0];grp=data[:6]
    for i in range(count):
        entry=data[6+16*i:22+16*i];size,offset=struct.unpack_from('<II',entry,8)
        res+=res_entry(3,i+1,data[offset:offset+size]);grp+=entry[:12]+struct.pack('<H',i+1)
    res+=res_entry(14,1,grp)
manifest=b'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0"><assemblyIdentity version="1.0.0.1" processorArchitecture="amd64" name="Domenia.Launcher" type="win32"/><trustInfo xmlns="urn:schemas-microsoft-com:asm.v3"><security><requestedPrivileges><requestedExecutionLevel level="asInvoker" uiAccess="false"/></requestedPrivileges></security></trustInfo><application xmlns="urn:schemas-microsoft-com:asm.v3"><windowsSettings><dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true</dpiAware></windowsSettings></application></assembly>'''
res+=res_entry(24,1,manifest)
def block(key,value=b'',children=b'',typ=0,vlen=None):
    head=struct.pack('<HHH',0,(len(value)//2 if typ else len(value)) if vlen is None else vlen,typ)+(key+'\0').encode('utf-16le')
    head+=b'\0'*((-len(head))%4)
    head+=value
    head+=b'\0'*((-len(head))%4)
    head+=children
    return struct.pack('<H',len(head))+head[2:]
strings=b''.join(block(k,(v+'\0').encode('utf-16le'),typ=1) for k,v in {
 'CompanyName':'Domenia Project','FileDescription':'Domenia launcher','FileVersion':'1.0.0.1',
 'InternalName':'Domenia','OriginalFilename':'Domenia.exe','ProductName':'Domenia','ProductVersion':'1.0 RC1'}.items())
fixed=struct.pack('<13I',0xFEEF04BD,0x10000,0x10000,1,0x10000,1,0x3f,0,0x40004,1,0,0,0)
sfi=block('StringFileInfo',children=block('040904B0',children=strings,typ=1),typ=1)
vfi=block('VarFileInfo',children=block('Translation',struct.pack('<HH',0x409,1200)))
res+=res_entry(16,1,block('VS_VERSION_INFO',fixed,sfi+vfi))
with tempfile.TemporaryDirectory() as d:
    d=Path(d)
    for lib,names in {'kernel32':['GetModuleFileNameW','GetSystemDirectoryW','GetFileAttributesW','GetCommandLineW','CreateProcessW','WaitForSingleObject','GetExitCodeProcess','CloseHandle','CreateFileW','GetLastError','ExitProcess'], 'user32':['MessageBoxW']}.items():
        (d/(lib+'.def')).write_text('LIBRARY '+lib+'.dll\nEXPORTS\n'+'\n'.join(names)+'\n')
        subprocess.run([lld,'/lib','/machine:x64','/def:'+str(d/(lib+'.def')),'/out:'+str(d/(lib+'.lib'))],check=True)
    (d/'app.res').write_bytes(res)
    subprocess.run([clang,'--target=x86_64-pc-windows-msvc','-Oz','-ffreestanding','-fno-stack-protector','-c',str(root/'launcher.c'),'-o',str(d/'app.obj')],check=True)
    subprocess.run([lld,'/machine:x64','/entry:mainCRTStartup','/subsystem:windows','/nodefaultlib','/dynamicbase','/nxcompat','/highentropyva','/timestamp:0','/manifest:no',str(d/'app.obj'),str(d/'app.res'),str(d/'kernel32.lib'),str(d/'user32.lib'),'/out:'+str(out)],check=True)
print(json.dumps({'file':str(out),'sha256':hashlib.sha256(out.read_bytes()).hexdigest(),'bytes':out.stat().st_size,'executed_on_windows':False}))
