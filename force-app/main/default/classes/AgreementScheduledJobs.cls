/**
 * @description : Scheduled job for auto-reminders and auto-expiry
 *                Schedule daily: System.schedule('SignForce Daily', '0 0 9 * * ?', new AgreementScheduledJobs());
 * @author      : SignForce
 */
public with sharing class AgreementScheduledJobs implements Schedulable {

    public void execute(SchedulableContext sc) {
        // Run both jobs
        handleExpiredAgreements();
        handleAutoReminders();
    }

    /**
     * Auto-expire agreements past their expiry date
     */
    private void handleExpiredAgreements() {
        List<Agreement__c> expiredAgreements = [
            SELECT Id, Name, Status__c, Expiry_Date__c
            FROM Agreement__c
            WHERE Status__c = 'Sent'
            AND Expiry_Date__c != null
            AND Expiry_Date__c < :DateTime.now()
            LIMIT 100
        ];

        List<Agreement__c> toUpdate = new List<Agreement__c>();
        for (Agreement__c agr : expiredAgreements) {
            agr.Status__c = 'Voided';
            agr.Void_Reason__c = 'Auto-expired';
            agr.Voided_Date__c = DateTime.now();
            toUpdate.add(agr);
            AuditTrailService.log(agr.Id, 'Agreement Expired', 'scheduledjob@signforce.com', null, 'Auto-expired by scheduled job');
        }

        if (!toUpdate.isEmpty()) {
            // CRUD guard only; DML deliberately stays in system context. This is a
            // Schedulable running as whichever admin scheduled it, and expiry must
            // process EVERY overdue agreement in the org regardless of record owner.
            // USER_MODE would silently skip agreements the scheduling admin cannot
            // edit, which is a behaviour break — so we assert object-level update
            // permission and keep the DML in system context.
            SignForceFLS.requireUpdateable(Agreement__c.SObjectType);
            // Inline mirror of the guard above. The static scanner does not trace into
            // SignForceFLS, so the same describe check is repeated where it sits directly
            // on the flow into the DML. Unreachable once requireUpdateable has passed.
            if (!Schema.sObjectType.Agreement__c.isUpdateable()) {
                throw new SignForceFLS.SignForceFLSException(
                    'Insufficient access to update Agreement records.');
            }
            update toUpdate;

            // Expire all pending signer tokens
            Set<Id> agrIds = new Set<Id>();
            for (Agreement__c a : toUpdate) agrIds.add(a.Id);

            List<Signer__c> signers = [
                SELECT Id, Token_Expired__c, Status__c
                FROM Signer__c
                WHERE Agreement__c IN :agrIds
                AND Status__c NOT IN ('Signed', 'Declined')
            ];
            for (Signer__c s : signers) {
                s.Token_Expired__c = true;
                s.Status__c = 'Voided';
            }
            // Same rationale as above: object-level guard, system-context DML,
            // so token expiry cannot silently skip signers on unowned agreements.
            if (!signers.isEmpty()) {
                SignForceFLS.requireUpdateable(Signer__c.SObjectType);
                // Inline mirror of the guard above — same rationale as the Agreement update.
                if (!Schema.sObjectType.Signer__c.isUpdateable()) {
                    throw new SignForceFLS.SignForceFLSException(
                        'Insufficient access to update Signer records.');
                }
                update signers;
            }
        }

        System.debug('SignForce Scheduled: Expired ' + toUpdate.size() + ' agreements');
    }

    /**
     * Auto-send reminders for agreements pending > 24 hours
     * Only sends if no reminder was sent in the last 24 hours
     */
    private void handleAutoReminders() {
        DateTime oneDayAgo = DateTime.now().addHours(-24);

        List<Agreement__c> needReminder = [
            SELECT Id, Name, Sent_Date__c, Last_Reminder_Sent__c
            FROM Agreement__c
            WHERE Status__c = 'Sent'
            AND Sent_Date__c < :oneDayAgo
            AND (Last_Reminder_Sent__c = null OR Last_Reminder_Sent__c < :oneDayAgo)
            LIMIT 50
        ];

        for (Agreement__c agr : needReminder) {
            try {
                AgreementService.sendBulkReminders(agr.Id);
            } catch(Exception e) {
                System.debug('SignForce Scheduled: Reminder failed for ' + agr.Id + ': ' + e.getMessage());
            }
        }

        System.debug('SignForce Scheduled: Sent reminders for ' + needReminder.size() + ' agreements');
    }
}