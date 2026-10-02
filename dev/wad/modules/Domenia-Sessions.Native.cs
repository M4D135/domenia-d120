using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security;
using System.Security.Principal;
namespace Domenia.Sessions {
    public sealed class SessionRow {
        public int Id {get;set;} public string Station {get;set;} public string User {get;set;}
        public string Domain {get;set;} public string State {get;set;} public string Protocol {get;set;} public string Detail {get;set;}
    }
    public static class Reader {
        [StructLayout(LayoutKind.Sequential)] private struct WTS_SESSION_INFO { public int SessionId; public IntPtr Name; public int State; }
        [DllImport("wtsapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr WTSOpenServerW(string name);
        [DllImport("wtsapi32.dll")] static extern void WTSCloseServer(IntPtr server);
        [DllImport("wtsapi32.dll", SetLastError=true)] static extern bool WTSEnumerateSessionsW(IntPtr server,int reserved,int version,out IntPtr buffer,out int count);
        [DllImport("wtsapi32.dll", SetLastError=true)] static extern bool WTSQuerySessionInformationW(IntPtr server,int id,int info,out IntPtr buffer,out int size);
        [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr buffer);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool LogonUserW(string user,string domain,IntPtr password,int type,int provider,out IntPtr token);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        private static string Text(IntPtr server,int id,int info,ref int error) {
            IntPtr p=IntPtr.Zero; int length=0;
            try { if(!WTSQuerySessionInformationW(server,id,info,out p,out length)){error=Marshal.GetLastWin32Error();return "";}
                if(p==IntPtr.Zero || length<2)return "";
                if(length>32768){error=122;return "";}return Marshal.PtrToStringUni(p)??"";
            } finally { if(p!=IntPtr.Zero)WTSFreeMemory(p); }
        }
        public static SessionRow[] Read(string computer,string user,string domain,SecureString password) {
            if(String.IsNullOrWhiteSpace(computer) || computer.Length>253 || !System.Text.RegularExpressions.Regex.IsMatch(computer,@"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"))throw new ArgumentException("Nom de machine invalide.");
            IntPtr token=IntPtr.Zero, secret=IntPtr.Zero, server=IntPtr.Zero, buffer=IntPtr.Zero;
            WindowsIdentity identity=null; WindowsImpersonationContext impersonation=null;
            try {
                if(password!=null) {
                    secret=Marshal.SecureStringToGlobalAllocUnicode(password);
                    try{if(!LogonUserW(user,domain,secret,9,3,out token))throw new Win32Exception(Marshal.GetLastWin32Error());}
                    finally{Marshal.ZeroFreeGlobalAllocUnicode(secret);secret=IntPtr.Zero;}
                    identity=new WindowsIdentity(token);impersonation=identity.Impersonate();
                }
                server=WTSOpenServerW(computer);if(server==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
                int count; if(!WTSEnumerateSessionsW(server,0,1,out buffer,out count))throw new Win32Exception(Marshal.GetLastWin32Error());
                if(count<0 || count>512)throw new InvalidOperationException("Nombre de sessions hors limite (512).");
                var rows=new List<SessionRow>();int stride=Marshal.SizeOf(typeof(WTS_SESSION_INFO));
                string[] states={"Active","Connectee","Connexion","Miroir","Deconnectee","Inactive","Ecoute","Reinitialisation","Arretee","Initialisation"};
                for(int i=0;i<count;i++) {
                    var s=(WTS_SESSION_INFO)Marshal.PtrToStructure(IntPtr.Add(buffer,i*stride),typeof(WTS_SESSION_INFO));
                    int error=0;string account=Text(server,s.SessionId,5,ref error), dom=Text(server,s.SessionId,7,ref error);
                    IntPtr proto=IntPtr.Zero;int len=0;string protocol="Indetermine";
                    try{if(WTSQuerySessionInformationW(server,s.SessionId,16,out proto,out len)&&proto!=IntPtr.Zero&&len>=2){short value=Marshal.ReadInt16(proto);protocol=value==0?"Console":value==2?"RDP":"Autre";}}finally{if(proto!=IntPtr.Zero)WTSFreeMemory(proto);}
                    rows.Add(new SessionRow{Id=s.SessionId,Station=Marshal.PtrToStringUni(s.Name)??"",User=account,Domain=dom,State=(s.State>=0&&s.State<states.Length?states[s.State]:"Indetermine"),Protocol=protocol,Detail=(error==0?"Lecture WTS":("Information partielle, code Windows "+error))});
                }
                return rows.ToArray();
            } finally {
                if(buffer!=IntPtr.Zero)WTSFreeMemory(buffer);if(server!=IntPtr.Zero)WTSCloseServer(server);
                if(impersonation!=null){impersonation.Undo();impersonation.Dispose();}if(identity!=null)identity.Dispose();
                if(token!=IntPtr.Zero)CloseHandle(token);if(secret!=IntPtr.Zero)Marshal.ZeroFreeGlobalAllocUnicode(secret);
            }
        }
    }
}
