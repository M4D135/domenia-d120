using System.Collections.Immutable;
using System.Security;

namespace Domenia.Core;

/// <summary>
/// Accounts of the workstation operations for this session (Domenia 1 $script:MachineCredential, RemoteAdminCredential,
/// AccessState): kept in memory only, never written to the disk, never logged; passwords as read-only SecureString copies until
/// the Windows API. One rule picks the account of the next operation (<see cref="MachineAccountRules.Cascade"/>); every change
/// moves the account generation (point 44) so that an operation started with the previous account stops instead of mixing two.
/// The machine screen sets the typed account; the slots of the Comptes page (Postes, Secrets) and of the access recovery
/// (temporary accounts) are set through the same service.
/// </summary>
public sealed class MachineAccountService : IDisposable
{
    private readonly EngineContext context;
    private readonly Lock gate = new();
    private readonly Dictionary<string, Slot> temporaryLocal = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, MachineAccountPause> pauses = new(StringComparer.OrdinalIgnoreCase);
    private readonly List<MachineTrialResult> trials = [];
    private Slot? typed;
    private Slot? remote;
    private Slot? temporary;
    private Slot? secrets;
    private Slot? secretsTemporary;
    private long generation;
    private bool disposed;

    private MachineAccountService(EngineContext context) => this.context = context;

    /// <summary>The single instance of the context.</summary>
    public static MachineAccountService From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new MachineAccountService(c));
    }

    /// <summary>Account generation: moves with every change of an account in use.</summary>
    public long Generation
    {
        get
        {
            lock (gate)
            {
                return generation;
            }
        }
    }

    // ---------------------------------------------------------------- reads

    /// <summary>The state of the cascade, for the workstation <paramref name="target"/> when one is chosen.</summary>
    public async Task<MachineAccountState> StateAsync(string? target, CancellationToken cancellationToken)
    {
        var session = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var key = MachineAccountRules.MachineKey(target);
        MachineWorkstation? workstation = null;
        if (key is not null && context.Readers.Find<IMachineAccountReader>() is { } reader)
        {
            workstation = await reader.FindWorkstationAsync(target!.Trim(), cancellationToken).ConfigureAwait(false);
        }
        return Build(session, key is null ? null : target!.Trim(), workstation);
    }

    /// <summary>The account the next operation on <paramref name="target"/> takes (Get-DomeniaMachineAccountInUse).</summary>
    public MachineAccountLabel Resolve(SessionSnapshot session, string? target)
    {
        ArgumentNullException.ThrowIfNull(session);
        var (_, inUse) = MachineAccountRules.Cascade(Input(session, target));
        return MachineAccountRules.Label(inUse.Source, inUse.Account);
    }

    /// <summary>
    /// Account and password copy for an operation on <paramref name="target"/> (vague 3: workers of the workstations). The caller
    /// disposes the copy; null for the Windows session, which needs no password. Never sent to the page.
    /// </summary>
    public (string Account, SecureString? Password) CredentialFor(SessionSnapshot session, string? target)
    {
        ArgumentNullException.ThrowIfNull(session);
        var label = Resolve(session, target);
        lock (gate)
        {
            var slot = label.Source switch
            {
                MachineAccountSource.TemporaryLocal => MachineAccountRules.MachineKey(target) is { } key ? temporaryLocal.GetValueOrDefault(key) : null,
                MachineAccountSource.Temporary => temporary,
                MachineAccountSource.Typed => typed,
                MachineAccountSource.Remote => remote,
                _ => null,
            };
            return (MachineAccountRules.ForTarget(label.Account, target), slot?.CopyPassword());
        }
    }

    // ---------------------------------------------------------------- typed account (panel « Compte poste »)

    /// <summary>
    /// Uses a typed account for the workstation operations, in memory only (Set-MachineCredentialFromUi). The password is a
    /// read-only SecureString owned by the service from now on (null in simulation, which asks for none).
    /// </summary>
    public void UseTyped(string account, SecureString? password)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(account);
        password?.MakeReadOnly();
        Slot? previous;
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            previous = typed;
            typed = new Slot(account.Trim(), password, context.Clock.GetUtcNow());
            generation++;
        }
        previous?.Dispose();
        context.Journal.Add(new JournalEntry(context.Clock.GetUtcNow(), "Compte poste saisi pour la session (en mémoire seulement)", Tone.Info));
    }

    /// <summary>Forgets the typed account (Clear-MachineCredential); the next level of the cascade takes over.</summary>
    public bool ForgetTyped()
    {
        Slot? previous;
        lock (gate)
        {
            previous = typed;
            typed = null;
            if (previous is not null)
            {
                generation++;
            }
        }
        if (previous is null)
        {
            return false;
        }
        previous.Dispose();
        context.Journal.Add(new JournalEntry(context.Clock.GetUtcNow(), "Compte poste oublié : retour au compte configuré", Tone.Info));
        return true;
    }

    // ---------------------------------------------------------------- slots of the Comptes page and of the access recovery

    /// <summary>Postes account of the Comptes page (CPT-013), after its validation by that page.</summary>
    public void UseRemote(string account, SecureString? password) => Replace(ref remote, account, password);

    public void ClearRemote() => Replace(ref remote, null, null);

    /// <summary>Secrets account of the Comptes page (CPT-014).</summary>
    public void UseSecrets(string account, SecureString? password) => Replace(ref secrets, account, password);

    public void ClearSecrets() => Replace(ref secrets, null, null);

    /// <summary>Temporary account accepted after a refusal: for one workstation (local account) or for every workstation.</summary>
    public void AcceptTemporary(string? computer, string account, SecureString? password)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(account);
        password?.MakeReadOnly();
        Slot? previous;
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            var slot = new Slot(account.Trim(), password, context.Clock.GetUtcNow());
            if (MachineAccountRules.MachineKey(computer) is { } key)
            {
                previous = temporaryLocal.GetValueOrDefault(key);
                temporaryLocal[key] = slot;
            }
            else
            {
                previous = temporary;
                temporary = slot;
            }
            generation++;
        }
        previous?.Dispose();
    }

    public void ForgetTemporary(string? computer)
    {
        Slot? previous;
        lock (gate)
        {
            if (MachineAccountRules.MachineKey(computer) is { } key)
            {
                temporaryLocal.Remove(key, out previous);
            }
            else
            {
                previous = temporary;
                temporary = null;
            }
            if (previous is not null)
            {
                generation++;
            }
        }
        previous?.Dispose();
    }

    /// <summary>Temporary account of the secrets reads, accepted after a refusal of LAPS or BitLocker.</summary>
    public void AcceptSecretsTemporary(string account, SecureString? password) => Replace(ref secretsTemporary, account, password);

    public void ForgetSecretsTemporary() => Replace(ref secretsTemporary, null, null);

    // ---------------------------------------------------------------- refusals and trials

    /// <summary>A refusal pauses the account (credential guard): it stays paused until a trial validates it.</summary>
    public void RecordRefusal(string account, string reason)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(account);
        lock (gate)
        {
            pauses[account.Trim()] = new MachineAccountPause(account.Trim(), context.Clock.GetUtcNow(), reason);
        }
    }

    /// <summary>A success validates the account: its pause ends.</summary>
    public void ClearPause(string account)
    {
        ArgumentNullException.ThrowIfNull(account);
        lock (gate)
        {
            pauses.Remove(account.Trim());
        }
    }

    /// <summary>
    /// Records a trial of the session (newest first, eight kept): a refusal of the identifiers or of the account pauses it, an
    /// administrator access validates it.
    /// </summary>
    public void RecordTrial(MachineTrialResult trial, string accountTried)
    {
        ArgumentNullException.ThrowIfNull(trial);
        ArgumentNullException.ThrowIfNull(accountTried);
        lock (gate)
        {
            trials.Insert(0, trial);
            if (trials.Count > MachineAccountRules.MaxTrials)
            {
                trials.RemoveRange(MachineAccountRules.MaxTrials, trials.Count - MachineAccountRules.MaxTrials);
            }
        }
        if (accountTried.Length == 0)
        {
            return;
        }
        if (trial.Verdict is MachineTrialVerdict.Rejected or MachineTrialVerdict.AccountState)
        {
            RecordRefusal(accountTried, trial.Text);
        }
        else if (trial.Verdict == MachineTrialVerdict.AdminOk)
        {
            ClearPause(accountTried);
        }
    }

    public void Dispose()
    {
        List<Slot> slots;
        lock (gate)
        {
            if (disposed)
            {
                return;
            }
            disposed = true;
            slots = [.. new[] { typed, remote, temporary, secrets, secretsTemporary }.OfType<Slot>(), .. temporaryLocal.Values];
            typed = remote = temporary = secrets = secretsTemporary = null;
            temporaryLocal.Clear();
        }
        foreach (var slot in slots)
        {
            slot.Dispose();
        }
    }

    // ---------------------------------------------------------------- state

    /// <summary>Builds the state for the page (names only).</summary>
    public MachineAccountState Build(SessionSnapshot session, string? target, MachineWorkstation? workstation)
    {
        ArgumentNullException.ThrowIfNull(session);
        var simulation = context.Directory.Kind == DirectorySourceKind.Simulation;
        CascadeSnapshot snapshot;
        lock (gate)
        {
            snapshot = new CascadeSnapshot(
                typed is null ? null : new MachineTypedAccount(typed.Account, typed.Since, typed.HasPassword),
                secretsTemporary?.Account, secrets?.Account, generation, [.. trials], new Dictionary<string, MachineAccountPause>(pauses, StringComparer.OrdinalIgnoreCase));
        }
        var input = Input(session, target);
        var (levels, inUse) = MachineAccountRules.Cascade(input);
        var secretsState = MachineAccountRules.SecretsCascade(snapshot.SecretsTemporary, snapshot.Secrets, DirectoryAccount(session), snapshot.Pauses);
        var label = MachineAccountRules.Label(inUse.Source, inUse.Account);
        return new MachineAccountState(
            inUse, MachineAccountRules.Sentence(label), MachineAccountRules.MachineKey(target) is null ? null : target!.Trim(), workstation, levels, secretsState,
            snapshot.Typed, !simulation, CredentialNote(simulation), snapshot.Generation, simulation, snapshot.Trials, Safeguards(simulation));
    }

    private sealed record CascadeSnapshot(
        MachineTypedAccount? Typed,
        string? SecretsTemporary,
        string? Secrets,
        long Generation,
        ImmutableArray<MachineTrialResult> Trials,
        IReadOnlyDictionary<string, MachineAccountPause> Pauses);

    private MachineAccountRules.CascadeInput Input(SessionSnapshot session, string? target)
    {
        var key = MachineAccountRules.MachineKey(target);
        lock (gate)
        {
            var connection = session.Authentication.Method == AuthenticationMethod.ExplicitCredentials ? session.Account.Login : null;
            return new MachineAccountRules.CascadeInput(
                key is null ? null : temporaryLocal.GetValueOrDefault(key)?.Account,
                temporary?.Account,
                typed?.Account,
                remote?.Account,
                connection,
                WindowsAccount(session),
                key is not null,
                context.Directory.Kind == DirectorySourceKind.Simulation,
                new Dictionary<string, MachineAccountPause>(pauses, StringComparer.OrdinalIgnoreCase));
        }
    }

    /// <summary>
    /// Account of the Windows session: the session account in simulation (never the real Windows account, so captures show no
    /// real name), the process account in directory mode.
    /// </summary>
    private string WindowsAccount(SessionSnapshot session)
    {
        if (context.Directory.Kind == DirectorySourceKind.Simulation || session.Authentication.Method != AuthenticationMethod.ExplicitCredentials)
        {
            return session.Account.Login;
        }
        return Environment.UserDomainName + "\\" + Environment.UserName;
    }

    /// <summary>Account of the directory reads: the connection account, otherwise the Windows session.</summary>
    private string DirectoryAccount(SessionSnapshot session) =>
        session.Authentication.Method == AuthenticationMethod.ExplicitCredentials ? session.Account.Login : WindowsAccount(session);

    private static string CredentialNote(bool simulation) => simulation
        ? "Simulation : aucun mot de passe n’est demandé. Le compte est gardé par son nom, en mémoire, pour essayer la règle et l’essai d’accès sur l’annuaire fictif."
        : "Le mot de passe part directement au moteur, qui le garde chiffré en mémoire (SecureString) jusqu’à l’API Windows : il n’est ni affiché, ni renvoyé, ni enregistré.";

    private static ImmutableArray<string> Safeguards(bool simulation)
    {
        var list = new List<string>
        {
            "Le compte poste vaut pour cette session : jamais enregistré sur le disque, jamais journalisé.",
            "Le mot de passe reste en SecureString jusqu’à l’API Windows : ni affiché, ni renvoyé à la page, ni passé en ligne de commande.",
            "Fermer le panneau, Échap ou un clic à côté ne changent rien : un mot de passe saisi sans " + FrenchText.Quote("Utiliser ce compte") + " est effacé.",
            "Chaque changement de compte ouvre une nouvelle génération : une opération lancée avec l’ancien compte s’arrête au lieu de mélanger deux comptes.",
            "L’essai d’accès lit seulement le système du poste choisi, sur votre clic : un seul poste, aucun balayage, aucune autre méthode.",
            "Un refus met le compte en pause : la prochaine opération avec lui est refusée tant qu’un essai réussi ne l’a pas validé.",
        };
        if (simulation)
        {
            list.Add("Simulation : aucun mot de passe n’est demandé, aucun poste n’est contacté ; l’essai lit l’annuaire fictif.");
        }
        return [.. list];
    }

    private void Replace(ref Slot? slot, string? account, SecureString? password)
    {
        password?.MakeReadOnly();
        Slot? previous;
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            previous = slot;
            slot = string.IsNullOrWhiteSpace(account) ? null : new Slot(account.Trim(), password, context.Clock.GetUtcNow());
            if (previous is not null || slot is not null)
            {
                generation++;
            }
        }
        previous?.Dispose();
    }

    /// <summary>One account in memory: its name, its read-only password and since when it is used.</summary>
    private sealed class Slot(string account, SecureString? password, DateTimeOffset since) : IDisposable
    {
        public string Account { get; } = account;

        public DateTimeOffset Since { get; } = since;

        public bool HasPassword => password is not null;

        /// <summary>A read-only copy for one operation; the caller disposes it.</summary>
        public SecureString? CopyPassword()
        {
            if (password is null)
            {
                return null;
            }
            var copy = password.Copy();
            copy.MakeReadOnly();
            return copy;
        }

        public void Dispose() => password?.Dispose();
    }
}
