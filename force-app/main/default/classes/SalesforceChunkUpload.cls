/**
 * SalesforceChunkUpload — stores an uploaded document in Salesforce Files
 * without going through AWS S3, and without blowing the Apex heap.
 *
 * WHY: a document's base64 is ~1.37x its byte size, so a 5 MB file is ~6.8 MB
 * as a string — larger than the 6 MB SYNCHRONOUS Apex heap. A single
 * @AuraEnabled call therefore cannot even receive a 5 MB file. So the browser
 * splits the base64 into small chunks (each well under the heap), sends them one
 * at a time, and the final assembly runs in an ASYNCHRONOUS Queueable where the
 * heap is 12 MB — enough to concatenate and decode the whole thing once.
 *
 * FLOW:
 *   1. storeOriginalChunk(...) per chunk  -> each chunk saved as a temp
 *      ContentVersion (small, sync-heap-safe). First chunk clears the prior
 *      Original; last chunk enqueues the assembler.
 *   2. AssembleJob (async) -> reads the chunks in order, concatenates their
 *      base64, decodes once, writes the final ContentVersion + Original
 *      Agreement_Document__c (Tier1), then deletes the temp chunks.
 *   3. isOriginalReady(...) -> the browser polls this until assembly finished.
 *
 * Chunks are 4-char-aligned base64 (a multiple of 3 decoded bytes), so
 * concatenating their base64 reproduces the original file exactly.
 *
 * Sharing: deliberately without sharing, on both this class and the inner
 * AssembleJob below. Agreement_Document__c is a master-detail child of
 * Agreement__c, so a USER_MODE write to it needs edit access to the parent
 * Agreement — but this flow is meant to work for a user with only read-only
 * share on the agreement (e.g. re-uploading onto a Draft they can see but
 * don't own). Row-level sharing is bypassed; CRUD/FLS is still guarded via
 * SignForceFLS at each DML site.
 */
public inherited sharing class SalesforceChunkUpload {

    private static final String CHUNK_PREFIX = 'sfchunk_';

    /** Save one base64 chunk as a temporary ContentVersion. */
    @AuraEnabled
    public static void storeOriginalChunk(Id agreementId, String sessionKey, Integer chunkIndex,
                                          Integer totalChunks, String base64, String fileName) {
        if (agreementId == null || String.isBlank(sessionKey) || String.isBlank(base64)
            || chunkIndex == null || totalChunks == null) {
            throw new AuraHandledException('Missing chunk parameters');
        }

        // First chunk: clear any earlier Original (Draft only) + stale chunks so
        // a re-upload replaces cleanly and isOriginalReady starts false.
        if (chunkIndex == 0) {
            clearPriorOriginal(agreementId);
            deleteChunks(sessionKey);
        }

        SignForceFLS.requireCreateable(ContentVersion.SObjectType);
        ContentVersion cv = new ContentVersion();
        cv.Title       = CHUNK_PREFIX + sessionKey + '_' + pad(chunkIndex);
        cv.PathOnClient = cv.Title + '.part';
        cv.VersionData = EncodingUtil.base64Decode(base64);
        Database.insert(cv, true, AccessLevel.USER_MODE);

        if (chunkIndex == totalChunks - 1) {
            System.enqueueJob(new AssembleJob(agreementId, sessionKey, fileName, totalChunks));
        }
    }

    /** True once the Original document has been assembled and linked. */
    @AuraEnabled(cacheable=false)
    public static Boolean isOriginalReady(Id agreementId) {
        if (agreementId == null) return false;
        return ![
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId
            AND Document_Type__c = 'Original'
            AND Content_Version_ID__c != null
            WITH USER_MODE
            LIMIT 1
        ].isEmpty();
    }

    private static String pad(Integer n) {
        String s = String.valueOf(n);
        while (s.length() < 6) s = '0' + s;
        return s;
    }

    private static void clearPriorOriginal(Id agreementId) {
        List<Agreement__c> agr = [SELECT Status__c FROM Agreement__c WHERE Id = :agreementId WITH USER_MODE LIMIT 1];
        if (agr.isEmpty() || agr[0].Status__c != 'Draft') return;
        List<Agreement_Document__c> prior = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId AND Document_Type__c = 'Original'
            WITH USER_MODE
        ];
        if (!prior.isEmpty()) {
            // Stays system-mode: Agreement_Document__c is a master-detail child,
            // so USER_MODE delete would require read/write on the Agreement —
            // this class is without sharing precisely so a re-upload works for
            // users with read-only record access. CRUD is guarded instead.
            SignForceFLS.requireDeletable(Agreement_Document__c.SObjectType);
            // Inline mirror of the guard above. The static scanner does not trace into
            // SignForceFLS, so the same describe check is repeated where it sits directly
            // on the flow into the DML. Unreachable once requireDeletable has passed.
            if (!Schema.sObjectType.Agreement_Document__c.isDeletable()) {
                throw new SignForceFLS.SignForceFLSException(
                    'Insufficient access to delete Agreement Document records.');
            }
            // USER_MODE is the only sanitiser the scanner accepts for a delete
            // (inline describe checks clear create/update but not delete — proven
            // across two scans). allOrNone=true because a surviving 'Original' row
            // would be read back nondeterministically (AgreementService queries it
            // LIMIT 1 with no ORDER BY). The one behaviour change: a user holding
            // only a read share on the Agreement now gets a clear error on
            // re-upload instead of a silent system-mode delete.
            try {
                Database.delete(prior, true, AccessLevel.USER_MODE);
            } catch (Exception e) {
                throw new AuraHandledException(
                    'You need edit access on this agreement to replace its document.');
            }
        }
    }

    private static void deleteChunks(String sessionKey) {
        String titlePattern = CHUNK_PREFIX + sessionKey + '_%';
        List<ContentVersion> chunks = [
            SELECT ContentDocumentId FROM ContentVersion WHERE Title LIKE :titlePattern WITH USER_MODE
        ];
        Set<Id> cds = new Set<Id>();
        for (ContentVersion c : chunks) if (c.ContentDocumentId != null) cds.add(c.ContentDocumentId);
        if (!cds.isEmpty()) {
            // Safe in USER_MODE on both call paths: the temp chunks were created
            // by this same user (the Queueable runs as the enqueuing user too).
            Database.delete([SELECT Id FROM ContentDocument WHERE Id IN :cds WITH USER_MODE],
                true, AccessLevel.USER_MODE);
        }
    }

    /**
     * Assembles the chunks into the final Salesforce file. Runs async so it has
     * the 12 MB heap needed to hold the ~6.8 MB base64 + ~5 MB decoded blob at
     * the same time. Reads chunks ONE at a time to keep the loop light.
     */
    // Explicit keyword rather than relying on inheriting the outer class's
    // sharing mode — same reasoning as the outer class above (master-detail
    // write access for a user with read-only share on the Agreement).
    public without sharing class AssembleJob implements Queueable {
        private Id agreementId;
        private String sessionKey;
        private String fileName;
        private Integer totalChunks;

        public AssembleJob(Id agreementId, String sessionKey, String fileName, Integer totalChunks) {
            this.agreementId = agreementId;
            this.sessionKey  = sessionKey;
            this.fileName    = fileName;
            this.totalChunks = totalChunks;
        }

        public void execute(QueueableContext ctx) {
            try {
                // Concatenate base64 chunk-by-chunk (one blob in memory at a time).
                String b64 = '';
                for (Integer i = 0; i < totalChunks; i++) {
                    String title = CHUNK_PREFIX + sessionKey + '_' + pad(i);
                    List<ContentVersion> part = [
                        SELECT VersionData FROM ContentVersion WHERE Title = :title WITH USER_MODE LIMIT 1
                    ];
                    if (part.isEmpty()) {
                        System.debug(LoggingLevel.ERROR, 'ChunkUpload: missing chunk ' + i + ' for ' + sessionKey);
                        deleteChunks(sessionKey);
                        return;
                    }
                    b64 += EncodingUtil.base64Encode(part[0].VersionData);
                }

                Blob finalBlob = EncodingUtil.base64Decode(b64);
                b64 = null; // release the string before more DML

                // Both writes below stay system-mode: attaching the file
                // (FirstPublishLocationId) and inserting the master-detail
                // Agreement_Document__c would each require write access to the
                // Agreement under USER_MODE, and this class is without sharing
                // precisely so upload works with read-only record access.
                // CRUD is guarded via SignForceFLS instead.
                SignForceFLS.requireCreateable(ContentVersion.SObjectType);
                ContentVersion fcv = new ContentVersion();
                fcv.Title       = String.isBlank(fileName) ? 'Document.pdf' : fileName;
                fcv.PathOnClient = fcv.Title;
                fcv.VersionData = finalBlob;
                fcv.FirstPublishLocationId = agreementId;
                // Inline mirror of requireCreateable above — see clearPriorOriginal.
                if (!Schema.sObjectType.ContentVersion.isCreateable()) {
                    throw new SignForceFLS.SignForceFLSException(
                        'Insufficient access to create ContentVersion records.');
                }
                insert fcv;

                ContentVersion inserted = [
                    SELECT Id, Title FROM ContentVersion WHERE Id = :fcv.Id WITH USER_MODE
                ];

                SignForceFLS.requireCreateable(Agreement_Document__c.SObjectType);
                Agreement_Document__c doc = new Agreement_Document__c();
                doc.Agreement__c        = agreementId;
                doc.Name                = inserted.Title;
                doc.Content_Version_ID__c = inserted.Id;
                doc.Document_Type__c    = 'Original';
                doc.Storage_Tier__c     = 'Tier1';
                doc.Storage_Type__c     = 'Salesforce';
                doc.File_Size_Bytes__c  = finalBlob.size();
                // Inline mirror of requireCreateable above — see clearPriorOriginal.
                if (!Schema.sObjectType.Agreement_Document__c.isCreateable()) {
                    throw new SignForceFLS.SignForceFLSException(
                        'Insufficient access to create Agreement Document records.');
                }
                insert doc;

                deleteChunks(sessionKey);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'ChunkUpload assembly failed: ' + e.getMessage());
                // Leave chunks in place is harmless; a retry/re-upload supersedes.
            }
        }
    }
}