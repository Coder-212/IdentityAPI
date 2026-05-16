public interface IUserProvisioningSubmissionProcessor
{
    Task ProcessAsync(
        ProvisioningType type,
        CancellationToken cancellationToken);
}

/// <summary>
/// Processes reserved user provisioning requests for a specific provisioning type.
/// </summary>
/// <remarks>
/// This processor is shared by the Create, Update and Delete provisioning jobs.
/// It keeps the existing job behavior unchanged:
/// it reserves a batch of provisioning requests, groups them by client,
/// retrieves the related Keycloak configuration, then generates the expected Excel file.
/// </remarks>
/// <param name="type">
/// The provisioning operation type to process: Create, Update or Delete.
/// </param>
/// <param name="cancellationToken">
/// The cancellation token used to stop the job execution.
/// </param>
/// <returns>
/// A task representing the asynchronous provisioning job processing.
/// </returns>
public sealed class UserProvisioningSubmissionProcessor : IUserProvisioningSubmissionProcessor
{
    private readonly IEreIdentityMongoContext _contextMongo;
    private readonly KeyCloakSettings _keycloakSettings;
    private readonly IExcelHelperWrapper _excelHelperWrapper;
    private readonly ILogger<UserProvisioningJobProcessor> _logger;

    public UserProvisioningJobProcessor(
        IEreIdentityMongoContext contextMongo,
        IOptions<KeyCloakSettings> keycloakSettings,
        IExcelHelperWrapper excelHelperWrapper,
        ILogger<UserProvisioningJobProcessor> logger)
    {
        _contextMongo = contextMongo;
        _keycloakSettings = keycloakSettings.Value;
        _excelHelperWrapper = excelHelperWrapper;
        _logger = logger;
    }

    public async Task ProcessAsync(
        ProvisioningType type,
        CancellationToken cancellationToken)
    {
        var requests = (await _contextMongo.TryReserveProvisioningRequestsBatchAsync(
                type,
                cancellationToken))
            .ToList();

        if (requests.Count == 0)
        {
            _logger.LogInformation("No provisioning requests found for {Type}", type);
            return;
        }

        _logger.LogInformation(
            "Reserved {Count} provisioning requests for {Type}",
            requests.Count,
            type);

        var clients = requests
            .Where(x => !string.IsNullOrWhiteSpace(x.ClientId))
            .Select(x => x.ClientId!)
            .Distinct()
            .ToList();

        var applicationInfos = await _contextMongo.GetApplicationInfosAsync(
            clients,
            cancellationToken);

        var serviceAccountsByClient = applicationInfos
            .GroupBy(x => x.ClientId)
            .ToDictionary(
                x => x.Key,
                x => x.First().KeycloakConfiguration);

        var groupedRequests = requests
            .Where(x => !string.IsNullOrWhiteSpace(x.ClientId))
            .GroupBy(x => x.ClientId!);

        foreach (var requestsByClient in groupedRequests)
        {
            var clientId = requestsByClient.Key;
            var requestList = requestsByClient.ToList();

            _logger.LogInformation(
                "Processing {Count} {Type} provisioning requests for client {ClientId}",
                requestList.Count,
                type,
                clientId);

            if (!serviceAccountsByClient.TryGetValue(clientId, out var serviceAccount))
            {
                _logger.LogWarning(
                    "No configuration found for client {ClientId}",
                    clientId);

                continue;
            }

            switch (type)
            {
                case ProvisioningType.Create:
                    _excelHelperWrapper.CreateUserExcel(
                        requestList,
                        _keycloakSettings.FilePath,
                        serviceAccount,
                        isCreation: true);
                    break;

                case ProvisioningType.Update:
                    _excelHelperWrapper.CreateUserExcel(
                        requestList,
                        _keycloakSettings.FilePath,
                        serviceAccount,
                        isCreation: false);
                    break;

                case ProvisioningType.Delete:
                    var userIds = requestList
                        .Select(x => x.UserId)
                        .Where(x => !string.IsNullOrWhiteSpace(x))
                        .ToList();

                    _excelHelperWrapper.RequestDeleteUserExcel(
                        _keycloakSettings.FilePath,
                        serviceAccount,
                        userIds!);
                    break;

                default:
                    throw new NotSupportedException(
                        $"Provisioning type {type} is not supported.");
            }
        }

        _logger.LogInformation(
            "End provisioning job for {Type}. Reserved count: {Count}",
            type,
            requests.Count);
    }
}

public sealed class UserProvisioningJob : IJob
{
    private readonly IUserProvisioningSubmissionProcessor _processor;

    public UserProvisioningJob(IUserProvisioningSubmissionProcessor processor)
    {
        _processor = processor;
    }

    public Task Execute(IJobExecutionContext context)
    {
        return _processor.ProcessAsync(
            ProvisioningType.Create,
            context.CancellationToken);
    }
}

public sealed class UpdateUserJob : IJob
{
    private readonly IUserProvisioningSubmissionProcessor _processor;

    public UpdateUserJob(IUserProvisioningSubmissionProcessor processor)
    {
        _processor = processor;
    }

    public Task Execute(IJobExecutionContext context)
    {
        return _processor.ProcessAsync(
            ProvisioningType.Update,
            context.CancellationToken);
    }
}

public sealed class DeleteUserJob : IJob
{
    private readonly IUserProvisioningSubmissionProcessor _processor;

    public DeleteUserJob(IUserProvisioningSubmissionProcessor processor)
    {
        _processor = processor;
    }

    public Task Execute(IJobExecutionContext context)
    {
        return _processor.ProcessAsync(
            ProvisioningType.Delete,
            context.CancellationToken);
    }
}

services.AddScoped<IUserProvisioningSubmissionProcessor, UserProvisioningSubmissionProcessor>();
