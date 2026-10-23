using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;

namespace Domenia.Ad;

public sealed partial class AdPosteReader
{
    private const int SecretIndexCap = 50_000;
    private static string DnKey(string dn) => DistinguishedName.Format(DistinguishedName.Parse(dn)).ToUpperInvariant();
    private static bool ValidDn(string dn)
    {
        try { return DistinguishedName.Parse(dn).Length > 1; }
        catch (FormatException) { return false; }
    }
    private static AdSearchRequest IndexComputers(ScopeSelection scope, bool full) => new(scope.Dn,
        "(&(objectCategory=computer)(!(userAccountControl:1.2.840.113556.1.4.803:=8192)))",
        scope.Subtree ? AdSearchScope.Subtree : AdSearchScope.OneLevel,
        full ? [.. AdDirectoryMapper.ComputerAttributes, "objectClass"] : ["objectGUID", "objectClass", "whenCreated"])
    { PageSize = 500, SizeLimit = SecretIndexCap + 1, ExpandRanges = full, MaxRangeValues = 4096, Timeout = TimeSpan.FromSeconds(12), Budget = TimeSpan.FromSeconds(60) };

    private SecretPresenceRead CountRecovery(string dn, IReadOnlyList<AdEntry> entries, bool partial, DateTimeOffset at)
    {
        var keys = entries.Select(e => (Entry: e, Key: RecoveryInfo(e, dn, source.Zone))).ToArray();
        partial |= keys.Any(k => k.Key is null || k.Key.CreatedAt > at);
        var duplicate = keys.Where(k => k.Key is not null).GroupBy(k => k.Key!.KeyGuid, StringComparer.OrdinalIgnoreCase).Where(g => g.Count() > 1)
            .Select(g => g.Key).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var duplicateObjects = entries.GroupBy(e => e.Guid("objectGUID")).Where(g => g.Count() > 1).Select(g => g.Key).ToHashSet();
        var duplicateDns = entries.Where(e => ValidDn(e.DistinguishedName)).GroupBy(e => DnKey(e.DistinguishedName))
            .Where(g => g.Count() > 1).Select(g => g.Key).ToHashSet();
        partial |= duplicate.Count > 0 || duplicateObjects.Count > 0 || duplicateDns.Count > 0;
        var valid = keys.Where(k => k.Key is not null && !(k.Key.CreatedAt > at) && !duplicate.Contains(k.Key.KeyGuid)
            && !duplicateObjects.Contains(k.Entry.Guid("objectGUID")) && !duplicateDns.Contains(DnKey(k.Entry.DistinguishedName)))
            .Select(k => k.Key!).ToArray();
        var dates = valid.Select(k => k.CreatedAt).OfType<DateTimeOffset>().Where(d => d <= at).ToArray();
        return new(at, partial ? valid.Length > 0 ? FactState.Estimated : FactState.Unknown : FactState.Observed,
            partial && valid.Length == 0 ? null : valid.Length, dates.Length > 0 ? dates.Max() : null);
    }

    public async Task<SecretsIndex> SecretsIndexAsync(ScopeSelection scope, IProgress<PosteProgress>? progress, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(scope);
        var local = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        AdDirectoryReader.EnsureScope(scope, local.Directory.Domain.RootDn);
        var epoch = source.Epoch;
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(180), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        // One identity for this OU-wide gesture. Accounts granted for one computer do not silently widen to its OU.
        using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.BitLocker, scope.Dn, budget.Token).ConfigureAwait(false);
        progress?.Report(new(0, 0, "Lecture des postes de l’OU, sans secret"));
        var raw = await access.SearchAsync(IndexComputers(scope, full: true), budget.Token).ConfigureAwait(false);
        var at = source.Clock.GetUtcNow();
        var candidates = new List<DirectoryComputer>(); var partial = raw.Count > SecretIndexCap;
        foreach (var entry in raw.Take(SecretIndexCap))
        {
            if (!ValidDn(entry.DistinguishedName)) { partial = true; continue; }
            var computer = HasClass(entry, "computer") && entry.Int("userAccountControl") is { } uac && (uac & AdValues.ServerTrustAccount) == 0
                ? AdDirectoryMapper.Computer(entry) : null;
            if (computer is null || computer.ObjectGuid == Guid.Empty || computer.WhenCreated == DateTimeOffset.MinValue || computer.WhenCreated > at
                || !computer.Sid.StartsWith(local.Directory.Domain.DomainSid + "-", StringComparison.Ordinal) || !ScopeRules.Contains(scope, computer.DistinguishedName))
            { partial = true; continue; }
            candidates.Add(computer);
        }
        var duplicateIds = candidates.GroupBy(c => c.ObjectGuid).Where(g => g.Count() > 1).Select(g => g.Key).ToHashSet();
        var duplicateDns = candidates.GroupBy(c => DnKey(c.DistinguishedName)).Where(g => g.Count() > 1).Select(g => g.Key).ToHashSet();
        partial |= duplicateIds.Count > 0 || duplicateDns.Count > 0;
        var computers = candidates.Where(c => !duplicateIds.Contains(c.ObjectGuid) && !duplicateDns.Contains(DnKey(c.DistinguishedName)))
            .OrderBy(c => c.Name, PosteText.French).ThenBy(c => c.ObjectGuid).ToArray();
        access.EnsureCurrent(); EnsureEpoch(epoch);
        // Full computer projections only, with bounded expanded membership; never mark the whole OU census complete here.
        await source.RememberObjectsAsync(new(local.Directory.Domain, at, false, [], [], [.. computers], []), epoch, CancellationToken.None).ConfigureAwait(false);
        var before = source.FleetDetails;
        var reads = new Dictionary<Guid, SecretPresenceRead>();
        var reason = "Lecture complète des objets visibles avec ce compte.";
        var fallbackState = FactState.Unknown;
        try
        {
            if (scope.Subtree && computers.Length > 0)
            {
                var keys = await access.SearchAsync(SecretQuery(scope.Dn, "(objectClass=msFVE-RecoveryInformation)", AdSearchScope.Subtree, RecoveryMetadata, 100_001)
                    with { PageSize = 500, Budget = TimeSpan.FromSeconds(90) }, budget.Token).ConfigureAwait(false);
                var capped = keys.Count > 100_000;
                var byDn = computers.ToDictionary(c => DnKey(c.DistinguishedName));
                var groups = new Dictionary<Guid, List<AdEntry>>();
                foreach (var key in keys.Take(100_000))
                {
                    if (!ValidDn(key.DistinguishedName)) { capped = true; continue; }
                    var parent = DistinguishedName.Parent(key.DistinguishedName);
                    if (parent is null || !byDn.TryGetValue(DnKey(parent), out var computer)) { capped = true; continue; }
                    if (!groups.TryGetValue(computer.ObjectGuid, out var bucket)) { groups[computer.ObjectGuid] = bucket = []; }
                    bucket.Add(key);
                }
                // Reread parent identities after the subtree scan; a new holder of the same DN must not inherit key counts.
                var confirmed = await access.SearchAsync(IndexComputers(scope, full: false), budget.Token).ConfigureAwait(false);
                partial |= confirmed.Count > SecretIndexCap;
                var identities = confirmed.Where(e => HasClass(e, "computer") && ValidDn(e.DistinguishedName)).GroupBy(e => DnKey(e.DistinguishedName))
                    .Where(g => g.Count() == 1).ToDictionary(g => g.Key, g => g.Single());
                foreach (var computer in computers)
                {
                    if (!identities.TryGetValue(DnKey(computer.DistinguishedName), out var current) || current.Guid("objectGUID") != computer.ObjectGuid || current.Time("whenCreated") != computer.WhenCreated)
                    { partial = true; continue; }
                    reads[computer.ObjectGuid] = CountRecovery(computer.DistinguishedName, groups.GetValueOrDefault(computer.ObjectGuid) ?? [], capped, source.Clock.GetUtcNow());
                }
                partial |= capped;
                progress?.Report(new(computers.Length, computers.Length, "Métadonnées BitLocker lues ; aucune clé demandée"));
            }
            else
            {
                // A non-recursive OU selection never sends a subtree query that would touch deeper OUs.
                foreach (var computer in computers)
                {
                    budget.Token.ThrowIfCancellationRequested();
                    var keys = await access.SearchAsync(SecretQuery(computer.DistinguishedName, "(objectClass=msFVE-RecoveryInformation)", AdSearchScope.OneLevel,
                        RecoveryMetadata, PosteSecrets.BitLockerCap + 1), budget.Token).ConfigureAwait(false);
                    var check = await access.SearchAsync(SecretQuery(computer.DistinguishedName, AdObjectAccess.GuidFilter(computer.ObjectGuid), AdSearchScope.Base,
                        ["objectGUID", "objectClass", "whenCreated"]), budget.Token).ConfigureAwait(false);
                    if (check.Count != 1 || !HasClass(check[0], "computer") || !DistinguishedName.AreEqual(check[0].DistinguishedName, computer.DistinguishedName)
                        || check[0].Guid("objectGUID") != computer.ObjectGuid || check[0].Time("whenCreated") != computer.WhenCreated)
                    { partial = true; continue; }
                    var capped = keys.Count > PosteSecrets.BitLockerCap;
                    reads[computer.ObjectGuid] = CountRecovery(computer.DistinguishedName, keys.Take(PosteSecrets.BitLockerCap).ToArray(), capped, source.Clock.GetUtcNow());
                    partial |= capped;
                    progress?.Report(new(reads.Count, computers.Length, "Métadonnées BitLocker lues ; aucune clé demandée"));
                }
            }
        }
        catch (OperationCanceledException) { partial = true; reason = "Lecture arrêtée ; seuls les constats déjà confirmés sont conservés."; }
        catch (DomeniaOperationException ex) when (ex.Code is AdErrors.Timeout or AdErrors.Credentials or AdErrors.AccessDenied or MachineErrors.AccountPaused or AdErrors.Unavailable)
        {
            partial = true;
            fallbackState = ex.Code is AdErrors.Credentials or AdErrors.AccessDenied or MachineErrors.AccountPaused ? FactState.Refused : FactState.Unavailable;
            reason = fallbackState == FactState.Refused ? "Lecture refusée ; aucun autre compte essayé." : "Lecture non aboutie ; couverture partielle.";
        }
        access.EnsureCurrent(); EnsureEpoch(epoch);
        partial |= reads.Count < computers.Length || reads.Values.Any(r => r.State != FactState.Observed);
        if (partial && reason == "Lecture complète des objets visibles avec ce compte.")
        { reason = "Lecture partielle : les réponses absentes, plafonnées ou ambiguës restent non concluantes."; }
        var patches = ImmutableDictionary.CreateBuilder<Guid, WorkstationSecretMetadata>();
        var rows = ImmutableArray.CreateBuilder<SecretsIndexRow>();
        foreach (var computer in computers)
        {
            var current = reads.GetValueOrDefault(computer.ObjectGuid) ?? new(source.Clock.GetUtcNow(), fallbackState, null, null);
            partial |= current.State != FactState.Observed;
            var laps = new LapsMetadataRead(at, computer.Laps, computer.LapsExpiration is >= 0 && (computer.LapsExpiration == 0 || AdValues.FromFileTime(computer.LapsExpiration) is not null)
                ? computer.LapsExpiration : null, computer.Laps == LapsKind.None ? FactState.Unknown : FactState.Observed);
            var metadata = PosteSecretCache.Merge(StoredSecrets(before, computer), new(current, null, laps));
            PosteSecretCache.Validate(metadata, source.Clock.GetUtcNow()); patches[computer.ObjectGuid] = metadata;
            var retained = current.Keys is > 0 ? current : metadata.LastPositive ?? current;
            var historic = current.Keys is not > 0 && metadata.LastPositive is not null;
            var expiration = AdValues.FromFileTime(laps.Expiration);
            rows.Add(new(computer.DistinguishedName, computer.Name, retained.Keys, historic ? FactState.Estimated : current.State, expiration,
                laps.Expiration == 0 || expiration < at, computer.Laps == LapsKind.None ? "Unknown" : computer.Laps.ToString())
            {
                BitLockerReadAt = retained.Keys is null ? null : retained.At,
                Detail = historic ? "Dernière présence positive conservée à sa date d’origine ; " + reason
                    : current.State == FactState.Observed ? "Objets visibles avec ce compte ; zéro ne prouve pas l’absence de clés." : reason,
            });
        }
        if (patches.Count > 0)
        { await source.SaveFleetAsync(FleetCachePatch.Empty with { WorkstationSecrets = patches.ToImmutable() }, epoch, CancellationToken.None).ConfigureAwait(false); }
        access.EnsureCurrent(); EnsureEpoch(epoch);
        var list = rows.ToImmutable();
        var positive = list.Count(r => r.BitLockerKeys > 0); var empty = list.Count(r => r.BitLockerKeys == 0);
        var refused = computers.Count(c => (reads.GetValueOrDefault(c.ObjectGuid)?.State ?? fallbackState) == FactState.Refused);
        var unknown = list.Count(r => r.BitLockerKeys is null); var lapsMissing = list.Count(r => r.LapsExpiration is null && !r.LapsExpired);
        return new(scope, source.Clock.GetUtcNow(), computers.Length, positive, empty, refused, list.Count(r => r.LapsExpired), lapsMissing, partial,
            FrenchText.Count(computers.Length, "poste", "postes") + " de l’OU " + scope.Label + " · " + positive + " avec présence BitLocker datée, " + empty + " sans objet visible, " + unknown + " non concluants. "
            + (partial ? "Couverture partielle. " : "") + reason + " Compte de l’index : " + access.Account + ". Aucune clé ni aucun mot de passe demandé.", list)
        { Unknown = unknown, Identity = access.Account };
    }
}
