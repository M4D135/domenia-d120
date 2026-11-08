using System.Collections.Immutable;
using System.Net;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Ad;

public sealed partial class AdRelationsReader
{
    private sealed record HarvestPair(RelationObject User, RelationObject Computer, DateTimeOffset First, DateTimeOffset Last, int Events, ImmutableHashSet<int> LogonTypes);

    public async Task<RelationHarvestEstimate> HarvestEstimateAsync(int days, int maxEvents, CancellationToken cancellationToken)
    {
        if (days is < 1 or > 30 || maxEvents is < 200 or > 20_000)
        { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Moisson limitée à 1–30 jours et 200–20 000 événements."); }
        var local = await LocalAsync(cancellationToken, withJournal: false).ConfigureAwait(false);
        var controller = source.ControllerName;
        if (controller is null || !CimQuery.IsHostName(controller) || !controller.Contains('.') || IPAddress.TryParse(controller, out _))
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Contrôleur DNS de la session inconnu ; établissez la session annuaire avant de préparer la moisson."); }
        var now = source.Clock.GetUtcNow(); var accessVersion = source.AccountContext is { } context ? AccountAccess.From(context).SelectionVersion : 0;
        var estimate = new RelationHarvestEstimate("", days, maxEvents, controller, local.Lookup.Users.Count(), local.Lookup.Computers.Count(), 0, 120,
            "Lecture du journal Sécurité de " + controller + " sur " + FrenchText.Count(days, "jour", "jours") + ", jusqu’à " + FrenchText.Integer(maxEvents)
                + " événements. Volume réel inconnu avant lecture ; budget global de 120 secondes, dont 60 au plus pour le journal. Fin de fenêtre fixée à "
                + PosteText.LocalDateTime(now, source.Zone) + ". Les nombres de comptes et de postes décrivent l’index local uniquement. Aucun poste contacté ; "
                + "les adresses restent des indices. Seuls de nouveaux couples historiques qualifiés sont proposés à la mémorisation locale après votre lancement.", now.AddMinutes(15))
        { EstimateKnown = false };
        return AdRelationResults.For(source).Remember(id => new AdRelationHarvestPlan(estimate with { Id = id }, local.Stored.StoreId, now, accessVersion), local.Epoch).Estimate;
    }

    public async Task<RelationHarvest> HarvestAsync(string estimateId, CancellationToken cancellationToken)
    {
        if (!WritePlans.IsPlanId(estimateId)) { throw new DomeniaOperationException(RelationErrors.Expired, "Aperçu de moisson invalide."); }
        var local = await LocalAsync(cancellationToken, withJournal: false).ConfigureAwait(false); var domain = local.Directory.Domain;
        var results = AdRelationResults.For(source); var prepared = results.Recall<AdRelationHarvestPlan>(estimateId, local.Epoch);
        long AccessVersion() => source.AccountContext is { } context ? AccountAccess.From(context).SelectionVersion : 0;
        if (prepared.StoreId != local.Stored.StoreId || prepared.AccessVersion != AccessVersion()
            || !string.Equals(prepared.Estimate.Controller, source.ControllerName, StringComparison.OrdinalIgnoreCase))
        { throw new DomeniaOperationException(RelationErrors.Expired, "Base, compte ou contrôleur modifié depuis l’aperçu ; préparez de nouveau la moisson."); }
        if (!results.BeginProbe(local.Epoch)) { throw new DomeniaOperationException(RelationErrors.ProbeBusy, "Une lecture de relations est déjà en cours ; cet aperçu reste disponible."); }
        try
        {
            var held = results.Take<AdRelationHarvestPlan>(estimateId, local.Epoch); var estimate = held.Estimate;
            using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(120), source.Clock);
            using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
            using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, null, budget.Token).ConfigureAwait(false);
            // This small read validates RootDSE/domain through the same lease before sending its identity to the event service.
            _ = await access.SearchAsync(new(domain.RootDn, "(objectClass=domainDNS)", AdSearchScope.Base, ["objectGUID"])
            { PageSize = 1, SizeLimit = 1, Timeout = TimeSpan.FromSeconds(3), Budget = TimeSpan.FromSeconds(4), ExpandRanges = false }, budget.Token).ConfigureAwait(false);
            if (!string.Equals(access.Controller, estimate.Controller, StringComparison.OrdinalIgnoreCase))
            { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Contrôleur résolu différent de l’aperçu ; aucun journal de remplacement demandé."); }
            RelationLogReading reading;
            using (var credential = access.CopyNativeCredential())
            {
                reading = await (EventReaderOverride?.Invoke(source.Clock) ?? new WindowsRelationEventsReader(source.Clock))
                    .ReadAsync(new(estimate.Controller, held.To.AddDays(-estimate.Days), held.To, estimate.MaxEvents), credential, budget.Token).ConfigureAwait(false);
            }
            access.EnsureCurrent(); EnsureEpoch(local.Epoch); cancellationToken.ThrowIfCancellationRequested();
            if (reading.Status == SourceStatus.Refused) { access.ReportNativeRefusal(reading.AuthenticationRejected); }
            var partial = reading.Status is not (SourceStatus.Ok or SourceStatus.Empty); string? issue = partial ? reading.Detail : null;
            var authenticationRejected = reading.AuthenticationRejected;
            var machineCount = 0; var unresolved = 0; var hintEvents = new List<RelationLogEvent>();
            var users = new Dictionary<string, AdRelationDirectory.Read?>(StringComparer.OrdinalIgnoreCase);
            var computers = new Dictionary<string, AdRelationDirectory.Read?>(StringComparer.OrdinalIgnoreCase);
            var identities = new Dictionary<Guid, AdRelationDirectory.Read>(); var dns = new Dictionary<string, Guid>(StringComparer.OrdinalIgnoreCase); var conflicts = new HashSet<Guid>();
            var pairs = new Dictionary<(Guid User, Guid Computer), HarvestPair>();
            bool Register(AdRelationDirectory.Read value)
            {
                var obj = value.Object; var dn = DistinguishedName.Format(DistinguishedName.Parse(obj.Dn));
                if (dns.TryGetValue(dn, out var prior) && prior != obj.Guid) { conflicts.Add(prior); conflicts.Add(obj.Guid); partial = true; return false; }
                dns[dn] = obj.Guid;
                if (identities.TryGetValue(obj.Guid, out var previous) && (previous.Object.Kind != obj.Kind || previous.Object.Login != obj.Login
                    || previous.Object.Sid != obj.Sid || previous.Object.Created != obj.Created || !DistinguishedName.AreEqual(previous.Object.Dn, obj.Dn)
                    || previous.Object.Upn != obj.Upn || !string.Equals(previous.Entry.String("dNSHostName"), value.Entry.String("dNSHostName"), StringComparison.OrdinalIgnoreCase)))
                { conflicts.Add(obj.Guid); partial = true; return false; }
                identities[obj.Guid] = value; return !conflicts.Contains(obj.Guid);
            }
            async Task<AdRelationDirectory.Read?> Resolve(string filter, RelationSubjectKind kind, Func<AdRelationDirectory.Read, bool> matches)
            {
                var rows = await access.SearchAsync(new(domain.RootDn, filter, AdSearchScope.Subtree, AdRelationDirectory.Attributes)
                { PageSize = 2, SizeLimit = 2, Timeout = TimeSpan.FromSeconds(3), Budget = TimeSpan.FromSeconds(4), ExpandRanges = false }, budget.Token).ConfigureAwait(false);
                if (rows.Count != 1)
                {
                    if (rows.Count > 1) { partial = true; foreach (var row in rows.Take(2)) { if (row.Guid("objectGUID") is { } id) { conflicts.Add(id); } } }
                    return null;
                }
                try
                {
                    if (AdRelationDirectory.Map(rows[0], domain) is not { } obj || obj.Kind != kind || obj.Created > held.To) { return null; }
                    var value = new AdRelationDirectory.Read(rows[0], obj);
                    return matches(value) && Register(value) ? value : null;
                }
                catch (Exception ex) when (ex is DomeniaOperationException or ArgumentException or FormatException) { partial = true; return null; }
            }
            async Task<AdRelationDirectory.Read?> User(RelationLogEvent entry)
            {
                var login = entry.Account.Contains('@') || entry.Account.Contains('\\') ? entry.Account
                    : entry.Domain is { } authority ? authority + "\\" + entry.Account : entry.Account;
                var key = entry.UserSid is { } sid ? "sid:" + sid : "account:" + login;
                if (users.TryGetValue(key, out var saved)) { return saved; }
                if (users.Count >= 128) { partial = true; issue = "Limite de 128 identités utilisateur distinctes à résoudre ; événements suivants non résolus."; return null; }
                string? filter;
                if (entry.UserSid is { } userSid)
                { filter = userSid.StartsWith(domain.DomainSid + "-", StringComparison.OrdinalIgnoreCase) ? "(&" + AdDirectoryMapper.UserFilter + "(objectSid=" + SearchText.LdapLiteral(userSid) + "))" : null; }
                else { filter = AdSessionIdentity.Filter(domain, login, null, true); }
                bool Matches(AdRelationDirectory.Read value)
                {
                    if (entry.UserSid is not null) { return value.Object.Sid == entry.UserSid; }
                    var account = CredentialRules.Parse(login);
                    return account.Form == AccountNameForm.Upn ? string.Equals(value.Object.Upn, login, StringComparison.OrdinalIgnoreCase)
                        : string.Equals(value.Object.Login, account.Name, StringComparison.OrdinalIgnoreCase);
                }
                var found = filter is null ? null : await Resolve(filter, RelationSubjectKind.User, Matches).ConfigureAwait(false);
                users[key] = found; return found;
            }
            async Task<AdRelationDirectory.Read?> Computer(string name)
            {
                if (computers.TryGetValue(name, out var saved)) { return saved; }
                if (computers.Count >= 128) { partial = true; issue = "Limite de 128 noms de postes distincts à résoudre ; événements suivants non résolus."; return null; }
                if (!CimQuery.IsHostName(name) || IPAddress.TryParse(name, out _)) { computers[name] = null; return null; }
                var full = name.Contains('.'); var attribute = full ? "dNSHostName" : "sAMAccountName";
                var found = await Resolve("(&" + AdDirectoryMapper.ComputerFilter + "(" + attribute + "=" + SearchText.LdapLiteral(full ? name : name + "$") + "))",
                    RelationSubjectKind.Computer, value => (value.Entry.Int("userAccountControl")!.Value & 8192) == 0
                        && (full ? string.Equals(value.Entry.String("dNSHostName"), name, StringComparison.OrdinalIgnoreCase)
                            : string.Equals(value.Object.Name, name, StringComparison.OrdinalIgnoreCase))).ConfigureAwait(false);
                computers[name] = found; return found;
            }
            var ordered = reading.Events.OrderByDescending(e => e.At).ToArray();
            void CountUnfinished() => unresolved += Math.Max(0, ordered.Length - machineCount - unresolved - pairs.Values.Sum(p => p.Events));
            try
            {
                foreach (var entry in ordered)
                {
                    budget.Token.ThrowIfCancellationRequested(); access.EnsureCurrent();
                    var bare = entry.Account.Split('\\')[^1].Split('@')[0];
                    if (bare.EndsWith('$')) { machineCount++; continue; }
                    if (entry.Address is not null) { hintEvents.Add(entry); }
                    if (reading.Status == SourceStatus.Refused || entry.EventId != 4624 || entry.Workstation is null) { unresolved++; continue; }
                    var user = await User(entry).ConfigureAwait(false);
                    var computer = user is null ? null : await Computer(entry.Workstation).ConfigureAwait(false);
                    if (user is null || computer is null || user.Object.Created > entry.At || computer.Object.Created > entry.At
                        || conflicts.Contains(user.Object.Guid) || conflicts.Contains(computer.Object.Guid)) { unresolved++; continue; }
                    var key = (user.Object.Guid, computer.Object.Guid);
                    if (pairs.TryGetValue(key, out var pair))
                    { pairs[key] = pair with { First = entry.At < pair.First ? entry.At : pair.First, Last = entry.At > pair.Last ? entry.At : pair.Last,
                        Events = pair.Events + 1, LogonTypes = pair.LogonTypes.Add(entry.LogonType!.Value) }; }
                    else if (pairs.Count < 4096) { pairs[key] = new(user.Object, computer.Object, entry.At, entry.At, 1, [entry.LogonType!.Value]); }
                    else { unresolved++; partial = true; issue = "Limite de 4 096 couples historiques ; reliquat non mémorisé."; }
                }
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && elapsed.IsCancellationRequested)
            { partial = true; issue = "Budget global de 120 secondes atteint ; couples déjà qualifiés conservés."; CountUnfinished(); }
            catch (DomeniaOperationException ex) when (ex.Code is AdErrors.Credentials or AdErrors.AccessDenied or AdErrors.Timeout or AdErrors.Unavailable)
            {
                partial = true; authenticationRejected |= ex.Code == AdErrors.Credentials;
                issue = (ex.Code == AdErrors.Credentials ? "Identifiants rejetés pendant la résolution AD" : "Résolution AD interrompue ou refusée")
                    + " ; couples déjà qualifiés conservés, aucun autre compte essayé.";
                CountUnfinished();
            }
            access.EnsureCurrent(); EnsureEpoch(local.Epoch); cancellationToken.ThrowIfCancellationRequested();
            var latest = await LocalAsync(cancellationToken, withJournal: false).ConfigureAwait(false);
            access.EnsureCurrent(); EnsureEpoch(local.Epoch);
            if (latest.Stored.StoreId != held.StoreId) { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Base changée pendant la moisson ; aucun résultat transféré."); }
            if (latest.Stored.Truncated || latest.Stored.Rejected > 0)
            { partial = true; issue = "Associations locales partiellement lisibles ; observations conservées en attente, mémorisation différée."; }
            var known = latest.Stored.Rows.Select(r => r.Relation).Concat(latest.Session).Where(r => r.UserGuid is not null && r.ComputerGuid is not null)
                .Select(r => (r.UserGuid!.Value, r.ComputerGuid!.Value)).ToHashSet();
            var observations = ImmutableDictionary.CreateBuilder<string, StoredRelation>(StringComparer.Ordinal); var rowsOut = ImmutableArray.CreateBuilder<RelationHarvestCouple>();
            foreach (var (key, pair) in pairs.OrderByDescending(p => p.Value.Last))
            {
                if (conflicts.Contains(key.User) || conflicts.Contains(key.Computer)) { unresolved += pair.Events; partial = true; continue; }
                var relation = new StoredRelation(pair.User.Login, pair.User.Guid, pair.User.Dn, pair.Computer.Name, pair.Computer.Guid, pair.Computer.Dn, RelationKind.History,
                    RelationRules.HarvestSource, pair.Last, FrenchText.Count(pair.Events, "événement 4624", "événements 4624") + " sur " + estimate.Controller
                        + " ; types " + string.Join(", ", pair.LogonTypes.Order()) + ". Nom de station historique, identités actuelles relues dans AD ; "
                        + "ce relevé ne prouve ni session actuelle ni GUID du poste au moment de l’événement.", true, null, null);
                var relationKey = RelationRules.Key(relation); var existing = known.Contains(key); var accepted = false;
                if (!existing)
                {
                    var receipt = AdRelationSession.For(source).ObserveValidated(relation, local.Epoch); accepted = receipt.Accepted;
                    if (accepted) { observations[relationKey] = relation; }
                    else { partial = true; issue = receipt.Reason; }
                }
                rowsOut.Add(new(relationKey, pair.User.Login, pair.User.Name, pair.User.Dn, pair.Computer.Name, pair.Computer.Dn, pair.First, pair.Last,
                    RelationRules.WhenText(pair.Last, source.Clock.GetUtcNow(), source.Zone) ?? "", pair.Events, "4624", existing) { CanSave = accepted });
            }
            var groupedHints = hintEvents.GroupBy(e => e.Account + "\0" + e.Address, StringComparer.OrdinalIgnoreCase).Select(g => g.MaxBy(e => e.At)!).OrderByDescending(e => e.At).ToArray();
            var hints = groupedHints.Take(100).Select(e => new RelationHint(e.Address!, e.EventId + " · " + estimate.Controller, "Indice historique",
                "Compte indiqué : " + e.Account + ". Adresse cliente, sans résolution DNS inverse ni association automatique.", e.At)).ToImmutableArray();
            if (groupedHints.Length > 100) { partial = true; }
            var resultId = observations.Count == 0 ? WritePlans.NewId() : results.RememberObservations("Moisson du journal", observations.ToImmutable(), local.Epoch);
            var knownCount = rowsOut.Count(r => r.Known);
            var message = FrenchText.Count(reading.Read, "événement examiné", "événements examinés") + " sur " + estimate.Controller + ", "
                + FrenchText.Count(rowsOut.Count, "couple historique qualifié", "couples historiques qualifiés") + ", dont " + FrenchText.Count(knownCount, "déjà connu", "déjà connus") + ". "
                + FrenchText.Count(machineCount, "événement de compte machine ignoré", "événements de comptes machines ignorés") + ", "
                + FrenchText.Count(unresolved, "événement sans couple qualifié", "événements sans couple qualifié") + ". " + reading.Detail
                + " Aucun poste contacté ; 4768/4769 et adresses seules restent des indices. "
                + FrenchText.Count(observations.Count, "nouveau couple en attente de mémorisation locale", "nouveaux couples en attente de mémorisation locale") + "."
                + (partial ? " Résultat partiel." : "") + (issue is null ? "" : " " + issue)
                + (groupedHints.Length > 100 ? " Seules les cent premières adresses par compte sont affichées." : "");
            return new(resultId, estimate.Days, reading.Read, partial, machineCount, unresolved, rowsOut.ToImmutable(), observations.Count, knownCount, estimate.Controller, message)
            { Hints = hints, Rejected = reading.Rejected, Ignored = reading.Ignored, AuthenticationRejected = authenticationRejected };
        }
        finally { results.EndProbe(); }
    }
}
