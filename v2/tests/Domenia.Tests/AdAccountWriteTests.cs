using System.Security.Principal;
using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static class AdAccountWriteTests
{
    private const string Dn = "CN=Compte," + Fixtures.People;
    private const string OperatorDn = "CN=Operateur," + Fixtures.People;
    private const string Login = "TEST\\operateur";

    [Test]
    public static async Task Five_account_writes_are_discovered_and_round_trip_by_GUID_on_the_same_controller()
    {
        foreach (var kind in new[] { AccountUnlock.Kind, AccountActivation.EnableKind, AccountActivation.DisableKind, AccountMustChangePassword.Kind, AccountExpiration.Kind })
        {
            using var ldap = new Connection(); using var source = Source(ldap);
            ldap.Values["userAccountControl"] = [kind == AccountActivation.EnableKind ? "514" : "512"];
            using var writers = WriteExecutors.Discover(source, [typeof(AdDirectorySource).Assembly]);
            var executor = writers.ForKind(kind)!;
            var draft = kind switch
            {
                AccountUnlock.Kind => await ((IAccountUnlockExecutor)executor).PlanAsync(Dn, CancellationToken.None),
                AccountActivation.EnableKind => await ((IAccountEnableExecutor)executor).PlanAsync(Dn, CancellationToken.None),
                AccountActivation.DisableKind => await ((IAccountDisableExecutor)executor).PlanAsync(Dn, null, CancellationToken.None),
                AccountMustChangePassword.Kind => await ((IAccountMustChangePasswordExecutor)executor).PlanAsync(Dn, CancellationToken.None),
                _ => await ((IAccountExpirationExecutor)executor).PlanAsync(Dn, new DateOnly(2026, 11, 15), CancellationToken.None),
            };
            Check.True(draft.Origin!.Matches(await source.GetSessionAsync(CancellationToken.None)), "lecture liée à la session");
            var plan = Seal(draft);
            Check.True((await executor.CheckAsync(plan, CancellationToken.None)).Current, "préconditions relues");
            Check.Equal(0, ldap.Writes, "préparer et vérifier n’écrit rien");
            Check.Equal(WriteResult.Applied, (await executor.ExecuteAsync(plan, CancellationToken.None)).Result, "requête acceptée");
            Check.Equal("<GUID=" + ldap.Id.ToString("D") + ">", ldap.LastTarget, "pas de ciblage d’un homonyme par DN");
            Check.Equal(1, ldap.Writes, "une seule requête LDAP");
            Check.Equal(VerificationState.Verified, (await executor.VerifyAsync(plan, CancellationToken.None)).State, "effet relu par GUID");
            Check.True(ldap.Searches.Last().Filter == AdObjectAccess.GuidFilter(ldap.Id), "relecture par identité immuable");
        }
    }

    [Test]
    public static async Task A_recreated_target_or_changed_UAC_is_never_overwritten()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        var executor = new AdAccountDisableExecutor(source);
        var plan = Seal(await executor.PlanAsync(Dn, null, CancellationToken.None));
        ldap.Values["userAccountControl"] = ["66048"];
        Check.False((await executor.CheckAsync(plan, CancellationToken.None)).Current, "bit étranger changé");
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.ExecuteAsync(plan, CancellationToken.None), "aucun envoi après changement");
        ldap.Values["userAccountControl"] = ["512"];
        ldap.Values["objectGUID"] = [Guid.NewGuid().ToByteArray()];
        Check.False((await executor.CheckAsync(plan, CancellationToken.None)).Current, "homonyme recréé");
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.ExecuteAsync(plan, CancellationToken.None), "homonyme protégé");
        Check.Equal(0, ldap.Writes, "aucune modification");
    }

    [Test]
    public static async Task The_own_session_system_accounts_and_missing_values_are_refused_before_a_plan()
    {
        using var ldap = new Connection(); using var source = Source(ldap, Dn);
        var disable = new AdAccountDisableExecutor(source);
        await Check.ThrowsAsync<DomeniaOperationException>(() => disable.PlanAsync(Dn, "CN=Quelquun," + Fixtures.People, CancellationToken.None), "opérateur fourni par le client ignoré");
        ldap.Values["objectSid"] = [Sid(Fixtures.Domain.DomainSid + "-502")];
        await Check.ThrowsAsync<DomeniaOperationException>(() => new AdAccountUnlockExecutor(source).PlanAsync(Dn, CancellationToken.None), "krbtgt refusé même pour déverrouiller");
        ldap.Values["objectSid"] = [Sid(Fixtures.Domain.DomainSid + "-1001")];
        ldap.Values.Remove("pwdLastSet");
        await Check.ThrowsAsync<DomeniaOperationException>(() => new AdAccountMustChangePasswordExecutor(source).PlanAsync(Dn, CancellationToken.None), "absence ne signifie pas zéro");
        ldap.Values.Remove("userAccountControl");
        await Check.ThrowsAsync<DomeniaOperationException>(() => new AdAccountUnlockExecutor(source).PlanAsync(Dn, CancellationToken.None), "état illisible");
        Check.Equal(0, ldap.Writes, "aucune écriture");
    }

    [Test]
    public static async Task An_already_completed_write_sends_nothing_and_an_atomic_UAC_conflict_preserves_the_other_change()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        var executor = new AdAccountDisableExecutor(source);
        var plan = Seal(await executor.PlanAsync(Dn, null, CancellationToken.None));
        ldap.Values["userAccountControl"] = ["514"];
        Check.Equal(WriteResult.NoChange, (await executor.ExecuteAsync(plan, CancellationToken.None)).Result, "déjà fait");
        Check.Equal(0, ldap.Writes, "aucun Modify inutile");
        ldap.Values["userAccountControl"] = ["512"];
        ldap.BeforeModify = () => ldap.Values["userAccountControl"] = ["66048"];
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.ExecuteAsync(plan, CancellationToken.None), "valeur modifiée entre lecture et requête");
        Check.Equal("66048", (string)ldap.Values["userAccountControl"][0], "bit concurrent conservé");
        Check.Equal(2, ldap.LastModifications.Count, "comparaison puis ajout dans la même requête");
        Check.Equal(AdModificationKind.Delete, ldap.LastModifications[0].Kind, "suppression de la valeur exacte sans permissive-modify");
        Check.Equal(AdModificationKind.Add, ldap.LastModifications[1].Kind, "ajout de la valeur confirmée");
    }

    [Test]
    public static async Task Lost_transport_preserves_the_unknown_outcome_until_a_readback_confirms_the_effect()
    {
        using var ldap = new Connection { LoseAnswer = true }; using var source = Source(ldap);
        var executor = new AdAccountDisableExecutor(source);
        var decision = ModeResolver.Resolve([], "0", () => throw new InvalidOperationException());
        using var context = new EngineContext(decision, source, new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal(),
            writers: WriteExecutors.From([executor]));
        var circuit = WriteCircuit.From(context);
        var planned = await circuit.PlanAsync(await executor.PlanAsync(Dn, null, CancellationToken.None), CancellationToken.None);
        var receipt = await circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, CancellationToken.None);
        Check.Equal(WriteResult.Unknown, receipt.Result, "réponse réseau perdue");
        Check.Equal(VerificationState.Verified, receipt.Verification, "effet relu sans répéter");
        Check.False(receipt.Pending, "relecture concluante");
        Check.Equal(1, ldap.Writes, "jamais réessayé");
    }

    [Test]
    public static async Task A_password_never_expires_change_and_unreadable_lock_state_are_not_reported_as_success()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        var change = new AdAccountMustChangePasswordExecutor(source);
        var plan = Seal(await change.PlanAsync(Dn, CancellationToken.None));
        ldap.Values["userAccountControl"] = ["66048"];
        Check.False((await change.CheckAsync(plan, CancellationToken.None)).Current, "mot de passe désormais sans expiration");
        ldap.Values["pwdLastSet"] = ["0"];
        Check.Equal(VerificationState.Mismatch, (await change.VerifyAsync(plan, CancellationToken.None)).State, "zéro seul ne prouve pas le changement exigé");
        var unlock = new AdAccountUnlockExecutor(source);
        var unlockPlan = Seal(await unlock.PlanAsync(Dn, CancellationToken.None));
        ldap.Values["lockoutTime"] = ["0"];
        ldap.Values.Remove("msDS-User-Account-Control-Computed");
        Check.Equal(VerificationState.Unknown, (await unlock.VerifyAsync(unlockPlan, CancellationToken.None)).State, "état calculé inconnu");
    }

    [Test]
    public static async Task Password_reset_requires_its_held_secret_and_the_effective_policy_then_sends_once()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        using var executor = new AdAccountPasswordResetExecutor(source);
        using var password = PasswordSecrets.FromText("Vélo-Bleu-2026!");
        var draft = await executor.PlanAsync(Dn, new(true, true), password, CancellationToken.None);
        var plan = Seal(draft);
        Check.False((await executor.CheckAsync(plan, CancellationToken.None)).Current, "secret pas encore confié au plan");
        executor.Hold(plan.Id, plan.ExpiresAt, password);
        Check.True((await executor.CheckAsync(plan, CancellationToken.None)).Current, "secret détenu");
        var json = System.Text.Json.JsonSerializer.Serialize(plan);
        Check.False(json.Contains("Vélo", StringComparison.Ordinal), "aucun secret dans le plan");
        Check.Equal(WriteResult.Applied, (await executor.ExecuteAsync(plan, CancellationToken.None)).Result, "acceptation LDAP");
        Check.Equal(VerificationState.Verified, (await executor.VerifyOutcomeAsync(plan, WriteResult.Applied, CancellationToken.None)).State, "acceptation et relecture");
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.ExecuteAsync(plan, CancellationToken.None), "secret à usage unique");
        Check.Equal(1, ldap.Writes, "un seul envoi");
    }

    [Test]
    public static async Task Password_policy_or_history_control_unavailable_refuses_the_reset_without_sending()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        using var executor = new AdAccountPasswordResetExecutor(source);
        using var password = PasswordSecrets.FromText("Vélo-Bleu-2026!");
        ldap.PasswordSupported = false;
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.PlanAsync(Dn, new(true, false), password, CancellationToken.None), "pas de repli sans historique");
        ldap.PasswordSupported = true; ldap.PolicyMinLength = 30;
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.PlanAsync(Dn, new(true, false), password, CancellationToken.None), "stratégie effective plus stricte");
        ldap.PolicyMinLength = 8;
        var plan = Seal(await executor.PlanAsync(Dn, new(true, false), password, CancellationToken.None));
        executor.Hold(plan.Id, plan.ExpiresAt, password);
        ldap.PolicyMinLength = 30;
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.ExecuteAsync(plan, CancellationToken.None), "stratégie modifiée depuis le plan");
        Check.Equal(0, ldap.Writes, "aucun secret envoyé");
    }

    [Test]
    public static async Task Password_transport_uncertainty_cannot_be_settled_by_flags_that_already_matched()
    {
        foreach (var loseAnswer in new[] { false, true })
        {
            using var ldap = new Connection { LoseAnswer = loseAnswer }; using var source = Source(ldap);
            ldap.Values["pwdLastSet"] = ["0"];
            using var executor = new AdAccountPasswordResetExecutor(source);
            using var password = PasswordSecrets.FromText("Vélo-Bleu-2026!");
            using var context = new EngineContext(ModeResolver.Resolve([], "0", () => throw new InvalidOperationException()), source,
                new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal(), writers: WriteExecutors.From([executor]));
            var circuit = WriteCircuit.From(context);
            var planned = await circuit.PlanAsync(await executor.PlanAsync(Dn, new(true, false), password, CancellationToken.None), CancellationToken.None);
            executor.Hold(planned.Plan.Id, planned.Plan.ExpiresAt, password);
            var receipt = await circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, CancellationToken.None);
            Check.Equal(loseAnswer ? VerificationState.Unknown : VerificationState.Verified, receipt.Verification, "les mêmes drapeaux ne prouvent pas la même issue");
            Check.Equal(loseAnswer, receipt.Pending, "issue incertaine conservée");
            var reread = await circuit.VerifyAsync(receipt.Id, CancellationToken.None);
            Check.Equal(receipt.Verification, reread.Verification, "relecture du reçu conserve la preuve de réponse ou son absence");
            Check.Equal(1, ldap.Writes, "aucun nouvel essai");
        }
    }

    [Test]
    public static async Task Fiche_and_accounts_password_writers_are_distinct_and_share_the_secure_reset_path()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        using var writers = WriteExecutors.Discover(source, [typeof(AdDirectorySource).Assembly]);
        var fiche = writers.Require<IPasswordResetExecutor>();
        var accounts = writers.Require<IAccountPasswordResetExecutor>();
        Check.False(ReferenceEquals(fiche, accounts), "deux contrats et mémoires de secrets distincts");
        using var password = PasswordSecrets.FromText("Vélo-Bleu-2026!");
        var draft = await fiche.PlanAsync(Dn, true, true, false, password, FicheSecurityPolicy.Default, CancellationToken.None);
        var plan = Seal(draft);
        Check.Equal(ObjectWrites.ResetPasswordKind, plan.Kind, "type de reçu propre à la Fiche");
        Check.True(plan.Confirmation.TypedNameRequired && plan.Confirmation.TypedName == "compte", "confirmation nominative même pour un compte standard");
        fiche.Hold(plan.Id, plan.ExpiresAt, password);
        await fiche.ExecuteAsync(plan, CancellationToken.None);
        Check.Equal(VerificationState.Verified, (await ((IWriteOutcomeVerifier)fiche).VerifyOutcomeAsync(plan, WriteResult.Applied, CancellationToken.None)).State, "acceptation et relecture");
        Check.False(System.Text.Json.JsonSerializer.Serialize(plan).Contains("Vélo", StringComparison.Ordinal), "secret absent du plan");
        await Check.ThrowsAsync<DomeniaOperationException>(() => fiche.ExecuteAsync(plan, CancellationToken.None), "secret déjà consommé");
        Check.Equal(1, ldap.Writes, "un seul envoi");
    }

    [Test]
    public static async Task Fiche_reset_without_forced_change_still_seals_pwdLastSet_and_refuses_a_later_password()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        using var writer = new AdFichePasswordResetExecutor(source);
        using var password = PasswordSecrets.FromText("Vélo-Bleu-2026!");
        var plan = Seal(await writer.PlanAsync(Dn, false, false, false, password, FicheSecurityPolicy.Default, CancellationToken.None));
        var stamp = plan.Changes.Single(c => c.Attribute == "pwdLastSet");
        Check.True(stamp.BeforeValue is not null && stamp.AfterValue is null, "ancien horodatage conservé et nouvelle date pilotée par AD");
        writer.Hold(plan.Id, plan.ExpiresAt, password);
        ldap.Values["pwdLastSet"] = [AccountWrites.Raw(AdValues.ToFileTime(Fixtures.Now))];
        Check.False((await writer.CheckAsync(plan, CancellationToken.None)).Current, "mot de passe changé depuis la préparation");
        await Check.ThrowsAsync<DomeniaOperationException>(() => writer.ExecuteAsync(plan, CancellationToken.None), "secret non envoyé");
        Check.Equal(0, ldap.Writes, "aucune mutation");
    }

    [Test]
    public static async Task Fiche_reset_validates_the_real_secret_before_the_plan_and_refuses_system_objects()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        using var writer = new AdFichePasswordResetExecutor(source);
        using var weak = PasswordSecrets.FromText("aaaaaaaaaaaaaa");
        await Check.ThrowsAsync<DomeniaOperationException>(() => writer.PlanAsync(Dn, true, false, false, weak, FicheSecurityPolicy.Default, CancellationToken.None), "complexité refusée avant confirmation");
        using var password = PasswordSecrets.FromText("Vélo-Bleu-2026!");
        ldap.Values["isCriticalSystemObject"] = ["TRUE"];
        await Check.ThrowsAsync<DomeniaOperationException>(() => writer.PlanAsync(Dn, true, false, false, password, FicheSecurityPolicy.Default, CancellationToken.None), "système protégé");
        ldap.Values.Remove("isCriticalSystemObject"); ldap.Values.Remove("lockoutTime");
        await Check.ThrowsAsync<DomeniaOperationException>(() => writer.PlanAsync(Dn, true, false, false, password, FicheSecurityPolicy.Default, CancellationToken.None), "verrouillage non lu ne vaut pas zéro");
        Check.Equal(0, ldap.Writes, "aucun envoi");
    }

    [Test]
    public static async Task Fiche_reset_keeps_an_unknown_response_pending_even_when_password_flags_already_matched()
    {
        using var ldap = new Connection { LoseAnswer = true }; using var source = Source(ldap);
        ldap.Values["pwdLastSet"] = ["0"];
        using var writer = new AdFichePasswordResetExecutor(source);
        using var password = PasswordSecrets.FromText("Vélo-Bleu-2026!");
        using var context = new EngineContext(ModeResolver.Resolve([], "0", () => throw new InvalidOperationException()), source,
            new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal(), writers: WriteExecutors.From([writer]));
        var circuit = WriteCircuit.From(context);
        var planned = await circuit.PlanAsync(await writer.PlanAsync(Dn, true, false, false, password, FicheSecurityPolicy.Default, CancellationToken.None), CancellationToken.None);
        writer.Hold(planned.Plan.Id, planned.Plan.ExpiresAt, password);
        var receipt = await circuit.ExecuteAsync(planned.Plan.Id, planned.Token, "compte", null, CancellationToken.None);
        Check.True(receipt.Pending && receipt.Verification == VerificationState.Unknown, "issue inconnue conservée");
        Check.Equal(VerificationState.Unknown, (await circuit.VerifyAsync(receipt.Id, CancellationToken.None)).Verification, "aucune preuve créée par une seconde lecture");
        Check.Equal(1, ldap.Writes, "aucun renvoi");
    }

    [Test]
    public static async Task Reset_does_not_claim_an_effective_forced_change_when_password_never_expires()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        using var writer = new AdFichePasswordResetExecutor(source);
        ldap.Values["userAccountControl"] = ["66048"];
        using var password = PasswordSecrets.FromText("Vélo-Bleu-2026!");
        var plan = Seal(await writer.PlanAsync(Dn, true, false, false, password, FicheSecurityPolicy.Default, CancellationToken.None));
        writer.Hold(plan.Id, plan.ExpiresAt, password);
        await writer.ExecuteAsync(plan, CancellationToken.None);
        Check.Equal(VerificationState.Mismatch, (await writer.VerifyOutcomeAsync(plan, WriteResult.Applied, CancellationToken.None)).State, "pwdLastSet zéro ne suffit pas");
        Check.Equal("66048", (string)ldap.Values["userAccountControl"][0], "aucune option non confirmée changée");
    }

    private static WritePlan Seal(WritePlanDraft draft) => WritePlans.Seal(draft, WritePlans.NewId(), Login, AppMode.Directory, Fixtures.Now, TimeZoneInfo.Utc);
    private static AdDirectorySource Source(Connection ldap, string operatorDn = OperatorDn)
    {
        var source = new AdDirectorySource("test.local", () => Login, TestClock.Fixed(), connection: new AdBoundaryTests.RecordingAdConnection());
        source.AdoptConnection(ldap, Fixtures.Domain, new(new(Login, "Opérateur", null, operatorDn), Fixtures.Domain.DomainSid + "-1100",
            new(RightsLevel.Unknown, "Inconnus", true, "Non mesurés")), source.Epoch, false);
        return source;
    }
    private static byte[] Sid(string text) { var sid = new SecurityIdentifier(text); var data = new byte[sid.BinaryLength]; sid.GetBinaryForm(data, 0); return data; }

    private sealed class Connection : IAdConnection, IAdPasswordConnection
    {
        internal Guid Id { get; } = Fixtures.IdOf("account-write");
        internal Dictionary<string, IReadOnlyList<object>> Values { get; } = new(StringComparer.OrdinalIgnoreCase);
        internal List<AdSearchRequest> Searches { get; } = [];
        internal int Writes { get; private set; }
        internal string? LastTarget { get; private set; }
        internal IReadOnlyList<AdModification> LastModifications { get; private set; } = [];
        internal Action? BeforeModify { get; set; }
        internal bool LoseAnswer { get; init; }
        public string Server => "DC1.test.local";
        internal Connection()
        {
            Values["objectGUID"] = [Id.ToByteArray()]; Values["objectSid"] = [Sid(Fixtures.Domain.DomainSid + "-1001")];
            Values["objectClass"] = ["top", "person", "user"]; Values["sAMAccountName"] = ["compte"]; Values["name"] = ["Compte"];
            Values["userAccountControl"] = ["512"]; Values["pwdLastSet"] = [AccountWrites.Raw(AdValues.ToFileTime(Fixtures.Now.AddDays(-1)))];
            Values["lockoutTime"] = [AccountWrites.Raw(AdValues.ToFileTime(Fixtures.Now.AddMinutes(-1)))]; Values["msDS-User-Account-Control-Computed"] = ["16"];
            Values["accountExpires"] = ["0"]; Values["uSNChanged"] = ["1"];
        }
        internal bool PasswordSupported { get; set; } = true;
        internal int PolicyMinLength { get; set; } = 8;
        public Task<AdRootDse> RootDseAsync(CancellationToken cancellationToken) => Task.FromResult(new AdRootDse(Fixtures.Root, "", "", Fixtures.Root, Server, null, null,
            PasswordSupported ? ["1.2.840.113556.1.4.2239"] : [], null));
        public Task<AdEntry?> ReadAsync(string distinguishedName, IReadOnlyList<string> attributes, CancellationToken cancellationToken) => throw new InvalidOperationException();
        public Task<IReadOnlyList<AdEntry>> SearchAsync(AdSearchRequest request, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested(); Searches.Add(request);
            if (request.Scope == AdSearchScope.Base && request.BaseDn == Fixtures.Root)
            {
                return Task.FromResult<IReadOnlyList<AdEntry>>([AdFicheReaderTests.Entry(Fixtures.Root, "domainDNS", new()
                { ["maxPwdAge"] = ["-77760000000000"], ["minPwdLength"] = [PolicyMinLength.ToString(System.Globalization.CultureInfo.InvariantCulture)],
                    ["pwdHistoryLength"] = ["24"], ["pwdProperties"] = ["1"], ["lockoutThreshold"] = ["5"], ["lockoutDuration"] = ["-18000000000"] })]);
            }
            return Task.FromResult<IReadOnlyList<AdEntry>>(request.Scope == AdSearchScope.Base && request.BaseDn == Dn || request.Filter == AdObjectAccess.GuidFilter(Id)
                ? [new(Dn, Values)] : []);
        }
        public Task ModifyAsync(string distinguishedName, IReadOnlyList<AdModification> modifications, CancellationToken cancellationToken)
        {
            Writes++; LastTarget = distinguishedName; LastModifications = modifications; BeforeModify?.Invoke();
            Check.Equal("<GUID=" + Id.ToString("D") + ">", distinguishedName, "identité LDAP");
            var next = new Dictionary<string, IReadOnlyList<object>>(Values, StringComparer.OrdinalIgnoreCase);
            foreach (var change in modifications)
            {
                if (change.Kind == AdModificationKind.Delete)
                {
                    if (!next.TryGetValue(change.Attribute, out var old) || !old.SequenceEqual(change.Values))
                    { throw new DomeniaOperationException(AdErrors.Constraint, "Valeur concurrente"); }
                    next.Remove(change.Attribute);
                }
                else
                {
                    if (change.Kind == AdModificationKind.Add && next.ContainsKey(change.Attribute)) { throw new DomeniaOperationException(AdErrors.Exists, "Valeur déjà présente"); }
                    next[change.Attribute] = change.Values;
                }
            }
            foreach (var pair in next) { Values[pair.Key] = pair.Value; }
            if (modifications.Any(m => m.Attribute == "lockoutTime")) { Values["msDS-User-Account-Control-Computed"] = ["0"]; }
            if (LoseAnswer) { throw new AdWriteOutcomeUnknownException(); }
            return Task.CompletedTask;
        }
        public Task ResetPasswordAsync(Guid objectGuid, System.Security.SecureString password, bool mustChange, bool unlock, CancellationToken cancellationToken)
        {
            Check.Equal(Id, objectGuid, "mot de passe ciblé par GUID");
            Check.True(password.Length > 0, "secret natif encore détenu pendant l’envoi");
            Writes++; LastTarget = "<GUID=" + Id.ToString("D") + ">";
            Values["pwdLastSet"] = [mustChange ? "0" : AccountWrites.Raw(AdValues.ToFileTime(Fixtures.Now))];
            if (unlock) { Values["lockoutTime"] = ["0"]; Values["msDS-User-Account-Control-Computed"] = ["0"]; }
            if (LoseAnswer) { throw new AdWriteOutcomeUnknownException(); }
            return Task.CompletedTask;
        }
        public Task RenameAsync(string distinguishedName, string newParentDn, string newRdn, CancellationToken cancellationToken) => throw new InvalidOperationException();
        public Task AddAsync(string distinguishedName, IReadOnlyDictionary<string, IReadOnlyList<object>> attributes, CancellationToken cancellationToken) => throw new InvalidOperationException();
        public Task DeleteAsync(string distinguishedName, CancellationToken cancellationToken) => throw new InvalidOperationException();
        public void Dispose() { }
    }
}
