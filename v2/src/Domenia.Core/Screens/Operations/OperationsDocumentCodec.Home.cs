using System.Collections.Immutable;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;

namespace Domenia.Core;

public static partial class OperationsDocumentCodec
{
    public const string HomeFormat = "Domenia.HomeCampaign/1";
    public const string PagedHomeFormat = "Domenia.HomeCampaign/LocalPages1";
    private sealed record HomeDocument(string Format, string Id, string StoreId, string DomainDn, ScopeSelection Scope, string Mode,
        ImmutableArray<string> Stages, ImmutableArray<string> DoneStages, int Count, string Targets, string TargetsSha256,
        ImmutableArray<string> Probes, ImmutableArray<HomeCampaignQuery> Queries, string PresenceDone, string InventoryDone,
        DateTimeOffset StartedAt, DateTimeOffset UpdatedAt, DateTimeOffset? PresenceStartedAt, bool Forced, bool Interrupted)
    {
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        public ImmutableArray<ScopeSelection>? Branches { get; init; }
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)]
        public bool ReadWithoutEcho { get; init; }
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        public ImmutableArray<HomeMemoryScope>? MemoryPolicies { get; init; }
    }

    private sealed class HomeCampaignConverter(IOperationsTargetPages? pages) : JsonConverter<HomeCampaignCheckpoint>
    {
        public override HomeCampaignCheckpoint Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        {
            using var document = JsonDocument.ParseValue(ref reader); var root = document.RootElement;
            string[] fields = ["format", "id", "storeId", "domainDn", "scope", "mode", "stages", "doneStages", "count", "targets", "targetsSha256",
                "probes", "queries", "presenceDone", "inventoryDone", "startedAt", "updatedAt", "presenceStartedAt", "forced", "interrupted"];
            var hasBranches = root.TryGetProperty("branches", out var branches);
            if (hasBranches) { fields = [.. fields, "branches"]; }
            if (root.TryGetProperty("readWithoutEcho", out _)) { fields = [.. fields, "readWithoutEcho"]; }
            if (root.TryGetProperty("memoryPolicies", out var memory))
            {
                fields = [.. fields, "memoryPolicies"];
                if (memory.ValueKind != JsonValueKind.Array) throw Invalid("Politique mémoire de campagne invalide.");
            }
            Fields(root, fields);
            if (hasBranches && branches.ValueKind != JsonValueKind.Array) { throw Invalid("Branches de campagne invalides."); }
            if (Encoding.UTF8.GetByteCount(root.GetRawText()) > MaxCampaignBytes) { throw Invalid("Plan Accueil supérieur à 900 Kio ; aucune troncature."); }
            var value = root.Deserialize<HomeDocument>(Plain) ?? throw Invalid("Plan Accueil vide.");
            if (value.Format != HomeFormat && (value.Format != PagedHomeFormat || pages is null)) { throw Invalid("Version du plan Accueil non prise en charge ou cibles locales indisponibles."); }
            if (value.Count is < 0 or > OperationsPersistence.MaxTargets || value.Targets is null || value.TargetsSha256 is not { Length: 64 } || !value.TargetsSha256.All(char.IsAsciiHexDigit))
            { throw Invalid("Liste du plan Accueil hors limites."); }
            var targets = value.Format == PagedHomeFormat
                ? value.Targets == value.TargetsSha256 ? pages!.ReadHome(value.TargetsSha256, value.Count) : throw Invalid("Référence des cibles Accueil incohérente.")
                : ReadInline(value);
            if (targets.IsDefault || targets.Length != value.Count || targets.Any(t => t is null)) { throw Invalid("Nombre de cibles Accueil incohérent."); }
            return new(value.Id, value.StoreId, value.DomainDn, value.Scope, value.Mode, value.Stages, value.DoneStages, targets, value.Probes, value.Queries,
                ReadBits(value.PresenceDone, targets), ReadBits(value.InventoryDone, targets), value.StartedAt, value.UpdatedAt, value.PresenceStartedAt, value.Forced, value.Interrupted)
            { Branches = value.Branches ?? [], ReadWithoutEcho = value.ReadWithoutEcho, MemoryPolicies = value.MemoryPolicies ?? [] };
        }
        private static ImmutableArray<QueryComputerIdentity> ReadInline(HomeDocument value)
        {
            var packed = Convert.FromBase64String(value.Targets);
            if (Convert.ToBase64String(packed) != value.Targets) { throw Invalid("Encodage des cibles Accueil non canonique."); }
            using var source = new MemoryStream(packed, writable: false);
            using var gzip = new GZipStream(source, CompressionMode.Decompress);
            using var output = new MemoryStream(); var buffer = new byte[8192]; int read;
            while ((read = gzip.Read(buffer)) != 0)
            {
                if (output.Length + read > MaxTargetsBytes) { throw Invalid("Liste Accueil décompressée supérieure à 16 Mio."); }
                output.Write(buffer, 0, read);
            }
            var bytes = output.ToArray();
            if (Convert.ToHexStringLower(SHA256.HashData(bytes)) != value.TargetsSha256) { throw Invalid("Empreinte des identités Accueil altérée."); }
            using (var targetsDocument = JsonDocument.Parse(bytes)) { Unique(targetsDocument.RootElement); }
            return JsonSerializer.Deserialize<ImmutableArray<QueryComputerIdentity>>(bytes, Plain);
        }
        public override void Write(Utf8JsonWriter writer, HomeCampaignCheckpoint value, JsonSerializerOptions options)
        {
            string encodedTargets, fingerprint;
            if (pages is not null) { encodedTargets = fingerprint = pages.WriteHome(value.Targets); }
            else
            {
                var bytes = JsonSerializer.SerializeToUtf8Bytes(value.Targets, Plain);
                if (bytes.Length > MaxTargetsBytes) { throw Invalid("Liste Accueil décompressée supérieure à 16 Mio."); }
                using var output = new MemoryStream();
                using (var gzip = new GZipStream(output, CompressionLevel.Fastest, true)) { gzip.Write(bytes); }
                encodedTargets = Convert.ToBase64String(output.ToArray()); fingerprint = Convert.ToHexStringLower(SHA256.HashData(bytes));
            }
            var document = new HomeDocument(pages is null ? HomeFormat : PagedHomeFormat, value.Id, value.StoreId, value.DomainDn, value.Scope, value.Mode, value.Stages, value.DoneStages,
                value.Targets.Length, encodedTargets, fingerprint, value.Probes, value.Queries,
                WriteBits(value.PresenceDone, value.Targets), WriteBits(value.InventoryDone, value.Targets), value.StartedAt, value.UpdatedAt, value.PresenceStartedAt, value.Forced, value.Interrupted)
            { Branches = value.Branches.IsEmpty ? null : value.Branches, ReadWithoutEcho = value.ReadWithoutEcho, MemoryPolicies = value.MemoryPolicies.IsEmpty ? null : value.MemoryPolicies };
            var encoded = JsonSerializer.SerializeToUtf8Bytes(document, Plain);
            if (encoded.Length > MaxCampaignBytes) { throw Invalid("Plan Accueil supérieur à 900 Kio ; aucune troncature."); }
            writer.WriteRawValue(encoded, skipInputValidation: false);
        }
        private static string WriteBits(ImmutableArray<Guid> completed, ImmutableArray<QueryComputerIdentity> targets)
        {
            var ids = completed.ToHashSet(); var bytes = new byte[(targets.Length + 7) / 8];
            for (var i = 0; i < targets.Length; i++) { if (ids.Contains(targets[i].Guid)) { bytes[i / 8] |= (byte)(1 << (i % 8)); } }
            return Convert.ToBase64String(bytes);
        }
        private static ImmutableArray<Guid> ReadBits(string text, ImmutableArray<QueryComputerIdentity> targets)
        {
            if (text is null) { throw Invalid("Progression Accueil absente."); }
            var bytes = Convert.FromBase64String(text);
            if (Convert.ToBase64String(bytes) != text || bytes.Length != (targets.Length + 7) / 8
                || targets.Length % 8 != 0 && (bytes[^1] >> (targets.Length % 8)) != 0) { throw Invalid("Bits Accueil étrangers au plan."); }
            return [.. targets.Where((_, i) => (bytes[i / 8] & (1 << (i % 8))) != 0).Select(t => t.Guid)];
        }
    }
}
