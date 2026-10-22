using System.Collections.Immutable;
using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Domenia.Core.Poste;

/// <summary>A choice of the operator checked before any plan: valid, or why nothing is prepared.</summary>
public sealed record RemoteCheck(bool Valid, string Reason)
{
    public static RemoteCheck Ok { get; } = new(true, "");

    public static RemoteCheck Refuse(string reason) => new(false, reason);
}

/// <summary>Normalised restart request (Domenia 1 Get-DomeniaRestartPlan).</summary>
public sealed record RestartRequest(bool Now, int DelaySeconds, int Minutes, string Message, string Title, string Summary, string ConfirmText);

/// <summary>Normalised program run request (Domenia 1 Get-DomeniaRunProgramPlan).</summary>
public sealed record RunRequest(bool Interactive, string Command, string Arguments, string? RunUser, bool Elevated, string Title, string Summary);

/// <summary>Commands copied for the technician's own console (PST-018 and its improvement), never a secret.</summary>
public sealed record PosteCommands(string PsRemote, string PsStatus, string InvokeCommand, string Mstsc, string Unc, string ComputerManagement, string EventViewer, string Services, bool UsesCredential);

/// <summary>Wake-on-LAN decision (Domenia 1 Test-DomeniaWakeAllowed): MAC, directed broadcast and port.</summary>
public sealed record WakeDecision(bool Allowed, string Reason, string MacAddress, string Broadcast, int Port);

/// <summary>Launch plan of a suite tool (Domenia 1 Get-DomeniaSuiteLaunchPlan): never a shell, never a credential.</summary>
public sealed record SuiteLaunchPlan(bool Allowed, string Mode, ImmutableArray<string> Arguments, ImmutableArray<string> Omitted, string Reason);

/// <summary>Rules of the remote actions of a workstation (Domenia 1 SE-08, UI-26, UX-42, D079, D080). Pure.</summary>
public static partial class PosteRemote
{
    public const int MaxMessageLength = 400;
    public const int MaxProgramLength = 260;
    public const int MaxArgumentsLength = 1024;

    /// <summary>Delays offered for a delayed restart (improvement: 5, 15, 30, 60 minutes).</summary>
    public static ImmutableArray<int> RestartMinutes { get; } = [5, 15, 30, 60];

    [GeneratedRegex(@"^[^\\/:*?""<>|\s]{1,64}(\\[^\\/:*?""<>|\s]{1,104})?$", RegexOptions.CultureInvariant, 200)]
    private static partial Regex SessionAccount();

    [GeneratedRegex(@"^(?=.{1,253}$)[A-Za-z0-9][A-Za-z0-9-]{0,62}(\.[A-Za-z0-9][A-Za-z0-9-]{0,62})*$", RegexOptions.CultureInvariant, 200)]
    private static partial Regex HostName();

    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", RegexOptions.CultureInvariant, 200)]
    private static partial Regex Login();

    [GeneratedRegex(@"^(--?|/)[A-Za-z][A-Za-z0-9-]{0,31}$", RegexOptions.CultureInvariant, 200)]
    private static partial Regex OptionName();

    /// <summary>Restart.DefaultDelaySeconds bounded from 1 to 60 minutes, 5 minutes when absent.</summary>
    public static int DelaySeconds(int? configured) => configured is not int value ? 300 : Math.Clamp(value, 60, 3600);

    public static string DefaultMessage(int delaySeconds)
    {
        var minutes = (int)Math.Ceiling(Math.Max(60, delaySeconds) / 60d);
        return "Votre poste va redémarrer dans " + FrenchText.Count(minutes, "minute", "minutes") + " à la demande du support informatique. Enregistrez votre travail et fermez vos documents.";
    }

    /// <summary>
    /// The restart chosen in the page: delayed with a message (default, by WinRM) or immediate and forced without message.
    /// The message is one line of 400 characters at most, without double quote nor control character.
    /// </summary>
    public static (RemoteCheck Check, RestartRequest? Request) Restart(string computer, string mode, int? minutes, string? message, bool winRmAllowed)
    {
        var target = (computer ?? "").Trim();
        if (mode is not ("delayed" or "now"))
        {
            return (RemoteCheck.Refuse("Choisissez « Différé avec message » ou « Maintenant »."), null);
        }
        if (target.Length == 0)
        {
            return (RemoteCheck.Refuse("Aucun poste sélectionné."), null);
        }
        if (mode == "now")
        {
            return (RemoteCheck.Ok, new RestartRequest(true, 0, 0, "", "Redémarrer " + target + " maintenant ?",
                "Redémarrage immédiat, sans délai ni message : le travail non enregistré sur le poste est perdu.", "Redémarrer maintenant"));
        }
        if (!winRmAllowed)
        {
            return (RemoteCheck.Refuse("Redémarrage différé indisponible : il passe par WinRM, désactivé par la configuration (Remote.UseWinRM). Rien n’est envoyé."), null);
        }
        var delay = DelaySeconds(minutes is int m ? m * 60 : null);
        var text = new string((message ?? "").Select(c => char.IsControl(c) ? ' ' : c == '"' ? '\'' : c).ToArray());
        text = Regex.Replace(text, @"\s+", " ", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(200)).Trim().TrimEnd('\\').Trim();
        if (text.Length == 0)
        {
            text = DefaultMessage(delay);
        }
        if (text.Length > MaxMessageLength)
        {
            return (RemoteCheck.Refuse("Message trop long : 400 caractères au plus."), null);
        }
        var mins = (int)Math.Ceiling(delay / 60d);
        return (RemoteCheck.Ok, new RestartRequest(false, delay, mins, text, "Redémarrer " + target + " dans " + FrenchText.Integer(mins) + " min ?",
            "Redémarrage dans " + FrenchText.Integer(mins) + " min. L’utilisateur voit le message : " + FrenchText.Quote(text), "Redémarrer dans " + FrenchText.Integer(mins) + " min"));
    }

    /// <summary>
    /// A program of the workstation run once by a single scheduled task (created then deleted), either in the background
    /// under SYSTEM or in an open user session; 260 characters for the program, 1 024 for the arguments, no control character.
    /// </summary>
    public static (RemoteCheck Check, RunRequest? Request) Run(string computer, string mode, string? command, string? arguments, string? runUser, bool elevated)
    {
        var target = (computer ?? "").Trim();
        var program = (command ?? "").Trim();
        var args = (arguments ?? "").Trim();
        var user = (runUser ?? "").Trim();
        if (target.Length == 0)
        {
            return (RemoteCheck.Refuse("Aucun poste sélectionné."), null);
        }
        if (mode is not ("system" or "interactive"))
        {
            return (RemoteCheck.Refuse("Choisissez « En arrière-plan (compte système) » ou « Dans la session de l’utilisateur »."), null);
        }
        if (program.Length == 0)
        {
            return (RemoteCheck.Refuse("Indiquez le programme à lancer, tel qu’il existe sur le poste."), null);
        }
        if (program.Length > MaxProgramLength || args.Length > MaxArgumentsLength)
        {
            return (RemoteCheck.Refuse("Programme ou arguments trop longs (260 et 1 024 caractères au plus)."), null);
        }
        if ((program + args).Any(char.IsControl))
        {
            return (RemoteCheck.Refuse("Retour à la ligne ou caractère de contrôle refusé dans la commande."), null);
        }
        var interactive = mode == "interactive";
        if (interactive)
        {
            if (user.Length == 0)
            {
                return (RemoteCheck.Refuse("Indiquez le compte de la session ouverte sur le poste."), null);
            }
            if (!SessionAccount().IsMatch(user))
            {
                return (RemoteCheck.Refuse("Compte de session invalide : DOMAINE\\identifiant ou identifiant."), null);
            }
        }
        var how = interactive ? "dans la session ouverte de " + user : "en arrière-plan sous le compte système, sans fenêtre visible";
        var line = program + (args.Length > 0 ? " " + args : "");
        return (RemoteCheck.Ok, new RunRequest(interactive, program, args, interactive ? user : null, elevated, "Exécuter un programme sur " + target + " ?",
            "Lance " + FrenchText.Quote(line) + " " + how + (elevated ? ", avec le niveau le plus élevé" : "") + ". Une tâche planifiée unique est créée puis supprimée ; l’exécution du programme n’est pas vérifiée."));
    }

    /// <summary>Commands for the technician's console (Get-DomeniaPsRemoteCommand and variants): values quoted, never a password.</summary>
    public static PosteCommands Commands(string computer, string? operationsAccount)
    {
        ArgumentNullException.ThrowIfNull(computer);
        static string Quote(string v) => "'" + v.Replace("'", "''", StringComparison.Ordinal) + "'";
        var host = computer.Trim();
        var user = (operationsAccount ?? "").Trim();
        var credential = user.Length > 0 ? " -Credential " + Quote(user) : "";
        var status = user.Length > 0
            ? "Commande PowerShell copiée avec le compte " + user + " : Windows demandera son mot de passe, qui n’est jamais copié."
            : "Commande PowerShell copiée : collez-la dans votre console PowerShell.";
        return new PosteCommands(
            "Enter-PSSession -ComputerName " + Quote(host) + credential,
            status,
            "Invoke-Command -ComputerName " + Quote(host) + credential + " -ScriptBlock { Get-CimInstance Win32_OperatingSystem | Select-Object CSName, Caption, LastBootUpTime }",
            "mstsc /v:" + host,
            "\\\\" + host + "\\c$",
            "compmgmt.msc /computer=\\\\" + host,
            "eventvwr.msc /computer=\\\\" + host,
            "services.msc /computer=\\\\" + host,
            user.Length > 0);
    }

    /// <summary>MAC address as one network card (Test-DomeniaMacAddress): not null, not broadcast, not multicast.</summary>
    public static (bool Valid, string Normalized, string Reason) Mac(string? value)
    {
        var text = (value ?? "").Trim();
        var hex = new string(text.Where(char.IsAsciiHexDigit).ToArray());
        var shapeOk = text.Length == 12 && hex.Length == 12
            || text.Length == 17 && hex.Length == 12 && (text.Count(c => c == '-') == 5 || text.Count(c => c == ':') == 5)
            || text.Length == 14 && hex.Length == 12 && text.Count(c => c == '.') == 2;
        if (!shapeOk)
        {
            return (false, "", "Adresse MAC absente ou mal formée.");
        }
        hex = hex.ToUpperInvariant();
        if (hex == "000000000000")
        {
            return (false, "", "Adresse MAC nulle.");
        }
        if (hex == "FFFFFFFFFFFF")
        {
            return (false, "", "Adresse de diffusion : pas une carte réseau.");
        }
        if ((Convert.ToInt32(hex[..2], 16) & 1) != 0)
        {
            return (false, "", "Adresse de groupe (multicast) : pas une carte réseau.");
        }
        return (true, string.Join("-", Enumerable.Range(0, 6).Select(i => hex.Substring(i * 2, 2))), "");
    }

    /// <summary>Magic packet: six bytes 0xFF then the MAC address sixteen times (102 bytes). Building it sends nothing.</summary>
    public static byte[] WakePacket(string mac)
    {
        var (valid, normalized, reason) = Mac(mac);
        if (!valid)
        {
            throw new ArgumentException(reason, nameof(mac));
        }
        var bytes = normalized.Split('-').Select(p => Convert.ToByte(p, 16)).ToArray();
        var packet = new byte[102];
        for (var i = 0; i < 6; i++)
        {
            packet[i] = 0xFF;
        }
        for (var r = 0; r < 16; r++)
        {
            Array.Copy(bytes, 0, packet, 6 + r * 6, 6);
        }
        return packet;
    }

    private static long Ipv4(string? address)
    {
        var parts = (address ?? "").Trim().Split('.');
        if (parts.Length != 4)
        {
            return -1;
        }
        long value = 0;
        foreach (var p in parts)
        {
            if (p.Length is 0 or > 3 || !p.All(char.IsAsciiDigit) || !int.TryParse(p, NumberStyles.None, CultureInfo.InvariantCulture, out var octet) || octet > 255)
            {
                return -1;
            }
            value = value * 256 + octet;
        }
        return value;
    }

    private static string Ipv4Text(long value) => string.Join(".", new[] { (value >> 24) & 255, (value >> 16) & 255, (value >> 8) & 255, value & 255 }.Select(v => v.ToString(CultureInfo.InvariantCulture)));

    /// <summary>Directed broadcast of the known subnet (/8 to /30), or empty when it cannot be one host's subnet.</summary>
    public static string Broadcast(string? address, int prefix)
    {
        if (prefix is < 8 or > 30)
        {
            return "";
        }
        var number = Ipv4(address);
        if (number < 0)
        {
            return "";
        }
        var first = number >> 24;
        if (first is 0 or 127 or >= 224)
        {
            return "";
        }
        var size = 1L << (32 - prefix);
        var network = number - number % size;
        var broadcast = network + size - 1;
        return number == network || number == broadcast ? "" : Ipv4Text(broadcast);
    }

    /// <summary>True when the address belongs to « a.b.c.d/n ».</summary>
    public static bool InNetwork(string? address, string? network)
    {
        var text = (network ?? "").Trim();
        var slash = text.IndexOf('/', StringComparison.Ordinal);
        if (slash < 0 || !int.TryParse(text.AsSpan(slash + 1), NumberStyles.None, CultureInfo.InvariantCulture, out var length) || length > 32)
        {
            return false;
        }
        var baseAddress = Ipv4(text[..slash]);
        var number = Ipv4(address);
        if (baseAddress < 0 || number < 0)
        {
            return false;
        }
        var size = 1L << (32 - length);
        return number - number % size == baseAddress - baseAddress % size;
    }

    /// <summary>
    /// Off by default (Features.WakeOnLan); one workstation, a valid MAC, a known subnet entirely inside the allowed perimeter
    /// and an explicit gesture are all required: no collective or automatic wake.
    /// </summary>
    public static WakeDecision Wake(bool enabled, IReadOnlyList<string> allowedNetworks, string? mac, string? address, int? prefix)
    {
        ArgumentNullException.ThrowIfNull(allowedNetworks);
        if (!enabled)
        {
            return new WakeDecision(false, "Réveil désactivé par défaut (Features.WakeOnLan).", "", "", 0);
        }
        var (valid, normalized, reason) = Mac(mac);
        if (!valid)
        {
            return new WakeDecision(false, "Adresse MAC inconnue ou invalide : " + reason, "", "", 0);
        }
        var broadcast = Broadcast(address, prefix ?? -1);
        if (broadcast.Length == 0)
        {
            return new WakeDecision(false, "Réseau du poste inconnu : adresse ou masque absent ou invalide.", normalized, "", 0);
        }
        if (!allowedNetworks.Any(n => InNetwork(address, n) && InNetwork(broadcast, n)))
        {
            return new WakeDecision(false, "Réseau du poste hors du périmètre autorisé.", normalized, broadcast, 0);
        }
        return new WakeDecision(true, "", normalized, broadcast, 9);
    }

    /// <summary>Non-secret context fields a suite tool may receive, with the strict pattern of their value.</summary>
    public static ImmutableArray<string> SuiteFields { get; } = ["ComputerName", "ComputerGuid", "UserLogin", "UserGuid", "Domain"];

    /// <summary>
    /// Launch plan from the declared contract (Test-DomeniaSuiteContract, Get-DomeniaSuiteLaunchPlan): only declared, validated
    /// fields are passed; without a recognised contract, the tool opens without argument. Explicit gesture only.
    /// </summary>
    public static SuiteLaunchPlan Suite(string tool, string? contract, IReadOnlyDictionary<string, string?> context, bool explicitGesture)
    {
        ArgumentNullException.ThrowIfNull(tool);
        ArgumentNullException.ThrowIfNull(context);
        if (!explicitGesture)
        {
            return new SuiteLaunchPlan(false, "None", [], [], "Ouverture uniquement par le bouton de l’outil : une navigation ou une sélection ne lance rien.");
        }
        var (recognized, reason, fields) = Contract(contract, tool);
        if (!recognized)
        {
            return new SuiteLaunchPlan(true, "NoArgument", [], [], reason + " Ouverture sans argument.");
        }
        var args = ImmutableArray.CreateBuilder<string>();
        var omitted = ImmutableArray.CreateBuilder<string>();
        foreach (var (field, option) in fields)
        {
            context.TryGetValue(field, out var raw);
            var value = (raw ?? "").Trim();
            string? why = null;
            if (value.Length == 0)
            {
                why = "Valeur absente.";
            }
            else if (field is "ComputerGuid" or "UserGuid")
            {
                if (Guid.TryParse(value, out var g))
                {
                    value = g.ToString("D");
                }
                else
                {
                    why = "GUID invalide.";
                }
            }
            else if (!(field is "ComputerName" or "Domain" ? HostName().IsMatch(value) : Login().IsMatch(value)))
            {
                why = "Valeur refusée : caractères non autorisés.";
            }
            if (why is not null)
            {
                omitted.Add(field + FrenchText.Colon + why);
                continue;
            }
            args.Add(option);
            args.Add(value);
        }
        return new SuiteLaunchPlan(true, "Contract", args.ToImmutable(), omitted.ToImmutable(), "");
    }

    private static (bool Recognized, string Reason, List<(string Field, string Option)> Fields) Contract(string? text, string tool)
    {
        var fields = new List<(string, string)>();
        if (string.IsNullOrWhiteSpace(text))
        {
            return (false, "Aucun contrat déclaré par l’outil.", fields);
        }
        if (text.Length > 16384)
        {
            return (false, "Contrat trop volumineux.", fields);
        }
        try
        {
            using var document = JsonDocument.Parse(text);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return (false, "Contrat non reconnu : objet attendu.", fields);
            }
            foreach (var property in root.EnumerateObject())
            {
                if (property.Name is not ("Schema" or "Tool" or "Version" or "Context" or "Description"))
                {
                    return (false, "Champ non prévu dans le contrat : " + property.Name + ".", fields);
                }
            }
            if (!root.TryGetProperty("Schema", out var schema) || schema.ValueKind != JsonValueKind.String || schema.GetString() != "DomeniaSuiteContract/1")
            {
                return (false, "Schéma non reconnu (DomeniaSuiteContract/1 attendu).", fields);
            }
            if (!root.TryGetProperty("Tool", out var name) || name.ValueKind != JsonValueKind.String || !string.Equals(name.GetString(), tool, StringComparison.OrdinalIgnoreCase))
            {
                return (false, "Contrat d’un autre outil que " + tool + ".", fields);
            }
            if (root.TryGetProperty("Context", out var ctx))
            {
                if (ctx.ValueKind != JsonValueKind.Object)
                {
                    return (false, "Context doit être un objet.", fields);
                }
                var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var entry in ctx.EnumerateObject())
                {
                    if (!SuiteFields.Contains(entry.Name))
                    {
                        return (false, "Champ de contexte non autorisé : " + entry.Name + ".", fields);
                    }
                    var option = entry.Value.ValueKind == JsonValueKind.String ? entry.Value.GetString()! : "";
                    if (!OptionName().IsMatch(option))
                    {
                        return (false, "Option invalide pour " + entry.Name + ".", fields);
                    }
                    if (!seen.Add(option))
                    {
                        return (false, "Option en double : " + option + ".", fields);
                    }
                    fields.Add((entry.Name, option));
                }
            }
            return (true, "", fields);
        }
        catch (JsonException)
        {
            return (false, "Contrat illisible (JSON invalide).", fields);
        }
    }
}
