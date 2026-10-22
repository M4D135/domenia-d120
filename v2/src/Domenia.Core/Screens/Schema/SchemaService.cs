using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>
/// The schema read in this session (Domenia 1 $script:DomeniaAdSchema): read once on an explicit gesture, kept in memory
/// with its controller and date, and used only for the domain it was read for (Get-DomeniaAdSchemaCatalogForAnalysis: a
/// schema of another session or domain never judges an index). One read at a time; a failed read keeps the previous schema.
/// Every other operation of the screen works on this catalog in memory, without any read.
/// </summary>
public sealed partial class SchemaService : IDisposable
{
    private readonly EngineContext context;
    private readonly SemaphoreSlim reading = new(1, 1);
    private readonly Lock gate = new();
    private SchemaCatalog? catalog;
    private string? lastError;

    private SchemaService(EngineContext context) => this.context = context;

    /// <summary>The single instance of the context.</summary>
    public static SchemaService From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new SchemaService(c));
    }

    [GeneratedRegex("^CN=Schema,CN=Configuration,DC=", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase)]
    private static partial Regex SchemaContextPattern();

    /// <summary>Status of the schema for the domain of the session (schema.status).</summary>
    public async Task<SchemaStatus> StatusAsync(CancellationToken cancellationToken)
    {
        var root = await RootAsync(cancellationToken).ConfigureAwait(false);
        return Status(For(root));
    }

    /// <summary>The catalog of this session for its domain, or null (never the schema of another domain).</summary>
    public async Task<SchemaCatalog?> CatalogAsync(CancellationToken cancellationToken)
    {
        var root = await RootAsync(cancellationToken).ConfigureAwait(false);
        return For(root);
    }

    /// <summary>The catalog, or schema.notRead.</summary>
    public async Task<SchemaCatalog> RequireCatalogAsync(CancellationToken cancellationToken) =>
        await CatalogAsync(cancellationToken).ConfigureAwait(false)
        ?? throw new DomeniaOperationException(SchemaErrors.NotRead, SchemaErrors.NotReadMessage);

    /// <summary>
    /// Reads the schema once (Start-DomeniaAdSchemaRead): never automatic, never a write; bounded to 8 000 attributes, 3 000
    /// classes and 90 seconds. A read for another domain or an unexpected schema context is refused; a failure keeps the schema
    /// read before.
    /// </summary>
    public async Task<SchemaStatus> ReadAsync(IProgress<SchemaReadStage>? progress, CancellationToken cancellationToken)
    {
        var reader = context.Readers.Require<ISchemaReader>();
        var root = await RootAsync(cancellationToken).ConfigureAwait(false)
            ?? throw new DomeniaOperationException(SchemaErrors.ReadFailed, "Connectez-vous à un domaine avant de lire son schéma.");
        await reading.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            SchemaReadResult result;
            try
            {
                result = await reader.ReadDefinitionsAsync(SchemaReadLimits.Default, progress, cancellationToken).ConfigureAwait(false);
            }
            catch (DomeniaOperationException ex) when (ex.Code != DomeniaErrors.SourceUnavailable)
            {
                throw Failed(root, ex.Message);
            }
            if (!DistinguishedName.AreEqual(result.DomainDn, root))
            {
                throw Failed(root, "schéma lu pour un autre domaine.");
            }
            if (!SchemaContextPattern().IsMatch(result.SchemaNamingContext))
            {
                throw Failed(root, "contexte de schéma inattendu, lecture refusée.");
            }
            var built = SchemaRules.BuildCatalog(result);
            lock (gate)
            {
                catalog = built;
                lastError = null;
            }
            context.Log.Info($"Schéma lu : {built.ClassCount} classes, {built.AttributeCount} attributs, {result.DurationMs} ms{(built.Truncated ? ", lecture tronquée" : "")}.");
            context.Journal.Add(new JournalEntry(context.Clock.GetUtcNow(),
                "Schéma lu sur " + built.Server + FrenchText.Colon + FrenchText.Count(built.ClassCount, "classe", "classes") + ", "
                + FrenchText.Count(built.AttributeCount, "attribut", "attributs") + (built.Truncated ? " (lecture incomplète)" : ""),
                built.Truncated ? Tone.Warn : Tone.Info));
            return Status(built);
        }
        finally
        {
            reading.Release();
        }
    }

    public void Dispose() => reading.Dispose();

    private DomeniaOperationException Failed(string root, string reason)
    {
        var text = "Lecture du schéma impossible" + FrenchText.Colon + reason.TrimEnd();
        if (!text.EndsWith('.'))
        {
            text += ".";
        }
        if (For(root) is not null)
        {
            text += " Le schéma lu précédemment reste affiché.";
        }
        lock (gate)
        {
            lastError = text;
        }
        context.Log.Warning("Lecture du schéma impossible (raison dans la page).");
        return new DomeniaOperationException(SchemaErrors.ReadFailed, text);
    }

    private SchemaCatalog? For(string? root)
    {
        lock (gate)
        {
            return catalog is not null && root is not null && DistinguishedName.AreEqual(catalog.DomainDn, root) ? catalog : null;
        }
    }

    private async Task<string?> RootAsync(CancellationToken cancellationToken)
    {
        var session = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        return session.Domain?.RootDn;
    }

    private SchemaStatus Status(SchemaCatalog? current)
    {
        string? error;
        lock (gate)
        {
            error = lastError;
        }
        var limits = new SchemaLimitsInfo(SchemaReadLimits.Default.MaxAttributes, SchemaReadLimits.Default.MaxClasses, (int)SchemaReadLimits.Default.Budget.TotalSeconds);
        var simulated = context.Directory.Kind == DirectorySourceKind.Simulation;
        var text = SchemaRules.StatusText(current, context.Clock.LocalTimeZone);
        if (current is null)
        {
            return new SchemaStatus(false, null, null, 0, 0, false, null, text, error is null ? Tone.Off : Tone.Alert, error, simulated, limits, null);
        }
        return new SchemaStatus(
            true, current.Server, current.ObservedAt, current.ClassCount, current.AttributeCount, current.Truncated, current.DurationMs, text,
            current.Truncated ? Tone.Warn : Tone.Ok, error, simulated, limits, SchemaRules.Statistics(current));
    }
}
