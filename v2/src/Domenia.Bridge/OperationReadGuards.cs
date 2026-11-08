using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>One admission boundary for history, queries, preloads and account switches. Receipt resolution stays accessible.</summary>
public static class OperationReadGuards
{
    public static bool RequiresGuard(string name) => name is
        "search.run" or "search.browse" or "search.containers" or "search.view" or "search.more" or
        "search.localQuery" or "search.preload" or "search.preview" or "search.revalidate" or "search.reconcile" or
        "search.netdiag" or "search.netdiag.plan" or "search.recheck" or "search.survey.plan" or "search.survey.run" or "search.home.selection" or
        "machine.account.use" or "machine.account.forget" or "machine.account.trial" or "poste.account.other" or
        "accounts.access.test" or "accounts.access.activate" or "accounts.access.clear" or "accounts.access.recover" or
        "accounts.connection.switch" or "accounts.connection.correct" or "relations.remove.plan" or "accounts.access.forget" or "accounts.access.forgetAll" or "session.connect" ||
        name.StartsWith("requetes.preview", StringComparison.Ordinal) ||
        name.StartsWith("requetes.collect.", StringComparison.Ordinal) ||
        name is "requetes.ldap.read" or "requetes.value.preview" or "requetes.object.test" or "requetes.objects.find" or "requetes.widget.evaluate";

    public static OperationDefinition Bind(EngineContext context, OperationDefinition definition)
    {
        if (!RequiresGuard(definition.Name)) return definition;
        var inner = definition.Handler;
        return definition with { Handler = async (args, bridge, token) =>
        {
            var circuit = WriteCircuit.From(context);
            var version = await circuit.EnsureConsultationAllowedAsync(token).ConfigureAwait(false);
            var result = await inner(args, bridge, token).ConfigureAwait(false);
            // Account mutations have already happened: never report them as unapplied after the fact.
            if (definition.Name.StartsWith("search.", StringComparison.Ordinal) || definition.Name.StartsWith("requetes.", StringComparison.Ordinal))
                await circuit.EnsureConsultationUnchangedAsync(version, token).ConfigureAwait(false);
            return result;
        } };
    }
}
