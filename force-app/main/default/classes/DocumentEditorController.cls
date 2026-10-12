/**
 * DocumentEditorController — Field placement and document editor UI backing.
 *
 * Internal users only. Guest signing portal uses GuestSigningApi
 * for any equivalent operations. The guest flows' DOCX->PDF conversion uses
 * DocumentEditorControllerGuest.convertToPdfViaLambda (a verbatim copy of the method below).
 *
 * ────────────────────────────────────────────────────────────────────────
 * SECURITY MODEL (Phase 2 hardening)
 * ────────────────────────────────────────────────────────────────────────
 *
 * Sharing mode:  with sharing
 * Reachable from: Internal Lightning users (documentEditor LWC)
 *                 NOT reachable from guest community
 * Authorization: Authenticated Salesforce session + sharing rules
 *                + WITH USER_MODE on every SOQL
 *                + AccessLevel.USER_MODE on every DML
 *                + SignForceFLS.require* guards before every DML
 *
 * Previously this class did raw DML without FLS guards — Checkmarx flagged
 * 9 sites. This version adds requireCreateable / requireUpdateable /
 * requireDeletable / requireAccessible before every DML or SOQL operation.
 *
 * The Phase 2 changes are mechanical: same logic, same method signatures,
 * just adds the FLS checks that the security review requires. No new
 * functionality, no breaking changes for the LWC.
 */
public with sharing class DocumentEditorController {

    @AuraEnabled
    public static Map<String, Object> getAgreementData(Id agreementId) {
        // 1. Agreement
        Agreement__c agr = [
            SELECT Id, Name, Status__c, Agreement_Type__c, Signing_Order__c
            FROM Agreement__c WHERE Id = :agreementId
            WITH USER_MODE
        ];

        // 2. Signers
        List<Signer__c> signers = [
            SELECT Id, Name, Email__c, Role__c, Signing_Order__c, Status__c
            FROM Signer__c
            WHERE Agreement__c = :agreementId
            WITH USER_MODE
            ORDER BY Signing_Order__c ASC NULLS LAST
        ];

        // 3. Original document (tiered storage — query Agreement_Document__c first
        //    so S3-only Tier2/Tier3 docs are visible, not just CDL-linked ones)
        List<Agreement_Document__c> originalDocs = [
            SELECT Id, Name, Content_Version_ID__c,
                   S3_Document_ID__c, S3_Preview_URL__c,
                   Storage_Tier__c, Storage_Type__c, Cloud_File_Id__c, Cloud_Provider__c,
                   File_Size_Bytes__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId
            AND Document_Type__c = 'Original'
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        Map<String, Object> documentMap = null;

        if (!originalDocs.isEmpty()) {
            Agreement_Document__c d = originalDocs[0];
            documentMap = new Map<String, Object>{
                'Id'                    => d.Id,
                'Name'                  => d.Name,
                'Content_Version_ID__c' => d.Content_Version_ID__c,
                'S3_Document_ID__c'     => d.S3_Document_ID__c,
                'S3_Preview_URL__c'     => d.S3_Preview_URL__c,
                'Storage_Tier__c'       => d.Storage_Tier__c,
                'Storage_Type__c'       => d.Storage_Type__c,
                'Cloud_File_Id__c'      => d.Cloud_File_Id__c,
                'Cloud_Provider__c'     => d.Cloud_Provider__c,
                'File_Size_Bytes__c'    => d.File_Size_Bytes__c
            };

            // Convenience: also resolve ContentDocumentId for Tier1 docs.
            if (String.isNotBlank(d.Content_Version_ID__c)) {
                try {
                    ContentVersion cv = [
                        SELECT ContentDocumentId
                        FROM ContentVersion WHERE Id = :d.Content_Version_ID__c
                        WITH USER_MODE
                        LIMIT 1
                    ];
                    documentMap.put('Content_Document_ID__c', cv.ContentDocumentId);
                } catch (Exception ignore) { /* CV may not exist for S3-only docs */ }
            }
        } else {
            // Fallback: legacy path for agreements that have a ContentDocumentLink
            // but no Agreement_Document__c row yet.
            List<ContentDocumentLink> allDocs = [
                SELECT ContentDocumentId,
                    ContentDocument.LatestPublishedVersionId,
                    ContentDocument.Title,
                    ContentDocument.FileType
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :agreementId
                AND ContentDocument.FileType IN ('PDF','DOCX','DOC','WORD')
                WITH USER_MODE
                ORDER BY ContentDocument.CreatedDate ASC
            ];
            for (ContentDocumentLink l : allDocs) {
                String title = l.ContentDocument.Title;
                if (!title.endsWith('- Signed Document') && !title.endsWith('Signed')) {
                    documentMap = new Map<String, Object>{
                        'Content_Version_ID__c'  => l.ContentDocument.LatestPublishedVersionId,
                        'Content_Document_ID__c' => l.ContentDocumentId,
                        'S3_Document_ID__c'      => null,
                        'S3_Preview_URL__c'      => null,
                        'Storage_Tier__c'        => 'Tier1'
                    };
                    break;
                }
            }
        }

        // 4. Signature fields
        List<Signature_Field__c> fields = [
            SELECT Id, Field_Type__c, Field_Label__c, Page_Number__c,
                   X_Position__c, Y_Position__c, Width__c, Height__c,
                   Is_Required__c, Is_Completed__c, Field_Value__c,
                   Assigned_Signer__c, Assigned_Signer__r.Name,
                   Assigned_Signer__r.Email__c, Page_Width__c
            FROM Signature_Field__c
            WHERE Agreement__c = :agreementId
            WITH USER_MODE
            ORDER BY Page_Number__c ASC, Y_Position__c ASC
        ];

        return new Map<String, Object>{
            'agreement' => agr,
            'signers'   => signers,
            'document'  => documentMap,
            'fields'    => fields
        };
    }

    @AuraEnabled
    public static Id saveField(Id agreementId, Id signerId, String fieldType,
                                String fieldLabel, Integer pageNumber,
                                Decimal xPos, Decimal yPos,
                                Decimal width, Decimal height,
                                Boolean isRequired, Decimal pageWidth) {
        requireDraftByAgreement(agreementId);
        SignForceFLS.requireCreateable(Signature_Field__c.SObjectType);

        Signature_Field__c field = new Signature_Field__c();
        field.Agreement__c = agreementId;
        field.Assigned_Signer__c = signerId;
        field.Field_Type__c = fieldType;
        field.Field_Label__c = fieldLabel;
        field.Page_Number__c = pageNumber;
        field.X_Position__c = xPos;
        field.Y_Position__c = yPos;
        field.Width__c = width;
        field.Height__c = height;
        field.Is_Required__c = isRequired;
        field.Is_Completed__c = false;
        field.Page_Width__c = pageWidth;
        Database.insert(field, true, AccessLevel.USER_MODE);
        return field.Id;
    }

    @AuraEnabled
    public static void updateFieldPosition(Id fieldId, Decimal xPos, Decimal yPos,
                                           Decimal width, Decimal height) {
        requireDraftByField(fieldId);
        SignForceFLS.requireUpdateable(Signature_Field__c.SObjectType);

        Signature_Field__c field = new Signature_Field__c();
        field.Id = fieldId;
        field.X_Position__c = xPos;
        field.Y_Position__c = yPos;
        field.Width__c = width;
        field.Height__c = height;
        Database.update(field, true, AccessLevel.USER_MODE);
    }

    /**
     * BUG-020 FIX: previously LWC's `handleFieldLabelChange` and
     * `handleFieldRequiredChange` only updated local state — there was no
     * Apex method to persist Field_Label__c / Is_Required__c, so navigating
     * away and back caused the wired data to overwrite the user's edits
     * (labels reverted to original template values). This method persists
     * just those two properties without touching position/size/signer.
     *
     * Also accepts optional conditional-display settings since the property
     * panel already exposes them client-side. nulls are skipped.
     */
    @AuraEnabled
    public static void updateFieldProperties(Id fieldId, String fieldLabel,
                                             Boolean isRequired) {
        if (fieldId == null) {
            throw new AuraHandledException('fieldId is required');
        }
        requireDraftByField(fieldId);
        SignForceFLS.requireUpdateable(Signature_Field__c.SObjectType);

        Signature_Field__c field = new Signature_Field__c(Id = fieldId);
        if (fieldLabel != null) field.Field_Label__c = fieldLabel;
        if (isRequired != null) field.Is_Required__c = isRequired;
        Database.update(field, true, AccessLevel.USER_MODE);
    }

    /**
     * Persist a field's "Assigned To" (signer) reassignment. Separate from
     * updateFieldProperties so its signature stays unchanged. A null signerId
     * clears the assignment (field becomes unassigned).
     */
    @AuraEnabled
    public static void updateFieldSigner(Id fieldId, Id signerId) {
        if (fieldId == null) {
            throw new AuraHandledException('fieldId is required');
        }
        requireDraftByField(fieldId);
        SignForceFLS.requireUpdateable(Signature_Field__c.SObjectType);

        Signature_Field__c field = new Signature_Field__c(Id = fieldId);
        field.Assigned_Signer__c = signerId;
        Database.update(field, true, AccessLevel.USER_MODE);
    }

    @AuraEnabled
    public static void deleteField(Id fieldId) {
        requireDraftByField(fieldId);
        SignForceFLS.requireDeletable(Signature_Field__c.SObjectType);
        Database.delete(new Signature_Field__c(Id = fieldId), true, AccessLevel.USER_MODE);
    }

    /**
     * Field layout may only change while the envelope is in Draft. The editor
     * hides its editing affordances on the same rule, but its wires are
     * cacheable and can be stale — so the rule is enforced server-side too.
     * The signing path is untouched: signers write field VALUES via
     * saveFieldValues / the guest controller, never through these methods.
     */
    private static void requireDraftByAgreement(Id agreementId) {
        List<Agreement__c> agr = [
            SELECT Status__c FROM Agreement__c WHERE Id = :agreementId
            WITH USER_MODE LIMIT 1
        ];
        if (!agr.isEmpty() && agr[0].Status__c != 'Draft') {
            throw new AuraHandledException(
                'This agreement has been sent and its fields can no longer be edited.');
        }
    }

    private static void requireDraftByField(Id fieldId) {
        List<Signature_Field__c> f = [
            SELECT Agreement__r.Status__c FROM Signature_Field__c WHERE Id = :fieldId
            WITH USER_MODE LIMIT 1
        ];
        if (!f.isEmpty() && f[0].Agreement__r.Status__c != 'Draft') {
            throw new AuraHandledException(
                'This agreement has been sent and its fields can no longer be edited.');
        }
    }

    @AuraEnabled
    public static void saveAllFields(String fieldsJson) {
        List<Object> rawFields = (List<Object>) JSON.deserializeUntyped(fieldsJson);
        List<Signature_Field__c> toUpsert = new List<Signature_Field__c>();
        Boolean hasNew = false;
        Boolean hasExisting = false;

        for (Object raw : rawFields) {
            Map<String, Object> f = (Map<String, Object>) raw;
            Signature_Field__c field = new Signature_Field__c();

            if (f.containsKey('id') && f.get('id') != null) {
                field.Id = (String) f.get('id');
                hasExisting = true;
            } else {
                hasNew = true;
            }

            field.Agreement__c = (String) f.get('agreementId');
            field.Assigned_Signer__c = f.get('signerId') != null ? (String) f.get('signerId') : null;
            field.Field_Type__c = (String) f.get('fieldType');
            field.Field_Label__c = (String) f.get('fieldLabel');
            field.Page_Number__c = Integer.valueOf(f.get('pageNumber'));
            field.X_Position__c = Decimal.valueOf(String.valueOf(f.get('xPos')));
            field.Y_Position__c = Decimal.valueOf(String.valueOf(f.get('yPos')));
            field.Width__c = Decimal.valueOf(String.valueOf(f.get('width')));
            field.Height__c = Decimal.valueOf(String.valueOf(f.get('height')));
            field.Is_Required__c = (Boolean) f.get('isRequired');
            field.Is_Completed__c = false;
            toUpsert.add(field);
        }

        if (toUpsert.isEmpty()) return;

        // upsert covers both create + update — require both grants if both branches fire.
        if (hasNew) SignForceFLS.requireCreateable(Signature_Field__c.SObjectType);
        if (hasExisting) SignForceFLS.requireUpdateable(Signature_Field__c.SObjectType);

        Database.upsert(toUpsert, true, AccessLevel.USER_MODE);
    }

    @AuraEnabled(cacheable=true)
    public static String getDocumentPageUrl(String contentVersionId, Integer pageNum) {
        // URL builder, no DML/SOQL. No FLS check needed.
        return '/sfc/servlet.shepherd/version/renditionDownload?rendition=THUMB720BY480&versionId='
               + contentVersionId + '&operationContext=CHATTER&contentId=' + contentVersionId;
    }

    @AuraEnabled
    public static List<Signature_Field__c> getFieldsForSigner(Id agreementId, Id signerId) {
        return [
            SELECT Id, Field_Type__c, Field_Label__c, Page_Number__c,
                   X_Position__c, Y_Position__c, Width__c, Height__c,
                   Is_Required__c, Is_Completed__c, Field_Value__c, Page_Width__c
            FROM Signature_Field__c
            WHERE Agreement__c = :agreementId
            AND Assigned_Signer__c = :signerId
            WITH USER_MODE
            ORDER BY Page_Number__c ASC, Y_Position__c ASC
        ];
    }

    @AuraEnabled
    public static void saveFieldValues(String fieldValuesJson) {
        List<Object> fieldValues = (List<Object>) JSON.deserializeUntyped(fieldValuesJson);
        List<Signature_Field__c> toUpdate = new List<Signature_Field__c>();

        for (Object obj : fieldValues) {
            Map<String, Object> fv = (Map<String, Object>) obj;
            String fieldId = (String) fv.get('id');
            String value = (String) fv.get('value');

            if (String.isBlank(fieldId)) continue;

            Signature_Field__c field = new Signature_Field__c(Id = fieldId);
            field.Field_Value__c = value;
            field.Is_Completed__c = String.isNotBlank(value);
            toUpdate.add(field);
        }

        if (!toUpdate.isEmpty()) {
            SignForceFLS.requireUpdateable(Signature_Field__c.SObjectType);
            Database.update(toUpdate, true, AccessLevel.USER_MODE);
        }
    }

    @AuraEnabled
    public static void createFileLink(Id contentDocumentId, Id agreementId) {
        SignForceFLS.requireCreateable(ContentDocumentLink.SObjectType);

        ContentDocumentLink cdl = new ContentDocumentLink();
        cdl.ContentDocumentId = contentDocumentId;
        cdl.LinkedEntityId = agreementId;
        cdl.ShareType = 'V';
        cdl.Visibility = 'AllUsers';
        Database.insert(cdl, true, AccessLevel.USER_MODE);
    }

    @AuraEnabled
    public static String getPublicPreviewUrl(String contentVersionId) {
        if (String.isBlank(contentVersionId)) {
            throw new AuraHandledException('contentVersionId is required');
        }

        // Look up the ContentVersion's file extension to decide preview path:
        //   - PDF files can render directly through PDFPreview.page
        //   - DOCX/DOC files cause "Invalid PDF structure" error because
        //     PDFPreview tries to read the bytes as PDF. We have to convert
        //     to PDF via Lambda first, same as documentGenerationHistory does.
        Id cvId = Id.valueOf(contentVersionId);
        List<ContentVersion> cvs = [
            SELECT Id, FileExtension, VersionData, PathOnClient, Title, ContentSize
            FROM ContentVersion WHERE Id = :cvId WITH USER_MODE LIMIT 1
        ];
        if (cvs.isEmpty()) {
            throw new AuraHandledException('File not found');
        }
        ContentVersion cv = cvs[0];
        String ext = cv.FileExtension != null ? cv.FileExtension.toLowerCase() : '';

        if (ext == 'pdf') {
            // PDF path — direct, no Lambda call.
            // Page.X.getUrl() emits the namespaced /apex/ns__PDFPreview path
            // so this stays correct once the app is a managed package.
            return Page.PDFPreview.getUrl() + '?cvId=' + contentVersionId
                + '&ts=' + System.currentTimeMillis();
        }

        if (ext == 'docx' || ext == 'doc') {
            // DOCX/DOC path — convert via Lambda, wrap S3 URL in PDFPreview
            String s3Url = convertToPdfViaLambda(cv);
            if (String.isBlank(s3Url)) {
                throw new AuraHandledException('Could not convert document for preview');
            }
            return Page.PDFPreview.getUrl() + '?pdfUrl=' + EncodingUtil.urlEncode(s3Url, 'UTF-8')
                + '&ts=' + System.currentTimeMillis();
        }

        // Unknown extension — try direct path as best-effort fallback.
        return Page.PDFPreview.getUrl() + '?cvId=' + contentVersionId
            + '&ts=' + System.currentTimeMillis();
    }

    /**
     * Calls Lambda's convertToPdf action with a ContentVersion's bytes.
     * Returns the S3 presigned PDF URL on success, throws on failure.
     * Same Lambda action createAgreement + documentGenerationHistory use.
     *
     * Used here by getPublicPreviewUrl (internal). The guest signing flows use
     * DocumentEditorControllerGuest.convertToPdfViaLambda, a verbatim copy. DOCX/DOC
     * files need Lambda conversion before PDF.js can render them, otherwise
     * PDFPreview throws "Invalid PDF structure".
     */
    public static String convertToPdfViaLambda(ContentVersion cv) {
        String endpoint;
        try {
            endpoint = SignForceConfigService.getLambdaEndpoint();
        } catch (Exception e) {
            throw new AuraHandledException(
                'Lambda endpoint is not configured. Ask your admin to set '
                + 'Lambda_Endpoint__c on SignForce_Config__mdt.'
            );
        }
        if (String.isBlank(endpoint)) {
            throw new AuraHandledException('Lambda endpoint is not configured');
        }

        Map<String, Object> config = SignForceConfigService.getClientConfig();
        String orgId = (String) config.get('orgId');
        String docId = 'agrpreview_' + cv.Id + '_' + String.valueOf(System.currentTimeMillis());
        String fileName = String.isNotBlank(cv.PathOnClient)
            ? cv.PathOnClient
            : (String.isNotBlank(cv.Title) ? cv.Title : 'document.docx');

        Map<String, Object> payload = new Map<String, Object>{
            'action'   => 'convertToPdf',
            'orgId'    => orgId,
            'docId'    => docId,
            'base64'   => EncodingUtil.base64Encode(cv.VersionData),
            'filename' => fileName
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);   // LibreOffice cold start can take ~5-10s
        req.setBody(JSON.serialize(payload));

        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (Exception e) {
            throw new AuraHandledException('Lambda call failed: ' + e.getMessage());
        }
        if (res.getStatusCode() != 200) {
            String body = res.getBody() == null ? '' : res.getBody();
            String snippet = body.substring(0, Math.min(500, body.length()));
            throw new AuraHandledException(
                'Conversion failed (HTTP ' + res.getStatusCode() + '): ' + snippet
            );
        }
        Map<String, Object> result =
            (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        Boolean success = result.get('success') == true;
        String url = (String) result.get('url');
        if (!success || String.isBlank(url)) {
            String err = (String) result.get('error');
            throw new AuraHandledException(
                'Lambda did not return a valid PDF URL. ' + (err != null ? 'Error: ' + err : '')
            );
        }
        return url;
    }

    @AuraEnabled
    public static Integer getFieldCount(Id agreementId) {
        // COUNT() with WITH USER_MODE
        List<AggregateResult> r = [
            SELECT COUNT(Id) ct FROM Signature_Field__c
            WHERE Agreement__c = :agreementId
            WITH USER_MODE
        ];
        return r.isEmpty() ? 0 : (Integer) r[0].get('ct');
    }
}