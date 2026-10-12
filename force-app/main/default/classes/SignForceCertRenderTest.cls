/**
 * SignForceCertRenderTest — covers the post-signing certificate render path
 * added in the "restore the completion certificate" fix:
 *
 *   - SignForceAuthz.requireVerifiedSignerForCertRender  (the authz variant
 *     that ALLOWS an already-signed signer, unlike requireVerifiedSignerForToken)
 *   - GuestSigningApi.generateSigningCertificateSecure  (the @AuraEnabled
 *     call the viewer makes right after completion to render + attach the cert)
 *
 * The key positive case is the one the old code got wrong: a signer whose
 * Status__c is already 'Signed' (markSigned ran) MUST be authorized here, so
 * the certificate can render. Every other guard (token revoked, 48h window,
 * view cap, bound session) is still enforced — proven by the negative cases.
 */
@isTest(SeeAllData=false)
private class SignForceCertRenderTest {

    // A stable raw session token; its SHA-256 hex is stored on the signer so the
    // bound-session check passes for the positive cases.
    private static final String RAW_SESSION = 'ce-cert-render-session-token-2026';

    private static String sessionHash() {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(RAW_SESSION)));
    }

    // A Signed signer with a valid bound session — the exact state at cert-render time.
    private static Signer__c signedSignerWithSession(Id agreementId, String email) {
        Signer__c s = TestDataFactory.createSignerWithToken(agreementId, email);
        s.Status__c = 'Signed';
        s.Session_Token_Hash__c = sessionHash();
        update s;
        return s;
    }

    // ═════════════════════════════════════════════════════════════════════
    //  requireVerifiedSignerForCertRender — POSITIVE (the fix)
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void certRender_signedSignerWithSession_isAllowed() {
        Agreement__c agr = TestDataFactory.createSentAgreement('CertRender Signed OK');
        Signer__c signer = signedSignerWithSession(agr.Id, 'signed@example.com');

        Test.startTest();
        Signer__c result = SignForceAuthz.requireVerifiedSignerForCertRender(
            signer.Access_Token__c, RAW_SESSION
        );
        Test.stopTest();

        // This is the whole point: an ALREADY-SIGNED signer is authorized here,
        // whereas requireVerifiedSignerForToken would deny it ("already signed").
        Assert.areEqual(signer.Id, result.Id, 'Signed signer with a valid session must be allowed for cert render');
        Assert.areEqual(agr.Id, result.Agreement__c, 'Agreement lookup must come back for the render');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  requireVerifiedSignerForCertRender — NEGATIVE (every guard still holds)
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void certRender_sessionMismatch_isDenied() {
        Agreement__c agr = TestDataFactory.createSentAgreement('CertRender Mismatch');
        Signer__c signer = signedSignerWithSession(agr.Id, 'mm@example.com');
        assertDenied(signer.Access_Token__c, 'a-different-session-token', 'session token mismatch');
    }

    @isTest
    static void certRender_noBoundSession_isDenied() {
        Agreement__c agr = TestDataFactory.createSentAgreement('CertRender NoSession');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'ns@example.com');
        signer.Status__c = 'Signed';   // signed, but Session_Token_Hash__c left blank
        update signer;
        assertDenied(signer.Access_Token__c, RAW_SESSION, 'signer has no bound session');
    }

    @isTest
    static void certRender_blankSessionToken_isDenied() {
        Agreement__c agr = TestDataFactory.createSentAgreement('CertRender BlankSess');
        Signer__c signer = signedSignerWithSession(agr.Id, 'bs@example.com');
        assertDenied(signer.Access_Token__c, '', 'blank session token');
    }

    @isTest
    static void certRender_blankOrShortToken_isDenied() {
        assertDenied('', RAW_SESSION, 'blank token');
        assertDenied('short', RAW_SESSION, 'token shorter than 10 chars');
    }

    @isTest
    static void certRender_nonexistentToken_isDenied() {
        assertDenied('00000000000000000000000000000000', RAW_SESSION, 'unknown token');
    }

    @isTest
    static void certRender_revokedToken_isDenied() {
        Agreement__c agr = TestDataFactory.createSentAgreement('CertRender Revoked');
        Signer__c signer = signedSignerWithSession(agr.Id, 'rv@example.com');
        signer.Token_Expired__c = true;
        update signer;
        assertDenied(signer.Access_Token__c, RAW_SESSION, 'revoked token');
    }

    @isTest
    static void certRender_declinedSigner_isDenied() {
        Agreement__c agr = TestDataFactory.createSentAgreement('CertRender Declined');
        Signer__c signer = signedSignerWithSession(agr.Id, 'dc@example.com');
        signer.Status__c = 'Declined';
        update signer;
        assertDenied(signer.Access_Token__c, RAW_SESSION, 'declined signer');
    }

    @isTest
    static void certRender_tokenPast48h_isDenied() {
        Agreement__c agr = TestDataFactory.createSentAgreement('CertRender Aged');
        Signer__c signer = signedSignerWithSession(agr.Id, 'ag@example.com');
        signer.Token_Created_Date__c = DateTime.now().addHours(-72);   // > 48h
        update signer;
        assertDenied(signer.Access_Token__c, RAW_SESSION, 'token older than 48h');
    }

    @isTest
    static void certRender_viewCapExceeded_isDenied() {
        Agreement__c agr = TestDataFactory.createSentAgreement('CertRender ViewCap');
        Signer__c signer = signedSignerWithSession(agr.Id, 'vc@example.com');
        signer.Token_View_Count__c = 55;   // >= 50
        update signer;
        assertDenied(signer.Access_Token__c, RAW_SESSION, 'view cap exceeded');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  GuestSigningApi.generateSigningCertificateSecure
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void generateCertSecure_signedSigner_succeedsAndAttachesCert() {
        Agreement__c agr = TestDataFactory.createSentAgreement('GenCert OK');
        Signer__c signer = signedSignerWithSession(agr.Id, 'gc@example.com');

        Test.startTest();
        Map<String, Object> r = GuestSigningApi.generateSigningCertificateSecure(
            signer.Access_Token__c, RAW_SESSION
        );
        Test.stopTest();

        Assert.areEqual(true, r.get('success'), 'Cert render for a signed signer must succeed');

        List<Agreement_Document__c> certDocs = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agr.Id AND Document_Type__c = 'Signed'
        ];
        Assert.isFalse(certDocs.isEmpty(), 'A Signed certificate document must be attached');
    }

    @isTest
    static void generateCertSecure_invalidToken_returnsFailureWithoutThrowing() {
        // A failure here must NOT throw (it would surface as a 500 to the signer,
        // even though the signature already succeeded) — it returns success:false
        // and the async CompletionEmailQueueable remains the fallback.
        Test.startTest();
        Map<String, Object> r = GuestSigningApi.generateSigningCertificateSecure(
            '00000000000000000000000000000000', RAW_SESSION
        );
        Test.stopTest();

        Assert.areEqual(false, r.get('success'), 'Invalid token must return success:false, never throw');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Helper
    // ═════════════════════════════════════════════════════════════════════

    private static void assertDenied(String token, String sessionToken, String description) {
        Boolean threw = false;
        try {
            SignForceAuthz.requireVerifiedSignerForCertRender(token, sessionToken);
        } catch (Exception anys) {
            threw = true;
        }
        Assert.isTrue(threw, 'Cert-render authz should have denied: ' + description);
    }
}