using Domenia.Core;

namespace Domenia.Ad;

internal sealed record AdSessionIdentity(AccountIdentity Identity, string? Sid, RightsInfo Rights)
{
    internal System.Collections.Immutable.ImmutableArray<string> Aliases { get; init; } = [];
    internal AdministrationIdentity Administration { get; init; } = AdministrationIdentity.Unknown;
    internal MachineAdministrationPrincipal? AdministrationPrincipal { get; init; }
    internal string? AuthenticatedLogin { get; init; }
    internal AdEntry? AdministrationSubject { get; init; }
    internal static readonly string[] Attributes = ["objectGUID", "objectSid", "objectClass", "sAMAccountName", "userPrincipalName", "displayName", "givenName", "distinguishedName"];

    /// <summary>A successful bind authenticates; this exact lookup identifies its domain object, never the desktop user.</summary>
    internal static async Task<AdSessionIdentity> ReadAsync(IAdConnection connection, DomainInfo domain, string login, string? windowsSid, bool explicitCredential, CancellationToken token)
    {
        using var diagnostic = AuthenticationTrace.Step(AuthenticationStage.AccountIdentity);
        var filter = Filter(domain, login, windowsSid, explicitCredential);
        if (filter is null) { return Unknown(login, "Identité de connexion non résolue dans ce domaine ; aucun droit déduit."); }
        var entries = await connection.SearchAsync(new(domain.RootDn, filter, AdSearchScope.Subtree, Attributes)
        { PageSize = 1, SizeLimit = 2, Timeout = TimeSpan.FromSeconds(10), Budget = TimeSpan.FromSeconds(10) }, token).ConfigureAwait(false);
        if (entries.Count == 0) { return Unknown(login, "Compte absent ou non lisible dans ce domaine ; aucun droit déduit."); }
        if (entries.Count != 1) { throw new DomeniaOperationException(AccountAccess.ContextRefused, "Identité de connexion ambiguë dans ce domaine."); }
        var entry = entries[0];
        var sid = entry.Sid("objectSid");
        var sam = entry.String("sAMAccountName");
        if (!ScopeRules.Contains(new(domain.RootDn, "", true), entry.DistinguishedName) || entry.Guid("objectGUID") is not { } guid || guid == Guid.Empty
            || !AccountsRules.IsDomainSid(sid) || !sid!.StartsWith(domain.DomainSid + "-", StringComparison.OrdinalIgnoreCase) || string.IsNullOrWhiteSpace(sam)
            || !entry.Strings("objectClass").Contains("user", StringComparer.OrdinalIgnoreCase)
            || entry.Strings("objectClass").Contains("computer", StringComparer.OrdinalIgnoreCase))
        { throw new DomeniaOperationException(AccountAccess.ContextRefused, "Identité de connexion incohérente : session non publiée."); }
        if (!explicitCredential && sid != windowsSid) { throw new DomeniaOperationException(AccountAccess.ContextRefused, "SID de session différent de celui relu dans l’annuaire."); }
        var requested = CredentialRules.Parse(login);
        if (explicitCredential && (requested.Form == AccountNameForm.Upn
            ? !string.Equals(entry.String("userPrincipalName"), login, StringComparison.OrdinalIgnoreCase)
            : !string.Equals(sam, requested.Name, StringComparison.OrdinalIgnoreCase)))
        { throw new DomeniaOperationException(AccountAccess.ContextRefused, "Compte relu différent de l’identifiant authentifié."); }
        var evidence = await AdAdministrationIdentity.ReadEvidenceAsync(connection, domain, entry, token).ConfigureAwait(false);
        return new(new(domain.NetbiosName + "\\" + sam, entry.String("displayName"), entry.String("givenName"), entry.DistinguishedName), sid,
            new(RightsLevel.Unknown, SessionTexts.RightsLabel(RightsLevel.Unknown), true, "Compte authentifié et identifié ; les groupes ne prouvent pas une délégation. Droits vérifiés sur l’objet à chaque action."))
            { Administration = evidence.Identity, AdministrationPrincipal = evidence.Principal, AuthenticatedLogin = login, AdministrationSubject = entry,
                Aliases = [.. new[] { login, domain.NetbiosName + "\\" + sam, domain.DnsName + "\\" + sam, entry.String("userPrincipalName") }
                    .OfType<string>().Where(CredentialRules.IsWellFormed).Distinct(StringComparer.OrdinalIgnoreCase)] };
    }

    internal static string? Filter(DomainInfo domain, string login, string? windowsSid, bool explicitCredential)
    {
        if (!explicitCredential)
        {
            return AccountsRules.IsDomainSid(windowsSid) ? "(objectSid=" + SearchText.LdapLiteral(windowsSid!) + ")" : null;
        }
        if (!CredentialRules.IsWellFormed(login)) { return null; }
        var parsed = CredentialRules.Parse(login);
        var account = parsed.Form switch
        {
            AccountNameForm.Upn => "(userPrincipalName=" + SearchText.LdapLiteral(login) + ")",
            AccountNameForm.DownLevel when parsed.Authority.Equals(domain.NetbiosName, StringComparison.OrdinalIgnoreCase) || parsed.Authority.Equals(domain.DnsName, StringComparison.OrdinalIgnoreCase)
                => "(sAMAccountName=" + SearchText.LdapLiteral(parsed.Name) + ")",
            _ => null,
        };
        return account is null ? null : "(&(objectCategory=person)(objectClass=user)" + account + ")";
    }

    private static AdSessionIdentity Unknown(string login, string detail) => new(new(login, null, null, null), null,
        new(RightsLevel.Unknown, SessionTexts.RightsLabel(RightsLevel.Unknown), true, detail));
}
