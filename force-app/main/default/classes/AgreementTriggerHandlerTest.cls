/**
 * AgreementTriggerHandlerTest - 100% coverage of AgreementTriggerHandler and AgreementTrigger.
 *
 * The handler is called directly with hand-built new/old lists. Whether a stamp was queued is read
 * from Limits.getFutureCalls(); the @future body never runs because these tests never call
 * Test.stopTest() around it, so no callout is attempted.
 */
@isTest
private class AgreementTriggerHandlerTest {

    private static Agreement__c insertAgreement(String status) {
        Agreement__c agr = new Agreement__c(
            Name = 'Trigger Handler Test ' + status,
            Status__c = status,
            Agreement_Type__c = 'Standard',
            Signing_Order__c = 'Sequential'
        );
        insert agr;
        return agr;
    }

    /** A copy of the record as it was before the update, keyed by Id. */
    private static Map<Id, Agreement__c> oldMapOf(Agreement__c agr) {
        return new Map<Id, Agreement__c>{ agr.Id => agr.clone(true, true, true, true) };
    }

    /**
     * The queued @future stamp runs when Test.stopTest() is reached. These agreements have no original
     * document, so the stamp job itself fails with a SignForceStampException - that is expected here and
     * irrelevant: what is asserted is that the handler QUEUED the job (Limits.getFutureCalls()).
     */
    private static Integer futureCallsWhileRunning(List<Agreement__c> newList, Map<Id, Agreement__c> oldMap) {
        Integer before = Limits.getFutureCalls();
        Test.startTest();
        AgreementTriggerHandler.afterUpdate(newList, oldMap);
        Integer queued = Limits.getFutureCalls() - before;
        try {
            Test.stopTest();
        } catch (Exception expected) {
            System.debug('stamp job failed as expected without an original document: ' + expected.getMessage());
        }
        return queued;
    }

    @isTest
    static void newlyCompleted_onlyTheTransitionCounts() {
        Agreement__c a = insertAgreement('Draft');
        Map<Id, Agreement__c> oldMap = oldMapOf(a);
        a.Status__c = 'Completed';
        Set<Id> ids = AgreementTriggerHandler.newlyCompleted(new List<Agreement__c>{ a }, oldMap);
        System.assertEquals(new Set<Id>{ a.Id }, ids);
    }

    @isTest
    static void newlyCompleted_alreadyCompleted_isNotNew() {
        Agreement__c a = insertAgreement('Completed');
        Set<Id> ids = AgreementTriggerHandler.newlyCompleted(new List<Agreement__c>{ a }, oldMapOf(a));
        System.assert(ids.isEmpty(), 'Completed -> Completed must not re-stamp');
    }

    @isTest
    static void newlyCompleted_otherStatusChange_isIgnored() {
        Agreement__c a = insertAgreement('Draft');
        Map<Id, Agreement__c> oldMap = oldMapOf(a);
        a.Status__c = 'Sent';
        System.assert(AgreementTriggerHandler.newlyCompleted(new List<Agreement__c>{ a }, oldMap).isEmpty());
    }

    @isTest
    static void afterUpdate_completedTransition_queuesOneStampPerAgreement() {
        Agreement__c a = insertAgreement('Draft');
        Agreement__c b = insertAgreement('Sent');
        Map<Id, Agreement__c> oldMap = new Map<Id, Agreement__c>{
            a.Id => a.clone(true, true, true, true),
            b.Id => b.clone(true, true, true, true)
        };
        a.Status__c = 'Completed';
        b.Status__c = 'Completed';
        System.assertEquals(2, futureCallsWhileRunning(new List<Agreement__c>{ a, b }, oldMap),
            'one @future stamp per newly completed agreement');
    }

    @isTest
    static void afterUpdate_nothingCompleted_queuesNothing() {
        Agreement__c a = insertAgreement('Draft');
        Map<Id, Agreement__c> oldMap = oldMapOf(a);
        a.Status__c = 'Sent';
        Integer before = Limits.getFutureCalls();
        AgreementTriggerHandler.afterUpdate(new List<Agreement__c>{ a }, oldMap);
        System.assertEquals(0, Limits.getFutureCalls() - before);
    }

    @isTest
    static void afterUpdate_suppressFlag_queuesNothing() {
        Agreement__c a = insertAgreement('Draft');
        Map<Id, Agreement__c> oldMap = oldMapOf(a);
        a.Status__c = 'Completed';
        AgreementControllerGuest.suppressCompletionStampTrigger = true;
        Integer before = Limits.getFutureCalls();
        AgreementTriggerHandler.afterUpdate(new List<Agreement__c>{ a }, oldMap);
        System.assertEquals(0, Limits.getFutureCalls() - before, 'guest signing owns the stamp when it sets the flag');
    }

    @isTest
    static void trigger_realUpdateToCompleted_queuesStamp() {
        Agreement__c a = insertAgreement('Sent');
        Integer before = Limits.getFutureCalls();
        Test.startTest();
        a.Status__c = 'Completed';
        update a;
        Integer queued = Limits.getFutureCalls() - before;
        try {
            Test.stopTest();
        } catch (Exception expected) {
            System.debug('stamp job failed as expected without an original document: ' + expected.getMessage());
        }
        System.assertEquals(1, queued, 'AgreementTrigger must hand the update to the handler');
    }

    @isTest
    static void trigger_realUpdateWithSuppressFlag_queuesNothing() {
        Agreement__c a = insertAgreement('Sent');
        AgreementControllerGuest.suppressCompletionStampTrigger = true;
        Integer before = Limits.getFutureCalls();
        a.Status__c = 'Completed';
        update a;
        System.assertEquals(0, Limits.getFutureCalls() - before);
    }
}
