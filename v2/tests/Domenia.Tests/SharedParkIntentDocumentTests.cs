using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

/// <summary>
/// Pure coverage of the shared-park intention metadata codec: round-trip of scalars and references (including the real SHA-256 an
/// absent survey carries), the compact size that carries no line, the expired-batch asymmetry between creation and re-read, identity
/// and fingerprint binding, backup-reference presence and absence (key required, null only when the flag is false), path canonicality
/// and collision, DOS reserved exponents versus subscripts, strict UTC timestamps, scalar and post-escaping size bounds, cancellation,
/// and the corruption/structure guards. No file, no SQLite, no share, no reflection: only in-memory bytes and fixed UTC fixtures.
/// </summary>
internal static class SharedParkIntentDocumentTests
{
    private static readonly DateTimeOffset T0 = new(2026, 10, 24, 11, 0, 0, TimeSpan.Zero);
    private static readonly DateTimeOffset Now = T0.AddMinutes(2);
    private const string StoreId = "store-01";
    private const string DomainDn = "DC=contoso,DC=local";
    private const string BatchPath = @"\\srv01\partage\park.tsv";
    private const string BatchId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string SessionId = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    private const string PlanId = "0123456789abcdef0123456789abcdef";
    private static readonly string PlanFp = Sha("plan");
    private const string SqlitePath = @"C:\ProgramData\Domenia\backups\park.sqlite";
    private const string TsvPath = @"C:\ProgramData\Domenia\backups\park.tsv";
    private const long SqliteLen = 4096;
    private const long TsvLen = 2048;

    // ---- fixtures -------------------------------------------------------------

    private static string Sha(string value) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    private static string Iso(DateTimeOffset value) => value.UtcDateTime.ToString("o", CultureInfo.InvariantCulture);

    // The readers always carry a real SHA-256 for the rows/local/remote fields, even when a survey is absent (SHA of empty bytes,
    // fingerprint of an empty sweep). Absence is expressed by the Exists flags and the null references, never by empty fingerprints.
    private static SharedParkBatch MakeBatch(bool localExists = true, bool remoteExists = true,
        DateTimeOffset? created = null, DateTimeOffset? expires = null, string? path = null,
        long epoch = 7, long revision = 3, long generation = 2,
        int mergedRows = 10, long payloadBytes = 1234, int added = 4, int replaced = 6)
    {
        var c = created ?? T0;
        var e = expires ?? T0.AddMinutes(10);
        return new SharedParkBatch(BatchId, SessionId, epoch, path ?? BatchPath, StoreId, DomainDn, revision, generation,
            localExists, false, Sha("rows"), Sha("local"), remoteExists, Sha("remote"), c, e,
            mergedRows, payloadBytes, Sha("proposed"), added, replaced);
    }

    private static SharedParkBackupReference Sqlite(string path = SqlitePath, long length = SqliteLen, string? sha = null)
        => new(path, length, sha ?? Sha("sqlite-copy"));

    private static SharedParkBackupReference Tsv(string path = TsvPath, long length = TsvLen, string? sha = null)
        => new(path, length, sha ?? Sha("tsv-copy"));

    private static SharedParkIntent MakeIntent(SharedParkBatch batch, SharedParkBackupReference? sqlite, SharedParkBackupReference? tsv,
        DateTimeOffset? recorded = null, string? planFp = null, string? batchFp = null)
        => new(1, PlanId, planFp ?? PlanFp, batch, batchFp ?? SharedParkIdentity.Fingerprint(batch), recorded ?? T0.AddMinutes(1), sqlite, tsv);

    private static SharedParkIntent ValidIntent() => MakeIntent(MakeBatch(), Sqlite(), Tsv());

    private static byte[] Enc(SharedParkIntent intent, DateTimeOffset? now = null)
        => SharedParkIntentDocument.Encode(intent, StoreId, DomainDn, PlanId, PlanFp, now ?? Now);

    private static SharedParkIntent Dec(byte[] document)
        => SharedParkIntentDocument.Decode(document, StoreId, DomainDn, PlanId, PlanFp, Now);

    // ---- crafted JSON helpers (digest recomputed so only the tested defect fires) ----

    private static JsonObject BatchNode(SharedParkBatch b) => new()
    {
        ["id"] = b.Id, ["sessionId"] = b.SessionId, ["epoch"] = b.Epoch, ["path"] = b.Path, ["storeId"] = b.StoreId,
        ["domainDn"] = b.DomainDn, ["revision"] = b.Revision, ["generation"] = b.Generation, ["localExists"] = b.LocalExists,
        ["legacy"] = b.Legacy, ["rowsFingerprint"] = b.RowsFingerprint, ["localFingerprint"] = b.LocalFingerprint,
        ["remoteExists"] = b.RemoteExists, ["remoteSha256"] = b.RemoteSha256, ["createdAt"] = Iso(b.CreatedAt),
        ["expiresAt"] = Iso(b.ExpiresAt), ["mergedRows"] = b.MergedRows, ["payloadBytes"] = b.PayloadBytes,
        ["proposedSha256"] = b.ProposedSha256, ["added"] = b.Added, ["replaced"] = b.Replaced,
    };

    private static JsonObject BackupNode(SharedParkBackupReference r) => new() { ["path"] = r.Path, ["length"] = r.Length, ["sha256"] = r.Sha256 };

    private static JsonObject ValidIntentNode()
    {
        var b = MakeBatch();
        return new JsonObject
        {
            ["version"] = 1, ["planId"] = PlanId, ["planFingerprint"] = PlanFp,
            ["batchFingerprint"] = SharedParkIdentity.Fingerprint(b), ["recordedAt"] = Iso(T0.AddMinutes(1)),
            ["batch"] = BatchNode(b), ["sqliteBackup"] = BackupNode(Sqlite()), ["tsvBackup"] = BackupNode(Tsv()),
        };
    }

    // Builds a coherent intent node: the batchFingerprint is recomputed from the exact batch, so flipping the Exists flags never leaves
    // a stale fingerprint behind (SharedParkIdentity.Fingerprint folds both flags in).
    private static JsonObject IntentNode(SharedParkBatch batch, JsonNode? sqlite, JsonNode? tsv) => new()
    {
        ["version"] = 1, ["planId"] = PlanId, ["planFingerprint"] = PlanFp,
        ["batchFingerprint"] = SharedParkIdentity.Fingerprint(batch), ["recordedAt"] = Iso(T0.AddMinutes(1)),
        ["batch"] = BatchNode(batch), ["sqliteBackup"] = sqlite, ["tsvBackup"] = tsv,
    };

    private static byte[] Wrap(JsonNode intent) => WrapRaw(intent.ToJsonString());

    private static byte[] WrapRaw(string intentJson) => Envelope(intentJson, Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(intentJson))));

    private static byte[] Envelope(string intentJson, string sha, string extraProps = "")
        => Encoding.UTF8.GetBytes("{\"format\":\"domenia.sharedParkIntent\",\"version\":1,\"intent\":" + intentJson + ",\"intentSha256\":\"" + sha + "\"" + extraProps + "}");

    // ---- round-trip -----------------------------------------------------------

    [Test]
    public static void Roundtrip_preserves_scalars_and_references()
    {
        var original = ValidIntent();
        var decoded = Dec(Enc(original));
        Check.Equal(original, decoded, "aller-retour fidèle de l’intention");
        Check.Equal(PlanId, decoded.PlanId, "identifiant du plan conservé");
        Check.Equal(BatchPath, decoded.Batch.Path, "chemin du TSV conservé");
        Check.Equal(SqlitePath, decoded.SqliteBackup!.Path, "référence SQLite conservée");
        Check.Equal(TsvPath, decoded.TsvBackup!.Path, "référence TSV conservée");
        Check.Equal(T0.AddMinutes(1), decoded.RecordedAt, "instant d’enregistrement conservé");
    }

    [Test]
    public static void Document_is_compact_and_carries_no_lines()
    {
        var document = Enc(ValidIntent());
        Check.True(document.Length < 8192, "le document de métadonnées reste court");
        Check.True(document.Length <= SharedParkIntentDocument.MaxDocumentBytes, "le document respecte le plafond de 64 Kio");
        var text = Encoding.UTF8.GetString(document);
        Check.False(text.Contains("SharedParkLine", StringComparison.Ordinal), "aucune ligne TSV n’est embarquée");
        Check.False(text.Contains('\n'), "aucune ligne de données n’est embarquée");
        Check.Equal(ValidIntent(), Dec(document), "le document court se relit à l’identique");
    }

    [Test]
    public static void Crafted_valid_document_decodes()
    {
        Check.Equal(ValidIntent(), Dec(Wrap(ValidIntentNode())), "un document construit à la main et bien digesté se relit");
    }

    [Test]
    public static void Roundtrip_when_no_survey_exists()
    {
        var intent = MakeIntent(MakeBatch(localExists: false, remoteExists: false), null, null);
        Check.Equal(intent, Dec(Enc(intent)), "aucune enquête : les deux références sont absentes");
    }

    [Test]
    public static void Roundtrip_with_only_local_survey()
    {
        var intent = MakeIntent(MakeBatch(remoteExists: false), Sqlite(), null);
        Check.Equal(intent, Dec(Enc(intent)), "enquête locale seule : référence SQLite présente, TSV absent");
    }

    [Test]
    public static void Roundtrip_with_real_absence_fingerprints()
    {
        // A cold preview, built purely in memory from the real computation sources (no SQLite, no file): RowsFingerprint is the
        // empty-sweep fingerprint (SHA-256 of empty bytes, as EmptySweeps computes), LocalFingerprint comes from
        // DomeniaDatabase.SharedParkLocalFingerprint at revision/generation 0, RemoteSha256 is SharedParkFile.Hash([]). The Exists flags
        // are false and the counters coherent. The codec must accept and round-trip these real absence values, never fold them to empty.
        var emptySweepFingerprint = Convert.ToHexStringLower(SHA256.HashData([]));
        var localFingerprint = DomeniaDatabase.SharedParkLocalFingerprint(StoreId, DomainDn, 0, 0, false, emptySweepFingerprint);
        var remoteSha = SharedParkFile.Hash([]);
        var batch = new SharedParkBatch(BatchId, SessionId, 0, BatchPath, StoreId, DomainDn, 0, 0,
            false, false, emptySweepFingerprint, localFingerprint, false, remoteSha,
            T0, T0.AddMinutes(10), 0, 0, Sha("proposed"), 0, 0);
        Check.True(IsHex(batch.RowsFingerprint) && IsHex(batch.LocalFingerprint) && IsHex(batch.RemoteSha256), "empreintes d’absence réelles (64 hex)");
        Check.Equal(Sha(""), batch.RemoteSha256, "RemoteSha256 = SHA-256 des octets vides");
        var intent = MakeIntent(batch, null, null);
        var decoded = Dec(Enc(intent));
        Check.Equal(intent, decoded, "aller-retour pur d’une intention d’absence cohérente");
        Check.Equal(emptySweepFingerprint, decoded.Batch.RowsFingerprint, "empreinte de balayure vide conservée");
        Check.Equal(localFingerprint, decoded.Batch.LocalFingerprint, "empreinte logique locale d’absence conservée");
        Check.Equal(remoteSha, decoded.Batch.RemoteSha256, "SHA distant d’absence conservé");
    }

    // ---- expiration asymmetry -------------------------------------------------

    [Test]
    public static void Encode_refuses_an_already_expired_batch()
    {
        Check.Throws<ArgumentException>(() => Enc(ValidIntent(), T0.AddMinutes(20)), "un lot expiré n’est pas scellé");
    }

    [Test]
    public static void Decode_accepts_a_valid_intention_after_expiry()
    {
        var document = Enc(ValidIntent());
        var decoded = SharedParkIntentDocument.Decode(document, StoreId, DomainDn, PlanId, PlanFp, T0.AddMinutes(20));
        Check.Equal(ValidIntent(), decoded, "preuve après redémarrage : une intention valide reste relisible après expiration");
    }

    [Test]
    public static void Encode_refuses_a_future_recorded_instant()
    {
        var intent = MakeIntent(MakeBatch(expires: T0.AddMinutes(15)), Sqlite(), Tsv(), recorded: T0.AddMinutes(10));
        Check.Throws<ArgumentException>(() => Enc(intent, T0.AddMinutes(2)), "un enregistrement futur par rapport à « now » est refusé");
    }

    // ---- identity and fingerprints -------------------------------------------

    [Test]
    public static void Wrong_plan_identity_is_refused()
    {
        var document = Enc(ValidIntent());
        Check.Throws<InvalidDataException>(() => SharedParkIntentDocument.Decode(document, StoreId, DomainDn, "00000000000000000000000000000000", PlanFp, Now), "identifiant de plan inattendu");
        Check.Throws<InvalidDataException>(() => SharedParkIntentDocument.Decode(document, StoreId, DomainDn, PlanId, Sha("autre-plan"), Now), "empreinte de plan inattendue");
    }

    [Test]
    public static void Wrong_store_or_domain_is_refused()
    {
        var document = Enc(ValidIntent());
        Check.Throws<InvalidDataException>(() => SharedParkIntentDocument.Decode(document, "autre-magasin", DomainDn, PlanId, PlanFp, Now), "magasin inattendu");
        Check.Throws<InvalidDataException>(() => SharedParkIntentDocument.Decode(document, StoreId, "DC=autre", PlanId, PlanFp, Now), "domaine inattendu");
    }

    [Test]
    public static void Wrong_batch_fingerprint_is_refused()
    {
        var intent = MakeIntent(MakeBatch(), Sqlite(), Tsv(), batchFp: Sha("fausse-empreinte"));
        Check.Throws<ArgumentException>(() => Enc(intent), "l’empreinte du lot recalculée doit correspondre");
    }

    // ---- backup references ----------------------------------------------------

    [Test]
    public static void References_required_when_survey_exists()
    {
        var noSqlite = MakeIntent(MakeBatch(), null, Tsv());
        Check.Throws<ArgumentException>(() => Enc(noSqlite), "enquête locale existante exige la référence SQLite");
        var noTsv = MakeIntent(MakeBatch(), Sqlite(), null);
        Check.Throws<ArgumentException>(() => Enc(noTsv), "TSV distant existant exige la référence TSV");
    }

    [Test]
    public static void References_forbidden_when_survey_absent()
    {
        var extraSqlite = MakeIntent(MakeBatch(localExists: false, remoteExists: true), Sqlite(), Tsv());
        Check.Throws<ArgumentException>(() => Enc(extraSqlite), "sans enquête locale, aucune référence SQLite");
        var extraTsv = MakeIntent(MakeBatch(localExists: true, remoteExists: false), Sqlite(), Tsv());
        Check.Throws<ArgumentException>(() => Enc(extraTsv), "sans TSV distant, aucune référence TSV");
    }

    [Test]
    public static void Invalid_backup_paths_are_refused()
    {
        string[] bad =
        [
            @"\\srv\share\park.sqlite", @"relative\park.sqlite", @"C:\a\..\b\park.sqlite", @"C:\a:b",
            @"C:\a<b", @"C:\CON\park.sqlite", @"C:\dir\", @"C:\dir\file.", "C:\\dir\\file\u0001x", @"C:/dir/file",
        ];
        foreach (var path in bad)
        {
            var intent = MakeIntent(MakeBatch(), new SharedParkBackupReference(path, 10, Sha("copie")), Tsv());
            Check.Throws<ArgumentException>(() => Enc(intent), $"chemin de sauvegarde invalide refusé : {path}");
        }
    }

    [Test]
    public static void Colliding_copy_paths_are_refused()
    {
        var sameCopies = MakeIntent(MakeBatch(),
            new SharedParkBackupReference(@"C:\Backup\Park.sqlite", 10, Sha("a")),
            new SharedParkBackupReference(@"c:\backup\PARK.SQLITE", 10, Sha("b")));
        Check.Throws<ArgumentException>(() => Enc(sameCopies), "les deux copies ne peuvent porter le même chemin (insensible à la casse)");

        var sharedLocal = @"C:\partage\park.tsv";
        var copyEqualsTsv = MakeIntent(MakeBatch(path: sharedLocal), new SharedParkBackupReference(sharedLocal, 10, Sha("a")), Tsv());
        Check.Throws<ArgumentException>(() => Enc(copyEqualsTsv), "une copie ne peut égaler le chemin du TSV");
    }

    [Test]
    public static void Batch_path_alias_or_root_is_refused()
    {
        // Batch.Path must be canonical before the collision comparison, so an alias that designates the same file is refused outright.
        Check.Throws<ArgumentException>(() => Enc(MakeIntent(MakeBatch(path: @"C:\backups\x\..\park.tsv"), Sqlite(), Tsv())), "dotdot refusé dans le chemin du TSV");
        Check.Throws<ArgumentException>(() => Enc(MakeIntent(MakeBatch(path: @"C:\"), Sqlite(), Tsv())), "racine seule refusée");
        Check.Throws<ArgumentException>(() => Enc(MakeIntent(MakeBatch(path: @"\\srv01\share"), Sqlite(), Tsv())), "partage seul sans fichier refusé");
    }

    [Test]
    public static void Reserved_exponents_and_subscripts_are_handled()
    {
        // DOS reserved COM/LPT with superscripts (U+00B9/²/³) are refused; the subscripts (U+2081/²/³) stay ordinary characters.
        var subscript = MakeIntent(MakeBatch(), new SharedParkBackupReference("C:\\logs\\COM\u2081.log", 10, Sha("sub")), Tsv());
        Check.Equal(subscript, Dec(Enc(subscript)), "les indices U+2081 restent des caractères ordinaires");
        var superscript = MakeIntent(MakeBatch(), new SharedParkBackupReference("C:\\logs\\COM\u00B9.log", 10, Sha("sup")), Tsv());
        Check.Throws<ArgumentException>(() => Enc(superscript), "les exposants DOS réservés U+00B9 sont refusés");
    }

    // ---- dates and bounds -----------------------------------------------------

    [Test]
    public static void Invalid_dates_and_bounds_are_refused()
    {
        Check.Throws<ArgumentException>(() => Enc(MakeIntent(MakeBatch(created: new DateTimeOffset(1960, 1, 1, 0, 0, 0, TimeSpan.Zero)), Sqlite(), Tsv())), "création antérieure à l’époque Unix");
        Check.Throws<ArgumentException>(() => Enc(MakeIntent(MakeBatch(expires: T0), Sqlite(), Tsv())), "expiration qui ne suit pas la création");
        Check.Throws<ArgumentException>(() => Enc(MakeIntent(MakeBatch(expires: T0.AddMinutes(16)), Sqlite(), Tsv())), "durée de vie au-delà de quinze minutes");
        Check.Throws<ArgumentException>(() => Enc(MakeIntent(MakeBatch(), Sqlite(), Tsv(), recorded: T0.AddMinutes(-1))), "enregistrement avant la création du lot");
        Check.Throws<ArgumentException>(() => Enc(MakeIntent(MakeBatch(), Sqlite(), Tsv(), recorded: T0.AddMinutes(10))), "enregistrement à l’expiration exclue");
        Check.Throws<ArgumentException>(() => Enc(MakeIntent(MakeBatch(epoch: -1), Sqlite(), Tsv())), "époque négative");
        Check.Throws<ArgumentException>(() => Enc(MakeIntent(MakeBatch(revision: -1), Sqlite(), Tsv())), "révision négative");
        Check.Throws<ArgumentException>(() => Enc(MakeIntent(MakeBatch(mergedRows: 50001), Sqlite(), Tsv())), "lignes fusionnées hors borne");
        Check.Throws<ArgumentException>(() => Enc(MakeIntent(MakeBatch(payloadBytes: 16_777_217), Sqlite(), Tsv())), "volume proposé hors borne");
        Check.Throws<ArgumentException>(() => Enc(MakeIntent(MakeBatch(mergedRows: 5, added: 4, replaced: 3), Sqlite(), Tsv())), "somme des compteurs au-delà des lignes fusionnées");
    }

    // ---- size bounds ----------------------------------------------------------

    [Test]
    public static void Oversized_identity_is_refused_before_fingerprint()
    {
        // Expected identity is made coherent with the batch so the size bound — not the identity check — is what refuses, isolated by
        // the precise "caractères" message. The bound fires before SharedParkIdentity.Fingerprint is ever recomputed.
        var huge = new string('s', 100_000);
        var baseBatch = MakeBatch();
        var b = baseBatch with { StoreId = huge };
        var intent = new SharedParkIntent(1, PlanId, PlanFp, b, SharedParkIdentity.Fingerprint(b), T0.AddMinutes(1), Sqlite(), Tsv());
        var ex = Check.Throws<ArgumentException>(() => SharedParkIntentDocument.Encode(intent, huge, DomainDn, PlanId, PlanFp, Now), "identité nettement au-delà de 64 Kio refusée avant calcul d’empreinte");
        Check.Contains("caractères", ex.Message, "refus de taille précis");
    }

    [Test]
    public static void Metadata_that_grows_after_escaping_is_refused()
    {
        // Raw scalars pass the length bound and the expected identity is coherent, so the identity check passes and it is the
        // post-serialization 64 KiB check (after JSON escaping) that refuses — not an identity mismatch.
        var bloat = new string('\u0001', 8192);
        var baseBatch = MakeBatch();
        var b = baseBatch with { StoreId = bloat, DomainDn = bloat };
        var intent = new SharedParkIntent(1, PlanId, PlanFp, b, SharedParkIdentity.Fingerprint(b), T0.AddMinutes(1), Sqlite(), Tsv());
        Check.Throws<ArgumentException>(() => SharedParkIntentDocument.Encode(intent, bloat, bloat, PlanId, PlanFp, Now), "métadonnées qui grossissent après échappement JSON refusées");
    }

    // ---- cancellation ---------------------------------------------------------

    [Test]
    public static void Pre_cancelled_token_is_honoured()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        Check.Throws<OperationCanceledException>(() => SharedParkIntentDocument.Encode(ValidIntent(), StoreId, DomainDn, PlanId, PlanFp, Now, cts.Token), "encodage annulé avant tout travail");
        var document = Enc(ValidIntent());
        Check.Throws<OperationCanceledException>(() => SharedParkIntentDocument.Decode(document, StoreId, DomainDn, PlanId, PlanFp, Now, cts.Token), "relecture annulée avant tout travail");
    }

    // ---- corruption and structure guards -------------------------------------

    [Test]
    public static void Truncated_bytes_are_refused()
    {
        var document = Enc(ValidIntent());
        Check.Throws<InvalidDataException>(() => Dec(document[..(document.Length / 2)]), "octets tronqués refusés");
    }

    [Test]
    public static void Invalid_utf8_is_refused()
    {
        var document = Enc(ValidIntent());
        document[5] = 0xFF;
        Check.Throws<InvalidDataException>(() => Dec(document), "UTF-8 invalide refusé");
    }

    [Test]
    public static void Inconsistent_hash_is_refused()
    {
        var intentJson = ValidIntentNode().ToJsonString();
        Check.Throws<InvalidDataException>(() => Dec(Envelope(intentJson, Sha("digest-incoherent"))), "SHA-256 incohérent refusé avant acceptation du contenu");
    }

    [Test]
    public static void Oversized_document_is_refused()
    {
        Check.Throws<InvalidDataException>(() => Dec(new byte[SharedParkIntentDocument.MaxDocumentBytes + 1]), "document au-delà de 64 Kio refusé avant lecture");
    }

    [Test]
    public static void Unknown_key_is_refused()
    {
        var node = ValidIntentNode();
        node["inconnu"] = 1;
        Check.Throws<InvalidDataException>(() => Dec(Wrap(node)), "propriété inconnue refusée");
    }

    [Test]
    public static void Duplicate_key_is_refused()
    {
        var json = ValidIntentNode().ToJsonString();
        var duplicated = json[..^1] + ",\"planId\":\"" + PlanId + "\"}";
        Check.Throws<InvalidDataException>(() => Dec(WrapRaw(duplicated)), "propriété dupliquée refusée");
    }

    [Test]
    public static void Missing_required_field_is_refused()
    {
        var node = ValidIntentNode();
        node.Remove("planId");
        Check.Throws<InvalidDataException>(() => Dec(Wrap(node)), "champ requis manquant refusé, jamais remplacé par un défaut");
    }

    [Test]
    public static void Null_required_field_is_refused()
    {
        var node = ValidIntentNode();
        node["planId"] = null;
        Check.Throws<InvalidDataException>(() => Dec(Wrap(node)), "champ requis null refusé, jamais remplacé par un défaut");
    }

    [Test]
    public static void Missing_sqlite_backup_key_is_refused()
    {
        // Coherent absent batch (both flags false, both references explicitly null, batchFingerprint recomputed from that batch). The
        // full document is read positively first, so the ONLY difference in the refused variant is the removed sqliteBackup key: the
        // refusal can no longer be a false positive from a flag/reference mismatch if the key-presence guard regresses.
        var batch = MakeBatch(localExists: false, remoteExists: false);
        var node = IntentNode(batch, sqlite: null, tsv: null);
        var decoded = Dec(Wrap(node));
        Check.False(decoded.SqliteBackup is not null, "document complet aux deux nulls relu avant retrait");
        node.Remove("sqliteBackup");
        Check.Throws<InvalidDataException>(() => Dec(Wrap(node)), "la clé sqliteBackup est requise, même quand le drapeau est faux");
    }

    [Test]
    public static void Missing_tsv_backup_key_is_refused()
    {
        // Same isolation for the TSV key: the accepted and refused documents differ only by the presence of tsvBackup.
        var batch = MakeBatch(localExists: false, remoteExists: false);
        var node = IntentNode(batch, sqlite: null, tsv: null);
        var decoded = Dec(Wrap(node));
        Check.False(decoded.TsvBackup is not null, "document complet aux deux nulls relu avant retrait");
        node.Remove("tsvBackup");
        Check.Throws<InvalidDataException>(() => Dec(Wrap(node)), "la clé tsvBackup est requise, même quand le drapeau est faux");
    }

    [Test]
    public static void Explicit_null_backup_accepted_when_absent()
    {
        // Coherent absent batch: both flags false and the batchFingerprint recomputed from that batch, so Validate reaches the
        // reference check and the explicit nulls are accepted.
        var batch = MakeBatch(localExists: false, remoteExists: false);
        var node = IntentNode(batch, sqlite: null, tsv: null);
        var decoded = Dec(Wrap(node));
        Check.False(decoded.SqliteBackup is not null, "null explicite acceptée quand l’enquête locale est absente");
        Check.False(decoded.TsvBackup is not null, "null explicite acceptée quand le TSV distant est absent");
    }

    [Test]
    public static void Wrong_version_is_refused()
    {
        var node = ValidIntentNode();
        node["version"] = 2;
        Check.Throws<InvalidDataException>(() => Dec(Wrap(node)), "seule la version 1 est admise");
    }

    // ---- strict UTC timestamps ------------------------------------------------

    [Test]
    public static void Non_utc_timestamp_is_refused()
    {
        var node = ValidIntentNode();
        node["recordedAt"] = "2026-10-24T13:01:00.0000000+02:00";
        Check.Throws<InvalidDataException>(() => Dec(Wrap(node)), "un horodatage non UTC est refusé");
    }

    [Test]
    public static void Date_only_timestamp_is_refused()
    {
        var node = ValidIntentNode();
        node["recordedAt"] = "2026-10-24";
        Check.Throws<InvalidDataException>(() => Dec(Wrap(node)), "une date seule n’est pas un horodatage complet");
    }

    [Test]
    public static void Missing_zone_timestamp_is_refused()
    {
        var node = ValidIntentNode();
        node["recordedAt"] = "2026-10-24T11:01:00.0000000";
        Check.Throws<InvalidDataException>(() => Dec(Wrap(node)), "une zone absente n’est pas résolue contre le fuseau local");
    }

    [Test]
    public static void Ambiguous_timestamp_is_refused()
    {
        var node = ValidIntentNode();
        node["recordedAt"] = "2026-10-24 11:01:00.0000000Z";
        Check.Throws<InvalidDataException>(() => Dec(Wrap(node)), "une forme calendaire ambiguë est refusée");
    }

    [Test]
    public static void Unknown_key_in_envelope_is_refused()
    {
        var intentJson = ValidIntentNode().ToJsonString();
        var sha = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(intentJson)));
        Check.Throws<InvalidDataException>(() => Dec(Envelope(intentJson, sha, ",\"extra\":1")), "propriété inconnue dans l’enveloppe refusée");
    }

    [Test]
    public static void Duplicate_key_in_envelope_is_refused()
    {
        var intentJson = ValidIntentNode().ToJsonString();
        var sha = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(intentJson)));
        Check.Throws<InvalidDataException>(() => Dec(Envelope(intentJson, sha, ",\"format\":\"domenia.sharedParkIntent\"")), "propriété dupliquée dans l’enveloppe refusée");
    }

    private static bool IsHex(string value) => value.Length == 64 && value.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f'));
}
