using System.Collections.Immutable;
using System.Security;
using Domenia.Core;

namespace Domenia.Tests;

/// <summary>Pure rules of the Comptes screen (docs/ops/comptes.md): rows, counts, support band, actions, lockouts, batch, writes.</summary>
internal static class AccountsRulesTests
{
    private const string Controller = "DC1.test.local";

    private static DirectoryUser Locked(string name = "Camille", int? adminCount = null) => Fixtures.User(name) with
    {
        ComputedAccountControl = AdValues.LockedOut,
        LockoutTime = Fixtures.Ft(Fixtures.Now - TimeSpan.FromMinutes(18)),
        BadPasswordCount = 5,
        AdminCount = adminCount,
    };

    private static WritePlan Seal(WritePlanDraft draft) =>
        WritePlans.Seal(draft, WritePlans.NewId(), @"TEST\adm", AppMode.Directory, Fixtures.Now, TestClock.Paris);

    private static SecureString Secret(string text) => PasswordSecrets.FromText(text);

    [Test]
    public static void Lock_state_never_takes_a_lone_lockout_time_for_a_lockout()
    {
        Check.Equal(AccountLock.Locked, AccountsRules.LockOf(Locked()), "bit calculé\u00A0: verrouillé");
        Check.Equal(AccountLock.ToCheck, AccountsRules.LockOf(Locked() with { ComputedAccountControl = null }), "calcul illisible\u00A0: à vérifier");
        Check.Equal(AccountLock.Expired, AccountsRules.LockOf(Locked() with { ComputedAccountControl = 0 }), "durée écoulée\u00A0: échu");
        Check.Equal(AccountLock.Unlocked, AccountsRules.LockOf(Fixtures.User("Libre")), "jamais verrouillé");
    }

    [Test]
    public static void Status_follows_the_order_of_urgency()
    {
        Check.Equal(AccountStatus.Disabled, AccountsRules.StatusOf(false, AccountLock.Locked, true, PasswordClass.Expired), "désactivé d’abord");
        Check.Equal(AccountStatus.Locked, AccountsRules.StatusOf(true, AccountLock.Locked, true, PasswordClass.Expired), "puis verrouillé");
        Check.Equal(AccountStatus.LockToCheck, AccountsRules.StatusOf(true, AccountLock.ToCheck, false, PasswordClass.Valid), "verrouillage à vérifier");
        Check.Equal(AccountStatus.AccountExpired, AccountsRules.StatusOf(true, AccountLock.Expired, true, PasswordClass.Expired), "compte expiré avant le mot de passe");
        Check.Equal(AccountStatus.PasswordExpired, AccountsRules.StatusOf(true, AccountLock.Unlocked, false, PasswordClass.Expired), "mot de passe expiré");
        Check.Equal(AccountStatus.MustChange, AccountsRules.StatusOf(true, AccountLock.Unlocked, false, PasswordClass.MustChange), "à changer");
        Check.Equal(AccountStatus.Expiring, AccountsRules.StatusOf(true, AccountLock.Unlocked, false, PasswordClass.Expiring), "expire bientôt");
        Check.Equal(AccountStatus.Ok, AccountsRules.StatusOf(true, AccountLock.Unlocked, false, PasswordClass.NeverExpires), "actif");
        Check.Equal(Tone.Alert, AccountsRules.StatusTone(AccountStatus.Locked), "ton du verrouillage");
    }

    [Test]
    public static void Row_dates_come_from_the_controller_and_an_estimate_is_said()
    {
        var user = Fixtures.User("Alice");
        var row = AccountsRules.Row(user, Fixtures.Domain, Fixtures.Now);
        Check.False(row.PasswordEstimated, "date calculée par le contrôleur");
        Check.Equal(Fixtures.Now + TimeSpan.FromDays(80), row.PasswordExpiresAt, "expiration");
        var estimated = AccountsRules.Row(user with { PasswordExpiryComputed = null }, Fixtures.Domain, Fixtures.Now);
        Check.True(estimated.PasswordEstimated, "sans calcul\u00A0: estimée par la stratégie");
        Check.Equal("Utilisateurs", row.Ou, "OU parente");
        Check.Null(AccountsRules.Row(user with { PasswordLastSet = 0 }, Fixtures.Domain, Fixtures.Now).PasswordExpiresAt, "à changer\u00A0: aucune date");
    }

    [Test]
    public static void Counts_are_exact_and_only_count_enabled_accounts_for_states()
    {
        var users = new[]
        {
            Locked("A"),
            Fixtures.User("B") with { UserAccountControl = AdValues.NormalAccount | AdValues.AccountDisabled },
            Fixtures.User("C") with { PasswordLastSet = 0, PasswordExpiryComputed = 0 },
            Fixtures.User("D") with { AccountExpires = Fixtures.Ft(Fixtures.Now - TimeSpan.FromDays(1)) },
            Fixtures.User("E") with { LastLogonTimestamp = null, AdminCount = 1 },
        };
        var rows = users.Select(u => AccountsRules.Row(u, Fixtures.Domain, Fixtures.Now)).ToList();
        var counts = AccountsRules.Counts(rows, Fixtures.Now);
        Check.Equal(5, counts.Total, "total");
        Check.Equal(4, counts.Enabled, "activés");
        Check.Equal(1, counts.Disabled, "désactivés");
        Check.Equal(1, counts.Locked, "verrouillés");
        Check.Equal(1, counts.MustChange, "à changer");
        Check.Equal(1, counts.AccountExpired, "expirés");
        Check.Equal(1, counts.NeverLoggedOn, "jamais connectés");
        Check.Equal(1, counts.Privileged, "à privilèges");
    }

    [Test]
    public static void Support_band_says_only_what_the_controller_answered()
    {
        var band = AccountsRules.Band(Locked(), Fixtures.Domain, Controller, Fixtures.Now, TestClock.Paris);
        Check.NotNull(band, "bandeau d’un compte verrouillé");
        Check.Equal(Tone.Alert, band!.Tone, "alerte");
        Check.Contains("Compte verrouillé depuis 18:08", band.Title, "heure locale, même jour");
        Check.True(band.Actions.SequenceEqual(["unlock", "lockouts"]), "déverrouiller puis lire les verrouillages");
        Check.True(band.Facts.Any(f => f.Limit is string l && l.Contains("pas répliqué", StringComparison.Ordinal)), "limite du compteur dite");
        Check.Null(AccountsRules.Band(Fixtures.User("Tranquille"), Fixtures.Domain, Controller, Fixtures.Now, TestClock.Paris), "rien à dire\u00A0: pas de bandeau");
        var expiring = Fixtures.User("Bientôt") with { PasswordExpiryComputed = Fixtures.Ft(Fixtures.Now + TimeSpan.FromDays(5)) };
        var soon = AccountsRules.Band(expiring, Fixtures.Domain, Controller, Fixtures.Now, TestClock.Paris);
        Check.Equal(Tone.Warn, soon!.Tone, "expiration proche");
        Check.Contains("dans 5 jours", soon.Title, "délai dit");
        Check.True(soon.Actions.Contains("reset"), "réinitialisation proposée");
    }

    [Test]
    public static void Actions_say_why_they_are_unavailable()
    {
        var user = Fixtures.User("Moi");
        var actions = AccountsRules.Actions(user, user.DistinguishedName);
        Check.False(actions.Disable.Available, "jamais son propre compte");
        Check.Contains("compte de session", actions.Disable.Reason, "raison dite");
        Check.False(actions.Unlock.Available, "pas verrouillé");
        Check.True(actions.ResetPassword.Available, "réinitialisation possible");
        var krbtgt = Fixtures.User("krbtgt") with { Sid = "S-1-5-21-1-2-3-502" };
        Check.False(AccountsRules.Actions(krbtgt, null).ResetPassword.Available, "krbtgt jamais écrit");
        var never = Fixtures.User("Service") with { UserAccountControl = AdValues.NormalAccount | AdValues.DontExpirePassword };
        Check.False(AccountsRules.Actions(never, null).MustChange.Available, "changement imposé sans effet");
        Check.True(AccountsRules.IsDomainSid("S-1-5-21-1-2-3-1104"), "SID de domaine");
        Check.False(AccountsRules.IsDomainSid("S-1-5-32-544"), "SID intégré refusé");
    }

    [Test]
    public static void A_domenia_refusal_near_a_lockout_is_a_lead_never_a_proof()
    {
        var at = Fixtures.Now;
        var near = AccountsLockouts.Match(at, [new DomeniaRefusal(at - TimeSpan.FromSeconds(40), @"test\camille", "badCredentials")]);
        Check.True(near.Near, "refus 40 s avant");
        Check.Equal(40, near.Seconds, "écart");
        var skew = AccountsLockouts.Match(at, [new DomeniaRefusal(at + TimeSpan.FromSeconds(4), null, "badCredentials")]);
        Check.True(skew.Near && skew.Ambiguous, "4 s de décalage tolérés, compte non attribué dit");
        Check.Contains("compte non attribué", skew.Label, "piste signalée");
        var far = AccountsLockouts.Match(at, [new DomeniaRefusal(at - TimeSpan.FromSeconds(121), null, "badCredentials")]);
        Check.False(far.Near, "au-delà de 120 s");
        Check.Equal(168, AccountsLockouts.ClampHours(0), "fenêtre hors bornes\u00A0: 168 h");
        Check.Equal(24, AccountsLockouts.ClampHours(24), "fenêtre admise");
    }

    [Test]
    public static void Lockout_report_counts_origins_and_never_concludes_from_a_refused_read()
    {
        var user = Locked();
        var events = ImmutableArray.Create(
            new LockoutEventRead(Fixtures.Now - TimeSpan.FromMinutes(18), "PC-01", "DC1.test.local"),
            new LockoutEventRead(Fixtures.Now - TimeSpan.FromHours(30), "PC-01", "DC1.test.local"),
            new LockoutEventRead(Fixtures.Now - TimeSpan.FromHours(50), "PT-07", "DC1.test.local"));
        var read = new LockoutEventsRead(LockoutReadState.Read, "DC1.test.local", true, events, false);
        var report = AccountsLockouts.Report(user, Fixtures.Domain, read, [], [@"test\camille"], 168, Fixtures.Now, TestClock.Paris, false);
        Check.Equal(3, report.Events.Length, "trois verrouillages");
        Check.Equal("PC-01", report.Origins[0].Computer, "poste le plus fréquent d’abord");
        Check.Equal(2, report.Origins[0].Count, "deux fois");
        Check.Equal("pdc", report.ServerSource, "émulateur PDC");
        Check.True(report.Facts.Any(f => f.Label == "Postes à l’origine"), "fait des postes à l’origine");
        var refused = AccountsLockouts.Report(user, Fixtures.Domain, read with { State = LockoutReadState.Refused, Events = [] }, [], [], 168, Fixtures.Now, TestClock.Paris, false);
        Check.True(refused.Facts.Any(f => f.Value == "Lecture refusée" && f.Limit is string l && l.Contains("ne signifie pas", StringComparison.Ordinal)), "refus ≠ aucun verrouillage");
    }

    [Test]
    public static void Batch_preview_lists_exact_targets_and_motivated_exclusions()
    {
        var a = Locked("A");
        var b = Locked("B");
        var admin = Locked("Admin", adminCount: 1);
        var free = Fixtures.User("Libre");
        var candidates = new List<AccountsBatchCandidate>
        {
            new(a.DistinguishedName, a),
            new(b.DistinguishedName, b),
            new(a.DistinguishedName, a),
            new(admin.DistinguishedName, admin),
            new(free.DistinguishedName, free),
            new("CN=Absent,OU=Utilisateurs,DC=test,DC=local", null),
        };
        var preview = AccountsBatch.Preview(AccountsBatchAction.Unlock, candidates, null, null, Fixtures.Now, TestClock.Paris, false);
        Check.Equal(2, preview.Count, "deux cibles exactes");
        Check.Equal("typed", preview.Confirmation, "saisie du nombre dès 2 cibles");
        Check.Equal("2", preview.TypedCount, "nombre à saisir");
        Check.Equal(4, preview.ExcludedCount, "quatre exclusions");
        Check.True(preview.Excluded.Any(e => e.Reason.StartsWith("Doublon", StringComparison.Ordinal)), "doublon");
        Check.True(preview.Excluded.Any(e => e.Reason.StartsWith("Compte à privilèges", StringComparison.Ordinal)), "privilèges\u00A0: à traiter seul");
        Check.True(preview.Excluded.Any(e => e.Reason.StartsWith("Pas verrouillé", StringComparison.Ordinal)), "rien à faire");
        Check.True(preview.Excluded.Any(e => e.Reason.StartsWith("Compte introuvable", StringComparison.Ordinal)), "DN inconnu");
        Check.Equal("accounts.unlock.plan", preview.PlanOperation, "un plan par cible");
        Check.Equal(0, preview.Targets[0].Index, "position de la cible conservée");
        var single = AccountsBatch.Preview(AccountsBatchAction.Unlock, [new(a.DistinguishedName, a)], null, null, Fixtures.Now, TestClock.Paris, false);
        Check.Equal("simple", single.Confirmation, "une cible\u00A0: confirmation simple");
        var me = Fixtures.User("Moi");
        var disable = AccountsBatch.Preview(AccountsBatchAction.Disable, [new(me.DistinguishedName, me)], me.DistinguishedName, null, Fixtures.Now, TestClock.Paris, false);
        Check.Equal(0, disable.Count, "jamais son propre compte");
        Check.Equal("none", disable.Confirmation, "rien à confirmer");
    }

    [Test]
    public static void Password_policy_is_checked_without_ever_returning_the_password()
    {
        var user = Fixtures.User("Camille Bernard") with { SamAccountName = "c.bernard", DisplayName = "Camille Bernard" };
        var weak = AccountPasswordReset.CheckPolicy("court", user, 12);
        Check.False(weak.Single(r => r.Id == "length").Met, "trop court");
        Check.False(weak.Single(r => r.Id == "classes").Met, "une seule classe");
        var named = AccountPasswordReset.CheckPolicy("Bernard-2026!xyz", user, 12);
        Check.False(named.Single(r => r.Id == "name").Met, "partie du nom affiché refusée");
        var good = AccountPasswordReset.CheckPolicy("Vélo-Bleu-2026!", user, 12);
        Check.True(good.All(r => r.Met), "mot de passe conforme");
        using var secret = Secret("court");
        var refused = Check.Throws<DomeniaOperationException>(() => AccountPasswordReset.EnsurePolicy(secret, user, Fixtures.Domain), "refus de la stratégie");
        Check.Equal(AccountPasswordReset.PolicyRefused, refused.Code, "code");
        Check.False(refused.Message.Contains("court", StringComparison.Ordinal), "le mot de passe n’est jamais cité");
    }

    [Test]
    public static void Password_reset_plans_its_changes_without_any_secret()
    {
        var user = Locked();
        var draft = AccountPasswordReset.Draft(user, new PasswordResetOptions(true, true), Fixtures.Domain, Controller, Fixtures.Now, TestClock.Paris);
        Check.Equal(3, draft.Changes.Length, "mot de passe, changement exigé, déverrouillage");
        var password = draft.Changes[0];
        Check.Equal("unicodePwd", password.Attribute, "attribut");
        Check.Null(password.BeforeValue, "aucune valeur avant");
        Check.Null(password.AfterValue, "aucune valeur après\u00A0: jamais le secret");
        Check.False(draft.Reversibility.Reversible, "sans retour arrière");
        var plan = Seal(draft);
        Check.Equal(WritePrecheck.Stale(AccountPasswordReset.SecretGoneMessage), AccountPasswordReset.Check(plan, user, secretHeld: false), "secret disparu\u00A0: rien n’est envoyé");
        Check.True(AccountPasswordReset.Check(plan, user, secretHeld: true).Current, "préconditions valables");
        var after = AccountPasswordReset.Apply(user, plan, TimeSpan.FromDays(90), Fixtures.Now, 9);
        Check.Equal(0L, after.PasswordLastSet, "changement exigé");
        Check.Equal(0L, after.LockoutTime, "déverrouillé");
        Check.Equal(VerificationState.Verified, AccountPasswordReset.Verify(after, plan).State, "relecture conforme");
        Check.Equal(VerificationState.Mismatch, AccountPasswordReset.Verify(user, plan).State, "rien n’a changé\u00A0: écart");
    }

    [Test]
    public static void Password_secrets_are_taken_once_and_expire_with_their_plan()
    {
        var clock = TestClock.Fixed();
        using var secrets = new PasswordSecrets(clock);
        using var secret = Secret("Vélo-Bleu-2026!");
        secrets.Hold("a", clock.GetUtcNow() + TimeSpan.FromMinutes(5), secret);
        Check.True(secrets.Contains("a"), "gardé pour son plan");
        using (var taken = secrets.Take("a"))
        {
            Check.NotNull(taken, "pris une fois");
            Check.Equal(secret.Length, taken!.Length, "même longueur");
        }
        Check.Null(secrets.Take("a"), "jamais deux fois");
        secrets.Hold("b", clock.GetUtcNow() + TimeSpan.FromMinutes(5), secret);
        clock.Advance(TimeSpan.FromMinutes(6));
        Check.False(secrets.Contains("b"), "expiré avec son plan");
        Check.Equal(0, secrets.Count, "plus rien en mémoire");
    }

    [Test]
    public static void Enable_and_disable_change_one_bit_and_protect_the_session_account()
    {
        var user = Fixtures.User("Bob");
        var draft = AccountActivation.Draft(user, false, null, Fixtures.Domain, Controller, Fixtures.Now, TestClock.Paris);
        Check.Equal(AccountActivation.DisableKind, draft.Kind, "désactivation");
        var change = draft.Changes.Single();
        Check.Equal(((AdValues.NormalAccount | AdValues.AccountDisabled)).ToString(System.Globalization.CultureInfo.InvariantCulture), change.AfterValue, "seul le bit 0x2 change");
        Check.True(draft.Reversibility.Reversible, "réversible par un nouveau plan");
        var self = Check.Throws<DomeniaOperationException>(() => AccountActivation.Draft(user, false, user.DistinguishedName, Fixtures.Domain, Controller, Fixtures.Now, TestClock.Paris), "compte de session");
        Check.Equal(AccountWrites.ProtectedAccount, self.Code, "compte protégé");
        var nothing = Check.Throws<DomeniaOperationException>(() => AccountActivation.Draft(user, true, null, Fixtures.Domain, Controller, Fixtures.Now, TestClock.Paris), "déjà activé");
        Check.Equal(WriteErrors.NothingToDo, nothing.Code, "rien à faire");
        var plan = Seal(draft);
        var after = AccountActivation.Apply(user, false, Fixtures.Now, 5);
        Check.True(AccountActivation.Check(plan, after, false).Current, "déjà dans l’état demandé\u00A0: valable, rien d’écrit");
        Check.Equal(VerificationState.Verified, AccountActivation.Verify(after, false, Controller).State, "relu désactivé");
        var privileged = AccountActivation.Draft(user with { AdminCount = 1 }, false, null, Fixtures.Domain, Controller, Fixtures.Now, TestClock.Paris);
        Check.True(privileged.Confirmation.TypedNameRequired, "saisie du nom pour un compte à privilèges");
    }

    [Test]
    public static void Forced_change_and_expiration_follow_domenia_1()
    {
        var user = Fixtures.User("Chloé");
        var must = AccountMustChangePassword.Draft(user, Controller, Fixtures.Now, TestClock.Paris);
        Check.Equal("0", must.Changes.Single().AfterValue, "pwdLastSet à 0");
        Check.Equal(WriteErrors.NothingToDo, Check.Throws<DomeniaOperationException>(() => AccountMustChangePassword.Draft(user with { PasswordLastSet = 0 }, Controller, Fixtures.Now, TestClock.Paris), "déjà exigé").Code, "rien à faire");
        var day = new DateOnly(2026, 11, 15);
        var expiration = AccountExpiration.Draft(user, day, Controller, Fixtures.Now, TestClock.Paris);
        Check.Contains("dernier jour", expiration.Changes.Single().After, "dernier jour d’ouverture dit");
        Check.Equal(AdValues.ToFileTime(LocalDays.StartOf(day, TestClock.Paris)).ToString(System.Globalization.CultureInfo.InvariantCulture), expiration.Changes.Single().AfterValue, "0 h locale du jour");
        var plan = Seal(expiration);
        var after = AccountExpiration.Apply(user, plan, Fixtures.Now, 3);
        Check.Equal(day, AccountExpiration.DayOf(after.AccountExpires, TestClock.Paris), "jour relu");
        Check.Equal(VerificationState.Verified, AccountExpiration.Verify(after, plan, TestClock.Paris).State, "relecture par jour local");
        var never = AccountExpiration.Draft(after, null, Controller, Fixtures.Now, TestClock.Paris);
        Check.Equal("0", never.Changes.Single().AfterValue, "jamais\u00A0: 0 comme Domenia 1");
        var past = AccountExpiration.Draft(user, new DateOnly(2026, 10, 1), Controller, Fixtures.Now, TestClock.Paris);
        Check.True(past.Risks.Any(r => r.Tone == Tone.Alert), "date passée signalée");
    }

    [Test]
    public static void Credential_context_refuses_before_any_call()
    {
        string[] domains = ["TEST", "test.local"];
        Check.False(CredentialRules.CheckContext(CredentialRules.Laps, @".\admin", "PC-01", domains).Valid, "compte local jamais pour LAPS");
        Check.False(CredentialRules.CheckContext(CredentialRules.Remote, @".\admin", null, domains).Valid, "compte local sans poste");
        Check.True(CredentialRules.CheckContext(CredentialRules.Remote, @"PC-01\admin", "pc-01.test.local", domains).Valid, "compte local du poste");
        Check.False(CredentialRules.CheckContext(CredentialRules.Remote, @"PC-02\admin", "PC-01", domains).Valid, "compte d’un autre poste");
        Check.True(CredentialRules.CheckContext(CredentialRules.Directory, "adm@test.local", null, domains).Valid, "forme UPN");
        Check.False(CredentialRules.CheckContext(CredentialRules.Directory, "adm", null, domains).Valid, "nom sans domaine");
        Check.Equal(@"test\adm", CredentialRules.AccountKey("adm@test.local", "test.local", "TEST", null), "clé commune UPN et NetBIOS");
        Check.Equal("pc-01", CredentialRules.MachineKey("PC-01.test.local."), "clé de poste");
    }

    [Test]
    public static void Leases_expire_and_never_extend_by_themselves()
    {
        var now = Fixtures.Now;
        var lease = CredentialRules.NewLease(CredentialRules.Laps, @"TEST\adm", LeaseMode.Inactivity, 30, 1, now);
        Check.True(CredentialRules.CheckLease(lease, 1, now + TimeSpan.FromMinutes(29)).Usable, "encore utilisable");
        Check.False(CredentialRules.CheckLease(lease, 1, now + TimeSpan.FromMinutes(31)).Usable, "expiré après 30 min sans utilisation");
        Check.Equal("encore 10 min sans utilisation", CredentialRules.Remaining(lease, 1, now + TimeSpan.FromMinutes(20)).Text.Replace(' ', ' '), "minutes arrondies au-dessus");
        var once = CredentialRules.NewLease(CredentialRules.Remote, @"TEST\adm", LeaseMode.OneShot, 30, 1, now);
        Check.False(CredentialRules.CheckLease(CredentialRules.Use(once, now), 1, now).Usable, "usage unique consommé");
        Check.False(CredentialRules.CheckLease(lease, 2, now).Usable, "autre session");
        Check.Equal(480, CredentialRules.NewLease("x", "y", LeaseMode.Inactivity, 9999, 1, now).InactivityMinutes, "borné à 480 min");
    }

    [Test]
    public static void Requirements_never_guess_a_right_and_transports_stay_off_without_consent()
    {
        var unlock = OperationRequirements.For("WriteUnlock");
        Check.True(unlock.Known, "opération connue");
        Check.Contains("lockoutTime", unlock.Right, "droit dit");
        var unknown = OperationRequirements.For("Inventée");
        Check.False(unknown.Known, "opération inconnue");
        Check.Equal(OperationRequirements.UnknownText, unknown.Right, "droit non documenté");
        Check.True(OperationRequirements.All().Rows.Length > 100, "table complète de Domenia 1");
        var table = TransportPolicy.Build(TransportSettings.Defaults, false, null);
        Check.Equal(7, table.Rows.Length, "sept transports");
        Check.True(table.Rows.Where(r => r.Intrusive).All(r => r.StateTone == Tone.Off), "intrusifs inactifs sans autorisation");
        Check.False(TransportPolicy.FallbackAllowed("PsExec", true, true, true, false).Allowed, "jamais pour une lecture sans autorisation propre");
    }
}
