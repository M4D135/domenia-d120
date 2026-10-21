using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>
/// Working OU of the session (decision of David, 21/10): chosen in the OU tree panel, remembered in the local preferences
/// per domain (key session.workingScope.&lt;SHA-256 of the root DN&gt;, like Directory.RootOu.&lt;hex&gt; in Domenia 1), and
/// used as the default scope of every section without a choice of its own. A remembered OU is restored only for its own
/// domain and only if the OU still exists; otherwise the default scope of the source applies and the journal says why.
/// The whole domain is a valid choice (always with sub-OUs): workstation measures then stay refused (scope.tooWide).
/// </summary>
public sealed class WorkingScope : IDisposable
{
    public const string PreferencePrefix = "session.workingScope.";

    private static readonly JsonSerializerOptions ValueJson = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    private readonly IPreferenceStore preferences;
    private readonly IOrganizationalUnitIndex? index;
    private readonly OperationJournal journal;
    private readonly TimeProvider clock;
    private readonly ITechnicalJournal log;
    private readonly SemaphoreSlim gate = new(1, 1);
    // Canonical root DN for which the remembered OU was looked for, and the scope chosen or restored for it.
    private string? restoredRoot;
    private ScopeSelection? chosen;

    /// <param name="index">Local OU index of the mode (never the network); null when the mode has none yet.</param>
    public WorkingScope(IPreferenceStore preferences, IOrganizationalUnitIndex? index, OperationJournal journal, TimeProvider clock, ITechnicalJournal log)
    {
        ArgumentNullException.ThrowIfNull(preferences);
        ArgumentNullException.ThrowIfNull(journal);
        ArgumentNullException.ThrowIfNull(clock);
        ArgumentNullException.ThrowIfNull(log);
        this.preferences = preferences;
        this.index = index;
        this.journal = journal;
        this.clock = clock;
        this.log = log;
    }

    /// <summary>The working scope shared by every module of the context.</summary>
    public static WorkingScope From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new WorkingScope(c.Preferences, c.Readers.Find<IOrganizationalUnitIndex>(), c.Journal, c.Clock, c.Log));
    }

    /// <summary>
    /// Scope of the session: chosen during this session, else remembered for this domain, else the default of the source.
    /// Never reads the network: the remembered OU is checked by the local OU index (memory, or the local base).
    /// </summary>
    public async Task<ScopeSelection?> CurrentAsync(SessionSnapshot session, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(session);
        if (RootKey(session) is not string rootKey)
        {
            return session.Scope;
        }
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (!string.Equals(restoredRoot, rootKey, StringComparison.Ordinal))
            {
                var restored = await RestoreAsync(session, rootKey, cancellationToken).ConfigureAwait(false);
                chosen = restored;
                restoredRoot = rootKey;
            }
            return chosen ?? session.Scope;
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>The session with its working scope in place of the default one.</summary>
    public async Task<SessionSnapshot> ApplyAsync(SessionSnapshot session, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(session);
        var scope = await CurrentAsync(session, cancellationToken).ConfigureAwait(false);
        return ReferenceEquals(scope, session.Scope) ? session : session with { Scope = scope };
    }

    /// <summary>
    /// session.setScope: checks in the local OU index (never the network) that the OU exists in the domain of the session,
    /// keeps it for the session and remembers it in the preferences. Errors: scope.outsideDomain, scope.unknown,
    /// source.unavailable (no local index for this mode).
    /// </summary>
    public async Task<ScopeSelection> SetAsync(SessionSnapshot session, string dn, bool subtree, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(dn);
        var root = session.Domain?.RootDn;
        if (root is null || RootKey(session) is not string rootKey)
        {
            throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);
        }
        var (selection, path) = await ResolveAsync(session, root, dn, subtree, cancellationToken).ConfigureAwait(false) switch
        {
            (ScopeSelection s, string p, null) => (s, p),
            (_, _, string code) => throw Refusal(code),
            _ => throw Refusal(DomeniaErrors.ScopeUnknown),
        };
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var previous = string.Equals(restoredRoot, rootKey, StringComparison.Ordinal) ? chosen ?? session.Scope : session.Scope;
            chosen = selection;
            restoredRoot = rootKey;
            if (!ScopeRules.SameScope(previous, selection))
            {
                var label = "OU de travail" + FrenchText.Colon + path + (selection.Subtree ? "" : " (sans sous-OU)");
                journal.Add(new JournalEntry(clock.GetUtcNow(), label, Tone.Info));
            }
            await RememberAsync(rootKey, selection, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            gate.Release();
        }
        return selection;
    }

    public void Dispose() => gate.Dispose();

    /// <summary>Preference key of a domain: prefix and SHA-256 of its canonical root DN.</summary>
    public static string PreferenceKey(string rootDn)
    {
        ArgumentNullException.ThrowIfNull(rootDn);
        var canonical = DistinguishedName.Format(DistinguishedName.Parse(rootDn)).ToUpperInvariant();
        return PreferencePrefix + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(canonical)));
    }

    private static string? RootKey(SessionSnapshot session)
    {
        if (session.Domain?.RootDn is not string root)
        {
            return null;
        }
        try
        {
            return PreferenceKey(root);
        }
        catch (FormatException)
        {
            return null;
        }
    }

    private async Task<ScopeSelection?> RestoreAsync(SessionSnapshot session, string rootKey, CancellationToken cancellationToken)
    {
        if (!preferences.TryGet(rootKey, out var value))
        {
            return null;
        }
        if (!TryRead(value, out var dn, out var subtree))
        {
            log.Warning("OU de travail mémorisée illisible : périmètre par défaut.");
            return null;
        }
        var (selection, _, refusal) = await ResolveAsync(session, session.Domain!.RootDn!, dn, subtree, cancellationToken).ConfigureAwait(false);
        if (refusal is not null)
        {
            // The code only: the DN is directory data, not needed to understand the fallback.
            log.Warning($"OU de travail mémorisée écartée ({refusal}) : périmètre par défaut.");
            if (refusal == DomeniaErrors.ScopeUnknown)
            {
                journal.Add(new JournalEntry(clock.GetUtcNow(), "OU de travail mémorisée introuvable" + FrenchText.Colon + "périmètre par défaut", Tone.Warn));
            }
        }
        return selection;
    }

    /// <summary>The scope for a DN of the session domain, its readable path, or the code of the refusal.</summary>
    private async Task<(ScopeSelection? Selection, string? Path, string? Refusal)> ResolveAsync(SessionSnapshot session, string root, string dn, bool subtree, CancellationToken cancellationToken)
    {
        var candidate = new ScopeSelection(dn, dn, subtree);
        if (ScopeRules.IsDomainRoot(candidate, root))
        {
            var name = session.Domain?.DnsName ?? root;
            // The whole domain always includes its sub-OUs.
            return (new ScopeSelection(root, name, true), name, null);
        }
        if (!ScopeRules.Contains(new ScopeSelection(root, root, true), dn))
        {
            return (null, null, DomeniaErrors.ScopeOutsideDomain);
        }
        if (index is null)
        {
            return (null, null, DomeniaErrors.SourceUnavailable);
        }
        var entry = await index.FindLocalAsync(dn, cancellationToken).ConfigureAwait(false);
        return entry is null ? (null, null, DomeniaErrors.ScopeUnknown) : (new ScopeSelection(entry.Dn, entry.Name, subtree), entry.Path, null);
    }

    private async Task RememberAsync(string rootKey, ScopeSelection selection, CancellationToken cancellationToken)
    {
        if (preferences.TryGet(rootKey, out var stored) && TryRead(stored, out var dn, out var subtree)
            && ScopeRules.SameScope(new ScopeSelection(dn, dn, subtree), selection))
        {
            return;
        }
        var element = JsonSerializer.SerializeToElement(new StoredScope(selection.Dn, selection.Subtree), ValueJson);
        try
        {
            await preferences.SetAsync(rootKey, element, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // The choice stays for the session; the operator is told it will not survive a restart.
            log.Warning($"Préférences non enregistrées (OU de travail) : {ex.GetType().Name}.");
            journal.Add(new JournalEntry(clock.GetUtcNow(), "Préférences non enregistrées" + FrenchText.Colon + "l’OU de travail vaut pour cette session", Tone.Warn));
        }
    }

    private static bool TryRead(JsonElement value, out string dn, out bool subtree)
    {
        dn = "";
        subtree = true;
        if (value.ValueKind != JsonValueKind.Object
            || !value.TryGetProperty("dn", out var dnValue) || dnValue.ValueKind != JsonValueKind.String
            || !value.TryGetProperty("subtree", out var subtreeValue) || subtreeValue.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            return false;
        }
        dn = dnValue.GetString()!;
        subtree = subtreeValue.GetBoolean();
        return dn.Length > 0;
    }

    private static DomeniaOperationException Refusal(string code) => code switch
    {
        DomeniaErrors.ScopeOutsideDomain => new(code, DomeniaErrors.ScopeOutsideDomainMessage),
        DomeniaErrors.SourceUnavailable => new(code, DomeniaErrors.SourceUnavailableMessage),
        _ => new(DomeniaErrors.ScopeUnknown, DomeniaErrors.ScopeUnknownMessage),
    };

    private sealed record StoredScope(string Dn, bool Subtree);
}
