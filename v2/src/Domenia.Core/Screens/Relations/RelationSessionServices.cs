using System.Collections.Concurrent;
using System.Text;

namespace Domenia.Core;

/// <summary>
/// Stop requests of the running probes of the relations screen (« Arrêter la détection », Domenia 1 REL-023): one token per
/// confirmed plan, cancelled on request. A stop is a request, not a confirmed cancellation: the probe ends after the workstation
/// it is reading, declares a partial result and keeps every saved association. Shared service of the context.
/// </summary>
public sealed class RelationProbeControl : IDisposable
{
    private readonly ConcurrentDictionary<string, CancellationTokenSource> running = new(StringComparer.Ordinal);

    /// <summary>The probe control shared by every module of the context.</summary>
    public static RelationProbeControl From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static _ => new RelationProbeControl());
    }

    /// <summary>Registers a running probe and returns its stop token source (null when the plan already runs).</summary>
    public CancellationTokenSource? Start(string planId)
    {
        ArgumentNullException.ThrowIfNull(planId);
        var source = new CancellationTokenSource();
        if (running.TryAdd(planId, source))
        {
            return source;
        }
        source.Dispose();
        return null;
    }

    /// <summary>Asks a running probe to stop; false when no probe of this plan runs.</summary>
    public bool Stop(string planId)
    {
        ArgumentNullException.ThrowIfNull(planId);
        if (!running.TryGetValue(planId, out var source))
        {
            return false;
        }
        try
        {
            source.Cancel();
            return true;
        }
        catch (ObjectDisposedException)
        {
            return false;
        }
    }

    public void Finish(string planId, CancellationTokenSource source)
    {
        ArgumentNullException.ThrowIfNull(planId);
        ArgumentNullException.ThrowIfNull(source);
        running.TryRemove(new KeyValuePair<string, CancellationTokenSource>(planId, source));
        source.Dispose();
    }

    public void Dispose()
    {
        foreach (var source in running.Values)
        {
            source.Dispose();
        }
        running.Clear();
    }
}

/// <summary>
/// Text of an import file chosen by the operator, received from the page in parts (a bridge message is 1 Mo at most) and kept in
/// memory only until its preview: never written to disk, dropped after 10 minutes or once read. Bounded: 8 Mio characters per
/// file, 4 files at a time (Domenia 1: CSV of 8 Mio, JSON of 2 Mio). Shared service of the context.
/// </summary>
public sealed class RelationImportStaging
{
    public const int MaxParts = 64;
    public const int MaxPartCharacters = 600_000;
    public const int MaxFiles = 4;

    private static readonly TimeSpan Lifetime = TimeSpan.FromMinutes(10);

    private readonly TimeProvider clock;
    private readonly Lock gate = new();
    private readonly Dictionary<string, Staged> files = new(StringComparer.Ordinal);

    public RelationImportStaging(TimeProvider clock)
    {
        ArgumentNullException.ThrowIfNull(clock);
        this.clock = clock;
    }

    /// <summary>The staging shared by every module of the context.</summary>
    public static RelationImportStaging From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new RelationImportStaging(c.Clock));
    }

    /// <summary>Keeps one part; a part sent twice replaces the first one. Refuses a file larger than the largest adapter.</summary>
    public RelationImportStaged Add(string id, int part, int parts, string text)
    {
        ArgumentNullException.ThrowIfNull(id);
        ArgumentNullException.ThrowIfNull(text);
        var now = clock.GetUtcNow();
        lock (gate)
        {
            foreach (var expired in files.Where(f => now - f.Value.Created > Lifetime).Select(f => f.Key).ToList())
            {
                files.Remove(expired);
            }
            if (!files.TryGetValue(id, out var staged) || staged.Parts.Length != parts)
            {
                while (files.Count >= MaxFiles)
                {
                    files.Remove(files.MinBy(f => f.Value.Created).Key);
                }
                staged = new Staged(new string?[parts], now);
                files[id] = staged;
            }
            staged.Parts[part] = text;
            var characters = staged.Parts.Sum(p => p?.Length ?? 0);
            if (characters > RelationImport.MaxCsvCharacters)
            {
                files.Remove(id);
                throw new DomeniaOperationException(RelationErrors.ImportTooLarge, "Fichier trop volumineux pour un aperçu" + FrenchText.Colon + "plus de "
                    + FrenchText.Integer(RelationImport.MaxCsvCharacters) + " caractères (8 Mio). Découpez le fichier ou filtrez l’export ; rien n’a été lu.");
            }
            var received = staged.Parts.Count(p => p is not null);
            return new RelationImportStaged(id, received, parts, characters, received == parts);
        }
    }

    /// <summary>The whole text of a staged file, removed from memory; relation.importIncomplete when a part is missing.</summary>
    public string Take(string id)
    {
        ArgumentNullException.ThrowIfNull(id);
        lock (gate)
        {
            if (!files.TryGetValue(id, out var staged) || staged.Parts.Any(p => p is null) || clock.GetUtcNow() - staged.Created > Lifetime)
            {
                throw new DomeniaOperationException(RelationErrors.ImportIncomplete, RelationErrors.ImportIncompleteMessage);
            }
            files.Remove(id);
            var builder = new StringBuilder(staged.Parts.Sum(p => p!.Length));
            foreach (var part in staged.Parts)
            {
                builder.Append(part);
            }
            return builder.ToString();
        }
    }

    private sealed record Staged(string?[] Parts, DateTimeOffset Created);
}
