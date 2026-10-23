using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class RelationJournalReadTests
{
    private static string Line(string id, string action = "Removed", string? note = null, string domain = Fixtures.Root, string details = "Origine conservée") => JsonSerializer.Serialize(new
    {
        Id = id, Action = action, WhenUtc = Fixtures.Now.ToString("o"), Declarant = @"TEST\operator", Note = note,
        Key = "ancienne-clé-D1", BaseDn = domain,
        Relation = new { UserLogin = "alice", UserGuid = Fixtures.User("alice").ObjectGuid.ToString("D"), UserDn = Fixtures.User("alice").DistinguishedName,
            Computer = "PC1", ComputerGuid = Fixtures.Computer("PC1").ObjectGuid.ToString("D"), ComputerDn = Fixtures.Computer("PC1").DistinguishedName,
            Kind = "Affectation", Source = "Saisie manuelle", When = Fixtures.Now.AddDays(-1).ToString("o"), Details = details, VerifiedInAD = "True", Declarant = @"TEST\operator" },
    });
    private static DomeniaDatabase Database(TemporaryFolder folder) => new(folder.File("history.db"), Fixtures.Root, TestClock.Fixed());

    [Test]
    public static async Task Legacy_relation_removals_and_restorations_survive_restart_with_their_original_ids_and_GUIDs()
    {
        using var folder = new TemporaryFolder(); var db = Database(folder); var removed = Guid.NewGuid().ToString("N");
        var path = db.Path + ".relations-journal.jsonl";
        await File.WriteAllTextAsync(path, Line(removed) + "\n" + Line(Guid.NewGuid().ToString("N"), "Restored", removed.ToUpperInvariant()) + "\n", new UTF8Encoding(true));
        var before = SHA256.HashData(File.ReadAllBytes(path));
        var read = await db.ReadRelationJournalAsync(CancellationToken.None);
        Check.Equal(2, read.Entries.Length, "deux entrées D1 relues"); Check.Equal(0, read.Rejected, "format ancien accepté");
        Check.Equal(0, RelationRules.Restorable(read.Entries).Length, "retrait déjà restauré non proposé à nouveau");
        Check.True(read.Entries.All(e => e.Relation.UserGuid == Fixtures.User("alice").ObjectGuid), "identité enregistrée conservée");
        Check.Equal(RelationKind.Assignment, read.Entries[0].Relation.Kind, "nature D1 reconnue");
        Check.True(before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(path))), "fichier intact"); Check.False(File.Exists(db.Path), "lecture sans création de base");
        Check.Equal(2, (await Database(folder).ReadRelationJournalAsync(CancellationToken.None)).Entries.Length, "autre instance relit les mêmes originaux");
    }

    [Test]
    public static async Task Foreign_domains_duplicate_JSON_properties_and_oversized_lines_are_excluded_with_explicit_counts()
    {
        using var folder = new TemporaryFolder(); var db = Database(folder);
        var valid = Line(Guid.NewGuid().ToString("N"));
        var ambiguous = valid.Insert(1, "\"id\":\"" + Guid.NewGuid().ToString("N") + "\",");
        await File.WriteAllTextAsync(db.Path + ".relations-journal.jsonl", string.Join('\n', valid, ambiguous,
            Line(Guid.NewGuid().ToString("N"), domain: "DC=other,DC=local"), new string('x', 65_537)) + "\n");
        var read = await db.ReadRelationJournalAsync(CancellationToken.None);
        Check.Equal(1, read.Entries.Length, "seule l’entrée valide du domaine est conservée"); Check.Equal(2, read.Rejected, "ambiguïté et limite signalées");
        Check.Equal(1, read.Foreign, "journal d’un autre domaine non mélangé");
    }

    [Test]
    public static async Task Conflicting_versions_of_one_journal_id_are_all_excluded_while_identical_repeats_are_collapsed()
    {
        using var folder = new TemporaryFolder(); var db = Database(folder); var conflict = Guid.NewGuid().ToString("N"); var same = Line(Guid.NewGuid().ToString("N"));
        await File.WriteAllTextAsync(db.Path + ".relations-journal.jsonl", string.Join('\n', Line(conflict), Line(conflict, details: "Autre contenu"), same, same) + "\n");
        var read = await db.ReadRelationJournalAsync(CancellationToken.None);
        Check.Equal(1, read.Entries.Length, "répétition exacte sans double retrait"); Check.Equal(2, read.Rejected, "deux versions contradictoires exclues");
        Check.False(read.Entries.Any(e => e.Id == conflict), "aucune version choisie arbitrairement");
    }

    [Test]
    public static async Task Journal_tail_keeps_only_the_last_400_lines_and_handles_a_cut_inside_a_large_UTF8_line()
    {
        using var folder = new TemporaryFolder(); var db = Database(folder); var path = db.Path + ".relations-journal.jsonl";
        var ids = Enumerable.Range(0, 405).Select(_ => Guid.NewGuid().ToString("N")).ToArray();
        await File.WriteAllTextAsync(path, string.Join('\n', ids.Select(id => Line(id))) + "\n");
        var capped = await db.ReadRelationJournalAsync(CancellationToken.None);
        Check.Equal(400, capped.Entries.Length, "400 dernières lignes"); Check.True(capped.Truncated, "limite visible");
        Check.False(capped.Entries.Any(e => ids.Take(5).Contains(e.Id)), "cinq premières hors fenêtre");
        await using (var file = new FileStream(path, FileMode.Create))
        {
            await file.WriteAsync(Encoding.UTF8.GetBytes(new string('é', 4_300_000) + "\n" + Line(ids[^1]) + "\n"));
        }
        var tail = await db.ReadRelationJournalAsync(CancellationToken.None);
        Check.Equal(1, tail.Entries.Length, "ligne complète après coupure UTF8 conservée"); Check.True(tail.Truncated, "préfixe non lu déclaré");
    }

    [Test]
    public static async Task Invalid_UTF8_or_incomplete_restore_records_do_not_destroy_previously_read_entries()
    {
        using var folder = new TemporaryFolder(); var db = Database(folder); var valid = Line(Guid.NewGuid().ToString("N"));
        await File.WriteAllBytesAsync(db.Path + ".relations-journal.jsonl", [.. Encoding.UTF8.GetBytes(valid + "\n"), 0xff, (byte)'\n',
            .. Encoding.UTF8.GetBytes(Line(Guid.NewGuid().ToString("N"), "Restored") + "\n")]);
        var read = await db.ReadRelationJournalAsync(CancellationToken.None);
        Check.Equal(1, read.Entries.Length, "entrée valide reçue conservée"); Check.Equal(2, read.Rejected, "UTF8 et restauration sans référence signalés");
        Check.Equal(1, RelationRules.Restorable(read.Entries).Length, "seul le retrait valide reste candidat, sans restauration automatique");
    }
}
