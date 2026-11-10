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
        Func<InventorySnapshot, AdWorkstationAccess, CancellationToken, Task<InventorySnapshot>>? afterRead = null, string? expectedSharingGeneration = null,
        PosteConfiguration? expectedConfiguration = null, bool awaitPhysicalCompletion = false, AdWorkstationReadAccess? retainedAccess = null,
        long? expectedAccountVersion = null, long? expectedMachineGeneration = null)
    {
        ArgumentNullException.ThrowIfNull(expected);
        if (scope is not (WorkstationReading.Survey or WorkstationReading.SurveyComplete or WorkstationReading.Quick or WorkstationReading.Full or WorkstationReading.Live))
        { throw new ArgumentException("Périmètre d’inventaire avec console invalide."); }
        var epoch = source.Epoch; InventorySnapshot? captured = null;
        InventorySnapshot RetainStopped(InventorySnapshot value)
        {
            EnsureEpoch(epoch);
            if (source.CurrentDirectory is not { } local || !local.Computers.Any(computer => computer.ObjectGuid == expected.ObjectGuid
                    && Domenia.Core.Queries.QueryComputerIdentity.Of(expected).Matches(computer))
                || value.CollectedAt < expected.WhenCreated || value.CollectedAt > source.Clock.GetUtcNow()
                || value.ReportedName is not null && !WorkstationIdentity.Matches(expected, value.ReportedName, value.HostIdentity))
            { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Identité locale ou native modifiée pendant l’arrêt ; inventaire écarté."); }
            if (value.ReportedName is null)
            {
                value = value.WithStatus(value.Access.Where(row => row.Status is SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial)
                    .Select(row => row.Category), SourceStatus.Unavailable,
                    "Identité Windows non confirmée ; données non attribuées au poste.");
            }
            return UnqualifiedAfterStop(value);
        }
        async Task<ConsoleAccountReading?> Read(WmiWorkstationReader reader, AdWorkstationAccess access, string host, CancellationToken stop)
        {
            access.EnsureCurrent(); EnsureEpoch(epoch);
            await access.BeforeContactAsync(source, host, stop).ConfigureAwait(false);
            if (expectedSharingGeneration is not null && access.SharingGeneration != expectedSharingGeneration)
                throw new DomeniaOperationException(AccountAccess.EpochChanged, "Compte modifié avant la reprise d’inventaire ; aucun nouvel envoi.");
            if (expectedConfiguration is { } settings && RemoteCollectionSettings.From(access.Settings) != RemoteCollectionSettings.From(settings))
                throw new DomeniaOperationException(AccountAccess.EpochChanged, "Réglages CIM, registre ou transport modifiés avant la reprise d’inventaire ; aucun nouvel envoi.");
            if (beforeRead is not null)
            { await beforeRead(host, stop).ConfigureAwait(false); await access.BeforeContactAsync(source, host, stop).ConfigureAwait(false); EnsureEpoch(epoch); }
            if (injected is null && beforeRead is null && afterRead is null)
            {
                var key = new InventoryReadKey(expected.ObjectGuid, expected.DistinguishedName.ToUpperInvariant(), expected.WhenCreated,
                    host.ToUpperInvariant(), scope, access.SharingGeneration, access.Settings.UseCim, access.Settings.UseRemoteRegistry, access.Settings.Options.UseWinRm)
                    { SelectedTransport = access.Settings.SelectedCimTransport };
                var shared = await SharedInventoryReads.For(source).ReadAsync(key,
                    async (updates, cancellation) =>
                    {
                        await access.BeforeContactAsync(source, host, cancellation).ConfigureAwait(false); EnsureEpoch(epoch);
                        return await reader.ReadSharedAsync(host, scope, updates, cancellation, access.Credential).ConfigureAwait(false);
                    }, progress, stop, awaitPhysicalCompletion).ConfigureAwait(false);
                captured = shared.Value;
                if (shared.Shared && source.AccountContext is { } telemetry) { OperationActivity.From(telemetry).RecordSharedInventory(captured.CimQueriesIssued); }
            }
            else
            {
                // Consent-bearing SYSTEM fallbacks, injected readers and callbacks remain exclusive to their caller.
                captured = injected is null ? await (awaitPhysicalCompletion
                    ? reader.ReadSharedAsync(host, scope, progress, stop, access.Credential)
                    : reader.ReadAsync(host, scope, progress, stop, access.Credential)).ConfigureAwait(false)
                    : await injected(host, stop).ConfigureAwait(false);
            }
            access.EnsureCurrent(); EnsureEpoch(epoch);
            if (afterRead is not null && !(awaitPhysicalCompletion && stop.IsCancellationRequested))
            { captured = await afterRead(captured, access, stop).ConfigureAwait(false); access.EnsureCurrent(); EnsureEpoch(epoch); }
            if (captured.CollectedAt < expected.WhenCreated || captured.CollectedAt > source.Clock.GetUtcNow())
            { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Date d’inventaire antérieure à l’objet ou future ; données écartées."); }
            if (captured.Access.Any(a => a.Status == SourceStatus.Refused || a.AuthenticationRejected))
            { access.Refused(host, "Inventaire et console", captured.Access.Any(a => a.AuthenticationRejected)); }
            if (captured.ReportedName is not null && !WorkstationIdentity.Matches(expected, captured.ReportedName, captured.HostIdentity))
            { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Identité Windows différente du poste attendu ; inventaire écarté."); }
            if (captured.ReportedName is null)
            {
                // Discard every payload without losing the native refusal/timeout that explains the missing identity.
                const string unconfirmed = "Identité Windows non confirmée ; données non attribuées au poste.";
                var originalAccess = captured.Access;
                captured = captured.WithStatus(originalAccess.Select(row => row.Category), SourceStatus.Unavailable, unconfirmed) with
                {
                    Access = [.. originalAccess.Select(row => row with
                    {
                        Status = row.Status is SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial ? SourceStatus.Unavailable : row.Status,
                        Detail = row.Status is SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial ? unconfirmed : row.Detail,
                        Items = 0,
                    })],
                };
            }
            if (awaitPhysicalCompletion && stop.IsCancellationRequested)
            {
                // A shared worker can finish for another subscriber after this campaign stopped. Keep its dated
                // payload, but no success, console or new LDAP qualification belongs to the stopped campaign.
                captured = RetainStopped(captured);
                stop.ThrowIfCancellationRequested();
            }
            if (captured.Console is { } console && WorkstationIdentity.Matches(expected, captured.ReportedName, captured.HostIdentity))
            {
                return new(host, console.Account is null ? SourceStatus.Empty : SourceStatus.Ok, console.Account, captured.ReportedName)
                { HostIdentity = captured.HostIdentity, ObservedAt = console.At, Detail = "Console réellement reçue dans l’inventaire ; SID du jeton non lu." };
            }
            var state = captured.StatusOf(InventoryCategories.System);
            return new(host, state is SourceStatus.Ok or SourceStatus.Empty ? SourceStatus.Partial : state, null, captured.ReportedName)
            { HostIdentity = captured.HostIdentity, AuthenticationRejected = captured.Access.Any(a => a.AuthenticationRejected), Detail = "Aucun champ de console qualifiable dans cet inventaire." };
        }

        RelationComputerReading result;
        try
        {
            result = await ComputerSessionCoreAsync(expected.DistinguishedName, expected.ObjectGuid, Read,
                WmiWorkstationReader.Budget(scope) + TimeSpan.FromSeconds(afterRead is null ? 20 : 65), token,
                Domenia.Core.Queries.QueryComputerIdentity.Of(expected), retainedAccess: retainedAccess,
                expectedAccountVersion: expectedAccountVersion, expectedMachineGeneration: expectedMachineGeneration).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested && captured is not null)
        {
            EnsureEpoch(epoch);
            // No further LDAP is sent after an operator stop. Retain completed inventory sources but no unverified console relation.
            var retained = awaitPhysicalCompletion ? RetainStopped(captured) : WithoutConsole(captured);
            return new(retained, "Lecture arrêtée ; sources déjà reçues conservées, console non publiée sans validation finale.",
                retained.Access.Any(a => a.Status == SourceStatus.Refused || a.AuthenticationRejected));
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

    private static InventorySnapshot UnqualifiedAfterStop(InventorySnapshot value) => WithoutConsole(value) with
    {
        Access = [.. value.Access.Select(row => row with
        {
            Status = row.Status is SourceStatus.Ok or SourceStatus.Empty ? SourceStatus.Partial : row.Status,
            Detail = row.RetryFailure == CollectionReadFailure.Cancelled ? row.Detail
                : row.Detail + " Lecture arrêtée ; qualification AD finale non effectuée.",
            RetryFailure = CollectionReadFailure.Cancelled,
        })],
    };
}
