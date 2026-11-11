using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using Domenia.Core;

namespace Domenia.Inventory;

/// <summary>A place is held from launch to confirmed OS exit, including timeout and failed cleanup attempts.</summary>
internal sealed class NativeReadProcess : IDisposable
{
    internal const int Limit = PhysicalWorkBudget.ReadLimit;
    private static int children;
    internal static int Running => Volatile.Read(ref children);
    private readonly Process process;
    private readonly SafeFileHandle job;
    private readonly IDisposable physical;
    private readonly IDisposable? resource;
    private readonly Task<NativeReadDiagnostics.Frame?> diagnosticReader;
    private readonly Lock stoppingGate = new();
    private bool disposed;
    private bool parentTerminationRequested;
    internal int Id => process.Id;
    internal bool HasExited => process.HasExited;
    internal NativeReadDiagnostics.ExitObservation? ExitObservation { get; private set; }

    private NativeReadProcess(Process process, SafeFileHandle job, IDisposable physical, Task<NativeReadDiagnostics.Frame?> diagnosticReader)
    {
        this.process = process; this.job = job; this.physical = physical;
        this.diagnosticReader = diagnosticReader;
        resource = RuntimeResources.Register(RuntimeResourceKind.NativeProcess, () => { RequestStop(); return Task.CompletedTask; });
    }

    internal static NativeReadProcess Start(string pipeName, string mode = NativeReadWorkerHost.Argument, IDisposable? admission = null)
    {
        var physical = admission ?? WmiReadWorkers.BorrowPhysicalAdmission() ?? PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Cim);
        Process? process = null; SafeFileHandle? job = null;
        Task<NativeReadDiagnostics.Frame?>? diagnosticReader = null;
        try
        {
            // Always the portable application's own executable; no path or executable is accepted over IPC.
            var executable = Environment.ProcessPath ?? throw new InvalidOperationException("Exécutable natif absent.");
            var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = AppContext.BaseDirectory, RedirectStandardError = true };
            start.ArgumentList.Add(mode); start.ArgumentList.Add(pipeName); start.ArgumentList.Add(Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture));
            start.Environment["DOTNET_EnableDiagnostics"] = "0";
            job = CreateJobObjectW(IntPtr.Zero, null);
            if (job.IsInvalid) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            var limits = new JobLimits { Basic = new BasicLimits { LimitFlags = 0x2000 | 0x8 | 0x100, ActiveProcessLimit = NativeIsolationPlan.ProcessLimit }, ProcessMemory = (UIntPtr)NativeIsolationPlan.MemoryLimit };
            if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<JobLimits>())) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            process = Process.Start(start) ?? throw new InvalidOperationException("Processus natif non démarré.");
            diagnosticReader = NativeReadDiagnostics.ReadAsync(process.StandardError.BaseStream);
            // The child waits on the private pipe. It receives neither account nor work before assignment succeeds.
            if (!AssignProcessToJobObject(job, process.Handle)) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            var owned = new NativeReadProcess(process, job, physical, diagnosticReader);
            Interlocked.Increment(ref children);
            return owned;
        }
        catch
        {
            if (process is not null) { StopAndWait(process, job); _ = NativeReadDiagnostics.Finish(diagnosticReader); process.Dispose(); }
            job?.Dispose(); physical.Dispose(); throw;
        }
    }

    internal static void VerifyClient(NamedPipeServerStream pipe, int expected)
    {
        if (!GetNamedPipeClientProcessId(pipe.SafePipeHandle, out var actual) || actual != expected)
        { throw new UnauthorizedAccessException("Identité du processus natif non confirmée."); }
    }

    internal static void VerifyServer(NamedPipeClientStream pipe, int expected)
    {
        if (!GetNamedPipeServerProcessId(pipe.SafePipeHandle, out var actual) || actual != expected)
        { throw new UnauthorizedAccessException("Identité du parent natif non confirmée."); }
    }

    public void Dispose()
    {
        lock (stoppingGate)
        {
            if (disposed) { return; }
            StopOwned();
            // No quota or handle is returned while the OS still reports a live process.
            process.Dispose(); job.Dispose(); disposed = true; Interlocked.Decrement(ref children); physical.Dispose(); resource?.Dispose();
        }
    }

    // The client calls this first so it can erase its parent-side secret before returning the physical budget lease.
    internal void Stop() { lock (stoppingGate) { if (!disposed) StopOwned(); } }

    // Only a request. OS exit, credential erasure, handle cleanup and quota release remain with the owning worker.
    internal void RequestStop()
    {
        lock (stoppingGate)
        {
            if (!disposed && !process.HasExited)
            {
                parentTerminationRequested = true;
                if (!TerminateJobObject(job, 2)) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            }
        }
    }

    private void StopOwned()
    {
        parentTerminationRequested |= StopAndWait(process, job);
        // Exit is confirmed and the job admits only this child: its stderr can now be fully observed.
        ExitObservation = new(NativeReadDiagnostics.Finish(diagnosticReader), process.ExitCode, parentTerminationRequested);
    }

    private static bool StopAndWait(Process process, SafeFileHandle? job)
    {
        var requested = false;
        if (!process.HasExited)
        {
            requested = true;
            if (job is { IsInvalid: false, IsClosed: false }) { _ = TerminateJobObject(job, 2); }
            // Assignment itself may have failed: terminating an empty job is not evidence that this child exited.
            if (!process.HasExited)
            {
                try { process.Kill(entireProcessTree: true); }
                catch (InvalidOperationException) when (process.HasExited) { }
                catch (Win32Exception) { /* Keep ownership and wait for physical exit even if termination was refused. */ }
            }
        }
        process.WaitForExit();
        return requested;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimits
    {
        internal long PerProcessTime; internal long PerJobTime; internal uint LimitFlags;
        internal UIntPtr MinimumWorkingSet; internal UIntPtr MaximumWorkingSet; internal uint ActiveProcessLimit;
        internal UIntPtr Affinity; internal uint Priority; internal uint Scheduling;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters { internal ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
    [StructLayout(LayoutKind.Sequential)]
    private struct JobLimits
    {
        internal BasicLimits Basic; internal IoCounters Io;
        internal UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern SafeFileHandle CreateJobObjectW(IntPtr attributes, string? name);
    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetInformationJobObject(SafeFileHandle job, int kind, ref JobLimits info, uint length);
    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);
    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateJobObject(SafeFileHandle job, uint exitCode);
    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint processId);
    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint processId);
}
