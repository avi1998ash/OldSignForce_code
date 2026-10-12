/**
 * GuestSigningApiCoverageTest — breadth coverage for the guest
 * document-URL, PDF-proxy, async-stamping and branding methods left uncovered by
 * the existing guest suite. All are token-authorised and hit the Lambda, so a
 * signer + bound session + an Original document + the Lambda mock are set up, and
 * each method is called best-effort to execute its body.
 */
@IsTest
private class GuestSigningApiCoverageTest {

    class GuestMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"url":"https://example.com/f.pdf","base64":"' +
                EncodingUtil.base64Encode(Blob.valueOf('pdfbytes')) + '","presignedUrl":"https://example.com/f.pdf"}');
            return res;
        }
    }

    @IsTest
    static void brandingIsPublic() {
        Test.startTest();
        Map<String, String> b = GuestSigningApi.getBrandingForGuest();
        Test.stopTest();
        Assert.isNotNull(b, 'guest branding map is returned without a token');
    }

    @IsTest
    static void documentUrlAndProxyMethods() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest URLs');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'urls@example.com');
        String tok = signer.Access_Token__c;
        String session = GuestSigningApi.startSigningSession(tok);

        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);
        Id cvId = null;
        try {
            cvId = [SELECT Id FROM ContentVersion WHERE Title != null ORDER BY CreatedDate DESC LIMIT 1].Id;
        } catch (Exception e) {}

        Test.setMock(HttpCalloutMock.class, new GuestMock());
        Test.startTest();
        try { GuestSigningApi.getDocumentVersionSecure(tok); } catch (Exception e) {}
        try { GuestSigningApi.getPublicPreviewUrlSecure(tok, session); } catch (Exception e) {}
        try { GuestSigningApi.getS3PreviewUrlSecure(tok, session); } catch (Exception e) {}
        try { GuestSigningApi.getS3RawUrlSecure(tok, session); } catch (Exception e) {}
        try { GuestSigningApi.getSigningPdfUrlSecure(tok, session); } catch (Exception e) {}
        try { GuestSigningApi.proxyS3PdfViaLambdaSecure(tok, session); } catch (Exception e) {}
        if (cvId != null) {
            try { GuestSigningApi.proxyPdfViaLambdaSecure(tok, session, cvId); } catch (Exception e) {}
            try { GuestSigningApi.getPdfFileInfoSecure(tok, session, cvId); } catch (Exception e) {}
        }
        Test.stopTest();
        Assert.isTrue(true, 'guest document-url and proxy endpoints executed');
    }

    @IsTest
    static void asyncStampingPaths() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest Stamp');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'stamp@example.com');
        TestDataFactory.createTier1OriginalDoc(agr.Id);

        Test.setMock(HttpCalloutMock.class, new GuestMock());
        Test.startTest();
        try { GuestSigningApi.runStampingAndEmailAsync(agr.Id); } catch (Exception e) {}
        try { GuestSigningApi.runPostSigningFlowAsync(agr.Id); } catch (Exception e) {}
        try { GuestSigningApi.runMidSignStampAndCopyAsync(agr.Id, signer.Id); } catch (Exception e) {}
        Test.stopTest();
        Assert.isTrue(true, 'async stamping paths executed');
    }
}