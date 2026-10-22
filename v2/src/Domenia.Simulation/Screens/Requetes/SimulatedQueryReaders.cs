using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Wmi;

namespace Domenia.Simulation;

/// <summary>
/// Query workshop in simulation (docs/ops/requetes.md): the dataset is the fictitious directory as the session sees it, the
/// observations of the generated world and the probe readings derived from the sub-stream « screen/requetes »; a collection
/// renews the planned readings in memory. No network, no disk. Realistic, cancellable delays (« latency/screen/requetes »).
/// </summary>
public sealed class SimulatedQueryWorkshopReader : IQueryWorkshopReader
{
    private readonly SimulatedDirectorySource source;

    public SimulatedQueryWorkshopReader(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
    }

    public async Task<QueryDataset> DatasetAsync(CancellationToken cancellationToken)
    {
        await source.SimulateScreenLatencyAsync("requetes", 70, 180, cancellationToken).ConfigureAwait(false);
        return SimulatedQueryState.For(source).Dataset();
    }

    public async Task<QueryMeasureResult> MeasureAsync(QueryMeasureRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        // About 40 ms per workstation, four in parallel, bounded.
        var spread = Math.Min(2600, 300 + request.Computers.Length * 10);
        await source.SimulateScreenLatencyAsync("requetes/measure", 400, spread + 400, cancellationToken).ConfigureAwait(false);
        return SimulatedQueryState.For(source).Measure(request, source.Clock.GetUtcNow());
    }
}

/// <summary>
/// Advanced WMI reads in simulation: a fictitious but faithful catalog of namespaces, class definitions and schemas (the
/// classes of the delivered probe catalog, the declared associations, the account classes and the refused providers), and
/// instances drawn from the simulated readings of the chosen workstation. Secret properties never appear.
/// </summary>
public sealed class SimulatedQueryWmiReader : IQueryWmiReader
{
    private readonly SimulatedDirectorySource source;

    public SimulatedQueryWmiReader(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
    }

    private string ComputerName(Guid computer) =>
        source.CurrentDirectory.Computers.FirstOrDefault(c => c.ObjectGuid == computer)?.Name ?? throw new DomeniaOperationException(QueryErrors.WmiUnknownComputer, QueryErrors.WmiUnknownComputerMessage);

    private Task Wait(CancellationToken cancellationToken) => source.SimulateScreenLatencyAsync("requetes/wmi", 120, 420, cancellationToken);

    public async Task<WmiNamespaceList> NamespacesAsync(Guid computer, string ns, CancellationToken cancellationToken)
    {
        var name = ComputerName(computer);
        await Wait(cancellationToken).ConfigureAwait(false);
        var all = SimulatedWmiCatalog.Current.Namespaces;
        if (!all.Contains(ns, StringComparer.OrdinalIgnoreCase))
        {
            throw new DomeniaOperationException(QueryErrors.WmiInvalid, "Espace de noms absent de ce poste : rien n’a été lu.");
        }
        var depth = ns.Split('\\').Length;
        ImmutableArray<string> children = [.. all.Where(n => n.StartsWith(ns + "\\", StringComparison.OrdinalIgnoreCase) && n.Split('\\').Length == depth + 1).Take(500)];
        return new WmiNamespaceList(name, ns, children, false, source.Clock.GetUtcNow());
    }

    public async Task<WmiClassList> ClassesAsync(Guid computer, string ns, string? filter, CancellationToken cancellationToken)
    {
        var name = ComputerName(computer);
        await Wait(cancellationToken).ConfigureAwait(false);
        var prefix = filter?.TrimEnd('*') ?? "";
        var exact = filter is not null && !filter.EndsWith('*');
        var classes = SimulatedWmiCatalog.Current.Classes.Where(c => string.Equals(c.Namespace, ns, StringComparison.OrdinalIgnoreCase))
            .Where(c => prefix.Length == 0 || (exact ? string.Equals(c.Name, prefix, StringComparison.OrdinalIgnoreCase) : c.Name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)))
            .Select(c => new WmiClassInfo(c.Name, c.Properties.Length, c.Properties.Count(p => p.Key), c.Remark)).ToList();
        return new WmiClassList(name, ns, filter, [.. classes.Take(2000)], classes.Count > 2000, source.Clock.GetUtcNow());
    }

    public async Task<WmiClassSchema> SchemaAsync(Guid computer, string ns, string className, CancellationToken cancellationToken)
    {
        var name = ComputerName(computer);
        await Wait(cancellationToken).ConfigureAwait(false);
        var definition = SimulatedWmiCatalog.Current.Classes.FirstOrDefault(c => string.Equals(c.Namespace, ns, StringComparison.OrdinalIgnoreCase) && string.Equals(c.Name, className, StringComparison.OrdinalIgnoreCase))
            ?? throw new DomeniaOperationException(QueryErrors.WmiInvalid, "Classe absente de cet espace de noms : rien n’a été lu.");
        var secrets = definition.Properties.Where(p => WqlRules.IsSecret(p.Name)).Select(p => p.Name).ToImmutableArray();
        return new WmiClassSchema(name, ns, definition.Name, definition.Description, [.. definition.Properties.Where(p => !WqlRules.IsSecret(p.Name)).Take(1024)], secrets, source.Clock.GetUtcNow());
    }

    public async Task<WmiSelectResult> SelectAsync(Guid computer, string ns, WqlSelect select, int limit, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(select);
        var name = ComputerName(computer);
        await source.SimulateScreenLatencyAsync("requetes/wmi/select", 260, 900, cancellationToken).ConfigureAwait(false);
        var definition = SimulatedWmiCatalog.Current.Classes.FirstOrDefault(c => string.Equals(c.Namespace, ns, StringComparison.OrdinalIgnoreCase) && string.Equals(c.Name, select.ClassName, StringComparison.OrdinalIgnoreCase))
            ?? throw new DomeniaOperationException(QueryErrors.WmiInvalid, "Classe absente de cet espace de noms sur ce poste : rien n’a été lu.");
        var missing = select.ReferencedProperties.Where(p => definition.Properties.All(x => !string.Equals(x.Name, p, StringComparison.OrdinalIgnoreCase))).ToList();
        if (missing.Count > 0)
        {
            throw new DomeniaOperationException(QueryErrors.WmiInvalid, "Propriétés absentes du schéma du poste : " + string.Join(", ", missing) + ". Rien n’a été lu.");
        }
        var key = SimulatedWmiCatalog.KeyOf(definition.Name);
        var columns = select.Properties.ToList();
        if (key is not null && !columns.Contains(key, StringComparer.OrdinalIgnoreCase))
        {
            columns.Add(key);
        }
        var instances = SimulatedWmiCatalog.Instances(source, computer, definition).Where(i => WqlRules.Matches(select.Where, i)).ToList();
        var rows = instances.Take(limit).Select((values, index) => new WmiInstanceRow(
            key is not null && values.TryGetValue(key, out var id) && id is not null ? id : index.ToString(CultureInfo.InvariantCulture),
            columns.ToImmutableDictionary(c => c, c => values.FirstOrDefault(v => string.Equals(v.Key, c, StringComparison.OrdinalIgnoreCase)).Value, StringComparer.OrdinalIgnoreCase))).ToImmutableArray();
        var at = source.Clock.GetUtcNow();
        var requestKey = WqlRules.RequestKey(ns, select.CanonicalQuery);
        SimulatedQueryState.For(source).Store(computer, new StoredWmiResult(requestKey, at, true, rows.Length, instances.Count <= limit, instances.Count > limit));
        var note = definition.ProbeId is null && instances.Count == 0
            ? "Aucune instance sur ce poste fictif."
            : "Instances de l’annuaire fictif : valeurs plausibles, aucun poste réel n’a été contacté.";
        return new WmiSelectResult(name, computer, ns, definition.Name, select.CanonicalQuery, [.. columns], rows, instances.Count > limit, instances.Count, at, requestKey, note);
    }

    public async Task<WmiSelectResult> RelatedAsync(Guid computer, string ns, string sourceClass, WmiInstanceRow sourceRow, WmiRelationPreset preset, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(sourceRow);
        ArgumentNullException.ThrowIfNull(preset);
        var name = ComputerName(computer);
        await Wait(cancellationToken).ConfigureAwait(false);
        var target = SimulatedWmiCatalog.Current.Classes.FirstOrDefault(c => string.Equals(c.Name, preset.Result, StringComparison.OrdinalIgnoreCase) && string.Equals(c.Namespace, ns, StringComparison.OrdinalIgnoreCase))
            ?? throw new DomeniaOperationException(QueryErrors.WmiInvalid, "Classe liée absente de ce poste : rien n’a été lu.");
        var all = SimulatedWmiCatalog.Instances(source, computer, target).ToList();
        List<IReadOnlyDictionary<string, string?>> related;
        if (preset.Kind == "Reference")
        {
            var value = WqlRules.ReferenceValue(preset, sourceRow.Values.FirstOrDefault(v => string.Equals(v.Key, preset.SourceProperty, StringComparison.OrdinalIgnoreCase)).Value);
            related = [.. all.Where(i => string.Equals(i.GetValueOrDefault(preset.TargetProperty), value, StringComparison.OrdinalIgnoreCase))];
        }
        else
        {
            // Declared association: the provider links a few instances; the fictitious catalog keeps the link stable per instance.
            var random = source.ScreenStream("requetes").Fork("relation/" + computer.ToString("N") + "/" + preset.Id + "/" + sourceRow.Id);
            related = [.. all.Where(_ => random.Chance(all.Count <= 2 ? 100 : 30)).Take(5)];
        }
        var columns = preset.Properties.Length > 0 ? preset.Properties.ToList() : target.Properties.Where(p => p.CimType != "ref").Select(p => p.Name).Take(8).ToList();
        var key = SimulatedWmiCatalog.KeyOf(target.Name);
        var rows = related.Select((values, index) => new WmiInstanceRow(key is not null && values.GetValueOrDefault(key) is { } id ? id : index.ToString(CultureInfo.InvariantCulture),
            columns.ToImmutableDictionary(c => c, c => values.FirstOrDefault(v => string.Equals(v.Key, c, StringComparison.OrdinalIgnoreCase)).Value, StringComparer.OrdinalIgnoreCase))).ToImmutableArray();
        var canonical = preset.Kind == "Reference"
            ? "SELECT " + string.Join(", ", columns) + " FROM " + target.Name + " WHERE " + preset.TargetProperty + " = '" + sourceRow.Values.GetValueOrDefault(preset.SourceProperty) + "'"
            : "ASSOCIATORS OF {" + sourceClass + "." + sourceRow.Id + "} WHERE AssocClass = " + preset.Association;
        return new WmiSelectResult(name, computer, ns, target.Name, canonical, [.. columns], rows, false, rows.Length, source.Clock.GetUtcNow(), WqlRules.RequestKey(ns, canonical),
            "Relation déclarée par le fournisseur, lue au moment de la demande (annuaire fictif).");
    }
}

/// <summary>
/// Fictitious WMI catalog shared by the advanced WMI reader and the collection of the workshop: namespaces, class definitions
/// (the classes of the delivered probe catalog, the declared associations, the account classes and the refused providers) and
/// the instances of a simulated workstation, drawn from its probe readings. Secret properties never appear.
/// </summary>
internal static class SimulatedWmiCatalog
{
    internal sealed record ClassDef(string Namespace, string Name, string Description, ImmutableArray<WmiPropertyInfo> Properties, string? Remark, string? ProbeId);

    internal sealed record CatalogData(ImmutableArray<string> Namespaces, ImmutableArray<ClassDef> Classes);

    private static readonly Lazy<CatalogData> Data = new(BuildCatalog, LazyThreadSafetyMode.ExecutionAndPublication);

    public static CatalogData Current => Data.Value;

    public static string? KeyOf(string className) => Keys.GetValueOrDefault(className);

    public static ClassDef? Find(string ns, string className) =>
        Current.Classes.FirstOrDefault(c => string.Equals(c.Namespace, ns, StringComparison.OrdinalIgnoreCase) && string.Equals(c.Name, className, StringComparison.OrdinalIgnoreCase));

    private static readonly Dictionary<string, string> Keys = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Win32_LogicalDisk"] = "DeviceID",
        ["Win32_Service"] = "Name",
        ["Win32_Process"] = "Handle",
        ["Win32_NetworkAdapter"] = "DeviceID",
        ["Win32_NetworkAdapterConfiguration"] = "Index",
        ["Win32_OperatingSystem"] = "Name",
        ["Win32_ComputerSystem"] = "Name",
        ["Win32_BIOS"] = "SerialNumber",
        ["Win32_Processor"] = "DeviceID",
        ["Win32_Printer"] = "DeviceID",
        ["Win32_DiskDrive"] = "DeviceID",
        ["Win32_DiskPartition"] = "DeviceID",
        ["Win32_UserAccount"] = "SID",
        ["Win32_Group"] = "SID",
        ["MSFT_PhysicalDisk"] = "ObjectId",
        ["Win32_EncryptableVolume"] = "DeviceID",
    };

    private static readonly Dictionary<string, string> Descriptions = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Win32_LogicalDisk"] = "Volume local, amovible ou réseau vu par Windows (lettre, système de fichiers, taille, espace libre).",
        ["Win32_Service"] = "Service Windows : nom, état, mode de démarrage, processus hôte.",
        ["Win32_Process"] = "Processus en cours d’exécution au moment de la lecture.",
        ["Win32_OperatingSystem"] = "Système d’exploitation installé : édition, build, démarrage, mémoire.",
        ["Win32_ComputerSystem"] = "Ordinateur : fabricant, modèle, mémoire, type de système, utilisateur de la console.",
        ["Win32_NetworkAdapter"] = "Carte réseau physique ou virtuelle.",
        ["Win32_NetworkAdapterConfiguration"] = "Configuration IP d’une carte réseau (adresses, DHCP, DNS).",
        ["Win32_Processor"] = "Processeur : modèle, cœurs, fréquence, virtualisation.",
        ["Win32_BIOS"] = "Micrologiciel du poste : version, date, numéro de série.",
        ["Win32_UserAccount"] = "Compte d’utilisateur ; lisez seulement les comptes locaux (LocalAccount = TRUE).",
        ["Win32_Group"] = "Groupe ; lisez seulement les groupes locaux (LocalAccount = TRUE).",
        ["Win32_Product"] = "Logiciel installé par Windows Installer : fournisseur MSI interdit, sa lecture peut lancer une réparation.",
        ["Win32_DiskDrive"] = "Disque physique.",
        ["Win32_DiskPartition"] = "Partition d’un disque physique.",
        ["Win32_DiskDriveToDiskPartition"] = "Association : disque physique ↔ partitions.",
        ["Win32_LogicalDiskToPartition"] = "Association : partition ↔ volume logique.",
        ["Win32_NetworkAdapterSetting"] = "Association : carte réseau ↔ configuration IP.",
        ["Win32_DependentService"] = "Association : dépendances entre services.",
        ["CIM_DataFile"] = "Fichier du disque : classe coûteuse, toujours filtrer par WHERE.",
    };

    private static CatalogData BuildCatalog()
    {
        var namespaces = new SortedSet<string>(StringComparer.OrdinalIgnoreCase) { "root", "root\\cimv2", "root\\default", "root\\subscription", "root\\Interop", "root\\cimv2\\power", "root\\cimv2\\mdm" };
        var classes = new Dictionary<string, ClassDef>(StringComparer.OrdinalIgnoreCase);
        foreach (var probe in QueryProbeCatalog.All)
        {
            var ns = probe.Namespace;
            var parts = ns.Split('\\');
            for (var i = 1; i <= parts.Length; i++)
            {
                namespaces.Add(string.Join("\\", parts.Take(i)));
            }
            var key = ns.ToLowerInvariant() + "|" + probe.Class.ToLowerInvariant();
            var props = classes.TryGetValue(key, out var existing) ? existing.Properties.ToList() : [];
            foreach (var field in probe.Fields)
            {
                if (props.All(p => !string.Equals(p.Name, field.Name, StringComparison.OrdinalIgnoreCase)))
                {
                    props.Add(new WmiPropertyInfo(field.Name, field.CimType, Keys.TryGetValue(probe.Class, out var k) && string.Equals(k, field.Name, StringComparison.OrdinalIgnoreCase), field.Unit, field.Description.Length > 0 ? field.Description : "Propriété " + field.Name + "."));
                }
            }
            if (Keys.TryGetValue(probe.Class, out var keyName) && props.All(p => !string.Equals(p.Name, keyName, StringComparison.OrdinalIgnoreCase)))
            {
                props.Insert(0, new WmiPropertyInfo(keyName, "string", true, "", "Clé de l’instance."));
            }
            classes[key] = new ClassDef(ns, probe.Class, Descriptions.GetValueOrDefault(probe.Class, "Classe lue par la sonde « " + probe.Name + " »."), [.. props], null, existing?.ProbeId ?? probe.Id);
        }
        void Add(string ns, string name, string? remark, params (string Name, string Type, bool Key)[] properties)
        {
            var key = ns.ToLowerInvariant() + "|" + name.ToLowerInvariant();
            if (!classes.ContainsKey(key))
            {
                classes[key] = new ClassDef(ns, name, Descriptions.GetValueOrDefault(name, "Classe " + name + "."), [.. properties.Select(p => new WmiPropertyInfo(p.Name, p.Type, p.Key, "", "Propriété " + p.Name + "."))], remark, null);
            }
        }
        Add("root\\cimv2", "Win32_DiskDrive", null, ("DeviceID", "string", true), ("Model", "string", false), ("Size", "uint64", false), ("InterfaceType", "string", false), ("SerialNumber", "string", false));
        Add("root\\cimv2", "Win32_DiskPartition", null, ("DeviceID", "string", true), ("DiskIndex", "uint32", false), ("Index", "uint32", false), ("Size", "uint64", false), ("Bootable", "boolean", false));
        Add("root\\cimv2", "Win32_DiskDriveToDiskPartition", "Association", ("Antecedent", "ref", true), ("Dependent", "ref", true));
        Add("root\\cimv2", "Win32_LogicalDiskToPartition", "Association", ("Antecedent", "ref", true), ("Dependent", "ref", true));
        Add("root\\cimv2", "Win32_NetworkAdapterSetting", "Association", ("Element", "ref", true), ("Setting", "ref", true));
        Add("root\\cimv2", "Win32_DependentService", "Association", ("Antecedent", "ref", true), ("Dependent", "ref", true), ("TypeOfDependency", "uint16", false));
        Add("root\\cimv2", "Win32_UserAccount", null, ("SID", "string", true), ("Name", "string", false), ("Domain", "string", false), ("LocalAccount", "boolean", false), ("Disabled", "boolean", false),
            ("Lockout", "boolean", false), ("PasswordExpires", "boolean", false), ("PasswordRequired", "boolean", false), ("Description", "string", false));
        Add("root\\cimv2", "Win32_Group", null, ("SID", "string", true), ("Name", "string", false), ("Domain", "string", false), ("LocalAccount", "boolean", false), ("Description", "string", false));
        Add("root\\cimv2", "Win32_Account", "Abstraite", ("SID", "string", true), ("Name", "string", false), ("Domain", "string", false), ("LocalAccount", "boolean", false));
        Add("root\\cimv2", "Win32_Product", "Fournisseur MSI refusé", ("IdentifyingNumber", "string", true), ("Name", "string", false), ("Version", "string", false), ("Vendor", "string", false));
        Add("root\\cimv2", "CIM_DataFile", "Coûteuse : filtrer par WHERE", ("Name", "string", true), ("FileSize", "uint64", false), ("LastModified", "datetime", false));
        Add("root\\cimv2", "Win32_GroupUser", "Association refusée (domaine)", ("GroupComponent", "ref", true), ("PartComponent", "ref", true));
        Add("root\\cimv2", "CIM_LogicalElement", "Abstraite, refusée", ("Name", "string", true));
        Add("root\\cimv2", "Win32_QuickFixEngineering", null, ("HotFixID", "string", true), ("Description", "string", false), ("InstalledOn", "string", false), ("InstalledBy", "string", false));
        return new CatalogData([.. namespaces], [.. classes.Values.OrderBy(c => c.Namespace, StringComparer.OrdinalIgnoreCase).ThenBy(c => c.Name, StringComparer.OrdinalIgnoreCase)]);
    }


    /// <summary>Instances of a class on a simulated workstation, as text, from the readings of its probes.</summary>
    public static IEnumerable<IReadOnlyDictionary<string, string?>> Instances(SimulatedDirectorySource source, Guid computer, ClassDef definition)
    {
        var state = SimulatedQueryState.For(source);
        var profile = state.Profile(computer);
        if (profile is null)
        {
            yield break;
        }
        var probes = QueryProbeCatalog.All.Where(p => string.Equals(p.Class, definition.Name, StringComparison.OrdinalIgnoreCase) && string.Equals(p.Namespace, definition.Namespace, StringComparison.OrdinalIgnoreCase))
            .OrderBy(p => p.Mode == "All" ? 0 : p.Mode == "Count" ? 1 : 2).ToList();
        var random = source.ScreenStream("requetes").Fork("wmi/" + computer.ToString("N"));
        var at = source.Clock.GetUtcNow();
        var merged = new List<Dictionary<string, string?>>();
        foreach (var probe in probes)
        {
            var reading = SimulatedQueryProbes.Reading(probe, profile, at, random.Fork(probe.Id), fresh: true);
            for (var i = 0; i < reading.Instances.Length; i++)
            {
                while (merged.Count <= i)
                {
                    merged.Add(new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase));
                }
                foreach (var (property, value) in reading.Instances[i].Values)
                {
                    merged[i].TryAdd(property, value is null ? null : QueryProbeCatalog.Invariant(value));
                }
            }
            if (probe.Mode == "All" && merged.Count > 0 && probes.Count > 1 && probe.Mode != "First")
            {
                // A detailed collection probe gives the list of instances; first-instance probes complete the first one.
                continue;
            }
        }
        var key = KeyOf(definition.Name);
        switch (definition.Name.ToUpperInvariant())
        {
            case "WIN32_PROCESS":
                foreach (var row in merged)
                {
                    row["Handle"] = row.GetValueOrDefault("ProcessId");
                }
                break;
            case "WIN32_USERACCOUNT":
                merged = [
                    new(StringComparer.OrdinalIgnoreCase) { ["SID"] = "S-1-5-21-111-222-333-500", ["Name"] = "Administrateur", ["Domain"] = profile.Name, ["LocalAccount"] = "True", ["Disabled"] = "False", ["Lockout"] = "False", ["Description"] = "Compte d’administration intégré" },
                    new(StringComparer.OrdinalIgnoreCase) { ["SID"] = "S-1-5-21-111-222-333-501", ["Name"] = "Invité", ["Domain"] = profile.Name, ["LocalAccount"] = "True", ["Disabled"] = "True", ["Lockout"] = "False", ["Description"] = "Compte invité intégré" },
                    new(StringComparer.OrdinalIgnoreCase) { ["SID"] = "S-1-5-21-111-222-333-1001", ["Name"] = "support", ["Domain"] = profile.Name, ["LocalAccount"] = "True", ["Disabled"] = random.Chance(30) ? "True" : "False", ["Lockout"] = "False", ["Description"] = "Support de proximité" },
                ];
                break;
            case "WIN32_GROUP":
                merged = [
                    new(StringComparer.OrdinalIgnoreCase) { ["SID"] = "S-1-5-32-544", ["Name"] = "Administrateurs", ["Domain"] = "BUILTIN", ["LocalAccount"] = "True", ["Description"] = "Accès complet à l’ordinateur" },
                    new(StringComparer.OrdinalIgnoreCase) { ["SID"] = "S-1-5-32-545", ["Name"] = "Utilisateurs", ["Domain"] = "BUILTIN", ["LocalAccount"] = "True", ["Description"] = "Utilisateurs de l’ordinateur" },
                    new(StringComparer.OrdinalIgnoreCase) { ["SID"] = "S-1-5-32-555", ["Name"] = "Utilisateurs du Bureau à distance", ["Domain"] = "BUILTIN", ["LocalAccount"] = "True", ["Description"] = "Ouverture de session à distance" },
                ];
                break;
            case "WIN32_DISKDRIVE":
                merged = [new(StringComparer.OrdinalIgnoreCase) { ["DeviceID"] = "\\\\.\\PHYSICALDRIVE0", ["Model"] = profile.Maker == "LENOVO" ? "SAMSUNG MZVL2512HCJQ" : "KIOXIA KXG80ZNV512G", ["Size"] = profile.DiskSize.ToString(CultureInfo.InvariantCulture), ["InterfaceType"] = "SCSI", ["SerialNumber"] = "0000_0000_" + random.Next(1000, 9999).ToString(CultureInfo.InvariantCulture) }];
                break;
            case "WIN32_DISKPARTITION":
                merged = [
                    new(StringComparer.OrdinalIgnoreCase) { ["DeviceID"] = "Disque n° 0, partition n° 0", ["DiskIndex"] = "0", ["Index"] = "0", ["Size"] = "272629760", ["Bootable"] = "True" },
                    new(StringComparer.OrdinalIgnoreCase) { ["DeviceID"] = "Disque n° 0, partition n° 1", ["DiskIndex"] = "0", ["Index"] = "1", ["Size"] = profile.DiskSize.ToString(CultureInfo.InvariantCulture), ["Bootable"] = "False" },
                ];
                break;
            case "WIN32_PRODUCT":
            case "CIM_DATAFILE":
            case "WIN32_GROUPUSER":
            case "CIM_LOGICALELEMENT":
                merged = [];
                break;
        }
        foreach (var row in merged)
        {
            if (key is not null && !row.ContainsKey(key))
            {
                row[key] = definition.Name + "." + merged.IndexOf(row).ToString(CultureInfo.InvariantCulture);
            }
            foreach (var property in definition.Properties)
            {
                row.TryAdd(property.Name, null);
            }
            yield return row;
        }
    }
}
