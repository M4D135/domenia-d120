using System.Collections.Immutable;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class CampaignPersistenceTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static readonly JsonSerializerOptions LegacyJson = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private static ImmutableArray<SurveyTarget> Targets(int count = 10) => [.. Enumerable.Range(0, count).Select(i =>
        new SurveyTarget(Fixtures.IdOf("campaign-" + i).ToString("D"), "PC" + i, "CN=PC" + i + "," + Fixtures.Postes, null))];
    private static OperationsLocalState State(int count = 10)
    {
        var targets = Targets(count);
        return new(Guid.NewGuid().ToString("D"), Fixtures.Root, 3, [], [], new(Guid.NewGuid().ToString("D"), Fixtures.Root,
            new(Fixtures.Postes, "Postes", true), SurveyMode.Ping, targets, [Guid.Parse(targets[0].Id), Guid.Parse(targets[^1].Id)],
            Fixtures.Now, Fixtures.Now, true, 0));
    }
    private static JsonObject Document(OperationsLocalState state) => JsonNode.Parse(OperationsDocumentCodec.Encode(state))!.AsObject();
    private static JsonObject Campaign(JsonObject root) => root["state"]!["survey"]!.AsObject();
    private static string Pack(byte[] bytes)
    {
        using var output = new MemoryStream();
        using (var gzip = new GZipStream(output, CompressionLevel.Fastest, true)) { gzip.Write(bytes); }
        return Convert.ToBase64String(output.ToArray());
    }

    [Test]
    public static void Versioned_campaign_roundtrip_keeps_exact_targets_and_bit_progress()
    {
        var before = State(); var text = OperationsDocumentCodec.Encode(before); var root = JsonNode.Parse(text)!.AsObject(); var campaign = Campaign(root);
        Check.Equal(OperationsDocumentCodec.Format, root["format"]!.GetValue<string>(), "version du journal");
        Check.Equal(OperationsDocumentCodec.CampaignFormat, campaign["format"]!.GetValue<string>(), "version du plan");
        Check.Equal(2, Convert.FromBase64String(campaign["done"]!.GetValue<string>()).Length, "dix cibles tiennent dans deux octets");
        Check.False(text.Contains("CN=PC", StringComparison.Ordinal), "liste effectivement compressée");
        var read = OperationsDocumentCodec.Decode(text);
        Check.True(before.Survey!.Targets.SequenceEqual(read.Survey!.Targets), "cibles exactes relues");
        Check.True(before.Survey.Completed.ToHashSet().SetEquals(read.Survey.Completed), "seuls les bits attendus");
        Check.Equal(text, OperationsDocumentCodec.Encode(read), "forme persistée stable");
    }

    [Test]
    public static void Historical_unversioned_journal_migrates_without_losing_progress()
    {
        var before = State(); var legacy = JsonSerializer.Serialize(before, LegacyJson);
        var read = OperationsDocumentCodec.Decode(legacy);
        Check.True(before.Survey!.Targets.SequenceEqual(read.Survey!.Targets), "cibles historiques conservées");
        Check.True(before.Survey.Completed.SequenceEqual(read.Survey.Completed), "progression historique conservée");
        Check.Contains(OperationsDocumentCodec.Format, OperationsDocumentCodec.Encode(read), "prochaine écriture versionnée");
    }

    [Test]
    public static void Future_journal_or_campaign_versions_are_never_guessed()
    {
        var root = Document(State()); root["format"] = "Domenia.Operations/3";
        Check.Contains("Version", Check.Throws<InvalidDataException>(() => OperationsDocumentCodec.Decode(root.ToJsonString()), "future enveloppe").Message, "refus ciblé");
        root = Document(State()); Campaign(root)["format"] = "Domenia.CampaignPlan/2";
        Check.Contains("Version", Check.Throws<InvalidDataException>(() => OperationsDocumentCodec.Decode(root.ToJsonString()), "futur plan").Message, "refus ciblé");
    }

    [Test]
    public static void Duplicate_unknown_and_missing_fields_are_refused()
    {
        var text = OperationsDocumentCodec.Encode(State());
        Check.Throws<InvalidDataException>(() => OperationsDocumentCodec.Decode(text.Insert(1, "\"format\":\"Domenia.Operations/2\",")), "doublon même valeur refusé");
        var root = Document(State()); Campaign(root)["command"] = "never execute";
        Check.Throws<InvalidDataException>(() => OperationsDocumentCodec.Decode(root.ToJsonString()), "commande étrangère refusée");
        root = Document(State()); root["state"]!.AsObject().Remove("revision");
        Check.Throws<InvalidDataException>(() => OperationsDocumentCodec.Decode(root.ToJsonString()), "révision absente refusée");
    }

    [Test]
    public static void Changed_targets_and_out_of_plan_progress_bits_are_refused()
    {
        var root = Document(State()); Campaign(root)["targetsSha256"] = new string('0', 64);
        Check.Contains("Empreinte", Check.Throws<InvalidDataException>(() => OperationsDocumentCodec.Decode(root.ToJsonString()), "SHA altéré").Message, "empreinte effectivement contrôlée");
        root = Document(State()); Campaign(root)["done"] = Convert.ToBase64String(new byte[] { 1, 128 });
        Check.Contains("Bits", Check.Throws<InvalidDataException>(() => OperationsDocumentCodec.Decode(root.ToJsonString()), "bit au-delà des dix cibles").Message, "bit hors cible refusé");
        root = Document(State()); Campaign(root)["count"] = 9;
        Check.Contains("Nombre", Check.Throws<InvalidDataException>(() => OperationsDocumentCodec.Decode(root.ToJsonString()), "compte modifié").Message, "compte comparé au contenu");
    }

    [Test]
    public static void Compression_bomb_is_stopped_at_the_unpacked_bound()
    {
        var bytes = new byte[OperationsDocumentCodec.MaxTargetsBytes + 1]; var root = Document(State());
        Campaign(root)["targets"] = Pack(bytes); Campaign(root)["targetsSha256"] = Convert.ToHexStringLower(SHA256.HashData(bytes));
        Check.Contains("16 Mio", Check.Throws<InvalidDataException>(() => OperationsDocumentCodec.Decode(root.ToJsonString()), "borne décompressée").Message, "borne atteinte avant le parsing JSON des cibles");
    }

    [Test]
    public static void Oversized_compressed_plan_is_explicitly_refused_without_truncation()
    {
        var before = State(); var targets = Targets(1000).Select(t => t with
        { Dn = "CN=" + Convert.ToHexString(RandomNumberGenerator.GetBytes(1024)) + "," + Fixtures.Postes }).ToImmutableArray();
        var oversized = before with { Survey = before.Survey! with { Targets = targets, Completed = [] } };
        Check.Contains("900 Kio", Check.Throws<InvalidDataException>(() => OperationsDocumentCodec.Encode(oversized), "plan trop grand").Message, "borne de plan exacte");
        Check.Equal(1000, oversized.Survey!.Targets.Length, "aucune troncature du plan soumis");
    }

    [Test]
    public static async Task SQLite_reads_back_versioned_plan_after_restart_and_retains_it_on_conflict()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed(); var db = new DomeniaDatabase(folder.File("campaign.db"), Fixtures.Root, clock);
        var cache = new SqliteDirectoryCache(db); var before = await cache.ReadOperationsAsync(None);
        var next = State() with { StoreId = before.StoreId, Revision = before.Revision + 1 };
        await cache.UpdateOperationsAsync(before.Revision, next, None);
        string payload;
        using (var sql = new SqliteDatabase(db.Path, readOnly: true)) { payload = (string)sql.Scalar("SELECT payload FROM domenia_v2_operations WHERE id=1;")!; }
        Check.Contains(OperationsDocumentCodec.PagedCampaignFormat, payload, "format local paginé réellement écrit en SQLite");
        var reopened = new DomeniaDatabase(db.Path, Fixtures.Root, clock); var read = await reopened.ReadOperationsAsync(None);
        Check.True(read.Survey!.Completed.ToHashSet().SetEquals(next.Survey!.Completed), "bits relus après réouverture");
        await Check.ThrowsAsync<InvalidDataException>(() => cache.UpdateOperationsAsync(before.Revision, next with { Survey = null }, None), "CAS périmé");
        using var verified = new SqliteDatabase(db.Path, readOnly: true);
        Check.Equal(payload, (string)verified.Scalar("SELECT payload FROM domenia_v2_operations WHERE id=1;")!, "octets et référence du plan intacts après conflit");
    }

    [Test]
    public static async Task Future_SQLite_document_with_a_matching_raw_hash_is_refused_and_preserved()
    {
        using var folder = new TemporaryFolder(); var db = new DomeniaDatabase(folder.File("campaign.db"), Fixtures.Root, TestClock.Fixed());
        var cache = new SqliteDirectoryCache(db); var before = await cache.ReadOperationsAsync(None);
        var next = State() with { StoreId = before.StoreId, Revision = 1 };
        await cache.UpdateOperationsAsync(0, next, None);
        var future = Document(next); future["format"] = "Domenia.Operations/3"; var payload = future.ToJsonString();
        var hash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(payload)));
        using (var sql = new SqliteDatabase(db.Path, readOnly: false))
        { sql.Execute("UPDATE domenia_v2_operations SET payload=?1,sha256=?2 WHERE id=1;", payload, hash); }
        var error = await Check.ThrowsAsync<InvalidDataException>(() => db.ReadOperationsAsync(None), "future version malgré SHA correct");
        Check.Contains("Version", error.Message, "refus sémantique après vérification brute");
        using var reread = new SqliteDatabase(db.Path, readOnly: true);
        Check.Equal(payload, (string)reread.Scalar("SELECT payload FROM domenia_v2_operations WHERE id=1;")!, "octets du futur document conservés");
    }

    [Test]
    public static async Task Session_change_after_durable_start_refuses_work_and_preserves_the_committed_plan()
    {
        using var x = new NativeFixture(); x.Cache.AfterSave = x.Source.Reset;
        var id = Guid.NewGuid().ToString("D");
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => x.Reader.BeginCollectionAsync(id, new(Fixtures.Postes, "Postes", true), SurveyMode.Ping, Targets(), None), "session changée après stockage");
        Check.Equal(AccountAccess.EpochChanged, error.Code, "refus de la génération initiale");
        Check.Equal(1, x.Cache.Hooks, "frontière après commit atteinte");
        Check.Equal(id, (await x.Database.ReadOperationsAsync(None)).Survey!.Id, "plan déjà durable conservé");
        Check.Equal(0, x.Connection.Calls, "aucun LDAP/sonde déclenché par le refus");
        using var lease = await x.Cache.AcquireOperationsLeaseAsync(None);
    }

    [Test]
    public static async Task Session_change_after_resume_claim_never_starts_a_second_background_read()
    {
        using var x = new NativeFixture(); var id = Guid.NewGuid().ToString("D");
        await x.Reader.BeginCollectionAsync(id, new(Fixtures.Postes, "Postes", true), SurveyMode.Ping, Targets(), None);
        await x.Reader.FinishCollectionAsync(id, true, None);
        var offer = (await x.Reader.RunsAsync(None)).Offer!; x.Cache.AfterSave = x.Source.Reset;
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => x.Reader.ResumeSurveyAsync(offer.Remaining, offer.ResumeToken!, None), "session changée après réservation");
        Check.Equal(AccountAccess.EpochChanged, error.Code, "réservation devenue périmée");
        Check.Equal(1, x.Cache.Hooks, "commit de réservation atteint");
        Check.Equal(0, x.Connection.Calls, "aucune qualification LDAP ou sonde lancée");
        Check.Equal(id, (await x.Database.ReadOperationsAsync(None)).Survey!.Id, "preuve de réservation préservée");
        using var lease = await x.Cache.AcquireOperationsLeaseAsync(None);
    }

    [Test]
    public static async Task Late_cancellation_after_start_keeps_the_plan_and_releases_admission()
    {
        using var x = new NativeFixture(); using var stop = new CancellationTokenSource(); x.Cache.AfterSave = stop.Cancel;
        var id = Guid.NewGuid().ToString("D");
        await Check.ThrowsAsync<OperationCanceledException>(() => x.Reader.BeginCollectionAsync(id, new(Fixtures.Postes, "Postes", true), SurveyMode.Ping, Targets(), stop.Token), "annulation après commit");
        Check.Equal(1, x.Cache.Hooks, "annulation tardive effectivement atteinte");
        Check.Equal(id, (await x.Database.ReadOperationsAsync(None)).Survey!.Id, "aucune compensation du commit");
        Check.Equal(0, x.Connection.Calls, "aucune collecte lancée");
        using var lease = await x.Cache.AcquireOperationsLeaseAsync(None);
    }

    [Test]
    public static async Task Survey_each_acknowledged_target_is_durable_and_a_lost_reply_does_not_erase_the_checkpoint()
    {
        using var x = new NativeFixture(); var targets = Targets(); var id = Guid.NewGuid().ToString("D");
        await x.Reader.BeginCollectionAsync(id, new(Fixtures.Postes, "Postes", true), SurveyMode.Ping, targets, None);
        var first = Guid.Parse(targets[0].Id); var second = Guid.Parse(targets[1].Id);
        await x.Reader.ProgressCollectionAsync(id, [first], 0, None);
        var visible = await new DomeniaDatabase(x.Database.Path, Fixtures.Root, TestClock.Fixed()).ReadOperationsAsync(None);
        Check.True(visible.Survey!.Completed.SequenceEqual([first]), "la première cible est durable avant le retour, sans attendre dix secondes");
        x.Cache.AfterSave = () => throw new IOException("Réponse locale interrompue après commit");
        await Check.ThrowsAsync<IOException>(() => x.Reader.ProgressCollectionAsync(id, [first, second], 1, None), "réponse perdue après commit");
        x.Cache.AfterSave = null;
        await x.Reader.FinishCollectionAsync(id, true, None);
        var cold = await new DomeniaDatabase(x.Database.Path, Fixtures.Root, TestClock.Fixed()).ReadOperationsAsync(None);
        Check.True(cold.Survey!.Completed.ToHashSet().SetEquals([first, second]), "les deux commits restent présents après arrêt et réouverture");
        Check.Equal(1, cold.Survey.Failed, "échec traité distinct du nombre de cibles achevées");
        Check.True(cold.Survey.Interrupted, "reprise explicite proposée, aucune relance automatique");
        Check.Equal(0, x.Connection.Calls, "persistance purement locale");
    }

    private sealed class NativeFixture : IDisposable
    {
        private readonly TemporaryFolder folder = new();
        public DomeniaDatabase Database { get; }
        public HookCache Cache { get; }
        public AdBoundaryTests.RecordingAdConnection Connection { get; } = new();
        public AdDirectorySource Source { get; }
        public AdOperationsReader Reader { get; }
        public NativeFixture()
        {
            Database = new(folder.File("campaign.db"), Fixtures.Root, TestClock.Fixed()); Cache = new(new(Database));
            Source = new("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: Connection, localStore: Cache); Reader = new(Source);
        }
        public void Dispose() { Reader.Dispose(); Source.Dispose(); Connection.Dispose(); folder.Dispose(); }
    }
    private sealed class HookCache(SqliteDirectoryCache inner) : IDirectoryCache, IOperationsLocalStore
    {
        public Action? AfterSave { get; set; }
        public int Hooks { get; private set; }
        public Task<DirectorySnapshot?> ReadAsync(CancellationToken token) => inner.ReadAsync(token);
        public Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken token) => inner.SaveAsync(snapshot, scope, controller, token);
        public Task<OperationsLocalState> ReadOperationsAsync(CancellationToken token) => inner.ReadOperationsAsync(token);
        public Task<IDisposable> AcquireOperationsLeaseAsync(CancellationToken token) => inner.AcquireOperationsLeaseAsync(token);
        public async Task<OperationsLocalState> UpdateOperationsAsync(long expectedRevision, OperationsLocalState next, CancellationToken token)
        {
            var saved = await inner.UpdateOperationsAsync(expectedRevision, next, token);
            if (AfterSave is { } action) { Hooks++; action(); }
            return saved;
        }
    }
}
