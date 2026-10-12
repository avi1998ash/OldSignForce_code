/**
 * AgreementControllerGuestOtpTest — tests for the emailed one-time-code
 * identity gate on the guest signing portal (sendSigningOtp / verifySigningOtp
 * on AgreementControllerGuest, semantics owned by OTPService).
 *
 * Covers the full contract: send happy path, cooldown refusal, verify happy
 * path, wrong-code attempt burn, lockout at five wrong attempts (code
 * invalidated), 10-minute expiry, resend resetting the attempt counter, the
 * otpVerified flag in the validateToken payload, and invalid-token rejection.
 * Assertions are on OUTCOMES (stored field state, audit rows, contract keys),
 * not just "no exception".
 */
@isTest(SeeAllData=false)
private class AgreementControllerGuestOtpTest {

    private static Signer__c freshSigner(String agreementName, String email) {
        Agreement__c agr = TestDataFactory.createSentAgreement(agreementName);
        return TestDataFactory.createSignerWithToken(agr.Id, email);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  sendSigningOtp
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void sendSigningOtp_freshSigner_sendsCodeAndAudits() {
        Signer__c signer = freshSigner('OTP Send OK', 'otp.send@example.com');

        Test.startTest();
        Map<String, Object> result = AgreementControllerGuest.sendSigningOtp(signer.Access_Token__c);
        Test.stopTest();

        Assert.areEqual(true, result.get('success'), 'Fresh signer send must succeed');
        Assert.areEqual('ot***@example.com', result.get('maskedEmail'),
            'Masked email must be first 2 chars + ***@domain');
        Assert.areEqual(60, result.get('cooldownSeconds'),
            'Successful send returns the full cooldown for the client countdown');

        Signer__c after = [
            SELECT OTP_Code__c, OTP_Sent_At__c, OTP_Attempts__c, OTP_Verified__c
            FROM Signer__c WHERE Id = :signer.Id
        ];
        Assert.isTrue(String.isNotBlank(after.OTP_Code__c), 'Code must be stored on the signer');
        Assert.areEqual(6, after.OTP_Code__c.length(), 'Code must be 6 digits');
        Assert.isTrue(after.OTP_Code__c.isNumeric(), 'Code must be numeric');
        Assert.isNotNull(after.OTP_Sent_At__c, 'Sent-at timestamp must be stamped');
        Assert.areEqual(0, after.OTP_Attempts__c.intValue(), 'Attempt counter starts at 0');
        Assert.isFalse(after.OTP_Verified__c, 'Signer is not verified by a send');

        Integer audits = [
            SELECT COUNT() FROM Signing_Event__c
            WHERE Agreement__c = :signer.Agreement__c AND Action__c = 'OTP Sent'
        ];
        Assert.areEqual(1, audits, 'Exactly one OTP Sent audit row must be logged');
    }

    @isTest
    static void sendSigningOtp_within60s_refusedWithCooldown() {
        Signer__c signer = freshSigner('OTP Cooldown', 'cool@example.com');

        Test.startTest();
        Map<String, Object> first = AgreementControllerGuest.sendSigningOtp(signer.Access_Token__c);
        String codeAfterFirst = [SELECT OTP_Code__c FROM Signer__c WHERE Id = :signer.Id].OTP_Code__c;
        Map<String, Object> second = AgreementControllerGuest.sendSigningOtp(signer.Access_Token__c);
        Test.stopTest();

        Assert.areEqual(true, first.get('success'), 'First send must succeed');
        Assert.areEqual(false, second.get('success'), 'Second send within 60s must be refused');
        Integer cooldown = (Integer) second.get('cooldownSeconds');
        Assert.isTrue(cooldown > 0 && cooldown <= 60,
            'Refusal must carry the remaining cooldown, got ' + cooldown);

        Signer__c after = [SELECT OTP_Code__c FROM Signer__c WHERE Id = :signer.Id];
        Assert.areEqual(codeAfterFirst, after.OTP_Code__c,
            'A refused resend must not rotate the stored code');

        Integer audits = [
            SELECT COUNT() FROM Signing_Event__c
            WHERE Agreement__c = :signer.Agreement__c AND Action__c = 'OTP Sent'
        ];
        Assert.areEqual(1, audits, 'The refused resend must not add a second audit row');
    }

    @isTest
    static void sendSigningOtp_resendAfterCooldown_resetsAttempts() {
        Signer__c signer = freshSigner('OTP Resend Reset', 'reset@example.com');

        Test.startTest();
        AgreementControllerGuest.sendSigningOtp(signer.Access_Token__c);
        // Burn two attempts ('000000' can never collide — real codes are 100000+).
        AgreementControllerGuest.verifySigningOtp(signer.Access_Token__c, '000000');
        AgreementControllerGuest.verifySigningOtp(signer.Access_Token__c, '000000');
        // Age the send past the cooldown so a resend is allowed.
        update new Signer__c(Id = signer.Id, OTP_Sent_At__c = DateTime.now().addSeconds(-61));
        Map<String, Object> resend = AgreementControllerGuest.sendSigningOtp(signer.Access_Token__c);
        Test.stopTest();

        Assert.areEqual(true, resend.get('success'), 'Resend after the cooldown must succeed');

        Signer__c after = [SELECT OTP_Code__c, OTP_Attempts__c FROM Signer__c WHERE Id = :signer.Id];
        Assert.areEqual(0, after.OTP_Attempts__c.intValue(),
            'A fresh code must reset the attempt counter');
        Assert.isTrue(String.isNotBlank(after.OTP_Code__c), 'A fresh code must be stored');
    }

    @isTest
    static void sendSigningOtp_alreadyVerified_stillSendsForNewTab() {
        // Verification is bound to the browser tab (sessionStorage in the viewer),
        // so a NEW tab/window legitimately needs a fresh code even after this
        // signer verified elsewhere. sendSigningOtp therefore sends rather than
        // refusing, and the fresh code resets server-side verification.
        Signer__c signer = freshSigner('OTP Already Verified', 'done@example.com');
        update new Signer__c(Id = signer.Id, OTP_Verified__c = true);

        Test.startTest();
        Map<String, Object> result = AgreementControllerGuest.sendSigningOtp(signer.Access_Token__c);
        Test.stopTest();

        Assert.areEqual(true, result.get('success'),
            'A new tab must be able to request a fresh code');
        Signer__c after = [SELECT OTP_Verified__c, OTP_Code__c FROM Signer__c WHERE Id = :signer.Id];
        Assert.isFalse(after.OTP_Verified__c,
            'A fresh code resets server-side verification (the tab proof gates the client)');
        Assert.isNotNull(after.OTP_Code__c, 'A fresh code must be stored');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  verifySigningOtp
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void verifySigningOtp_correctCode_verifiesAndAudits() {
        Signer__c signer = freshSigner('OTP Verify OK', 'vok@example.com');

        Test.startTest();
        AgreementControllerGuest.sendSigningOtp(signer.Access_Token__c);
        String code = [SELECT OTP_Code__c FROM Signer__c WHERE Id = :signer.Id].OTP_Code__c;
        Map<String, Object> result = AgreementControllerGuest.verifySigningOtp(signer.Access_Token__c, code);
        Test.stopTest();

        Assert.areEqual(true, result.get('verified'), 'Correct code must verify');
        Assert.areEqual(false, result.get('locked'), 'Correct code must not lock');

        Signer__c after = [SELECT OTP_Verified__c, OTP_Code__c FROM Signer__c WHERE Id = :signer.Id];
        Assert.isTrue(after.OTP_Verified__c, 'Signer must be marked OTP-verified');
        Assert.isTrue(String.isBlank(after.OTP_Code__c),
            'The code is single-use and must be cleared after verification');

        Integer audits = [
            SELECT COUNT() FROM Signing_Event__c
            WHERE Agreement__c = :signer.Agreement__c AND Action__c = 'OTP Verified'
        ];
        Assert.areEqual(1, audits, 'Exactly one OTP Verified audit row must be logged');
    }

    @isTest
    static void verifySigningOtp_wrongCode_burnsAttempts() {
        Signer__c signer = freshSigner('OTP Wrong Code', 'wrong@example.com');

        Test.startTest();
        AgreementControllerGuest.sendSigningOtp(signer.Access_Token__c);
        Map<String, Object> r1 = AgreementControllerGuest.verifySigningOtp(signer.Access_Token__c, '000000');
        Map<String, Object> r2 = AgreementControllerGuest.verifySigningOtp(signer.Access_Token__c, '000001');
        Test.stopTest();

        Assert.areEqual(false, r1.get('verified'), 'Wrong code must not verify');
        Assert.areEqual(4, r1.get('attemptsLeft'), 'First wrong attempt leaves 4');
        Assert.areEqual(false, r1.get('locked'), 'Not locked after one wrong attempt');
        Assert.areEqual(3, r2.get('attemptsLeft'), 'Second wrong attempt leaves 3');

        Signer__c after = [
            SELECT OTP_Attempts__c, OTP_Code__c, OTP_Verified__c FROM Signer__c WHERE Id = :signer.Id
        ];
        Assert.areEqual(2, after.OTP_Attempts__c.intValue(), 'Both wrong attempts must be recorded');
        Assert.isTrue(String.isNotBlank(after.OTP_Code__c), 'Code stays live below the attempt cap');
        Assert.isFalse(after.OTP_Verified__c, 'Signer must remain unverified');
    }

    @isTest
    static void verifySigningOtp_fifthWrongAttempt_locksAndInvalidatesCode() {
        Signer__c signer = freshSigner('OTP Lockout', 'lock@example.com');

        Test.startTest();
        AgreementControllerGuest.sendSigningOtp(signer.Access_Token__c);
        String realCode = [SELECT OTP_Code__c FROM Signer__c WHERE Id = :signer.Id].OTP_Code__c;

        Map<String, Object> last = null;
        for (Integer i = 0; i < 5; i++) {
            last = AgreementControllerGuest.verifySigningOtp(signer.Access_Token__c, '000000');
        }
        // The code was invalidated by the lockout — even the REAL code must fail now.
        Map<String, Object> afterLock = AgreementControllerGuest.verifySigningOtp(
            signer.Access_Token__c, realCode
        );
        Test.stopTest();

        Assert.areEqual(true, last.get('locked'), 'Fifth wrong attempt must lock');
        Assert.areEqual(0, last.get('attemptsLeft'), 'No attempts left after lockout');

        Signer__c after = [SELECT OTP_Code__c, OTP_Verified__c FROM Signer__c WHERE Id = :signer.Id];
        Assert.isTrue(String.isBlank(after.OTP_Code__c),
            'Lockout must blank the stored code so a fresh send is required');
        Assert.isFalse(after.OTP_Verified__c, 'Locked signer must remain unverified');

        Assert.areEqual(false, afterLock.get('verified'),
            'The invalidated code must not verify even when correct');
        Assert.areEqual(true, afterLock.get('locked'),
            'Post-lockout verify attempts must still report locked');
    }

    @isTest
    static void verifySigningOtp_expiredCode_rejected() {
        Signer__c signer = freshSigner('OTP Expiry', 'expire@example.com');

        Test.startTest();
        AgreementControllerGuest.sendSigningOtp(signer.Access_Token__c);
        String code = [SELECT OTP_Code__c FROM Signer__c WHERE Id = :signer.Id].OTP_Code__c;
        // Age the code past the 10-minute window.
        update new Signer__c(Id = signer.Id, OTP_Sent_At__c = DateTime.now().addMinutes(-11));
        Map<String, Object> result = AgreementControllerGuest.verifySigningOtp(signer.Access_Token__c, code);
        Test.stopTest();

        Assert.areEqual(false, result.get('verified'), 'Expired code must not verify');
        Assert.areEqual(false, result.get('locked'), 'Expiry is not a lockout');
        Assert.isTrue(((String) result.get('message')).containsIgnoreCase('expired'),
            'Message must say the code expired, got: ' + result.get('message'));

        Signer__c after = [SELECT OTP_Verified__c FROM Signer__c WHERE Id = :signer.Id];
        Assert.isFalse(after.OTP_Verified__c, 'Signer must remain unverified after expiry');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  validateToken payload — otpVerified flag
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void validateToken_reportsOtpVerifiedFlag() {
        Signer__c signer = freshSigner('OTP Token Flag', 'flag@example.com');

        Test.startTest();
        Map<String, Object> before = AgreementControllerGuest.getSignerByTokenSecure(signer.Access_Token__c);
        update new Signer__c(Id = signer.Id, OTP_Verified__c = true);
        Map<String, Object> after = AgreementControllerGuest.getSignerByTokenSecure(signer.Access_Token__c);
        Test.stopTest();

        Assert.areEqual(false, before.get('otpVerified'),
            'Unverified signer must get otpVerified=false in the token payload');
        Assert.areEqual(true, after.get('otpVerified'),
            'Verified signer must get otpVerified=true so the LWC skips the gate');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Invalid token rejection
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void sendSigningOtp_invalidToken_throws() {
        Boolean threw = false;
        Test.startTest();
        try {
            AgreementControllerGuest.sendSigningOtp('00000000000000000000000000000000');
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Invalid token must be rejected by sendSigningOtp');
    }

    @isTest
    static void verifySigningOtp_invalidToken_throws() {
        Boolean threw = false;
        Test.startTest();
        try {
            AgreementControllerGuest.verifySigningOtp('00000000000000000000000000000000', '123456');
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Invalid token must be rejected by verifySigningOtp');
    }
}