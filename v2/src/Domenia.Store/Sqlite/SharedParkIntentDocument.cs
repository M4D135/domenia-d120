using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

/// <summary>
/// One initial backup copy the future private journal will declare: a canonical local Windows path, the declared non-negative length
/// and the SHA-256 of the copied bytes. It is a <em>reference</em>, never the copy itself: no bytes, no stream, no handle. The copies
/// do not exist yet, so this record certifies no completed backup and no publication success.
/// </summary>
internal sealed record SharedParkBackupReference(string Path, long Length, string Sha256);

/// <summary>
/// The bounded metadata the durable protocol writes before it touches any copy: the sealed plan it belongs to (id and fingerprint),
/// the compact <see cref="SharedParkBatch"/> it was previewed from together with that batch's recomputed fingerprint, the UTC instant
/// the intention was recorded, and the initial SQLite and TSV backup references. Each reference is present exactly when the batch says
/// the matching survey exists (<see cref="SharedParkBatch.LocalExists"/> for SQLite, <see cref="SharedParkBatch.RemoteExists"/> for
/// the TSV) and null otherwise. It carries no line, no data array, no lease and no connection in any field, and it is never the TSV.
/// It is an intention, never a receipt: this format proves no copy was ever made and certifies no completed backup nor any publication
/// success. The future protocol must itself verify the backups exist and match before it persists this intention; nothing here does.
/// </summary>
internal sealed record SharedParkIntent(int Version, string PlanId, string PlanFingerprint, SharedParkBatch Batch,
    string BatchFingerprint, DateTimeOffset RecordedAt, SharedParkBackupReference? SqliteBackup, SharedParkBackupReference? TsvBackup);

/// <summary>
/// Pure, bounded codec for <see cref="SharedParkIntent"/>: <see cref="Encode"/> seals a freshly built intention into a versioned JSON
/// envelope (the exact intent JSON plus the SHA-256 of its UTF-8 bytes), <see cref="Decode"/> re-reads such a document. Both bind the
/// answer to the calling context — the expected store, domain, plan id and plan fingerprint — and both take a UTC <c>now</c> and a
/// cancellation token. There is no file, SQLite, share, ACL, process or any other I/O here: the returned bytes are a short metadata
/// document, never the TSV, and the caller owns where they are written. The codec does not implement the private DACL, the lock, the
/// file quota, the copies, publication, receipts or the UI: those obligations stay in the future journal and later lots, with no
/// placeholder pretending they exist. The SHA-256 detects corruption, never an administrator's falsification.
/// </summary>
internal static class SharedParkIntentDocument
{
    /// <summary>Tag of the envelope format, versioned so a future reader can tell this document apart from any other.</summary>
    public const string FormatTag = "domenia.sharedParkIntent";

    /// <summary>The only document and intent version this codec writes and accepts.</summary>
    public const int DocumentVersion = 1;

    /// <summary>Hard ceiling on the complete document (envelope included): 64 KiB.</summary>
    public const int MaxDocumentBytes = 64 * 1024;

    private const int MaxPathLength = 1024;
    private const int MaxScalarLength = 8192;
    private const int MaxMergedRows = 50000;
    private const long MaxPayloadBytes = 16_777_216;
    private static readonly TimeSpan MaxBatchLifetime = TimeSpan.FromMinutes(15);
    private static readonly DateTimeOffset UnixEpoch = new(1970, 1, 1, 0, 0, 0, TimeSpan.Zero);
    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
    private static readonly JsonDocumentOptions StrictJson = new() { CommentHandling = JsonCommentHandling.Disallow, AllowTrailingCommas = false, MaxDepth = 32 };
    private static readonly char[] InvalidFileChars = ['<', '>', '"', '|', '?', '*', ':', '/'];
    private static readonly string[] ReservedDeviceNames =
    [
        "CON", "PRN", "AUX", "NUL", "CLOCK$",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
        "COM\u00B9", "COM\u00B2", "COM\u00B3", "LPT\u00B9", "LPT\u00B2", "LPT\u00B3",
    ];

    /// <summary>
    /// Seals <paramref name="intent"/> into a bounded document. The expected store, domain, plan id and plan fingerprint must match the
    /// intention exactly, and <paramref name="now"/> must be UTC. An already-expired batch, a recorded instant in the future, a missing
    /// or defaulted required field, an oversized scalar, a bad identity, fingerprint, path or bound is refused as an
    /// <see cref="ArgumentException"/> — a programming error of the caller, never a silent fix. Honours cancellation before any work and
    /// just before returning.
    /// </summary>
    internal static byte[] Encode(SharedParkIntent intent, string expectedStoreId, string expectedDomainDn,
        string expectedPlanId, string expectedPlanFingerprint, DateTimeOffset now, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ArgumentNullException.ThrowIfNull(intent, nameof(intent));
        RequireExpected(expectedStoreId, nameof(expectedStoreId));
        RequireExpected(expectedDomainDn, nameof(expectedDomainDn));
        RequireExpected(expectedPlanId, nameof(expectedPlanId));
        RequireExpected(expectedPlanFingerprint, nameof(expectedPlanFingerprint));
        if (now.Offset != TimeSpan.Zero) { throw new ArgumentException("« now » doit être exprimé en UTC.", nameof(now)); }
        try
        {
            Validate(intent, expectedStoreId, expectedDomainDn, expectedPlanId, expectedPlanFingerprint, now, allowExpired: false);
        }
        catch (InvalidDataException ex)
        {
            throw new ArgumentException("Intention de parc partagé refusée à l’encodage : " + ex.Message, nameof(intent), ex);
        }

        var document = Build(intent);
        if (document.Length > MaxDocumentBytes) { throw new ArgumentException("Le document complet dépasse 64 Kio après échappement JSON.", nameof(intent)); }
        cancellationToken.ThrowIfCancellationRequested();
        return document;
    }

    /// <summary>
    /// Re-reads a document produced by <see cref="Encode"/>. Size and strict UTF-8 are checked before any parse; the envelope, the
    /// intention and every nested object require all their properties and reject unknown and duplicated ones; the exact SHA-256 of the
    /// intent bytes is verified before the content is accepted. The expected store, domain, plan id and plan fingerprint must match, and
    /// <paramref name="now"/> must be UTC. Unlike <see cref="Encode"/>, a still-well-formed intention whose batch has since expired is
    /// accepted (proof after a restart), never a right to replay it. Every corruption or mismatch is an <see cref="InvalidDataException"/>.
    /// </summary>
    internal static SharedParkIntent Decode(ReadOnlyMemory<byte> document, string expectedStoreId, string expectedDomainDn,
        string expectedPlanId, string expectedPlanFingerprint, DateTimeOffset now, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        RequireExpected(expectedStoreId, nameof(expectedStoreId));
        RequireExpected(expectedDomainDn, nameof(expectedDomainDn));
        RequireExpected(expectedPlanId, nameof(expectedPlanId));
        RequireExpected(expectedPlanFingerprint, nameof(expectedPlanFingerprint));
        if (now.Offset != TimeSpan.Zero) { throw new ArgumentException("« now » doit être exprimé en UTC.", nameof(now)); }
        if (document.Length > MaxDocumentBytes) { throw new InvalidDataException("Le document dépasse 64 Kio avant toute lecture."); }

        string text;
        try
        {
            text = StrictUtf8.GetString(document.Span);
        }
        catch (Exception ex)
        {
            throw new InvalidDataException("Le document n’est pas un UTF-8 strict.", ex);
        }

        JsonDocument parsed;
        try
        {
            parsed = JsonDocument.Parse(text, StrictJson);
        }
        catch (JsonException ex)
        {
            throw new InvalidDataException("Le document n’est pas un JSON strict complet.", ex);
        }

        using (parsed)
        {
            var envelope = parsed.RootElement;
            CheckShape(envelope, "enveloppe", "format", "version", "intent", "intentSha256");
            if (ReadString(envelope, "enveloppe", "format") != FormatTag) { throw new InvalidDataException("La balise de format de l’enveloppe est inconnue."); }
            if (ReadInt(envelope, "enveloppe", "version") != DocumentVersion) { throw new InvalidDataException("Seule la version 1 de l’enveloppe est lue."); }

            if (!envelope.TryGetProperty("intent", out var intentEl)) { throw new InvalidDataException("L’intention est absente de l’enveloppe."); }
            if (intentEl.ValueKind != JsonValueKind.Object) { throw new InvalidDataException("L’intention doit être un objet JSON."); }

            var storedSha = ReadString(envelope, "enveloppe", "intentSha256");
            if (!IsSha256Hex(storedSha)) { throw new InvalidDataException("L’empreinte « intentSha256 » doit être 64 chiffres hexadécimaux en minuscules."); }
            var computedSha = Convert.ToHexStringLower(SHA256.HashData(StrictUtf8.GetBytes(intentEl.GetRawText())));
            if (!CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(computedSha), Encoding.ASCII.GetBytes(storedSha)))
            {
                throw new InvalidDataException("Le SHA-256 de l’intention ne correspond pas à ses octets : contenu corrompu.");
            }

            var intent = ReadIntent(intentEl);
            Validate(intent, expectedStoreId, expectedDomainDn, expectedPlanId, expectedPlanFingerprint, now, allowExpired: true);
            cancellationToken.ThrowIfCancellationRequested();
            return intent;
        }
    }

    private static byte[] Build(SharedParkIntent intent)
    {
        using var intentBuffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(intentBuffer, new JsonWriterOptions { Indented = false }))
        {
            WriteIntent(writer, intent);
        }

        var intentBytes = intentBuffer.ToArray();
        var sha = Convert.ToHexStringLower(SHA256.HashData(intentBytes));
        var intentJson = StrictUtf8.GetString(intentBytes);

        using var documentBuffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(documentBuffer, new JsonWriterOptions { Indented = false }))
        {
            writer.WriteStartObject();
            writer.WriteString("format", FormatTag);
            writer.WriteNumber("version", DocumentVersion);
            writer.WritePropertyName("intent");
            writer.WriteRawValue(intentJson, skipInputValidation: true);
            writer.WriteString("intentSha256", sha);
            writer.WriteEndObject();
        }

        return documentBuffer.ToArray();
    }

    private static void WriteIntent(Utf8JsonWriter writer, SharedParkIntent intent)
    {
        writer.WriteStartObject();
        writer.WriteNumber("version", intent.Version);
        writer.WriteString("planId", intent.PlanId);
        writer.WriteString("planFingerprint", intent.PlanFingerprint);
        writer.WriteString("batchFingerprint", intent.BatchFingerprint);
        writer.WriteString("recordedAt", Iso(intent.RecordedAt));
        WriteBatch(writer, intent.Batch);
        WriteBackup(writer, "sqliteBackup", intent.SqliteBackup);
        WriteBackup(writer, "tsvBackup", intent.TsvBackup);
        writer.WriteEndObject();
    }

    private static void WriteBatch(Utf8JsonWriter writer, SharedParkBatch batch)
    {
        writer.WritePropertyName("batch");
        writer.WriteStartObject();
        writer.WriteString("id", batch.Id);
        writer.WriteString("sessionId", batch.SessionId);
        writer.WriteNumber("epoch", batch.Epoch);
        writer.WriteString("path", batch.Path);
        writer.WriteString("storeId", batch.StoreId);
        writer.WriteString("domainDn", batch.DomainDn);
        writer.WriteNumber("revision", batch.Revision);
        writer.WriteNumber("generation", batch.Generation);
        writer.WriteBoolean("localExists", batch.LocalExists);
        writer.WriteBoolean("legacy", batch.Legacy);
        writer.WriteString("rowsFingerprint", batch.RowsFingerprint);
        writer.WriteString("localFingerprint", batch.LocalFingerprint);
        writer.WriteBoolean("remoteExists", batch.RemoteExists);
        writer.WriteString("remoteSha256", batch.RemoteSha256);
        writer.WriteString("createdAt", Iso(batch.CreatedAt));
        writer.WriteString("expiresAt", Iso(batch.ExpiresAt));
        writer.WriteNumber("mergedRows", batch.MergedRows);
        writer.WriteNumber("payloadBytes", batch.PayloadBytes);
        writer.WriteString("proposedSha256", batch.ProposedSha256);
        writer.WriteNumber("added", batch.Added);
        writer.WriteNumber("replaced", batch.Replaced);
        writer.WriteEndObject();
    }

    private static void WriteBackup(Utf8JsonWriter writer, string name, SharedParkBackupReference? reference)
    {
        writer.WritePropertyName(name);
        if (reference is null) { writer.WriteNullValue(); return; }
        writer.WriteStartObject();
        writer.WriteString("path", reference.Path);
        writer.WriteNumber("length", reference.Length);
        writer.WriteString("sha256", reference.Sha256);
        writer.WriteEndObject();
    }

    private static SharedParkIntent ReadIntent(JsonElement intent)
    {
        CheckShape(intent, "intention", "version", "planId", "planFingerprint", "batchFingerprint", "recordedAt", "batch", "sqliteBackup", "tsvBackup");
        var version = ReadInt(intent, "intention", "version");
        var planId = ReadString(intent, "intention", "planId");
        var planFingerprint = ReadString(intent, "intention", "planFingerprint");
        var batchFingerprint = ReadString(intent, "intention", "batchFingerprint");
        var recordedAt = ReadDateTime(intent, "intention", "recordedAt");
        var batch = ReadBatch(intent.GetProperty("batch"));
        var sqlite = ReadBackup(intent, "sqliteBackup");
        var tsv = ReadBackup(intent, "tsvBackup");
        return new SharedParkIntent(version, planId, planFingerprint, batch, batchFingerprint, recordedAt, sqlite, tsv);
    }

    private static SharedParkBatch ReadBatch(JsonElement batch)
    {
        CheckShape(batch, "lot", "id", "sessionId", "epoch", "path", "storeId", "domainDn", "revision", "generation",
            "localExists", "legacy", "rowsFingerprint", "localFingerprint", "remoteExists", "remoteSha256", "createdAt",
            "expiresAt", "mergedRows", "payloadBytes", "proposedSha256", "added", "replaced");
        return new SharedParkBatch(
            ReadString(batch, "lot", "id"),
            ReadString(batch, "lot", "sessionId"),
            ReadLong(batch, "lot", "epoch"),
            ReadString(batch, "lot", "path"),
            ReadString(batch, "lot", "storeId"),
            ReadString(batch, "lot", "domainDn"),
            ReadLong(batch, "lot", "revision"),
            ReadLong(batch, "lot", "generation"),
            ReadBool(batch, "lot", "localExists"),
            ReadBool(batch, "lot", "legacy"),
            ReadString(batch, "lot", "rowsFingerprint"),
            ReadString(batch, "lot", "localFingerprint"),
            ReadBool(batch, "lot", "remoteExists"),
            ReadString(batch, "lot", "remoteSha256"),
            ReadDateTime(batch, "lot", "createdAt"),
            ReadDateTime(batch, "lot", "expiresAt"),
            ReadInt(batch, "lot", "mergedRows"),
            ReadLong(batch, "lot", "payloadBytes"),
            ReadString(batch, "lot", "proposedSha256"),
            ReadInt(batch, "lot", "added"),
            ReadInt(batch, "lot", "replaced"));
    }

    private static SharedParkBackupReference? ReadBackup(JsonElement owner, string name)
    {
        // The property must be present (CheckShape already required it); only an explicit JSON null is read as an absent reference.
        var element = owner.GetProperty(name);
        if (element.ValueKind == JsonValueKind.Null) { return null; }
        if (element.ValueKind != JsonValueKind.Object) { throw new InvalidDataException($"« {name} » doit être un objet ou null."); }
        CheckShape(element, name, "path", "length", "sha256");
        return new SharedParkBackupReference(
            ReadString(element, name, "path"),
            ReadLong(element, name, "length"),
            ReadString(element, name, "sha256"));
    }

    private static void Validate(SharedParkIntent intent, string expectedStoreId, string expectedDomainDn,
        string expectedPlanId, string expectedPlanFingerprint, DateTimeOffset now, bool allowExpired)
    {
        if (intent.Version != DocumentVersion) { throw new InvalidDataException("Seule la version 1 de l’intention est admise."); }
        var batch = intent.Batch ?? throw new InvalidDataException("Le lot compact est obligatoire.");

        // Bound every scalar before any fingerprint recomputation or serialization, so an oversized identity cannot drive an unbounded
        // hash or allocation before the final 64 KiB document check.
        EnsureScalarsBounded(intent, batch);

        if (!WritePlans.IsPlanId(intent.PlanId)) { throw new InvalidDataException("L’identifiant du plan doit être 32 chiffres hexadécimaux en minuscules."); }
        if (!string.Equals(intent.PlanId, expectedPlanId, StringComparison.Ordinal)) { throw new InvalidDataException("L’identifiant du plan ne correspond pas au contexte attendu."); }
        if (!IsSha256Hex(intent.PlanFingerprint)) { throw new InvalidDataException("L’empreinte du plan doit être 64 chiffres hexadécimaux en minuscules."); }
        if (!string.Equals(intent.PlanFingerprint, expectedPlanFingerprint, StringComparison.Ordinal)) { throw new InvalidDataException("L’empreinte du plan ne correspond pas au contexte attendu."); }
        if (!IsSha256Hex(intent.BatchFingerprint)) { throw new InvalidDataException("L’empreinte du lot doit être 64 chiffres hexadécimaux en minuscules."); }
        if (!string.Equals(SharedParkIdentity.Fingerprint(batch), intent.BatchFingerprint, StringComparison.Ordinal))
        {
            throw new InvalidDataException("L’empreinte du lot recalculée ne correspond pas à celle déclarée.");
        }

        if (!string.Equals(batch.StoreId, expectedStoreId, StringComparison.Ordinal)) { throw new InvalidDataException("L’identifiant du magasin ne correspond pas au contexte attendu."); }
        if (!string.Equals(batch.DomainDn, expectedDomainDn, StringComparison.Ordinal)) { throw new InvalidDataException("Le DN du domaine ne correspond pas au contexte attendu."); }
        if (!WritePlans.IsPlanId(batch.Id)) { throw new InvalidDataException("L’identifiant du lot doit être 32 chiffres hexadécimaux en minuscules."); }
        if (!WritePlans.IsPlanId(batch.SessionId)) { throw new InvalidDataException("L’identifiant de session doit être 32 chiffres hexadécimaux en minuscules."); }

        if (batch.Epoch < 0 || batch.Revision < 0 || batch.Generation < 0) { throw new InvalidDataException("L’époque, la révision et la génération du lot sont non négatives."); }
        if (batch.MergedRows < 0 || batch.MergedRows > MaxMergedRows) { throw new InvalidDataException("Le nombre de lignes fusionnées est hors de 0 à 50000."); }
        if (batch.PayloadBytes < 0 || batch.PayloadBytes > MaxPayloadBytes) { throw new InvalidDataException("Le volume proposé est hors de 0 à 16777216 octets."); }
        if (batch.Added < 0 || batch.Replaced < 0 || (long)batch.Added + batch.Replaced > batch.MergedRows)
        {
            throw new InvalidDataException("Les compteurs ajoutés/remplacés sont non négatifs et leur somme n’excède pas les lignes fusionnées.");
        }

        if (!IsCanonicalWindowsFilePath(batch.Path)) { throw new InvalidDataException("Le chemin du TSV partagé doit être un fichier canonique local ou UNC, sans alias, racine ni caractère de contrôle."); }
        if (!IsSha256Hex(batch.ProposedSha256)) { throw new InvalidDataException("L’empreinte des octets proposés doit être 64 chiffres hexadécimaux en minuscules."); }

        // The readers always carry a real SHA-256 for these, even when a survey is absent (the SHA of empty bytes, the fingerprint of an
        // empty sweep): absence is carried by the Exists flags and the null references, never by folding a fingerprint onto an empty string.
        if (!IsSha256Hex(batch.RowsFingerprint)) { throw new InvalidDataException("L’empreinte exhaustive des lignes est un SHA-256, même en absence."); }
        if (!IsSha256Hex(batch.LocalFingerprint)) { throw new InvalidDataException("L’empreinte logique locale est un SHA-256, même en absence."); }
        if (!IsSha256Hex(batch.RemoteSha256)) { throw new InvalidDataException("Le SHA du TSV distant est un SHA-256, même en absence."); }

        if (batch.CreatedAt.Offset != TimeSpan.Zero || batch.ExpiresAt.Offset != TimeSpan.Zero || intent.RecordedAt.Offset != TimeSpan.Zero)
        {
            throw new InvalidDataException("Les horodatages sont exprimés en UTC.");
        }
        if (batch.CreatedAt <= UnixEpoch) { throw new InvalidDataException("La création du lot suit l’époque Unix."); }
        if (batch.ExpiresAt <= batch.CreatedAt) { throw new InvalidDataException("L’expiration du lot suit sa création."); }
        if (batch.ExpiresAt - batch.CreatedAt > MaxBatchLifetime) { throw new InvalidDataException("La durée de vie du lot dépasse quinze minutes."); }
        if (intent.RecordedAt < batch.CreatedAt || intent.RecordedAt >= batch.ExpiresAt) { throw new InvalidDataException("L’instant d’enregistrement est dans la fenêtre du lot (inclusive en début, exclusive en fin)."); }
        if (intent.RecordedAt > now) { throw new InvalidDataException("L’instant d’enregistrement est futur par rapport à « now »."); }
        if (!allowExpired && now >= batch.ExpiresAt) { throw new InvalidDataException("Le lot est déjà expiré : aucune nouvelle intention n’est scellée."); }

        if (batch.LocalExists != (intent.SqliteBackup is not null)) { throw new InvalidDataException("La référence de sauvegarde SQLite est présente exactement quand l’enquête locale existe."); }
        if (batch.RemoteExists != (intent.TsvBackup is not null)) { throw new InvalidDataException("La référence de sauvegarde du TSV est présente exactement quand le TSV distant existe."); }
        if (intent.SqliteBackup is { } sqlite) { ValidateBackup(sqlite, "sqliteBackup"); }
        if (intent.TsvBackup is { } tsv) { ValidateBackup(tsv, "tsvBackup"); }

        var copies = new List<string>(3) { batch.Path };
        if (intent.SqliteBackup is { } s) { copies.Add(s.Path); }
        if (intent.TsvBackup is { } t) { copies.Add(t.Path); }
        for (var i = 0; i < copies.Count; i++)
        {
            for (var j = i + 1; j < copies.Count; j++)
            {
                if (string.Equals(copies[i], copies[j], StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException("Les chemins des deux copies et du TSV sont deux à deux distincts (comparaison insensible à la casse).");
                }
            }
        }
    }

    private static void EnsureScalarsBounded(SharedParkIntent intent, SharedParkBatch batch)
    {
        foreach (var (value, label) in new (string?, string)[]
        {
            (intent.PlanId, "planId"), (intent.PlanFingerprint, "planFingerprint"), (intent.BatchFingerprint, "batchFingerprint"),
            (batch.Id, "id"), (batch.SessionId, "sessionId"), (batch.Path, "path"), (batch.StoreId, "storeId"), (batch.DomainDn, "domainDn"),
            (batch.RowsFingerprint, "rowsFingerprint"), (batch.LocalFingerprint, "localFingerprint"), (batch.RemoteSha256, "remoteSha256"),
            (batch.ProposedSha256, "proposedSha256"),
            (intent.SqliteBackup?.Path, "sqliteBackup.path"), (intent.SqliteBackup?.Sha256, "sqliteBackup.sha256"),
            (intent.TsvBackup?.Path, "tsvBackup.path"), (intent.TsvBackup?.Sha256, "tsvBackup.sha256"),
        })
        {
            if (value is { Length: > MaxScalarLength }) { throw new InvalidDataException($"Le champ « {label} » dépasse {MaxScalarLength} caractères avant toute sérialisation."); }
        }
    }

    private static void ValidateBackup(SharedParkBackupReference reference, string label)
    {
        if (!IsCanonicalLocalBackupPath(reference.Path)) { throw new InvalidDataException($"Le chemin de sauvegarde « {label} » doit être un chemin local Windows pleinement qualifié, canonique et borné."); }
        if (reference.Length < 0) { throw new InvalidDataException($"La longueur déclarée de « {label} » est non négative."); }
        if (!IsSha256Hex(reference.Sha256)) { throw new InvalidDataException($"Le SHA-256 de « {label} » doit être 64 chiffres hexadécimaux en minuscules."); }
    }

    private static void CheckShape(JsonElement element, string label, params string[] allowed)
    {
        if (element.ValueKind != JsonValueKind.Object) { throw new InvalidDataException($"« {label} » doit être un objet JSON."); }
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in element.EnumerateObject())
        {
            if (Array.IndexOf(allowed, property.Name) < 0) { throw new InvalidDataException($"« {label} » porte une propriété inconnue « {property.Name} »."); }
            if (!seen.Add(property.Name)) { throw new InvalidDataException($"« {label} » porte une propriété dupliquée « {property.Name} »."); }
        }
        foreach (var name in allowed)
        {
            if (!element.TryGetProperty(name, out _)) { throw new InvalidDataException($"« {label} » omet la propriété requise « {name} »."); }
        }
    }

    private static string ReadString(JsonElement element, string label, string name)
    {
        if (!element.TryGetProperty(name, out var value)) { throw new InvalidDataException($"« {label} » omet la propriété requise « {name} »."); }
        if (value.ValueKind != JsonValueKind.String) { throw new InvalidDataException($"« {label}.{name} » doit être une chaîne."); }
        return value.GetString()!;
    }

    private static int ReadInt(JsonElement element, string label, string name)
    {
        if (!element.TryGetProperty(name, out var value)) { throw new InvalidDataException($"« {label} » omet la propriété requise « {name} »."); }
        if (value.ValueKind != JsonValueKind.Number) { throw new InvalidDataException($"« {label}.{name} » doit être un nombre entier."); }
        try { return value.GetInt32(); }
        catch (Exception ex) { throw new InvalidDataException($"« {label}.{name} » n’est pas un entier 32 bits.", ex); }
    }

    private static long ReadLong(JsonElement element, string label, string name)
    {
        if (!element.TryGetProperty(name, out var value)) { throw new InvalidDataException($"« {label} » omet la propriété requise « {name} »."); }
        if (value.ValueKind != JsonValueKind.Number) { throw new InvalidDataException($"« {label}.{name} » doit être un nombre entier."); }
        try { return value.GetInt64(); }
        catch (Exception ex) { throw new InvalidDataException($"« {label}.{name} » n’est pas un entier 64 bits.", ex); }
    }

    private static bool ReadBool(JsonElement element, string label, string name)
    {
        if (!element.TryGetProperty(name, out var value)) { throw new InvalidDataException($"« {label} » omet la propriété requise « {name} »."); }
        return value.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => throw new InvalidDataException($"« {label}.{name} » doit être un booléen."),
        };
    }

    private static DateTimeOffset ReadDateTime(JsonElement element, string label, string name)
    {
        var text = ReadString(element, label, name);
        // Strict canonical UTC form only — exactly what Iso emits. The standard "o" parser treats the zone (K) as optional and can
        // re-interpret a zone-less value through the host time zone, so a round-trip comparison against Iso(parsed) is required: it
        // forces the trailing Z, the seven-digit precision and the calendar, and refuses any value the host zone could have shifted.
        if (!DateTimeOffset.TryParseExact(text, "o", CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var parsed) || Iso(parsed) != text)
        {
            throw new InvalidDataException($"« {label}.{name} » n’est pas un horodatage ISO 8601 UTC à la forme « o ».");
        }
        return parsed;
    }

    private static void RequireExpected(string value, string name)
    {
        ArgumentNullException.ThrowIfNull(value, name);
        if (value.Length == 0) { throw new ArgumentException("La valeur attendue ne peut être vide.", name); }
    }

    private static string Iso(DateTimeOffset value) => value.UtcDateTime.ToString("o", CultureInfo.InvariantCulture);

    private static bool IsSha256Hex(string? value) =>
        value is { Length: 64 } && value.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f'));

    private static bool ContainsControl(string value) => value.Any(c => c < '\u0020' || c == '\u007F');

    /// <summary>Lexical only, never touching the disk: a canonical ordinary Windows file path — a fully qualified local file
    /// (« C:\dir\file ») or an explicit UNC share (« \\server\share\file »). Bounded, free of NUL/control, of the device namespaces
    /// (« \\?\ », « \\.\ »), of root-only or share-only forms, and of every ambiguity the shared reader refuses: dot/dotdot, empty,
    /// trailing dot or space, forbidden characters and DOS-reserved device names (superscript COM/LPT too). Nothing is normalized to
    /// become acceptable; the final physical qualification belongs to the future journal, not to this pure codec.</summary>
    private static bool IsCanonicalWindowsFilePath(string? path)
    {
        if (string.IsNullOrEmpty(path) || path.Length > MaxPathLength || ContainsControl(path)) { return false; }
        if (path.StartsWith(@"\\?\", StringComparison.Ordinal) || path.StartsWith(@"\\.\", StringComparison.Ordinal)) { return false; }
        if (path.StartsWith(@"\\", StringComparison.Ordinal))
        {
            var tail = path.AsSpan(2);
            if (tail.IsEmpty || tail[0] == '\\') { return false; }
            var serverEnd = tail.IndexOf('\\');
            if (serverEnd < 0) { return false; }
            if (!QualifiedComponent(tail[..serverEnd].ToString())) { return false; }
            var shareTail = tail[(serverEnd + 1)..];
            var shareEnd = shareTail.IndexOf('\\');
            var share = (shareEnd < 0 ? shareTail : shareTail[..shareEnd]).ToString();
            if (!QualifiedComponent(share)) { return false; }
            if (shareEnd < 0) { return false; }
            var remainder = shareTail[(shareEnd + 1)..].ToString();
            if (remainder.Length == 0) { return false; }
            return remainder.Split('\\').All(component => QualifiedComponent(component));
        }
        if (path.Length >= 3 && char.IsAsciiLetter(path[0]) && path[1] == ':' && path[2] == '\\')
        {
            var remainder = path[3..];
            if (remainder.Length == 0) { return false; }
            return remainder.Split('\\').All(component => QualifiedComponent(component));
        }
        return false;
    }

    /// <summary>Lexical only, never touching the disk: a canonical local Windows file path (« C:\dir\file »), the same ordinary-component
    /// rules as the shared reader but restricted to a local drive (no UNC, no device namespace, no alternate data stream).</summary>
    private static bool IsCanonicalLocalBackupPath(string? path)
    {
        if (string.IsNullOrEmpty(path) || path.Length > MaxPathLength || ContainsControl(path)) { return false; }
        if (path.Contains('/', StringComparison.Ordinal)) { return false; }
        if (!(path.Length >= 4 && char.IsAsciiLetter(path[0]) && path[1] == ':' && path[2] == '\\')) { return false; }
        if (path.IndexOf(':', 2) >= 0) { return false; }
        var remainder = path[3..];
        if (remainder.Length == 0) { return false; }
        return remainder.Split('\\').All(component => QualifiedComponent(component));
    }

    /// <summary>One ordinary path component: never empty, never dot/dotdot, no trailing dot or space, no forbidden character, no
    /// DOS-reserved device name (COM/LPT with superscripts U+00B9/²/³ included; the U+2081/²/³ subscripts stay ordinary characters).</summary>
    private static bool QualifiedComponent(ReadOnlySpan<char> name)
    {
        if (name.IsEmpty) { return false; }
        if (name.SequenceEqual(".".AsSpan()) || name.SequenceEqual("..".AsSpan())) { return false; }
        if (name[^1] is '.' or ' ') { return false; }
        if (name.IndexOfAny(InvalidFileChars) >= 0) { return false; }
        var dot = name.IndexOf('.');
        var stem = (dot < 0 ? name : name[..dot]).ToString();
        return !Array.Exists(ReservedDeviceNames, r => string.Equals(r, stem, StringComparison.OrdinalIgnoreCase));
    }
}
