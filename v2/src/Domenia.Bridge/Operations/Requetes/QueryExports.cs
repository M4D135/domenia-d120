using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Wmi;

namespace Domenia.Bridge.Operations.Requetes;

/// <summary>
/// An export prepared by the engine and kept for 30 minutes under a token: the page receives its facts and a preview, never
/// the whole content; saving writes exactly what was prepared (counted again), copying asks for the content explicitly.
/// </summary>
internal sealed class PreparedExport
{
    public required string Token { get; init; }

    /// <summary>« results », « pack » or « script ».</summary>
    public required string Kind { get; init; }

    public required string FileName { get; init; }

    public required string Content { get; init; }

    public string? Metadata { get; init; }

    public required int Rows { get; init; }

    public required string Sha256 { get; init; }

    public required DateTimeOffset At { get; init; }

    public string? PackId { get; init; }

    public string? PackName { get; init; }

    public long PackVersion { get; init; }

    /// <summary>Paths written by the save, once: a token is saved at most once (a second save would duplicate the file).</summary>
    public string? SavedPath { get; set; }

    public string? SavedMetadataPath { get; set; }
}

/// <summary>Prepared exports and pack uploads of the session (memory only, bounded).</summary>
internal sealed class QueryExportStore
{
    private const int MaxExports = 8;
    private const long MaxChars = 64L * 1024 * 1024;
    private static readonly TimeSpan Life = TimeSpan.FromMinutes(30);
    private static readonly TimeSpan UploadLife = TimeSpan.FromMinutes(10);
    private readonly Lock gate = new();
    private readonly LinkedList<PreparedExport> exports = new();
    private readonly Dictionary<string, (StringBuilder Text, int Next, int Count, DateTimeOffset At)> uploads = new(StringComparer.Ordinal);
    private readonly TimeProvider clock;

    private QueryExportStore(TimeProvider clock) => this.clock = clock;

    public static QueryExportStore From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new QueryExportStore(c.Clock));
    }

    public PreparedExport Keep(PreparedExport export)
    {
        lock (gate)
        {
            var now = clock.GetUtcNow();
            exports.AddFirst(export);
            var node = exports.Last;
            long chars = 0;
            foreach (var item in exports)
            {
                chars += item.Content.Length + (item.Metadata?.Length ?? 0);
            }
            while (node is not null && node != exports.First && (exports.Count > MaxExports || chars > MaxChars || now - node.Value.At > Life))
            {
                var previous = node.Previous;
                chars -= node.Value.Content.Length + (node.Value.Metadata?.Length ?? 0);
                exports.Remove(node);
                node = previous;
            }
            return export;
        }
    }

    public PreparedExport Require(string token)
    {
        lock (gate)
        {
            var export = exports.FirstOrDefault(e => e.Token == token);
            if (export is null || clock.GetUtcNow() - export.At > Life)
            {
                throw new DomeniaOperationException(QueryErrors.ExportUnavailable, "Export introuvable ou expiré (30 minutes) : préparez-le de nouveau. Rien n’a été écrit.");
            }
            return export;
        }
    }

    /// <summary>
    /// One part of a pack sent by the page (the bridge refuses messages over 1 Mo): parts arrive in order, the text is kept in
    /// memory for 10 minutes, 16 Mio at most, then examined once.
    /// </summary>
    public (string Upload, int Received, long Chars) Part(string? upload, int index, int count, string text)
    {
        lock (gate)
        {
            var now = clock.GetUtcNow();
            foreach (var key in uploads.Where(u => now - u.Value.At > UploadLife).Select(u => u.Key).ToList())
            {
                uploads.Remove(key);
            }
            if (index == 0)
            {
                if (uploads.Count >= 4)
                {
                    uploads.Remove(uploads.OrderBy(u => u.Value.At).First().Key);
                }
                upload = QueryWorkshop.NewId();
                uploads[upload] = (new StringBuilder(text.Length * Math.Max(1, count)), 0, count, now);
            }
            if (upload is null || !uploads.TryGetValue(upload, out var state) || state.Next != index || state.Count != count)
            {
                throw new DomeniaOperationException(QueryErrors.PackInvalid, "Envoi du pack interrompu ou dans le désordre : choisissez de nouveau le fichier. Rien n’a été importé.");
            }
            if (state.Text.Length + (long)text.Length > QueryLibrary.MaxDocumentBytes)
            {
                uploads.Remove(upload);
                throw new DomeniaOperationException(QueryErrors.PackInvalid, "Pack de plus de 16 Mio : rien n’a été importé.");
            }
            state.Text.Append(text);
            uploads[upload] = (state.Text, index + 1, count, now);
            return (upload, index + 1, state.Text.Length);
        }
    }

    /// <summary>The whole text of a complete upload, once (the upload is forgotten).</summary>
    public string TakeUpload(string upload)
    {
        lock (gate)
        {
            if (!uploads.Remove(upload, out var state) || state.Next != state.Count)
            {
                throw new DomeniaOperationException(QueryErrors.PackInvalid, "Envoi du pack incomplet ou expiré : choisissez de nouveau le fichier. Rien n’a été importé.");
            }
            return state.Text.ToString();
        }
    }
}

/// <summary>
/// Exports of a frozen preview (Domenia 1 Start-DomeniaQueryExport): every object of one verdict, as CSV (« ; », formulas
/// neutralised, secret columns masked and counted) or JSON (typed values, states and source dates, readable by the exported
/// PowerShell script), with a metadata document (population, definition, clocks, fingerprint, recomputation). Saving writes
/// the prepared file and its metadata together into the Exports folder of the Domenia data (temporary files, then unique
/// names), after counting the rows again; in capture and E2E modes nothing is written.
/// </summary>
internal static class QueryExports
{
    private static readonly SemaphoreSlim OneAtATime = new(1, 1);
    private static readonly JsonSerializerOptions Indented = new() { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
    private static readonly JsonSerializerOptions IndentedCamel = new()
    {
        WriteIndented = true,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    /// <summary>Preview of a prepared content given to the page (the whole content stays in the engine).</summary>
    public const int PreviewLength = 6000;

    private static object? Typed(object? value) => value switch
    {
        decimal d => Math.Round(d, 6),
        bool or string => value,
        null => null,
        _ => Convert.ToString(value, CultureInfo.InvariantCulture),
    };

    /// <summary>A column holding a secret is never exported (none of the catalog informations is one; kept as a guard).</summary>
    private static bool Secret(QueryColumnView column, QueryField? field) =>
        WqlRules.IsSecret(column.Id) || field?.Property is { } property && WqlRules.IsSecret(property) || field?.LdapAttribute is { } attribute && WqlRules.IsSecret(attribute);

    public static object Results(EngineContext context, QueryEvaluation evaluation, string verdict, string format, DateTimeOffset now, bool stale)
    {
        var query = evaluation.Query;
        var columns = RequetesViews.Columns(query);
        var rows = new List<(QueryRecord Record, MatchState Verdict)>();
        for (var i = 0; i < evaluation.Population.Length; i++)
        {
            if (verdict == "all" || QueryTexts.VerdictKey(evaluation.Verdicts[i]) == verdict)
            {
                rows.Add((evaluation.Population[i], evaluation.Verdicts[i]));
            }
        }
        if (rows.Count > QueryLimits.MaxExportRows)
        {
            throw new DomeniaOperationException(QueryErrors.ExportTooLarge, "Plus de 200 000 lignes : réduisez le périmètre ou choisissez un verdict. Aucun fichier préparé.");
        }
        var expected = verdict switch
        {
            "match" => evaluation.Matched,
            "unknown" => evaluation.Unknown,
            "noMatch" => evaluation.NotMatched,
            _ => evaluation.Population.Length,
        };
        if (expected != rows.Count)
        {
            throw new DomeniaOperationException(QueryErrors.ExportTooLarge, "Le nombre de lignes ne correspond pas à l’aperçu : aucun fichier préparé. Relancez l’aperçu.");
        }
        var fields = columns.ToDictionary(c => c.Id, c => QueryCatalog.Find(query.Target, c.Id, query.Resolved.ReadDefinition), StringComparer.Ordinal);
        var secret = columns.Where(c => Secret(c, fields[c.Id])).Select(c => c.Id).ToHashSet(StringComparer.Ordinal);
        var masked = 0;
        string content;
        string mime;
        if (format == "json")
        {
            var list = rows.Select(r => new
            {
                id = r.Record.Id,
                name = r.Record.Name,
                dn = r.Record.Dn,
                verdict = QueryTexts.VerdictKey(r.Verdict),
                active = r.Record.Active,
                values = columns.Where(c => !secret.Contains(c.Id)).ToDictionary(c => c.Id, c => r.Record.Values.TryGetValue(c.Id, out var v) ? Typed(v) : null),
                states = query.RequestedFields.ToDictionary(f => f, f => r.Record.State(f), StringComparer.Ordinal),
                clocks = query.Clocks.Where(r.Record.Clocks.ContainsKey).ToDictionary(c => c, c => r.Record.Clocks[c].UtcDateTime.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture), StringComparer.Ordinal),
            }).ToList();
            masked = secret.Count * rows.Count;
            content = JsonSerializer.Serialize(list, Indented);
            mime = "application/json";
        }
        else
        {
            var builder = new StringBuilder();
            builder.Append(string.Join(";", new[] { "Verdict", "Nom", "Chemin AD", "État du compte" }.Concat(columns.Select(c => c.Label)).Select(Cell))).Append("\r\n");
            foreach (var (record, state) in rows)
            {
                var cells = new List<string>
                {
                    state switch { MatchState.Match => "Correspond", MatchState.NoMatch => "Ne correspond pas", _ => "Inconnu" },
                    record.Name,
                    record.Dn,
                    record.Active switch { true => "Actif", false => "Désactivé", _ => "État inconnu" },
                };
                foreach (var column in columns)
                {
                    if (secret.Contains(column.Id))
                    {
                        masked++;
                        cells.Add("••••");
                        continue;
                    }
                    cells.Add(record.Values.TryGetValue(column.Id, out var v) ? QueryFormat.Raw(v, fields[column.Id]) : "");
                }
                builder.Append(string.Join(";", cells.Select(Cell))).Append("\r\n");
            }
            content = builder.ToString();
            mime = "text/csv";
        }
        var clocks = query.Clocks.Select(clock =>
        {
            var dates = rows.Select(r => r.Record.Clocks.TryGetValue(clock, out var at) ? at : (DateTimeOffset?)null).OfType<DateTimeOffset>().ToList();
            return new { clock, source = QueryCatalog.ClockLabel(clock), dated = dates.Count, oldest = dates.Count > 0 ? dates.Min() : (DateTimeOffset?)null, newest = dates.Count > 0 ? dates.Max() : (DateTimeOffset?)null };
        }).ToArray();
        var hash = QueryRecipeJson.Sha256(content);
        var stamp = now.UtcDateTime.ToString("yyyyMMdd'-'HHmm", CultureInfo.InvariantCulture);
        var fileName = "Domenia-requete-" + WindowsRelease.Slug(query.Normalized.Name) + "-" + verdict.ToLowerInvariant() + "-" + stamp + (format == "json" ? ".json" : ".csv");
        var recomputed = stale ? "Les données locales ont changé depuis l’aperçu figé : ce fichier garde les valeurs de l’aperçu ; relancez l’aperçu pour un export à jour." : null;
        using var definition = JsonDocument.Parse(QueryRecipeJson.Write(query.Normalized));
        var metadata = JsonSerializer.Serialize(new
        {
            format = "domenia.queryExport",
            version = 2,
            exportedAt = now.UtcDateTime.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture),
            population = evaluation.Description,
            verdict,
            rows = rows.Count,
            fileName,
            fingerprint = query.Fingerprint,
            definition = definition.RootElement,
            clocks,
            secretsMasked = masked,
            sha256 = hash,
            recomputedSince = recomputed,
            note = "Données lues au moment de l’aperçu figé ; les valeurs inconnues ne sont jamais remplacées par zéro.",
        }, IndentedCamel);
        var export = QueryExportStore.From(context).Keep(new PreparedExport
        {
            Token = QueryWorkshop.NewId(),
            Kind = "results",
            FileName = fileName,
            Content = content,
            Metadata = metadata,
            Rows = rows.Count,
            Sha256 = hash,
            At = now,
        });
        var label = verdict switch { "match" => "correspondants", "unknown" => "inconnus", "noMatch" => "non correspondants", _ => "objets" };
        return new
        {
            token = export.Token,
            kind = export.Kind,
            fileName,
            metadataFileName = MetadataName(fileName),
            mime,
            rows = rows.Count,
            bytes = Encoding.UTF8.GetByteCount(content),
            secretsMasked = masked,
            sha256 = hash,
            preview = content.Length > PreviewLength ? content[..PreviewLength] : content,
            truncated = content.Length > PreviewLength,
            recomputed,
            text = FrenchText.Count(rows.Count, "ligne", "lignes") + " (" + label + ") préparées depuis l’aperçu figé du " + QueryFormat.LocalDate(evaluation.Description.EvaluatedAt, TimeZoneInfo.Utc) + " UTC.",
        };
    }

    /// <summary>A pack or a script kept under a token, like the results.</summary>
    public static object Prepare(EngineContext context, string kind, string fileName, string content, int rows, string mime, string text, QueryPackExport? pack = null, string? packName = null)
    {
        var hash = QueryRecipeJson.Sha256(content);
        var export = QueryExportStore.From(context).Keep(new PreparedExport
        {
            Token = QueryWorkshop.NewId(),
            Kind = kind,
            FileName = fileName,
            Content = content,
            Rows = rows,
            Sha256 = hash,
            At = context.Clock.GetUtcNow(),
            PackId = pack?.PackId,
            PackName = packName,
            PackVersion = pack?.Version ?? 0,
        });
        return new
        {
            token = export.Token,
            kind,
            fileName,
            mime,
            rows,
            count = kind == "pack" ? rows : (int?)null,
            version = pack?.Version,
            nextVersion = pack?.NextVersion,
            bytes = Encoding.UTF8.GetByteCount(content),
            sha256 = hash,
            preview = content.Length > PreviewLength ? content[..PreviewLength] : content,
            truncated = content.Length > PreviewLength,
            content = kind == "script" ? content : null,
            text,
        };
    }

    public static object Content(EngineContext context, string token)
    {
        var export = QueryExportStore.From(context).Require(token);
        return new { content = export.Content, metadata = export.Metadata, fileName = export.FileName };
    }

    private static string MetadataName(string fileName) => Path.ChangeExtension(fileName, ".metadata.json");

    /// <summary>CSV cell: « ; » separator, quotes doubled, formulas (= + - @) neutralised.</summary>
    public static string Cell(string? value)
    {
        var text = value ?? "";
        if (text.Length > 0 && text[0] is '=' or '+' or '-' or '@' or '\t' or '\r')
        {
            text = "'" + text;
        }
        return text.IndexOfAny([';', '"', '\n', '\r']) >= 0 ? "\"" + text.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"" : text;
    }

    /// <summary>Records of a CSV text (quoted line breaks included), header excluded.</summary>
    public static int CsvRecords(string content)
    {
        ArgumentNullException.ThrowIfNull(content);
        var records = 0;
        var quoted = false;
        var any = false;
        for (var i = 0; i < content.Length; i++)
        {
            var c = content[i];
            if (c == '"')
            {
                quoted = !quoted;
            }
            else if (c == '\n' && !quoted)
            {
                records++;
                any = false;
                continue;
            }
            if (c != '\r')
            {
                any = true;
            }
        }
        if (any)
        {
            records++;
        }
        return Math.Max(0, records - 1);
    }

    /// <summary>Rows of a prepared content counted again from the text itself (never trusted from the preparation alone).</summary>
    private static int Count(PreparedExport export)
    {
        if (export.Kind == "script")
        {
            return export.Rows;
        }
        if (export.FileName.EndsWith(".csv", StringComparison.Ordinal))
        {
            return CsvRecords(export.Content);
        }
        using var document = JsonDocument.Parse(export.Content, new JsonDocumentOptions { MaxDepth = 96 });
        var root = document.RootElement;
        if (root.ValueKind == JsonValueKind.Array)
        {
            return root.GetArrayLength();
        }
        return root.TryGetProperty("Recipes", out var recipes) && recipes.ValueKind == JsonValueKind.Array ? recipes.GetArrayLength() : -1;
    }

    /// <summary>
    /// Writes a prepared export (and its metadata) into the Exports folder: rows counted again and fingerprint checked against
    /// the preparation, temporary files of the same folder, unique names (a collision takes the next index), the metadata
    /// named after the file actually written. A token is saved once. Refused when the preferences are not persistent.
    /// </summary>
    public static async Task<object> SaveAsync(EngineContext context, string token, bool includeMetadata, CancellationToken cancellationToken)
    {
        if (!context.Preferences.Persistent)
        {
            throw new DomeniaOperationException(QueryErrors.ExportUnavailable, "Aucun fichier écrit dans ce mode (capture, E2E ou sans dossier de données) : copiez le contenu à la place.");
        }
        var export = QueryExportStore.From(context).Require(token);
        var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolderOption.Create);
        if (!Path.IsPathFullyQualified(root))
        {
            throw new DomeniaOperationException(QueryErrors.ExportUnavailable, "Dossier de données introuvable : copiez le contenu à la place.");
        }
        await OneAtATime.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (export.SavedPath is { } already)
            {
                throw new DomeniaOperationException(QueryErrors.ExportUnavailable, "Cet export est déjà enregistré (" + Path.GetFileName(already) + ") : préparez-en un nouveau pour un autre fichier.");
            }
            if (QueryRecipeJson.Sha256(export.Content) != export.Sha256 || Count(export) != export.Rows)
            {
                throw new DomeniaOperationException(QueryErrors.ExportTooLarge, "Le contenu ne correspond plus à sa préparation (nombre de lignes ou empreinte) : aucun fichier écrit. Préparez l’export de nouveau.");
            }
            var folder = Path.Combine(root, "Domenia", "Exports");
            var fileName = export.FileName;
            if (context.Mode == AppMode.Simulation)
            {
                fileName = Path.GetFileNameWithoutExtension(fileName) + "-simulation" + Path.GetExtension(fileName);
            }
            var bom = fileName.EndsWith(".csv", StringComparison.Ordinal) || fileName.EndsWith(".ps1", StringComparison.Ordinal);
            var bytes = Encode(export.Content, bom);
            Directory.CreateDirectory(folder);
            var written = WriteUnique(folder, fileName, bytes);
            string? metadataPath = null;
            if (includeMetadata && export.Metadata is { } metadata)
            {
                try
                {
                    metadataPath = WriteUnique(folder, MetadataName(Path.GetFileName(written)), Encode(metadata, false), exact: true);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    // The two files go together: without its metadata, the export is withdrawn.
                    TryDelete(context, written);
                    throw;
                }
            }
            export.SavedPath = written;
            export.SavedMetadataPath = metadataPath;
            context.Journal.Add(new JournalEntry(context.Clock.GetUtcNow(), "Requêtes" + FrenchText.Colon + "export enregistré (" + Path.GetFileName(written) + (metadataPath is null ? "" : " et ses métadonnées") + ")", Tone.Ok));
            return new { path = written, fileName = Path.GetFileName(written), metadataPath, bytes = bytes.Length, rows = export.Rows, kind = export.Kind };
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            context.Log.Warning($"Export de requête non enregistré : {ex.GetType().Name}.");
            throw new DomeniaOperationException(QueryErrors.ExportUnavailable, "Le fichier n’a pas pu être écrit (disque plein ou droits) : copiez le contenu à la place. Rien n’a été laissé dans le dossier.");
        }
        finally
        {
            OneAtATime.Release();
        }
    }

    private static byte[] Encode(string content, bool bom) => [.. (bom ? Encoding.UTF8.GetPreamble() : []), .. new UTF8Encoding(false).GetBytes(content)];

    /// <summary>Writes a temporary file then moves it to a free name (« -2 », « -3 »… on collision, even a concurrent one).</summary>
    private static string WriteUnique(string folder, string fileName, byte[] bytes, bool exact = false)
    {
        var temporary = Path.Combine(folder, fileName + "." + Environment.ProcessId.ToString(CultureInfo.InvariantCulture) + "." + QueryWorkshop.NewId()[..8] + ".tmp");
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            for (var index = 1; index <= 1000; index++)
            {
                var target = Path.Combine(folder, index == 1 ? fileName : Path.GetFileNameWithoutExtension(fileName) + "-" + index.ToString(CultureInfo.InvariantCulture) + Path.GetExtension(fileName));
                if (File.Exists(target))
                {
                    if (exact)
                    {
                        throw new IOException("The metadata file name is already taken.");
                    }
                    continue;
                }
                try
                {
                    File.Move(temporary, target, overwrite: false);
                    return target;
                }
                catch (IOException) when (File.Exists(target) && !exact)
                {
                    // Taken between the check and the move (another export): next index.
                }
            }
            throw new IOException("No free export file name.");
        }
        finally
        {
            if (File.Exists(temporary))
            {
                File.Delete(temporary);
            }
        }
    }

    private static void TryDelete(EngineContext context, string file)
    {
        try
        {
            File.Delete(file);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            context.Log.Warning($"Export sans métadonnées non retiré ({ex.GetType().Name}).");
        }
    }
}
