using System.ComponentModel;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

public sealed partial class CimSession
{
    private NativeReadClient? native;
    private bool nativeStopped;
    private int nativeRestarts;

    /// <summary>Fresh reading processes one session may start after a request stayed silent past its own deadline.</summary>
    internal const int NativeRestartLimit = 2;

    /// <summary>Test seams: the child entry point and the clock of the request deadlines (production: worker, system clock).</summary>
    internal string NativeWorkerMode { get; init; } = NativeReadWorkerHost.Argument;
    internal TimeProvider? NativeClock { get; init; }
    private int NativeMilliseconds(TimeSpan? limit = null) => Math.Clamp((int)Math.Ceiling((limit is { } requested && requested < Remaining ? requested : Remaining).TotalMilliseconds), 1, 300_000);

    private NativeReadReply NativeRead(NativeReadRequest request)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (nativeStopped || OutOfBudget) { throw new TimeoutException(); }
        native ??= new(new(Host, Transport, NativeMilliseconds(), credential is null or { Session: true },
            credential is { Session: false } ? credential.Account : null, ReadsEnabled, RegistryEnabled), credential, cancellationToken, NativeClock, journal: journal, starting: NativeStarting);
        return native.ReadAsync(request, NativeWorkerMode).GetAwaiter().GetResult();
    }

    private static bool NativeFailure(Exception ex) => ex is IOException or UnauthorizedAccessException or Win32Exception
        or OperationCanceledException or TimeoutException or JsonException or DomeniaOperationException;

    private SourceStatus NativeFailed(Exception ex)
    {
        native?.Dispose(); native = null;
        // A request silent past its own deadline (a DCOM provider that ignores its timeout) had its child stopped and its exit
        // confirmed: the following sources are read by a fresh child, a bounded number of times and within the session
        // budget. Any other failure, the caller's stop or the end of the budget ends native reading for this session
        // (bench of 11/11/2026: one slow Defender query lost the 14 sources after it).
        if (ex is TimeoutException && !nativeStopped && !disposed && !OutOfBudget && !cancellationToken.IsCancellationRequested
            && nativeRestarts < NativeRestartLimit)
        {
            nativeRestarts++;
            journal?.Info("Lecture de " + Host + " : requête sans réponse dans son délai ; les sources suivantes sont lues par un processus neuf ("
                + nativeRestarts.ToString(System.Globalization.CultureInfo.InvariantCulture) + "/" + NativeRestartLimit.ToString(System.Globalization.CultureInfo.InvariantCulture) + ").");
        }
        else { nativeStopped = true; }
        return ex is OperationCanceledException or TimeoutException ? SourceStatus.Interrupted
            : ex is DomeniaOperationException ? SourceStatus.Unavailable : SourceStatus.Error;
    }

    private string NativeFailureDetail(Exception ex) => ex is DomeniaOperationException { Code: "operation.siteBusy" } site ? site.Message
        : ex is DomeniaOperationException { Code: "machine.busy" or "operation.physicalBusy" }
        ? "Budget physique atteint ; des appels restent actifs ou en nettoyage. Aucun nouvel appel envoyé."
        : !nativeStopped
        ? "Requête sans réponse dans son délai ; processus de lecture arrêté, les sources suivantes sont lues par un processus neuf. Aucun rejeu de cette requête."
            + (Transport == InventoryTransport.WinRm ? " Fermeture d’un éventuel shell distant non confirmée." : "")
        : "Lecture native non reçue ; fermeture du processus demandée, place physique retenue jusqu’à terminaison confirmée. Aucun rejeu automatique."
            + (Transport == InventoryTransport.WinRm ? " Fermeture d’un éventuel shell distant non confirmée." : "");

    private CimReading NativeReading(NativeReadRequest request, string category)
    {
        var begin = clock.GetTimestamp();
        try
        {
            var reading = NativeRead(request).Reading ?? throw new InvalidDataException("Réponse native incohérente.");
            if (reading.Instances.Count > 20_000 || !Enum.IsDefined(reading.Status) || !FactMatches(reading) || !RetryFactMatches(reading) || reading.ProjectionRejected && (reading.Status != SourceStatus.Error || reading.Items != 0 || reading.AuthenticationRejected)) { throw new InvalidDataException("Réponse native hors limites."); }
            authenticationRefused |= reading.AuthenticationRejected;
            return reading with { DurationMs = (int)clock.GetElapsedTime(begin).TotalMilliseconds };
        }
        catch (Exception ex) when (NativeFailure(ex))
        {
            var status = NativeFailed(ex);
            return new(category, status, NativeFailureDetail(ex), (int)clock.GetElapsedTime(begin).TotalMilliseconds, [])
                { RetryFailure = cancellationToken.IsCancellationRequested ? CollectionReadFailure.Cancelled : RetryFailure(ex, status) };
        }
    }

    private RegistryReading NativeRegistry(NativeReadRequest request)
    {
        var begin = clock.GetTimestamp();
        try
        {
            var reading = NativeRead(request).Registry ?? throw new InvalidDataException("Réponse native incohérente.");
            authenticationRefused |= reading.AuthenticationRejected;
            return reading with { DurationMs = (int)clock.GetElapsedTime(begin).TotalMilliseconds };
        }
        catch (Exception ex) when (NativeFailure(ex))
        { return new(NativeFailed(ex), false, null, NativeFailureDetail(ex), (int)clock.GetElapsedTime(begin).TotalMilliseconds); }
    }

    private WorkstationUserReading NativeUser(NativeReadKind kind)
    {
        var begin = clock.GetTimestamp();
        try
        {
            var reading = NativeRead(new(kind, NativeMilliseconds())).User ?? throw new InvalidDataException("Réponse native incohérente.");
            authenticationRefused |= reading.Access.AuthenticationRejected;
            return reading with { Access = reading.Access with { DurationMs = (int)clock.GetElapsedTime(begin).TotalMilliseconds } };
        }
        catch (Exception ex) when (NativeFailure(ex))
        { return new(null, new(kind == NativeReadKind.WinRmUser ? "WinRm" : "RemoteRegistry", NativeFailed(ex),
            NativeFailureDetail(ex), (int)clock.GetElapsedTime(begin).TotalMilliseconds, 0,
            kind == NativeReadKind.WinRmUser ? InventoryTransport.WinRm : InventoryTransport.RemoteRegistry), []); }
    }
}
