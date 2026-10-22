using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;

namespace Domenia.Tests;

/// <summary>
/// Collective plans of the Comptes screen (TRV-229, docs/ops/comptes.md § 3.5): the engine seals the exact preview, checks the
/// typed number again and hands out the plan of each sealed target once. Written with the code, run at the very end in the VM
/// (decision of 21/10).
/// </summary>
internal static class AccountsBatchSealTests
{
    private static string Args(object value) => JsonSerializer.Serialize(value);

    private static DirectoryUser Locked(string name) => Fixtures.User(name) with
    {
        ComputedAccountControl = AdValues.LockedOut,
        LockoutTime = Fixtures.Ft(Fixtures.Now - TimeSpan.FromMinutes(12)),
    };

    private static AccountsBatchPreview Preview(params DirectoryUser[] users) =>
        AccountsBatch.Preview(AccountsBatchAction.Unlock, [.. users.Select(u => new AccountsBatchCandidate(u.DistinguishedName, u))], null, null, Fixtures.Now, TestClock.Paris, false);

    // ---------------------------------------------------------------- pure rules of the seal

    [Test]
    public static void Fingerprint_binds_the_action_the_date_and_the_exact_ordered_list()
    {
        string[] list = ["0a5e3d21-7c84-4f92-b1a6-5d3e8f20c7b4", "6f1c2b7e-9a43-4d1e-8c55-2b7d90e4a1c3"];
        var first = AccountsBatchSeals.Fingerprint(AccountsBatchAction.Unlock, null, list);
        Check.Equal(64, first.Length, "SHA-256 en hexadécimal");
        Check.Equal(first, AccountsBatchSeals.Fingerprint(AccountsBatchAction.Unlock, null, [.. list.Select(g => g.ToUpperInvariant())]), "casse des GUID sans effet");
        Check.False(first == AccountsBatchSeals.Fingerprint(AccountsBatchAction.Unlock, null, [list[1], list[0]]), "l’ordre compte");
        Check.False(first == AccountsBatchSeals.Fingerprint(AccountsBatchAction.Enable, null, list), "l’action compte");
        Check.False(AccountsBatchSeals.Fingerprint(AccountsBatchAction.Expiration, new DateOnly(2027, 1, 31), list)
            == AccountsBatchSeals.Fingerprint(AccountsBatchAction.Expiration, null, list), "la date compte");
        Check.False(first == AccountsBatchSeals.Fingerprint(AccountsBatchAction.Unlock, null, [list[0]]), "le nombre compte");
    }

    [Test]
    public static void A_sealed_batch_is_confirmed_by_the_exact_number_then_issues_each_target_once()
    {
        var clock = TestClock.Fixed();
        using var seals = new AccountsBatchSeals(clock);
        var sealedPreview = seals.Seal(Preview(Locked("Alice"), Locked("Bruno"), Locked("Chloé")), null);
        var seal = sealedPreview.Batch!;
        Check.Equal(3, seal.Count, "trois cibles scellées");
        Check.True(seal.TypedRequired, "saisie du nombre dès deux cibles");
        Check.False(seal.Confirmed, "pas encore confirmé");
        Check.Equal(32, seal.Id.Length, "identifiant de 32 hexadécimaux");
        var early = Check.Throws<DomeniaOperationException>(() => seals.Issue(seal.Id, 0), "aucun plan avant la confirmation");
        Check.Equal(AccountsBatchSeals.Unconfirmed, early.Code, "lot non confirmé");
        var wrong = Check.Throws<DomeniaOperationException>(() => seals.Confirm(seal.Id, "4"), "nombre faux");
        Check.Equal(AccountsBatchSeals.CountMismatch, wrong.Code, "nombre revérifié par le moteur");
        Check.Equal(AccountsBatchSeals.Unknown, Check.Throws<DomeniaOperationException>(() => seals.Confirm(seal.Id, "3"), "lot dépensé").Code, "un nombre faux dépense le lot");

        var again = seals.Seal(Preview(Locked("Alice"), Locked("Bruno"), Locked("Chloé")), null).Batch!;
        Check.False(again.Id == seal.Id, "nouvel identifiant");
        Check.Equal(again.Fingerprint, seal.Fingerprint, "même liste exacte, même empreinte");
        Check.True(seals.Confirm(again.Id, " 3 ").Confirmed, "nombre exact (espaces ignorés)");
        Check.True(seals.Confirm(again.Id, null).Confirmed, "une seconde confirmation ne change rien");
        var (action, date, dn, guid, _) = seals.Issue(again.Id, 1);
        Check.Equal(AccountsBatchAction.Unlock, action, "action scellée");
        Check.Null(date, "aucune date");
        Check.Equal(Locked("Bruno").DistinguishedName, dn, "cible de rang 1");
        Check.Equal(Fixtures.IdOf("Bruno").ToString("D"), guid, "GUID scellé");
        Check.Equal(AccountsBatchSeals.AlreadyIssued, Check.Throws<DomeniaOperationException>(() => seals.Issue(again.Id, 1), "deuxième plan").Code, "un plan par cible, jamais rejoué");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, Check.Throws<DomeniaOperationException>(() => seals.Issue(again.Id, 3), "hors de la liste").Code, "rang hors de l’aperçu");
    }

    [Test]
    public static void A_single_target_needs_no_typed_number_and_an_empty_preview_prepares_nothing()
    {
        var clock = TestClock.Fixed();
        using var seals = new AccountsBatchSeals(clock);
        var one = seals.Seal(Preview(Locked("Alice")), null).Batch!;
        Check.False(one.TypedRequired, "confirmation simple pour une cible");
        Check.True(seals.Confirm(one.Id, null).Confirmed, "confirmé sans nombre");
        var none = seals.Seal(Preview(Fixtures.User("Libre")), null).Batch!;
        Check.Equal(0, none.Count, "aucune cible (rien à déverrouiller)");
        Check.Equal(AccountsBatchSeals.Unknown, Check.Throws<DomeniaOperationException>(() => seals.Confirm(none.Id, null), "lot vide").Code, "rien n’est préparé");
    }

    [Test]
    public static void A_sealed_batch_expires_after_ten_minutes_without_a_gesture()
    {
        var clock = TestClock.Fixed();
        using var seals = new AccountsBatchSeals(clock);
        var seal = seals.Seal(Preview(Locked("Alice"), Locked("Bruno")), null).Batch!;
        clock.Advance(AccountsBatchSeals.Lifetime + TimeSpan.FromSeconds(1));
        Check.Equal(AccountsBatchSeals.Expired, Check.Throws<DomeniaOperationException>(() => seals.Confirm(seal.Id, "2"), "expiré").Code, "aperçu expiré");
        Check.Equal(AccountsBatchSeals.Unknown, Check.Throws<DomeniaOperationException>(() => seals.Confirm(seal.Id, "2"), "oublié").Code, "un lot expiré est oublié");
        var sliding = seals.Seal(Preview(Locked("Alice"), Locked("Bruno")), null).Batch!;
        seals.Confirm(sliding.Id, "2");
        clock.Advance(TimeSpan.FromMinutes(9));
        _ = seals.Issue(sliding.Id, 0);
        clock.Advance(TimeSpan.FromMinutes(9));
        _ = seals.Issue(sliding.Id, 1);
        Check.True(true, "chaque plan prolonge le lot (délai glissant)");
    }

    [Test]
    public static void At_most_sixteen_batches_are_kept_the_oldest_goes_first()
    {
        var clock = TestClock.Fixed();
        using var seals = new AccountsBatchSeals(clock);
        var first = seals.Seal(Preview(Locked("Alice")), null).Batch!;
        for (var i = 0; i < AccountsBatchSeals.Capacity; i++)
        {
            clock.Advance(TimeSpan.FromSeconds(1));
            _ = seals.Seal(Preview(Locked("Bruno")), null);
        }
        Check.Equal(AccountsBatchSeals.Unknown, Check.Throws<DomeniaOperationException>(() => seals.Confirm(first.Id, null), "le plus ancien").Code, "liste bornée");
    }

    [Test]
    public static void A_preview_read_is_stopped_by_its_ticket()
    {
        using var seals = new AccountsBatchSeals(TestClock.Fixed());
        Check.False(seals.Cancel("inconnu-0001"), "aucune lecture sous ce ticket");
        using var running = seals.Track("lecture-0001");
        Check.True(seals.Cancel("lecture-0001"), "lecture arrêtée");
        Check.True(running.IsCancellationRequested, "jeton annulé");
        seals.Untrack("lecture-0001", running);
        Check.False(seals.Cancel("lecture-0001"), "ticket oublié à la fin de la lecture");
        using var replaced = seals.Track("lecture-0002");
        using var newer = seals.Track("lecture-0002");
        Check.True(replaced.IsCancellationRequested, "une nouvelle lecture du même ticket arrête l’ancienne");
        Check.False(newer.IsCancellationRequested, "la nouvelle continue");
    }

    // ---------------------------------------------------------------- through the real bridge

    [Test]
    public static async Task The_page_runs_a_sealed_batch_through_the_bridge_and_the_engine_checks_everything()
    {
        var bridge = new SimulatedBridge();
        var locked = bridge.Source.CurrentDirectory.Users.Where(u => AccountsRules.LockOf(u) == AccountLock.Locked && u.AdminCount != 1).Take(3).Select(u => u.DistinguishedName).ToArray();
        Check.Equal(3, locked.Length, "trois comptes verrouillés ordinaires");
        var preview = SimulatedBridge.Json(await bridge.CallAsync("accounts.batch.preview", Args(new { action = "unlock", dns = locked, ticket = "lecture-0001" })));
        var batch = preview.GetProperty("batch");
        Check.Equal(3, batch.GetProperty("count").GetInt32(), "lot scellé de trois comptes");
        Check.True(batch.GetProperty("typedRequired").GetBoolean(), "saisie du nombre");
        var id = batch.GetProperty("id").GetString()!;
        var early = await bridge.CallAsync("accounts.batch.plan", Args(new { id, index = 0 }));
        Check.Equal(AccountsBatchSeals.Unconfirmed, early.Error?.Code, "aucun plan avant la confirmation");
        var wrong = await bridge.CallAsync("accounts.batch.confirm", Args(new { id, typedCount = "2" }));
        Check.Equal(AccountsBatchSeals.CountMismatch, wrong.Error?.Code, "nombre revérifié");

        preview = SimulatedBridge.Json(await bridge.CallAsync("accounts.batch.preview", Args(new { action = "unlock", dns = locked })));
        id = preview.GetProperty("batch").GetProperty("id").GetString()!;
        var confirmed = SimulatedBridge.Json(await bridge.CallAsync("accounts.batch.confirm", Args(new { id, typedCount = "3" })));
        Check.True(confirmed.GetProperty("confirmed").GetBoolean(), "confirmé par le moteur");
        for (var index = 0; index < 3; index++)
        {
            var planned = SimulatedBridge.Json(await bridge.CallAsync("accounts.batch.plan", Args(new { id, index })));
            Check.Equal(AccountUnlock.Kind, planned.GetProperty("plan").GetProperty("kind").GetString(), "plan de déverrouillage");
            var receipt = SimulatedBridge.Json(await bridge.CallAsync("write.execute", Args(new
            {
                planId = planned.GetProperty("plan").GetProperty("id").GetString(),
                token = planned.GetProperty("token").GetString(),
                typedName = (string?)null,
            })));
            Check.Equal("verified", receipt.GetProperty("verification").GetString(), "écriture relue " + index);
        }
        var replay = await bridge.CallAsync("accounts.batch.plan", Args(new { id, index = 0 }));
        Check.Equal(AccountsBatchSeals.AlreadyIssued, replay.Error?.Code, "jamais deux plans pour une cible");
        Check.True(locked.All(dn => AccountsRules.LockOf(bridge.Source.CurrentDirectory.Users.First(u => u.DistinguishedName == dn)) != AccountLock.Locked), "surcouche à jour");
        var badId = await bridge.CallAsync("accounts.batch.confirm", Args(new { id = "ABC", typedCount = "3" }));
        Check.Equal("arguments.invalid", badId.Error?.Code, "identifiant mal formé");
        var badTicket = await bridge.CallAsync("accounts.batch.preview", Args(new { action = "unlock", dns = locked, ticket = "x" }));
        Check.Equal("arguments.invalid", badTicket.Error?.Code, "ticket mal formé");
        var cancel = SimulatedBridge.Json(await bridge.CallAsync("accounts.batch.cancel", Args(new { ticket = "lecture-0009" })));
        Check.False(cancel.GetProperty("cancelled").GetBoolean(), "aucune lecture à arrêter");
        Check.True(bridge.Registry.TryGet("accounts.batch.confirm", out var definition) && definition.Class == OperationClass.Local, "confirmation locale, jamais une écriture");
    }

    [Test]
    public static async Task Batch_preview_bounds_duplicates_and_protected_accounts()
    {
        var bridge = new SimulatedBridge();
        var users = bridge.Source.CurrentDirectory.Users;
        var tooMany = Enumerable.Range(0, 5001).Select(i => "CN=U" + i.ToString(System.Globalization.CultureInfo.InvariantCulture) + ",OU=Utilisateurs,DC=example,DC=local").ToArray();
        var bounded = await bridge.CallAsync("accounts.batch.preview", Args(new { action = "unlock", dns = tooMany }));
        Check.Equal("arguments.invalid", bounded.Error?.Code, "5 000 DN au plus");
        var locked = users.First(u => AccountsRules.LockOf(u) == AccountLock.Locked && u.AdminCount != 1);
        var krbtgt = users.First(u => u.SamAccountName == "krbtgt");
        var privileged = users.First(u => u.AdminCount == 1 && u.SamAccountName != "krbtgt" && !AdValues.IsDisabled(u.UserAccountControl));
        var preview = SimulatedBridge.Json(await bridge.CallAsync("accounts.batch.preview", Args(new
        {
            action = "disable",
            dns = new[] { locked.DistinguishedName, locked.DistinguishedName, krbtgt.DistinguishedName, privileged.DistinguishedName, "CN=Personne,OU=Utilisateurs,DC=example,DC=local" },
        })));
        Check.Equal(1, preview.GetProperty("count").GetInt32(), "une seule cible");
        var reasons = preview.GetProperty("excluded").EnumerateArray().Select(e => e.GetProperty("reason").GetString()!).ToList();
        Check.True(reasons.Any(r => r.StartsWith("Doublon", StringComparison.Ordinal)), "doublon exclu");
        Check.True(reasons.Any(r => r.Contains("krbtgt", StringComparison.Ordinal)), "krbtgt exclu");
        Check.True(reasons.Any(r => r.StartsWith("Compte à privilèges", StringComparison.Ordinal)), "compte à privilèges à traiter seul");
        Check.True(reasons.Any(r => r.StartsWith("Compte introuvable", StringComparison.Ordinal)), "DN inconnu exclu");
        Check.Equal("simple", preview.GetProperty("confirmation").GetString(), "confirmation simple pour une cible");
    }
}
