using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Domenia.App;

/// <summary>Owns only the health child and descendants; the assistant itself must survive the original application.</summary>
internal sealed class PackageUpdateHealthJob : IDisposable
{
    private readonly SafeFileHandle handle;
    internal PackageUpdateHealthJob()
    {
        handle = CreateJobObjectW(IntPtr.Zero, null);
        if (handle.IsInvalid) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
        var limits = new Limits { Basic = new BasicLimits { LimitFlags = 0x2000 } }; // KILL_ON_JOB_CLOSE
        if (!SetInformationJobObject(handle, 9, ref limits, (uint)Marshal.SizeOf<Limits>()))
        { var error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error); }
    }
    internal void Assign(Process child)
    {
        // The child is waiting on its private pipe and receives no work before this succeeds.
        if (!AssignProcessToJobObject(handle, child.Handle)) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
    }
    internal async Task<bool> StopAndConfirmAsync(Process child)
    {
        try
        {
            if (!TerminateJobObject(handle, 2)) { return false; }
            await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10)).ConfigureAwait(false);
            var until = Stopwatch.GetTimestamp();
            do
            {
                if (!QueryInformationJobObject(handle, 1, out var accounting, (uint)Marshal.SizeOf<Accounting>(), IntPtr.Zero)) { return false; }
                if (accounting.ActiveProcesses == 0) { return true; }
                await Task.Delay(50).ConfigureAwait(false);
            } while (Stopwatch.GetElapsedTime(until) < TimeSpan.FromSeconds(10));
            return false;
        }
        catch (Exception error) when (error is InvalidOperationException or Win32Exception or TimeoutException) { return false; }
    }
    public void Dispose() => handle.Dispose();

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimits
    {
        internal long PerProcessTime, PerJobTime;
        internal uint LimitFlags;
        internal UIntPtr MinimumWorkingSet, MaximumWorkingSet;
        internal uint ActiveProcessLimit;
        internal UIntPtr Affinity;
        internal uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters { internal ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes; }
    [StructLayout(LayoutKind.Sequential)]
    private struct Limits
    {
        internal BasicLimits Basic;
        internal IoCounters Io;
        internal UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct Accounting
    {
        internal long UserTime, KernelTime, PeriodUserTime, PeriodKernelTime;
        internal uint PageFaults, TotalProcesses, ActiveProcesses, TerminatedProcesses;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern SafeFileHandle CreateJobObjectW(IntPtr attributes, string? name);
    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern bool SetInformationJobObject(SafeFileHandle job, int informationClass, ref Limits information, uint length);
    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);
    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern bool TerminateJobObject(SafeFileHandle job, uint exitCode);
    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern bool QueryInformationJobObject(SafeFileHandle job, int informationClass, out Accounting information, uint length, IntPtr returned);
}
