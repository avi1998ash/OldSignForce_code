/**
 * GuestSigningApiInternal - the INTERNAL-user half of the data-access helpers that used to live in
 * GuestSigningApi.
 *
 * Called only by INTERNAL-user Apex: PDFPreviewController (internal branch), StampedAgreementPDFController
 * and SignedDocumentPDFController. GuestSigningApi (guest, `without sharing`) is no longer called by
 * those classes.
 *
 * SHARING: `with sharing`. Internal users run under their own record access (Agreement__c is Public
 * Read/Write internally and its children are controlled by parent). The guest copies of the shared
 * helpers stay in GuestSigningApi, which is `without sharing` because the Site Guest User has no sharing.
 *
 *   MOVED from GuestSigningApi (internal-only, no guest caller): sdAgreement, sdOriginalDoc,
 *     sdContentVersion, sdFields (SignedDocumentPDF page); stAgreement, stSigners, stSignatureField,
 *     stValueFields (StampedAgreementPDF page).
 *   COPIED (GuestSigningApi keeps its own, still used by guest code): pdfBase64, pdfDistributionUrl,
 *     pdfInfo, pdfCreateDistributionUrl, pdfChunk (+ private getOrCreateContentDistributionUrl) and the
 *     shared helpers savedSignatureFor, auditRowsFor, orgTimeZone, userName.
 *
 * Method bodies are verbatim copies; nothing else was changed.
 */
public with sharing class GuestSigningApiInternal {

    // PDFPreview page data access (called from PDFPreviewController's @RemoteAction methods when the
    // running user is NOT a guest).

    public static String pdfBase64(String contentVersionId) {
        ContentVersion cv = [
            SELECT Id, VersionData FROM ContentVersion
            WHERE Id = :contentVersionId LIMIT 1
        ];
        return EncodingUtil.base64Encode(cv.VersionData);
    }

    public static String pdfDistributionUrl(String contentVersionId) {
        List<ContentDistribution> dists = [
            SELECT ContentDownloadUrl FROM ContentDistribution
            WHERE ContentVersionId = :contentVersionId LIMIT 1
        ];
        return dists.isEmpty() ? null : dists[0].ContentDownloadUrl;
    }

    public static Map<String, Object> pdfInfo(String contentVersionId) {
        ContentVersion cv = [
            SELECT ContentSize, FileType, ContentDocumentId
            FROM ContentVersion WHERE Id = :contentVersionId LIMIT 1
        ];
        Integer chunkSize = 3000000;
        Map<String, Object> info = new Map<String, Object>();
        info.put('size', cv.ContentSize);
        info.put('fileType', cv.FileType);
        info.put('totalChunks', (Integer) Math.ceil((Decimal) cv.ContentSize / chunkSize));
        info.put('chunkSize', chunkSize);
        if (cv.ContentSize > 4500000) {
            info.put('distributionUrl', pdfCreateDistributionUrl(contentVersionId));
        }
        return info;
    }

    public static String pdfCreateDistributionUrl(String contentVersionId) {
        try {
            return getOrCreateContentDistributionUrl((Id) contentVersionId, 'PDFPreview-');
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'PDFPreview: ContentDistribution failed: ' + e.getMessage());
            return null;
        }
    }

    public static String pdfChunk(String contentVersionId, Integer chunkIndex) {
        ContentVersion cv = [
            SELECT VersionData FROM ContentVersion
            WHERE Id = :contentVersionId LIMIT 1
        ];
        Blob fullData = cv.VersionData;
        Integer chunkSize = 3000000;
        Integer startByte = chunkIndex * chunkSize;
        Integer endByte = Math.min(startByte + chunkSize, fullData.size());
        if (startByte >= fullData.size()) return '';
        String fullBase64 = EncodingUtil.base64Encode(fullData);
        Integer b64Start = (startByte / 3) * 4;
        Integer b64End = Math.min((Integer) Math.ceil((Decimal) endByte / 3) * 4, fullBase64.length());
        return fullBase64.substring(b64Start, b64End);
    }

    // Private helper used by pdfCreateDistributionUrl.
    private static String getOrCreateContentDistributionUrl(Id cvId, String namePrefix) {
        List<ContentDistribution> existing = [
            SELECT ContentDownloadUrl FROM ContentDistribution
            WHERE ContentVersionId = :cvId LIMIT 1
        ];
        if (!existing.isEmpty()) {
            return existing[0].ContentDownloadUrl;
        }

        ContentDistribution dist = new ContentDistribution();
        dist.Name = namePrefix + cvId;
        dist.ContentVersionId = cvId;
        dist.PreferencesAllowViewInBrowser = true;
        dist.PreferencesLinkLatestVersion = false;
        dist.PreferencesNotifyOnVisit = false;
        dist.PreferencesPasswordRequired = false;
        dist.PreferencesAllowOriginalDownload = true;
        insert dist;

        ContentDistribution created = [
            SELECT ContentDownloadUrl FROM ContentDistribution WHERE Id = :dist.Id
        ];
        return created.ContentDownloadUrl;
    }

    // Shared by the PDF-rendering controllers (copies of the GuestSigningApi helpers).

    /** Saved signature for a signer's email. Shared by all PDF controllers. */
    public static List<Saved_Signature__c> savedSignatureFor(String email) {
        return [
            SELECT Signature_Data__c, Signature_Type__c, Font_Family__c
            FROM Saved_Signature__c WHERE Email__c = :email LIMIT 1
        ];
    }

    /** Audit-trail rows for an agreement. Shared by the PDF controllers. */
    public static List<Signing_Event__c> auditRowsFor(Id agreementId) {
        return [
            SELECT Action__c, Signer_Email__c, Event_Timestamp__c, IP_Address__c
            FROM Signing_Event__c WHERE Agreement__c = :agreementId
            ORDER BY Event_Timestamp__c ASC
        ];
    }

    /** Org time zone. */
    public static String orgTimeZone() {
        return [SELECT TimeZoneSidKey FROM Organization LIMIT 1].TimeZoneSidKey;
    }

    /** Display name of a user (the agreement's creator). */
    public static List<User> userName(Id userId) {
        return [SELECT Name FROM User WHERE Id = :userId LIMIT 1];
    }

    // ── SignedDocumentPDF / StampedAgreementPDF pages (moved from GuestSigningApi) ──

    public static Agreement__c sdAgreement(Id agreementId) {
        return [SELECT Id, Envelope_ID__c FROM Agreement__c WHERE Id = :agreementId];
    }

    public static List<Agreement_Document__c> sdOriginalDoc(Id agreementId) {
        return [
            SELECT Content_Version_ID__c FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId AND Document_Type__c = 'Original'
            LIMIT 1
        ];
    }

    public static ContentVersion sdContentVersion(Id contentVersionId) {
        return [SELECT Id, VersionData FROM ContentVersion WHERE Id = :contentVersionId];
    }

    public static List<Signature_Field__c> sdFields(Id agreementId) {
        return [
            SELECT Id, Field_Type__c, Field_Value__c, Page_Number__c,
                   X_Position__c, Y_Position__c, Width__c, Height__c,
                   Page_Width__c, Is_Completed__c, Assigned_Signer__c,
                   Assigned_Signer__r.Name, Assigned_Signer__r.Email__c,
                   Assigned_Signer__r.Signature_Certificate_ID__c,
                   Assigned_Signer__r.Signed_Date__c
            FROM Signature_Field__c
            WHERE Agreement__c = :agreementId
            ORDER BY Page_Number__c ASC
        ];
    }

    public static Agreement__c stAgreement(Id agreementId) {
        return [
            SELECT Id, Name, Agreement_Type__c, Status__c,
                   Completed_Date__c, Envelope_ID__c,
                   CreatedById, Owner.Name
            FROM Agreement__c WHERE Id = :agreementId
        ];
    }

    public static List<Signer__c> stSigners(Id agreementId) {
        return [
            SELECT Id, Name, Email__c, Role__c, Status__c,
                   Signed_Date__c, Signature_Certificate_ID__c,
                   Signing_IP_Address__c, Signing_Order__c
            FROM Signer__c
            WHERE Agreement__c = :agreementId
            ORDER BY Signing_Order__c ASC NULLS LAST
        ];
    }

    public static List<Signature_Field__c> stSignatureField(Id agreementId, Id signerId) {
        return [
            SELECT Field_Value__c, Field_Type__c
            FROM Signature_Field__c
            WHERE Agreement__c = :agreementId
              AND Assigned_Signer__c = :signerId
              AND Field_Type__c IN ('Signature', 'Initial')
              AND Is_Completed__c = true
            LIMIT 1
        ];
    }

    public static List<Signature_Field__c> stValueFields(Id agreementId) {
        return [
            SELECT Field_Label__c, Field_Type__c, Field_Value__c
            FROM Signature_Field__c
            WHERE Agreement__c = :agreementId
              AND Is_Completed__c = true
              AND Field_Type__c NOT IN ('Signature', 'Initial')
            ORDER BY Page_Number__c ASC, Y_Position__c ASC
        ];
    }
}
