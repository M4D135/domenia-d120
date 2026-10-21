using Domenia.Core;

namespace Domenia.Tests;

/// <summary>Pure rules of the unlock of an account (AccountUnlock), the same with the simulation and with Active Directory.</summary>
internal static class AccountUnlockTests
{
    private const string Controller = "DC1.test.local";

    private static DirectoryUser Locked(string name = "Camille", int? badPasswords = 5, int? adminCount = null) => Fixtures.User(name) with
    {
        ComputedAccountControl = AdValues.LockedOut,
        LockoutTime = Fixtures.Ft(Fixtures.Now - TimeSpan.FromMinutes(18)),
        BadPasswordCount = badPasswords,
        AdminCount = adminCount,
    };

    private static WritePlanDraft Draft(DirectoryUser user) => AccountUnlock.Draft(user, Fixtures.Domain, Controller, Fixtures.Now, TestClock.Paris);

    private static WritePlan Plan(DirectoryUser user) =>
        WritePlans.Seal(Draft(user), WritePlans.NewId(), @"TEST\adm", AppMode.Directory, Fixtures.Now, TestClock.Paris);

    [Test]
    public static void A_locked_standard_account_gets_a_simple_confirmation()
    {
        var user = Locked();
        var draft = Draft(user);
        Check.Equal(AccountUnlock.Kind, draft.Kind, "type");
        Check.Equal("Camille", draft.Target.Name, "nom affiché");
        Check.Equal(user.ObjectGuid.ToString("D"), draft.Target.ObjectGuid, "GUID");
        Check.Equal(Controller, draft.Controller, "contrôleur");
        var change = draft.Changes.Single();
        Check.Equal("lockoutTime", change.Attribute, "attribut");
        Check.Equal(WriteChangeKind.Clear, change.Kind, "remise à zéro");
        Check.Equal("Verrouillé depuis le 21/10/2026 à 18:08", change.Before, "heure locale de Paris");
        Check.Equal("0", change.AfterValue, "valeur après");
        Check.False(draft.Confirmation.TypedNameRequired, "confirmation simple");
        Check.False(draft.Reversibility.Reversible, "sans retour arrière");
        Check.True(draft.Risks.Any(r => r.Tone == Tone.Warn && r.Text.Contains("5 essais erronés", StringComparison.Ordinal)), "identité du demandeur, avec les essais");
        Check.Contains("pourra de nouveau ouvrir une session", draft.Summary, "résumé");
        Check.Contains("sur DC1.test.local", draft.Summary, "contrôleur dans le résumé");
    }

    [Test]
    public static void A_protected_account_asks_for_its_exact_name()
    {
        var draft = Draft(Locked("adm-camille", adminCount: 1));
        Check.True(draft.Confirmation.TypedNameRequired, "saisie exigée");
        Check.Equal("adm-camille", draft.Confirmation.TypedName, "nom à saisir : sAMAccountName");
        Check.Equal(Tone.Alert, draft.Risks[0].Tone, "risque en tête");
        Check.Contains("adminCount", draft.Risks[0].Text, "compte à privilèges");
    }

    [Test]
    public static void Expired_unconfirmed_and_disabled_lockouts_are_explained()
    {
        var expired = Locked() with { ComputedAccountControl = 0 };
        Check.True(Draft(expired).Risks.Any(r => r.Text.Contains("a déjà expiré (durée de 30", StringComparison.Ordinal)), "verrouillage expiré (Domenia 1 l’efface aussi)");
        var unconfirmed = Locked() with { ComputedAccountControl = null };
        Check.True(Draft(unconfirmed).Risks.Any(r => r.Text.Contains("n’a pas confirmé", StringComparison.Ordinal)), "calcul illisible : à vérifier");
        var disabled = Locked() with { UserAccountControl = AdValues.NormalAccount | AdValues.AccountDisabled };
        var draft = Draft(disabled);
        Check.True(draft.Risks.Any(r => r.Tone == Tone.Warn && r.Text.Contains("désactivé", StringComparison.Ordinal)), "compte désactivé");
        Check.Contains("reste désactivé", draft.Summary, "résumé honnête");
        var mustChange = Locked() with { PasswordLastSet = 0 };
        Check.True(Draft(mustChange).Risks.Any(r => r.Text.Contains("Mot de passe à changer", StringComparison.Ordinal)), "mot de passe à changer");
    }

    [Test]
    public static void An_account_that_is_not_locked_has_nothing_to_plan()
    {
        foreach (var lockout in new long?[] { null, 0 })
        {
            var refused = Check.Throws<DomeniaOperationException>(() => Draft(Fixtures.User("Libre") with { LockoutTime = lockout }), "non verrouillé");
            Check.Equal(WriteErrors.NothingToDo, refused.Code, "rien à faire");
            Check.Equal(AccountUnlock.NotLockedMessage, refused.Message, "message");
        }
    }

    [Test]
    public static void Preconditions_are_read_again_just_before_sending()
    {
        var user = Locked();
        var plan = Plan(user);
        Check.True(AccountUnlock.Check(plan, user, TestClock.Paris).Current, "inchangé : envoi possible");
        Check.True(AccountUnlock.Check(plan, user with { DistinguishedName = user.DistinguishedName.ToUpperInvariant() }, TestClock.Paris).Current, "DN sans casse");
        var unlocked = AccountUnlock.Check(plan, user with { LockoutTime = 0 }, TestClock.Paris);
        Check.True(unlocked.Current, "déjà déverrouillé : valable, rien ne sera écrit");
        Check.Contains("déjà déverrouillé", unlocked.Detail, "dit");
        var relocked = AccountUnlock.Check(plan, user with { LockoutTime = Fixtures.Ft(Fixtures.Now - TimeSpan.FromMinutes(1)) }, TestClock.Paris);
        Check.False(relocked.Current, "verrouillé de nouveau depuis le plan");
        Check.Contains("Rien n’a été envoyé", relocked.Detail, "raison");
        Check.False(AccountUnlock.Check(plan, user with { DistinguishedName = "CN=Camille,OU=Autre,DC=test,DC=local" }, TestClock.Paris).Current, "déplacé");
        Check.False(AccountUnlock.Check(plan, user with { ObjectGuid = Guid.NewGuid() }, TestClock.Paris).Current, "autre objet");
        Check.False(AccountUnlock.Check(plan, null, TestClock.Paris).Current, "supprimé");
    }

    [Test]
    public static void The_change_and_its_postcondition()
    {
        var user = Locked();
        var after = AccountUnlock.Apply(user, Fixtures.Now, 4242);
        Check.Equal(0L, after.LockoutTime, "lockoutTime à 0");
        Check.Equal(0, after.ComputedAccountControl, "bit 0x10 retiré");
        Check.Equal(0, after.BadPasswordCount, "essais remis à zéro");
        Check.Equal(4242L, after.UsnChanged, "numéro de mise à jour");
        Check.Equal(Fixtures.Now, after.WhenChanged, "date de modification");
        Check.Equal(user.ObjectGuid, after.ObjectGuid, "même objet");
        Check.Null(AccountUnlock.Apply(user with { BadPasswordCount = null }, Fixtures.Now, 1).BadPasswordCount, "compteur illisible laissé illisible");

        Check.Equal(VerificationState.Verified, AccountUnlock.Verify(after, Controller).State, "relu déverrouillé");
        Check.Contains("relu sur DC1.test.local", AccountUnlock.Verify(after, Controller).Detail, "contrôleur de la relecture");
        Check.Equal(VerificationState.Mismatch, AccountUnlock.Verify(user, Controller).State, "encore verrouillé");
        Check.Equal(VerificationState.Unknown, AccountUnlock.Verify(null, Controller).State, "introuvable : rien de prouvé");
    }
}
