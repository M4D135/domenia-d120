using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Domenia.Core.Queries;

/// <summary>
/// Readable, commented PowerShell 5.1 script of one recipe (Domenia 1 ConvertTo-DomeniaQueryPowerShell, made standalone):
/// it reads the directory part with Get-ADComputer, Get-ADUser or Get-ADGroup -LDAPFilter, read only, bounded by a search
/// base and a result size. The recipe is embedded as an ASCII JSON data literal; the script holds no credential, writes
/// nothing and is never run by the export. Conditions computed by Domenia (readings, probes) are listed, not evaluated.
/// </summary>
public static partial class QueryScript
{
    [GeneratedRegex(@"[\p{Cc}\p{Zl}\p{Zp}\u0085]+", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex LineBreaks();

    /// <summary>One comment line: no line terminator or control character can end the comment.</summary>
    public static string Comment(string text, int maxLength = 400)
    {
        var clean = LineBreaks().Replace(text ?? "", " ").Trim();
        return clean.Length > maxLength ? clean[..maxLength] + "…" : clean;
    }

    /// <summary>Every non-ASCII character as a JSON \u escape: typographic quotes can never close the single-quoted literal.</summary>
    public static string AsciiJson(string json)
    {
        ArgumentNullException.ThrowIfNull(json);
        var builder = new StringBuilder(json.Length + 64);
        foreach (var c in json)
        {
            if (c < 32 || c > 126)
            {
                builder.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
            }
            else
            {
                builder.Append(c);
            }
        }
        return builder.ToString();
    }

    /// <summary>PowerShell single-quoted literal, every non-ASCII character spelled [char] so the file reads the same in any code page.</summary>
    public static string Literal(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var parts = new List<string>();
        var current = new StringBuilder();
        void Flush()
        {
            if (current.Length > 0)
            {
                parts.Add("'" + current.ToString().Replace("'", "''", StringComparison.Ordinal) + "'");
                current.Clear();
            }
        }
        foreach (var c in text)
        {
            if (c is < ' ' or > '~' || c is '‘' or '’' or '‚' or '‛')
            {
                Flush();
                parts.Add("[char]0x" + ((int)c).ToString("X4", CultureInfo.InvariantCulture));
            }
            else
            {
                current.Append(c);
            }
        }
        Flush();
        return parts.Count == 0 ? "''" : parts.Count == 1 ? parts[0] : "(" + string.Join(" + ", parts) + ")";
    }

    public static string Cmdlet(QueryTarget target) => target switch
    {
        QueryTarget.User => "Get-ADUser",
        QueryTarget.Group => "Get-ADGroup",
        _ => "Get-ADComputer",
    };

    /// <summary>One-line command equivalent to the directory part of a recipe (transparency, copy).</summary>
    public static string Command(CompiledQuery query, LdapTranslation ldap, string? searchBase)
    {
        ArgumentNullException.ThrowIfNull(query);
        ArgumentNullException.ThrowIfNull(ldap);
        var properties = Properties(query);
        return Cmdlet(query.Target) + " -LDAPFilter " + Literal(ldap.PreFilter) + (string.IsNullOrEmpty(searchBase) ? "" : " -SearchBase " + Literal(searchBase) + " -SearchScope Subtree")
            + " -ResultSetSize 5000" + (properties.Count > 0 ? " -Properties " + string.Join(",", properties) : "");
    }

    private static List<string> Properties(CompiledQuery query) =>
        query.RequestedFields.Select(f => QueryCatalog.Find(query.Target, f, query.Resolved.ReadDefinition)?.LdapAttribute).OfType<string>()
            .SelectMany(a => a.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
            .Where(a => Ldap.LdapSchema.Find(a) is not null).Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.OrdinalIgnoreCase).ToList();

    /// <summary>The whole script (CRLF), ready to be saved with a UTF-8 byte order mark.</summary>
    public static string PowerShell(CompiledQuery query, LdapTranslation ldap, DateTimeOffset exportedAt)
    {
        ArgumentNullException.ThrowIfNull(query);
        ArgumentNullException.ThrowIfNull(ldap);
        var recipe = query.Normalized;
        var lines = new List<string>();
        void Note(string text)
        {
            var indent = text.Length - text.TrimStart(' ').Length;
            lines.Add(("# " + new string(' ', indent) + Comment(text)).TrimEnd());
        }
        lines.Add("#requires -Version 5.1");
        Note("===== Requête Domenia exportée =====");
        Note("Nom : " + recipe.Name);
        Note("Identifiant : " + recipe.Id + " · format " + recipe.MinimalFormat() + " · cible : " + QueryTexts.TargetLabel(recipe.Target));
        Note("Exportée le " + exportedAt.UtcDateTime.ToString("dd'/'MM'/'yyyy HH':'mm", CultureInfo.InvariantCulture) + " UTC. L’export n’a rien exécuté : relisez puis lancez ce script vous-même.");
        lines.Add("#");
        Note("Ce script lit l’annuaire en lecture seule (" + Cmdlet(recipe.Target) + " -LDAPFilter), n’écrit rien et ne contient ni identifiant ni secret.");
        Note("Il lit seulement la base indiquée par -SearchBase, dans la limite de -ResultSetSize objets : jamais tout le domaine sans votre choix.");
        lines.Add("#");
        Note("Conditions :");
        foreach (var (element, values) in QueryAnalysis.Summary(recipe))
        {
            if (element is "Nom" or "Cible")
            {
                continue;
            }
            foreach (var value in values)
            {
                Note("  " + element + " : " + value);
            }
        }
        lines.Add("#");
        Note("Filtre LDAP envoyé au contrôleur : " + ldap.PreFilter);
        if (ldap.Residual.Length > 0)
        {
            Note("Conditions calculées par Domenia, non évaluées par ce script (relevés, sondes, règles locales) :");
            foreach (var item in ldap.Residual)
            {
                Note("  - " + item);
            }
        }
        foreach (var note in ldap.Notes)
        {
            Note("Remarque : " + note);
        }
        lines.Add("#");
        Note("Informations utilisées et sources :");
        foreach (var id in query.RequestedFields)
        {
            if (QueryCatalog.Find(recipe.Target, id, recipe.ReadDefinition) is { } field)
            {
                Note("  - " + field.Name + " : " + field.SourceLabel + " · " + field.Freshness);
            }
        }
        var parameters = QueryEngine.ParameterRows(recipe);
        Note("Paramètres de la recette (valeurs figées à l’export) :");
        if (parameters.Length == 0)
        {
            Note("  (aucun)");
        }
        foreach (var parameter in parameters)
        {
            Note("  - " + parameter.Label + " (" + parameter.FieldName + ") = " + parameter.ValueLabel);
        }
        lines.Add("#");
        Note("Limites :");
        Note("  - Une information absente du filtre LDAP reste à vérifier dans Domenia : ce script ne rend que les candidats de l’annuaire.");
        Note("  - Les dates relatives (jours depuis la connexion…) sont converties à l’export : exportez de nouveau pour les recalculer.");
        Note("  - Lecture seule ; aucune collecte n’est déclenchée.");
        lines.Add("#");
        Note("Exemple : .\\requete.ps1 -SearchBase 'OU=Postes,DC=example,DC=local' -Server dc01.example.local");
        lines.Add("[CmdletBinding()]");
        lines.Add("param(");
        lines.Add("    [Parameter(Mandatory = $true)][string]$SearchBase,");
        lines.Add("    [string]$Server,");
        lines.Add("    [ValidateRange(1, 200000)][int]$ResultSetSize = 5000,");
        lines.Add("    [switch]$ShowDefinition");
        lines.Add(")");
        lines.Add("$ErrorActionPreference = 'Stop'");
        lines.Add("$definition = '" + AsciiJson(QueryRecipeJson.Write(recipe)).Replace("'", "''", StringComparison.Ordinal) + "'");
        lines.Add("if ($ShowDefinition) { $definition | ConvertFrom-Json | ConvertTo-Json -Depth 32; return }");
        lines.Add("Import-Module ActiveDirectory -ErrorAction Stop");
        lines.Add("$ldapFilter = " + Literal(ldap.PreFilter));
        var properties = Properties(query);
        lines.Add("$properties = @(" + string.Join(", ", properties.Select(p => "'" + p + "'")) + ")");
        lines.Add("$query = @{ LDAPFilter = $ldapFilter; SearchBase = $SearchBase; SearchScope = 'Subtree'; ResultSetSize = $ResultSetSize; Properties = $properties }");
        lines.Add("if ($Server) { $query.Server = $Server }");
        lines.Add(Cmdlet(recipe.Target) + " @query | Select-Object -Property (@('Name', 'DistinguishedName') + $properties)");
        return string.Join("\r\n", lines) + "\r\n";
    }
}

/// <summary>One cmdlet of the ActiveDirectory or LAPS modules (reference only: Domenia never runs them).</summary>
public sealed record QueryCmdlet(string Name, string Module, bool Write, bool Credential, string Synopsis, string Syntax, string Example);

/// <summary>
/// Built-in reference of the ActiveDirectory and LAPS cmdlets (Domenia 1 hidden « Référence » tab read the installed modules;
/// Domenia 2 ships no PowerShell, so the reference is delivered). Filterable by text and module, copied on demand.
/// </summary>
public static class QueryCmdlets
{
    private const string Ad = "ActiveDirectory";
    private const string Laps = "LAPS";
    private const string LegacyLaps = "AdmPwd.PS";
    private const string Common = " [-Server <string>] [-Credential <PSCredential>] [-AuthType <ADAuthType>]";

    public static IReadOnlyList<QueryCmdlet> All { get; } =
    [
        new("Get-ADComputer", Ad, false, true, "Lit des comptes ordinateurs par identité, filtre PowerShell ou filtre LDAP.",
            "Get-ADComputer -LDAPFilter <string> [-SearchBase <string>] [-SearchScope Base|OneLevel|Subtree] [-ResultSetSize <int>] [-Properties <string[]>]" + Common,
            "Get-ADComputer -LDAPFilter '(operatingSystem=*Windows 10*)' -SearchBase 'OU=Postes,DC=example,DC=local' -Properties operatingSystem"),
        new("Get-ADUser", Ad, false, true, "Lit des comptes utilisateurs par identité, filtre PowerShell ou filtre LDAP.",
            "Get-ADUser -LDAPFilter <string> [-SearchBase <string>] [-SearchScope Base|OneLevel|Subtree] [-ResultSetSize <int>] [-Properties <string[]>]" + Common,
            "Get-ADUser -LDAPFilter '(&(objectCategory=person)(lockoutTime>=1))' -Properties lockoutTime"),
        new("Get-ADGroup", Ad, false, true, "Lit des groupes par identité, filtre PowerShell ou filtre LDAP.",
            "Get-ADGroup -LDAPFilter <string> [-SearchBase <string>] [-SearchScope Base|OneLevel|Subtree] [-ResultSetSize <int>] [-Properties <string[]>]" + Common,
            "Get-ADGroup -LDAPFilter '(!(member=*))' -SearchBase 'OU=Groupes,DC=example,DC=local'"),
        new("Get-ADGroupMember", Ad, false, true, "Liste les membres d’un groupe, éventuellement de façon récursive.",
            "Get-ADGroupMember -Identity <ADGroup> [-Recursive]" + Common, "Get-ADGroupMember -Identity 'GG-Support-N2' -Recursive"),
        new("Get-ADPrincipalGroupMembership", Ad, false, true, "Liste les groupes dont un compte est membre direct.",
            "Get-ADPrincipalGroupMembership -Identity <ADPrincipal> [-ResourceContextServer <string>]" + Common, "Get-ADPrincipalGroupMembership -Identity c.bernard"),
        new("Get-ADObject", Ad, false, true, "Lit tout objet de l’annuaire par identité ou filtre LDAP.",
            "Get-ADObject -LDAPFilter <string> [-SearchBase <string>] [-SearchScope Base|OneLevel|Subtree] [-ResultSetSize <int>] [-Properties <string[]>] [-IncludeDeletedObjects]" + Common,
            "Get-ADObject -LDAPFilter '(objectClass=contact)' -SearchBase 'OU=Utilisateurs,DC=example,DC=local'"),
        new("Get-ADOrganizationalUnit", Ad, false, true, "Lit des unités d’organisation.",
            "Get-ADOrganizationalUnit -LDAPFilter <string> [-SearchBase <string>] [-SearchScope Base|OneLevel|Subtree] [-Properties <string[]>]" + Common,
            "Get-ADOrganizationalUnit -LDAPFilter '(name=*)' -SearchBase 'OU=Postes,DC=example,DC=local' -SearchScope OneLevel"),
        new("Search-ADAccount", Ad, false, true, "Cherche des comptes verrouillés, désactivés, expirés ou inactifs.",
            "Search-ADAccount [-LockedOut] [-AccountDisabled] [-AccountExpired] [-AccountInactive] [-PasswordExpired] [-PasswordNeverExpires] [-TimeSpan <TimeSpan>] [-UsersOnly] [-ComputersOnly] [-SearchBase <string>]" + Common,
            "Search-ADAccount -AccountInactive -TimeSpan 90.00:00:00 -ComputersOnly -SearchBase 'OU=Postes,DC=example,DC=local'"),
        new("Get-ADDomain", Ad, false, true, "Lit les informations du domaine (racine, contrôleurs FSMO, niveau fonctionnel).",
            "Get-ADDomain [[-Identity] <ADDomain>]" + Common, "Get-ADDomain"),
        new("Get-ADDomainController", Ad, false, true, "Trouve ou lit des contrôleurs de domaine.",
            "Get-ADDomainController [-Discover] [-DomainName <string>] [-Service <ADDiscoverableService[]>] [-Filter <string>]" + Common, "Get-ADDomainController -Discover -Service PrimaryDC"),
        new("Get-ADDefaultDomainPasswordPolicy", Ad, false, true, "Lit la stratégie de mot de passe par défaut du domaine.",
            "Get-ADDefaultDomainPasswordPolicy [[-Identity] <ADDefaultDomainPasswordPolicy>]" + Common, "Get-ADDefaultDomainPasswordPolicy"),
        new("Get-ADFineGrainedPasswordPolicy", Ad, false, true, "Lit les stratégies de mot de passe affinées.",
            "Get-ADFineGrainedPasswordPolicy -Filter <string> [-Properties <string[]>]" + Common, "Get-ADFineGrainedPasswordPolicy -Filter *"),
        new("Get-ADUserResultantPasswordPolicy", Ad, false, true, "Donne la stratégie de mot de passe qui s’applique à un utilisateur.",
            "Get-ADUserResultantPasswordPolicy -Identity <ADAccount>" + Common, "Get-ADUserResultantPasswordPolicy -Identity c.bernard"),
        new("Get-ADReplicationPartnerMetadata", Ad, false, true, "Lit l’état de réplication d’un contrôleur avec ses partenaires.",
            "Get-ADReplicationPartnerMetadata -Target <Object[]> [-Partition <string[]>]" + Common, "Get-ADReplicationPartnerMetadata -Target dc01.example.local"),
        new("Unlock-ADAccount", Ad, true, true, "Déverrouille un compte (écriture : dans Domenia, plan, confirmation, reçu et relecture).",
            "Unlock-ADAccount -Identity <ADAccount> [-WhatIf] [-Confirm]" + Common, "Unlock-ADAccount -Identity c.bernard -WhatIf"),
        new("Enable-ADAccount", Ad, true, true, "Active un compte (écriture).", "Enable-ADAccount -Identity <ADAccount> [-WhatIf] [-Confirm]" + Common, "Enable-ADAccount -Identity c.bernard -WhatIf"),
        new("Disable-ADAccount", Ad, true, true, "Désactive un compte (écriture).", "Disable-ADAccount -Identity <ADAccount> [-WhatIf] [-Confirm]" + Common, "Disable-ADAccount -Identity c.bernard -WhatIf"),
        new("Set-ADAccountPassword", Ad, true, true, "Change ou réinitialise un mot de passe (écriture ; le mot de passe passe en SecureString, jamais en clair).",
            "Set-ADAccountPassword -Identity <ADAccount> [-Reset] [-NewPassword <SecureString>] [-WhatIf] [-Confirm]" + Common, "Set-ADAccountPassword -Identity c.bernard -Reset -WhatIf"),
        new("Move-ADObject", Ad, true, true, "Déplace un objet vers une autre OU (écriture).", "Move-ADObject -Identity <ADObject> -TargetPath <string> [-WhatIf] [-Confirm]" + Common,
            "Move-ADObject -Identity 'CN=PC-PAR-0042,OU=Paris,OU=Postes,DC=example,DC=local' -TargetPath 'OU=Quarantaine,OU=Postes,DC=example,DC=local' -WhatIf"),
        new("Add-ADGroupMember", Ad, true, true, "Ajoute des membres à un groupe (écriture).", "Add-ADGroupMember -Identity <ADGroup> -Members <ADPrincipal[]> [-WhatIf] [-Confirm]" + Common,
            "Add-ADGroupMember -Identity 'GG-Support-N1' -Members c.bernard -WhatIf"),
        new("Remove-ADGroupMember", Ad, true, true, "Retire des membres d’un groupe (écriture).", "Remove-ADGroupMember -Identity <ADGroup> -Members <ADPrincipal[]> [-WhatIf] [-Confirm]" + Common,
            "Remove-ADGroupMember -Identity 'GG-Support-N1' -Members c.bernard -WhatIf"),
        new("Get-LapsADPassword", Laps, false, true, "Lit les informations LAPS Windows d’un poste (expiration ; le mot de passe n’est affiché qu’avec -AsPlainText, jamais par Domenia).",
            "Get-LapsADPassword -Identity <string[]> [-DomainController <string>] [-Domain <string>] [-IncludeHistory] [-AsPlainText] [-DecryptionCredential <PSCredential>] [-Credential <PSCredential>]",
            "Get-LapsADPassword -Identity PC-PAR-0042"),
        new("Get-LapsDiagnostics", Laps, false, false, "Rassemble les journaux et l’état LAPS du poste local.", "Get-LapsDiagnostics [-OutputFolder <string>] [-CollectNetworkTrace] [-ResetPassword]", "Get-LapsDiagnostics -OutputFolder C:\\Temp\\laps"),
        new("Find-LapsADExtendedRights", Laps, false, true, "Liste les délégations de lecture des mots de passe LAPS sur une OU.", "Find-LapsADExtendedRights -Identity <string> [-IncludeComputers] [-Domain <string>] [-DomainController <string>] [-Credential <PSCredential>]",
            "Find-LapsADExtendedRights -Identity 'OU=Postes,DC=example,DC=local'"),
        new("Set-LapsADComputerSelfPermission", Laps, true, true, "Autorise les postes d’une OU à mettre à jour leur mot de passe LAPS (écriture d’ACL).",
            "Set-LapsADComputerSelfPermission -Identity <string> [-Domain <string>] [-DomainController <string>] [-Credential <PSCredential>]", "Set-LapsADComputerSelfPermission -Identity 'OU=Postes,DC=example,DC=local' -WhatIf"),
        new("Reset-LapsPassword", Laps, true, false, "Force la rotation du mot de passe LAPS du poste local (écriture).", "Reset-LapsPassword", "Reset-LapsPassword"),
        new("Update-LapsADSchema", Laps, true, true, "Étend le schéma pour LAPS Windows (écriture de schéma).", "Update-LapsADSchema [-Credential <PSCredential>]", "Update-LapsADSchema -WhatIf"),
        new("Get-AdmPwdPassword", LegacyLaps, false, false, "LAPS hérité : lit l’expiration et le mot de passe d’un poste (Domenia n’en lit que l’expiration).", "Get-AdmPwdPassword -ComputerName <string>", "Get-AdmPwdPassword -ComputerName PC-PAR-0042"),
        new("Reset-AdmPwdPassword", LegacyLaps, true, false, "LAPS hérité : fixe une nouvelle date d’expiration (écriture).", "Reset-AdmPwdPassword -ComputerName <string> [-WhenEffective <DateTime>]", "Reset-AdmPwdPassword -ComputerName PC-PAR-0042"),
        new("Find-AdmPwdExtendedRights", LegacyLaps, false, false, "LAPS hérité : liste les délégations de lecture sur une OU.", "Find-AdmPwdExtendedRights -Identity <string>", "Find-AdmPwdExtendedRights -Identity 'OU=Postes,DC=example,DC=local'"),
    ];
}
