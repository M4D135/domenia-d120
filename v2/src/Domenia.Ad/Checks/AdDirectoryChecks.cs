using System.Collections.Immutable;
using System.Diagnostics;
using System.DirectoryServices;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>
/// Directory checks of « Vérifier l’application » for the Active Directory source (Domenia 1 Start-SelfCheck, OPE-007; docs/ops/
/// operations.md § 8): RootDSE binding, read of the base, one user, one computer and one group searched, first level of the tree,
/// DACL of the base, and in a full check three repeated searches. Read only, on the controller of the session (or the one the
/// domain locator gives), with the Windows session (Kerberos, signed and sealed), size limits of 1 to 25 objects, 10 s per read,
/// never retried; a failed read is a row in error, never an exception. No object name is written in the report: only counts,
/// the controller and the base. The constructor reads nothing; the simulation never calls it (its own reader answers first, and
/// a source that is not Active Directory gets a single row saying so).
/// </summary>
public sealed class AdDirectoryChecks : IDirectoryChecks
{
    /// <summary>Longest wait for one read (Domenia 1: 10 s, no new attempt).</summary>
    public static readonly TimeSpan ReadTimeout = TimeSpan.FromSeconds(10);

    private const AuthenticationTypes Binding = AuthenticationTypes.Secure | AuthenticationTypes.Signing | AuthenticationTypes.Sealing;
    private const string Users = "(&(objectCategory=person)(objectClass=user))";

    private readonly IDirectorySource source;

    public AdDirectoryChecks(IDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
    }

    public async Task<ImmutableArray<CheckRow>> CheckDirectoryAsync(bool full, CancellationToken cancellationToken)
    {
        if (source.Kind != DirectorySourceKind.ActiveDirectory)
        {
            return [new CheckRow("Annuaire", "Lecture de l’annuaire", CheckStatus.Info, 0, "Source sans annuaire réel" + FrenchText.Colon + "aucune lecture LDAP n’est lancée.")];
        }
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var server = session.Controller?.DnsName;
        var rows = new List<CheckRow>();
        string? naming = null;
        await MeasureAsync(rows, "Annuaire", "Liaison RootDSE", () =>
        {
            using var root = Entry(server, "RootDSE");
            naming = First(root, "defaultNamingContext");
            var host = First(root, "dnsHostName");
            return naming is null
                ? (CheckStatus.Error, "defaultNamingContext vide" + FrenchText.Colon + "le contrôleur n’a pas donné la base du domaine.")
                : (CheckStatus.Ok, "Contrôleur " + (host ?? server ?? "trouvé par le localisateur du domaine") + " · base " + naming + ".");
        }, cancellationToken).ConfigureAwait(false);
        if (naming is not string baseDn)
        {
            rows.Add(new CheckRow("Annuaire", "Contrôles suivants", CheckStatus.Info, 0, "Non lancés" + FrenchText.Colon + "sans base du domaine, rien d’autre n’est lu."));
            return [.. rows];
        }
        await MeasureAsync(rows, "Annuaire", "Lecture de la base", () =>
        {
            var found = Search(server, baseDn, "(objectClass=*)", SearchScope.Base, ["distinguishedName", "objectClass"], 1);
            return found == 1 ? (CheckStatus.Ok, "Base lue (distinguishedName, objectClass).") : (CheckStatus.Error, "Base illisible avec le compte de la session.");
        }, cancellationToken).ConfigureAwait(false);
        await MeasureAsync(rows, "Annuaire", "Recherche utilisateur", () => Found(Search(server, baseDn, Users, SearchScope.Subtree, ["name"], 1), "compte utilisateur"), cancellationToken).ConfigureAwait(false);
        await MeasureAsync(rows, "Annuaire", "Recherche machine", () => Found(Search(server, baseDn, "(objectCategory=computer)", SearchScope.Subtree, ["name"], 1), "ordinateur"), cancellationToken).ConfigureAwait(false);
        await MeasureAsync(rows, "Annuaire", "Recherche groupe", () => Found(Search(server, baseDn, "(objectCategory=group)", SearchScope.Subtree, ["name"], 1), "groupe"), cancellationToken).ConfigureAwait(false);
        await MeasureAsync(rows, "Annuaire", "Lecture de l’arborescence", () =>
        {
            var found = Search(server, baseDn, "(|(objectClass=organizationalUnit)(objectClass=container))", SearchScope.OneLevel, ["name"], 5);
            return found > 0
                ? (CheckStatus.Ok, FrenchText.Count(found, "branche lue", "branches lues") + " à la racine du domaine (5 au plus).")
                : (CheckStatus.Warn, "Aucune OU ni conteneur lu à la racine du domaine.");
        }, cancellationToken).ConfigureAwait(false);
        await MeasureAsync(rows, "Sécurité", "Lecture des droits de la base", () =>
        {
            using var entry = Entry(server, baseDn);
            if (entry.Options is { } options)
            {
                options.SecurityMasks = SecurityMasks.Dacl;
            }
            var rules = entry.ObjectSecurity.GetAccessRules(true, false, typeof(SecurityIdentifier));
            return (CheckStatus.Ok, "Liste de contrôle d’accès de la base lue" + FrenchText.Colon + FrenchText.Count(rules.Count, "entrée", "entrées") + " (lecture seule).");
        }, cancellationToken).ConfigureAwait(false);
        if (full)
        {
            await MeasureAsync(rows, "Mesure", "Recherches répétées", () =>
            {
                var times = new List<double>();
                for (var i = 0; i < 3; i++)
                {
                    var start = Stopwatch.GetTimestamp();
                    Search(server, baseDn, "(|" + Users + "(objectCategory=computer))", SearchScope.Subtree, ["name"], 25);
                    times.Add(Stopwatch.GetElapsedTime(start).TotalMilliseconds);
                }
                return (CheckStatus.Ok, "Mesures" + FrenchText.Colon + string.Join(" / ", times.Select(t => FrenchText.Integer((long)Math.Round(t)))) + FrenchText.Nbsp + "ms, moyenne "
                    + ActivityRules.Duration(times.Average()) + " (25 objets au plus par recherche).");
            }, cancellationToken).ConfigureAwait(false);
        }
        return [.. rows];
    }

    /// <summary>Runs one read off the calling thread, bounded to <see cref="ReadTimeout"/>, and records its row and duration.</summary>
    private static async Task MeasureAsync(List<CheckRow> rows, string category, string test, Func<(CheckStatus Status, string Detail)> read, CancellationToken cancellationToken)
    {
        var start = Stopwatch.GetTimestamp();
        CheckStatus status;
        string detail;
        try
        {
            (status, detail) = await Task.Run(read, cancellationToken).WaitAsync(ReadTimeout, cancellationToken).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            (status, detail) = (CheckStatus.Error, "Délai de " + FrenchText.Integer((long)ReadTimeout.TotalSeconds) + FrenchText.Nbsp + "s dépassé" + FrenchText.Colon + "lecture abandonnée, aucune nouvelle tentative.");
        }
        catch (Exception ex) when (ex is COMException or UnauthorizedAccessException or InvalidOperationException or ArgumentException or NotSupportedException)
        {
            (status, detail) = (CheckStatus.Error, Reason(ex));
        }
        rows.Add(new CheckRow(category, test, status, Math.Round(Stopwatch.GetElapsedTime(start).TotalMilliseconds, 1), detail));
    }

    private static (CheckStatus, string) Found(int count, string what) =>
        count > 0 ? (CheckStatus.Ok, "Un " + what + " lu (nom non repris dans le rapport).") : (CheckStatus.Warn, "Aucun " + what + " lu avec le compte de la session.");

    private static int Search(string? server, string baseDn, string filter, SearchScope scope, string[] attributes, int limit)
    {
        using var root = Entry(server, baseDn);
        using var searcher = new DirectorySearcher(root, filter, attributes, scope)
        {
            SizeLimit = limit,
            ClientTimeout = ReadTimeout,
            ServerTimeLimit = ReadTimeout,
            ReferralChasing = ReferralChasingOption.None,
        };
        using var results = searcher.FindAll();
        return results.Count;
    }

    private static DirectoryEntry Entry(string? server, string dn)
    {
        // A « / » of a DN is escaped in an ADsPath.
        var path = "LDAP://" + (string.IsNullOrWhiteSpace(server) ? "" : server + "/") + dn.Replace("/", "\\/", StringComparison.Ordinal);
        return new DirectoryEntry(path, null, null, Binding);
    }

    private static string? First(DirectoryEntry entry, string attribute) =>
        entry.Properties[attribute] is { Count: > 0 } values && values[0] is string text && text.Length > 0 ? text : null;

    /// <summary>A fixed French reason from the result code, never the message of the system (which may quote the server).</summary>
    private static string Reason(Exception ex)
    {
        var code = ex.HResult;
        return code switch
        {
            unchecked((int)0x8007203A) => "Serveur injoignable" + FrenchText.Colon + "le contrôleur ne répond pas (aucune nouvelle tentative).",
            unchecked((int)0x8007052E) => "Identifiants refusés par le contrôleur" + FrenchText.Colon + "lecture abandonnée.",
            unchecked((int)0x80070005) => "Accès refusé" + FrenchText.Colon + "le compte de la session ne peut pas lire cet élément.",
            unchecked((int)0x80072030) => "Objet introuvable sur le contrôleur.",
            unchecked((int)0x8007054B) => "Domaine introuvable" + FrenchText.Colon + "aucun contrôleur trouvé par le localisateur.",
            _ when ex is UnauthorizedAccessException => "Accès refusé" + FrenchText.Colon + "le compte de la session ne peut pas lire cet élément.",
            _ => "Lecture impossible (code 0x" + code.ToString("X8", CultureInfo.InvariantCulture) + ")" + FrenchText.Colon + "aucune nouvelle tentative.",
        };
    }
}
