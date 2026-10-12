@IsTest
private class SigningControllerTest {
    private static void setRequest(String token) {
        RestRequest req = new RestRequest();
        req.requestUri = '/services/apexrest/signing/';
        req.httpMethod = 'GET';
        req.params.put('token', token);
        req.headers.put('User-Agent', 'Apex Test');
        RestContext.request = req;
        RestContext.response = new RestResponse();
    }

    @IsTest
    static void getSigningDataRunsNoAssert() {
        setRequest(null);
        SigningController.SigningResponse blankTokenRes = SigningController.getSigningData();

        setRequest('missing-token');
        SigningController.SigningResponse unknownTokenRes = SigningController.getSigningData();

        Agreement__c agr = TestDataFactory.createSentAgreement('Signing Controller Coverage');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'signing@example.com');
        TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 20, 30);
        TestDataFactory.createTier1OriginalDoc(agr.Id);

        setRequest(signer.Access_Token__c);
        SigningController.SigningResponse validTokenRes = SigningController.getSigningData();

        Assert.areEqual(false, blankTokenRes.success,
            'A request with no token must be refused');
        Assert.areEqual('Invalid token', blankTokenRes.error,
            'A blank token is reported as an invalid token');
        Assert.areEqual(false, unknownTokenRes.success,
            'A token that matches no signer must be refused');
        Assert.areEqual('Invalid or expired link', unknownTokenRes.error,
            'An unmatched token is reported as an invalid or expired link');
        Assert.areEqual(true, validTokenRes.success,
            'A pending signer on a Sent agreement should be able to load the signing data');
        Assert.areEqual(String.valueOf(signer.Id), validTokenRes.signerId,
            'The response resolves the signer that owns the token');
        Assert.areEqual(1, validTokenRes.fields.size(),
            'The one signature field assigned to this signer is returned');
        Assert.areEqual(1, validTokenRes.documents.size(),
            'The Original document is returned for signing');
    }
}