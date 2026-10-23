using System.Collections.Frozen;
using System.Globalization;

namespace Domenia.Core.Poste;

/// <summary>Meaning of the last result of a scheduled task (SCHED_S_* codes are states, not failures).</summary>
public sealed record TaskResultText(string Code, string Text, bool? Failure);

/// <summary>
/// Closed tables that turn CIM codes into French labels (Domenia 1 UX-37, Get-DomeniaInventoryValueText and the readings):
/// a value the table does not know comes back as it is — a made-up label could not be checked anywhere, a raw code can.
/// The raw value is always kept beside the label (tip, copy, export). Pure.
/// </summary>
public static class PosteLabels
{
    private static readonly FrozenDictionary<string, string> Roles = new Dictionary<string, string>
    {
        ["0"] = "Poste autonome",
        ["1"] = "Poste membre du domaine",
        ["2"] = "Serveur autonome",
        ["3"] = "Serveur membre du domaine",
        ["4"] = "Contrôleur de domaine de sauvegarde",
        ["5"] = "Contrôleur de domaine principal",
    }.ToFrozenDictionary(StringComparer.Ordinal);

    private static readonly FrozenDictionary<string, string> Chassis = new Dictionary<string, string>
    {
        ["1"] = "Autre", ["2"] = "Inconnu", ["3"] = "Bureau", ["4"] = "Bureau (profil bas)", ["5"] = "Bureau (format pizza)",
        ["6"] = "Tour", ["7"] = "Portable", ["8"] = "Portable", ["9"] = "Portable", ["10"] = "Portable", ["11"] = "Station d’accueil",
        ["12"] = "Bureau (tout-en-un)", ["13"] = "Portable (compact)", ["14"] = "Bureau (gain de place)", ["16"] = "Châssis principal",
        ["17"] = "Châssis d’extension", ["18"] = "Sous-châssis", ["23"] = "Baie (rack)", ["26"] = "Portable", ["28"] = "Station d’accueil",
        ["30"] = "Tablette", ["31"] = "Convertible", ["32"] = "Détachable", ["34"] = "Mini PC", ["35"] = "Mini PC",
        ["36"] = "Clé PC", ["37"] = "Serveur (densité faible)", ["38"] = "Serveur (densité moyenne)", ["39"] = "Serveur (densité élevée)", ["41"] = "Lame",
    }.ToFrozenDictionary(StringComparer.Ordinal);

    private static readonly FrozenDictionary<string, string> Languages = new Dictionary<string, string>
    {
        ["1031"] = "Allemand", ["1033"] = "Anglais (États-Unis)", ["1036"] = "Français", ["1040"] = "Italien", ["1043"] = "Néerlandais",
        ["1044"] = "Norvégien", ["1046"] = "Portugais (Brésil)", ["1049"] = "Russe", ["1053"] = "Suédois", ["1055"] = "Turc",
        ["1058"] = "Ukrainien", ["2057"] = "Anglais (Royaume-Uni)", ["2060"] = "Français (Belgique)", ["2070"] = "Portugais",
        ["3082"] = "Espagnol", ["3084"] = "Français (Canada)", ["4105"] = "Anglais (Canada)", ["4108"] = "Français (Suisse)",
    }.ToFrozenDictionary(StringComparer.Ordinal);

    private static readonly FrozenDictionary<string, string> NetStatus = new Dictionary<string, string>
    {
        ["0"] = "Déconnectée", ["1"] = "Connexion en cours", ["2"] = "Connectée", ["3"] = "Déconnexion en cours", ["4"] = "Matériel absent",
        ["5"] = "Matériel désactivé", ["6"] = "Panne matérielle", ["7"] = "Composant non installé", ["8"] = "Inconnu",
    }.ToFrozenDictionary(StringComparer.Ordinal);

    private static readonly FrozenDictionary<string, string> BitLockerMethods = new Dictionary<string, string>
    {
        ["0"] = "Inconnue", ["1"] = "AES 128 bits avec diffuseur", ["2"] = "AES 256 bits avec diffuseur", ["3"] = "AES 128 bits",
        ["4"] = "AES 256 bits", ["5"] = "Chiffrement matériel", ["6"] = "XTS-AES 128 bits", ["7"] = "XTS-AES 256 bits",
    }.ToFrozenDictionary(StringComparer.Ordinal);

    private static readonly FrozenDictionary<string, string> Smart = new Dictionary<string, string>
    {
        ["OK"] = "Sain", ["PRED FAIL"] = "Panne annoncée", ["PREDICTIVE FAILURE"] = "Panne annoncée", ["UNKNOWN"] = "Inconnu",
        ["N/A"] = "Non applicable", ["BAD"] = "Hors service", ["SERVICE"] = "En maintenance", ["DEGRADED"] = "Dégradé",
        ["OFFLINE"] = "Hors ligne", ["STARTING"] = "Démarrage", ["STOPPING"] = "Arrêt",
    }.ToFrozenDictionary(StringComparer.Ordinal);

    private static readonly FrozenDictionary<int, string> Media = new Dictionary<int, string>
    {
        [0] = "type non précisé", [3] = "disque dur", [4] = "SSD", [5] = "mémoire de classe stockage",
    }.ToFrozenDictionary();

    private static readonly FrozenDictionary<int, string> Buses = new Dictionary<int, string>
    {
        [1] = "SCSI", [2] = "ATAPI", [3] = "ATA", [4] = "IEEE 1394", [5] = "SSA", [6] = "Fibre Channel", [7] = "USB", [8] = "RAID",
        [9] = "iSCSI", [10] = "SAS", [11] = "SATA", [12] = "SD", [13] = "MMC", [14] = "virtuel", [15] = "fichier virtuel",
        [16] = "espaces de stockage", [17] = "NVMe",
    }.ToFrozenDictionary();

    private static readonly FrozenDictionary<int, string> BatteryStatuses = new Dictionary<int, string>
    {
        [1] = "sur batterie", [2] = "sur secteur", [3] = "chargée", [4] = "faible", [5] = "critique", [6] = "en charge",
        [7] = "en charge (haute)", [8] = "en charge (faible)", [9] = "en charge (critique)", [10] = "non défini", [11] = "partiellement chargée",
    }.ToFrozenDictionary();

    private static readonly FrozenDictionary<int, string> DeviceErrors = new Dictionary<int, string>
    {
        [1] = "mal configuré", [3] = "pilote endommagé ou ressources insuffisantes", [10] = "ne peut pas démarrer", [12] = "ressources insuffisantes",
        [14] = "redémarrage nécessaire", [18] = "pilotes à réinstaller", [19] = "configuration du registre endommagée", [21] = "en cours de suppression",
        [22] = "désactivé", [24] = "absent ou mal installé", [28] = "pilote non installé", [29] = "désactivé par le micrologiciel",
        [31] = "pilote non chargé", [32] = "service du pilote désactivé", [37] = "échec de l’initialisation du pilote", [39] = "pilote endommagé ou absent",
        [43] = "arrêté après un problème signalé", [45] = "déconnecté", [48] = "pilote bloqué (compatibilité)", [52] = "signature du pilote non vérifiée",
    }.ToFrozenDictionary();

    private static readonly FrozenDictionary<string, string> ServiceStates = new Dictionary<string, string>
    {
        ["Running"] = "En cours", ["Stopped"] = "Arrêté", ["Start Pending"] = "Démarrage en cours", ["Stop Pending"] = "Arrêt en cours",
        ["Paused"] = "En pause", ["Pause Pending"] = "Mise en pause en cours", ["Continue Pending"] = "Reprise en cours",
    }.ToFrozenDictionary(StringComparer.Ordinal);

    /// <summary>Classes of the MSI provider, never queried: reading them triggers a consistency check of every package.</summary>
    public static FrozenSet<string> MsiProviderClasses { get; } = new[]
    {
        "Win32_Product", "Win32_ProductCheck", "Win32_ProductResource", "Win32_ProductSoftwareFeatures", "Win32_SoftwareElement",
        "Win32_SoftwareElementCheck", "Win32_SoftwareFeature", "Win32_SoftwareFeatureCheck", "Win32_Property", "Win32_Patch",
        "Win32_PatchPackage", "Win32_ApplicationService", "Win32_InstalledSoftwareElement",
    }.ToFrozenSet(StringComparer.OrdinalIgnoreCase);

    /// <summary>Numeric key normalised: « 0409 » and « 409 » are the same language.</summary>
    private static string Key(string raw)
    {
        var key = raw.Trim();
        if (key.Length > 0 && key.All(char.IsAsciiDigit))
        {
            key = key.TrimStart('0');
            if (key.Length == 0)
            {
                key = "0";
            }
        }
        return key;
    }

    private static string Lookup(FrozenDictionary<string, string> table, string? raw) =>
        raw is null ? "" : table.TryGetValue(Key(raw), out var label) ? label : raw.Trim();

    public static string DomainRole(int? role) => role is int r ? Lookup(Roles, r.ToString(CultureInfo.InvariantCulture)) : "";

    /// <summary>ChassisTypes is a list: « 9, 10 » gives two labels, duplicates folded.</summary>
    public static string ChassisText(IEnumerable<int> codes)
    {
        ArgumentNullException.ThrowIfNull(codes);
        var labels = codes.Select(c => Lookup(Chassis, c.ToString(CultureInfo.InvariantCulture))).Distinct(StringComparer.Ordinal).ToList();
        return string.Join(", ", labels);
    }

    public static string Language(int? langId) => langId is int l ? Lookup(Languages, l.ToString(CultureInfo.InvariantCulture)) : "";

    /// <summary>« Connectée, 1 Gb/s » from NetConnectionStatus and the link speed in bits per second.</summary>
    public static string Adapter(int? status, long? speedBitsPerSecond)
    {
        var label = status is int s ? Lookup(NetStatus, s.ToString(CultureInfo.InvariantCulture)) : "État non lu";
        if (speedBitsPerSecond is not long speed || speed <= 0)
        {
            return label;
        }
        var mb = speed / 1_000_000d;
        var text = mb >= 1000 ? FrenchText.Decimal(mb / 1000d, mb % 1000 == 0 ? 0 : 1) + " Gb/s" : FrenchText.Decimal(mb, 0) + " Mb/s";
        return label + ", " + text;
    }

    public static string BitLockerMethod(int? method) => method is int m ? Lookup(BitLockerMethods, m.ToString(CultureInfo.InvariantCulture)) : "";

    public static string SmartStatus(string? status) => status is null ? "" : Smart.TryGetValue(status.Trim().ToUpperInvariant(), out var label) ? label : status.Trim();

    public static string MediaType(int? code) => code is not int c ? "" : Media.TryGetValue(c, out var label) ? label : "code " + c.ToString(CultureInfo.InvariantCulture);

    public static string BusType(int? code) => code is not int c ? "" : Buses.TryGetValue(c, out var label) ? label : "code " + c.ToString(CultureInfo.InvariantCulture);

    public static string BatteryStatus(int? code) => code is not int c ? "" : BatteryStatuses.TryGetValue(c, out var label) ? label : "code " + c.ToString(CultureInfo.InvariantCulture);

    /// <summary>Device manager error: disabled and disconnected devices are told apart from an anomaly.</summary>
    public static string DeviceError(int code) =>
        DeviceErrors.TryGetValue(code, out var label) ? "code " + code.ToString(CultureInfo.InvariantCulture) + FrenchText.Colon + label : "code " + code.ToString(CultureInfo.InvariantCulture);

    /// <summary>True when a device code is a choice (disabled, disconnected) rather than an anomaly.</summary>
    public static bool DeviceCodeIsChoice(int code) => code is 22 or 29 or 45;

    public static string ServiceState(string? state) => string.IsNullOrEmpty(state) ? "Non lu" : ServiceStates.TryGetValue(state, out var label) ? label : state;

    public static string ServiceStart(string? startMode, bool? delayed) => startMode switch
    {
        "Auto" => delayed switch { true => "Automatique (différé)", false => "Automatique", null => "Automatique (délai non lu)" },
        "Manual" => "Manuel",
        "Disabled" => "Désactivé",
        "Boot" => "Démarrage du système",
        "System" => "Système",
        null or "" => "Non lu",
        _ => startMode,
    };

    /// <summary>
    /// Last result of a scheduled task (Domenia 1 point 96): SCHED_S_* states are not failures; any other value is the exit
    /// code of the action or an error, shown as it is and to be checked. An unreadable code is « non lu », never guessed.
    /// </summary>
    public static TaskResultText TaskResult(string? code)
    {
        var text = (code ?? "").Trim();
        if (text.Length < 3 || text.Length > 10 || !text.StartsWith("0x", StringComparison.OrdinalIgnoreCase)
            || !uint.TryParse(text.AsSpan(2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var value))
        {
            return new TaskResultText(text, "non lu", null);
        }
        var label = value switch
        {
            0 => "succès",
            0x41300 => "tâche prête",
            0x41301 => "en cours d’exécution",
            0x41302 => "tâche désactivée",
            0x41303 => "jamais exécutée",
            0x41304 => "plus aucune exécution planifiée",
            0x41306 => "arrêtée par un utilisateur",
            _ => "",
        };
        return label.Length > 0 ? new TaskResultText(text, label, false) : new TaskResultText(text, "code de sortie ou erreur à vérifier", true);
    }

    /// <summary>
    /// Executable of a startup command, never its arguments (secrets travel there): the quoted path, or the first token.
    /// </summary>
    public static string CommandExecutable(string? command)
    {
        var text = (command ?? "").Trim();
        if (text.Length == 0)
        {
            return "";
        }
        if (text[0] == '"')
        {
            var end = text.IndexOf('"', 1);
            return end > 1 ? text[1..end].Trim() : "";
        }
        var stop = text.IndexOfAny([' ', '\t', ',']);
        return stop < 0 ? text : text[..stop];
    }

    /// <summary>
    /// Usual reading of the undocumented productState word of the Security Center: bit 0x1000 marks an active scanner, a low
    /// byte of 0 up-to-date signatures. Both are estimates.
    /// </summary>
    public static (bool? Enabled, bool? UpToDate) AntivirusState(int? productState)
    {
        if (productState is not int value || value < 0 || value > 0xFFFFFF)
        {
            return (null, null);
        }
        var middle = (value >> 8) & 0xFF;
        var low = value & 0xFF;
        return ((middle & 0x10) != 0, low == 0);
    }

    /// <summary>Hypervisor named by the declared maker and model, or null: an estimate, never a proof.</summary>
    public static string? VirtualPlatform(string? manufacturer, string? model)
    {
        var text = (manufacturer ?? "") + " " + (model ?? "");
        if ((model ?? "").Contains("Virtual Machine", StringComparison.OrdinalIgnoreCase) && (manufacturer ?? "").Contains("Microsoft", StringComparison.OrdinalIgnoreCase))
        {
            return "Hyper-V";
        }
        (string Mark, string Name)[] signatures =
        [
            ("VMware", "VMware"), ("VirtualBox", "VirtualBox"), ("innotek", "VirtualBox"), ("QEMU", "KVM / QEMU"), ("KVM", "KVM / QEMU"),
            ("Standard PC (", "KVM / QEMU"), ("HVM domU", "Xen"), ("Xen", "Xen"), ("Amazon EC2", "Amazon EC2"),
            ("Google Compute Engine", "Google Compute Engine"), ("Parallels", "Parallels"), ("Bochs", "Bochs"),
        ];
        return signatures.FirstOrDefault(s => text.Contains(s.Mark, StringComparison.OrdinalIgnoreCase)).Name;
    }

    /// <summary>Wording of a source status in the access report.</summary>
    public static string SourceStatusLabel(SourceStatus status) => status switch
    {
        SourceStatus.Ok => "Lu",
        SourceStatus.Empty => "Lu, rien trouvé",
        SourceStatus.Partial => "Lu en partie",
        SourceStatus.Refused => "Refusé",
        SourceStatus.Unavailable => "Indisponible",
        SourceStatus.Unreachable => "Injoignable",
        SourceStatus.Skipped => "Non tenté",
        SourceStatus.Interrupted => "Interrompu",
        _ => "En échec",
    };

    public static Tone SourceStatusTone(SourceStatus status) => status switch
    {
        SourceStatus.Ok or SourceStatus.Empty => Tone.Ok,
        SourceStatus.Partial => Tone.Warn,
        SourceStatus.Refused or SourceStatus.Error => Tone.Alert,
        SourceStatus.Unavailable or SourceStatus.Unreachable => Tone.Warn,
        _ => Tone.Off,
    };

    public static string TransportLabel(InventoryTransport transport) => transport switch
    {
        InventoryTransport.Dcom => "DCOM",
        InventoryTransport.WinRm => "WinRM",
        InventoryTransport.PsExec => "PsExec",
        InventoryTransport.ScheduledTask => "Tâche planifiée",
        InventoryTransport.NetApi => "NetAPI (RPC)",
        InventoryTransport.EventLog => "Journal Windows (RPC)",
        InventoryTransport.RemoteRegistry => "Registre distant (RPC)",
        _ => "Local",
    };

    /// <summary>
    /// TPM in one readable line: version from SpecVersion (« 2.0, 0, 1.59 » is version, level, revision), then its two
    /// states. A value not read stays « non lu ».
    /// </summary>
    public static string TpmText(TpmInfo tpm)
    {
        ArgumentNullException.ThrowIfNull(tpm);
        var parts = (tpm.Specification ?? "").Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        var version = parts.Length == 0 ? "TPM, version non lue" : "TPM " + parts[0] + (parts.Length >= 3 ? " (niveau " + parts[1] + ", révision " + parts[2] + ")" : "");
        var enabled = tpm.Enabled switch { true => "activé", false => "désactivé", _ => "activation non lue" };
        var ready = tpm.Activated switch { true => "opérationnel", false => "non opérationnel", _ => "état non lu" };
        return version + " · " + enabled + ", " + ready;
    }

    /// <summary>userAccountControl of a computer account: the raw value and the flags that matter, in French (never guessed).</summary>
    public static string UacText(int value)
    {
        var flags = new List<string>();
        if ((value & AdValues.WorkstationTrustAccount) != 0)
        {
            flags.Add("compte de poste de travail");
        }
        if ((value & AdValues.ServerTrustAccount) != 0)
        {
            flags.Add("contrôleur de domaine");
        }
        if ((value & AdValues.AccountDisabled) != 0)
        {
            flags.Add("désactivé");
        }
        if ((value & AdValues.PasswordNotRequired) != 0)
        {
            flags.Add("mot de passe non exigé");
        }
        if ((value & AdValues.DontExpirePassword) != 0)
        {
            flags.Add("mot de passe sans expiration");
        }
        if ((value & AdValues.TrustedForDelegation) != 0)
        {
            flags.Add("approuvé pour la délégation");
        }
        if ((value & 0x1000000) != 0)
        {
            flags.Add("délégation contrainte avec transition de protocole");
        }
        return value.ToString(CultureInfo.InvariantCulture) + (flags.Count == 0 ? "" : " · " + string.Join(", ", flags));
    }
}
