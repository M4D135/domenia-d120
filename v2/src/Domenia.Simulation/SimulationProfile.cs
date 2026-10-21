using System.Collections.Immutable;

namespace Domenia.Simulation;

/// <summary>One service OU of the users tree, with its number of people.</summary>
public sealed record ServiceSpec(string Site, string Name, string GroupName, int People);

/// <summary>One site: OU name, computer code, phone prefix reserved for fiction (ARCEP) and active workstations.</summary>
public sealed record SiteSpec(string Name, string Code, string PhonePrefix, int Workstations);

/// <summary>Operating system share of the active workstations.</summary>
public sealed record OsSpec(string OperatingSystem, string Version, int Count);

/// <summary>Every count and distribution of the fictitious directory (docs/SIMULATION.md § 4 and 5), as named constants.</summary>
public static class SimulationProfile
{
    public const string DnsName = "example.local";
    public const string NetbiosName = "EXAMPLE";
    public const string RootDn = "DC=example,DC=local";
    public const string SessionLogin = "j.martin";
    public const string WorkingOuName = "Postes";

    public static ImmutableArray<SiteSpec> Sites { get; } =
    [
        new("Paris", "PAR", "+33 1 99 00", 186),
        new("Lyon", "LYO", "+33 4 65 71", 82),
        new("Marseille", "MRS", "+33 4 65 71", 64),
        new("Lille", "LIL", "+33 3 53 01", 44),
        new("Bordeaux", "BDX", "+33 5 36 49", 36),
    ];

    public static ImmutableArray<ServiceSpec> Services { get; } =
    [
        new("Paris", "Direction", "Direction", 18),
        new("Paris", "Finances", "Finances", 92),
        new("Paris", "Ressources humaines", "RH", 64),
        new("Paris", "Informatique", "Informatique", 71),
        new("Paris", "Juridique", "Juridique", 33),
        new("Paris", "Communication", "Communication", 41),
        new("Paris", "Achats", "Achats", 52),
        new("Paris", "Commercial", "Commercial", 189),
        new("Lyon", "Commercial", "Commercial", 141),
        new("Lyon", "Logistique", "Logistique", 89),
        new("Marseille", "Commercial", "Commercial", 102),
        new("Marseille", "Logistique", "Logistique", 88),
        new("Lille", "Commercial", "Commercial", 130),
        new("Bordeaux", "Commercial", "Commercial", 78),
    ];

    public const int Departures = 48;
    public const int LongLeave = 22;
    public const int AdminAccounts = 6;
    public const int ServiceAccounts = 13;

    // Exact populations among the active people (password and lock states).
    public const int NeverExpiringPeople = 2;
    public const int MustChange = 4;
    public const int Expired = 11;
    public const int Expiring = 23;
    public const int LockedPeople = 6; // plus Camille Bernard: 7 locked accounts
    public const int LockoutExpired = 2;
    public const int RecentWithoutLogon = 5; // plus the 4 « must change »: 9 created this month, never logged on
    public const int StaleLogonPeople = 40;
    public const int Interns = 6;
    public const int BadPasswordPeople = 30;

    public static ImmutableArray<OsSpec> WorkstationSystems { get; } =
    [
        new("Windows 11 Entreprise", "10.0 (26100)", 214),
        new("Windows 11 Entreprise", "10.0 (22631)", 96),
        new("Windows 11 Entreprise", "10.0 (26200)", 58),
        new("Windows 10 Entreprise", "10.0 (19045)", 23),
        new("Windows 10 Entreprise LTSC", "10.0 (19044)", 12),
        new("Windows 11 Professionnel", "10.0 (26100)", 9),
    ];

    public const int LaptopPercent = 30;
    public const int QuarantinedWorkstations = 19;
    public const int JustJoinedWorkstations = 3;

    // Exact workstation states among the 412 active ones (disjoint sets).
    public const int StaleWorkstations = 11;
    public const int NeverLoggedOnWorkstations = 2;
    public const int MachinePasswordOldOnly = 3;
    public const int RecentlyCreatedWorkstations = 4;
    public const int ErrorProbes = 3;
    public const int WithoutLaps = 23;
    public const int LapsExpired = 8;

    // Presence of the initial round.
    public const int OnlineWorkday = 287;
    public const int OnlineWeekend = 61;
    public const int NeverChecked = 12; // including the 3 error probes
    public const int CheckExpired = 15;
    public const int CheckAging = 39;
    public const int RoundSpread = 6;
    public const int RoundJitter = 40;

    // Inventory.
    public static ImmutableArray<double> CriticalDiskPercents { get; } = [3.1, 4.0, 5.2, 6.4, 7.7, 8.3, 8.9, 9.4, 9.8];
    public const int PingFilteredIndex = 4; // the critical disk at 7,7 %: answers WMI, never ping
    public const int TightDisks = 17;
    public const int LongUptime = 21;
    public const int WithoutInventoryOthers = 25; // plus the 13 inactive and the 3 error probes: 41
    public const int InactiveWithExpiredInventory = 8;

    public static ImmutableArray<string> LaptopModels { get; } = ["Dell Latitude 5440", "HP EliteBook 840 G10", "Lenovo ThinkPad T14 Gen 4"];
    public static ImmutableArray<string> DesktopModels { get; } = ["Dell OptiPlex 7010", "HP EliteDesk 800 G6", "Lenovo ThinkCentre M70q"];

    public static ImmutableArray<string> ServiceAccountNames { get; } =
    [
        "svc-sauvegarde", "svc-impression", "svc-sql", "svc-web", "svc-messagerie", "svc-scan", "svc-supervision",
        "svc-antivirus", "svc-deploiement", "svc-annuaire", "svc-gestion", "svc-paie", "svc-finance",
    ];

    public static ImmutableArray<(string Sam, string Given, string Surname, bool Female)> AdminPeople { get; } =
    [
        ("adm-j.martin", "Julien", "Martin", false),
        ("adm-s.leroy", "Sophie", "Leroy", true),
        ("adm-n.petit", "Nicolas", "Petit", false),
        ("adm-p.moreau", "Pauline", "Moreau", true),
        ("adm-c.girard", "Céline", "Girard", true),
        ("adm-a.roux", "Antoine", "Roux", false),
    ];
}
