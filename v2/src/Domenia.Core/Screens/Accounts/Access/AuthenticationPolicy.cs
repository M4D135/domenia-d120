namespace Domenia.Core;

/// <summary>Effective bounds shared by account admission and the native provider. One discovered controller is pinned;
/// the Windows locator may select it before any explicit secret is supplied, never after.</summary>
public sealed record AuthenticationPolicy(bool AllowWindowsSession, int TotalSeconds, int PerServerSeconds)
{
    public const int EffectiveServerCandidates = 1;
    public static AuthenticationPolicy Read(RuntimeConfiguration? configuration = null)
    {
        var c = configuration ?? RuntimeConfiguration.Default;
        var total = Math.Clamp(c.Integer("Auth", "LoginTimeoutSeconds", 30), 5, 120);
        return new(c.Flag("Auth", "AllowWindowsSession", true), total,
            Math.Min(total, Math.Clamp(c.Integer("Auth", "PerServerTimeoutSeconds", 6), 1, 30)));
    }
}

public sealed record WindowsSessionChoice(bool Available, string Login, string Label, string? Reason)
{
    public static WindowsSessionChoice Read(bool allowed, bool simulated, string? joinedDomain, string login, string machineName)
    {
        var name = CredentialRules.Parse(login);
        var reason = simulated ? "Démonstration : aucune connexion Windows au domaine."
            : !allowed ? "La connexion par session Windows est désactivée par la configuration."
            : string.IsNullOrWhiteSpace(joinedDomain) ? "Ce poste n’est pas joint à un domaine."
            : !CredentialRules.IsWellFormed(login) || name.Form != AccountNameForm.DownLevel || name.Name.EndsWith('$')
                || name.Authority.Equals(machineName, StringComparison.OrdinalIgnoreCase) || name.Authority == "."
                || new[] { "NT AUTHORITY", "AUTORITE NT", "NT SERVICE", "NT VIRTUAL MACHINE", "IIS APPPOOL", "WINDOW MANAGER", "FONT DRIVER HOST", "BUILTIN" }.Contains(name.Authority, StringComparer.OrdinalIgnoreCase)
                || name.Name.Equals("SYSTEM", StringComparison.OrdinalIgnoreCase)
                || name.Name.StartsWith("DWM-", StringComparison.OrdinalIgnoreCase) || name.Name.StartsWith("UMFD-", StringComparison.OrdinalIgnoreCase)
                ? "La session Windows utilise un compte local, système ou ordinateur ; choisissez un compte du domaine."
            : null;
        return new(reason is null, login, "Continuer en tant que " + login, reason);
    }
    public void RequireAvailable()
    {
        if (!Available) throw new DomeniaOperationException("accounts.windowsSessionUnavailable", Reason ?? "Session Windows indisponible.");
    }
}

/// <summary>Local process identity only: querying this choice never authenticates or opens the vault.</summary>
public interface IWindowsSessionChoiceSource { WindowsSessionChoice WindowsSessionChoice { get; } }
