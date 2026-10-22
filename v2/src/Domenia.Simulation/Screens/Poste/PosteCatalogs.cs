using System.Collections.Immutable;

namespace Domenia.Simulation.Poste;

/// <summary>A hardware model of the fictitious fleet, with what its firmware and drivers would report.</summary>
internal sealed record SimModel(string Maker, string Model, bool Laptop, string Cpu, int Cores, int Threads, int MaxMhz, string BiosPrefix, string MacPrefix, int Chassis, string VendorTool, string Firmware);

/// <summary>A software of the catalog: name, version, publisher, size (Mo), architecture, scope, share of the fleet, services.</summary>
internal sealed record SimSoftware(string Name, string Version, string? Publisher, int SizeMb, string Architecture, string Scope, int Percent, string Departments, string Source);

/// <summary>A Windows service of a workstation: key name, display name, start mode, delayed, usual state, account, dependencies.</summary>
internal sealed record SimService(string Name, string Display, string StartMode, bool Delayed, string State, string Account, string DependsOn, string Description);

/// <summary>A usual process: name, working set range (Mo), processor weight, account.</summary>
internal sealed record SimProcess(string Name, int MinMb, int MaxMb, int CpuWeight, bool User);

/// <summary>Fixed catalogs of the fictitious workstations (docs/SIMULATION.md § 4.5: six models of three makers).</summary>
internal static class PosteCatalogs
{
    public static ImmutableArray<SimModel> Models { get; } =
    [
        new("Dell Inc.", "Latitude 5440", true, "13th Gen Intel(R) Core(TM) i5-1345U", 10, 12, 1600, "1.", "D4-81-D7", 10, "Dell Command | Update", "UEFI"),
        new("Dell Inc.", "OptiPlex 7010", false, "13th Gen Intel(R) Core(TM) i5-13500", 14, 20, 2500, "1.", "B0-4F-13", 3, "Dell Command | Update", "UEFI"),
        new("HP", "HP EliteBook 840 G10", true, "13th Gen Intel(R) Core(TM) i7-1365U", 10, 12, 1800, "V70 Ver. 01.", "9C-7B-EF", 10, "HP Support Assistant", "UEFI"),
        new("HP", "HP EliteDesk 800 G6 Desktop Mini PC", false, "Intel(R) Core(TM) i5-10500T CPU @ 2.30GHz", 6, 12, 2300, "S21 Ver. 02.", "48-0F-CF", 35, "HP Support Assistant", "UEFI"),
        new("LENOVO", "21HD0049FR", true, "13th Gen Intel(R) Core(TM) i7-1355U", 10, 12, 1700, "R2FET", "8C-8C-AA", 10, "Lenovo Vantage", "UEFI"),
        new("LENOVO", "11JN0019FR", false, "12th Gen Intel(R) Core(TM) i5-12500T", 6, 12, 2000, "M4BKT", "6C-24-08", 35, "Lenovo Vantage", "UEFI"),
    ];

    /// <summary>Marketing names of the Lenovo product codes (the firmware reports the code).</summary>
    public static string FriendlyModel(SimModel model) => model.Model switch
    {
        "21HD0049FR" => "ThinkPad T14 Gen 4",
        "11JN0019FR" => "ThinkCentre M70q Gen 3",
        _ => model.Model,
    };

    /// <summary>Label of the model in the stored inventory of the directory simulation (docs/SIMULATION.md § 5.1).</summary>
    public static string Label(SimModel model) => model.Model switch
    {
        "Latitude 5440" => "Dell Latitude 5440",
        "OptiPlex 7010" => "Dell OptiPlex 7010",
        "HP EliteBook 840 G10" => "HP EliteBook 840 G10",
        "HP EliteDesk 800 G6 Desktop Mini PC" => "HP EliteDesk 800 G6",
        "21HD0049FR" => "Lenovo ThinkPad T14 Gen 4",
        "11JN0019FR" => "Lenovo ThinkCentre M70q",
        _ => model.Model,
    };

    public static ImmutableArray<SimSoftware> Software { get; } =
    [
        new("Microsoft 365 Apps pour entreprise - fr-fr", "16.0.18129.20158", "Microsoft Corporation", 3480, "64 bits", "Machine", 100, "", "Uninstall64"),
        new("Microsoft Edge", "141.0.3537.71", "Microsoft Corporation", 640, "64 bits", "Machine", 100, "", "Uninstall64"),
        new("Microsoft Edge WebView2 Runtime", "141.0.3537.71", "Microsoft Corporation", 610, "64 bits", "Machine", 100, "", "Uninstall64"),
        new("Microsoft Teams", "25275.2601.4002.2815", "Microsoft Corporation", 520, "64 bits", "Machine", 92, "", "Uninstall64"),
        new("Microsoft OneDrive", "25.184.0921.0002", "Microsoft Corporation", 380, "64 bits", "Machine", 100, "", "Uninstall64"),
        new("Google Chrome", "141.0.7390.108", "Google LLC", 590, "64 bits", "Machine", 64, "", "Uninstall64"),
        new("Mozilla Firefox (x64 fr)", "144.0", "Mozilla", 260, "64 bits", "Machine", 22, "", "Uninstall64"),
        new("Adobe Acrobat Reader (64-bit)", "25.001.20756", "Adobe", 780, "64 bits", "Machine", 96, "", "Uninstall64"),
        new("7-Zip 24.09 (x64)", "24.09", "Igor Pavlov", 6, "64 bits", "Machine", 88, "", "Uninstall64"),
        new("Notepad++ (64-bit x64)", "8.8.6", "Notepad++ Team", 16, "64 bits", "Machine", 34, "Informatique", "Uninstall64"),
        new("VLC media player", "3.0.21", "VideoLAN", 170, "64 bits", "Machine", 41, "", "Uninstall64"),
        new("Zoom Workplace (64-bit)", "6.6.2.10985", "Zoom Communications, Inc.", 330, "64 bits", "Utilisateur", 18, "Commercial,Direction", "UserHives"),
        new("Microsoft Visual C++ 2015-2022 Redistributable (x64)", "14.44.35211", "Microsoft Corporation", 21, "64 bits", "Machine", 100, "", "Uninstall64"),
        new("Microsoft Visual C++ 2015-2022 Redistributable (x86)", "14.44.35211", "Microsoft Corporation", 18, "32 bits", "Machine", 97, "", "Uninstall32"),
        new("Microsoft Visual C++ 2013 Redistributable (x86)", "12.0.40664", "Microsoft Corporation", 17, "32 bits", "Machine", 46, "", "Uninstall32"),
        new("Microsoft Windows Desktop Runtime - 8.0.21 (x64)", "8.0.21", "Microsoft Corporation", 210, "64 bits", "Machine", 78, "", "Uninstall64"),
        new("Microsoft .NET Runtime - 8.0.21 (x64)", "8.0.21", "Microsoft Corporation", 72, "64 bits", "Machine", 78, "", "Uninstall64"),
        new("Microsoft Windows Desktop Runtime - 6.0.36 (x64)", "6.0.36", "Microsoft Corporation", 205, "64 bits", "Machine", 31, "", "Uninstall64"),
        new("Java 8 Update 471", "8.0.4710.11", "Oracle Corporation", 120, "32 bits", "Machine", 12, "Finances,Achats", "Uninstall32"),
        new("Greenshot 1.2.10.6", "1.2.10.6", "Greenshot", 6, "32 bits", "Machine", 52, "", "Uninstall32"),
        new("Microsoft Update Health Tools", "5.72.0.0", "Microsoft Corporation", 1, "64 bits", "Machine", 100, "", "Uninstall64"),
        new("Outil de suppression de logiciels malveillants Microsoft Windows", "5.135", "Microsoft Corporation", 92, "64 bits", "Machine", 60, "", "Sccm"),
        new("Client de paie Example", "4.12.3", "Example SI", 410, "32 bits", "Machine", 100, "Ressources humaines,Finances", "Uninstall32"),
        new("Example CRM (client lourd)", "2024.3.11", "Example SI", 255, "32 bits", "Machine", 100, "Commercial,Direction", "Uninstall32"),
        new("GED Example Connect", "7.4.0", "Example SI", 96, "64 bits", "Machine", 70, "", "Uninstall64"),
        new("Planning Example", "3.8.1", null, 58, "32 bits", "Machine", 100, "Logistique", "Uninstall32"),
        new("Stocks Example Terminal", "2.2.7", null, 44, "32 bits", "Machine", 100, "Logistique", "Uninstall32"),
        new("Comptabilité Example Pro", "11.5.2", "Example SI", 380, "32 bits", "Machine", 100, "Finances", "Uninstall32"),
        new("Pilote d’impression universel HP", "7.4.0.25959", "HP Inc.", 60, "64 bits", "Machine", 55, "", "Uninstall64"),
        new("KeePassXC", "2.7.10", "KeePassXC Team", 82, "64 bits", "Machine", 9, "Informatique", "Uninstall64"),
        new("PowerShell 7-x64", "7.5.3.0", "Microsoft Corporation", 125, "64 bits", "Machine", 7, "Informatique", "Uninstall64"),
        new("Remote Server Administration Tools", "10.0.26100.1", "Microsoft Corporation", 340, "64 bits", "Machine", 6, "Informatique", "Uninstall64"),
        new("WinSCP 6.5.4", "6.5.4", "Martin Prikryl", 38, "32 bits", "Machine", 5, "Informatique", "Uninstall32"),
        new("Microsoft Power BI Desktop (x64)", "2.147.1085.0", "Microsoft Corporation", 980, "64 bits", "Machine", 14, "Finances,Direction", "Uninstall64"),
        new("Spotify", "1.2.74.477", "Spotify AB", 290, "64 bits", "Utilisateur", 6, "", "UserHives"),
        new("Calculatrice Windows", "11.2508.4.0", "Microsoft Corporation", 32, "64 bits", "Store", 100, "", "Appx"),
        new("Photos Microsoft", "2025.11090.25002.0", "Microsoft Corporation", 410, "64 bits", "Store", 100, "", "Appx"),
        new("Outil Capture d’écran", "11.2509.21.0", "Microsoft Corporation", 63, "64 bits", "Store", 100, "", "Appx"),
        new("Bloc-notes Windows", "11.2508.38.0", "Microsoft Corporation", 12, "64 bits", "Store", 100, "", "Appx"),
    ];

    public static ImmutableArray<SimService> Services { get; } =
    [
        new("AudioEndpointBuilder", "Générateur de points de terminaison du service Audio Windows", "Auto", false, "Running", "LocalSystem", "", "Gère les périphériques audio."),
        new("Audiosrv", "Audio Windows", "Auto", false, "Running", "NT AUTHORITY\\LocalService", "AudioEndpointBuilder,RpcSs", "Gère l’audio des programmes."),
        new("BFE", "Moteur de filtrage de base", "Auto", false, "Running", "NT AUTHORITY\\LocalService", "RpcSs", "Moteur de filtrage du pare-feu et d’IPsec."),
        new("BITS", "Service de transfert intelligent en arrière-plan", "Auto", true, "Stopped", "LocalSystem", "RpcSs", "Transfère des fichiers en arrière-plan."),
        new("BrokerInfrastructure", "Service d’infrastructure des tâches en arrière-plan", "Auto", false, "Running", "LocalSystem", "RpcEptMapper", "Infrastructure des tâches en arrière-plan."),
        new("CDPSvc", "Service de plateforme des appareils connectés", "Auto", true, "Running", "NT AUTHORITY\\LocalService", "", "Plateforme des appareils connectés."),
        new("CryptSvc", "Services de chiffrement", "Auto", false, "Running", "NT AUTHORITY\\NetworkService", "RpcSs", "Catalogues de signatures et certificats racines."),
        new("DcomLaunch", "Lanceur de processus serveur DCOM", "Auto", false, "Running", "LocalSystem", "", "Lance les serveurs COM et DCOM."),
        new("Dhcp", "Client DHCP", "Auto", false, "Running", "NT AUTHORITY\\LocalService", "NSI,Afd", "Inscrit et met à jour les adresses IP."),
        new("DiagTrack", "Expériences des utilisateurs connectés et télémétrie", "Auto", false, "Running", "LocalSystem", "RpcSs", "Télémétrie."),
        new("Dnscache", "Client DNS", "Auto", false, "Running", "NT AUTHORITY\\NetworkService", "nsi", "Met en cache les noms DNS."),
        new("DoSvc", "Optimisation de la distribution", "Auto", true, "Stopped", "NT AUTHORITY\\NetworkService", "RpcSs", "Optimise la distribution des mises à jour."),
        new("DPS", "Service de stratégie de diagnostic", "Auto", false, "Running", "NT AUTHORITY\\LocalService", "", "Détection des problèmes."),
        new("edgeupdate", "Service Microsoft Edge Update (edgeupdate)", "Auto", true, "Stopped", "LocalSystem", "RpcSs", "Maintient Microsoft Edge à jour."),
        new("EventLog", "Journal d’événements Windows", "Auto", false, "Running", "NT AUTHORITY\\LocalService", "", "Gère les journaux d’événements."),
        new("EventSystem", "Système d’événement COM+", "Auto", false, "Running", "NT AUTHORITY\\LocalService", "rpcss", "Notification d’événements COM+."),
        new("FontCache", "Service de cache de police Windows", "Auto", false, "Running", "NT AUTHORITY\\LocalService", "", "Cache des polices."),
        new("gpsvc", "Client de stratégie de groupe", "Auto", false, "Running", "LocalSystem", "RpcSs,Mup", "Applique les stratégies de groupe."),
        new("gupdate", "Service Google Update (gupdate)", "Auto", true, "Stopped", "LocalSystem", "RpcSs", "Maintient Google Chrome à jour."),
        new("iphlpsvc", "Assistance IP", "Auto", false, "Running", "LocalSystem", "RasMan,Winmgmt,nsi", "Connectivité IPv6."),
        new("LanmanServer", "Serveur", "Auto", false, "Running", "LocalSystem", "SamSS,Srv2", "Partage de fichiers et d’imprimantes."),
        new("LanmanWorkstation", "Station de travail", "Auto", false, "Running", "NT AUTHORITY\\NetworkService", "Bowser,MRxSmb20,NSI", "Connexions aux partages."),
        new("LicenseManager", "Service Gestionnaire de licences Windows", "Manual", false, "Running", "NT AUTHORITY\\LocalService", "", "Licences du Store."),
        new("lmhosts", "Assistance NetBIOS sur TCP/IP", "Manual", false, "Running", "NT AUTHORITY\\LocalService", "Afd", "Résolution NetBIOS."),
        new("MapsBroker", "Gestionnaire des cartes téléchargées", "Auto", true, "Stopped", "NT AUTHORITY\\NetworkService", "", "Cartes hors connexion."),
        new("mpssvc", "Pare-feu Windows Defender", "Auto", false, "Running", "NT AUTHORITY\\LocalService", "mpsdrv,bfe", "Protège l’ordinateur."),
        new("MSDTC", "Coordinateur de transactions distribuées", "Manual", false, "Stopped", "NT AUTHORITY\\NetworkService", "RPCSS,SamSS", "Transactions distribuées."),
        new("Netlogon", "Netlogon", "Auto", false, "Running", "LocalSystem", "LanmanWorkstation", "Canal sécurisé avec le contrôleur de domaine."),
        new("Netman", "Connexions réseau", "Manual", false, "Running", "LocalSystem", "RpcSs", "Dossier Connexions réseau."),
        new("NlaSvc", "Connaissance des emplacements réseau", "Auto", false, "Running", "NT AUTHORITY\\NetworkService", "NSI,RpcSs,TcpIp,Dhcp,Eventlog", "Profil réseau et pare-feu."),
        new("nsi", "Service Interface du magasin réseau", "Auto", false, "Running", "NT AUTHORITY\\LocalService", "rpcss,nsiproxy", "Notifications réseau."),
        new("OneSyncSvc_4a1d3", "Synchronisation de l’hôte_4a1d3", "Auto", true, "Stopped", "LocalSystem", "", "Synchronise courrier et contacts."),
        new("PlugPlay", "Plug-and-Play", "Manual", false, "Running", "LocalSystem", "", "Reconnaissance du matériel."),
        new("Power", "Alimentation", "Auto", false, "Running", "LocalSystem", "", "Stratégie d’alimentation."),
        new("ProfSvc", "Service de profil utilisateur", "Auto", false, "Running", "LocalSystem", "RpcSs", "Charge et décharge les profils."),
        new("RemoteRegistry", "Registre à distance", "Auto", false, "Stopped", "NT AUTHORITY\\LocalService", "RPCSS", "Accès distant au registre."),
        new("RpcEptMapper", "Mappeur de point de terminaison RPC", "Auto", false, "Running", "NT AUTHORITY\\NetworkService", "", "Résout les points de terminaison RPC."),
        new("RpcSs", "Appel de procédure distante (RPC)", "Auto", false, "Running", "NT AUTHORITY\\NetworkService", "RpcEptMapper,DcomLaunch", "Gestionnaire RPC."),
        new("SamSs", "Gestionnaire de comptes de sécurité", "Auto", false, "Running", "LocalSystem", "RPCSS", "Comptes de sécurité locaux."),
        new("Schedule", "Planificateur de tâches", "Auto", false, "Running", "LocalSystem", "RPCSS,SystemEventsBroker", "Exécute les tâches planifiées."),
        new("SecurityHealthService", "Service Sécurité Windows", "Manual", false, "Running", "LocalSystem", "RpcSs", "État de sécurité."),
        new("SENS", "Service de notification d’événements système", "Auto", false, "Running", "LocalSystem", "EventSystem", "Événements système."),
        new("ShellHWDetection", "Détection matériel noyau", "Auto", false, "Running", "LocalSystem", "RpcSs", "Exécution automatique."),
        new("Spooler", "Spouleur d’impression", "Auto", false, "Running", "LocalSystem", "RPCSS,http", "Met en file les travaux d’impression."),
        new("sppsvc", "Protection logicielle", "Auto", true, "Stopped", "NT AUTHORITY\\NetworkService", "RpcSs", "Licences Windows."),
        new("SysMain", "SysMain", "Auto", false, "Running", "LocalSystem", "rpcss", "Améliore les performances."),
        new("TermService", "Services Bureau à distance", "Manual", false, "Running", "NT AUTHORITY\\NetworkService", "RPCSS", "Connexions Bureau à distance."),
        new("Themes", "Thèmes", "Auto", false, "Running", "LocalSystem", "", "Gestion des thèmes."),
        new("TrkWks", "Client de suivi de lien distribué", "Auto", false, "Running", "LocalSystem", "RpcSs", "Liens entre fichiers NTFS."),
        new("UsoSvc", "Mettre à jour le service Orchestrator", "Auto", true, "Stopped", "LocalSystem", "rpcss", "Orchestrateur des mises à jour."),
        new("W32Time", "Temps Windows", "Manual", false, "Running", "NT AUTHORITY\\LocalService", "", "Synchronise l’horloge."),
        new("WdNisSvc", "Service Inspection du réseau de l’Antivirus Microsoft Defender", "Manual", false, "Running", "NT AUTHORITY\\LocalService", "WdNisDrv", "Inspection réseau."),
        new("WinDefend", "Service Antivirus Microsoft Defender", "Auto", false, "Running", "LocalSystem", "RpcSs", "Protection antivirus."),
        new("WinHttpAutoProxySvc", "Service de découverte automatique de Proxy Web pour les services HTTP Windows", "Manual", false, "Running", "NT AUTHORITY\\LocalService", "Dhcp", "Détection du proxy."),
        new("Winmgmt", "Infrastructure de gestion Windows", "Auto", false, "Running", "LocalSystem", "RPCSS", "Fournisseurs WMI."),
        new("WinRM", "Gestion à distance de Windows (Gestion WSM)", "Auto", true, "Running", "NT AUTHORITY\\NetworkService", "RPCSS,HTTP", "WS-Management."),
        new("WlanSvc", "Service de configuration automatique WLAN", "Auto", false, "Running", "LocalSystem", "nativewifip,RpcSs,Ndisuio,wcmsvc", "Connexions Wi-Fi."),
        new("wscsvc", "Centre de sécurité", "Auto", true, "Running", "NT AUTHORITY\\LocalService", "RpcSs", "État de sécurité."),
        new("WSearch", "Windows Search", "Auto", true, "Running", "LocalSystem", "RPCSS,BrokerInfrastructure", "Indexation."),
        new("wuauserv", "Windows Update", "Manual", false, "Stopped", "LocalSystem", "rpcss", "Mises à jour Windows."),
        new("WpnService", "Service du système de notifications Push Windows", "Auto", false, "Running", "LocalSystem", "rpcss", "Notifications."),
        new("XblGameSave", "Xbox Live – Sauvegarde de jeu", "Disabled", false, "Stopped", "LocalSystem", "UserManager,XblAuthManager", "Désactivé par stratégie."),
        new("Fax", "Télécopie", "Disabled", false, "Stopped", "NT AUTHORITY\\NetworkService", "TapiSrv,RpcSs,PlugPlay,Spooler", "Désactivé par stratégie."),
    ];

    public static ImmutableArray<SimProcess> Processes { get; } =
    [
        new("System", 1, 4, 3, false), new("Registry", 40, 90, 0, false), new("smss.exe", 1, 2, 0, false), new("csrss.exe", 5, 9, 1, false),
        new("wininit.exe", 6, 9, 0, false), new("services.exe", 10, 18, 1, false), new("lsass.exe", 22, 40, 2, false), new("svchost.exe", 8, 60, 2, false),
        new("svchost.exe", 12, 90, 2, false), new("svchost.exe", 20, 140, 3, false), new("MsMpEng.exe", 180, 420, 4, false), new("SearchIndexer.exe", 30, 90, 2, false),
        new("spoolsv.exe", 12, 30, 1, false), new("WmiPrvSE.exe", 14, 40, 2, false), new("dwm.exe", 70, 180, 4, true), new("explorer.exe", 110, 260, 3, true),
        new("sihost.exe", 20, 35, 1, true), new("RuntimeBroker.exe", 18, 60, 1, true), new("ctfmon.exe", 12, 24, 0, true), new("OneDrive.exe", 70, 160, 2, true),
        new("ms-teams.exe", 260, 980, 8, true), new("msedgewebview2.exe", 90, 340, 4, true), new("OUTLOOK.EXE", 240, 640, 6, true), new("msedge.exe", 120, 520, 6, true),
        new("WINWORD.EXE", 140, 380, 3, true), new("EXCEL.EXE", 120, 420, 4, true), new("SecurityHealthSystray.exe", 6, 12, 0, true), new("Greenshot.exe", 20, 40, 1, true),
        new("taskhostw.exe", 12, 30, 1, true), new("TextInputHost.exe", 40, 80, 1, true), new("StartMenuExperienceHost.exe", 60, 110, 1, true), new("SearchHost.exe", 90, 180, 2, true),
        new("chrome.exe", 150, 780, 6, true), new("AcroRd32.exe", 110, 260, 2, true), new("Widgets.exe", 30, 60, 0, true),
    ];

    /// <summary>Scheduled tasks: path, name, author, Microsoft or not.</summary>
    public static ImmutableArray<(string Path, string Name, string Author, bool Microsoft)> Tasks { get; } =
    [
        ("\\Microsoft\\Windows\\Defrag\\", "ScheduledDefrag", "Microsoft Corporation", true),
        ("\\Microsoft\\Windows\\WindowsUpdate\\", "Scheduled Start", "Microsoft Corporation", true),
        ("\\Microsoft\\Windows\\UpdateOrchestrator\\", "Schedule Scan", "Microsoft Corporation", true),
        ("\\Microsoft\\Windows\\Windows Defender\\", "Windows Defender Scheduled Scan", "Microsoft Corporation", true),
        ("\\Microsoft\\Windows\\Time Synchronization\\", "SynchronizeTime", "Microsoft Corporation", true),
        ("\\Microsoft\\Windows\\Diagnosis\\", "Scheduled", "Microsoft Corporation", true),
        ("\\Microsoft\\Office\\", "Office Automatic Updates 2.0", "Microsoft Office", true),
        ("\\", "MicrosoftEdgeUpdateTaskMachineCore", "Microsoft Corporation", true),
        ("\\", "GoogleUpdaterTaskSystem141.0.7390.108", "Google LLC", false),
        ("\\Example\\", "Synchronisation GED", "EXAMPLE\\svc-gestion", false),
        ("\\Example\\", "Inventaire matériel hebdomadaire", "EXAMPLE\\svc-deploiement", false),
    ];

    /// <summary>Startup entries: name, executable (never arguments), location, Microsoft or not.</summary>
    public static ImmutableArray<(string Name, string Executable, string Location, bool Microsoft)> Startup { get; } =
    [
        ("OneDrive", "C:\\Program Files\\Microsoft OneDrive\\OneDrive.exe", "HKU\\…\\Run", true),
        ("SecurityHealth", "C:\\Windows\\system32\\SecurityHealthSystray.exe", "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run", true),
        ("Teams", "C:\\Program Files\\WindowsApps\\MSTeams\\ms-teams.exe", "HKU\\…\\Run", true),
        ("Greenshot", "C:\\Program Files (x86)\\Greenshot\\Greenshot.exe", "Common Startup", false),
        ("Adobe Acrobat Synchronizer", "C:\\Program Files\\Adobe\\Acrobat DC\\Acrobat\\AdobeCollabSync.exe", "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run", false),
        ("GoogleUpdater", "C:\\Program Files (x86)\\Google\\GoogleUpdater\\updater.exe", "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run", false),
        ("Zoom", "C:\\Users\\…\\AppData\\Roaming\\Zoom\\bin\\Zoom.exe", "HKU\\…\\Run", false),
        ("Spotify", "C:\\Users\\…\\AppData\\Roaming\\Spotify\\Spotify.exe", "HKU\\…\\Run", false),
        ("Logitech Options", "C:\\Program Files\\Logitech\\LogiOptionsPlus\\logioptionsplus_agent.exe", "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run", false),
        ("Imprimante Copieur", "C:\\Program Files\\Copieur\\StatusMonitor.exe", "Common Startup", false),
        ("Rappel GED", "C:\\Program Files\\Example\\GED\\gedagent.exe", "Common Startup", false),
        ("Synchro Planning", "C:\\Program Files (x86)\\Example\\Planning\\syncplan.exe", "HKU\\…\\Run", false),
        ("Outil fournisseur", "C:\\Program Files\\Vendor\\Agent\\agent.exe", "HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Run", false),
        ("Mise à jour Java", "C:\\Program Files (x86)\\Common Files\\Java\\Java Update\\jusched.exe", "HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Run", false),
        ("Assistant de visioconférence", "C:\\Program Files\\Visio\\assist.exe", "HKU\\…\\Run", false),
    ];
}
