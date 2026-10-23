using System.Text.Json;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;
using Domenia.Store;

namespace Domenia.Tests;

internal static class LegacySessionsTests
{
    private static readonly DateTimeOffset At = Fixtures.Now.AddMinutes(-2);
    private static string Payload(string? computer = null, DateTimeOffset? at = null, bool partial = false, bool empty = false) => JsonSerializer.Serialize(new
    {
        Computer = computer ?? "PC1", ObservedUtc = (at ?? At).ToString("O"), Source = "WTS, lecture a la demande", Identity = @"TEST\ancien",
        Rows = empty ? [] : new[] { new { Id = 1, Station = "Console", User = partial ? "" : "alice", Domain = "TEST", State = "Active", Protocol = "Console",
            Detail = partial ? "Information partielle, code Windows 5" : "Lecture WTS", LogonTicks = (at ?? At).AddHours(-1).ToFileTime(), IdleTicks = TimeSpan.FromMinutes(12).Ticks } },
    });
    private static async Task<DomeniaDatabase> Database(TemporaryFolder folder)
    {
        var db = new DomeniaDatabase(folder.File("sessions.db"), Fixtures.Root, TestClock.Fixed()); await db.InitializeAsync(CancellationToken.None); return db;
    }
    private static void Put(DomeniaDatabase db, string? payload = null, string status = "Success", string? guid = null, string? dn = null, string? attempted = null, string? success = null)
    {
        var pc = Fixtures.Computer("PC1"); using var sql = new SqliteDatabase(db.Path, false);
        sql.Execute("INSERT INTO domenia_details(object_guid,result_kind,request_key,dn,attempt_at,status,error,success_at,payload,attempt_payload,revision) VALUES(?1,'Sessions','WTS',?2,?3,?4,'Accès refusé',?5,?6,'{\"CollectionError\":\"Accès refusé\"}',4);",
            guid ?? pc.ObjectGuid.ToString("D"), dn ?? pc.DistinguishedName, attempted ?? At.AddSeconds(-3).ToString("O"), status, success ?? At.ToString("O"), payload ?? Payload());
    }

    [Test]
    public static async Task A_D1_WTS_read_preserves_native_dates_account_and_idle_ticks_without_touching_the_original()
    {
        using var folder = new TemporaryFolder(); var db = await Database(folder); Put(db, guid: Fixtures.Computer("PC1").ObjectGuid.ToString("D").ToUpperInvariant());
        var before = await File.ReadAllBytesAsync(db.Path);
        var read = await db.ReadLegacySessionsAsync(Fixtures.Computer("PC1"), CancellationToken.None);
        var memory = read.Memory!;
        Check.Equal(At, memory.Latest.At, "date native, pas la date d’import"); Check.Equal(SourceStatus.Ok, memory.Latest.Status, "liste complète");
        Check.Equal(At.AddHours(-1), memory.Latest.Rows.Single().LogonAt!.Value, "FILETIME WTS converti");
        Check.Equal(TimeSpan.FromMinutes(12), memory.Latest.Rows.Single().Idle!.Value, "durée distincte de FILETIME");
        Check.Equal(@"TEST\ancien", memory.Latest.Reader, "identité de lecture D1");
        var after = await File.ReadAllBytesAsync(db.Path);
        Check.True(before.SequenceEqual(after), "aucune modification de la base d’origine");
        using var sql = new SqliteDatabase(db.Path, true); Check.Equal(4L, (long)sql.Scalar("SELECT revision FROM domenia_details;")!, "révision D1 intacte");
    }

    [Test]
    public static async Task A_D1_error_keeps_the_old_success_separate_and_does_not_guess_an_authentication_failure()
    {
        using var folder = new TemporaryFolder(); var db = await Database(folder); Put(db, status: "Error", attempted: Fixtures.Now.ToString("O"));
        var memory = (await db.ReadLegacySessionsAsync(Fixtures.Computer("PC1"), CancellationToken.None)).Memory!;
        Check.Equal(SourceStatus.Error, memory.Latest.Status, "erreur historique générique"); Check.False(memory.Latest.AuthenticationRejected, "aucun rejet d’identité déduit du texte");
        Check.Equal(0, memory.Latest.Rows.Length, "échec sans lignes"); Check.Equal(1, memory.LastComplete!.Rows.Length, "dernier succès conservé");
        Check.Equal(At, memory.LastComplete.At, "date de succès conservée");
    }

    [Test]
    public static async Task Partial_D1_accounts_remain_unread_and_never_create_a_complete_history()
    {
        using var folder = new TemporaryFolder(); var db = await Database(folder); Put(db, Payload(partial: true));
        var memory = (await db.ReadLegacySessionsAsync(Fixtures.Computer("PC1"), CancellationToken.None)).Memory!;
        Check.Equal(SourceStatus.Partial, memory.Latest.Status, "information partielle D1 respectée"); Check.Null(memory.LastComplete, "aucune liste complète inventée");
        var view = PosteSessions.Stored(memory, TestClock.Paris);
        Check.Equal(1, view.UnreadSessions, "compte non lu conservé"); Check.Equal(1, view.Rows.Length, "ligne illisible visible"); Check.Equal(0, view.UserSessions, "compte inconnu");
    }

    [Test]
    public static async Task Only_an_explicit_D1_empty_array_can_prove_an_empty_historical_list()
    {
        foreach (var missing in new[] { false, true })
        {
            using var folder = new TemporaryFolder(); var db = await Database(folder);
            var json = Payload(empty: true); if (missing) { json = json.Replace("\"Rows\":[]", "\"Unrelated\":[]", StringComparison.Ordinal); }
            Put(db, json); var result = await db.ReadLegacySessionsAsync(Fixtures.Computer("PC1"), CancellationToken.None);
            if (missing) { Check.Null(result.Memory, "liste absente différente de liste vide"); Check.True(result.Notice is not null, "absence du contrat signalée"); }
            else { Check.Equal(SourceStatus.Empty, result.Memory!.Latest.Status, "liste vide native"); }
        }
    }

    [Test]
    public static async Task Foreign_parent_wrong_machine_undated_future_and_precreation_D1_reads_are_not_attributed()
    {
        foreach (var defect in new[] { "dn", "name", "offset", "future", "creation", "guid" })
        {
            using var folder = new TemporaryFolder(); var db = await Database(folder); var pc = Fixtures.Computer("PC1");
            var at = defect == "future" ? Fixtures.Now.AddHours(1) : defect == "creation" ? pc.WhenCreated.AddDays(-1) : At;
            Put(db, Payload(defect == "name" ? "PC2" : "PC1", at), dn: defect == "dn" ? "CN=PC1,DC=other,DC=local" : null,
                guid: defect == "guid" ? Guid.NewGuid().ToString("D") : null, attempted: at.AddSeconds(-1).ToString("O"),
                success: defect == "offset" ? at.ToString("yyyy-MM-ddTHH:mm:ss") : at.ToString("O"));
            Check.Null((await db.ReadLegacySessionsAsync(pc, CancellationToken.None)).Memory, "détail incompatible : " + defect);
        }
    }

    [Test]
    public static async Task Oversized_duplicate_and_case_ambiguous_D1_details_are_rejected_without_selecting_a_version()
    {
        foreach (var defect in new[] { "bytes", "json", "rows", "case" })
        {
            using var folder = new TemporaryFolder(); var db = await Database(folder); var pc = Fixtures.Computer("PC1");
            var json = defect == "bytes" ? new string('x', PosteSessionCache.MaxBytes + 1) : Payload();
            if (defect == "json") { json = json.Insert(1, "\"computer\":\"PC2\","); }
            if (defect == "rows")
            {
                using var document = JsonDocument.Parse(json);
                var row = document.RootElement.GetProperty("Rows")[0].GetRawText();
                json = json.Replace("[" + row + "]", "[" + row + "," + row + "]", StringComparison.Ordinal);
            }
            Put(db, json);
            if (defect == "case")
            {
                using var sql = new SqliteDatabase(db.Path, false);
                sql.Execute("INSERT INTO domenia_details SELECT object_guid,'sessions',request_key,dn,attempt_at,status,error,success_at,payload,attempt_payload,summary_payload,attempt_summary,revision FROM domenia_details;");
            }
            Check.Null((await db.ReadLegacySessionsAsync(pc, CancellationToken.None)).Memory, "détail ambigu : " + defect);
        }
    }

    [Test]
    public static async Task Opening_D1_sessions_is_local_and_a_new_native_failure_preserves_the_D1_complete_list()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source; Put(db);
        var reader = new AdPosteReader(source) { SessionsOverride = (_, _, _) => Task.FromResult(new WindowsSessionsRead(SourceStatus.Refused, [], 0, Fixtures.Now, "Refus WTS.")) };
        var consent = new ConsentState(new(false, null, 0, "", null), new(false, null, 0, "", null)); var pc = Fixtures.Computer("PC1");
        var calls = ldap.Calls;
        var opened = await reader.OpenAsync(pc.DistinguishedName, PosteHealthPolicy.Default, consent, CancellationToken.None);
        Check.Equal(calls, ldap.Calls, "aucun réseau à l’ouverture D1"); Check.Equal(At, opened.CachedSessions!.ReadAt!.Value, "date D1 visible");
        var failed = await reader.SessionsAsync(pc.DistinguishedName, CancellationToken.None);
        Check.Equal(FactState.Refused, failed.ReadState, "nouvelle tentative native"); Check.Equal(At, failed.LastComplete!.ReadAt!.Value, "D1 gardé en historique");
        Check.Equal(At, (await db.ReadFleetAsync(CancellationToken.None)).WorkstationSessions[pc.ObjectGuid].LastComplete!.At, "historique transmis au stockage V2");
        using var sql = new SqliteDatabase(db.Path, true); Check.Equal(Payload(), (string)sql.Scalar("SELECT payload FROM domenia_details;")!, "original D1 conservé");
    }
}
