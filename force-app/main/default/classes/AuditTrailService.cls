/**
 * AuditTrailService - internal-user utility for inserting Signing_Event__c
 * audit rows. Captures action, signer email, IP, and user agent.
 *
 * SHARING: `with sharing`. Every caller of this class is an internal-user
 * class (AgreementController, AgreementService, CommentController,
 * AgreementScheduledJobs, SignForceBulkSend). The guest signing flows use
 * AuditTrailServiceGuest, which holds a verbatim copy of these methods.
 */
public with sharing class AuditTrailService {

    /**
     * Overload that records a diagnostic note alongside the event.
     *
     * Added because failure details were being lost: callers logging a failure
     * passed the error text as the fifth argument, which this class binds to
     * User_Agent__c — so "Stamped Document Failed" rows carried an empty
     * Notes__c and the reason sat in a field nobody reads. Notes__c is the field
     * the record page shows.
     */
    public static void log(Id agreementId, String action, String signerEmail,
                           String ipAddress, String userAgent, String notes) {
        try {
            Signing_Event__c evt = new Signing_Event__c();
            evt.Agreement__c = agreementId;
            evt.Action__c = action;
            evt.Signer_Email__c = signerEmail;
            evt.IP_Address__c = ipAddress;
            evt.User_Agent__c = userAgent;
            evt.Notes__c = (notes != null && notes.length() > 255)
                ? notes.substring(0, 255) : notes;
            evt.Event_Timestamp__c = DateTime.now();
            // CRUD assertion on the object being written. Signing_Event__c create is
            // granted to internal users by SignForce_User and to the site guest by
            // SignForce_Guest_User_Access, so every context that reaches here passes.
            // Should a subscriber revoke it, the catch below keeps logging best-effort.
            if (!Schema.sObjectType.Signing_Event__c.isCreateable()) {
                throw new SignForceFLS.SignForceFLSException(
                    'Insufficient access to create Signing Event records.');
            }
            insert evt;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'AuditTrailService.log failed (non-fatal): ' + e.getMessage());
        }
    }

    public static void log(Id agreementId, String action, String signerEmail, String ipAddress, String userAgent) {
        // Audit logging is best-effort: a failure here (e.g. guest FLS/validation)
        // must NEVER break the signing flow it is recording. Swallow + log only.
        try {
            Signing_Event__c evt = new Signing_Event__c();
            evt.Agreement__c = agreementId;
            evt.Action__c = action;
            evt.Signer_Email__c = signerEmail;
            evt.IP_Address__c = ipAddress;
            evt.User_Agent__c = userAgent;
            evt.Event_Timestamp__c = DateTime.now();
            // Same CRUD assertion as the overload above; the catch keeps it best-effort.
            if (!Schema.sObjectType.Signing_Event__c.isCreateable()) {
                throw new SignForceFLS.SignForceFLSException(
                    'Insufficient access to create Signing Event records.');
            }
            insert evt;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'AuditTrailService.log failed (non-fatal): ' + e.getMessage());
        }
    }
}