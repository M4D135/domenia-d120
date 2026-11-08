using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;
using static Domenia.Tests.Fixtures;

namespace Domenia.Tests;

internal static class DomainAccountRefreshTests
{
    [Test]
    public static async Task Account_census_reads_users_only_and_never_certifies_a_truncated_total()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection
        { SearchAnswer = _ => [AdRelationDirectoryTests.User(User("a")), AdRelationDirectoryTests.User(User("b"))] };
        var measure = await AdDirectoryReader.ReadDomainAccountsAsync(ldap, Domain, 2, TestClock.Fixed(), CancellationToken.None);
        Check.True(measure.Complete, "borne exacte complète grâce à la sentinelle");
        Check.Equal(2, measure.Active, "utilisateurs des branches du domaine");
        var request = ldap.Searches.Single();
        Check.Equal(Root, request.BaseDn, "domaine explicite");
        Check.Equal(AdSearchScope.Subtree, request.Scope, "tous les utilisateurs");
        Check.Equal(AdDirectoryMapper.UserFilter, request.Filter, "aucune lecture des postes ou groupes");
        Check.Equal(3, request.SizeLimit, "sentinelle");
        Check.Equal(8, request.Attributes.Count, "seuls les attributs nécessaires aux compteurs");
        Check.False(request.Attributes.Contains("memberOf"), "aucune expansion des appartenances");
        Check.True(request.PageSize > 0 && request.Timeout > TimeSpan.Zero, "lecture bornée");
        var partial = await AdDirectoryReader.ReadDomainAccountsAsync(ldap, Domain, 1, TestClock.Fixed(), CancellationToken.None);
        Check.False(partial.Complete, "troncature réelle");
        var input = Input(Snapshot() with { Coverage = new(Postes, "Postes", true) });
        Check.Null(Widget(WidgetCatalog.ActiveAccounts, input with { State = input.State with { DomainAccounts = partial } }).Data, "aucun faux total après limite");
    }

    [Test]
    public static async Task Account_census_rejects_duplicate_and_foreign_identities()
    {
        foreach (var users in new[] { new[] { User("a"), User("a") }, new[] { User("a") with { DistinguishedName = "CN=a,DC=foreign,DC=local" } }, new[] { User("a") with { ObjectGuid = Guid.Empty } } })
        {
            using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = _ => users.Select(AdRelationDirectoryTests.User).ToArray() };
            await Check.ThrowsAsync<DomeniaOperationException>(() => AdDirectoryReader.ReadDomainAccountsAsync(ldap, Domain, 10, TestClock.Fixed(), CancellationToken.None), "identité invalide");
        }
    }

    [Test]
    public static async Task Missing_or_unreadable_UAC_never_becomes_an_active_account_or_a_complete_total()
    {
        foreach (var raw in new string?[] { null, "illisible", "-1", "2147483648" })
        {
            var unreadable = AdRelationDirectoryTests.User(User("unreadable"));
            var attributes = unreadable.AttributeNames.ToDictionary(name => name, unreadable.Raw, StringComparer.OrdinalIgnoreCase);
            attributes.Remove("userAccountControl");
            if (raw is not null) { attributes["userAccountControl"] = new object[] { raw }; }
            using var ldap = new AdBoundaryTests.RecordingAdConnection
            { SearchAnswer = _ => [AdRelationDirectoryTests.User(User("known")), new AdEntry(unreadable.DistinguishedName, attributes)] };
            var measure = await AdDirectoryReader.ReadDomainAccountsAsync(ldap, Domain, 10, TestClock.Fixed(), CancellationToken.None);
            Check.False(measure.Complete, "attribut absent, illisible, négatif ou hors entier : lecture incomplète");
            Check.Equal(1, measure.Active, "seul le compte dont l’activation est lisible est retenu");
            Check.Equal(0, measure.Disabled, "l’inconnu n’est pas inventé désactivé");
            var input = Input(Snapshot() with { Coverage = new(Postes, "Postes", true) });
            input = input with { State = input.State with { DomainAccounts = measure } };
            foreach (var id in new[] { WidgetCatalog.ActiveAccounts, WidgetCatalog.LockedAccounts, WidgetCatalog.PasswordsExpiring })
            {
                var widget = Widget(id, input);
                Check.Null(widget.Data, "aucun total certifié à partir du census incomplet");
                Check.Equal(Tone.Off, widget.Tone, "aucun succès vert");
            }
        }
    }

    [Test]
    public static async Task Missing_account_state_stays_unknown_after_real_projection_persistence_and_widget_calculation()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection
        { SearchAnswer = _ => [AdRelationDirectoryTests.User(User("state-unreadable"))] };
        var measure = await AdDirectoryReader.ReadDomainAccountsAsync(ldap, Domain, 10, TestClock.Fixed(), CancellationToken.None);
        Check.True(measure.Complete, "tous les comptes et leurs UAC sont lus");
        Check.Equal(1, measure.Active, "activation connue");
        Check.Equal(1, measure.LockUnknown, "aucun attribut de verrouillage reçu");
        Check.Equal(1, measure.PasswordUnknown, "aucune date ni aucun bit d’expiration reçu");
        using var folder = new TemporaryFolder();
        var path = folder.File("unknown-accounts.db");
        var cache = new SqliteDirectoryCache(new DomeniaDatabase(path, Root, TestClock.Fixed()));
        await cache.SaveDomainAccountsAsync(measure, CancellationToken.None);
        var reopened = new SqliteDirectoryCache(new DomeniaDatabase(path, Root, TestClock.Fixed()));
        var saved = (await reopened.ReadDomainAccountsAsync(CancellationToken.None))!;
        Check.Equal(measure.Domain.RootDn, saved.Domain.RootDn, "même domaine à la réouverture");
        Check.Equal(measure.ReadAt, saved.ReadAt, "date de la mesure conservée");
        Check.True(saved.Complete, "la couverture des utilisateurs reste complète");
        Check.Equal(1, saved.LockUnknown, "verrouillage inconnu conservé");
        Check.Equal(1, saved.PasswordUnknown, "expiration inconnue conservée");
        var input = Input(Snapshot() with { Coverage = new(Postes, "Postes", true) });
        input = input with { State = input.State with { DomainAccounts = saved } };
        Check.Equal(1, Kpi(Widget(WidgetCatalog.ActiveAccounts, input)).Value, "UAC lisible permet ce seul total");
        var locks = Widget(WidgetCatalog.LockedAccounts, input);
        Check.Equal(0, Kpi(locks).Value, "aucun verrouillage confirmé");
        Check.Equal(1, Part(Kpi(locks).Breakdown, "toCheck"), "l’inconnu reste visible à côté du zéro confirmé");
        Check.Equal(Tone.Off, locks.Tone, "zéro avec inconnus ne signifie pas tout va bien");
        var passwords = Widget(WidgetCatalog.PasswordsExpiring, input);
        Check.Null(passwords.Data, "aucun total d’expiration incomplet");
        Check.Null(passwords.MeasuredAt, "la tuile ne certifie aucune mesure exploitable");
        Check.Equal(Tone.Off, passwords.Tone, "absence de résultat explicite");
        Check.True(passwords.Detail.Contains("Expiration illisible", StringComparison.Ordinal), "la cause est expliquée");
    }

    [Test]
    public static void Lock_census_distinguishes_missing_state_zero_timestamp_and_controller_confirmation()
    {
        var measure = DomainAccountMeasure.Compute(Domain,
        [
            User("missing") with { ComputedAccountControl = null, LockoutTime = null },
            User("timestamp-only") with { ComputedAccountControl = null, LockoutTime = Ft(Now - TimeSpan.FromMinutes(5)) },
            User("never-locked") with { ComputedAccountControl = null, LockoutTime = 0 },
            User("unlocked") with { ComputedAccountControl = 0, LockoutTime = null },
            User("locked") with { ComputedAccountControl = AdValues.LockedOut, LockoutTime = null },
            User("disabled") with { UserAccountControl = AdValues.NormalAccount | AdValues.AccountDisabled, ComputedAccountControl = null, LockoutTime = null },
        ], Now, true, DashboardPolicy.Default.PasswordExpiringWindow);
        Check.Equal(5, measure.Active, "seuls les comptes actifs alimentent ces états");
        Check.Equal(1, measure.Disabled, "désactivé à part");
        Check.Equal(1, measure.Locked, "seule la confirmation du contrôleur certifie le verrouillage");
        Check.Equal(2, measure.LockUnknown, "absence complète et date seule restent à vérifier");
    }

    [Test]
    public static void Password_census_keeps_positive_evidence_and_does_not_turn_missing_or_invalid_dates_into_valid_passwords()
    {
        var measure = DomainAccountMeasure.Compute(Domain,
        [
            User("dated") with { PasswordLastSet = null, PasswordExpiryComputed = Ft(Now + TimeSpan.FromDays(3)) },
            User("expired") with { PasswordLastSet = null, PasswordExpiryComputed = null, ComputedAccountControl = AdValues.PasswordExpired },
            User("must-change") with { PasswordLastSet = 0, PasswordExpiryComputed = null },
            User("never-flag") with { PasswordLastSet = null, PasswordExpiryComputed = null, UserAccountControl = AdValues.NormalAccount | AdValues.DontExpirePassword },
            User("never-date") with { PasswordLastSet = null, PasswordExpiryComputed = AdValues.Never },
            User("estimated") with { PasswordLastSet = Ft(Now - Domain.PasswordPolicy.MaxPasswordAge + TimeSpan.FromDays(3)), PasswordExpiryComputed = null },
            User("missing") with { PasswordLastSet = null, PasswordExpiryComputed = null, ComputedAccountControl = null },
            User("invalid-expiry") with { PasswordExpiryComputed = 0 },
            User("invalid-last-set") with { PasswordLastSet = -1, PasswordExpiryComputed = null },
            User("disabled") with { UserAccountControl = AdValues.NormalAccount | AdValues.AccountDisabled, PasswordLastSet = null, PasswordExpiryComputed = null },
        ], Now, true, DashboardPolicy.Default.PasswordExpiringWindow);
        Check.Equal(9, measure.Active, "comptes actifs");
        Check.Equal(1, measure.Disabled, "le désactivé illisible ne dégrade pas les comptes actifs");
        Check.Equal(2, measure.Expiring, "date calculée et estimation admise");
        Check.Equal(1, measure.Expired, "bit du contrôleur suffisant");
        Check.Equal(1, measure.MustChange, "pwdLastSet zéro est une information positive");
        Check.Equal(2, measure.NeverExpires, "bit et sentinelle sont des informations positives");
        Check.Equal(3, measure.PasswordUnknown, "absence et dates invalides restent inconnues");
    }

    [Test]
    public static async Task Widget_refresh_persists_domain_counts_without_replacing_the_OU_and_reopens_offline()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("accounts.db");
        var cache = new SqliteDirectoryCache(new DomeniaDatabase(path, Root, TestClock.Fixed()));
        var selected = new ScopeSelection(Postes, "Postes", true);
        await cache.SaveAsync(Snapshot(computers: [Computer("PC1")]) with { Coverage = selected }, selected, null, CancellationToken.None);
        using var ldap = new AdBoundaryTests.RecordingAdConnection
        { SearchAnswer = q => q.Filter == AdDirectoryMapper.UserFilter ? [AdRelationDirectoryTests.User(User("alice")), AdRelationDirectoryTests.User(User("disabled") with { UserAccountControl = 514 })] : [] };
        using (var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache))
        {
            await source.ConnectAsync(CancellationToken.None);
            using var dashboard = new DashboardService(source, new OperationJournal(), TestClock.Fixed());
            var refreshed = await dashboard.RefreshAsync(WidgetCatalog.ActiveAccounts, CancellationToken.None);
            Check.Equal(1, Kpi(refreshed).Value, "le vrai service affiche le compte après la lecture");
            Check.Equal(1, Part(Kpi(refreshed).Breakdown, "disabled"), "comptes désactivés distincts");
            Check.Equal("Domaine test.local", refreshed.ScopeLabel, "périmètre annoncé");
            Check.Equal(1, (await source.ReadLocalAsync(CancellationToken.None)).Directory.Computers.Length, "OU conservée");
        }
        using var noNetwork = new AdBoundaryTests.RecordingAdConnection();
        var reopened = new SqliteDirectoryCache(new DomeniaDatabase(path, Root, TestClock.Fixed()));
        using var local = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: noNetwork, localStore: reopened);
        var state = await local.ReadLocalAsync(CancellationToken.None);
        var input = Input(state.Directory) with { State = state };
        Check.Equal(1, Kpi(Widget(WidgetCatalog.ActiveAccounts, input)).Value, "compteur conservé après réouverture");
        Check.Equal(0, noNetwork.Calls, "relecture locale sans connexion");
        Check.Equal(selected, state.Directory.Coverage, "aucun faux census du domaine");
        var saved = (await reopened.ReadDomainAccountsAsync(CancellationToken.None))!;
        await reopened.SaveDomainAccountsAsync(saved with { Complete = false }, CancellationToken.None);
        Check.False((await reopened.ReadDomainAccountsAsync(CancellationToken.None))!.Complete, "une mesure partielle remplace l’ancien succès sans le masquer");
        await Check.ThrowsAsync<InvalidDataException>(() => reopened.SaveDomainAccountsAsync(saved with { Domain = Domain with { RootDn = "DC=other,DC=local" } }, CancellationToken.None), "autre domaine refusé");
    }
}
