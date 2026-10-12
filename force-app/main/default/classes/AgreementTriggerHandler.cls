/**
 * AgreementTriggerHandler - logic for AgreementTrigger (after update).
 *
 * When an Agreement__c transitions to Completed, queue the Lambda-based
 * stamping flow (S3-backed, handles any file size). Async because Apex
 * triggers cannot make synchronous HTTP callouts.
 *
 * SECURITY: The trigger runs in system context. This class does no SOQL or
 * DML itself (`with sharing` therefore changes nothing); the async method it
 * calls (AgreementController.generateStampedPDFServerAsync) does its own FLS
 * guards on every DML, per the SignForceFLS pattern.
 *
 * Moved out of the trigger body so it can be unit-tested directly. Behaviour
 * is unchanged except that the former `!Test.isRunningTest()` wrapper is gone:
 * tests that complete an agreement without wanting a stamp set
 * AgreementControllerGuest.suppressCompletionStampTrigger = true.
 */
public with sharing class AgreementTriggerHandler {

    public static void afterUpdate(List<Agreement__c> newList, Map<Id, Agreement__c> oldMap) {
        Set<Id> completedNow = newlyCompleted(newList, oldMap);

        // Guest signing queues its own stamp (it owns the completion email that runs
        // after it) and sets this flag in the same transaction. Without the check both
        // it and this trigger queued an @future stamp; the two ran at once, neither had
        // committed a Stamped row for the other to see, and both called the backend -
        // leaving two identical stamped PDFs in the customer's Drive.
        if (completedNow.isEmpty() || AgreementControllerGuest.suppressCompletionStampTrigger) {
            return;
        }

        // @future runs async - required because Lambda stamping makes callouts.
        // Bulkified: one async call per agreement that completed this transaction.
        for (Id agreementId : completedNow) {
            AgreementController.generateStampedPDFServerAsync(agreementId);
        }
    }

    /** Ids of agreements whose Status__c changed to 'Completed' in this update. */
    public static Set<Id> newlyCompleted(List<Agreement__c> newList, Map<Id, Agreement__c> oldMap) {
        Set<Id> completedNow = new Set<Id>();
        for (Agreement__c agr : newList) {
            Agreement__c old = oldMap.get(agr.Id);
            if (agr.Status__c == 'Completed' && old.Status__c != 'Completed') {
                completedNow.add(agr.Id);
            }
        }
        return completedNow;
    }
}
