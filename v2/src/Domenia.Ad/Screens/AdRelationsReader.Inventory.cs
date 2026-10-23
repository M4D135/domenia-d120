using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Ad;

public sealed partial class AdRelationsReader
{
    internal sealed record QualifiedInventory(InventorySnapshot Value, string Notice, bool Denied = false);

    /// <summary>Reuse the console pipeline around one native inventory, preserving its completed payload on operator cancellation.</summary>
    internal async Task<QualifiedInventory> InventoryAsync(DirectoryComputer expected, WorkstationReading scope, IProgress<PosteProgress>? progress,
        CancellationToken token, Func<string, CancellationToken, Task<InventorySnapshot>>? injected = null, Func<string, CancellationToken, Task>? beforeRead = null,
        Func<InventorySnapshot, AdWorkstationAccess, CancellationToken, Task<InventorySnapshot>>? afterRead = null)
    {
        ArgumentNullException.ThrowIfNull(expected);
        if (scope is not (WorkstationReading.Survey or WorkstationReading.SurveyComplete or WorkstationReading.Quick or WorkstationReading.Full or WorkstationReading.Live))
        { throw new ArgumentException("Périmètre d’inventaire avec console invalide."); }
        var epoch = source.Epoch; InventorySnapshot? captured = null;
        async Task<ConsoleAccountReading?> Read(WmiWorkstationReader reader, AdWorkstationAccess access, string host, CancellationToken stop)
        {
            if (beforeRead is not null) { await beforeRead(host, stop).ConfigureAwait(false); access.EnsureCurrent(); EnsureEpoch(epoch); }
            captured = injected is null ? await reader.ReadAsync(host, scope, progress, stop, access.Credential).ConfigureAwait(false)
                : await injected(host, stop).ConfigureAwait(false);
            access.EnsureCurrent(); EnsureEpoch(epoch);
            if (afterRead is not null) { captured = await afterRead(captured, access, stop).ConfigureAwait(false); access.EnsureCurrent(); EnsureEpoch(epoch); }
            if (captured.CollectedAt < expected.WhenCreated || captured.CollectedAt > source.Clock.GetUtcNow())
            { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Date d’inventaire antérieure à l’objet ou future ; données écartées."); }
            if (captured.Access.Any(a => a.Status == SourceStatus.Refused || a.AuthenticationRejected))
            { access.Refused(host, "Inventaire et console", captured.Access.Any(a => a.AuthenticationRejected)); }
            if (captured.ReportedName is not null && !WorkstationIdentity.Matches(expected, captured.ReportedName))
            { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Identité Windows différente du poste attendu ; inventaire écarté."); }
            if (captured.ReportedName is null)
            {
                foreach (var row in captured.Access)
                {
                    captured = captured.WithStatus([row.Category], row.Status is SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial ? SourceStatus.Unavailable : row.Status,
                        "Identité Windows non confirmée ; données non attribuées au poste.");
                }
            }
            if (captured.Console is { } console && WorkstationIdentity.Matches(expected, captured.ReportedName))
            {
                return new(host, console.Account is null ? SourceStatus.Empty : SourceStatus.Ok, console.Account, captured.ReportedName)
                { ObservedAt = console.At, Detail = "Console réellement reçue dans l’inventaire ; SID du jeton non lu." };
            }
            var state = captured.StatusOf(InventoryCategories.System);
            return new(host, state is SourceStatus.Ok or SourceStatus.Empty ? SourceStatus.Partial : state, null, captured.ReportedName)
            { AuthenticationRejected = captured.Access.Any(a => a.AuthenticationRejected), Detail = "Aucun champ de console qualifiable dans cet inventaire." };
        }

        RelationComputerReading result;
        try
        {
            result = await ComputerSessionCoreAsync(expected.DistinguishedName, expected.ObjectGuid, Read,
                WmiWorkstationReader.Budget(scope) + TimeSpan.FromSeconds(afterRead is null ? 20 : 65), token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested && captured is not null)
        {
            EnsureEpoch(epoch);
            // No further LDAP is sent after an operator stop. Retain completed inventory sources but no unverified console relation.
            return new(WithoutConsole(captured), "Lecture arrêtée ; sources déjà reçues conservées, console non publiée sans validation finale.");
        }
        EnsureEpoch(epoch);
        if (captured is null) { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, result.Message); }
        if (result.ConsoleReadAt is null) { captured = WithoutConsole(captured); }
        var notice = result.Message;
        if (result.Savable)
        {
            var saved = await AdRelationSession.For(source).SaveAsync(epoch, token).ConfigureAwait(false);
            notice += " " + saved.Text;
        }
        return new(captured, notice, result.Attempts.Any(a => a.Status is "REFUSE" or "AUTH_REJETEE") || captured.Access.Any(a => a.Status == SourceStatus.Refused || a.AuthenticationRejected));
    }

    private static InventorySnapshot WithoutConsole(InventorySnapshot value) => value with
    { Console = null, System = value.System is null ? null : value.System with { UserName = null } };
}
