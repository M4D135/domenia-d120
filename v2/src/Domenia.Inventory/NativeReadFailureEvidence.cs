using System.ComponentModel;
using System.Globalization;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

internal enum NativeReadStage { Admission, WorkerStart, PipeConnect, Handshake, RequestWrite, ResponseRead, ResponseValidate }

/// <summary>Only observed primitives survive cleanup: no exception, target, credential or request payload is retained.</summary>
internal sealed record NativeReadFailureEvidence(
    InventoryTransport Transport, NativeReadKind Kind, NativeReadStage Stage, int BudgetMs,
    long ElapsedMs, long? ExecutionMs, bool CallerCancellation, bool RequestDeadline,
    bool RequestWriteCompleted, string ExceptionType, int HResult, int? NativeErrorCode, string RegistryOperation)
{
    internal static NativeReadFailureEvidence Capture(InventoryTransport transport, NativeReadRequest request,
        NativeReadStage stage, long queuedAt, long? executingAt, TimeProvider clock,
        CancellationToken callerToken, CancellationToken requestDeadline, bool requestWriteCompleted, Exception exception)
    {
        var observedAt = clock.GetTimestamp();
        var type = exception.GetType().FullName ?? exception.GetType().Name;
        type = new string(type.Take(256).Select(c => char.IsControl(c) ? '?' : c).ToArray());
        return new(transport, request.Kind, stage, request.BudgetMs,
            ReadPerformance.Milliseconds(clock.GetElapsedTime(queuedAt, observedAt)),
            executingAt is { } start ? ReadPerformance.Milliseconds(clock.GetElapsedTime(start, observedAt)) : null,
            callerToken.IsCancellationRequested, requestDeadline.IsCancellationRequested, requestWriteCompleted,
            type, exception.HResult, exception is Win32Exception native ? native.NativeErrorCode : null,
            RegistryOperationFor(request));
    }

    internal string Format()
    {
        var execution = ExecutionMs?.ToString(CultureInfo.InvariantCulture) ?? "absent";
        var native = NativeErrorCode is { } code ? "0x" + code.ToString("X8", CultureInfo.InvariantCulture) : "absent";
        return FormattableString.Invariant($"Lecture native interrompue : transport={Transport}; kind={Kind}; stage={Stage}; budgetMs={BudgetMs}; elapsedMs={ElapsedMs}; executionMs={execution}; callerCancellation={CallerCancellation}; requestDeadline={RequestDeadline}; requestWriteCompleted={RequestWriteCompleted}; exception={ExceptionType}; hresult=0x{HResult:X8}; win32={native}; registry={RegistryOperation}.");
    }

    private static string RegistryOperationFor(NativeReadRequest request)
    {
        if (request.Kind != NativeReadKind.Registry || request.Registry is not { Hive: InventoryRegistry.Machine } registry) { return "Other"; }
        bool Matches(string key, string name, RegistryMethod method) => registry.Method == method
            && string.Equals(registry.Key, key, StringComparison.OrdinalIgnoreCase)
            && string.Equals(registry.Name, name, StringComparison.OrdinalIgnoreCase);
        if (Matches(InventoryRegistry.UpdatePolicy, "WUServer", RegistryMethod.String)) { return "UpdatePolicy/WUServer"; }
        if (Matches(InventoryRegistry.UpdatePolicy + @"\AU", "UseWUServer", RegistryMethod.Dword)) { return "UpdatePolicy/AU/UseWUServer"; }
        if (Matches(InventoryRegistry.UpdateInstall, "LastSuccessTime", RegistryMethod.String)) { return "UpdateInstall/LastSuccessTime"; }
        return "Other";
    }
}
