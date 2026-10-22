using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// Fixed data of the fictitious domain that the generated directory does not carry and that only the audit reads: group
/// policy objects and their links, sites and subnets, trusts, fine-grained password policies, service principal names and
/// delegations, the security descriptors of the objects (docs/SIMULATION.md § 4 and docs/ops/audit.md). Deterministic: the
/// same names always give the same GUIDs, whatever the seed.
/// </summary>
internal static class SimulatedAuditData
{
    public const int MachineAccountQuota = 10;
    public const int DeletedObjectsVisible = 17;
    public const int DomainFunctionalLevel = 7;

    /// <summary>GUID derived from a name (SHA-256), stable across runs.</summary>
    public static Guid GuidOf(string name) => new(SHA256.HashData(Encoding.UTF8.GetBytes("audit/" + name)).AsSpan(0, 16));

    public sealed record Gpo(string Name, Guid Guid, int Flags, int DaysSinceChange);

    public static readonly Gpo DefaultDomain = new("Default Domain Policy", new Guid("31b2f340-016d-11d2-945f-00c04fb984f9"), 0, 412);
    public static readonly Gpo DefaultControllers = new("Default Domain Controllers Policy", new Guid("6ac1786c-016f-11d2-945f-00c04fb984f9"), 0, 412);
    public static readonly Gpo Edge = new("Navigateur - Microsoft Edge", GuidOf("gpo/edge"), 1, 37);
    public static readonly Gpo Baseline = new("Postes - Sécurité de base", GuidOf("gpo/baseline"), 1, 21);
    public static readonly Gpo Firewall = new("Postes - Pare-feu Windows", GuidOf("gpo/firewall"), 1, 64);
    public static readonly Gpo BitLocker = new("Postes - BitLocker (portables)", GuidOf("gpo/bitlocker"), 1, 95);
    public static readonly Gpo Laps = new("LAPS - Postes", GuidOf("gpo/laps"), 1, 140);
    public static readonly Gpo Updates = new("Postes - Mises à jour Windows", GuidOf("gpo/updates"), 1, 9);
    public static readonly Gpo ParisProxy = new("Postes Paris - Proxy", GuidOf("gpo/paris-proxy"), 1, 210);
    public static readonly Gpo Quarantine = new("Quarantaine - Restrictions", GuidOf("gpo/quarantine"), 0, 300);
    public static readonly Gpo Servers = new("Serveurs - Sécurité", GuidOf("gpo/servers"), 1, 48);
    public static readonly Gpo Drives = new("Utilisateurs - Lecteurs réseau", GuidOf("gpo/drives"), 2, 17);
    public static readonly Gpo Folders = new("Utilisateurs - Redirection des dossiers", GuidOf("gpo/folders"), 2, 501);
    public static readonly Gpo Legacy = new("Ancienne GPO - Windows 7", GuidOf("gpo/legacy"), 3, 1460);
    public static readonly Gpo Unlinked = new("Test - Ne pas lier", GuidOf("gpo/test"), 0, 233);
    public static readonly Gpo SiteParis = new("Site Paris - Serveur de mises à jour", GuidOf("gpo/site-paris"), 1, 120);

    public static ImmutableArray<Gpo> Gpos { get; } =
        [DefaultDomain, DefaultControllers, Edge, Baseline, Firewall, BitLocker, Laps, Updates, ParisProxy, Quarantine, Servers, Drives, Folders, Legacy, Unlinked, SiteParis];

    /// <summary>Links by container (path from the root, « » for the root), with their gPLink options and gPOptions.</summary>
    public sealed record ContainerLinks(string Path, int GpOptions, ImmutableArray<(Gpo Gpo, int Options)> Links);

    public static ImmutableArray<ContainerLinks> Links { get; } =
    [
        new(string.Empty, 0, [(DefaultDomain, 0), (Edge, 0)]),
        new("OU=Domain Controllers", 0, [(DefaultControllers, 0)]),
        new("OU=Postes", 0, [(Baseline, 2), (Firewall, 0), (BitLocker, 0), (Laps, 0), (Updates, 0)]),
        new("OU=Paris,OU=Postes", 0, [(ParisProxy, 0)]),
        new("OU=Quarantaine,OU=Postes", 1, [(Quarantine, 0)]),
        new("OU=Serveurs", 0, [(Servers, 0)]),
        new("OU=Utilisateurs", 0, [(Drives, 0), (Folders, 1)]),
        new("OU=Départs,OU=Utilisateurs", 0, [(Legacy, 0)]),
    ];

    public static string GpLink(ImmutableArray<(Gpo Gpo, int Options)> links, string rootDn) =>
        string.Concat(links.Reverse().Select(l => "[LDAP://cn={" + l.Gpo.Guid.ToString("D").ToUpperInvariant() + "},cn=policies,cn=system," + rootDn + ";" + l.Options.ToString(System.Globalization.CultureInfo.InvariantCulture) + "]"));

    public sealed record Site(string Name, string Description, string Code, ImmutableArray<string> Subnets);

    public static ImmutableArray<Site> Sites { get; } =
    [
        new("Paris", "Siège, salle serveurs principale", "PAR", ["10.10.0.0/16", "10.11.0.0/16"]),
        new("Lyon", "Agence et second contrôleur", "LYO", ["10.20.0.0/16", "10.21.0.0/24"]),
        new("Marseille", "Agence", "MRS", ["10.30.0.0/16"]),
        new("Lille", "Agence", "LIL", ["10.40.0.0/16"]),
        new("Bordeaux", "Agence", "BDX", ["10.50.0.0/16", "10.51.0.0/24"]),
    ];

    /// <summary>Second octet of the workstation addresses of a site code (« PC-LYO-0001 » → 20).</summary>
    public static int SiteOctet(string code) => code switch
    {
        "PAR" => 10,
        "LYO" => 20,
        "MRS" => 30,
        "LIL" => 40,
        "BDX" => 50,
        _ => 90,
    };

    public const string TrustName = "filiale.example.net";
    public const string TrustNetbios = "FILIALE";

    /// <summary>Service principal names of the service accounts (Kerberoasting targets).</summary>
    public static ImmutableDictionary<string, ImmutableArray<string>> ServicePrincipalNames { get; } = new Dictionary<string, ImmutableArray<string>>(StringComparer.OrdinalIgnoreCase)
    {
        ["svc-sql"] = ["MSSQLSvc/srv-sql-01.example.local:1433", "MSSQLSvc/srv-sql-02.example.local:1433", "MSSQLSvc/srv-sql-03.example.local:1433"],
        ["svc-web"] = ["HTTP/intranet.example.local", "HTTP/srv-web-01.example.local"],
        ["svc-sauvegarde"] = ["BackupSvc/srv-fic-01.example.local"],
        ["svc-supervision"] = ["HOST/srv-app-02.example.local"],
        ["svc-paie"] = ["HTTP/paie.example.local"],
    }.ToImmutableDictionary(StringComparer.OrdinalIgnoreCase);

    public const string ConstrainedDelegationAccount = "svc-web";
    public const string ConstrainedDelegationTarget = "MSSQLSvc/srv-sql-01.example.local:1433";
    public const string ReplicationRightsAccount = "svc-annuaire";

    public static readonly Guid ReplicateChanges = new("1131f6aa-9c07-11d1-f79f-00c04fc2dcd2");
    public static readonly Guid ReplicateAllChanges = new("1131f6ad-9c07-11d1-f79f-00c04fc2dcd2");
    public static readonly Guid ResetPassword = new("00299570-246d-11d0-a768-00aa006e0529");
    public static readonly Guid ChangePassword = new("ab721a53-1e2f-11d0-9819-00aa0040529b");
    public static readonly Guid LockoutTime = new("28630ebf-41d5-11d1-a9c1-0000f80367c1");
    public static readonly Guid Member = new("bf9679c0-0de6-11d0-a285-00aa003049e2");
    public static readonly Guid PersonalInformation = new("77b5b886-944a-11d1-aebd-0000f80367c1");
    public static readonly Guid GeneralInformation = new("59ba2f42-79a2-11d0-9020-00c04fc2d3cf");
    public static readonly Guid PublicInformation = new("e48d0154-bcf8-11d1-8702-00c04fb96050");
    public static readonly Guid RemoteAccess = new("037088f8-0ae1-11d2-b422-00a0c968f939");
    public static readonly Guid DnsHostNameWrite = new("72e39547-7b18-11d1-adef-00c04fd8d5cd");
    public static readonly Guid SpnWrite = new("f3a64788-5306-11d1-a9c5-0000f80367c1");
    public static readonly Guid UserClass = new("bf967aba-0de6-11d0-a285-00aa003049e2");
    public static readonly Guid ComputerClass = new("bf967a86-0de6-11d0-a285-00aa003049e2");
    public static readonly Guid GroupClass = new("bf967a9c-0de6-11d0-a285-00aa003049e2");
    public static readonly Guid ApplyGroupPolicy = new("edacfd8f-ffb3-11d1-b41d-00a0c968f939");

    /// <summary>Fine-grained password policies: name, precedence, rules, and the groups or accounts they apply to.</summary>
    public sealed record Pso(string Name, int Precedence, int MinLength, int History, bool Complexity, TimeSpan? MaxAge, int LockoutThreshold, TimeSpan? LockoutDuration, ImmutableArray<string> AppliesToGroups, bool ServiceAccounts);

    public static readonly Pso PrivilegedPso = new("PSO-Comptes-a-privileges", 10, 16, 24, true, TimeSpan.FromDays(90), 3, null, ["GG-Admins-Postes", "GG-Admins-Serveurs"], false);
    public static readonly Pso ServicePso = new("PSO-Comptes-de-service", 20, 24, 12, true, null, 0, TimeSpan.FromMinutes(30), [], true);

    public static ImmutableArray<Pso> Psos { get; } = [PrivilegedPso, ServicePso];

    public static readonly string[] Partitions =
    [
        "DC=example,DC=local",
        "CN=Configuration,DC=example,DC=local",
        "CN=Schema,CN=Configuration,DC=example,DC=local",
        "DC=DomainDnsZones,DC=example,DC=local",
        "DC=ForestDnsZones,DC=example,DC=local",
    ];

    /// <summary>Sources of the stored relation history (user_machine_history), with their nature.</summary>
    public static readonly (string Source, RelationKind Kind)[] HistorySources =
    [
        ("Session console (relevé WMI de Domenia)", RelationKind.Console),
        ("Journal de sécurité (événement 4624)", RelationKind.History),
        ("Profil utilisateur (C:\\Users)", RelationKind.History),
        ("Session distante (relevé de Domenia)", RelationKind.RemoteSession),
        ("Import CSV du parc (inventaire 2026)", RelationKind.Imported),
    ];
}
