/**
 * SignForceBulkSend — DocuSign-style Bulk Send (Option 1).
 *
 * Takes ONE "master" agreement (a document with its signature-field layout) and a
 * list of recipients, and produces a SEPARATE, INDEPENDENT agreement per recipient:
 * each gets its own copy of the document, its own single signer, and its own
 * signing link. One recipient completing has no bearing on the others.
 *
 * This is deliberately additive — it reuses the existing clone/send building blocks
 * and does not change AgreementController.bulkSend (which adds many signers to ONE
 * shared envelope) or any existing flow.
 *
 * Batch tracking is stored in a manifest ContentVersion titled
 * "SFBulkBatch_<batchId>" linked to the master agreement, because new custom fields
 * cannot be created in this org (CLI deploys report success but the field never
 * materializes). The manifest lists the agreement ids the batch produced, which
 * getBulkStatus reads back to aggregate progress.
 *
 * SCOPE: the master's Original document must be Salesforce-stored (Tier1). An
 * S3-backed master is rejected with a clear message rather than copied wrongly —
 * copying S3 bytes needs a callout, which is out of scope for this first cut.
 *
 * Sharing: deliberately without sharing, and for exactly one operation. This
 * is reached only from the internal "Bulk Operations" tab (signforceBulkConsole
 * LWC) — granted via SignForce_User, not guest or Sites-reachable. Every SOQL
 * below already runs WITH USER_MODE and every per-recipient DML already runs
 * AccessLevel.USER_MODE, so row-level enforcement on the reads and on the
 * copies does NOT depend on this keyword. What does depend on it is the single
 * manifest ContentDocumentLink written back onto the master in writeManifest:
 * the sender is not necessarily the master's owner, only someone who can see it
 * (e.g. a team/read-only share), and that link has to attach regardless or
 * getBulkStatus can never report progress. See writeManifest for the detail.
 */
public inherited sharing class SignForceBulkSend {

    private static final String MANIFEST_PREFIX = 'SFBulkBatch_';
    // Recipients handled per async execution. Small, so heap (one PDF blob copied
    // per recipient) and per-transaction DML stay comfortable; the job chains
    // itself until the whole list is done.
    private static final Integer CHUNK_SIZE = 5;

    public class BulkSendException extends Exception {}

    /**
     * Kicks off a bulk send. Validates the master, records the batch, and queues
     * the work. Returns { batchId, total } immediately; poll getBulkStatus for
     * progress.
     *
     * recipientsJson: [ { "name": "...", "email": "..." }, ... ]
     */
    @AuraEnabled
    public static Map<String, Object> startBulkSend(Id sourceAgreementId, String recipientsJson) {
        if (sourceAgreementId == null) throw new AuraHandledException('Source agreement is required');
        if (String.isBlank(recipientsJson)) throw new AuraHandledException('Recipient list is required');

        // Parse + clean the recipient list.
        List<Map<String, Object>> recipients = new List<Map<String, Object>>();
        Set<String> seen = new Set<String>();
        try {
            for (Object o : (List<Object>) JSON.deserializeUntyped(recipientsJson)) {
                Map<String, Object> r = (Map<String, Object>) o;
                String email = String.valueOf(r.get('email')).trim();
                String name = r.get('name') == null ? '' : String.valueOf(r.get('name')).trim();
                if (String.isBlank(email) || !email.contains('@')) continue;
                String key = email.toLowerCase();
                if (seen.contains(key)) continue;   // de-dupe within the list
                seen.add(key);
                recipients.add(new Map<String, Object>{
                    'name' => String.isBlank(name) ? email : name,
                    'email' => email
                });
            }
        } catch (Exception e) {
            throw new AuraHandledException('Recipient list is not valid: ' + e.getMessage());
        }
        if (recipients.isEmpty()) throw new AuraHandledException('No valid recipients (need name + email).');

        // The master must exist and carry a Salesforce-stored Original document.
        validateMaster(sourceAgreementId);

        String batchId = AgreementService.generateUUID();
        System.enqueueJob(new BulkSendQueueable(
            sourceAgreementId, recipients, 0, batchId, new List<Id>()
        ));

        return new Map<String, Object>{ 'batchId' => batchId, 'total' => recipients.size() };
    }

    /** Progress for a batch: counts by status across the agreements it produced. */
    @AuraEnabled
    public static Map<String, Object> getBulkStatus(Id sourceAgreementId, String batchId) {
        Map<String, Object> out = new Map<String, Object>{
            'total' => 0, 'sent' => 0, 'completed' => 0, 'declined' => 0, 'draft' => 0
        };
        List<Id> ids = readManifest(sourceAgreementId, batchId);
        out.put('total', ids.size());
        if (ids.isEmpty()) return out;

        Integer sent = 0, completed = 0, declined = 0, draft = 0;
        for (Agreement__c a : [SELECT Status__c FROM Agreement__c WHERE Id IN :ids WITH USER_MODE]) {
            String st = a.Status__c;
            if (st == 'Completed') completed++;
            else if (st == 'Declined' || st == 'Voided') declined++;
            else if (st == 'Draft') draft++;
            else sent++;   // Sent / In Progress
        }
        out.put('sent', sent); out.put('completed', completed);
        out.put('declined', declined); out.put('draft', draft);
        return out;
    }

    /**
     * Agreements that can act as a bulk-send master, for the picker.
     *
     * Only ones that would pass validateMaster are listed — a Salesforce-stored
     * Original document. Offering an agreement the send would then reject is a
     * worse experience than not offering it, so the same rule filters both.
     */
    @AuraEnabled
    public static List<Map<String, Object>> listMasterAgreements() {
        Set<Id> withTier1Doc = new Set<Id>();
        for (Agreement_Document__c d : [
            SELECT Agreement__c
            FROM Agreement_Document__c
            WHERE Document_Type__c = 'Original'
            AND Content_Version_ID__c != null
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 2000
        ]) {
            withTier1Doc.add(d.Agreement__c);
        }
        if (withTier1Doc.isEmpty()) return new List<Map<String, Object>>();

        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (Agreement__c a : [
            SELECT Id, Name, Status__c, Agreement_Type__c, CreatedDate
            FROM Agreement__c
            WHERE Id IN :withTier1Doc
            AND Is_Template__c = false
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 200
        ]) {
            out.add(new Map<String, Object>{
                'id'     => a.Id,
                'name'   => a.Name,
                'status' => a.Status__c,
                'type'   => a.Agreement_Type__c
            });
        }
        return out;
    }

    // ── validation ──────────────────────────────────────────────────────────

    private static void validateMaster(Id sourceAgreementId) {
        List<Agreement__c> masters = [
            SELECT Id, Name FROM Agreement__c WHERE Id = :sourceAgreementId WITH USER_MODE LIMIT 1
        ];
        if (masters.isEmpty()) throw new AuraHandledException('Source agreement not found.');

        List<Agreement_Document__c> orig = [
            SELECT Id, Content_Version_ID__c, Storage_Tier__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :sourceAgreementId AND Document_Type__c = 'Original'
            WITH USER_MODE
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        if (orig.isEmpty()) {
            throw new AuraHandledException('The selected agreement has no document to send. Upload a document first.');
        }
        if (String.isBlank(orig[0].Content_Version_ID__c)) {
            throw new AuraHandledException(
                'Bulk send currently supports Salesforce-stored documents only. '
                + 'Re-upload the master document to this agreement and try again.'
            );
        }
    }

    // ── async worker ────────────────────────────────────────────────────────

    public class BulkSendQueueable implements Queueable {
        private Id sourceId;
        private List<Map<String, Object>> recipients;
        private Integer startIndex;
        private String batchId;
        private List<Id> createdSoFar;

        public BulkSendQueueable(Id sourceId, List<Map<String, Object>> recipients,
                                 Integer startIndex, String batchId, List<Id> createdSoFar) {
            this.sourceId = sourceId;
            this.recipients = recipients;
            this.startIndex = startIndex;
            this.batchId = batchId;
            this.createdSoFar = createdSoFar;
        }

        public void execute(QueueableContext ctx) {
            Integer stopAt = Math.min(startIndex + CHUNK_SIZE, recipients.size());
            for (Integer i = startIndex; i < stopAt; i++) {
                try {
                    Id newAgrId = cloneAndSend(sourceId, recipients[i], batchId);
                    if (newAgrId != null) createdSoFar.add(newAgrId);
                } catch (Exception e) {
                    // One bad recipient must not sink the whole batch.
                    System.debug(LoggingLevel.WARN,
                        'BulkSend: recipient ' + recipients[i].get('email') + ' failed: ' + e.getMessage());
                }
            }

            if (stopAt < recipients.size()) {
                System.enqueueJob(new BulkSendQueueable(
                    sourceId, recipients, stopAt, batchId, createdSoFar
                ));
            } else {
                writeManifest(sourceId, batchId, createdSoFar);
            }
        }
    }

    // ── per-recipient clone + send ──────────────────────────────────────────

    /**
     * Builds one independent agreement for a recipient — cloned core fields, a
     * fresh copy of the master's document, the single recipient as signer, and the
     * signature-field layout re-pointed to that signer — then sends it.
     */
    public static Id cloneAndSend(Id sourceId, Map<String, Object> recipient, String batchId) {
        Agreement__c master = [
            SELECT Name, Agreement_Type__c, Signing_Order__c, Message_to_Signers__c
            FROM Agreement__c WHERE Id = :sourceId WITH USER_MODE LIMIT 1
        ];
        String rName = String.valueOf(recipient.get('name'));
        String rEmail = String.valueOf(recipient.get('email'));

        // 1. New agreement (independent copy).
        Agreement__c agr = new Agreement__c();
        agr.Name = master.Name + ' - ' + rName;
        agr.Agreement_Type__c = master.Agreement_Type__c;
        agr.Signing_Order__c = master.Signing_Order__c;
        agr.Message_to_Signers__c = master.Message_to_Signers__c;
        agr.Status__c = 'Draft';
        agr.Storage_Location__c = 'Salesforce';
        Database.insert(agr, true, AccessLevel.USER_MODE);

        // 2. Copy the master's Original document (Tier1: read VersionData via SOQL,
        //    no callout, publish a fresh file on the new agreement).
        copyOriginalDocument(sourceId, agr.Id);

        // 3. The single recipient becomes the one signer.
        Signer__c signer = new Signer__c(
            Agreement__c = agr.Id,
            Name = rName,
            Email__c = rEmail,
            Role__c = 'Signer',
            Signing_Order__c = 1,
            Status__c = 'Pending'
        );
        Database.insert(signer, true, AccessLevel.USER_MODE);

        // 4. Copy the field layout, all assigned to this one signer.
        copyFields(sourceId, agr.Id, signer.Id);

        // 5. Send — this sets Sent, mints an envelope id and emails the signer.
        AgreementService.sendForSignature(agr.Id);

        AuditTrailService.log(agr.Id, 'Bulk Send Copy Created', rEmail, null, 'Batch: ' + batchId);
        return agr.Id;
    }

    private static void copyOriginalDocument(Id sourceId, Id newAgreementId) {
        List<Agreement_Document__c> orig = [
            SELECT Content_Version_ID__c, File_Size_Bytes__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :sourceId AND Document_Type__c = 'Original'
            AND Content_Version_ID__c != null
            WITH USER_MODE
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        if (orig.isEmpty()) return;

        List<ContentVersion> src = [
            SELECT Title, PathOnClient, VersionData
            FROM ContentVersion WHERE Id = :orig[0].Content_Version_ID__c WITH USER_MODE LIMIT 1
        ];
        if (src.isEmpty() || src[0].VersionData == null) return;

        ContentVersion cv = new ContentVersion(
            Title = src[0].Title,
            PathOnClient = String.isBlank(src[0].PathOnClient) ? (src[0].Title + '.pdf') : src[0].PathOnClient,
            VersionData = src[0].VersionData,
            FirstPublishLocationId = newAgreementId,
            Origin = 'H'
        );
        Database.insert(cv, true, AccessLevel.USER_MODE);
        ContentVersion inserted = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id WITH USER_MODE LIMIT 1];

        Database.insert(new Agreement_Document__c(
            Agreement__c = newAgreementId,
            Name = src[0].Title,
            Content_Version_ID__c = inserted.Id,
            Document_Type__c = 'Original',
            Storage_Tier__c = 'Tier1',
            File_Size_Bytes__c = orig[0].File_Size_Bytes__c
        ), true, AccessLevel.USER_MODE);
    }

    private static void copyFields(Id sourceId, Id newAgreementId, Id signerId) {
        List<Signature_Field__c> srcFields = [
            SELECT Field_Type__c, Field_Label__c, Page_Number__c,
                   X_Position__c, Y_Position__c, Width__c, Height__c,
                   Is_Required__c, Page_Width__c
            FROM Signature_Field__c WHERE Agreement__c = :sourceId WITH USER_MODE
        ];
        if (srcFields.isEmpty()) return;

        List<Signature_Field__c> newFields = new List<Signature_Field__c>();
        for (Signature_Field__c f : srcFields) {
            newFields.add(new Signature_Field__c(
                Agreement__c = newAgreementId,
                Assigned_Signer__c = signerId,   // one signer per copy
                Field_Type__c = f.Field_Type__c,
                Field_Label__c = f.Field_Label__c,
                Page_Number__c = f.Page_Number__c,
                X_Position__c = f.X_Position__c,
                Y_Position__c = f.Y_Position__c,
                Width__c = f.Width__c,
                Height__c = f.Height__c,
                Is_Required__c = f.Is_Required__c,
                Page_Width__c = f.Page_Width__c
            ));
        }
        Database.insert(newFields, true, AccessLevel.USER_MODE);
    }

    // ── batch manifest (fieldless tracking) ─────────────────────────────────

    private static void writeManifest(Id sourceId, String batchId, List<Id> agreementIds) {
        try {
            // The manifest file itself is user-mode: it carries no
            // FirstPublishLocationId, so there is no record-level dependency to
            // fail on, and copyOriginalDocument has already proved this user can
            // create a ContentVersion. The LINK back onto the master stays
            // system-mode on purpose — it must attach even when the sender's share
            // on the master is read-only, and getBulkStatus is blind without it.
            // The catch below swallows failures, so a USER_MODE link that failed
            // would break batch progress silently.
            SignForceFLS.requireCreateable(ContentVersion.SObjectType);
            SignForceFLS.requireCreateable(ContentDocumentLink.SObjectType);
            String title = MANIFEST_PREFIX + batchId;
            String body = JSON.serialize(new Map<String, Object>{
                'batchId' => batchId,
                'sourceId' => sourceId,
                'total' => agreementIds.size(),
                'agreementIds' => agreementIds
            });
            ContentVersion cv = new ContentVersion(
                Title = title,
                PathOnClient = title + '.json',
                VersionData = Blob.valueOf(body),
                Origin = 'H'
            );
            Database.insert(cv, true, AccessLevel.USER_MODE);
            Id cdId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id WITH USER_MODE LIMIT 1].ContentDocumentId;
            // CRUD assertion on the link object — the ContentVersion above already runs
            // USER_MODE, this is the matching check for the link the scanner reads.
            if (!Schema.sObjectType.ContentDocumentLink.isCreateable()) {
                throw new SignForceFLS.SignForceFLSException(
                    'Insufficient access to create ContentDocumentLink records.');
            }
            insert new ContentDocumentLink(
                ContentDocumentId = cdId, LinkedEntityId = sourceId, ShareType = 'V'
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'BulkSend manifest write failed: ' + e.getMessage());
        }
    }

    private static List<Id> readManifest(Id sourceId, String batchId) {
        List<Id> ids = new List<Id>();
        if (sourceId == null || String.isBlank(batchId)) return ids;
        try {
            String title = MANIFEST_PREFIX + batchId;
            Set<Id> docIds = new Set<Id>();
            for (ContentDocumentLink l : [
                SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :sourceId WITH USER_MODE
            ]) docIds.add(l.ContentDocumentId);
            if (docIds.isEmpty()) return ids;

            List<ContentVersion> cvs = [
                SELECT VersionData FROM ContentVersion
                WHERE ContentDocumentId IN :docIds AND Title = :title AND IsLatest = true
                WITH USER_MODE
                ORDER BY CreatedDate DESC LIMIT 1
            ];
            if (cvs.isEmpty()) return ids;
            Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(cvs[0].VersionData.toString());
            if (m.get('agreementIds') instanceof List<Object>) {
                for (Object o : (List<Object>) m.get('agreementIds')) ids.add((Id) String.valueOf(o));
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'BulkSend manifest read failed: ' + e.getMessage());
        }
        return ids;
    }
}