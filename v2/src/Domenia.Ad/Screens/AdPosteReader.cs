using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;

namespace Domenia.Ad;

/// <summary>Real workstation console. Local entry points use only committed AD objects and GUID-bound observations.</summary>
public sealed partial class AdPosteReader
{
    private readonly AdDirectorySource source;
    private PosteConfiguration configuration = PosteConfiguration.Defaults;
    public AdPosteReader(AdDirectorySource source) { ArgumentNullException.ThrowIfNull(source); this.source = source; }
    public PosteOptions Options => Volatile.Read(ref configuration).Options;

    private void EnsureEpoch(long epoch)
    {
        if (source.Epoch != epoch) { throw new DomeniaOperationException(AdErrors.NotConnected, "Session modifiée pendant la lecture du poste ; résultat écarté."); }
    }

    private async Task<PosteConfiguration> SettingsAsync(CancellationToken token)
    {
        var value = source.AccountContext?.Readers.Find<IPosteSettingsReader>() is { } reader
            ? await reader.CurrentAsync(token).ConfigureAwait(false) : PosteConfiguration.Defaults;
        Volatile.Write(ref configuration, value);
        return value;
    }

    private sealed record LocalPoste(DirectorySnapshot Directory, DirectoryComputer Computer, CachedFleet Fleet, WorkstationObservation? Observation, long Epoch)
    {
        public ImmutableArray<StoredRelation> Relations { get; init; } = [];
        public string? RelationNotice { get; init; }
    }

    private async Task<LocalPoste> LocalAsync(string dn, CancellationToken token)
    {
        AdFicheObjects.ValidateDn(dn);
        var epoch = source.Epoch;
        var local = await source.ReadLocalAsync(token).ConfigureAwait(false);
        AdFicheObjects.EnsureDomain(dn, local.Directory.Domain.RootDn);
        var candidates = local.Directory.Computers.Where(c => DistinguishedName.AreEqual(c.DistinguishedName, dn)).Take(2).ToArray();
        if (candidates.Length != 1 || candidates[0].ObjectGuid == Guid.Empty)
        { throw new DomeniaOperationException(PosteErrors.ComputerUnknown, "Poste absent ou ambigu dans la base locale ; relisez sa fiche dans Rechercher."); }
        await SettingsAsync(token).ConfigureAwait(false);
        EnsureEpoch(epoch);
        var computer = candidates[0];
        var fleet = source.FleetDetails;
        var relations = await StoredRelationsAsync(token).ConfigureAwait(false); EnsureEpoch(epoch);
        return new(local.Directory, computer, fleet, fleet.Observations.Workstations.FirstOrDefault(o => o.ComputerGuid == computer.ObjectGuid), epoch)
        { Relations = new RelationLookup(relations).For(computer), RelationNotice = relations is { Truncated: true } or { Rejected: > 0 } or { UncertainDates: > 0 } ? relations.Notice : null };
    }

    private static InventorySnapshot? Inventory(LocalPoste local) => local.Fleet.Inventories.TryGetValue(local.Computer.ObjectGuid, out var inventory)
        && WorkstationIdentity.Matches(local.Computer, inventory.ReportedName) && inventory.CollectedAt >= local.Computer.WhenCreated ? inventory : null;

    private static Dictionary<string, string> Names(DirectorySnapshot directory) => directory.Users.Select(u => (Dn: u.DistinguishedName, Name: u.DisplayName ?? u.Cn))
        .Concat(directory.Groups.Select(g => (Dn: g.DistinguishedName, Name: g.Name))).GroupBy(v => v.Dn, StringComparer.OrdinalIgnoreCase)
        .ToDictionary(g => g.Key, g => g.First().Name, StringComparer.OrdinalIgnoreCase);

    private static PosteComputer Computer(LocalPoste local, IReadOnlyDictionary<string, string> names) => PosteHeaderRules.Computer(local.Computer, local.Directory, names) with
    {
        // An OU convention is not an AD site and the lack of visible LAPS metadata is not proof of absence.
        Site = Inventory(local)?.Site,
        LapsKind = local.Computer.Laps switch { LapsKind.Windows => "Windows LAPS", LapsKind.Legacy => "LAPS historique", _ => "LAPS non déterminé" },
    };

    private PresenceReading? Presence(LocalPoste local) => local.Observation?.Presence is { HasReading: true, CheckedAt: { } at } p && at >= local.Computer.WhenCreated
        ? new(p.Answered, null, null, at, p.LastOnlineAt, false, "Test ICMP daté de la base locale") : null;

    private PosteAssociation Association(LocalPoste local)
    {
        var computer = local.Computer;
        var declared = computer.ManagedByDn is { } dn
            ? local.Directory.Users.Where(u => DistinguishedName.AreEqual(u.DistinguishedName, dn)).Take(2).ToArray() : [];
        var detected = Recent(computer.ObjectGuid, local.Epoch)?.Detected;
        ImmutableArray<AssociationEvent> history = detected is null ? [] : [new(detected.ReadAt, detected.User.Login, detected.Source,
            "Lu pendant cette session. " + (detected.History ? "Indice historique ; pas une session actuelle. " : "Nom de console. ")
            + (detected.SidCompared ? "SID comparé." : "SID non comparé."))];
        if (StoredAssociation(local, declared: true, history) is { } storedDeclaration) { return storedDeclaration; }
        if (declared.Length == 1)
        {
            var user = declared[0];
            return PosteHeaderRules.Association(new(user.DisplayName ?? user.Cn, user.SamAccountName, user.DistinguishedName, user.ObjectGuid), AssociationBadge.Declared,
                "managedBy (annuaire)", local.Directory.ReadAt == DateTimeOffset.MinValue ? null : local.Directory.ReadAt,
                "Gestionnaire déclaré ; cela ne prouve pas qui utilise actuellement le poste", false, history, source.Zone);
        }
        if (detected is not null)
        {
            return PosteHeaderRules.Association(detected.User, detected.History ? AssociationBadge.History : AssociationBadge.Observed,
                detected.Source + " · session uniquement", detected.EvidenceAt ?? detected.ReadAt,
                (detected.EvidenceAt is null ? "Date de lecture, date de connexion inconnue. " : "")
                + "Compte AD résolu, aucune affectation déduite. " + (detected.SidCompared ? "SID comparé." : "SID de l’observation non lu."), detected.SidCompared, history, source.Zone);
        }
        if (StoredAssociation(local, declared: false, history) is { } storedObservation) { return storedObservation; }
        var machine = local.Fleet.Facts.Machines.GetValueOrDefault(computer.ObjectGuid);
        if (machine is { ConsoleAt: { } seen, ConsoleUser: { Length: > 0 } login } && seen >= computer.WhenCreated)
        {
            return PosteHeaderRules.Association(new(login, login, null, null), AssociationBadge.Observed, "Compte observé à la console", seen,
                "Nom observé sans GUID utilisateur enregistré ; aucune identité AD déduite du seul nom", false, [], source.Zone);
        }
        var empty = PosteHeaderRules.Association(null, AssociationBadge.None, "Base locale", null, "Aucune relation qualifiée pour ce poste", false, [], source.Zone);
        return local.Fleet.Facts.Associations > 0 ? empty with { Text = "Des associations existent dans la base ; elles ne sont pas encore qualifiées dans cette console." } : empty;
    }

    public async Task<PosteList> ListAsync(ScopeSelection? scope, string? text, int limit, PosteHealthPolicy policy, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(policy);
        if (limit is < 1 or > 1000 || text?.Length > 500) { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Liste limitée à 1 000 postes et filtre de 500 caractères."); }
        var epoch = source.Epoch;
        var local = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        if (scope is not null) { AdFicheObjects.ValidateDn(scope.Dn); AdFicheObjects.EnsureDomain(scope.Dn, local.Directory.Domain.RootDn); }
        var fleet = source.FleetDetails;
        var relations = await StoredRelationsAsync(cancellationToken).ConfigureAwait(false); EnsureEpoch(epoch);
        var relationIndex = new RelationLookup(relations);
        var observations = fleet.Observations.Workstations.ToDictionary(o => o.ComputerGuid);
        var names = Names(local.Directory);
        var words = FrenchText.Fold(text?.Trim() ?? "").Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var candidates = local.Directory.Computers.Where(c => (c.UserAccountControl & AdValues.ServerTrustAccount) == 0 && (scope is null || ScopeRules.Contains(scope, c.DistinguishedName)))
            .Select(c => new LocalPoste(local.Directory, c, fleet, observations.GetValueOrDefault(c.ObjectGuid), epoch)
            { Relations = relationIndex.For(c), RelationNotice = relations is { Truncated: true } or { Rejected: > 0 } or { UncertainDates: > 0 } ? relations.Notice : null })
            .Select(c => (Local: c, Association: Association(c)))
            .Where(c => words.All(w => FrenchText.Fold(string.Join(" ", c.Local.Computer.Name, c.Local.Computer.DnsHostName, c.Local.Computer.SamAccountName,
                c.Local.Computer.OperatingSystem, c.Local.Computer.Description, c.Association.User?.Name, c.Association.User?.Login, Inventory(c.Local)?.Site,
                DistinguishedName.Parent(c.Local.Computer.DistinguishedName))).Contains(w, StringComparison.Ordinal)))
            .OrderBy(c => c.Local.Computer.Name, PosteText.French).ThenBy(c => c.Local.Computer.ObjectGuid).ToArray();
        var now = source.Clock.GetUtcNow();
        var rows = ImmutableArray.CreateBuilder<PosteRow>();
        foreach (var item in candidates.Take(limit))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var c = Computer(item.Local, names);
            var inv = Inventory(item.Local);
            var badge = PosteHeaderRules.Badge(Presence(item.Local), source.Zone, now);
            var health = PosteBoardBuilder.Build(c, inv, policy, now, source.Zone).Health;
            rows.Add(new(c.Dn, c.Guid, c.Name, c.DnsName, c.Enabled, c.OperatingSystem, c.Release, c.Kind, c.Site, c.Ou.Name, item.Association.User,
                badge.State, badge.Label, badge.CheckedAt, inv?.CollectedAt, new(health.State, health.Alerts + health.Warnings, health.Verdict)));
        }
        EnsureEpoch(epoch);
        var coverage = local.Directory.CoversScope(scope ?? new(local.Directory.Domain.RootDn, "Domaine", true)) ? "" : " · base partielle sur ce périmètre";
        return new(scope, candidates.Length, rows.Count, candidates.Length > limit, text,
            FrenchText.Count(candidates.Length, "poste connu", "postes connus") + coverage + " · liste locale, aucune requête au poste.", rows.ToImmutable());
    }

    public async Task<PosteConsole> OpenAsync(string dn, PosteHealthPolicy policy, ConsentState consent, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(policy); ArgumentNullException.ThrowIfNull(consent);
        var local = await LocalAsync(dn, cancellationToken).ConfigureAwait(false);
        var now = source.Clock.GetUtcNow();
        var computer = Computer(local, Names(local.Directory));
        var inv = Inventory(local);
        var association = Association(local);
        var summary = inv is null ? null : new InventorySummary(inv.CollectedAt, inv.Deep, inv.Deep ? "Inventaire complet" : "Inventaire rapide", PosteText.Age(inv.CollectedAt, now),
            "Base locale (relevé daté)", inv.Access.Count(a => a.Status is SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial), inv.Access.Count(a => a.Status == SourceStatus.Refused), inv.DurationMs, PosteLabels.TransportLabel(inv.Transport));
        var header = PosteHeaderRules.Header(computer, PosteHeaderRules.Badge(Presence(local), source.Zone, now), association, summary,
            local.Directory.ReadAt == DateTimeOffset.MinValue ? null : local.Directory.ReadAt);
        var metadata = local.Fleet.Facts.BitLocker.Where(b => b.Machines.ContainsKey(computer.Guid) && local.Computer.WhenCreated != DateTimeOffset.MinValue
            && b.At >= local.Computer.WhenCreated && b.At <= now.AddMinutes(2)).OrderByDescending(b => b.At).FirstOrDefault();
        var count = metadata?.Machines.GetValueOrDefault(computer.Guid)?.Keys;
        var at = metadata?.At;
        var known = PosteSecretCache.Applicable(local.Fleet.WorkstationSecrets.GetValueOrDefault(computer.Guid), local.Computer.WhenCreated, now);
        var retained = known?.BitLocker is { Keys: > 0 } visible ? visible : known?.LastPositive ?? known?.BitLocker;
        var useRetained = retained is not null && (at is null || retained.At >= at);
        if (useRetained) { count = retained!.Keys; at = retained.At; }
        var historic = useRetained && known?.LastPositive is not null && known.BitLocker?.Keys is not > 0;
        var objectAt = local.Directory.ObjectReadAt?.GetValueOrDefault(computer.Guid, local.Directory.ReadAt) ?? local.Directory.ReadAt;
        var laps = known?.Laps is { } freshLaps && freshLaps.At >= objectAt ? freshLaps : null;
        var lapsExpiration = laps is null ? computer.LapsExpiration : AdValues.FromFileTime(laps.Expiration);
        var lapsKind = laps?.Kind switch { LapsKind.Windows => "Windows LAPS", LapsKind.Legacy => "LAPS historique", LapsKind.None => "LAPS non déterminé", _ => computer.LapsKind };
        var secrets = new SecretsSummary(count is null ? "Présence des clés BitLocker non lue pour ce poste ; aucune clé demandée." : FrenchText.Count(count.Value, "objet de récupération visible", "objets de récupération visibles")
                + (historic ? " lors du dernier constat positif conservé ; la lecture suivante n’a pas confirmé cette présence." : " lors du relevé daté ; aucune clé demandée."),
            count, at, lapsKind, lapsExpiration, laps?.Expiration == 0 || lapsExpiration < now, "Compte de lecture à confirmer au geste", "Métadonnées locales seulement",
            known?.BitLocker?.State == FactState.Refused, laps?.State == FactState.Refused);
        var notes = ImmutableArray.CreateBuilder<PosteFact>();
        if (local.Fleet.Inventories.ContainsKey(computer.Guid) && inv is null)
        { notes.Add(PosteText.Fact("Inventaire écarté", "Identité ou date incompatible avec le compte ordinateur", FactState.Unknown, "Base locale", "Relancez un relevé ; le contenu incompatible n’est pas affiché.", tone: Tone.Warn)); }
        if (configuration.State == ConfigurationFileState.Invalid || !configuration.Warnings.IsEmpty)
        { notes.Add(PosteText.Fact("Configuration", configuration.Problem ?? string.Join(" ", configuration.Warnings), FactState.Observed, LegacyConfiguration.FileName, "Les réglages absents ou invalides conservent les défauts documentés.", tone: Tone.Warn)); }
        EnsureEpoch(local.Epoch);
        return new(computer, header, association, Recent(computer.Guid, local.Epoch)?.Live, summary, PosteBoardBuilder.Build(computer, inv, policy, now, source.Zone),
            inv is null ? "Aucun inventaire validé pour ce poste ; un inventaire rapide nécessite un geste explicite." : null,
            secrets, consent, Options, false, false, notes.ToImmutable())
        {
            CachedSessions = PosteSessionCache.Applicable(local.Fleet.WorkstationSessions.GetValueOrDefault(computer.Guid), local.Computer.WhenCreated, now) is { } sessions
                ? PosteSessions.Stored(sessions, source.Zone) : null,
        };
    }

    public async Task<InventoryResult?> CachedInventoryAsync(string dn, PosteHealthPolicy policy, CancellationToken cancellationToken)
    {
        var local = await LocalAsync(dn, cancellationToken).ConfigureAwait(false);
        var inv = Inventory(local);
        if (inv is null) { return null; }
        var now = source.Clock.GetUtcNow();
        var result = InventoryRows.Build(inv, PosteBoardBuilder.Build(Computer(local, Names(local.Directory)), inv, policy, now, source.Zone), "Base locale (relevé daté)", now, source.Zone);
        EnsureEpoch(local.Epoch); return result;
    }

    public async Task<SoftwareResult> CachedSoftwareAsync(string dn, CancellationToken cancellationToken)
    {
        var local = await LocalAsync(dn, cancellationToken).ConfigureAwait(false);
        if (Recent(local.Computer.ObjectGuid, local.Epoch)?.Software is { } software) { return software with { Origin = "Relevé conservé dans cette session" }; }
        var inv = Inventory(local);
        var rows = PosteSoftware.Rows(inv?.Software ?? []);
        var status = inv?.StatusOf(InventoryCategories.Software) ?? SourceStatus.Skipped;
        ImmutableArray<SoftwareScopeAccess> access = [new("Machine", status, PosteLabels.SourceStatusLabel(status), rows.Length, "Données déjà présentes dans l’inventaire, sans nouvelle lecture.")];
        var today = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(source.Clock.GetUtcNow(), source.Zone).DateTime);
        EnsureEpoch(local.Epoch);
        return new(local.Computer.Name, inv?.CollectedAt, inv is null ? "Aucun inventaire" : "Inventaire enregistré",
            "Cache local uniquement. Les champs non collectés restent inconnus ; « Charger les logiciels » relit les portées choisies.", false,
            rows.Length, rows, access, PosteSoftware.AccessSummary(access), PosteSoftware.NotCovered(access, new(false, false, false)), PosteSoftware.Columns(rows), PosteSoftware.Board(rows, today), []);
    }

    public async Task<UserRef?> FindAccountAsync(string login, CancellationToken cancellationToken)
    {
        if (!CredentialRules.IsWellFormed(login)) { return null; }
        var epoch = source.Epoch;
        var directory = (await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false)).Directory;
        var name = CredentialRules.Parse(login);
        if (name.Form == AccountNameForm.DownLevel && !name.Authority.Equals(directory.Domain.DnsName, StringComparison.OrdinalIgnoreCase)
            && !name.Authority.Equals(directory.Domain.NetbiosName, StringComparison.OrdinalIgnoreCase)) { return null; }
        var users = directory.Users.Where(u => name.Form == AccountNameForm.Upn ? string.Equals(u.UserPrincipalName, login, StringComparison.OrdinalIgnoreCase)
            : u.SamAccountName.Equals(name.Name, StringComparison.OrdinalIgnoreCase)).Take(2).ToArray();
        EnsureEpoch(epoch);
        return users.Length == 1 ? new(users[0].DisplayName ?? users[0].Cn, users[0].SamAccountName, users[0].DistinguishedName, users[0].ObjectGuid) : null;
    }

    public async Task<ImmutableArray<DnRef>> GroupsAsync(string? text, CancellationToken cancellationToken)
    {
        if (text?.Length > 500) { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Filtre limité à 500 caractères."); }
        var epoch = source.Epoch;
        var directory = (await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false)).Directory;
        var needle = FrenchText.Fold(text?.Trim() ?? "");
        var result = directory.Groups.Where(g => needle.Length == 0 || FrenchText.Fold(g.Name).Contains(needle, StringComparison.Ordinal))
            .OrderBy(g => g.Name, PosteText.French).ThenBy(g => g.ObjectGuid).Take(50).Select(g => new DnRef(g.DistinguishedName, g.Name)).ToImmutableArray();
        EnsureEpoch(epoch); return result;
    }
}
