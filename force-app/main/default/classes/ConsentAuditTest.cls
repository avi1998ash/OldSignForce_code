/**
 * ConsentAuditTest — the per-signer consent-accepted audit event: written once,
 * carrying the signer's email and IP, and never duplicated.
 */
@IsTest
private class ConsentAuditTest {

    private static Signer__c makeSigner(Id agreementId, String email, String token) {
        Signer__c s = new Signer__c(
            Agreement__c = agreementId,
            Email__c = email,
            Role__c = 'Signer',
            Signing_Order__c = 1,
            Status__c = 'Pending',
            Access_Token__c = token,
            Token_Created_Date__c = DateTime.now(),
            Token_Expired__c = false,
            Token_View_Count__c = 0
        );
        insert s;
        return s;
    }

    private static Integer consentCount(Id agreementId, String email) {
        return [
            SELECT COUNT() FROM Signing_Event__c
            WHERE Agreement__c = :agreementId
            AND Action__c = 'Consent Accepted'
            AND Signer_Email__c = :email
        ];
    }

    @IsTest
    static void logConsent_writesOneEvent_andIsIdempotent() {
        Agreement__c agr = new Agreement__c(Name = 'Consent NDA', Status__c = 'Sent');
        insert agr;
        String token = 'tok_' + EncodingUtil.convertToHex(Crypto.generateAesKey(128)).substring(0, 28);
        makeSigner(agr.Id, 'signer@example.com', token);

        Test.startTest();
        GuestSigningApi.logConsentAccepted(token, '203.0.113.7', 'UnitTest-UA');
        GuestSigningApi.logConsentAccepted(token, '203.0.113.7', 'UnitTest-UA');   // again
        Test.stopTest();

        Assert.areEqual(1, consentCount(agr.Id, 'signer@example.com'),
            'Exactly one consent event even after a repeat call');

        Signing_Event__c ev = [
            SELECT IP_Address__c, User_Agent__c FROM Signing_Event__c
            WHERE Agreement__c = :agr.Id AND Action__c = 'Consent Accepted' LIMIT 1
        ];
        Assert.areEqual('203.0.113.7', ev.IP_Address__c, 'IP captured on the consent event');
        Assert.areEqual('UnitTest-UA', ev.User_Agent__c, 'User agent captured on the consent event');
    }

    @IsTest
    static void logConsent_unknownToken_noEventNoError() {
        Agreement__c agr = new Agreement__c(Name = 'Other', Status__c = 'Sent');
        insert agr;

        Test.startTest();
        GuestSigningApi.logConsentAccepted('tok_does_not_exist', '1.2.3.4', 'UA');
        GuestSigningApi.logConsentAccepted('', null, null);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Signing_Event__c WHERE Action__c = 'Consent Accepted'],
            'An unknown or blank token writes nothing and does not error');
    }
}