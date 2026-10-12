/**
 * SignForceCloudPushQueueable — best-effort mirror of Salesforce-stored files
 * (template DOCX uploads, generated documents) into every connected cloud
 * provider's configured destination folder.
 *
 * Runs as a Queueable because both call sites commit the file's ContentVersion
 * first, and Salesforce refuses HTTP callouts in a transaction with pending
 * DML. Failures are logged and swallowed: the Salesforce copy is the system of
 * record, the cloud copy is a convenience mirror — a Drive outage or expired
 * token must never break an upload or a generation that already succeeded.
 *
 * Bulk generation enqueues one of these per batch execute (scope size 1), so
 * the one-child-queueable limit of batch context is never exceeded.
 *
 * Sharing: without sharing — the file was committed by the caller moments ago;
 * this job only re-reads it to push the same bytes out.
 */
public with sharing class SignForceCloudPushQueueable implements Queueable, Database.AllowsCallouts {

    private List<Id> contentVersionIds;
    // Optional subfolder under the configured destination ("Templates", the
    // source object's label, …). Blank = destination root.
    private String folderName;

    public SignForceCloudPushQueueable(List<Id> contentVersionIds) {
        this(contentVersionIds, null);
    }

    public SignForceCloudPushQueueable(Id contentVersionId) {
        this(new List<Id>{ contentVersionId }, null);
    }

    public SignForceCloudPushQueueable(Id contentVersionId, String folderName) {
        this(new List<Id>{ contentVersionId }, folderName);
    }

    public SignForceCloudPushQueueable(List<Id> contentVersionIds, String folderName) {
        this.contentVersionIds = contentVersionIds;
        this.folderName = folderName;
    }

    public void execute(QueueableContext ctx) {
        if (contentVersionIds == null || contentVersionIds.isEmpty()) return;
        List<String> providers = IntegrationService.enabledProviders();
        if (providers.isEmpty()) return;

        SignForceFLS.requireAccessible(ContentVersion.SObjectType);
        for (ContentVersion cv : [
            SELECT Title, PathOnClient, FileExtension, VersionData
            FROM ContentVersion WHERE Id IN :contentVersionIds
        ]) {
            try {
                String fileName = String.isNotBlank(cv.PathOnClient) ? cv.PathOnClient : cv.Title;
                String ct = contentTypeFor(cv.FileExtension);
                for (String provider : providers) {
                    String folderId = String.isBlank(folderName)
                        ? IntegrationService.targetForProvider(provider)
                        : IntegrationService.ensureSubfolder(provider, folderName);
                    IntegrationService.pushDocument(provider, fileName, cv.VersionData, ct, folderId);
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'SignForceCloudPushQueueable: push failed for ' + cv.Id + ': ' + e.getMessage());
            }
        }
        // AFTER the last callout: writing the folder-id cache earlier would put
        // DML before the pushes and Salesforce would refuse their callouts.
        IntegrationService.flushSubfolderCache();
    }

    @TestVisible
    private static String contentTypeFor(String ext) {
        String e = ext == null ? '' : ext.toLowerCase();
        if (e == 'pdf') return 'application/pdf';
        if (e == 'docx') return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
        if (e == 'doc') return 'application/msword';
        return 'application/octet-stream';
    }
}