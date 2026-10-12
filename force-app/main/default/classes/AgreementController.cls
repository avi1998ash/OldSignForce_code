/**
 * AgreementController — @AuraEnabled entry points for agreement lifecycle
 * operations from internal Lightning users.
 */
public with sharing class AgreementController {

    // ═════════════════════════════════════════════════════════════════════
    //  S3 / TIERED STORAGE
    // ═════════════════════════════════════════════════════════════════════

    @AuraEnabled
    public static String getS3PreviewUrl(String agreementId) {
        List<Agreement_Document__c> docs = [
            SELECT Id, S3_Document_ID__c, S3_Preview_URL__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId
            AND Document_Type__c = 'Original'
            AND S3_Document_ID__c != null
            WITH USER_MODE
            LIMIT 1
        ];

        if (docs.isEmpty()) return null;

        String orgId = UserInfo.getOrganizationId();
        String docId = docs[0].S3_Document_ID__c;

        Http http = new Http();
        HttpRequest req = new HttpRequest();
        req.setEndpoint(SignForceConfigService.getLambdaEndpoint());
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(30000);
        req.setBody(JSON.serialize(new Map<String, Object>{
            'action' => 'getUrl',
            'orgId' => orgId,
            'docId' => docId
        }));

        HttpResponse res = http.send(req);
        if (res.getStatusCode() == 200) {
            Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            String url = (String) result.get('url');

            SignForceFLS.requireUpdateable(Agreement_Document__c.SObjectType);
            docs[0].S3_Preview_URL__c = url;
            Database.update(docs[0], true, AccessLevel.USER_MODE);
            return url;
        }

        return docs[0].S3_Preview_URL__c;
    }

    @AuraEnabled(cacheable=true)
    public static String getOrgId() {
        return UserInfo.getOrganizationId();
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getStorageTierForUpload() {
        return SignForceConfigService.getClientConfig();
    }

    @AuraEnabled
    public static Id uploadTier1Document(
        Id agreementId,
        String fileName,
        String pdfBase64,
        Decimal fileSize
    ) {
        if (agreementId == null) {
            throw new AuraHandledException('agreementId is required');
        }
        if (String.isBlank(pdfBase64)) {
            throw new AuraHandledException('pdfBase64 is required');
        }

        SignForceFLS.requireCreateable(ContentVersion.SObjectType);
        ContentVersion cv = new ContentVersion();
        cv.Title = String.isBlank(fileName) ? 'Document.pdf' : fileName;
        cv.PathOnClient = cv.Title;
        cv.VersionData = EncodingUtil.base64Decode(pdfBase64);
        cv.FirstPublishLocationId = agreementId;
        Database.insert(cv, true, AccessLevel.USER_MODE);

        ContentVersion inserted = [
            SELECT Id, ContentDocumentId, Title
            FROM ContentVersion WHERE Id = :cv.Id
            WITH USER_MODE
        ];

        // BUG-039 FIX: previously a fresh 'Original' Agreement_Document__c was
        // inserted on every upload, leaving stale Original rows behind and
        // causing duplicates (and the wrong file being stamped/emailed later).
        // Mirror the reuse logic in createAgreementDocumentS3: remove any prior
        // 'Original' for this agreement before inserting the new one. Scope the
        // cleanup to Draft agreements only — matching the upload gating, so we
        // never delete the Original of an already-sent/completed agreement.
        Boolean isDraft = [
            SELECT Status__c FROM Agreement__c WHERE Id = :agreementId
            WITH USER_MODE
            LIMIT 1
        ].Status__c == 'Draft';
        if (isDraft) {
            List<Agreement_Document__c> priorOriginals = [
                SELECT Id FROM Agreement_Document__c
                WHERE Agreement__c = :agreementId
                AND Document_Type__c = 'Original'
                WITH USER_MODE
            ];
            if (!priorOriginals.isEmpty()) {
                SignForceFLS.requireDeletable(Agreement_Document__c.SObjectType);
                Database.delete(priorOriginals, true, AccessLevel.USER_MODE);
            }
        }

        SignForceFLS.requireCreateable(Agreement_Document__c.SObjectType);
        Agreement_Document__c doc = new Agreement_Document__c();
        doc.Agreement__c = agreementId;
        doc.Name = inserted.Title;
        doc.Content_Version_ID__c = inserted.Id;
        doc.Document_Type__c = 'Original';
        doc.Storage_Tier__c = 'Tier1';
        doc.File_Size_Bytes__c = fileSize;
        Database.insert(doc, true, AccessLevel.USER_MODE);

        return doc.Id;
    }

    @AuraEnabled
    public static Id createAgreementDocumentS3(
        Id agreementId,
        String s3DocId,
        String s3Url,
        String fileName,
        Decimal fileSize,
        String tier
    ) {
        if (agreementId == null) {
            throw new AuraHandledException('agreementId is required');
        }
        if (String.isBlank(s3DocId)) {
            throw new AuraHandledException('s3DocId is required for S3-tier documents');
        }

        List<Agreement_Document__c> existing = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId
            AND Document_Type__c = 'Original'
            WITH USER_MODE
            LIMIT 1
        ];

        Agreement_Document__c doc;
        if (!existing.isEmpty()) {
            doc = existing[0];
            SignForceFLS.requireUpdateable(Agreement_Document__c.SObjectType);
        } else {
            doc = new Agreement_Document__c();
            doc.Agreement__c = agreementId;
            doc.Document_Type__c = 'Original';
            SignForceFLS.requireCreateable(Agreement_Document__c.SObjectType);
        }
        doc.Name = String.isBlank(fileName) ? 'Document.pdf' : fileName;
        doc.S3_Document_ID__c = s3DocId;
        doc.S3_Preview_URL__c = s3Url;
        doc.Storage_Tier__c = String.isBlank(tier) ? 'Tier2' : tier;
        doc.File_Size_Bytes__c = fileSize;
        Database.upsert(doc, true, AccessLevel.USER_MODE);
        return doc.Id;
    }

    /**
     * Ensure the connected cloud provider's folder hierarchy exists for this
     * agreement and return {provider, originalFolderId} so the browser can push a
     * >4MB original straight into the Original folder. Throws a user-facing error
     * when no provider is connected (the >4MB-no-cloud case).
     */
    @AuraEnabled
    public static Map<String, Object> prepareCloudUpload(Id agreementId) {
        if (agreementId == null) throw new AuraHandledException('agreementId is required');
        String provider = IntegrationService.primaryProvider();
        if (provider == null) {
            throw new AuraHandledException('Connect a cloud provider to upload files over 4 MB.');
        }
        try {
            Map<String, Object> folders = IntegrationService.setupFoldersForAgreement(agreementId);
            return new Map<String, Object>{
                'provider'         => provider,
                'originalFolderId' => folders.get('originalFolderId')
            };
        } catch (Exception e) {
            throw new AuraHandledException('Could not prepare cloud upload: ' + e.getMessage());
        }
    }

    /**
     * Server-side proxy for one cloud-upload chunk (browser -> Apex -> Lambda),
     * so the browser never hits the Lambda directly and CORS is a non-issue.
     * Returns the cloud file id on the LAST chunk, null otherwise.
     */
    @AuraEnabled
    public static String pushCloudChunk(String sessionId, Integer chunkIndex, Integer totalChunks,
                                        String chunkBase64, String provider, String folderId, String fileName) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(SignForceConfigService.getLambdaEndpoint());
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);
        req.setBody(JSON.serialize(new Map<String, Object>{
            'action'      => 'pushCloudChunk',
            'orgId'       => UserInfo.getOrganizationId(),
            'sessionId'   => sessionId,
            'chunkIndex'  => chunkIndex,
            'totalChunks' => totalChunks,
            'chunkBase64' => chunkBase64,
            'provider'    => provider,
            'folderId'    => folderId,
            'fileName'    => fileName,
            'contentType' => 'application/pdf'
        }));
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new AuraHandledException('Cloud upload failed: HTTP ' + res.getStatusCode() + ' ' + res.getBody());
        }
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        if (body.get('success') != true) {
            throw new AuraHandledException('Cloud upload failed: ' + body.get('message'));
        }
        return (String) body.get('externalId');
    }

    /**
     * Fetch a cloud-stored Original's PDF bytes (base64) via the Lambda proxy so
     * the editor / viewer can render it. Bearer token stays server-side.
     */
    @AuraEnabled
    public static Map<String, Object> getCloudDocChunk(Id agreementId, Integer rangeStart, Integer rangeLen, Id documentId) {
        // documentId targets a SPECIFIC cloud doc (e.g. the Stamped copy for the
        // record-page preview); omitted -> latest cloud Original (editor/viewer).
        List<Agreement_Document__c> docs = documentId != null
            ? [
                SELECT Cloud_File_Id__c, Cloud_Provider__c
                FROM Agreement_Document__c
                WHERE Id = :documentId
                AND Storage_Type__c = 'Cloud' AND Cloud_File_Id__c != null
                WITH USER_MODE
                LIMIT 1
            ]
            : [
                SELECT Cloud_File_Id__c, Cloud_Provider__c
                FROM Agreement_Document__c
                WHERE Agreement__c = :agreementId AND Document_Type__c = 'Original'
                AND Storage_Type__c = 'Cloud' AND Cloud_File_Id__c != null
                WITH USER_MODE
                ORDER BY CreatedDate DESC LIMIT 1
            ];
        if (docs.isEmpty()) return null;
        HttpRequest req = new HttpRequest();
        req.setEndpoint(SignForceConfigService.getLambdaEndpoint());
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);
        req.setBody(JSON.serialize(new Map<String, Object>{
            'action'     => 'downloadFromCloud',
            'orgId'      => UserInfo.getOrganizationId(),
            'provider'   => docs[0].Cloud_Provider__c,
            'fileId'     => docs[0].Cloud_File_Id__c,
            'rangeStart' => rangeStart,
            'rangeLen'   => rangeLen
        }));
        HttpResponse res = new Http().send(req);
        String raw = res.getBody();
        if (res.getStatusCode() != 200) {
            throw new AuraHandledException('Cloud fetch failed (HTTP ' + res.getStatusCode() + '): '
                + (raw != null ? raw.substring(0, Math.min(400, raw.length())) : ''));
        }
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(raw);
        if (body.get('success') != true) {
            throw new AuraHandledException('Cloud fetch failed: ' + body.get('message'));
        }
        return new Map<String, Object>{
            'base64' => body.get('pdfBase64'),
            'size'   => body.get('size')
        };
    }

    /**
     * Record a >4MB Original that now lives in the cloud provider. Mirrors
     * createAgreementDocumentS3's reuse pattern but stores the cloud handle
     * (Storage_Type__c='Cloud', Cloud_File_Id__c) with NO ContentVersion and NO
     * S3 id — the null CV is what keeps IntegrationService from re-uploading it.
     */
    @AuraEnabled
    public static Id createAgreementDocumentCloud(
        Id agreementId, String cloudFileId, String provider,
        String folderId, String fileName, Decimal fileSize
    ) {
        if (agreementId == null) throw new AuraHandledException('agreementId is required');
        if (String.isBlank(cloudFileId)) throw new AuraHandledException('cloudFileId is required');

        List<Agreement_Document__c> existing = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId
            AND Document_Type__c = 'Original'
            WITH USER_MODE
            LIMIT 1
        ];

        Agreement_Document__c doc;
        if (!existing.isEmpty()) {
            doc = existing[0];
            SignForceFLS.requireUpdateable(Agreement_Document__c.SObjectType);
        } else {
            doc = new Agreement_Document__c();
            doc.Agreement__c = agreementId;
            doc.Document_Type__c = 'Original';
            SignForceFLS.requireCreateable(Agreement_Document__c.SObjectType);
        }
        doc.Name              = String.isBlank(fileName) ? 'Document.pdf' : fileName;
        doc.Storage_Type__c   = 'Cloud';
        doc.Cloud_File_Id__c  = cloudFileId;
        doc.Cloud_Provider__c = provider;
        doc.Cloud_Folder_Id__c = folderId;
        doc.File_Size_Bytes__c = fileSize;
        // Clear any stale Salesforce/S3 handles so the discriminator is unambiguous.
        doc.Content_Version_ID__c = null;
        doc.S3_Document_ID__c = null;
        doc.S3_Preview_URL__c = null;
        doc.Storage_Tier__c = null;
        Database.upsert(doc, true, AccessLevel.USER_MODE);
        return doc.Id;
    }

    @AuraEnabled
    public static Map<String, Object> initChunkedUpload(Id agreementId, String fileName) {
        if (agreementId == null) {
            throw new AuraHandledException('agreementId is required');
        }
        String orgId = UserInfo.getOrganizationId();
        String docId = String.valueOf(agreementId) + '_' + String.valueOf(Datetime.now().getTime());

        return new Map<String, Object>{
            'orgId' => orgId,
            'docId' => docId,
            'lambdaEndpoint' => SignForceConfigService.getLambdaEndpoint(),
            'tier' => 'Tier3'
        };
    }

    // ═════════════════════════════════════════════════════════════════════
    //  STAMPING (server-side, S3-backed)
    // ═════════════════════════════════════════════════════════════════════

    @AuraEnabled
    public static void generateStampedPDFServerInternal(Id agreementId) {
        // NOTE: Stamping is a trusted backend assembly operation. It runs as the
        // user whose action completed the agreement (AgreementTrigger →
        // generateStampedPDFServerAsync), and that profile may lack FLS on some of
        // the queried fields. The queries and DML below therefore run in system
        // mode — same approach already used for the stamped ContentVersion insert
        // (AccessLevel.SYSTEM_MODE). Agreements completed by a guest signer are
        // stamped by AgreementControllerGuest.generateStampedPDFServerGuest instead.
        // No data is exposed to the user beyond the stamped PDF itself.
        try {
            System.debug('SignForce Stamp: Starting for agreement=' + agreementId);

            // Completion used to set TWO async stamps running: the guest signing flow
            // (AgreementControllerGuest) queues one (it also sends the completion
            // email) and AgreementTrigger
            // queues another (it is the only stamp the in-org signing path gets).
            // Both then produce a file and a Stamped row, which is why a completed
            // agreement showed two identical "Final Signed Document" entries.
            //
            // Neither path can simply be dropped — one owns the email, the other
            // owns in-org signing — so whichever arrives second stops here. The
            // check is deliberately narrow: it only skips when the agreement is
            // ALREADY Completed and a Stamped row exists that was created at or
            // after that moment, i.e. a stamp that already carries every signature.
            // Mid-flow stamps (agreement still in progress) are untouched, so no
            // signature can be lost by skipping.
            List<Agreement__c> agrCheck = [
                SELECT Status__c, Completed_Date__c FROM Agreement__c
                WHERE Id = :agreementId LIMIT 1
            ];
            if (!agrCheck.isEmpty()
                && agrCheck[0].Status__c == 'Completed'
                && agrCheck[0].Completed_Date__c != null) {
                Integer finalStamps = [
                    SELECT COUNT() FROM Agreement_Document__c
                    WHERE Agreement__c = :agreementId
                    AND Document_Type__c = 'Stamped'
                    AND CreatedDate >= :agrCheck[0].Completed_Date__c
                ];
                if (finalStamps > 0) {
                    System.debug('SignForce Stamp: final stamp already present, skipping duplicate');
                    return;
                }
            }

            List<Agreement_Document__c> origDocs = [
                SELECT Id, Content_Version_ID__c, S3_Document_ID__c, Storage_Tier__c,
                    Storage_Type__c, Cloud_File_Id__c, Cloud_Provider__c
                FROM Agreement_Document__c
                WHERE Agreement__c = :agreementId
                AND Document_Type__c = 'Original'
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            if (origDocs.isEmpty()) {
                System.debug(LoggingLevel.ERROR, 'SignForce Stamp: No original document found for ' + agreementId);
                throw new SignForceStampException('No original document found for agreement ' + agreementId);
            }
            Agreement_Document__c origDoc = origDocs[0];
            System.debug('SignForce Stamp: Original tier=' + origDoc.Storage_Tier__c 
                + ', S3=' + origDoc.S3_Document_ID__c 
                + ', CV=' + origDoc.Content_Version_ID__c);

            Agreement__c agr = [
                SELECT Name, Envelope_ID__c
                FROM Agreement__c WHERE Id = :agreementId
            ];

            List<Signature_Field__c> fields = [
                SELECT Field_Type__c, Field_Value__c, Page_Number__c,
                    X_Position__c, Y_Position__c, Width__c, Height__c,
                    Page_Width__c, Is_Completed__c,
                    Assigned_Signer__r.Name, Assigned_Signer__r.Email__c,
                    Assigned_Signer__r.Signing_IP_Address__c, Assigned_Signer__r.Signed_Date__c,
                    Assigned_Signer__r.Signature_Certificate_ID__c
                FROM Signature_Field__c
                WHERE Agreement__c = :agreementId
                AND Is_Completed__c = true
            ];

            if (fields.isEmpty()) {
                System.debug(LoggingLevel.ERROR, 'SignForce Stamp: No completed fields. Skipping.');
                throw new SignForceStampException('No completed signature fields found');
            }
            System.debug('SignForce Stamp: ' + fields.size() + ' completed fields found');

            List<Map<String, Object>> fieldList = buildStampFieldList(fields);
            if (fieldList.isEmpty()) {
                System.debug(LoggingLevel.ERROR, 'SignForce Stamp: Field list empty after build');
                return;
            }
            System.debug('SignForce Stamp: Built ' + fieldList.size() + ' fields for Lambda');

            Map<String, Object> meta = new Map<String, Object>();
            meta.put('envelopeId', agr.Envelope_ID__c != null ? (Object)agr.Envelope_ID__c : (Object)String.valueOf(agreementId));
            meta.put('agreementName', agr.Name);
            meta.put('referencePageWidth', 762);

            // New uploads always live in Salesforce Files (Tier1, no S3), so the
            // stamped result is produced by the Lambda's base64 stamp path and
            // stored back in Salesforce — S3 is never touched. stampViaS3 remains
            // only for any legacy document that still has an S3 copy.
            Boolean isCloud = origDoc.Storage_Type__c == 'Cloud'
                && String.isNotBlank(origDoc.Cloud_File_Id__c);
            Boolean isS3 = String.isNotBlank(origDoc.S3_Document_ID__c);
            System.debug('SignForce Stamp: Routing to '
                + (isCloud ? 'stampViaCloud' : (isS3 ? 'stampViaS3' : 'stampOriginalToSalesforce')));
            if (isCloud) {
                stampViaCloud(agreementId, agr, origDoc, fieldList, meta);
            } else if (isS3) {
                stampViaS3(agreementId, agr, origDoc, fieldList, meta);
            } else {
                stampOriginalToSalesforce(agreementId, agr, origDoc, fieldList, meta);
            }
            
            System.debug('SignForce Stamp:Completed successfully for agreement ' + agreementId);

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'SignForce Stamp:  FAILED — ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'SignForce Stamp: Stack — ' + e.getStackTraceString());
            throw new SignForceStampException('Stamping failed: ' + e.getMessage());
        }
    }

    /**
     * Tier1 stamping path: bytes live in ContentVersion. Upload to S3
     * first, then call Lambda stampS3. Stamped result lives in S3.
     *
     * CRITICAL: Also fetches stamped PDF bytes and saves them to a new
     * ContentVersion in the SAME transaction (before DML), so the email
     * step later can read them via CV path without HTTP callouts.
     * This avoids "Uncommitted work pending" errors in the email step.
     */
   private static void stampOriginalToS3(
        Id agreementId,
        Agreement__c agr,
        Agreement_Document__c origDoc,
        List<Map<String, Object>> fieldList,
        Map<String, Object> meta
    ) {
        if (String.isBlank(origDoc.Content_Version_ID__c)) {
            throw new SignForceStampException('stampOriginalToS3: Original CV is blank');
        }

        String orgId = UserInfo.getOrganizationId();
        String stagingDocId = 'stamping_' + String.valueOf(agreementId)
            + '_' + Datetime.now().getTime();

        System.debug('stampOriginalToS3: Start, stagingDocId=' + stagingDocId);

        // Step 1: Upload original bytes to S3
        {
            ContentVersion cv = [
                SELECT VersionData FROM ContentVersion
                WHERE Id = :origDoc.Content_Version_ID__c
                LIMIT 1
            ];

            Integer rawSize = cv.VersionData.size();
            System.debug('stampOriginalToS3: CV raw size = ' + rawSize + ' bytes');

            String pdfBase64 = EncodingUtil.base64Encode(cv.VersionData);
            cv = null;

            Integer base64Size = pdfBase64.length();
            System.debug('stampOriginalToS3: Base64 size = ' + base64Size + ' chars');

            String body = '{"action":"upload","orgId":"' + orgId
                + '","docId":"' + stagingDocId
                + '","pdfBase64":"' + pdfBase64 + '"}';
            pdfBase64 = null;

            Integer bodySize = body.length();
            System.debug('stampOriginalToS3: Payload size = ' + bodySize + ' chars');

            HttpRequest req = new HttpRequest();
            req.setEndpoint(SignForceConfigService.getLambdaEndpoint());
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(120000);
            req.setBody(body);
            body = null;

            HttpResponse res;
            try {
                res = new Http().send(req);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    'stampOriginalToS3: upload callout exception: ' + e.getMessage());
                throw new SignForceStampException('Upload callout failed: ' + e.getMessage());
            }

            System.debug('stampOriginalToS3: upload HTTP status = ' + res.getStatusCode());
            if (res.getStatusCode() != 200) {
                String respBody = res.getBody();
                String snippet = respBody != null ? respBody.substring(0, Math.min(300, respBody.length())) : 'null';
                System.debug(LoggingLevel.ERROR,
                    'stampOriginalToS3: upload HTTP ' + res.getStatusCode() + ', body=' + snippet);
                throw new SignForceStampException('Upload returned HTTP ' + res.getStatusCode() + ': ' + snippet);
            }
            System.debug('stampOriginalToS3: ✅ Upload step successful');
        }

        // Step 2: Stamp (Lambda reads from S3, writes new S3 key)
        String stampedDocId = stagingDocId + '_stamped_' + Datetime.now().getTime();

        Map<String, Object> stampPayload = new Map<String, Object>{
            'action' => 'stampS3',
            'orgId' => orgId,
            'sourceDocId' => stagingDocId,
            'targetDocId' => stampedDocId,
            'fields' => fieldList,
            'meta' => meta
        };

        String stampBody = JSON.serialize(stampPayload);
        System.debug('stampOriginalToS3: stamp payload size = ' + stampBody.length() + ' chars');

        HttpRequest stampReq = new HttpRequest();
        stampReq.setEndpoint(SignForceConfigService.getLambdaEndpoint());
        stampReq.setMethod('POST');
        stampReq.setHeader('Content-Type', 'application/json');
        stampReq.setTimeout(120000);
        stampReq.setBody(stampBody);

        HttpResponse stampRes;
        try {
            stampRes = new Http().send(stampReq);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'stampOriginalToS3: stamp callout exception: ' + e.getMessage());
            throw new SignForceStampException('Stamp callout failed: ' + e.getMessage());
        }

        System.debug('stampOriginalToS3: stamp HTTP status = ' + stampRes.getStatusCode());
        if (stampRes.getStatusCode() != 200) {
            String respBody = stampRes.getBody();
            String snippet = respBody != null ? respBody.substring(0, Math.min(300, respBody.length())) : 'null';
            System.debug(LoggingLevel.ERROR,
                'stampOriginalToS3: stampS3 HTTP ' + stampRes.getStatusCode() + ', body=' + snippet);
            throw new SignForceStampException('Stamping returned HTTP ' + stampRes.getStatusCode() + ': ' + snippet);
        }

        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(stampRes.getBody());
        String stampedUrl = (String) result.get('url');
        System.debug('stampOriginalToS3: ✅ Stamping step successful, URL=' + stampedUrl);

        // Step 2.5: Fetch stamped PDF bytes from S3 NOW, before any DML.
        // We need to save the bytes to ContentVersion so the email step can
        // retrieve them without callouts (which would fail with "Uncommitted
        // work pending" after the Stamped record DML below).
        Blob stampedPdfBlob = null;
        try {
            HttpRequest pdfReq = new HttpRequest();
            pdfReq.setEndpoint(stampedUrl);
            pdfReq.setMethod('GET');
            pdfReq.setTimeout(120000);
            pdfReq.setHeader('Accept', 'application/pdf');
            HttpResponse pdfRes = new Http().send(pdfReq);
            if (pdfRes.getStatusCode() == 200) {
                stampedPdfBlob = pdfRes.getBodyAsBlob();
                System.debug('stampOriginalToS3: ✅ Fetched stamped PDF bytes: ' + stampedPdfBlob.size());
            } else {
                System.debug(LoggingLevel.WARN, 'stampOriginalToS3: stamped PDF GET HTTP ' + pdfRes.getStatusCode());
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'stampOriginalToS3: stamped PDF fetch exception: ' + e.getMessage());
        }

        // Save stamped bytes to ContentVersion for email use (no callout needed later)
        Id stampedCvId = null;
        if (stampedPdfBlob != null) {
            try {
                // Always PUBLISH A NEW FILE. It is tempting to add a version to the
                // existing stamped file instead, so the Files panel shows one entry
                // rather than one per signer — but signing runs as the Site Guest
                // User, and the platform lets it neither delete nor add a version to
                // a ContentDocument owned by someone else. Both attempts fail
                // silently, and versioning fails in the worst possible way: the
                // re-stamp after signatures 2..N is never stored, so the "signed"
                // document keeps only the FIRST signature.
                //
                // Publishing a new file is the one operation the guest context can
                // actually perform, so it is what keeps every signature. The extra
                // rows in the Files panel are cosmetic; losing signatures is not.
                ContentVersion stampedCv = new ContentVersion();
                stampedCv.Title = stampedFileTitle(agreementId, agr.Name);
                stampedCv.PathOnClient = stampedFileName(agr.Name);
                stampedCv.VersionData = stampedPdfBlob;
                stampedCv.FirstPublishLocationId = agreementId;

                // Origin removed — sometimes restricted in Guest context.
                // Database.insert with SYSTEM_MODE to bypass Guest FLS limitations.
                Database.SaveResult sr = Database.insert(stampedCv, true, AccessLevel.SYSTEM_MODE);
                if (sr.isSuccess()) {
                    stampedCvId = sr.getId();
                    System.debug('stampOriginalToS3: ✅ Stamped CV created Id=' + stampedCvId);
                } else {
                    System.debug(LoggingLevel.WARN, 'stampOriginalToS3: Stamped CV insert errors: ' + sr.getErrors());
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'stampOriginalToS3: Stamped CV insert exception: ' + e.getMessage());
            }
        }

        // Step 3: Persist Stamped row
        // SignForceFLS.requireDeletable(Agreement_Document__c.SObjectType);
        // ENTITY_IS_DELETED guard: another async path (e.g. generateCertificateOnly)
        // may have already deleted these rows. Use Database.delete with allOrNone=false
        // and ignore EntityIsDeleted errors instead of throwing.
        List<Agreement_Document__c> oldStamped = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId AND Document_Type__c = 'Stamped'
        ];
        if (!oldStamped.isEmpty()) {
            try {
                // CRUD: skip rather than throw. This runs in guest/async stamping,
                // where a missing delete right must not cost a signature - the
                // superseded row simply stays, as it does when the delete fails.
                Database.DeleteResult[] drs = Schema.sObjectType.Agreement_Document__c.isDeletable()
                    ? Database.delete(oldStamped, false)
                    : new List<Database.DeleteResult>();
                for (Database.DeleteResult dr : drs) {
                    if (!dr.isSuccess()) {
                        for (Database.Error err : dr.getErrors()) {
                            // Ignore "already deleted" — that's the desired end state anyway.
                            if (err.getStatusCode() != StatusCode.ENTITY_IS_DELETED) {
                                System.debug(LoggingLevel.WARN,
                                    'stampOriginalToS3: oldStamped delete non-fatal error: '
                                    + err.getStatusCode() + ' ' + err.getMessage());
                            }
                        }
                    }
                }
            } catch (Exception delEx) {
                System.debug(LoggingLevel.WARN, 'stampOriginalToS3: oldStamped delete swallowed: ' + delEx.getMessage());
            }
        }

        // System-mode path (guest-safe): CRUD gate intentionally skipped here.
        Agreement_Document__c stamped = new Agreement_Document__c();
        stamped.Agreement__c = agreementId;
        stamped.Name = (agr.Name + ' - Stamped Signed Document').abbreviate(80);
        stamped.Document_Type__c = 'Stamped';
        stamped.S3_Document_ID__c = stampedDocId;
        stamped.S3_Preview_URL__c = stampedUrl;
        stamped.Content_Version_ID__c = stampedCvId;  // Same-transaction CV for callout-free retrieval
        stamped.Storage_Tier__c = 'Tier1';
        Database.insert(stamped, true, AccessLevel.SYSTEM_MODE);

        System.debug('stampOriginalToS3: ✅ Stamped record created Id=' + stamped.Id + ', CV=' + stampedCvId);
    }

    /**
     * Salesforce-only stamping path (no S3): the original lives in ContentVersion,
     * so we send its bytes to the Lambda's base64 stamp endpoint, get the stamped
     * PDF back as base64, and store it straight into a new ContentVersion. Nothing
     * is written to S3. Runs in the async completion context, whose 12 MB heap
     * comfortably holds a ~4 MB file's base64 + decoded blob.
     */
    private static void stampOriginalToSalesforce(
        Id agreementId,
        Agreement__c agr,
        Agreement_Document__c origDoc,
        List<Map<String, Object>> fieldList,
        Map<String, Object> meta
    ) {
        if (String.isBlank(origDoc.Content_Version_ID__c)) {
            throw new SignForceStampException('stampOriginalToSalesforce: Original CV is blank');
        }

        // Read original bytes → base64 → Lambda base64 stamp → stamped blob.
        Blob stampedPdfBlob;
        {
            ContentVersion cv = [
                SELECT VersionData, FileExtension, PathOnClient, Title FROM ContentVersion
                WHERE Id = :origDoc.Content_Version_ID__c LIMIT 1
            ];
            String ext = cv.FileExtension == null ? '' : cv.FileExtension.toLowerCase();
            String pdfBase64;
            if (ext == 'pdf') {
                pdfBase64 = EncodingUtil.base64Encode(cv.VersionData);
            } else {
                // Generated agreements carry a DOCX original; the stamper parses
                // PDF only ("No PDF header found"). Convert to the same PDF
                // rendition the signer saw (LibreOffice is deterministic, so the
                // field coordinates captured during signing still line up).
                pdfBase64 = convertOriginalToPdfBase64(cv);
            }
            cv = null;

            String body = JSON.serialize(new Map<String, Object>{
                'pdfBase64' => pdfBase64,
                'fields'    => fieldList,
                'meta'      => meta
            });
            pdfBase64 = null;

            HttpRequest req = new HttpRequest();
            req.setEndpoint(SignForceConfigService.getLambdaEndpoint());
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(120000);
            req.setBody(body);
            body = null;

            HttpResponse res;
            try {
                res = new Http().send(req);
            } catch (Exception e) {
                throw new SignForceStampException('Stamp callout failed: ' + e.getMessage());
            }
            if (res.getStatusCode() != 200) {
                String rb = res.getBody();
                throw new SignForceStampException('Stamping returned HTTP ' + res.getStatusCode()
                    + ': ' + (rb != null ? rb.substring(0, Math.min(300, rb.length())) : 'null'));
            }
            Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            String stampedBase64 = (String) result.get('pdfBase64');
            if (String.isBlank(stampedBase64)) {
                throw new SignForceStampException('Stamp response contained no pdfBase64');
            }
            stampedPdfBlob = EncodingUtil.base64Decode(stampedBase64);
        }

        // Publish a new file — see the note in stampOriginalToS3: the Site Guest
        // User can neither delete nor version someone else's ContentDocument, and
        // versioning fails silently, which would drop every signature after the
        // first.
        Id stampedCvId = null;
        ContentVersion stampedCv = new ContentVersion();
        stampedCv.Title = stampedFileTitle(agreementId, agr.Name);
        stampedCv.PathOnClient = stampedFileName(agr.Name);
        stampedCv.VersionData = stampedPdfBlob;
        stampedCv.FirstPublishLocationId = agreementId;
        Database.SaveResult sr = Database.insert(stampedCv, true, AccessLevel.SYSTEM_MODE);
        if (sr.isSuccess()) {
            stampedCvId = sr.getId();
        } else {
            System.debug(LoggingLevel.WARN, 'stampOriginalToSalesforce: Stamped CV insert errors: ' + sr.getErrors());
        }

        // Replace any prior Stamped rows (ignore already-deleted).
        List<Agreement_Document__c> oldStamped = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId AND Document_Type__c = 'Stamped'
        ];
        if (!oldStamped.isEmpty()) {
            try {
                // CRUD: guest/async stamping - skip when the context cannot delete.
                if (Schema.sObjectType.Agreement_Document__c.isDeletable()) {
                    Database.delete(oldStamped, false);
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'stampOriginalToSalesforce: oldStamped delete swallowed: ' + e.getMessage());
            }
        }

        Agreement_Document__c stamped = new Agreement_Document__c();
        stamped.Agreement__c        = agreementId;
        stamped.Name                = (agr.Name + ' - Stamped Signed Document').abbreviate(80);
        stamped.Document_Type__c    = 'Stamped';
        stamped.Content_Version_ID__c = stampedCvId;
        stamped.Storage_Tier__c     = 'Tier1';
        stamped.Storage_Type__c     = 'Salesforce';
        Database.insert(stamped, true, AccessLevel.SYSTEM_MODE);

        System.debug('stampOriginalToSalesforce: ✅ Stamped stored in Salesforce, CV=' + stampedCvId);
    }

    /**
     * DOCX/DOC original → PDF base64 for the stamper, via the backend:
     * convertToPdf (LibreOffice, uploads to S3) then proxyUrl to pull the bytes
     * back server-side. Runs in the async stamping context, so the extra two
     * callouts are safe.
     */
    private static String convertOriginalToPdfBase64(ContentVersion cv) {
        String endpoint = SignForceConfigService.getLambdaEndpoint();
        String fileName = String.isNotBlank(cv.PathOnClient)
            ? cv.PathOnClient
            : (String.isNotBlank(cv.Title) ? cv.Title : 'document.docx');

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);
        req.setBody(JSON.serialize(new Map<String, Object>{
            'action'   => 'convertToPdf',
            'orgId'    => UserInfo.getOrganizationId(),
            'docId'    => 'agrstamp_' + cv.Id + '_' + String.valueOf(System.currentTimeMillis()),
            'base64'   => EncodingUtil.base64Encode(cv.VersionData),
            'filename' => fileName
        }));
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new SignForceStampException(
                'Original DOCX→PDF conversion failed: HTTP ' + res.getStatusCode());
        }
        Map<String, Object> conv = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        String url = (String) conv.get('url');
        if (conv.get('success') != true || String.isBlank(url)) {
            throw new SignForceStampException(
                'Original DOCX→PDF conversion failed: ' + conv.get('error'));
        }

        HttpRequest proxy = new HttpRequest();
        proxy.setEndpoint(endpoint);
        proxy.setMethod('POST');
        proxy.setHeader('Content-Type', 'application/json');
        proxy.setTimeout(120000);
        proxy.setBody(JSON.serialize(new Map<String, String>{ 'proxyUrl' => url }));
        res = new Http().send(proxy);
        if (res.getStatusCode() != 200) {
            throw new SignForceStampException(
                'Converted PDF fetch failed: HTTP ' + res.getStatusCode());
        }
        Map<String, Object> fetched = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        String b64 = (String) fetched.get('pdfBase64');
        if (String.isBlank(b64)) {
            throw new SignForceStampException('Converted PDF fetch returned no bytes');
        }
        return b64;
    }

    /**
     * Tier2/Tier3 stamping path: Original already in S3.
     *
     * Like stampOriginalToS3, this also fetches the stamped PDF bytes and
     * saves them to a ContentVersion BEFORE any DML — so the email step
     * can retrieve them via CV path without callouts. Only caches CV if
     * file is under 6MB (Salesforce CV practical limit).
     */
  /**
   * Stamp a Cloud-tier (>4MB) Original. The Lambda downloads the original from
   * the cloud provider, stamps it, and uploads the stamped PDF straight back to
   * the agreement's Stamped folder — S3 and Salesforce heap are never touched.
   * We store only the returned cloud handle; the completion email fetches the
   * stamped bytes from the cloud on demand.
   */
  private static void stampViaCloud(
        Id agreementId,
        Agreement__c agr,
        Agreement_Document__c origDoc,
        List<Map<String, Object>> fieldList,
        Map<String, Object> meta
    ) {
        // Resolve the destination Stamped folder + provider from the Agreement.
        Agreement__c a = [
            SELECT Cloud_Provider__c, Cloud_Stamped_Folder_Id__c
            FROM Agreement__c WHERE Id = :agreementId LIMIT 1
        ];
        String provider = String.isNotBlank(origDoc.Cloud_Provider__c)
            ? origDoc.Cloud_Provider__c : a.Cloud_Provider__c;
        String stampedFolderId = a.Cloud_Stamped_Folder_Id__c;
        if (String.isBlank(stampedFolderId)) {
            throw new SignForceStampException('stampViaCloud: Stamped folder id missing on agreement');
        }
        String outName = stampedFileName(agr.Name);

        Map<String, Object> payload = new Map<String, Object>{
            'action'       => 'stampCloud',
            'provider'     => provider,
            'orgId'        => UserInfo.getOrganizationId(),
            'sourceFileId' => origDoc.Cloud_File_Id__c,
            'folderId'     => stampedFolderId,
            'fileName'     => outName,
            'fields'       => fieldList,
            'meta'         => meta
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint(SignForceConfigService.getLambdaEndpoint());
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);
        req.setBody(JSON.serialize(payload));

        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (Exception e) {
            throw new SignForceStampException('stampViaCloud callout failed: ' + e.getMessage());
        }
        if (res.getStatusCode() != 200) {
            String b = res.getBody();
            throw new SignForceStampException('stampViaCloud HTTP ' + res.getStatusCode()
                + ': ' + (b != null ? b.substring(0, Math.min(300, b.length())) : 'null'));
        }
        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        if (result.get('success') != true) {
            throw new SignForceStampException('stampViaCloud failed: ' + result.get('message'));
        }
        String stampedFileId = (String) result.get('fileId');
        String previewUrl = (String) result.get('previewUrl');
        // Persist the size so the completion email can decide attach-vs-link
        // without having to pull the bytes back just to measure them.
        Decimal stampedSize = result.get('size') != null
            ? (Decimal) Double.valueOf(String.valueOf(result.get('size')))
            : null;
        System.debug('stampViaCloud: ✅ stamped fileId=' + stampedFileId);

        // Remove any prior Stamped rows (idempotent re-stamp), then record the new one.
        List<Agreement_Document__c> oldStamped = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId AND Document_Type__c = 'Stamped'
        ];
        if (!oldStamped.isEmpty()) {
            try {
                // CRUD: guest/async stamping - skip when the context cannot delete.
                if (Schema.sObjectType.Agreement_Document__c.isDeletable()) {
                    Database.delete(oldStamped, false);
                }
            } catch (Exception delEx) {
                System.debug(LoggingLevel.WARN, 'stampViaCloud: oldStamped delete swallowed: ' + delEx.getMessage());
            }
        }

        Agreement_Document__c stamped = new Agreement_Document__c();
        stamped.Agreement__c = agreementId;
        stamped.Name = (agr.Name + ' - Stamped Signed Document').abbreviate(80);
        stamped.Document_Type__c = 'Stamped';
        stamped.Storage_Type__c = 'Cloud';
        stamped.Cloud_Provider__c = provider;
        stamped.Cloud_File_Id__c = stampedFileId;
        stamped.Cloud_Folder_Id__c = stampedFolderId;
        stamped.S3_Preview_URL__c = previewUrl;
        stamped.File_Size_Bytes__c = stampedSize;
        stamped.Storage_Tier__c = origDoc.Storage_Tier__c != null ? origDoc.Storage_Tier__c : 'Tier2';
        Database.insert(stamped, true, AccessLevel.SYSTEM_MODE);
        System.debug('stampViaCloud: ✅ Stamped record created Id=' + stamped.Id + ', size=' + stampedSize);
    }


  /**
   * File name for the stamped PDF.
   *
   * This lands on ContentVersion.PathOnClient, and IntegrationService reads
   * PathOnClient to name the copy it pushes to Google Drive or OneDrive — so
   * whatever this returns is what the customer sees in their drive.
   *
   * It used to strip everything outside [a-zA-Z0-9._-], which turned
   * "Test - Burlington Textiles Corp of America (12) - Stamped.pdf" into
   * "Test_-_Burlington_Textiles_Corp_of_America__12__-_Stamped.pdf". Spaces and
   * brackets are legal in file names on every platform and in both cloud
   * providers; only the reserved set below is not. That reserved set is the
   * same one IntegrationService.cloudFolderName already uses for folders, so
   * the file and the folder holding it are now named by one rule.
   */
  private static String stampedFileName(String agreementName) {
      String base = String.isBlank(agreementName) ? 'Agreement' : agreementName;
      String cleaned = (base + ' - Stamped.pdf')
          .replaceAll('["*:<>?/\\\\|]', '-')   // reserved on Windows and in Drive
          .replaceAll('\\s+', ' ')             // collapse runs of whitespace
          .trim();
      return String.isBlank(cleaned) ? 'Agreement - Stamped.pdf' : cleaned;
  }

  /**
   * Names a stamped file after the progress it captures.
   *
   * The document is re-stamped after every signature and each stamp is published
   * as its own file — signing runs as the Site Guest User, which the platform lets
   * neither delete nor version the earlier ones. Giving them all the same name left
   * a pile of identical rows with no way to tell which was current, or whose
   * signature each carried.
   *
   * So they are named instead: "Signed 2 of 3 - Darsh Desai" while the round is in
   * progress, and "Final Signed Document" once everyone has signed. Nothing looks
   * files up by title — the Stamped/Signed pointers on Agreement_Document__c are
   * what code resolves through — so this is presentation only.
   */
  private static String stampedFileTitle(Id agreementId, String agreementName) {
      String base = String.isBlank(agreementName) ? 'Agreement' : agreementName;
      try {
          List<Signer__c> signers = [
              SELECT Name, Email__c, Status__c
              FROM Signer__c
              WHERE Agreement__c = :agreementId
              AND (Role__c = 'Signer' OR Role__c = null)
              ORDER BY Signed_Date__c ASC NULLS LAST
          ];
          Integer total = signers.size();
          if (total <= 1) return truncateTitle(base + ' - Signed Document');

          Integer signed = 0;
          String latest = null;
          for (Signer__c s : signers) {
              if (s.Status__c != 'Signed') continue;
              signed++;
              String who = String.isNotBlank(s.Name) ? s.Name : s.Email__c;
              if (String.isNotBlank(who)) latest = who;   // ordered by Signed_Date__c
          }

          if (signed >= total) return truncateTitle(base + ' - Final Signed Document');
          String label = base + ' - Signed ' + signed + ' of ' + total;
          if (String.isNotBlank(latest)) label += ' - ' + latest;
          return truncateTitle(label);
      } catch (Exception e) {
          // Naming must never block a stamp.
          return truncateTitle(base + ' - Stamped Signed Document');
      }
  }

  /** ContentVersion.Title caps at 255 characters. */
  private static String truncateTitle(String title) {
      if (String.isBlank(title)) return 'Signed Document';
      return title.length() > 255 ? title.substring(0, 255) : title;
  }

  private static void stampViaS3(
        Id agreementId,
        Agreement__c agr,
        Agreement_Document__c origDoc,
        List<Map<String, Object>> fieldList,
        Map<String, Object> meta
    ) {
        String orgId = UserInfo.getOrganizationId();
        String stampedDocId = origDoc.S3_Document_ID__c + '_stamped_' + Datetime.now().getTime();

        System.debug('stampViaS3: Start, sourceDocId=' + origDoc.S3_Document_ID__c
            + ', targetDocId=' + stampedDocId);

        Map<String, Object> payload = new Map<String, Object>{
            'action' => 'stampS3',
            'orgId' => orgId,
            'sourceDocId' => origDoc.S3_Document_ID__c,
            'targetDocId' => stampedDocId,
            'fields' => fieldList,
            'meta' => meta
        };

        Http http = new Http();
        HttpRequest req = new HttpRequest();
        req.setEndpoint(SignForceConfigService.getLambdaEndpoint());
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);
        req.setBody(JSON.serialize(payload));

        HttpResponse res;
        try {
            res = http.send(req);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'stampViaS3: callout exception: ' + e.getMessage());
            throw new SignForceStampException('Stamp callout failed: ' + e.getMessage());
        }

        System.debug('stampViaS3: HTTP status = ' + res.getStatusCode());
        if (res.getStatusCode() != 200) {
            String respBody = res.getBody();
            String snippet = respBody != null ? respBody.substring(0, Math.min(300, respBody.length())) : 'null';
            System.debug(LoggingLevel.ERROR,
                'stampViaS3: Lambda HTTP ' + res.getStatusCode() + ', body=' + snippet);
            throw new SignForceStampException('Stamping returned HTTP ' + res.getStatusCode() + ': ' + snippet);
        }

        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        String stampedUrl = (String) result.get('url');
        System.debug('stampViaS3: ✅ Stamping successful, URL=' + stampedUrl);

        // Fetch stamped PDF bytes NOW (before DML) for callout-free email access.
        // Only cache if under ~6MB (ContentVersion size limit considerations).
        Blob stampedPdfBlob = null;
        try {
            HttpRequest pdfReq = new HttpRequest();
            pdfReq.setEndpoint(stampedUrl);
            pdfReq.setMethod('GET');
            pdfReq.setTimeout(120000);
            pdfReq.setHeader('Accept', 'application/pdf');
            HttpResponse pdfRes = new Http().send(pdfReq);
            if (pdfRes.getStatusCode() == 200) {
                Blob raw = pdfRes.getBodyAsBlob();
                if (raw.size() < 6 * 1024 * 1024) {
                    stampedPdfBlob = raw;
                    System.debug('stampViaS3: ✅ Fetched stamped PDF bytes: ' + raw.size());
                } else {
                    System.debug('stampViaS3: Stamped PDF too large for CV cache (' 
                        + raw.size() + ' bytes), S3 only');
                }
            } else {
                System.debug(LoggingLevel.WARN, 'stampViaS3: stamped PDF GET HTTP ' + pdfRes.getStatusCode());
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'stampViaS3: stamped PDF fetch exception: ' + e.getMessage());
        }

        Id stampedCvId = null;
        if (stampedPdfBlob != null) {
            try {
                ContentVersion stampedCv = new ContentVersion();
                stampedCv.Title = stampedFileTitle(agreementId, agr.Name);
                stampedCv.PathOnClient = stampedFileName(agr.Name);
                stampedCv.VersionData = stampedPdfBlob;
                // Origin removed — sometimes restricted in Guest context.
                // Database.insert with SYSTEM_MODE to bypass Guest FLS limitations.
                Database.SaveResult sr = Database.insert(stampedCv, true, AccessLevel.SYSTEM_MODE);
                if (sr.isSuccess()) {
                    stampedCvId = sr.getId();
                    System.debug('stampViaS3: ✅ Stamped CV created Id=' + stampedCvId);
                } else {
                    System.debug(LoggingLevel.WARN, 'stampViaS3: Stamped CV insert errors: ' + sr.getErrors());
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'stampViaS3: Stamped CV insert exception: ' + e.getMessage());
            }
        }

        // SignForceFLS.requireDeletable(Agreement_Document__c.SObjectType);
        // ENTITY_IS_DELETED guard: another async path may have already deleted these rows.
        List<Agreement_Document__c> oldStamped = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId AND Document_Type__c = 'Stamped'
        ];
        if (!oldStamped.isEmpty()) {
            try {
                // CRUD: skip rather than throw. This runs in guest/async stamping,
                // where a missing delete right must not cost a signature - the
                // superseded row simply stays, as it does when the delete fails.
                Database.DeleteResult[] drs = Schema.sObjectType.Agreement_Document__c.isDeletable()
                    ? Database.delete(oldStamped, false)
                    : new List<Database.DeleteResult>();
                for (Database.DeleteResult dr : drs) {
                    if (!dr.isSuccess()) {
                        for (Database.Error err : dr.getErrors()) {
                            if (err.getStatusCode() != StatusCode.ENTITY_IS_DELETED) {
                                System.debug(LoggingLevel.WARN,
                                    'stampViaS3: oldStamped delete non-fatal error: '
                                    + err.getStatusCode() + ' ' + err.getMessage());
                            }
                        }
                    }
                }
            } catch (Exception delEx) {
                System.debug(LoggingLevel.WARN, 'stampViaS3: oldStamped delete swallowed: ' + delEx.getMessage());
            }
        }

        // System-mode path (guest-safe): CRUD gate intentionally skipped here.
        Agreement_Document__c stamped = new Agreement_Document__c();
        stamped.Agreement__c = agreementId;
        stamped.Name = (agr.Name + ' - Stamped Signed Document').abbreviate(80);
        stamped.Document_Type__c = 'Stamped';
        stamped.S3_Document_ID__c = stampedDocId;
        stamped.S3_Preview_URL__c = stampedUrl;
        stamped.Content_Version_ID__c = stampedCvId;  // Same-transaction CV for callout-free retrieval
        stamped.Storage_Tier__c = origDoc.Storage_Tier__c != null ? origDoc.Storage_Tier__c : 'Tier2';
        Database.insert(stamped, true, AccessLevel.SYSTEM_MODE);

        System.debug('stampViaS3: ✅ Stamped record created Id=' + stamped.Id + ', CV=' + stampedCvId);
    }

    /**
     * Build the field-list payload sent to Lambda's stampS3 action.
    /**
     * Preserves full signature data — no truncation.
     */
    private static List<Map<String, Object>> buildStampFieldList(List<Signature_Field__c> fields) {
        List<Map<String, Object>> fieldList = new List<Map<String, Object>>();
        for (Signature_Field__c f : fields) {
            if (String.isBlank(f.Field_Value__c)) continue;

            Map<String, Object> fm = new Map<String, Object>();
            fm.put('fieldType', f.Field_Type__c);

            // Preserve signature data fully - no truncation or conversion
            fm.put('value', f.Field_Value__c);

            // BUG-041 FIX: Pehle Lambda ko sirf raw Field_Value__c milta tha,
            // jiska Type signature ka format hai "typed:<Name>:<FontFamily>"
            // (e.g. "typed:John Doe:Dancing Script"). Lambda ko font nahi
            // pata tha so it rendered everything in default Arial — typography
            // mismatch between signing UI (cursive script) and signed PDF (Arial).
            // Ab parsedValue + fontFamily explicitly extract karke bhejte hain,
            // taki Lambda renderer signature ko correct script font me draw kare.
            String rawVal = f.Field_Value__c;
            String parsedValue = rawVal;
            String fontFamily = '';
            if (f.Field_Type__c == 'Signature' || f.Field_Type__c == 'Initial') {
                if (String.isNotBlank(rawVal) && rawVal.startsWith('typed:')) {
                    // Format: "typed:Display Name:Font Family"
                    List<String> parts = rawVal.split(':', 3);
                    if (parts.size() >= 2) parsedValue = parts[1];
                    if (parts.size() >= 3) fontFamily = parts[2];
                }
            }
            // BUG-042 FIX: Checkbox field on Lambda render side was drawing
            // 'X' for the checked state. We now send the expected checkmark
            // glyph explicitly so the Lambda renderer (and any other consumer)
            // doesn't have to guess. We send U+2713 (✓) — universally
            // available + renders well in most PDF fonts. When unchecked,
            // we send an empty ballot box character to maintain visible
            // distinction (Lambda can still skip rendering if it prefers).
            if (f.Field_Type__c == 'Checkbox') {
                Boolean isChecked = (rawVal == 'true');
                parsedValue = isChecked ? '\u2713' : '';
                fm.put('checkboxChecked', isChecked);
                fm.put('checkboxSymbol', isChecked ? '\u2713' : '\u2610');
            }
            fm.put('parsedValue', parsedValue);
            fm.put('fontFamily', fontFamily);

            fm.put('page', f.Page_Number__c != null ? (Integer)f.Page_Number__c - 1 : 0);
            fm.put('x', f.X_Position__c);
            fm.put('y', f.Y_Position__c);
            fm.put('width', f.Width__c);
            fm.put('height', f.Height__c);
            fm.put('pageWidth', f.Page_Width__c);
            fm.put('isCompleted', f.Is_Completed__c);

            fm.put('signerName', f.Assigned_Signer__r != null ? f.Assigned_Signer__r.Name : '');
            // Real signing certificate ID for the stamp footer ("CertID · Name ·
            // Date"). Without this the Lambda fell back to using the signer's
            // NAME as the cert ID, so the name printed twice (uppercase cert
            // slot + normal name). Sending the real ID fixes that duplication.
            fm.put('certId', f.Assigned_Signer__r != null ? f.Assigned_Signer__r.Signature_Certificate_ID__c : '');
            fm.put('signerEmail', f.Assigned_Signer__r != null ? f.Assigned_Signer__r.Email__c : '');
            fm.put('signerIp', f.Assigned_Signer__r != null ? f.Assigned_Signer__r.Signing_IP_Address__c : '');
            fm.put('signedTimestamp', f.Assigned_Signer__r != null && f.Assigned_Signer__r.Signed_Date__c != null
                ? f.Assigned_Signer__r.Signed_Date__c.formatGmt('yyyy-MM-dd HH:mm:ss') + ' UTC' : '');

            fieldList.add(fm);
        }
        return fieldList;
    }

    @AuraEnabled
    public static void regenerateStampedPDF(Id agreementId) {
        if (agreementId == null) {
            throw new AuraHandledException('agreementId is required.');
        }
        generateStampedPDFServerInternal(agreementId);
        AuditTrailService.log(agreementId, 'Stamped PDF Regenerated', UserInfo.getUserEmail(), null, null);
    }

    @AuraEnabled
    public static void regenerateStampedAndResend(Id agreementId) {
        regenerateStampedPDF(agreementId);
        try {
            AgreementService.sendCompletionEmailsPublic(agreementId);
        } catch (Exception e) {
            throw new AuraHandledException(
                'Stamped PDF regenerated OK, but re-sending emails failed: ' + e.getMessage()
            );
        }
    }

    @AuraEnabled
    public static void sendCompletionEmailsWithPDF(Id agreementId) {
        try {
            PDFGenerationService.generateCertificateOnly(agreementId);
        } catch(Exception e) {
            System.debug('Certificate generation failed (non-fatal): ' + e.getMessage());
        }
        // sendCompletionEmailsPublic throws AgreementException when EVERY recipient
        // is rejected. Letting that escape an @AuraEnabled method twice hurt the
        // admin: the UI showed the generic "An internal server error has occurred"
        // instead of the real reason, and the rollback that comes with an escaping
        // exception took the "Completion Email Failed" audit rows with it — so the
        // record carried no trace of the very failure that had just happened.
        //
        // Converting it here puts the actual reason in front of the person who can
        // act on it. The rows still roll back on this path (any exception out of an
        // @AuraEnabled method rolls the transaction back, AuraHandledException
        // included) — but the admin now reads the reason directly rather than being
        // sent to look for a record that is not there. On the queueable path, where
        // nobody is watching, sendEmailSafe catches instead and the rows persist.
        try {
            AgreementService.sendCompletionEmailsPublic(agreementId);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
        try {
            IntegrationService.pushAgreementDocumentsAsync(agreementId);
        } catch(Exception e) {
            System.debug('Cloud push failed: ' + e.getMessage());
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    //  AGREEMENT QUERIES
    // ═════════════════════════════════════════════════════════════════════

    @AuraEnabled(cacheable=true)
    public static List<Agreement__c> getMyAgreements() {
        return [
            SELECT Id, Name, Status__c, Agreement_Type__c, Sent_Date__c,
                   Completed_Date__c, Expiry_Date__c, Signing_Order__c, CreatedDate
            FROM Agreement__c
            WHERE Is_Template__c = false
            WITH USER_MODE
            ORDER BY CreatedDate DESC LIMIT 50
        ];
    }

    @AuraEnabled(cacheable=true)
    public static Agreement__c getAgreementDetail(Id agreementId) {
        return [
            SELECT Id, Name, Status__c, Agreement_Type__c, Sent_Date__c,
                   Completed_Date__c, Expiry_Date__c, Signing_Order__c,
                   Message_to_Signers__c, Document_Hash__c
            FROM Agreement__c WHERE Id = :agreementId
            WITH USER_MODE
        ];
    }

    @AuraEnabled(cacheable=true)
    public static List<Signer__c> getSigners(Id agreementId) {
        return [
            SELECT Id, Name, Email__c, Role__c, Status__c, Signing_Order__c, Signed_Date__c
            FROM Signer__c WHERE Agreement__c = :agreementId
            WITH USER_MODE
            ORDER BY Signing_Order__c ASC
        ];
    }

    @AuraEnabled(cacheable=true)
    public static List<Signing_Event__c> getAuditTrail(Id agreementId) {
        return [
            SELECT Id, Name, Action__c, Signer_Email__c, IP_Address__c, Event_Timestamp__c, Notes__c
            FROM Signing_Event__c WHERE Agreement__c = :agreementId
            WITH USER_MODE
            ORDER BY Event_Timestamp__c ASC
        ];
    }

    // ═════════════════════════════════════════════════════════════════════
    //  AGREEMENT LIFECYCLE
    // ═════════════════════════════════════════════════════════════════════

    @AuraEnabled
    public static Id createAgreement(String name, String agreementType, String signingOrder, String message, DateTime expiryDate) {
        Agreement__c agr = AgreementService.createAgreement(name, agreementType, signingOrder, message, expiryDate);
        return agr.Id;
    }

    /**
     * BUG-037/042/043/063 FIX: lets the agreement editor persist edits to the
     * core agreement details (name, type, signing order, message, expiry). Uses
     * the SAME field API names as AgreementService.createAgreement. Name/type
     * are only overwritten when a non-blank value is supplied (so a blank input
     * does not wipe an existing value); expiryDate may be null to CLEAR it.
     */
    @AuraEnabled
    public static void updateAgreement(Id agreementId, String name, String agreementType, String signingOrder, String message, Datetime expiryDate) {
        if (agreementId == null) {
            throw new AuraHandledException('agreementId is required');
        }
        Agreement__c agr = [
            SELECT Id, Name, Agreement_Type__c, Signing_Order__c,
                   Message_to_Signers__c, Expiry_Date__c
            FROM Agreement__c WHERE Id = :agreementId
            WITH USER_MODE
            LIMIT 1
        ];

        SignForceFLS.requireUpdateable(Agreement__c.SObjectType);
        if (String.isNotBlank(name))          agr.Name = name;
        if (String.isNotBlank(agreementType)) agr.Agreement_Type__c = agreementType;
        agr.Signing_Order__c = signingOrder;
        agr.Message_to_Signers__c = message;
        agr.Expiry_Date__c = expiryDate;   // null intentionally clears the expiry
        Database.update(agr, true, AccessLevel.USER_MODE);
    }

    @AuraEnabled
    public static void sendForSignature(Id agreementId) {
        AgreementService.sendForSignature(agreementId);
    }

    @AuraEnabled
    public static void sendForSignatureWithCustomEmail(Id agreementId, String emailSubject, String emailMessage) {
        AgreementService.sendForSignature(agreementId, emailSubject, emailMessage);
    }

    @AuraEnabled
    public static void voidAgreement(Id agreementId, String reason) {
        AgreementService.voidAgreement(agreementId, reason);
    }

    @AuraEnabled
    public static Id correctAgreement(Id agreementId, String reason) {
        return AgreementService.correctAgreement(agreementId, reason);
    }

    @AuraEnabled
    public static Boolean verifyDocumentHash(Id agreementId) {
        return AgreementService.verifyDocumentHash(agreementId);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  SIGNERS
    // ═════════════════════════════════════════════════════════════════════

    /**
     * Recipients may only change while the envelope is in Draft. The editor UI
     * hides its buttons on the same rule, but getAgreementDetail is a cacheable
     * wire — a panel rendered before Send still shows them — so the rule is
     * enforced here where it cannot be stale.
     */
    private static void requireDraftAgreement(Id agreementId) {
        List<Agreement__c> agr = [
            SELECT Status__c FROM Agreement__c WHERE Id = :agreementId
            WITH USER_MODE LIMIT 1
        ];
        if (!agr.isEmpty() && agr[0].Status__c != 'Draft') {
            throw new AuraHandledException(
                'This agreement has been sent — recipients can no longer be changed.');
        }
    }

    /**
     * Signing order must be unique among the people who actually sign.
     * Shared numbers used to mean "sign together as a group", but that read as a
     * bug to administrators, so duplicates are refused outright. CC recipients
     * never sign - their order is meaningless - so they are exempt on both sides.
     * Role__c can legitimately be null and such a person DOES sign, and SOQL's
     * != never matches null rows, hence the explicit null arm in the filter.
     */
    private static void requireUniqueSigningOrder(Id agreementId, Integer orderNum, String role, Id excludeId) {
        if (orderNum == null || role == 'CC') return;
        List<Signer__c> clash = [
            SELECT Name FROM Signer__c
            WHERE Agreement__c = :agreementId
              AND Signing_Order__c = :orderNum
              AND (Role__c != 'CC' OR Role__c = null)
              AND Id != :excludeId
            WITH USER_MODE
            LIMIT 1
        ];
        if (!clash.isEmpty()) {
            String msg = 'Signing order ' + orderNum + ' is already taken by ' + clash[0].Name
                       + '. Give each signer a unique order.';
            AuraHandledException e = new AuraHandledException(msg);
            e.setMessage(msg);
            throw e;
        }
    }

    @AuraEnabled
    public static Id addSigner(Id agreementId, String signerName, String email, String role, Integer orderNum) {
        requireDraftAgreement(agreementId);
        requireUniqueSigningOrder(agreementId, orderNum, role, null);
        SignForceFLS.requireCreateable(Signer__c.SObjectType);
        Signer__c s = new Signer__c();
        s.Agreement__c = agreementId;
        s.Name = signerName;
        s.Email__c = email;
        s.Role__c = role;
        s.Signing_Order__c = orderNum;
        s.Status__c = 'Pending';
        Database.insert(s, true, AccessLevel.USER_MODE);
        // BUG-008/010/016 FIX: return Id so LWC can track the row for later
        // updates / deletes without re-querying.
        return s.Id;
    }

    @AuraEnabled
    public static void updateSigner(Id signerId, String signerName, String email, String role, Integer orderNum) {
        Signer__c s = [
            SELECT Id, Status__c, Agreement__c FROM Signer__c WHERE Id = :signerId
            WITH USER_MODE
            LIMIT 1
        ];
        if (s.Status__c == 'Signed') {
            throw new AuraHandledException('Cannot edit a signer who has already signed.');
        }
        requireDraftAgreement(s.Agreement__c);
        requireUniqueSigningOrder(s.Agreement__c, orderNum, role, s.Id);
        SignForceFLS.requireUpdateable(Signer__c.SObjectType);
        // Minimal record: updating the queried row would carry the master-detail
        // Agreement__c field into the USER_MODE payload, which fails FLS.
        Signer__c upd = new Signer__c(Id = s.Id);
        upd.Name = signerName;
        upd.Email__c = email;
        upd.Role__c = role;
        upd.Signing_Order__c = orderNum;
        Database.update(upd, true, AccessLevel.USER_MODE);
    }

    @AuraEnabled
    public static void deleteSigner(Id signerId) {
        Signer__c s = [
            SELECT Id, Status__c, Agreement__c FROM Signer__c WHERE Id = :signerId
            WITH USER_MODE
            LIMIT 1
        ];
        if (s.Status__c == 'Signed') {
            throw new AuraHandledException('Cannot remove a signer who has already signed.');
        }
        requireDraftAgreement(s.Agreement__c);
        List<Signature_Field__c> fields = [
            SELECT Id FROM Signature_Field__c
            WHERE Assigned_Signer__c = :signerId
            WITH USER_MODE
        ];
        if (!fields.isEmpty()) {
            SignForceFLS.requireDeletable(Signature_Field__c.SObjectType);
            Database.delete(fields, true, AccessLevel.USER_MODE);
        }
        SignForceFLS.requireDeletable(Signer__c.SObjectType);
        Database.delete(s, true, AccessLevel.USER_MODE);
    }

    @AuraEnabled
    public static void resendSignerEmail(Id signerId) {
        AgreementService.resendSignerEmail(signerId);
    }

    @AuraEnabled
    public static void sendReminder(Id signerId) {
        AgreementService.sendReminderEmail(signerId);
    }

    @AuraEnabled
    public static void sendBulkReminders(Id agreementId) {
        AgreementService.sendBulkReminders(agreementId);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  TOKEN BRIDGES
    // ═════════════════════════════════════════════════════════════════════

    @AuraEnabled
    public static Map<String, Object> getSignerByToken(String token) {
        return AgreementService.validateToken(token);
    }

    @AuraEnabled
    public static void declineAgreement(Id signerId, String reason) {
        AgreementService.declineAgreementGuest(signerId, reason);
    }

    @AuraEnabled
    public static Map<String, Object> markSigned(Id signerId, String ipAddress, String userAgent) {
        AgreementService.markSigned(signerId, ipAddress, userAgent);

        Signer__c signer = [
            SELECT Agreement__c, Signature_Certificate_ID__c FROM Signer__c WHERE Id = :signerId
            WITH USER_MODE
            LIMIT 1
        ];
        Agreement__c agr = [
            SELECT Id, Status__c FROM Agreement__c WHERE Id = :signer.Agreement__c
            WITH USER_MODE
            LIMIT 1
        ];

        return new Map<String, Object>{
            'isCompleted' => agr.Status__c == 'Completed',
            'agreementId' => agr.Id,
            'certificateId' => signer.Signature_Certificate_ID__c
        };
    }

    // ═════════════════════════════════════════════════════════════════════
    //  SIGNATURE LIBRARY
    // ═════════════════════════════════════════════════════════════════════

    @AuraEnabled
    public static void saveSignature(String email, String signatureData, String signatureType, String fontFamily) {
        SignatureService.saveSignature(email, signatureData, signatureType, fontFamily);
    }

    @AuraEnabled
    public static Map<String, Object> getSavedSignature(String email) {
        return SignatureService.getSavedSignature(email);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  DOCUMENT METADATA / PUBLIC URLS
    // ═════════════════════════════════════════════════════════════════════

    @AuraEnabled
    public static String getDocumentPublicUrl(Id agreementId) {
        String url = DocumentService.getDocumentPublicUrl(agreementId);
        if (String.isNotBlank(url)) return url;
        try {
            DocumentService.createPublicUrlForAgreement(agreementId);
            url = DocumentService.getDocumentPublicUrl(agreementId);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Failed to create public URL: ' + e.getMessage());
        }
        return url;
    }

    @AuraEnabled
    public static Map<String, Object> getLargeDocumentInfo(String contentVersionId) {
        Map<String, Object> result = new Map<String, Object>();

        ContentVersion cv = [
            SELECT ContentSize, ContentDocumentId
            FROM ContentVersion WHERE Id = :contentVersionId
            WITH USER_MODE
            LIMIT 1
        ];

        result.put('size', cv.ContentSize);
        result.put('isLarge', cv.ContentSize > 4500000);

        if (cv.ContentSize > 4500000) {
            result.put('publicUrl', getOrCreateDistributionUrl(contentVersionId, 'Preview-', true));
        }
        return result;
    }

    @AuraEnabled
    public static Map<String, Object> getPdfFileInfo(String contentVersionId) {
        ContentVersion cv = [
            SELECT ContentSize, ContentDocumentId
            FROM ContentVersion WHERE Id = :contentVersionId
            WITH USER_MODE
            LIMIT 1
        ];
        Map<String, Object> result = new Map<String, Object>();
        result.put('size', cv.ContentSize);
        result.put('isLarge', cv.ContentSize > 4000000);

        if (cv.ContentSize > 4000000) {
            try {
                result.put('downloadUrl', getOrCreateDistributionUrl(contentVersionId, 'Preview-', false));
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'ContentDistribution error: ' + e.getMessage());
            }
        }
        return result;
    }

    @AuraEnabled
    public static String proxyPdfViaLambda(String downloadUrl) {
        // downloadUrl is always a ContentDistribution public link (see
        // getPdfFileInfo -> getOrCreateDistributionUrl below): a self-authenticating
        // URL that needs no Salesforce session to read. The Lambda's proxyUrl
        // handler confirms this — it does a plain unauthenticated GET and never
        // reads accessToken/instanceUrl.
        //
        // This used to send UserInfo.getSessionId() in the payload anyway: a live,
        // full-API-privilege Salesforce session token, handed to an external host,
        // for a field nothing on the receiving end ever looked at. Removing it
        // costs nothing — the request works exactly the same without it — and it
        // was flagged by the security review as sending a session identifier off
        // the platform, which is one of the checks a security review looks for.
        Http http = new Http();
        HttpRequest req = new HttpRequest();
        req.setEndpoint(SignForceConfigService.getLambdaEndpoint());
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);

        Map<String, String> payload = new Map<String, String>();
        payload.put('proxyUrl', downloadUrl);
        req.setBody(JSON.serialize(payload));

        HttpResponse res = http.send(req);
        if (res.getStatusCode() == 200) {
            Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            return (String) result.get('pdfBase64');
        }
        String body = res.getBody();
        throw new AuraHandledException(
            'Proxy failed: HTTP ' + res.getStatusCode() + ' '
            + (body != null ? body.substring(0, Math.min(300, body.length())) : '')
        );
    }

    private static String getOrCreateDistributionUrl(Id cvId, String namePrefix, Boolean wantPublicUrl) {
        List<ContentDistribution> existing = [
            SELECT DistributionPublicUrl, ContentDownloadUrl
            FROM ContentDistribution
            WHERE ContentVersionId = :cvId
            WITH USER_MODE
            LIMIT 1
        ];

        if (!existing.isEmpty()) {
            return wantPublicUrl ? existing[0].DistributionPublicUrl : existing[0].ContentDownloadUrl;
        }

        SignForceFLS.requireCreateable(ContentDistribution.SObjectType);
        ContentDistribution dist = new ContentDistribution();
        dist.Name = namePrefix + cvId;
        dist.ContentVersionId = cvId;
        dist.PreferencesAllowViewInBrowser = true;
        dist.PreferencesLinkLatestVersion = false;
        dist.PreferencesNotifyOnVisit = false;
        dist.PreferencesPasswordRequired = false;
        dist.PreferencesAllowOriginalDownload = true;
        Database.insert(dist, true, AccessLevel.USER_MODE);

        ContentDistribution created = [
            SELECT DistributionPublicUrl, ContentDownloadUrl
            FROM ContentDistribution WHERE Id = :dist.Id
            WITH USER_MODE
        ];
        return wantPublicUrl ? created.DistributionPublicUrl : created.ContentDownloadUrl;
    }

    // ═════════════════════════════════════════════════════════════════════
    //  TEMPLATES
    // ═════════════════════════════════════════════════════════════════════

    @AuraEnabled
    public static Id saveAsTemplate(Id agreementId, String templateName) {
        Agreement__c agr = [
            SELECT Id, Name, Agreement_Type__c, Signing_Order__c, Message_to_Signers__c
            FROM Agreement__c WHERE Id = :agreementId
            WITH USER_MODE
        ];

        SignForceFLS.requireCreateable(Agreement__c.SObjectType);
        Agreement__c template = new Agreement__c();
        template.Name = templateName;
        template.Agreement_Type__c = agr.Agreement_Type__c;
        template.Signing_Order__c = agr.Signing_Order__c;
        template.Message_to_Signers__c = agr.Message_to_Signers__c;
        template.Status__c = 'Draft';
        template.Is_Template__c = true;
        template.Template_Name__c = templateName;
        template.Storage_Location__c = 'Salesforce';
        Database.insert(template, true, AccessLevel.USER_MODE);

        List<Signer__c> signers = [
            SELECT Name, Email__c, Role__c, Signing_Order__c
            FROM Signer__c WHERE Agreement__c = :agreementId
            WITH USER_MODE
        ];
        List<Signer__c> templateSigners = new List<Signer__c>();
        for (Signer__c s : signers) {
            Signer__c ts = new Signer__c();
            ts.Agreement__c = template.Id;
            ts.Name = s.Name;
            ts.Email__c = s.Email__c;
            ts.Role__c = s.Role__c;
            ts.Signing_Order__c = s.Signing_Order__c;
            ts.Status__c = 'Pending';
            templateSigners.add(ts);
        }
        if (!templateSigners.isEmpty()) {
            SignForceFLS.requireCreateable(Signer__c.SObjectType);
            Database.insert(templateSigners, true, AccessLevel.USER_MODE);
        }

        List<Signature_Field__c> fields = [
            SELECT Field_Type__c, Field_Label__c, Page_Number__c,
                   X_Position__c, Y_Position__c, Width__c, Height__c,
                   Is_Required__c, Page_Width__c, Assigned_Signer__r.Email__c
            FROM Signature_Field__c WHERE Agreement__c = :agreementId
            WITH USER_MODE
        ];

        if (!fields.isEmpty() && !templateSigners.isEmpty()) {
            Map<String, Id> emailToNewSigner = new Map<String, Id>();
            for (Signer__c ts : templateSigners) {
                emailToNewSigner.put(ts.Email__c, ts.Id);
            }

            List<Signature_Field__c> templateFields = new List<Signature_Field__c>();
            for (Signature_Field__c f : fields) {
                Signature_Field__c tf = new Signature_Field__c();
                tf.Agreement__c = template.Id;
                tf.Field_Type__c = f.Field_Type__c;
                tf.Field_Label__c = f.Field_Label__c;
                tf.Page_Number__c = f.Page_Number__c;
                tf.X_Position__c = f.X_Position__c;
                tf.Y_Position__c = f.Y_Position__c;
                tf.Width__c = f.Width__c;
                tf.Height__c = f.Height__c;
                tf.Is_Required__c = f.Is_Required__c;
                tf.Page_Width__c = f.Page_Width__c;
                if (f.Assigned_Signer__r != null && emailToNewSigner.containsKey(f.Assigned_Signer__r.Email__c)) {
                    tf.Assigned_Signer__c = emailToNewSigner.get(f.Assigned_Signer__r.Email__c);
                }
                templateFields.add(tf);
            }
            SignForceFLS.requireCreateable(Signature_Field__c.SObjectType);
            Database.insert(templateFields, true, AccessLevel.USER_MODE);
        }

        AuditTrailService.log(template.Id, 'Template Created', UserInfo.getUserEmail(), null, 'From agreement: ' + agreementId);
        return template.Id;
    }

    @AuraEnabled(cacheable=true)
    public static List<Agreement__c> getTemplates() {
        return [
            SELECT Id, Name, Template_Name__c, Agreement_Type__c, Signing_Order__c, CreatedDate
            FROM Agreement__c
            WHERE Is_Template__c = true
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 50
        ];
    }

    @AuraEnabled
    public static Id createFromTemplate(Id templateId, String newName) {
        Agreement__c template = [
            SELECT Name, Agreement_Type__c, Signing_Order__c, Message_to_Signers__c
            FROM Agreement__c WHERE Id = :templateId AND Is_Template__c = true
            WITH USER_MODE
        ];

        SignForceFLS.requireCreateable(Agreement__c.SObjectType);
        Agreement__c newAgr = new Agreement__c();
        newAgr.Name = String.isNotBlank(newName) ? newName : template.Name;
        newAgr.Agreement_Type__c = template.Agreement_Type__c;
        newAgr.Signing_Order__c = template.Signing_Order__c;
        newAgr.Message_to_Signers__c = template.Message_to_Signers__c;
        newAgr.Status__c = 'Draft';
        newAgr.Storage_Location__c = 'Salesforce';
        Database.insert(newAgr, true, AccessLevel.USER_MODE);

        List<Signer__c> templateSigners = [
            SELECT Name, Email__c, Role__c, Signing_Order__c
            FROM Signer__c WHERE Agreement__c = :templateId
            WITH USER_MODE
        ];
        List<Signer__c> newSigners = new List<Signer__c>();
        for (Signer__c s : templateSigners) {
            Signer__c ns = new Signer__c();
            ns.Agreement__c = newAgr.Id;
            ns.Name = s.Name;
            ns.Email__c = s.Email__c;
            ns.Role__c = s.Role__c;
            ns.Signing_Order__c = s.Signing_Order__c;
            ns.Status__c = 'Pending';
            newSigners.add(ns);
        }
        if (!newSigners.isEmpty()) {
            SignForceFLS.requireCreateable(Signer__c.SObjectType);
            Database.insert(newSigners, true, AccessLevel.USER_MODE);
        }

        List<Signature_Field__c> templateFields = [
            SELECT Field_Type__c, Field_Label__c, Page_Number__c,
                   X_Position__c, Y_Position__c, Width__c, Height__c,
                   Is_Required__c, Page_Width__c, Assigned_Signer__r.Email__c
            FROM Signature_Field__c WHERE Agreement__c = :templateId
            WITH USER_MODE
        ];

        if (!templateFields.isEmpty() && !newSigners.isEmpty()) {
            Map<String, Id> emailToNewSigner = new Map<String, Id>();
            for (Signer__c ns : newSigners) {
                emailToNewSigner.put(ns.Email__c, ns.Id);
            }

            List<Signature_Field__c> newFields = new List<Signature_Field__c>();
            for (Signature_Field__c f : templateFields) {
                Signature_Field__c nf = new Signature_Field__c();
                nf.Agreement__c = newAgr.Id;
                nf.Field_Type__c = f.Field_Type__c;
                nf.Field_Label__c = f.Field_Label__c;
                nf.Page_Number__c = f.Page_Number__c;
                nf.X_Position__c = f.X_Position__c;
                nf.Y_Position__c = f.Y_Position__c;
                nf.Width__c = f.Width__c;
                nf.Height__c = f.Height__c;
                nf.Is_Required__c = f.Is_Required__c;
                nf.Page_Width__c = f.Page_Width__c;
                if (f.Assigned_Signer__r != null && emailToNewSigner.containsKey(f.Assigned_Signer__r.Email__c)) {
                    nf.Assigned_Signer__c = emailToNewSigner.get(f.Assigned_Signer__r.Email__c);
                }
                newFields.add(nf);
            }
            SignForceFLS.requireCreateable(Signature_Field__c.SObjectType);
            Database.insert(newFields, true, AccessLevel.USER_MODE);
        }

        AuditTrailService.log(newAgr.Id, 'Created from Template', UserInfo.getUserEmail(), null, 'Template: ' + templateId);
        return newAgr.Id;
    }

    // ═════════════════════════════════════════════════════════════════════
    //  BULK SEND / IN-PERSON / CONDITIONAL FIELDS
    // ═════════════════════════════════════════════════════════════════════

    @AuraEnabled
    public static Map<String, Object> bulkSend(Id agreementId, String signersJson) {
        Map<String, Object> result = new Map<String, Object>();
        Integer successCount = 0;
        Integer failCount = 0;
        List<String> errors = new List<String>();

        try {
            Agreement__c agr = [
                SELECT Id, Name, Status__c, Signing_Order__c, Message_to_Signers__c, Envelope_ID__c
                FROM Agreement__c WHERE Id = :agreementId
                WITH USER_MODE
            ];

            List<Object> signersList = (List<Object>) JSON.deserializeUntyped(signersJson);
            List<Signer__c> newSigners = new List<Signer__c>();

            for (Object obj : signersList) {
                Map<String, Object> s = (Map<String, Object>) obj;
                String name = (String) s.get('name');
                String email = (String) s.get('email');
                String role = s.containsKey('role') ? (String) s.get('role') : 'Signer';
                Integer order = s.containsKey('order') ? Integer.valueOf(s.get('order')) : newSigners.size() + 1;

                if (String.isBlank(name) || String.isBlank(email)) {
                    failCount++;
                    errors.add('Missing name or email for row ' + (newSigners.size() + failCount));
                    continue;
                }

                Signer__c signer = new Signer__c();
                signer.Agreement__c = agreementId;
                signer.Name = name;
                signer.Email__c = email;
                signer.Role__c = role;
                signer.Signing_Order__c = order;
                signer.Status__c = 'Pending';
                signer.Access_Token__c = AgreementService.generateToken();
                signer.Token_Created_Date__c = DateTime.now();
                signer.Token_View_Count__c = 0;
                signer.Token_Expired__c = false;
                newSigners.add(signer);
                successCount++;
            }

            if (!newSigners.isEmpty()) {
                SignForceFLS.requireCreateable(Signer__c.SObjectType);
                Database.insert(newSigners, true, AccessLevel.USER_MODE);
            }

            result.put('successCount', successCount);
            result.put('failCount', failCount);
            result.put('errors', errors);
            result.put('totalSigners', newSigners.size());

        } catch (Exception e) {
            throw new AuraHandledException('Bulk send failed: ' + e.getMessage());
        }
        return result;
    }

    @AuraEnabled
    public static Map<String, Object> startInPersonSigning(Id signerId) {
        Signer__c signer = [
            SELECT Id, Name, Email__c, Status__c, Agreement__c, Access_Token__c
            FROM Signer__c WHERE Id = :signerId
            WITH USER_MODE
        ];

        if (signer.Status__c == 'Signed') {
            throw new AuraHandledException('This signer has already signed.');
        }

        SignForceFLS.requireUpdateable(Signer__c.SObjectType);
        // The queried record carries Agreement__c, a non-reparentable master-detail.
        // A USER_MODE update refuses any payload containing that field for a
        // non-admin (CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY on Agreement__c), even
        // when its value is unchanged — so the token rotation is written through a
        // minimal record carrying only the fields this method actually changes,
        // the same shape updateFieldCondition uses.
        signer.Access_Token__c = AgreementService.generateToken();
        Signer__c tokenUpdate = new Signer__c(Id = signer.Id);
        tokenUpdate.Access_Token__c = signer.Access_Token__c;
        tokenUpdate.Token_Created_Date__c = DateTime.now();
        tokenUpdate.Token_View_Count__c = 0;
        tokenUpdate.Token_Expired__c = false;
        // Release the single-browser session binding along with the rotation
        // (same as sendReminderEmail): the signer may have opened their emailed
        // link elsewhere, and a held binding would greet the fresh in-person tab
        // with "already open on another browser or device".
        tokenUpdate.Session_Token_Hash__c = null;
        tokenUpdate.Session_Bound_At__c = null;
        // In-person: the host verifies the signer face to face, and the emailed
        // code would land in an inbox the signer may not have on the host's
        // device — pre-clear the OTP gate for this session. Only reachable by an
        // authenticated internal user; sendReminderEmail resets it so a later
        // REMOTE link goes back through OTP.
        tokenUpdate.OTP_Verified__c = true;
        Database.update(tokenUpdate, true, AccessLevel.USER_MODE);

        String baseUrl = SignForceConfigService.getSigningSiteBaseUrl();
        // inperson=1 tells signingViewer to close its tab and notify the opener
        // once the signature lands, so the record page can refresh itself.
        String signingUrl = baseUrl + '/signature?token=' + signer.Access_Token__c + '&inperson=1';

        // Same signing page hosted INSIDE Salesforce, so in-person signing from
        // Lightning runs as the logged-in user instead of the guest site. The
        // component is opened DIRECTLY as a URL-addressable page (/lightning/cmp)
        // — no custom tab involved, so no tab header band and no temp-nav-item
        // resolution. Lightning strips non-namespaced query params — hence c__.
        String objName = SignForce_Config__mdt.SObjectType.getDescribe().getName();
        Integer nsIdx = objName.indexOf('__SignForce_Config__mdt');
        String nsPrefix = nsIdx > -1 ? objName.substring(0, nsIdx + 2) : '';
        String internalUrl = '/lightning/cmp/' + nsPrefix + 'signingViewer'
            + '?c__token=' + signer.Access_Token__c + '&c__inperson=1';

        AuditTrailService.log(signer.Agreement__c, 'In-Person Signing Started', signer.Email__c, null, null);

        Map<String, Object> result = new Map<String, Object>();
        result.put('signingUrl', signingUrl);
        result.put('internalUrl', internalUrl);
        // For NavigationMixin.GenerateUrl on the client (standard__component).
        result.put('internalCmpName', nsPrefix + 'signingViewer');
        result.put('signerName', signer.Name);
        result.put('signerEmail', signer.Email__c);
        result.put('token', signer.Access_Token__c);
        return result;
    }

    @AuraEnabled
    public static void updateFieldCondition(Id fieldId, String conditionType, Id conditionFieldId, String conditionValue) {
        SignForceFLS.requireUpdateable(Signature_Field__c.SObjectType);
        Signature_Field__c field = new Signature_Field__c(Id = fieldId);
        field.Condition_Type__c = conditionType;
        field.Condition_Field__c = conditionFieldId;
        field.Condition_Value__c = conditionValue;
        Database.update(field, true, AccessLevel.USER_MODE);
    }

    @AuraEnabled
    public static List<Map<String, Object>> getFieldsWithConditions(Id signerId) {
        Signer__c signer = [
            SELECT Agreement__c FROM Signer__c WHERE Id = :signerId
            WITH USER_MODE
            LIMIT 1
        ];

        List<Signature_Field__c> fields = [
            SELECT Id, Field_Type__c, Field_Label__c, Page_Number__c,
                   X_Position__c, Y_Position__c, Width__c, Height__c,
                   Is_Required__c, Is_Completed__c, Field_Value__c, Page_Width__c,
                   Condition_Type__c, Condition_Field__c, Condition_Value__c
            FROM Signature_Field__c
            WHERE Agreement__c = :signer.Agreement__c
            AND Assigned_Signer__c = :signerId
            WITH USER_MODE
            ORDER BY Page_Number__c ASC, Y_Position__c ASC
        ];

        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (Signature_Field__c f : fields) {
            Map<String, Object> fm = new Map<String, Object>();
            fm.put('Id', f.Id);
            fm.put('Field_Type__c', f.Field_Type__c);
            fm.put('Field_Label__c', f.Field_Label__c);
            fm.put('Page_Number__c', f.Page_Number__c);
            fm.put('X_Position__c', f.X_Position__c);
            fm.put('Y_Position__c', f.Y_Position__c);
            fm.put('Width__c', f.Width__c);
            fm.put('Height__c', f.Height__c);
            fm.put('Is_Required__c', f.Is_Required__c);
            fm.put('Is_Completed__c', f.Is_Completed__c);
            fm.put('Field_Value__c', f.Field_Value__c);
            fm.put('Page_Width__c', f.Page_Width__c);
            fm.put('conditionType', f.Condition_Type__c != null ? f.Condition_Type__c : 'None');
            fm.put('conditionFieldId', f.Condition_Field__c);
            fm.put('conditionValue', f.Condition_Value__c != null ? f.Condition_Value__c : '');
            result.add(fm);
        }
        return result;
    }

    // ═════════════════════════════════════════════════════════════════════
    //  DEPRECATED
    // ═════════════════════════════════════════════════════════════════════

    @AuraEnabled
    public static List<Signature_Field__c> getFieldsForSigner(Id signerId) {
        throw new AuraHandledException('This endpoint has been replaced. Please refresh the page.');
    }

    @AuraEnabled
    public static void saveFieldValues(String fieldValuesJson) {
        throw new AuraHandledException('This endpoint has been replaced. Please refresh the page.');
    }

    @AuraEnabled
    public static String getAgreementDocumentVersion(Id agreementId) {
        throw new AuraHandledException('This endpoint has been replaced. Please refresh the page.');
    }

    @AuraEnabled
    public static String getDocumentVersionForGuest(Id agreementId) {
        throw new AuraHandledException('This endpoint has been replaced. Please refresh the page.');
    }

    @AuraEnabled
    public static Map<String, Object> getDocumentForSigning(Id agreementId) {
        throw new AuraHandledException('This endpoint has been replaced. Please refresh the page.');
    }

    @future(callout=true)
    public static void generateStampedPDFServerAsync(Id agreementId) {
        generateStampedPDFServerInternal(agreementId);

        // The final stamp now exists, so the per-signature intermediates it
        // supersedes can go — but NOT from here. This runs as whoever signed, and
        // for a guest signature that is the Site Guest User, which cannot delete a
        // ContentDocument it does not own (measured: 0 removed as guest, 1 as
        // admin, same call). Publishing an event hands the work to
        // SignForceFileCleanupTrigger, which the platform runs as the Automated
        // Process user, and publishing is something the guest CAN do.
        //
        // Fire-and-forget on purpose: the final stamp is already saved above, so a
        // cleanup that never runs costs extra rows in the Files panel, nothing more.
        try {
            EventBus.publish(new SignForce_File_Cleanup__e(
                Agreement_Id__c = String.valueOf(agreementId)
            ));
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'File cleanup event not published: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> searchExistingSigners(String searchTerm) {
        if (String.isBlank(searchTerm) || searchTerm.length() < 2) {
            return new List<Map<String, Object>>();
        }
        String likePattern = '%' + String.escapeSingleQuotes(searchTerm) + '%';

        Map<String, Map<String, Object>> uniqueByEmail = new Map<String, Map<String, Object>>();

        for (Signer__c s : [
            SELECT Name, Email__c, Role__c, CreatedDate
            FROM Signer__c
            WHERE Email__c != null
            AND (Name LIKE :likePattern OR Email__c LIKE :likePattern)
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 100
        ]) {
            String emailKey = s.Email__c.toLowerCase();
            if (!uniqueByEmail.containsKey(emailKey)) {
                uniqueByEmail.put(emailKey, new Map<String, Object>{
                    'name'   => s.Name,
                    'email'  => s.Email__c,
                    'role'   => String.isBlank(s.Role__c) ? 'Signer' : s.Role__c,
                    'source' => 'Past Signer'
                });
            }
        }

        for (Contact c : [
            SELECT Name, Email, Title
            FROM Contact
            WHERE Email != null
            AND (Name LIKE :likePattern OR Email LIKE :likePattern)
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 50
        ]) {
            String emailKey = c.Email.toLowerCase();
            if (!uniqueByEmail.containsKey(emailKey)) {
                uniqueByEmail.put(emailKey, new Map<String, Object>{
                    'name'   => c.Name,
                    'email'  => c.Email,
                    'role'   => 'Signer',
                    'source' => 'Contact'
                });
            }
        }

        for (Lead l : [
            SELECT Name, Email, Title
            FROM Lead
            WHERE Email != null
            AND IsConverted = false
            AND (Name LIKE :likePattern OR Email LIKE :likePattern)
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 50
        ]) {
            String emailKey = l.Email.toLowerCase();
            if (!uniqueByEmail.containsKey(emailKey)) {
                uniqueByEmail.put(emailKey, new Map<String, Object>{
                    'name'   => l.Name,
                    'email'  => l.Email,
                    'role'   => 'Signer',
                    'source' => 'Lead'
                });
            }
        }

        List<Map<String, Object>> results = new List<Map<String, Object>>(uniqueByEmail.values());
        if (results.size() > 20) {
            List<Map<String, Object>> trimmed = new List<Map<String, Object>>();
            for (Integer i = 0; i < 20; i++) trimmed.add(results[i]);
            return trimmed;
        }
        return results;
    }

    // Custom exception for stamping errors (works in @future context)
    public class SignForceStampException extends Exception {}
}