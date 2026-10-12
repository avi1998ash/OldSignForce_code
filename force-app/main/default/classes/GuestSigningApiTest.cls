/**
* GuestSigningApiTest — exhaustive tests for the guest signing
* portal entry points.
*
* Every public method on GuestSigningApi is covered with:
*   - Positive path (valid token, expected result)
*   - Token denial path (invalid/expired/revoked token must be rejected)
*   - Cross-scope path where applicable (token-for-A claiming B's resources)
*
* HTTP callouts (Lambda S3 + proxy) are mocked. Visualforce PDF generation
* is gated by Test.isRunningTest() blocks in SignedAgreementPDFController,
* so we don't need to mock those — they just return placeholder bytes.
*
* The most important tests for the security review are the negative paths
* — they prove that the token validation actually rejects bad input rather
* than just decorating valid input.
*/
@isTest(SeeAllData=false)
private class GuestSigningApiTest {
    
    // ═════════════════════════════════════════════════════════════════════
    //  Mock for Lambda callouts (S3 presign + proxy)
    // ═════════════════════════════════════════════════════════════════════
    
   private class LambdaMockSuccess implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest req) {
        HttpResponse res = new HttpResponse();
        res.setStatusCode(200);
        res.setHeader('Content-Type', 'application/json');
        res.setBody(JSON.serialize(new Map<String, Object>{
            'success'   => true,                              // ← THIS was missing
            'url'       => 'https://example.s3.amazonaws.com/test/presigned?sig=abc',
            'pdfBase64' => EncodingUtil.base64Encode(Blob.valueOf('mocked pdf bytes'))
        }));
        return res;
    }
}
    
    // ═════════════════════════════════════════════════════════════════════
    //  getSignerByTokenSecure
    // ═════════════════════════════════════════════════════════════════════
    
    @isTest
    static void getSignerByTokenSecure_validToken_returnsSignerMap() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest GetSigner OK');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'gs@example.com');
        
        Test.startTest();
        Map<String, Object> result = GuestSigningApi.getSignerByTokenSecure(
            signer.Access_Token__c
        );
        Test.stopTest();
        
        Assert.isNotNull(result, 'Should return result map');
        // AgreementService.validateToken returns these on success; on
        // failure returns {error: '...'}. Confirm success shape.
        Assert.isFalse(result.containsKey('error'),
                       'Valid token should not produce an error response');
    }
    
    @isTest
    static void getSignerByTokenSecure_invalidToken_returnsErrorMap() {
        TestDataFactory.suppressCompletionStamp();
        // AgreementService.validateToken returns {error: '...'} for
        // unknown tokens, NOT a thrown exception. Confirm shape.
        Test.startTest();
        Map<String, Object> result = GuestSigningApi.getSignerByTokenSecure(
            '00000000000000000000000000000000'
        );
        Test.stopTest();
        
        Assert.isNotNull(result, 'Should return result map even on failure');
        Assert.isTrue(result.containsKey('error'),
                      'Invalid token must produce error response');
    }
    
    // ═════════════════════════════════════════════════════════════════════
    //  declineAgreementSecure
    // ═════════════════════════════════════════════════════════════════════
    
    @isTest
    static void declineAgreementSecure_validToken_marksSignerDeclined() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest Decline OK');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'decline@example.com');
        String sessionToken = GuestSigningApi.startSigningSession(signer.Access_Token__c);
        
        Test.startTest();
        GuestSigningApi.declineAgreementSecure(
            signer.Access_Token__c, sessionToken, 'Not interested'
        );
        Test.stopTest();
        
        Signer__c after = [SELECT Status__c, Decline_Reason__c FROM Signer__c WHERE Id = :signer.Id];
        Assert.areEqual('Declined', after.Status__c, 'Status should be Declined');
        Assert.areEqual('Not interested', after.Decline_Reason__c);
    }
    
    @isTest
    static void declineAgreementSecure_invalidToken_throws() {
        TestDataFactory.suppressCompletionStamp();
        Boolean threw = false;
        Test.startTest();
        try {
            GuestSigningApi.declineAgreementSecure(
                '00000000000000000000000000000000', null, 'reason'
            );
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();
        
        Assert.isTrue(threw, 'Invalid token must be rejected by declineAgreementSecure');
    }
    
    // ═════════════════════════════════════════════════════════════════════
    //  getFieldsForSignerSecure
    // ═════════════════════════════════════════════════════════════════════
    
    @isTest
    static void getFieldsForSignerSecure_validToken_returnsAssignedFields() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest GetFields OK');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'gf@example.com');
        TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 200);
        TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 300, 400);
        
        Test.startTest();
        List<Signature_Field__c> fields = GuestSigningApi.getFieldsForSignerSecure(
            signer.Access_Token__c
        );
        Test.stopTest();
        
        Assert.areEqual(2, fields.size(), 'Should return both fields assigned to this signer');
    }
    
    @isTest
    static void getFieldsForSignerSecure_otherSignersFieldsExcluded() {
        TestDataFactory.suppressCompletionStamp();
        // Two signers on same agreement; each should see only their own fields
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest GetFields Scope');
        Signer__c signerA = TestDataFactory.createSignerWithToken(agr.Id, 'sa@example.com');
        Signer__c signerB = TestDataFactory.createSignerWithToken(agr.Id, 'sb@example.com');
        TestDataFactory.createSignatureField(agr.Id, signerA.Id, 1, 100, 200);
        TestDataFactory.createSignatureField(agr.Id, signerB.Id, 1, 100, 300);
        TestDataFactory.createSignatureField(agr.Id, signerB.Id, 1, 100, 400);
        
        Test.startTest();
        List<Signature_Field__c> aFields = GuestSigningApi.getFieldsForSignerSecure(
            signerA.Access_Token__c
        );
        List<Signature_Field__c> bFields = GuestSigningApi.getFieldsForSignerSecure(
            signerB.Access_Token__c
        );
        Test.stopTest();
        
        Assert.areEqual(1, aFields.size(), 'Signer A should see 1 field (its own)');
        Assert.areEqual(2, bFields.size(), 'Signer B should see 2 fields (its own)');
    }
    
    @isTest
    static void getFieldsForSignerSecure_invalidToken_throws() {
        TestDataFactory.suppressCompletionStamp();
        Boolean threw = false;
        Test.startTest();
        try {
            GuestSigningApi.getFieldsForSignerSecure(
                '00000000000000000000000000000000'
            );
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();
        
        Assert.isTrue(threw);
    }
    
    // ═════════════════════════════════════════════════════════════════════
    //  saveFieldValuesSecure
    // ═════════════════════════════════════════════════════════════════════
    
    @isTest
    static void saveFieldValuesSecure_ownFields_updates() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest SaveValues OK');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'sv@example.com');
        Signature_Field__c f1 = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 200);
        Signature_Field__c f2 = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 300);
        
        String json = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{ 'id' => f1.Id, 'value' => 'John Doe' },
                new Map<String, Object>{ 'id' => f2.Id, 'value' => '2026-05-11' }
        });
        
        Test.startTest();
        GuestSigningApi.saveFieldValuesSecure(signer.Access_Token__c, json);
        Test.stopTest();
        
        List<Signature_Field__c> after = [
            SELECT Id, Field_Value__c, Is_Completed__c
            FROM Signature_Field__c WHERE Id IN :new Set<Id>{ f1.Id, f2.Id }
            ORDER BY Y_Position__c
        ];
        Assert.areEqual(2, after.size());
        Assert.areEqual('John Doe', after[0].Field_Value__c);
        Assert.areEqual(true, after[0].Is_Completed__c);
        Assert.areEqual('2026-05-11', after[1].Field_Value__c);
    }
    
    @isTest
    static void saveFieldValuesSecure_otherSignersField_throws() {
        TestDataFactory.suppressCompletionStamp();
        // Token A trying to write to B's field
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest SaveValues Cross');
        Signer__c signerA = TestDataFactory.createSignerWithToken(agr.Id, 'sva@example.com');
        Signer__c signerB = TestDataFactory.createSignerWithToken(agr.Id, 'svb@example.com');
        Signature_Field__c fieldForB = TestDataFactory.createSignatureField(
            agr.Id, signerB.Id, 1, 100, 200
        );
        
        String json = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{ 'id' => fieldForB.Id, 'value' => 'Hacker McTamper' }
        });
        
        Boolean threw = false;
        Test.startTest();
        try {
            GuestSigningApi.saveFieldValuesSecure(signerA.Access_Token__c, json);
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();
        
        Assert.isTrue(threw, 'Signer A must not be able to write Signer B\'s field');
        
        // Confirm B's field is unchanged
        Signature_Field__c after = [SELECT Field_Value__c FROM Signature_Field__c WHERE Id = :fieldForB.Id];
        Assert.areEqual(null, after.Field_Value__c, 'B\'s field must not be tampered');
    }
    
    @isTest
    static void saveFieldValuesSecure_blankJson_noOp() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest SaveValues Blank');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'blank@example.com');
        
        Test.startTest();
        // Should not throw, just no-op
        GuestSigningApi.saveFieldValuesSecure(signer.Access_Token__c, '');
        GuestSigningApi.saveFieldValuesSecure(signer.Access_Token__c, null);
        Integer dmlUsed = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(0, dmlUsed,
            'Blank/null field JSON must short-circuit before any DML is issued');
    }
    
    @isTest
    static void saveFieldValuesSecure_invalidToken_throws() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest SaveValues BadToken');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'st@example.com');
        Signature_Field__c f = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 200);
        
        String json = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{ 'id' => f.Id, 'value' => 'x' }
        });
        
        Boolean threw = false;
        Test.startTest();
        try {
            GuestSigningApi.saveFieldValuesSecure(
                '00000000000000000000000000000000', json
            );
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();
        
        Assert.isTrue(threw);
    }
    
    // ═════════════════════════════════════════════════════════════════════
    //  getDocumentVersionSecure
    // ═════════════════════════════════════════════════════════════════════
    
    @isTest
    static void getDocumentVersionSecure_tier1Doc_returnsCvId() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest GetDocVer OK');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'gdv@example.com');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);
        
        Test.startTest();
        String result = GuestSigningApi.getDocumentVersionSecure(
            signer.Access_Token__c
        );
        Test.stopTest();
        
        Assert.areEqual(doc.Content_Version_ID__c, result,
                        'Should return ContentVersion ID of the original doc');
    }
    
    @isTest
    static void getDocumentVersionSecure_noDoc_returnsNull() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest GetDocVer NoDoc');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'nodoc@example.com');
        
        Test.startTest();
        String result = GuestSigningApi.getDocumentVersionSecure(
            signer.Access_Token__c
        );
        Test.stopTest();
        
        Assert.areEqual(null, result, 'Agreement with no original doc returns null');
    }
    
    @isTest
    static void getDocumentVersionSecure_invalidToken_throws() {
        TestDataFactory.suppressCompletionStamp();
        Boolean threw = false;
        Test.startTest();
        try {
            GuestSigningApi.getDocumentVersionSecure(
                '00000000000000000000000000000000'
            );
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();
        
        Assert.isTrue(threw);
    }
    
    // ═════════════════════════════════════════════════════════════════════
    //  getDocumentForSigningSecure
    // ═════════════════════════════════════════════════════════════════════
    
    @isTest
    static void getDocumentForSigningSecure_smallDoc_noDownloadUrl() {
        TestDataFactory.suppressCompletionStamp();
        // Document <= 4MB → no downloadUrl in response
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest GetDocSign Small');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'small@example.com');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);
        
        Test.startTest();
        Map<String, Object> result = GuestSigningApi.getDocumentForSigningSecure(
            signer.Access_Token__c
        );
        Test.stopTest();
        
        Assert.isNotNull(result);
        Assert.areEqual(doc.Content_Version_ID__c, result.get('cvId'));
        Assert.isFalse(result.containsKey('downloadUrl'),
                       'Small doc should not have downloadUrl populated');
    }
    
    @isTest
    static void getDocumentForSigningSecure_invalidToken_throws() {
        TestDataFactory.suppressCompletionStamp();
        Boolean threw = false;
        Test.startTest();
        try {
            GuestSigningApi.getDocumentForSigningSecure(
                '00000000000000000000000000000000'
            );
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();
        
        Assert.isTrue(threw);
    }
    
    // ═════════════════════════════════════════════════════════════════════
    //  getS3PreviewUrlSecure
    // ═════════════════════════════════════════════════════════════════════
    
    @isTest
    static void getS3PreviewUrlSecure_s3BackedDoc_returnsUrl() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest S3Url OK');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 's3@example.com');
        TestDataFactory.createS3OriginalDoc(agr.Id, 'Tier2');
        String sessionToken = GuestSigningApi.startSigningSession(signer.Access_Token__c);
        
        Test.setMock(HttpCalloutMock.class, new LambdaMockSuccess());
        
        Test.startTest();
        String url = GuestSigningApi.getS3PreviewUrlSecure(signer.Access_Token__c, sessionToken);
        Test.stopTest();
        
        Assert.isNotNull(url, 'Should return either fresh or cached presigned URL');
    }
    
    @isTest
    static void getS3PreviewUrlSecure_noS3Doc_returnsNull() {
        TestDataFactory.suppressCompletionStamp();
        // Tier1 doc (CV only, no S3) → method returns null per contract
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest S3Url Tier1');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'tier1@example.com');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        String sessionToken = GuestSigningApi.startSigningSession(signer.Access_Token__c);
        
        Test.startTest();
        String url = GuestSigningApi.getS3PreviewUrlSecure(signer.Access_Token__c, sessionToken);
        Test.stopTest();
        
        Assert.areEqual(null, url, 'Tier1-only doc must return null S3 URL');
    }
    
    @isTest
    static void getS3PreviewUrlSecure_invalidToken_throws() {
        TestDataFactory.suppressCompletionStamp();
        Boolean threw = false;
        Test.startTest();
        try {
            GuestSigningApi.getS3PreviewUrlSecure(
                '00000000000000000000000000000000', null
            );
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();
        
        Assert.isTrue(threw);
    }
    
    // ═════════════════════════════════════════════════════════════════════
    //  getSigningPdfUrlSecure  (pdf.js raw-URL path — no VF page / classic Site)
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void getSigningPdfUrlSecure_s3BackedDoc_returnsRawUrl() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest SigningPdf S3');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'spdf@example.com');
        TestDataFactory.createS3OriginalDoc(agr.Id, 'Tier2');
        String sessionToken = GuestSigningApi.startSigningSession(signer.Access_Token__c);

        Test.setMock(HttpCalloutMock.class, new LambdaMockSuccess());

        Test.startTest();
        String url = GuestSigningApi.getSigningPdfUrlSecure(signer.Access_Token__c, sessionToken);
        Test.stopTest();

        Assert.isNotNull(url, 'Should return a raw presigned PDF URL');
        Assert.isFalse(url.startsWith('/apex/'), 'Must be a RAW url, not a VF page path');
        Assert.isFalse(url.contains('signvforcesite'), 'Must not contain the classic Site prefix');
    }

    @isTest
    static void getSigningPdfUrlSecure_cvDoc_convertsAndReturnsRawUrl() {
        TestDataFactory.suppressCompletionStamp();
        // Tier1 (CV-only) Original → resolution order 2: Lambda convertToPdf → raw URL.
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest SigningPdf CV');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'cvpdf@example.com');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        String sessionToken = GuestSigningApi.startSigningSession(signer.Access_Token__c);

        Test.setMock(HttpCalloutMock.class, new LambdaMockSuccess());

        Test.startTest();
        String url = GuestSigningApi.getSigningPdfUrlSecure(signer.Access_Token__c, sessionToken);
        Test.stopTest();

        Assert.isNotNull(url, 'CV doc should convert via Lambda and return a raw URL');
        Assert.isFalse(url.startsWith('/apex/'), 'Must be a RAW url, not a VF page path');
    }

    @isTest
    static void getSigningPdfUrlSecure_contentLinkFallback_convertsAndReturnsRawUrl() {
        TestDataFactory.suppressCompletionStamp();
        // CV linked to the agreement but NO Agreement_Document__c Original row →
        // exercises the ContentDocumentLink fallback branch (resolution order 2).
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest SigningPdf Link');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'linkpdf@example.com');
        ContentVersion cv = new ContentVersion(
            Title = 'Linked Doc', PathOnClient = 'linked.pdf',
            VersionData = Blob.valueOf('fake-pdf-bytes'), FirstPublishLocationId = agr.Id
        );
        insert cv;
        String sessionToken = GuestSigningApi.startSigningSession(signer.Access_Token__c);

        Test.setMock(HttpCalloutMock.class, new LambdaMockSuccess());

        Test.startTest();
        String url = GuestSigningApi.getSigningPdfUrlSecure(signer.Access_Token__c, sessionToken);
        Test.stopTest();

        Assert.isNotNull(url, 'ContentDocumentLink fallback should convert and return a raw URL');
        Assert.isFalse(url.startsWith('/apex/'), 'Must be a RAW url');
    }

    @isTest
    static void getSigningPdfUrlSecure_invalidToken_throws() {
        TestDataFactory.suppressCompletionStamp();
        Boolean threw = false;
        Test.startTest();
        try {
            GuestSigningApi.getSigningPdfUrlSecure(
                '00000000000000000000000000000000', null
            );
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Invalid token must throw');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  getPdfFileInfoSecure
    // ═════════════════════════════════════════════════════════════════════
    
    @isTest
    static void getPdfFileInfoSecure_validCv_returnsSize() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest PdfInfo OK');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'pi@example.com');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);
        String sessionToken = GuestSigningApi.startSigningSession(signer.Access_Token__c);
        
        Test.startTest();
        Map<String, Object> result = GuestSigningApi.getPdfFileInfoSecure(
            signer.Access_Token__c, sessionToken, doc.Content_Version_ID__c
        );
        Test.stopTest();
        
        Assert.isNotNull(result);
        Assert.isTrue(result.containsKey('size'), 'Result must include size');
        Assert.isTrue(result.containsKey('isLarge'), 'Result must include isLarge flag');
    }
    
    @isTest
    static void getPdfFileInfoSecure_crossAgreementCv_throws() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agrA = TestDataFactory.createSentAgreement('Guest PdfInfo Cross A');
        Agreement__c agrB = TestDataFactory.createSentAgreement('Guest PdfInfo Cross B');
        Signer__c signerA = TestDataFactory.createSignerWithToken(agrA.Id, 'pia@example.com');
        Agreement_Document__c docForB = TestDataFactory.createTier1OriginalDoc(agrB.Id);
        String sessionToken = GuestSigningApi.startSigningSession(signerA.Access_Token__c);
        
        Boolean threw = false;
        Test.startTest();
        try {
            GuestSigningApi.getPdfFileInfoSecure(
                signerA.Access_Token__c, sessionToken, docForB.Content_Version_ID__c
            );
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();
        
        Assert.isTrue(threw, 'Cross-agreement CV must be rejected');
    }
    
    @isTest
    static void getPdfFileInfoSecure_invalidToken_throws() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest PdfInfo BadToken');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);
        
        Boolean threw = false;
        Test.startTest();
        try {
            GuestSigningApi.getPdfFileInfoSecure(
                '00000000000000000000000000000000', null, doc.Content_Version_ID__c
            );
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();
        
        Assert.isTrue(threw);
    }
    
    // ═════════════════════════════════════════════════════════════════════
    //  proxyPdfViaLambdaSecure
    // ═════════════════════════════════════════════════════════════════════
    
    @isTest
    static void proxyPdfViaLambdaSecure_validCv_returnsBase64() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest Proxy OK');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'px@example.com');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);
        String sessionToken = GuestSigningApi.startSigningSession(signer.Access_Token__c);
        
        // Pre-create the ContentDistribution so the production code path takes
        // the SELECT-existing branch, not the INSERT-new branch. Otherwise the
        // DML-then-callout pattern throws CalloutException in test context.
        ContentDistribution cd = new ContentDistribution();
        cd.Name = 'Sign-' + doc.Content_Version_ID__c;
        cd.ContentVersionId = doc.Content_Version_ID__c;
        cd.PreferencesAllowViewInBrowser = true;
        cd.PreferencesLinkLatestVersion = false;
        cd.PreferencesNotifyOnVisit = false;
        cd.PreferencesPasswordRequired = false;
        cd.PreferencesAllowOriginalDownload = true;
        Database.insert(cd, true, AccessLevel.USER_MODE);

        Test.setMock(HttpCalloutMock.class, new LambdaMockSuccess());
        
        Test.startTest();
        String b64 = GuestSigningApi.proxyPdfViaLambdaSecure(
            signer.Access_Token__c, sessionToken, doc.Content_Version_ID__c
        );
        Test.stopTest();
        
        Assert.isNotNull(b64, 'Should return base64-encoded PDF bytes');
    }
    
    @isTest
    static void proxyPdfViaLambdaSecure_crossAgreementCv_throws() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agrA = TestDataFactory.createSentAgreement('Guest Proxy Cross A');
        Agreement__c agrB = TestDataFactory.createSentAgreement('Guest Proxy Cross B');
        Signer__c signerA = TestDataFactory.createSignerWithToken(agrA.Id, 'pxa@example.com');
        Agreement_Document__c docForB = TestDataFactory.createTier1OriginalDoc(agrB.Id);
        String sessionToken = GuestSigningApi.startSigningSession(signerA.Access_Token__c);
        
        Boolean threw = false;
        Test.startTest();
        try {
            GuestSigningApi.proxyPdfViaLambdaSecure(
                signerA.Access_Token__c, sessionToken, docForB.Content_Version_ID__c
            );
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();
        
        Assert.isTrue(threw, 'Cross-agreement CV proxy must be denied');
    }
    
    @isTest
    static void proxyPdfViaLambdaSecure_invalidToken_throws() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest Proxy BadToken');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);
        
        Boolean threw = false;
        Test.startTest();
        try {
            GuestSigningApi.proxyPdfViaLambdaSecure(
                '00000000000000000000000000000000', null, doc.Content_Version_ID__c
            );
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();
        
        Assert.isTrue(threw);
    }
    
    @isTest
    static void proxyPdfViaLambdaSecure_docxCv_convertsAndReturnsBase64() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest Proxy DOCX');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'pxd@example.com');

        ContentVersion cv = new ContentVersion();
        cv.Title = 'Test DOCX';
        cv.PathOnClient = 'test.docx';
        cv.VersionData = Blob.valueOf('fake-docx-bytes');
        cv.FirstPublishLocationId = agr.Id;
        insert cv;
        ContentVersion insertedCv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id];

        Agreement_Document__c doc = new Agreement_Document__c();
        doc.Agreement__c = agr.Id;
        doc.Name = 'Test DOCX';
        doc.Content_Version_ID__c = insertedCv.Id;
        doc.Document_Type__c = 'Original';
        doc.Storage_Tier__c = 'Tier1';
        insert doc;

        String sessionToken = GuestSigningApi.startSigningSession(signer.Access_Token__c);
        Test.setMock(HttpCalloutMock.class, new LambdaMockSuccess());

        Test.startTest();
        String b64 = GuestSigningApi.proxyPdfViaLambdaSecure(
            signer.Access_Token__c, sessionToken, insertedCv.Id
        );
        Test.stopTest();

        Assert.isNotNull(b64, 'DOCX should convert via Lambda and return base64 bytes');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  proxyS3PdfViaLambdaSecure  (S3-only Originals, no ContentVersion)
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void proxyS3PdfViaLambdaSecure_s3Doc_returnsBase64() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest S3 Proxy OK');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'ps3@example.com');
        TestDataFactory.createS3OriginalDoc(agr.Id, 'Tier2');
        String sessionToken = GuestSigningApi.startSigningSession(signer.Access_Token__c);
        Test.setMock(HttpCalloutMock.class, new LambdaMockSuccess());

        Test.startTest();
        String b64 = GuestSigningApi.proxyS3PdfViaLambdaSecure(
            signer.Access_Token__c, sessionToken
        );
        Test.stopTest();

        Assert.isNotNull(b64, 'S3-only doc should proxy server-side and return base64');
    }

    @isTest
    static void proxyS3PdfViaLambdaSecure_noDoc_returnsNull() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest S3 Proxy None');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'ps3n@example.com');
        // No S3 Original created → must return null (LWC then uses URL path).
        String sessionToken = GuestSigningApi.startSigningSession(signer.Access_Token__c);

        Test.startTest();
        String b64 = GuestSigningApi.proxyS3PdfViaLambdaSecure(
            signer.Access_Token__c, sessionToken
        );
        Test.stopTest();

        Assert.isNull(b64, 'No S3-backed Original → null');
    }

    @isTest
    static void proxyS3PdfViaLambdaSecure_invalidToken_throws() {
        TestDataFactory.suppressCompletionStamp();
        Boolean threw = false;
        Test.startTest();
        try {
            GuestSigningApi.proxyS3PdfViaLambdaSecure(
                '00000000000000000000000000000000', null
            );
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Invalid token must throw');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  getSavedSignatureSecure / saveSignatureSecure
    // ═════════════════════════════════════════════════════════════════════
    
    @isTest
    static void saveAndGetSignatureSecure_roundTrip() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest Sig RT');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'sig@example.com');
        String sessionToken = GuestSigningApi.startSigningSession(signer.Access_Token__c);
        
        Test.startTest();
        GuestSigningApi.saveSignatureSecure(
            signer.Access_Token__c,
            sessionToken,
            'data:image/png;base64,iVBORw0KGgo=',
            'Draw',  // Picklist value — must match Saved_Signature__c.Signature_Type__c
            null
        );
        Map<String, Object> retrieved = GuestSigningApi.getSavedSignatureSecure(
            signer.Access_Token__c, sessionToken
        );
        Test.stopTest();
        
        Assert.isNotNull(retrieved, 'Should retrieve the just-saved signature');
    }
    
    @isTest
    static void getSavedSignatureSecure_invalidToken_throws() {
        TestDataFactory.suppressCompletionStamp();
        Boolean threw = false;
        Test.startTest();
        try {
            GuestSigningApi.getSavedSignatureSecure(
                '00000000000000000000000000000000', null
            );
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();
        
        Assert.isTrue(threw);
    }
    
    @isTest
    static void saveSignatureSecure_invalidToken_throws() {
        TestDataFactory.suppressCompletionStamp();
        Boolean threw = false;
        Test.startTest();
        try {
            GuestSigningApi.saveSignatureSecure(
                '00000000000000000000000000000000',
                null,
                'data:image/png;base64,xxx',
                'Draw',  // Valid picklist value — but token will fail first
                null
            );
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();
        
        Assert.isTrue(threw);
    }
    
    // ═════════════════════════════════════════════════════════════════════
    //  getBrandingForGuest (public, no token)
    // ═════════════════════════════════════════════════════════════════════
    
    @isTest
    static void getBrandingForGuest_returnsMap() {
        TestDataFactory.suppressCompletionStamp();
        Test.startTest();
        Map<String, String> branding = GuestSigningApi.getBrandingForGuest();
        Test.stopTest();
        
        Assert.isNotNull(branding,
                         'Branding service should return a map even when no custom branding configured');
    }
    
    // ═════════════════════════════════════════════════════════════════════
    //  completeSigningSecure — the big bundled flow
    // ═════════════════════════════════════════════════════════════════════
    
    @isTest
    static void completeSigningSecure_singleSigner_marksCompleted() {
        TestDataFactory.suppressCompletionStamp();
        // Single signer → completion fires on this signer's mark-signed
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest Complete Solo');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'solo@example.com');
        String sessionToken = GuestSigningApi.startSigningSession(signer.Access_Token__c);
        Signature_Field__c f = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 200);
        // Mark field completed (precondition for markSigned to flip status)
        f.Field_Value__c = 'Signature';
        f.Is_Completed__c = true;
        update f;
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        
        Test.setMock(HttpCalloutMock.class, new LambdaMockSuccess());
        
        Test.startTest();
        Map<String, Object> result = GuestSigningApi.completeSigningSecure(
            signer.Access_Token__c, sessionToken, '2001:db8::1', 'TestAgent/1.0', '127.0.0.1'
        );
        Test.stopTest();
        
        Assert.isNotNull(result);
        Assert.areEqual(agr.Id, result.get('agreementId'));
        // After completion, the signer's status should be Signed
        Signer__c after = [SELECT Status__c FROM Signer__c WHERE Id = :signer.Id];
        Assert.areEqual('Signed', after.Status__c);
    }
    
    @isTest
    static void completeSigningSecure_invalidToken_throws() {
        TestDataFactory.suppressCompletionStamp();
        Boolean threw = false;
        Test.startTest();
        try {
            GuestSigningApi.completeSigningSecure(
                '00000000000000000000000000000000', null, '127.0.0.1', 'agent', '127.0.0.1'
            );
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();
        
        Assert.isTrue(threw, 'Invalid token must be rejected by completeSigningSecure');
    }
    @IsTest
    static void testRunPostSigningFlowAsyncCoverage() {
        TestDataFactory.suppressCompletionStamp();
        
        Id agrId = AgreementController.createAgreement(
            'Async Coverage',
            'Contract',
            'Sequential',
            null,
            null
        );
        
        Test.startTest();
        
        GuestSigningApi.runPostSigningFlowAsync(agrId);

        Test.stopTest();

        Agreement__c after = [
            SELECT Name, Status__c FROM Agreement__c WHERE Id = :agrId
        ];
        Assert.areEqual('Draft', after.Status__c,
            'No signer signed, so the async post-signing flow must leave the agreement at Draft');
        Assert.areEqual('Async Coverage', after.Name,
            'The async flow must run against the agreement it was queued for');
    }
    @IsTest
    static void testRunStampingAndEmailAsyncCoverage() {
        TestDataFactory.suppressCompletionStamp();
        
        Id agrId = AgreementController.createAgreement(
            'Async Coverage 2',
            'Contract',
            'Sequential',
            null,
            null
        );
        
        Test.startTest();
        
        GuestSigningApi.runStampingAndEmailAsync(agrId);

        Test.stopTest();

        Agreement__c after = [
            SELECT Status__c FROM Agreement__c WHERE Id = :agrId
        ];
        Integer stampedDocs = [
            SELECT COUNT() FROM Agreement_Document__c
            WHERE Agreement__c = :agrId AND Document_Type__c = 'Stamped'
        ];
        Assert.areEqual('Draft', after.Status__c,
            'Async stamping/email must not advance an agreement nobody has signed');
        Assert.areEqual(0, stampedDocs,
            'With no Original document the stamping step must fail quietly, leaving no Stamped record');
    }
    @IsTest
    static void testGetPublicPreviewUrlSecure_PdfFile() {
        TestDataFactory.suppressCompletionStamp();
        
        Agreement__c agr =
            TestDataFactory.createSentAgreement('Preview PDF');
        
        Signer__c signer =
            TestDataFactory.createSignerWithToken(
                agr.Id,
                'preview@test.com'
            );
        
        String sessionToken =
            GuestSigningApi.startSigningSession(
                signer.Access_Token__c
            );
        
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        
        Test.setMock(
            HttpCalloutMock.class,
            new LambdaMockSuccess()
        );
        
        Test.startTest();
        
        String url =
            GuestSigningApi.getPublicPreviewUrlSecure(
                signer.Access_Token__c,
                sessionToken
            );
        
        Test.stopTest();
        
        System.assertNotEquals(null, url);
    }
    @IsTest
    static void testGetPublicPreviewUrlSecure_InvalidToken() {
        TestDataFactory.suppressCompletionStamp();
        
        Boolean thrown = false;
        
        Test.startTest();
        
        try {
            GuestSigningApi.getPublicPreviewUrlSecure(
                'BADTOKEN',
                'BADSESSION'
            );
        } catch (Exception e) {
            thrown = true;
        }
        
        Test.stopTest();
        
        System.assert(thrown);
    }
    // ═════════════════════════════════════════════════════════════════════
//  validateSigningSession
// ═════════════════════════════════════════════════════════════════════

@isTest
static void validateSigningSession_validSession_returnsTrue() {
        TestDataFactory.suppressCompletionStamp();
    Agreement__c agr = TestDataFactory.createSentAgreement('Validate Session OK');
    Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'vs@example.com');
    String sessionToken = GuestSigningApi.startSigningSession(signer.Access_Token__c);

    Test.startTest();
    Boolean result = GuestSigningApi.validateSigningSession(
        signer.Access_Token__c, sessionToken
    );
    Test.stopTest();

    Assert.isTrue(result, 'Valid session token should return true');
}

@isTest
static void validateSigningSession_wrongSessionToken_returnsFalse() {
        TestDataFactory.suppressCompletionStamp();
    Agreement__c agr = TestDataFactory.createSentAgreement('Validate Session Wrong');
    Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'vsw@example.com');
    // Start a session so a binding exists, then pass a different token
    GuestSigningApi.startSigningSession(signer.Access_Token__c);

    Test.startTest();
    Boolean result = GuestSigningApi.validateSigningSession(
        signer.Access_Token__c, 'totally-wrong-session-token'
    );
    Test.stopTest();

    Assert.isFalse(result, 'Wrong session token should return false, not throw');
}

@isTest
static void validateSigningSession_nullSession_returnsFalse() {
        TestDataFactory.suppressCompletionStamp();
    Agreement__c agr = TestDataFactory.createSentAgreement('Validate Session Null');
    Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'vsn@example.com');

    Test.startTest();
    Boolean result = GuestSigningApi.validateSigningSession(
        signer.Access_Token__c, null
    );
    Test.stopTest();

    Assert.isFalse(result, 'Null session token should return false safely');
}

// ═════════════════════════════════════════════════════════════════════
//  getOtherCompletedFieldsSecure
// ═════════════════════════════════════════════════════════════════════

@isTest
static void getOtherCompletedFieldsSecure_returnsOtherSignersCompletedFields() {
        TestDataFactory.suppressCompletionStamp();
    Agreement__c agr = TestDataFactory.createSentAgreement('Other Fields OK');
    Signer__c signerA = TestDataFactory.createSignerWithToken(agr.Id, 'oca@example.com');
    Signer__c signerB = TestDataFactory.createSignerWithToken(agr.Id, 'ocb@example.com');

    // B has 2 completed fields, A has 1 completed field
    Signature_Field__c bField1 = TestDataFactory.createSignatureField(agr.Id, signerB.Id, 1, 100, 200);
    Signature_Field__c bField2 = TestDataFactory.createSignatureField(agr.Id, signerB.Id, 1, 100, 300);
    Signature_Field__c aField  = TestDataFactory.createSignatureField(agr.Id, signerA.Id, 1, 100, 400);

    // Mark B's fields completed, leave A's incomplete
    bField1.Is_Completed__c = true; bField1.Field_Value__c = 'B Sig 1';
    bField2.Is_Completed__c = true; bField2.Field_Value__c = 'B Sig 2';
    update new List<Signature_Field__c>{ bField1, bField2 };

    Test.startTest();
    // A's token → should see B's 2 completed fields, NOT A's own field
    List<Signature_Field__c> seen = GuestSigningApi.getOtherCompletedFieldsSecure(
        signerA.Access_Token__c
    );
    Test.stopTest();

    Assert.areEqual(2, seen.size(), 'Signer A should see both of B\'s completed fields');
  
}

@isTest
static void getOtherCompletedFieldsSecure_incompleteOtherFields_excluded() {
        TestDataFactory.suppressCompletionStamp();
    Agreement__c agr = TestDataFactory.createSentAgreement('Other Fields Incomplete');
    Signer__c signerA = TestDataFactory.createSignerWithToken(agr.Id, 'ocia@example.com');
    Signer__c signerB = TestDataFactory.createSignerWithToken(agr.Id, 'ocib@example.com');

    // B has a field but has NOT completed it
    TestDataFactory.createSignatureField(agr.Id, signerB.Id, 1, 100, 200);

    Test.startTest();
    List<Signature_Field__c> seen = GuestSigningApi.getOtherCompletedFieldsSecure(
        signerA.Access_Token__c
    );
    Test.stopTest();

    Assert.areEqual(0, seen.size(), 'Incomplete fields from other signers must be excluded');
}

@isTest
static void getOtherCompletedFieldsSecure_invalidToken_throws() {
        TestDataFactory.suppressCompletionStamp();
    Boolean threw = false;
    Test.startTest();
    try {
        GuestSigningApi.getOtherCompletedFieldsSecure(
            '00000000000000000000000000000000'
        );
    } catch (Exception e) {
        threw = true;
    }
    Test.stopTest();

    Assert.isTrue(threw, 'Invalid token must be rejected');
}

// ═════════════════════════════════════════════════════════════════════
//  runMidSignStampAndCopyAsync
// ═════════════════════════════════════════════════════════════════════

@isTest
static void runMidSignStampAndCopyAsync_coverage() {
        TestDataFactory.suppressCompletionStamp();
    // @future methods can only be called inside Test.startTest/stopTest.
    // We just verify they don't throw an unhandled exception — the inner
    // service calls are covered by their own unit tests.
    Id agrId = AgreementController.createAgreement(
        'MidSign Async Coverage',
        'Contract',
        'Sequential',
        null,
        null
    );
    Agreement__c agr = [SELECT Id FROM Agreement__c WHERE Id = :agrId];
    Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'midsign@example.com');

    Test.setMock(HttpCalloutMock.class, new LambdaMockSuccess());

    Test.startTest();
    GuestSigningApi.runMidSignStampAndCopyAsync(agrId, signer.Id);
    Test.stopTest();
    // No assertion needed — absence of unhandled exception is the contract
}

// ═════════════════════════════════════════════════════════════════════
//  completeSigningSecure — multi-signer mid-flow path
// ═════════════════════════════════════════════════════════════════════

@isTest
static void completeSigningSecure_multiSigner_firstSignerNotCompleted() {
        TestDataFactory.suppressCompletionStamp();
    // Two signers: A signs first, agreement stays Sent (not Completed).
    // The mid-sign async path (runMidSignStampAndCopyAsync) should be queued
    // and the response should carry isCompleted = false.
    Agreement__c agr = TestDataFactory.createSentAgreement('Complete Multi First');
    Signer__c signerA = TestDataFactory.createSignerWithToken(agr.Id, 'cma@example.com');
    Signer__c signerB = TestDataFactory.createSignerWithToken(agr.Id, 'cmb@example.com');
    String sessionToken = GuestSigningApi.startSigningSession(signerA.Access_Token__c);

    Signature_Field__c fA = TestDataFactory.createSignatureField(agr.Id, signerA.Id, 1, 100, 200);
    fA.Field_Value__c = 'Signature A';
    fA.Is_Completed__c = true;
    update fA;
    TestDataFactory.createTier1OriginalDoc(agr.Id);

    Test.setMock(HttpCalloutMock.class, new LambdaMockSuccess());

    Test.startTest();
    Map<String, Object> result = GuestSigningApi.completeSigningSecure(
        signerA.Access_Token__c, sessionToken, '2001:db8::2', 'TestAgent/2.0', '10.0.0.1'
    );
    Test.stopTest();

    Assert.isNotNull(result);
    // With signerB still pending the agreement is NOT completed
    Assert.isFalse((Boolean) result.get('isCompleted'),
        'Agreement with pending signers must not be marked completed');
    Assert.areEqual(agr.Id, result.get('agreementId'));
}
}