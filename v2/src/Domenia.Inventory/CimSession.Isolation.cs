using System.ComponentModel;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

public sealed partial class CimSession
{
    private NativeReadClient? native;
    private bool nativeStopped;
    private int NativeMilliseconds(TimeSpan? limit = null) => Math.Clamp((int)Math.Ceiling((limit is { } requested && requested < Remaining ? requested : Remaining).TotalMilliseconds), 1, 300_000);

    private NativeReadReply NativeRead(NativeReadRequest request)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (nativeStopped || OutOfBudget) { throw new TimeoutException(); }
        native ??= new(new(Host, Transport, NativeMilliseconds(), credential is null or { Session: true },
            credential is { Session: false } ? credential.Account : null, ReadsEnabled, RegistryEnabled), credential, cancellationToken, journal: journal);
        return native.Read(request);
    }

    private static bool NativeFailure(Exception ex) => ex is IOException or UnauthorizedAccessException or Win32Exception
        or OperationCanceledException or TimeoutException or JsonException or DomeniaOperationException;

    private SourceStatus NativeFailed(Exception ex)
    {
        nativeStopped = true; native?.Dispose();
        return ex is OperationCanceledException or TimeoutException ? SourceStatus.Interrupted
            : ex is DomeniaOperationException ? SourceStatus.Unavailable : SourceStatus.Error;
    }

    private string NativeFailureDetail(Exception ex) => ex is DomeniaOperationException { Code: "operation.siteBusy" } site ? site.Message
        : ex is DomeniaOperationException { Code: "machine.busy" or "operation.physicalBusy" }
        ? "Budget physique atteint ; des appels restent actifs ou en nettoyage. Aucun nouvel appel envoyé."
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
