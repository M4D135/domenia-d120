using Domenia.Ad;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class DirectoryReadAccessTests
{
    private const string Admin = @"EXAMPLE\adm-j.martin";

    [Test]
    public static async Task A_directory_gesture_spends_a_one_shot_once_and_passive_polling_keeps_its_owned_credential_valid()
    {
        var bridge = new SimulatedBridge(); using var owner = bridge.Context;
        var access = AccountAccess.From(owner); await access.OverviewAsync(CancellationToken.None);
        access.RegisterRefusal(CredentialRules.Laps, "Lecture LAPS", "PC1", "accessDenied", null, true);
        var request = (await access.OverviewAsync(CancellationToken.None)).Pending.First(p => p.Scope == CredentialRules.Laps && p.Target == "PC1");
        using var password = PasswordSecrets.FromText("directory-lease-fixture!");
        Check.True((await access.RecoverAsync(request.Id, Admin, password, LeaseMode.OneShot, 30, "PC1", CancellationToken.None)).Result.Success, "compte temporaire validé");
        using var lease = await access.AcquireDirectoryReadAsync(CredentialRules.Laps, "PC1", CancellationToken.None);
        Check.Equal(Admin, lease.Account, "compte de la ressource retenu");
        await access.OverviewAsync(CancellationToken.None);
        lease.BeforeContact(); lease.EnsureCurrent();
        Check.True(lease.Credential?.Password?.Length > 0, "copie encore détenue par le geste après le balayage");
        using var next = await access.AcquireDirectoryReadAsync(CredentialRules.Laps, "PC1", CancellationToken.None);
        Check.Null(next.Credential, "pas de second départ avec le compte à usage unique");
    }

    [Test]
    public static async Task Directory_read_lease_is_invalidated_by_an_explicit_account_change()
    {
        var bridge = new SimulatedBridge(); using var owner = bridge.Context; var access = AccountAccess.From(owner);
        using var lease = await access.AcquireDirectoryReadAsync(CredentialRules.BitLocker, "PC1", CancellationToken.None);
        using var password = PasswordSecrets.FromText("directory-change-fixture!");
        Check.True((await access.ActivateAsync(AccessUsage.Secrets, Admin, password, CancellationToken.None)).Result.Success, "nouveau compte Secrets accepté");
        Check.Equal(AccountAccess.EpochChanged, Check.Throws<DomeniaOperationException>(lease.EnsureCurrent, "ancienne sélection invalidée").Code, "résultat ancien écarté");
    }

    [Test]
    public static async Task An_authentication_refusal_pauses_the_same_account_across_LDAP_resources_without_losing_the_refusal_result()
    {
        var bridge = new SimulatedBridge(); using var owner = bridge.Context; var access = AccountAccess.From(owner);
        using var lease = await access.AcquireDirectoryReadAsync(CredentialRules.Laps, "PC1", CancellationToken.None);
        access.RegisterRefusal(CredentialRules.Laps, "Lecture LAPS", "PC1", "badCredentials", lease.AccountKey, true);
        lease.EnsureCurrent(); // The refusal itself may be reported; another contact may not be sent.
        Check.Equal(MachineErrors.AccountPaused, Check.Throws<DomeniaOperationException>(lease.BeforeContact, "contact suivant bloqué").Code, "pause du compte");
        await Check.ThrowsAsync<DomeniaOperationException>(() => access.AcquireDirectoryReadAsync(CredentialRules.BitLocker, "PC1", CancellationToken.None), "autre ressource, même compte en pause");
        await Check.ThrowsAsync<DomeniaOperationException>(() => access.AcquireDirectoryReadAsync(CredentialRules.Directory, null, CancellationToken.None), "annuaire également en pause");
    }

    private static (AdDirectorySource Source, EngineContext Context, AdBoundaryTests.RecordingAdConnection Ldap) Source()
    {
        var ldap = new AdBoundaryTests.RecordingAdConnection();
        var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: new AdBoundaryTests.RecordingAdConnection());
        source.AdoptConnection(ldap, Fixtures.Domain, new(new(@"TEST\operator", "operator", "Opérateur", "CN=operator," + Fixtures.People), Fixtures.Domain.DomainSid + "-1001", new(RightsLevel.Unknown, "Inconnus", true, "Non mesurés")), source.Epoch, false);
        var context = new EngineContext(ModeResolver.Resolve([], "0", () => throw new InvalidOperationException()), source, new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal());
        return (source, context, ldap);
    }

    private static AdSearchRequest Query => new(Fixtures.Postes, "(objectClass=computer)", AdSearchScope.OneLevel, ["objectGUID"]) { SizeLimit = 1 };

    [Test]
    public static async Task A_native_journal_refusal_is_attributed_to_its_LDAP_lease_without_confusing_permissions_and_authentication()
    {
        foreach (var authentication in new[] { false, true })
        {
            var (source, context, ldap) = Source(); using var owned = source; using var owner = context;
            using var read = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, null, CancellationToken.None);
            read.ReportNativeRefusal(authentication); read.EnsureCurrent();
            Check.Equal(1, AccountAccess.From(context).Refusals().Length, "refus natif enregistré une seule fois");
            if (authentication)
            {
                var error = await Check.ThrowsAsync<DomeniaOperationException>(() => read.SearchAsync(Query, CancellationToken.None), "compte en pause avant contact");
                Check.Equal(MachineErrors.AccountPaused, error.Code, "rejet d’identité et non simple permission"); Check.Equal(0, ldap.Calls, "aucun essai LDAP après rejet journal");
            }
            else { await read.SearchAsync(Query, CancellationToken.None); Check.True(ldap.Calls > 0, "permission journal manquante ne devient pas un mauvais mot de passe LDAP"); }
        }
    }

    [Test]
    public static async Task A_foreign_LDAP_controller_never_serves_object_reads_even_after_a_repeated_attempt()
    {
        var (source, context, ldap) = Source(); using var owned = source; using var owner = context;
        ldap.RootContext = "DC=foreign,DC=local";
        using var read = await AdReadAccess.AcquireAsync(source, CredentialRules.BitLocker, "PC1", CancellationToken.None);
        for (var n = 0; n < 2; n++)
        { await Check.ThrowsAsync<DomeniaOperationException>(() => read.SearchAsync(Query, CancellationToken.None), "contrôleur étranger refusé"); }
        Check.Equal(0, ldap.Searches.Count, "échec de domaine non mémorisé comme une connexion validée");
    }

    [Test]
    public static async Task LDAP_wrapper_records_a_refusal_then_blocks_the_next_contact_without_an_account_retry()
    {
        var (source, context, ldap) = Source(); using var owned = source; using var owner = context;
        ldap.SearchAnswer = _ => throw new DomeniaOperationException(AdErrors.Credentials, "Rejet simulé");
        using var read = await AdReadAccess.AcquireAsync(source, CredentialRules.Laps, "PC1", CancellationToken.None);
        await Check.ThrowsAsync<DomeniaOperationException>(() => read.SearchAsync(Query, CancellationToken.None), "premier rejet");
        var calls = ldap.Calls;
        var second = await Check.ThrowsAsync<DomeniaOperationException>(() => read.SearchAsync(Query, CancellationToken.None), "aucun second essai");
        Check.Equal(MachineErrors.AccountPaused, second.Code, "raison locale de suspension");
        Check.Equal(calls, ldap.Calls, "aucun LDAP après rejet");
        Check.Equal(1, AccountAccess.From(context).Refusals().Length, "rejet enregistré une seule fois");
    }

    [Test]
    public static async Task A_directory_session_change_discards_the_response_already_in_flight()
    {
        var (source, context, ldap) = Source(); using var owned = source; using var owner = context;
        using var read = await AdReadAccess.AcquireAsync(source, CredentialRules.BitLocker, "PC1", CancellationToken.None);
        ldap.SearchAnswer = _ => { source.Reset(); return []; };
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => read.SearchAsync(Query, CancellationToken.None), "réponse ancienne écartée");
        Check.Equal(AccountAccess.EpochChanged, error.Code, "fence de session");
    }

    [Test]
    public static async Task LDAP_read_scope_is_checked_before_binding_and_cannot_request_a_foreign_object()
    {
        var (source, context, ldap) = Source(); using var owned = source; using var owner = context;
        using var read = await AdReadAccess.AcquireAsync(source, CredentialRules.BitLocker, "PC1", CancellationToken.None);
        await Check.ThrowsAsync<DomeniaOperationException>(() => read.SearchAsync(new("DC=foreign,DC=local", "(objectClass=*)", AdSearchScope.Base, ["objectGUID"]), CancellationToken.None), "objet hors domaine refusé");
        Check.Equal(0, ldap.Calls, "aucun bind LDAP pour un objet étranger");
    }
}
