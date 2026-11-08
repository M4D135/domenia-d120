using System.Management;
using WmiEnumerationOptions = System.Management.EnumerationOptions;
using Domenia.Core;

namespace Domenia.Inventory;

public sealed partial class WmiMachineAccessProbe
{
    // This explicit account validation reads membership only. It never treats a successful CIM SELECT as admin proof.
    // The native child budget remains authoritative for the whole BFS; all objects are disposed before child exit.
    private static string? ReadLocalAdministrator(ManagementScope scope, string computer, string? login, CancellationToken token, MachineAdministrationPrincipal? principal)
    {
        return ConfirmLocalAdministrator(computer, login, Query, token, principal);

        List<LocalAccount> Query(string query)
        {
            token.ThrowIfCancellationRequested();
            using var searcher = new ManagementObjectSearcher(scope, new ObjectQuery(query),
                new WmiEnumerationOptions { Timeout = TimeSpan.FromSeconds(4), ReturnImmediately = true, Rewindable = false });
            using var rows = searcher.Get(); var result = new List<LocalAccount>();
            foreach (var row in rows)
            {
                using (row)
                {
                    token.ThrowIfCancellationRequested();
                    if (result.Count >= 4096) { throw new InvalidDataException("Groupes locaux au-delà de la limite de validation."); }
                    if (row["SID"] is not string sid || row["Name"] is not string accountName || row["Domain"] is not string accountDomain
                        || sid.Length > 184 || accountName.Length is 0 or > 256 || accountDomain.Length is 0 or > 255)
                    { throw new InvalidDataException("Identité de membre local incomplète."); }
                    result.Add(new(sid, accountName, accountDomain, row.ClassPath.ClassName.Equals("Win32_Group", StringComparison.OrdinalIgnoreCase)));
                }
            }
            return result;
        }
    }

    internal static string? ConfirmLocalAdministrator(string computer, string? login, Func<string, IReadOnlyList<LocalAccount>> query,
        CancellationToken token, MachineAdministrationPrincipal? principal = null)
    {
        if (login is null) return null;
        LocalAccount? user = null;
        HashSet<string>? groupSids = null;
        if (CredentialRules.IsLocalAccount(login, computer))
        {
            if (principal is not null) return null; // Domain evidence cannot authenticate a local homonym.
            var name = CredentialRules.Parse(login).Name;
            var users = query("SELECT SID,Name,Domain FROM Win32_UserAccount WHERE LocalAccount=True AND Name='" + Literal(name)
                + "' AND Domain='" + Literal(computer) + "'");
            if (users.Count != 1 || users[0].IsGroup || !Same(users[0].Name, name) || !Same(users[0].Domain, computer)
                || !AccountsRules.IsDomainSid(users[0].Sid)) return null;
            user = users[0];
        }
        else
        {
            if (principal?.IsBounded != true || !Same(principal.Account, login)) return null;
            groupSids = principal.GroupSids.ToHashSet(StringComparer.Ordinal);
        }
        var groups = query("SELECT SID,Name,Domain FROM Win32_Group WHERE LocalAccount=True AND SID='S-1-5-32-544'");
        if (groups.Count != 1 || !groups[0].IsGroup || groups[0].Sid != "S-1-5-32-544" || !LocalDomain(groups[0].Domain, computer)) { return null; }
        var pending = new Queue<(LocalAccount Account, int Depth)>(); pending.Enqueue((groups[0], 0));
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase); var membersRead = 0;
        while (pending.TryDequeue(out var item))
        {
            token.ThrowIfCancellationRequested();
            if (!seen.Add(item.Account.Sid)) { continue; }
            if (seen.Count > 32 || item.Depth > 8) { return null; }
            var path = "Win32_Group.Domain=\"" + PathLiteral(item.Account.Domain) + "\",Name=\"" + PathLiteral(item.Account.Name) + "\"";
            var members = query("ASSOCIATORS OF {" + path + "} WHERE AssocClass=Win32_GroupUser");
            foreach (var member in members)
            {
                if (++membersRead > 4096) { return null; }
                if (user is not null && member.Sid == user.Sid && !member.IsGroup && Same(member.Name, user.Name) && Same(member.Domain, computer)) return user.Sid;
                // Resolve domain nesting with the authenticated LDAP token, never by WMI domain enumeration.
                if (principal is not null && !LocalDomain(member.Domain, computer)
                    && (!member.IsGroup && member.Sid == principal.AccountSid || member.IsGroup && groupSids!.Contains(member.Sid))) return principal.AccountSid;
                if (member.IsGroup && LocalDomain(member.Domain, computer)) { pending.Enqueue((member, item.Depth + 1)); }
            }
        }
        return null;

    }

    internal sealed record LocalAccount(string Sid, string Name, string Domain, bool IsGroup);
    private static bool LocalDomain(string domain, string computer) => Same(domain, computer) || Same(domain, "BUILTIN");
    private static bool Same(string left, string right) => string.Equals(left, right, StringComparison.OrdinalIgnoreCase);
    private static string Literal(string text) => text.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("'", "\\'", StringComparison.Ordinal);
    private static string PathLiteral(string text) => text.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("\"", "\\\"", StringComparison.Ordinal);
}
