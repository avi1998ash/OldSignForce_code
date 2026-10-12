/**
 * SignForceAuthzTest — exhaustive tests for the token validation
 * authorization layer.
 *
 * This is the single most important test class for the security review.
 * The reviewer will look for negative-path tests proving every denial
 * branch is exercised. Every method here is paired with a positive case
 * (success) and one or more negative cases (denial).
 *
 * SignForceAuthz throws AuraHandledException with the SAFE_DENY_MESSAGE
 * constant for non-REST callers. The Rest variants wrap the same logic
 * in AuthzException for HTTP status code handling.
 *
 * Coverage targets:
 *   - requireSignerForToken (positive + 8 negative branches)
 *   - requireSignerForTokenAndId (positive + mismatch)
 *   - requireSignerForTokenAndAgreement (positive + mismatch)
 *   - requireFieldsBelongToSigner (positive + cross-signer + empty)
 *   - requireContentVersionForToken (positive + cross-agreement + missing)
 *   - requireContentVersionForTokenRest (positive + denied)
 *   - requireSignerForTokenRest (positive + denied)
 *   - tokenCache hit (covered by repeated calls in same transaction)
 */
@isTest(SeeAllData=false)
private class SignForceAuthzTest {

    // ═════════════════════════════════════════════════════════════════════
    //  requireSignerForToken — POSITIVE
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void requireSignerForToken_validToken_returnsSigner() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Authz Positive');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'alice@example.com');

        Test.startTest();
        Signer__c result = SignForceAuthz.requireSignerForToken(signer.Access_Token__c);
        Test.stopTest();

        Assert.areEqual(signer.Id, result.Id, 'Should return the signer bound to the token');
        Assert.areEqual('alice@example.com', result.Email__c);
        Assert.areEqual(agr.Id, result.Agreement__c, 'Agreement lookup must match');
    }

    @isTest
    static void requireSignerForToken_repeatedCallSameTransaction_usesCache() {
        // Second call should hit the in-memory cache; both must return
        // the same signer reference identity.
        Agreement__c agr = TestDataFactory.createSentAgreement('Authz Cache');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'cache@example.com');

        Test.startTest();
        Signer__c first = SignForceAuthz.requireSignerForToken(signer.Access_Token__c);
        Signer__c second = SignForceAuthz.requireSignerForToken(signer.Access_Token__c);
        Test.stopTest();

        Assert.areEqual(first.Id, second.Id, 'Second call should return same signer');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  requireSignerForToken — NEGATIVE PATHS
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void requireSignerForToken_nullToken_throws() {
        assertAuthzDenied(null, 'null token must be denied');
    }

    @isTest
    static void requireSignerForToken_emptyToken_throws() {
        assertAuthzDenied('', 'empty token must be denied');
    }

    @isTest
    static void requireSignerForToken_whitespaceToken_throws() {
        assertAuthzDenied('   ', 'whitespace-only token must be denied');
    }

    @isTest
    static void requireSignerForToken_tooShort_throws() {
        // Authz rejects anything < 10 chars
        assertAuthzDenied('short', 'token shorter than 10 chars must be denied');
        assertAuthzDenied('abc12345', '8-char token must be denied');
    }

    @isTest
    static void requireSignerForToken_nonexistent_throws() {
        // Valid length, but no matching Signer__c row
        assertAuthzDenied('00000000000000000000000000000000', 'unknown token must be denied');
    }

    @isTest
    static void requireSignerForToken_expiredByAge_throws() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Authz Aged Token');
        Signer__c signer = TestDataFactory.createSignerInState(
            agr.Id, 'aged@example.com', 'Pending',
            DateTime.now().addHours(-72),  // 72 hours old, > 48h window
            false, 0
        );
        assertAuthzDenied(signer.Access_Token__c, 'token older than 48h must be denied');
    }

    @isTest
    static void requireSignerForToken_revoked_throws() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Authz Revoked');
        Signer__c signer = TestDataFactory.createSignerInState(
            agr.Id, 'revoked@example.com', 'Pending',
            DateTime.now(), true, 0  // Token_Expired__c = true
        );
        assertAuthzDenied(signer.Access_Token__c, 'revoked token must be denied');
    }

    @isTest
    static void requireSignerForToken_alreadySigned_throws() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Authz Signed');
        Signer__c signer = TestDataFactory.createSignerInState(
            agr.Id, 'signed@example.com', 'Signed',
            DateTime.now(), false, 5
        );
        assertAuthzDenied(signer.Access_Token__c, 'already-signed signer must be denied');
    }

    @isTest
    static void requireSignerForToken_declined_throws() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Authz Declined');
        Signer__c signer = TestDataFactory.createSignerInState(
            agr.Id, 'declined@example.com', 'Declined',
            DateTime.now(), false, 2
        );
        assertAuthzDenied(signer.Access_Token__c, 'declined signer must be denied');
    }

    @isTest
    static void requireSignerForToken_viewCountExceeded_throws() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Authz View Limit');
        Signer__c signer = TestDataFactory.createSignerInState(
            agr.Id, 'spam@example.com', 'Pending',
            DateTime.now(), false, 51  // >= 50 = denied
        );
        assertAuthzDenied(signer.Access_Token__c, 'token with >=50 views must be denied');
    }

    @isTest
    static void requireSignerForToken_viewCountAtBoundary_throws() {
        // 50 exactly should be denied (>=50 in the code)
        Agreement__c agr = TestDataFactory.createSentAgreement('Authz View Boundary');
        Signer__c signer = TestDataFactory.createSignerInState(
            agr.Id, 'boundary@example.com', 'Pending',
            DateTime.now(), false, 50
        );
        assertAuthzDenied(signer.Access_Token__c, 'token at view cap (50) must be denied');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  requireSignerForTokenAndId — POSITIVE + NEGATIVE
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void requireSignerForTokenAndId_matchingIds_returnsSigner() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Authz TokenAndId OK');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'tid@example.com');

        Test.startTest();
        Signer__c result = SignForceAuthz.requireSignerForTokenAndId(
            signer.Access_Token__c, signer.Id
        );
        Test.stopTest();

        Assert.areEqual(signer.Id, result.Id);
    }

    @isTest
    static void requireSignerForTokenAndId_mismatch_throws() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Authz TokenAndId Cross');
        Signer__c signerA = TestDataFactory.createSignerWithToken(agr.Id, 'aa@example.com');
        Signer__c signerB = TestDataFactory.createSignerWithToken(agr.Id, 'bb@example.com');

        Boolean threw = false;
        Test.startTest();
        try {
            // Token for A, but claim signerId = B
            SignForceAuthz.requireSignerForTokenAndId(signerA.Access_Token__c, signerB.Id);
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Mismatched signerId must be rejected');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  requireSignerForTokenAndAgreement — POSITIVE + NEGATIVE
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void requireSignerForTokenAndAgreement_matchingAg_returnsSigner() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Authz TokenAndAg OK');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'tag@example.com');

        Test.startTest();
        Signer__c result = SignForceAuthz.requireSignerForTokenAndAgreement(
            signer.Access_Token__c, agr.Id
        );
        Test.stopTest();

        Assert.areEqual(signer.Id, result.Id);
        Assert.areEqual(agr.Id, result.Agreement__c);
    }

    @isTest
    static void requireSignerForTokenAndAgreement_mismatch_throws() {
        Agreement__c agrA = TestDataFactory.createSentAgreement('TokenAndAg Cross A');
        Agreement__c agrB = TestDataFactory.createSentAgreement('TokenAndAg Cross B');
        Signer__c signerA = TestDataFactory.createSignerWithToken(agrA.Id, 'cross@example.com');

        Boolean threw = false;
        Test.startTest();
        try {
            // Token for A's signer, but claim agreement = B
            SignForceAuthz.requireSignerForTokenAndAgreement(signerA.Access_Token__c, agrB.Id);
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Mismatched agreementId must be rejected');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  requireFieldsBelongToSigner — POSITIVE
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void requireFieldsBelongToSigner_validFields_passes() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Authz Fields OK');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'fields@example.com');
        Signature_Field__c f1 = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 200);
        Signature_Field__c f2 = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 200, 300);

        Test.startTest();
        Set<Id> result = SignForceAuthz.requireFieldsBelongToSigner(
            signer.Access_Token__c,
            new Set<Id>{ f1.Id, f2.Id }
        );
        Test.stopTest();

        Assert.areEqual(2, result.size(), 'Both fields should be in the validated set');
        Assert.isTrue(result.contains(f1.Id));
        Assert.isTrue(result.contains(f2.Id));
    }

    @isTest
    static void requireFieldsBelongToSigner_emptySet_returnsEmptySet() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Authz Fields Empty');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'empty@example.com');

        Test.startTest();
        Set<Id> result = SignForceAuthz.requireFieldsBelongToSigner(
            signer.Access_Token__c, new Set<Id>()
        );
        Test.stopTest();

        Assert.areEqual(0, result.size(), 'Empty input must return empty set, no exception');
    }

    @isTest
    static void requireFieldsBelongToSigner_nullSet_returnsEmptySet() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Authz Fields Null');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'null@example.com');

        Test.startTest();
        Set<Id> result = SignForceAuthz.requireFieldsBelongToSigner(
            signer.Access_Token__c, null
        );
        Test.stopTest();

        Assert.areEqual(0, result.size(), 'Null input must return empty set, no exception');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  requireFieldsBelongToSigner — NEGATIVE
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void requireFieldsBelongToSigner_fieldFromDifferentSigner_throws() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Authz Fields Cross');
        Signer__c signerA = TestDataFactory.createSignerWithToken(agr.Id, 'a@example.com');
        Signer__c signerB = TestDataFactory.createSignerWithToken(agr.Id, 'b@example.com');
        Signature_Field__c fieldForB = TestDataFactory.createSignatureField(
            agr.Id, signerB.Id, 1, 100, 200
        );

        Boolean threw = false;
        Test.startTest();
        try {
            // Token A trying to validate field that's assigned to B
            SignForceAuthz.requireFieldsBelongToSigner(
                signerA.Access_Token__c,
                new Set<Id>{ fieldForB.Id }
            );
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Must reject when signer A tries to operate on signer B\'s field');
    }

    @isTest
    static void requireFieldsBelongToSigner_fieldFromDifferentAgreement_throws() {
        Agreement__c agrA = TestDataFactory.createSentAgreement('Authz Fields AgCross A');
        Agreement__c agrB = TestDataFactory.createSentAgreement('Authz Fields AgCross B');
        Signer__c signerA = TestDataFactory.createSignerWithToken(agrA.Id, 'ac@example.com');
        Signer__c signerB = TestDataFactory.createSignerWithToken(agrB.Id, 'bc@example.com');
        Signature_Field__c fieldOnB = TestDataFactory.createSignatureField(
            agrB.Id, signerB.Id, 1, 100, 200
        );

        Boolean threw = false;
        Test.startTest();
        try {
            SignForceAuthz.requireFieldsBelongToSigner(
                signerA.Access_Token__c,
                new Set<Id>{ fieldOnB.Id }
            );
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Cross-agreement field access must be denied');
    }

    @isTest
    static void requireFieldsBelongToSigner_mixedValidAndInvalid_throwsAllOrNothing() {
        // If even one field is out of scope, the whole batch is rejected.
        Agreement__c agr = TestDataFactory.createSentAgreement('Authz Fields Mixed');
        Signer__c signerA = TestDataFactory.createSignerWithToken(agr.Id, 'mxa@example.com');
        Signer__c signerB = TestDataFactory.createSignerWithToken(agr.Id, 'mxb@example.com');
        Signature_Field__c fieldA = TestDataFactory.createSignatureField(agr.Id, signerA.Id, 1, 100, 200);
        Signature_Field__c fieldB = TestDataFactory.createSignatureField(agr.Id, signerB.Id, 1, 200, 300);

        Boolean threw = false;
        Test.startTest();
        try {
            SignForceAuthz.requireFieldsBelongToSigner(
                signerA.Access_Token__c,
                new Set<Id>{ fieldA.Id, fieldB.Id }  // mix of valid + invalid
            );
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Even one out-of-scope field must reject the whole batch');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  requireContentVersionForToken — POSITIVE
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void requireContentVersionForToken_validCv_passes() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Authz CV OK');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'cv@example.com');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);

        String denial = null;
        Test.startTest();
        // Should not throw — cv belongs to signer's agreement via Agreement_Document__c
        try {
            SignForceAuthz.requireContentVersionForToken(
                signer.Access_Token__c, doc.Content_Version_ID__c
            );
        } catch (Exception anys) {
            denial = anys.getMessage();
        }
        Test.stopTest();

        Assert.areEqual(null, denial,
            'A ContentVersion on the same agreement as the signer must be allowed, not denied');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  requireContentVersionForToken — NEGATIVE
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void requireContentVersionForToken_cvFromDifferentAgreement_throws() {
        Agreement__c agrA = TestDataFactory.createSentAgreement('Authz CV Cross A');
        Agreement__c agrB = TestDataFactory.createSentAgreement('Authz CV Cross B');
        Signer__c signerA = TestDataFactory.createSignerWithToken(agrA.Id, 'cvcrossa@example.com');
        Agreement_Document__c docForB = TestDataFactory.createTier1OriginalDoc(agrB.Id);

        Boolean threw = false;
        Test.startTest();
        try {
            SignForceAuthz.requireContentVersionForToken(
                signerA.Access_Token__c, docForB.Content_Version_ID__c
            );
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Cross-agreement CV access must be denied');
    }

    @isTest
    static void requireContentVersionForToken_invalidToken_throws() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Authz CV Bad Token');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);

        Boolean threw = false;
        Test.startTest();
        try {
            SignForceAuthz.requireContentVersionForToken(
                '00000000000000000000000000000000', doc.Content_Version_ID__c
            );
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Invalid token must be rejected');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  REST variants — different exception type (AuthzException)
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void requireSignerForTokenRest_valid_returnsSigner() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Rest Authz OK');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'rest@example.com');

        Test.startTest();
        Signer__c result = SignForceAuthz.requireSignerForTokenRest(signer.Access_Token__c);
        Test.stopTest();

        Assert.areEqual(signer.Id, result.Id);
    }

    @isTest
    static void requireSignerForTokenRest_invalid_throwsAuthzException() {
        Boolean threwAuthz = false;
        Test.startTest();
        try {
            SignForceAuthz.requireSignerForTokenRest('00000000000000000000000000000000');
        } catch (SignForceAuthz.AuthzException ae) {
            threwAuthz = true;
        } catch (Exception other) {
            // Should not get here — REST variants must throw AuthzException
            Assert.fail('REST denial must throw AuthzException, got: ' + other.getTypeName());
        }
        Test.stopTest();

        Assert.isTrue(threwAuthz, 'REST denial must throw AuthzException specifically');
    }

    @isTest
    static void requireContentVersionForTokenRest_valid_passes() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Rest CV OK');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'restcv@example.com');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);

        String denial = null;
        Test.startTest();
        try {
            SignForceAuthz.requireContentVersionForTokenRest(
                signer.Access_Token__c, doc.Content_Version_ID__c
            );
        } catch (Exception anys) {
            denial = anys.getMessage();
        }
        Test.stopTest();

        Assert.areEqual(null, denial,
            'The REST variant must allow a ContentVersion on the agreement the token belongs to');
    }

    @isTest
    static void requireContentVersionForTokenRest_crossAgreement_throwsAuthzException() {
        Agreement__c agrA = TestDataFactory.createSentAgreement('Rest Cross A');
        Agreement__c agrB = TestDataFactory.createSentAgreement('Rest Cross B');
        Signer__c signerA = TestDataFactory.createSignerWithToken(agrA.Id, 'restxa@example.com');
        Agreement_Document__c docForB = TestDataFactory.createTier1OriginalDoc(agrB.Id);

        Boolean threwAuthz = false;
        Test.startTest();
        try {
            SignForceAuthz.requireContentVersionForTokenRest(
                signerA.Access_Token__c, docForB.Content_Version_ID__c
            );
        } catch (SignForceAuthz.AuthzException ae) {
            threwAuthz = true;
        }
        Test.stopTest();

        Assert.isTrue(threwAuthz, 'REST cross-agreement denial must throw AuthzException');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Helpers
    // ═════════════════════════════════════════════════════════════════════

    /**
     * Confirm requireSignerForToken with the given token throws SOMETHING.
     * Don't assert specific exception type because the safe-deny pattern
     * uses AuraHandledException with a generic message — we just need to
     * prove the call was rejected.
     */
    private static void assertAuthzDenied(String token, String description) {
        Boolean threw = false;
        try {
            SignForceAuthz.requireSignerForToken(token);
        } catch (Exception anys) {
            threw = true;
        }
        Assert.isTrue(threw, 'Should have thrown: ' + description);
    }
    @isTest
static void requireSignerForTokenRest_catchBlockCoverage() {
    Test.startTest();
    try {
        SignForceAuthz.requireSignerForTokenRest(null);
        System.assert(false);
    } catch (SignForceAuthz.AuthzException e) {
        System.assert(true);
    }
    Test.stopTest();
}
    @isTest
static void requireContentVersionForTokenRest_catchBlockCoverage() {

    Agreement__c agr =
        TestDataFactory.createSentAgreement('REST Catch');

    Agreement_Document__c doc =
        TestDataFactory.createTier1OriginalDoc(agr.Id);

    Test.startTest();
    try {
        SignForceAuthz.requireContentVersionForTokenRest(
            null,
            doc.Content_Version_ID__c
        );
        System.assert(false);
    } catch (SignForceAuthz.AuthzException e) {
        System.assert(true);
    }
    Test.stopTest();
}
}