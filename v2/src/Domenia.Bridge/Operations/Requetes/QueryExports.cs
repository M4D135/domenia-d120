using System.Globalization;
using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Queries;

namespace Domenia.Bridge.Operations.Requetes;

/// <summary>
/// Exports of a frozen preview (Domenia 1 Start-DomeniaQueryExport): every object of one verdict, as CSV (« ; », formulas
/// neutralised) or JSON, with a metadata document (population, definition, clocks, fingerprint). Saving writes into the
/// Exports folder of the Domenia data (temporary file, then a unique name); in capture and E2E modes nothing is written.
/// </summary>
internal static class QueryExports
{
    private static readonly SemaphoreSlim OneAtATime = new(1, 1);

    public static object Results(QueryEvaluation evaluation, string verdict, string format, DateTimeOffset now)
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
            throw new DomeniaOperationException(QueryErrors.ExportTooLarge, "Plus de 200 000 lignes : réduisez le périmètre ou choisissez un verdict. Aucun fichier préparé.");
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
                values = columns.ToDictionary(c => c.Id, c => r.Record.Values.TryGetValue(c.Id, out var v) ? QueryFormat.Raw(v, QueryCatalog.Find(query.Target, c.Id, query.Resolved.ReadDefinition)) : null),
            });
            content = JsonSerializer.Serialize(list, new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
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
                cells.AddRange(columns.Select(c => record.Values.TryGetValue(c.Id, out var v) ? QueryFormat.Raw(v, QueryCatalog.Find(query.Target, c.Id, query.Resolved.ReadDefinition)) : ""));
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
        var metadata = JsonSerializer.Serialize(new
        {
            format = "domenia.queryExport",
            version = 1,
            exportedAt = now.UtcDateTime.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture),
            population = evaluation.Description,
            verdict,
            rows = rows.Count,
            fingerprint = query.Fingerprint,
            definition = JsonDocument.Parse(QueryRecipeJson.Write(query.Normalized)).RootElement,
            clocks,
            sha256 = hash,
            note = "Données lues au moment de l’aperçu figé ; les valeurs inconnues ne sont jamais remplacées par zéro.",
        }, new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping, PropertyNamingPolicy = JsonNamingPolicy.CamelCase });
        var stamp = now.UtcDateTime.ToString("yyyyMMdd'-'HHmm", CultureInfo.InvariantCulture);
        var fileName = "Domenia-requete-" + WindowsRelease.Slug(query.Normalized.Name) + "-" + verdict.ToLowerInvariant() + "-" + stamp + (format == "json" ? ".json" : ".csv");
        var label = verdict switch { "match" => "correspondants", "unknown" => "inconnus", "noMatch" => "non correspondants", _ => "objets" };
        return new
        {
            fileName,
            content,
            mime,
            metadata,
            metadataFileName = Path.ChangeExtension(fileName, ".metadata.json"),
            rows = rows.Count,
            secretsMasked = 0,
            sha256 = hash,
            text = FrenchText.Count(rows.Count, "ligne", "lignes") + " (" + label + ") préparées depuis l’aperçu figé du " + QueryFormat.LocalDate(evaluation.Description.EvaluatedAt, TimeZoneInfo.Utc) + " UTC.",
        };
    }

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

    public static async Task<object> SaveAsync(EngineContext context, string fileName, string content, CancellationToken cancellationToken)
    {
        if (!context.Preferences.Persistent)
        {
            throw new DomeniaOperationException(QueryErrors.ExportUnavailable, "Aucun fichier écrit dans ce mode (capture, E2E ou sans dossier de données) : copiez le contenu à la place.");
        }
        if (fileName.Length is < 5 or > 160 || fileName.Any(c => !(char.IsAsciiLetterOrDigit(c) || c is '.' or '-' or '_')) || fileName.StartsWith('.')
            || !(fileName.EndsWith(".csv", StringComparison.Ordinal) || fileName.EndsWith(".json", StringComparison.Ordinal) || fileName.EndsWith(".ps1", StringComparison.Ordinal) || fileName.EndsWith(".txt", StringComparison.Ordinal)))
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("fileName") + " doit être un nom de fichier simple (.csv, .json, .ps1 ou .txt).");
        }
        var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolderOption.Create);
        if (!Path.IsPathFullyQualified(root))
        {
            throw new DomeniaOperationException(QueryErrors.ExportUnavailable, "Dossier de données introuvable : copiez le contenu à la place.");
        }
        var folder = Path.Combine(root, "Domenia", "Exports");
        if (context.Mode == AppMode.Simulation)
        {
            fileName = Path.GetFileNameWithoutExtension(fileName) + "-simulation" + Path.GetExtension(fileName);
        }
        var bom = fileName.EndsWith(".csv", StringComparison.Ordinal) || fileName.EndsWith(".ps1", StringComparison.Ordinal);
        var bytes = (bom ? Encoding.UTF8.GetPreamble() : []).Concat(new UTF8Encoding(false).GetBytes(content)).ToArray();
        await OneAtATime.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            Directory.CreateDirectory(folder);
            var target = Path.Combine(folder, fileName);
            var index = 1;
            while (File.Exists(target))
            {
                index++;
                target = Path.Combine(folder, Path.GetFileNameWithoutExtension(fileName) + "-" + index.ToString(CultureInfo.InvariantCulture) + Path.GetExtension(fileName));
            }
            var temporary = target + "." + Environment.ProcessId.ToString(CultureInfo.InvariantCulture) + ".tmp";
            await using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            {
                await stream.WriteAsync(bytes, CancellationToken.None).ConfigureAwait(false);
                await stream.FlushAsync(CancellationToken.None).ConfigureAwait(false);
            }
            File.Move(temporary, target, overwrite: false);
            context.Journal.Add(new JournalEntry(context.Clock.GetUtcNow(), "Requêtes" + FrenchText.Colon + "export enregistré (" + Path.GetFileName(target) + ")", Tone.Ok));
            return new { path = target, fileName = Path.GetFileName(target), bytes = bytes.Length };
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            context.Log.Warning($"Export de requête non enregistré : {ex.GetType().Name}.");
            throw new DomeniaOperationException(QueryErrors.ExportUnavailable, "Le fichier n’a pas pu être écrit (disque plein ou droits) : copiez le contenu à la place.");
        }
        finally
        {
            OneAtATime.Release();
        }
    }
}
