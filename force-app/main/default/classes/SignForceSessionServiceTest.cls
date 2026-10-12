/**
 * SignForceSessionServiceTest — the single-browser lock on a signing link.
 *
 * The promise to the sender is that a forwarded link is useless: once the
 * intended signer has consented on their own browser, nobody else can open the
 * document, incognito included. These tests pin that promise down, and equally
 * pin the escape hatch — resending the link must let the genuine signer back in,
 * because otherwise a signer who switches device is locked out for good.
 */
@IsTest
private class SignForceSessionServiceTest {

    private static Signer__c newSigner(String label, String email) {
        Agreement__c agr = TestDataFactory.createSentAgreement(label);
        return TestDataFactory.createSignerWithToken(agr.Id, email);
    }

    private static Integer blockedEvents(Id agreementId) {
        return [
            SELECT COUNT() FROM Signing_Event__c
            WHERE Agreement__c = :agreementId AND Action__c = 'Signing Session Blocked'
        ];
    }

    @IsTest
    static void firstClaimBindsAndValidates() {
        Signer__c signer = newSigner('Session Bind', 'first@example.com');

        Test.startTest();
        String session = SignForceSessionService.start(signer.Access_Token__c);
        Test.stopTest();

        Assert.isNotNull(session, 'The first browser to consent must be given a session');
        Assert.isTrue(SignForceSessionService.validate(signer.Access_Token__c, session),
            'The session just issued must validate');

        Signer__c after = [
            SELECT Session_Token_Hash__c, Session_Bound_At__c
            FROM Signer__c WHERE Id = :signer.Id
        ];
        Assert.isNotNull(after.Session_Bound_At__c, 'Binding time should be recorded');
        Assert.areNotEqual(session, after.Session_Token_Hash__c,
            'Only the HASH may be stored - never the raw session token');
    }

    /**
     * The whole point: a second browser, another device, or an incognito window
     * arrives with no session of its own and must be turned away.
     */
    @IsTest
    static void secondBrowserIsRefused() {
        Signer__c signer = newSigner('Session Lock', 'locked@example.com');
        String first = SignForceSessionService.start(signer.Access_Token__c);

        Test.startTest();
        String second = SignForceSessionService.start(signer.Access_Token__c);
        Test.stopTest();

        Assert.isNotNull(first, 'Sanity: the first claim should have succeeded');
        Assert.isNull(second, 'A forwarded link opened elsewhere must be refused');
        Assert.isTrue(SignForceSessionService.validate(signer.Access_Token__c, first),
            'The refused attempt must not disturb the genuine signer session');
    }

    @IsTest
    static void refusedAttemptIsAudited() {
        Signer__c signer = newSigner('Session Audit', 'audit@example.com');
        SignForceSessionService.start(signer.Access_Token__c);

        Test.startTest();
        SignForceSessionService.start(signer.Access_Token__c);
        Test.stopTest();

        Assert.areEqual(1, blockedEvents(signer.Agreement__c),
            'A blocked open is exactly what a sender needs to see in the audit trail');
    }

    @IsTest
    static void wrongOrMissingSessionNeverValidates() {
        Signer__c signer = newSigner('Session Reject', 'reject@example.com');

        Test.startTest();
        Assert.isFalse(SignForceSessionService.validate(signer.Access_Token__c, null),
            'No session token means no access');
        Assert.isFalse(SignForceSessionService.validate(signer.Access_Token__c, ''),
            'A blank session token means no access');

        SignForceSessionService.start(signer.Access_Token__c);
        Assert.isFalse(SignForceSessionService.validate(signer.Access_Token__c, 'not-the-real-one'),
            'A guessed session token must not open the document');
        Test.stopTest();
    }

    /**
     * Recovery. A signer who switches device is locked out by design, so the
     * resend path MUST clear the binding — without this the lock is a trap.
     */
    @IsTest
    static void resendingTheLinkClearsTheBinding() {
        Signer__c signer = newSigner('Session Reset', 'reset@example.com');
        String first = SignForceSessionService.start(signer.Access_Token__c);
        Assert.isNotNull(first, 'Sanity: first claim should succeed');

        // What AgreementService does when a sender resends: new access token,
        // binding wiped.
        Test.startTest();
        Signer__c reset = new Signer__c(
            Id = signer.Id,
            Access_Token__c = AgreementService.generateToken(),
            Session_Token_Hash__c = null,
            Session_Bound_At__c = null
        );
        update reset;

        Signer__c reloaded = [SELECT Access_Token__c FROM Signer__c WHERE Id = :signer.Id];
        String second = SignForceSessionService.start(reloaded.Access_Token__c);
        Test.stopTest();

        Assert.isNotNull(second,
            'After a resend the signer must be able to claim the link again');
        Assert.isFalse(SignForceSessionService.validate(reloaded.Access_Token__c, first),
            'The old session must not survive a resend');
    }

    /** Two signers on one agreement hold independent locks. */
    @IsTest
    static void signersDoNotShareALock() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Session Multi');
        Signer__c a = TestDataFactory.createSignerWithToken(agr.Id, 'a@example.com');
        Signer__c b = TestDataFactory.createSignerWithToken(agr.Id, 'b@example.com');

        Test.startTest();
        String sessionA = SignForceSessionService.start(a.Access_Token__c);
        String sessionB = SignForceSessionService.start(b.Access_Token__c);
        Test.stopTest();

        Assert.isNotNull(sessionA, 'Signer A claims their own link');
        Assert.isNotNull(sessionB,
            'Signer B has their own token and record - A claiming must not lock B out');
        Assert.isFalse(SignForceSessionService.validate(a.Access_Token__c, sessionB),
            'One signer session must not open another signer link');
    }
}