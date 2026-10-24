using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

/// <summary>
/// Pure preview merge of the qualified local survey with the lines of the shared TSV: no disk, no network, no clock but the
/// explicit one. The merge never certifies a remote line, never mutates the snapshot, never invents a date, a counter or a
/// console, and refuses as a whole anything the bounded codec could not write back.
/// </summary>
internal static class SharedParkMergeTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static readonly DateTimeOffset Now = TestClock.Reference;
    private static readonly string Store = new('0', 64);
    private static readonly string Domain = Fixtures.Root;
    private static readonly string RowsFingerprint = new('C', 64);
    private static readonly Guid Pc1Guid = new("11111111-2222-3333-4444-555555555555");
    private const string Pc1Dn = "CN=PC1,OU=Postes,DC=test,DC=local";

    private static RelationSweepRecord Row(string key, string name, DateTimeOffset? at, string status = "SESSION", string? user = null, int attempts = 1, Guid? guid = null, string? dn = null)
        => new(key, new string('A', 64), name, guid, dn, at, status, user, attempts) { PreservedFingerprint = new string('B', 64) };

    private static RelationSweepCacheSnapshot Sweeps(ImmutableArray<RelationSweepRecord> rows, string? storeId = null, string? domainDn = null, long total = -1, int rejected = 0, int uncertain = 0, bool truncated = false, long generation = 0)
        => new(storeId ?? Store, domainDn ?? Domain, rows, total < 0 ? rows.Length : total, rejected, uncertain, truncated, RowsFingerprint, "instantané de test") { Generation = generation };

    private static DomeniaDatabase.SharedParkLocalRead Local(RelationSweepCacheSnapshot sweeps, bool exists = true, long revision = 3)
        => new(exists, false, sweeps.StoreId, sweeps.DomainDn, revision, sweeps.Generation, sweeps.Fingerprint, new string('D', 64), sweeps);

    private static DomeniaDatabase.SharedParkLocalRead LocalRows(ImmutableArray<RelationSweepRecord> rows) => Local(Sweeps(rows));

    private static DomeniaDatabase.SharedParkLocalRead Local(params RelationSweepRecord[] rows) => LocalRows([.. rows]);

    private static SharedParkLine Remote(string computer, DateTimeOffset at, string status = "CONFIRME", string? user = null, int attempts = 2, string? probedBy = null)
        => new(computer, at, status, user, attempts, probedBy);

    private static SharedParkMergePreview Merge(DomeniaDatabase.SharedParkLocalRead local, params SharedParkLine[] remote)
        => SharedParkMerge.Preview(local, [.. remote], Now, None);

    [Test]
    public static void The_local_survey_alone_is_selected_by_name_without_any_remote_line()
    {
        var local = Local(
            Row("PC1", "PC1", Now.AddHours(-1), "SESSION", "alice", 3, Pc1Guid, Pc1Dn),
            Row("shared:PC1", "PC1", Now.AddHours(-2), "PARTAGE_LU", null, 1),
            Row("PC2", "PC2", Now.AddHours(-3), "LU", null, 2));
        var preview = Merge(local);
        Check.Equal(2, preview.Lines.Length, "deux noms : les homonymes locaux ne donnent qu’un résultat d’aperçu");
        Check.Equal("PC1", preview.Lines[0].Computer, "tri OrdinalIgnoreCase");
        Check.Equal(Now.AddHours(-1), preview.Lines[0].At, "la date la plus récente gagne");
        Check.Equal("SESSION", preview.Lines[0].Status, "les champs du gagnant sont conservés");
        Check.Equal(3, preview.Lines[0].Attempts, "le compteur original du gagnant, sans addition inventée");
        Check.Equal("PC2", preview.Lines[1].Computer, "le second nom suit");
        Check.Equal(2, preview.Lines[1].Attempts, "le compteur de la ligne gagnante");
        Check.Equal(0, preview.Added, "rien d’ajouté sans ligne distante");
        Check.Equal(0, preview.Replaced, "rien de remplacé sans ligne distante");
        Check.Equal(0, preview.RemoteWinners.Length, "aucune ligne distante gagnante");
    }

    [Test]
    public static void An_absent_local_survey_merges_the_remote_lines_as_additions()
    {
        var absent = Local(Sweeps([]), exists: false, revision: 0);
        var preview = Merge(absent, Remote("PC9", Now.AddMinutes(-5)), Remote("PC8", Now.AddMinutes(-9)));
        Check.Equal(2, preview.Lines.Length, "le relevé absent n’empêche aucun ajout");
        Check.Equal("PC8", preview.Lines[0].Computer, "tri OrdinalIgnoreCase");
        Check.Equal("PC9", preview.Lines[1].Computer, "tri OrdinalIgnoreCase");
        Check.Equal(2, preview.Added, "deux ajouts");
        Check.Equal(0, preview.Replaced, "aucun remplacement sur un relevé absent");
        Check.Equal(2, preview.RemoteWinners.Length, "les deux lignes distantes gagnent l’aperçu");
        Check.Equal("PC8", preview.RemoteWinners[0].Computer, "les gagnantes sont triées comme les lignes fusionnées");
    }

    [Test]
    public static void A_strictly_newer_remote_line_replaces_and_an_unknown_name_is_added()
    {
        var local = Local(
            Row("PC1", "PC1", Now.AddHours(-2), "SESSION", "alice", 3),
            Row("PC2", "PC2", Now.AddHours(-1), "LU", null, 1));
        var preview = Merge(local,
            Remote("PC1", Now.AddHours(-1).AddSeconds(-1), "CONFIRME", "bob", 5),
            Remote("PC3", Now.AddHours(-3), "LU", null, 1));
        Check.Equal(3, preview.Lines.Length, "deux noms locaux, un ajout");
        var pc1 = preview.Lines.Single(l => l.Computer == "PC1");
        Check.Equal(Now.AddHours(-1).AddSeconds(-1), pc1.At, "la distante strictement plus récente remplace le résultat d’aperçu");
        Check.Equal("CONFIRME", pc1.Status, "le statut de la ligne gagnante, sans substitution");
        Check.Equal("bob", pc1.User ?? string.Empty, "l’utilisateur de la ligne gagnante");
        Check.Equal(5, pc1.Attempts, "le compteur de la ligne gagnante, sans addition inventée");
        Check.Equal(1, preview.Added, "un seul ajout");
        Check.Equal(1, preview.Replaced, "un seul remplacement strict");
        Check.Equal(2, preview.RemoteWinners.Length, "l’ajout et le remplacement sont tous deux des gagnantes distantes");
    }

    [Test]
    public static void An_equal_remote_date_keeps_the_local_result()
    {
        var at = Now.AddHours(-4);
        var local = Local(Row("PC1", "PC1", at, "SESSION", "alice", 7));
        var preview = Merge(local, Remote("PC1", at, "CONFIRME", "bob", 9));
        Check.Equal(1, preview.Lines.Length, "un seul poste pour la même date");
        Check.Equal("SESSION", preview.Lines[0].Status, "à date égale, le résultat local est gardé, conformément à SyncPark.Merge");
        Check.Equal("alice", preview.Lines[0].User ?? string.Empty, "l’utilisateur local est gardé");
        Check.Equal(7, preview.Lines[0].Attempts, "le compteur local n’est ni écrasé ni incrémenté");
        Check.Equal(0, preview.Added, "le nom existait déjà");
        Check.Equal(0, preview.Replaced, "la stricte antériorité est exigée pour remplacer");
        Check.Equal(0, preview.RemoteWinners.Length, "aucune distante n’a gagné");
    }

    [Test]
    public static void Names_meet_without_case_sensitivity()
    {
        var local = Local(Row("pc1", "pc1", Now.AddHours(-2), "SESSION", "alice", 1));
        var preview = Merge(local, Remote("PC1", Now.AddMinutes(-10), "LU", null, 2));
        Check.Equal(1, preview.Lines.Length, "un seul poste pour pc1 et PC1");
        Check.Equal("PC1", preview.Lines[0].Computer, "les champs de la gagnante distante sont conservés tels quels");
        Check.Equal(0, preview.Added, "pas un ajout : le nom existait sans distinction de casse");
        Check.Equal(1, preview.Replaced, "la distante plus récente remplace");
    }

    [Test]
    public static void The_most_recent_local_homonym_wins()
    {
        var local = Local(
            Row("shared:PC7", "PC7", Now.AddHours(-5), "PARTAGE_LU", null, 1),
            Row("PC7", "PC7", Now.AddHours(-1), "SESSION", "alice", 4, Pc1Guid, Pc1Dn),
            Row("autre:PC7", "PC7", Now.AddHours(-3), "PING_MUET", null, 2));
        var preview = Merge(local);
        Check.Equal(1, preview.Lines.Length, "trois lignes physiques, un seul résultat d’aperçu");
        Check.Equal(Now.AddHours(-1), preview.Lines[0].At, "la date la plus récente gagne");
        Check.Equal(4, preview.Lines[0].Attempts, "le compteur du gagnant");
        Check.Equal("SESSION", preview.Lines[0].Status, "les champs du gagnant");
    }

    [Test]
    public static void An_equal_date_prefers_the_guided_line_then_the_stable_key()
    {
        var at = Now.AddHours(-6);
        var guided = Local(
            Row("shared:PC1", "PC1", at, "PARTAGE_LU", null, 1),
            Row("zz:PC1", "PC1", at, "SESSION", "alice", 2, Pc1Guid, Pc1Dn));
        var first = Merge(guided);
        Check.Equal(1, first.Lines.Length, "deux lignes, un résultat");
        Check.Equal("SESSION", first.Lines[0].Status, "à date égale, la ligne avec GUID est choisie d’abord, même si sa clé trie après");
        Check.Equal(2, first.Lines[0].Attempts, "le compteur de la ligne à GUID");
        var twins = Local(
            Row("shared:PC1", "PC1", at, "PARTAGE_LU", null, 1),
            Row("autre:PC1", "PC1", at, "LU", null, 3));
        var twinsReversed = Local(
            Row("autre:PC1", "PC1", at, "LU", null, 3),
            Row("shared:PC1", "PC1", at, "PARTAGE_LU", null, 1));
        Check.Equal("LU", Merge(twins).Lines[0].Status, "sans GUID, le départage suit StorageKey en ordinal");
        Check.Equal("LU", Merge(twinsReversed).Lines[0].Status, "l’ordre d’entrée ne change pas le départage");
    }

    [Test]
    public static void The_reversed_entry_order_gives_the_same_bytes()
    {
        var rows = ImmutableArray.Create(
            Row("PC2", "PC2", Now.AddHours(-2), "LU", null, 1),
            Row("PC1", "PC1", Now.AddHours(-1), "SESSION", "alice", 3, Pc1Guid, Pc1Dn),
            Row("shared:PC1", "PC1", Now.AddHours(-3), "PARTAGE_LU", null, 1));
        var remote = ImmutableArray.Create(Remote("PC3", Now.AddMinutes(-5)), Remote("PC1", Now.AddMinutes(-1), "CONFIRME", "bob", 8));
        var first = SharedParkMerge.Preview(LocalRows(rows), remote, Now, None);
        var second = SharedParkMerge.Preview(LocalRows([.. rows.Reverse()]), [.. remote.Reverse()], Now, None);
        Check.True(first.Lines.SequenceEqual(second.Lines), "mêmes lignes fusionnées quel que soit l’ordre d’entrée");
        Check.True(first.RemoteWinners.SequenceEqual(second.RemoteWinners), "mêmes gagnantes distantes quel que soit l’ordre d’entrée");
        Check.True(SharedParkFile.Encode(first.Lines).SequenceEqual(SharedParkFile.Encode(second.Lines)), "mêmes octets encodés");
        Check.Equal(first.Added, second.Added, "mêmes compteurs");
        Check.Equal(first.Replaced, second.Replaced, "mêmes compteurs");
    }

    [Test]
    public static void The_merge_never_mutates_the_snapshot_nor_invents_an_identity()
    {
        var local = Local(
            Row("PC1", "PC1", Now.AddHours(-2), "SESSION", "alice", 3, Pc1Guid, Pc1Dn),
            Row("shared:PC9", "PC9", Now.AddHours(-2), "PARTAGE_LU", null, 1));
        var preview = Merge(local, Remote("PC1", Now.AddMinutes(-5), "CONFIRME", "bob", 9));
        var pc1 = preview.Lines.Single(l => l.Computer == "PC1");
        Check.Equal("CONFIRME", pc1.Status, "la distante plus récente gagne l’aperçu");
        Check.Null(pc1.ProbedBy, "aucune console inventée quand la ligne gagnante n’en porte pas");
        var pc9 = preview.Lines.Single(l => l.Computer == "PC9");
        Check.Null(pc9.ProbedBy, "le lecteur local n’expose pas de sondeur : rien n’est fabriqué");
        var original = local.Sweeps.Rows.Single(r => r.StorageKey == "PC1");
        Check.Equal(Pc1Guid, original.ComputerGuid ?? Guid.Empty, "le GUID local reste intact dans l’instantané original");
        Check.Equal(Pc1Dn, original.ComputerDn ?? string.Empty, "le DN local reste intact");
        Check.Equal(64, original.PreservedFingerprint.Length, "l’empreinte de conservation reste intacte");
        var external = local.Sweeps.Rows.Single(r => r.StorageKey == "shared:PC9");
        Check.Null(external.ComputerGuid, "aucun GUID déduit d’une observation externe, même après fusion");
        Check.Null(external.ComputerDn, "aucun DN inventé pour l’observation externe");
    }

    [Test]
    public static void The_remote_prober_is_carried_never_invented()
    {
        var local = Local(Row("PC1", "PC1", Now.AddHours(-2), "SESSION", "alice", 1));
        var won = Merge(local, Remote("PC1", Now.AddMinutes(-5), "CONFIRME", "bob", 2, "AUTRE-POSTE"));
        Check.Equal("AUTRE-POSTE", won.Lines[0].ProbedBy ?? string.Empty, "la sonde de la ligne distante gagnante est conservée telle quelle");
        var kept = Merge(local, Remote("PC1", Now.AddHours(-3), "CONFIRME", "bob", 2, "AUTRE-POSTE"));
        Check.Equal("SESSION", kept.Lines[0].Status, "le local plus récent garde le résultat");
        Check.Null(kept.Lines[0].ProbedBy, "aucune console distante n’est reportée sur la ligne locale gagnante");
    }

    [Test]
    public static void A_duplicated_remote_name_is_refused_even_when_dates_would_decide()
    {
        var local = Local(Row("PC1", "PC1", Now.AddHours(-2), "SESSION", "alice", 1));
        var ex = Check.Throws<InvalidDataException>(() => Merge(local,
            Remote("pc1", Now.AddHours(-1), "LU", null, 1),
            Remote("PC1", Now.AddHours(-2), "CONFIRME", null, 1)), "doublon distant refusé même si une date aurait départagé");
        Check.Contains("dupliqué", ex.Message, "le refus nomme la cause ; le TSV ambigu n’est pas corrigé silencieusement");
    }

    [Test]
    public static void Absent_sentinel_and_future_remote_dates_are_refused()
    {
        var local = Local(Row("PC1", "PC1", Now.AddHours(-2), "SESSION", "alice", 1));
        Check.Throws<InvalidDataException>(() => Merge(local, Remote("PC9", default)), "date absente refusée");
        Check.Throws<InvalidDataException>(() => Merge(local, Remote("PC9", DateTimeOffset.UnixEpoch)), "date sentinelle refusée");
        Check.Throws<InvalidDataException>(() => Merge(local, Remote("PC9", Now.AddMinutes(2).AddSeconds(1))), "date au-delà de deux minutes devant l’horloge refusée");
        Merge(local, Remote("PC9", Now.AddMinutes(2)));
        Check.True(true, "la borne exacte de deux minutes est admise");
    }

    [Test]
    public static void A_local_row_without_a_real_or_timely_date_is_refused()
    {
        Check.Throws<InvalidDataException>(() => Merge(Local(Row("PC1", "PC1", null))), "date locale absente refusée, jamais substituée");
        Check.Throws<InvalidDataException>(() => Merge(Local(Row("PC1", "PC1", DateTimeOffset.UnixEpoch))), "date locale sentinelle refusée");
        Check.Throws<InvalidDataException>(() => Merge(Local(Row("PC1", "PC1", Now.AddMinutes(3)))), "date locale trop future refusée");
    }

    [Test]
    public static void Control_characters_and_byte_order_marks_are_refused()
    {
        var local = Local(Row("PC1", "PC1", Now.AddHours(-2), "SESSION", "alice", 1));
        Check.Throws<InvalidDataException>(() => Merge(local, Remote("PC9", Now, "STAT\u0001UT")), "caractère de contrôle refusé dans le statut");
        Check.Throws<InvalidDataException>(() => Merge(local, Remote("PC9", Now, "STAT\uFEFFUT")), "U+FEFF refusé dans le statut");
        Check.Throws<InvalidDataException>(() => Merge(local, Remote("PC9", Now, "CONFIRME", "ali\uFEFFce")), "U+FEFF refusé dans l’utilisateur");
        Check.Throws<InvalidDataException>(() => Merge(local, Remote("PC9", Now, "CONFIRME", null, 1, "post\u0001e")), "caractère de contrôle refusé dans la sonde");
    }

    [Test]
    public static void An_incoherent_local_snapshot_or_a_missing_array_is_refused_as_a_whole()
    {
        var good = Row("PC1", "PC1", Now.AddHours(-1), "SESSION", "alice", 1);
        Check.Throws<InvalidDataException>(() => Merge(Local(Sweeps([good], total: 2))), "total incohérent refusé");
        Check.Throws<InvalidDataException>(() => Merge(Local(Sweeps([good], truncated: true))), "lecture partielle refusée");
        Check.Throws<InvalidDataException>(() => Merge(Local(Sweeps([good], rejected: 1))), "ligne rejetée refusée");
        Check.Throws<InvalidDataException>(() => Merge(Local(Sweeps([good], uncertain: 1))), "date incertaine refusée");
        Check.Throws<InvalidDataException>(() => Merge(Local(Sweeps([good], generation: -1))), "génération négative refusée");
        Check.Throws<InvalidDataException>(() => Merge(Local(Sweeps([good]), revision: -1)), "révision négative refusée");
        var sweeps = Sweeps([good]);
        Check.Throws<InvalidDataException>(() => Merge(new DomeniaDatabase.SharedParkLocalRead(true, false, new string('9', 64), Domain, 1, 0, sweeps.Fingerprint, new string('D', 64), sweeps)),
            "store annoncé différent du relevé refusé");
        Check.Throws<InvalidDataException>(() => Merge(new DomeniaDatabase.SharedParkLocalRead(true, false, Store, "DC=autre,DC=local", 1, 0, sweeps.Fingerprint, new string('D', 64), sweeps)),
            "domaine annoncé différent du relevé refusé");
        Check.Throws<InvalidDataException>(() => Merge(new DomeniaDatabase.SharedParkLocalRead(false, false, Store, Domain, 0, 0, sweeps.Fingerprint, new string('D', 64), sweeps)),
            "résultat absent portant des lignes refusé");
        Check.Throws<InvalidDataException>(() => Merge(new DomeniaDatabase.SharedParkLocalRead(true, false, Store, Domain, 1, 0, new string('E', 64), new string('D', 64), sweeps)),
            "empreinte des lignes incohérente avec le relevé porté : refusée, de toute façon la relecture physique reste à faire");
        Check.Throws<InvalidDataException>(() => SharedParkMerge.Preview(Local(good), default, Now, None), "tableau distant non fourni refusé");
    }

    [Test]
    public static void The_header_generation_must_match_the_carried_survey()
    {
        var good = Row("PC1", "PC1", Now.AddHours(-1), "SESSION", "alice", 1);
        var valid = Local(Sweeps([good], generation: 5));
        Check.Equal(1, Merge(valid).Lines.Length, "génération d’en-tête positive identique à celle du relevé : admise");
        Check.Throws<InvalidDataException>(() => Merge(valid with { Generation = -1 }), "génération d’en-tête négative refusée avec relevé valide");
        Check.Throws<InvalidDataException>(() => Merge(valid with { Generation = 4 }), "génération d’en-tête positive divergente refusée");
        Check.Throws<InvalidDataException>(() => Merge(valid with { Generation = 6 }), "génération d’en-tête positive divergente refusée, même au-dessus");
    }

    [Test]
    public static void The_union_beyond_fifty_thousand_names_is_refused_and_the_bound_itself_is_accepted()
    {
        var localRows = ImmutableArray.CreateRange(Enumerable.Range(0, 25_000)
            .Select(i => Row("P" + i.ToString("D5", CultureInfo.InvariantCulture), "P" + i.ToString("D5", CultureInfo.InvariantCulture), Now.AddHours(-1), "SESSION", null, 1)));
        var remoteLines = ImmutableArray.CreateRange(Enumerable.Range(25_000, 25_000)
            .Select(i => Remote("P" + i.ToString("D5", CultureInfo.InvariantCulture), Now.AddMinutes(-5))));
        var atBound = SharedParkMerge.Preview(LocalRows(localRows), remoteLines, Now, None);
        Check.Equal(SharedParkFile.MaxRows, atBound.Lines.Length, "la borne de 50 000 noms est réellement atteinte et acceptée");
        Check.Equal(25_000, atBound.Added, "les 25 000 noms distants inconnus sont ajoutés");
        Check.Equal(0, atBound.Replaced, "aucun remplacement : les noms sont disjoints");
        var beyond = remoteLines.Add(Remote("P50000", Now.AddMinutes(-5)));
        var ex = Check.Throws<InvalidDataException>(() => SharedParkMerge.Preview(LocalRows(localRows), beyond, Now, None), "union au-delà de 50 000 noms refusée, jamais tronquée");
        Check.Contains("50 000", ex.Message, "le refus nomme la borne du codec");
    }

    [Test]
    public static void A_pre_cancelled_merge_refuses_before_any_work()
    {
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        Check.Throws<OperationCanceledException>(() => SharedParkMerge.Preview(Local(Row("PC1", "PC1", Now.AddHours(-1))), [Remote("PC2", Now)], Now, cancelled.Token),
            "une annulation préalable n’inspecte aucune ligne");
        Check.Throws<OperationCanceledException>(() => SharedParkMerge.Preview(Local(Row("PC1", "PC1", Now.AddHours(-1))), [Remote("PC2", default)], Now, cancelled.Token),
            "l’annulation prime sur une donnée pourtant refusée");
    }
}
