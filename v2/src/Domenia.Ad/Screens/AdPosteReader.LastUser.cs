using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Ad;

public sealed partial class AdPosteReader
{
    private sealed record DetectedUser(UserRef User, DateTimeOffset ReadAt, DateTimeOffset? EvidenceAt, string Source, bool History, bool SidCompared);
    private static readonly string[] UserIdentityAttributes = [.. AdSessionIdentity.Attributes, "whenCreated"];

    private static string DetectionMethod(UserDetectionSource source) => source switch
    {
        UserDetectionSource.Console => "CIM utilisateur courant",
        UserDetectionSource.LogonUi => "LogonUI (dernier nom affiché)",
        UserDetectionSource.Security => "Journal Sécurité 4624 (optionnel)",
        _ => "Profils CIM par SID",
    };

    public async Task<LastUserDetection> DetectLastUserAsync(string dn, IProgress<PosteProgress>? progress, CancellationToken cancellationToken)
    {
        using var timeout = new CancellationTokenSource(CimBudgets.LastUser, source.Clock);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(timeout.Token, cancellationToken);
        var local = await LocalAsync(dn, stop.Token).ConfigureAwait(false);
        var memory = await AdRelationPassMemory.BeginAsync(source, local.Directory.Domain.RootDn, local.Epoch, stop.Token).ConfigureAwait(false);
        RelationSweepUpdate? consolePass = null;
        var attempts = ImmutableArray.CreateBuilder<DetectionAttempt>();
        var old = Association(local);
        void Attempt(string method, string status, string detail, int duration = 0, string? candidate = null)
        {
            var label = RelationRules.AttemptStatus(status);
            attempts.Add(new(attempts.Count + 1, method, status, label.Label, label.Tone, duration, detail, candidate));
        }
        Attempt("Association locale", old.User is null ? "VIDE" : "LU", old.Text);
        DetectedUser? detected = null;
        using var directory = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, dn, stop.Token).ConfigureAwait(false);
        async Task ConfirmParent()
        {
            var parent = await SecretComputerAsync(local, directory, ["objectGUID", "objectClass", "objectSid", "whenCreated", "dNSHostName", "sAMAccountName"], stop.Token).ConfigureAwait(false);
            if (parent.Time("whenCreated") != local.Computer.WhenCreated || parent.Sid("objectSid") != local.Computer.Sid
                || !string.Equals(parent.String("dNSHostName"), local.Computer.DnsHostName, StringComparison.OrdinalIgnoreCase)
                || !string.Equals(parent.String("sAMAccountName"), local.Computer.SamAccountName, StringComparison.OrdinalIgnoreCase))
            { throw new DomeniaOperationException(PosteErrors.ComputerUnknown, "Identité du poste modifiée ; relisez sa fiche avant une nouvelle détection."); }
        }
        try
        {
            await ConfirmParent().ConfigureAwait(false);
            if (local.Computer.DnsHostName is not { } host || !CimQuery.IsHostName(host) || WorkstationIdentity.ExpectedName(local.Computer) is null)
            { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Compte machine et nom DNS incohérents ; aucun contact distant."); }
            using var machine = await AdWorkstationAccess.AcquireAsync(source, host, stop.Token).ConfigureAwait(false);
            var reader = InventoryReader(machine);
            foreach (var kind in Enum.GetValues<UserDetectionSource>())
            {
                stop.Token.ThrowIfCancellationRequested(); directory.EnsureCurrent(); machine.EnsureCurrent(); EnsureEpoch(local.Epoch);
                var method = DetectionMethod(kind);
                progress?.Report(new((int)kind + 1, Enum.GetValues<UserDetectionSource>().Length, method));
                var read = kind == UserDetectionSource.Security
                    ? await new WindowsLastUserEventsReader(source.Clock).ReadAsync(host, local.Computer.WhenCreated, machine.Settings, machine.Credential, stop.Token).ConfigureAwait(false)
                    : await reader.ReadUserSourceAsync(host, kind, stop.Token, machine.Credential).ConfigureAwait(false);
                directory.EnsureCurrent(); machine.EnsureCurrent(); EnsureEpoch(local.Epoch);
                if (read.ReportedName is not null) { ConfirmIdentity(local.Computer, read.ReportedName); }
                if (read.Access.Status == SourceStatus.Refused || read.Access.AuthenticationRejected)
                { machine.Refused(host, "Détection du dernier utilisateur", read.Access.AuthenticationRejected); }
                if (kind == UserDetectionSource.Console)
                {
                    var passStatus = read.Access.AuthenticationRejected ? "AUTH_REJETEE" : read.Access.Status switch
                    {
                        SourceStatus.Empty when WorkstationIdentity.Matches(local.Computer, read.ReportedName) => "LU",
                        SourceStatus.Refused => "REFUSE", SourceStatus.Interrupted => "DELAI", _ => "ERREUR",
                    };
                    consolePass = new(local.Computer.ObjectGuid, local.Computer.DistinguishedName, WorkstationIdentity.ExpectedName(local.Computer)!,
                        source.Clock.GetUtcNow(), passStatus, read.Candidates.Length == 1 ? read.Candidates[0].Account : null);
                }
                if (read.Access.AuthenticationRejected)
                { Attempt(method, "AUTH_REJETEE", "Compte machine suspendu ; aucune autre source ni aucun autre compte essayé.", read.Access.DurationMs); break; }
                var state = read.Access.Status switch
                {
                    SourceStatus.Ok or SourceStatus.Empty => read.Candidates.Length == 0 ? "VIDE" : "LU",
                    SourceStatus.Partial => "A_REVOIR", SourceStatus.Refused => "REFUSE", SourceStatus.Skipped => "IGNORE",
                    SourceStatus.Interrupted => "ARRETE", _ => "NON_EFFECTUE",
                };
                Attempt(method, state, read.Access.Detail, read.Access.DurationMs);
                foreach (var candidate in read.Candidates)
                {
                    var begin = source.Clock.GetTimestamp();
                    var (user, reason) = await ResolveDetectedUserAsync(local, directory, candidate, stop.Token).ConfigureAwait(false);
                    Attempt("Vérification AD · " + candidate.Origin, user is null ? "A_REVOIR" : "CONFIRME", reason,
                        (int)source.Clock.GetElapsedTime(begin).TotalMilliseconds, PosteText.Flat(candidate.Account ?? candidate.Sid ?? "", 320));
                    if (user is null) { continue; }
                    detected = new(user, source.Clock.GetUtcNow(), candidate.EvidenceAt, candidate.Origin, kind != UserDetectionSource.Console, candidate.Sid is not null);
                    break;
                }
                if (detected is not null) { break; }
            }
            if (detected is not null || consolePass?.Status == "LU")
            {
                await ConfirmParent().ConfigureAwait(false);
                directory.EnsureCurrent(); machine.EnsureCurrent(); EnsureEpoch(local.Epoch);
                if (detected is not null)
                {
                    Recent(local.Computer.ObjectGuid, local.Epoch, new(detected.ReadAt, Detected: detected));
                    if (!detected.History && consolePass is not null) { consolePass = consolePass with { Status = "CONFIRME" }; }
                }
            }
        }
        catch (OperationCanceledException)
        { detected = null; consolePass = null; Attempt("Détection", "ARRETE", "Arrêt ou budget de 25 secondes atteint ; aucun nouveau lien publié sans vérification finale."); }
        catch (DomeniaOperationException ex) when (ex.Code is AdErrors.Timeout or AdErrors.Credentials or AdErrors.AccessDenied or AdErrors.Unavailable or MachineErrors.AccountPaused or "machine.busy")
        { detected = null; consolePass = null; Attempt("Détection", ex.Code is AdErrors.Credentials or AdErrors.AccessDenied or MachineErrors.AccountPaused ? "REFUSE" : "NON_EFFECTUE", "Lecture ou validation AD non aboutie ; association existante conservée, aucun autre compte essayé."); }
        directory.EnsureCurrent(); EnsureEpoch(local.Epoch); cancellationToken.ThrowIfCancellationRequested();
        string? memorization = null;
        if (detected is { User.Guid: { } userGuid, User.Dn: { } userDn })
        {
            var shared = AdRelationSession.For(source);
            var relation = new StoredRelation(detected.User.Login, userGuid, userDn, WorkstationIdentity.ExpectedName(local.Computer)!,
                local.Computer.ObjectGuid, local.Computer.DistinguishedName, detected.History ? RelationKind.History : RelationKind.Console,
                detected.Source, detected.History ? detected.EvidenceAt : detected.EvidenceAt ?? detected.ReadAt,
                "Détection du dernier utilisateur. " + (detected.History ? "Historique ; date de connexion " + (detected.EvidenceAt is null ? "inconnue. " : "lue dans la source. ") : "Console à la date de lecture. ")
                    + (detected.SidCompared ? "SID comparé à AD." : "Nom de domaine résolu ; SID de l’observation non lu."), true, null, null);
            var receipt = shared.ObserveValidated(relation, local.Epoch);
            memorization = receipt.Reason;
            if (receipt.Accepted)
            {
                try { memorization = (await shared.SaveAsync(local.Epoch, stop.Token).ConfigureAwait(false)).Text; }
                catch (OperationCanceledException) { memorization = "Observation confirmée gardée dans la session ; mémorisation locale différée après arrêt."; }
            }
            EnsureEpoch(local.Epoch);
        }
        string? passageNotice = null;
        if (consolePass is not null) { passageNotice = await memory.CompleteAsync(consolePass, cancellationToken).ConfigureAwait(false); }
        var association = Association(local);
        var verdict = detected is null ? "Aucun nouveau compte confirmé ; l’association existante est conservée."
            : "Compte AD résolu : " + detected.User.Name + " (" + detected.User.Login + "). "
                + (detected.History ? "Indice historique, pas une session actuelle. " : "Nom observé à la console. ")
                + (detected.SidCompared ? "SID comparé à l’annuaire. " : "Le SID de l’observation n’a pas été lu. ")
                + "Aucune affectation déclarée remplacée. " + memorization;
        if (passageNotice is not null) { verdict += " " + passageNotice; }
        return new(local.Computer.Name, source.Clock.GetUtcNow(), attempts.ToImmutable(), detected?.User, detected is not null, verdict, association, 25);
    }

    private async Task<(UserRef? User, string Reason)> ResolveDetectedUserAsync(LocalPoste local, AdReadAccess directory, WorkstationUserCandidate candidate, CancellationToken token)
    {
        var domain = local.Directory.Domain;
        if (candidate.Account is { } account && (account.Length > 320 || account.Any(char.IsControl))
            || candidate.Sid is { } sid && (!AccountsRules.IsDomainSid(sid) || !sid.StartsWith(domain.DomainSid + "-", StringComparison.OrdinalIgnoreCase)))
        { return (null, "Compte local, autorité étrangère ou identité invalide ; aucun nom réattribué au domaine."); }
        var filter = AdSessionIdentity.Filter(domain, candidate.Account ?? "", candidate.Sid, candidate.Sid is null);
        if (filter is null) { return (null, "Nom non qualifié, local ou d’une autre autorité ; aucune recherche par simple homonymie."); }
        var rows = await directory.SearchAsync(new(domain.RootDn, filter, AdSearchScope.Subtree, UserIdentityAttributes)
        { PageSize = 1, SizeLimit = 2, Timeout = TimeSpan.FromSeconds(3), Budget = TimeSpan.FromSeconds(3), ExpandRanges = false }, token).ConfigureAwait(false);
        if (rows.Count != 1) { return (null, "Compte AD non visible ou ambigu ; candidat non confirmé."); }
        var entry = rows[0]; var foundSid = entry.Sid("objectSid"); var sam = entry.String("sAMAccountName"); var created = entry.Time("whenCreated");
        if (!ValidDn(entry.DistinguishedName) || !ScopeRules.Contains(new(domain.RootDn, "", true), entry.DistinguishedName)
            || !HasClass(entry, "user") || HasClass(entry, "computer") || entry.Guid("objectGUID") is not { } id || id == Guid.Empty
            || foundSid is null || !foundSid.StartsWith(domain.DomainSid + "-", StringComparison.OrdinalIgnoreCase) || string.IsNullOrWhiteSpace(sam)
            || created is null || created == DateTimeOffset.MinValue || created > source.Clock.GetUtcNow()
            || candidate.EvidenceAt is { } at && at < created)
        { return (null, "Identité AD ou dates incohérentes ; candidat écarté."); }
        var match = RelationRules.MatchAccount(new(sam, domain.NetbiosName, domain.DnsName, foundSid, entry.String("userPrincipalName")), candidate.Account, candidate.Sid, local.Computer.DnsHostName);
        if (!match.Match) { return (null, match.Reason); }
        return (new(entry.String("displayName") ?? sam, sam, entry.DistinguishedName, id), match.Reason + " Compte AD résolu à la date de lecture ; affectation non déduite.");
    }
}
