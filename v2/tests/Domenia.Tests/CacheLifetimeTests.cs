using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Core.Queries;
using ProbeReading = Domenia.Core.Accueil.ProbeReading;

namespace Domenia.Tests;

internal static class CacheLifetimeTests
{
    [Test]
    public static void Content_keys_refuse_large_or_deep_inputs_without_hashing_a_truncated_prefix()
    {
        Check.Equal(BoundedCacheKey.Create(new { value = "one" }), BoundedCacheKey.Create(new { value = "one" }), "stable");
        Check.False(BoundedCacheKey.Create(new { value = "one" }) == BoundedCacheKey.Create(new { value = "two" }), "contenu différent");
        Check.Null(BoundedCacheKey.Create(new string('x', 262145)), "octets hors borne : pas de clé partielle");
        Check.Null(BoundedCacheKey.Create(Enumerable.Range(0, 4097).ToArray()), "nœuds hors borne");
        Check.Null(BoundedCacheKey.Create(new { action = (Action)(() => { }) }), "action non mise en cache");
    }

    [Test]
    public static void Software_presentations_depend_on_content_day_identity_session_and_culture_and_are_bounded()
    {
        var cache = new SoftwareViewCache(); var guid = Guid.NewGuid(); var day = new DateOnly(2026, 11, 1); var calls = 0;
        SoftwareResult Build() { calls++; return new("PC", Fixtures.Now, "local", "daté", true, 0, [], [], "", null, PosteSoftware.Columns([]), PosteSoftware.Board([], day), []); }
        var first = cache.Resolve(guid, 1, day, new { rows = "a" }, Build);
        Check.True(ReferenceEquals(first, cache.Resolve(guid, 1, day, new { rows = "a" }, Build)), "même calcul réutilisé");
        cache.Resolve(guid, 1, day, new { rows = "b" }, Build);
        cache.Resolve(guid, 1, day.AddDays(1), new { rows = "a" }, Build);
        cache.Resolve(Guid.NewGuid(), 1, day, new { rows = "a" }, Build);
        cache.Resolve(guid, 2, day, new { rows = "a" }, Build);
        Check.Equal(5, calls, "chaque dépendance réellement invalidante");
        var culture = System.Globalization.CultureInfo.CurrentCulture;
        try { System.Globalization.CultureInfo.CurrentCulture = System.Globalization.CultureInfo.GetCultureInfo(culture.Name == "en-US" ? "fr-FR" : "en-US"); cache.Resolve(guid, 2, day, new { rows = "a" }, Build); }
        finally { System.Globalization.CultureInfo.CurrentCulture = culture; }
        Check.Equal(6, calls, "culture invalide le texte");
        for (var i = 0; i <= SoftwareViewCache.MaxEntries; i++) cache.Resolve(guid, 2, day, new { i }, Build);
        var before = calls; cache.Resolve(guid, 2, day, new { rows = "a" }, Build);
        Check.Equal(before + 1, calls, "ancienne entrée évincée, pas de rétention sans borne");
        cache.Resolve(guid, 2, day, new string('x', 300000), Build); cache.Resolve(guid, 2, day, new string('x', 300000), Build);
        Check.Equal(before + 3, calls, "grand contenu intégral calculé à chaque fois, jamais tronqué pour rentrer en cache");
    }

    [Test]
    public static void Compiled_plans_reuse_only_the_same_definition_and_release_removed_widgets()
    {
        var cache = new FleetQueryPlanCache(); var recipe = QueryRecipe.Empty(QueryTarget.Computer, "plan.one");
        var first = cache.Compile(recipe);
        Check.True(ReferenceEquals(first, cache.Compile(recipe)), "plan réutilisé");
        Check.False(ReferenceEquals(first, cache.Compile(recipe with { Clauses = [new("name", QueryOperator.Contains, QueryValue.FromText("PC"))] })), "même ID mais définition modifiée");
        for (var i = 0; i < 100; i++) cache.Compile(recipe with { Id = "plan." + i });
        Check.True(cache.Count <= FleetQueryPlanCache.Capacity, "borne de plans");
        cache.Retain([]); Check.Equal(0, cache.Count, "suppression des widgets libère les plans");
    }

    [Test]
    public static async Task Observation_age_is_configurable_without_changing_collection_reuse_or_accepting_future_clocks()
    {
        var preferences = new MemoryPreferenceStore();
        Check.Equal(30, ObservationFreshness.ReadDays(preferences), "défaut historique");
        foreach (var days in new[] { 1, 3650 })
        {
            await preferences.SetAsync(CollectionSettingsRules.PreferenceKey, JsonSerializer.SerializeToElement(new { observationMaxAgeDays = days }), default);
            Check.Equal(days, ObservationFreshness.ReadDays(preferences), "borne valide");
        }
        await preferences.SetAsync(CollectionSettingsRules.PreferenceKey, JsonSerializer.SerializeToElement(new { observationMaxAgeDays = 3651 }), default);
        Check.Equal(30, ObservationFreshness.ReadDays(preferences), "hors limites ignoré");
        Check.False(ObservationFreshness.Recent(Fixtures.Now.AddMinutes(6), Fixtures.Now, TimeSpan.FromDays(3650)), "futur exclu même si la durée est longue");
        Check.True(ObservationFreshness.Recent(Fixtures.Now.AddMinutes(5), Fixtures.Now, TimeSpan.FromDays(1)), "tolérance explicite");
        Check.False(ObservationFreshness.Recent(Fixtures.Now.AddDays(-1), Fixtures.Now, TimeSpan.FromDays(1)), "limite exacte expirée");
        var pc = Fixtures.Computer("PC1");
        var input = Fixtures.Input(Fixtures.Snapshot(computers: [pc]), [Fixtures.Observe(pc, Fixtures.Presence(true, TimeSpan.FromMinutes(-6))) ]);
        var summary = DashboardCalculator.Compute(input);
        var gauge = (GaugeData)summary.Widgets[WidgetCatalog.MeasureFreshness].Data!;
        Check.Equal(0, gauge.Fresh, "vrai calcul ne compte pas le futur comme récent");
        Check.Equal(1, gauge.Breakdown.Single(p => p.Key == "never").Value, "date future non déterminée, pas zéro silencieux");
    }

    [Test]
    public static void Failed_attempt_cache_has_bounded_delays_and_never_renews_dates_or_unlocks_accounts()
    {
        var clock = new CacheClock(); var cache = new ProbeFailureCache(clock);
        foreach (var sample in new[] { (SourceStatus.Unreachable, 120), (SourceStatus.Interrupted, 120), (SourceStatus.Refused, 600), (SourceStatus.Unavailable, 600), (SourceStatus.Error, 60) })
        {
            var reading = new ProbeReading(MeasureState.Error, Fixtures.Now, [], "Échec") { FailureStatus = sample.Item1 };
            cache.Remember("same", reading); clock.Seconds += sample.Item2 - 1;
            Check.True(ReferenceEquals(reading, cache.Read("same")), "tentative initiale, date inchangée");
            Check.Null(cache.Read("other"), "autre identité/compte/définition ne réutilise rien");
            clock.Seconds++; Check.Null(cache.Read("same"), "expiration exacte");
        }
        var refused = new ProbeReading(MeasureState.Refused, Fixtures.Now, [], "Compte") { FailureStatus = SourceStatus.Refused, AuthenticationRejected = true };
        cache.Remember("account", refused); Check.Null(cache.Read("account"), "refus d’authentification réservé au circuit du compte, sans réactivation par TTL");
        cache.Remember("success", new(MeasureState.Known, Fixtures.Now, ["ok"], null)); Check.Null(cache.Read("success"), "aucun succès dans le cache négatif");
        var failed = refused with { AuthenticationRejected = false };
        for (var i = 0; i < 100000; i++) cache.Remember(i.ToString(System.Globalization.CultureInfo.InvariantCulture), failed);
        Check.Equal(ProbeFailureCache.Capacity, cache.Count, "100 000 échecs : rétention bornée");
        Check.Null(cache.Read("0"), "ancienne entrée évincée");
        Check.NotNull(cache.Read("99999"), "dernière conservée");
        for (var i = 0; i < 100000; i++) cache.Remember("99999", failed);
        Check.Equal(ProbeFailureCache.Capacity, cache.Count, "remplacements ne gonflent pas la file d’éviction");
    }

    [Test]
    public static async Task The_existing_clear_button_releases_visits_without_removing_saved_preferences()
    {
        var bridge = new SimulatedBridge(); using var context = bridge.Context;
        var visits = FicheSession.From(context); var id = Guid.NewGuid();
        visits.KeepHistory(id, Fixtures.Now);
        await context.Preferences.SetAsync("fixture.keep", JsonSerializer.SerializeToElement("conservé"), default);
        var response = await bridge.CallAsync("accueil.cache.clear");
        Check.Equal("result", response.Kind, "geste réel du pont accepté");
        Check.Null(visits.History(id), "visite effacée par le bouton existant");
        Check.True(context.Preferences.TryGet("fixture.keep", out var kept) && kept.GetString() == "conservé", "préférence durable inchangée");
    }

    internal sealed class CacheClock : TimeProvider
    {
        public long Seconds { get; set; }
        public override long TimestampFrequency => 1;
        public override long GetTimestamp() => Seconds;
        public override DateTimeOffset GetUtcNow() => Fixtures.Now.AddSeconds(Seconds);
    }
}
