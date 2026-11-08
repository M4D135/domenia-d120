using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;

namespace Domenia.Tests;

internal static class FicheVisitPolicyTests
{
    [Test]
    public static async Task A_visit_expires_without_renewing_its_observation_and_owner_changes_clear_all_ephemeral_state()
    {
        var clock = TestClock.Fixed();
        var session = new FicheSession(clock);
        var bridge = new SimulatedBridge(clock: clock);
        var owner = await bridge.Context.Directory.GetSessionAsync(CancellationToken.None);
        var ownerKey = session.BindOwner(owner);
        var entry = Entry(1);
        session.KeepRead(new(entry, clock.GetUtcNow(), "dc", 0));
        Check.NotNull(session.LastRead(entry.Dn), "lecture présente avant échéance");
        clock.Advance(TimeSpan.FromSeconds(44));
        Check.NotNull(session.LastRead(entry.Dn), "une consultation n’allonge pas le délai");
        clock.Advance(TimeSpan.FromSeconds(1));
        Check.Null(session.LastRead(entry.Dn), "45 secondes réelles écoulées");
        Check.True(session.Visits.Hits >= 2 && session.Visits.Misses >= 1 && session.Visits.Expired == 1, "succès, absence et expiration mesurés");
        session.KeepRead(new(entry, clock.GetUtcNow(), "dc", 0));
        session.KeepHistory(entry.ObjectGuid, clock.GetUtcNow());
        session.KeepAttempt(entry.Dn, "identity", clock.GetUtcNow());
        session.BindOwner(owner with { Epoch = owner.Epoch + 1 });
        Check.False(session.Publish(new(entry, clock.GetUtcNow(), "dc", 0), ownerKey), "retour tardif de l’ancien lecteur refusé atomiquement");
        Check.Null(session.LastRead(entry.Dn), "reconnexion invalide la visite");
        Check.Null(session.History(entry.ObjectGuid), "observations de visite isolées par session");
        Check.Null(session.Attempt(entry.Dn, "identity"), "tentatives isolées aussi");
        session.KeepRead(new(entry, clock.GetUtcNow(), "dc", 0));
        session.BindOwner(owner with { Account = owner.Account with { Login = "another" } });
        Check.Null(session.LastRead(entry.Dn), "changement de compte invalide même sans nouvelle génération");
    }

    [Test]
    public static void Four_hundred_GUID_visits_bound_the_actual_session_and_an_empty_GUID_is_never_cached()
    {
        var clock = TestClock.Fixed();
        var session = new FicheSession(clock);
        for (var i = 0; i < 1000; i++)
        {
            var entry = Entry(i);
            session.KeepRead(new(entry, clock.GetUtcNow(), null, 0));
            session.KeepHistory(entry.ObjectGuid, clock.GetUtcNow());
        }
        Check.Equal(400, session.Visits.Count, "visites de fiches bornées");
        Check.Equal(400, session.RetainedObjects, "autres observations de visite bornées aussi");
        Check.Null(session.LastRead(Entry(0).Dn), "plus ancienne visite évincée");
        Check.Null(session.History(Entry(0).ObjectGuid), "historique de visite évincé avec son objet");
        Check.NotNull(session.LastRead(Entry(999).Dn), "dernière visite présente");
        var unknown = Entry(1001) with { ObjectGuid = Guid.Empty };
        session.KeepRead(new(unknown, clock.GetUtcNow(), null, 0));
        session.KeepHistory(Guid.Empty, clock.GetUtcNow());
        Check.Null(session.LastRead(unknown.Dn), "pas de cache sans GUID");
        Check.Null(session.History(Guid.Empty), "pas de métadonnées sans GUID");
    }

    [Test]
    public static void The_shared_cache_bounds_and_summary_lifetime_are_real_and_an_ambiguous_DN_never_selects_the_newest_GUID()
    {
        var clock = TestClock.Fixed();
        var cache = new FicheVisitCache<FicheSummary>(clock, TimeSpan.FromSeconds(90));
        for (var i = 0; i < 401; i++) { var entry = Entry(i); cache.Put(entry.ObjectGuid, FicheSummary.From(entry, clock.GetUtcNow()), clock.GetUtcNow()); }
        Check.Equal(400, cache.Metrics.Count, "borne commune");
        Check.Equal(1L, cache.Metrics.Evictions, "éviction réellement comptée");
        var existing = Entry(400);
        var recreated = existing with { ObjectGuid = Guid.NewGuid() };
        cache.Put(recreated.ObjectGuid, FicheSummary.From(recreated, clock.GetUtcNow()), clock.GetUtcNow());
        Check.Null(cache.Find(s => FicheValues.SameDn(s.Dn, existing.Dn)), "DN ambigu");
        clock.Advance(TimeSpan.FromSeconds(89));
        Check.NotNull(cache.Find(s => s.ObjectGuid == recreated.ObjectGuid), "résumé disponible avant 90 secondes");
        clock.Advance(TimeSpan.FromSeconds(1));
        Check.Equal(0, cache.Metrics.Count, "résumés expirés à 90 secondes");
    }

    [Test]
    public static async Task The_real_bridge_and_sheet_builders_apply_the_same_historical_copy_and_edit_policy()
    {
        var bridge = new SimulatedBridge();
        var user = bridge.Source.CurrentDirectory.Users.First();
        var response = await bridge.CallAsync("fiche.preview", JsonSerializer.Serialize(new { dn = user.DistinguishedName }));
        var sheet = SimulatedBridge.Json(response);
        var policy = sheet.GetProperty("cachePolicy");
        Check.True(policy.GetProperty("consult").GetBoolean() && policy.GetProperty("copy").GetBoolean(), "lecture et copie historiques permises");
        Check.False(policy.GetProperty("modify").GetBoolean(), "aucune écriture depuis le cache");
        Check.False(sheet.GetProperty("edit").GetProperty("available").GetBoolean(), "éditeur réellement désactivé");
        Check.Contains("historique", sheet.GetProperty("origin").GetProperty("detail").GetString(), "provenance historique affichable sans promesse de réseau en cours");
        var stale = FicheCachePolicy.Decide(true, Fixtures.Now.AddMinutes(-16), Fixtures.Now);
        Check.True(stale.Consult && stale.Copy && !stale.Modify, "lecture live ancienne ne reste pas modifiable");
        Check.False(FicheCachePolicy.Decide(true, null, Fixtures.Now).Modify, "date manquante");
        Check.False(FicheCachePolicy.Decide(true, Fixtures.Now.AddMinutes(6), Fixtures.Now).Modify, "date future");
        Check.False(FicheCachePolicy.Decide(true, Fixtures.Now, Fixtures.Now, identityKnown: false).Copy, "identité inconnue");
        var call = FicheCallSheets.Origin("live", Fixtures.Now.AddMinutes(-16), "dc", Fixtures.Now, TestClock.Paris);
        Check.Equal("expired", call.State, "fiche d’appel utilise la même politique");
        Check.False(call.Live, "ancienne lecture ne certifie plus les valeurs absentes");
    }

    private static FicheEntry Entry(int index)
    {
        var id = Fixtures.IdOf("visit-" + index);
        return FicheEntry.Create(FicheKind.User, id, "CN=Visit" + index + "," + Fixtures.People, "Visit" + index,
            new Dictionary<string, IEnumerable<string?>> { ["objectGUID"] = [id.ToString("D")], ["uSNChanged"] = ["1"] });
    }
}
