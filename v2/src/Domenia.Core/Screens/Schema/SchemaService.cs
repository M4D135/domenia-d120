using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>
/// The schema read in this session (Domenia 1 $script:DomeniaAdSchema): read once on an explicit gesture, kept in memory
/// with its controller and date, and used only for the session and the domain it was read for
/// (Get-DomeniaAdSchemaCatalogForAnalysis compares SessionEpoch and the domain: a schema of another session or domain never
/// judges an index). One read at a time: a second one is refused while the first runs; the read is cut beyond its budget
/// (90 seconds for the reader, the operation stopped at 150 seconds like the Domenia 1 job); a failed read keeps the previous
/// schema. Every other operation of the screen works on this catalog in memory, without any read.
/// </summary>
public sealed partial class SchemaService : IDisposable
{
    private readonly EngineContext context;
    private readonly SemaphoreSlim reading = new(1, 1);
    private readonly Lock gate = new();
    private SchemaCatalog? catalog;
    private string? catalogSession;
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

    /// <summary>
    /// Hard stop of one read: its budget and two thirds more (90 s → 150 s, the Domenia 1 job), in case a reader overruns the
    /// budget it was given.
    /// </summary>
    public static TimeSpan HardLimit(SchemaReadLimits limits)
    {
        ArgumentNullException.ThrowIfNull(limits);
        return limits.Budget + (limits.Budget * 2 / 3);
    }

    /// <summary>Status of the schema for the session (schema.status).</summary>
    public async Task<SchemaStatus> StatusAsync(CancellationToken cancellationToken)
    {
        var session = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        return Status(For(session));
    }

    /// <summary>The catalog of this session for its domain, or null (never the schema of another session or domain).</summary>
    public async Task<SchemaCatalog?> CatalogAsync(CancellationToken cancellationToken)
    {
        var session = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        return For(session);
    }

    /// <summary>The catalog, or schema.notRead.</summary>
    public async Task<SchemaCatalog> RequireCatalogAsync(CancellationToken cancellationToken) =>
        await CatalogAsync(cancellationToken).ConfigureAwait(false)
        ?? throw new DomeniaOperationException(SchemaErrors.NotRead, SchemaErrors.NotReadMessage);

    /// <summary>Reads the schema once with the limits of Domenia 1 (<see cref="SchemaReadLimits.Default"/>).</summary>
    public Task<SchemaStatus> ReadAsync(IProgress<SchemaReadStage>? progress, CancellationToken cancellationToken) =>
        ReadAsync(SchemaReadLimits.Default, progress, cancellationToken);

    /// <summary>
    /// Reads the schema once (Start-DomeniaAdSchemaRead): never automatic, never a write; bounded by <paramref name="limits"/>
    /// (8 000 attributes, 3 000 classes and 90 seconds for the screen). A second read while one runs is refused
    /// (schema.readBusy); a read that overruns <see cref="HardLimit"/> is stopped (schema.readFailed); a read for another domain
    /// or an unexpected schema context is refused; a failure keeps the schema read before.
    /// </summary>
    public async Task<SchemaStatus> ReadAsync(SchemaReadLimits limits, IProgress<SchemaReadStage>? progress, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(limits);
        var reader = context.Readers.Require<ISchemaReader>();
        var session = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var root = session.Domain?.RootDn
            ?? throw new DomeniaOperationException(SchemaErrors.ReadFailed, "Connectez-vous à un domaine avant de lire son schéma.");
        if (!await reading.WaitAsync(0, cancellationToken).ConfigureAwait(false))
        {
            throw new DomeniaOperationException(SchemaErrors.ReadBusy, SchemaErrors.ReadBusyMessage);
        }
        try
        {
            var hardLimit = HardLimit(limits);
            using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            budget.CancelAfter(hardLimit);
            SchemaReadResult result;
            try
            {
                result = await reader.ReadDefinitionsAsync(limits, progress, budget.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && budget.IsCancellationRequested)
            {
                throw Failed(session, "lecture interrompue au-delà de " + FrenchText.Integer((long)hardLimit.TotalSeconds) + " secondes (budget de "
                    + FrenchText.Integer((long)limits.Budget.TotalSeconds) + " secondes dépassé).");
            }
            catch (DomeniaOperationException ex) when (ex.Code != DomeniaErrors.SourceUnavailable)
            {
                throw Failed(session, ex.Message);
            }
            if (!DistinguishedName.AreEqual(result.DomainDn, root))
            {
                throw Failed(session, "schéma lu pour un autre domaine.");
            }
            if (!SchemaContextPattern().IsMatch(result.SchemaNamingContext))
            {
                throw Failed(session, "contexte de schéma inattendu, lecture refusée.");
            }
            var built = SchemaRules.BuildCatalog(result);
            lock (gate)
            {
                catalog = built;
                catalogSession = SessionIdentity.Key(session);
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

    private DomeniaOperationException Failed(SessionSnapshot session, string reason)
    {
        var text = "Lecture du schéma impossible" + FrenchText.Colon + reason.TrimEnd();
        if (!text.EndsWith('.'))
        {
            text += ".";
        }
        if (For(session) is not null)
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

    /// <summary>The catalog when it was read for this very session and its domain; otherwise null.</summary>
    private SchemaCatalog? For(SessionSnapshot session)
    {
        var root = session.Domain?.RootDn;
        var key = SessionIdentity.Key(session);
        lock (gate)
        {
            return catalog is not null && root is not null && DistinguishedName.AreEqual(catalog.DomainDn, root)
                && string.Equals(catalogSession, key, StringComparison.Ordinal) ? catalog : null;
        }
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
