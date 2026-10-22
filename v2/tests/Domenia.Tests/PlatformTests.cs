using System.Reflection;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

// Probe types for the discovery tests. Public ones are found, the others never are; their screen (« probe ») is used
// by no real module.

/// <summary>Found by discovery: public, non-abstract, parameterless constructor.</summary>
public sealed class ProbeModule : IOperationModule
{
    public string Screen => "probe";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context) =>
        [new OperationDefinition("probe.echo", OperationClass.Local, (_, _, _) => Task.FromResult<object?>(context.Mode.ToString()), "sonde")];
}

/// <summary>Never found: no parameterless constructor.</summary>
public sealed class ProbeModuleWithArguments(string screen) : IOperationModule
{
    public string Screen => screen;

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context) => [];
}

/// <summary>Never found: abstract.</summary>
public abstract class ProbeModuleBase : IOperationModule
{
    public string Screen => "probe";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context) => [];
}

/// <summary>Read interface of a probe screen.</summary>
public interface IProbeReader : IScreenReader
{
    string Name { get; }
}

/// <summary>Source type used only by the probe readers below, so they never match a real source.</summary>
public sealed class ProbeSource : IDirectorySource
{
    public DirectorySourceKind Kind => DirectorySourceKind.Simulation;

    public Task<SessionSnapshot> GetSessionAsync(CancellationToken cancellationToken) => throw new NotSupportedException();

    public Task<DirectoryState> ReadLocalAsync(CancellationToken cancellationToken) => throw new NotSupportedException();

    public Task<DirectoryState> RefreshAsync(MeasureFamily family, ScopeSelection? scope, CancellationToken cancellationToken) => throw new NotSupportedException();
}

/// <summary>Probe reader for <see cref="ProbeSource"/>.</summary>
public sealed class ProbeReader(ProbeSource source) : IProbeReader
{
    public string Name => source.Kind.ToString();
}

/// <summary>Internal module and reader: never found (public types only).</summary>
internal sealed class HiddenProbeModule : IOperationModule
{
    public string Screen => "hidden";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context) => [];
}

internal sealed class OutsideScreenModule : IOperationModule
{
    public string Screen => "probe";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context) =>
        [new OperationDefinition("other.echo", OperationClass.Local, (_, _, _) => Task.FromResult<object?>(null), "hors écran")];
}

internal sealed class InvalidScreenModule : IOperationModule
{
    public string Screen => "Probe.Screen";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context) => [];
}

internal sealed class DuplicateModule : IOperationModule
{
    public string Screen => "probe";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context) =>
        [new OperationDefinition("probe.echo", OperationClass.Local, (_, _, _) => Task.FromResult<object?>(null), "doublon")];
}

internal static class PlatformTests
{
    private static readonly Assembly BridgeAssembly = typeof(DashboardOperations).Assembly;
    private static readonly Assembly SimulationAssembly = typeof(SimulatedDirectorySource).Assembly;

    private static readonly (string Name, OperationClass Class)[] SimulationOperations =
    [
        ("accounts.access.activate", OperationClass.NetworkRead),
        ("accounts.access.cancel", OperationClass.Local),
        ("accounts.access.clear", OperationClass.LocalRead),
        ("accounts.access.dismiss", OperationClass.Local),
        ("accounts.access.forget", OperationClass.LocalRead),
        ("accounts.access.forgetAll", OperationClass.LocalRead),
        ("accounts.access.recover", OperationClass.NetworkRead),
        ("accounts.access.revision", OperationClass.Local),
        ("accounts.access.state", OperationClass.LocalRead),
        ("accounts.access.test", OperationClass.NetworkRead),
        ("accounts.access.tryRemote", OperationClass.NetworkRead),
        ("accounts.batch.cancel", OperationClass.Local),
        ("accounts.batch.confirm", OperationClass.Local),
        ("accounts.batch.plan", OperationClass.LocalRead),
        ("accounts.batch.preview", OperationClass.LocalRead),
        ("accounts.connection.correct", OperationClass.NetworkRead),
        ("accounts.connection.switch", OperationClass.NetworkRead),
        ("accounts.detail", OperationClass.LocalRead),
        ("accounts.disable.plan", OperationClass.LocalRead),
        ("accounts.enable.plan", OperationClass.LocalRead),
        ("accounts.expiration.plan", OperationClass.LocalRead),
        ("accounts.list", OperationClass.LocalRead),
        ("accounts.lockouts", OperationClass.NetworkRead),
        ("accounts.mustChange.plan", OperationClass.LocalRead),
        ("accounts.password.plan", OperationClass.LocalRead),
        ("accounts.remembered.forget", OperationClass.LocalWrite),
        ("accounts.requirements", OperationClass.Local),
        ("accounts.scope.get", OperationClass.LocalRead),
        ("accounts.scope.reset", OperationClass.LocalWrite),
        ("accounts.scope.set", OperationClass.LocalWrite),
        ("accounts.transports", OperationClass.LocalRead),
        ("accounts.unlock.plan", OperationClass.LocalRead),
        ("accueil.analysis.compare", OperationClass.LocalRead),
        ("accueil.analysis.pivots", OperationClass.LocalRead),
        ("accueil.analysis.snapshots", OperationClass.LocalRead),
        ("accueil.bitlocker.read", OperationClass.NetworkRead),
        ("accueil.board", OperationClass.LocalRead),
        ("accueil.cache.clear", OperationClass.Local),
        ("accueil.collections", OperationClass.LocalRead),
        ("accueil.favorite.drop", OperationClass.LocalWrite),
        ("accueil.favorite.save", OperationClass.LocalWrite),
        ("accueil.favorites", OperationClass.LocalRead),
        ("accueil.firstSteps", OperationClass.LocalRead),
        ("accueil.firstSteps.dismiss", OperationClass.LocalWrite),
        ("accueil.health.exceptions", OperationClass.LocalRead),
        ("accueil.health.explain", OperationClass.LocalRead),
        ("accueil.health.policy", OperationClass.LocalRead),
        ("accueil.health.revert", OperationClass.LocalWrite),
        ("accueil.health.save", OperationClass.LocalWrite),
        ("accueil.help.seen", OperationClass.LocalWrite),
        ("accueil.journal", OperationClass.LocalRead),
        ("accueil.lastView", OperationClass.LocalRead),
        ("accueil.lastView.save", OperationClass.LocalWrite),
        ("accueil.layout", OperationClass.LocalRead),
        ("accueil.layout.reset", OperationClass.LocalWrite),
        ("accueil.layout.save", OperationClass.LocalWrite),
        ("accueil.probe", OperationClass.Local),
        ("accueil.provenance", OperationClass.LocalRead),
        ("accueil.refresh.plan", OperationClass.LocalRead),
        ("accueil.refresh.run", OperationClass.NetworkRead),
        ("accueil.refresh.state", OperationClass.Local),
        ("accueil.refresh.stop", OperationClass.Local),
        ("accueil.scope.reset", OperationClass.LocalWrite),
        ("accueil.selfCheck", OperationClass.LocalRead),
        ("accueil.snapshot.take", OperationClass.LocalWrite),
        ("accueil.targets", OperationClass.LocalRead),
        ("accueil.widgets.catalog", OperationClass.Local),
        ("assistance.capture.clear", OperationClass.Local),
        ("assistance.capture.export", OperationClass.LocalWrite),
        ("assistance.capture.import", OperationClass.Local),
        ("assistance.capture.swap", OperationClass.Local),
        ("assistance.capture.take", OperationClass.Local),
        ("assistance.computers.resolve", OperationClass.LocalRead),
        ("assistance.document.reveal", OperationClass.Local),
        ("assistance.dossier.prepare", OperationClass.LocalWrite),
        ("assistance.engine.state", OperationClass.Local),
        ("assistance.incidents.clear", OperationClass.Local),
        ("assistance.overview", OperationClass.Local),
        ("assistance.pin.add", OperationClass.Local),
        ("assistance.pin.locate", OperationClass.LocalRead),
        ("assistance.pin.remove", OperationClass.Local),
        ("assistance.recipes", OperationClass.Local),
        ("assistance.report.export", OperationClass.LocalWrite),
        ("assistance.report.preview", OperationClass.Local),
        ("assistance.step.run", OperationClass.NetworkRead),
        ("assistance.subject.analyse", OperationClass.Local),
        ("assistance.subject.read", OperationClass.LocalRead),
        ("assistance.subjects.search", OperationClass.LocalRead),
        ("assistance.subjects.suggest", OperationClass.LocalRead),
        ("assistance.ticket.export", OperationClass.LocalWrite),
        ("assistance.ticket.preview", OperationClass.Local),
        ("assistance.workshop.get", OperationClass.Local),
        ("assistance.workshop.poll", OperationClass.Local),
        ("assistance.workshop.reset", OperationClass.Local),
        ("audit.catalogue", OperationClass.Local),
        ("audit.dc.compare", OperationClass.NetworkRead),
        ("audit.dc.list", OperationClass.NetworkRead),
        ("audit.dc.probe", OperationClass.NetworkRead),
        ("audit.dc.services", OperationClass.NetworkRead),
        ("audit.finding.objects", OperationClass.Local),
        ("audit.identities.scan", OperationClass.NetworkRead),
        ("audit.localTotals", OperationClass.LocalRead),
        ("audit.object.acl", OperationClass.NetworkRead),
        ("audit.object.estimate", OperationClass.Local),
        ("audit.object.gpoApplied", OperationClass.NetworkRead),
        ("audit.object.gpoLinks", OperationClass.NetworkRead),
        ("audit.object.groupPath", OperationClass.Local),
        ("audit.object.groups", OperationClass.NetworkRead),
        ("audit.object.history", OperationClass.LocalRead),
        ("audit.object.machineIdentity", OperationClass.NetworkRead),
        ("audit.object.membership", OperationClass.NetworkRead),
        ("audit.object.policy", OperationClass.NetworkRead),
        ("audit.object.relations", OperationClass.LocalRead),
        ("audit.object.tokenGroups", OperationClass.NetworkRead),
        ("audit.objects.search", OperationClass.LocalRead),
        ("audit.overview", OperationClass.NetworkRead),
        ("audit.suggestions", OperationClass.LocalRead),
        ("audit.target", OperationClass.LocalRead),
        ("dashboard.summary", OperationClass.LocalRead),
        ("dashboard.widget.refresh", OperationClass.NetworkRead),
        ("dashboard.widget.setEnabled", OperationClass.LocalWrite),
        ("directory.ou.children", OperationClass.LocalRead),
        ("directory.ou.search", OperationClass.LocalRead),
        .. SearchOperationsTests.Operations,
        ("fiche.attributes", OperationClass.LocalRead),
        ("fiche.callSheet", OperationClass.LocalRead),
        ("fiche.callSheet.read", OperationClass.NetworkRead),
        ("fiche.compare", OperationClass.LocalRead),
        ("fiche.createOu.plan", OperationClass.LocalRead),
        ("fiche.delete.plan", OperationClass.LocalRead),
        ("fiche.destinations", OperationClass.LocalRead),
        ("fiche.enable.plan", OperationClass.LocalRead),
        ("fiche.expiration.plan", OperationClass.LocalRead),
        ("fiche.expirePassword.plan", OperationClass.LocalRead),
        ("fiche.groups", OperationClass.LocalRead),
        ("fiche.groups.delta", OperationClass.Local),
        ("fiche.groups.delta.check", OperationClass.LocalRead),
        ("fiche.groups.nested", OperationClass.LocalRead),
        ("fiche.groups.why", OperationClass.LocalRead),
        ("fiche.history", OperationClass.LocalRead),
        ("fiche.lockouts", OperationClass.NetworkRead),
        ("fiche.logonByDc", OperationClass.NetworkRead),
        ("fiche.members", OperationClass.LocalRead),
        ("fiche.membership.plan", OperationClass.LocalRead),
        ("fiche.move.plan", OperationClass.LocalRead),
        ("fiche.options.plan", OperationClass.LocalRead),
        ("fiche.pick", OperationClass.LocalRead),
        ("fiche.presence", OperationClass.NetworkRead),
        ("fiche.preview", OperationClass.LocalRead),
        ("fiche.rawAttribute.plan", OperationClass.LocalRead),
        ("fiche.read", OperationClass.LocalRead),
        ("fiche.recent", OperationClass.LocalRead),
        ("fiche.recent.add", OperationClass.LocalWrite),
        ("fiche.recent.clear", OperationClass.LocalWrite),
        ("fiche.relations", OperationClass.LocalRead),
        ("fiche.resetPassword.plan", OperationClass.LocalRead),
        ("fiche.resolve", OperationClass.LocalRead),
        ("fiche.rights", OperationClass.NetworkRead),
        ("fiche.update.plan", OperationClass.LocalRead),
        ("relations.associate.plan", OperationClass.LocalRead),
        ("relations.compare", OperationClass.LocalRead),
        ("relations.computer.read", OperationClass.NetworkRead),
        ("relations.detect.collect", OperationClass.NetworkRead),
        ("relations.detect.run", OperationClass.NetworkRead),
        ("relations.detect.stop", OperationClass.Local),
        ("relations.export.open", OperationClass.Local),
        ("relations.export.save", OperationClass.LocalWrite),
        ("relations.harvest.estimate", OperationClass.LocalRead),
        ("relations.harvest.run", OperationClass.NetworkRead),
        ("relations.import.plan", OperationClass.LocalRead),
        ("relations.import.preview", OperationClass.LocalRead),
        ("relations.import.stage", OperationClass.Local),
        ("relations.import.undo.plan", OperationClass.LocalRead),
        ("relations.journal", OperationClass.LocalRead),
        ("relations.list", OperationClass.LocalRead),
        ("relations.observations.pending", OperationClass.LocalRead),
        ("relations.observations.plan", OperationClass.LocalRead),
        ("relations.orphans.check", OperationClass.NetworkRead),
        ("relations.orphans.plan", OperationClass.LocalRead),
        ("relations.overview", OperationClass.LocalRead),
        ("relations.remove.plan", OperationClass.LocalRead),
        ("relations.restore.plan", OperationClass.LocalRead),
        ("relations.subject", OperationClass.LocalRead),
        ("relations.subjects.search", OperationClass.LocalRead),
        ("relations.sweep.forget.plan", OperationClass.LocalRead),
        ("relations.sweep.plan", OperationClass.LocalRead),
        ("relations.targets.search", OperationClass.NetworkRead),
        ("poste.account.find", OperationClass.LocalRead),
        ("poste.account.other", OperationClass.NetworkRead),
        ("poste.account.plan", OperationClass.LocalRead),
        ("poste.bios.reference", OperationClass.LocalWrite),
        ("poste.bitlocker.list", OperationClass.NetworkRead),
        ("poste.bitlocker.reveal", OperationClass.NetworkRead),
        ("poste.collect.stop", OperationClass.Local),
        ("poste.commands", OperationClass.LocalRead),
        ("poste.consent.grant", OperationClass.Local),
        ("poste.consent.history", OperationClass.Local),
        ("poste.consent.revoke", OperationClass.Local),
        ("poste.diagnostic", OperationClass.NetworkRead),
        ("poste.dsreg.analyze", OperationClass.Local),
        ("poste.events", OperationClass.NetworkRead),
        ("poste.export.save", OperationClass.LocalWrite),
        ("poste.gpupdate.plan", OperationClass.LocalRead),
        ("poste.group.plan", OperationClass.LocalRead),
        ("poste.groups.search", OperationClass.LocalRead),
        ("poste.host", OperationClass.LocalRead),
        ("poste.inventory", OperationClass.NetworkRead),
        ("poste.inventory.cached", OperationClass.LocalRead),
        ("poste.laps", OperationClass.NetworkRead),
        ("poste.laps.reveal", OperationClass.NetworkRead),
        ("poste.lastUser.detect", OperationClass.NetworkRead),
        ("poste.list", OperationClass.LocalRead),
        ("poste.live", OperationClass.NetworkRead),
        ("poste.logonByDc", OperationClass.NetworkRead),
        ("poste.move.plan", OperationClass.LocalRead),
        ("poste.open", OperationClass.LocalRead),
        ("poste.option.set", OperationClass.LocalWrite),
        ("poste.ping", OperationClass.NetworkRead),
        ("poste.probe.details", OperationClass.LocalRead),
        ("poste.probes.collect", OperationClass.NetworkRead),
        ("poste.processes", OperationClass.NetworkRead),
        ("poste.profile.plan", OperationClass.LocalRead),
        ("poste.quickDiag", OperationClass.NetworkRead),
        ("poste.readings", OperationClass.LocalRead),
        ("poste.rename.plan", OperationClass.LocalRead),
        ("poste.restart.plan", OperationClass.LocalRead),
        ("poste.restart.sessions", OperationClass.NetworkRead),
        ("poste.restartCancel.plan", OperationClass.LocalRead),
        ("poste.run.plan", OperationClass.LocalRead),
        ("poste.running", OperationClass.Local),
        ("poste.secret.hide", OperationClass.Local),
        ("poste.secret.state", OperationClass.Local),
        ("poste.secrets.index", OperationClass.NetworkRead),
        ("poste.service.plan", OperationClass.LocalRead),
        ("poste.services", OperationClass.NetworkRead),
        ("poste.sessions", OperationClass.NetworkRead),
        ("poste.slow", OperationClass.NetworkRead),
        ("poste.software", OperationClass.NetworkRead),
        ("poste.software.cached", OperationClass.LocalRead),
        ("poste.suite.launch", OperationClass.NetworkRead),
        ("poste.suite.plan", OperationClass.LocalRead),
        ("poste.tool.open", OperationClass.NetworkRead),
        ("poste.wake.plan", OperationClass.LocalRead),
        ("poste.wmi.classes", OperationClass.NetworkRead),
        ("poste.wmi.namespaces", OperationClass.NetworkRead),
        ("poste.wmi.query", OperationClass.NetworkRead),
        ("requetes.catalog", OperationClass.Local),
        ("requetes.cmdlets", OperationClass.LocalRead),
        ("requetes.collect.object", OperationClass.NetworkRead),
        ("requetes.collect.plan", OperationClass.LocalRead),
        ("requetes.collect.run", OperationClass.NetworkRead),
        ("requetes.consumer.bind", OperationClass.LocalWrite),
        ("requetes.consumer.release", OperationClass.LocalWrite),
        ("requetes.coverage", OperationClass.LocalRead),
        ("requetes.details.list", OperationClass.LocalRead),
        ("requetes.draft.get", OperationClass.LocalRead),
        ("requetes.draft.keep", OperationClass.LocalWrite),
        ("requetes.export.content", OperationClass.Local),
        ("requetes.export.save", OperationClass.LocalWrite),
        ("requetes.ldap.read", OperationClass.Local),
        ("requetes.library.archive", OperationClass.LocalWrite),
        ("requetes.library.get", OperationClass.LocalRead),
        ("requetes.library.impact", OperationClass.LocalRead),
        ("requetes.library.list", OperationClass.LocalRead),
        ("requetes.library.restore", OperationClass.LocalWrite),
        ("requetes.library.revert", OperationClass.LocalWrite),
        ("requetes.library.save", OperationClass.LocalWrite),
        ("requetes.object.test", OperationClass.LocalRead),
        ("requetes.objects.find", OperationClass.LocalRead),
        ("requetes.pack.apply", OperationClass.LocalWrite),
        ("requetes.pack.examine", OperationClass.LocalRead),
        ("requetes.pack.export", OperationClass.LocalRead),
        ("requetes.pack.history", OperationClass.LocalRead),
        ("requetes.pack.part", OperationClass.Local),
        ("requetes.pack.rollback", OperationClass.LocalWrite),
        ("requetes.pack.version", OperationClass.LocalRead),
        ("requetes.preview", OperationClass.LocalRead),
        ("requetes.preview.export", OperationClass.Local),
        ("requetes.preview.groups", OperationClass.LocalRead),
        ("requetes.preview.object", OperationClass.LocalRead),
        ("requetes.preview.page", OperationClass.LocalRead),
        ("requetes.preview.segment", OperationClass.Local),
        ("requetes.scope", OperationClass.LocalRead),
        ("requetes.scope.set", OperationClass.LocalWrite),
        ("requetes.script", OperationClass.Local),
        ("requetes.search.apply", OperationClass.Local),
        ("requetes.search.clear", OperationClass.Local),
        ("requetes.search.selection", OperationClass.Local),
        ("requetes.validate", OperationClass.Local),
        ("requetes.value.preview", OperationClass.Local),
        ("requetes.widget.evaluate", OperationClass.LocalRead),
        ("requetes.widget.list", OperationClass.LocalRead),
        ("requetes.widget.remove", OperationClass.LocalWrite),
        ("requetes.widget.save", OperationClass.LocalWrite),
        ("requetes.wmi.analyze", OperationClass.Local),
        ("requetes.wmi.build", OperationClass.Local),
        ("requetes.wmi.cache", OperationClass.LocalRead),
        ("requetes.wmi.classes", OperationClass.NetworkRead),
        ("requetes.wmi.namespaces", OperationClass.NetworkRead),
        ("requetes.wmi.recipe", OperationClass.Local),
        ("requetes.wmi.relation", OperationClass.NetworkRead),
        ("requetes.wmi.relations", OperationClass.Local),
        ("requetes.wmi.run", OperationClass.NetworkRead),
        ("requetes.wmi.schema", OperationClass.NetworkRead),
        ("session.info", OperationClass.LocalRead),
        ("session.setScope", OperationClass.LocalWrite),
        ("shell.activity", OperationClass.LocalRead),
        ("shell.automation.contract", OperationClass.Local),
        ("shell.automation.preview", OperationClass.LocalRead),
        ("shell.demo.coverage", OperationClass.LocalRead),
        ("shell.fault", OperationClass.LocalWrite),
        ("shell.interface.get", OperationClass.LocalRead),
        ("shell.interface.set", OperationClass.LocalWrite),
        ("shell.lookup", OperationClass.LocalRead),
        ("shell.lookup.verify", OperationClass.LocalRead),
        ("write.execute", OperationClass.Write),
        ("write.receipts.get", OperationClass.LocalRead),
        ("write.receipts.list", OperationClass.LocalRead),
        ("write.receipts.verify", OperationClass.NetworkRead),
    ];

    private static EngineContext Context(AppMode mode = AppMode.Simulation, IDirectorySource? source = null)
    {
        var decision = mode == AppMode.Simulation
            ? SimulatedBridge.Decision
            : ModeResolver.Resolve([], null, () => new DomainJoinInfo(DomainJoinState.Joined, "cnamts.local"));
        source ??= mode == AppMode.Simulation
            ? new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, TestClock.Fixed())
            : new UnavailableDirectorySource("cnamts.local", () => @"CNAMTS\degun");
        return new EngineContext(decision, source, new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal(), ScreenReaders.Discover(source, [SimulationAssembly]));
    }

    [Test]
    public static void Modules_of_the_bridge_are_found_without_any_central_list()
    {
        var modules = OperationModules.Discover([BridgeAssembly]);
        string[] names = [.. modules.Select(m => m.GetType().Name)];
        Check.True(names.SequenceEqual(["AccountUnlockOperations", "AccountsAccessOperations", "AccountsOperations", "AccueilOperations", "AssistanceOperations", "AuditOperations", "DashboardOperations", "DirectoryTreeOperations", "FicheOperations", "PosteOperations", "RelationsOperations", "RequetesOperations", "RequetesWmiOperations", "SearchOperations", "SessionOperations", "ShellOperations", "WriteOperations"]), "modules trouvés : " + string.Join(", ", names));
        using var context = Context();
        var registry = OperationModules.CreateRegistry(context, modules);
        Check.Equal(SimulationOperations.Length, registry.Names.Count, "opérations déclarées");
        foreach (var (name, operationClass) in SimulationOperations)
        {
            Check.True(registry.TryGet(name, out var definition), "opération présente : " + name);
            Check.Equal(operationClass, definition!.Class, "classe de " + name);
        }
    }

    [Test]
    public static void Tree_reads_are_network_reads_in_directory_mode()
    {
        using var context = Context(AppMode.Directory);
        var registry = OperationModules.CreateRegistry(context, OperationModules.Discover([BridgeAssembly]));
        Check.True(registry.TryGet("directory.ou.children", out var children), "arbre déclaré");
        Check.Equal(OperationClass.NetworkRead, children!.Class, "lecture réseau en mode annuaire");
        Check.True(registry.TryGet("directory.ou.search", out var search), "recherche déclarée");
        Check.Equal(OperationClass.NetworkRead, search!.Class, "lecture réseau en mode annuaire");
    }

    [Test]
    public static void Only_public_concrete_modules_with_a_parameterless_constructor_are_found()
    {
        var modules = OperationModules.Discover([typeof(PlatformTests).Assembly]);
        string[] names = [.. modules.Select(m => m.GetType().Name)];
        Check.True(names.SequenceEqual(["ProbeModule"]), "seul le module public est trouvé : " + string.Join(", ", names));
    }

    [Test]
    public static void Composition_errors_stop_the_start()
    {
        using var context = Context();
        Check.Throws<InvalidOperationException>(() => OperationModules.CreateRegistry(context, [new OutsideScreenModule()]), "opération hors de son écran");
        Check.Throws<InvalidOperationException>(() => OperationModules.CreateRegistry(context, [new InvalidScreenModule()]), "nom d’écran invalide");
        Check.Throws<ArgumentException>(() => OperationModules.CreateRegistry(context, [new ProbeModule(), new DuplicateModule()]), "opération en double");
        Check.True(OperationModules.IsValidScreen("dashboard"), "écran valide");
        Check.False(OperationModules.IsValidScreen("Dashboard"), "majuscule refusée");
        Check.False(OperationModules.IsValidScreen("dash.board"), "point refusé");
        Check.False(OperationModules.IsValidScreen(""), "vide refusé");
    }

    [Test]
    public static async Task Discovered_module_runs_through_the_dispatcher()
    {
        using var context = Context();
        var registry = OperationModules.CreateRegistry(context, OperationModules.Discover([typeof(PlatformTests).Assembly]));
        var sent = new List<BridgeResponse>();
        var dispatcher = new BridgeDispatcher(registry, sent.Add, AdmissionGuards.For(AppMode.Simulation));
        await dispatcher.HandleAsync("""{"id":"p1","op":"probe.echo","args":{}}""", CancellationToken.None);
        Check.Equal("result", sent.Single().Kind, "réponse du module trouvé");
        Check.Equal("Simulation", (string)sent.Single().Data!, "le module a reçu le contexte");
    }

    [Test]
    public static void Domenia_assemblies_come_from_the_trusted_list_only()
    {
        var assemblies = OperationModules.LoadDomeniaAssemblies();
        string[] names = [.. assemblies.Select(a => a.GetName().Name!)];
        foreach (var expected in new[] { "Domenia.Core", "Domenia.Bridge", "Domenia.Simulation", "Domenia.Store" })
        {
            Check.True(names.Contains(expected), "assemblage chargé : " + expected);
        }
        Check.True(names.All(n => n == "Domenia" || n.StartsWith("Domenia.", StringComparison.Ordinal)), "seulement des assemblages Domenia : " + string.Join(", ", names));
    }

    [Test]
    public static void Screen_readers_follow_the_source_of_the_mode()
    {
        var simulated = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, TestClock.Fixed());
        var readers = ScreenReaders.Discover(simulated, [SimulationAssembly, typeof(PlatformTests).Assembly]);
        Check.True(readers.Find<IDirectoryTreeReader>() is SimulatedDirectoryTreeReader, "arbre simulé trouvé");
        Check.True(ReferenceEquals(readers.Find<IOrganizationalUnitIndex>(), readers.Find<IDirectoryTreeReader>()), "index local des OU : la même instance");
        Check.Null(readers.Find<IProbeReader>(), "lecteur d’une autre source ignoré");

        var unavailable = new UnavailableDirectorySource("cnamts.local", () => @"CNAMTS\degun");
        var none = ScreenReaders.Discover(unavailable, [SimulationAssembly]);
        Check.Null(none.Find<IDirectoryTreeReader>(), "aucun arbre sans Domenia.Ad");
        Check.Null(none.Find<IOrganizationalUnitIndex>(), "aucun index local sans base");
        var refused = Check.Throws<DomeniaOperationException>(() => none.Require<IDirectoryTreeReader>(), "lecteur exigé");
        Check.Equal(DomeniaErrors.SourceUnavailable, refused.Code, "source indisponible");

        var probe = ScreenReaders.Discover(new ProbeSource(), [SimulationAssembly, typeof(PlatformTests).Assembly]);
        Check.Equal("Simulation", probe.Require<IProbeReader>().Name, "lecteur construit avec sa source");
        Check.True(probe.Interfaces.SequenceEqual(["IProbeReader"]), "interfaces servies : " + string.Join(", ", probe.Interfaces));
    }

    [Test]
    public static void Screen_reader_constructors_read_nothing()
    {
        var source = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, TestClock.Fixed());
        _ = ScreenReaders.Discover(source, [SimulationAssembly]);
        // The world is a Lazy: discovering the readers must not generate it (startup stays light, on the UI thread).
        var field = typeof(SimulatedDirectorySource).GetField("world", BindingFlags.NonPublic | BindingFlags.Instance);
        var lazy = (Lazy<SimulatedWorld>)field!.GetValue(source)!;
        Check.False(lazy.IsValueCreated, "aucune génération à la découverte");
    }

    [Test]
    public static void Screen_read_interfaces_have_no_write_method()
    {
        string[] verbs = ["Write", "Set", "Delete", "Move", "Reset", "Unlock", "Enable", "Disable", "Add", "Remove", "Create", "Update"];
        var interfaces = typeof(IScreenReader).Assembly.GetExportedTypes().Where(t => t.IsInterface && typeof(IScreenReader).IsAssignableFrom(t));
        foreach (var type in interfaces)
        {
            foreach (var method in type.GetMethods())
            {
                Check.False(verbs.Any(v => method.Name.StartsWith(v, StringComparison.Ordinal)), $"méthode d’écriture : {type.Name}.{method.Name}");
            }
        }
    }

    [Test]
    public static void Engine_services_are_shared_and_disposed_with_the_context()
    {
        var context = Context();
        var first = DashboardService.From(context);
        Check.True(ReferenceEquals(first, DashboardService.From(context)), "un seul service de l’Accueil par contexte");
        Check.True(ReferenceEquals(WorkingScope.From(context), WorkingScope.From(context)), "une seule OU de travail par contexte");
        context.Dispose();
        Check.Throws<ObjectDisposedException>(() => DashboardService.From(context), "contexte fermé");
        context.Dispose();
    }

    [Test]
    public static async Task Simulation_guard_admits_local_writes_and_always_refuses_writes()
    {
        var ran = new List<string>();
        OperationDefinition Define(string name, OperationClass operationClass, bool served = false) =>
            new(name, operationClass, (_, _, _) =>
            {
                ran.Add(name);
                return Task.FromResult<object?>(null);
            }, "test", served);
        var registry = new OperationRegistry(
        [
            Define("test.local", OperationClass.Local),
            Define("test.read", OperationClass.LocalRead),
            Define("test.preference", OperationClass.LocalWrite),
            Define("test.write", OperationClass.Write, served: true),
        ]);
        var sent = new List<BridgeResponse>();
        var dispatcher = new BridgeDispatcher(registry, sent.Add, AdmissionGuards.For(AppMode.Simulation));
        foreach (var name in new[] { "test.local", "test.read", "test.preference", "test.write" })
        {
            await dispatcher.HandleAsync("{\"id\":\"x\",\"op\":\"" + name + "\",\"args\":{}}", CancellationToken.None);
        }
        Check.True(ran.SequenceEqual(["test.local", "test.read", "test.preference"]), "local, lecture locale et écriture locale admises : " + string.Join(", ", ran));
        Check.Equal(DomeniaErrors.SimulationReadOnly, sent[^1].Error!.Code, "écriture AD refusée, même marquée servie");
        Check.Null(AdmissionGuards.ReadOnlySimulation(new OperationDefinition("x.y", OperationClass.LocalWrite, (_, _, _) => Task.FromResult<object?>(null), "t")), "LocalWrite admise");
    }
}
