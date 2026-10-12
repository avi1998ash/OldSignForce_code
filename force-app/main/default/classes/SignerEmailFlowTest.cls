/**
 * SignerEmailFlowTest — the sequential multi-signer email rules.
 *
 * Every signer, including the last, gets a "you have signed successfully"
 * confirmation with no attachment. A single-signer agreement is deliberately
 * different: that person receives ONE email in total, the completion one, which
 * both confirms their signature and carries the documents.
 *
 * The confirmations are counted through the 'Signed Confirmation Emailed' audit
 * event, which sendSignedConfirmationEmail writes once per email it sends. Test
 * context does not deliver mail, so the audit trail is the observable record of
 * who was written to, and it survives regardless of send limits.
 */
@IsTest
private class SignerEmailFlowTest {

    private static Agreement__c makeAgreement() {
        Agreement__c agr = AgreementService.createAgreement(
            'Email Flow Agreement', 'Contract', 'Sequential', 'Please sign.', null
        );
        agr.OwnerId = UserInfo.getUserId();
        update agr;
        return agr;
    }

    private static Signer__c makeSigner(Id agreementId, String email, Integer order) {
        Signer__c s = new Signer__c(
            Agreement__c          = agreementId,
            Email__c              = email,
            Role__c               = 'Signer',
            Signing_Order__c      = order,
            Status__c             = 'Pending',
            Access_Token__c       = 'tok_' + EncodingUtil.convertToHex(
                Crypto.generateAesKey(128)).substring(0, 28),
            Token_Created_Date__c = DateTime.now(),
            Token_Expired__c      = false,
            Token_View_Count__c   = 0
        );
        insert s;
        return s;
    }

    private static Integer confirmationCount(Id agreementId) {
        return [
            SELECT COUNT() FROM Signing_Event__c
            WHERE Agreement__c = :agreementId
            AND Action__c = 'Signed Confirmation Emailed'
        ];
    }

    /** Signs every signer in order, oldest first. */
    private static void signAll(Id agreementId) {
        for (Signer__c s : [
            SELECT Id FROM Signer__c
            WHERE Agreement__c = :agreementId AND Role__c = 'Signer'
            ORDER BY Signing_Order__c ASC NULLS LAST
        ]) {
            AgreementService.markSigned(s.Id, '1.1.1.1', 'test-agent');
        }
    }

    @IsTest
    static void oneSigner_sendsNoConfirmation() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement();
        makeSigner(agr.Id, 'solo@example.com', 1);

        Test.startTest();
        signAll(agr.Id);
        Test.stopTest();

        Assert.areEqual(0, confirmationCount(agr.Id),
            'A sole signer must not get a separate confirmation — their single completion email covers it');
        Assert.areEqual('Completed',
            [SELECT Status__c FROM Agreement__c WHERE Id = :agr.Id].Status__c,
            'Agreement should complete once the only signer signs');
    }

    @IsTest
    static void twoSigners_confirmAllButTheLast() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement();
        makeSigner(agr.Id, 's1@example.com', 1);
        makeSigner(agr.Id, 's2@example.com', 2);

        Test.startTest();
        signAll(agr.Id);
        Test.stopTest();

        // Only the FIRST signer is confirmed. The second one completes the
        // agreement, so the all-parties email covers their signature instead.
        Assert.areEqual(1, confirmationCount(agr.Id),
            'The last signer gets the all-parties email, not a separate confirmation');
        Assert.areEqual('Completed',
            [SELECT Status__c FROM Agreement__c WHERE Id = :agr.Id].Status__c,
            'Agreement should complete after the second signer');
    }

    @IsTest
    static void threeSigners_confirmAllButTheLast() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement();
        makeSigner(agr.Id, 'a@example.com', 1);
        makeSigner(agr.Id, 'b@example.com', 2);
        makeSigner(agr.Id, 'c@example.com', 3);

        Test.startTest();
        signAll(agr.Id);
        Test.stopTest();

        Assert.areEqual(2, confirmationCount(agr.Id),
            'Signers 1 and 2 are confirmed; the third completes and gets the all-parties email');
    }

    @IsTest
    static void fiveSigners_confirmAllButTheLast() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement();
        for (Integer i = 1; i <= 5; i++) {
            makeSigner(agr.Id, 'signer' + i + '@example.com', i);
        }

        Test.startTest();
        signAll(agr.Id);
        Test.stopTest();

        Assert.areEqual(4, confirmationCount(agr.Id),
            'Signers 1-4 are confirmed; the fifth completes and gets the all-parties email');
    }

    /**
     * CC and Approver rows must not change which branch runs. Two real signers
     * plus a CC is still a two-signer agreement, so both signers are confirmed and
     * the CC is never told "you have signed".
     */
    @IsTest
    static void ccDoesNotCountAsASigner() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement();
        makeSigner(agr.Id, 'real1@example.com', 1);
        makeSigner(agr.Id, 'real2@example.com', 2);

        Signer__c cc = new Signer__c(
            Agreement__c          = agr.Id,
            Email__c              = 'watcher@example.com',
            Role__c               = 'CC',
            Signing_Order__c      = 3,
            Status__c             = 'Pending',
            Access_Token__c       = 'tok_' + EncodingUtil.convertToHex(
                Crypto.generateAesKey(128)).substring(0, 28),
            Token_Created_Date__c = DateTime.now(),
            Token_Expired__c      = false,
            Token_View_Count__c   = 0
        );
        insert cc;

        Test.startTest();
        signAll(agr.Id);
        Test.stopTest();

        Assert.areEqual(1, confirmationCount(agr.Id),
            'Only the first signer is confirmed; the CC is not a signer and the last completes');
        Assert.areEqual(0, [
            SELECT COUNT() FROM Signing_Event__c
            WHERE Agreement__c = :agr.Id
            AND Action__c = 'Signed Confirmation Emailed'
            AND Signer_Email__c = 'watcher@example.com'
        ], 'A CC must never receive a "you have signed" confirmation');
    }

    /**
     * A lone signer alongside a CC is still a SOLE signer — the CC must not push
     * it onto the multi-signer path and produce an extra email.
     */
    @IsTest
    static void oneSignerPlusCc_isStillSoleSigner() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement();
        makeSigner(agr.Id, 'only@example.com', 1);

        Signer__c cc = new Signer__c(
            Agreement__c          = agr.Id,
            Email__c              = 'cc@example.com',
            Role__c               = 'CC',
            Signing_Order__c      = 2,
            Status__c             = 'Pending',
            Access_Token__c       = 'tok_' + EncodingUtil.convertToHex(
                Crypto.generateAesKey(128)).substring(0, 28),
            Token_Created_Date__c = DateTime.now(),
            Token_Expired__c      = false,
            Token_View_Count__c   = 0
        );
        insert cc;

        Test.startTest();
        signAll(agr.Id);
        Test.stopTest();

        Assert.areEqual(0, confirmationCount(agr.Id),
            'One Signer plus a CC is still a sole-signer agreement');
    }
}