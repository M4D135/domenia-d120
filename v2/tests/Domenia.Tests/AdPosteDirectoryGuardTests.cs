using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Tests;

internal static class AdPosteDirectoryGuardTests
{
    private static EngineContext Context(AdDirectorySource source) => new(new(AppMode.Directory, ModeReason.Argument, "Annuaire de test", null, "test.local", []), source,
        new MemoryPreferenceStore(), source.Clock, new RecordingJournal());
    private static AdPosteReader NoMachine(AdDirectorySource source) => new(source)
    { InventoryReaderOverride = _ => throw new InvalidOperationException("Aucun contact machine ne doit suivre ce refus LDAP.") };

    [Test]
    public static async Task A_paused_directory_account_blocks_the_initial_workstation_identity_before_any_LDAP_or_machine_contact()
    {
        using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var context = Context(source);
        var account = AccountAccess.From(context); await account.OverviewAsync(CancellationToken.None);
        account.RegisterRefusal(CredentialRules.Directory, "Validation du poste", Fixtures.Computer("PC1").DistinguishedName, "badCredentials", null, true);
        var calls = ldap.Calls;
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => NoMachine(source).ServicesAsync(Fixtures.Computer("PC1").DistinguishedName, CancellationToken.None), "compte suspendu");
        Check.Equal(MachineErrors.AccountPaused, error.Code, "pause partagée respectée"); Check.Equal(calls, ldap.Calls, "aucun nouveau contact LDAP");
    }

    [Test]
    public static async Task A_directory_identity_refusal_is_registered_once_and_the_next_workstation_gesture_is_local_only()
    {
        using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var context = Context(source);
        ldap.SearchAnswer = _ => throw new DomeniaOperationException(AdErrors.Credentials, "Rejet simulé");
        var reader = NoMachine(source);
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ServicesAsync(Fixtures.Computer("PC1").DistinguishedName, CancellationToken.None), "premier rejet enregistré");
        var calls = ldap.Calls;
        var second = await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ProcessesAsync(Fixtures.Computer("PC1").DistinguishedName, CancellationToken.None), "geste suivant bloqué");
        Check.Equal(MachineErrors.AccountPaused, second.Code, "aucun nouveau compte essayé"); Check.Equal(calls, ldap.Calls, "aucun second contact LDAP");
        var refusals = AccountAccess.From(context).Refusals(); Check.Equal(1, refusals.Length, "rejet unique"); Check.Equal("badCredentials", refusals.Single().Kind, "rejet d’identité conservé");
    }

    [Test]
    public static async Task SID_creation_foreign_DN_and_duplicate_parent_responses_are_rejected_before_CIM()
    {
        foreach (var defect in new[] { "sid", "creation", "dn", "duplicate" })
        {
            using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
            var pc = Fixtures.Computer("PC1");
            var wrong = pc with { Sid = defect == "sid" ? Fixtures.Domain.DomainSid + "-9999" : pc.Sid,
                WhenCreated = defect == "creation" ? pc.WhenCreated.AddMinutes(1) : pc.WhenCreated,
                DistinguishedName = defect == "dn" ? "CN=OTHER," + Fixtures.Postes : pc.DistinguishedName };
            var entry = AdPosteNetworkTests.Entry(wrong); ldap.SearchAnswer = _ => defect == "duplicate" ? [entry, entry] : [entry];
            var error = await Check.ThrowsAsync<DomeniaOperationException>(() => NoMachine(source).ServicesAsync(pc.DistinguishedName, CancellationToken.None), "identité ambiguë ou remplacée");
            Check.Equal(PosteErrors.ComputerUnknown, error.Code, "parent non confirmé");
        }
    }

    [Test]
    public static async Task Missing_parent_and_a_foreign_controller_never_fall_back_to_the_cached_workstation()
    {
        foreach (var foreign in new[] { false, true })
        {
            using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
            if (foreign) { ldap.RootContext = "DC=other,DC=local"; }
            else { ldap.SearchAnswer = _ => throw new DomeniaOperationException(AdErrors.NoSuchObject, "Objet absent simulé"); }
            await Check.ThrowsAsync<DomeniaOperationException>(() => NoMachine(source).ServicesAsync(Fixtures.Computer("PC1").DistinguishedName, CancellationToken.None), "aucun poste de remplacement");
            Check.Equal(foreign ? 0 : 1, ldap.Searches.Count, "domaine contrôlé avant lecture de l’objet");
        }
    }
}
