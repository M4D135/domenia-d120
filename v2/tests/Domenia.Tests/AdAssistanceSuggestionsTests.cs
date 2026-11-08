using System.Collections.Immutable;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Tests;

internal static class AdAssistanceSuggestionsTests
{
    private sealed class Cache(DirectorySnapshot directory, FleetObservations observations) : IDirectoryCache, IAccueilCache
    {
        internal Action? ReadingFleet { get; set; }
        public Task<DirectorySnapshot?> ReadAsync(CancellationToken token) => Task.FromResult<DirectorySnapshot?>(directory);
        public Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken token) => throw new InvalidOperationException("Lecture locale uniquement");
        public Task<CachedFleet> ReadFleetAsync(CancellationToken token)
        { ReadingFleet?.Invoke(); return Task.FromResult(CachedFleet.Empty("suggestions") with { Observations = observations }); }
        public Task<CachedFleet> SaveFleetAsync(FleetCachePatch patch, CancellationToken token) => throw new InvalidOperationException("Aucune sonde implicite");
        public Task<ImmutableArray<FleetSnapshot>> ReadFleetHistoryAsync(ScopeSelection scope, CancellationToken token) => throw new InvalidOperationException("Aucun historique implicite");
    }

    private static async Task<ImmutableArray<SubjectSuggestion>> Read(DirectorySnapshot directory, FleetObservations? observations = null, ScopeSelection? scope = null)
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = _ => throw new InvalidOperationException("Aucun LDAP pour des suggestions locales") };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap,
            localStore: new Cache(directory, observations ?? FleetObservations.Empty));
        var result = await new AdAssistanceReader(source).SuggestionsAsync(scope, CancellationToken.None);
        Check.Equal(0, ldap.Calls, "aucun bind, RootDSE, LDAP ni recherche annexe"); return result;
    }

    [Test]
    public static async Task Native_suggestions_include_actual_account_and_workstation_signals_with_dates()
    {
        var locked = Fixtures.User("locked") with { ComputedAccountControl = AdValues.LockedOut };
        var expired = Fixtures.User("expired") with { PasswordExpiryComputed = Fixtures.Ft(Fixtures.Now.AddDays(-1)) };
        var change = Fixtures.User("change") with { PasswordLastSet = 0 };
        var disk = Fixtures.Computer("disk"); var ping = Fixtures.Computer("ping"); var boot = Fixtures.Computer("boot");
        var readings = new FleetObservations(Fixtures.Now, [
            Fixtures.Observe(disk, inventory: Fixtures.Disk(100, 0, TimeSpan.FromMinutes(9))),
            Fixtures.Observe(ping, Fixtures.Presence(false, TimeSpan.FromMinutes(8))),
            Fixtures.Observe(boot, inventory: Fixtures.Disk(100, 60, TimeSpan.FromMinutes(7), TimeSpan.FromDays(45)))]);
        var rows = await Read(Fixtures.Snapshot(users: [locked, expired, change], computers: [disk, ping, boot]), readings);
        Check.Equal(6, rows.Length, "comptes et postes réellement suggérés");
        foreach (var (dn, reason) in new[] { (locked.DistinguishedName, "verrouillé"), (expired.DistinguishedName, "Mot de passe expiré"),
            (change.DistinguishedName, "Changement du mot de passe"), (disk.DistinguishedName, "Disque système presque plein"),
            (ping.DistinguishedName, "ping peut être filtré"), (boot.DistinguishedName, "uptime actuel non établi") })
        {
            var row = rows.Single(r => r.Subject.Dn == dn); Check.True(row.Reason.Contains(reason, StringComparison.Ordinal), "raison issue de la donnée : " + reason);
            Check.True(row.Reason.Contains("mémorisé le", StringComparison.Ordinal) && row.Reason.Contains("non revérifié", StringComparison.Ordinal), "provenance locale et date affichées");
        }
        Check.Equal(Tone.Alert, rows.Single(r => r.Subject.Dn == disk.DistinguishedName).Subject.Tone, "zéro libre réellement mesuré alerte");
    }

    [Test]
    public static async Task Suggestions_reject_unknown_incoherent_future_and_duplicate_measurements()
    {
        var unknown = Fixtures.Computer("unknown"); var zeroSize = Fixtures.Computer("zero-size"); var future = Fixtures.Computer("future");
        var duplicate = Fixtures.Computer("duplicate"); var before = Fixtures.Computer("before"); var refused = Fixtures.Computer("refused");
        var duplicateReading = Fixtures.Observe(duplicate, Fixtures.Presence(false, TimeSpan.FromMinutes(1)));
        var readings = new FleetObservations(Fixtures.Now, [
            Fixtures.Observe(unknown, new(MeasureState.Known, null, Fixtures.Now.AddMinutes(-1), null)),
            Fixtures.Observe(zeroSize, inventory: Fixtures.Disk(0, 0, TimeSpan.FromMinutes(1))),
            Fixtures.Observe(future, Fixtures.Presence(false, TimeSpan.FromMinutes(-1))),
            duplicateReading, duplicateReading,
            Fixtures.Observe(before, new(MeasureState.Known, false, before.WhenCreated.AddSeconds(-1), null)),
            Fixtures.Observe(refused, new(MeasureState.Refused, false, Fixtures.Now.AddMinutes(-1), null), Fixtures.Disk(100, 0, TimeSpan.FromMinutes(1)) with { State = MeasureState.Incomplete })]);
        var rows = await Read(Fixtures.Snapshot(computers: [unknown, zeroSize, future, duplicate, before, refused]), readings);
        Check.Equal(0, rows.Length, "aucun état inconnu transformé en panne ou en disque plein");
    }

    [Test]
    public static async Task Suggestions_apply_scope_to_both_kinds_and_reject_conflicts_outside_that_scope()
    {
        var branch = "OU=Assistance," + Fixtures.Root;
        var inside = Fixtures.User("inside") with { DistinguishedName = "CN=inside," + branch, ComputedAccountControl = AdValues.LockedOut };
        var outside = Fixtures.User("outside") with { ComputedAccountControl = AdValues.LockedOut };
        var conflicting = Fixtures.Computer("conflicting", branch);
        var outsideDuplicate = Fixtures.Computer("outside-duplicate") with { ObjectGuid = conflicting.ObjectGuid };
        var pc = Fixtures.Computer("inside-pc", branch); var other = Fixtures.Computer("outside-pc");
        var rows = await Read(Fixtures.Snapshot(users: [inside, outside], computers: [conflicting, outsideDuplicate, pc, other]),
            new(Fixtures.Now, [Fixtures.Observe(conflicting, Fixtures.Presence(false, TimeSpan.FromMinutes(1))), Fixtures.Observe(pc, Fixtures.Presence(false, TimeSpan.FromMinutes(1))),
                Fixtures.Observe(other, Fixtures.Presence(false, TimeSpan.FromMinutes(1)))]), new(branch, "Assistance", true));
        Check.Equal(2, rows.Length, "une suggestion de chaque famille dans l’OU");
        Check.True(rows.Any(r => r.Subject.Dn == inside.DistinguishedName), "compte dans l’OU"); Check.True(rows.Any(r => r.Subject.Dn == pc.DistinguishedName), "poste dans l’OU");
        Check.False(rows.Any(r => r.Subject.Dn == conflicting.DistinguishedName), "doublon GUID hors périmètre rend l’identité ambiguë");
    }

    [Test]
    public static async Task Suggestions_require_dated_identity_and_skip_disabled_accounts_and_workstations()
    {
        var disabled = Fixtures.User("disabled") with { UserAccountControl = AdValues.NormalAccount | AdValues.AccountDisabled, ComputedAccountControl = AdValues.LockedOut };
        var future = Fixtures.User("future") with { ComputedAccountControl = AdValues.LockedOut };
        var unknown = Fixtures.User("unknown") with { UserAccountControl = 0, ComputedAccountControl = AdValues.LockedOut };
        var recreated = Fixtures.User("recreated") with { WhenCreated = Fixtures.Now.AddMinutes(-1), ComputedAccountControl = AdValues.LockedOut };
        var missing = Fixtures.User("missing") with { ComputedAccountControl = AdValues.LockedOut };
        var pc = Fixtures.Computer("disabled-pc") with { UserAccountControl = AdValues.WorkstationTrustAccount | AdValues.AccountDisabled };
        var directory = Fixtures.Snapshot(users: [disabled, future, unknown, recreated, missing], computers: [pc]);
        directory = directory with { ObjectReadAt = new[] { disabled.ObjectGuid, unknown.ObjectGuid, recreated.ObjectGuid, pc.ObjectGuid }.ToImmutableDictionary(id => id, _ => directory.ReadAt)
            .SetItem(future.ObjectGuid, Fixtures.Now.AddDays(1)) };
        var rows = await Read(directory, new(Fixtures.Now, [Fixtures.Observe(pc, Fixtures.Presence(false, TimeSpan.FromMinutes(1)))]));
        Check.Equal(0, rows.Length, "dates manquantes, futures, antérieures à création ou comptes désactivés exclus");
    }

    [Test]
    public static async Task Suggestions_label_estimated_expiry_and_never_estimate_from_missing_or_future_dates()
    {
        var estimated = Fixtures.User("estimated") with { PasswordExpiryComputed = null, PasswordLastSet = Fixtures.Ft(Fixtures.Now.AddDays(-100)) };
        var missing = Fixtures.User("missing") with { PasswordExpiryComputed = null, PasswordLastSet = null };
        var future = Fixtures.User("future") with { PasswordExpiryComputed = null, PasswordLastSet = Fixtures.Ft(Fixtures.Now.AddDays(1)) };
        var never = Fixtures.User("never") with { PasswordExpiryComputed = AdValues.Never, PasswordLastSet = Fixtures.Ft(Fixtures.Now.AddDays(-100)) };
        var checkLock = never with { ObjectGuid = Guid.NewGuid(), DistinguishedName = "CN=check-lock," + Fixtures.People, Cn = "check-lock", SamAccountName = "check-lock", ComputedAccountControl = null, LockoutTime = Fixtures.Ft(Fixtures.Now.AddMinutes(-1)) };
        var rows = await Read(Fixtures.Snapshot(users: [estimated, missing, future, never, checkLock]));
        Check.Equal(2, rows.Length, "une estimation et un état de verrouillage incertain");
        Check.True(rows.Single(r => r.Subject.Dn == estimated.DistinguishedName).Reason.Contains("estimée", StringComparison.Ordinal), "date estimée distinguée d’une date LDAP");
        Check.True(rows.Single(r => r.Subject.Dn == checkLock.DistinguishedName).Reason.Contains("état calculé non lu", StringComparison.Ordinal), "lockoutTime ne prouve pas le verrouillage actuel");
    }

    [Test]
    public static async Task Suggestions_are_stably_ordered_and_bounded_to_twelve_without_a_network_read()
    {
        var users = Enumerable.Range(1, 30).Select(i => Fixtures.User("U" + i.ToString("D2", System.Globalization.CultureInfo.InvariantCulture)) with { ComputedAccountControl = AdValues.LockedOut }).ToArray();
        var rows = await Read(Fixtures.Snapshot(users: users.Reverse()));
        Check.Equal(12, rows.Length, "plafond réel de la réponse"); Check.Equal(users[0].DistinguishedName, rows[0].Subject.Dn, "ordre déterministe");
        Check.Equal(users[11].DistinguishedName, rows[11].Subject.Dn, "fin de la première page locale");
    }

    [Test]
    public static async Task Suggestions_do_not_publish_after_generation_changes_during_the_cache_read()
    {
        var user = Fixtures.User("locked") with { ComputedAccountControl = AdValues.LockedOut };
        var cache = new Cache(Fixtures.Snapshot(users: [user]), FleetObservations.Empty);
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var changed = false; cache.ReadingFleet = () => { changed = true; source.Reset(); };
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => new AdAssistanceReader(source).SuggestionsAsync(null, CancellationToken.None), "génération changée pendant lecture locale");
        Check.True(changed, "interleaving effectivement atteint"); Check.Equal(AdErrors.NotConnected, error.Code, "cache de l’ancienne génération non publié"); Check.Equal(0, ldap.Calls, "aucune tentative réseau de rattrapage");
    }

    [Test]
    public static async Task Suggestions_honour_cancellation_even_when_no_candidate_survives()
    {
        var cache = new Cache(Fixtures.Snapshot(), FleetObservations.Empty);
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        using var stop = new CancellationTokenSource(); var cancelled = false;
        cache.ReadingFleet = () => { cancelled = true; stop.Cancel(); };
        await Check.ThrowsAsync<OperationCanceledException>(() => new AdAssistanceReader(source).SuggestionsAsync(null, stop.Token), "annulation pendant la lecture du cache vide");
        Check.True(cancelled, "annulation injectée réellement"); Check.Equal(0, ldap.Calls, "aucun réseau sur annulation");
    }
}
