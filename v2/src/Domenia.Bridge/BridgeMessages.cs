using System.Text.Json;
using System.Text.Json.Serialization;

namespace Domenia.Bridge;

/// <summary>Request sent by the page: a correlation id, a declared operation name and its JSON arguments.</summary>
public sealed record BridgeRequest(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("op")] string Operation,
    [property: JsonPropertyName("args")] JsonElement Arguments);

/// <summary>Answer or event pushed to the page. <see cref="Kind"/> is "result", "error" or "event"; « error » is written only when set.</summary>
public sealed record BridgeResponse(
    [property: JsonPropertyName("id")] string? Id,
    [property: JsonPropertyName("kind")] string Kind,
    [property: JsonPropertyName("op")] string Operation,
    [property: JsonPropertyName("data")] object? Data,
    [property: JsonPropertyName("error"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] BridgeError? Error = null);

/// <summary>Error returned to the page: a stable code for the interface and a French message for the operator.</summary>
public sealed record BridgeError(
    [property: JsonPropertyName("code")] string Code,
    [property: JsonPropertyName("message")] string Message);

/// <summary>Class of an operation, which decides how the engine admits and budgets it.</summary>
public enum OperationClass
{
    /// <summary>Pure computation or in-memory state; never touches disk or network.</summary>
    Local,
    /// <summary>Read of the local SQLite store or local files.</summary>
    LocalRead,
    /// <summary>Directory, WMI, DNS or ping read; only after an explicit operator gesture.</summary>
    NetworkRead,
    /// <summary>
    /// Write to the local preferences of the application only (user data folder, separate document in simulation); never
    /// the directory nor a workstation. Admitted in simulation.
    /// </summary>
    LocalWrite,
    /// <summary>Write to Active Directory or remote action; plan, confirmation, receipt and re-read required.</summary>
    Write,
}
