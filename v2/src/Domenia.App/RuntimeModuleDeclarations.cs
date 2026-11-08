using Domenia.Bridge;

// Closed, compiled exports. Changing a module requires reviewing this declaration; CI compares the real factories.
[assembly: OperationModulePlan(typeof(global::Domenia.App.AccueilJournalOperations), ModuleRegistrationPhase.Host, "accueil", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "accueil.log.tail")]

[assembly: OperationModulePlan(typeof(global::Domenia.App.DemoSessionHostOperations), ModuleRegistrationPhase.Host, "settings", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "settings.demo.exit", "settings.demo.open", "settings.demo.reset", "settings.demo.session")]

[assembly: OperationModulePlan(typeof(global::Domenia.App.HostOperations), ModuleRegistrationPhase.Host, "app", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "app.info")]

[assembly: OperationModulePlan(typeof(global::Domenia.App.SearchHostOperations), ModuleRegistrationPhase.Host, "search", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) })]

[assembly: OperationModulePlan(typeof(global::Domenia.App.PackageUpdateHostOperations), ModuleRegistrationPhase.Host, "settings", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "settings.defaults.package", "settings.update.check", "settings.update.demoRollback", "settings.update.folder",
    "settings.update.install", "settings.update.prepare", "settings.update.status")]

[assembly: OperationModulePlan(typeof(global::Domenia.App.PortableConfigurationHostOperations), ModuleRegistrationPhase.Host, "settings", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "settings.configuration.seed.decide", "settings.configuration.seed.status")]

[assembly: OperationModulePlan(typeof(global::Domenia.App.Settings.SettingsHostOperations), ModuleRegistrationPhase.Host, "settings", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "settings.about", "settings.config", "settings.dataPolicy", "settings.folder.open",
    "settings.folders.browse", "settings.logs", "settings.preferences", "settings.preferences.export",
    "settings.preferences.import", "settings.preferences.import.preview", "settings.storage.destination.check", "settings.storage.destinations",
    "settings.window", "settings.window.forget", "settings.window.zoom.set")]

[assembly: OperationModulePlan(typeof(global::Domenia.App.LegacyBoardHostOperations), ModuleRegistrationPhase.Host, "shell", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "shell.interface.migrate", "shell.interface.migration.preview", "shell.interface.compatibility.preview", "shell.interface.compatibility.apply")]

[assembly: OperationModulePlan(typeof(global::Domenia.App.ShellHostOperations), ModuleRegistrationPhase.Host, "shell", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "shell.about", "shell.board.team", "shell.export.list", "shell.export.open",
    "shell.export.save", "shell.files.browse", "shell.files.read", "shell.files.share",
    "shell.files.shareRead", "shell.guide.info", "shell.guide.open", "shell.policy",
    "shell.window.chrome")]

[assembly: OperationModulePlan(typeof(global::Domenia.App.TechnicalJournalOperations), ModuleRegistrationPhase.Host, "shell", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "shell.journal.status")]

[assembly: OperationModulePlan(typeof(global::Domenia.App.WindowActivityOperations), ModuleRegistrationPhase.Host, "shell", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "shell.window.activity")]
