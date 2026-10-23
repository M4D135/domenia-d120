using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Core.Queries;
using Domenia.Inventory;

namespace Domenia.Ad;

public sealed partial class AdRelationsReader
{
    internal Func<PosteConfiguration, WmiWorkstationReader>? InventoryReaderOverride { get; init; }
    private sealed record ConsoleResult(RelationObject Computer, ImmutableArray<RelationAttempt> Attempts, RelationObservedAccount? Observed,
        StoredRelation? Relation, string Status, string Message)
    {
        internal DateTimeOffset? VerifiedAt { get; init; }
    }

    public Task<RelationComputerReading> ComputerSessionAsync(string dn, CancellationToken cancellationToken) =>
        ComputerSessionAsync(dn, null, cancellationToken);

    internal Task<RelationComputerReading> ComputerSessionAsync(string dn, Guid? expectedGuid, CancellationToken cancellationToken) =>
        ComputerSessionCoreAsync(dn, expectedGuid, null, TimeSpan.FromSeconds(25), cancellationToken);

    internal Task<RelationComputerReading> ComputerSessionAsync(QueryComputerIdentity expected, CancellationToken cancellationToken) =>
        ComputerSessionCoreAsync(expected.Dn, expected.Guid, null, TimeSpan.FromSeconds(25), cancellationToken, expected);

    private delegate Task<ConsoleAccountReading?> NativeConsoleRead(WmiWorkstationReader reader, AdWorkstationAccess access, string host, CancellationToken token);

    private async Task<RelationComputerReading> ComputerSessionCoreAsync(string dn, Guid? expectedGuid, NativeConsoleRead? nativeRead,
        TimeSpan duration, CancellationToken cancellationToken, QueryComputerIdentity? planned = null)
    {
        var epoch = source.Epoch;
        var state = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false); EnsureEpoch(epoch);
        var local = (state.Directory, Lookup: AdRelationLookup.For(state.Directory), Epoch: epoch);
        AdRelationDirectory.ValidateDn(dn, local.Directory.Domain);
        var expected = local.Lookup.Find(dn);
        if (expected is not { Kind: RelationSubjectKind.Computer })
        { throw new DomeniaOperationException(RelationErrors.NotRelationObject, "Poste absent ou ambigu dans l’index ; relisez sa fiche avant de demander sa console."); }
        if (expectedGuid is { } id && expected.Guid != id)
        { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Le GUID du poste a changé depuis son affichage ; aucun contact envoyé."); }
        var memory = await AdRelationPassMemory.BeginAsync(source, local.Directory.Domain.RootDn, local.Epoch, cancellationToken).ConfigureAwait(false);
        var read = await ReadConsoleAsync(local.Directory.Domain, expected, local.Epoch, cancellationToken, nativeRead: nativeRead, duration: duration, planned: planned).ConfigureAwait(false);
        EnsureEpoch(local.Epoch); cancellationToken.ThrowIfCancellationRequested();
        var resultId = ""; var message = read.Message; var savable = false;
        if (read.Relation is { } relation)
        {
            var shared = AdRelationSession.For(source);
            if (shared.ValidationError(relation) is { } invalid) { throw new DomeniaOperationException(RelationErrors.IdentityChanged, invalid); }
            var receipt = shared.ObserveValidated(relation, local.Epoch);
            if (receipt.Accepted)
            {
                resultId = AdRelationResults.For(source).RememberObservations("Lecture de session",
                    ImmutableDictionary.CreateRange(StringComparer.Ordinal, [KeyValuePair.Create(RelationRules.Key(relation), relation)]), local.Epoch);
                if (resultId == RelationChange.SessionResultId) { message += " Aperçus individuels pleins ; observation regroupée avec les attentes de la session."; }
            }
            savable = receipt.Accepted;
            message += " " + receipt.Reason;
        }
        var pc = read.Computer;
        message += " " + await memory.CompleteAsync(new(pc.Guid, pc.Dn, pc.Name, source.Clock.GetUtcNow(),
            AdRelationPassMemory.Status(read.Status, read.Relation is not null), read.Observed?.Account), cancellationToken).ConfigureAwait(false);
        var subject = new RelationSubject(pc.Kind, pc.Dn, pc.Guid.ToString("D"), pc.Name, pc.Login, pc.Detail,
            RelationRules.Path(pc.Dn, local.Directory.Domain.DnsName), pc.Enabled, pc.LastLogon, pc.Created);
        return new(resultId, subject, read.Attempts, read.Observed, savable, message) { ConsoleReadAt = read.VerifiedAt };
    }

    /// <summary>One console only. Historical logon names, profile folders and fallback transports cannot supply this result.</summary>
    private async Task<ConsoleResult> ReadConsoleAsync(DomainInfo domain, RelationObject expected, long epoch, CancellationToken cancellationToken,
        AdReadAccess? sharedDirectory = null, string? expectedHost = null, NativeConsoleRead? nativeRead = null, TimeSpan? duration = null, QueryComputerIdentity? planned = null)
    {
        var attempts = ImmutableArray.CreateBuilder<RelationAttempt>();
        var computer = expected; RelationObservedAccount? observed = null; StoredRelation? relation = null;
        DateTimeOffset? verifiedAt = null;
        var status = "NON_EFFECTUE"; var message = "Console non déterminée ; associations existantes conservées.";
        void Attempt(string method, string state, string detail, string resource, long duration = 0)
        {
            var label = RelationRules.AttemptStatus(state);
            attempts.Add(new(method, state, label.Label, label.Tone, computer.Name, detail, duration, resource));
        }
        using var elapsed = new CancellationTokenSource(duration ?? TimeSpan.FromSeconds(25), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        try
        {
            using var ownedDirectory = sharedDirectory is null ? await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, null, budget.Token).ConfigureAwait(false) : null;
            var directory = sharedDirectory ?? ownedDirectory!;
            var first = await AdRelationDirectory.ExactAsync(directory, domain, expected.Dn, expected.Guid, false, budget.Token).ConfigureAwait(false);
            if (first.Object.Kind != RelationSubjectKind.Computer || first.Object.Sid != expected.Sid || first.Object.Created != expected.Created
                || !string.Equals(first.Object.Login, expected.Login, StringComparison.OrdinalIgnoreCase))
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Identité du poste modifiée depuis son affichage ; relisez sa fiche."); }
            computer = first.Object;
            var machineIdentity = AdDirectoryMapper.Computer(first.Entry)!;
            if (planned is not null && !planned.Matches(machineIdentity))
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Identité différente du plan confirmé ; aucun contact distant."); }
            var host = machineIdentity.DnsHostName;
            if (host is null || !CimQuery.IsHostName(host) || WorkstationIdentity.ExpectedName(machineIdentity) is null
                || computer.Created == DateTimeOffset.MinValue || computer.Created > source.Clock.GetUtcNow()
                || expectedHost is not null && !host.Equals(expectedHost, StringComparison.OrdinalIgnoreCase))
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Identité Windows ou date de création du poste incohérente ; aucun contact distant."); }
            using var machine = await AdWorkstationAccess.AcquireAsync(source, host, budget.Token).ConfigureAwait(false);
            directory.EnsureCurrent(); machine.EnsureCurrent(); EnsureEpoch(epoch);
            var began = source.Clock.GetTimestamp();
            var reader = InventoryReaderOverride?.Invoke(machine.Settings) ?? machine.InventoryReader();
            var reading = nativeRead is null ? await reader.ReadConsoleAccountAsync(host, budget.Token, machine.Credential, dcomOnly: true).ConfigureAwait(false)
                : await nativeRead(reader, machine, host, budget.Token).ConfigureAwait(false);
            directory.EnsureCurrent(); machine.EnsureCurrent(); EnsureEpoch(epoch); budget.Token.ThrowIfCancellationRequested();
            if (reading?.Status == SourceStatus.Refused || reading?.AuthenticationRejected == true)
            { machine.Refused(host, "Lecture de la console", reading.AuthenticationRejected); }
            status = reading is null ? "NON_EFFECTUE" : reading.AuthenticationRejected ? "AUTH_REJETEE" : reading.Status switch
            {
                SourceStatus.Ok => "LU", SourceStatus.Empty => "VIDE", SourceStatus.Partial => "A_REVOIR", SourceStatus.Refused => "REFUSE",
                SourceStatus.Interrupted => "ARRETE", SourceStatus.Skipped => "IGNORE", _ => "NON_EFFECTUE",
            };
            Attempt(nativeRead is null ? "Console CIM/DCOM" : "Console de l’inventaire", status, reading?.Detail ?? "Lecture indisponible.", "Postes", (long)source.Clock.GetElapsedTime(began).TotalMilliseconds);
            if (reading is null || reading.AuthenticationRejected || reading.Status is not (SourceStatus.Ok or SourceStatus.Empty))
            { return new(computer, attempts.ToImmutable(), null, null, status, message); }
            if (!WorkstationIdentity.Matches(machineIdentity, reading.ReportedName))
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Le nom Windows reçu diffère du compte machine relu ; observation écartée."); }
            var at = reading.ObservedAt;
            if (at is null || at < computer.Created || at > source.Clock.GetUtcNow())
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Date de lecture de console absente ou incohérente ; observation écartée."); }
            if (reading.Status == SourceStatus.Ok && reading.ConsoleUser is { } account)
            {
                var reason = "Compte local, non qualifié, étranger ou illisible ; aucune recherche par homonymie.";
                RelationObject? user = null;
                var filter = account.Length is > 0 and <= 320 && !account.Any(char.IsControl) ? AdSessionIdentity.Filter(domain, account, null, true) : null;
                if (filter is not null)
                {
                    var found = await directory.SearchAsync(new(domain.RootDn, filter, AdSearchScope.Subtree, AdRelationDirectory.Attributes)
                    { SizeLimit = 2, PageSize = 1, Timeout = TimeSpan.FromSeconds(3), Budget = TimeSpan.FromSeconds(3), ExpandRanges = false }, budget.Token).ConfigureAwait(false);
                    if (found.Count == 1 && AdRelationDirectory.Map(found[0], domain) is { Kind: RelationSubjectKind.User } candidate
                        && candidate.Created is { } created && created <= at)
                    {
                        var match = RelationRules.MatchAccount(new(candidate.Login, domain.NetbiosName, domain.DnsName, candidate.Sid, candidate.Upn), account, null, computer.Name);
                        reason = match.Reason; if (match.Match) { user = candidate; }
                    }
                    else { reason = "Compte absent, ambigu, illisible ou créé après l’observation ; aucun lien confirmé."; }
                }
                var badge = RelationRules.BadgeOf(user is null ? RelationKind.Unknown : RelationKind.Console);
                observed = new(RelationRules.Flat(account, 320), user?.Login ?? RelationRules.ParseAccount(account).Login, user?.Dn, user?.Guid.ToString("D"), user?.Name,
                    user is not null, false, reason, RelationRules.ConsoleSource, user is null ? RelationKind.Unknown : RelationKind.Console, badge.Badge, badge.Label, at.Value);
                Attempt("Identité du compte AD", user is null ? "A_REVOIR" : "CONFIRME", reason, "Annuaire");
                if (user is not null)
                {
                    relation = new(user.Login, user.Guid, user.Dn, computer.Name, computer.Guid, computer.Dn, RelationKind.Console, RelationRules.ConsoleSource, at,
                        (nativeRead is null ? "Console lue par CIM/DCOM" : "Console reçue dans l’inventaire CIM")
                            + " à cette date ; SID du jeton non lu, sessions RDP non recensées. Identités AD vérifiées ; aucune affectation déduite.", true, null, null);
                    message = "Console observée : " + user.Login + " sur " + computer.Name + ". SID du jeton non lu ; aucune affectation déclarée remplacée.";
                }
                else { message = reason + " Associations existantes conservées."; }
            }
            else { message = "Aucun compte de console à la date de lecture ; les sessions RDP ne sont pas recensées. Associations existantes conservées."; }
            // A recreated, renamed or redirected parent invalidates even a negative console reading.
            var last = await AdRelationDirectory.ExactAsync(directory, domain, computer.Dn, computer.Guid, false, budget.Token).ConfigureAwait(false);
            if (last.Object.Kind != RelationSubjectKind.Computer || last.Object.Sid != computer.Sid || last.Object.Created != computer.Created
                || !string.Equals(last.Object.Login, computer.Login, StringComparison.OrdinalIgnoreCase)
                || !string.Equals(last.Entry.String("dNSHostName"), host, StringComparison.OrdinalIgnoreCase))
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Identité du poste modifiée pendant la lecture ; aucun résultat publié."); }
            directory.EnsureCurrent(); machine.EnsureCurrent(); EnsureEpoch(epoch); budget.Token.ThrowIfCancellationRequested();
            verifiedAt = at;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        { relation = null; observed = null; status = "ARRETE"; message = "Budget de lecture atteint ; aucun résultat sans vérification finale."; Attempt("Validation finale", status, message, "Annuaire"); }
        catch (DomeniaOperationException ex) when (ex.Code is AdErrors.Timeout or AdErrors.Unavailable or AdErrors.AccessDenied or AdErrors.Credentials or MachineErrors.AccountPaused or "machine.busy")
        {
            relation = null; observed = null;
            status = ex.Code is AdErrors.Credentials or MachineErrors.AccountPaused ? "AUTH_REJETEE" : ex.Code == AdErrors.AccessDenied ? "REFUSE" : "NON_EFFECTUE";
            message = "Lecture ou validation refusée ou indisponible ; aucun autre compte essayé, associations conservées.";
            Attempt("Lecture et validation", status, message, "Annuaire");
        }
        EnsureEpoch(epoch); cancellationToken.ThrowIfCancellationRequested();
        return new(computer, attempts.ToImmutable(), observed, relation, status, message) { VerifiedAt = verifiedAt };
    }

    public async Task<RelationObservationReceipt> ObserveAsync(RelationObservationRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.Computer.Length is 0 or > 4096 || request.Account.Length is 0 or > 320 || request.Source.Length is 0 or > 512
            || request.Detail?.Length > 16_384 || request.ObservedAt == DateTimeOffset.MinValue || request.ObservedAt > source.Clock.GetUtcNow())
        { return new(false, null, "Observation reçue hors contrat ; aucun lien créé."); }
        var local = await LocalAsync(cancellationToken, withJournal: false).ConfigureAwait(false);
        var pc = local.Lookup.Find(request.Computer); var user = local.Lookup.Find(request.Account);
        if (pc is not { Kind: RelationSubjectKind.Computer } || user is not { Kind: RelationSubjectKind.User })
        { return new(false, null, "Identités locales absentes ou ambiguës ; observation non qualifiée."); }
        var match = RelationRules.MatchAccount(new(user.Login, local.Directory.Domain.NetbiosName, local.Directory.Domain.DnsName, user.Sid, user.Upn), request.Account, null, pc.Name);
        if (!match.Match) { return new(false, null, match.Reason); }
        // This public DTO is not network evidence. Only acknowledge an observation already held by a native producer.
        var matches = local.Session.Where(r => r.UserGuid == user.Guid && r.ComputerGuid == pc.Guid && r.When == request.ObservedAt
            && r.Source == request.Source && r.Kind is RelationKind.Console or RelationKind.RemoteSession).ToArray();
        var known = matches.Length == 1 ? matches[0] : null;
        return known is null ? new(false, null, "Aucune observation native correspondante en attente ; les textes d’un écran ne prouvent pas une session distante.")
            : new(true, RelationRules.Key(known), "Observation native déjà qualifiée dans la session ; date et contenu conservés sans modification.");
    }
}
