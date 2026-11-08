using System.Collections.Immutable;
using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static class AdAssistanceShellTests
{
    private static SubjectRecord Subject(DirectoryComputer pc) => new(pc.DistinguishedName, pc.ObjectGuid, AssistanceSubject.Computer, pc.Name, pc.SamAccountName,
        "Postes", new Dictionary<string, IReadOnlyList<object?>>(), true, null, [], [], [], Fixtures.Now);

    [Test]
    public static async Task Native_support_local_search_dossier_and_shell_lookup_never_contact_AD()
    {
        var pc = Fixtures.Computer("PC-Étage"); var user = Fixtures.User("Éléonore");
        var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(users: [user], computers: [pc]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = _ => throw new InvalidOperationException("Aucun accès réseau autorisé") };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var support = new AdAssistanceReader(source); var shell = new AdShellReader(source);
        Check.Equal(1, (await support.SearchAsync("eleonore", 10, CancellationToken.None)).Length, "recherche sans accents");
        Check.Equal(1, (await shell.LookupAsync("pc-etage", ImmutableHashSet.Create(ShellLookupKind.Computer), 10, CancellationToken.None)).Total, "sélecteur local");
        Check.Equal(0, (await support.ComputersNamedAsync(["PC-É"], CancellationToken.None)).Length, "pas de résolution approximative d’une liste");
        Check.Equal(1, (await support.ComputersNamedAsync([pc.SamAccountName], CancellationToken.None)).Length, "nom de compte exact");
        var dossier = await support.DossierDataAsync(new(new(true, null, "Guids", [pc.ObjectGuid.ToString("D")], null, pc.Name, 1, false), ["etat", "postes", "observations"], 100), CancellationToken.None);
        Check.Equal(1, dossier.Computers.Count, "poste inclus par GUID"); Check.Equal(0, dossier.Observations.Count, "aucune observation inventée");
        Check.False(dossier.Source["Simulation"]!.GetValue<bool>(), "origine réelle locale");
        Check.False((await shell.CoverageAsync(CancellationToken.None)).Available, "couverture simulation non revendiquée");
        Check.Equal(0, ldap.Calls, "aucun bind ou RootDSE dans les lectures locales");
    }

    [Test]
    public static async Task Native_support_rejects_forged_actions_subject_kinds_and_domain_wide_dossiers()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var reader = new AdAssistanceReader(source);
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.RunStepAsync(new("arbitrary", "Invoke-Expression", "Libre", [AssistanceSubject.Computer]), Subject(pc), CancellationToken.None), "action non déclarée refusée");
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.RunStepAsync(AssistanceRecipes.FindAction("inventory")!, Subject(pc) with { Kind = AssistanceSubject.User }, CancellationToken.None), "type de sujet refusé");
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.DossierDataAsync(new(new(true, null, "OU", [], Fixtures.Root, "Domaine", 1, false), ["postes"], 100), CancellationToken.None), "racine refusée même si le DTO dit Valid");
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.DossierDataAsync(new(new(true, null, "Guids", [], null, "Tous", 0, false), ["postes"], 100), CancellationToken.None), "sélection vide n’élargit pas le périmètre");
        Check.Equal(0, ldap.Calls, "rejets avant réseau");
    }

    [Test]
    public static async Task Native_support_subject_is_qualified_and_replaced_GUID_is_not_accepted_for_a_step()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc])); var actual = pc;
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(actual)] : [] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var reader = new AdAssistanceReader(source); var subject = await reader.ReadSubjectAsync(pc.DistinguishedName, CancellationToken.None);
        Check.Equal(pc.ObjectGuid, subject!.Guid, "GUID LDAP conservé"); Check.Equal(Fixtures.Now, subject.ReadAt, "horloge de la lecture réelle");
        actual = pc with { ObjectGuid = Guid.NewGuid() };
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.RunStepAsync(AssistanceRecipes.FindAction("inventory")!, subject, CancellationToken.None), "GUID remplacé refusé avant WMI");
        Check.True(ldap.Searches.All(q => q.SizeLimit == 2), "une seule identité, réponse bornée");
    }

    [Test]
    public static async Task Shell_picker_reports_same_GUID_moved_and_does_not_accept_a_namesake()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc]));
        var moved = pc with { DistinguishedName = "CN=PC1,OU=Autre," + Fixtures.Root };
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = _ => [AdPosteNetworkTests.Entry(moved)] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var shell = new AdShellReader(source); var check = await shell.VerifyAsync(pc.DistinguishedName, pc.ObjectGuid, CancellationToken.None);
        Check.Equal("moved", check.State, "déplacement conservant le GUID signalé"); Check.Equal(moved.DistinguishedName, check.Item!.Dn, "nouveau DN");
        moved = moved with { ObjectGuid = Guid.NewGuid() };
        await Check.ThrowsAsync<DomeniaOperationException>(() => shell.VerifyAsync(pc.DistinguishedName, pc.ObjectGuid, CancellationToken.None), "homonyme avec autre GUID rejeté");
    }

    [Test]
    public static async Task Shell_denied_picker_never_becomes_a_missing_or_successful_object()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = _ => throw new DomeniaOperationException(AdErrors.AccessDenied, "Refus de test") };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var check = await new AdShellReader(source).VerifyAsync(pc.DistinguishedName, pc.ObjectGuid, CancellationToken.None);
        Check.Equal("denied", check.State, "refus distinct de l’absence"); Check.Null(check.Item, "aucun ancien objet présenté comme relu");
    }
    [Test]
    public static async Task Assistance_missing_account_state_is_unknown_and_never_an_active_card()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc]));
        var complete = AdPosteNetworkTests.Entry(pc);
        var incomplete = new AdEntry(pc.DistinguishedName, complete.AttributeNames.Where(n => n != "userAccountControl").ToDictionary(n => n, complete.Raw));
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = _ => [incomplete] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => new AdAssistanceReader(source).ReadSubjectAsync(pc.DistinguishedName, CancellationToken.None), "UAC non lu refusé");
        Check.Equal(DomeniaErrors.SourceUnavailable, error.Code, "source inconnue distincte d’un compte actif");
    }

    [Test]
    public static async Task Shell_missing_OU_has_a_missing_state_without_falling_back_to_a_parent()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = _ => throw new DomeniaOperationException(AdErrors.NoSuchObject, "Absente") };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap,
            localStore: new AdPosteNetworkTests.Cache(Fixtures.Snapshot()));
        var result = await new AdShellReader(source).ResolveOuAsync(Fixtures.Postes, CancellationToken.None);
        Check.Equal("missing", result.State, "OU absente explicitée"); Check.Null(result.Item, "aucun parent substitué");
    }

}
