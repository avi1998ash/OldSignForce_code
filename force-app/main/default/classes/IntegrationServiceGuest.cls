/**
 * IntegrationServiceGuest - guest-side copy of IntegrationService.
 *
 * The guest signing completion flow (GuestSigningApi, AgreementControllerGuest) pushes the final
 * signed documents to the connected cloud provider through pushAgreementDocuments. This class holds
 * a verbatim copy of that method and the helpers it needs (anyEnabled, isEnabled, targetFor,
 * pushDocument, callBackend, credsFor, pushCredsFor, cloudFolderName, interpret, mapError, Result),
 * plus primaryProvider (called by SignForceConfigServiceGuest.getClientConfig).
 * Admin, folder-setup, test-connection and queueable methods stay in IntegrationService.
 *
 * SHARING: `with sharing` - deliberately identical to IntegrationService. The guest callers are
 * `without sharing`, but IntegrationService has always been `with sharing`, so this code has always
 * run under the calling user's sharing; keeping the keyword keeps that behaviour unchanged.
 *
 * CONFIG: reads go through SignForceConfigServiceGuest. A failure to configure still raises the
 * ORIGINAL SignForceConfigService.ConfigurationException type.
 * NOTE: Result is a separate inner class (IntegrationServiceGuest.Result); no caller uses it.
 */
public with sharing class IntegrationServiceGuest {

    public static final String GOOGLE_DRIVE = 'GoogleDrive';

    public static final String ONE_DRIVE    = 'OneDrive';

    public static final String BOX          = 'Box';

    public static final String SHAREPOINT   = 'SharePoint';

    public static final String AWS_S3       = 'AwsS3';

    public static final Set<String> PROVIDERS = new Set<String>{
        GOOGLE_DRIVE, ONE_DRIVE, BOX, SHAREPOINT, AWS_S3
    };

    /**
     * Providers the backend can actually OAuth into and upload to, in preference
     * order. Box/SharePoint appear in PROVIDERS but the Lambda has no handler for
     * them yet, so they must not be picked as an upload destination.
     */
    private static final List<String> OAUTH_PROVIDERS = new List<String>{ GOOGLE_DRIVE, ONE_DRIVE };

    /**
     * Human-readable cloud folder name for an agreement: just the record name so
     * it's easy to spot/track in Drive/OneDrive. Strips characters OneDrive/
     * SharePoint reject (" * : < > ? / \ |), trims, and falls back to the record
     * id only if the name is blank. Each agreement stores its own folder id, so
     * two same-named agreements never cross-contaminate even if the names match.
     */
    @TestVisible
    private static String cloudFolderName(String rawName, Id agreementId) {
        String cleaned = rawName == null ? '' : rawName.replaceAll('["*:<>?/\\\\|]', '-').trim();
        cleaned = cleaned.replaceAll('\\s+', ' ');
        if (cleaned.length() > 120) cleaned = cleaned.substring(0, 120).trim();
        return String.isBlank(cleaned) ? ('Agreement_' + String.valueOf(agreementId)) : cleaned;
    }

    /** First enabled OAuth provider that has a destination folder set, else null. */
    public static String primaryProvider() {
        SignForce_Admin_Config__c cfg = SignForce_Admin_Config__c.getOrgDefaults();
        for (String p : OAUTH_PROVIDERS) {
            if (isEnabled(cfg, p) && String.isNotBlank(targetFor(cfg, p))) return p;
        }
        return null;
    }

    /**
     * OAuth client credentials for a provider. Each provider has its own app
     * registration — posting Google's client id to the Microsoft token endpoint
     * fails with an opaque invalid_client, so never share one set across providers.
     * The GoogleDrive branch resolves creds exactly as it always has.
     */
    public static Map<String, Object> credsFor(String provider) {
        if (provider == ONE_DRIVE) {
            return new Map<String, Object>{
                'clientId'     => SignForceConfigServiceGuest.getMicrosoftClientId(),
                'clientSecret' => SignForceConfigServiceGuest.getMicrosoftClientSecret()
            };
        }
        return new Map<String, Object>{
            'clientId'     => SignForceConfigServiceGuest.getGoogleClientId(),
            'clientSecret' => SignForceConfigServiceGuest.getGoogleClientSecret()
        };
    }

    /** Credentials for the agreement-push callout, keyed off the custom setting. */
    private static Map<String, Object> pushCredsFor(SignForce_Admin_Config__c cfg, String provider) {
        if (provider == ONE_DRIVE) {
            return new Map<String, Object>{
                'clientId'     => cfg.Microsoft_Client_ID__c,
                'clientSecret' => cfg.Microsoft_Client_Secret__c
            };
        }
        return new Map<String, Object>{
            'clientId'     => cfg.Google_Client_ID__c,
            'clientSecret' => cfg.Google_Client_Secret__c
        };
    }

    /** Outcome of a single upload / test / connect, safe to return to the UI. */
    public class Result {
        @AuraEnabled public String provider;
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
        @AuraEnabled public String externalId;   // file id / object key, when known
        @AuraEnabled public String url;          // OAuth "connect" URL, when requested
        public Result(String provider, Boolean success, String message) {
            this.provider = provider;
            this.success  = success;
            this.message  = message;
        }
    }

    /** True if at least one provider is enabled — cheap gate before async work. */
    public static Boolean anyEnabled() {
        SignForce_Admin_Config__c cfg = SignForce_Admin_Config__c.getOrgDefaults();
        if (cfg == null) return false;
        for (String p : PROVIDERS) if (isEnabled(cfg, p)) return true;
        return false;
    }

    public static void pushAgreementDocuments(Id agreementId) {
        try {
            if (agreementId == null || !anyEnabled()) return;
            SignForce_Admin_Config__c cfg = SignForce_Admin_Config__c.getOrgDefaults();
            
            Agreement__c agr = [
                SELECT Name, Cloud_Provider__c, Cloud_Main_Folder_Id__c,
                    Cloud_Original_Folder_Id__c, Cloud_Stamped_Folder_Id__c, Cloud_Cert_Folder_Id__c
                FROM Agreement__c WHERE Id = :agreementId LIMIT 1
            ];

            List<Task> tasksToInsert = new List<Task>();
            Boolean persistFolderIds = false;
            for (String provider : PROVIDERS) {
                if (!isEnabled(cfg, provider)) continue;
                try {
                    String mainFolderId;
                    String originalFolderId;
                    String stampedFolderId;
                    String certFolderId;

                    // Reuse the folder tree the direct-upload flow already created
                    // for this agreement. Without this, EVERY completion makes a
                    // second duplicate tree — the backend always creates a new
                    // folder, it never dedupes by name.
                    if (String.isNotBlank(agr.Cloud_Main_Folder_Id__c)
                        && (String.isBlank(agr.Cloud_Provider__c) || agr.Cloud_Provider__c == provider)) {
                        mainFolderId     = agr.Cloud_Main_Folder_Id__c;
                        originalFolderId = agr.Cloud_Original_Folder_Id__c;
                        stampedFolderId  = agr.Cloud_Stamped_Folder_Id__c;
                        certFolderId     = agr.Cloud_Cert_Folder_Id__c;
                    } else {
                        // Legacy / first time: create the tree once, then persist the
                        // ids below so subsequent runs reuse them.
                        Map<String, Object> setupBody = new Map<String, Object>{
                            'action'         => 'setupAgreementFolders',
                            'provider'       => provider,
                            'parentFolderId' => targetFor(cfg, provider),
                            'agreementName'  => cloudFolderName(agr.Name, agreementId),
                            'orgId'          => UserInfo.getOrganizationId()
                        };
                        setupBody.putAll(pushCredsFor(cfg, provider));
                        HttpResponse res = callBackend(setupBody);

                        if (res.getStatusCode() != 200) {
                            throw new CalloutException('Failed to setup ' + provider + ' folder structure: ' + res.getBody());
                        }

                        Map<String, Object> folderMap = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                        if (folderMap.get('success') != true) {
                            throw new CalloutException(provider + ' setup folders returned failure: ' + folderMap.get('message'));
                        }

                        mainFolderId     = (String) folderMap.get('mainFolderId');
                        originalFolderId = (String) folderMap.get('originalFolderId');
                        stampedFolderId  = (String) folderMap.get('stampedFolderId');
                        certFolderId     = (String) folderMap.get('certFolderId');

                        if (String.isBlank(agr.Cloud_Main_Folder_Id__c)) {
                            agr.Cloud_Provider__c           = provider;
                            agr.Cloud_Main_Folder_Id__c     = mainFolderId;
                            agr.Cloud_Original_Folder_Id__c = originalFolderId;
                            agr.Cloud_Stamped_Folder_Id__c  = stampedFolderId;
                            agr.Cloud_Cert_Folder_Id__c     = certFolderId;
                            persistFolderIds = true;
                        }
                    }
                    
                    // 2. Query all documents linked to the agreement
                    List<Agreement_Document__c> docs = [
                        SELECT Name, Document_Type__c, Content_Version_ID__c
                        FROM Agreement_Document__c
                        WHERE Agreement__c = :agreementId
                    ];
                    
                    String statusDesc = 'Successfully created folder hierarchy.\nMain Folder ID: ' + mainFolderId + '\n\nUploaded files:\n';
                    Boolean allSuccess = true;
                    
                    for (Agreement_Document__c doc : docs) {
                        if (String.isBlank(doc.Content_Version_ID__c)) continue;
                        
                        String targetFolderId = null;
                        if (doc.Document_Type__c == 'Original') {
                            targetFolderId = originalFolderId;
                        } else if (doc.Document_Type__c == 'Stamped') {
                            targetFolderId = stampedFolderId;
                        } else if (doc.Document_Type__c == 'Signed') {
                            targetFolderId = certFolderId;
                        }
                        
                        if (String.isBlank(targetFolderId)) continue;
                        
                        ContentVersion cv = [
                            SELECT Title, PathOnClient, FileType, VersionData, FileExtension
                            FROM ContentVersion
                            WHERE Id = :doc.Content_Version_ID__c
                            LIMIT 1
                        ];
                        
                        String fileName = cv.PathOnClient;
                        if (String.isBlank(fileName)) {
                            fileName = cv.Title + '.' + (cv.FileExtension != null ? cv.FileExtension : 'pdf');
                        }
                        
                        String cType = cv.FileType == 'PDF' ? 'application/pdf' : 'application/octet-stream';
                        
                        Result r = pushDocument(provider, fileName, cv.VersionData, cType, targetFolderId);
                        statusDesc += '- ' + doc.Document_Type__c + ' (' + fileName + '): ' + (r.success ? 'Succeeded (File ID: ' + r.externalId + ')' : 'Failed (' + r.message + ')') + '\n';
                        if (!r.success) {
                            allSuccess = false;
                        }
                    }
                    
                    tasksToInsert.add(new Task(
                        WhatId = agreementId,
                        Subject = 'Cloud Upload: ' + provider + (allSuccess ? ' Succeeded' : ' Partially Failed'),
                        Description = statusDesc,
                        Status = 'Completed',
                        Priority = 'Normal',
                        ActivityDate = Date.today()
                    ));
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN, 'integration push failed (' + provider + '): ' + e.getMessage());
                    tasksToInsert.add(new Task(
                        WhatId = agreementId,
                        Subject = 'Cloud Upload: ' + provider + ' Failed',
                        Description = 'Exception: ' + e.getMessage() + '\nStack: ' + e.getStackTraceString(),
                        Status = 'Completed',
                        Priority = 'Normal',
                        ActivityDate = Date.today()
                    ));
                }
            }
            // CRUD: Task carries WhatId -> Agreement__c, so the parent's read
            // access is checked next to the child's create access, which is what
            // the scanner's WhatId/WhoId rule asks for.
            // Skip rather than throw: this runs @future off guest signing, where
            // Task create is not granted. Today that insert throws and the outer
            // catch swallows it - which also skips the folder-id persist below.
            // Skipping leaves the audit Task absent exactly as it is now and lets
            // the rest of the method finish.
            if (!tasksToInsert.isEmpty()
                && Schema.sObjectType.Task.isCreateable()
                && Schema.sObjectType.Agreement__c.isAccessible()) {
                insert tasksToInsert;
            }
            // Persist any newly created folder tree so the next completion reuses
            // it instead of creating a duplicate. DML after the callouts above is
            // fine; callout-after-DML is what Salesforce forbids.
            if (persistFolderIds) {
                try {
                    // CRUD: skip when this context cannot write Agreement__c. The
                    // persist is a best-effort cache of the folder tree and already
                    // tolerates failure - the catch below swallows it - so skipping
                    // matches today's outcome on the guest/@future path, where
                    // Agreement__c edit is not granted.
                    if (Schema.sObjectType.Agreement__c.isUpdateable()) {
                        update agr;
                    }
                } catch (Exception ue) {
                    System.debug(LoggingLevel.WARN, 'pushAgreementDocuments: folder id persist failed: ' + ue.getMessage());
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'pushAgreementDocuments error: ' + e.getMessage());
        }
    }

    /** Upload one document (bytes) to a single provider via the backend. Never throws. */
    public static Result pushDocument(String provider, String fileName, Blob content,
                                      String contentType, String target) {
        if (!PROVIDERS.contains(provider)) return new Result(provider, false, 'Unknown provider: ' + provider);
        if (String.isBlank(contentType)) contentType = 'application/pdf';
        try {
            Map<String, Object> body = new Map<String, Object>{
                'action'        => 'pushToCloud',
                'provider'      => provider,
                'folderId'      => target,
                'fileName'      => fileName,
                'contentType'   => contentType,
                'contentBase64' => EncodingUtil.base64Encode(content),
                'orgId'         => UserInfo.getOrganizationId()
            };
            body.putAll(credsFor(provider));
            return interpret(provider, callBackend(body));
        } catch (Exception e) {
            return new Result(provider, false, mapError(e));
        }
    }

    public static HttpResponse callBackend(Map<String, Object> payload) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(SignForceConfigServiceGuest.getLambdaEndpoint()); // throws if unconfigured
        SignForceConfigServiceGuest.applyLambdaAuth(req);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);
        req.setBody(JSON.serialize(payload));
        return new Http().send(req);
    }

    private static Result interpret(String provider, HttpResponse res) {
        Integer sc = res.getStatusCode();
        Map<String, Object> body;
        try {
            Object parsed = JSON.deserializeUntyped(res.getBody());
            if (parsed instanceof Map<String, Object>) body = (Map<String, Object>) parsed;
        } catch (Exception ignore) { /* non-JSON body */ }

        if (sc >= 200 && sc < 300) {
            Boolean ok = body == null ? true : (body.get('success') == true);
            String msg = body != null && body.get('message') != null
                ? String.valueOf(body.get('message'))
                : (ok ? 'OK' : 'Backend reported failure');
            Result r = new Result(provider, ok, msg);
            if (body != null && body.get('externalId') != null) r.externalId = String.valueOf(body.get('externalId'));
            if (body != null && body.get('url') != null)        r.url = String.valueOf(body.get('url'));
            return r;
        }
        String emsg = body != null && body.get('message') != null ? String.valueOf(body.get('message')) : ('Backend HTTP ' + sc);
        return new Result(provider, false, emsg);
    }

    private static String mapError(Exception e) {
        if (e instanceof SignForceConfigService.ConfigurationException) {
            return 'SignForce backend (Lambda) endpoint is not configured yet. Set it in SignForce_Config__mdt, then try again.';
        }
        return e.getMessage();
    }

    @TestVisible
    private static Boolean isEnabled(SignForce_Admin_Config__c cfg, String provider) {
        if (cfg == null) return false;
        if (provider == GOOGLE_DRIVE) return cfg.Integration_GoogleDrive_Enabled__c == true;
        if (provider == ONE_DRIVE)    return cfg.Integration_OneDrive_Enabled__c == true;
        if (provider == BOX)          return cfg.Integration_Box_Enabled__c == true;
        if (provider == SHAREPOINT)   return cfg.Integration_SharePoint_Enabled__c == true;
        if (provider == AWS_S3)       return cfg.Integration_AwsS3_Enabled__c == true;
        return false;
    }

    @TestVisible
    private static String targetFor(SignForce_Admin_Config__c cfg, String provider) {
        if (cfg == null) return null;
        if (provider == GOOGLE_DRIVE) return cfg.Integration_GoogleDrive_Target__c;
        if (provider == ONE_DRIVE)    return cfg.Integration_OneDrive_Target__c;
        if (provider == BOX)          return cfg.Integration_Box_Target__c;
        if (provider == SHAREPOINT)   return cfg.Integration_SharePoint_Target__c;
        if (provider == AWS_S3)       return cfg.Integration_AwsS3_Target__c;
        return null;
    }
}
