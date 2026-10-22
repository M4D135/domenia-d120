using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>
/// Scope of the Comptes section (decision of David, 21/10: the working OU is the default of every section without a choice
/// of its own; « surcharge par section prévue ensuite »): the OU chosen in the Comptes screen, remembered per domain in the
/// local preferences (key accounts.scope.&lt;SHA-256 of the root DN&gt;), else the working OU of the session. Never the whole
/// domain: the root is refused (scope.tooWide). Checked in the local OU index only, never by the network.
/// </summary>
public sealed class AccountsSectionScope : IDisposable
{
    public const string PreferencePrefix = "accounts.scope.";

    public const string RootRefusedMessage = "Choisissez une OU\u00A0: la liste des comptes n’est jamais lue sur tout le domaine.";

    private static readonly JsonSerializerOptions ValueJson = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    private readonly IPreferenceStore preferences;
    private readonly IOrganizationalUnitIndex? index;
    private readonly WorkingScope working;
    private readonly OperationJournal journal;
    private readonly TimeProvider clock;
    private readonly ITechnicalJournal log;
    private readonly SemaphoreSlim gate = new(1, 1);
    private string? restoredRoot;
    private ScopeSelection? chosen;

    public AccountsSectionScope(IPreferenceStore preferences, IOrganizationalUnitIndex? index, WorkingScope working, OperationJournal journal, TimeProvider clock, ITechnicalJournal log)
    {
        ArgumentNullException.ThrowIfNull(preferences);
        ArgumentNullException.ThrowIfNull(working);
        ArgumentNullException.ThrowIfNull(journal);
        ArgumentNullException.ThrowIfNull(clock);
        ArgumentNullException.ThrowIfNull(log);
        this.preferences = preferences;
        this.index = index;
        this.working = working;
        this.journal = journal;
        this.clock = clock;
        this.log = log;
    }

    /// <summary>The section scope shared by the modules of the context.</summary>
    public static AccountsSectionScope From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new AccountsSectionScope(c.Preferences, c.Readers.Find<IOrganizationalUnitIndex>(), WorkingScope.From(c), c.Journal, c.Clock, c.Log));
    }

    /// <summary>Preference key of a domain for the section scope.</summary>
    public static string PreferenceKey(string rootDn)
    {
        ArgumentNullException.ThrowIfNull(rootDn);
        var canonical = DistinguishedName.Format(DistinguishedName.Parse(rootDn)).ToUpperInvariant();
        return PreferencePrefix + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(canonical)));
    }

    /// <summary>
    /// Scope of the section: chosen in this session, else remembered for this domain (if the OU still exists), else the working
    /// OU of the session; null when neither exists (directory mode not connected).
    /// </summary>
    public async Task<AccountsScope?> CurrentAsync(SessionSnapshot session, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(session);
        var root = session.Domain?.RootDn;
        if (root is null || Key(root) is not string key)
        {
            return null;
        }
        ScopeSelection? section;
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (!string.Equals(restoredRoot, key, StringComparison.Ordinal))
            {
                chosen = await RestoreAsync(root, key, cancellationToken).ConfigureAwait(false);
                restoredRoot = key;
            }
            section = chosen;
        }
        finally
        {
            gate.Release();
        }
        if (section is not null)
        {
            return await DescribeAsync(section, AccountsScopeOrigin.Section, session, cancellationToken).ConfigureAwait(false);
        }
        var current = await working.CurrentAsync(session, cancellationToken).ConfigureAwait(false);
        return current is null ? null : await DescribeAsync(current, AccountsScopeOrigin.Working, session, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// accounts.scope.set: an OU of the session domain (never the root), checked in the local index, kept for the session and
    /// remembered. Errors: scope.tooWide, scope.outsideDomain, scope.unknown, source.unavailable.
    /// </summary>
    public async Task<AccountsScope> SetAsync(SessionSnapshot session, string dn, bool subtree, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(dn);
        var root = session.Domain?.RootDn;
        if (root is null || Key(root) is not string key)
        {
            throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);
        }
        var candidate = new ScopeSelection(dn, dn, subtree);
        if (ScopeRules.IsDomainRoot(candidate, root))
        {
            throw new DomeniaOperationException(DomeniaErrors.ScopeTooWide, RootRefusedMessage);
        }
        if (!ScopeRules.Contains(new ScopeSelection(root, root, true), dn))
        {
            throw new DomeniaOperationException(DomeniaErrors.ScopeOutsideDomain, "Cette OU n’appartient pas au domaine de la session\u00A0: le périmètre des comptes n’a pas été changé.");
        }
        if (index is null)
        {
            throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);
        }
        var entry = await index.FindLocalAsync(dn, cancellationToken).ConfigureAwait(false)
            ?? throw new DomeniaOperationException(DomeniaErrors.ScopeUnknown, "OU introuvable\u00A0: le périmètre des comptes n’a pas été changé.");
        var selection = new ScopeSelection(entry.Dn, entry.Name, subtree);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var changed = !ScopeRules.SameScope(chosen, selection) || !string.Equals(restoredRoot, key, StringComparison.Ordinal);
            chosen = selection;
            restoredRoot = key;
            if (changed)
            {
                journal.Add(new JournalEntry(clock.GetUtcNow(), "Périmètre des comptes" + FrenchText.Colon + entry.Path + (subtree ? "" : " (sans sous-OU)"), Tone.Info));
            }
            await RememberAsync(key, selection, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            gate.Release();
        }
        return new AccountsScope(entry.Dn, entry.Name, entry.Path, subtree, AccountsScopeOrigin.Section);
    }

    /// <summary>accounts.scope.reset: back to the working OU of the session; the remembered choice is removed.</summary>
    public async Task<AccountsScope?> ResetAsync(SessionSnapshot session, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(session);
        var root = session.Domain?.RootDn;
        if (root is not null && Key(root) is string key)
        {
            await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                chosen = null;
                restoredRoot = key;
                if (preferences.TryGet(key, out _))
                {
                    try
                    {
                        await preferences.SetAsync(key, null, cancellationToken).ConfigureAwait(false);
                    }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                    {
                        log.Warning($"Préférences non enregistrées (périmètre des comptes)\u00A0: {ex.GetType().Name}.");
                    }
                }
            }
            finally
            {
                gate.Release();
            }
        }
        return await CurrentAsync(session, cancellationToken).ConfigureAwait(false);
    }

    public void Dispose() => gate.Dispose();

    private async Task<AccountsScope> DescribeAsync(ScopeSelection selection, AccountsScopeOrigin origin, SessionSnapshot session, CancellationToken cancellationToken)
    {
        var path = selection.Label;
        if (index is not null && session.Domain?.RootDn is string root && !ScopeRules.IsDomainRoot(selection, root))
        {
            var entry = await index.FindLocalAsync(selection.Dn, cancellationToken).ConfigureAwait(false);
            if (entry is not null)
            {
                path = entry.Path;
            }
        }
        return new AccountsScope(selection.Dn, selection.Label, path, selection.Subtree, origin);
    }

    private async Task<ScopeSelection?> RestoreAsync(string root, string key, CancellationToken cancellationToken)
    {
        if (!preferences.TryGet(key, out var value))
        {
            return null;
        }
        if (value.ValueKind != JsonValueKind.Object
            || !value.TryGetProperty("dn", out var dnValue) || dnValue.ValueKind != JsonValueKind.String
            || !value.TryGetProperty("subtree", out var subtreeValue) || subtreeValue.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            log.Warning("Périmètre des comptes mémorisé illisible\u00A0: OU de travail.");
            return null;
        }
        var dn = dnValue.GetString()!;
        if (index is null || ScopeRules.IsDomainRoot(new ScopeSelection(dn, dn, true), root))
        {
            return null;
        }
        var entry = await index.FindLocalAsync(dn, cancellationToken).ConfigureAwait(false);
        if (entry is null)
        {
            log.Warning("Périmètre des comptes mémorisé introuvable\u00A0: OU de travail.");
            return null;
        }
        return new ScopeSelection(entry.Dn, entry.Name, subtreeValue.GetBoolean());
    }

    private async Task RememberAsync(string key, ScopeSelection selection, CancellationToken cancellationToken)
    {
        var element = JsonSerializer.SerializeToElement(new StoredScope(selection.Dn, selection.Subtree), ValueJson);
        try
        {
            await preferences.SetAsync(key, element, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log.Warning($"Préférences non enregistrées (périmètre des comptes)\u00A0: {ex.GetType().Name}.");
            journal.Add(new JournalEntry(clock.GetUtcNow(), "Préférences non enregistrées" + FrenchText.Colon + "le périmètre des comptes vaut pour cette session", Tone.Warn));
        }
    }

    private static string? Key(string root)
    {
        try
        {
            return PreferenceKey(root);
        }
        catch (FormatException)
        {
            return null;
        }
    }

    private sealed record StoredScope(string Dn, bool Subtree);
}
