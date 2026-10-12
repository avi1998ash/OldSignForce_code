/**
 * IntegrationService — pushes SignForce documents to external cloud storage
 * (Google Drive, OneDrive, Box, SharePoint, AWS S3) THROUGH the SignForce backend (Lambda).
 *
 * DESIGN — backend-brokered (multi-org friendly, no per-org OAuth config):
 *  - Salesforce holds NO OAuth app/secret/Named Credential. It POSTs to the
 *    SignForce backend (the same AWS Lambda used for stamping; endpoint =
 *    SignForce_Config__mdt.Lambda_Endpoint__c). The backend owns ONE OAuth app
 *    per provider and brokers the login + stores each org's token.
 *  - So every subscriber org just clicks Connect -> logs in; nothing to configure
 *    in Salesforce or Google per org.
 *
 *  Backend JSON contract (POST, returns JSON):
 *    getConnectUrl        {provider, orgId}                          -> {success, url}
 *    testCloud            {provider, orgId}                          -> {success, message}
 *    pushToCloud          {provider, folderId, fileName,
 *                          contentType, contentBase64, orgId}        -> {success, externalId, message}
 *    pushAgreementToCloud {provider, folderId, agreementId, orgId}   -> {success, externalId, message}
 *
 *  Every method is best-effort and never throws.
 */
// GUEST SPLIT: the guest signing completion flow uses IntegrationServiceGuest (a verbatim copy of
// pushAgreementDocuments and its helpers). This class keeps every method, including the originals,
// for the internal admin / queueable callers.
public with sharing class IntegrationService {

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

    /** Destination folder id configured for `provider`, or null. */
    public static String targetForProvider(String provider) {
        return targetFor(SignForce_Admin_Config__c.getOrgDefaults(), provider);
    }

    /**
     * Ensure the cloud folder hierarchy exists for an agreement and return the
     * folder ids {provider, mainFolderId, originalFolderId, stampedFolderId,
     * certFolderId}. Idempotent: the backend setupAgreementFolders is NOT
     * idempotent (it always creates), so we persist the ids on the Agreement and
     * reuse them on later calls — otherwise every re-upload / stamp spawns a
     * duplicate folder tree. Does one callout only on the first call.
     */
    public static Map<String, Object> setupFoldersForAgreement(Id agreementId) {
        String provider = primaryProvider();
        if (provider == null) {
            throw new CalloutException('No cloud provider is connected.');
        }
        Agreement__c agr = [
            SELECT Name, Cloud_Provider__c, Cloud_Main_Folder_Id__c, Cloud_Original_Folder_Id__c,
                   Cloud_Stamped_Folder_Id__c, Cloud_Cert_Folder_Id__c
            FROM Agreement__c WHERE Id = :agreementId LIMIT 1
        ];
        if (String.isNotBlank(agr.Cloud_Main_Folder_Id__c)) {
            return new Map<String, Object>{
                'provider'         => provider,
                'mainFolderId'     => agr.Cloud_Main_Folder_Id__c,
                'originalFolderId' => agr.Cloud_Original_Folder_Id__c,
                'stampedFolderId'  => agr.Cloud_Stamped_Folder_Id__c,
                'certFolderId'     => agr.Cloud_Cert_Folder_Id__c
            };
        }

        SignForce_Admin_Config__c cfg = SignForce_Admin_Config__c.getOrgDefaults();
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
            throw new CalloutException('Failed to set up ' + provider + ' folders: ' + res.getBody());
        }
        Map<String, Object> folderMap = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        if (folderMap.get('success') != true) {
            throw new CalloutException(provider + ' folder setup failed: ' + folderMap.get('message'));
        }

        agr.Cloud_Provider__c           = provider;
        agr.Cloud_Main_Folder_Id__c     = (String) folderMap.get('mainFolderId');
        agr.Cloud_Original_Folder_Id__c = (String) folderMap.get('originalFolderId');
        agr.Cloud_Stamped_Folder_Id__c  = (String) folderMap.get('stampedFolderId');
        agr.Cloud_Cert_Folder_Id__c     = (String) folderMap.get('certFolderId');
        Database.update(agr, true);

        return new Map<String, Object>{
            'provider'         => provider,
            'mainFolderId'     => agr.Cloud_Main_Folder_Id__c,
            'originalFolderId' => agr.Cloud_Original_Folder_Id__c,
            'stampedFolderId'  => agr.Cloud_Stamped_Folder_Id__c,
            'certFolderId'     => agr.Cloud_Cert_Folder_Id__c
        };
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
                'clientId'     => SignForceConfigService.getMicrosoftClientId(),
                'clientSecret' => SignForceConfigService.getMicrosoftClientSecret()
            };
        }
        return new Map<String, Object>{
            'clientId'     => SignForceConfigService.getGoogleClientId(),
            'clientSecret' => SignForceConfigService.getGoogleClientSecret()
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

    // ── Public API ───────────────────────────────────────────────────────

    /** True if at least one provider is enabled — cheap gate before async work. */
    public static Boolean anyEnabled() {
        SignForce_Admin_Config__c cfg = SignForce_Admin_Config__c.getOrgDefaults();
        if (cfg == null) return false;
        for (String p : PROVIDERS) if (isEnabled(cfg, p)) return true;
        return false;
    }

    /** Providers currently enabled in the admin config, in PROVIDERS order. */
    public static List<String> enabledProviders() {
        List<String> out = new List<String>();
        SignForce_Admin_Config__c cfg = SignForce_Admin_Config__c.getOrgDefaults();
        if (cfg == null) return out;
        for (String p : PROVIDERS) if (isEnabled(cfg, p)) out.add(p);
        return out;
    }

    // ── Named subfolders under the configured destination ────────────────────
    // The backend's create-folder actions ALWAYS create (no find-by-name), so
    // created ids are cached in Integration_Config_JSON__c. The cache is only
    // written by flushSubfolderCache(), which callers invoke AFTER their last
    // callout — a mid-sequence DML here would block every callout after it.

    private static Map<String, Object> subfolderCache;
    private static Boolean subfolderCacheDirty = false;

    private static Map<String, Object> loadSubfolderCache() {
        if (subfolderCache == null) {
            subfolderCache = new Map<String, Object>();
            try {
                SignForce_Admin_Config__c cfg = SignForce_Admin_Config__c.getOrgDefaults();
                if (cfg != null && String.isNotBlank(cfg.Integration_Config_JSON__c)) {
                    subfolderCache = (Map<String, Object>) JSON.deserializeUntyped(cfg.Integration_Config_JSON__c);
                }
            } catch (Exception e) { /* corrupt JSON — start fresh */ }
        }
        return subfolderCache;
    }

    /**
     * Folder id of `<destination>/<name>` for the provider, creating the folder
     * on first use. Falls back to the destination root when the provider has no
     * folder actions (Box/SharePoint/S3) or creation fails — a push must never
     * die for want of a folder.
     */
    public static String ensureSubfolder(String provider, String name) {
        SignForce_Admin_Config__c cfg = SignForce_Admin_Config__c.getOrgDefaults();
        String parent = targetFor(cfg, provider);
        if (String.isBlank(name) || (provider != GOOGLE_DRIVE && provider != ONE_DRIVE)) return parent;
        String key = 'subfolder:' + provider + ':' + name;
        Map<String, Object> cache = loadSubfolderCache();
        String cached = (String) cache.get(key);
        if (String.isNotBlank(cached)) return cached;
        try {
            Map<String, Object> body = new Map<String, Object>{
                'action'     => (provider == GOOGLE_DRIVE ? 'createGoogleFolder' : 'createOneDriveFolder'),
                'folderName' => name,
                'parentId'   => parent,
                'orgId'      => UserInfo.getOrganizationId()
            };
            body.putAll(credsFor(provider));
            HttpResponse res = callBackend(body);
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            String folderId = (parsed.get('success') == true) ? (String) parsed.get('folderId') : null;
            if (String.isNotBlank(folderId)) {
                cache.put(key, folderId);
                subfolderCacheDirty = true;
                return folderId;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'ensureSubfolder failed for ' + provider + '/' + name + ': ' + e.getMessage());
        }
        return parent;
    }

    /** Persist folder ids created this transaction. Call AFTER the last callout. */
    public static void flushSubfolderCache() {
        if (!subfolderCacheDirty || subfolderCache == null) return;
        try {
            SignForce_Admin_Config__c cfg = SignForce_Admin_Config__c.getOrgDefaults();
            if (cfg == null) return;
            cfg.Integration_Config_JSON__c = JSON.serialize(subfolderCache);
            upsert cfg;
            subfolderCacheDirty = false;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'flushSubfolderCache failed (folder will be re-created on the next push): ' + e.getMessage());
        }
    }

    /** Upload one document (bytes) to every ENABLED provider. Never throws. */
    public static List<Result> pushToEnabled(String fileName, Blob content, String contentType) {
        List<Result> out = new List<Result>();
        SignForce_Admin_Config__c cfg = SignForce_Admin_Config__c.getOrgDefaults();
        if (cfg == null || content == null) return out;
        for (String provider : PROVIDERS) {
            if (!isEnabled(cfg, provider)) continue;
            out.add(pushDocument(provider, fileName, content, contentType, targetFor(cfg, provider)));
        }
        return out;
    }

    /**
     * Push a completed agreement's final documents to every enabled provider BY
     * REFERENCE — the backend fetches the signed PDF from storage and uploads it,
     * so no (possibly large) bytes pass through Salesforce. Best-effort: returns
     * void, never throws, no-op when nothing is enabled.
     */

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

    @future(callout=true)
    public static void pushAgreementDocumentsAsync(Id agreementId) {
        pushAgreementDocuments(agreementId);
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

    /** Asks the backend whether a provider is connected. Never throws. */
    @AuraEnabled
    public static Result testConnection(String provider) {
        if (!PROVIDERS.contains(provider)) return new Result(provider, false, 'Unknown provider: ' + provider);
        try {
            Map<String, Object> body = new Map<String, Object>{
                'action' => 'testCloud',
                'provider' => provider,
                'orgId' => UserInfo.getOrganizationId()
            };
            body.putAll(credsFor(provider));
            return interpret(provider, callBackend(body));
        } catch (Exception e) {
            return new Result(provider, false, mapError(e));
        }
    }

    /**
     * Returns the provider's OAuth login URL (built by the backend). The UI opens
     * it; the user logs in on the provider's own page and the backend stores the
     * token, keyed by org. Never throws.
     */
    @AuraEnabled
    public static Result getConnectUrl(String provider) {
        if (!PROVIDERS.contains(provider)) return new Result(provider, false, 'Unknown provider: ' + provider);
        if (provider == AWS_S3) return new Result(provider, false, 'AWS S3 uses a backend key — no login needed.');
        try {
            Map<String, Object> body = new Map<String, Object>{
                'action' => 'getConnectUrl',
                'provider' => provider,
                'orgId' => UserInfo.getOrganizationId()
            };
            body.putAll(credsFor(provider));
            return interpret(provider, callBackend(body));
        } catch (Exception e) {
            return new Result(provider, false, mapError(e));
        }
    }

    // ── Backend call ────────────────────────────────────────────────────────

    public static HttpResponse callBackend(Map<String, Object> payload) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(SignForceConfigService.getLambdaEndpoint()); // throws if unconfigured
        SignForceConfigService.applyLambdaAuth(req);
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

    // ── Config helpers ──────────────────────────────────────────────────────

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