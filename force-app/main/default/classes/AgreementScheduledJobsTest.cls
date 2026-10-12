/**
 * AgreementScheduledJobsTest — covers the Schedulable that runs daily
 * to expire agreements and send reminders.
 */
@isTest(SeeAllData=false)
private class AgreementScheduledJobsTest {

    @isTest
    static void execute_expiresAgedAgreements_andVoidsSigners() {
        // Create an agreement with an expiry date in the past
        Agreement__c agr = TestDataFactory.createSentAgreement('Expired Test');
        agr.Expiry_Date__c = DateTime.now().addDays(-1);
        update agr;

        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'exp@example.com');

        Test.startTest();
        // Schedule via System.schedule — Salesforce executes the job
        // when stopTest() runs
        String cronExp = '0 0 0 1 1 ? 2099';
        String jobId = System.schedule('TestJob_' + DateTime.now().getTime(),
                                       cronExp, new AgreementScheduledJobs());
        Assert.isNotNull(jobId, 'Job should have been scheduled');
        Test.stopTest();

        // Manually invoke execute() too, since System.schedule with a future
        // cronExp won't actually run the job body in this test.
        AgreementScheduledJobs job = new AgreementScheduledJobs();
        job.execute(null);

        Agreement__c reloaded = [SELECT Status__c, Void_Reason__c FROM Agreement__c WHERE Id = :agr.Id];
        Assert.areEqual('Voided', reloaded.Status__c,
            'Expired agreement should be voided by the scheduled job');
        Assert.areEqual('Auto-expired', reloaded.Void_Reason__c);

        Signer__c reloadedSigner = [SELECT Status__c, Token_Expired__c FROM Signer__c WHERE Id = :signer.Id];
        Assert.isTrue(reloadedSigner.Token_Expired__c,
            'Signer token should be expired');
    }

    @isTest
    static void execute_nonExpiredAgreement_isUntouched() {
        // Agreement still within expiry → should NOT be voided
        Agreement__c agr = TestDataFactory.createSentAgreement('Not Yet Expired');
        agr.Expiry_Date__c = DateTime.now().addDays(7);
        update agr;

        Test.startTest();
        AgreementScheduledJobs job = new AgreementScheduledJobs();
        job.execute(null);
        Test.stopTest();

        Agreement__c reloaded = [SELECT Status__c FROM Agreement__c WHERE Id = :agr.Id];
        Assert.areEqual('Sent', reloaded.Status__c,
            'Non-expired agreement should remain in Sent status');
    }

    @isTest
    static void execute_noAgreements_doesNotThrow() {
        Test.startTest();
        AgreementScheduledJobs job = new AgreementScheduledJobs();
        job.execute(null);
        Test.stopTest();

        // Nothing to expire means the expiry branch must write nothing —
        // it logs one Signing_Event__c per agreement it voids.
        Assert.areEqual(0, [SELECT COUNT() FROM Signing_Event__c],
            'With no agreements in scope the job must void nothing and log no expiry events');
    }
}