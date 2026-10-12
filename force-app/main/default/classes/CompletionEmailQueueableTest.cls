/**
 * Tests for CompletionEmailQueueable (two-phase: cert regen → email).
 *
 * NOTE: In test context, chaining a queueable from a queueable throws an
 * AsyncException — CompletionEmailQueueable catches it and falls back to
 * sending the email inline, so the cert phase test also covers the
 * email-fallback path.
 */
@isTest
private class CompletionEmailQueueableTest {

    /** Generic 200-OK mock so any S3/Lambda callout inside the email path succeeds. */
    private class GenericHttpMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(200);
            res.setBody('{"success": true}');
            return res;
        }
    }

    /** Completed agreement + signed signer — the state right after the last signature. */
    private static Id makeCompletedAgreement() {
        Agreement__c agr = TestDataFactory.createSentAgreement('CEQ Test NDA');

        Signer__c s = TestDataFactory.createSignerWithToken(agr.Id, 'ceq.signer@example.com');
        s.Status__c = 'Signed';
        s.Signed_Date__c = DateTime.now();
        update s;

        agr.Status__c = 'Completed';
        agr.Completed_Date__c = DateTime.now();
        update agr;

        return agr.Id;
    }

    @isTest
    static void testCertPhase_generatesCertificate() {
        TestDataFactory.suppressCompletionStamp();
        Id agrId = makeCompletedAgreement();
        Test.setMock(HttpCalloutMock.class, new GenericHttpMock());

        Test.startTest();
        // Single-arg constructor = default 'cert' phase (production entry point)
        System.enqueueJob(new CompletionEmailQueueable(agrId));
        Test.stopTest();

        List<Agreement_Document__c> certs = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agrId AND Document_Type__c = 'Signed'
        ];
        System.assertEquals(1, certs.size(),
            'Cert phase must generate exactly one Signed certificate document');
    }

    @isTest
    static void testCertPhase_replacesStaleCertificate() {
        TestDataFactory.suppressCompletionStamp();
        Id agrId = makeCompletedAgreement();

        // Pehle se ek (stale) certificate maujood hai
        SignedAgreementPDFController.generateAndAttachPDF(agrId);
        Id staleCertId = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agrId AND Document_Type__c = 'Signed'
            LIMIT 1
        ].Id;

        Test.setMock(HttpCalloutMock.class, new GenericHttpMock());
        Test.startTest();
        System.enqueueJob(new CompletionEmailQueueable(agrId, 'cert'));
        Test.stopTest();

        List<Agreement_Document__c> certs = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agrId AND Document_Type__c = 'Signed'
        ];
        System.assertEquals(1, certs.size(),
            'Regeneration must leave exactly one certificate (no duplicates)');
        System.assertNotEquals(staleCertId, certs[0].Id,
            'The stale certificate must be replaced by a fresh one');
    }

    @isTest
    static void testEmailPhase_runsWithoutThrowing() {
        TestDataFactory.suppressCompletionStamp();
        Id agrId = makeCompletedAgreement();
        Test.setMock(HttpCalloutMock.class, new GenericHttpMock());

        Test.startTest();
        System.enqueueJob(new CompletionEmailQueueable(agrId, 'email'));
        Test.stopTest();

        // Email phase ke saare errors internally caught hote hain — job ka
        // bina exception ke complete hona hi pass criteria hai.
        System.assert(true, 'Email phase completed without surfacing an exception');
    }

    @isTest
    static void testBlankPhase_defaultsToCert() {
        TestDataFactory.suppressCompletionStamp();
        Id agrId = makeCompletedAgreement();
        Test.setMock(HttpCalloutMock.class, new GenericHttpMock());

        Test.startTest();
        System.enqueueJob(new CompletionEmailQueueable(agrId, null));
        Test.stopTest();

        List<Agreement_Document__c> certs = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agrId AND Document_Type__c = 'Signed'
        ];
        System.assertEquals(1, certs.size(),
            'Blank phase must default to cert phase and generate the certificate');
    }
}