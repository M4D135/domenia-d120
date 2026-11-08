using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace Domenia.Inventory;

/// <summary>Explicit local discovery only. Keeps the approved bytes and ordinary ancestors pinned until OS process exit.
/// No PATH lookup, download, copy, ACL repair or executable launch. Approval is an exact package hash, not a filename.</summary>
internal sealed class RemotePsExecBinary : IDisposable
{
    internal const string ApprovedSha256 = "edfae1a69522f87b12c6dac3225d930e4848832e3c551ee1e7d31736bf4525ef";
    internal const int MaximumBytes = 16 * 1024 * 1024;
    private readonly List<SafeFileHandle> parents;
    private readonly FileStream file;
    internal string Path { get; }
    internal string Sha256 { get; }
    private RemotePsExecBinary(string path, string hash, FileStream file, List<SafeFileHandle> parents)
    { Path = path; Sha256 = hash; this.file = file; this.parents = parents; }

    internal static RemotePsExecBinary? Find(string folder, CancellationToken token)
    {
        foreach (var relative in new[] { "PsExec64.exe", "PsExec.exe", @"wad\PsExec64.exe", @"wad\PsExec.exe" })
        {
            token.ThrowIfCancellationRequested(); var path = System.IO.Path.Combine(folder, relative);
            // A present but unapproved candidate is a refusal, not permission to try a different executable.
            // Ancestors are opened without following reparse points before even probing the terminal name.
            try { return Open(path, ApprovedSha256, token); }
            catch (Win32Exception ex) when (ex.NativeErrorCode is 2 or 3) { continue; }
        }
        return null;
    }

    internal static RemotePsExecBinary Open(string path, string expectedHash, CancellationToken token)
    {
        if (!OperatingSystem.IsWindows()) { throw new PlatformNotSupportedException("Qualification PsExec réservée à Windows."); }
        token.ThrowIfCancellationRequested();
        if (expectedHash.Length != 64 || !expectedHash.All(char.IsAsciiHexDigit) || path.Length is < 4 or > 1024
            || path[1] != ':' || path[2] != '\\' || !char.IsAsciiLetter(path[0]) || path[3..].Contains(':')
            || path.Contains('/') || path.Any(char.IsControl) || System.IO.Path.GetFullPath(path) != path
            || new DriveInfo(path[..3]).DriveType != DriveType.Fixed)
        { throw new IOException("Binaire PsExec : chemin local fixe absolu et ordinaire obligatoire."); }
        var parents = new List<SafeFileHandle>(); FileStream? stream = null;
        try
        {
            var chain = new Stack<string>(); var parent = System.IO.Path.GetDirectoryName(path);
            while (parent is not null) { chain.Push(parent); parent = System.IO.Path.GetDirectoryName(parent); }
            while (chain.TryPop(out var directory))
            {
                token.ThrowIfCancellationRequested(); var pin = OpenHandle(directory, 0x80, FileShare.ReadWrite, 0x02200000);
                parents.Add(pin); var info = Info(pin);
                if ((info.Attributes & (uint)FileAttributes.Directory) == 0 || (info.Attributes & (uint)FileAttributes.ReparsePoint) != 0)
                { throw new IOException("Ancêtre PsExec indirect ; binaire refusé."); }
            }
            var handle = OpenHandle(path, 0x80000000, FileShare.Read, 0x00200000);
            try
            {
                var info = Info(handle);
                if ((info.Attributes & (uint)(FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0 || info.Links != 1)
                { throw new IOException("Binaire PsExec indirect ou lié plusieurs fois ; refus."); }
                stream = new FileStream(handle, FileAccess.Read);
            }
            catch { handle.Dispose(); throw; }
            if (stream.Length is < 1 or > MaximumBytes) { throw new IOException("Binaire PsExec hors limite de 16 Mio."); }
            var length = stream.Length; long total = 0; using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var bytes = new byte[64 * 1024]; int count;
            while ((count = stream.Read(bytes)) != 0) { token.ThrowIfCancellationRequested(); total += count; if (total > length) { throw new IOException("Binaire modifié."); } hash.AppendData(bytes, 0, count); }
            var actual = Convert.ToHexStringLower(hash.GetHashAndReset());
            if (total != length || stream.Length != length || !string.Equals(actual, expectedHash, StringComparison.OrdinalIgnoreCase))
            { throw new IOException("Empreinte PsExec non approuvée ; aucune exécution."); }
            token.ThrowIfCancellationRequested(); return new(path, actual, stream, parents);
        }
        catch { stream?.Dispose(); foreach (var pin in parents) { pin.Dispose(); } throw; }
    }

    public void Dispose() { file.Dispose(); foreach (var pin in parents) { pin.Dispose(); } }

    private static SafeFileHandle OpenHandle(string path, uint access, FileShare share, uint flags)
    {
        var handle = CreateFileW(path, access, share, IntPtr.Zero, 3, flags, IntPtr.Zero);
        if (!handle.IsInvalid) { return handle; }
        var error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error, "Binaire PsExec ou ancêtre non qualifiable.");
    }
    private static HandleInfo Info(SafeFileHandle handle)
    { if (!GetFileInformationByHandle(handle, out var info)) { throw new Win32Exception(Marshal.GetLastWin32Error()); } return info; }
    [StructLayout(LayoutKind.Sequential)]
    private struct HandleInfo
    {
        internal uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh, Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern SafeFileHandle CreateFileW(string path, uint access, FileShare share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out HandleInfo info);
}
