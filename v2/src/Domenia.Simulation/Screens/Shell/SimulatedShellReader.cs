using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// Reads of the shell in simulation (docs/ops/shell.md): derived from the fictitious directory as the session sees it
/// (<see cref="SimulatedDirectorySource.CurrentDirectory"/>, writes of the session applied), in memory only. The account
/// refused for the operator (Domenia 1 TRV-047, TRV-048: « un compte refusé pour l’opérateur de démonstration ») is drawn
/// once from the screen stream « screen/shell », so the central generator is left untouched. Each read waits a short
/// realistic delay (« latency/screen/shell »), cancellable.
/// </summary>
public sealed class SimulatedShellReader : IShellReader
{
    private const string Screen = "shell";
    private const int MinDelayMilliseconds = 60;
    private const int MaxDelayMilliseconds = 180;

    private readonly SimulatedDirectorySource source;
    private readonly Lazy<Guid?> refused;

    /// <summary>Found by ScreenReaders.Discover for the simulated source; cheap: nothing is generated here.</summary>
    public SimulatedShellReader(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
        refused = new Lazy<Guid?>(DrawRefused, LazyThreadSafetyMode.ExecutionAndPublication);
    }

    public async Task<ShellLookupResult> LookupAsync(string text, IReadOnlySet<ShellLookupKind> kinds, int limit, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(text);
        ArgumentNullException.ThrowIfNull(kinds);
        await WaitAsync(cancellationToken).ConfigureAwait(false);
        var directory = source.CurrentDirectory;
        var needle = FrenchText.Fold(text.Trim());
        var found = new List<ShellLookupItem>();
        if (kinds.Contains(ShellLookupKind.User))
        {
            found.AddRange(directory.Users
                .Where(u => Matches(needle, u.Cn, u.SamAccountName, u.DisplayName, u.GivenName, u.Surname, u.Mail, u.UserPrincipalName))
                .Select(u => UserItem(directory, u)));
        }
        if (kinds.Contains(ShellLookupKind.Computer))
        {
            found.AddRange(directory.Computers
                .Where(c => Matches(needle, c.Name, c.SamAccountName, c.DnsHostName, c.Description))
                .Select(c => ComputerItem(directory, c)));
        }
        if (kinds.Contains(ShellLookupKind.Ou))
        {
            found.AddRange(directory.OrganizationalUnits
                .Where(o => Matches(needle, o.Name, o.Description))
                .Select(o => OuItem(directory, o)));
        }
        var ordered = found
            .OrderBy(i => i.Kind)
            .ThenBy(i => FrenchText.Fold(i.Name), StringComparer.Ordinal)
            .ThenBy(i => i.Dn, StringComparer.Ordinal)
            .ToList();
        var items = ordered.Take(limit).ToImmutableArray();
        var summary = ordered.Count == 0
            ? "Aucun objet ne correspond dans l’annuaire fictif."
            : ordered.Count > limit
                ? FrenchText.Count(ordered.Count, "objet trouvé", "objets trouvés") + FrenchText.Colon + "les " + FrenchText.Integer(limit) + " premiers sont affichés, précisez la recherche."
                : FrenchText.Count(ordered.Count, "objet trouvé", "objets trouvés") + " dans l’annuaire fictif.";
        return new ShellLookupResult(items, ordered.Count, ordered.Count > limit, summary);
    }

    public async Task<ShellLookupCheck> VerifyAsync(string dn, Guid objectGuid, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        await WaitAsync(cancellationToken).ConfigureAwait(false);
        var directory = source.CurrentDirectory;
        if (refused.Value == objectGuid)
        {
            return new ShellLookupCheck("denied", ShellErrors.LookupDeniedMessage, null);
        }
        var item = directory.Users.Where(u => u.ObjectGuid == objectGuid).Select(u => UserItem(directory, u))
            .Concat(directory.Computers.Where(c => c.ObjectGuid == objectGuid).Select(c => ComputerItem(directory, c)))
            .Concat(directory.OrganizationalUnits.Where(o => o.ObjectGuid == objectGuid).Select(o => OuItem(directory, o)))
            .FirstOrDefault();
        if (item is null)
        {
            return new ShellLookupCheck("missing", "Objet introuvable dans l’annuaire fictif" + FrenchText.Colon + "supprimé, recréé ou hors de portée. Choisissez-le de nouveau.", null);
        }
        return DistinguishedName.AreEqual(item.Dn, dn)
            ? new ShellLookupCheck("ok", "Objet revérifié" + FrenchText.Colon + "même nom distinctif, même GUID.", item)
            : new ShellLookupCheck("moved", "Objet déplacé ou renommé depuis votre choix" + FrenchText.Colon + "son nouveau nom distinctif est repris.", item);
    }

    public Task<ShellDemoCoverage> CoverageAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var directory = source.CurrentDirectory;
        var now = source.World.Reference;
        var users = directory.Users;
        var computers = directory.Computers;
        var groups = directory.Groups;
        var soon = AdValues.ToFileTime(now + TimeSpan.FromDays(7));
        var nowFileTime = AdValues.ToFileTime(now);
        var refusedName = refused.Value is Guid id ? users.FirstOrDefault(u => u.ObjectGuid == id)?.Cn : null;
        ShellDemoFixture[] fixtures =
        [
            Fixture("ous", "OU de sites, de services et restreintes", directory.OrganizationalUnits.Length, "Arborescence d’OU sous la racine du domaine."),
            Fixture("locked", "Comptes verrouillés", users.Count(u => AccountStateOf(u).Lock == LockState.Locked), "Verrouillage calculé par le contrôleur (msDS-User-Account-Control-Computed)."),
            Fixture("disabled", "Comptes désactivés", users.Count(u => AdValues.IsDisabled(u.UserAccountControl)), "Bit 0x2 de userAccountControl."),
            Fixture("admins", "Comptes à privilèges (adminCount = 1)", users.Count(u => u.AdminCount == 1), "Confirmation par saisie du nom pour leurs écritures."),
            Fixture("accents", "Noms accentués", users.Count(u => u.Cn.Any(c => c > '\u007f')), "Recherche sans accent ni casse."),
            Fixture("apostrophes", "Noms avec apostrophe", users.Count(u => u.Cn.Contains('\'', StringComparison.Ordinal) || u.Cn.Contains('’', StringComparison.Ordinal)), "Échappements LDAP et affichage."),
            Fixture("escaped", "Noms avec une virgule échappée dans le DN", users.Count(u => u.DistinguishedName.Contains("\\,", StringComparison.Ordinal)), "Échappement RFC 4514 dans le nom distinctif."),
            Fixture("lapsSoon", "Postes au mot de passe LAPS expirant sous 7 jours", computers.Count(c => c.LapsExpiration is long laps && laps > nowFileTime && laps <= soon), "Date d’expiration seulement, jamais le mot de passe."),
            Fixture("lapsExpired", "Postes au mot de passe LAPS expiré", computers.Count(c => c.LapsExpiration is long laps && laps <= nowFileTime), "Date d’expiration seulement, jamais le mot de passe."),
            Fixture("noDns", "Postes sans nom DNS", computers.Count(c => string.IsNullOrEmpty(c.DnsHostName)), "Ping et WMI impossibles sans nom : signalé au lieu d’être tenté."),
            Fixture("emptyGroup", "Groupes vides", groups.Count(g => g.Members.IsEmpty), "Membres et appartenances cohérents."),
            Fixture("allGroup", "Groupe « Tous » ou équivalent", groups.Count(g => g.Name.Contains("Tous", StringComparison.OrdinalIgnoreCase) || g.Name.Contains("Utilisateurs du domaine", StringComparison.Ordinal)), "Groupe qui contient tout le monde."),
            Fixture("refused", "Compte refusé pour l’opérateur", refusedName is null ? 0 : 1, refusedName is null ? "Aucun compte disponible pour la démonstration du refus." : "Revérifier ce compte dans un sélecteur répond « accès refusé » (" + refusedName + ")."),
        ];
        var present = fixtures.Count(f => f.Present);
        var summary = present == fixtures.Length
            ? "Toutes les catégories de l’annuaire de démonstration sont présentes."
            : FrenchText.Integer(present) + " catégories présentes sur " + FrenchText.Integer(fixtures.Length) + FrenchText.Colon + "les absentes sont à ajouter au générateur de la simulation.";
        return Task.FromResult(new ShellDemoCoverage(true, "simulation", [.. fixtures], present, fixtures.Length, summary));
    }

    public async Task<ImmutableArray<AutomationComputerRow>> ComputersAsync(AutomationPerimeter perimeter, int limit, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(perimeter);
        await WaitAsync(cancellationToken).ConfigureAwait(false);
        return [.. ShellAutomation.Select(source.CurrentDirectory.Computers, perimeter)
            .Take(limit + 1)
            .Select(c => new AutomationComputerRow(c.Name, c.DnsHostName, c.ObjectGuid.ToString("D"), c.DistinguishedName,
                !AdValues.IsDisabled(c.UserAccountControl), c.OperatingSystem, AdValues.FromFileTime(c.LastLogonTimestamp)))];
    }

    private static AccountState AccountStateOf(DirectoryUser user) =>
        AccountState.Evaluate(user.UserAccountControl, user.ComputedAccountControl, user.LockoutTime);

    private static ShellDemoFixture Fixture(string id, string label, int count, string detail) => new(id, label, count, count > 0, detail);

    private static bool Matches(string needle, params string?[] values) =>
        needle.Length > 0 && values.Any(v => !string.IsNullOrEmpty(v) && FrenchText.Fold(v).Contains(needle, StringComparison.Ordinal));

    private static ShellLookupItem UserItem(DirectorySnapshot directory, DirectoryUser u) => new(
        ShellLookupKind.User, "Utilisateur", u.DisplayName ?? u.Cn, u.DistinguishedName, u.ObjectGuid.ToString("D"),
        u.UserPrincipalName ?? u.SamAccountName, ContainerPath(directory, u.DistinguishedName), !AdValues.IsDisabled(u.UserAccountControl));

    private static ShellLookupItem ComputerItem(DirectorySnapshot directory, DirectoryComputer c) => new(
        ShellLookupKind.Computer, "Poste", c.Name, c.DistinguishedName, c.ObjectGuid.ToString("D"),
        c.DnsHostName, ContainerPath(directory, c.DistinguishedName), !AdValues.IsDisabled(c.UserAccountControl));

    private static ShellLookupItem OuItem(DirectorySnapshot directory, DirectoryOu o) => new(
        ShellLookupKind.Ou, "OU", o.Name, o.DistinguishedName, o.ObjectGuid.ToString("D"),
        o.Description, ContainerPath(directory, o.DistinguishedName), true);

    /// <summary>« example.local › Utilisateurs › Lyon »: the domain then the names of the containers, from the top.</summary>
    private static string ContainerPath(DirectorySnapshot directory, string dn)
    {
        try
        {
            var names = DistinguishedName.Parse(dn)
                .Skip(1)
                .Where(n => !string.Equals(n.Type, "DC", StringComparison.OrdinalIgnoreCase))
                .Select(n => n.Value)
                .Reverse();
            return string.Join(FrenchText.PathSeparator, names.Prepend(directory.Domain.DnsName));
        }
        catch (FormatException)
        {
            return directory.Domain.DnsName;
        }
    }

    /// <summary>One active, non privileged user drawn from the screen stream: the account refused for the operator.</summary>
    private Guid? DrawRefused()
    {
        var candidates = source.World.Directory.Users
            .Where(u => !AdValues.IsDisabled(u.UserAccountControl) && u.AdminCount != 1 && u.DistinguishedName.Contains("OU=", StringComparison.Ordinal))
            .OrderBy(u => u.ObjectGuid)
            .ToList();
        if (candidates.Count == 0)
        {
            return null;
        }
        var random = source.ScreenStream(Screen).Fork("refused");
        return candidates[random.Next(candidates.Count)].ObjectGuid;
    }

    private Task WaitAsync(CancellationToken cancellationToken) =>
        source.SimulateScreenLatencyAsync(Screen, MinDelayMilliseconds, MaxDelayMilliseconds, cancellationToken);
}
