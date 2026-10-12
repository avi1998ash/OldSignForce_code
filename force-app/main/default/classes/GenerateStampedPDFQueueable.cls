/**
 * GenerateStampedPDFQueueable — RETIRED. Body commented out, not deleted.
 *
 * This class stamped the signed PDF and sent completion emails when an
 * agreement reached Completed. It is superseded by
 * AgreementController.generateStampedPDFServerAsync, which is what
 * AgreementTrigger actually calls.
 *
 * Confirmed unreachable before retiring it:
 *   - no production caller anywhere in the repo (the only reference was
 *     LegacyStampingCoverageTest, a test written purely to give it coverage),
 *   - not listed in any permission set or profile,
 *   - StampedPDFController's own header already recorded it as uncalled.
 *
 * Kept as an empty class rather than deleted because this ships in a managed
 * package: removing a class is the kind of change that is awkward to reverse
 * once a version is released, and leaving the shell costs nothing.
 *
 * The implementation is preserved verbatim below so the stamping logic is not
 * lost — if this path is ever revived, note the security constraint the old
 * comments recorded: the @future ran as whoever completed the agreement, which
 * for a public-link signature is the Site Guest User, and
 * SignForce_Guest_User_Access grants Agreement_Document__c allowCreate=false.
 * AccessLevel.USER_MODE on those inserts would therefore throw for exactly the
 * actor the method existed to serve, and the swallowing catch would hide it.
 */
public with sharing class GenerateStampedPDFQueueable {

    // Intentionally empty. Retired implementation retained below for reference.
    // "with sharing" here is bookkeeping, not a behaviour change: the class has
    // no body left to share anything. The retired code needed without-sharing
    // for the guest-completion path described above; if it is ever revived,
    // that keyword has to come back with it.

    /*
    @future(callout=true)
    public static void generateAndSend(Id agreementId) {
        try {
            PageReference pdfPage = Page.Stampedpdf;
            pdfPage.getParameters().put('agreementId', agreementId);

            Blob pdfBlob;
            if (Test.isRunningTest()) {
                pdfBlob = Blob.valueOf('PDF_PLACEHOLDER');
            } else {
                pdfBlob = pdfPage.getContentAsPDF();
            }

            storePDFAndSendEmails(agreementId, pdfBlob);

        } catch (Exception e) {
            System.debug('Error: ' + e.getMessage());
        }
    }

    private static void storePDFAndSendEmails(Id agreementId, Blob pdfBlob) {
        Agreement__c agr = [SELECT Id, Name FROM Agreement__c WHERE Id = :agreementId WITH USER_MODE];

        SignForceFLS.requireCreateable(ContentVersion.SObjectType);
        ContentVersion cv = new ContentVersion();
        cv.Title          = agr.Name + ' - Signed Document';
        cv.PathOnClient   = agr.Name + '_Signed.pdf';
        cv.VersionData    = pdfBlob;
        cv.IsMajorVersion = true;
        insert cv;

        ContentVersion inserted = [
            SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id WITH USER_MODE
        ];

        SignForceFLS.requireCreateable(ContentDocumentLink.SObjectType);
        ContentDocumentLink cdl = new ContentDocumentLink();
        cdl.ContentDocumentId = inserted.ContentDocumentId;
        cdl.LinkedEntityId    = agreementId;
        cdl.ShareType         = 'V';
        cdl.Visibility        = 'AllUsers';
        insert cdl;

        SignForceFLS.requireCreateable(Agreement_Document__c.SObjectType);
        Agreement_Document__c doc = new Agreement_Document__c();
        doc.Agreement__c          = agreementId;
        doc.Document_Type__c      = 'Signed';
        doc.Content_Version_ID__c = cv.Id;
        insert doc;

        AgreementService.sendCompletionEmailsPublic(agreementId);
    }
    */
}