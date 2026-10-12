/**
 * AgreementFileCleanup — keeps a completed agreement's Files list to the final
 * signed document only.
 *
 * The document is re-stamped after every signature and each stamp is published as
 * its own file, because signing runs as the Site Guest User and the platform lets
 * it neither delete nor add a version to a ContentDocument owned by someone else.
 * Attempting to version them is actively destructive — the re-stamp after
 * signatures 2..N is silently never stored, leaving a "signed" document carrying
 * only the FIRST signature. So intermediates are produced deliberately and removed
 * afterwards, once the final stamp exists.
 *
 * Runs only on completion, and only ever removes files this package created and
 * has already superseded:
 *   - "<Agreement> - Signed N of M - <name>"  intermediate stamps
 *   - older duplicates of "<Agreement> - Final Signed Document"
 * It never touches the newest final document, the signing certificate, the
 * original, or anything a user uploaded, and never the file the Stamped/Signed
 * pointer resolves through.
 *
 * Every failure is swallowed. A context without delete rights simply leaves the
 * extra rows in place — which is the behaviour before this class existed. Nothing
 * here can cost a signature.
 */
public with sharing class AgreementFileCleanup {

    /** Removes superseded stamped files. Returns how many went. Never throws. */
    public static Integer removeSupersededFiles(Id agreementId) {
        if (agreementId == null) return 0;
        try {
            Agreement__c agr = [SELECT Id, Name FROM Agreement__c WHERE Id = :agreementId LIMIT 1];
            String base = String.isBlank(agr.Name) ? '' : agr.Name;
            if (String.isBlank(base)) return 0;

            String finalTitle = base + ' - Final Signed Document';
            String progressPrefix = base + ' - Signed ';

            Set<Id> docIds = new Set<Id>();
            for (ContentDocumentLink l : [
                SELECT ContentDocumentId FROM ContentDocumentLink
                WHERE LinkedEntityId = :agreementId
            ]) {
                docIds.add(l.ContentDocumentId);
            }
            if (docIds.isEmpty()) return 0;

            List<ContentDocument> docs = [
                SELECT Id, Title FROM ContentDocument
                WHERE Id IN :docIds
                ORDER BY CreatedDate DESC
            ];

            // Completion runs TWO stamping jobs — the guest signing flow queues one
            // and AgreementTrigger queues another — and they race, so a completed
            // agreement can end up with two identical final files, each with its own
            // Stamped row. A guard inside the stamper cannot reliably win that race
            // (both jobs read before either writes), so the redundant Stamped rows
            // are dropped here instead, once everything has settled.
            //
            // The NEWEST Stamped row survives; older ones and the files they point
            // at go. Every one of them carries the complete set of signatures — they
            // are copies of the same final document, not different stages.
            List<Agreement_Document__c> stampedRows = [
                SELECT Id, Content_Version_ID__c FROM Agreement_Document__c
                WHERE Agreement__c = :agreementId
                AND Document_Type__c = 'Stamped'
                AND Content_Version_ID__c != null
                ORDER BY CreatedDate DESC
            ];
            List<Agreement_Document__c> redundantRows = new List<Agreement_Document__c>();
            Set<Id> droppedCvIds = new Set<Id>();
            for (Integer i = 1; i < stampedRows.size(); i++) {          // skip [0], the newest
                redundantRows.add(stampedRows[i]);
                try { droppedCvIds.add((Id) stampedRows[i].Content_Version_ID__c); } catch (Exception ignored) {}
            }
            if (!redundantRows.isEmpty() && Schema.sObjectType.Agreement_Document__c.isDeletable()) {
                Database.delete(redundantRows, false);
            }

            // Whatever the SURVIVING pointers reference must not be deleted — emails
            // and previews resolve through them, not through the title.
            Set<Id> protectedDocs = new Set<Id>();
            Set<Id> pointerCvIds = new Set<Id>();
            for (Agreement_Document__c d : [
                SELECT Content_Version_ID__c FROM Agreement_Document__c
                WHERE Agreement__c = :agreementId AND Content_Version_ID__c != null
            ]) {
                try { pointerCvIds.add((Id) d.Content_Version_ID__c); } catch (Exception ignored) {}
            }
            pointerCvIds.removeAll(droppedCvIds);
            Set<Id> droppedDocs = new Set<Id>();
            Set<Id> allCvIds = new Set<Id>(pointerCvIds);
            allCvIds.addAll(droppedCvIds);
            if (!allCvIds.isEmpty()) {
                for (ContentVersion cv : [
                    SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id IN :allCvIds
                ]) {
                    if (droppedCvIds.contains(cv.Id)) droppedDocs.add(cv.ContentDocumentId);
                    else protectedDocs.add(cv.ContentDocumentId);
                }
            }
            // A file still referenced by a surviving pointer wins over a dropped one.
            droppedDocs.removeAll(protectedDocs);

            // When a Stamped/Signed pointer anchors one of the finals, THAT copy is
            // the keeper regardless of where it falls in the date ordering. Decided
            // BEFORE the walk below: deciding it inside the loop meant an orphan
            // that happened to be newer was seen first, looked like "the one final",
            // and survived alongside the pointed copy.
            Boolean keptFinal = false;
            for (ContentDocument c : docs) {
                if (protectedDocs.contains(c.Id) && finalTitle.equals(c.Title)) {
                    keptFinal = true;
                    break;
                }
            }

            List<ContentDocument> stale = new List<ContentDocument>();
            for (ContentDocument c : docs) {          // newest first
                String title = c.Title == null ? '' : c.Title;
                if (protectedDocs.contains(c.Id)) continue;

                if (droppedDocs.contains(c.Id)) {
                    stale.add(c);                     // file of a redundant Stamped row
                } else if (title == finalTitle) {
                    // Keep the newest final; anything identical behind it is a copy
                    // produced by the same completion.
                    if (!keptFinal) { keptFinal = true; continue; }
                    stale.add(c);
                } else if (title.startsWith(progressPrefix)) {
                    stale.add(c);                     // an intermediate stamp
                }
                // anything else — certificate, original, user uploads — untouched
            }
            if (stale.isEmpty()) return 0;

            Integer removed = 0;
            // allOrNone=false: a parallel path may have removed these already, and a
            // context lacking delete rights must degrade quietly - hence the CRUD
            // check gates the DML instead of throwing.
            if (Schema.sObjectType.ContentDocument.isDeletable()) {
                for (Database.DeleteResult dr : Database.delete(stale, false)) {
                    if (dr.isSuccess()) removed++;
                }
            }
            System.debug(LoggingLevel.INFO,
                'AgreementFileCleanup: removed ' + removed + ' of ' + stale.size()
                + ' superseded file(s) for ' + agreementId);
            return removed;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'AgreementFileCleanup skipped for ' + agreementId + ': ' + e.getMessage());
            return 0;
        }
    }

    /**
     * Sweeps completed agreements. Intended for a scheduled job, which runs as the
     * scheduling admin — a context that can always delete, unlike the guest session
     * that created the files.
     */
    public static Integer cleanupCompleted(Integer maxAgreements) {
        Integer rows = (maxAgreements == null || maxAgreements <= 0) ? 20 : maxAgreements;
        Integer removed = 0;
        for (Agreement__c agr : [
            SELECT Id FROM Agreement__c
            WHERE Status__c = 'Completed'
            ORDER BY LastModifiedDate DESC
            LIMIT :rows
        ]) {
            removed += removeSupersededFiles(agr.Id);
        }
        return removed;
    }
}