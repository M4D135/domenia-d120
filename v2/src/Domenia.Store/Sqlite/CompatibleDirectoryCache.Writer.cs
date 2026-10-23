using Domenia.Core;

namespace Domenia.Store;

public sealed partial class CompatibleDirectoryCache : ILocalStorageWriter
{
    public async Task<WritePlanDraft> PrepareWriterResumeAsync(CancellationToken cancellationToken) =>
        await (await DatabaseAsync(cancellationToken).ConfigureAwait(false)).PrepareWriterResumeAsync(cancellationToken).ConfigureAwait(false);
    public async Task<WritePrecheck> CheckWriterResumeAsync(WritePlan plan, CancellationToken cancellationToken) =>
        await (await DatabaseAsync(cancellationToken).ConfigureAwait(false)).CheckWriterResumeAsync(plan, cancellationToken).ConfigureAwait(false);
    public async Task<WriteOutcome> ApplyWriterResumeAsync(WritePlan plan, CancellationToken cancellationToken) =>
        await (await DatabaseAsync(cancellationToken).ConfigureAwait(false)).ApplyWriterResumeAsync(plan, cancellationToken).ConfigureAwait(false);
    public async Task<WriteVerification> VerifyWriterResumeAsync(WritePlan plan, CancellationToken cancellationToken) =>
        await (await DatabaseAsync(cancellationToken).ConfigureAwait(false)).VerifyWriterResumeAsync(plan, cancellationToken).ConfigureAwait(false);
}
