using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
namespace Domenia.Secrets {
    public static class ClipboardWriter {
        [DllImport("user32.dll",SetLastError=true)] static extern bool OpenClipboard(IntPtr owner);
        [DllImport("user32.dll",SetLastError=true)] static extern bool CloseClipboard();
        [DllImport("user32.dll",SetLastError=true)] static extern bool EmptyClipboard();
        [DllImport("user32.dll",SetLastError=true)] static extern IntPtr SetClipboardData(uint format,IntPtr memory);
        [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint RegisterClipboardFormatW(string name);
        [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr GlobalAlloc(uint flags,UIntPtr bytes);
        [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr GlobalLock(IntPtr memory);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool GlobalUnlock(IntPtr memory);
        [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr GlobalFree(IntPtr memory);
        static IntPtr Allocate(byte[] bytes) {
            IntPtr h=GlobalAlloc(2,(UIntPtr)(uint)bytes.Length);if(h==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
            IntPtr p=GlobalLock(h);if(p==IntPtr.Zero){GlobalFree(h);throw new Win32Exception(Marshal.GetLastWin32Error());}
            try{Marshal.Copy(bytes,0,p,bytes.Length);}finally{GlobalUnlock(h);}return h;
        }
        public static void Set(IntPtr owner,string text) {
            if(owner==IntPtr.Zero)throw new ArgumentException("Fenetre proprietaire absente.");
            if(text==null || text.Length==0 || text.Length>8192)throw new ArgumentException("Valeur de copie absente ou hors limite.");
            uint[] formats={RegisterClipboardFormatW("ExcludeClipboardContentFromMonitorProcessing"),RegisterClipboardFormatW("CanIncludeInClipboardHistory"),RegisterClipboardFormatW("CanUploadToCloudClipboard"),13};
            foreach(uint f in formats)if(f==0)throw new Win32Exception(Marshal.GetLastWin32Error());
            IntPtr[] memory=new IntPtr[4];bool opened=false;byte[] content=Encoding.Unicode.GetBytes(text+"\0");
            try {
                for(int i=0;i<3;i++)memory[i]=Allocate(new byte[4]);memory[3]=Allocate(content);
                if(!OpenClipboard(owner))throw new Win32Exception(Marshal.GetLastWin32Error());opened=true;
                if(!EmptyClipboard())throw new Win32Exception(Marshal.GetLastWin32Error());
                for(int i=0;i<4;i++){
                    if(SetClipboardData(formats[i],memory[i])==IntPtr.Zero){EmptyClipboard();throw new Win32Exception(Marshal.GetLastWin32Error());}
                    memory[i]=IntPtr.Zero; // Windows owns successful transfers.
                }
            } finally {
                if(opened)CloseClipboard();for(int i=0;i<4;i++)if(memory[i]!=IntPtr.Zero)GlobalFree(memory[i]);Array.Clear(content,0,content.Length);
            }
        }
    }
}
