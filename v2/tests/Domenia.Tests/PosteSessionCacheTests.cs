using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Store;

namespace Domenia.Tests;

internal static class PosteSessionCacheTests
{
    private static WorkstationSessionRead Complete(DateTimeOffset at) => new(at, SourceStatus.Ok,
        [new("1", "Console", "alice", "TEST", "Active", "Console", at.AddHours(-1), TimeSpan.FromMinutes(2), null)], 0, @"TEST\operator", "Lecture WTS");
    private static FleetCachePatch Patch(Guid id, WorkstationSessionRead read) => FleetCachePatch.Empty with
    { WorkstationSessions = ImmutableDictionary<Guid, WorkstationSessionMemory>.Empty.Add(id, new("PC1", read, read.Complete ? read : null)) };

    [Test]
    public static void A_failed_session_attempt_keeps_the_dated_complete_list_without_claiming_it_is_current()
    {
        var first = Complete(Fixtures.Now.AddMinutes(-2));
        var old = new WorkstationSessionMemory("PC1", first, first);
        var refused = new WorkstationSessionRead(Fixtures.Now, SourceStatus.Refused, [], 0, @"TEST\operator", "Lecture refusée") { AuthenticationRejected = true };
        var merged = PosteSessionCache.Merge(old, new("PC1", refused, null)); PosteSessionCache.Validate(merged, Fixtures.Now);
        Check.Equal(refused, merged.Latest, "dernier refus explicite"); Check.Equal(first, merged.LastComplete!, "dernier succès daté séparément");
        Check.False(merged.Latest.Complete, "refus distinct d’une liste vide");
    }

    [Test]
    public static void Older_and_simultaneous_conflicting_reads_do_not_replace_newer_sessions()
    {
        var read = Complete(Fixtures.Now); var current = new WorkstationSessionMemory("PC1", read, read);
        var empty = read with { Status = SourceStatus.Empty, Rows = [] };
        Check.Equal(current, PosteSessionCache.Merge(current, new("PC1", empty, empty)), "même date ne permet pas de choisir le vide");
        var older = empty with { At = Fixtures.Now.AddSeconds(-1) };
        Check.Equal(current, PosteSessionCache.Merge(current, new("PC1", older, older)), "aucune régression temporelle");
        var later = empty with { At = Fixtures.Now.AddSeconds(1) }; var final = PosteSessionCache.Merge(current, new("PC1", later, later));
        Check.Equal(0, final.LastComplete!.Rows.Length, "vide réellement plus récent accepté");
    }

    [Test]
    public static void Session_memory_rejects_ambiguous_rows_invalid_dates_unbounded_fields_and_false_complete_statuses()
    {
        var read = Complete(Fixtures.Now);
        var invalid = new[]
        {
            read with { Rows = [read.Rows[0], read.Rows[0]] }, read with { Rows = [null!] }, read with { Unread = 1 }, read with { AuthenticationRejected = true },
            read with { Status = SourceStatus.Empty }, read with { At = Fixtures.Now.AddMinutes(3) },
            read with { Rows = [read.Rows[0] with { User = new string('x', 321) }] },
            read with { Rows = [read.Rows[0] with { LogonAt = Fixtures.Now.AddSeconds(1) }] },
            read with { Rows = [read.Rows[0] with { Idle = TimeSpan.FromSeconds(-1) }] },
            read with { Rows = [read.Rows[0] with { Id = "1\n" }] },
        };
        foreach (var item in invalid)
        { Check.Throws<InvalidDataException>(() => PosteSessionCache.Validate(new("PC1", item, null), Fixtures.Now), "lecture invalide refusée"); }
        Check.Throws<InvalidDataException>(() => PosteSessionCache.Validate(new("PC1", read, read with { At = Fixtures.Now.AddSeconds(1) }), Fixtures.Now), "succès postérieur à la dernière tentative refusé");
    }

    [Test]
    public static void Memory_from_before_the_computer_creation_is_not_reassigned_to_a_recreated_object()
    {
        var read = Complete(Fixtures.Now); var old = read with { At = Fixtures.Now.AddHours(-2), Rows = [] };
        Check.Null(PosteSessionCache.Applicable(new("PC1", old, old), Fixtures.Now.AddHours(-1), Fixtures.Now), "ancien relevé non réattribué");
        var recent = PosteSessionCache.Applicable(new("PC1", read, old), Fixtures.Now.AddHours(-1), Fixtures.Now)!;
        Check.Null(recent.LastComplete, "ancienne liste complète filtrée séparément"); Check.Equal(read, recent.Latest, "tentative récente conservée");
    }

    [Test]
    public static async Task Sessions_are_durable_GUID_bound_and_leave_D1_details_untouched()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed(); var db = new DomeniaDatabase(folder.File("sessions.db"), Fixtures.Root, clock);
        var cache = new SqliteDirectoryCache(db); var pc = Fixtures.Computer("PC1");
        await cache.SaveObjectsAsync(Fixtures.Snapshot(computers: [pc]), null, CancellationToken.None);
        using (var sql = new SqliteDatabase(db.Path, false))
        { sql.Execute("INSERT INTO domenia_details(object_guid,result_kind,request_key,dn,attempt_at,status,payload,revision) VALUES(?1,'Sessions','WTS',?2,'2026-10-20T10:00:00Z','Success','{\"historique\":true}',1);", pc.ObjectGuid.ToString("D"), pc.DistinguishedName); }
        await cache.SaveFleetAsync(Patch(pc.ObjectGuid, Complete(Fixtures.Now)), CancellationToken.None);
        var cold = new DomeniaDatabase(db.Path, Fixtures.Root, clock);
        var stored = (await cold.ReadFleetAsync(CancellationToken.None)).WorkstationSessions[pc.ObjectGuid];
        Check.Equal("alice", stored.Latest.Rows.Single().User!, "sessions relues après réouverture"); Check.Equal(Fixtures.Now, stored.Latest.At, "date conservée");
        using var after = new SqliteDatabase(db.Path, true);
        Check.Equal("{\"historique\":true}", (string)after.Scalar("SELECT payload FROM domenia_details WHERE result_kind='Sessions';")!, "détail D1 conservé sans réécriture");
        await Check.ThrowsAsync<InvalidDataException>(() => cache.SaveFleetAsync(Patch(Guid.NewGuid(), Complete(Fixtures.Now)), CancellationToken.None), "GUID inconnu refusé");
        Check.Equal(1, (await cold.ReadFleetAsync(CancellationToken.None)).WorkstationSessions.Count, "aucune ligne étrangère créée");
    }
}
