using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Tests;

internal static class LegacyAccountProjectionTests
{
    private static DirectoryUser Historical(string name) => Fixtures.User(name) with
    {
        LegacyIndexOnly = true, Sid = "", UserAccountControl = 0, ComputedAccountControl = null,
        LockoutTime = null, BadPasswordCount = null, PasswordLastSet = null, PasswordExpiryComputed = null,
        LastLogonTimestamp = null, AccountExpires = null, AdminCount = null, MemberOf = [], PrimaryGroupId = 0,
        WhenCreated = DateTimeOffset.MinValue, WhenChanged = DateTimeOffset.MinValue,
        ObservedAttributes = ["objectGUID", "distinguishedName", "name", "sAMAccountName"],
    };

    [Test]
    public static void Historical_enabled_accounts_never_prove_password_health_lock_or_privileges()
    {
        var user = Historical("HISTORIQUE");
        Check.Equal(PasswordClass.Unknown, AccountState.ClassifyPassword(user, TimeSpan.Zero, Fixtures.Now, TimeSpan.FromDays(7)), "pas de mot de passe valide par défaut");
        Check.Equal(AccountLock.ToCheck, AccountsRules.LockOf(user), "aucun verrouillage lu");
        var row = AccountsRules.Row(user, Fixtures.Domain, Fixtures.Now);
        Check.True(row.Enabled && row.LegacyIndexOnly, "seul le bit d’activation historique conservé");
        Check.Equal(Tone.Info, row.Tone, "aucun verdict sain vert");
        Check.Contains("D1", row.StatusLabel, "source historique visible");
        var counts = AccountsRules.Counts([row], Fixtures.Now);
        Check.Equal(1, counts.Enabled, "compte actif historique compté");
        Check.Equal(1, counts.LockToCheck, "état non confirmé");
        Check.Equal(0, counts.NeverLoggedOn, "date non conservée ne vaut pas jamais connecté");
        Check.Equal(0, counts.NeverExpires, "aucune expiration inventée");
        var measure = DomainAccountMeasure.Compute(Fixtures.Domain, [user], Fixtures.Now, true, TimeSpan.FromDays(7));
        Check.False(measure.Complete, "index D1 jamais promu en recensement complet");
        Check.Equal(1, measure.LockUnknown, "verrouillage inconnu compté");
        Check.Equal(1, measure.PasswordUnknown, "mot de passe inconnu compté");
        Check.False(AccountsRules.Actions(user, null).ResetPassword.Available, "relecture nécessaire avant action");
        Check.Throws<DomeniaOperationException>(() => AccountsRules.Detail(user, Fixtures.Snapshot(users: [user]), null, null, Fixtures.Now, TimeZoneInfo.Utc, false), "pas de détail sécurité inventé");
        Check.Equal(0, AccountsRules.Band(user, Fixtures.Domain, null, Fixtures.Now, TimeZoneInfo.Utc)!.Actions.Length, "aucune action dérivée du cache ancien");
    }

    [Test]
    public static void Search_preview_and_comparison_keep_D1_unknown_attributes_and_own_dates()
    {
        var a = Historical("D1-A"); var b = Historical("D1-B");
        var snapshot = Fixtures.Snapshot(users: [a, b]) with
        {
            ObjectReadAt = ImmutableDictionary<Guid, DateTimeOffset>.Empty.Add(a.ObjectGuid, DateTimeOffset.MinValue).Add(b.ObjectGuid, Fixtures.Now.AddDays(-30)),
        };
        var factory = new SearchRowFactory(snapshot, [], null, Fixtures.Now);
        var row = factory.User(a);
        var preview = SearchDetails.Preview(row, a, snapshot, null, TimeZoneInfo.Utc, "Base locale");
        var attrs = preview.Sections.Single(s => s.Id == "attributes").Items;
        Check.False(attrs.Any(i => i.Label.EndsWith("userAccountControl", StringComparison.Ordinal) || i.Label.EndsWith("primaryGroupID", StringComparison.Ordinal) || i.Label.EndsWith("whenCreated", StringComparison.Ordinal)), "aucun attribut synthétique publié");
        Check.True(preview.Sections[0].Items.All(i => i.Date.Contains("Date non confirmée", StringComparison.Ordinal)), "date du vrai objet inconnue, pas date globale récente");
        var comparison = SearchDetails.Compare([(row, a, null), (factory.User(b), b, null)], snapshot, TimeZoneInfo.Utc);
        foreach (var property in new[] { "Mot de passe", "Création AD", "Groupes (memberOf)", "Compte protégé (adminCount)" })
        {
            var line = comparison.Lines.Single(l => l.Property == property);
            Check.Equal("unknown", line.Difference, "deux inconnus ne sont pas identiques : " + property);
            Check.True(line.Values.All(v => !v.Known), "aucun Non, zéro ni Valide inventé : " + property);
        }
        var names = comparison.Lines.Single(l => l.Property == "Compte");
        Check.True(names.Values[0].Date != names.Values[1].Date, "chaque objet conserve sa date propre");
    }
}
