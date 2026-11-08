using System.Collections.Immutable;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Tests;

internal static class AdAssistanceContextTests
{
    private sealed class Cache(DirectorySnapshot directory, FleetObservations observations) : IObjectDirectoryCache, IAccueilCache
    {
        internal Action? Saved { get; set; }
        internal int ObjectWrites { get; private set; }
        internal int FleetWrites { get; private set; }
        public Task<DirectorySnapshot?> ReadAsync(CancellationToken token) => Task.FromResult<DirectorySnapshot?>(directory);
        public Task<DirectorySnapshot?> ReadKnownAsync(CancellationToken token) => ReadAsync(token);
        public Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken token) => throw new InvalidOperationException("Aucun recensement permis");
        public Task<DirectorySnapshot> SaveObjectsAsync(DirectorySnapshot objects, string? controller, CancellationToken token)
        {
            token.ThrowIfCancellationRequested(); ObjectWrites++;
            var dates = directory.ObjectReadAt ?? directory.Users.Select(u => u.ObjectGuid).Concat(directory.Computers.Select(c => c.ObjectGuid))
                .Distinct().ToImmutableDictionary(id => id, _ => directory.ReadAt);
            foreach (var id in objects.Users.Select(u => u.ObjectGuid).Concat(objects.Computers.Select(c => c.ObjectGuid))) { dates = dates.SetItem(id, objects.ReadAt); }
            directory = directory with
            {
                Users = [.. directory.Users.Where(u => !objects.Users.Any(next => next.ObjectGuid == u.ObjectGuid)), .. objects.Users],
                Computers = [.. directory.Computers.Where(c => !objects.Computers.Any(next => next.ObjectGuid == c.ObjectGuid)), .. objects.Computers],
                ObjectReadAt = dates,
            };
            Saved?.Invoke(); return Task.FromResult(directory);
        }
        public Task<CachedFleet> ReadFleetAsync(CancellationToken token) => Task.FromResult(CachedFleet.Empty("assistance-test") with { Observations = observations });
        public Task<CachedFleet> SaveFleetAsync(FleetCachePatch patch, CancellationToken token) { FleetWrites++; throw new InvalidOperationException("Aucune sonde implicite permise"); }
        public Task<ImmutableArray<FleetSnapshot>> ReadFleetHistoryAsync(ScopeSelection scope, CancellationToken token) => Task.FromResult(ImmutableArray<FleetSnapshot>.Empty);
    }

    private static AdEntry Entry(DirectoryComputer pc, params (string Name, object Value)[] values)
    {
        var entry = AdPosteNetworkTests.Entry(pc);
        var attributes = entry.AttributeNames.ToDictionary(n => n, entry.Raw, StringComparer.OrdinalIgnoreCase);
        foreach (var (name, value) in values) { attributes[name] = [value]; }
        if (pc.ManagedByDn is { } managed) { attributes["managedBy"] = [managed]; }
        return new(pc.DistinguishedName, attributes);
    }

    private static async Task<(SubjectRecord Subject, AdSearchRequest[] Requests)> Read(DirectorySnapshot directory, AdEntry fresh, params WorkstationObservation[] observations)
    {
        var cache = new Cache(directory, new(Fixtures.Now, [.. observations]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = _ => [fresh] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var subject = await new AdAssistanceReader(source).ReadSubjectAsync(fresh.DistinguishedName, CancellationToken.None);
        Check.NotNull(subject, "la vraie lecture du sujet a produit une fiche");
        Check.Equal(1, cache.ObjectWrites, "lecture ciblée réellement mémorisée");
        Check.Equal(0, cache.FleetWrites, "aucune nouvelle mesure du poste");
        Check.Equal(1, ldap.Searches.Count, "aucune recherche de relations ni collecte implicite");
        Check.True(ldap.Searches.All(q => q.Scope == AdSearchScope.Base && q.SizeLimit == 2), "lecture d’un seul sujet qualifié");
        return (subject!, [.. ldap.Searches]);
    }

    private static ImmutableArray<SupportFinding> Findings(SubjectRecord subject)
    {
        var snapshot = SupportSnapshots.Create(subject.Properties, Fixtures.Root, subject.Dn, subject.Name, "computer", SnapshotSource.Live,
            subject.ReadAt, Fixtures.Now, subject.MemberOfComplete);
        return SupportFindings.Analyse(snapshot, Fixtures.Now, TestClock.Paris, subject.Signals);
    }

    [Test]
    public static async Task Native_assistance_uses_exact_GUID_cached_measurements_and_only_LAPS_expiration_metadata()
    {
        var pc = Fixtures.Computer("PC1"); var checkedAt = Fixtures.Now.AddMinutes(-7); var boot = Fixtures.Now.AddDays(-45);
        var expiry = Fixtures.Now.AddDays(-2); var logon = Fixtures.Now.AddDays(-120);
        var observation = Fixtures.Observe(pc, Fixtures.Presence(false, TimeSpan.FromMinutes(7)), Fixtures.Disk(1000, 50, TimeSpan.FromMinutes(7), TimeSpan.FromDays(45)));
        var (subject, requests) = await Read(Fixtures.Snapshot(computers: [pc]), Entry(pc,
            ("msLAPS-PasswordExpirationTime", Fixtures.Ft(expiry)), ("lastLogonTimestamp", Fixtures.Ft(logon))), observation);
        var signals = subject.Signals!; Check.NotNull(signals, "signaux machine natifs raccordés");
        Check.Equal(LapsKind.Windows, signals.Laps!.Value, "métadonnée Windows observée"); Check.Equal(expiry, signals.LapsExpiration!.Value, "date LDAP exacte");
        Check.Equal(false, signals.LastPresenceAnswered!.Value, "absence de réponse effectivement mesurée"); Check.Equal(checkedAt, signals.LastPresenceAt!.Value, "pas de date remplacée par maintenant");
        Check.Equal(5d, signals.SystemDiskFreePercent!.Value, "pourcentage calculé sur les octets réellement lus");
        Check.Equal(boot, signals.LastBootAt!.Value, "démarrage WMI mémorisé"); Check.Equal(logon, signals.LastLogonAt!.Value, "date LDAP de connexion");
        var codes = Findings(subject).Select(f => f.Code).ToHashSet(StringComparer.Ordinal);
        foreach (var code in new[] { "LAPS_EXPIRED", "NO_ANSWER", "DISK_LOW", "UPTIME_LONG", "COMPUTER_STALE" }) { Check.True(codes.Contains(code), "analyse native : " + code); }
        Check.True(Findings(subject).Single(f => f.Code == "UPTIME_LONG").Evidence.Contains("ne prouve pas l’uptime actuel", StringComparison.Ordinal), "un ancien relevé ne prouve pas l’état actuel");
        Check.True(subject.Facts.Any(f => f.Value.Contains("secret non lu", StringComparison.Ordinal)), "lecture de métadonnées distincte du secret");
        var requested = requests.SelectMany(q => q.Attributes).ToArray();
        foreach (var secret in new[] { "msLAPS-Password", "msLAPS-EncryptedPassword", "ms-Mcs-AdmPwd" })
        { Check.False(requested.Contains(secret, StringComparer.OrdinalIgnoreCase), "aucun secret demandé : " + secret); Check.False(subject.Properties.ContainsKey(secret), "aucun secret dans la fiche"); }
    }

    [Test]
    public static async Task Missing_or_invalid_native_LAPS_metadata_is_unknown_and_not_absent()
    {
        var pc = Fixtures.Computer("PC1");
        foreach (var fresh in new[] { Entry(pc), Entry(pc, ("msLAPS-PasswordExpirationTime", -1L)), Entry(pc, ("ms-Mcs-AdmPwdExpirationTime", long.MaxValue)) })
        {
            var (subject, _) = await Read(Fixtures.Snapshot(computers: [pc]), fresh);
            Check.NotNull(subject.Signals, "contexte connu même sans mesures"); Check.Null(subject.Signals!.Laps, "type non démontré");
            Check.Null(subject.Signals.LapsExpiration, "aucune date de remplacement");
            var findings = Findings(subject); Check.True(findings.Any(f => f.Code == "LAPS_UNREAD" && f.Basis == FindingBasis.Coverage), "couverture explicitée");
            Check.False(findings.Any(f => f.Code is "LAPS_ABSENT" or "LAPS_EXPIRED"), "pas de verdict d’absence ni d’expiration");
        }
    }

    [Test]
    public static async Task Native_LAPS_zero_preserves_observed_schema_and_means_rotation_requested_without_a_fake_date()
    {
        var pc = Fixtures.Computer("PC1");
        foreach (var (attribute, kind) in new[] { ("msLAPS-PasswordExpirationTime", LapsKind.Windows), ("ms-Mcs-AdmPwdExpirationTime", LapsKind.Legacy) })
        {
            var (subject, _) = await Read(Fixtures.Snapshot(computers: [pc]), Entry(pc, (attribute, 0L)));
            Check.Equal(kind, subject.Signals!.Laps!.Value, "schéma effectivement observé");
            Check.True(subject.Signals.LapsRotationRequested, "zéro exact conservé comme demande de rotation"); Check.Null(subject.Signals.LapsExpiration, "aucune date 1601 ou date actuelle fabriquée");
            var findings = Findings(subject); Check.True(findings.Any(f => f.Code == "LAPS_ROTATION_REQUESTED"), "constat explicite");
            Check.False(findings.Any(f => f.Code is "LAPS_UNREAD" or "LAPS_ABSENT" or "LAPS_EXPIRED"), "zéro distinct des autres états");
            Check.True(subject.Facts.Single(f => f.Label == "Métadonnées LAPS").Value.Contains("secret non lu", StringComparison.Ordinal), "portée de lecture inchangée");
        }
    }

    [Test]
    public static async Task A_future_valid_legacy_LAPS_expiration_is_preserved_as_metadata()
    {
        var pc = Fixtures.Computer("PC1"); var expiry = Fixtures.Now.AddDays(10);
        var (subject, _) = await Read(Fixtures.Snapshot(computers: [pc]), Entry(pc, ("ms-Mcs-AdmPwdExpirationTime", Fixtures.Ft(expiry))));
        Check.Equal(LapsKind.Legacy, subject.Signals!.Laps!.Value, "attribut historique réellement observé");
        Check.Equal(expiry, subject.Signals.LapsExpiration!.Value, "une expiration future est légitime");
        Check.False(Findings(subject).Any(f => f.Code.StartsWith("LAPS_", StringComparison.Ordinal)), "aucune alerte inventée");
    }

    [Test]
    public static async Task Homonymous_or_duplicate_GUID_observations_cannot_produce_machine_signals()
    {
        var pc = Fixtures.Computer("PC1"); var observation = Fixtures.Observe(pc, Fixtures.Presence(false, TimeSpan.FromMinutes(1)), Fixtures.Disk(100, 0, TimeSpan.FromMinutes(1)));
        foreach (var records in new[] { new[] { observation with { ComputerGuid = Guid.NewGuid() } }, new[] { observation, observation } })
        {
            var (subject, _) = await Read(Fixtures.Snapshot(computers: [pc]), Entry(pc), records);
            Check.Null(subject.Signals!.LastPresenceAnswered, "pas de rapprochement par nom ou de choix arbitraire");
            Check.Null(subject.Signals.SystemDiskFreePercent, "pas de faux zéro"); Check.Null(subject.Signals.LastBootAt, "inventaire non qualifié");
            Check.False(Findings(subject).Any(f => f.Code is "NO_ANSWER" or "DISK_LOW" or "UPTIME_LONG"), "aucune alerte issue d’une identité ambiguë");
        }
    }

    [Test]
    public static async Task Observations_before_creation_in_future_or_refused_remain_unknown()
    {
        var pc = Fixtures.Computer("PC1"); var reading = Fixtures.Observe(pc, Fixtures.Presence(false, TimeSpan.FromMinutes(1)), Fixtures.Disk(100, 0, TimeSpan.FromMinutes(1)));
        var cases = new[]
        {
            reading with { Presence = reading.Presence with { CheckedAt = pc.WhenCreated.AddSeconds(-1) }, Inventory = reading.Inventory with { CheckedAt = pc.WhenCreated.AddSeconds(-1) } },
            reading with { Presence = reading.Presence with { CheckedAt = Fixtures.Now.AddSeconds(1) }, Inventory = reading.Inventory with { CheckedAt = Fixtures.Now.AddSeconds(1) } },
            reading with { Presence = reading.Presence with { State = MeasureState.Refused }, Inventory = reading.Inventory with { State = MeasureState.Incomplete } },
            reading with { Presence = reading.Presence with { Answered = null }, Inventory = InventoryMeasure.Unread },
        };
        foreach (var record in cases)
        {
            var (subject, _) = await Read(Fixtures.Snapshot(computers: [pc]), Entry(pc, ("lastLogonTimestamp", Fixtures.Ft(Fixtures.Now.AddDays(1)))), record);
            var signals = subject.Signals!; Check.Null(signals.LastPresenceAnswered, "présence non qualifiée"); Check.Null(signals.LastPresenceAt, "date rejetée non réutilisée");
            Check.Null(signals.SystemDiskFreePercent, "disque non qualifié"); Check.Null(signals.LastBootAt, "démarrage non qualifié"); Check.Null(signals.LastLogonAt, "connexion future non crédible");
            Check.Equal("Non lue pour cette identité", subject.Facts.Single(f => f.Label == "Présence mémorisée").Value, "réponse inconnue distincte d’un ping sans réponse");
        }
    }

    [Test]
    public static async Task Native_assistance_distinguishes_zero_free_bytes_from_unknown_or_inconsistent_disk_size()
    {
        var pc = Fixtures.Computer("PC1");
        foreach (var (size, free, expected) in new (long Size, long Free, double? Expected)[] { (100, 0, 0d), (0, 0, null), (100, -1, null), (100, 101, null) })
        {
            var reading = Fixtures.Observe(pc, inventory: Fixtures.Disk(size, free, TimeSpan.FromMinutes(1)) with { LastBootAt = Fixtures.Now });
            var (subject, _) = await Read(Fixtures.Snapshot(computers: [pc]), Entry(pc), reading);
            Check.Equal(expected, subject.Signals!.SystemDiskFreePercent, "taille et espace libre cohérents requis");
            Check.Equal(expected == 0, Findings(subject).Any(f => f.Code == "DISK_LOW"), "seul le zéro réellement mesuré alerte");
            Check.Null(subject.Signals.LastBootAt, "démarrage après le relevé rejeté");
        }
    }

    [Test]
    public static async Task User_context_uses_actual_managedBy_DNs_and_rejects_unqualified_cached_endpoints()
    {
        var user = Fixtures.User("alice"); var good = Fixtures.Computer("PC-linked") with { ManagedByDn = user.DistinguishedName.ToUpperInvariant() };
        var sameName = Fixtures.Computer("alice"); var other = Fixtures.Computer("PC-other") with { ManagedByDn = Fixtures.User("bob").DistinguishedName };
        var empty = Fixtures.Computer("PC-empty") with { ObjectGuid = Guid.Empty, ManagedByDn = user.DistinguishedName };
        var foreign = Fixtures.Computer("PC-foreign", "DC=other,DC=local") with { ManagedByDn = user.DistinguishedName };
        var malformed = Fixtures.Computer("PC-malformed") with { DistinguishedName = "broken", ManagedByDn = user.DistinguishedName };
        var future = Fixtures.Computer("PC-future") with { ManagedByDn = user.DistinguishedName, WhenCreated = Fixtures.Now.AddDays(1) };
        var duplicate = Fixtures.Computer("PC-duplicate") with { ManagedByDn = user.DistinguishedName };
        var duplicateUnlinked = Fixtures.Computer("PC-duplicate-unlinked") with { ObjectGuid = duplicate.ObjectGuid, ManagedByDn = null };
        var ambiguousDn = Fixtures.Computer("PC-same-dn") with { ManagedByDn = user.DistinguishedName };
        var escapedDn = ambiguousDn with { ObjectGuid = Guid.NewGuid(), DistinguishedName = "CN=PC-same-\\64n," + Fixtures.Postes, ManagedByDn = null };
        var futureRead = Fixtures.Computer("PC-future-read") with { ManagedByDn = user.DistinguishedName };
        var undated = Fixtures.Computer("PC-undated") with { ManagedByDn = user.DistinguishedName };
        var dated = Fixtures.Now.AddMinutes(-10);
        var directory = Fixtures.Snapshot(users: [user], computers: [good, sameName, other, empty, foreign, malformed, future, duplicate, duplicateUnlinked, ambiguousDn, escapedDn, futureRead, undated]);
        directory = directory with { ObjectReadAt = directory.Computers.Where(c => c != undated).Select(c => c.ObjectGuid).Distinct().ToImmutableDictionary(id => id, _ => dated)
            .SetItem(futureRead.ObjectGuid, Fixtures.Now.AddMinutes(1)) };
        var (subject, _) = await Read(directory, AdRelationDirectoryTests.User(user));
        Check.Null(subject.Signals, "aucun signal machine inventé pour un utilisateur");
        Check.Equal(good.DistinguishedName, subject.Related.Single().Dn, "seul le lien DN réel vers une identité qualifiée est affiché");
        Check.True(subject.Related[0].Detail.Contains("non revérifié", StringComparison.Ordinal), "contexte local annoncé");
        Check.True(subject.Facts.Any(f => f.Label == "Relations locales"), "provenance visible");
    }

    [Test]
    public static async Task Computer_context_uses_fresh_managedBy_instead_of_an_old_owner_or_namesake()
    {
        var alice = Fixtures.User("alice"); var bob = Fixtures.User("bob"); var pc = Fixtures.Computer("PC1") with { ManagedByDn = alice.DistinguishedName };
        var fresh = pc with { ManagedByDn = bob.DistinguishedName };
        var (subject, _) = await Read(Fixtures.Snapshot(users: [alice, bob], computers: [pc]), Entry(fresh));
        Check.Equal(bob.DistinguishedName, subject.Related.Single().Dn, "relation fraîche, identité liée du cache");
        var (unlinked, _) = await Read(Fixtures.Snapshot(users: [alice, bob], computers: [pc]), Entry(fresh with { ManagedByDn = null }));
        Check.Equal(0, unlinked.Related.Length, "l’ancien propriétaire n’est pas ressuscité");
    }

    [Test]
    public static async Task ManagedBy_context_is_bounded_without_searching_the_directory()
    {
        var user = Fixtures.User("alice");
        var pcs = Enumerable.Range(1, 12).Select(i => Fixtures.Computer("PC" + i.ToString("D2", System.Globalization.CultureInfo.InvariantCulture)) with { ManagedByDn = user.DistinguishedName }).ToArray();
        var (subject, _) = await Read(Fixtures.Snapshot(users: [user], computers: pcs), AdRelationDirectoryTests.User(user));
        Check.Equal(10, subject.Related.Length, "contexte borné à dix liens");
        Check.Equal(pcs[0].DistinguishedName, subject.Related[0].Dn, "ordre stable"); Check.Equal(pcs[9].DistinguishedName, subject.Related[9].Dn, "borne réelle");
        Check.True(subject.Facts.Any(f => f.Label == "Relations locales" && f.Value.Contains("limité à 10", StringComparison.Ordinal)), "troncature explicitée");
    }

    [Test]
    public static async Task A_managedBy_read_before_the_subject_was_recreated_is_not_reidentified_by_DN()
    {
        var user = Fixtures.User("alice") with { WhenCreated = Fixtures.Now.AddMinutes(-5), ObjectGuid = Guid.NewGuid() };
        var pc = Fixtures.Computer("PC1") with { ManagedByDn = user.DistinguishedName };
        var (subject, _) = await Read(Fixtures.Snapshot(users: [user], computers: [pc], readAt: Fixtures.Now.AddMinutes(-10)), AdRelationDirectoryTests.User(user));
        Check.Equal(user.ObjectGuid, subject.Guid, "nouvelle identité effectivement relue");
        Check.Equal(0, subject.Related.Length, "l’ancienne relation au même DN ne prouve pas un lien avec le nouveau GUID");
    }

    [Test]
    public static async Task Native_assistance_does_not_return_a_subject_after_source_generation_changes()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new Cache(Fixtures.Snapshot(computers: [pc]), FleetObservations.Empty);
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = _ => [Entry(pc)] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var changed = false; cache.Saved = () => { changed = true; source.Reset(); };
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => new AdAssistanceReader(source).ReadSubjectAsync(pc.DistinguishedName, CancellationToken.None), "session remplacée pendant la mémorisation");
        Check.True(changed, "frontière réellement atteinte"); Check.Equal(1, cache.ObjectWrites, "la lecture avait bien abouti");
        Check.Equal(AdErrors.NotConnected, error.Code, "échec de génération explicite");
    }

    [Test]
    public static async Task Native_assistance_honours_late_cancellation_without_a_fake_subject()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new Cache(Fixtures.Snapshot(computers: [pc]), FleetObservations.Empty);
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = _ => [Entry(pc)] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        using var stop = new CancellationTokenSource(); var cancelled = false;
        cache.Saved = () => { cancelled = true; stop.Cancel(); };
        await Check.ThrowsAsync<OperationCanceledException>(() => new AdAssistanceReader(source).ReadSubjectAsync(pc.DistinguishedName, stop.Token), "annulation après la lecture réelle");
        Check.True(cancelled, "annulation injectée à la frontière attendue"); Check.Equal(1, cache.ObjectWrites, "lecture mémorisée conservée"); Check.Equal(0, cache.FleetWrites, "aucune sonde ajoutée");
    }
}
