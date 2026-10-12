/**
 * SignForceFileCleanupTrigger — removes an agreement's superseded stamped files.
 *
 * This exists as a PLATFORM EVENT subscriber for one reason: execution context.
 *
 * The document is re-stamped after every signature and each stamp is published as
 * its own file, because signing runs as the Site Guest User and the platform lets
 * it neither delete nor version a ContentDocument owned by someone else. Cleaning
 * up from the Agreement trigger does not work either — a trigger always runs as
 * the user who caused the DML, which for a guest signature is the guest. Measured
 * on a real agreement: the identical call removed 0 files as the guest and 1 as an
 * admin.
 *
 * A platform-event subscriber runs as the Automated Process user instead, so the
 * delete is actually permitted. The guest only has to PUBLISH the event, which it
 * can do.
 *
 * Failure is non-fatal by design: the event fires after the final stamp is already
 * saved, so a cleanup that cannot run leaves extra rows in the Files panel and
 * never costs a signature.
 */
trigger SignForceFileCleanupTrigger on SignForce_File_Cleanup__e (after insert) {
    for (SignForce_File_Cleanup__e evt : Trigger.new) {
        if (String.isBlank(evt.Agreement_Id__c)) continue;
        try {
            Id agreementId = (Id) evt.Agreement_Id__c;
            Integer removed = AgreementFileCleanup.removeSupersededFiles(agreementId);
            System.debug(LoggingLevel.INFO,
                'SignForceFileCleanupTrigger: removed ' + removed + ' file(s) for ' + agreementId);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'SignForceFileCleanupTrigger skipped: ' + e.getMessage());
        }
    }
}