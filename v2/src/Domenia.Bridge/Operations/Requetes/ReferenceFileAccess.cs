using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Domenia.Bridge.Operations.Requetes;

/// <summary>Windows read handles opened without following reparse points. Ancestor handles deny rename/delete for their lifetime.</summary>
internal sealed class ReferenceFileAccess : IDisposable
{
    private readonly List<SafeFileHandle> parents = [];
    private ReferenceFileAccess() { }
    internal static ReferenceFileAccess PinParents(string file, bool allowMissing = false)
    {
        var result = new ReferenceFileAccess();
        try
        {
            var stack = new Stack<string>();
            for (var current = Path.GetDirectoryName(file); current is not null; current = Path.GetDirectoryName(current)) { stack.Push(current); }
            while (stack.TryPop(out var directory))
            {
                var handle = Open(directory, directory: true, allowMissing);
                if (handle is null) { break; }
                result.parents.Add(handle);
            }
            return result;
        }
        catch { result.Dispose(); throw; }
    }
    internal static FileStream? OpenRead(string path, bool allowMissing = false)
    {
        var handle = Open(path, directory: false, allowMissing);
        if (handle is null) { return null; }
        try { return new FileStream(handle, FileAccess.Read, 65536, isAsync: false); }
        catch { handle.Dispose(); throw; }
    }
    private static SafeFileHandle? Open(string path, bool directory, bool allowMissing)
    {
        // FILE_READ_ATTRIBUTES alone is a metadata open: it does not establish the read access needed
        // for a reliable sharing restriction. FILE_LIST_DIRECTORY pins the directory stream without
        // enumerating it or requesting any write/delete permission. Keep FILE_SHARE_DELETE absent.
        var handle = Native.CreateFile(path, directory ? 0x81u : 0x80000000u, directory ? 3u : 1u, IntPtr.Zero, 3,
            0x00200000u | (directory ? 0x02000000u : 0x08000000u), IntPtr.Zero);
        if (handle.IsInvalid)
        {
            var error = Marshal.GetLastWin32Error(); handle.Dispose();
            if (allowMissing && error is 2 or 3) { return null; }
            throw new IOException("Accès au fichier ou à son parent impossible (" + error + ").", new Win32Exception(error));
        }
        try
        {
            if (!Native.GetFileInformationByHandle(handle, out var info)) { throw new IOException("Identité du handle indisponible.", new Win32Exception(Marshal.GetLastWin32Error())); }
            if ((info.Attributes & 0x400) != 0 || ((info.Attributes & 0x10) != 0) != directory)
            { throw new IOException("Lien, jonction ou type de fichier inattendu refusé depuis le handle."); }
            return handle;
        }
        catch { handle.Dispose(); throw; }
    }
    public void Dispose() { for (var i = parents.Count - 1; i >= 0; i--) { parents[i].Dispose(); } parents.Clear(); }
    private static class Native
    {
        [StructLayout(LayoutKind.Sequential)] internal struct Information
        {
            internal uint Attributes;
            internal System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
            internal uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetFileInformationByHandle(SafeFileHandle file, out Information information);
    }
}
