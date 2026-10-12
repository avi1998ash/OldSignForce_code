/**
 * @description : DocumentService - Document Upload & Management
 * @author      : SignForce
**/
public with sharing class DocumentService {

    @AuraEnabled
    public static void linkDocumentToAgreement(Id agreementId, Id contentDocumentId, String documentType) {
        ContentVersion cv = [
            SELECT Id, Title, FileType, ContentSize, ContentDocumentId
            FROM ContentVersion
            WHERE ContentDocumentId = :contentDocumentId
            WITH USER_MODE
            ORDER BY CreatedDate DESC LIMIT 1
        ];

        // Mirror the reuse logic in AgreementController.createAgreementDocumentS3:
        // a Draft re-upload/replace of the Original must not leave the OLD
        // Original (and its stale public URL) behind. Purge any prior 'Original'
        // for this agreement before inserting the new one. Scope the cleanup to
        // Draft agreements only — matching the upload gating — so we never delete
        // the Original of an already-sent/completed agreement.
        if (documentType == 'Original') {
            Boolean isDraft = [
                SELECT Status__c FROM Agreement__c WHERE Id = :agreementId WITH USER_MODE LIMIT 1
            ].Status__c == 'Draft';
            if (isDraft) {
                List<Agreement_Document__c> priorOriginals = [
                    SELECT Id FROM Agreement_Document__c
                    WHERE Agreement__c = :agreementId
                    AND Document_Type__c = 'Original'
                    WITH USER_MODE
                ];
                if (!priorOriginals.isEmpty()) {
                    Database.delete(priorOriginals, true, AccessLevel.USER_MODE);
                }
            }
        }

        Agreement_Document__c doc = new Agreement_Document__c();
        doc.Agreement__c = agreementId;
        doc.Name = cv.Title;
        doc.Content_Version_ID__c = cv.Id;
        doc.Document_Type__c = documentType;
        // No stale public link: a replaced Original points at a new
        // ContentVersion, so leave External_URL__c null and let
        // createPublicUrlForAgreement regenerate the URL for the new file.
        doc.External_URL__c = null;
        Database.insert(doc, true, AccessLevel.USER_MODE);
    }

    @AuraEnabled(cacheable=true)
    public static List<DocWrapper> getAgreementDocuments(Id agreementId) {
        List<Agreement_Document__c> docs = [
            SELECT Id, Name, Content_Version_ID__c, Document_Type__c,
                   External_URL__c, CreatedDate,
                   S3_Document_ID__c, S3_Preview_URL__c, Storage_Tier__c,
                   Storage_Type__c, Cloud_File_Id__c, Cloud_Provider__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
        ];

        // Collect all ContentVersion IDs (S3-only docs may have none).
        Set<Id> cvIds = new Set<Id>();
        for (Agreement_Document__c d : docs) {
            if (String.isNotBlank(d.Content_Version_ID__c)) {
                cvIds.add(d.Content_Version_ID__c);
            }
        }

        // Get actual file titles from ContentVersion (Tier1 docs only).
        Map<Id, String> titleMap = new Map<Id, String>();
        Map<Id, String> fileTypeMap = new Map<Id, String>();
        if (!cvIds.isEmpty()) {
            for (ContentVersion cv : [
                SELECT Id, Title, FileType, PathOnClient
                FROM ContentVersion
                WHERE Id IN :cvIds
                WITH USER_MODE
            ]) {
                titleMap.put(cv.Id, cv.Title);
                fileTypeMap.put(cv.Id, cv.FileType);
            }
        }

        List<DocWrapper> wrappers = new List<DocWrapper>();
        for (Agreement_Document__c d : docs) {
            DocWrapper w = new DocWrapper();
            w.Id = d.Id;
            w.contentVersionId = d.Content_Version_ID__c;
            w.documentType = d.Document_Type__c;
            w.createdDate = d.CreatedDate;
            w.s3DocumentId = d.S3_Document_ID__c;
            w.s3PreviewUrl = d.S3_Preview_URL__c;
            w.storageTier = d.Storage_Tier__c;
            w.storageType = d.Storage_Type__c;
            w.cloudFileId = d.Cloud_File_Id__c;
            w.cloudProvider = d.Cloud_Provider__c;

            // Name: prefer ContentVersion title (Tier1), fall back to the
            // Agreement_Document__c.Name (which is what S3 docs use).
            w.Name = titleMap.containsKey(d.Content_Version_ID__c)
                ? titleMap.get(d.Content_Version_ID__c)
                : d.Name;

            // FileType drives the icon in the LWC. ContentVersion knows it for
            // Tier1; otherwise infer from the name extension.
            //
            // Cloud and S3 stamped documents carry the Agreement_Document__c name
            // ("<Agreement> - Stamped Signed Document"), which has no extension on
            // it at all — so both checks missed and the row rendered with the
            // blank "unknown file" icon. Stamping and the certificate only ever
            // produce PDFs, so their type is known from the document type itself.
            // Original keeps the extension check, since that one is whatever the
            // user uploaded.
            if (fileTypeMap.containsKey(d.Content_Version_ID__c)) {
                w.fileType = fileTypeMap.get(d.Content_Version_ID__c);
            } else {
                String lower = String.isBlank(w.Name) ? '' : w.Name.toLowerCase();
                if (lower.endsWith('.pdf'))                                  w.fileType = 'PDF';
                else if (lower.endsWith('.docx') || lower.endsWith('.doc'))  w.fileType = 'WORD';
                else if (d.Document_Type__c == 'Stamped'
                      || d.Document_Type__c == 'Signed')                     w.fileType = 'PDF';
                else                                                         w.fileType = '';
            }
            wrappers.add(w);
        }
        return wrappers;
    }
    
    public class DocWrapper {
        @AuraEnabled public String Id { get; set; }
        @AuraEnabled public String Name { get; set; }
        @AuraEnabled public String contentVersionId { get; set; }
        @AuraEnabled public String documentType { get; set; }
        @AuraEnabled public DateTime createdDate { get; set; }
        @AuraEnabled public String fileType { get; set; }
        // S3-tier metadata. Populated for Tier2/Tier3 docs where bytes live in
        // S3 instead of ContentVersion. Null for Tier1.
        @AuraEnabled public String s3DocumentId { get; set; }
        @AuraEnabled public String s3PreviewUrl { get; set; }
        @AuraEnabled public String storageTier { get; set; }
        // Cloud-tier (>4MB Google Drive / OneDrive) metadata. Null otherwise.
        @AuraEnabled public String storageType { get; set; }
        @AuraEnabled public String cloudFileId { get; set; }
        @AuraEnabled public String cloudProvider { get; set; }
    }

    @AuraEnabled
    public static void deleteAgreementDocument(Id documentId) {
        Agreement_Document__c doc = [
            SELECT Id, Content_Version_ID__c FROM Agreement_Document__c WHERE Id = :documentId
            WITH USER_MODE
        ];
        Database.delete(doc, true, AccessLevel.USER_MODE);
    }

    @AuraEnabled(cacheable=true)
    public static String getDocumentDownloadUrl(String contentVersionId) {
        return '/sfc/servlet.shepherd/version/download/' + contentVersionId;
    }

    /**
     * BUG-024: <lightning-file-upload> performs the upload before the client
     * can inspect file size, so the LWC must validate size AFTER upload.
     * Returns the byte size of the latest ContentVersion for the uploaded
     * ContentDocument so handleUploadFinished can reject files over the limit.
     */
    @AuraEnabled
    public static Integer getContentVersionSize(Id contentDocumentId) {
        ContentVersion cv = [
            SELECT ContentSize
            FROM ContentVersion
            WHERE ContentDocumentId = :contentDocumentId
            WITH USER_MODE
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        return cv.ContentSize;
    }

    /**
     * BUG-024: Deletes an over-size ContentDocument that was already uploaded
     * by <lightning-file-upload> before the size check could run, so an
     * oversized file is never linked to the agreement and leaves no orphan.
     */
    @AuraEnabled
    public static void deleteContentDocument(Id contentDocumentId) {
        Database.delete(
            [SELECT Id FROM ContentDocument WHERE Id = :contentDocumentId WITH USER_MODE],
            true, AccessLevel.USER_MODE
        );
    }

    /**
     * Creates a ContentDistribution (public link) for the agreement's original PDF
     * and stores the public URL in Agreement_Document__c.External_URL__c
     */
    public static void createPublicUrlForAgreement(Id agreementId) {

        List<Agreement_Document__c> docs = [
            SELECT Id, Content_Version_ID__c, External_URL__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId
            AND Document_Type__c = 'Original'
            WITH USER_MODE
            LIMIT 1
        ];

        String cvId;
        Agreement_Document__c doc;

        if (!docs.isEmpty() && String.isNotBlank(docs[0].Content_Version_ID__c)) {
            doc = docs[0];

            // ⚠️ IMPORTANT: If URL already exists → return
            if (String.isNotBlank(doc.External_URL__c)) return;

            cvId = doc.Content_Version_ID__c;

        } else {

            List<ContentDocumentLink> links = [
                SELECT ContentDocument.LatestPublishedVersionId, ContentDocument.Title
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :agreementId
                AND ContentDocument.FileType IN ('PDF','DOCX','DOC','WORD')
                WITH USER_MODE
                ORDER BY ContentDocument.CreatedDate ASC
            ];

            for (ContentDocumentLink l : links) {
                String title = l.ContentDocument.Title;
                if (!title.endsWith('- Signed Document') && !title.endsWith('Signed')) {
                    cvId = l.ContentDocument.LatestPublishedVersionId;
                    break;
                }
            }

            if (String.isBlank(cvId)) return;
        }

        // 🔥 FIX 1: Use DistributionPublicUrl (NOT ContentDownloadUrl)
        List<ContentDistribution> existing = [
            SELECT Id, DistributionPublicUrl
            FROM ContentDistribution
            WHERE ContentVersionId = :cvId
            WITH USER_MODE
            LIMIT 1
        ];

        String publicUrl;

        if (!existing.isEmpty()) {
            publicUrl = existing[0].DistributionPublicUrl;

        } else {

            ContentDistribution cd = new ContentDistribution();
            cd.Name = 'SignForce-' + agreementId;
            cd.ContentVersionId = cvId;

            // 🔥 FIX 2: Correct settings
            cd.PreferencesAllowViewInBrowser = true;
            cd.PreferencesAllowOriginalDownload = true;
            cd.PreferencesLinkLatestVersion = true;
            cd.PreferencesNotifyOnVisit = false;

            Database.insert(cd, true, AccessLevel.USER_MODE);

            cd = [
                SELECT DistributionPublicUrl
                FROM ContentDistribution
                WHERE Id = :cd.Id
                WITH USER_MODE
            ];

            publicUrl = cd.DistributionPublicUrl;
        }

        // Save URL
        if (doc != null) {
            doc.External_URL__c = publicUrl;
            Database.update(doc, true, AccessLevel.USER_MODE);

        } else {
            Agreement_Document__c newDoc = new Agreement_Document__c();
            newDoc.Agreement__c = agreementId;
            newDoc.Name = 'Document';
            newDoc.Content_Version_ID__c = cvId;
            newDoc.Document_Type__c = 'Original';
            newDoc.External_URL__c = publicUrl;
            Database.insert(newDoc, true, AccessLevel.USER_MODE);
        }
    }

    /**
     * Returns the public URL for the agreement's original document (for guest users)
     */
    @AuraEnabled
    public static String getDocumentPublicUrl(Id agreementId) {
        List<Agreement_Document__c> docs = [
            SELECT Id, External_URL__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId
            AND Document_Type__c = 'Original'
            WITH USER_MODE
            LIMIT 1
        ];
        if (!docs.isEmpty() && String.isNotBlank(docs[0].External_URL__c)) {
            return docs[0].External_URL__c;
        }
        return null;
    }
}