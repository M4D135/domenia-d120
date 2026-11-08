using System.Collections.Immutable;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Domenia.Core;
using Domenia.Core.Queries;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private readonly Lock operationsTargetsGate = new();
    private OperationsTargetsSnapshot? operationsTargetsSnapshot;
    private sealed record OperationsTargetsSnapshot(string Fingerprint, string Manifest, object Targets, long SchemaVersion, bool Committed = false);

    private static bool HasOnlyQualifiedStorageTriggers(SqliteDatabase db) => OperationsTargetPages.OnlyKnownGuards(db);

    private long EstimateOperationsBytes(OperationsLocalState state)
    {
        // Admission still reserves space for the actual census; it must not serialize that census
        // into a second giant byte[] merely to display the writer's queue length at every checkpoint.
        var header = state with
        {
            HomeCampaign = state.HomeCampaign is { } home ? home with { Targets = [], PresenceDone = [], InventoryDone = [] } : null,
            Survey = state.Survey is { } survey ? survey with { Targets = [], Completed = [] } : null,
        };
        long bytes = JsonSerializer.SerializeToUtf8Bytes(header, Json).LongLength + 65_536;
        if (state.HomeCampaign is { } h)
        {
            bytes += h.Targets.Length;
            lock (operationsTargetsGate)
            { if (operationsTargetsSnapshot is { Committed: true, Targets: ImmutableArray<QueryComputerIdentity> cached } && cached.Equals(h.Targets)) { return bytes; } }
            return bytes + OperationsTargetPages.EstimateBytes(h.Targets);
        }
        if (state.Survey is { } s)
        {
            bytes += s.Targets.Length;
            lock (operationsTargetsGate)
            { if (operationsTargetsSnapshot is { Committed: true, Targets: ImmutableArray<SurveyTarget> cached } && cached.Equals(s.Targets)) { return bytes; } }
            return bytes + OperationsTargetPages.EstimateBytes(s.Targets);
        }
        return bytes;
    }

    /// <summary>
    /// The identities are immutable; only the small operations document contains changing progress.
    /// Each page has a content hash, and its ordered manifest has a separate content hash. Keeping
    /// one verified snapshot avoids rereading/recompressing 100,000 identities at every checkpoint.
    /// SQL guards prohibit changing a published set in place, including through another instance.
    /// </summary>
    private sealed class OperationsTargetPages(DomeniaDatabase owner, SqliteDatabase db) : IOperationsTargetPages
    {
        private const int PageTargets = 256;
        private const int MaxPageBytes = 2 * 1024 * 1024;
        private const int MaxManifestBytes = 1024 * 1024;
        private const int MaxPages = 4096;
        private const long MaxSetBytes = 512L * 1024 * 1024;
        private const string Format = "Domenia.CampaignTargets/1";
        private const string Sets = "domenia_v2_operation_target_sets";
        private const string Pages = "domenia_v2_operation_target_pages";
        private static readonly JsonSerializerOptions Options = new()
        { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, MaxDepth = 16, UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow };
        private sealed record Size(long Bytes);
        private static readonly ConditionalWeakTable<object, Size> Sizes = new();
        private sealed record Page(int Ordinal, int Count, int Bytes, string Sha256);
        private sealed record Manifest(string Format, string Kind, int Count, ImmutableArray<Page> Pages);
        private static readonly string[] Guards =
        [
            "CREATE TRIGGER domenia_operation_targets_set_immutable BEFORE UPDATE ON " + Sets + " BEGIN SELECT RAISE(ABORT,'Immutable campaign target manifest'); END",
            "CREATE TRIGGER domenia_operation_targets_page_immutable BEFORE UPDATE ON " + Pages + " BEGIN SELECT RAISE(ABORT,'Immutable campaign target page'); END",
            "CREATE TRIGGER domenia_operation_targets_page_insert BEFORE INSERT ON " + Pages + " WHEN EXISTS(SELECT 1 FROM " + Sets + " WHERE fingerprint=NEW.fingerprint) BEGIN SELECT RAISE(ABORT,'Published campaign target set'); END",
            "CREATE TRIGGER domenia_operation_targets_set_delete BEFORE DELETE ON " + Sets + " WHEN EXISTS(SELECT 1 FROM domenia_v2_operations WHERE instr(payload,OLD.fingerprint)>0) BEGIN SELECT RAISE(ABORT,'Referenced campaign target set'); END",
            "CREATE TRIGGER domenia_operation_targets_page_delete BEFORE DELETE ON " + Pages + " WHEN EXISTS(SELECT 1 FROM " + Sets + " WHERE fingerprint=OLD.fingerprint) BEGIN SELECT RAISE(ABORT,'Published campaign target page'); END",
        ];
        internal static bool OnlyKnownGuards(SqliteDatabase db) => db.Query("SELECT sql FROM sqlite_master WHERE type='trigger';")
            .All(row => Guards.Contains(NormalizeGuard(row["sql"] as string), StringComparer.Ordinal) || KnownFleetGuard(row["sql"] as string));
        private static string NormalizeGuard(string? sql) => (sql ?? "").Replace("IF NOT EXISTS ", "", StringComparison.Ordinal).Trim().TrimEnd(';');

        internal static long EstimateBytes<T>(ImmutableArray<T> targets)
        {
            if (targets.IsDefault || targets.Length > OperationsPersistence.MaxTargets) { throw Invalid("nombre hors limites."); }
            return Sizes.GetValue(ImmutableCollectionsMarshal.AsArray(targets)!, _ =>
            {
                long bytes = MaxManifestBytes;
                for (var i = 0; i < targets.Length; i += PageTargets)
                { bytes += Encoding.UTF8.GetByteCount(SerializePage(targets, i, Math.Min(PageTargets, targets.Length - i))); }
                if (bytes > MaxSetBytes + MaxManifestBytes) { throw Invalid("identités trop volumineuses ; aucun plan tronqué ou remplacé."); }
                return new(bytes);
            }).Bytes;
        }

        internal string? WrittenReference { get; private set; }
        internal void Committed()
        {
            lock (owner.operationsTargetsGate)
            {
                if (owner.operationsTargetsSnapshot is { } cached && cached.Fingerprint == WrittenReference)
                { owner.operationsTargetsSnapshot = cached with { Committed = true }; }
            }
        }
        public string WriteHome(ImmutableArray<QueryComputerIdentity> targets) => Write("home", targets);
        public string WriteSurvey(ImmutableArray<SurveyTarget> targets) => Write("survey", targets);
        public ImmutableArray<QueryComputerIdentity> ReadHome(string fingerprint, int count) => Read<QueryComputerIdentity>("home", fingerprint, count);
        public ImmutableArray<SurveyTarget> ReadSurvey(string fingerprint, int count) => Read<SurveyTarget>("survey", fingerprint, count);

        private static InvalidDataException Invalid(string message) => new("Cibles durables : " + message);
        private static string Hash(string value) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
        private static bool Fingerprint(string? value) => value is { Length: 64 } && value.All(char.IsAsciiHexDigit);

        private void EnsureTables()
        {
            db.Script("CREATE TABLE IF NOT EXISTS " + Sets + "(fingerprint TEXT PRIMARY KEY NOT NULL,manifest TEXT NOT NULL);"
                + "CREATE TABLE IF NOT EXISTS " + Pages + "(fingerprint TEXT NOT NULL,ordinal INTEGER NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(fingerprint,ordinal));");
            foreach (var guard in Guards) { db.Script(guard.Replace("CREATE TRIGGER ", "CREATE TRIGGER IF NOT EXISTS ", StringComparison.Ordinal) + ";"); }
        }

        private string Write<T>(string kind, ImmutableArray<T> targets)
        {
            if (targets.IsDefault || targets.Length > OperationsPersistence.MaxTargets) { throw Invalid("nombre hors limites."); }
            EnsureTables();
            OperationsTargetsSnapshot? cached;
            lock (owner.operationsTargetsGate) { cached = owner.operationsTargetsSnapshot; }
            if (cached is not null && cached.Targets is ImmutableArray<T> same && same.Equals(targets)
                && db.Scalar("SELECT manifest FROM " + Sets + " WHERE fingerprint=?1;", cached.Fingerprint) as string == cached.Manifest)
            {
                _ = Read<T>(kind, cached.Fingerprint, targets.Length);
                WrittenReference = cached.Fingerprint; return cached.Fingerprint;
            }
            // First pass keeps descriptors only, never a second whole serialized copy of the census.
            var descriptors = ImmutableArray.CreateBuilder<Page>(); long totalBytes = 0;
            for (var ordinal = 0; ordinal < targets.Length;)
            {
                var count = Math.Min(PageTargets, targets.Length - ordinal);
                var payload = SerializePage(targets, ordinal, count);
                while (Encoding.UTF8.GetByteCount(payload) > MaxPageBytes && count > 1)
                { count /= 2; payload = SerializePage(targets, ordinal, count); }
                var bytes = Encoding.UTF8.GetByteCount(payload);
                if (bytes > MaxPageBytes || (totalBytes += bytes) > MaxSetBytes || descriptors.Count == MaxPages)
                { throw Invalid("identités trop volumineuses ; aucun plan tronqué ou remplacé."); }
                descriptors.Add(new(ordinal, count, bytes, Hash(payload))); ordinal += count;
            }
            var manifest = JsonSerializer.Serialize(new Manifest(Format, kind, targets.Length, descriptors.ToImmutable()), Options);
            if (Encoding.UTF8.GetByteCount(manifest) > MaxManifestBytes) { throw Invalid("manifeste hors limites."); }
            var fingerprint = Hash(manifest);
            if (db.Scalar("SELECT manifest FROM " + Sets + " WHERE fingerprint=?1;", fingerprint) is string previous)
            {
                if (previous != manifest) { throw Invalid("empreinte du manifeste incohérente."); }
                _ = Read<T>(kind, fingerprint, targets.Length);
            }
            else
            {
                foreach (var page in descriptors)
                {
                    var payload = SerializePage(targets, page.Ordinal, page.Count);
                    if (Hash(payload) != page.Sha256) { throw Invalid("identités modifiées pendant la préparation."); }
                    db.Execute("INSERT INTO " + Pages + "(fingerprint,ordinal,payload) VALUES(?1,?2,?3);", fingerprint, page.Ordinal, payload);
                    if (db.Scalar("SELECT payload FROM " + Pages + " WHERE fingerprint=?1 AND ordinal=?2;", fingerprint, page.Ordinal) as string != payload)
                    { throw Invalid("page différente après écriture ; transaction annulée."); }
                }
                db.Execute("INSERT INTO " + Sets + "(fingerprint,manifest) VALUES(?1,?2);", fingerprint, manifest);
            }
            // A rollback cannot make this cache authoritative: every use also requires its SQL manifest.
            lock (owner.operationsTargetsGate) { owner.operationsTargetsSnapshot = new(fingerprint, manifest, targets, SchemaVersion()); }
            WrittenReference = fingerprint; return fingerprint;
        }

        private static string SerializePage<T>(ImmutableArray<T> targets, int ordinal, int count) =>
            JsonSerializer.Serialize(targets.AsSpan().Slice(ordinal, count).ToArray(), Options);

        private ImmutableArray<T> Read<T>(string kind, string fingerprint, int count)
        {
            if (!Fingerprint(fingerprint) || count is < 0 or > OperationsPersistence.MaxTargets || !Table(db, Sets) || !Table(db, Pages))
            { throw Invalid("référence absente ou hors limites."); }
            var json = db.Scalar("SELECT CASE WHEN length(CAST(manifest AS BLOB))<=1048576 THEN manifest END FROM " + Sets + " WHERE fingerprint=?1;", fingerprint) as string;
            if (json is null || Hash(json) != fingerprint) { throw Invalid("manifeste absent ou empreinte altérée."); }
            var manifest = ReadValue<Manifest>(json) ?? throw Invalid("manifeste vide.");
            if (manifest.Format != Format || manifest.Kind != kind || manifest.Count != count || manifest.Pages.IsDefault || manifest.Pages.Length > MaxPages)
            { throw Invalid("version, type ou nombre incohérent."); }
            var ordinal = 0; long totalBytes = 0;
            foreach (var page in manifest.Pages)
            {
                if (page is null || page.Ordinal != ordinal || page.Count is < 1 or > PageTargets || page.Bytes is < 1 or > MaxPageBytes || !Fingerprint(page.Sha256))
                { throw Invalid("ordre ou taille des pages incohérent."); }
                ordinal += page.Count; totalBytes += page.Bytes;
            }
            if (ordinal != count || totalBytes > MaxSetBytes
                || (long?)db.Scalar("SELECT count(*) FROM " + Pages + " WHERE fingerprint=?1;", fingerprint) != manifest.Pages.Length)
            { throw Invalid("pages manquantes, supplémentaires ou trop volumineuses."); }
            var guardDefinitions = db.Query("SELECT sql FROM sqlite_master WHERE type='trigger' AND name IN ('domenia_operation_targets_set_immutable','domenia_operation_targets_page_immutable','domenia_operation_targets_page_insert','domenia_operation_targets_set_delete','domenia_operation_targets_page_delete');")
                .Select(row => NormalizeGuard(row["sql"] as string)).ToHashSet(StringComparer.Ordinal);
            var guards = guardDefinitions.Count == Guards.Length && Guards.All(guardDefinitions.Contains);
            var schemaVersion = SchemaVersion();
            lock (owner.operationsTargetsGate)
            {
                if (guards && owner.operationsTargetsSnapshot is { } cached && cached.Fingerprint == fingerprint && cached.Manifest == json
                    && cached.SchemaVersion == schemaVersion
                    && cached.Targets is ImmutableArray<T> same && same.Length == count) { return same; }
            }
            var result = ImmutableArray.CreateBuilder<T>(count);
            foreach (var page in manifest.Pages)
            {
                var payload = db.Scalar("SELECT CASE WHEN length(CAST(payload AS BLOB))<=2097152 THEN payload END FROM " + Pages + " WHERE fingerprint=?1 AND ordinal=?2;", fingerprint, page.Ordinal) as string;
                if (payload is null || Encoding.UTF8.GetByteCount(payload) != page.Bytes || Hash(payload) != page.Sha256)
                { throw Invalid("page absente ou empreinte altérée ; aucune progression acceptée."); }
                var items = ReadValue<ImmutableArray<T>>(payload);
                if (items.IsDefault || items.Length != page.Count || items.Any(item => item is null)) { throw Invalid("nombre d’identités incohérent dans une page."); }
                result.AddRange(items);
            }
            var targets = result.MoveToImmutable();
            if (guards) { lock (owner.operationsTargetsGate) { owner.operationsTargetsSnapshot = new(fingerprint, json, targets, schemaVersion); } }
            return targets;
        }

        private long SchemaVersion() => (long)db.Scalar("PRAGMA schema_version;")!;

        private static T? ReadValue<T>(string json)
        {
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 16 });
            Unique(document.RootElement);
            return document.RootElement.Deserialize<T>(Options);
        }
        private static void Unique(JsonElement value)
        {
            if (value.ValueKind == JsonValueKind.Object)
            {
                var fields = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var property in value.EnumerateObject())
                { if (!fields.Add(property.Name)) { throw Invalid("champ JSON en double."); } Unique(property.Value); }
            }
            else if (value.ValueKind == JsonValueKind.Array) { foreach (var item in value.EnumerateArray()) { Unique(item); } }
        }

        internal void RemoveUnreferenced()
        {
            if (!Table(db, Sets)) { return; }
            // Remove manifests first; their pages cease to be published in this same transaction.
            db.Execute("DELETE FROM " + Sets + " WHERE fingerprint<>?1;", WrittenReference ?? "");
            db.Execute("DELETE FROM " + Pages + " WHERE NOT EXISTS(SELECT 1 FROM " + Sets + " WHERE " + Sets + ".fingerprint=" + Pages + ".fingerprint);");
            lock (owner.operationsTargetsGate)
            { if (owner.operationsTargetsSnapshot?.Fingerprint != WrittenReference) { owner.operationsTargetsSnapshot = null; } }
        }
    }
}
