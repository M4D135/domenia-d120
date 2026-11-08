using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>Answer of relations.export.save: parts received and, with the last one, the document written (or kept in memory).</summary>
public sealed record RelationExportAnswer(string Id, int Received, int Parts, bool Complete, RelationExportResult? Result);

/// <summary>A CSV of the associations written by « Exporter » (Domenia 1 Export-DomeniaLinksCsv, Get-LinkCsvPath).</summary>
public sealed record RelationExportResult(bool Saved, string FileName, string? Folder, int Rows, int Bytes, string Sha256, string Message, DateTimeOffset At);

/// <summary>Answer of relations.export.open (« Ouvrir le CSV », Domenia 1 BtnOpenLinksCsv).</summary>
public sealed record RelationExportOpened(bool Opened, string Message);

/// <summary>
/// CSV exports of the relations screen (docs/ops/relations.md § 2): the page builds the CSV with the kit (visible columns,
/// formulas neutralised, secret columns left out) and sends it in parts, because a bridge message is 1 Mo at most. Once complete,
/// the document is written in %LOCALAPPDATA%\Domenia\Exports (Exports-simulation in simulation, never shared), dated, never
/// overwritten (« -2 », « -3 »…), through a temporary file of the same folder then renamed (no half document under its final
/// name); a link in place of the folder is refused. Where the receipts of the mode live in memory (capture, E2E, no data folder),
/// nothing is written and the result says so. « Ouvrir le CSV » opens only a document written by this session. Shared service.
/// </summary>
public sealed class RelationExports
{
    public const int MaxParts = 64;
    public const int MaxPartCharacters = 600_000;
    public const int MaxDocumentBytes = 16 * 1024 * 1024;
    public const string ExportFailed = "relations.exportFailed";
    public const string ExportTooLarge = "relations.exportTooLarge";

    /// <summary>Lists that can be exported, in the names of the files (Domenia-Relations-<sujet>-AAAAMMJJ-HHmmss.csv).</summary>
    public static readonly IReadOnlyList<string> Subjects = ["toutes", "sujet", "selection", "moisson", "orphelines", "import"];

    private static readonly TimeSpan Lifetime = TimeSpan.FromMinutes(10);
    private static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false);

    private readonly EngineContext context;
    private readonly Lock gate = new();
    private readonly Dictionary<string, (string?[] Parts, string Subject, DateTimeOffset Created)> staged = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, string> written = new(StringComparer.OrdinalIgnoreCase);

    private RelationExports(EngineContext context)
    {
        this.context = context;
        var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolderOption.DoNotVerify);
        Folder = context.Receipts.Persistent && Path.IsPathFullyQualified(root)
            ? Path.Combine(root, ProductInfo.Name, context.Mode == AppMode.Simulation ? "Exports-simulation" : "Exports")
            : null;
    }

    /// <summary>The exports shared by every module of the context.</summary>
    public static RelationExports From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new RelationExports(c));
    }

    /// <summary>Folder of the documents; null when nothing may be written in this mode.</summary>
    public string? Folder { get; }

    /// <summary>Keeps one part; with the last one, writes the whole document once.</summary>
    public async Task<RelationExportAnswer> AddAsync(string id, int part, int parts, string subject, string text, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(id);
        ArgumentNullException.ThrowIfNull(subject);
        ArgumentNullException.ThrowIfNull(text);
        var now = context.Clock.GetUtcNow();
        string? whole = null;
        int received;
        lock (gate)
        {
            foreach (var expired in staged.Where(f => now - f.Value.Created > Lifetime).Select(f => f.Key).ToList())
            {
                staged.Remove(expired);
            }
            if (!staged.TryGetValue(id, out var entry) || entry.Parts.Length != parts || entry.Subject != subject)
            {
                while (staged.Count >= 4)
                {
                    staged.Remove(staged.MinBy(f => f.Value.Created).Key);
                }
                entry = (new string?[parts], subject, now);
                staged[id] = entry;
            }
            entry.Parts[part] = text;
            if (entry.Parts.Sum(p => (long)(p?.Length ?? 0)) > MaxDocumentBytes)
            {
                staged.Remove(id);
                throw new DomeniaOperationException(ExportTooLarge, "Document trop volumineux (plus de 16 Mo)" + FrenchText.Colon + "rien n’a été écrit. Filtrez la liste puis exportez de nouveau.");
            }
            received = entry.Parts.Count(p => p is not null);
            if (received == parts)
            {
                staged.Remove(id);
                whole = string.Concat(entry.Parts);
            }
        }
        if (whole is null)
        {
            return new RelationExportAnswer(id, received, parts, false, null);
        }
        var result = await SaveAsync(subject, whole, cancellationToken).ConfigureAwait(false);
        return new RelationExportAnswer(id, received, parts, true, result);
    }

    /// <summary>Opens a document written by this session with the application Windows associates with CSV files.</summary>
    public RelationExportOpened Open(string fileName)
    {
        ArgumentNullException.ThrowIfNull(fileName);
        if (!written.TryGetValue(fileName, out var path))
        {
            return new RelationExportOpened(false, "Ce fichier n’a pas été exporté pendant cette session" + FrenchText.Colon + "rien n’a été ouvert.");
        }
        if (!File.Exists(path))
        {
            return new RelationExportOpened(false, "Fichier introuvable (déplacé ou supprimé depuis l’export)" + FrenchText.Colon + "rien n’a été ouvert.");
        }
        try
        {
            using var process = Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
            return new RelationExportOpened(true, "Ouverture de " + Path.GetFileName(path) + " avec l’application associée de Windows.");
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException or FileNotFoundException)
        {
            context.Log.Warning($"Relations : export non ouvert ({ex.GetType().Name}).");
            return new RelationExportOpened(false, "Aucune application ne peut ouvrir ce fichier" + FrenchText.Colon + "ouvrez le dossier des exports dans l’Explorateur.");
        }
    }

    private async Task<RelationExportResult> SaveAsync(string subject, string csv, CancellationToken cancellationToken)
    {
        var at = context.Clock.GetUtcNow();
        var body = csv.TrimStart('﻿');
        var rows = Math.Max(0, body.Split('\n').Count(line => line.Trim().Length > 0) - 1);
        var bytes = Utf8.GetBytes(body);
        byte[] data = [0xEF, 0xBB, 0xBF, .. bytes];
        var sha = Convert.ToHexStringLower(SHA256.HashData(data));
        var stamp = TimeZoneInfo.ConvertTime(at, context.Clock.LocalTimeZone).ToString("yyyyMMdd'-'HHmmss", CultureInfo.InvariantCulture);
        var name = "Domenia-Relations-" + subject + "-" + stamp + ".csv";
        if (data.Length > MaxDocumentBytes)
        {
            throw new DomeniaOperationException(ExportTooLarge, "Document trop volumineux (plus de 16 Mo)" + FrenchText.Colon + "rien n’a été écrit.");
        }
        if (Folder is null)
        {
            Journal("Export CSV préparé en mémoire, non écrit (" + FrenchText.Count(rows, "ligne", "lignes") + ")", Tone.Info);
            return new RelationExportResult(false, name, null, rows, data.Length, sha,
                "CSV préparé, non écrit" + FrenchText.Colon + "ce mode (capture, E2E ou sans dossier de données) garde tout en mémoire.", at);
        }
        var temporary = "";
        try
        {
            var info = new DirectoryInfo(Folder);
            if (info.Exists && info.Attributes.HasFlag(FileAttributes.ReparsePoint))
            {
                throw new IOException("Exports folder is a link.");
            }
            info.Create();
            var target = Unique(name);
            temporary = Path.Combine(Folder, ".domenia-" + Guid.NewGuid().ToString("N") + ".tmp");
            await using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough | FileOptions.Asynchronous))
            {
                await stream.WriteAsync(data, cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
            }
            File.Move(temporary, target, overwrite: false);
            temporary = "";
            var file = Path.GetFileName(target);
            written[file] = target;
            Journal("Export CSV des associations" + FrenchText.Colon + file + " (" + FrenchText.Count(rows, "ligne", "lignes") + ")", Tone.Ok);
            return new RelationExportResult(true, file, Folder, rows, data.Length, sha, "CSV enregistré" + FrenchText.Colon + file + ", " + FrenchText.Count(rows, "ligne", "lignes") + ".", at);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            context.Log.Warning($"Relations : export non enregistré ({ex.GetType().Name}).");
            throw new DomeniaOperationException(ExportFailed, "CSV non enregistré" + FrenchText.Colon + Reason(ex) + " Rien n’a été remplacé.");
        }
        finally
        {
            if (temporary.Length > 0)
            {
                try
                {
                    File.Delete(temporary);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    context.Log.Warning($"Relations : fichier temporaire laissé ({ex.GetType().Name}).");
                }
            }
        }
    }

    private void Journal(string what, Tone tone) => context.Journal.Add(new JournalEntry(context.Clock.GetUtcNow(), what, tone));

    private string Unique(string name)
    {
        var extension = Path.GetExtension(name);
        var stem = Path.GetFileNameWithoutExtension(name);
        var candidate = Path.Combine(Folder!, name);
        for (var n = 2; File.Exists(candidate) || Directory.Exists(candidate); n++)
        {
            candidate = Path.Combine(Folder!, stem + "-" + n.ToString(CultureInfo.InvariantCulture) + extension);
        }
        return candidate;
    }

    private static string Reason(Exception ex) => ex switch
    {
        UnauthorizedAccessException => "accès refusé au dossier des exports.",
        IOException io when io.HResult is unchecked((int)0x80070070) or unchecked((int)0x80070027) => "disque plein.",
        _ => "dossier des exports indisponible (verrouillé, lien ou chemin non admis).",
    };
}
