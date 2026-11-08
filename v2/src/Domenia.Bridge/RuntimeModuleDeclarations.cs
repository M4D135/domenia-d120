using Domenia.Bridge;

// Closed, compiled exports. Changing a module requires reviewing this declaration; CI compares the real factories.
[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.AccountUnlockOperations), ModuleRegistrationPhase.Screens, "accounts", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "accounts.unlock.plan")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.AccountsAccessOperations), ModuleRegistrationPhase.Screens, "accounts", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "accounts.access.activate", "accounts.access.cancel", "accounts.access.clear", "accounts.access.dismiss",
    "accounts.access.forget", "accounts.access.forgetAll", "accounts.access.recover", "accounts.access.revision",
    "accounts.access.state", "accounts.access.test", "accounts.access.tryRemote", "accounts.connection.correct",
    "accounts.connection.switch", "accounts.remembered.forget", "accounts.requirements", "accounts.transports")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.AccountsOperations), ModuleRegistrationPhase.Screens, "accounts", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "accounts.batch.cancel", "accounts.batch.confirm", "accounts.batch.plan", "accounts.batch.preview",
    "accounts.detail", "accounts.disable.plan", "accounts.enable.plan", "accounts.expiration.plan",
    "accounts.list", "accounts.lockouts", "accounts.mustChange.plan", "accounts.password.plan",
    "accounts.scope.get", "accounts.scope.reset", "accounts.scope.set")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.AccountsVaultOperations), ModuleRegistrationPhase.Screens, "accounts", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "accounts.vault.delete", "accounts.vault.save")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.AccueilOperations), ModuleRegistrationPhase.Screens, "accueil", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "accueil.analysis.compare", "accueil.analysis.pivots", "accueil.analysis.snapshots", "accueil.bitlocker.read",
    "accueil.board", "accueil.cache.clear", "accueil.collections", "accueil.favorite.drop",
    "accueil.favorite.save", "accueil.favorites", "accueil.firstSteps", "accueil.firstSteps.dismiss",
    "accueil.health.exceptions", "accueil.health.explain", "accueil.health.policy", "accueil.health.query",
    "accueil.health.revert", "accueil.health.save", "accueil.help.seen", "accueil.journal",
    "accueil.lastView", "accueil.lastView.save", "accueil.layout", "accueil.layout.reset",
    "accueil.layout.restore", "accueil.layout.save", "accueil.probe", "accueil.provenance",
    "accueil.query.bind", "accueil.refresh.drawn", "accueil.refresh.plan", "accueil.refresh.run",
    "accueil.refresh.state", "accueil.refresh.stop", "accueil.scope.reset", "accueil.selfCheck",
    "accueil.session.details", "accueil.snapshot.take", "accueil.targets", "accueil.widget.cancel",
    "accueil.widget.drawn", "accueil.widget.plan", "accueil.widget.run", "accueil.widget.state",
    "accueil.widgets.catalog")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.AssistanceOperations), ModuleRegistrationPhase.Screens, "assistance", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "assistance.capture.clear", "assistance.capture.export", "assistance.capture.import", "assistance.capture.swap",
    "assistance.capture.take", "assistance.computers.resolve", "assistance.document.reveal", "assistance.dossier.prepare",
    "assistance.engine.state", "assistance.incidents.clear", "assistance.overview", "assistance.pin.add",
    "assistance.pin.locate", "assistance.pin.remove", "assistance.recipes", "assistance.report.export",
    "assistance.report.preview", "assistance.step.run", "assistance.subject.analyse", "assistance.subject.read",
    "assistance.subjects.search", "assistance.subjects.suggest", "assistance.ticket.export", "assistance.ticket.preview",
    "assistance.workshop.get", "assistance.workshop.poll", "assistance.workshop.reset")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.AuditOperations), ModuleRegistrationPhase.Screens, "audit", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "audit.catalogue", "audit.dc.compare", "audit.dc.list", "audit.dc.probe",
    "audit.dc.services", "audit.finding.objects", "audit.identities.scan", "audit.localTotals",
    "audit.object.acl", "audit.object.estimate", "audit.object.gpoApplied", "audit.object.gpoLinks",
    "audit.object.groupPath", "audit.object.groups", "audit.object.history", "audit.object.machineIdentity",
    "audit.object.membership", "audit.object.policy", "audit.object.relations", "audit.object.tokenGroups",
    "audit.objects.search", "audit.overview", "audit.suggestions", "audit.target")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.BoardLayoutOperations), ModuleRegistrationPhase.Screens, "shell", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "shell.board.default.apply", "shell.board.default.preview", "shell.board.export", "shell.board.import.apply",
    "shell.board.import.preview")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.BridgeQueueOperations), ModuleRegistrationPhase.Screens, "operations", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "operations.queue.cancel", "operations.queue.read")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.ConfigurationOperations), ModuleRegistrationPhase.Foundation, "settings", new Type[] {  },
    "settings.configuration.apply", "settings.configuration.export", "settings.configuration.interface", "settings.configuration.options",
    "settings.configuration.preview", "settings.configuration.save")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.DashboardOperations), ModuleRegistrationPhase.Screens, "dashboard", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "dashboard.summary", "dashboard.widget.refresh", "dashboard.widget.setEnabled")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.DirectoryTreeOperations), ModuleRegistrationPhase.Screens, "directory", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "directory.branch.children", "directory.ou.children", "directory.ou.search")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.FicheOperations), ModuleRegistrationPhase.Screens, "fiche", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "fiche.attributes", "fiche.callSheet", "fiche.callSheet.read", "fiche.compare",
    "fiche.createOu.plan", "fiche.delete.plan", "fiche.destinations", "fiche.enable.plan",
    "fiche.expiration.plan", "fiche.expirePassword.plan", "fiche.groups", "fiche.groups.delta",
    "fiche.groups.delta.check", "fiche.groups.nested", "fiche.groups.why", "fiche.history",
    "fiche.lockouts", "fiche.logonByDc", "fiche.members", "fiche.membership.plan",
    "fiche.move.plan", "fiche.options.plan", "fiche.pick", "fiche.presence",
    "fiche.preview", "fiche.rawAttribute.plan", "fiche.read", "fiche.recent",
    "fiche.recent.add", "fiche.recent.clear", "fiche.relations", "fiche.resetPassword.plan",
    "fiche.resolve", "fiche.rights", "fiche.update.plan")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.FicheWorkflowOperations), ModuleRegistrationPhase.Screens, "fiche", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "fiche.compensation.context", "fiche.compensation.plan", "fiche.lifecycle.close", "fiche.lifecycle.create",
    "fiche.lifecycle.get", "fiche.lifecycle.plan", "fiche.lifecycle.prepare", "fiche.lifecycle.record")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.MachineOperations), ModuleRegistrationPhase.Screens, "machine", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "machine.account.forget", "machine.account.state", "machine.account.trial", "machine.account.use",
    "machine.account.watch", "machine.workstations.search")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.OperationsOperations), ModuleRegistrationPhase.Screens, "operations", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "operations.activity", "operations.blockers", "operations.center", "operations.check.run",
    "operations.diagnostic.preview", "operations.diagnostic.save", "operations.dossier.save", "operations.engine",
    "operations.export.save", "operations.health", "operations.interface.report", "operations.journal",
    "operations.overview", "operations.publication.report", "operations.receipts", "operations.receipts.detail",
    "operations.receipts.review", "operations.rules", "operations.runs", "operations.stats",
    "operations.survey.forget", "operations.survey.postpone", "operations.survey.resume", "operations.survey.stop",
    "operations.task.stop")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.PersonalProbeOperations), ModuleRegistrationPhase.Screens, "accueil", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "accueil.probes.apply", "accueil.probes.personal", "accueil.probes.preview")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.PosteLayoutOperations), ModuleRegistrationPhase.Screens, "poste", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "poste.layout.get", "poste.layout.preset", "poste.layout.probe", "poste.layout.query",
    "poste.layout.restore", "poste.layout.save")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.PosteOperations), ModuleRegistrationPhase.Screens, "poste", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "poste.account.find", "poste.account.other", "poste.account.plan", "poste.bios.reference",
    "poste.bitlocker.list", "poste.bitlocker.reveal", "poste.collect.stop", "poste.commands",
    "poste.consent.grant", "poste.consent.history", "poste.consent.revoke", "poste.diagnostic",
    "poste.dsreg.analyze", "poste.events", "poste.export.save", "poste.gpupdate.plan",
    "poste.group.plan", "poste.groups.search", "poste.host", "poste.inventory",
    "poste.inventory.cached", "poste.laps", "poste.laps.reveal", "poste.lastUser.detect",
    "poste.list", "poste.live", "poste.logonByDc", "poste.move.plan",
    "poste.open", "poste.option.set", "poste.ping", "poste.probe.details",
    "poste.probes.collect", "poste.processes", "poste.profile.plan", "poste.quickDiag",
    "poste.read.cleanup.plan", "poste.read.pending", "poste.readings", "poste.rename.plan",
    "poste.restart.plan", "poste.restart.sessions", "poste.restartCancel.plan", "poste.run.plan",
    "poste.running", "poste.secret.hide", "poste.secret.state", "poste.secrets.index",
    "poste.service.plan", "poste.services", "poste.sessions", "poste.slow",
    "poste.software", "poste.software.cached", "poste.detail.cached", "poste.suite.launch", "poste.suite.plan",
    "poste.tool.open", "poste.wake.plan", "poste.wmi.classes", "poste.wmi.namespaces",
    "poste.wmi.query")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.PostePersonalProbeOperations), ModuleRegistrationPhase.Screens, "poste", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "poste.personalProbe.discard", "poste.personalProbe.plan", "poste.personalProbe.run")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.ReferenceDistributionOperations), ModuleRegistrationPhase.Screens, "requetes", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "requetes.reference.distribution.list", "requetes.reference.distribution.read")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.RelationsOperations), ModuleRegistrationPhase.Screens, "relations", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "relations.associate.plan", "relations.compare", "relations.computer.read", "relations.detect.collect",
    "relations.detect.run", "relations.detect.stop", "relations.export.open", "relations.export.save",
    "relations.harvest.estimate", "relations.harvest.run", "relations.import.plan", "relations.import.preview",
    "relations.import.stage", "relations.import.undo.plan", "relations.journal", "relations.list",
    "relations.observations.pending", "relations.observations.plan", "relations.observations.save", "relations.orphans.check",
    "relations.orphans.plan", "relations.overview", "relations.remove.plan", "relations.restore.plan",
    "relations.subject", "relations.subjects.search", "relations.sweep.forget.plan", "relations.sweep.plan",
    "relations.targets.search")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.RequetesOperations), ModuleRegistrationPhase.Screens, "requetes", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "requetes.catalog", "requetes.cmdlets", "requetes.collect.object", "requetes.collect.plan",
    "requetes.collect.run", "requetes.consumer.bind", "requetes.consumer.release", "requetes.coverage",
    "requetes.details.list", "requetes.draft.get", "requetes.draft.keep", "requetes.export.content",
    "requetes.export.save", "requetes.ldap.read", "requetes.library.archive", "requetes.library.get",
    "requetes.library.impact", "requetes.library.list", "requetes.library.restore", "requetes.library.revert",
    "requetes.library.save", "requetes.object.test", "requetes.objects.find", "requetes.pack.apply",
    "requetes.pack.examine", "requetes.pack.export", "requetes.pack.history", "requetes.pack.part",
    "requetes.pack.rollback", "requetes.pack.version", "requetes.preview", "requetes.preview.export",
    "requetes.preview.groups", "requetes.preview.object", "requetes.preview.page", "requetes.preview.segment",
    "requetes.reference.demo.prepare", "requetes.reference.discard", "requetes.reference.history", "requetes.scope",
    "requetes.scope.set", "requetes.home.recipe", "requetes.script", "requetes.search.apply", "requetes.search.clear",
    "requetes.search.selection", "requetes.validate", "requetes.value.preview", "requetes.widget.evaluate",
    "requetes.widget.list", "requetes.widget.place", "requetes.widget.remove", "requetes.widget.save")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.RequetesWmiOperations), ModuleRegistrationPhase.Screens, "requetes", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "requetes.wmi.analyze", "requetes.wmi.build", "requetes.wmi.cache", "requetes.wmi.classes",
    "requetes.wmi.namespaces", "requetes.wmi.recipe", "requetes.wmi.relation", "requetes.wmi.relations",
    "requetes.wmi.run", "requetes.wmi.schema")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.SchemaOperations), ModuleRegistrationPhase.Screens, "schema", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "schema.attribute", "schema.class", "schema.filter.analyze", "schema.filter.insert",
    "schema.list", "schema.read", "schema.status")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.SearchOperations), ModuleRegistrationPhase.Screens, "search", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "search.browse", "search.catalog", "search.checks.resume", "search.compare",
    "search.containers", "search.dns.reverse", "search.favorite.move", "search.favorite.pin",
    "search.favorite.unpin", "search.home.selection", "search.localQuery", "search.measures",
    "search.memory", "search.more", "search.netdiag", "search.netdiag.plan", "search.policy",
    "search.preload", "search.preview", "search.query.favorite", "search.query.rows", "search.recent.add",
    "search.recent.clear", "search.recheck", "search.recipe.more", "search.recipe.run",
    "search.reconcile", "search.revalidate",
    "search.run", "search.selection", "search.suggest", "search.survey.forget",
    "search.survey.plan", "search.survey.run", "search.survey.state", "search.survey.stop",
    "search.view", "search.workspace.remove", "search.workspace.save", "search.workspace.undo")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.SessionOperations), ModuleRegistrationPhase.Foundation, "session", new Type[] {  },
    "session.connect", "session.info", "session.interfaceReady", "session.setScope")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.SettingsOperations), ModuleRegistrationPhase.Screens, "settings", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "settings.collection", "settings.collection.set", "settings.collection.window.check", "settings.connection",
    "settings.connection.forget", "settings.connection.set", "settings.scope.follow", "settings.demo", "settings.demo.scenario.plan",
    "settings.preferences.reset", "settings.remoteCollection", "settings.remoteCollection.set", "settings.storage",
    "settings.storage.backup.plan", "settings.storage.backup.schedule.set", "settings.storage.backupCopy.plan", "settings.storage.integrity",
    "settings.storage.legacy.plan", "settings.storage.legacy.preview", "settings.storage.measure", "settings.storage.move.plan",
    "settings.storage.purge.plan", "settings.storage.purge.preview", "settings.storage.restore.plan", "settings.storage.restore.preferences",
    "settings.storage.resume.plan", "settings.storage.retention.plan", "settings.storage.retention.preview", "settings.storage.retention.set",
    "settings.storage.rollback.plan", "settings.storage.writerResume.plan")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.ShellOperations), ModuleRegistrationPhase.Screens, "shell", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "shell.activity", "shell.automation.contract", "shell.automation.preview", "shell.demo.coverage",
    "shell.diagnostics.handled", "shell.fault", "shell.incident", "shell.interface.get",
    "shell.interface.set", "shell.lookup", "shell.lookup.verify", "shell.metric",
    "shell.ou.resolve")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.SyncOperations), ModuleRegistrationPhase.Screens, "synchro", new Type[] { typeof(global::Domenia.Bridge.SessionOperations), typeof(global::Domenia.Bridge.ConfigurationOperations), typeof(global::Domenia.Bridge.WriteOperations) },
    "synchro.absences.check", "synchro.controls", "synchro.gaps.read", "synchro.index.export",
    "synchro.index.search", "synchro.overview", "synchro.park.reset.plan", "synchro.park.shared.read",
    "synchro.park.state", "synchro.read.discard", "synchro.read.estimate", "synchro.read.run",
    "synchro.read.stop", "synchro.snapshot.compare", "synchro.snapshot.delete.plan", "synchro.snapshot.export",
    "synchro.snapshot.plan", "synchro.store.plan")]

[assembly: OperationModulePlan(typeof(global::Domenia.Bridge.WriteOperations), ModuleRegistrationPhase.Foundation, "write", new Type[] {  },
    "write.execute", "write.receipts.get", "write.receipts.list", "write.receipts.verify")]
