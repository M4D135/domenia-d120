using System.Collections.Immutable;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Domenia.Core;

/// <summary>The existing operations journal, with a bounded versioned campaign. No credentials, command or automatic replay.</summary>
public static partial class OperationsDocumentCodec
{
    public const string Format = "Domenia.Operations/2";
    private const string PreviousFormat = "Domenia.Operations/1";
    public const string CampaignFormat = "Domenia.CampaignPlan/1";
    public const string PagedCampaignFormat = "Domenia.CampaignPlan/LocalPages1";
    public const int MaxDocumentBytes = 8 * 1024 * 1024;
    public const int MaxCampaignBytes = 900 * 1024;
    public const int MaxTargetsBytes = 16 * 1024 * 1024;
    private static readonly JsonSerializerOptions Plain = new()
    { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, MaxDepth = 40, UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow };
    private static readonly JsonSerializerOptions Packed = CreateOptions();
    private static JsonSerializerOptions CreateOptions(IOperationsTargetPages? targets = null)
    {
        var options = new JsonSerializerOptions(Plain);
        options.Converters.Add(new CampaignConverter(targets));
        options.Converters.Add(new HomeCampaignConverter(targets));
        return options;
    }

    public static string Encode(OperationsLocalState state, IOperationsTargetPages? targets = null)
    {
        OperationsPersistence.Validate(state);
        var text = JsonSerializer.Serialize(new Envelope(Format, state), targets is null ? Packed : CreateOptions(targets));
        if (Encoding.UTF8.GetByteCount(text) > MaxDocumentBytes) { throw Invalid("Journal d’opérations supérieur à 8 Mio."); }
        return text;
    }

    public static OperationsLocalState Decode(string text, IOperationsTargetPages? targets = null)
    {
        if (Encoding.UTF8.GetByteCount(text) > MaxDocumentBytes) { throw Invalid("Journal d’opérations supérieur à 8 Mio."); }
        try
        {
            using var document = JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = 40 });
            Unique(document.RootElement);
            var root = document.RootElement;
            OperationsLocalState? state;
            if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("format", out var format))
            {
                Fields(root, "format", "state");
                if (format.GetString() is not (Format or PreviousFormat)) { throw Invalid("Version du journal d’opérations non prise en charge."); }
                if (format.GetString() == PreviousFormat) { Fields(root.GetProperty("state"), "storeId", "domainDn", "revision", "runs", "samples", "survey"); }
                else { Fields(root.GetProperty("state"), "storeId", "domainDn", "revision", "runs", "samples", "survey", "homeCampaign"); }
                state = root.GetProperty("state").Deserialize<OperationsLocalState>(targets is null ? Packed : CreateOptions(targets));
            }
            else
            {
                // The only migration is the known pre-versioned journal. No future format is guessed.
                if (root.TryGetProperty("homeCampaign", out var legacyHome))
                {
                    Fields(root, "storeId", "domainDn", "revision", "runs", "samples", "survey", "homeCampaign");
                    if (legacyHome.ValueKind != JsonValueKind.Null) { throw Invalid("Plan Accueil sans format explicite."); }
                }
                else { Fields(root, "storeId", "domainDn", "revision", "runs", "samples", "survey"); }
                state = root.Deserialize<OperationsLocalState>(Plain);
            }
            if (state is null) { throw Invalid("Journal d’opérations vide."); }
            OperationsPersistence.Validate(state);
            return state;
        }
        catch (Exception error) when (error is JsonException or FormatException or ArgumentException or OverflowException or InvalidOperationException)
        { throw Invalid("Journal d’opérations illisible ou incohérent.", error); }
    }

    private static void Unique(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var field in value.EnumerateObject())
            {
                if (!names.Add(field.Name)) { throw Invalid("Champ du journal en double."); }
                Unique(field.Value);
            }
        }
        else if (value.ValueKind == JsonValueKind.Array) { foreach (var child in value.EnumerateArray()) { Unique(child); } }
    }

    private static void Fields(JsonElement value, params string[] names)
    {
        if (value.ValueKind != JsonValueKind.Object || value.EnumerateObject().Count() != names.Length
            || names.Any(name => !value.TryGetProperty(name, out _))) { throw Invalid("Champs du journal non reconnus ou manquants."); }
    }

    private static InvalidDataException Invalid(string message, Exception? inner = null) => new(message, inner);
    private sealed record Envelope(string Format, OperationsLocalState State);
    private sealed record Campaign(string Format, string Id, string DomainDn, ScopeSelection Scope, SurveyMode Mode,
        int Count, string Targets, string TargetsSha256, string Done, DateTimeOffset StartedAt, DateTimeOffset UpdatedAt, bool Interrupted, int Failed);

    private sealed class CampaignConverter(IOperationsTargetPages? pages) : JsonConverter<OperationsSurveyCheckpoint>
    {
        public override OperationsSurveyCheckpoint Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        {
            using var doc = JsonDocument.ParseValue(ref reader);
            var root = doc.RootElement;
            Fields(root, "format", "id", "domainDn", "scope", "mode", "count", "targets", "targetsSha256", "done", "startedAt", "updatedAt", "interrupted", "failed");
            if (Encoding.UTF8.GetByteCount(root.GetRawText()) > MaxCampaignBytes) { throw Invalid("Plan de campagne supérieur à 900 Kio ; aucune troncature."); }
            var value = root.Deserialize<Campaign>(Plain) ?? throw Invalid("Plan de campagne vide.");
            if (value.Format != CampaignFormat && (value.Format != PagedCampaignFormat || pages is null)) { throw Invalid("Version du plan de campagne non prise en charge ou cibles locales indisponibles."); }
            if (value.Count is < 1 or > OperationsPersistence.MaxTargets || value.Targets is null || value.Done is null
                || value.TargetsSha256 is not { Length: 64 } || !value.TargetsSha256.All(char.IsAsciiHexDigit))
            { throw Invalid("Plan de campagne hors limites."); }
            var targets = value.Format == PagedCampaignFormat
                ? value.Targets == value.TargetsSha256 ? pages!.ReadSurvey(value.TargetsSha256, value.Count) : throw Invalid("Référence des cibles de campagne incohérente.")
                : ReadInline(value);
            if (targets.IsDefault || targets.Length != value.Count) { throw Invalid("Nombre de cibles de campagne incohérent."); }
            var done = Convert.FromBase64String(value.Done);
            if (Convert.ToBase64String(done) != value.Done || done.Length != (value.Count + 7) / 8 || value.Count % 8 != 0 && (done[^1] >> (value.Count % 8)) != 0)
            { throw Invalid("Bits de progression hors du plan."); }
            var completed = ImmutableArray.CreateBuilder<Guid>();
            for (var i = 0; i < value.Count; i++)
            {
                if ((done[i / 8] & (1 << (i % 8))) != 0)
                {
                    if (targets[i] is null || !Guid.TryParse(targets[i].Id, out var id)) { throw Invalid("Identité terminée invalide."); }
                    completed.Add(id);
                }
            }
            return new(value.Id, value.DomainDn, value.Scope, value.Mode, targets, completed.ToImmutable(), value.StartedAt, value.UpdatedAt, value.Interrupted, value.Failed);
        }

        private static ImmutableArray<SurveyTarget> ReadInline(Campaign value)
        {
            var packed = Convert.FromBase64String(value.Targets);
            if (Convert.ToBase64String(packed) != value.Targets) { throw Invalid("Encodage des cibles non canonique."); }
            using var source = new MemoryStream(packed, writable: false);
            using var gzip = new GZipStream(source, CompressionMode.Decompress);
            using var output = new MemoryStream();
            var buffer = new byte[8192];
            int read;
            while ((read = gzip.Read(buffer)) != 0)
            {
                if (output.Length + read > MaxTargetsBytes) { throw Invalid("Liste décompressée supérieure à 16 Mio."); }
                output.Write(buffer, 0, read);
            }
            var raw = output.ToArray();
            if (!string.Equals(Convert.ToHexStringLower(SHA256.HashData(raw)), value.TargetsSha256, StringComparison.Ordinal))
            { throw Invalid("Empreinte de la liste de campagne altérée."); }
            using (var targetsDoc = JsonDocument.Parse(raw)) { Unique(targetsDoc.RootElement); }
            return JsonSerializer.Deserialize<ImmutableArray<SurveyTarget>>(raw, Plain);
        }

        public override void Write(Utf8JsonWriter writer, OperationsSurveyCheckpoint value, JsonSerializerOptions options)
        {
            string encodedTargets, fingerprint;
            if (pages is not null) { encodedTargets = fingerprint = pages.WriteSurvey(value.Targets); }
            else
            {
                var raw = JsonSerializer.SerializeToUtf8Bytes(value.Targets, Plain);
                if (raw.Length > MaxTargetsBytes) { throw Invalid("Liste décompressée supérieure à 16 Mio."); }
                using var output = new MemoryStream();
                using (var gzip = new GZipStream(output, CompressionLevel.Fastest, leaveOpen: true)) { gzip.Write(raw); }
                encodedTargets = Convert.ToBase64String(output.ToArray()); fingerprint = Convert.ToHexStringLower(SHA256.HashData(raw));
            }
            var done = new byte[(value.Targets.Length + 7) / 8];
            var completed = value.Completed.ToHashSet();
            for (var i = 0; i < value.Targets.Length; i++)
            { if (completed.Contains(Guid.Parse(value.Targets[i].Id))) { done[i / 8] |= (byte)(1 << (i % 8)); } }
            var campaign = new Campaign(pages is null ? CampaignFormat : PagedCampaignFormat, value.Id, value.DomainDn, value.Scope, value.Mode, value.Targets.Length,
                encodedTargets, fingerprint, Convert.ToBase64String(done),
                value.StartedAt, value.UpdatedAt, value.Interrupted, value.Failed);
            var bytes = JsonSerializer.SerializeToUtf8Bytes(campaign, Plain);
            if (bytes.Length > MaxCampaignBytes) { throw Invalid("Plan de campagne supérieur à 900 Kio ; aucune troncature."); }
            writer.WriteRawValue(bytes, skipInputValidation: false);
        }
    }
}
