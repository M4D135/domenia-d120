using System.Collections.Immutable;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Store;

namespace Domenia.Tests;

internal static class PosteSecretCacheTests
{
    private static WorkstationSecretMetadata Positive(DateTimeOffset at) => new(new(at, FactState.Observed, 2, at.AddDays(-1)), null, null);
    private static FleetCachePatch Patch(Guid id, WorkstationSecretMetadata value) => FleetCachePatch.Empty with
    { WorkstationSecrets = ImmutableDictionary<Guid, WorkstationSecretMetadata>.Empty.Add(id, value) };

    [Test]
    public static void Empty_or_refused_reads_keep_the_last_positive_presence_at_its_original_date()
    {
        var at = Fixtures.Now.AddHours(-1);
        var old = PosteSecretCache.Merge(null, Positive(at));
        foreach (var reading in new[] { new SecretPresenceRead(Fixtures.Now, FactState.Observed, 0, null), new SecretPresenceRead(Fixtures.Now, FactState.Refused, null, null) })
        {
            var result = PosteSecretCache.Merge(old, new(reading, null, null));
            Check.Equal(reading, result.BitLocker, "dernière tentative conservée séparément");
            Check.Equal(at, result.LastPositive!.At, "date de présence non rajeunie"); Check.Equal(2, result.LastPositive.Keys!.Value, "ancien constat non remplacé par zéro");
            PosteSecretCache.Validate(result, Fixtures.Now);
        }
    }

    [Test]
    public static void Out_of_order_secret_metadata_keeps_each_resource_independent()
    {
        var old = PosteSecretCache.Merge(null, Positive(Fixtures.Now));
        var laps = new LapsMetadataRead(Fixtures.Now.AddMinutes(-1), LapsKind.Windows, 0, FactState.Observed);
        var result = PosteSecretCache.Merge(old, new(new(Fixtures.Now.AddHours(-1), FactState.Observed, 1, null), null, laps));
        Check.Equal(2, result.BitLocker!.Keys!.Value, "lecture BitLocker ancienne écartée");
        Check.Equal(2, result.LastPositive!.Keys!.Value, "présence plus récente intacte"); Check.Equal(laps, result.Laps, "LAPS fusionné indépendamment");
        var changed = PosteSecretCache.Merge(result, new(new(Fixtures.Now, FactState.Observed, 3, null), null, null));
        Check.Equal(3, changed.LastPositive!.Keys!.Value, "dernier relevé à même date retenu");
    }

    [Test]
    public static void Secret_metadata_does_not_apply_before_the_current_computer_creation_or_when_creation_is_unknown()
    {
        var value = PosteSecretCache.Merge(null, Positive(Fixtures.Now.AddDays(-1)));
        Check.Null(PosteSecretCache.Applicable(value, Fixtures.Now, Fixtures.Now), "relevé d’un ancien détenteur");
        Check.Null(PosteSecretCache.Applicable(value, DateTimeOffset.MinValue, Fixtures.Now), "création inconnue ne qualifie pas l’historique");
        Check.NotNull(PosteSecretCache.Applicable(value, Fixtures.Now.AddYears(-1), Fixtures.Now), "relevé postérieur à la création");
    }

    [Test]
    public static void Secret_metadata_rejects_false_zeroes_future_reads_and_malformed_LAPS_expirations()
    {
        foreach (var invalid in new WorkstationSecretMetadata[] {
            new(new(Fixtures.Now, FactState.Unknown, 0, null), null, null),
            new(new(Fixtures.Now, FactState.Refused, 3, null), null, null),
            Positive(Fixtures.Now.AddDays(1)),
            new(null, null, new(Fixtures.Now, LapsKind.Windows, long.MaxValue, FactState.Observed)),
            new(null, null, new(Fixtures.Now, LapsKind.None, 0, FactState.Observed)),
            new(null, Positive(Fixtures.Now).BitLocker, null),
        }) { Check.Throws<InvalidDataException>(() => PosteSecretCache.Validate(invalid, Fixtures.Now), "données incohérentes refusées"); }
    }

    [Test]
    public static async Task Secret_metadata_roundtrips_in_SQLite_by_GUID_without_replacing_the_last_positive_on_empty_read()
    {
        using var folder = new TemporaryFolder(); var pc = Fixtures.Computer("PC1");
        var db = new DomeniaDatabase(folder.File("secrets.db"), Fixtures.Root, TestClock.Fixed());
        await db.InitializeAsync(CancellationToken.None);
        await db.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [pc]), new(Fixtures.Postes, "Postes", true), null, CancellationToken.None);
        await db.SaveFleetAsync(Patch(pc.ObjectGuid, Positive(Fixtures.Now.AddMinutes(-5))), CancellationToken.None);
        await db.SaveFleetAsync(Patch(pc.ObjectGuid, new(new(Fixtures.Now, FactState.Observed, 0, null), null, null)), CancellationToken.None);
        var saved = (await db.ReadFleetAsync(CancellationToken.None)).WorkstationSecrets[pc.ObjectGuid];
        Check.Equal(0, saved.BitLocker!.Keys!.Value, "dernière lecture vide datée");
        Check.Equal(2, saved.LastPositive!.Keys!.Value, "constat positif conservé après relecture SQL");
        await Check.ThrowsAsync<InvalidDataException>(() => db.SaveFleetAsync(Patch(Guid.NewGuid(), Positive(Fixtures.Now)), CancellationToken.None), "GUID non connu refusé");
        Check.Equal(1, (await db.ReadFleetAsync(CancellationToken.None)).WorkstationSecrets.Count, "transaction précédente préservée");
    }

    [Test]
    public static async Task Workstation_header_uses_dated_positive_metadata_after_a_later_empty_read_without_contacting_the_directory()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc]));
        await cache.SaveFleetAsync(Patch(pc.ObjectGuid, Positive(Fixtures.Now.AddMinutes(-1))), CancellationToken.None);
        await cache.SaveFleetAsync(Patch(pc.ObjectGuid, new(new(Fixtures.Now, FactState.Observed, 0, null), null, null)), CancellationToken.None);
        var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var consent = new ConsentState(new(false, null, 0, "Non accordée", null), new(false, null, 0, "Non accordée", null));
        var value = await new AdPosteReader(source).OpenAsync(pc.DistinguishedName, PosteHealthPolicy.Default, consent, CancellationToken.None);
        Check.Equal(2, value.Secrets.BitLockerKeys!.Value, "présence ancienne conservée");
        Check.Equal(Fixtures.Now.AddMinutes(-1), value.Secrets.BitLockerReadAt!.Value, "date d’origine présentée");
        Check.True(value.Secrets.Text.Contains("pas confirmé", StringComparison.Ordinal), "incertitude actuelle visible"); Check.Equal(0, ldap.Calls, "ouverture locale seulement");
    }

    [Test]
    public static async Task A_refused_recovery_listing_records_the_attempt_only_after_confirming_the_computer_GUID()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc]));
        await cache.SaveFleetAsync(Patch(pc.ObjectGuid, Positive(Fixtures.Now.AddMinutes(-1))), CancellationToken.None);
        var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.Scope == AdSearchScope.OneLevel
            ? throw new DomeniaOperationException(AdErrors.AccessDenied, "Refus simulé") : [AdPosteNetworkTests.Entry(pc)] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var result = await new AdPosteReader(source).BitLockerListAsync(pc.DistinguishedName, CancellationToken.None);
        Check.Equal(FactState.Refused, result.ReadState, "refus présenté");
        var saved = cache.Fleet.WorkstationSecrets[pc.ObjectGuid];
        Check.Equal(FactState.Refused, saved.BitLocker!.State, "tentative actuelle enregistrée");
        Check.Equal(2, saved.LastPositive!.Keys!.Value, "ancienne présence non effacée par le refus");
    }
}
