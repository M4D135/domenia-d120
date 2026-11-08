using System.Reflection;
using System.Reflection.Emit;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class CompiledOperationContractTests
{
    [Test]
    public static void Every_loaded_layer_carries_the_same_reviewed_registry_before_any_operation_is_queued()
    {
        Check.Equal(64, CompiledOperationContracts.Fingerprint.Length, "empreinte compilée réelle");
        CompiledOperationContracts.RequireAssemblies(OperationModules.LoadDomeniaAssemblies());
        var clock = TestClock.Fixed();
        var source = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock);
        using var context = new EngineContext(SimulatedBridge.Decision, source, new MemoryPreferenceStore(), clock,
            new RecordingJournal(), ScreenReaders.Discover(source, [typeof(SimulatedDirectorySource).Assembly]));
        foreach (var hash in new string?[] { null, new string('0', 64) })
        {
            var assembly = AssemblyBuilder.DefineDynamicAssembly(new AssemblyName("Unpinned" + Guid.NewGuid().ToString("N")), AssemblyBuilderAccess.Run);
            if (hash is not null) assembly.SetCustomAttribute(new CustomAttributeBuilder(typeof(AssemblyMetadataAttribute).GetConstructor([typeof(string), typeof(string)])!, [CompiledOperationContracts.MetadataKey, hash]));
            var type = assembly.DefineDynamicModule("body").DefineType("Unreviewed", TypeAttributes.Public);
            var method = type.DefineMethod("Run", MethodAttributes.Public | MethodAttributes.Static, typeof(Task<object>), [typeof(JsonElement), typeof(BridgeContext), typeof(CancellationToken)]);
            var il = method.GetILGenerator(); il.Emit(OpCodes.Ldnull); il.Emit(OpCodes.Ret);
            var handler = type.CreateType()!.GetMethod("Run")!.CreateDelegate<OperationHandler>();
            Check.Throws<InvalidDataException>(() => new OperationRegistry([new("test.read", OperationClass.LocalRead, handler, "Corps non qualifié")]), "registre refusé avant file et exécution");
            Check.Throws<InvalidDataException>(() => OperationModules.CreateRegistryFromDefinitions(context,
                [new("test.read", OperationClass.LocalRead, handler, "Corps masqué par un wrapper")], null), "corps d’origine vérifié avant les wrappers de suivi");
        }
    }
}
